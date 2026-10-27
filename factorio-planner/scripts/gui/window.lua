-- The main draggable window with the Plan, Factories and Items tabs.

local common = require("scripts.gui.common")
local model = require("scripts.model")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local window = {}

window.TABS = { "plan", "factories", "items" }

-- Tab builders, registered by the tab modules: builder(player, container, ctx)
window.builders = {}

local function get(player)
  local w = player.gui.screen.fp_window
  if w and w.valid then return w end
  return nil
end
window.get = get

function window.is_open(player)
  return get(player) ~= nil
end

local function tab_index(name)
  for i, n in ipairs(window.TABS) do
    if n == name then return i end
  end
  return 1
end

function window.open(player, tab)
  local state = model.player(player.index)
  if tab then state.tab = tab end
  local w = get(player)
  if w then
    w.bring_to_front()
    window.select_tab(player, state.tab)
    return w
  end
  w = player.gui.screen.add({ type = "frame", name = "fp_window", direction = "vertical" })
  common.titlebar(w, L("title"), "window_close", {
    { type = "sprite-button", style = "frame_action_button", sprite = "utility/clock", tooltip = L("log"), tags = { fp = "open_log" } },
    { type = "sprite-button", style = "frame_action_button", sprite = "utility/preset", tooltip = L("settings"), tags = { fp = "open_settings" } },
  })
  local inner = w.add({ type = "frame", name = "fp_inner", style = "inside_deep_frame", direction = "vertical" })
  local tabs = inner.add({ type = "tabbed-pane", name = "fp_tabs", style = "tabbed_pane_with_no_side_padding", tags = { fp = "tab_changed" } })
  for _, name in ipairs(window.TABS) do
    local tab = tabs.add({ type = "tab", name = "fp_tab_" .. name, caption = L("tab-" .. name) })
    local content = tabs.add({ type = "flow", name = "fp_content_" .. name, direction = "vertical" })
    content.style.padding = 8
    content.style.vertical_spacing = 6
    content.style.width = 980
    tabs.add_tab(tab, content)
  end
  tabs.selected_tab_index = tab_index(state.tab)
  if state.location then
    w.location = state.location
  else
    w.auto_center = true
  end
  player.opened = w
  window.refresh(player)
  return w
end

function window.close(player)
  local w = get(player)
  if w then w.destroy() end
  common.close_dialog(player)
end

function window.toggle(player)
  if get(player) then window.close(player) else window.open(player) end
end

function window.select_tab(player, name)
  local state = model.player(player.index)
  state.tab = name
  local w = get(player)
  if not w then return end
  local tabs = w.fp_inner.fp_tabs
  tabs.selected_tab_index = tab_index(name)
  window.refresh(player)
end

--- Rebuild the selected tab.
function window.refresh(player)
  local w = get(player)
  if not w then return end
  local state = model.player(player.index)
  local container = w.fp_inner.fp_tabs["fp_content_" .. state.tab]
  if not container then return end
  local builder = window.builders[state.tab]
  container.clear()
  if builder then builder(player, container, common.ctx(player)) end
end

--- Refresh every player who has the window open. A player's open factory
--- editor is left alone (it shows their private draft, possibly mid-typing).
function window.refresh_all(opts)
  local except = opts and opts.except
  for _, player in pairs(game.connected_players) do
    if get(player) and player.index ~= except then
      local state = model.player(player.index)
      if not (state.tab == "factories" and state.draft) then
        window.refresh(player)
      else
        window.refresh_editor_status(player)
      end
    end
  end
end

-- Set by the editor module: updates parts of the editor that depend on shared state.
window.refresh_editor_status = function() end

handlers.window_close = function(player)
  window.close(player)
end

handlers.tab_changed = function(player, element, event)
  if event.name ~= defines.events.on_gui_selected_tab_changed then return end
  local name = window.TABS[element.selected_tab_index] or "plan"
  window.select_tab(player, name)
end

-- Settings dialog -------------------------------------------------------------------------

local function settings_dialog(player)
  local ctx = common.ctx(player)
  local frame = common.open_dialog(player, "settings", L("settings"))
  local body = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  local t = body.add({ type = "table", column_count = 2 })
  t.style.vertical_spacing = 8
  t.style.horizontal_spacing = 12

  t.add({ type = "label", caption = L("setting-unit") })
  local units = {}
  local selected = 1
  for i, u in ipairs(fp_util.UNIT_ORDER) do
    units[i] = fp_util.UNITS[u].suffix
    if u == ctx.unit then selected = i end
  end
  t.add({ type = "drop-down", items = units, selected_index = selected, tags = { fp = "set_unit" } })

  t.add({ type = "label", caption = L("setting-edit"), tooltip = L("setting-edit-tooltip") })
  t.add({
    type = "drop-down", items = { L("edit-everyone"), L("edit-admins") },
    selected_index = model.edit_mode() == "admins" and 2 or 1,
    enabled = player.admin, tags = { fp = "set_edit_mode" },
  })

  t.add({ type = "label", caption = L("setting-max-belt") })
  local items = { L("best-researched") }
  local current = settings.global["fp-max-belt"].value
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
  if u then player.mod_settings["fp-rate-unit"] = { value = u } end
end

handlers.set_edit_mode = function(player, element)
  if not player.admin then return end
  settings.global["fp-edit-permission"] = { value = element.selected_index == 2 and "admins" or "everyone" }
  model.log(player.index, { "fp.log-edit-mode", L("edit-" .. model.edit_mode()) }, nil)
end

handlers.set_max_belt = function(player, element)
  if not model.can_edit(player) then return end
  local tiers = common.ctx(player).tiers
  local i = element.selected_index
  settings.global["fp-max-belt"] = { value = i > 1 and tiers[i - 1].name or "" }
end

handlers.set_one_lane = function(player, element)
  if not model.can_edit(player) then return end
  settings.global["fp-one-lane"] = { value = element.state }
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
