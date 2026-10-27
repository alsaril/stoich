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
