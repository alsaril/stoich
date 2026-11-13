-- Event wiring only; the work happens in scripts/.

local model = require("scripts.model")
local plan = require("scripts.plan")
local draft = require("scripts.draft")
local scanner = require("scripts.scanner")
local fp_util = require("scripts.util")
local common = require("scripts.gui.common")
local window = require("scripts.gui.window")
local editor = require("scripts.gui.editor")
require("scripts.gui.actions")
require("scripts.gui.recipe")
local dialogs = require("scripts.gui.dialogs")
local plan_gui = require("scripts.gui.plan")
local items = require("scripts.gui.items")

local L = common.L
local TOOL = "stoich-selection-tool"


-- Lifecycle -----------------------------------------------------------------------------------

local function rebuild_all_guis()
  for _, player in pairs(game.players) do
    local was_open = window.is_open(player)
    window.close_all(player)
    if player.connected then
      if was_open then window.open(player) end
      editor.restore(player) -- a draft always has its editor window
    end
  end
end

script.on_init(function()
  model.init()
end)

script.on_load(function()
  -- Nothing to restore: all state is in storage and nothing is written here.
end)

script.on_configuration_changed(function()
  model.migrate()
  local bad = model.validate_all()
  for _, key in ipairs(model.plan_keys()) do
    for _, id in ipairs(model.factory_ids(key)) do plan.balance_factory(model.get(id)) end
  end
  for _, state in pairs(storage.players) do
    if state.draft then plan.balance_factory(state.draft.factory) end
    model.reset_transient(state)
  end
  plan.rebalance_all()
  rebuild_all_guis()
  if bad > 0 then game.print(L("invalid-after-update", bad)) end
end)

script.on_event(defines.events.on_player_joined_game, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  local state = model.player(player.index)
  model.reset_transient(state)
  -- Rebuild the window if it was open when the player left.
  if state.was_open then
    state.was_open = nil
    window.close_all(player)
    window.open(player)
  end
  editor.restore(player)
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

-- A plan belongs to its surface's name: a renamed surface takes its plan along.
script.on_event(defines.events.on_surface_renamed, function(event)
  if model.rename_plan(event.old_name, event.new_name) then
    for _, player in pairs(game.connected_players) do window.refresh(player) end
  end
end)

-- Window and tool -----------------------------------------------------------------------------------

local function toggle(player)
  window.toggle(player)
end

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name ~= "stoich-toggle-window" then return end
  local player = game.get_player(event.player_index)
  if player then toggle(player) end
end)

script.on_event("stoich-toggle-window", function(event)
  local player = game.get_player(event.player_index)
  if player then toggle(player) end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local element = event.element
  if not (element and element.valid and element.get_mod() == script.mod_name) then return end
  local player = game.get_player(event.player_index)
  if player then window.on_closed(player, element) end
end)

script.on_event(defines.events.on_gui_location_changed, function(event)
  local element = event.element
  if not (element and element.valid) then return end
  local state = model.player(event.player_index)
  if element.name == "stoich_window" then
    state.location = element.location
  elseif window.children[element.name] then
    state.locations = state.locations or {}
    state.locations[element.name] = element.location
  end
end)

-- GUI events all go through the tag dispatcher.
for _, name in ipairs({
  "on_gui_click", "on_gui_checked_state_changed", "on_gui_value_changed", "on_gui_text_changed",
  "on_gui_elem_changed", "on_gui_selection_state_changed", "on_gui_confirmed",
}) do
  script.on_event(defines.events[name], common.dispatch)
end

