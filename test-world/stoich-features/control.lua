-- In-game check of Stoich 0.4 features on Space Age: plans per surface, the recipe dialog
-- (by item, modules, beacons), recipe factories, voids and imports. Builds a real
-- recycler and a real assembler with modules and beacons, captures them, makes the same
-- setups in the recipe dialog and compares the two flows. Screenshots of every screen.
-- Writes script-output/features/report.txt, *.png and done.txt.

local D = "stoich-debug"
local P = 1
local GAP = 30
local OUT = "features/"
local log_lines = {}
local fails = 0

local function note(s)
  log_lines[#log_lines + 1] = s
  log("stoich-features: " .. s)
end

local function check(ok, what)
  if not ok then fails = fails + 1 end
  note((ok and "ok    " or "FAIL  ") .. what)
end

local function act(action, match, value)
  local ok = remote.call(D, "act", P, action, match or {}, value)
  note("act " .. action .. " " .. serpent.line(match or {}) .. (value ~= nil and (" = " .. serpent.line(value)) or "") .. " -> " .. tostring(ok))
  return ok
end

local function shot(name)
  game.take_screenshot({ player = P, by_player = P, path = OUT .. name .. ".png", show_gui = true, force_render = true })
  note("shot " .. name)
end

local function draft() return remote.call(D, "draft", P) end
local function dialog() return remote.call(D, "dialog", P) end
local function player() return game.get_player(P) end

-- the main window alone: child windows closed first
local function open_plan()
  for _ = 1, 4 do
    if not remote.call(D, "act", P, "child_close", {}) then break end
  end
  remote.call(D, "open", P)
end

local function index_of(list, value)
  for i, v in ipairs(list or {}) do
    if v == value then return i end
  end
end

-- World ---------------------------------------------------------------------------------------------

local function clear(surface, l, t, r, b)
  surface.request_to_generate_chunks({ (l + r) / 2, (t + b) / 2 }, 3)
  surface.force_generate_chunk_requests()
  for _, e in ipairs(surface.find_entities_filtered({ area = { { l - 8, t - 8 }, { r + 8, b + 8 } } })) do
    if e.valid and e.type ~= "character" then e.destroy() end
  end
  local tiles = {}
  for x = l - 8, r + 7 do
    for y = t - 8, b + 7 do tiles[#tiles + 1] = { name = ((x + y) % 2 == 0) and "lab-dark-1" or "lab-dark-2", position = { x, y } } end
  end
  surface.set_tiles(tiles)
end

local function place(surface, name, x, y, opts)
  opts = opts or {}
  local e = surface.create_entity({ name = name, position = { x, y }, force = "player", recipe = opts.recipe, create_build_effect_smoke = false })
  if not e then error("could not place " .. name .. " at " .. x .. "," .. y) end
  for _, m in ipairs(opts.modules or {}) do e.get_module_inventory().insert({ name = m, count = 1 }) end
  return e
end

-- a substation above the cell powers the machine and both beacons
local function power(surface, x, y)
  place(surface, "substation", x, y - 6)
  place(surface, "electric-energy-interface", x + 4, y - 6)
end

local function rep(m, n)
  local out = {}
  for i = 1, n do out[i] = m end
  return out
end

-- cells: a machine with modules and two beacons (left and right, 2 speed modules each)
local CELLS = {
  recycler = { x = 0, y = 0, machine = "recycler", modules = rep("speed-module-3", 4), feed = "copper-cable" },
  assembler = { x = 20, y = 0, machine = "assembling-machine-3", recipe = "copper-cable", modules = rep("productivity-module-3", 4), feed = "copper-plate" },
}

local function area(cell)
  return { left_top = { x = cell.x - 9, y = cell.y - 9 }, right_bottom = { x = cell.x + 9, y = cell.y + 9 } }
end

local function build()
  local nauvis = game.surfaces.nauvis
  clear(nauvis, -12, -12, 34, 12)
  for _, cell in pairs(CELLS) do
    power(nauvis, cell.x, cell.y)
    cell.entity = place(nauvis, cell.machine, cell.x + 0.5, cell.y + 0.5, { recipe = cell.recipe, modules = cell.modules })
    for _, dx in ipairs({ -3, 3 }) do place(nauvis, "beacon", cell.x + 0.5 + dx, cell.y + 0.5, { modules = rep("speed-module-3", 2) }) end
  end
  -- Vulcanus: three cable assemblers, nothing else
  local vulcanus = game.planets.vulcanus.create_surface()
  clear(vulcanus, -12, -12, 12, 12)
  power(vulcanus, 0, 0)
  for i = 0, 2 do place(vulcanus, "assembling-machine-2", -2.5 + 3 * i, 0.5, { recipe = "copper-cable" }) end
  storage.cells = CELLS
end

local function feed()
  for _, cell in pairs(storage.cells or {}) do
    local e = cell.entity
    if e and e.valid then
      local inv = e.get_inventory(defines.inventory.crafter_input)
      if inv.get_item_count(cell.feed) < 20 then inv.insert({ name = cell.feed, count = 40 }) end
      e.get_output_inventory().clear()
    end
  end
end

-- Steps -------------------------------------------------------------------------------------------------

local captured = {}
local made = {}

local function machine_line(d, machine)
  for _, line in ipairs(d and d.factory.lines or {}) do
    if line.machine == machine and not line.idle then return line end
  end
end

local function capture_cell(key)
  local cell = storage.cells[key]
  remote.call(D, "capture", P, area(cell))
  local line = machine_line(draft(), cell.machine)
  check(line ~= nil, "captured the " .. key .. " (" .. cell.machine .. ")")
  if line then
    captured[key] = line.flow
    local powered = 0
    for _, b in ipairs(cell.entity.get_beacons()) do
      if b.status == defines.entity_status.working then powered = powered + 1 end
    end
    note(string.format("  %s: speed %s, productivity %s, entity speed bonus %.4f, prod bonus %.4f, beacons %d (%d working)", key,
      tostring(line.speed), tostring(line.productivity), cell.entity.speed_bonus, cell.entity.productivity_bonus, #cell.entity.get_beacons(), powered))
    check(powered == 2, key .. ": both beacons working")
  end
  act("editor_cancel")
end

local function compare(key)
  local want, got = captured[key], made[key]
  if not (want and got) then
    check(false, key .. ": nothing to compare")
    return
  end
  local keys = {}
  for k in pairs(want) do keys[#keys + 1] = k end
  for k in pairs(got) do if want[k] == nil then keys[#keys + 1] = k end end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local a, b = want[k] or 0, got[k] or 0
    local diff = a ~= 0 and (b - a) / math.abs(a) * 100 or (b == 0 and 0 or 100)
    check(math.abs(diff) < 0.01, string.format("%s %s: captured %.5f/s, dialog %.5f/s (%+.4f%%)", key, k, a, b, diff))
  end
end

-- one machine with modules and 2 beacons, in the recipe dialog, then Create and keep its line
local function dialog_modules(machine_modules)
  for slot, m in ipairs(machine_modules) do act("dlg_module", { slot = slot }, m) end
  act("dlg_num", { field = "beacon_count" }, 2)
  act("dlg_beacon_module", { slot = 1 }, "speed-module-3")
  act("dlg_beacon_module", { slot = 2 }, "speed-module-3")
end

local function keep_made(key, machine)
  local line = machine_line(draft(), machine)
  check(line ~= nil, "the dialog made a " .. key .. " factory")
  if line then
    made[key] = line.flow
    note(string.format("  dialog %s: speed %+.3f%%, productivity %+.3f%%", key, line.speed_pct or 0, line.prod_pct or 0))
  end
end

local function plan_status(key)
  local r = remote.call("stoich", "plan_result", key)
  if not r then return "none" end
  local kinds = {}
  for _, p in ipairs(r.problems) do kinds[#kinds + 1] = p.type .. (p.item and (" " .. p.item) or "") end
  return r.status .. " [" .. table.concat(kinds, ", ") .. "]"
end

local steps = {}
local function step(fn) steps[#steps + 1] = fn end

step(function() capture_cell("recycler") end)
step(function() capture_cell("assembler") end)
step(function() open_plan() end)
step(function() shot("f01-plan-empty") end)

-- a recycling factory, picked by item
step(function() act("fac_new_recipe") end)
step(function() act("dlg_item", {}, "copper-cable") end)
step(function()
  local dlg = dialog()
  note("  recipes for copper cable: " .. table.concat(dlg and dlg.recipes or {}, ", "))
  check(dlg and dlg.recipe == "copper-cable-recycling", "copper cable's recycling picked first")
  check(dlg and dlg.machines and dlg.machines[1] == "recycler", "on the recycler")
  shot("f02-dialog-item")
end)
step(function() dialog_modules(rep("speed-module-3", 4)) end)
step(function() shot("f03-dialog-recycler-modules") end)
step(function() act("dlg_recipe_ok") end)
step(function()
  keep_made("recycler", "recycler")
  shot("f04-editor-recycling")
end)
step(function() act("editor_save") end)

-- a cable assembler, recipe picked directly, on an assembling machine 3
step(function() act("fac_new_recipe") end)
step(function() act("dlg_recipe", {}, "copper-cable") end)
step(function()
  local dlg = dialog()
  note("  machines: " .. table.concat(dlg and dlg.machines or {}, ", "))
  local i = dlg and index_of(dlg.machines, "assembling-machine-3")
  check(i ~= nil, "assembling machine 3 offered")
  if i then act("dlg_machine", {}, i) end
end)
step(function() dialog_modules(rep("productivity-module-3", 4)) end)
step(function() shot("f05-dialog-assembler-modules") end)
step(function() act("dlg_recipe_ok") end)
step(function() keep_made("assembler", "assembling-machine-3") end)
step(function() act("editor_save") end)
step(function()
  compare("recycler")
  compare("assembler")
end)

-- a sink of cables: the plan wants plates, which nothing makes here
step(function() open_plan() end)
step(function() act("fac_new_sink") end)
step(function() act("row_signal", { mode = "sink", i = 1 }, { type = "item", name = "copper-cable" }) end)
step(function() act("row_rate", { mode = "sink", i = 1 }, 600) end)
step(function() act("editor_name", {}, "Cable demand") end)
step(function() act("editor_save") end)
step(function()
  note("  nauvis plan after the sink: " .. plan_status("nauvis"))
  shot("f06-plan-sink")
end)
-- plates come from another planet: an import, from the toolbar. The recycler makes
-- plates too, so how much each gives is the player's choice (a split), not a negative count.
step(function() act("fac_boundary", { kind = "import" }) end)
step(function() act("row_signal", { mode = "boundary", i = 1 }, { type = "item", name = "copper-plate" }) end)
step(function() act("editor_save") end)
step(function()
  open_plan()
  local status = plan_status("nauvis")
  note("  nauvis plan with the import: " .. status)
  check(status:find("^NEEDS_SPLIT") ~= nil, "the import and the recycler: a split to choose")
  shot("f07-plan-import")
end)
step(function() act("problem_split", { mode = "plan" }) end)
step(function()
  local status = plan_status("nauvis")
  note("  nauvis plan after choosing the split: " .. status)
  check(status:find("^EXACT") ~= nil, "the split (all plates imported at first) balances the plan")
  shot("f08-split")
end)

-- a void from the toolbar
step(function() open_plan() end)
step(function() act("fac_boundary", { kind = "void" }) end)
step(function() act("row_signal", { mode = "boundary", i = 1 }, { type = "item", name = "iron-plate" }) end)
step(function() shot("f09-editor-void") end)
step(function() act("editor_save") end)
step(function()
  open_plan()
  note("  nauvis plan with a void: " .. plan_status("nauvis"))
  shot("f10-plan-void-import")
end)

-- Vulcanus: on its map (remote view) a capture goes to its plan, and the window opens there
step(function()
  act("window_close")
  player().set_controller({ type = defines.controllers.remote, surface = "vulcanus", position = { 0, 0 } })
  note("  remote view: player.surface " .. player().surface.name .. ", physical " .. player().physical_surface.name)
end)
step(function()
  remote.call(D, "capture", P, { left_top = { x = -6, y = -3 }, right_bottom = { x = 6, y = 3 } })
  local d = draft()
  check(d and d.plan == "vulcanus", "a capture on Vulcanus belongs to Vulcanus's plan (draft plan " .. tostring(d and d.plan) .. ")")
end)
step(function() shot("f11-editor-vulcanus") end)
step(function() act("editor_save") end)
step(function()
  open_plan()
  local ids = remote.call(D, "factories", "vulcanus")
  local n = 0
  for _ in pairs(ids) do n = n + 1 end
  check(n == 1, "Vulcanus's plan has its factory (" .. n .. ")")
  note("  vulcanus plan: " .. plan_status("vulcanus"))
  shot("f12-plan-vulcanus")
end)
step(function() act("plan_surface", {}, 1) end)
step(function() shot("f13-selector-nauvis") end)
step(function()
  act("window_close")
  remote.call(D, "open", P)
  shot("f14-reopened-on-vulcanus-map")
end)
step(function()
  act("window_close")
  player().exit_remote_view()
  note("  back: player.surface " .. player().surface.name)
  remote.call(D, "open", P)
  shot("f15-reopened-on-nauvis")
end)
step(function() act("open_log") end)
step(function() shot("f16-log") end)
step(function() act("dialog_close") end)
step(function() remote.call(D, "open", P, "statistics") end)
step(function() shot("f17-statistics") end)
step(function()
  open_plan()
  act("fac_export_all")
end)
step(function() shot("f18-export") end)
step(function() act("dialog_close") end)

step(function()
  note("")
  note(string.format("%d failure(s)", fails))
  helpers.write_file(OUT .. "report.txt", table.concat(log_lines, "\n"))
  helpers.write_file(OUT .. "done.txt", fails == 0 and "pass" or "fail")
end)

-- Events --------------------------------------------------------------------------------------------

script.on_init(function()
  game.forces.player.research_all_technologies()
  build()
  game.surfaces.nauvis.always_day = true
end)

script.on_event(defines.events.on_player_created, function(event)
  local p = game.get_player(event.player_index)
  p.teleport({ 10, -14 }, "nauvis")
  p.zoom = 0.5
end)

script.on_event(defines.events.on_tick, function(event)
  feed()
  local start = 180 -- machines run a while before the first capture
  local i = (event.tick - start) / GAP + 1
  if i >= 1 and i == math.floor(i) and steps[i] then
    local ok, err = pcall(steps[i])
    if not ok then
      check(false, "step " .. i .. ": " .. tostring(err))
      helpers.write_file(OUT .. "report.txt", table.concat(log_lines, "\n"))
    end
  end
end)
