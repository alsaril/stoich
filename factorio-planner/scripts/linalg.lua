-- Gaussian elimination to reduced row echelon form with row origins.
-- Pure Lua, arithmetic only: deterministic and runnable outside the game.

local linalg = {}

local abs = math.abs

-- Pivots below PIVOT_TOL * (largest entry of the original column) count as zero.
linalg.PIVOT_TOL = 1e-9
-- A zero row is inconsistent when its right-hand side exceeds RHS_TOL times the
-- magnitude of the right-hand sides it was combined from.
linalg.RHS_TOL = 1e-7

--- Reduce [A | b | I] to RREF with partial pivoting.
--- @param A number[][] m rows of n coefficients (missing entries count as 0)
--- @param b number[] m right-hand sides
--- @param n integer number of unknowns (columns of A)
--- @return table result
---   rank, pivot_col[row] = col, pivot_row[col] = row, free = {col...},
---   solution[col] (free columns = 0), inconsistent = { {row, rhs, origin = {eq...}} },
---   null(col) -> vector with that free column at 1 and the other free columns at 0
function linalg.rref(A, b, n)
  local m = #A
  local width = n + 1 + m
  local R = {}
  local col_max = {}
  for j = 1, n do col_max[j] = 0 end
  for i = 1, m do
    local src = A[i]
    local row = {}
    for j = 1, n do
      local v = src[j] or 0
      row[j] = v
      if abs(v) > col_max[j] then col_max[j] = abs(v) end
    end
    row[n + 1] = b[i] or 0
    for k = 1, m do row[n + 1 + k] = 0 end
    row[n + 1 + i] = 1
    R[i] = row
  end

  local pivot_col, pivot_row = {}, {}
  local r = 1
  for c = 1, n do
    if r > m then break end
    local tol = linalg.PIVOT_TOL * col_max[c]
    local best, best_i = 0, nil
    for i = r, m do
      local v = abs(R[i][c])
      if v > best then best, best_i = v, i end
    end
    if best_i and best > tol and best > 0 then
      R[r], R[best_i] = R[best_i], R[r]
      local prow = R[r]
      local p = prow[c]
      for j = 1, width do prow[j] = prow[j] / p end
      prow[c] = 1
      for i = 1, m do
        if i ~= r then
          local row = R[i]
          local f = row[c]
          if f ~= 0 then
            for j = 1, width do
              local v = prow[j]
              if v ~= 0 then row[j] = row[j] - f * v end
            end
            row[c] = 0
          end
        end
      end
      pivot_col[r] = c
      pivot_row[c] = r
      r = r + 1
    else
      -- Column is (numerically) dependent: clear the noise below the pivot line.
      for i = r, m do R[i][c] = 0 end
    end
  end
  local rank = r - 1

  local free = {}
  for c = 1, n do
    if not pivot_row[c] then free[#free + 1] = c end
  end

  local solution = {}
  for c = 1, n do solution[c] = 0 end
  for row = 1, rank do solution[pivot_col[row]] = R[row][n + 1] end

  local inconsistent = {}
  for i = rank + 1, m do
    local row = R[i]
    local rhs = row[n + 1]
    local scale, emax = 0, 0
    for k = 1, m do
      local e = row[n + 1 + k]
      scale = scale + abs(e * (b[k] or 0))
      if abs(e) > emax then emax = abs(e) end
    end
    if abs(rhs) > linalg.RHS_TOL * scale and abs(rhs) > 1e-12 then
      local origin = {}
      for k = 1, m do
        if abs(row[n + 1 + k]) > linalg.PIVOT_TOL * emax then origin[#origin + 1] = k end
      end
      inconsistent[#inconsistent + 1] = { row = i, rhs = rhs, origin = origin }
    end
  end

  local function null(f)
    local v = {}
    for c = 1, n do v[c] = 0 end
    v[f] = 1
    for row = 1, rank do v[pivot_col[row]] = -R[row][f] end
    return v
  end

  return {
    rank = rank,
    pivot_col = pivot_col,
    pivot_row = pivot_row,
    free = free,
    solution = solution,
    inconsistent = inconsistent,
    null = null,
    matrix = R,
  }
end

return linalg
