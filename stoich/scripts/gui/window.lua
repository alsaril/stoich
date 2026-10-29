-- The main draggable window (the plan: factories, sinks and splits) and its child
-- windows: the factory editor, statistics and a plan split. Esc / E closes the
-- frontmost one first.

local common = require("scripts.gui.common")
local model = require("scripts.model")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local window = {}

-- Builds the main window's content, set by the plan module: builder(player, container, ctx)
window.builder = nil

-- Child windows, frontmost first: the one that takes Esc / E when several are open.
window.CHILDREN = { "stoich_editor", "stoich_split", "stoich_stats" }
local IS_CHILD = {}
for _, name in ipairs(window.CHILDREN) do IS_CHILD[name] = true end
window.IS_CHILD = IS_CHILD

-- What a child does when the player closes it, by frame name (set by its module):
-- close(player) -> true when it closed (false: it asked first and stays open)
window.child_close = {}

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

--- Give Esc / E to the frontmost window still open.
function window.refocus(player)
  for _, name in ipairs(window.CHILDREN) do
    local c = window.child(player, name)
    if c and c.visible then return window.focus(player, c) end
  end
  local w = get(player)
  if w and w.visible then window.focus(player, w) end
end

function window.open(player)
  local w = get(player)
  if w then
    w.bring_to_front()
    return w
  end
  local state = model.player(player.index)
  w = player.gui.screen.add({ type = "frame", name = "stoich_window", direction = "vertical" })
  local size = window.size(player)
  w.style.width = size.width
  w.style.height = size.height
  common.titlebar(w, L("title"), "window_close", {
    { type = "sprite-button", style = "frame_action_button", sprite = "utility/grid_view",
      tooltip = L(state.compact and "size-large" or "size-compact"), tags = { fp = "window_size" } },
    { type = "sprite-button", style = "frame_action_button", sprite = "utility/clock", tooltip = L("log"), tags = { fp = "open_log" } },
    { type = "sprite-button", style = "frame_action_button", sprite = "utility/preset", tooltip = L("settings"), tags = { fp = "open_settings" } },
  })
  local inner = w.add({ type = "frame", name = "stoich_inner", style = "inside_deep_frame", direction = "vertical" })
  inner.style.vertically_stretchable = true
  inner.style.horizontally_stretchable = true
  local content = inner.add({ type = "flow", name = "stoich_content", direction = "vertical" })
  content.style.padding = 8
  content.style.vertical_spacing = 6
  -- the content fills the window; scroll panes inside take the remaining height
  content.style.horizontally_stretchable = true
  content.style.vertically_stretchable = true
  if state.location then
    w.location = state.location
  else
    w.auto_center = true
  end
  window.refresh(player)
  window.refocus(player)
  return w
end

--- Open (or bring forward) a child window and give it Esc / E.
--- @param opts table { width?, height? }
--- @return LuaGuiElement frame, LuaGuiElement content flow, boolean created
function window.open_child(player, name, caption, opts)
  opts = opts or {}
  local frame = window.child(player, name)
  local created = false
  if not frame then
    created = true
    frame = player.gui.screen.add({ type = "frame", name = name, direction = "vertical" })
    if opts.width then frame.style.width = opts.width end
    if opts.height then frame.style.height = opts.height end
    common.titlebar(frame, caption, "child_close")
    local inner = frame.add({ type = "frame", name = "stoich_inner", style = "inside_deep_frame", direction = "vertical" })
    inner.style.vertically_stretchable = true
    inner.style.horizontally_stretchable = true
    local content = inner.add({ type = "flow", name = "stoich_content", direction = "vertical" })
    content.style.padding = 8
    content.style.vertical_spacing = 6
    content.style.horizontally_stretchable = true
    content.style.vertically_stretchable = true
    local locations = model.player(player.index).locations
    if locations and locations[name] then frame.location = locations[name] else frame.auto_center = true end
  else
    frame.stoich_titlebar.children[1].caption = caption
  end
  frame.visible = true
  frame.bring_to_front()
  window.focus(player, frame)
  return frame, frame.stoich_inner.stoich_content, created
end

