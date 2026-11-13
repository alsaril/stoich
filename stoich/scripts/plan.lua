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

--- A sink, void or import: a list of items instead of recipe lines.
function plan.is_list(f)
  return model.LIST_KINDS[f.kind] == true
end

--- A void or import: its items' rates come from the plan balance.
function plan.is_boundary(f)
  return model.BOUNDARY_KINDS[f.kind] == true
end

--- The items of a void or import, sorted, each once.
function plan.boundary_items(f)
  local set = {}
  for _, row in ipairs(f.sink_items or {}) do
    if row.key then set[row.key] = true end
  end
  return fp_util.sorted_keys(set)
end

--- Plan unit of one item of a void or import: "<factory id>:<item key>".
function plan.unit_id(id, key)
  return id .. ":" .. key
end

--- The factory id (and the item, for a void or import unit) behind a plan unit id.
--- @return integer? id, string? item
function plan.unit_owner(uid)
  if type(uid) == "number" then return uid, nil end
  local id, key = tostring(uid):match("^(%d+):(.+)$")
  return tonumber(id), key
end

--- Custom keys marked as fluid on any line of a factory (or row of a sink, void or import).
function plan.fluid_keys(factory)
  local set = {}
  for _, line in ipairs(factory.lines) do
    for k in pairs(line.fluid_keys or {}) do set[k] = true end
  end
  for _, row in ipairs(plan.is_list(factory) and factory.sink_items or {}) do
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

--- How much of a sink's rates the plan delivers, 0 to 1 (as typed when not set).
function plan.sink_scale(sink)
  return sink.scale or 1
end

--- Balance one factory (or sink) and store the result on it.
function plan.balance_factory(factory)
  local result
  if plan.is_boundary(factory) then
    -- nothing to solve: its rates come from the plan; it only needs an item
    local any = #plan.boundary_items(factory) > 0
    result = solver.balance({}, {}, {}, {})
    result.status = any and "EXACT" or "NEEDS_SPLIT"
    result.problems = any and {} or { { type = "empty_list" } }
  elseif factory.kind == "sink" then
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
  if plan.is_boundary(f) then return #plan.boundary_items(f) > 0 end
  return next(f.result.net) ~= nil
end

