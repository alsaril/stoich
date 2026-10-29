-- End-to-end scenarios: control.lua driven through the strict mock runtime.

local t = require("tests.t")
local mock = require("tests.mock_runtime")

local TOOL = "stoich-selection-tool"

local function boot(opts)
  mock.reset(opts)
  require("control")
  mock.init.on_init()
  local p1 = mock.new_player(1, { admin = true })
  mock.fire("on_player_joined_game", { player_index = 1 })
  return p1
end

local function win(p) return p.gui.screen.stoich_window end
local function dialog(p) return p.gui.screen.stoich_dialog end

local function open(p)
  if not win(p) then mock.fire("on_lua_shortcut", { player_index = p.index, prototype_name = "stoich-toggle-window" }) end
  t.truthy(win(p), "window open")
end

local function scr(p) return p.gui.screen end
local function editor_win(p) return p.gui.screen.stoich_editor end
local function stats_win(p) return p.gui.screen.stoich_stats end
local function split_win(p) return p.gui.screen.stoich_split end

-- Show a window: "plan" (the main window), "stats" (statistics), "split" (the first plan split).
local function go(p, what)
  open(p)
  if what == "stats" then
    mock.click(p, mock.find(scr(p), "open_stats"))
  elseif what == "split" then
    mock.click(p, mock.find(scr(p), "plan_split_edit"))
  end
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

