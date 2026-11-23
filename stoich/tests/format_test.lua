-- Number parsing and formatting (util.lua): what the player types and reads.

local t = require("tests.t")
local fp_util = require("scripts.util")

t.test("format: typed numbers, with ',' as decimal mark and k / M suffixes", function()
  t.eq(fp_util.parse_number("12"), 12)
  t.eq(fp_util.parse_number(" 1,5 "), 1.5)
  t.eq(fp_util.parse_number("-2.25"), -2.25)
  t.eq(fp_util.parse_number(".5"), 0.5)
  t.eq(fp_util.parse_number("3."), 3)
  t.eq(fp_util.parse_number("2k"), 2000)
  t.eq(fp_util.parse_number("1.5M"), 1500000)
  t.eq(fp_util.parse_number(""), nil)
  t.eq(fp_util.parse_number("abc"), nil)
  t.eq(fp_util.parse_number("1e5"), nil, "no exponents")
  t.eq(fp_util.parse_number(nil), nil)
end)

t.test("format: counts keep 2 decimals (or the asked number), trailing zeros trimmed", function()
  t.eq(fp_util.format_count(nil), "?")
  t.eq(fp_util.format_count(0.004), "0")
  t.eq(fp_util.format_count(-0.004), "0")
  t.eq(fp_util.format_count(2), "2")
  t.eq(fp_util.format_count(2.5), "2.5")
  t.eq(fp_util.format_count(2.456), "2.46")
  t.eq(fp_util.format_count(1.47, 1), "1.5")
  t.eq(fp_util.format_count(0.0625, 1), "0.1")
  t.eq(fp_util.format_count(2.04, 1), "2")
end)

t.test("format: rates with k / M / G and the unit suffix", function()
  t.eq(fp_util.format_number(0.001), "1m")
  t.eq(fp_util.format_number(0), "0")
  t.eq(fp_util.format_number(12.345), "12.35")
  t.eq(fp_util.format_number(123.45), "123.5") -- one decimal from 100
  t.eq(fp_util.format_number(12345), "12.3k")
  t.eq(fp_util.format_number(2500000), "2.5M")
  t.eq(fp_util.format_number(3e9), "3G")
  t.eq(fp_util.format_rate(1, "min"), "60")
  t.eq(fp_util.format_rate(1, "s", true), "1/s")
  t.eq(fp_util.format_rate(0.5, "h", true), "1800/h") -- "k" only from 10 000
end)

t.test("format: item keys", function()
  t.eq(fp_util.key("item", "iron-plate"), "item/iron-plate")
  local kind, name = fp_util.parse_key("fluid/water")
  t.eq(kind, "fluid")
  t.eq(name, "water")
  kind, name = fp_util.parse_key("space data")
  t.eq(kind, "custom", "a key without a type is a custom name")
  t.eq(name, "space data")
  t.eq(fp_util.key_from_signal({ type = "virtual", name = "signal-A" }), "custom/signal-A")
  t.eq(fp_util.signal_from_key("custom/x"), nil)
  t.eq(fp_util.signal_from_key("item/coal").name, "coal")
end)

-- Item keys with quality ---------------------------------------------------------------------

local json = require("tests.json")