--- The plan as the solver sees it: one unit per usable factory or sink (flow per copy),
--- one per item of a void or import (one item per second each), and the factories it
--- leaves out (invalid, not balanced, nothing in or out).
--- @return table[] units { id, flow, count, factory, item? (void/import), sink? }, number[] excluded
function plan.units(key)
  local p = model.plan(key)
  local units, excluded = {}, {}
  for _, id in ipairs(model.factory_ids(key)) do
    local f = p.factories[id]
    if not plan.usable(f) then
      excluded[#excluded + 1] = id
    elseif plan.is_boundary(f) then
      local sign = f.kind == "import" and 1 or -1
      for _, item in ipairs(plan.boundary_items(f)) do
        units[#units + 1] = { id = plan.unit_id(id, item), flow = { [item] = sign }, count = 0, factory = id, item = item }
      end
    else
      local sink = f.kind == "sink"
      units[#units + 1] = { id = id, flow = sink and plan.sink_flow(f) or f.result.net, count = f.copies or 1, factory = id, sink = sink or nil }
    end
  end
  return units, excluded
end

--- Shares of a split that matches usage: each factory's built capacity of the item
--- (copies × output per copy), so all of them run at the same share of what is built.
--- Every unit that makes the item takes part, a new one too; when none is built, each
--- counts as one copy.
function plan.usage_shares(item, units)
  local ids, flows, counts, built = {}, {}, {}, false
  for _, unit in ipairs(units) do
    -- an import has nothing built: it covers what the factories don't
    if not unit.item and (unit.flow[item] or 0) > 0 then
      ids[#ids + 1] = unit.id
      flows[unit.id] = unit.flow
      counts[unit.id] = unit.count or 0
      if counts[unit.id] > 0 then built = true end
    end
  end
  if not built then
    for _, id in ipairs(ids) do counts[id] = 1 end
  end
  return solver.shares_from_counts(item, ids, flows, counts)
end

--- Does an import of the plan bring this item in? Its split can't match usage (an import
--- has nothing built).
function plan.imported(item, units)
  for _, unit in ipairs(units) do
    if unit.item and (unit.flow[item] or 0) > 0 then return true end
  end
  return false
end

-- Diagnosis of a plan that can't balance ------------------------------------------------------

local FIX = "fix:"

local function fix_unit(item)
  return { id = FIX .. item, flow = { [item] = -1 }, item = item, fix = true }
end

local function with_fixes(lines, items)
  local out = {}
  for _, line in ipairs(lines) do out[#out + 1] = line end
  for _, item in ipairs(items) do out[#out + 1] = fix_unit(item) end
  return out
end

--- Items the contradicting equations of a result are about, sorted.
local function conflict_items(r)
  local set = {}
  for _, p in ipairs(r.problems) do
    if p.type == "conflict" then
      for _, item in ipairs(p.involved or {}) do set[item] = true end
      for _, item in ipairs(p.items or {}) do set[item] = true end
    end
  end
  return fp_util.sorted_keys(set)
end

-- Diagnosis is a bounded search: at most this many solves, this many options per step.
plan.DIAGNOSE_BUDGET = 400
plan.DIAGNOSE_BRANCH = 3

--- What closes a plan that can't balance: the fewest items that, left free to go out
--- (a void) or come in (an import), make it balance with nothing negative. A bounded
--- search: at each step the items that remove the most contradictions, a surplus before
--- a shortage, and the one where the factories make least first; a set is kept only if
--- the closed plan runs no factory backwards. With each item, the ones that would do as
--- well instead (void ice or water: either closes that loop).
--- @return table[] fixes { item, rate (per second; > 0 surplus, < 0 short, nil unknown), alternatives },
---   boolean closed: with all of them the plan balances
function plan.diagnose(lines, anchors, splits)
  local solves = 0
  local function solve(items)
    solves = solves + 1
    return solver.balance(with_fixes(lines, items), anchors, splits, {}, {})
  end
  -- what the sinks ask for is what the plan is for: never "import the science"
  local demanded = {}
  for _, line in ipairs(lines) do
    if line.sink then
      for item in pairs(line.flow) do demanded[item] = true end
    end
  end
  -- how much the factories make, and whether one runs backwards
  local function made(r)
    local sum, negative = 0, false
    for _, line in ipairs(lines) do
      if not line.item and not line.sink and not r.undetermined[line.id] then
        local c = r.counts[line.id] or 0
        sum = sum + math.abs(c)
        if c < -solver.NEGATIVE_TOL then negative = true end
      end
    end
    return sum, negative
  end
  local function kind_of(r, item)
    local id = FIX .. item
    if r.undetermined[id] or r.counts[id] == nil then return 1 end
    return r.counts[id] >= -solver.NEGATIVE_TOL and 0 or 2
  end
  local function less(a, b)
    if a.n ~= b.n then return a.n < b.n end
    if a.kind ~= b.kind then return a.kind < b.kind end
    if math.abs(a.made - b.made) > 1e-9 then return a.made < b.made end
    return a.item < b.item
  end
  local function copy(list)
    local out = {}
    for i, v in ipairs(list) do out[i] = v end
    return out
  end

  local r0 = solve({})
  local fallback -- the first closed set (even with a factory backwards), else the least contradicting
  local function search(chosen, r)
    if r.status ~= "CONFLICT" then
      local _, negative = made(r)
      if not negative then return copy(chosen), r end
      if not fallback or fallback.r.status == "CONFLICT" then fallback = { items = copy(chosen), r = r } end
      return nil
    end
    if not fallback or (fallback.r.status == "CONFLICT" and r.inconsistent < fallback.r.inconsistent) then
      fallback = { items = copy(chosen), r = r }
    end
    if solves >= plan.DIAGNOSE_BUDGET then return nil end
    local taken = {}
    for item in pairs(demanded) do taken[item] = true end
    for _, item in ipairs(chosen) do taken[item] = true end
    local options = {}
    for _, item in ipairs(conflict_items(r)) do
      if not taken[item] and solves < plan.DIAGNOSE_BUDGET then
        chosen[#chosen + 1] = item
        local tried = solve(chosen)
        chosen[#chosen] = nil
        if tried.inconsistent < r.inconsistent then
          options[#options + 1] = { item = item, r = tried, n = tried.inconsistent, kind = kind_of(tried, item), made = (made(tried)) }
        end
      end
    end
    table.sort(options, less)
    for i = 1, math.min(#options, plan.DIAGNOSE_BRANCH) do
      chosen[#chosen + 1] = options[i].item
      local found, fr = search(chosen, options[i].r)
      chosen[#chosen] = nil
      if found then return found, fr end
    end
    return nil
  end
  local items, r = search({}, r0)
  if not items then
    if not fallback then return {}, false end
    items, r = fallback.items, fallback.r
  end
  local closed = r.status ~= "CONFLICT"
  local _, negative = made(r)
  -- alternatives: the item swapped for another leaves the plan as closed (and as sound)
  local pool = {}
  local in_set = {}
  for _, item in ipairs(items) do in_set[item] = true end
  for _, item in ipairs(conflict_items(r0)) do
    if not demanded[item] and not in_set[item] then pool[#pool + 1] = item end
  end
  local fixes = {}
  for i, item in ipairs(items) do
    local fix = { item = item, alternatives = {} }
    local id = FIX .. item
    if closed and not r.undetermined[id] then fix.rate = r.counts[id] end
    if closed then
      for _, other in ipairs(pool) do
        if solves >= plan.DIAGNOSE_BUDGET + 100 then break end
        local swapped = copy(items)
        swapped[i] = other
        local tried = solve(swapped)
        local _, neg = made(tried)
        if tried.status ~= "CONFLICT" and (negative or not neg) then fix.alternatives[#fix.alternatives + 1] = other end
      end
    end
    fixes[i] = fix
  end
  return fixes, closed
end

--- Re-run the balance of a plan and cache it in the plan. Sinks are the anchors, at
--- their scale; the plan is closed but for its voids and imports. A void or import
--- takes only what the plan can't do without: where the balance leaves its rate free,
--- it is held at 0 (the factories make what is used, rather than import or void more).
function plan.rebalance(key)
  local p = model.plan(key)
  local lines, excluded = plan.units(key)
  for _, split in ipairs(p.splits) do
    if split.match_usage and not plan.imported(split.item, lines) then split.shares = plan.usage_shares(split.item, lines) end
  end
  local anchors, boundary = {}, {}
  for _, line in ipairs(lines) do
    local f = p.factories[line.factory]
    if f.kind == "sink" then anchors[line.id] = plan.sink_scale(f) end
    if line.item then boundary[#boundary + 1] = line.id end
  end
  -- what a balance settles below 0 (a free count is just 0): 0 nothing, 1 only voids or
  -- imports (the plan is short of an item, or has too much: said as such), 2 a factory
  local function negative_level(res)
    local level = 0
    for _, line in ipairs(lines) do
      if not res.undetermined[line.id] and (res.counts[line.id] or 0) < -solver.NEGATIVE_TOL then
        if not line.item then return 2 end
        level = 1
      end
    end
    return level
  end
  local r = solver.balance(lines, anchors, p.splits, {}, {})
  -- one free rate at a time (holding one at 0 can settle another), the hold that leaves
  -- the least negative: with an item in both a void and an import, the other one moves
  -- it. Never one that drives a factory negative (a recycler that would have to make all
  -- the plates its cables need): that choice stays the player's.
  for _ = 1, #boundary do
    local chosen, best = nil, 2
    for _, uid in ipairs(boundary) do
      if anchors[uid] == nil and r.undetermined[uid] then
        anchors[uid] = 0
        local tried = solver.balance(lines, anchors, p.splits, {}, {})
        anchors[uid] = nil
        local level = negative_level(tried)
        if level < best then
          chosen, best = { uid, tried }, level
          if level == 0 then break end
        end
      end
    end
    if not chosen then break end
    anchors[chosen[1]] = 0
    r = chosen[2]
  end
  -- a void or import below 0: the plan is short of the item, or has too much of it
  for _, problem in ipairs(r.problems) do
    if problem.type == "negative" then
      local rest = {}
      for _, uid in ipairs(problem.lines) do
        local id, item = plan.unit_owner(uid)
        local f = item and p.factories[id]
        if f then
          r.problems[#r.problems + 1] = { type = f.kind == "void" and "void_short" or "import_surplus", item = item, id = id }
        else
          rest[#rest + 1] = uid
        end
      end
      problem.lines = rest
    end
  end
  for i = #r.problems, 1, -1 do
    if r.problems[i].type == "negative" and #r.problems[i].lines == 0 then table.remove(r.problems, i) end
  end
  -- can't balance: say which items would close it, and how much of each is left or missing
  if r.status == "CONFLICT" then r.fixes, r.fixes_close = plan.diagnose(lines, anchors, p.splits) end
  r.excluded = excluded
  r.shortage = {}
  local order = {}
  for _, line in ipairs(lines) do
    local f = p.factories[line.factory]
    if not plan.is_list(f) then
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

--- Rebalance every plan (after a mod update).
function plan.rebalance_all()
  for _, key in ipairs(model.plan_keys()) do plan.rebalance(key) end
end

--- Rate of each item of a void or import in its plan's balance (per second, never
--- negative unless the plan is short of it).
function plan.boundary_rates(f, r)
  local rates = {}
  for _, item in ipairs(plan.boundary_items(f)) do
    rates[item] = r and r.counts and r.counts[plan.unit_id(f.id, item)] or 0
  end
  return rates
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
