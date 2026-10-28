local t = require("tests.t")
local belts = require("scripts.belts")

-- Krastorio 2 belt prototypes (speeds from its data stage).
local K2 = {
  { name = "transport-belt", speed = 0.03125 },
  { name = "fast-transport-belt", speed = 0.0625 },
  { name = "express-transport-belt", speed = 0.09375 },
  { name = "kr-advanced-transport-belt", speed = 0.125 },
  { name = "kr-superior-transport-belt", speed = 0.1875 },
}

t.test("belts: K2 tiers are 15/30/45/60/90 items/s", function()
  local tiers = belts.tiers_from(K2)
  t.eq(#tiers, 5)
  local expected = { 15, 30, 45, 60, 90 }
  for i, cap in ipairs(expected) do t.near(tiers[i].capacity, cap) end
  t.eq(tiers[1].name, "transport-belt")
  t.eq(tiers[5].name, "kr-superior-transport-belt")
  for _, tier in ipairs(tiers) do t.truthy(tier.color, "colour for " .. tier.name) end
end)

t.test("belts: input order does not matter and duplicates collapse", function()
  local shuffled = { K2[4], K2[1], K2[5], K2[3], K2[2], { name = "zz-other-yellow", speed = 0.03125 } }
  local tiers = belts.tiers_from(shuffled)
  t.eq(#tiers, 5)
  t.eq(tiers[1].name, "transport-belt")
end)

t.test("belts: tier lookup", function()
  local tiers = belts.tiers_from(K2)
  t.eq(belts.tier_for(0, tiers), nil)
  t.eq(belts.tier_for(10, tiers).tier.name, "transport-belt")
  t.eq(belts.tier_for(15, tiers).tier.name, "transport-belt")
  t.eq(belts.tier_for(15.01, tiers).tier.name, "fast-transport-belt")
  t.eq(belts.tier_for(-40, tiers).tier.name, "express-transport-belt")
  t.eq(belts.tier_for(89, tiers).exceeds, false)
  local over = belts.tier_for(207, tiers)
  t.eq(over.exceeds, true)
  t.near(over.belts, 2.3)
end)

t.test("belts: max tier and one lane", function()
  local tiers = belts.tiers_from(K2)
  local blue = belts.index_of(tiers, "express-transport-belt")
  local r = belts.tier_for(103.5, tiers, blue)
  t.eq(r.exceeds, true)
  t.eq(r.tier.name, "express-transport-belt")
  t.near(r.belts, 2.3)
  local lane = belts.tier_for(10, tiers, nil, true)
  t.eq(lane.tier.name, "fast-transport-belt")
end)

t.test("belts: stacking multiplies capacity", function()
  local tiers = belts.tiers_from(K2, 4)
  t.near(tiers[1].capacity, 60)
end)

t.test("belts: fluid detection by key type", function()
  t.eq(belts.is_fluid("fluid/water"), true)
  t.eq(belts.is_fluid("item/water-barrel"), false)
  t.eq(belts.is_fluid("item/fluid-wagon"), false)
  t.eq(belts.is_fluid("custom/space-data"), false)
  t.eq(belts.is_fluid("custom/steam", { ["custom/steam"] = true }), true)
end)
