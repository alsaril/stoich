-- Test world for Stoich (Krastorio 2): a grid of labelled zones to
-- capture. Builds on a clean lab surface, researches everything, then
-- auto-saves once as "_autosave-stoich-test" so the save can be loaded directly.

local SURFACE = "stoich-lab"
local COLS, ZW, ZH, GAP = 4, 46, 30, 8

local function surface() return game.surfaces[SURFACE] end

local function set_tiles(l, t, r, b, name)
  local tiles = {}
  for x = l, r - 1 do
    for y = t, b - 1 do
      tiles[#tiles + 1] = { name = name or (((x + y) % 2 == 0) and "lab-dark-1" or "lab-dark-2"), position = { x, y } }
    end
  end
  surface().set_tiles(tiles)
end

local function place(name, x, y, opts)
  opts = opts or {}
  if not prototypes.entity[name] then
    log("stoich-test: missing entity " .. name)
    return nil
  end
  local params = { name = name, position = { x, y }, force = "player", direction = opts.direction, raise_built = true }
  if opts.recipe then
    if not prototypes.recipe[opts.recipe] then
      log("stoich-test: missing recipe " .. opts.recipe)
      return nil
    end
    params.recipe = opts.recipe
  end
  local e = surface().create_entity(params)
  if not e then log("stoich-test: could not place " .. name .. " at " .. x .. "," .. y) end
  if e and opts.modules then
    local inv = e.get_module_inventory()
    for _, m in ipairs(opts.modules) do
      if prototypes.item[m] then inv.insert({ name = m, count = 1 }) end
    end
  end
  if e and opts.fuel and e.get_inventory(defines.inventory.fuel) then
    e.get_inventory(defines.inventory.fuel).insert({ name = opts.fuel, count = 50 })
  end
  return e
end

local zones, order = {}, {}

--- Next zone in the grid: draws its frame and title, returns its top-left corner.
local function zone(key, title)
  local i = #order
  local col, row = i % COLS, math.floor(i / COLS)
  local l, t = col * (ZW + GAP), row * (ZH + GAP)
  local r, b = l + ZW, t + ZH
  zones[key] = { title = title, area = { left_top = { x = l, y = t }, right_bottom = { x = r, y = b } } }
  order[#order + 1] = key
  rendering.draw_rectangle({ color = { r = 0.3, g = 0.75, b = 1, a = 0.8 }, width = 4, filled = false,
    left_top = { l, t }, right_bottom = { r, b }, surface = surface(), draw_on_ground = true })
  rendering.draw_text({ text = title, surface = surface(), target = { (l + r) / 2, t - 2.5 }, color = { r = 1, g = 1, b = 1 },
    scale = 2.5, alignment = "center" })
  return l, t
end

--- A row of machines starting at (x, y).
local function row(name, recipe, count, x, y, step, opts)
  local out = {}
  for i = 0, count - 1 do
    local o = { recipe = recipe }
    for k, v in pairs(opts or {}) do o[k] = v end
    out[#out + 1] = place(name, x + i * step, y, o)
  end
  return out
end

local function ore_patch(resource, l, t, r, b, amount)
  for x = l, r - 1 do
    for y = t, b - 1 do surface().create_entity({ name = resource, position = { x + 0.5, y + 0.5 }, amount = amount }) end
  end
end

local function mine(key, title, resource, drills)
  local l, t = zone(key, title)
  ore_patch(resource, l + 3, t + 3, l + 3 + 7 * math.min(drills, 5), t + 18, 5000)
  for i = 0, drills - 1 do
    place("electric-mining-drill", l + 5.5 + (i % 5) * 7, t + 6.5 + math.floor(i / 5) * 7)
  end
end

local function build()
  local s = game.create_surface(SURFACE, {
    width = 600, height = 400,
    default_enable_all_autoplace_controls = false,
    autoplace_settings = {
      entity = { treat_missing_as_default = false, settings = {} },
      decorative = { treat_missing_as_default = false, settings = {} },
    },
    no_enemies_mode = true,
  })
  s.always_day = true
  s.request_to_generate_chunks({ 80, 80 }, 10)
  s.force_generate_chunk_requests()
  set_tiles(-20, -20, COLS * (ZW + GAP) + 10, 6 * (ZH + GAP) + 10)
  game.forces.player.research_all_technologies()

  local l, t

  -- Green circuits: one assembler with productivity modules, one with speed modules, two idle
  l, t = zone("circuits", "Green circuits (K2)")
  row("assembling-machine-2", "copper-cable", 6, l + 4, t + 5, 4)
  local c = row("assembling-machine-2", "electronic-circuit", 4, l + 4, t + 11, 4)
  if c[1] then c[1].get_module_inventory().insert({ name = "productivity-module", count = 2 }) end
  if c[2] then c[2].get_module_inventory().insert({ name = "speed-module", count = 2 }) end
  row("assembling-machine-2", nil, 2, l + 4, t + 17, 4)

  -- Red circuits: a long chain with mixed machine tiers (many lines in the editor)
  l, t = zone("red", "Red circuits (long chain)")
  row("assembling-machine-2", "copper-cable", 4, l + 4, t + 4, 4)
  row("assembling-machine-3", "copper-cable", 2, l + 20, t + 4, 4)
  row("assembling-machine-2", "electronic-circuit", 3, l + 30, t + 4, 4)
  row("assembling-machine-3", "electronic-circuit", 2, l + 4, t + 9, 4)
  row("assembling-machine-2", "advanced-circuit", 3, l + 13, t + 9, 4)
  row("assembling-machine-3", "advanced-circuit", 2, l + 26, t + 9, 4)
  row("assembling-machine-2", "kr-electronic-components", 3, l + 4, t + 14, 4)
  row("stone-furnace", "kr-glass", 3, l + 17, t + 14, 3, { fuel = "coal" })
  row("steel-furnace", "kr-glass", 2, l + 28, t + 14, 3, { fuel = "coal" })
  row("steel-furnace", "kr-silicon", 3, l + 4, t + 19, 3, { fuel = "coal" })
  row("chemical-plant", "plastic-bar", 2, l + 15, t + 19, 4)
  row("assembling-machine-2", nil, 1, l + 26, t + 19, 4)

  -- Oil with three recipes making heavy oil, crackers and plastic
  l, t = zone("oil", "Oil: processing + coal/coke liquefaction")
  row("oil-refinery", "advanced-oil-processing", 6, l + 4, t + 5, 6)
  row("oil-refinery", "coal-liquefaction", 2, l + 4, t + 11, 6)
  row("oil-refinery", "kr-coke-liquefaction", 1, l + 16, t + 11, 6)
  row("chemical-plant", "heavy-oil-cracking", 3, l + 24, t + 11, 4)
  row("chemical-plant", "light-oil-cracking", 7, l + 4, t + 17, 4)
  row("chemical-plant", "plastic-bar", 8, l + 4, t + 22, 4)

  -- Batteries: sulfur, sulfuric acid, batteries
  l, t = zone("battery", "Batteries")
  row("chemical-plant", "sulfur", 3, l + 4, t + 5, 4)
  row("chemical-plant", "sulfuric-acid", 2, l + 4, t + 11, 4)
  row("chemical-plant", "battery", 5, l + 4, t + 17, 4)

  -- Smelting columns; iron also in a second design with steel furnaces
  l, t = zone("iron", "Iron smelting (stone furnaces)")
  row("stone-furnace", "iron-plate", 12, l + 3, t + 6, 3, { fuel = "coal" })
  place("kr-crusher", l + 6, t + 14)
  l, t = zone("iron2", "Iron smelting (steel furnaces)")
  row("steel-furnace", "iron-plate", 8, l + 3, t + 6, 3, { fuel = "coal" })
  l, t = zone("copper", "Copper smelting")
  row("stone-furnace", "copper-plate", 10, l + 3, t + 6, 3, { fuel = "coal" })
  l, t = zone("steel", "Steel")
  row("steel-furnace", "steel-plate", 8, l + 3, t + 6, 3, { fuel = "coal" })
  l, t = zone("brick", "Stone bricks")
  row("stone-furnace", "stone-brick", 6, l + 3, t + 6, 3, { fuel = "coal" })

  -- Intermediates
  l, t = zone("gears", "Gears")
  row("assembling-machine-2", "iron-gear-wheel", 5, l + 4, t + 6, 4)
  l, t = zone("belts", "Transport belts")
  row("assembling-machine-2", "iron-gear-wheel", 2, l + 4, t + 6, 4)
  row("assembling-machine-2", "transport-belt", 3, l + 4, t + 12, 4)
  l, t = zone("engines", "Engines")
  row("assembling-machine-2", "iron-gear-wheel", 2, l + 4, t + 5, 4)
  row("assembling-machine-2", "pipe", 2, l + 16, t + 5, 4)
  row("assembling-machine-3", "engine-unit", 6, l + 4, t + 12, 4)

  -- Raw resources: two separate iron mines (the plan needs a split between them)
  mine("mine_iron", "Iron ore mine (west)", "iron-ore", 6)
  mine("mine_iron2", "Iron ore mine (east)", "iron-ore", 4)
  mine("mine_copper", "Copper ore mine", "copper-ore", 6)
  mine("mine_stone", "Stone quarry", "stone", 3)
  mine("mine_coal", "Coal mine", "coal", 4)

  -- Pumpjacks on crude oil (one at 200%, one at 50%)
  l, t = zone("pumpjacks", "Pumpjacks (crude oil)")
  local normal = prototypes.entity["crude-oil"] and prototypes.entity["crude-oil"].normal_resource_amount or 300000
  s.create_entity({ name = "crude-oil", position = { l + 10.5, t + 10.5 }, amount = normal * 2 })
  s.create_entity({ name = "crude-oil", position = { l + 20.5, t + 10.5 }, amount = math.floor(normal / 2) })
  place("pumpjack", l + 10.5, t + 10.5)
  place("pumpjack", l + 20.5, t + 10.5)

  -- Offshore pump at a small lake, placed like a player would
  l, t = zone("pump", "Offshore pump")
  set_tiles(l + 4, t + 14, l + 30, t + 26, "water")
  local placed = false
  for _, y in ipairs({ t + 13.5, t + 13, t + 12.5, t + 14 }) do
    for x = l + 5, l + 28 do
      for _, dir in ipairs({ defines.direction.north, defines.direction.south, defines.direction.east, defines.direction.west }) do
        if not placed and s.can_place_entity({ name = "offshore-pump", position = { x + 0.5, y }, direction = dir, force = "player",
            build_check_type = defines.build_check_type.manual }) then
          placed = place("offshore-pump", x + 0.5, y, { direction = dir }) ~= nil
        end
      end
    end
  end
  if not placed then log("stoich-test: could not place the offshore pump") end

  -- Boilers only: capturing them offers "make a sink" with their fuel
  l, t = zone("boilers", "Boilers only (makes a sink)")
  for i = 0, 2 do
    local b = place("boiler", l + 8 + i * 8, t + 12)
    if b and b.burner then b.burner.inventory.insert({ name = "coal", count = 20 }) end
  end

  rendering.draw_text({
    text = "Ctrl+Alt+C: capture tool  -  Ctrl+Alt+P: planner window", surface = s, target = { 100, -12 },
    color = { r = 1, g = 0.9, b = 0.5 }, scale = 2, alignment = "center",
  })
  storage.zones = zones
  storage.zone_order = order
end

script.on_init(function()
  build()
  storage.save_at = 180
end)

script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index)
  if player.character then
    player.character.teleport({ 100, -6 }, SURFACE)
  else
    player.teleport({ 100, -6 }, SURFACE)
  end
  player.zoom = 0.4
end)

script.on_event(defines.events.on_tick, function(event)
  if storage.save_at and event.tick >= storage.save_at then
    storage.save_at = nil
    game.auto_save("stoich-test")
    helpers.write_file("stoich-test-saved.txt", tostring(event.tick))
  end
end)

remote.add_interface("stoich-test-world", {
  zones = function() return storage.zones end,
  zone_order = function() return storage.zone_order end,
})
