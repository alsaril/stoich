-- Module and beacon effects of hand-added recipe lines, against the mock's prototypes
-- (the game's own module, beacon and recycler values).

local t = require("tests.t")
local mock = require("tests.mock_runtime")

local function setup()
  mock.reset()
  return require("scripts.modules")
end

t.test("modules: what fits where (only bonuses need to be allowed)", function()
  local modules = setup()
  local am2, recycler, beacon = prototypes.entity["assembling-machine-2"], prototypes.entity["recycler"], prototypes.entity["beacon"]
  local cable, recycling = prototypes.recipe["copper-cable"], prototypes.recipe["copper-cable-recycling"]
  t.eq(table.concat(modules.for_machine(am2, cable), ","), "productivity-module,quality-module,speed-module")
  -- the recycler takes no productivity
  t.eq(table.concat(modules.for_machine(recycler, recycling), ","), "quality-module,speed-module")
  -- a beacon takes speed modules despite their quality malus, but no quality or productivity
  t.eq(table.concat(modules.for_beacon(beacon, recycler, recycling), ","), "speed-module")
  t.eq(modules.slots(recycler), 4)
  t.eq(table.concat(modules.beacons(am2), ","), "beacon")
  t.eq(modules.slots({ module_inventory_size = 4, effect_receiver = { uses_module_effects = false } }), 0)
end)

t.test("modules: speed and productivity from slots and beacons, within the limits", function()
  local modules = setup()
  local am2, cable = prototypes.entity["assembling-machine-2"], prototypes.recipe["copper-cable"]
  local e = modules.effect(am2, cable, { modules = { "speed-module", "speed-module" } })
  t.near(e.speed, 0.4)
  t.near(e.productivity, 0)
  e = modules.effect(am2, cable, { modules = { "productivity-module", "productivity-module" } })
  t.near(e.speed, -0.1)
  t.near(e.productivity, 0.08)
  -- 4 beacons with 2 speed modules each: 4 × 1.5 effectivity × 0.5 (profile for 4) × 0.4
  e = modules.effect(am2, cable, { modules = {}, beacon = "beacon", beacon_count = 4, beacon_modules = { "speed-module", "speed-module" } })
  t.near(e.speed, 1.2)
  -- past the end of the profile its last entry counts
  e = modules.effect(am2, cable, { modules = {}, beacon = "beacon", beacon_count = 6, beacon_modules = { "speed-module" } })
  t.near(e.speed, 6 * 1.5 * 0.5 * 0.2)
  -- a slot left empty in the middle, and more modules than slots
  e = modules.effect(am2, cable, { modules = { [2] = "speed-module", [3] = "speed-module" } })
  t.near(e.speed, 0.2)
  -- the machine's limits and its own bonus
  local tight = { module_inventory_size = 4, effect_receiver = { base_effect = { productivity = 0.5 }, speed_limits = { low = -0.1, high = 1 } } }
  e = modules.effect(tight, cable, { modules = { "productivity-module", "productivity-module", "productivity-module", "productivity-module" } })
  t.near(e.speed, -0.1, nil, "clamped")
  t.near(e.productivity, 0.66)
end)
