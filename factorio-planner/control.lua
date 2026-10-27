-- Event wiring only; the work happens in scripts/.

local model = require("scripts.model")
local plan = require("scripts.plan")
local draft = require("scripts.draft")
local scanner = require("scripts.scanner")
local fp_util = require("scripts.util")
local common = require("scripts.gui.common")
local window = require("scripts.gui.window")
local editor = require("scripts.gui.editor")
local factories = require("scripts.gui.factories")
require("scripts.gui.plan")
require("scripts.gui.items")

local L = common.L
local TOOL = "fp-selection-tool"

-- Function values are never stored, so this is set again on every load.
plan.refresh_hook = function(opts) window.refresh_all(opts) end

-- Lifecycle -----------------------------------------------------------------------------------

local function rebuild_all_guis()
  for _, player in pairs(game.players) do
    local was_open = window.is_open(player)
    window.close(player)
    if was_open and player.connected then window.open(player) end
  end
end

script.on_init(function()
  model.init()
  plan.rebalance()
end)

script.on_load(function()
  -- Nothing to restore: all state is in storage and nothing is written here.
end)

script.on_configuration_changed(function()
  model.migrate()
  local bad = model.validate_all()
  for _, id in ipairs(model.factory_ids()) do plan.balance_factory(model.get(id)) end
  for _, state in pairs(storage.players) do
    if state.draft then plan.balance_factory(state.draft.factory) end
    state.dialog = nil
  end
  plan.rebalance()
  rebuild_all_guis()
  if bad > 0 then game.print(L("invalid-after-update", bad)) end
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local state = model.player(player.index)
  -- Rebuild the window if it was open when the player left.
  if state.was_open then
    state.was_open = nil
    window.close(player)
    window.open(player)
  end
end)

script.on_event(defines.events.on_player_left_game, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local state = model.player(player.index)
  state.was_open = window.is_open(player) or nil
end)

script.on_event(defines.events.on_player_removed, function(event)
  model.remove_player(event.player_index)
end)

-- Window and tool -----------------------------------------------------------------------------------

local function toggle(player)
  window.toggle(player)
end

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name ~= "fp-toggle-window" then return end
  local player = game.get_player(event.player_index)
  if player then toggle(player) end
end)

script.on_event("fp-toggle-window", function(event)
  local player = game.get_player(event.player_index)
  if player then toggle(player) end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local element = event.element
  if element and element.valid and element.name == "fp_window" then
    local player = game.get_player(event.player_index)
    if player then window.close(player) end
  end
end)

script.on_event(defines.events.on_gui_location_changed, function(event)
  local element = event.element
  if element and element.valid and element.name == "fp_window" then
    model.player(event.player_index).location = element.location
  end
end)

-- GUI events all go through the tag dispatcher.
for _, name in ipairs({
  "on_gui_click", "on_gui_checked_state_changed", "on_gui_value_changed", "on_gui_text_changed",
  "on_gui_elem_changed", "on_gui_selection_state_changed", "on_gui_confirmed", "on_gui_selected_tab_changed",
  "on_gui_switch_state_changed",
}) do
  script.on_event(defines.events[name], common.dispatch)
end

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "fp-rate-unit" then
    local player = event.player_index and game.get_player(event.player_index)
    if player and window.is_open(player) then window.refresh(player) end
  elseif event.setting == "fp-edit-permission" or event.setting == "fp-max-belt" or event.setting == "fp-one-lane" then
    window.refresh_all()
  end
end)

-- Capture --------------------------------------------------------------------------------------------

local function capture(event)
  if event.item ~= TOOL then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  if not model.can_edit(player) then
    player.print(L("no-permission"))
    return
  end
  local scan = scanner.scan_entities(event.entities, player.force)
  local area = { left_top = { x = event.area.left_top.x, y = event.area.left_top.y }, right_bottom = { x = event.area.right_bottom.x, y = event.area.right_bottom.y } }
  local source = { surface_index = event.surface.index, areas = { area } }
  player.clear_cursor()
  if scan.production == 0 then
    if next(scan.generators) then
      local f = draft.sink_from_generators(scan.generators)
      editor.open_factory(player, f, { notice = L("sink-from-generators") })
    else
      player.print(L("nothing-selected"))
    end
    return
  end
  local f = draft.from_scan(scan, source)
  local notice = nil
  if scan.idle > 0 then notice = L("idle-notice", scan.idle) end
  editor.open_factory(player, f, { notice = notice, translate = f.main_product })
end

script.on_event(defines.events.on_string_translated, function(event)
  local d = draft.get(event.player_index)
  if not (d and d.name_auto and d.name_request == event.id and event.translated) then return end
  d.factory.name = event.result
  d.name_auto = false
  local player = game.get_player(event.player_index)
  editor.set_name_field(player, event.result)
end)