--- Content flow of an open child window, or nil.
function window.child_content(player, name)
  local c = window.child(player, name)
  return c and c.stoich_inner.stoich_content or nil
end

function window.destroy_child(player, name)
  local c = window.child(player, name)
  if c then c.destroy() end
  window.refocus(player)
end

--- Hide every window (while the player drags a recapture area on the map), or show them again.
function window.set_hidden(player, hidden)
  local w = get(player)
  if w then w.visible = not hidden end
  for _, name in ipairs(window.CHILDREN) do
    local c = window.child(player, name)
    if c then c.visible = not hidden end
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
  for _, name in ipairs(window.CHILDREN) do
    local c = window.child(player, name)
    if c then c.destroy() end
  end
  window.close(player)
end

-- Set by the editor module: false when an unsaved editor must ask before the main
-- window (and with it the editor) closes.
window.can_close_all = function() return true end

--- The player closed the main window (Esc, E, the close button or the hotkey):
--- every child window goes with it, after asking about unsaved changes.
function window.close_by_player(player)
  if not window.can_close_all(player) then return end
  window.close_all(player)
end

--- The player closed a child window (Esc, E or its close button).
function window.close_child_by_player(player, name)
  local close = window.child_close[name]
  if close then close(player) else window.destroy_child(player, name) end
end

function window.toggle(player)
  if get(player) then window.close_by_player(player) else window.open(player) end
end

