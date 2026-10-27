local t = require("tests.t")
local fake = require("tests.fake_game")
local json = require("tests.json")
local model = require("scripts.model")
local plan = require("scripts.plan")
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
  local ok, saved = model.save_factory(f, {}, 1)
  t.truthy(ok)
  local data = through_json(exchange.pack({ saved }))
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
    local _, saved = model.save_factory(f, {}, 1)
    return saved
  end
  local a = custom("a", { ["item/electronic-circuit"] = 1 })
  local b = custom("b", { ["item/electronic-circuit"] = 2 })
  model.plan().splits = { { item = "item/electronic-circuit", shares = { [a.id] = 25, [b.id] = 75 } } }
  local data = through_json(exchange.pack({ a, b }, true))

  fake.reset() -- another save
  model.new_id(); model.new_id(); model.new_id() -- ids already taken there
  local unpacked = assert(exchange.unpack(data))
  local added = exchange.add_to_plan(unpacked, 1, plan.balance_factory)
  t.eq(#added, 2)
  local split = model.plan().splits[1]
  t.truthy(split)
  t.near(split.shares[added[1].id], 25)
  t.near(split.shares[added[2].id], 75)
end)

t.test("exchange: rejects strings that are not ours", function()
  t.eq(exchange.unpack({ hello = 1 }), nil)
  t.eq(exchange.unpack(nil), nil)
  local _, err = exchange.unpack({ fp = 99, factories = {} })
  t.eq(err, "newer-format")
end)

t.test("exchange: old Kotlin state imports and balances like the old tool", function()
  fake.reset()
  local state = json.read_file(TEST_ROOT .. "/tests/fixtures/old_state.json")
  local items = exchange.old_items(state)
  t.eq(#items, 41)
  local fluids = {}
  for _, name in ipairs(items) do
    if exchange.guess_fluid(name) then fluids[name] = true end
  end
  t.truthy(fluids["mineral water"])
  local list = exchange.from_old(state, 60, fluids)
  t.eq(#list, 42)
  local sinks = 0
  for _, f in ipairs(list) do
    if f.kind == "sink" then sinks = sinks + 1 end
  end
  t.eq(sinks, 1)
  local unpacked = { factories = {} }
  for _, f in ipairs(list) do unpacked.factories[#unpacked.factories + 1] = { factory = f } end
  exchange.add_to_plan(unpacked, 1, plan.balance_factory)
  local r = plan.rebalance()
  t.eq(r.status, "EXACT")
  local by_name = {}
  for _, id in ipairs(model.factory_ids()) do by_name[model.get(id).name] = id end
  t.near(r.counts[by_name["green circuits"]], 14.05, 0.01)
  t.near(r.shortage[by_name["green circuits"]], 10.05, 0.01)
  t.near(r.shortage[by_name["uranium processing"]], -0.77, 0.01)
  t.eq(r.order[1], by_name["green circuits"])
  -- fluids were marked on the imported lines
  local oil = model.get(by_name["oil"])
  local marked = false
  for k in pairs(oil.lines[1].fluid_keys) do marked = true end
  t.truthy(marked, "oil line has a fluid key")
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
  local olds = {
    '{"factories":{"a":{"factory":{"name":5},"summary":{"x":1}},"b":{"factory":{"name":"b"},"summary":{"y":"z"}}}}',
    '{"factories":{"a":{"summary":3}}}',
    '[1,2,3]',
  }
  for _, text in ipairs(olds) do
    local data = json.decode(text)
    t.truthy(pcall(exchange.old_items, data))
    t.truthy(pcall(exchange.from_old, data, 60, {}))
  end
end)