script.on_event(defines.events.on_runtime_mod_setting_changed, function(event)
  if event.setting == "stoich-rate-unit" then
    -- every number on screen is in the unit, typed ones too: rebuild all this player's windows
    local player = event.player_index and game.get_player(event.player_index)
    if player then
      dialogs.sync_unit(player)
      window.rebuild_player(player)
    end
  elseif event.setting == "stoich-edit-permission" then
    -- what is enabled changes everywhere, the editor included
    for _, player in pairs(game.connected_players) do window.rebuild_player(player) end
  elseif event.setting == "stoich-max-belt" or event.setting == "stoich-one-lane" then
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
  -- read before clear_cursor below, which ends a pending recapture
  local state = model.player(player.index)
  local recapture = state.recapture and draft.get(player.index) ~= nil
  state.recapture = nil
  local scan = scanner.scan_entities(event.entities, player.force)
  local area = { left_top = { x = event.area.left_top.x, y = event.area.left_top.y }, right_bottom = { x = event.area.right_bottom.x, y = event.area.right_bottom.y } }
  local source = { surface_index = event.surface.index, areas = { area } }
  -- a capture goes to the plan of the surface it was made on
  local key = event.surface.name
  player.clear_cursor()
  if recapture then
    if scan.production == 0 then
      player.print(L("nothing-selected"))
      editor.recapture(player, nil)
    else
      editor.recapture(player, draft.from_scan(scan, source))
    end
    return
  end
  if scan.production == 0 then
    if next(scan.generators) then
      local f = draft.sink_from_generators(scan.generators)
      editor.open_factory(player, f, { notice = L("sink-from-generators"), plan = key })
    else
      player.print(L("nothing-selected"))
    end
    return
  end
  local f = draft.from_scan(scan, source)
  -- the main product names a new capture (once translated); it isn't kept.
  -- Idle machines get their own line with a recipe picker, so there is no notice for them.
  local main = f.main_product
  f.main_product = nil
  editor.open_factory(player, f, { translate = main, plan = key })
end

script.on_event(defines.events.on_string_translated, function(event)
  local d = draft.get(event.player_index)
  if not (d and d.name_auto and d.name_request == event.id and event.translated) then return end
  d.factory.name = event.result
  d.name_auto = false
  local player = game.get_player(event.player_index)
  editor.set_name_field(player, event.result)
end)

script.on_event(defines.events.on_player_cursor_stack_changed, function(event)
  local state = storage.players[event.player_index]
  if not (state and state.recapture) then return end
  local player = game.get_player(event.player_index)
  local stack = player and player.cursor_stack
  if stack and stack.valid_for_read and stack.name == TOOL then return end
  editor.cancel_recapture(player)
end)

script.on_event(defines.events.on_player_selected_area, capture)
script.on_event(defines.events.on_player_alt_selected_area, capture)

-- Debug ---------------------------------------------------------------------------------------------

--- /stoich-lines: print the recipe lines of your open editor draft, with the raw
--- values to check against the in-game machine tooltips.
commands.add_command("stoich-lines", { "stoich.command-lines" }, function(cmd)
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

remote.add_interface("stoich", {
  --- For other mods / console checks: the cached result of a surface's plan (Nauvis by default).
  plan_result = function(surface_name)
    local p = storage.plans[surface_name or model.DEFAULT_PLAN]
    return p and p.result
  end,
})

-- Test driver ----------------------------------------------------------------------------------------
-- Lets a helper mod drive the mod like a player (scripts can't raise GUI events),
-- to take screenshots. Only registered when the hidden startup setting
-- stoich-debug-interface is on; the test helper mod turns it on, normal installs don't.

local EVENT_FOR = {
  ["button"] = "on_gui_click", ["sprite-button"] = "on_gui_click", ["checkbox"] = "on_gui_checked_state_changed",
  ["textfield"] = "on_gui_text_changed", ["text-box"] = "on_gui_text_changed", ["slider"] = "on_gui_value_changed",
  ["drop-down"] = "on_gui_selection_state_changed", ["choose-elem-button"] = "on_gui_elem_changed",
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

local debug_setting = settings.startup["stoich-debug-interface"]
if debug_setting and debug_setting.value then
  remote.add_interface("stoich-debug", {
    --- Open the main window, or one of its child windows: "statistics", "splits"
    --- (the first plan split).
    open = function(player_index, what)
      local player = game.get_player(player_index)
      window.open(player)
      local p = model.plan(model.selected(player_index))
      if what == "statistics" then
        items.open(player)
      elseif what == "splits" and p.splits[1] then
        plan_gui.open_split(player, p.splits[1].item)
      end
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
      if t == "checkbox" then
        if value == nil then element.state = not element.state else element.state = value end
      elseif t == "textfield" or t == "text-box" then element.text = tostring(value)
      elseif t == "slider" then element.slider_value = value
      elseif t == "drop-down" then element.selected_index = value
      elseif t == "choose-elem-button" then element.elem_value = value
      end
      common.dispatch({ name = defines.events[EVENT_FOR[t]], element = element, player_index = player_index, tick = game.tick })
      if (t == "textfield") and element.valid then
        common.dispatch({ name = defines.events.on_gui_confirmed, element = element, player_index = player_index, tick = game.tick })
      end
      return true
    end,
    draft = function(player_index)
      return draft.get(player_index)
    end,
    --- The open dialog's state (the recipe dialog's recipes, machines, modules...).
    dialog = function(player_index)
      local state = storage.players[player_index]
      return state and state.dialog
    end,
    --- Close the plan of a test world that lacks mines for some inputs: a source factory
    --- (one custom line) for each item nothing makes, a void for each item nothing uses.
    --- plan_key: default the plan player 1 looks at. Returns how many factories it added.
    plan_sources = function(plan_key)
      local key = plan_key or model.selected(1)
      local n = 0
      for _ = 1, 10 do
        local made, used, missing = {}, {}, {}
        for _, u in ipairs(plan.units(key)) do
          for k, v in pairs(u.flow) do
            if v > 0 then made[k] = true else used[k] = true end
          end
        end
        local seen = {}
        for _, problem in ipairs(model.plan(key).result.problems) do
          if problem.type == "conflict" then
            -- an item can be named by several conflicts: one source (or void) for it
            for _, item in ipairs(problem.items) do
              if not seen[item] then
                seen[item] = true
                missing[#missing + 1] = item
              end
            end
          end
        end
        if #missing == 0 then break end
        table.sort(missing)
        for _, item in ipairs(missing) do
          local sign = (not made[item] and 1) or (not used[item] and -1) or nil
          if sign then
            local f = model.new_factory("factory")
            local line = model.add_line(f, { kind = "custom", label = item, count = 1, flow = { [item] = sign } })
            f.name = fp_util.pretty_name(select(2, fp_util.parse_key(item))) .. (sign > 0 and " source" or " void")
            f.anchors[line.id] = 1
            f.external = { [item] = true }
            plan.balance_factory(f)
            model.save_factory(f, {}, 1, false, key)
            n = n + 1
          end
        end
        window.plan_changed(key)
      end
      return n
    end,
    --- The factories of a plan (default: the one player 1 looks at).
    factories = function(key)
      return model.plan(key or model.selected(1)).factories
    end,
    --- Scroll the plan list to its end (mods can't scroll each other's elements).
    scroll_plan = function(player_index)
      local w = window.get(game.get_player(player_index))
      local pane = w and common.find(w, "stoich_plan_pane")
      if pane then pane.scroll_to_bottom() end
      return pane ~= nil
    end,
  })
end