t.test("keys: normal keys stay as they were; other tiers get a suffix", function()
  t.eq(fp_util.key("item", "iron-plate"), "item/iron-plate")
  t.eq(fp_util.key("item", "iron-plate", "normal"), "item/iron-plate")
  t.eq(fp_util.key("item", "iron-plate", "rare"), "item/iron-plate|rare")
  t.eq(fp_util.key("fluid", "water", "rare"), "fluid/water", "fluids never carry quality")
  t.eq(fp_util.key("custom", "x", "rare"), "custom/x")
  local ty, n, q = fp_util.parse_key("item/iron-plate|rare")
  t.eq(ty, "item") t.eq(n, "iron-plate") t.eq(q, "rare")
  ty, n, q = fp_util.parse_key("item/iron-plate")
  t.eq(n, "iron-plate") t.eq(q, "normal")
  ty, n, q = fp_util.parse_key("custom/a|b")
  t.eq(ty, "custom") t.eq(n, "a|b", "a custom label keeps its text") t.eq(q, "normal")
  for _, key in ipairs({ "item/iron-plate", "item/iron-plate|legendary", "fluid/water", "custom/space data" }) do
    t.eq(fp_util.key(fp_util.parse_key(key)), key, "round trip " .. key)
  end
  t.eq(fp_util.base_key("item/gear|epic"), "item/gear")
  t.eq(fp_util.with_quality("item/gear", "epic"), "item/gear|epic")
  t.eq(fp_util.with_quality("item/gear|epic", "normal"), "item/gear")
  t.eq(fp_util.quality_of("item/gear|uncommon"), "uncommon")
  t.eq(fp_util.rich("item/gear|rare"), "[item=gear,quality=rare]")
  t.eq(fp_util.rich("item/gear"), "[item=gear]")
  t.eq(fp_util.sprite("item/gear|rare"), "item/gear")
  t.eq(fp_util.key_from_signal({ name = "gear", quality = "epic" }), "item/gear|epic")
  t.eq(fp_util.key_from_signal({ type = "fluid", name = "water", quality = "epic" }), "fluid/water")
  t.eq(fp_util.signal_from_key("item/gear|epic").quality, "epic")
  t.eq(fp_util.signal_from_key("item/gear").quality, nil)
end)

t.test("keys: tiers sort by level, never by name", function()
  local keys = { "item/b", "item/a|legendary", "item/a|uncommon", "item/a", "item/a|epic", "item/a|rare", "fluid/z" }
  table.sort(keys, fp_util.key_less)
  t.eq(table.concat(keys, " "), "fluid/z item/a item/a|uncommon item/a|rare item/a|epic item/a|legendary item/b")
  t.truthy(fp_util.quality_less("rare", "epic"))
  t.truthy(not fp_util.quality_less("epic", "rare"))
  t.truthy(fp_util.quality_less("legendary", "zzz-modded"), "an unknown tier goes last")
end)

t.test("keys: every key of the old save stays as it is", function()
  local state = json.read_file(TEST_ROOT .. "/tests/fixtures/old_state.json")
  local n = 0
  for _, f in pairs(state.factories) do
    for key in pairs(f.summary) do
      local ty, name, q = fp_util.parse_key(key)
      t.eq(q, "normal", key)
      -- the old tool's keys are bare names (custom keys): nothing of them is taken as a tier
      t.eq(name, key:match("^[%w%-]+/(.*)$") or key, key)
      t.eq(fp_util.base_key(key), fp_util.key(ty, name), key)
      n = n + 1
    end
  end
  t.truthy(n > 100)
end)

t.test("format: small rates read in m, µ and n; typed back the same", function()
  t.eq(fp_util.format_number(0.0045), "4.5m")
  t.eq(fp_util.format_number(-0.0021), "-2.1m")
  t.eq(fp_util.format_number(0.000123), "123µ")
  t.eq(fp_util.format_number(1.23e-7), "123n")
  t.eq(fp_util.format_number(4e-10), "0.4n")
  t.eq(fp_util.format_number(1e-14), "0")
  t.eq(fp_util.format_number(0.0099), "9.9m")
  t.eq(fp_util.format_number(0.009999), "0.01", "rounds up into the plain range")
  t.eq(fp_util.format_rate(0.0001, "min", true), "6m/min")
  t.near(fp_util.parse_number("4.5m"), 0.0045, 1e-15)
  t.near(fp_util.parse_number("12µ"), 1.2e-5, 1e-18)
  t.near(fp_util.parse_number("3u"), 3e-6, 1e-18)
  t.near(fp_util.parse_number("7n"), 7e-9, 1e-20)
  t.eq(fp_util.parse_number("2M"), 2e6, "M is mega")
  for _, v in ipairs({ 0.0045, 0.000123, 1.23e-7 }) do
    t.near(fp_util.parse_number(fp_util.format_number(v)), v, v * 1e-9)
  end
end)
