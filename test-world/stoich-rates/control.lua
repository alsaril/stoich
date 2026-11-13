-- Rate check for Stoich: builds one machine per cell (pumpjacks at several yields,
-- modules, beacons, drills, crafters, an offshore pump), captures each cell through
-- Stoich's debug interface, then runs the machines with script-fed inputs and
-- drained outputs and compares what they really make with what Stoich computed.
-- Works with or without Krastorio 2. Writes script-output/stoich-rates/report.txt.

local D = "stoich-debug"
local P = 1
local SURFACE = "stoich-rates"
local CELL, COLS = 32, 6
local CAPTURE, START, WINDOW = 120, 300, 18000 -- ticks; WINDOW = 5 game minutes
local TOLERANCE = 1 -- percent

local function surface() return game.surfaces[SURFACE] end

local function first_item(names)
  for _, n in ipairs(names) do
    if prototypes.item[n] then return n end
  end
end

local function product_amount(p)
  local a = p.amount or ((p.amount_min + p.amount_max) / 2)
  return a * (p.independent_probability or p.probability or 1)
end

local function place(name, x, y, opts)
  opts = opts or {}
  if not prototypes.entity[name] then error("missing entity " .. name) end
  local e = surface().create_entity({ name = name, position = { x, y }, force = "player", recipe = opts.recipe,
    direction = opts.direction, create_build_effect_smoke = false })
  if not e then error("could not place " .. name .. " at " .. x .. "," .. y) end
  for _, m in ipairs(opts.modules or {}) do
    if m then e.get_module_inventory().insert({ name = m, count = 1 }) end
  end
  return e
end

-- Beacons around a 3x3 machine, in this order (the top middle last: drills drop there).
local RING = { { -3, 0 }, { 3, 0 }, { 0, 3 }, { -3, 3 }, { 3, 3 }, { -3, -3 }, { 3, -3 }, { 0, -3 } }

