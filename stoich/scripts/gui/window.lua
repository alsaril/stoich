-- The main window (the plan: factories, sinks and splits) and its child windows:
-- the factory editor, statistics and a plan split. One child at a time; the main
-- window hides while it is open and comes back when it closes. Esc / E closes the
-- child first, then the main window.

local common = require("scripts.gui.common")
local model = require("scripts.model")
local plan = require("scripts.plan")

local L = common.L
local handlers = common.handlers

local window = {}

-- One size for every screen (mod windows can't be resized by dragging); the child
-- windows take the main window's height.
window.SIZE = { width = 960, height = 680 }
window.EDITOR_WIDTH = 900
window.SINK_WIDTH = 460

-- Builds the main window's content, set by the plan module: builder(player, container, ctx)
window.builder = nil

-- Child windows by frame name, registered by their modules:
--   refresh(player, opts, ctx)   after a plan change (opts from window.plan_changed)
--   rebuild(player, ctx)         from scratch (rate unit or permissions changed)
--   close(player)?               the player closed it (may ask first); default: destroy
--   dismiss(player)?             closed by another child opening; default: destroy
--   before_close_all(player)?    -> false when it asked first (the main window stays)
--   keep_open(player)?           -> true while a close must be ignored
window.children = {}
local CHILD_NAMES = {}

function window.register_child(name, def)
  if not window.children[name] then CHILD_NAMES[#CHILD_NAMES + 1] = name end
  window.children[name] = def
end

local function get(player)
  local w = player.gui.screen.stoich_window
  if w and w.valid then return w end
  return nil
end
window.get = get

function window.child(player, name)
  local c = player.gui.screen[name]
  if c and c.valid then return c end
  return nil
end

--- The open child window's name, if any.
local function open_child_name(player)
  for _, name in ipairs(CHILD_NAMES) do
    if window.child(player, name) then return name end
  end
  return nil
end
window.open_child_name = open_child_name

function window.is_open(player)
  return get(player) ~= nil
end

--- Make a frame the one Esc / E closes. Writing player.opened asks the previous
--- GUI to close (on_gui_closed); that close is ours to ignore.
function window.focus(player, frame)
  if not (frame and frame.valid) then return end
  local state = model.player(player.index)
  state.focusing = true
  player.opened = frame
  state.focusing = nil
end

--- Give Esc / E to the child window if one is open, else to the main window.
function window.refocus(player)
  local name = open_child_name(player)
  local frame = name and window.child(player, name) or get(player)
  if frame and frame.visible then window.focus(player, frame) end
end

local function content_frame(frame)
  local inner = frame.add({ type = "frame", name = "stoich_inner", style = "inside_deep_frame", direction = "vertical" })
  inner.style.vertically_stretchable = true
  inner.style.horizontally_stretchable = true
  local content = inner.add({ type = "flow", name = "stoich_content", direction = "vertical" })
  content.style.padding = 8
  content.style.vertical_spacing = 6
  -- the content fills the window; scroll panes inside take the remaining height
  content.style.horizontally_stretchable = true
  content.style.vertically_stretchable = true
  return content
end

function window.open(player, ctx)
  local w = get(player)
  if w then
    w.bring_to_front()
    return w
  end
  local state = model.player(player.index)
  w = player.gui.screen.add({ type = "frame", name = "stoich_window", direction = "vertical" })
  w.style.width = window.SIZE.width
  w.style.height = window.SIZE.height
  common.titlebar(w, L("title"), "window_close", {
    { type = "sprite-button", style = "frame_action_button", sprite = "utility/clock", tooltip = L("log"), tags = { fp = "open_log" } },
    { type = "sprite-button", style = "frame_action_button", sprite = "utility/preset", tooltip = L("settings"), tags = { fp = "open_settings" } },
  })
  content_frame(w)
  if state.location then
    w.location = state.location
  else
    w.auto_center = true
  end
  -- rebuilt while a child is open (a size toggle, a mod update): it stays hidden under it
  if open_child_name(player) then w.visible = false end
  window.refresh(player, ctx)
  window.refocus(player)
  return w
end

--- Open (or bring forward) a child window in place of the main window and give it Esc / E.
--- Another open child is closed first (dismissed: no questions).
--- @param opts table { width?, height? }
--- @return LuaGuiElement frame, LuaGuiElement content flow
function window.open_child(player, name, caption, opts)
  opts = opts or {}
  local other = open_child_name(player)
  if other and other ~= name then
    local dismiss = window.children[other].dismiss
    if dismiss then dismiss(player) else window.child(player, other).destroy() end
  end
  window.open(player)
  local frame = window.child(player, name)
  if not frame then
    frame = player.gui.screen.add({ type = "frame", name = name, direction = "vertical" })
    common.titlebar(frame, caption, "child_close")
    content_frame(frame)
    local locations = model.player(player.index).locations
    if locations and locations[name] then frame.location = locations[name] else frame.auto_center = true end
  else
    frame.stoich_titlebar.children[1].caption = caption
  end
  if opts.width then frame.style.width = opts.width end
  if opts.height then frame.style.height = opts.height end
  local w = get(player)
  if w then w.visible = false end
  frame.visible = true
  frame.bring_to_front()
  window.focus(player, frame)
  return frame, frame.stoich_inner.stoich_content
end

--- Content flow of an open child window, or nil.
function window.child_content(player, name)
  local c = window.child(player, name)
  return c and c.stoich_inner.stoich_content or nil
end

--- Close a child window: the main window comes back.
function window.destroy_child(player, name)
  local c = window.child(player, name)
  if c then c.destroy() end
  local w = get(player)
  if w and not model.player(player.index).recapture then w.visible = true end
  window.refocus(player)
end

--- Hide every window (while the player drags a recapture area on the map), or show
--- them again: the child if one is open, else the main window.
--- @param hint LocalisedString? shown at the top of the screen while hidden
function window.set_hidden(player, hidden, hint)
  local name = open_child_name(player)
  local c = name and window.child(player, name)
  local w = get(player)
  if c then c.visible = not hidden end
  if w then w.visible = not hidden and not c end
  local old = player.gui.screen.stoich_hint
  if old and old.valid then old.destroy() end
  if hidden and hint then
    local frame = player.gui.screen.add({ type = "frame", name = "stoich_hint", direction = "horizontal" })
    frame.add({ type = "label", caption = hint, style = "bold_label" })
    local res, scale = player.display_resolution, player.display_scale or 1
    frame.location = { x = math.floor(res.width / 2 - 220 * scale), y = math.floor(80 * scale) }
  end
  if not hidden then window.refocus(player) end
end

--- Close the main window only (rebuilds keep the child windows and the editor).
function window.close(player)
  local w = get(player)
  if w then w.destroy() end
  common.close_dialog(player)
end

--- Close every window this mod has open for the player.
function window.close_all(player)
  for _, name in ipairs(CHILD_NAMES) do
    local c = window.child(player, name)
    if c then c.destroy() end
  end
  local hint = player.gui.screen.stoich_hint
  if hint and hint.valid then hint.destroy() end
  window.close(player)
  model.player(player.index).plan_order = nil -- sorted afresh next time
end

--- The player closed the main window (Esc, E, the close button or the hotkey):
--- the child window goes with it, after asking about unsaved changes.
function window.close_by_player(player)
  for _, name in ipairs(CHILD_NAMES) do
    local before = window.children[name].before_close_all
    if window.child(player, name) and before and not before(player) then return end
  end
  window.close_all(player)
end

--- The player closed a child window (Esc, E or its close button).
function window.close_child_by_player(player, name)
  local close = window.children[name] and window.children[name].close
  if close then close(player) else window.destroy_child(player, name) end
end

function window.toggle(player)
  if get(player) then window.close_by_player(player) else window.open(player) end
end

--- Rebuild the main window's content.
function window.refresh(player, ctx)
  local w = get(player)
  if not w then return end
  local container = w.stoich_inner.stoich_content
  container.clear()
  if window.builder then window.builder(player, container, ctx or common.ctx(player)) end
end

--- Refresh every player's windows after a plan change. An open factory editor
--- only updates its status (it shows the player's private draft, possibly mid-typing).
--- @param opts table? passed to the child windows (see window.plan_changed)
function window.refresh_all(opts)
  for _, player in pairs(game.connected_players) do
    local ctx = common.ctx(player)
    window.refresh(player, ctx)
    local name = open_child_name(player)
    if name then window.children[name].refresh(player, opts or {}, ctx) end
  end
end

--- Rebuild everything a player has open (the rate unit or permissions changed).
function window.rebuild_player(player)
  local ctx = common.ctx(player)
  window.refresh(player, ctx)
  local name = open_child_name(player)
  if name then window.children[name].rebuild(player, ctx) end
end

--- After any change to factories, sinks, copies or splits: balance the plan once
--- and refresh every player's windows.
--- @param opts table? { keep_split = player_index, line = id }: that player's split
---   window is updated in place instead of rebuilt (they are dragging its slider)
function window.plan_changed(opts)
  plan.rebalance()
  window.refresh_all(opts)
end

--- Show an area on the map (remote view). The view switch closes the open GUI; the
--- windows stay as they are for when the player comes back.
function window.show_on_map(player, source)
  if not (source and source.areas and #source.areas > 0) then
    player.print(L("no-area"))
    return
  end
  local surface = game.get_surface(source.surface_index)
  if not surface then
    player.print(L("no-surface"))
    return
  end
  local l, t, r, b = math.huge, math.huge, -math.huge, -math.huge
  for _, area in ipairs(source.areas) do
    local lt, rb = area.left_top, area.right_bottom
    l, t = math.min(l, lt.x), math.min(t, lt.y)
    r, b = math.max(r, rb.x), math.max(b, rb.y)
    rendering.draw_rectangle({
      color = { r = 0.3, g = 0.9, b = 0.4, a = 0.8 }, width = 4, filled = false,
      left_top = lt, right_bottom = rb, surface = surface, players = { player }, time_to_live = 60 * 15,
    })
  end
  model.player(player.index).map_tick = game.tick
  player.set_controller({ type = defines.controllers.remote, position = { x = (l + r) / 2, y = (t + b) / 2 }, surface = surface })
end

--- on_gui_closed: Esc / E (or another GUI opening) closed one of our windows.
function window.on_closed(player, element)
  local state = model.player(player.index)
  if state.focusing then return end -- we moved Esc / E to another window ourselves
  if state.map_tick == game.tick then return end -- the switch to the map view
  for _, name in ipairs(CHILD_NAMES) do
    local keep = window.children[name].keep_open
    if keep and keep(player) then return end
  end
  if element.name == "stoich_window" then
    window.close_by_player(player)
  elseif window.children[element.name] then
    window.close_child_by_player(player, element.name)
  end
end

handlers.window_close = function(player)
  window.close_by_player(player)
end

handlers.child_close = function(player, element)
  -- the close button sits in the child's title bar, right under its frame
  local frame = element.parent.parent
  window.close_child_by_player(player, frame.name)
end

return window