script.on_event(defines.events.on_player_selected_area, capture)
script.on_event(defines.events.on_player_alt_selected_area, capture)

-- Debug ---------------------------------------------------------------------------------------------

--- /fp-lines: print the recipe lines of your open editor draft, with the raw
--- values to check against the in-game machine tooltips.
commands.add_command("fp-lines", { "fp.command-lines" }, function(cmd)
  local player = game.get_player(cmd.player_index)
  if not player then return end
  local d = draft.get(player.index)
  if not d then
    player.print(L("command-no-draft"))
    return
  end
  local f = d.factory
  player.print("== " .. (f.name or "?") .. " (" .. (f.result and f.result.status or "?") .. ")")
  for _, line in ipairs(f.lines) do
    local what = line.recipe or line.resource or line.label or "?"
    local head = string.format("#%d %s %s on %s ×%s", line.id, line.kind, what, line.machine or "-", fp_util.format_count(line.count))
    if line.speed then head = head .. string.format(" speed %.4f", line.speed) end
    if line.productivity then head = head .. string.format(" prod %+.1f%%", line.productivity * 100) end
    if line.idle then head = head .. " IDLE" end
    if line.overridden then head = head .. " OVERRIDDEN" end
    player.print(head)
    for _, key in ipairs(fp_util.sorted_keys(line.flow)) do
      local v = line.flow[key]
      player.print(string.format("    %s %+.4f/s (%+.3f/min) per machine", key, v, v * 60))
    end
  end
end)

remote.add_interface("factorio-planner", {
  --- For other mods / console checks: the cached plan result.
  plan_result = function() return model.plan().result end,
})

-- Test driver ----------------------------------------------------------------------------------------
-- Lets a scenario or helper mod drive the mod like a player (scripts can't raise
-- GUI events). Used to take screenshots; harmless in normal games.

local EVENT_FOR = {
  ["button"] = "on_gui_click", ["sprite-button"] = "on_gui_click", ["checkbox"] = "on_gui_checked_state_changed",
  ["textfield"] = "on_gui_text_changed", ["text-box"] = "on_gui_text_changed", ["slider"] = "on_gui_value_changed",
  ["drop-down"] = "on_gui_selection_state_changed", ["choose-elem-button"] = "on_gui_elem_changed",
  ["tabbed-pane"] = "on_gui_selected_tab_changed",
}

local function find_action(element, action, match)
  for _, child in pairs(element.children) do
    local tags = child.tags
    if tags.fp == action then
      local ok = true
      for k, v in pairs(match or {}) do
        if tags[k] ~= v then ok = false end
      end
      if ok then return child end
    end
    local found = find_action(child, action, match)
    if found then return found end
  end
end

remote.add_interface("factorio-planner-debug", {
  open = function(player_index, tab)
    local player = game.get_player(player_index)
    window.open(player, tab)
    if tab then window.select_tab(player, tab) end
  end,
  --- Capture an area as if the player dragged the tool over it.
  capture = function(player_index, area)
    local player = game.get_player(player_index)
    local types = {}
    for _, t in ipairs(scanner.PRODUCTION_TYPES) do types[#types + 1] = t end
    for _, t in ipairs(scanner.GENERATOR_TYPES) do types[#types + 1] = t end
    local entities = player.surface.find_entities_filtered({ area = area, type = types, force = player.force })
    capture({ player_index = player_index, item = TOOL, entities = entities, area = area, surface = player.surface })
  end,
  --- Operate one of the mod's GUI elements, found by its action tag.
  --- value: new state/text/slider value/index/elem value depending on the element type.
  act = function(player_index, action, match, value)
    local player = game.get_player(player_index)
    local element = find_action(player.gui.screen, action, match)
    if not element then return false end
    local t = element.type
    if t == "checkbox" then element.state = (value == nil) and not element.state or value
    elseif t == "textfield" or t == "text-box" then element.text = tostring(value)
    elseif t == "slider" then element.slider_value = value
    elseif t == "drop-down" then element.selected_index = value
    elseif t == "choose-elem-button" then element.elem_value = value
    elseif t == "tabbed-pane" then element.selected_tab_index = value end
    common.dispatch({ name = defines.events[EVENT_FOR[t]], element = element, player_index = player_index, tick = game.tick })
    if (t == "textfield") and element.valid then
      common.dispatch({ name = defines.events.on_gui_confirmed, element = element, player_index = player_index, tick = game.tick })
    end
    return true
  end,
  draft = function(player_index)
    return draft.get(player_index)
  end,
  factories = function()
    return model.plan().factories
  end,
})