local function tiles(l, t, r, b, name)
  local out = {}
  for x = l, r - 1 do
    for y = t, b - 1 do
      out[#out + 1] = { name = name or (((x + y) % 2 == 0) and "lab-dark-1" or "lab-dark-2"), position = { x, y } }
    end
  end
  surface().set_tiles(out)
end

local cases = {}

--- One test cell: a substation and an energy interface, then build(cx, cy) places the
--- machine (and beacons). cx, cy is a tile centre, so 3x3 machines sit on it.
local function cell(key, build)
  cases[#cases + 1] = { key = key, build = build }
end

local function build_cell(c, i)
  local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
  local l, t = col * CELL, row * CELL
  local cx, cy = l + CELL / 2 + 0.5, t + CELL / 2 + 0.5
  c.area = { left_top = { x = l + 2, y = t + 2 }, right_bottom = { x = l + CELL - 2, y = t + CELL - 2 } }
  place("substation", cx - 6.5, cy - 0.5)
  place("electric-energy-interface", cx - 6.5, cy + 2.5)
  rendering.draw_text({ text = c.key, surface = surface(), target = { cx, t + 3 }, color = { 1, 1, 1 }, scale = 2,
    alignment = "center" })
  local ok, err = pcall(function() c.build(c, cx, cy) end)
  if not ok then c.error = tostring(err) end
  c.build = nil -- storage can't hold functions
end

local function beacons(cx, cy, n, module)
  for i = 1, n do
    place("beacon", cx + RING[i][1], cy + RING[i][2], { modules = { module, module } })
  end
end

local function rep(m, n)
  local out = {}
  for i = 1, n do out[i] = m end
  return out
end

local function define_cases()
  local SPEED = first_item({ "speed-module-3", "speed-module-2", "speed-module" })
  local PROD = first_item({ "productivity-module-3", "productivity-module-2", "productivity-module" })
  local oil = prototypes.entity["crude-oil"]
  local normal = oil.normal_resource_amount
  local minimum = oil.minimum_resource_amount

  local function pumpjack(amount, modules, n_beacons)
    return function(c, cx, cy)
      c.resource = surface().create_entity({ name = "crude-oil", position = { cx, cy }, amount = amount })
      c.amount = amount
      c.entity = place("pumpjack", cx, cy, { modules = modules })
      c.kind = "fluid-out"
      if n_beacons then beacons(cx, cy, n_beacons, SPEED) end
    end
  end
  local function yield_key(amount) return string.format("%d%%", math.floor(amount / normal * 100 + 0.5)) end

  for _, amount in ipairs({ minimum, math.floor(normal / 2), normal, normal * 2, normal * 10 }) do
    cell("pumpjack " .. yield_key(amount), pumpjack(amount))
  end
  cell("pumpjack 100% speed", pumpjack(normal, rep(SPEED, 2)))
  cell("pumpjack 100% prod", pumpjack(normal, rep(PROD, 2)))
  cell("pumpjack 100% 2 beacons", pumpjack(normal, nil, 2))
  cell("pumpjack 50% prod+2 beacons", pumpjack(math.floor(normal / 2), rep(PROD, 2), 2))

  local function drill(modules, n_beacons)
    return function(c, cx, cy)
      c.ores = {}
      for x = cx - 2.5, cx + 2.5 do
        for y = cy - 2.5, cy + 2.5 do
          c.ores[#c.ores + 1] = surface().create_entity({ name = "iron-ore", position = { x, y }, amount = 10000 })
        end
      end
      c.entity = place("electric-mining-drill", cx, cy, { modules = modules })
      c.chest = place("steel-chest", c.entity.drop_position.x, c.entity.drop_position.y)
      c.kind = "drill"
      if n_beacons then beacons(cx, cy, n_beacons, SPEED) end
    end
  end
  cell("drill", drill())
  cell("drill prod", drill(rep(PROD, 3)))
  cell("drill speed+2 beacons", drill(rep(SPEED, 3), 2))

  local function crafter(machine, recipe, modules, n_beacons)
    return function(c, cx, cy)
      -- furnaces pick their recipe from the input (K2 turns them into assemblers, which don't)
      local furnace = prototypes.entity[machine].type == "furnace"
      c.entity = place(machine, cx, cy, { recipe = not furnace and recipe or nil, modules = modules })
      c.recipe = recipe
      c.kind = "crafter"
      if n_beacons then beacons(cx, cy, n_beacons, SPEED) end
    end
  end
  cell("assembler-3 gears", crafter("assembling-machine-3", "iron-gear-wheel"))
  cell("assembler-3 gears prod", crafter("assembling-machine-3", "iron-gear-wheel", rep(PROD, 4)))
  cell("assembler-3 gears speed", crafter("assembling-machine-3", "iron-gear-wheel", rep(SPEED, 4)))
  cell("assembler-3 gears prod+1 beacon", crafter("assembling-machine-3", "iron-gear-wheel", rep(PROD, 4), 1))
  cell("assembler-3 gears prod+4 beacons", crafter("assembling-machine-3", "iron-gear-wheel", rep(PROD, 4), 4))
  cell("assembler-3 gears 2+2+8 beacons", crafter("assembling-machine-3", "iron-gear-wheel",
    { PROD, PROD, SPEED, SPEED }, 8))
  cell("assembler-2 circuits prod+2 beacons", crafter("assembling-machine-2", "electronic-circuit", rep(PROD, 4), 2))
  cell("electric furnace prod+2 beacons", crafter("electric-furnace", "iron-plate", rep(PROD, 2), 2))
  cell("chemical plant plastic prod+2 beacons", crafter("chemical-plant", "plastic-bar", rep(PROD, 3), 2))
  cell("refinery advanced oil prod", crafter("oil-refinery", "advanced-oil-processing", rep(PROD, 3)))

  cell("offshore pump", function(c, cx, cy)
    tiles(math.floor(cx) - 4, math.floor(cy) + 2, math.floor(cx) + 6, math.floor(cy) + 10, "water")
    for _, y in ipairs({ cy + 1, cy + 1.5, cy + 0.5, cy + 2 }) do
      for x = cx - 3, cx + 4 do
        for _, dir in ipairs({ defines.direction.north, defines.direction.south, defines.direction.east, defines.direction.west }) do
          if not c.entity and surface().can_place_entity({ name = "offshore-pump", position = { x, y }, direction = dir,
              force = "player", build_check_type = defines.build_check_type.manual }) then
            c.entity = place("offshore-pump", x, y, { direction = dir })
          end
        end
      end
    end
    if not c.entity then error("could not place the offshore pump") end
    -- an unconnected pump has nowhere to push to: give it a pipe and drain that
    local conn = c.entity.get_fluid_box_pipe_connections(1)[1]
    c.pipe = place("pipe", conn.target_position.x, conn.target_position.y)
    c.kind = "fluid-out"
  end)
end

-- Measurement ---------------------------------------------------------------------------------------

local function record(c, key, amount, tick)
  if tick < START or tick > START + WINDOW or amount <= 0 then return end
  local m = c.out[key]
  if not m then
    -- the first output only starts the clock: rate = what came after it / time since
    c.out[key] = { first = tick, last = tick, sum = 0 }
  else
    m.sum = m.sum + amount
    m.last = tick
  end
end

local function fed(c, key, amount, tick)
  if tick < START or tick > START + WINDOW or amount <= 0 then return end
  c.inputs[key] = (c.inputs[key] or 0) + amount
end

local function drain_fluids(c, tick, outputs_only) -- crafters: output boxes only
  local e = c.entity
  for i = 1, e.fluids_count do
    local proto = e.get_fluid_box_prototype(i)
    if proto and proto.object_name == nil and proto[1] then proto = proto[1] end
    if not outputs_only or (proto and proto.production_type == "output") then
      local f = e.get_fluid(i)
      if f and f.amount > 0 then
        record(c, "fluid/" .. f.name, f.amount, tick)
        e.clear_fluid(i)
      end
    end
  end
end

local function run_case(c, tick)
  local e = c.entity
  if not (e and e.valid) then return end
  if c.resource then c.resource.amount = c.amount end -- hold the yield
  if c.kind == "fluid-out" then
    -- whole segment: an offshore pump's water isn't in its own fluid box
    if c.pipe then
      -- the pump and its pipe share one segment, so count it from the production statistics
      -- (only this pump makes water here) and just keep the pipe empty
      c.pipe.clear_fluid_inside()
      local stats = game.forces.player.get_fluid_production_statistics(SURFACE)
      if tick == START then c.stat0 = stats.get_input_count("water") end
      if tick == START + WINDOW then c.out["fluid/water"] = { first = START, last = tick, sum = stats.get_input_count("water") - c.stat0 } end
    else
      for name, amount in pairs(e.get_fluid_contents()) do record(c, "fluid/" .. name, amount, tick) end
      e.clear_fluid_inside()
    end
  elseif c.kind == "drill" then
    for _, ore in ipairs(c.ores) do
      if ore.valid then ore.amount = 10000 end
    end
    local inv = c.chest.get_inventory(defines.inventory.chest)
    for _, item in ipairs(inv.get_contents()) do record(c, "item/" .. item.name, item.count, tick) end
    inv.clear()
  elseif c.kind == "crafter" then
    local inv = e.get_inventory(defines.inventory.crafter_input)
    for _, ing in ipairs(prototypes.recipe[c.recipe].ingredients) do
      if ing.type == "item" then
        local want = math.max(ing.amount * 4, 10)
        local have = inv.get_item_count(ing.name)
        if have < want then fed(c, "item/" .. ing.name, inv.insert({ name = ing.name, count = want - have }), tick) end
      else
        fed(c, "fluid/" .. ing.name, e.insert_fluid({ name = ing.name, amount = 1000 }), tick)
      end
    end
    local out = e.get_output_inventory()
    for _, item in ipairs(out.get_contents()) do record(c, "item/" .. item.name, item.count, tick) end
    out.clear()
    drain_fluids(c, tick, true)
  end
end

local function capture(c)
  remote.call(D, "capture", P, c.area)
  local d = remote.call(D, "draft", P)
  if not d then
    c.error = "capture opened no editor"
    return
  end
  for _, line in ipairs(d.factory.lines) do
    if line.machine == c.entity.name and not line.idle then
      c.line = { flow = line.flow, speed = line.speed, productivity = line.productivity, count = line.count }
    end
  end
  if not c.line then
    local seen = {}
    for _, line in ipairs(d.factory.lines) do
      seen[#seen + 1] = string.format("%s %s %s%s", line.kind, tostring(line.recipe or line.resource), line.machine, line.idle and " idle" or "")
    end
    local inv = c.entity.get_inventory(defines.inventory.crafter_input)
    c.error = string.format("no line for %s; lines: %s; input: %s; recipe %s; status %s", c.entity.name,
      table.concat(seen, ", "), inv and serpent.line(inv.get_contents()) or "-",
      c.entity.get_recipe and tostring(c.entity.get_recipe() and c.entity.get_recipe().name) or "-", tostring(c.entity.status))
  end
  remote.call(D, "act", P, "editor_cancel", {})
  local e = c.entity
  c.info = {
    speed_bonus = e.speed_bonus, productivity_bonus = e.productivity_bonus,
    crafting_speed = (c.kind == "crafter") and e.crafting_speed or nil,
    beacons = (c.kind ~= "fluid-out" or e.type == "mining-drill") and #(e.get_beacons() or {}) or 0,
    modules = e.get_module_inventory() and #e.get_module_inventory().get_contents() > 0 and serpent.line(e.get_module_inventory().get_contents()) or "-",
  }
end

-- Report --------------------------------------------------------------------------------------------

local function report()
  local mods = {}
  for name, version in pairs(script.active_mods) do mods[#mods + 1] = name .. " " .. version end
  table.sort(mods)
  local lines = { "Stoich rate check: " .. table.concat(mods, ", "),
    string.format("window %d ticks; pass = within %g%%; rates per second per machine", WINDOW, TOLERANCE), "" }
  local fails, worst = 0, 0
  for _, c in ipairs(cases) do
    lines[#lines + 1] = "== " .. c.key
    if c.error then
      lines[#lines + 1] = "   ERROR " .. c.error
      fails = fails + 1
    else
      local i = c.info
      lines[#lines + 1] = string.format("   status %s; speed bonus %+.4f; productivity %+.4f%s; beacons %d; modules %s",
        tostring(c.status), i.speed_bonus, i.productivity_bonus,
        i.crafting_speed and string.format("; crafting speed %.4f", i.crafting_speed) or "", i.beacons, i.modules)
      lines[#lines + 1] = string.format("   stoich line: speed %s, productivity %s",
        c.line.speed and string.format("%.4f", c.line.speed) or "-",
        c.line.productivity and string.format("%+.4f", c.line.productivity) or "-")
      local keys = {}
      for k in pairs(c.line.flow) do keys[#keys + 1] = k end
      for k in pairs(c.out) do
        if not c.line.flow[k] then keys[#keys + 1] = k end
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        local want = c.line.flow[k] or 0
        local got, how
        if want >= 0 then
          local m = c.out[k]
          got = (m and m.last > m.first) and m.sum / (m.last - m.first) * 60 or 0
          how = "out"
        else
          got = -(c.inputs[k] or 0) / WINDOW * 60
          how = "in "
        end
        local diff = want ~= 0 and (got - want) / math.abs(want) * 100 or (got == 0 and 0 or 100)
        local ok = math.abs(diff) <= TOLERANCE
        -- inputs are measured by topping up buffers, so they are only a rough check
        if how == "out" then
          if not ok then fails = fails + 1 end
          if math.abs(diff) > worst then worst = math.abs(diff) end
        end
        lines[#lines + 1] = string.format("   %s %-28s stoich %10.4f  measured %10.4f  %+7.2f%% %s", how, k, want, got, diff,
          ok and "ok" or (how == "out" and "FAIL" or "(rough)"))
      end
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format("%d case(s), %d failure(s); worst output difference %.2f%%", #cases, fails, worst)
  helpers.write_file("stoich-rates/report.txt", table.concat(lines, "\n"))
  helpers.write_file("stoich-rates/done.txt", fails == 0 and "pass" or "fail")
end

-- Events --------------------------------------------------------------------------------------------

script.on_init(function()
  local s = game.create_surface(SURFACE, {
    width = COLS * CELL + 64, height = 6 * CELL + 64, default_enable_all_autoplace_controls = false,
    autoplace_settings = { entity = { treat_missing_as_default = false, settings = {} },
      decorative = { treat_missing_as_default = false, settings = {} } },
    no_enemies_mode = true,
  })
  s.always_day = true
  s.request_to_generate_chunks({ 0, 0 }, 8)
  s.force_generate_chunk_requests()
  tiles(-8, -8, COLS * CELL + 8, 6 * CELL + 8)
  game.forces.player.research_all_technologies()
  define_cases()
  for i, c in ipairs(cases) do
    c.out, c.inputs = {}, {}
    build_cell(c, i)
  end
  storage.cases = cases
  game.speed = 50
end)

script.on_load(function() cases = storage.cases or {} end)

script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index)
  player.teleport({ CELL * COLS / 2, -4 }, SURFACE)
  player.zoom = 0.3
end)

script.on_event(defines.events.on_tick, function(event)
  local tick = event.tick
  for _, c in ipairs(cases) do
    if not c.error then run_case(c, tick) end
  end
  if tick == CAPTURE then
    for _, c in ipairs(cases) do
      if not c.error then
        local ok, err = pcall(capture, c)
        if not ok then c.error = tostring(err) end
      end
    end
  elseif tick == START + WINDOW / 2 then
    for _, c in ipairs(cases) do
      if c.entity and c.entity.valid then
        for name, v in pairs(defines.entity_status) do
          if v == c.entity.status then c.status = name end
        end
      end
    end
  elseif tick == START + WINDOW + 1 then
    report()
    game.speed = 1
  end
end)