--- Main window size: most of the screen, or a fixed compact size.
--- (Factorio mod windows can't be resized by dragging.)
function window.size(player)
  local state = model.player(player.index)
  if state.compact then return window.COMPACT end
  return window.large_size(player)
end

window.COMPACT = { width = 860, height = 560 }
window.EDITOR_WIDTH = 900
window.SINK_WIDTH = 460

function window.large_size(player)
  local res = player.display_resolution or { width = 1920, height = 1080 }
  local scale = player.display_scale or 1
  local width = math.floor(res.width / scale * 0.8)
  local height = math.floor(res.height / scale * 0.85)
  return { width = math.max(900, math.min(width, 1600)), height = math.max(500, math.min(height, 1200)) }
end

--- Rebuild the main window's content.
function window.refresh(player)
  local w = get(player)
  if not w then return end
  local container = w.stoich_inner.stoich_content
  container.clear()
  if window.builder then window.builder(player, container, common.ctx(player)) end
end

--- Show the current rate unit in an open settings dialog (it can also change in the game's mod settings).
function window.sync_unit(player)
  local d = player.gui.screen.stoich_dialog
  local dd = d and d.valid and common.find(d, "stoich_unit")
  if not dd then return end
  local unit = player.mod_settings["stoich-rate-unit"].value
  for i, u in ipairs(fp_util.UNIT_ORDER) do
    if u == unit then dd.selected_index = i end
  end
end

--- Rebuild the main window (e.g. after a size change).
function window.reopen(player)
  if not get(player) then return end
  local state = model.player(player.index)
  window.close(player)
  state.location = nil
  window.open(player)
end

-- Child windows that show shared plan state, refreshed with the main window
-- (set by their modules): refresh(player, opts)
window.child_refresh = {}

--- Refresh every player's windows after a plan change. An open factory editor
--- only updates its status (it shows the player's private draft, possibly mid-typing).
--- @param opts table? passed to the child refreshers (see plan.changed)
function window.refresh_all(opts)
  for _, player in pairs(game.connected_players) do
    if get(player) then window.refresh(player) end
    for _, name in ipairs(window.CHILDREN) do
      local refresh = window.child_refresh[name]
      if refresh and window.child(player, name) then refresh(player, opts or {}) end
    end
    if window.child(player, "stoich_editor") then window.refresh_editor_status(player) end
  end
end

-- Set by the editor module: updates parts of the editor that depend on shared state.
window.refresh_editor_status = function() end

--- on_gui_closed: Esc / E (or another GUI opening) closed one of our windows.
-- Set by the editor module: true while a close must be ignored (a recapture is under
-- way, or the editor just switched to the map view, which closes the open GUI).
window.keep_open = function() return false end

function window.on_closed(player, element)
  local state = model.player(player.index)
  if state.focusing then return end -- we moved Esc / E to another window ourselves
  if window.keep_open(player) then return end
  if element.name == "stoich_window" then
    window.close_by_player(player)
  elseif IS_CHILD[element.name] then
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

handlers.window_size = function(player)
  local state = model.player(player.index)
  state.compact = not state.compact or nil
  window.reopen(player)
end

-- Settings dialog -------------------------------------------------------------------------

local function settings_dialog(player)
  local ctx = common.ctx(player)
  local frame = common.open_dialog(player, "settings", L("settings"))
  local body = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  local t = body.add({ type = "table", column_count = 2 })
  t.style.vertical_spacing = 8
  t.style.horizontal_spacing = 12

  -- the rate unit applies to every tab; it lives here only
  t.add({ type = "label", caption = L("setting-unit") })
  local units, selected = {}, 2
  for i, u in ipairs(fp_util.UNIT_ORDER) do
    units[i] = fp_util.UNITS[u].suffix
    if u == ctx.unit then selected = i end
  end
  t.add({ type = "drop-down", name = "stoich_unit", items = units, selected_index = selected, tags = { fp = "set_unit" } })

  t.add({ type = "label", caption = L("setting-edit"), tooltip = L("setting-edit-tooltip") })
  t.add({
    type = "drop-down", items = { L("edit-everyone"), L("edit-admins") },
    selected_index = model.edit_mode() == "admins" and 2 or 1,
    enabled = player.admin, tags = { fp = "set_edit_mode" },
  })

  t.add({ type = "label", caption = L("setting-max-belt") })
  local items = { L("best-researched") }
  local current = settings.global["stoich-max-belt"].value
  local sel = 1
  for i, tier in ipairs(ctx.tiers) do
    items[#items + 1] = { "", "[entity=" .. tier.name .. "] ", common.entity_name(tier.name), " (" .. fp_util.format_number(tier.capacity) .. "/s)" }
    if tier.name == current then sel = i + 1 end
  end
  t.add({ type = "drop-down", items = items, selected_index = sel, enabled = ctx.can_edit, tags = { fp = "set_max_belt" } })

  t.add({ type = "label", caption = L("setting-one-lane") })
  t.add({ type = "checkbox", state = ctx.one_lane, enabled = ctx.can_edit, tags = { fp = "set_one_lane" } })
end

handlers.open_settings = function(player)
  settings_dialog(player)
end

handlers.set_unit = function(player, element)
  local u = fp_util.UNIT_ORDER[element.selected_index]
  if u then player.mod_settings["stoich-rate-unit"] = { value = u } end
end

handlers.set_edit_mode = function(player, element)
  if not player.admin then return end
  settings.global["stoich-edit-permission"] = { value = element.selected_index == 2 and "admins" or "everyone" }
  model.log(player.index, { "stoich.log-edit-mode", L("edit-" .. model.edit_mode()) }, nil)
end

handlers.set_max_belt = function(player, element)
  if not model.can_edit(player) then return end
  local tiers = common.ctx(player).tiers
  local i = element.selected_index
  settings.global["stoich-max-belt"] = { value = i > 1 and tiers[i - 1].name or "" }
end

handlers.set_one_lane = function(player, element)
  if not model.can_edit(player) then return end
  settings.global["stoich-one-lane"] = { value = element.state }
end

-- Edit log -------------------------------------------------------------------------------------

handlers.open_log = function(player)
  local frame = common.open_dialog(player, "log", L("log"))
  local pane = frame.add({ type = "scroll-pane", style = "scroll_pane" })
  pane.style.maximal_height = 500
  pane.style.minimal_width = 420
  local t = pane.add({ type = "table", column_count = 4, draw_horizontal_lines = true })
  t.style.horizontal_spacing = 12
  if #storage.log == 0 then
    pane.add({ type = "label", caption = L("log-empty") })
  end
  for i = #storage.log, 1, -1 do
    local e = storage.log[i]
    t.add({ type = "label", caption = common.time_ago(e.tick) })
    t.add({ type = "label", caption = common.player_name(e.player), style = "bold_label" })
    t.add({ type = "label", caption = e.action })
    t.add({ type = "label", caption = e.factory or "" })
  end
end

return window
