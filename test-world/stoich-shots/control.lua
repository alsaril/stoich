-- Drives Stoich through its GUI on the test world and takes
-- screenshots of every screen with realistic amounts of data (test only).
local D = "stoich-debug"
local P = 1
local log_lines = {}

local function note(s)
  log_lines[#log_lines + 1] = s
  log("stoich-shots: " .. s)
end

local function act(action, match, value)
  local ok = remote.call(D, "act", P, action, match or {}, value)
  note(action .. " " .. serpent.line(match or {}) .. " -> " .. tostring(ok))
  return ok
end

local function draft() return remote.call(D, "draft", P) end
-- "plan": the main window alone (child windows closed first);
-- "statistics", "splits": that window over it.
local function open(tab)
  if tab == "plan" then
    for _ = 1, 4 do
      if not remote.call(D, "act", P, "child_close", {}) then break end
    end
  end
  remote.call(D, "open", P, tab)
end

local function shot(name, opts)
  opts = opts or {}
  game.take_screenshot({ player = P, by_player = P, path = "shots/" .. name .. ".png", show_gui = opts.gui ~= false,
    zoom = opts.zoom, position = opts.position, force_render = true })
  note("shot " .. name)
end

local function zone(key) return remote.call("stoich-test-world", "zones")[key] end

local function capture(key)
  remote.call(D, "capture", P, zone(key).area)
  local d = draft()
  note("capture " .. key .. ": " .. (d and (d.factory.name .. " " .. d.factory.result.status) or "no draft"))
end

local function try_save(name)
  local d = draft()
  if not d then return end
  local status = d.factory.result.status
  act("editor_save")
  if draft() then
    note("NOT SAVED " .. name .. ": " .. tostring(status))
    shot("x-not-saved-" .. name)
    act("editor_cancel")
  end
end

local function factory_id(name_part)
  for id, f in pairs(remote.call(D, "factories")) do
    if f.name:lower():find(name_part, 1, true) then return id end
  end
end

local steps = {}
local function step(fn) steps[#steps + 1] = fn end

step(function() shot("01-world", { gui = false, zoom = 0.18, position = { 105, 80 } }) end)
step(function() open("plan") end)
step(function() shot("02-plan-empty") end)

-- capture every production zone (screenshots of the interesting editors on the way)
local SHOW = { circuits = "03-editor-circuits", red = "04-editor-red-circuits", oil = "05-editor-oil" }
for _, key in ipairs({ "circuits", "red", "oil", "battery", "iron", "iron2", "copper", "steel", "brick", "gears", "belts",
  "engines", "mine_iron", "mine_iron2", "mine_copper", "mine_stone", "mine_coal", "pumpjacks", "pump" }) do
  step(function() capture(key) end)
  if SHOW[key] then step(function() shot(SHOW[key]) end) end
  if key == "oil" then
    step(function() act("split_slider", { mode = "factory" }, 70) end)
    step(function() shot("06-editor-oil-split-moved") end)
  end
  step(function() try_save(key) end)
end

-- boilers become a sink with their fuel
step(function() capture("boilers") end)
step(function() act("row_rate", { mode = "sink", i = 1 }, 30) end)
step(function() shot("07-sink-generators") end)
step(function() try_save("boilers") end)

-- a demand sink with several items
local DEMAND = {
  { "electronic-circuit", 600 }, { "advanced-circuit", 120 }, { "plastic-bar", 300 }, { "engine-unit", 30 },
  { "transport-belt", 240 }, { "battery", 60 }, { "steel-plate", 120 }, { "stone-brick", 90 }, { "copper-plate", 200 },
}
step(function() open("plan") end)
step(function() act("fac_new_sink") end)
for i, row in ipairs(DEMAND) do
  if i > 1 then step(function() act("row_add", { mode = "sink" }) end) end
  step(function() act("row_signal", { mode = "sink", i = i }, { type = "item", name = row[1] }) end)
  step(function() act("row_rate", { mode = "sink", i = i }, row[2]) end)
end
step(function() act("editor_name", {}, "Main bus demand") end)
step(function() shot("08-sink-demand") end)
step(function() try_save("demand") end)

step(function() open("plan") end)
step(function() act("plan_hide_ok") end)
step(function() shot("10-plan-hide-satisfied") end)
step(function() act("plan_hide_ok") end)

-- plan: what can't balance and what would close it, then fixed the way a player would
-- (the world has no mines for some inputs: those go to the plan's import, leftovers to its void)
step(function() open("plan") end)
step(function() shot("11-plan-conflicts") end)
step(function()
  note("plan sources: " .. remote.call(D, "plan_sources"))
end)
step(function() open("plan") end)
step(function() act("problem_split", { mode = "plan" }) end)
step(function() open("plan") end)
step(function() act("problem_split", { mode = "plan" }) end)
step(function() open("plan") end)
step(function()
  for _, part in ipairs({ "electronic", "plastic", "iron plate" }) do
    local id = factory_id(part)
    if id then act("plan_copies", { id = id, delta = 1 }) end
  end
end)
step(function() shot("12-plan") end)
step(function() open("splits") end)
step(function() shot("13-splits") end)

step(function() open("statistics") end)
step(function() shot("14-items") end)
step(function() act("items_toggle", { item = "item/iron-plate" }) end)
step(function() act("items_toggle", { item = "item/electronic-circuit" }) end)
step(function() shot("15-items-expanded") end)

step(function() act("open_settings") end)
step(function() shot("16-settings") end)
step(function() act("dialog_close") end)
step(function() act("open_log") end)
step(function() shot("17-log") end)
step(function() act("dialog_close") end)

-- the plan's void and import (opened from the toolbar), and a recipe factory picked by item
step(function() open("plan") end)
step(function() act("fac_boundary", { kind = "import" }) end)
step(function() shot("17a-editor-import") end)
step(function() act("editor_cancel") end)
step(function() act("fac_new_recipe") end)
step(function() act("dlg_item", {}, "iron-gear-wheel") end)
step(function()
  -- the first machine may take no modules: one that does
  local dlg = remote.call(D, "dialog", P)
  for i, name in ipairs(dlg and dlg.machines or {}) do
    if (prototypes.entity[name].module_inventory_size or 0) > 0 then return act("dlg_machine", {}, i) end
  end
end)
step(function() act("dlg_module", { slot = 1 }, "speed-module") end)
step(function() shot("17b-dialog-new-recipe") end)
step(function() act("dialog_close") end)

-- editor states: conflict, recapture, dialogs
step(function() open("plan") end)
step(function() act("fac_edit", { id = factory_id("electronic circuit") }) end)
step(function() act("editor_external", { item = "item/wood" }, false) end)
step(function() shot("18-editor-conflict") end)
step(function() act("editor_recapture") end)
step(function() shot("19-editor-recapture") end)
step(function() game.get_player(P).clear_cursor() end)
step(function() act("editor_add_recipe") end)
step(function() act("dlg_recipe", {}, "iron-gear-wheel") end)
step(function() shot("20-dialog-add-recipe") end)
step(function() act("dialog_close") end)
step(function() act("editor_add_custom") end)
step(function() shot("21-dialog-custom-line") end)
step(function() act("dialog_close") end)
step(function() act("editor_cancel") end)
step(function() open("plan") end)
step(function() act("fac_export_all") end)
step(function() shot("22-dialog-export") end)
step(function() act("dialog_close") end)
step(function() act("fac_delete", { id = factory_id("gears") }) end)
step(function() shot("23-dialog-delete") end)
step(function() act("dialog_close") end)
step(function() open("plan") end)
step(function() shot("24-plan-final") end)

-- − / + keeps the plan list where it was scrolled to: + on the last row (in view at the
-- bottom) changes it, and the list stays put
step(function() note("scrolled: " .. tostring(remote.call(D, "scroll_plan", P))) end)
step(function() shot("25-plan-scrolled") end)
step(function()
  local order = remote.call("stoich", "plan_result", game.get_player(P).surface.name).order or {}
  act("plan_copies", { id = order[#order], delta = 1 })
end)
step(function() shot("26-plan-scrolled-after-plus") end)

-- show on map from the editor: does the window close, and does the draft survive?
step(function() open("plan") end)
step(function() act("fac_edit", { id = factory_id("battery") }) end)
step(function() act("editor_show_map") end)
step(function()
  local player = game.get_player(P)
  note("after show map: window open " .. tostring(player.gui.screen.stoich_window ~= nil) .. ", draft kept " .. tostring(draft() ~= nil)
    .. ", controller " .. tostring(player.controller_type))
end)
step(function() open("plan") end)
step(function() note("reopened: editor shown " .. tostring(draft() ~= nil)) end)

step(function()
  local out = { plan = remote.call("stoich", "plan_result", game.get_player(P).surface.name), factories = remote.call(D, "factories") }
  helpers.write_file("shots/data.json", helpers.table_to_json(out))
  helpers.write_file("shots/steps.log", table.concat(log_lines, "\n"))
  helpers.write_file("shots/done.txt", "done")
end)

local GAP = 20

script.on_init(function() storage.t0 = game.tick + 60 end)

script.on_event(defines.events.on_tick, function(event)
  if not remote.interfaces["stoich-test-world"] then return end -- other worlds (rates) only want the setting
  if not storage.t0 then storage.t0 = event.tick + 60 end
  local i = (event.tick - storage.t0) / GAP + 1
  if i >= 1 and i == math.floor(i) and steps[i] then
    local ok, err = pcall(steps[i])
    if not ok then
      note("step " .. i .. " FAILED: " .. tostring(err))
      helpers.write_file("shots/steps.log", table.concat(log_lines, "\n"))
    end
  end
end)
