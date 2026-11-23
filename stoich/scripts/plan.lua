-- Factory balance, plan balance, shortage and belt chokes (pure but for prototype reads).

local solver = require("scripts.solver")
local belts = require("scripts.belts")
local model = require("scripts.model")
local fp_util = require("scripts.util")
local scanner = require("scripts.scanner")
local lp = require("scripts.lp")

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

-- Quality conditions, as the game's filters: "any", or a comparator and a tier (">=rare").
plan.QUALITY_OPS = { "any", "=", ">=", ">", "<=", "<" }

--- A condition's comparator and tier; nil for one that isn't valid.
--- @return string? op, string? tier
function plan.parse_condition(cond)
  if cond == "any" then return "any", nil end
  if type(cond) ~= "string" then return nil end
  -- the comparator, then a tier name (">=" alone is no condition)
  for _, op in ipairs({ ">=", "<=", "=", ">", "<" }) do
    if cond:sub(1, #op) == op then
      local tier = cond:sub(#op + 1)
      if tier:match("^[%w%-_]+$") then return op, tier end
      return nil
    end
  end
  return nil
end

--- Does an item key match a row's item (its base key) and quality condition?
function plan.matches_condition(key, base, cond)
  if fp_util.base_key(key) ~= base then return false end
  local op, tier = plan.parse_condition(cond)
  if op == "any" then return true end
  if not op then return false end
  local q = fp_util.quality_of(key)
  if q == tier then return op == "=" or op == ">=" or op == "<=" end
  if op == "=" then return false end
  local higher = fp_util.quality_less(tier, q)
  if op == ">=" or op == ">" then return higher end
  return not higher
end

--- Rows of a void or import that name an item.
local function list_rows(f)
  local n = 0
  for _, row in ipairs(f.sink_items or {}) do
    if row.key then n = n + 1 end
  end
  return n
end

--- The items of a void or import, sorted, each once. A row with a quality condition stands
--- for the matching tiers of its item that the plan's factories make or use (`present`).
--- @param present table<string, boolean>? the plan's item keys (nil: rows with a condition give nothing)
function plan.boundary_items(f, present)
  local set = {}
  for _, row in ipairs(f.sink_items or {}) do
    if row.key and row.quality then
      for key in pairs(present or {}) do
        if plan.matches_condition(key, fp_util.base_key(row.key), row.quality) then set[key] = true end
      end
    elseif row.key then
      set[row.key] = true
    end
  end
  return fp_util.sorted_keys(set, fp_util.key_less)
end

--- Did a void's or import's item come from a row with a quality condition (not named itself)?
function plan.row_condition(f, item)
  for _, row in ipairs(f.sink_items or {}) do
    if row.key == item and not row.quality then return false end
  end
  return true
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
      for _, item in ipairs(plan.boundary_items(f, present)) do
        units[#units + 1] = { id = plan.unit_id(id, item), flow = { [item] = sign }, count = 0, factory = id, item = item,
          condition = plan.row_condition(f, item) }
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

-- What closes a plan that can't balance: a linear program (scripts/lp.lua). Every factory's
-- copies, every existing void and import, and a void for each item something makes and an
-- import for each item something uses are variables, all >= 0 (no factory backwards); every
-- item balances and the sinks get their rates. The least voiding wins, imports cost far more
-- than voids (the factories make what they can), and importing what a sink asks for most of
-- all. Exact and deterministic: no search, no budget to run out on a plan's size.
-- (Before 0.5 a bounded search for the fewest items; with quality it ran out of budget and
-- closed scrap plans by importing the science's ingredients.)

-- Costs per item (or fluid unit) a second: voiding what
-- nothing uses is cheapest, voiding what a factory could still use dearer (the surplus is
-- voided at the end of its chain: the factories make what they can, and the plan stays
-- settled), importing what nothing makes dearer still, importing what a factory could make
-- more, what a sink asks for most; running a factory costs a little.
plan.FIX_COSTS = { void = 1, void_used = 3, import = 1000, import_made = 1e5, demanded = 1e7, factory = 1e-3 }
-- Work one plan balance may do in linear programs (Find a fix has no limit): settling the
-- voids' rates and the whole diagnosis share it. Pivots x rows x columns, ~0.02 us each in
-- plain Lua 5.5 on an M-series Mac, so ~1 s at most. Out of budget, the alternatives ("or
-- instead") stop; a plan that runs out before its first fixes is marked complicated.
plan.AUTO_WORK = 50000000

--- A work budget shared by the linear programs of one balance.
--- @param work number? nil: no limit
function plan.new_budget(work)
  return { work = work, spent = 0, exhausted = false }
end

local function id_order(a, b) return solver.id_less(a, b) end

--- What would close a plan that can't balance.
--- @param lines table[] the plan's units
--- @param anchors table the balance's anchors (only the sinks' count here)
--- @param splits table[] the plan's splits
--- @param work number? a budget (pivots x rows x columns); nil: none
--- @return table[] fixes { item (the key, or the base key of several tiers), keys, rates = { [key] = rate },
---   rate (per second, the sum; > 0 surplus, < 0 short), alternatives },
---   boolean closed, integer solves (linear programs), boolean exhausted (the budget ran out)
--- The plan as a linear program (shared by the diagnosis and the plan balance).
--- @param candidates boolean a void per item made and an import per item used (the diagnosis);
---   without: only the plan's units (settling the rates of its own voids and imports)
local function lp_model(lines, anchors, splits, budget, candidates)
  -- the work budget is shared by every program of one balance (plan.new_budget)
  budget = budget or plan.new_budget(nil)
  local solves = 0
  local fixed, units = {}, {}
  for _, line in ipairs(lines) do
    if line.sink and anchors[line.id] ~= nil then fixed[line.id] = anchors[line.id] else units[#units + 1] = line end
  end
  table.sort(units, function(x, y) return id_order(x.id, y.id) end)
  -- items: who makes and uses them, their scale, what the sinks ask for
  local made, used, scale, demanded, consumed = {}, {}, {}, {}, {}
  for _, line in ipairs(lines) do
    for k, v in pairs(line.flow) do
      if v > 0 then made[k] = true elseif v < 0 then used[k] = true end
      if v < 0 and not line.sink and not line.item then consumed[k] = true end
      if line.sink then demanded[k] = true end
      local a = math.abs(v) * (fixed[line.id] and math.max(fixed[line.id], 1e-9) or 1)
      if a > (scale[k] or 0) then scale[k] = a end
    end
  end
  local keys = {}
  for k in pairs(scale) do keys[#keys + 1] = k end
  table.sort(keys, fp_util.key_less)
  local row_of = {}
  for i, k in ipairs(keys) do row_of[k] = i end
  -- variables: the units, then a void and an import per item
  local vars = {}
  for _, u in ipairs(units) do vars[#vars + 1] = { unit = u } end
  for _, k in ipairs(candidates and keys or {}) do
    if made[k] then vars[#vars + 1] = { key = k, sign = -1 } end
    if used[k] then vars[#vars + 1] = { key = k, sign = 1 } end
  end
  local C = plan.FIX_COSTS
  -- per item a second, what is voided or imported, as the player counts it
  local function boundary_cost(key, sign)
    if sign < 0 then return consumed[key] and C.void_used or C.void end
    if demanded[key] then return C.demanded end
    if made[key] then return C.import_made end
    return C.import
  end
  local function cost(v)
    if v.unit then
      -- a void or import the plan has: free in the diagnosis (it is there already); settling
      -- its rate, it costs as a suggested one would
      if v.unit.item then return candidates and 0 or boundary_cost(v.unit.item, v.unit.flow[v.unit.item] or -1) end
      if v.unit.sink then return 0 end
      -- running a factory costs a little: a surplus is voided where it comes out
      return C.factory
    end
    return boundary_cost(v.key, v.sign)
  end
  -- the splits, as the balance has them: each line's share of what they make together
  local split_rows = {}
  local by_id = {}
  for _, line in ipairs(lines) do by_id[line.id] = line end
  for _, split in ipairs(splits or {}) do
    local ids, total = {}, 0
    for id, share in pairs(split.shares or {}) do
      local line = by_id[id]
      if line and (line.flow[split.item] or 0) > 0 and share >= 0 then
        ids[#ids + 1] = id
        total = total + share
      end
    end
    table.sort(ids, id_order)
    if #ids >= 2 and total > 0 then
      for i = 1, #ids - 1 do
        local terms = { [ids[i]] = by_id[ids[i]].flow[split.item] }
        local s = split.shares[ids[i]] / total
        for _, id in ipairs(ids) do terms[id] = (terms[id] or 0) - s * by_id[id].flow[split.item] end
        split_rows[#split_rows + 1] = terms
      end
    end
  end

  -- one linear program without the forbidden variables; nil when out of budget
  local function run(forbidden)
    if budget.work and budget.spent >= budget.work then
      budget.exhausted = true
      return nil
    end
    local cols, c = {}, {}
    for i, v in ipairs(vars) do
      if not forbidden[i] then
        cols[#cols + 1] = i
        c[#c + 1] = cost(v)
      end
    end
    local A, b = {}, {}
    for i = 1, #keys do A[i], b[i] = {}, 0 end
    for j, i in ipairs(cols) do
      local v = vars[i]
      if v.unit then
        for k, x in pairs(v.unit.flow) do
          local r = row_of[k]
          A[r][j] = (A[r][j] or 0) + x
        end
      else
        local r = row_of[v.key]
        A[r][j] = (A[r][j] or 0) + v.sign
      end
    end
    for id, count in pairs(fixed) do
      for k, x in pairs(by_id[id].flow) do b[row_of[k]] = b[row_of[k]] - x * count end
    end
    local col_of_unit = {}
    for j, i in ipairs(cols) do
      if vars[i].unit then col_of_unit[vars[i].unit.id] = j end
    end
    for _, terms in ipairs(split_rows) do
      local row, rhs = {}, 0
      for id, coef in pairs(terms) do
        if fixed[id] then rhs = rhs - coef * fixed[id]
        elseif col_of_unit[id] then row[col_of_unit[id]] = (row[col_of_unit[id]] or 0) + coef end
      end
      A[#A + 1], b[#b + 1] = row, rhs
    end
    solves = solves + 1
    local x, pivots = lp.minimize(c, A, b, #cols)
    budget.spent = budget.spent + (pivots or 0) * #A * (#cols + #A)
    if not x then return nil end
    -- the fixes: voids and imports with a rate, by base item and way; and the factories' counts
    -- voided: by a suggested void or one the plan has
    local rates, counts, voided, import_cost = {}, {}, {}, 0
    for j, i in ipairs(cols) do
      local v = vars[i]
      if not v.unit and v.sign > 0 then import_cost = import_cost + c[j] * x[j] end
      if v.unit then
        counts[i] = x[j]
        if v.unit.item and x[j] > 0 then
          for k, f in pairs(v.unit.flow) do
            if f < 0 then voided[k] = (voided[k] or 0) - f * x[j] end
          end
        end
      elseif x[j] > 1e-9 * math.max(scale[v.key], 1) then
        rates[v.key] = (rates[v.key] or 0) - v.sign * x[j]
        if v.sign < 0 then voided[v.key] = (voided[v.key] or 0) + x[j] end
      end
    end
    return rates, counts, voided, import_cost
  end

  -- the void of an item, by key
  local void_var = {}
  for i, v in ipairs(vars) do
    if v.key and v.sign < 0 then void_var[v.key] = i end
    -- settling the plan's own rates: its void of the item (the diagnosis leaves the plan's own
    -- voids as they are and moves only what it suggests)
    if not candidates and v.unit and v.unit.item and (v.unit.flow[v.unit.item] or 0) < 0 and not void_var[v.unit.item] then
      void_var[v.unit.item] = i
    end
  end
  -- no factory runs beyond what its outputs are needed for: one whose every output is
  -- (partly) voided turns a surplus into something to void (batteries into accumulators,
  -- gears into plates). Its outputs aren't voided then, and the plan is worked out again:
  -- the surplus goes to the void where it comes out. A factory whose output is all voided
  -- (bricks from stone nobody needs) doesn't run at all.
  --- @param keep_pointless boolean? leave a factory that only makes what is voided (an
  ---   alternative: "or instead, bricks")
  local wanted_key = {}
  for k in pairs(consumed) do wanted_key[k] = true end
  for k in pairs(demanded) do wanted_key[k] = true end
  --- A ban that leaves no answer at all (the plan's own void, needed after all) is undone and
  --- not made again: the rules are preferences, the last answer stands.
  local function solve_closing(forbidden, keep_pointless)
    local kept, last, step = {}, nil, nil
    local function ban(i)
      if kept[i] or forbidden[i] then return false end
      forbidden[i] = true
      step[#step + 1] = i
      return true
    end
    for _ = 1, 2 * #vars + 2 do
      local rates, counts, voided, import_cost = run(forbidden)
      if not rates then
        if budget.exhausted or not last then return nil end
        for _, i in ipairs(step) do
          forbidden[i] = nil
          kept[i] = true
        end
        rates, counts, voided, import_cost = last[1], last[2], last[3], last[4]
      end
      last, step = { rates, counts, voided, import_cost }, {}
      local changed = false
      for i, v in ipairs(vars) do
        local u = v.unit
        if u and not u.item and not u.sink and (counts[i] or 0) > 1e-9 then
          -- judged by its wanted outputs (what a factory uses or a sink asks for): a byproduct
          -- nothing uses (the rare plates of a recycler of normal gears) is always voided
          local any, all_voided, wanted, all_partly = false, true, false, true
          for k, f in pairs(u.flow) do
            if f > 0 then
              any = true
              local out = voided[k] or 0
              if not (out > 0 and out >= f * counts[i] * (1 - 1e-9)) then all_voided = false end
              if wanted_key[k] then
                wanted = true
                if not (out > 0) then all_partly = false end
              end
            end
          end
          if any and all_voided and not keep_pointless then
            if ban(i) then changed = true end
          elseif wanted and all_partly and not all_voided then
            for k, f in pairs(u.flow) do
              if f > 0 and wanted_key[k] and void_var[k] and ban(void_var[k]) then changed = true end
            end
          end
        end
        if changed then break end
      end
      if not changed then return rates, counts, import_cost end
    end
    return nil
  end

  -- groups: an item's tiers that go the same way are one fix
  local function groups_of(rates)
    local list, by = {}, {}
    for _, k in ipairs(keys) do
      local v = rates[k]
      if v and v ~= 0 then
        local id = fp_util.base_key(k) .. (v > 0 and ">" or "<")
        local g = by[id]
        if not g then
          g = { id = id, keys = {}, rates = {}, rate = 0 }
          by[id] = g
          list[#list + 1] = g
        end
        g.keys[#g.keys + 1] = k
        g.rates[k] = v
        g.rate = g.rate + v
      end
    end
    return list, by
  end
  local function vars_of(g)
    local set = {}
    for i, v in ipairs(vars) do
      if v.key and g.rates[v.key] and (v.sign < 0) == (g.rate > 0) then set[i] = true end
    end
    return set
  end

  return {
    vars = vars, run = run, solve_closing = solve_closing, groups_of = groups_of, vars_of = vars_of,
    status = function() return solves, budget.exhausted end,
  }
end

--- What would close a plan that can't balance.
--- @param lines table[] the plan's units
--- @param anchors table the balance's anchors (only the sinks' count here)
--- @param splits table[] the plan's splits
--- @param work number? a budget (pivots x rows x columns); nil: none
--- @return table[] fixes { item (the key, or the base key of several tiers), keys, rates = { [key] = rate },
---   rate (per second, the sum; > 0 surplus, < 0 short), alternatives },
---   boolean closed, integer solves (linear programs), boolean exhausted (the budget ran out),
---   table? counts { [unit id] = count } with the fixes (every factory forwards),
---   string[] the items of the player's splits in the way (the fixes are without them)
function plan.diagnose(lines, anchors, splits, work)
  local budget = type(work) == "table" and work or plan.new_budget(work)
  local function attempt(list)
    local model_ = lp_model(lines, anchors, list, budget, true)
    return model_, model_.solve_closing({})
  end
  local m, rates, var_counts, import_cost = attempt(splits)
  -- a split of the player's can hold factories at a ratio the plan can't run (recyclers of
  -- every quality at the same copies, scrap tied to a recycler nothing feeds). When the plan
  -- without its splits imports less, the splits its answer breaks are in the way: the fixes
  -- shown are without them (one more program, whatever the number of splits)
  local in_way = {}
  if rates and import_cost > 0 and splits and #splits > 0 then
    local free = lp_model(lines, anchors, {}, budget, true)
    local _, free_counts, _, free_cost = free.run({})
    if free_counts and free_cost < import_cost * (1 - 1e-6) then
      local count_of, flow_of = {}, {}
      for i, v in ipairs(free.vars) do
        if v.unit then
          count_of[v.unit.id] = free_counts[i] or 0
          flow_of[v.unit.id] = v.unit.flow
        end
      end
      local kept = {}
      for _, split in ipairs(splits) do
        -- each line's part of what they make together, against its share
        local made, total, share_sum = {}, 0, 0
        for id, share in pairs(split.shares or {}) do
          local f = flow_of[id] and flow_of[id][split.item] or 0
          if f > 0 and share >= 0 then
            made[id] = f * (count_of[id] or 0)
            total = total + made[id]
            share_sum = share_sum + share
          end
        end
        local broken = false
        for id, part in pairs(made) do
          local want = share_sum > 0 and split.shares[id] / share_sum or 0
          local got = total > 0 and part / total or want
          if math.abs(got - want) > 1e-6 then broken = true end
        end
        if broken then in_way[#in_way + 1] = split.item else kept[#kept + 1] = split end
      end
      if #in_way > 0 then
        local m2, rates2, counts2 = attempt(kept)
        if rates2 then m, rates, var_counts = m2, rates2, counts2 else in_way = {} end
      end
    end
  end
  local run, solve_closing, groups_of, vars_of = m.run, m.solve_closing, m.groups_of, m.vars_of
  if not rates then
    local solves, exhausted = m.status()
    return {}, false, solves, exhausted
  end
  local found, by = groups_of(rates)
  local fixes = {}
  for i, g in ipairs(found) do
    fixes[i] = { item = #g.keys == 1 and g.keys[1] or fp_util.base_key(g.keys[1]), keys = g.keys, rates = g.rates,
      rate = g.rate, alternatives = {} }
  end
  -- alternatives: without this fix, one other item (the same way) does instead
  for i, g in ipairs(found) do
    local forbidden = vars_of(g)
    for _ = 1, 6 do
      -- (an alternative may run a factory only to void its output: "or instead, bricks")
      local other = solve_closing(forbidden, true)
      if not other then break end
      local list, other_by = groups_of(other)
      local new, lost = {}, 0
      for _, h in ipairs(list) do
        if not by[h.id] then new[#new + 1] = h end
      end
      for id in pairs(by) do
        if id ~= g.id and not other_by[id] then lost = lost + 1 end
      end
      if #new ~= 1 or lost > 0 or (new[1].rate > 0) ~= (g.rate > 0) then break end
      local h = new[1]
      fixes[i].alternatives[#fixes[i].alternatives + 1] = #h.keys == 1 and h.keys[1] or fp_util.base_key(h.keys[1])
      for v in pairs(vars_of(h)) do forbidden[v] = true end
    end
    local _, out = m.status()
    if out then break end
  end
  -- out of budget for the alternatives only: the fixes stand
  local solves = m.status()
  local counts = {}
  for i, v in ipairs(m.vars) do
    if v.unit then counts[v.unit.id] = var_counts[i] or 0 end
  end
  return fixes, true, solves, false, counts, in_way
end

--- The rates of a plan's own voids and imports, as the least voided and imported with every
--- factory running forwards and the sinks getting their rates (the linear program, without
--- candidates); nil when it has none.
--- @return table? { [unit id] = rate }
--- @param budget table? plan.new_budget (none: no limit)
--- @return table? rates, boolean? out of budget
function plan.settle_boundaries(lines, anchors, splits, budget)
  local any = false
  for _, line in ipairs(lines) do
    if line.item then any = true end
  end
  if not any then return nil end
  local m = lp_model(lines, anchors, splits, budget, false)
  local _, counts = m.solve_closing({})
  if not counts then
    local _, out = m.status()
    return nil, out
  end
  local rates = {}
  for i, v in ipairs(m.vars) do
    if v.unit and v.unit.item then rates[v.unit.id] = counts[i] or 0 end
  end
  return rates
end

--- Re-run the balance of a plan and cache it in the plan. Sinks are the anchors, at
--- their scale; the plan is closed but for its voids and imports. A void or import
--- takes only what the plan can't do without: where the balance leaves its rate free,
--- it is held at 0 (the factories make what is used, rather than import or void more).
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
  local budget = plan.new_budget(how ~= "full" and plan.AUTO_WORK or nil)
  local no_forward, settle_out = false, false
  if any_free and r.status ~= "CONFLICT" then
    local rates, out = plan.settle_boundaries(lines, anchors, splits, budget)
    if rates then
      for _, uid in ipairs(boundary) do anchors[uid] = rates[uid] or 0 end
      local settled = balance()
      if settled.status ~= "CONFLICT" then r = settled else for _, uid in ipairs(boundary) do anchors[uid] = nil end end
    elseif out then
      settle_out = true -- out of budget: Find a fix works it out
    else
      no_forward = true -- no rates keep every factory forwards
    end
  end
  -- the program found nothing that keeps every factory forwards (the plan is short of an
  -- item, or has too much of it): one free rate at a time, held at 0, the hold that leaves the
  -- least negative; never one that drives a factory negative
  for _ = 1, #boundary do
    local chosen, best = nil, 2
    for _, uid in ipairs(boundary) do
      if anchors[uid] == nil and r.undetermined[uid] then
        anchors[uid] = 0
        local tried = balance()
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
  -- no forward answer, and holding rates at 0 leaves a factory backwards or a choice to make:
  -- the plan can't balance (a split asked for here would only pin a ratio of factories that
  -- can't run, recyclers of byproducts nothing takes); say what would close it instead
  if no_forward and (r.status == "NEEDS_SPLIT" or negative_level(r) == 2) then
    r.status = "CONFLICT"
    for i = #r.problems, 1, -1 do
      local kind = r.problems[i].type
      if kind == "split" or kind == "negative" then table.remove(r.problems, i) end
    end
  end
  -- can't balance: say which items would close it, and how much of each is left or missing
  if settle_out and how ~= "none" then r.complicated = true end
  if r.status == "CONFLICT" and how ~= "none" then
    local fixes, closed, solves, exhausted, counts, in_way = plan.diagnose(lines, anchors, splits, budget)
    if in_way and #in_way > 0 then r.splits_in_way = in_way end
    r.diagnose_solves = solves
    if exhausted and how ~= "full" then
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
  for _, line in ipairs(lines) do
    if line.item and not r.undetermined[line.id] then
      local rate = r.counts[line.id] or 0
      for k, f in pairs(line.flow) do
        if f < 0 and rate > solver.NEGATIVE_TOL then voided[k] = true end
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

-- Research and mod updates --------------------------------------------------------------------

--- Lines of a factory that research or a mod update would change: { [line id] = new flow }.
--- Overridden, custom and old lines (without inputs) are never worked out again (runtime).
function plan.changed_lines(f, force)
  local out, any = {}, false
  if plan.is_list(f) then return out, false end
  for _, line in ipairs(f.lines) do
    if not line.invalid and scanner.has_inputs(line) then
      local flow = scanner.line_flow(line, force)
      if flow and scanner.flows_differ(line.flow, flow) then
        out[line.id] = flow
        any = true
      end
    end
  end
  return out, any
end

--- The force whose research a plan follows (runtime): the player force.
function plan.force()
  return game.forces and (game.forces.player or game.forces[1])
end

--- Factories of a plan whose numbers research (or a mod update) changed, with the copies
--- the plan needs of each before and after (runtime).
--- @return table? { factories = { { id, name, lines, before, after } } } or nil when nothing changes
function plan.pending_changes(key, force)
  force = force or plan.force()
  local p = model.plan(key)
  local override, list = {}, {}
  for _, id in ipairs(model.factory_ids(key)) do
    local f = p.factories[id]
    local changed, any = plan.changed_lines(f, force)
    if any then
      local copy = fp_util.deep_copy(f)
      local n = 0
      for _, line in ipairs(copy.lines) do
        if changed[line.id] then
          line.flow = changed[line.id]
          n = n + 1
        end
      end
      plan.balance_factory(copy)
      override[id] = copy
      list[#list + 1] = { id = id, name = f.name, lines = n }
    end
  end
  if #list == 0 then return nil end
  local before = p.result or plan.solve(key, nil, { diagnose = "none" })
  local after = plan.solve(key, override, { diagnose = "none" })
  for _, entry in ipairs(list) do
    local function needed(r)
      if not r.counts or r.undetermined[entry.id] then return nil end
      return r.counts[entry.id]
    end
    entry.before, entry.after = needed(before), needed(after)
  end
  return { factories = list }
end

--- Write what research changed into the plan's factories (Update all): new flows, a new
--- revision (an open draft of one of them then has a stale save), one log entry (runtime).
--- @return integer factories updated
function plan.apply_pending(key, player_index, force)
  force = force or plan.force()
  local p = model.plan(key)
  local n = 0
  for _, id in ipairs(model.factory_ids(key)) do
    local f = p.factories[id]
    local changed, any = plan.changed_lines(f, force)
    if any then
      for _, line in ipairs(f.lines) do
        if changed[line.id] then line.flow = changed[line.id] end
      end
      f.revision = (f.revision or 0) + 1
      f.modified_by = player_index
      f.modified_tick = game.tick
      plan.balance_factory(f)
      n = n + 1
    end
  end
  if n > 0 then model.log(player_index, { "stoich.log-research-update", n }, nil, key) end
  return n
end

--- Work out again what research changed, for every plan (runtime). Cheap: only plans with a
--- changed line are balanced (twice).
function plan.check_pending()
  storage.pending = {}
  local force = plan.force()
  if not force then return end
  for _, key in ipairs(model.plan_keys()) do storage.pending[key] = plan.pending_changes(key, force) end
end

-- Quality -------------------------------------------------------------------------------------

local function tiered(key)
  return fp_util.quality_of(key) ~= fp_util.NORMAL
end

--- Does a factory have quality: an item of a tier above normal, a recipe or machine of one,
--- or a line with a quality chance?
function plan.factory_has_quality(f)
  for _, line in ipairs(f.lines or {}) do
    if line.recipe_quality or line.machine_quality then return true end
    for key in pairs(line.flow or {}) do
      if tiered(key) then return true end
    end
    for _, v in ipairs(line.variants or {}) do
      if (v.quality_chance or 0) > 0 then return true end
    end
  end
  for _, row in ipairs(f.sink_items or {}) do
    if row.key and tiered(row.key) or row.quality then return true end
  end
  return false
end

--- Does a plan show quality (its pickers, badges, filters)? When some factory has it, or a
--- player turned it on before any capture.
function plan.has_quality(key)
  local p = model.plan(key)
  if p.quality then return true end
  for _, f in pairs(p.factories) do
    if plan.factory_has_quality(f) then return true end
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

--- Void or import rows that stand for exactly these tiers of one item: the key itself for
--- one, else a quality condition over the tiers the plan has of it ("any", ">=rare",
--- "<=epic"), else a row per tier.
--- @param keys string[] keys of one base item
--- @param present table<string, boolean> the plan's keys (plan.present_keys)
--- @return table[] rows { key, quality? }
function plan.condition_rows(keys, present)
  if #keys == 1 then return { { key = keys[1] } } end
  local base = fp_util.base_key(keys[1])
  local wanted, all = {}, {}
  for _, k in ipairs(keys) do wanted[k] = true end
  for k in pairs(present) do
    if fp_util.base_key(k) == base then all[#all + 1] = k end
  end
  for _, k in ipairs(keys) do
    if not present[k] then all[#all + 1] = k end
  end
  table.sort(all, fp_util.key_less)
  local sorted = fp_util.sorted_keys(wanted, fp_util.key_less)
  local low, high = fp_util.quality_of(sorted[1]), fp_util.quality_of(sorted[#sorted])
  -- "any" only when it means from normal up (it would also take a tier the plan gets later)
  local conds = { ">=" .. low, "<=" .. high }
  if low == fp_util.NORMAL then conds[1] = "any" end
  for _, cond in ipairs(conds) do
    local same = true
    for _, k in ipairs(all) do
      if plan.matches_condition(k, base, cond) ~= (wanted[k] == true) then same = false break end
    end
    if same then return { { key = base, quality = cond } } end
  end
  local rows = {}
  for _, k in ipairs(sorted) do rows[#rows + 1] = { key = k } end
  return rows
end

--- Rate of each item of a void or import in its plan's balance (per second, never
--- negative unless the plan is short of it).
function plan.boundary_rates(f, r)
  local rates = {}
  for _, item in ipairs(plan.boundary_items(f)) do rates[item] = 0 end
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
