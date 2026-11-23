local t = require("tests.t")
local fake = require("tests.fake_game")
local scanner = require("scripts.scanner")

local circuit = {
  name = "electronic-circuit",
  energy = 0.5,
  ingredients = { { type = "item", name = "iron-plate", amount = 1 }, { type = "item", name = "copper-cable", amount = 3 } },
  products = { { type = "item", name = "electronic-circuit", amount = 1, independent_probability = 1, shared_probability = { min = 0, max = 1 } } },
  productivity_bonus = 0,
  prototype = { maximum_productivity = 3 },
}

t.test("scanner: product amount with 2.1 probabilities", function()
  t.near(scanner.product_amount({ amount = 2 }), 2)
  t.near(scanner.product_amount({ amount_min = 1, amount_max = 4 }), 2.5)
  t.near(scanner.product_amount({ amount = 1, independent_probability = 0.007, shared_probability = { min = 0, max = 1 } }), 0.007)
  t.near(scanner.product_amount({ amount = 1, independent_probability = 1, shared_probability = { min = 0.2, max = 0.5 } }), 0.3)
  t.near(scanner.product_amount({ amount = 1, probability = 0.5 }), 0.5) -- 2.0 field
  t.near(scanner.product_amount({ amount = 1, extra_count_fraction = 0.25 }), 1.25)
end)

t.test("scanner: assembler with modules", function()
  -- crafting_speed already includes modules and beacons; productivity +8%
  local flow = scanner.recipe_flow(circuit.ingredients, circuit.products, 0.6375 / 0.5, 0.08)
  t.near(flow["item/iron-plate"], -1.275)
  t.near(flow["item/copper-cable"], -3.825)
  t.near(flow["item/electronic-circuit"], 1.275 * 1.08)
end)

t.test("scanner: productivity skips the ignored part (kovarex)", function()
  local ingredients = { { type = "item", name = "uranium-235", amount = 40 }, { type = "item", name = "uranium-238", amount = 5 } }
  local products = {
    { type = "item", name = "uranium-235", amount = 41, ignored_by_productivity = 40 },
    { type = "item", name = "uranium-238", amount = 2, ignored_by_productivity = 2 },
  }
  local flow = scanner.recipe_flow(ingredients, products, 1, 0.1)
  t.near(flow["item/uranium-235"], 1.1) -- 41.1 out - 40 in
  t.near(flow["item/uranium-238"], -3)
end)

t.test("scanner: furnace smelting", function()
  local flow = scanner.recipe_flow({ { type = "item", name = "iron-ore", amount = 1 } }, { { type = "item", name = "iron-plate", amount = 1 } }, 2 / 3.2, 0)
  t.near(flow["item/iron-ore"], -0.625)
  t.near(flow["item/iron-plate"], 0.625)
end)

t.test("scanner: solid resource drill with mining research", function()
  local res = { { products = { { type = "item", name = "iron-ore", amount = 1 } }, mining_time = 1, share = 1 } }
  local flow = scanner.mining_flow(res, 0.5, 0.1)
  t.near(flow["item/iron-ore"], 0.55)
end)

t.test("scanner: uranium drill uses acid per ten cycles, no productivity on it", function()
  local res = { { products = { { type = "item", name = "uranium-ore", amount = 1 } }, mining_time = 2, required_fluid = "sulfuric-acid", fluid_amount = 10, share = 1 } }
  local flow = scanner.mining_flow(res, 0.5, 0.2)
  t.near(flow["item/uranium-ore"], 0.25 * 1.2)
  t.near(flow["fluid/sulfuric-acid"], -0.25)
end)

t.test("scanner: drill over mixed ores splits by tiles", function()
  local res = {
    { products = { { type = "item", name = "iron-ore", amount = 1 } }, mining_time = 1, share = 0.75 },
    { products = { { type = "item", name = "copper-ore", amount = 1 } }, mining_time = 1, share = 0.25 },
  }
  local flow = scanner.mining_flow(res, 0.5, 0)
  t.near(flow["item/iron-ore"], 0.375)
  t.near(flow["item/copper-ore"], 0.125)
end)

t.test("scanner: offshore pump", function()
  local flow = scanner.pump_flow("water", 20)
  t.near(flow["fluid/water"], 1200)
end)

