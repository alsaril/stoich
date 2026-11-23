local t = require("tests.t")
local lp = require("scripts.lp")

t.test("lp: the least cost that meets the equations", function()
  -- x1 + x2 = 4, x1 - x3 = 1, minimize x2 + 2 x3: x1 = 1, x2 = 3 costs 3; x1 = 4, x3 = 3 costs 6
  local x = lp.minimize({ 0, 1, 2 }, { { [1] = 1, [2] = 1 }, { [1] = 1, [3] = -1 } }, { 4, 1 }, 3)
  t.near(x[1], 1) t.near(x[2], 3) t.near(x[3], 0)
  -- with x3 cheaper than x2 the other vertex wins
  x = lp.minimize({ 0, 3, 1 }, { { [1] = 1, [2] = 1 }, { [1] = 1, [3] = -1 } }, { 4, 1 }, 3)
  t.near(x[1], 4) t.near(x[2], 0) t.near(x[3], 3)
  -- infeasible: x1 = -1
  local none, _, why = lp.minimize({ 0 }, { { [1] = 1 } }, { -1 }, 1)
  t.eq(none, nil)
  t.eq(why, "infeasible")
  -- out of pivots: no answer, and it says so
  none, _, why = lp.minimize({ 0, 1, 2 }, { { [1] = 1, [2] = 1 }, { [1] = 1, [3] = -1 } }, { 4, 1 }, 3, 0)
  t.eq(none, nil)
  t.eq(why, "pivots")
  -- a negative right-hand side that is fine: -x1 = -2
  x = lp.minimize({ 1 }, { { [1] = -1 } }, { -2 }, 1)
  t.near(x[1], 2)
end)

t.test("lp: degenerate and redundant rows", function()
  -- x1 + x2 = 2 twice; minimize x1: x2 = 2
  local x = lp.minimize({ 1, 0 }, { { [1] = 1, [2] = 1 }, { [1] = 1, [2] = 1 } }, { 2, 2 }, 2)
  t.near(x[1], 0) t.near(x[2], 2)
  -- 0 = 0
  x = lp.minimize({ 1 }, { {} }, { 0 }, 1)
  t.near(x[1], 0)
end)