t.test("gui: window opens, statistics opens over it, hotkey toggles", function()
  local p = boot()
  open(p)
  t.truthy(mock.text(scr(p)):find("<stoich.empty-title>", 1, true), "empty plan guide")
  t.eq(mock.find(win(p), "open_stats").enabled, false, "nothing to show yet")
  capture(p, oil_build())
  mock.click(p, mock.named(scr(p), "stoich_save"))
  -- a child window takes the plan's place; Esc / E closes it and the plan comes back
  go(p, "stats")
  t.truthy(stats_win(p))
  t.eq(win(p).visible, false, "the plan hides under it")
  mock.press_esc(p)
  t.eq(stats_win(p), nil)
  t.eq(win(p).visible, true, "and comes back")
  t.truthy(p.opened == win(p))
  mock.fire_custom("stoich-toggle-window", 1)
  t.eq(win(p), nil)
  mock.fire_custom("stoich-toggle-window", 1)
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
  t.truthy(mock.named(scr(p), "stoich_lines"), "lines table")
  t.eq(p.cursor, nil)

  -- move the split slider: counts change, the slider element survives (no rebuild)
  local slider = mock.find(scr(p), "split_slider", { mode = "factory" })
  local before = {}
  for k, v in pairs(d.factory.result.counts) do before[k] = v end
  mock.slide(p, slider, 70)
  t.truthy(slider.valid, "slider not rebuilt")
  t.near(d.factory.splits[1].shares[slider.tags.line], 70)
  local changed = false
  for k, v in pairs(d.factory.result.counts) do if math.abs(v - before[k]) > 1e-9 then changed = true end end
  t.truthy(changed, "solved counts changed")
  local field = mock.named(scr(p), "f_" .. slider.tags.line)
  t.eq(field.text, "70")

  -- type a share
  mock.type_text(p, field, "55")
  t.near(d.factory.splits[1].shares[slider.tags.line], 55)

  -- anchor a line and let it go again
  local free
  for _, e in ipairs(mock.find_all(scr(p), "editor_anchor")) do
    if not e.state then free = e end
  end
  local free_line = free.tags.line
  mock.click(p, free)
  t.truthy(d.factory.anchors[free_line] ~= nil, "anchored")
  mock.click(p, mock.find(scr(p), "editor_anchor", { line = free_line }))
  t.eq(d.factory.anchors[free_line], nil, "free again")

  -- anchor value
  local anchor_field
  for _, e in ipairs(mock.find_all(scr(p), "editor_anchor_value")) do
    if e.enabled then anchor_field = e end
  end
  t.truthy(anchor_field, "anchored line")
  mock.type_text(p, anchor_field, "4")
  t.eq(d.factory.anchors[anchor_field.tags.line], 4)

  -- untick an external -> conflict -> tick again
  local ext = mock.find(scr(p), "editor_external", { item = "item/plastic-bar" })
  mock.click(p, ext)
  t.eq(d.factory.result.status, "CONFLICT")
  t.eq(mock.find(scr(p), "stoich_save" ) == nil, true) -- save is found by name, not action
  local save = mock.named(scr(p), "stoich_save")
  t.eq(save.enabled, false)
  -- the reason is on its own line above the buttons, only while there is one
  t.eq(mock.named(scr(p), "stoich_save_note").visible, true)
  t.eq(mock.named(scr(p), "stoich_save_reason").caption[1], "stoich.save-not-exact")
  click(p, "problem_external", { item = "item/plastic-bar" })
  t.eq(draft_of(p).factory.result.status, "EXACT")
  save = mock.named(scr(p), "stoich_save")
  t.eq(save.enabled, true)
  t.eq(mock.named(scr(p), "stoich_save_note").visible, false)

  -- the localised product name arrives and fills the default name
  t.eq(#p.translations, 1)
  mock.fire("on_string_translated", { player_index = 1, id = 1, translated = true, result = "Plastic bar (localised)", localised_string = p.translations[1] })
  t.eq(d.factory.name, "Plastic bar (localised)")
  t.eq(mock.named(scr(p), "stoich_name").text, "Plastic bar (localised)")

  -- /stoich-lines prints the lines
  mock.commands["stoich-lines"]({ player_index = 1 })
  t.truthy(#p.printed > 3)

  mock.click(p, save)
  t.eq(draft_of(p), nil)
  local plan = storage.plans.main
  local n = 0
  for _ in pairs(plan.factories) do n = n + 1 end
  t.eq(n, 1)
  t.truthy(mock.text(scr(p)):find("Plastic bar", 1, true), "factory listed")
  t.eq(#storage.log, 1)
end)

local function saved_oil(p)
  capture(p, oil_build())
  mock.click(p, mock.named(scr(p), "stoich_save"))
  for id in pairs(storage.plans.main.factories) do return id end
end

-- A factory with one custom line, saved straight into the plan (what capturing a mine,
-- a pump or a void would give).
local function custom_factory(name, net)
  local model, plan = require("scripts.model"), require("scripts.plan")
  local f = model.new_factory("factory")
  local line = model.add_line(f, { kind = "custom", label = name, count = 1, flow = net })
  f.name = name
  f.anchors[line.id] = 1
  f.external = plan.flow_items(net)
  plan.balance_factory(f)
  local _, saved = model.save_factory(f, {}, 1)
  require("scripts.gui.window").plan_changed()
  return saved
end

-- The plan is closed: what nothing in these small test plans makes (crude oil, coal...)
-- gets a source factory, what nothing uses a void, as a player would capture a pump.
local function close_plan()
  local plan = require("scripts.plan")
  for _ = 1, 10 do
    local made, used, missing = {}, {}, {}
    for _, u in ipairs(plan.units()) do
      for k, v in pairs(u.flow) do
        if v > 0 then made[k] = true else used[k] = true end
      end
    end
    for _, problem in ipairs(storage.plans.main.result.problems) do
      if problem.type == "conflict" then
        for _, key in ipairs(problem.items) do missing[#missing + 1] = key end
      end
    end
    if #missing == 0 then return end
    table.sort(missing)
    for _, key in ipairs(missing) do
      if not made[key] then custom_factory(key .. " source", { [key] = 1 })
      elseif not used[key] then custom_factory(key .. " void", { [key] = -1 }) end
    end
  end
end

local function add_sink(p, item, per_min)
  go(p, "plan")
  click(p, "fac_new_sink")
  local sig = mock.find(scr(p), "row_signal", { mode = "sink" })
  mock.pick(p, sig, { type = "item", name = item })
  local rate = mock.find(scr(p), "row_rate", { mode = "sink" })
  mock.type_text(p, rate, tostring(per_min))
  mock.type_text(p, mock.find(scr(p), "editor_name"), "Demand")
  t.eq(draft_of(p).factory.result.status, "EXACT")
  mock.click(p, mock.named(scr(p), "stoich_save"))
end

t.test("gui: sink drives the plan; conflicts fixed in one click; copies and pins", function()
  local p = boot()
  local id = saved_oil(p)
  add_sink(p, "plastic-bar", 60)
  go(p, "plan")
  local r = storage.plans.main.result
  t.eq(r.status, "CONFLICT")
  -- an item in a plan problem opens the statistics window on it
  local item = mock.find(win(p), "problem_item", { mode = "plan" }).tags.item
  click(p, "problem_item", { mode = "plan", item = item })
  t.truthy(stats_win(p), "statistics window")
  t.eq(storage.players[1].expanded[item], true)
  t.truthy(p.opened == stats_win(p), "Esc / E goes to the statistics window")
  click(p, "child_close", nil, stats_win(p))
  t.eq(stats_win(p), nil)
  t.truthy(p.opened == win(p), "and back to the main window")
  -- the plan has no "comes from outside" button; these test plans lack the mines and pumps
  t.eq(mock.find(win(p), "problem_external", { mode = "plan" }), nil, "no external buttons in the plan")
  close_plan()
  r = storage.plans.main.result
  t.eq(r.status, "EXACT")
  -- 8 plastic plants make 16/s per copy at the anchored count; demand 1/s
  t.truthy(r.counts[id] > 0)
  local before = r.shortage[id]
  click(p, "plan_copies", { id = id, delta = 1 })
  t.eq(storage.plans.main.factories[id].copies, 2)
  t.near(storage.plans.main.result.shortage[id], before - 1)
  -- with no copies built the whole need is short, shown with one decimal
  click(p, "plan_copies", { id = id, delta = -1 })
  click(p, "plan_copies", { id = id, delta = -1 })
  t.eq(storage.plans.main.factories[id].copies, 0)
  t.near(storage.plans.main.result.shortage[id], 0.0625)
  local shown = false
  for _, e in ipairs(mock.all(scr(p))) do
    if e.type == "label" and e.caption == "+0.1" then shown = true end
  end
  t.truthy(shown, "shortage 0.0625 shows as +0.1, not +1")
  click(p, "plan_copies", { id = id, delta = 1 })
  -- filter hides rows
  mock.type_text(p, mock.find(scr(p), "plan_filter"), "zzz")
  t.truthy(mock.text(scr(p)):find("<stoich.plan-filtered>", 1, true))
  mock.type_text(p, mock.find(scr(p), "plan_filter"), "")
  -- items tab: expand plastic, open the factory from it
  go(p, "stats")
  click(p, "items_toggle", { item = "item/plastic-bar" })
  t.truthy(mock.find(scr(p), "items_open"))
  click(p, "items_open")
  t.truthy(draft_of(p), "editor opened from items tab")
  click(p, "editor_cancel")
  t.eq(draft_of(p), nil)
end)

t.test("gui: rows keep their place while the window is open; sorted again when it reopens", function()
  local p = boot()
  open(p)
  local a = custom_factory("a plates", { ["item/iron-plate"] = 1 })
  local b = custom_factory("b gears", { ["item/iron-plate"] = -1, ["item/iron-gear-wheel"] = 1 })
  add_sink(p, "iron-gear-wheel", 120) -- 2/s: 2 copies of each
  click(p, "plan_copies", { id = b.id, delta = 1 }) -- b: 2 short -> 1 short, a stays 2 short
  local function order()
    local out = {}
    for _, e in ipairs(mock.find_all(win(p), "fac_edit")) do
      if e.tags.id == a.id or e.tags.id == b.id then out[#out + 1] = e.tags.id end
    end
    return out
  end
  local first = order()
  click(p, "plan_copies", { id = first[1], delta = 1 })
  click(p, "plan_copies", { id = first[1], delta = 1 })
  click(p, "plan_copies", { id = first[1], delta = 1 })
  local now = order()
  t.eq(now[1], first[1], "the clicked row stays where it was")
  click(p, "window_close")
  open(p)
  t.eq(order()[1], first[2], "reopened: the one still short comes first")
end)

t.test("gui: a long problem list shows its first rows; split prompts come first", function()
  local p = boot()
  open(p)
  -- six products, each from an input nothing makes; gears from two designs (a split)
  local sink = require("scripts.draft").new_sink()
  for i = 1, 6 do
    custom_factory("maker " .. i, { ["custom/input " .. i] = -1, ["custom/product " .. i] = 1 })
    sink.sink_items[i] = { key = "custom/product " .. i, rate = 1 }
  end
  custom_factory("gears A", { ["item/iron-gear-wheel"] = 1 })
  custom_factory("gears B", { ["item/iron-gear-wheel"] = 2 })
  sink.sink_items[7] = { key = "item/iron-gear-wheel", rate = 1 }
  require("scripts.plan").balance_factory(sink)
  require("scripts.model").save_factory(sink, {}, 1)
  require("scripts.gui.window").plan_changed()
  local list = mock.named(win(p), "stoich_problems")
  local first = list.children[1]
  t.eq(first.children[#first.children].tags.fp, "problem_split", "the split prompt first")
  t.eq(#list.children, 4 + 1, "four rows and the toggle")
  click(p, "plan_all_problems")
  t.truthy(#mock.named(win(p), "stoich_problems").children > 5, "all of them")
  click(p, "plan_all_problems")
  t.eq(#mock.named(win(p), "stoich_problems").children, 5, "back to four")
end)

t.test("gui: plan split between two factories, slider in its window", function()
  local p = boot()
  saved_oil(p)
  saved_oil(p) -- a second design making the same items
  add_sink(p, "plastic-bar", 60)
  go(p, "plan")
  close_plan()
  t.eq(storage.plans.main.result.status, "NEEDS_SPLIT")
  click(p, "problem_split", { mode = "plan" })
  t.eq(storage.plans.main.result.status, "EXACT")
  local slider = mock.find(scr(p), "split_slider", { mode = "plan" })
  t.truthy(slider)
  mock.slide(p, slider, 80)
  t.truthy(slider.valid, "plan slider survives")
  t.near(storage.plans.main.splits[1].shares[slider.tags.line], 80)
  t.eq(storage.plans.main.result.status, "EXACT")
end)

t.test("gui: export and import a factory string", function()
  local p = boot()
  saved_oil(p)
  go(p, "plan")
  t.eq(mock.text(scr(p)):find("<stoich.col-status>", 1, true), nil, "no status column")
  click(p, "fac_export_all")
  local text = mock.all(dialog(p))
  local box
  for _, e in ipairs(text) do if e.type == "text-box" then box = e end end
  local s = box.text
  t.truthy(#s > 10)
  click(p, "dialog_close")
  click(p, "fac_import")
  mock.type_text(p, mock.named(dialog(p), "stoich_import_text"), s)
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
  mock.type_text(p, mock.named(dialog(p), "stoich_import_text"), "nonsense")
  click(p, "fac_import_ok")
  t.truthy(dialog(p))
  t.truthy(mock.text(dialog(p)):find("import-error", 1, true))
end)

t.test("gui: a hand-edited import is cleaned before anything is saved; every factory opens", function()
  local p = boot()
  open(p)
  local data = { fp = 1, kind = "factories", factories = {
    { kind = "sink", name = 5, icon = { type = "bogus", name = "x" },
      sink_items = { { key = 5 }, { key = "item/coal", rate = "x" }, "junk", { key = "item/plastic-bar", rate = 1, signal = { type = "item", name = "plastic-bar" } } } },
    { name = "dup ids", icon = { type = "item", name = "no-such-item" },
      lines = { { id = 1, kind = "weird", flow = { ["item/iron-plate"] = 1, ["item/x"] = "a" } }, { id = 1, flow = { ["item/iron-gear-wheel"] = -1 } }, { id = "q", flow = {} } },
      anchors = { { 1, 1 }, { "z", 2 }, { 99, 1 } },
      splits = { { item = 7, shares = {} }, { item = "item/iron-plate", shares = { { 1, "x" } } } },
      external = { 5, "item/iron-gear-wheel" } },
  } }
  click(p, "fac_import")
  mock.type_text(p, mock.named(dialog(p), "stoich_import_text"), require("scripts.exchange").encode(data))
  click(p, "fac_import_ok")
  t.eq(dialog(p), nil, "imported")
  local sink, f
  for _, x in pairs(storage.plans.main.factories) do
    if x.kind == "sink" then sink = x else f = x end
  end
  t.eq(sink.name, "Imported")
  t.eq(sink.icon, nil, "unknown icon type dropped")
  t.eq(#sink.sink_items, 2, "rows without a valid key dropped")
  t.eq(sink.sink_items[1].rate, 0)
  t.eq(sink.sink_items[2].signal, nil, "no editing state")
  t.eq(f.icon, nil, "icon of a missing item dropped")
  t.eq(#f.lines, 3)
  t.eq(f.lines[1].id ~= f.lines[2].id and f.lines[2].id ~= f.lines[3].id and f.lines[1].id ~= f.lines[3].id, true, "unique line ids")
  t.eq(f.lines[1].kind, "custom")
  t.eq(f.lines[1].flow["item/x"], nil, "non-numeric flow dropped")
  t.eq(#f.splits, 1, "split on a non-key item dropped")
  t.eq(next(f.splits[1].shares), nil)
  t.eq(f.external["item/iron-gear-wheel"], true)
  -- everything opens in the editor
  for _, id in ipairs(require("scripts.model").factory_ids()) do
    click(p, "fac_edit", { id = id })
    t.truthy(editor_win(p), "opens")
    click(p, "editor_cancel")
  end
end)

t.test("gui: a saved sink opens unchanged; it stores and exports only items and rates", function()
  local p = boot()
  add_sink(p, "plastic-bar", 60)
  local id
  for fid, x in pairs(storage.plans.main.factories) do if x.kind == "sink" then id = fid end end
  for k in pairs(storage.plans.main.factories[id].sink_items[1]) do
    t.truthy(k == "key" or k == "rate" or k == "fluid", "stored row field " .. k)
  end
  click(p, "fac_edit", { id = id })
  t.eq(require("scripts.draft").is_dirty(draft_of(p)), false)
  click(p, "child_close", nil, editor_win(p))
  t.eq(dialog(p), nil, "no question for an unchanged sink")
  t.eq(editor_win(p), nil)
  click(p, "fac_export_all")
  local box
  for _, e in ipairs(mock.all(dialog(p))) do if e.type == "text-box" then box = e end end
  local exported = require("scripts.exchange").decode(box.text)
  for k in pairs(exported.factories[1].sink_items[1]) do
    t.truthy(k == "key" or k == "rate" or k == "fluid", "exported row field " .. k)
  end
end)

t.test("gui: changing the rate unit rebuilds the open editor", function()
  local p = boot()
  open(p)
  click(p, "fac_new_sink")
  mock.pick(p, mock.find(editor_win(p), "row_signal", { mode = "sink", i = 1 }), { type = "item", name = "coal" })
  mock.type_text(p, mock.find(editor_win(p), "row_rate", { mode = "sink", i = 1 }), "60") -- /min
  t.near(draft_of(p).factory.sink_items[1].rate, 1)
  p.mod_settings["stoich-rate-unit"] = { value = "s" }
  t.eq(mock.find(editor_win(p), "row_rate", { mode = "sink", i = 1 }).text, "1", "shown in the new unit")
  mock.type_text(p, mock.find(editor_win(p), "row_rate", { mode = "sink", i = 1 }), "2")
  t.near(draft_of(p).factory.sink_items[1].rate, 2, 1e-9, "typed in the new unit")
end)

t.test("gui: generators-only selection opens a sink with their fuel", function()
  local p = boot()
  capture(p, { mock.boiler(1, 1, "coal"), mock.boiler(2, 1, "coal") })
  local d = draft_of(p)
  t.eq(d.factory.kind, "sink")
  t.eq(d.factory.sink_items[1].key, "item/coal")
  mock.type_text(p, mock.find(scr(p), "row_rate", { mode = "sink" }), "30")
  t.near(d.factory.sink_items[1].rate, 0.5)
  mock.click(p, mock.named(scr(p), "stoich_save"))
  t.eq(draft_of(p), nil)
end)

t.test("gui: admins-only mode blocks edits but not viewing", function()
  local p1 = boot({ edit = "admins" })
  local id = saved_oil(p1)
  local p2 = mock.new_player(2, { admin = false })
  mock.fire("on_player_joined_game", { player_index = 2 })
  open(p2)
  t.truthy(mock.text(scr(p2)):find("Plastic bar", 1, true), "viewer sees the plan")
  local plus = mock.find(scr(p2), "plan_copies", { id = id, delta = 1 })
  t.eq(plus.enabled, false)
  capture(p2, oil_build())
  t.eq(draft_of(p2), nil)
  t.truthy(#p2.printed > 0)
  -- an admin switches to everyone in the settings dialog
  click(p1, "open_settings")
  mock.select(p1, mock.find(dialog(p1), "set_edit_mode"), 1)
  t.eq(settings.global["stoich-edit-permission"].value, "everyone")
  plus = mock.find(scr(p2), "plan_copies", { id = id, delta = 1 })
  t.eq(plus.enabled, true, "p2's window refreshed after the setting changed")
end)

t.test("gui: stale save shows the conflict dialog; overwrite and reload work", function()
  local p1 = boot()
  local id = saved_oil(p1)
  local p2 = mock.new_player(2, { admin = false })
  mock.fire("on_player_joined_game", { player_index = 2 })
  open(p2)
  go(p1, "plan")
  go(p2, "plan")
  click(p1, "fac_edit", { id = id })
  click(p2, "fac_edit", { id = id })
  mock.type_text(p2, mock.find(scr(p2), "editor_name"), "by p2")
  mock.click(p2, mock.named(scr(p2), "stoich_save"))
  t.eq(storage.plans.main.factories[id].name, "by p2")
  -- p1 is in the editor, so only its status refreshes; p2 saved fine.
  mock.type_text(p1, mock.find(scr(p1), "editor_name"), "by p1")
  mock.click(p1, mock.named(scr(p1), "stoich_save"))
  t.truthy(dialog(p1), "conflict dialog")
  t.truthy(mock.text(dialog(p1)):find("player2", 1, true))
  click(p1, "conflict_reload")
  t.eq(draft_of(p1).factory.name, "by p2")
  mock.type_text(p1, mock.find(scr(p1), "editor_name"), "by p1")
  mock.click(p2, mock.find(scr(p2), "fac_edit", { id = id }))
  mock.type_text(p2, mock.find(scr(p2), "editor_name"), "again p2")
  mock.click(p2, mock.named(scr(p2), "stoich_save"))
  mock.click(p1, mock.named(scr(p1), "stoich_save"))
  click(p1, "conflict_overwrite")
  t.eq(storage.plans.main.factories[id].name, "by p1")
end)

t.test("gui: other players' plan window refreshes live", function()
  local p1 = boot()
  local id = saved_oil(p1)
  local p2 = mock.new_player(2, {})
  mock.fire("on_player_joined_game", { player_index = 2 })
  open(p2)
  go(p1, "plan")
  local label_before = mock.text(scr(p2))
  click(p1, "plan_copies", { id = id, delta = 1 })
  t.truthy(mock.text(scr(p2)) ~= label_before, "p2 sees the new copy count")
end)

t.test("gui: delete with confirmation, rescan, show on map, add recipe and custom line", function()
  local p = boot()
  local id = saved_oil(p)
  go(p, "plan")
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
  go(p, "plan")
  go(p, "plan")
  go(p, "stats")
  t.truthy(#game.printed > 0)
end)

-- Fuzz: fire the natural event on every interactive element, re-reading the
-- GUI after each one (actions rebuild it), including dialogs.
local SKIP = { window_close = true, child_close = true }

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
  for _, what in ipairs({ "plan", "stats" }) do
    go(p, what)
    total = total + poke_all(p)
  end
  -- the factory editor after a capture, then the sink editor
  capture(p, oil_build())
  total = total + poke_all(p)
  go(p, "plan")
  if storage.players[1].draft then click(p, "editor_cancel") end
  click(p, "fac_new_sink")
  total = total + poke_all(p)
  t.truthy(total > 60, "poked " .. total .. " controls")
end)

t.test("gui: remaining controls", function()
  local p = boot()
  local id = saved_oil(p)
  go(p, "plan")
  click(p, "fac_capture")
  t.eq(p.cursor, TOOL)
  click(p, "fac_export_all")
  t.truthy(dialog(p))
  click(p, "dialog_close")
  click(p, "show_map", { id = id })
  t.eq(p.controller.type, defines.controllers.remote)
  t.truthy(win(p), "the switch to the map view doesn't close the window")
  click(p, "fac_new")
  local d = draft_of(p)
  t.eq(d.factory.kind, "factory")
  click(p, "editor_add_custom")
  click(p, "row_add", { mode = "dialog" })
  t.eq(#storage.players[1].dialog.rows, 2)
  click(p, "row_delete", { mode = "dialog", i = 2 })
  t.eq(#storage.players[1].dialog.rows, 1)
  mock.pick(p, mock.find(dialog(p), "row_signal", { mode = "dialog", i = 1 }), { type = "item", name = "iron-plate" })
  mock.type_text(p, mock.find(dialog(p), "row_rate", { mode = "dialog", i = 1 }), "60")
  click(p, "dlg_line_ok")
  local count = mock.find(scr(p), "editor_line_count")
  mock.type_text(p, count, "2")
  t.eq(d.factory.lines[1].count, 2)
  click(p, "editor_cancel")
  -- split dropdown and removal on a captured oil build
  capture(p, oil_build())
  d = draft_of(p)
  local dd = mock.find(scr(p), "split_item", { mode = "factory" })
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
  t.eq(settings.global["stoich-max-belt"].value, "transport-belt")
  click(p, "set_one_lane")
  t.eq(settings.global["stoich-one-lane"].value, true)
  click(p, "dialog_close")
  -- items tab collapse
  go(p, "stats")
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
  mock.pick(p, mock.find(scr(p), "editor_assign_recipe", { line = idle.id }), "plastic-bar")
  t.eq(idle.idle, true)
  t.truthy(#p.printed > 0)
  -- research productivity of the recipe is applied
  mock.force.recipes["copper-cable"].productivity_bonus = 0.1
  mock.pick(p, mock.find(scr(p), "editor_assign_recipe", { line = idle.id }), "copper-cable")
  t.eq(idle.recipe, "copper-cable")
  t.eq(idle.idle, nil)
  t.near(idle.flow["item/copper-cable"], 2 * 0.75 / 0.5 * 1.1)
  click(p, "editor_delete_line", { line = idle.id })
  -- factory mode: a byproduct nobody consumes gets a void line
  mock.click(p, mock.find(scr(p), "editor_external", { item = "item/plastic-bar" }))
  t.eq(d.factory.result.status, "CONFLICT")
  click(p, "problem_sink", { mode = "factory", item = "item/plastic-bar" })
  t.eq(draft_of(p).factory.result.status, "EXACT")
  local void
  for _, l in ipairs(draft_of(p).factory.lines) do if l.label == "void plastic-bar" then void = l end end
  t.truthy(void, "void line added")
  click(p, "editor_delete_line", { line = void.id })
  mock.click(p, mock.find(scr(p), "editor_external", { item = "item/plastic-bar" }))
  t.eq(draft_of(p).factory.result.status, "EXACT")
  mock.click(p, mock.named(scr(p), "stoich_save"))
  -- plan mode: a byproduct nothing uses offers a sink for it, a missing input nothing
  custom_factory("gear press", { ["item/plastic-bar"] = -1, ["item/iron-gear-wheel"] = 1, ["item/sulfur"] = 1 })
  add_sink(p, "iron-gear-wheel", 60)
  t.eq(mock.find(scr(p), "problem_sink", { mode = "plan", item = "fluid/crude-oil" }), nil, "no sink offered for a missing input")
  click(p, "problem_sink", { mode = "plan", item = "item/sulfur" })
  t.eq(draft_of(p).factory.kind, "sink")
  t.eq(draft_of(p).factory.sink_items[1].key, "item/sulfur")
end)

t.test("gui: discard question for unsaved captures and edits", function()
  local p = boot()
  local id = saved_oil(p)
  capture(p, oil_build()) -- a new capture counts as unsaved work
  local captured = draft_of(p)
  -- capturing again over the unsaved capture asks; keep editing keeps it
  capture(p, oil_build())
  t.truthy(dialog(p), "discard question")
  t.truthy(draft_of(p) == captured, "capture kept while asking")
  click(p, "discard_keep")
  t.eq(dialog(p), nil)
  t.truthy(draft_of(p) == captured)
  t.truthy(p.opened == editor_win(p), "Esc / E back on the editor")
  -- asked again, discard: the new capture opens
  capture(p, oil_build())
  click(p, "discard_ok")
  t.truthy(draft_of(p) ~= captured, "new capture opened after discarding")
  t.eq(#p.translations, 3, "default-name translation requested for each capture")
  click(p, "editor_cancel")
  -- editing a saved factory: unchanged, another capture opens without a question
  click(p, "fac_edit", { id = id })
  capture(p, oil_build())
  t.eq(dialog(p), nil, "nothing to lose")
  click(p, "editor_cancel")
  -- changed, it asks
  click(p, "fac_edit", { id = id })
  mock.type_text(p, mock.find(scr(p), "editor_name"), "changed")
  capture(p, oil_build())
  t.truthy(dialog(p), "asks before capturing over a changed draft")
  t.eq(draft_of(p).factory.name, "changed")
  click(p, "discard_ok")
  t.truthy(draft_of(p).factory.name ~= "changed", "new capture opened")
end)

t.test("gui: the editor is its own window; closing it asks about unsaved changes", function()
  local p = boot()
  -- a capture opens the main window with the editor over it; Esc / E goes to the editor
  capture(p, oil_build())
  t.truthy(win(p) and editor_win(p), "both windows")
  t.truthy(p.opened == editor_win(p))
  t.truthy(mock.find(win(p), "fac_new"), "the plan stays usable under the editor")
  -- Esc on a fresh capture: asked, keep editing
  mock.press_esc(p)
  t.truthy(editor_win(p), "still open while asking")
  t.truthy(dialog(p), "discard question")
  t.truthy(mock.text(dialog(p)):find("<stoich.discard-close>", 1, true))
  click(p, "discard_keep")
  t.truthy(draft_of(p), "kept")
  t.truthy(p.opened == editor_win(p), "Esc / E back on the editor")
  -- the close button: asked, discard
  click(p, "child_close", nil, editor_win(p))
  click(p, "discard_ok")
  t.eq(editor_win(p), nil)
  t.eq(draft_of(p), nil)
  t.truthy(win(p), "the main window stays")
  t.truthy(p.opened == win(p))
  -- an unchanged saved factory closes without a question
  local id = saved_oil(p)
  click(p, "fac_edit", { id = id })
  mock.press_esc(p)
  t.eq(dialog(p), nil)
  t.eq(editor_win(p), nil)
  t.eq(draft_of(p), nil)
  -- closing the main window takes the editor with it, asking first when it has changes
  click(p, "fac_new_sink")
  mock.pick(p, mock.find(editor_win(p), "row_signal", { mode = "sink", i = 1 }), { type = "item", name = "coal" })
  mock.fire_custom("stoich-toggle-window", 1)
  t.truthy(win(p) and editor_win(p) and dialog(p), "asked before closing everything")
  click(p, "discard_ok")
  t.eq(win(p), nil)
  t.eq(editor_win(p), nil)
  t.eq(draft_of(p), nil, "sink draft dropped")
  -- and quietly when nothing changed
  open(p)
  click(p, "fac_edit", { id = id })
  click(p, "window_close")
  t.eq(win(p), nil)
  t.eq(editor_win(p), nil)
  t.eq(draft_of(p), nil)
  -- recapture: the windows hide while the tool is out, Esc / E don't close them
  open(p)
  click(p, "fac_edit", { id = id })
  click(p, "editor_recapture")
  t.eq(win(p).visible, false)
  t.eq(editor_win(p).visible, false)
  t.truthy(scr(p).stoich_hint, "a hint says what to do")
  mock.press_esc(p)
  t.truthy(draft_of(p), "kept while recapturing")
  capture(p, oil_build())
  t.truthy(editor_win(p).visible, "back with the new area")
  t.eq(scr(p).stoich_hint, nil, "hint gone")
  t.eq(win(p).visible, false, "the plan stays hidden under the editor")
  t.truthy(draft_of(p).factory.id == id, "same factory, recaptured")
  -- show on map closes the open GUI in the same tick; the editor stays
  click(p, "editor_show_map")
  t.truthy(editor_win(p) and draft_of(p), "kept for the trip to the map")
  game.tick = game.tick + 1
  click(p, "editor_cancel")
  t.eq(draft_of(p), nil)
end)

t.test("gui: an invalid factory is repaired by deleting its broken line", function()
  local p = boot()
  local id = saved_oil(p)
  prototypes.recipe["coal-liquefaction"] = nil
  mock.init.on_configuration_changed({})
  t.eq(storage.plans.main.factories[id].result.status, "INVALID")
  go(p, "plan")
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
  mock.click(p, mock.named(scr(p), "stoich_save"))
  t.eq(storage.plans.main.factories[id].invalid, nil)
  t.eq(storage.plans.main.factories[id].result.status, "EXACT")
end)

t.test("gui: split prompt offers every useful item in a dropdown", function()
  local p = boot()
  capture(p, oil_build())
  click(p, "split_remove", { mode = "factory" })
  local d = draft_of(p)
  t.eq(d.factory.result.status, "NEEDS_SPLIT")
  local cand = mock.named(scr(p), "stoich_cand")
  t.truthy(cand, "candidate dropdown")
  local cands = mock.find(scr(p), "problem_split", { mode = "factory" }).tags.cands
  t.truthy(#cands > 1)
  mock.select(p, cand, #cands)
  mock.click(p, mock.find(scr(p), "problem_split", { mode = "factory" }))
  t.eq(d.factory.splits[1].item, cands[#cands])
end)

t.test("gui: picker maps recipes to products; fluid flag only for custom names", function()
  local p = boot()
  open(p)
  go(p, "plan")
  click(p, "fac_new_sink")
  t.eq(mock.find(scr(p), "row_fluid", { mode = "sink" }), nil, "no fluid flag for an empty row")
  -- picking a recipe (as the signal picker allows) stores what it makes
  mock.pick(p, mock.find(scr(p), "row_signal", { mode = "sink", i = 1 }), { type = "recipe", name = "plastic-bar" })
  t.eq(draft_of(p).factory.sink_items[1].key, "item/plastic-bar")
  t.eq(mock.find(scr(p), "row_fluid", { mode = "sink" }), nil, "no fluid flag for a real item")
  click(p, "row_add", { mode = "sink" })
  mock.type_text(p, mock.find(scr(p), "row_text", { mode = "sink", i = 2 }), "space data", true)
  t.truthy(mock.find(scr(p), "row_fluid", { mode = "sink", i = 2 }), "fluid flag for the custom name")
  t.eq(mock.find(scr(p), "row_fluid", { mode = "sink", i = 1 }), nil)
end)

t.test("gui: editor groups items; shortage never shows below 0", function()
  local p = boot()
  capture(p, oil_build())
  local text = mock.text(scr(p))
  t.truthy(text:find("<stoich.items-inputs>", 1, true) and text:find("<stoich.items-outputs>", 1, true) and text:find("<stoich.items-inside>", 1, true))
  mock.click(p, mock.named(scr(p), "stoich_save"))
  local id
  for fid in pairs(storage.plans.main.factories) do id = fid end
  add_sink(p, "plastic-bar", 60)
  go(p, "plan")
  close_plan()
  local r = storage.plans.main.result
  t.eq(r.status, "EXACT")
  t.truthy(r.shortage[id] < 0, "overbuilt in this plan")
  -- the "to build" cell reads a green tick, with the surplus in its tooltip
  local found = false
  for _, e in ipairs(mock.all(win(p))) do
    local tip = e.type == "label" and e.style.name == "bold_label" and e.tooltip
    -- { "", { "stoich.shortage-tooltip", ... }, "\n", { "stoich.surplus-tooltip", ... } }
    if type(tip) == "table" and type(tip[4]) == "table" and tip[4][1] == "stoich.surplus-tooltip" then
      found = true
      t.eq(e.caption, "✓")
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
  t.eq(d.belt, "", "the basic belt has no icon")
  t.eq(common.rate_display(ctx, 20, "item/iron-plate").belt, "[entity=fast-transport-belt]", "a faster one has")
  t.eq(d.fill, "67%")
  t.eq(d.tooltip[1], "stoich.belt-tooltip")
  local over = common.rate_display(ctx, 40, "item/iron-plate")
  t.eq(over.exceeds, true)
  t.eq(over.color, common.RED)
  t.eq(over.belt, "[entity=fast-transport-belt]")
  t.eq(over.fill, "1.33×")
  -- a plan-wide total may take several belts by design: same numbers, not red
  local total = common.rate_display(ctx, 40, "item/iron-plate", nil, { total = true })
  t.eq(total.color, nil)
  t.eq(total.fill_color, nil)
  t.eq(total.fill, "1.33×")
  t.eq(total.tooltip[1], "stoich.belt-total-tooltip")
  local fluid = common.rate_display(ctx, 400, "fluid/water")
  t.eq(fluid.belt, "—")
  t.eq(fluid.fill, "")
  -- the editor shows them as three columns, updated in place while balancing
  capture(p, oil_build())
  local lines = mock.named(scr(p), "stoich_lines")
  local any_rate = false
  for _, e in ipairs(mock.all(lines)) do
    if e.name and e.name:match("^out_%d+_belt$") and e.caption ~= "" then any_rate = true end
  end
  t.truthy(any_rate, "output belt cells filled")
end)

t.test("gui: statistics in its own window; one window size", function()
  local p = boot()
  saved_oil(p)
  open(p)
  go(p, "stats")
  t.truthy(stats_win(p) and win(p), "statistics over the main window")
  click(p, "items_collapse")
  -- closing the main window closes the statistics with it
  click(p, "window_close")
  t.eq(stats_win(p), nil)
  open(p)
  -- the same size on any screen, no size toggle
  t.eq(win(p).style.width, 960)
  t.eq(win(p).style.height, 680)
  t.eq(mock.find(win(p), "window_size"), nil)
  -- hide satisfied factories
  click(p, "plan_hide_ok")
  t.eq(storage.players[1].hide_ok, true)
end)

t.test("gui: a plan split is a row of the plan; its pencil opens the split window", function()
  local p = boot()
  saved_oil(p)
  saved_oil(p) -- a second design making the same items
  -- two factories with the same name, like several identical mines
  for _, f in pairs(storage.plans.main.factories) do f.name = "Plastic bar" end
  add_sink(p, "plastic-bar", 60)
  go(p, "plan")
  close_plan()
  click(p, "problem_split", { mode = "plan" })
  t.truthy(split_win(p), "adding a plan split opens its window")
  t.truthy(p.opened == split_win(p))
  local text = mock.text(split_win(p))
  t.truthy(text:find("#", 1, true), "same-named factories get their id")
  t.truthy(text:find("<stoich.needed-count>", 1, true), "needed copies per factory")
  click(p, "child_close", nil, split_win(p))
  t.eq(split_win(p), nil)
  -- the plan lists the split as a row: a "split" mark, one chip per factory with its share
  t.eq(mock.find(win(p), "split_slider", { mode = "plan" }), nil, "no sliders in the main window")
  t.truthy(mock.text(win(p)):find("<stoich.split-mark>", 1, true))
  local shares = {}
  for _, e in ipairs(mock.all(win(p))) do
    if e.type == "sprite-button" and e.style.name == "slot_button" and e.parent.children[1].type == "sprite-button"
      and #e.parent.children == 2 and e.parent.children[2].type == "sprite-button" then shares[#shares + 1] = e.number end
  end
  t.eq(#shares, 2, "two factory chips")
  t.near(shares[1] + shares[2], 100)
  -- the pencil opens the window again; a dragged slider survives, the row follows
  click(p, "plan_split_edit")
  local slider = mock.find(split_win(p), "split_slider", { mode = "plan" })
  mock.slide(p, slider, 25)
  t.truthy(slider.valid, "slider survives")
  local found = false
  for _, e in ipairs(mock.all(win(p))) do
    if e.type == "sprite-button" and e.number and math.abs(e.number - 25) < 1e-9 then found = true end
  end
  t.truthy(found, "the plan row shows the new share")
  -- removing the split from its row closes its window
  click(p, "split_remove", { mode = "plan" }, win(p))
  t.eq(#storage.plans.main.splits, 0)
  t.eq(split_win(p), nil, "window closed with its split")
end)

t.test("gui: one rate unit selector, in the settings dialog", function()
  local p = boot()
  open(p)
  t.eq(#mock.find_all(scr(p), "set_unit"), 0, "none in the window")
  click(p, "open_settings")
  local all = mock.find_all(p.gui.screen, "set_unit")
  t.eq(#all, 1, "only the one in settings")
  mock.select(p, all[1], 1)
  t.eq(p.mod_settings["stoich-rate-unit"].value, "s")
  t.eq(mock.named(dialog(p), "stoich_unit").selected_index, 1)
end)

t.test("gui: a new sink is named after its first item; the list marks sinks without renaming them", function()
  local p = boot()
  open(p)
  go(p, "plan")
  click(p, "fac_new_sink")
  local d = draft_of(p)
  mock.pick(p, mock.find(scr(p), "row_signal", { mode = "sink", i = 1 }), { type = "item", name = "coal" })
  t.eq(d.factory.name, "Coal")
  t.eq(mock.named(scr(p), "stoich_name").text, "Coal")
  local id = #p.translations
  mock.fire("on_string_translated", { player_index = 1, id = id, translated = true, result = "Coal (localised)", localised_string = p.translations[id] })
  t.eq(d.factory.name, "Coal (localised)")
  -- a typed name wins over later picks
  mock.type_text(p, mock.find(scr(p), "editor_name"), "Boilers")
  mock.pick(p, mock.find(scr(p), "row_signal", { mode = "sink", i = 1 }), { type = "item", name = "iron-plate" })
  t.eq(d.factory.name, "Boilers")
  mock.type_text(p, mock.find(scr(p), "row_rate", { mode = "sink", i = 1 }), "30")
  mock.click(p, mock.named(scr(p), "stoich_save"))
  local name_label
  for _, e in ipairs(mock.all(scr(p))) do
    if e.type == "label" and e.caption == "Boilers" then name_label = e end
  end
  t.truthy(name_label, "name shown as is, no suffix")
  t.truthy(mock.text(scr(p)):find("<stoich.sink-mark>", 1, true), "marked next to the name")
  -- the sink row shows what it takes in as slots and an arrow with nothing after it; no rate fields
  local chip
  for _, e in ipairs(mock.all(scr(p))) do
    if e.type == "sprite-button" and e.sprite == "item/iron-plate" then chip = e end
  end
  t.truthy(chip, "iron plate slot")
  local chips = chip.parent.children
  t.eq(chips[#chips].caption, "→")
  for _, e in ipairs(mock.all(scr(p))) do t.truthy(e.type ~= "textfield" or e.tags.fp == "plan_filter", "only the filter is a text field") end
end)

local function gear_build(x0)
  local list = {}
  for i = 1, 3 do list[#list + 1] = mock.crafter("assembling-machine", "assembling-machine-2", "copper-cable", x0 + i * 4, 40) end
  for i = 1, 2 do list[#list + 1] = mock.crafter("assembling-machine", "assembling-machine-2", "electronic-circuit", x0 + i * 4, 44) end
  return list
end

t.test("gui: recapture area replaces the open factory's contents", function()
  local p = boot()
  local id = saved_oil(p)
  go(p, "plan")
  click(p, "plan_copies", { id = id, delta = 1 })
  go(p, "plan")
  click(p, "fac_edit", { id = id })
  local d = draft_of(p)
  local name = d.factory.name
  click(p, "editor_recapture")
  t.eq(p.cursor, TOOL)
  t.eq(storage.players[1].recapture, true)
  -- select a different build: it replaces the lines in the open editor, no new factory, no question
  mock.fire("on_player_selected_area", { player_index = 1, item = TOOL, entities = gear_build(200), area = AREA, surface = mock.surface })
  t.eq(dialog(p), nil)
  t.truthy(draft_of(p) == d, "same draft")
  t.eq(d.factory.id, id)
  t.eq(d.factory.name, name, "name kept")
  local recipes = {}
  for _, l in ipairs(d.factory.lines) do recipes[l.recipe or "?"] = true end
  t.truthy(recipes["electronic-circuit"] and not recipes["plastic-bar"], "new contents")
  t.eq(storage.players[1].recapture, nil)
  t.eq(d.factory.result.status, "EXACT")
  mock.click(p, mock.named(scr(p), "stoich_save"))
  local n = 0
  for _ in pairs(storage.plans.main.factories) do n = n + 1 end
  t.eq(n, 1, "replaced in place")
  t.eq(storage.plans.main.factories[id].copies, 2, "copies kept")
end)

t.test("gui: dropping the tool cancels a recapture", function()
  local p = boot()
  local id = saved_oil(p)
  go(p, "plan")
  click(p, "fac_edit", { id = id })
  click(p, "editor_recapture")
  t.eq(storage.players[1].recapture, true)
  p.clear_cursor() -- Q
  t.eq(storage.players[1].recapture, nil)
  click(p, "editor_cancel")
  -- a later capture opens a new factory as usual
  capture(p, gear_build(300))
  t.eq(draft_of(p).factory.id, nil)
end)

t.test("gui: a factory without an anchor offers to anchor its first line", function()
  local p = boot()
  open(p)
  go(p, "plan")
  click(p, "fac_new")
  click(p, "editor_add_custom")
  mock.pick(p, mock.find(dialog(p), "row_signal", { mode = "dialog", i = 1 }), { type = "item", name = "iron-plate" })
  mock.type_text(p, mock.find(dialog(p), "row_rate", { mode = "dialog", i = 1 }), "60")
  click(p, "dlg_line_ok")
  local d = draft_of(p)
  d.factory.anchors = {}
  click(p, "editor_external", { item = "item/iron-plate" })
  t.eq(d.factory.result.status, "NEEDS_SPLIT")
  click(p, "problem_anchor", { mode = "factory" })
  t.eq(d.factory.anchors[d.factory.lines[1].id], 1)
  t.eq(d.factory.result.status, "EXACT")
end)

t.test("gui: the editor window is one column, as tall as the main window", function()
  local p = boot()
  open(p)
  capture(p, oil_build())
  t.truthy(mock.named(editor_win(p), "stoich_lines"))
  t.truthy(mock.named(editor_win(p), "stoich_items_table"), "one items table")
  t.eq(editor_win(p).style.width, 900)
  t.eq(editor_win(p).style.height, 680)
end)

t.test("gui: the debug interface only exists when its hidden setting is on", function()
  boot()
  t.truthy(mock.interfaces["stoich"])
  t.eq(mock.interfaces["stoich-debug"], nil)
  local p = boot({ debug_interface = true })
  local debug = mock.interfaces["stoich-debug"]
  t.truthy(debug)
  -- act toggles a checkbox both ways when no value is given
  saved_oil(p)
  debug.open(p.index, "plan")
  local hide_ok = function() return mock.find(scr(p), "plan_hide_ok").state end
  local before = hide_ok()
  t.eq(debug.act(p.index, "plan_hide_ok", {}), true)
  t.eq(hide_ok(), not before)
  t.eq(debug.act(p.index, "plan_hide_ok", {}), true)
  t.eq(hide_ok(), before)
  -- the test world lacks mines for some inputs: sources (and voids) close its plan
  add_sink(p, "plastic-bar", 60)
  t.truthy(debug.plan_sources() > 0)
  t.truthy(next(debug.factories()), "the factories, for the screenshot driver")
  t.truthy(storage.plans.main.result.status ~= "CONFLICT")
end)

t.test("gui: every handler is reached by some scenario", function()
  local missing = {}
  for _, file in ipairs({ "common", "window", "dialogs", "splits", "problems", "rows", "editor", "actions", "plan", "items" }) do
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
