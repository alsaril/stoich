-- The plan as a linear program (scripts/lp.lua), used two ways (docs/solver.md):
-- settling the rates of a plan's own voids and imports (plan_lp.settle_boundaries), and
-- what would close a plan that can't balance (plan_lp.diagnose).
--
-- Every factory's copies and every void and import are variables, all >= 0 (no factory
-- backwards); every item balances and the sinks get their rates. The least voided per second
-- wins; imports cost far more than voids (the factories make what they can), importing what a
-- sink asks for most of all. Exact and deterministic: no search.

local solver = require("scripts.solver")
local fp_util = require("scripts.util")
local lp = require("scripts.lp")

local plan_lp = {}

-- Costs per item (or fluid unit) a second: voiding what nothing uses is cheapest, voiding
-- what a factory could still use dearer (the surplus is voided at the end of its chain: the
-- factories make what they can, and the plan stays settled), importing what nothing makes
-- dearer still, importing what a factory could make more, what a sink asks for most; running
-- a factory costs a little.
plan_lp.FIX_COSTS = { void = 1, void_used = 3, import = 1000, import_made = 1e5, demanded = 1e7, factory = 1e-3 }
-- Work one plan balance may do in linear programs (Find a fix has no limit): settling the
-- voids' rates and the whole diagnosis share it. Pivots x rows x columns, ~0.02 us each in
-- plain Lua 5.5 on an M-series Mac, so ~1 s at most. Out of budget, the alternatives ("or
-- instead") stop; a plan that runs out before its first fixes is marked complicated.
plan_lp.AUTO_WORK = 50000000

--- A work budget shared by the linear programs of one balance.
--- @param work number? nil: no limit
function plan_lp.new_budget(work)
  return { work = work, spent = 0, exhausted = false }
end

-- The two uses of the program, spelled out:
-- SETTLE: only the plan's own units; its voids and imports cost what a suggested one would,
--   and the closing rules may ban the plan's own void of an item.
-- DIAGNOSE: a suggested void for every item made and an import for every item used; the
--   plan's own voids and imports are free (they are there already) and stay as they are:
--   the rules ban only suggested voids.
local SETTLE = { suggest = false, own_free = false, ban_own_voids = true }
local DIAGNOSE = { suggest = true, own_free = true, ban_own_voids = false }

local function id_order(a, b) return solver.id_less(a, b) end

-- The model -----------------------------------------------------------------------------------

--- The program's items, variables and split rows for a plan.
--- @param kind table SETTLE or DIAGNOSE
--- @return table model
local function new_model(lines, anchors, splits, budget, kind)
  local M = { kind = kind, budget = budget or plan_lp.new_budget(nil), solves = 0, fixed = {}, units = {}, by_id = {} }
  for _, line in ipairs(lines) do
    M.by_id[line.id] = line
    if line.sink and anchors[line.id] ~= nil then M.fixed[line.id] = anchors[line.id] else M.units[#M.units + 1] = line end
  end
  table.sort(M.units, function(x, y) return id_order(x.id, y.id) end)

  -- items: who makes and uses them, their scale, what the sinks ask for
  local made, used, scale, demanded, consumed = {}, {}, {}, {}, {}
  for _, line in ipairs(lines) do
    for k, v in pairs(line.flow) do
      if v > 0 then made[k] = true elseif v < 0 then used[k] = true end
      if v < 0 and not line.sink and not line.item then consumed[k] = true end
      if line.sink then demanded[k] = true end
      local a = math.abs(v) * (M.fixed[line.id] and math.max(M.fixed[line.id], 1e-9) or 1)
      if a > (scale[k] or 0) then scale[k] = a end
    end
  end
  M.made, M.used, M.scale, M.demanded, M.consumed = made, used, scale, demanded, consumed
  -- wanted: what a factory uses or a sink asks for (a byproduct nothing uses isn't)
  M.wanted = {}
  for k in pairs(consumed) do M.wanted[k] = true end
  for k in pairs(demanded) do M.wanted[k] = true end
  M.keys = {}
  for k in pairs(scale) do M.keys[#M.keys + 1] = k end
  table.sort(M.keys, fp_util.key_less)
  M.row_of = {}
  for i, k in ipairs(M.keys) do M.row_of[k] = i end

  -- variables: the units, then (diagnosing) a void and an import per item
  M.vars = {}
  for _, u in ipairs(M.units) do M.vars[#M.vars + 1] = { unit = u } end
  if kind.suggest then
    for _, k in ipairs(M.keys) do
      if made[k] then M.vars[#M.vars + 1] = { key = k, sign = -1 } end
      if used[k] then M.vars[#M.vars + 1] = { key = k, sign = 1 } end
    end
  end

  -- the void of an item the closing rules may ban: a suggested one, or (settling) the plan's own
  M.void_var = {}
  for i, v in ipairs(M.vars) do
    if v.key and v.sign < 0 then M.void_var[v.key] = i end
    if kind.ban_own_voids and v.unit and v.unit.item and (v.unit.flow[v.unit.item] or 0) < 0 and not M.void_var[v.unit.item] then
      M.void_var[v.unit.item] = i
    end
  end

  -- the splits, as the balance has them: each line's share of what they make together
  M.split_rows = {}
  for _, split in ipairs(splits or {}) do
    local ids, total = {}, 0
    for id, share in pairs(split.shares or {}) do
      local line = M.by_id[id]
      if line and (line.flow[split.item] or 0) > 0 and share >= 0 then
        ids[#ids + 1] = id
        total = total + share
      end
    end
    table.sort(ids, id_order)
    if #ids >= 2 and total > 0 then
      for i = 1, #ids - 1 do
        local terms = { [ids[i]] = M.by_id[ids[i]].flow[split.item] }
        local s = split.shares[ids[i]] / total
        for _, id in ipairs(ids) do terms[id] = (terms[id] or 0) - s * M.by_id[id].flow[split.item] end
        M.split_rows[#M.split_rows + 1] = terms
      end
    end
  end
  return M
end

--- Per item a second, what is voided or imported, as the player counts it.
local function boundary_cost(M, key, sign)
  local C = plan_lp.FIX_COSTS
  if sign < 0 then return M.consumed[key] and C.void_used or C.void end
  if M.demanded[key] then return C.demanded end
  if M.made[key] then return C.import_made end
  return C.import
end

local function cost(M, v)
  if v.unit then
    if v.unit.item then
      if M.kind.own_free then return 0 end
      return boundary_cost(M, v.unit.item, v.unit.flow[v.unit.item] or -1)
    end
    if v.unit.sink then return 0 end
    -- running a factory costs a little: a surplus is voided where it comes out
    return plan_lp.FIX_COSTS.factory
  end
  return boundary_cost(M, v.key, v.sign)
end

-- Solving -------------------------------------------------------------------------------------

--- One linear program without the forbidden variables.
--- @return table? rates (suggested voids > 0 and imports < 0, by key), table counts (by
---   variable), table voided (by key, the plan's voids too), number import_cost; nil: no
---   answer (budget.exhausted: out of budget or pivots, else infeasible)
local function run(M, forbidden)
  local budget = M.budget
  if budget.work and budget.spent >= budget.work then
    budget.exhausted = true
    return nil
  end
  local cols, c = {}, {}
  for i, v in ipairs(M.vars) do
    if not forbidden[i] then
      cols[#cols + 1] = i
      c[#c + 1] = cost(M, v)
    end
  end
  local A, b = {}, {}
  for i = 1, #M.keys do A[i], b[i] = {}, 0 end
  for j, i in ipairs(cols) do
    local v = M.vars[i]
    if v.unit then
      for k, x in pairs(v.unit.flow) do
        local r = M.row_of[k]
        A[r][j] = (A[r][j] or 0) + x
      end
    else
      local r = M.row_of[v.key]
      A[r][j] = (A[r][j] or 0) + v.sign
    end
  end
  for id, count in pairs(M.fixed) do
    for k, x in pairs(M.by_id[id].flow) do b[M.row_of[k]] = b[M.row_of[k]] - x * count end
  end
  local col_of_unit = {}
  for j, i in ipairs(cols) do
    if M.vars[i].unit then col_of_unit[M.vars[i].unit.id] = j end
  end
  for _, terms in ipairs(M.split_rows) do
    local row, rhs = {}, 0
    for id, coef in pairs(terms) do
      if M.fixed[id] then rhs = rhs - coef * M.fixed[id]
      elseif col_of_unit[id] then row[col_of_unit[id]] = (row[col_of_unit[id]] or 0) + coef end
    end
    A[#A + 1], b[#b + 1] = row, rhs
  end
  M.solves = M.solves + 1
  local x, pivots, why = lp.minimize(c, A, b, #cols)
  budget.spent = budget.spent + (pivots or 0) * #A * (#cols + #A)
  -- out of pivots says nothing about the plan, and no budget helps: too complicated
  if why == "pivots" then budget.exhausted, budget.pivots = true, true end
  if not x then return nil end
  local rates, counts, voided, import_cost = {}, {}, {}, 0
  for j, i in ipairs(cols) do
    local v = M.vars[i]
    if not v.unit and v.sign > 0 then import_cost = import_cost + c[j] * x[j] end
    if v.unit then
      counts[i] = x[j]
      if v.unit.item and x[j] > 0 then
        for k, f in pairs(v.unit.flow) do
          if f < 0 then voided[k] = (voided[k] or 0) - f * x[j] end
        end
      end
    elseif x[j] > 1e-9 * math.max(M.scale[v.key], 1) then
      rates[v.key] = (rates[v.key] or 0) - v.sign * x[j]
      if v.sign < 0 then voided[v.key] = (voided[v.key] or 0) + x[j] end
    end
  end
  return rates, counts, voided, import_cost
end

--- The program with the two rules the costs can't express, by solving again:
--- 1. no factory only to void: one whose output is all voided (bricks from stone nobody needs)
---    doesn't run; the surplus is voided where it comes out;
--- 2. no factory beyond need: one whose every wanted output is partly voided turns a surplus
---    into something to void (batteries into accumulators): those outputs aren't voided, so
---    it runs for what is used. A byproduct nothing uses (a recycler's rare plates) doesn't count.
--- The rules are preferences: a ban that leaves no answer at all is undone, not made again,
--- and the last answer stands.
--- @param keep_pointless boolean? no rule 1 (an alternative: "or instead, bricks")
--- @return table? rates, table counts, number import_cost
local function solve_closing(M, forbidden, keep_pointless)
  local kept, last, step = {}, nil, nil
  local function ban(i)
    if kept[i] or forbidden[i] then return false end
    forbidden[i] = true
    step[#step + 1] = i
    return true
  end
  for _ = 1, 2 * #M.vars + 2 do
    local rates, counts, voided, import_cost = run(M, forbidden)
    if not rates then
      if M.budget.exhausted or not last then return nil end
      for _, i in ipairs(step) do
        forbidden[i] = nil
        kept[i] = true
      end
      rates, counts, voided, import_cost = last[1], last[2], last[3], last[4]
    end
    last, step = { rates, counts, voided, import_cost }, {}
    local changed = false
    for i, v in ipairs(M.vars) do
      local u = v.unit
      if u and not u.item and not u.sink and (counts[i] or 0) > 1e-9 then
        local any, all_voided, wanted, all_partly = false, true, false, true
        for k, f in pairs(u.flow) do
          if f > 0 then
            any = true
            local out = voided[k] or 0
            if not (out > 0 and out >= f * counts[i] * (1 - 1e-9)) then all_voided = false end
            if M.wanted[k] then
              wanted = true
              if not (out > 0) then all_partly = false end
            end
          end
        end
        if any and all_voided and not keep_pointless then
          if ban(i) then changed = true end
        elseif wanted and all_partly and not all_voided then
          for k, f in pairs(u.flow) do
            if f > 0 and M.wanted[k] and M.void_var[k] and ban(M.void_var[k]) then changed = true end
          end
        end
      end
      if changed then break end
    end
    if not changed then return rates, counts, import_cost end
  end
  return nil
end

-- Fixes ---------------------------------------------------------------------------------------

--- An item's tiers that go the same way are one fix.
--- @return table[] groups { id, keys, rates, rate }, table by id
local function groups_of(M, rates)
  local list, by = {}, {}
  for _, k in ipairs(M.keys) do
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

--- The suggested variables of a fix (its voids, or its imports).
local function vars_of(M, g)
  local set = {}
  for i, v in ipairs(M.vars) do
    if v.key and g.rates[v.key] and (v.sign < 0) == (g.rate > 0) then set[i] = true end
  end
  return set
end

local function fix_name(g)
  return #g.keys == 1 and g.keys[1] or fp_util.base_key(g.keys[1])
end

--- The splits a split-free answer breaks: a line's part of the item off its share.
local function broken_splits(M, counts, splits)
  local count_of = {}
  for i, v in ipairs(M.vars) do
    if v.unit then count_of[v.unit.id] = counts[i] or 0 end
  end
  local broken, kept = {}, {}
  for _, split in ipairs(splits) do
    local made, total, share_sum = {}, 0, 0
    for id, share in pairs(split.shares or {}) do
      local line = M.by_id[id]
      local f = line and line.flow[split.item] or 0
      if f > 0 and share >= 0 then
        made[id] = f * (count_of[id] or 0)
        total = total + made[id]
        share_sum = share_sum + share
      end
    end
    local off = false
    for id, part in pairs(made) do
      local want = share_sum > 0 and split.shares[id] / share_sum or 0
      local got = total > 0 and part / total or want
      if math.abs(got - want) > 1e-6 then off = true end
    end
    if off then broken[#broken + 1] = split.item else kept[#kept + 1] = split end
  end
  return broken, kept
end

--- What would close a plan that can't balance.
--- @param lines table[] the plan's units
--- @param anchors table the balance's anchors (only the sinks' count here)
--- @param splits table[] the plan's splits
--- @param work number|table|nil a budget (pivots x rows x columns, or plan_lp.new_budget); nil: none
--- @return table[] fixes { item (the key, or the base key of several tiers), keys, rates = { [key] = rate },
---   rate (per second, the sum; > 0 surplus, < 0 short), alternatives },
---   boolean closed, integer solves (linear programs), boolean exhausted (the budget ran out),
---   table? counts { [unit id] = count } with the fixes (every factory forwards),
---   string[] the items of the player's splits in the way (the fixes are without them)
function plan_lp.diagnose(lines, anchors, splits, work)
  local budget = type(work) == "table" and work or plan_lp.new_budget(work)
  local function attempt(list)
    local M = new_model(lines, anchors, list, budget, DIAGNOSE)
    return M, solve_closing(M, {})
  end
  local M, rates, var_counts, import_cost = attempt(splits)
  -- a split of the player's can hold factories at a ratio the plan can't run (recyclers of
  -- every quality at the same copies, scrap tied to a recycler nothing feeds). When the plan
  -- without its splits imports less, the splits its answer breaks are in the way: the fixes
  -- shown are without them (one more program, whatever the number of splits)
  local in_way = {}
  if rates and import_cost > 0 and splits and #splits > 0 then
    local free = new_model(lines, anchors, {}, budget, DIAGNOSE)
    local _, free_counts, _, free_cost = run(free, {})
    if free_counts and free_cost < import_cost * (1 - 1e-6) then
      local kept
      in_way, kept = broken_splits(free, free_counts, splits)
      if #in_way > 0 then
        local M2, rates2, counts2 = attempt(kept)
        if rates2 then M, rates, var_counts = M2, rates2, counts2 else in_way = {} end
      end
    end
  end
  if not rates then return {}, false, M.solves, M.budget.exhausted end
  local found, by = groups_of(M, rates)
  local fixes = {}
  for i, g in ipairs(found) do
    fixes[i] = { item = fix_name(g), keys = g.keys, rates = g.rates, rate = g.rate, alternatives = {} }
  end
  -- alternatives: without this fix, one other item (the same way) does instead
  for i, g in ipairs(found) do
    local forbidden = vars_of(M, g)
    for _ = 1, 6 do
      -- (an alternative may run a factory only to void its output: "or instead, bricks")
      local other = solve_closing(M, forbidden, true)
      if not other then break end
      local list, other_by = groups_of(M, other)
      local new, lost = {}, 0
      for _, h in ipairs(list) do
        if not by[h.id] then new[#new + 1] = h end
      end
      for id in pairs(by) do
        if id ~= g.id and not other_by[id] then lost = lost + 1 end
      end
      if #new ~= 1 or lost > 0 or (new[1].rate > 0) ~= (g.rate > 0) then break end
      local h = new[1]
      fixes[i].alternatives[#fixes[i].alternatives + 1] = fix_name(h)
      for v in pairs(vars_of(M, h)) do forbidden[v] = true end
    end
    -- out of budget for the alternatives only: the fixes stand
    if M.budget.exhausted then break end
  end
  local counts = {}
  for i, v in ipairs(M.vars) do
    if v.unit then counts[v.unit.id] = var_counts[i] or 0 end
  end
  return fixes, true, M.solves, false, counts, in_way
end

--- The rates of a plan's own voids and imports, as the least voided and imported with every
--- factory running forwards and the sinks getting their rates.
--- @param budget table? plan_lp.new_budget (none: no limit)
--- @return table? rates { [unit id] = rate } (nil: the plan has no void or import, or no
---   answer keeps every factory forwards), boolean? out of budget
function plan_lp.settle_boundaries(lines, anchors, splits, budget)
  local any = false
  for _, line in ipairs(lines) do
    if line.item then any = true end
  end
  if not any then return nil end
  local M = new_model(lines, anchors, splits, budget, SETTLE)
  local _, counts = solve_closing(M, {})
  if not counts then return nil, M.budget.exhausted end
  local rates = {}
  for i, v in ipairs(M.vars) do
    if v.unit and v.unit.item then rates[v.unit.id] = counts[i] or 0 end
  end
  return rates
end

return plan_lp
