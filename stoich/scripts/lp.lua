-- A small linear program solver (two-phase simplex, Bland's rule): minimize c·x subject to
-- A x = b, x >= 0. Pure and deterministic (fixed pivot order), for plans of a few hundred
-- variables. Used to find the least voiding that closes a plan (plan.diagnose).

local lp = {}

local EPS = 1e-9

--- @param c number[] costs (n)
--- @param A table[] rows (m) of { [j] = coefficient } (sparse)
--- @param b number[] right-hand sides (m)
--- @param n integer variables
--- @param max_iter integer? pivots allowed (default 50 x (m + n))
--- @return number[]? x the optimum (nil: infeasible, or out of pivots), integer pivots
function lp.minimize(c, A, b, n, max_iter)
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
  local pivots = 0

  local function pivot(r, col)
    local pr = T[r]
    local p = pr[col]
    for j = 1, width do pr[j] = pr[j] / p end
    for i = 1, m do
      if i ~= r then
        local row = T[i]
        local f = row[col]
        if f ~= 0 then
          for j = 1, width do row[j] = row[j] - f * pr[j] end
        end
      end
    end
    basis[r] = col
    pivots = pivots + 1
  end

  -- minimize cost over the columns allowed (cols[j] true); returns false when out of pivots
  local function run(cost, cols)
    while true do
      if pivots >= max_iter then return false end
      -- reduced costs: cost_j - cB · column j
      local enter
      for j = 1, width - 1 do
        if cols[j] then
          local z = cost[j] or 0
          for i = 1, m do
            local cb = cost[basis[i]] or 0
            if cb ~= 0 then z = z - cb * T[i][j] end
          end
          if z < -EPS then enter = j break end -- Bland: the first that improves
        end
      end
      if not enter then return true end
      local leave, best
      for i = 1, m do
        local a = T[i][enter]
        if a > EPS then
          local ratio = T[i][width] / a
          if not best or ratio < best - EPS or (math.abs(ratio - best) <= EPS and basis[i] < basis[leave]) then
            leave, best = i, ratio
          end
        end
      end
      if not leave then return true end -- unbounded below: can't happen with cost >= 0
      pivot(leave, enter)
    end
  end

  -- phase 1: the artificials out
  local cost1, all = {}, {}
  for j = 1, n + m do all[j] = true end
  for i = 1, m do cost1[n + i] = 1 end
  if not run(cost1, all) then return nil, pivots end
  local infeasibility = 0
  for i = 1, m do
    if basis[i] > n then infeasibility = infeasibility + T[i][width] end
  end
  if infeasibility > 1e-7 then return nil, pivots end
  -- an artificial left in the basis at 0: pivot it out on any real column
  for i = 1, m do
    if basis[i] > n then
      for j = 1, n do
        if math.abs(T[i][j]) > EPS then
          pivot(i, j)
          break
        end
      end
    end
  end
  -- phase 2: the costs, real columns only
  local real = {}
  for j = 1, n do real[j] = true end
  if not run(c, real) then return nil, pivots end
  local x = {}
  for j = 1, n do x[j] = 0 end
  for i = 1, m do
    if basis[i] <= n then x[basis[i]] = T[i][width] end
  end
  return x, pivots
end

return lp
