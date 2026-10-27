local t = require("tests.t")
local linalg = require("scripts.linalg")

t.test("linalg: square system", function()
  -- x + y = 3, x - y = 1
  local r = linalg.rref({ { 1, 1 }, { 1, -1 } }, { 3, 1 }, 2)
  t.eq(r.rank, 2)
  t.eq(#r.free, 0)
  t.eq(#r.inconsistent, 0)
  t.near(r.solution[1], 2)
  t.near(r.solution[2], 1)
end)

t.test("linalg: underdetermined gives free column and null vector", function()
  -- x + y = 2
  local r = linalg.rref({ { 1, 1 } }, { 2 }, 2)
  t.eq(r.rank, 1)
  t.eq(#r.free, 1)
  t.eq(r.free[1], 2)
  local v = r.null(2)
  t.near(v[1], -1)
  t.near(v[2], 1)
end)

t.test("linalg: inconsistent row knows its origin", function()
  -- x = 1, 2x = 3, y = 5
  local r = linalg.rref({ { 1, 0 }, { 0, 1 }, { 2, 0 } }, { 1, 5, 3 }, 2)
  t.eq(r.rank, 2)
  t.eq(#r.inconsistent, 1)
  local origin = r.inconsistent[1].origin
  table.sort(origin)
  t.eq(#origin, 2)
  t.eq(origin[1], 1)
  t.eq(origin[2], 3)
end)

t.test("linalg: consistent dependent rows are not conflicts", function()
  local r = linalg.rref({ { 1, 2 }, { 2, 4 }, { 1, 0 } }, { 3, 6, 1 }, 2)
  t.eq(r.rank, 2)
  t.eq(#r.inconsistent, 0)
  t.near(r.solution[1], 1)
  t.near(r.solution[2], 1)
end)

t.test("linalg: tolerance scales with large flows", function()
  -- 3159 ore/s style magnitudes with a tiny relative error stay consistent
  local r = linalg.rref({ { 3159, -1e-3 }, { 6318, -2e-3 } }, { 3159, 6318 * (1 + 1e-12) }, 2)
  t.eq(#r.inconsistent, 0)
end)

t.test("linalg: no unknowns", function()
  local r = linalg.rref({ {}, {} }, { 0, 2 }, 0)
  t.eq(r.rank, 0)
  t.eq(#r.inconsistent, 1)
  t.eq(r.inconsistent[1].origin[1], 2)
end)
