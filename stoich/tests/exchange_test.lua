local t = require("tests.t")
local fake = require("tests.fake_game")
local json = require("tests.json")
local model = require("scripts.model")
local plan = require("scripts.plan")
local research = require("scripts.research")
local draft = require("scripts.draft")
local exchange = require("scripts.exchange")
local scanner = require("scripts.scanner")

local function through_json(data)
  return json.decode(json.encode(data))
end

local function oil_factory()
  local entries = {}
  for _ = 1, 6 do
    entries[#entries + 1] = { kind = "recipe", recipe = "advanced-oil-processing", machine = "oil-refinery",
      flow = { ["fluid/crude-oil"] = -20, ["fluid/heavy-oil"] = 5, ["fluid/light-oil"] = 9, ["fluid/petroleum-gas"] = 11 } }
  end
  for _ = 1, 2 do
    entries[#entries + 1] = { kind = "recipe", recipe = "coal-liquefaction", machine = "oil-refinery",
      flow = { ["item/coal"] = -2, ["fluid/heavy-oil"] = 13, ["fluid/light-oil"] = 4, ["fluid/petroleum-gas"] = 2 } }
  end
  entries[#entries + 1] = { kind = "recipe", recipe = "heavy-oil-cracking", machine = "chemical-plant", flow = { ["fluid/heavy-oil"] = -20, ["fluid/light-oil"] = 15 } }
  entries[#entries + 1] = { kind = "recipe", recipe = "light-oil-cracking", machine = "chemical-plant", flow = { ["fluid/light-oil"] = -15, ["fluid/petroleum-gas"] = 10 } }
  return draft.from_scan({ lines = scanner.group(entries) })
end

t.test("exchange: factory survives a JSON round trip", function()
  fake.reset()
  local f = oil_factory()
  t.eq(f.result.status, "EXACT")
  local ok, saved = model.save_factory(f, {}, 1, false, "nauvis")
  t.truthy(ok)
  local data = through_json(exchange.pack({ saved }, "nauvis"))
  local unpacked = assert(exchange.unpack(data))
  t.eq(#unpacked.factories, 1)
  local copy = unpacked.factories[1].factory
  t.eq(copy.name, saved.name)
  t.eq(#copy.lines, #saved.lines)
  for id, v in pairs(saved.anchors) do t.eq(copy.anchors[id], v, "anchor " .. id) end
  t.eq(#copy.splits, 1)
  for id, v in pairs(saved.splits[1].shares) do t.near(copy.splits[1].shares[id], v) end
  for k in pairs(saved.external) do t.truthy(copy.external[k], "external " .. k) end
  local r = plan.balance_factory(copy)
  t.eq(r.status, "EXACT")
  for id, c in pairs(saved.result.counts) do t.near(r.counts[id], c, 1e-9) end
end)

t.test("exchange: plan import remaps split factory ids", function()
  fake.reset()
  local function custom(name, net)
    local f = model.new_factory("factory")
    local line = model.add_line(f, { kind = "custom", label = name, count = 1, flow = net })
    f.name, f.anchors[line.id], f.external = name, 1, plan.flow_items(net)
    plan.balance_factory(f)
    local _, saved = model.save_factory(f, {}, 1, false, "nauvis")
    return saved
  end
  local a = custom("a", { ["item/electronic-circuit"] = 1 })
  local b = custom("b", { ["item/electronic-circuit"] = 2 })
  model.plan("nauvis").splits = { { item = "item/electronic-circuit", shares = { [a.id] = 25, [b.id] = 75 }, match_usage = true } }
  local data = through_json(exchange.pack({ a, b }, "nauvis"))

  fake.reset() -- another save
  model.new_id(); model.new_id(); model.new_id() -- ids already taken there
  local unpacked = assert(exchange.unpack(data))
  local added = exchange.add_to_plan(unpacked, 1, "nauvis")
  t.eq(#added, 2)
  local split = model.plan("nauvis").splits[1]
  t.truthy(split)
  t.near(split.shares[added[1].id], 25)
  t.near(split.shares[added[2].id], 75)
  t.eq(split.match_usage, true, "still matches usage")
end)

t.test("exchange: rejects strings that are not ours", function()
  t.eq(exchange.unpack({ hello = 1 }), nil)
  t.eq(exchange.unpack(nil), nil)
  local _, err = exchange.unpack({ fp = 99, factories = {} })
  t.eq(err, "newer-format")
end)

-- Review finding: malformed pastes must not raise (a Lua error ends a multiplayer game).
t.test("exchange: malformed strings are rejected without errors", function()
  fake.reset()
  local bad = {
    '{"fp":"v2","factories":[]}',
    '{"fp":1,"factories":[5]}',
    '{"fp":1,"factories":[{"name":"x","lines":[{"id":1,"flow":3}]}]}',
    '{"fp":1,"factories":[{"name":"x","lines":5,"anchors":7,"splits":[3],"external":"y"}]}',
    '{"fp":1,"factories":{"a":1}}',
  }
  for _, text in ipairs(bad) do
    local ok, unpacked = pcall(exchange.unpack, json.decode(text))
    t.truthy(ok, "unpack raised for " .. text)
    if unpacked then
      -- whatever survives must still be balanceable
      for _, e in ipairs(unpacked.factories) do plan.balance_factory(e.factory) end
    end
  end
end)

t.test("exchange: a sink keeps its scale; odd values are checked", function()
  fake.reset()
  local s = draft.new_sink()
  s.sink_items[1] = { key = "item/iron-plate", rate = 2 }
  s.scale = 0.4
  local copy = exchange.deserialize_factory(through_json(exchange.serialize_factory(s)))
  t.near(copy.scale, 0.4)
  s.scale = nil
  t.eq(exchange.deserialize_factory(through_json(exchange.serialize_factory(s))).scale, nil, "1 stays as nothing")
  local data = through_json(exchange.serialize_factory(s))
  data.scale = -3
  t.eq(exchange.deserialize_factory(data).scale, 0)
  data.scale = 7
  t.eq(exchange.deserialize_factory(data).scale, nil)
  data.scale = "x"
  t.eq(exchange.deserialize_factory(data).scale, nil)
end)

t.test("exchange: voids and imports keep their items, without rates", function()
  fake.reset()
  local f = draft.new_boundary("import")
  f.sink_items = { { key = "item/copper-plate" }, { key = "custom/space-data", fluid = true } }
  plan.balance_factory(f)
  local _, saved = model.save_factory(f, {}, 1, false, "nauvis")
  local data = through_json(exchange.pack({ saved }, "nauvis"))
  -- a rate in a hand-edited string is dropped
  data.factories[1].sink_items[1].rate = 5
  local copy = assert(exchange.unpack(data)).factories[1].factory
  t.eq(copy.kind, "import")
  t.eq(#copy.sink_items, 2)
  t.eq(copy.sink_items[1].key, "item/copper-plate")
  t.eq(copy.sink_items[1].rate, nil)
  t.eq(copy.sink_items[2].fluid, true)
  t.eq(plan.balance_factory(copy).status, "EXACT")
end)

t.test("exchange: written as format 2; format 1 (before quality) is read too", function()
  fake.reset({ quality = true })
  local function custom(net)
    local f = model.new_factory("factory")
    local line = model.add_line(f, { kind = "custom", label = "x", count = 1, flow = net })
    f.name, f.anchors[line.id], f.external = "x", 1, plan.flow_items(net)
    plan.balance_factory(f)
    local _, saved = model.save_factory(f, {}, 1, false, "nauvis")
    return saved
  end
  local plain = custom({ ["item/iron-plate"] = -1, ["item/iron-gear-wheel"] = 1 })
  local data = through_json(exchange.pack({ plain }, "nauvis"))
  t.eq(data.fp, 2)
  -- a 0.4 string: format 1, the same factory
  data.fp = 1
  local old = assert(exchange.unpack(data)).factories[1].factory
  t.eq(plan.balance_factory(old).status, "EXACT")
  data = through_json(exchange.pack({ plain }, "nauvis"))
  local rare = custom({ ["item/iron-plate|rare"] = -1, ["item/iron-gear-wheel|rare"] = 0.9, ["item/iron-gear-wheel|epic"] = 0.1 })
  data = through_json(exchange.pack({ rare }, "nauvis"))
  t.eq(data.fp, 2)
  local copy = assert(exchange.unpack(data)).factories[1].factory
  t.near(copy.lines[1].flow["item/iron-gear-wheel|epic"], 0.1)
  t.truthy(copy.external["item/iron-plate|rare"])
  t.eq(plan.balance_factory(copy).status, "EXACT")
  model.validate_factory(copy)
  t.eq(copy.invalid, nil, "the tiers exist")
  -- a void with a tier
  local v = draft.new_boundary("void")
  v.sink_items = { { key = "item/iron-gear-wheel|epic" } }
  t.eq(exchange.pack({ v }, "nauvis").fp, 2)
end)

t.test("exchange: a key with an unknown tier makes the factory invalid, not an error", function()
  fake.reset() -- no Space Age: only normal
  local f = model.new_factory("factory")
  model.add_line(f, { kind = "custom", label = "x", count = 1, flow = { ["item/iron-plate|rare"] = 1 } })
  t.truthy(model.validate_factory(f))
end)

t.test("exchange: lines keep what they are worked out from; odd values are dropped", function()
  fake.reset()
  local f = model.new_factory("factory")
  model.add_line(f, { kind = "recipe", recipe = "iron-gear-wheel", machine = "assembling-machine-2", count = 2,
    flow = { ["item/iron-plate"] = -1.5, ["item/iron-gear-wheel"] = 0.75 },
    variants = { { n = 2, speed = 0.75, productivity = 0.1, quality_chance = 0 } } })
  model.add_line(f, { kind = "mining", resource = "iron-ore", machine = "electric-mining-drill", count = 1,
    flow = { ["item/iron-ore"] = 0.65 }, variants = { { n = 1, productivity = 0, quality_chance = 0, base = { ["item/iron-ore"] = 0.5 } } } })
  model.add_line(f, { kind = "recipe", recipe = "copper-cable", machine = "assembling-machine-2", count = 1, manual = true,
    flow = { ["item/copper-plate"] = -1.5, ["item/copper-cable"] = 3 },
    config = { machine = "assembling-machine-2", modules = { { slot = 2, name = "speed-module" } }, beacon = "beacon", beacon_count = 2,
      beacon_modules = { { slot = 1, name = "speed-module" } }, speed = 5 } })
  local data = through_json(exchange.pack({ f }, "nauvis"))
  t.eq(data.fp, 2, "new line fields")
  local copy = assert(exchange.unpack(data)).factories[1].factory
  t.eq(copy.lines[1].variants[1].n, 2)
  t.near(copy.lines[1].variants[1].speed, 0.75)
  t.near(copy.lines[1].variants[1].productivity, 0.1)
  t.near(copy.lines[2].variants[1].base["item/iron-ore"], 0.5)
  local c = copy.lines[3].config
  t.eq(c.machine, "assembling-machine-2")
  t.eq(c.modules[1].slot, 2)
  t.eq(c.modules[1].name, "speed-module")
  t.eq(c.beacon_count, 2)
  t.eq(c.speed, 5)
  -- hand-edited nonsense is dropped, not kept
  data.factories[1].lines[1].variants = { { n = -1, speed = 1, productivity = 0 }, "x", { n = 1, productivity = "y", speed = 1 } }
  data.factories[1].lines[3].config = { modules = 5 }
  copy = assert(exchange.unpack(data)).factories[1].factory
  t.eq(copy.lines[1].variants, nil)
  t.eq(copy.lines[3].config, nil)
end)

t.test("exchange: a hand-added line whose machine can't craft is invalid, not an error", function()
  fake.reset()
  local f = model.new_factory("factory")
  model.add_line(f, { kind = "recipe", recipe = "copper-cable", machine = "assembling-machine-2", count = 1, manual = true,
    flow = { ["item/copper-plate"] = -1.5, ["item/copper-cable"] = 3 }, config = { machine = "assembling-machine-2" } })
  local data = through_json(exchange.pack({ f }, "nauvis"))
  -- a hand-edited string: the machine is a drill (no crafting speed to ask for)
  data.factories[1].lines[1].config.machine = "electric-mining-drill"
  local copy = assert(exchange.unpack(data)).factories[1].factory
  t.truthy(model.validate_factory(copy), "invalid")
  t.truthy(copy.lines[1].invalid)
  t.eq(scanner.config_flow("copper-cable", copy.lines[1].config, nil), nil, "not worked out")
  local changed = research.changed_lines(copy, nil)
  t.eq(next(changed), nil, "research leaves it alone")
  -- a crafter is fine
  data.factories[1].lines[1].config.machine = "assembling-machine-2"
  copy = assert(exchange.unpack(data)).factories[1].factory
  t.eq(model.validate_factory(copy), false)
end)

t.test("exchange: a void row's quality condition travels; nonsense is dropped", function()
  fake.reset({ quality = true })
  local v = draft.new_boundary("void")
  v.sink_items = { { key = "item/iron-gear-wheel", quality = ">=rare" }, { key = "item/iron-plate|rare" } }
  local data = through_json(exchange.pack({ v }, "nauvis"))
  t.eq(data.fp, 2)
  local copy = assert(exchange.unpack(data)).factories[1].factory
  t.eq(copy.sink_items[1].quality, ">=rare")
  t.eq(copy.sink_items[2].quality, nil)
  t.eq(copy.sink_items[2].key, "item/iron-plate|rare")
  data.factories[1].sink_items[1].quality = "~rare"
  copy = assert(exchange.unpack(data)).factories[1].factory
  t.eq(copy.sink_items[1].quality, nil)
end)

t.test("exchange: tiers and variants are checked; the plan's Quality switch travels", function()
  fake.reset({ quality = true })
  t.eq(exchange.item_key("item/iron-plate|normal"), "item/iron-plate", "normal is no tier")
  local f = model.new_factory("factory")
  model.add_line(f, { kind = "recipe", recipe = "iron-gear-wheel", machine = "assembling-machine-2", count = 1,
    flow = { ["item/iron-gear-wheel"] = 1 }, variants = { { n = 1, speed = 1, productivity = 0 } }, recipe_quality = "normal" })
  model.add_line(f, { kind = "mining", resource = "iron-ore", machine = "electric-mining-drill", count = 1,
    flow = { ["item/iron-ore"] = 1 }, variants = { { n = 1, productivity = 0, base = { ["item/iron-ore"] = 1 } } } })
  model.plan("nauvis").quality = true
  local data = through_json(exchange.pack({ f }, "nauvis"))
  t.eq(data.quality, true)
  -- a crafter's variant without its speed, a drill's without its flow: dropped
  data.factories[1].lines[1].variants[1].speed = nil
  data.factories[1].lines[1].variants[1].base = { ["item/iron-ore"] = 1 }
  data.factories[1].lines[2].variants[1].base = nil
  data.factories[1].lines[2].variants[1].speed = 1
  local unpacked = assert(exchange.unpack(data))
  local copy = unpacked.factories[1].factory
  t.eq(copy.lines[1].variants, nil)
  t.eq(copy.lines[2].variants, nil)
  t.eq(copy.lines[1].recipe_quality, nil, "normal is no tier")
  fake.reset()
  exchange.add_to_plan(unpacked, 1, "nauvis")
  t.eq(model.plan("nauvis").quality, true)
end)
