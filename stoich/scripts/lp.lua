-- A small linear program solver (two-phase simplex): minimize c·x subject to
-- A x = b, x >= 0. Pure and deterministic (fixed pivot order), for plans of a few hundred
-- variables. Used to settle a plan's void and import rates and to find what would close a
-- plan that can't balance (plan_lp).
--
-- The tableau keeps its objective row up to date with each pivot (not worked out again for
-- every column each step), and a pivot touches only the pivot row's non-zero columns: a
-- plan's rows are mostly zeros (each item is made and used by a few units). Bland's rule
-- (the first improving column, the lowest basis index on a tie) can't cycle, and the same
-- program always takes the same pivots. (Dantzig's rule, the most improving column, was
-- tried: on real plans it did no less work overall and stalled on one.)

local lp = {}

local EPS = 1e-9
-- the objective row is worked out again from the tableau this often (rounding drift)
local REFRESH = 64

--- @param c number[] costs (n)
--- @param A table[] rows (m) of { [j] = coefficient } (sparse)
--- @param b number[] right-hand sides (m)
--- @param n integer variables
--- @param max_iter integer? pivots allowed (default 50 x (m + n))
--- @param max_work number? work allowed (a budget's rest); nil: no limit
--- @return number[]? x the optimum, integer pivots, string? why there is none: "infeasible"
---   (no x >= 0 meets the rows), "pivots" (out of pivots) or "work" (out of work allowed),
---   integer work (arithmetic operations done: what a budget counts)
function lp.minimize(c, A, b, n, max_iter, max_work)
  local m = #A
  max_iter = max_iter or 50 * (m + n)
  -- tableau: m rows over n + m columns (the artificials), right-hand side last
  local width = n + m + 1
  local T = {}
  for i = 1, m do
    local row = {}
    for j = 1, width do row[j] = 0 end
    local sign = (b[i] or 0) < 0 and -1 or 1
    for j, v in pairs(A[i]) do row[j] = sign * v end
    row[n + i] = 1
    row[width] = sign * (b[i] or 0)
    T[i] = row
  end
  local basis = {}
  for i = 1, m do basis[i] = n + i end
  local pivots, work = 0, m * width

  -- reduced costs for these costs, from the tableau as it is: z_j = cost_j - cB · column j
  local function objective(cost)
    local z = {}
    for j = 1, width - 1 do z[j] = cost[j] or 0 end
    z[width] = 0
    for i = 1, m do
      local cb = cost[basis[i]] or 0
      if cb ~= 0 then
        local row = T[i]
        for j = 1, width do
          local v = row[j]
          if v ~= 0 then z[j] = z[j] - cb * v end
        end
      end
    end
    work = work + m * width
    return z
  end

  local function pivot(r, col, z)
    local pr = T[r]
    local p = pr[col]
    -- the pivot row's non-zero columns: the only ones a row changes in
    local nz = {}
    for j = 1, width do
      local v = pr[j]
      if v ~= 0 then
        pr[j] = v / p
        nz[#nz + 1] = j
      end
    end
    pr[col] = 1
    local k = #nz
    for i = 1, m do
      if i ~= r then
        local row = T[i]
        local f = row[col]
        if f ~= 0 then
          for q = 1, k do
            local j = nz[q]
            row[j] = row[j] - f * pr[j]
          end
          row[col] = 0
          work = work + k
        end
      end
    end
    if z then
      local f = z[col]
      if f ~= 0 then
        for q = 1, k do
          local j = nz[q]
          z[j] = z[j] - f * pr[j]
        end
        z[col] = 0
      end
    end
    work = work + width
    basis[r] = col
    pivots = pivots + 1
  end

  -- minimize cost over the columns allowed (cols[j] true); returns nil when done, else why
  -- it stopped ("pivots", "work")
  local function run(cost, cols)
    local z = objective(cost)
    local since = 0
    while true do
      if pivots >= max_iter then return "pivots" end
      if max_work and work >= max_work then return "work" end
      if since >= REFRESH then
        z = objective(cost)
        since = 0
      end
      -- the entering column, Bland's: the first that improves; one with no row to pivot on
      -- (only entries at rounding level) is set aside, not taken for the optimum
      local enter, leave, best
      local skip = {}
      while true do
        enter = nil
        for j = 1, width - 1 do
          if cols[j] and not skip[j] and z[j] < -EPS then
            enter = j
            break
          end
        end
        work = work + width
        if not enter then break end
        leave, best = nil, nil
        for i = 1, m do
          local a = T[i][enter]
          if a > EPS then
            local ratio = T[i][width] / a
            if not best or ratio < best - EPS or (math.abs(ratio - best) <= EPS and basis[i] < basis[leave]) then
              leave, best = i, ratio
            end
          end
        end
        work = work + m
        if leave then break end
        skip[enter] = true
      end
      if leave then
        pivot(leave, enter, z)
        since = since + 1
      elseif since > 0 then
        -- optimal (or unbounded, which costs >= 0 rule out) by a row kept up to date through
        -- pivots: check it against one worked out afresh (rounding drift can end too early)
        z = objective(cost)
        since = 0
      else
        return nil
      end
    end
  end

  -- phase 1: the artificials out
  local cost1, all = {}, {}
  for j = 1, n + m do all[j] = true end
  for i = 1, m do cost1[n + i] = 1 end
  local stop = run(cost1, all)
  if stop then return nil, pivots, stop, work end
  local infeasibility = 0
  for i = 1, m do
    if basis[i] > n then infeasibility = infeasibility + T[i][width] end
  end
  if infeasibility > 1e-7 then return nil, pivots, "infeasible", work end
  -- an artificial left in the basis at 0: pivot it out on any real column
  for i = 1, m do
    if basis[i] > n then
      for j = 1, n do
        if math.abs(T[i][j]) > EPS then
          pivot(i, j, nil)
          break
        end
      end
    end
  end
  -- phase 2: the costs, real columns only
  local real = {}
  for j = 1, n do real[j] = true end
  stop = run(c, real)
  if stop then return nil, pivots, stop, work end
  local x = {}
  for j = 1, n do x[j] = 0 end
  for i = 1, m do
    if basis[i] <= n then x[basis[i]] = T[i][width] end
  end
  return x, pivots, nil, work
end

return lp
