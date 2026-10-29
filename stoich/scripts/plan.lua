-- Factory balance, plan balance, shortage and belt chokes (pure but for prototype reads).

local solver = require("scripts.solver")
local belts = require("scripts.belts")
local model = require("scripts.model")
local fp_util = require("scripts.util")

local plan = {}

plan.TOLERANCE = 0.05 -- shortage within ±this is "ok"

local function flow_items(flow)
  local set = {}
  for k in pairs(flow) do set[k] = true end
  return set
end
plan.flow_items = flow_items

--- Custom keys marked as fluid on any line of a factory (or row of a sink).
function plan.fluid_keys(factory)
  local set = {}
  for _, line in ipairs(factory.lines) do
    for k in pairs(line.fluid_keys or {}) do set[k] = true end
  end
  for _, row in ipairs(factory.kind == "sink" and factory.sink_items or {}) do
    if row.key and row.fluid then set[row.key] = true end
  end
  return set
end

--- Lines of a factory that take part in its balance.
function plan.solvable_lines(factory)
  local out = {}
  for _, line in ipairs(factory.lines) do
    if not line.idle and not line.invalid and next(line.flow) then out[#out + 1] = line end
  end
  return out
end

--- Consumption of a sink as a flow map (per second, negative): its items and rates.
function plan.sink_flow(sink)
  local flow = {}
  for _, row in ipairs(sink.sink_items or {}) do
    if row.key and row.rate and row.rate ~= 0 then flow[row.key] = (flow[row.key] or 0) - math.abs(row.rate) end
  end
  return flow
end

--- Balance one factory (or sink) and store the result on it.
function plan.balance_factory(factory)
  local result
  if factory.kind == "sink" then
    local flow = plan.sink_flow(factory)
    local status = next(flow) and "EXACT" or "NEEDS_SPLIT"
    local problems = {}
    if status ~= "EXACT" then problems[1] = { type = "empty_sink" } end
    local lines = { { id = 1, flow = flow } }
    result = solver.balance(lines, { [1] = 1 }, {}, flow_items(flow))
    result.status = status
    result.problems = problems
  else
    local lines = plan.solvable_lines(factory)
    local anchors = {}
    for _, line in ipairs(lines) do
      if factory.anchors[line.id] ~= nil then anchors[line.id] = factory.anchors[line.id] end
    end
    result = solver.balance(lines, anchors, factory.splits, factory.external, { require_anchor = true })
  end
  -- Invalid follows the current lines: deleting or overriding the broken ones repairs the factory.
  factory.invalid = model.collect_invalid(factory)
  if factory.invalid then
    result.status = "INVALID"
    table.insert(result.problems, 1, { type = "invalid", missing = factory.invalid })
  end
  factory.result = result
  return result
end

--- Can this factory take part in the plan balance?
function plan.usable(f)
  if f.invalid then return false end
  if not f.result or f.result.status ~= "EXACT" then return false end
  if f.kind == "sink" then return next(plan.sink_flow(f)) ~= nil end
  return next(f.result.net) ~= nil
end

--- The plan as the solver sees it: one unit per usable factory or sink (flow per copy),
--- and the factories it leaves out (invalid, not balanced, nothing in or out).
--- @return table[] units { id, flow, count }, number[] excluded
function plan.units()
  local p = model.plan()
  local units, excluded = {}, {}
  for _, id in ipairs(model.factory_ids()) do
    local f = p.factories[id]
    if plan.usable(f) then
      units[#units + 1] = { id = id, flow = f.kind == "sink" and plan.sink_flow(f) or f.result.net, count = f.copies or 1 }
    else
      excluded[#excluded + 1] = id
    end
  end
  return units, excluded
end

--- Re-run the plan balance and cache it in the plan. Sinks are the anchors; the plan
--- is closed (nothing comes from or goes outside it).
function plan.rebalance()
  local p = model.plan()
  local lines, excluded = plan.units()
  local anchors = {}
  for _, line in ipairs(lines) do
    if p.factories[line.id].kind == "sink" then anchors[line.id] = 1 end
  end
  local r = solver.balance(lines, anchors, p.splits, {}, {})
  r.excluded = excluded
  r.shortage = {}
  local order = {}
  for _, line in ipairs(lines) do
    local f = p.factories[line.id]
    if f.kind ~= "sink" then
      local needed = r.counts[line.id]
      if r.undetermined[line.id] then needed = nil end
      r.shortage[line.id] = needed and (needed - f.copies) or nil
      order[#order + 1] = line.id
    end
  end
  table.sort(order, function(a, b)
    local sa, sb = r.shortage[a], r.shortage[b]
    if sa == nil and sb ~= nil then return true end
    if sb == nil and sa ~= nil then return false end
    if sa and sb and sa ~= sb then return sa > sb end
    local na, nb = p.factories[a].name, p.factories[b].name
    if na ~= nb then return na < nb end
    return a < b
  end)
  r.order = order
  p.result = r
  return r
end

--- "short" when more copies are needed, "ok" when demand is covered (overbuilt counts as ok).
function plan.shortage_class(shortage)
  if shortage == nil then return nil end
  if shortage > plan.TOLERANCE then return "short" end
  return "ok"
end

--- Belt check of one copy: external item flows above the allowed tier.
--- @return table[] { item, rate, check } for chokes
function plan.chokes(factory, tiers, max_index, one_lane)
  local out = {}
  local net = factory.result and factory.result.net or {}
  local fluid_keys = plan.fluid_keys(factory)
  for _, key in ipairs(fp_util.sorted_keys(net)) do
    if not belts.is_fluid(key, fluid_keys) then
      local check = belts.tier_for(net[key], tiers, max_index, one_lane)
      if check and check.exceeds then out[#out + 1] = { item = key, rate = net[key], check = check } end
    end
  end
  return out
end

return plan