t.test("scanner: grouping averages different module setups", function()
  local lines = scanner.group({
    { kind = "recipe", recipe = "electronic-circuit", machine = "assembling-machine-2", flow = { ["item/electronic-circuit"] = 1 } },
    { kind = "recipe", recipe = "electronic-circuit", machine = "assembling-machine-2", flow = { ["item/electronic-circuit"] = 2 } },
    { kind = "recipe", recipe = "electronic-circuit", machine = "assembling-machine-3", flow = { ["item/electronic-circuit"] = 5 } },
    { kind = "recipe", machine = "assembling-machine-2", idle = true },
  })
  t.eq(#lines, 3)
  t.eq(lines[1].machine, "assembling-machine-2")
  t.eq(lines[1].count, 2)
  t.near(lines[1].flow["item/electronic-circuit"], 1.5)
  t.eq(lines[2].count, 1)
  t.eq(lines[3].idle, true)
end)

-- Fake LuaEntity objects -------------------------------------------------------------------

local function recipe(proto) return proto end

local function crafter(type, name, speed, prod, r, prev)
  return {
    valid = true, type = type, name = name, crafting_speed = speed, productivity_bonus = prod,
    get_recipe = function() return r end,
    previous_recipe = prev,
  }
end

t.test("scanner: scan_entities with fake entities", function()
  fake.reset()
  local force = { recipes = { ["iron-plate"] = recipe({
    name = "iron-plate", energy = 3.2,
    ingredients = { { type = "item", name = "iron-ore", amount = 1 } },
    products = { { type = "item", name = "iron-plate", amount = 1 } },
    productivity_bonus = 0.1, prototype = { maximum_productivity = 3 },
  }) } }
  local entities = {
    crafter("assembling-machine", "assembling-machine-2", 0.75, 0, circuit),
    crafter("assembling-machine", "assembling-machine-2", 1.25, 0, circuit),
    crafter("furnace", "stone-furnace", 1, 0, nil, { name = { name = "iron-plate" }, quality = "normal" }),
    crafter("assembling-machine", "assembling-machine-2", 0.75, 0, nil),
    { valid = true, type = "boiler", name = "boiler", burner = { currently_burning = { name = { name = "coal" } } }, fluids_count = 2 },
    { valid = false, type = "furnace" },
  }
  local scan = scanner.scan_entities(entities, force)
  t.eq(scan.production, 4)
  t.eq(scan.idle, 1)
  t.truthy(scan.generators["item/coal"])
  t.eq(#scan.lines, 3)
  local circuits, furnace
  for _, line in ipairs(scan.lines) do
    if line.recipe == "electronic-circuit" then circuits = line end
    if line.recipe == "iron-plate" then furnace = line end
  end
  t.eq(circuits.count, 2)
  t.near(circuits.flow["item/electronic-circuit"], 2) -- (1.5 + 2.5) / 2 crafts per second
  t.near(furnace.flow["item/iron-plate"], 1 / 3.2 * 1.1) -- research productivity from the force recipe
end)

t.test("scanner: main product", function()
  local lines = {
    { count = 2, flow = { ["item/a"] = 1, ["item/b"] = -1 } },
    { count = 1, flow = { ["item/b"] = 3, ["item/c"] = 0.5 } },
  }
  t.eq(scanner.main_product(lines), "item/a")
end)

t.test("scanner: main product prefers what nothing inside consumes", function()
  -- six cable assemblers overproduce cable, but circuits are the build's output
  local lines = {
    { count = 6, flow = { ["item/copper-plate"] = -1.5, ["item/copper-cable"] = 3 } },
    { count = 4, flow = { ["item/copper-cable"] = -1.6, ["item/electronic-circuit"] = 0.8 } },
  }
  t.eq(scanner.main_product(lines), "item/electronic-circuit")
end)

-- Lines keep their inputs ------------------------------------------------------------------

t.test("scanner: a captured line keeps its machine values and works out again to the same flow", function()
  fake.reset()
  prototypes.recipe["electronic-circuit"] = circuit
  local r = { name = "electronic-circuit", energy = 0.5, ingredients = circuit.ingredients, products = circuit.products,
    productivity_bonus = 0.1, prototype = { maximum_productivity = 3 } }
  local force = { recipes = { ["electronic-circuit"] = r }, mining_drill_productivity_bonus = 0 }
  local entities = {
    crafter("assembling-machine", "assembling-machine-2", 0.75, 0, r),
    crafter("assembling-machine", "assembling-machine-2", 0.75, 0, r),
    crafter("assembling-machine", "assembling-machine-2", 1.25, 0.08, r), -- other modules
  }
  local line = scanner.scan_entities(entities, force).lines[1]
  t.eq(#line.variants, 2, "two sets of machine values")
  local n = 0
  for _, v in ipairs(line.variants) do n = n + v.n end
  t.eq(n, 3)
  t.truthy(scanner.has_inputs(line))
  t.map_near(scanner.line_flow(line, force), line.flow, 1e-12, "unchanged force")
  t.truthy(not scanner.flows_differ(scanner.line_flow(line, force), line.flow))
  -- research: +10% more productivity on the recipe
  r.productivity_bonus = 0.2
  local after = scanner.line_flow(line, force)
  t.truthy(scanner.flows_differ(after, line.flow))
  t.near(after["item/electronic-circuit"], (2 * 1.5 * 1.2 + 2.5 * 1.28) / 3, 1e-9)
  t.near(after["item/iron-plate"], line.flow["item/iron-plate"], 1e-12, "inputs stay")
  -- overridden, custom and old lines are never worked out again
  line.overridden = true
  t.eq(scanner.line_flow(line, force), nil)
  t.eq(scanner.has_inputs({ kind = "recipe", recipe = "electronic-circuit", flow = {} }), false, "captured before 0.5")
end)

t.test("scanner: a drill line follows mining research; its fluid doesn't take productivity", function()
  fake.reset()
  prototypes.entity["electric-mining-drill"] = { name = "electric-mining-drill", uses_force_mining_productivity_bonus = true }
  local res = { { products = { { type = "item", name = "uranium-ore", amount = 1 } }, mining_time = 2, required_fluid = "sulfuric-acid", fluid_amount = 10, share = 1 } }
  local function entry(own)
    -- productivity_bonus of the entity includes the research (0.2)
    return { kind = "mining", resource = "uranium-ore", machine = "electric-mining-drill", flow = scanner.mining_flow(res, 0.5, own + 0.2),
      own_productivity = own, base = scanner.mining_flow(res, 0.5, 0), speed = 0.5 }
  end
  local line = scanner.group({ entry(0), entry(0), entry(0.1) })[1]
  t.eq(#line.variants, 2)
  local force = { mining_drill_productivity_bonus = 0.2 }
  t.map_near(scanner.line_flow(line, force), line.flow, 1e-12)
  force.mining_drill_productivity_bonus = 0.5
  local after = scanner.line_flow(line, force)
  t.near(after["item/uranium-ore"], 0.25 * (2 * 1.5 + 1.6) / 3, 1e-12)
  t.near(after["fluid/sulfuric-acid"], -0.25, 1e-12)
end)

-- Quality -------------------------------------------------------------------------------------

local TIERS = {
  normal = { next = "uncommon", next_probability = 1, chain_probability = 0.1 },
  uncommon = { next = "rare", next_probability = 1, chain_probability = 0.1 },
  rare = { next = "epic", next_probability = 1, chain_probability = 0.1 },
  epic = { next = "legendary", next_probability = 1, chain_probability = 0.1 },
  legendary = { next_probability = 0, chain_probability = 0 },
}

t.test("scanner: quality rolls as the game's get_roll_chances (2.1)", function()
  -- measured in the game: normal at 10%
  t.map_near(scanner.quality_split(TIERS, "normal", 0.1), { normal = 0.9, uncommon = 0.09, rare = 0.009, epic = 0.0009, legendary = 0.0001 }, 1e-12)
  t.map_near(scanner.quality_split(TIERS, "rare", 0.1), { rare = 0.9, epic = 0.09, legendary = 0.01 }, 1e-12)
  -- the last tier takes the rest
  t.map_near(scanner.quality_split(TIERS, "legendary", 0.5), { legendary = 1 })
  -- rolls stop at the first locked tier
  local unlocked = { normal = true, uncommon = true, rare = true }
  t.map_near(scanner.quality_split(TIERS, "normal", 0.1, unlocked), { normal = 0.9, uncommon = 0.09, rare = 0.01 }, 1e-12)
  t.map_near(scanner.quality_split(TIERS, "rare", 0.1, unlocked), { rare = 1 })
  t.map_near(scanner.quality_split(TIERS, "normal", 0.1, { normal = true, uncommon = true, legendary = true }), { normal = 0.9, uncommon = 0.1 }, 1e-12)
  -- no chance, all the chance, more than all of it (the overflow carries into the second step)
  t.map_near(scanner.quality_split(TIERS, "normal", 0), { normal = 1 })
  t.map_near(scanner.quality_split(TIERS, "normal", 1), { uncommon = 0.9, rare = 0.09, epic = 0.009, legendary = 0.001 }, 1e-12)
  t.map_near(scanner.quality_split(TIERS, "normal", 1.5), { uncommon = 0.85, rare = 0.135, epic = 0.0135, legendary = 0.0015 }, 1e-12)
end)

local function rolls(chance)
  return function(base) return scanner.quality_split(TIERS, base, chance) end
end

t.test("scanner: a crafter with quality: ingredients at its tier, fluids plain, productivity before the roll", function()
  local ingredients = { { type = "item", name = "iron-plate", amount = 2 }, { type = "fluid", name = "water", amount = 10 } }
  local products = { { type = "item", name = "gear", amount = 1 }, { type = "fluid", name = "steam", amount = 5 } }
  local flow = scanner.recipe_flow(ingredients, products, 1, 0.5, { quality = "rare", rolls = rolls(0.1) })
  t.map_near(flow, {
    ["item/iron-plate|rare"] = -2, ["fluid/water"] = -10, ["fluid/steam"] = 5 * 1.5,
    ["item/gear|rare"] = 1.5 * 0.9, ["item/gear|epic"] = 1.5 * 0.09, ["item/gear|legendary"] = 1.5 * 0.01,
  }, 1e-12)
  -- a tier of its own for an ingredient or product (2.1 quality_change), and a product the roll skips
  products[1].affected_by_quality = false
  flow = scanner.recipe_flow(ingredients, products, 1, 0, { quality = "rare", rolls = rolls(0.1), ingredient_quality = { [1] = "uncommon" } })
  t.near(flow["item/iron-plate|uncommon"], -2)
  t.near(flow["item/gear|rare"], 1)
  -- no quality table: exactly as before
  flow = scanner.recipe_flow(ingredients, { { type = "item", name = "gear", amount = 1 } }, 1, 0)
  t.map_near(flow, { ["item/iron-plate"] = -2, ["fluid/water"] = -10, ["item/gear"] = 1 })
end)

t.test("scanner: drills start normal and roll", function()
  local res = { { products = { { type = "item", name = "iron-ore", amount = 1 } }, mining_time = 1, share = 1 } }
  local flow = scanner.mining_flow(res, 0.5, 0.2, rolls(0.1))
  t.near(flow["item/iron-ore"], 0.6 * 0.9)
  t.near(flow["item/iron-ore|uncommon"], 0.6 * 0.09)
end)

t.test("scanner: an upcycling loop of crafters and recyclers balances", function()
  local solver = require("scripts.solver")
  -- gears from plates in rare... simplified: an assembler makes gears from plates at each
  -- tier with 10% quality; a recycler gives back a quarter of the plates at each tier, rolled
  local lines, id = {}, 0
  local tiers = { "normal", "uncommon", "rare", "epic" }
  local fp_util = require("scripts.util")
  for _, q in ipairs(tiers) do
    id = id + 1
    lines[#lines + 1] = { id = id, flow = scanner.recipe_flow({ { type = "item", name = "plate", amount = 2 } },
      { { type = "item", name = "gear", amount = 1 } }, 1, 0, { quality = q, rolls = rolls(0.1) }) }
    id = id + 1
    lines[#lines + 1] = { id = id, flow = scanner.recipe_flow({ { type = "item", name = "gear", amount = 1 } },
      { { type = "item", name = "plate", amount = 0.5 } }, 1, 0, { quality = q, rolls = rolls(0.1) }) }
  end
  -- plates come in at normal; legendary gears and plates go out
  id = id + 1
  lines[#lines + 1] = { id = id, flow = { ["item/plate"] = 1 } }
  local external = { ["item/gear|legendary"] = true, ["item/plate|legendary"] = true }
  local r = solver.balance(lines, { [id] = 10 }, {}, external)
  t.eq(r.status, "EXACT")
  for k, c in pairs(r.counts) do t.truthy(c > -1e-9, "count " .. k .. " >= 0") end
  t.truthy((r.net["item/gear|legendary"] or 0) > 0, "legendary gears out")
  t.eq(fp_util.base_key("item/gear|legendary"), "item/gear")
end)

t.test("scanner: group keys gain tiers only when not normal", function()
  t.eq(scanner.group_key("recipe", "gear", "am2"), "recipe|gear|am2")
  t.eq(scanner.group_key("recipe", "gear", "am2", nil, nil), "recipe|gear|am2")
  t.eq(scanner.group_key("recipe", "gear", "am2", "rare", nil), "recipe|gear|am2|rare|")
  t.eq(scanner.group_key("recipe", "gear", "am2", nil, "epic"), "recipe|gear|am2||epic")
  local lines = scanner.group({
    { kind = "recipe", recipe = "gear", machine = "am2", flow = { ["item/gear"] = 1 } },
    { kind = "recipe", recipe = "gear", machine = "am2", recipe_quality = "rare", flow = { ["item/gear|rare"] = 1 } },
  })
  t.eq(#lines, 2, "a rare recipe is a line of its own")
  t.eq(lines[1].key, "recipe|gear|am2")
  t.eq(lines[2].recipe_quality, "rare")
end)

t.test("scanner: the main product is the highest tier the build sends out", function()
  local lines = {
    { count = 1, flow = { ["item/plate"] = -1, ["item/gear"] = 0.9, ["item/gear|uncommon"] = 0.09, ["item/gear|legendary"] = 0.001 } },
    { count = 1, flow = { ["item/copper"] = 0.5 } },
  }
  t.eq(scanner.main_product(lines), "item/gear|legendary")
end)
