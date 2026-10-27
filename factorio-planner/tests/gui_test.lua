-- End-to-end scenarios: control.lua driven through the strict mock runtime.

local t = require("tests.t")
local mock = require("tests.mock_runtime")

local TOOL = "fp-selection-tool"

local function boot(opts)
  mock.reset(opts)
  require("control")
  mock.init.on_init()
  local p1 = mock.new_player(1, { admin = true })
  mock.fire("on_player_joined_game", { player_index = 1 })
  return p1
end

local function win(p) return p.gui.screen.fp_window end
local function dialog(p) return p.gui.screen.fp_dialog end

local function open(p)
  if not win(p) then mock.fire("on_lua_shortcut", { player_index = p.index, prototype_name = "fp-toggle-window" }) end
  t.truthy(win(p), "window open")
end

local function tab(p, index)
  mock.select_tab(p, mock.named(win(p), "fp_tabs"), index)
end

local function click(p, action, match, root)
  local e = mock.find(root or p.gui.screen, action, match)
  t.truthy(e, "element " .. action .. " " .. t.fmt(match or {}))
  mock.click(p, e)
  return e
end

local function oil_build()
  local list = {}
  local x = 0
  local function add(n, type, name, recipe)
    for _ = 1, n do
      list[#list + 1] = mock.crafter(type, name, recipe, x, 0)
      x = x + 1
    end
  end
  add(6, "assembling-machine", "oil-refinery", "advanced-oil-processing")
  add(2, "assembling-machine", "oil-refinery", "coal-liquefaction")
  add(3, "assembling-machine", "chemical-plant", "heavy-oil-cracking")
  add(7, "assembling-machine", "chemical-plant", "light-oil-cracking")
  add(8, "assembling-machine", "chemical-plant", "plastic-bar")
  list[#list + 1] = mock.crafter("assembling-machine", "assembling-machine-2", nil, x, 0, { idle = true })
  return list
end

local AREA = { left_top = { x = -1, y = -1 }, right_bottom = { x = 100, y = 10 } }

local function capture(p, entities)
  mock.fire("on_player_selected_area", { player_index = p.index, item = TOOL, entities = entities, area = AREA, surface = mock.surface })
end

local function draft_of(p) return storage.players[p.index].draft end

t.test("gui: window opens, tabs switch, hotkey toggles", function()
  local p = boot()
  open(p)
  t.truthy(mock.text(win(p)):find("<fp.plan-empty>", 1, true), "plan empty message")
  tab(p, 2)
  t.truthy(mock.text(win(p)):find("<fp.no-factories>", 1, true))
  tab(p, 3)
  tab(p, 1)
  mock.fire_custom("fp-toggle-window", 1)
  t.eq(win(p), nil)
  mock.fire_custom("fp-toggle-window", 1)
  t.truthy(win(p))
  -- Esc / E closes it
  mock.fire("on_gui_closed", { player_index = 1, element = win(p) })
  t.eq(win(p), nil)
end)

t.test("gui: capture an oil build, balance live, save", function()
  local p = boot()
  capture(p, oil_build())
  t.truthy(win(p), "editor opened")
  local d = draft_of(p)
  t.eq(d.factory.result.status, "EXACT")
  t.eq(#d.factory.splits, 1)
  t.truthy(mock.named(win(p), "fp_lines"), "lines table")
  t.eq(p.cursor, nil)

  -- move the split slider: counts change, the slider element survives (no rebuild)
  local slider = mock.find(win(p), "split_slider", { mode = "factory" })
  local before = {}
  for k, v in pairs(d.factory.result.counts) do before[k] = v end
  mock.slide(p, slider, 70)
  t.truthy(slider.valid, "slider not rebuilt")
  t.near(d.factory.splits[1].shares[slider.tags.line], 70)
  local changed = false
  for k, v in pairs(d.factory.result.counts) do if math.abs(v - before[k]) > 1e-9 then changed = true end end
  t.truthy(changed, "solved counts changed")
  local field = mock.named(win(p), "f_" .. slider.tags.line)
  t.eq(field.text, "70")

  -- type a share
  mock.type_text(p, field, "55")
  t.near(d.factory.splits[1].shares[slider.tags.line], 55)

  -- anchor value
  local anchor_field
  for _, e in ipairs(mock.find_all(win(p), "editor_anchor_value")) do
    if e.enabled then anchor_field = e end
  end
  t.truthy(anchor_field, "anchored line")
  mock.type_text(p, anchor_field, "4")
  t.eq(d.factory.anchors[anchor_field.tags.line], 4)

  -- untick an external -> conflict -> tick again
  local ext = mock.find(win(p), "editor_external", { item = "item/plastic-bar" })
  mock.click(p, ext)
  t.eq(d.factory.result.status, "CONFLICT")
  t.eq(mock.find(win(p), "fp_save" ) == nil, true) -- save is found by name, not action
  local save = mock.named(win(p), "fp_save")
  t.eq(save.enabled, false)
  click(p, "problem_external", { item = "item/plastic-bar" })
  t.eq(draft_of(p).factory.result.status, "EXACT")
  save = mock.named(win(p), "fp_save")
  t.eq(save.enabled, true)

  -- the localised product name arrives and fills the default name
  t.eq(#p.translations, 1)
  mock.fire("on_string_translated", { player_index = 1, id = 1, translated = true, result = "Plastic bar (localised)", localised_string = p.translations[1] })
  t.eq(d.factory.name, "Plastic bar (localised)")
  t.eq(mock.named(win(p), "fp_name").text, "Plastic bar (localised)")

  -- /fp-lines prints the lines
  mock.commands["fp-lines"]({ player_index = 1 })
  t.truthy(#p.printed > 3)

  mock.click(p, save)
  t.eq(draft_of(p), nil)
  local plan = storage.plans.main
  local n = 0
  for _ in pairs(plan.factories) do n = n + 1 end
  t.eq(n, 1)
  t.truthy(mock.text(win(p)):find("Plastic bar", 1, true), "factory listed")
  t.eq(#storage.log, 1)
end)

local function saved_oil(p)
  capture(p, oil_build())
  mock.click(p, mock.named(win(p), "fp_save"))
  for id in pairs(storage.plans.main.factories) do return id end
end

local function add_sink(p, item, per_min)
  tab(p, 2)
  click(p, "fac_new_sink")
  local sig = mock.find(win(p), "row_signal", { mode = "sink" })
  mock.pick(p, sig, { type = "item", name = item })
  local rate = mock.find(win(p), "row_rate", { mode = "sink" })
  mock.type_text(p, rate, tostring(per_min))
  mock.type_text(p, mock.find(win(p), "editor_name"), "Demand")
  t.eq(draft_of(p).factory.result.status, "EXACT")
  mock.click(p, mock.named(win(p), "fp_save"))
end

t.test("gui: sink drives the plan; conflicts fixed in one click; copies and pins", function()
  local p = boot()
  local id = saved_oil(p)
  add_sink(p, "plastic-bar", 60)
  tab(p, 1)
  local r = storage.plans.main.result
  t.eq(r.status, "CONFLICT")
  -- mark every conflicting input external from the problems list
  for _ = 1, 10 do
    local b = mock.find(win(p), "problem_external", { mode = "plan" })
    if not b then break end
    mock.click(p, b)
  end
  r = storage.plans.main.result
  t.eq(r.status, "EXACT")
  -- 8 plastic plants make 16/s per copy at the anchored count; demand 1/s
  t.truthy(r.counts[id] > 0)
  local before = r.shortage[id]
  click(p, "plan_copies", { id = id, delta = 1 })
  t.eq(storage.plans.main.factories[id].copies, 2)
  t.near(storage.plans.main.result.shortage[id], before - 1)
  local pin = mock.find(win(p), "plan_pin", { id = id })
  mock.click(p, pin)
  t.eq(storage.plans.main.factories[id].pinned, true)
  -- filter hides rows
  mock.type_text(p, mock.find(win(p), "plan_filter"), "zzz")
  t.truthy(mock.text(win(p)):find("<fp.plan-filtered>", 1, true))
  mock.type_text(p, mock.find(win(p), "plan_filter"), "")
  -- sink rate edited in place (Enter)
  local rate = mock.find(win(p), "plan_sink_rate")
  mock.type_text(p, rate, "120", true)
  local sink_rate
  for _, f in pairs(storage.plans.main.factories) do if f.kind == "sink" then sink_rate = f.sink_items[1].rate end end
  t.near(sink_rate, 2)
  -- items tab: expand plastic, open the factory from it
  tab(p, 3)
  click(p, "items_toggle", { item = "item/plastic-bar" })
  t.truthy(mock.find(win(p), "items_open"))
  click(p, "items_open")
  t.truthy(draft_of(p), "editor opened from items tab")
  click(p, "editor_cancel")
  t.eq(draft_of(p), nil)
end)

t.test("gui: plan split between two factories, slider in the plan tab", function()
  local p = boot()
  local a = saved_oil(p)
  -- duplicate gives a second design making the same items
  tab(p, 2)
  click(p, "fac_duplicate", { id = a })
  add_sink(p, "plastic-bar", 60)
  tab(p, 1)
  for _ = 1, 10 do
    local b = mock.find(win(p), "problem_external", { mode = "plan" })
    if not b then break end
    mock.click(p, b)
  end
  t.eq(storage.plans.main.result.status, "NEEDS_SPLIT")
  click(p, "problem_split", { mode = "plan" })
  t.eq(storage.plans.main.result.status, "EXACT")
  local slider = mock.find(win(p), "split_slider", { mode = "plan" })
  t.truthy(slider)
  mock.slide(p, slider, 80)
  t.truthy(slider.valid, "plan slider survives")
  t.near(storage.plans.main.splits[1].shares[slider.tags.line], 80)
  t.eq(storage.plans.main.result.status, "EXACT")
end)

t.test("gui: export and import a factory string", function()
  local p = boot()
  local id = saved_oil(p)
  tab(p, 2)
  click(p, "fac_export", { id = id })
  local text = mock.all(dialog(p))
  local box
  for _, e in ipairs(text) do if e.type == "text-box" then box = e end end
  local s = box.text
  t.truthy(#s > 10)
  click(p, "dialog_close")
  click(p, "fac_import")
  mock.type_text(p, mock.named(dialog(p), "fp_import_text"), s)
  click(p, "fac_import_ok")
  t.eq(dialog(p), nil)
  local n = 0
  for _, f in pairs(storage.plans.main.factories) do
    n = n + 1
    t.eq(f.result.status, "EXACT")
  end
  t.eq(n, 2)
  -- garbage shows an error, keeps the dialog
  click(p, "fac_import")
  mock.type_text(p, mock.named(dialog(p), "fp_import_text"), "nonsense")
  click(p, "fac_import_ok")
  t.truthy(dialog(p))
  t.truthy(mock.text(dialog(p)):find("import-error", 1, true))
end)

t.test("gui: generators-only selection opens a sink with their fuel", function()
  local p = boot()
  capture(p, { mock.boiler(1, 1, "coal"), mock.boiler(2, 1, "coal") })
  local d = draft_of(p)
  t.eq(d.factory.kind, "sink")
  t.eq(d.factory.sink_items[1].key, "item/coal")
  mock.type_text(p, mock.find(win(p), "row_rate", { mode = "sink" }), "30")
  t.near(d.factory.sink_items[1].rate, 0.5)
  mock.click(p, mock.named(win(p), "fp_save"))
  t.eq(draft_of(p), nil)
end)

t.test("gui: admins-only mode blocks edits but not viewing", function()
  local p1 = boot({ edit = "admins" })
  local id = saved_oil(p1)
  local p2 = mock.new_player(2, { admin = false })
  mock.fire("on_player_joined_game", { player_index = 2 })
  open(p2)
  t.truthy(mock.text(win(p2)):find("Plastic bar", 1, true), "viewer sees the plan")
  local plus = mock.find(win(p2), "plan_copies", { id = id, delta = 1 })
  t.eq(plus.enabled, false)
  capture(p2, oil_build())
  t.eq(draft_of(p2), nil)
  t.truthy(#p2.printed > 0)
  -- an admin switches to everyone in the settings dialog
  click(p1, "open_settings")
  mock.select(p1, mock.find(dialog(p1), "set_edit_mode"), 1)
  t.eq(settings.global["fp-edit-permission"].value, "everyone")
  plus = mock.find(win(p2), "plan_copies", { id = id, delta = 1 })
  t.eq(plus.enabled, true, "p2's window refreshed after the setting changed")
end)

t.test("gui: stale save shows the conflict dialog; overwrite and reload work", function()
  local p1 = boot()
  local id = saved_oil(p1)
  local p2 = mock.new_player(2, { admin = false })
  mock.fire("on_player_joined_game", { player_index = 2 })
  open(p2)
  tab(p1, 2)
  tab(p2, 2)
  click(p1, "fac_edit", { id = id })
  click(p2, "fac_edit", { id = id })
  mock.type_text(p2, mock.find(win(p2), "editor_name"), "by p2")
  mock.click(p2, mock.named(win(p2), "fp_save"))
  t.eq(storage.plans.main.factories[id].name, "by p2")
  -- p1's plan tab refreshed live? p1 is in the editor, so only the status refreshes; p2 saved fine.
  mock.type_text(p1, mock.find(win(p1), "editor_name"), "by p1")
  mock.click(p1, mock.named(win(p1), "fp_save"))
  t.truthy(dialog(p1), "conflict dialog")
  t.truthy(mock.text(dialog(p1)):find("player2", 1, true))
  click(p1, "conflict_reload")
  t.eq(draft_of(p1).factory.name, "by p2")
  mock.type_text(p1, mock.find(win(p1), "editor_name"), "by p1")
  mock.click(p2, mock.find(win(p2), "fac_edit", { id = id }))
  mock.type_text(p2, mock.find(win(p2), "editor_name"), "again p2")
  mock.click(p2, mock.named(win(p2), "fp_save"))
  mock.click(p1, mock.named(win(p1), "fp_save"))
  click(p1, "conflict_overwrite")
  t.eq(storage.plans.main.factories[id].name, "by p1")
end)

t.test("gui: other players' plan tab refreshes live", function()
  local p1 = boot()
  local id = saved_oil(p1)
  local p2 = mock.new_player(2, {})
  mock.fire("on_player_joined_game", { player_index = 2 })
  open(p2)
  tab(p1, 1)
  local label_before = mock.text(win(p2))
  click(p1, "plan_copies", { id = id, delta = 1 })
  t.truthy(mock.text(win(p2)) ~= label_before, "p2 sees the new copy count")
end)

t.test("gui: delete with confirmation, rescan, show on map, add recipe and custom line", function()
  local p = boot()
  local id = saved_oil(p)
  tab(p, 2)
  click(p, "fac_edit", { id = id })
  -- one more plastic plant appears, rescan picks it up
  mock.crafter("assembling-machine", "chemical-plant", "plastic-bar", 50, 0)
  click(p, "editor_rescan")
  local plastic
  for _, l in ipairs(draft_of(p).factory.lines) do if l.recipe == "plastic-bar" then plastic = l end end
  t.eq(plastic.count, 9)
  click(p, "editor_show_map")
  t.eq(p.controller.type, defines.controllers.remote)
  t.eq(#mock.drawn, 1)
  -- add recipe dialog
  click(p, "editor_add_recipe")
  mock.pick(p, mock.find(dialog(p), "dlg_recipe"), "electronic-circuit")
  mock.select(p, mock.find(dialog(p), "dlg_machine"), 1)
  mock.type_text(p, mock.find(dialog(p), "dlg_num", { field = "count" }), "2")
  click(p, "dlg_recipe_ok")
  local circuit
  for _, l in ipairs(draft_of(p).factory.lines) do if l.recipe == "electronic-circuit" then circuit = l end end
  t.truthy(circuit, "manual recipe line")
  t.near(circuit.flow["item/electronic-circuit"], 0.75 / 0.5)
  -- custom line dialog with a custom key marked fluid
  click(p, "editor_add_custom")
  mock.type_text(p, mock.find(dialog(p), "dlg_label"), "import")
  mock.type_text(p, mock.find(dialog(p), "row_text", { mode = "dialog" }), "space data", true)
  mock.type_text(p, mock.find(dialog(p), "row_rate", { mode = "dialog" }), "60")
  click(p, "row_fluid", { mode = "dialog" })
  click(p, "dlg_line_ok")
  local custom
  for _, l in ipairs(draft_of(p).factory.lines) do if l.label == "import" then custom = l end end
  t.truthy(custom)
  t.near(custom.flow["custom/space data"], 1)
  t.truthy(custom.fluid_keys["custom/space data"])
  -- override the flow of a scanned line
  click(p, "editor_edit_flow", { line = plastic.id })
  mock.type_text(p, mock.find_all(dialog(p), "row_rate")[1], "1")
  click(p, "dlg_line_ok")
  t.truthy(plastic.overridden)
  click(p, "editor_cancel")
  -- delete with confirmation
  click(p, "fac_delete", { id = id })
  t.truthy(dialog(p))
  click(p, "fac_delete_ok", { id = id })
  t.eq(storage.plans.main.factories[id], nil)
end)

t.test("gui: removed mod marks factories invalid and the GUI still builds", function()
  local p = boot()
  local id = saved_oil(p)
  open(p)
  prototypes.recipe["coal-liquefaction"] = nil
  mock.init.on_configuration_changed({})
  t.truthy(storage.plans.main.factories[id].invalid)
  t.eq(storage.plans.main.factories[id].result.status, "INVALID")
  t.truthy(win(p), "window rebuilt")
  tab(p, 1)
  tab(p, 2)
  tab(p, 3)
  t.truthy(#game.printed > 0)
end)

-- Fuzz: fire the natural event on every interactive element, re-reading the
-- GUI after each one (actions rebuild it), including dialogs.
local SKIP = { window_close = true, tab_changed = true }

local function act(p, e)
  local kind = e.type
  if kind == "button" or kind == "sprite-button" or kind == "checkbox" then
    mock.click(p, e)
  elseif kind == "textfield" or kind == "text-box" then
    mock.type_text(p, e, "1", true)
  elseif kind == "slider" then
    mock.slide(p, e, 33)
  elseif kind == "drop-down" then
    if #e.items > 0 then mock.select(p, e, #e.items) end
  elseif kind == "choose-elem-button" then
    mock.pick(p, e, e.elem_type == "recipe" and "copper-cable" or { type = "item", name = "iron-plate" })
  elseif kind == "tabbed-pane" then
    mock.select_tab(p, e, 3)
  end
end

local function poke_all(p, limit)
  local count, i = 0, 1
  while count < (limit or 300) do
    local list = {}
    for _, e in ipairs(mock.all(p.gui.screen)) do
      if e.tags.fp and e.enabled and not SKIP[e.tags.fp] then list[#list + 1] = e end
    end
    if i > #list then break end
    act(p, list[i])
    count = count + 1
    i = i + 1
    if not win(p) then open(p) end
  end
  return count
end

t.test("gui: fuzz every control on every screen", function()
  local p = boot()
  saved_oil(p)
  add_sink(p, "plastic-bar", 60)
  local total = 0
  for tab_index = 1, 3 do
    open(p)
    tab(p, tab_index)
    total = total + poke_all(p)
  end
  -- the factory editor after a capture, then the sink editor
  capture(p, oil_build())
  total = total + poke_all(p)
  tab(p, 2)
  if storage.players[1].draft then click(p, "editor_cancel") end
  click(p, "fac_new_sink")
  total = total + poke_all(p)
  t.truthy(total > 150, "poked " .. total .. " controls")
end)

t.test("gui: remaining controls", function()
  local p = boot()
  local id = saved_oil(p)
  tab(p, 2)
  click(p, "fac_capture")
  t.eq(p.cursor, TOOL)
  click(p, "fac_export_all")
  t.truthy(dialog(p))
  click(p, "dialog_close")
  click(p, "show_map", { id = id })
  t.eq(p.controller.type, defines.controllers.remote)
  click(p, "fac_new")
  local d = draft_of(p)
  t.eq(d.factory.kind, "factory")
  mock.type_text(p, mock.find(win(p), "editor_copies"), "3")
  t.eq(d.factory.copies, 3)
  click(p, "editor_pinned")
  t.eq(d.factory.pinned, true)
  click(p, "editor_add_custom")
  click(p, "row_add", { mode = "dialog" })
  t.eq(#storage.players[1].dialog.rows, 2)
  mock.pick(p, mock.find(dialog(p), "row_signal", { mode = "dialog", i = 1 }), { type = "item", name = "iron-plate" })
  mock.type_text(p, mock.find(dialog(p), "row_rate", { mode = "dialog", i = 1 }), "60")
  click(p, "dlg_line_ok")
  local count = mock.find(win(p), "editor_line_count")
  mock.type_text(p, count, "2")
  t.eq(d.factory.lines[1].count, 2)
  click(p, "editor_cancel")
  -- split dropdown and removal on a captured oil build
  capture(p, oil_build())
  d = draft_of(p)
  local dd = mock.find(win(p), "split_item", { mode = "factory" })
  t.truthy(dd, "split item dropdown")
  local before = d.factory.splits[1].item
  local target = 1
  if dd.tags.cands[1] == before then target = 2 end
  mock.select(p, dd, target)
  t.truthy(d.factory.splits[1].item ~= before, "split item switched")
  t.eq(d.factory.result.status, "EXACT")
  click(p, "split_remove", { mode = "factory" })
  t.eq(#d.factory.splits, 0)
  t.eq(d.factory.result.status, "NEEDS_SPLIT")
  click(p, "problem_split", { mode = "factory" })
  t.eq(d.factory.result.status, "EXACT")
  click(p, "editor_cancel")
  -- settings: belt tier and one lane
  click(p, "open_settings")
  mock.select(p, mock.find(dialog(p), "set_max_belt"), 2)
  t.eq(settings.global["fp-max-belt"].value, "transport-belt")
  click(p, "set_one_lane")
  t.eq(settings.global["fp-one-lane"].value, true)
  click(p, "dialog_close")
  -- items tab collapse
  tab(p, 3)
  click(p, "items_collapse")
  click(p, "window_close")
  t.eq(win(p), nil)
end)

t.test("gui: idle machines get a recipe; add sink fixes surpluses", function()
  local p = boot()
  capture(p, oil_build())
  local d = draft_of(p)
  local idle
  for _, l in ipairs(d.factory.lines) do if l.idle then idle = l end end
  t.truthy(idle, "idle line from the empty assembler")
  -- an assembler can't make plastic: rejected, the line stays idle
  mock.pick(p, mock.find(win(p), "editor_assign_recipe", { line = idle.id }), "plastic-bar")
  t.eq(idle.idle, true)
  t.truthy(#p.printed > 0)
  -- research productivity of the recipe is applied
  mock.force.recipes["copper-cable"].productivity_bonus = 0.1
  mock.pick(p, mock.find(win(p), "editor_assign_recipe", { line = idle.id }), "copper-cable")
  t.eq(idle.recipe, "copper-cable")
  t.eq(idle.idle, nil)
  t.near(idle.flow["item/copper-cable"], 2 * 0.75 / 0.5 * 1.1)
  click(p, "editor_delete_line", { line = idle.id })
  -- factory mode: a byproduct nobody consumes gets a void line
  mock.click(p, mock.find(win(p), "editor_external", { item = "item/plastic-bar" }))
  t.eq(d.factory.result.status, "CONFLICT")
  click(p, "problem_sink", { mode = "factory", item = "item/plastic-bar" })
  t.eq(draft_of(p).factory.result.status, "EXACT")
  local void
  for _, l in ipairs(draft_of(p).factory.lines) do if l.label == "void plastic-bar" then void = l end end
  t.truthy(void, "void line added")
  click(p, "editor_delete_line", { line = void.id })
  mock.click(p, mock.find(win(p), "editor_external", { item = "item/plastic-bar" }))
  t.eq(draft_of(p).factory.result.status, "EXACT")
  mock.click(p, mock.named(win(p), "fp_save"))
  -- plan mode: a pinned factory's surplus offers a sink for it
  local id
  for fid in pairs(storage.plans.main.factories) do id = fid end
  tab(p, 1)
  click(p, "plan_pin", { id = id })
  for _ = 1, 10 do
    local b = mock.find(win(p), "problem_external", { mode = "plan" })
    if not b or b.tags.item == "item/plastic-bar" then break end
    mock.click(p, b)
  end
  t.eq(mock.find(win(p), "problem_sink", { mode = "plan", item = "fluid/crude-oil" }), nil, "no sink offered for a missing input")
  click(p, "problem_sink", { mode = "plan", item = "item/plastic-bar" })
  t.eq(draft_of(p).factory.kind, "sink")
  t.eq(draft_of(p).factory.sink_items[1].key, "item/plastic-bar")
end)

t.test("gui: discard question for unsaved captures and edits", function()
  local p = boot()
  local id = saved_oil(p)
  capture(p, oil_build()) -- a new capture counts as unsaved work
  local captured = draft_of(p)
  tab(p, 1)
  click(p, "fac_edit", { id = id })
  t.truthy(dialog(p), "discard question")
  t.truthy(draft_of(p) == captured, "capture kept while asking")
  click(p, "discard_keep")
  t.eq(dialog(p), nil)
  t.truthy(draft_of(p) == captured)
  t.eq(storage.players[1].tab, "factories")
  -- capturing again over the unsaved capture also asks
  capture(p, oil_build())
  t.truthy(dialog(p))
  click(p, "discard_ok")
  t.truthy(draft_of(p) ~= captured, "new capture opened after discarding")
  t.eq(#p.translations, 3, "default-name translation requested for each capture")
  click(p, "editor_cancel")
  -- editing a saved factory: unchanged opens other things freely, changed asks
  tab(p, 2)
  click(p, "fac_edit", { id = id })
  tab(p, 1)
  click(p, "fac_edit", { id = id }) -- same factory: just shows it
  t.eq(dialog(p), nil)
  mock.type_text(p, mock.find(win(p), "editor_name"), "changed")
  tab(p, 1)
  click(p, "plan_pin", { id = id }) -- pinned: its plastic is a surplus the plan offers a sink for
  tab(p, 3)
  click(p, "items_toggle", { item = "item/plastic-bar" })
  click(p, "items_open")
  t.eq(dialog(p), nil, "same factory again, no question")
  tab(p, 1)
  click(p, "problem_sink", { mode = "plan", item = "item/plastic-bar" })
  t.truthy(dialog(p), "asks before opening a new sink over a changed draft")
  t.eq(draft_of(p).factory.name, "changed")
  click(p, "discard_ok")
  t.eq(draft_of(p).factory.kind, "sink")
end)

t.test("gui: an invalid factory is repaired by deleting its broken line", function()
  local p = boot()
  local id = saved_oil(p)
  prototypes.recipe["coal-liquefaction"] = nil
  mock.init.on_configuration_changed({})
  t.eq(storage.plans.main.factories[id].result.status, "INVALID")
  tab(p, 2)
  click(p, "fac_edit", { id = id })
  local d = draft_of(p)
  t.eq(d.factory.result.status, "INVALID")
  local broken
  for _, l in ipairs(d.factory.lines) do if l.invalid then broken = l end end
  t.truthy(broken and broken.recipe == "coal-liquefaction")
  click(p, "editor_delete_line", { line = broken.id })
  t.eq(d.factory.invalid, nil)
  t.truthy(d.factory.result.status ~= "INVALID", "status " .. d.factory.result.status)
  -- the split on heavy oil lost a line; whatever is left to choose, choose it and save
  for _ = 1, 3 do
    if d.factory.result.status == "EXACT" then break end
    click(p, "problem_split", { mode = "factory" })
  end
  t.eq(d.factory.result.status, "EXACT")
  mock.click(p, mock.named(win(p), "fp_save"))
  t.eq(storage.plans.main.factories[id].invalid, nil)
  t.eq(storage.plans.main.factories[id].result.status, "EXACT")
end)

t.test("gui: split prompt offers every useful item in a dropdown", function()
  local p = boot()
  capture(p, oil_build())
  click(p, "split_remove", { mode = "factory" })
  local d = draft_of(p)
  t.eq(d.factory.result.status, "NEEDS_SPLIT")
  local cand = mock.named(win(p), "fp_cand")
  t.truthy(cand, "candidate dropdown")
  local cands = mock.find(win(p), "problem_split", { mode = "factory" }).tags.cands
  t.truthy(#cands > 1)
  mock.select(p, cand, #cands)
  mock.click(p, mock.find(win(p), "problem_split", { mode = "factory" }))
  t.eq(d.factory.splits[1].item, cands[#cands])
end)

t.test("gui: picker maps recipes to products; fluid flag only for custom names", function()
  local p = boot()
  open(p)
  tab(p, 2)
  click(p, "fac_new_sink")
  t.eq(mock.find(win(p), "row_fluid", { mode = "sink" }), nil, "no fluid flag for an empty row")
  -- picking a recipe (as the signal picker allows) stores what it makes
  mock.pick(p, mock.find(win(p), "row_signal", { mode = "sink", i = 1 }), { type = "recipe", name = "plastic-bar" })
  t.eq(draft_of(p).factory.sink_items[1].key, "item/plastic-bar")
  t.eq(mock.find(win(p), "row_fluid", { mode = "sink" }), nil, "no fluid flag for a real item")
  click(p, "row_add", { mode = "sink" })
  mock.type_text(p, mock.find(win(p), "row_text", { mode = "sink", i = 2 }), "space data", true)
  t.truthy(mock.find(win(p), "row_fluid", { mode = "sink", i = 2 }), "fluid flag for the custom name")
  t.eq(mock.find(win(p), "row_fluid", { mode = "sink", i = 1 }), nil)
end)

t.test("gui: editor groups items; shortage never shows below 0", function()
  local p = boot()
  capture(p, oil_build())
  local text = mock.text(win(p))
  t.truthy(text:find("<fp.items-inputs>", 1, true) and text:find("<fp.items-outputs>", 1, true) and text:find("<fp.items-inside>", 1, true))
  mock.click(p, mock.named(win(p), "fp_save"))
  local id
  for fid in pairs(storage.plans.main.factories) do id = fid end
  add_sink(p, "plastic-bar", 60)
  tab(p, 1)
  for _ = 1, 10 do
    local b = mock.find(win(p), "problem_external", { mode = "plan" })
    if not b then break end
    mock.click(p, b)
  end
  local r = storage.plans.main.result
  t.eq(r.status, "EXACT")
  t.truthy(r.shortage[id] < 0, "overbuilt in this plan")
  -- the shortage cell reads 0, green, with the surplus in its tooltip
  local found = false
  for _, e in ipairs(mock.all(win(p))) do
    local tip = e.type == "label" and e.tooltip
    if type(tip) == "table" and tip[1] == "fp.surplus-tooltip" then
      found = true
      t.eq(e.caption, "0")
      t.eq(e.style.font_color, require("scripts.gui.common").GREEN)
    end
  end
  t.truthy(found, "surplus shown in a tooltip")
end)

t.test("gui: belt display is a plain number, the slowest belt and how full it is", function()
  local p = boot()
  local common = require("scripts.gui.common")
  local ctx = common.ctx(p) -- mock: express belts not researched, so fast is the highest allowed
  local d = common.rate_display(ctx, 10, "item/iron-plate")
  t.eq(d.color, nil, "number not tinted")
  t.truthy(d.caption:find("[entity=transport-belt]", 1, true))
  t.truthy(d.caption:find("67%", 1, true), d.caption)
  t.eq(d.tooltip[1], "fp.belt-tooltip")
  local over = common.rate_display(ctx, 40, "item/iron-plate")
  t.eq(over.exceeds, true)
  t.eq(over.color, common.RED)
  t.truthy(over.caption:find("1.33×[entity=fast-transport-belt]", 1, true), over.caption)
  local fluid = common.rate_display(ctx, 400, "fluid/water")
  t.eq(fluid.color, nil)
  t.eq(fluid.exceeds, nil)
end)

t.test("gui: every handler is reached by some scenario", function()
  local f = assert(io.open(TEST_ROOT .. "/scripts/gui/common.lua"))
  f:close()
  local missing = {}
  for _, file in ipairs({ "common", "window", "splits", "problems", "rows", "editor", "factories", "plan", "items" }) do
    local h = assert(io.open(TEST_ROOT .. "/scripts/gui/" .. file .. ".lua"))
    local src = h:read("*a")
    h:close()
    for name in src:gmatch("\nhandlers%.([%w_]+) =") do
      if not mock.hits[name] then missing[#missing + 1] = name end
    end
    for name in src:gmatch("common%.handlers%.([%w_]+) =") do
      if not mock.hits[name] then missing[#missing + 1] = name end
    end
  end
  table.sort(missing)
  t.eq(table.concat(missing, ", "), "", "handlers never fired")
end)
