-- Plans for the solver tests, built in the fake game (tests/fake_game.lua): real saves from
-- tests/fixtures/*.json and small hand-made ones.

local model = require("scripts.model")
local plan = require("scripts.plan")
local conditions = require("scripts.conditions")
local draft = require("scripts.draft")
local fp_util = require("scripts.util")

local plans = {}

--- Make the prototypes a key names, if the fake game hasn't got them.
local function known(key)
  local kind, name = fp_util.parse_key(key)
  prototypes[kind][name] = prototypes[kind][name] or { name = name }
end

--- A real plan from tests/fixtures (factories as their net per copy), into plan "fulgora".
function plans.load(file)
  local json = require("tests.json")
  local data = json.read_file(TEST_ROOT .. "/tests/fixtures/" .. file)
  -- the fake game knows only a few prototypes: make the ones this plan uses
  for _, e in ipairs(data.factories) do
    for key in pairs(e.net or {}) do known(key) end
    for _, row in ipairs(e.items or {}) do known(row.key) end
  end
  local ids = {}
  for _, e in ipairs(data.factories) do
    local f
    if e.kind == "factory" then
      f = model.new_factory("factory")
      local line = model.add_line(f, { kind = "custom", label = e.name, count = 1, flow = e.net })
      f.anchors[line.id] = 1
      f.external = plan.flow_items(e.net)
    else
      f = e.kind == "sink" and draft.new_sink() or draft.new_boundary(e.kind)
      for _, row in ipairs(e.items) do f.sink_items[#f.sink_items + 1] = { key = row.key, rate = row.rate, quality = row.quality } end
    end
    f.name, f.copies = e.name, e.copies
    plan.balance_factory(f)
    local _, saved = model.save_factory(f, {}, 1, false, "fulgora")
    ids[#ids + 1] = saved.id
  end
  -- splits: shares by the factory's place in the list
  for _, sp in ipairs(data.splits or {}) do
    local shares = {}
    for pos, share in pairs(sp.shares) do shares[ids[tonumber(pos)]] = share end
    local p = model.plan("fulgora")
    p.splits[#p.splits + 1] = { item = sp.item, shares = shares, match_usage = sp.match_usage or nil }
  end
end

--- A factory of one custom line (its net per copy), saved into a plan.
function plans.factory(key, name, net)
  for k in pairs(net) do known(k) end
  local f = model.new_factory("factory")
  local line = model.add_line(f, { kind = "custom", label = name, count = 1, flow = net })
  f.anchors[line.id] = 1
  f.external = plan.flow_items(net)
  f.name = name
  plan.balance_factory(f)
  local _, saved = model.save_factory(f, {}, 1, false, key)
  return saved
end

--- A sink of these rates { [key] = per second }, saved into a plan.
--- @param scale number? how much of its rates the plan delivers (default 1)
function plans.sink(key, name, rates, scale)
  local f = draft.new_sink()
  f.scale = scale
  for _, k in ipairs(fp_util.sorted_keys(rates, fp_util.key_less)) do
    known(k)
    f.sink_items[#f.sink_items + 1] = { key = k, rate = rates[k] }
  end
  f.name = name
  plan.balance_factory(f)
  local _, saved = model.save_factory(f, {}, 1, false, key)
  return saved
end

--- Rows in the plan's void or import: keys, or { key, quality } with a quality condition.
function plans.boundary(key, kind, keys)
  for _, k in ipairs(keys) do
    local item, quality = k, nil
    if type(k) == "table" then item, quality = k[1], k[2] end
    known(item)
    draft.add_boundary_item(key, kind, item, 1, quality)
  end
end

--- Apply the fixes a balance suggested (a void or import row each, with its quality condition).
function plans.apply_fixes(key, r)
  local present = plan.present_keys(key)
  for _, fix in ipairs(r.fixes or {}) do
    for _, row in ipairs(conditions.condition_rows(fix.keys, present)) do
      draft.add_boundary_item(key, fix.rate < 0 and "import" or "void", row.key, 1, row.quality)
    end
  end
end

return plans
