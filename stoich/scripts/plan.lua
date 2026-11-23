-- Factory balance, plan balance, shortage and belt chokes (pure but for prototype reads).

local solver = require("scripts.solver")
local belts = require("scripts.belts")
local model = require("scripts.model")
local fp_util = require("scripts.util")
local conditions = require("scripts.conditions")
local plan_lp = require("scripts.plan_lp")

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

--- Rows of a void or import that name an item.
local function list_rows(f)
  local n = 0
  for _, row in ipairs(f.sink_items or {}) do
    if row.key then n = n + 1 end
  end
  return n
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
    local any = list_rows(factory) > 0
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
  if plan.is_boundary(f) then return list_rows(f) > 0 end
  return next(f.result.net) ~= nil
end

--- The plan as the solver sees it: one unit per usable factory or sink (flow per copy),
--- one per item of a void or import (one item per second each), and the factories it
--- leaves out (invalid, not balanced, nothing in or out).
--- @param override table? { [id] = factory } used instead of the saved ones (what-if balances)
--- @return table[] units { id, flow, count, factory, item? (void/import), sink? }, number[] excluded
function plan.units(key, override)
  local p = model.plan(key)
  local units, excluded = {}, {}
  -- what the factories and sinks make and use: a void or import row with a quality
  -- condition stands for those of its tiers
  local present = {}
  for _, id in ipairs(model.factory_ids(key)) do
    local f = override and override[id] or p.factories[id]
    if plan.usable(f) and not plan.is_boundary(f) then
      for k in pairs(f.kind == "sink" and plan.sink_flow(f) or f.result.net) do present[k] = true end
    end
  end
  for _, id in ipairs(model.factory_ids(key)) do
    local f = override and override[id] or p.factories[id]
    if not plan.usable(f) then
      excluded[#excluded + 1] = id
    elseif plan.is_boundary(f) then
      local sign = f.kind == "import" and 1 or -1
      for _, item in ipairs(conditions.boundary_items(f, present)) do
        units[#units + 1] = { id = plan.unit_id(id, item), flow = { [item] = sign }, count = 0, factory = id, item = item,
          condition = conditions.row_condition(f, item) }
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

--- Re-run the balance of a plan and cache it in the plan. Sinks are the anchors, at
--- their scale; the plan is closed but for its voids and imports. A void or import
--- takes only what the plan can't do without: where the balance leaves its rate free, the
--- linear program settles it (the least voided and imported, every factory forwards).
function plan.rebalance(key)
  local r = plan.solve(key)
  model.plan(key).result = r
  return r
end

--- The plan balance (see plan.rebalance), not stored.
--- @param override table? { [id] = factory } in place of the saved ones; the plan's splits
---   are then left as they are (a copy takes the usage shares)
--- @param opts table? { diagnose = "full" | "none" }: when the plan can't balance, what to
---   search for what would close it. By default a small budget (AUTO_WORK): a plan that
---   needs more is marked complicated (Find a fix runs the full search).
function plan.solve(key, override, opts)
  local p = model.plan(key)
  local function factory(id) return override and override[id] or p.factories[id] end
  local lines, excluded = plan.units(key, override)
  local splits = override and fp_util.deep_copy(p.splits) or p.splits
  for _, split in ipairs(splits) do
    if split.match_usage and not plan.imported(split.item, lines) then split.shares = plan.usage_shares(split.item, lines) end
  end
  local anchors, boundary = {}, {}
  for _, line in ipairs(lines) do
    local f = factory(line.factory)
    if f.kind == "sink" then anchors[line.id] = plan.sink_scale(f) end
    if line.item then boundary[#boundary + 1] = line.id end
  end
  -- solves are counted (a plan with many quality tiers needs more of them)
  local solves = 0
  local function balance()
    solves = solves + 1
    return solver.balance(lines, anchors, splits, {}, {})
  end
  local r = balance()
  -- free void or import rates: the linear program settles them (the least voided and
  -- imported with every factory forwards); then the equations again, and what stays free is
  -- a choice between factories, the player's (a split)
  local any_free = false
  for _, uid in ipairs(boundary) do
    if r.undetermined[uid] then any_free = true end
  end
  local how = opts and opts.diagnose
  local budget = plan_lp.new_budget(how ~= "full" and plan_lp.AUTO_WORK or nil)
  if any_free and r.status ~= "CONFLICT" then
    local rates, out = plan_lp.settle_boundaries(lines, anchors, splits, budget)
    if rates then
      for _, uid in ipairs(boundary) do anchors[uid] = rates[uid] or 0 end
      local settled = balance()
      -- (the equations rejecting the program's rates would be rounding: the plan as it was)
      if settled.status ~= "CONFLICT" then r = settled else for _, uid in ipairs(boundary) do anchors[uid] = nil end end
    elseif out then
      -- out of budget: not worked out, Find a fix does it (out of pivots: nothing will). Its
      -- free rates are a question of budget, not a choice to ask the player for
      r.status = "UNSETTLED"
      for i = #r.problems, 1, -1 do
        local kind = r.problems[i].type
        if kind == "split" or kind == "anchor" or kind == "negative" then table.remove(r.problems, i) end
      end
      if budget.pivots then r.too_complicated = true elseif how ~= "none" then r.complicated = true end
    else
      -- no rates keep every factory forwards: the plan can't balance, and the diagnosis says
      -- what would close it (a split asked for here would only pin a ratio of factories that
      -- can't run)
      r.status = "CONFLICT"
      for i = #r.problems, 1, -1 do
        local kind = r.problems[i].type
        -- (prompts about a free choice or a count below 0 mean nothing here)
        if kind == "split" or kind == "anchor" or kind == "negative" then table.remove(r.problems, i) end
      end
    end
  end
  -- a void or import the equations put below 0: the plan is short of the item, or has too
  -- much of it
  for _, problem in ipairs(r.problems) do
    if problem.type == "negative" then
      local rest = {}
      for _, uid in ipairs(problem.lines) do
        local id, item = plan.unit_owner(uid)
        local f = item and factory(id)
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
  if r.status == "CONFLICT" and how ~= "none" then
    local fixes, closed, solves, exhausted, counts, in_way = plan_lp.diagnose(lines, anchors, splits, budget)
    if in_way and #in_way > 0 then r.splits_in_way = in_way end
    r.diagnose_solves = solves
    if exhausted and budget.pivots then
      r.too_complicated = true -- the simplex gave up: no search will do better
    elseif exhausted and how ~= "full" then
      r.complicated = true -- the full search waits for Find a fix
    else
      r.fixes, r.fixes_close = fixes, closed
    end
    -- the equations' counts mean nothing here (some below 0): the copies the fixes would
    -- need, or unknown
    for _, line in ipairs(lines) do
      if anchors[line.id] == nil or not line.sink then
        if counts and counts[line.id] then
          r.counts[line.id] = counts[line.id]
          r.undetermined[line.id] = nil
        else
          r.undetermined[line.id] = true
        end
      end
    end
    r.with_fixes = counts ~= nil or nil
  end
  r.solves = solves
  r.lp_work = budget.spent -- linear-program work of this balance (pivots x rows x columns)
  r.excluded = excluded
  r.binding = plan.binding(lines, r)
  r.shortage = {}
  local order = {}
  for _, line in ipairs(lines) do
    local f = factory(line.factory)
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
    local na, nb = factory(a).name, factory(b).name
    if na ~= nb then return na < nb end
    return a < b
  end)
  r.order = order
  return r
end

--- Find a fix: balance the plan again with the search for what would close it, and keep it
--- as the plan's result (until the next change balances it again).
function plan.find_fix(key)
  local r = plan.solve(key, nil, { diagnose = "full" })
  model.plan(key).result = r
  return r
end

--- What each factory with several outputs runs for: the outputs none of whose surplus goes to
--- a void (scrap recycling runs for electronic circuits; its holmium ore is left over). Only
--- for factories that have some output voided, with the plan determined there.
--- @return table<integer, string[]> { [factory id] = keys, by key order }
function plan.binding(lines, r)
  local voided = {}
  local scales = solver.item_scales(lines, r.counts)
  for _, line in ipairs(lines) do
    if line.item and not r.undetermined[line.id] then
      local rate = r.counts[line.id] or 0
      -- (a void of a legendary byproduct at 1e-7/s is a void too)
      for k, f in pairs(line.flow) do
        if f < 0 and rate > solver.negative_tol(line, scales) then voided[k] = true end
      end
    end
  end
  local out = {}
  for _, line in ipairs(lines) do
    if not line.item and not line.sink and not r.undetermined[line.id] and (r.counts[line.id] or 0) > solver.NEGATIVE_TOL then
      local outputs, any_voided = {}, false
      for k, f in pairs(line.flow) do
        if f > 0 then
          if voided[k] then any_voided = true else outputs[#outputs + 1] = k end
        end
      end
      if any_voided and #outputs > 0 then
        table.sort(outputs, fp_util.key_less)
        out[line.id] = outputs
      end
    end
  end
  return out
end

--- Rebalance every plan (after a mod update).
function plan.rebalance_all()
  for _, key in ipairs(model.plan_keys()) do plan.rebalance(key) end
end

-- Quality -------------------------------------------------------------------------------------

--- Does a plan show quality (its pickers, badges, filters)? When some factory has it, or a
--- player turned it on before any capture.
function plan.has_quality(key)
  local p = model.plan(key)
  if p.quality then return true end
  for _, f in pairs(p.factories) do
    if conditions.factory_has_quality(f) then return true end
  end
  return false
end

--- Item keys the plan's factories and sinks make or use.
function plan.present_keys(key)
  local present = {}
  for _, unit in ipairs((plan.units(key))) do
    if not unit.item then
      for k in pairs(unit.flow) do present[k] = true end
    end
  end
  return present
end

--- Rate of each item of a void or import in its plan's balance (per second, never
--- negative unless the plan is short of it).
function plan.boundary_rates(f, r)
  local rates = {}
  for _, item in ipairs(conditions.boundary_items(f)) do rates[item] = 0 end
  -- the items a quality condition stands for are the plan's units of this void or import
  local prefix = tostring(f.id) .. ":"
  for uid, c in pairs(r and r.counts or {}) do
    if type(uid) == "string" and uid:sub(1, #prefix) == prefix then rates[uid:sub(#prefix + 1)] = c end
  end
  return rates
end

--- "short" when more copies are needed, "ok" when demand is covered (overbuilt counts as ok).
function plan.shortage_class(shortage)
  if shortage == nil then return nil end
  if shortage > plan.TOLERANCE then return "short" end
  return "ok"
end

--- Belt check of one copy: external item flows above the allowed tier. The qualities of
--- an item share its belt: their flows (each way) are checked together.
--- @return table[] { item (a key, or the base key of several tiers), rate, check } for chokes
function plan.chokes(factory, tiers, max_index, one_lane)
  local out = {}
  local net = factory.result and factory.result.net or {}
  local fluid_keys = plan.fluid_keys(factory)
  local groups, order = {}, {}
  for _, key in ipairs(fp_util.sorted_keys(net, fp_util.key_less)) do
    if not belts.is_fluid(key, fluid_keys) then
      local id = fp_util.base_key(key) .. (net[key] > 0 and ">" or "<")
      local g = groups[id]
      if not g then
        g = { item = key, rate = 0, n = 0 }
        groups[id] = g
        order[#order + 1] = g
      end
      g.rate = g.rate + net[key]
      g.n = g.n + 1
      if g.n > 1 then g.item = fp_util.base_key(key) end
    end
  end
  for _, g in ipairs(order) do
    local check = belts.tier_for(g.rate, tiers, max_index, one_lane)
    if check and check.exceeds then out[#out + 1] = { item = g.item, rate = g.rate, check = check } end
  end
  return out
end

return plan
