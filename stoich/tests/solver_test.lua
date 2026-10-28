local t = require("tests.t")
local solver = require("scripts.solver")
local json = require("tests.json")

local function find_problem(result, kind)
  for _, p in ipairs(result.problems) do
    if p.type == kind then return p end
  end
end

-- Ported from FactoryLogicTest.kt: `should solve exact system`.
t.test("solver: exact system", function()
  local lines = {
    { id = "a3", flow = { a1 = -1, a2 = -3, a3 = 5 } },
    { id = "a4", flow = { a2 = -1, a3 = -2, a4 = 2 } },
    { id = "a5", flow = { a1 = -2, a4 = -1, a5 = 1 } },
  }
  local r = solver.balance(lines, { a4 = 5 }, {}, { a1 = true, a2 = true, a5 = true })
  t.eq(r.status, "EXACT")
  t.map_near(r.counts, { a3 = 2, a4 = 5, a5 = 10 })
  t.map_near(r.net, { a1 = -22, a2 = -11, a5 = 10 })

  local flow = {}
  for _, f in ipairs(r.flow) do flow[f.item] = f end
  t.near(flow.a1.total, 22)
  t.near(flow.a2.total, 11)
  t.near(flow.a3.total, 10)
  t.near(flow.a4.total, 10)
  t.near(flow.a5.total, 10)

  -- Components with amounts and percents as in the Kotlin test; order per compareTo.
  local a1 = flow.a1.components
  t.eq(#a1, 3)
  t.eq(a1[1].source, "input"); t.eq(a1[1].virtual, true); t.near(a1[1].count, 22); t.near(a1[1].percent, 1)
  t.eq(a1[2].source, "a5"); t.near(a1[2].count, -20); t.near(a1[2].percent, -0.91, 0.005)
  t.eq(a1[3].source, "a3"); t.near(a1[3].count, -2); t.near(a1[3].percent, -0.09, 0.005)

  local a3 = flow.a3.components
  t.eq(#a3, 2)
  t.eq(a3[1].source, "a3"); t.near(a3[1].count, 10); t.near(a3[1].percent, 1)
  t.eq(a3[2].source, "a4"); t.near(a3[2].count, -10); t.near(a3[2].percent, -1)

  local a5 = flow.a5.components
  t.eq(a5[1].source, "a5"); t.near(a5[1].count, 10)
  t.eq(a5[2].source, "output"); t.eq(a5[2].virtual, true); t.near(a5[2].count, -10); t.near(a5[2].percent, -1)

  -- Items sorted by flow, largest first.
  t.eq(r.flow[1].item, "a1")
  t.eq(r.flow[2].item, "a2")
end)

-- Ported: `should solve underdetermined system`, now NEEDS_SPLIT with {a3, a3'}.
local function underdetermined_lines()
  return {
    { id = "a1", flow = { a1 = 1 } },
    { id = "a2", flow = { a2 = 1 } },
    { id = "a3", flow = { a1 = -2, a2 = -1, a3 = 1 } },
    { id = "a3'", flow = { a1 = -2, a2 = -1, a3 = 1 } },
    { id = "f", flow = { a3 = -1 } },
  }
end

t.test("solver: underdetermined system needs a split", function()
  local r = solver.balance(underdetermined_lines(), { f = 1 }, {}, {})
  t.eq(r.status, "NEEDS_SPLIT")
  local p = find_problem(r, "split")
  t.truthy(p, "split prompt")
  t.eq(p.item, "a3")
  t.eq(#p.lines, 2)
  t.eq(p.lines[1], "a3")
  t.eq(p.lines[2], "a3'")
  t.truthy(r.undetermined["a3"] and r.undetermined["a3'"])
end)

t.test("solver: underdetermined system with 50/50 split", function()
  local r = solver.balance(underdetermined_lines(), { f = 1 }, { { item = "a3", shares = { a3 = 50, ["a3'"] = 50 } } }, {})
  t.eq(r.status, "EXACT")
  t.map_near(r.counts, { a1 = 2, a2 = 1, a3 = 0.5, ["a3'"] = 0.5, f = 1 })
  t.map_near(r.net, {})
  local flow = {}
  for _, f in ipairs(r.flow) do flow[f.item] = f end
  t.near(flow.a1.total, 2)
  t.near(flow.a2.total, 1)
  t.near(flow.a3.total, 1)
end)

t.test("solver: uneven split", function()
  local r = solver.balance(underdetermined_lines(), { f = 1 }, { { item = "a3", shares = { a3 = 75, ["a3'"] = 25 } } }, {})
  t.eq(r.status, "EXACT")
  t.near(r.counts["a3"], 0.75)
  t.near(r.counts["a3'"], 0.25)
end)

t.test("solver: split with share 0 leaves a recipe unused", function()
  local r = solver.balance(underdetermined_lines(), { f = 1 }, { { item = "a3", shares = { a3 = 100, ["a3'"] = 0 } } }, {})
  t.eq(r.status, "EXACT")
  t.near(r.counts["a3"], 1)
  t.near(r.counts["a3'"], 0)
end)

-- Ported: `should solve overdetermined system`, now CONFLICT naming a1.
local function overdetermined_lines()
  return {
    { id = "a2", flow = { a2 = 1 } },
    { id = "a3", flow = { a1 = -2, a2 = -1, a3 = 1 } },
    { id = "f", flow = { a3 = -1 } },
  }
end

t.test("solver: overdetermined system is a conflict naming a1", function()
  local r = solver.balance(overdetermined_lines(), { f = 1 }, {}, {})
  t.eq(r.status, "CONFLICT")
  local p = find_problem(r, "conflict")
  t.truthy(p, "conflict problem")
  t.eq(#p.items, 1)
  t.eq(p.items[1], "a1")
  t.eq(p.reasons.a1, "no_producer")
  t.truthy(r.suggested_external.a1)
end)

t.test("solver: marking a1 external makes it exact", function()
  local r = solver.balance(overdetermined_lines(), { f = 1 }, {}, { a1 = true })
  t.eq(r.status, "EXACT")
  t.map_near(r.counts, { a2 = 1, a3 = 1, f = 1 })
  t.map_near(r.net, { a1 = -2 })
end)

t.test("solver: byproduct with no consumer is a conflict", function()
  local lines = {
    { id = 1, flow = { ["item/plate"] = -1, ["item/gear"] = 1, ["fluid/hydrogen"] = 3 } },
    { id = 2, flow = { ["item/plate"] = 1 } },
  }
  local r = solver.balance(lines, { [1] = 2 }, {}, { ["item/gear"] = true })
  t.eq(r.status, "CONFLICT")
  local p = find_problem(r, "conflict")
  t.eq(p.items[1], "fluid/hydrogen")
  t.eq(p.reasons["fluid/hydrogen"], "no_consumer")
  local fixed = solver.balance(lines, { [1] = 2 }, {}, { ["item/gear"] = true, ["fluid/hydrogen"] = true })
  t.eq(fixed.status, "EXACT")
  t.near(fixed.counts[2], 2)
  t.near(fixed.net["fluid/hydrogen"], 6)
end)

t.test("solver: negative count", function()
  local lines = {
    { id = "c", flow = { x = -1 } },
    { id = "p1", flow = { x = 1 } },
    { id = "p2", flow = { x = 1 } },
  }
  local r = solver.balance(lines, { c = 1, p1 = 3 }, {}, {})
  t.eq(r.status, "NEGATIVE")
  local p = find_problem(r, "negative")
  t.eq(p.lines[1], "p2")
  t.near(r.counts.p2, -2)
end)

-- Oil processing + coal liquefaction, the main parallel-recipe case.
local function oil_lines()
  return {
    { id = 1, flow = { ["fluid/crude-oil"] = -20, ["fluid/heavy-oil"] = 5, ["fluid/light-oil"] = 9, ["fluid/petroleum-gas"] = 11 } },
    { id = 2, flow = { ["item/coal"] = -2, ["fluid/steam"] = -10, ["fluid/heavy-oil"] = 13, ["fluid/light-oil"] = 4, ["fluid/petroleum-gas"] = 2 } },
    { id = 3, flow = { ["fluid/heavy-oil"] = -20, ["fluid/light-oil"] = 15 } },
    { id = 4, flow = { ["fluid/light-oil"] = -15, ["fluid/petroleum-gas"] = 10 } },
    { id = 5, flow = { ["fluid/petroleum-gas"] = -20, ["item/coal"] = -1, ["item/plastic-bar"] = 2 } },
  }
end
local oil_external = { ["fluid/crude-oil"] = true, ["item/coal"] = true, ["fluid/steam"] = true, ["item/plastic-bar"] = true }

t.test("solver: parallel oil recipes prompt a heavy oil split", function()
  local r = solver.balance(oil_lines(), { [5] = 10 }, {}, oil_external)
  t.eq(r.status, "NEEDS_SPLIT")
  local p = find_problem(r, "split")
  t.eq(p.item, "fluid/heavy-oil")
  t.eq(#p.lines, 2)
  t.eq(p.lines[1], 1)
  t.eq(p.lines[2], 2)
  t.contains(p.candidates, "fluid/light-oil")
  t.contains(p.candidates, "fluid/petroleum-gas")
end)

t.test("solver: pre-filled split from scanned counts is exact at those counts", function()
  -- Scanned: 6 refineries and 2 liquefaction lines; derive shares, solve, get the same ratio.
  local lines = oil_lines()
  local flows = {}
  for _, l in ipairs(lines) do flows[l.id] = l.flow end
  local shares = solver.shares_from_counts("fluid/heavy-oil", { 1, 2 }, flows, { [1] = 6, [2] = 2 })
  t.near(shares[1] + shares[2], 100)
  t.near(shares[1], 100 * 30 / 56)
  local r = solver.balance(lines, { [5] = 10 }, { { item = "fluid/heavy-oil", shares = shares } }, oil_external)
  t.eq(r.status, "EXACT")
  t.near(r.counts[1] / r.counts[2], 3, 1e-9)
  for id = 1, 5 do t.truthy(r.counts[id] >= 0, "count " .. id .. " >= 0") end
  -- Switching the split item to light oil with matching shares gives the same counts.
  local light = solver.shares_from_counts("fluid/light-oil", { 1, 2 }, flows, r.counts)
  local r2 = solver.balance(lines, { [5] = 10 }, { { item = "fluid/light-oil", shares = light } }, oil_external)
  t.eq(r2.status, "EXACT")
  for id = 1, 5 do t.near(r2.counts[id], r.counts[id], 1e-9) end
end)

t.test("solver: split whose lines are gone is dropped and prompted again", function()
  local r = solver.balance(underdetermined_lines(), { f = 1 }, { { item = "a3", shares = { a3 = 50, gone = 50 } } }, {})
  t.eq(r.status, "NEEDS_SPLIT")
  t.truthy(find_problem(r, "split_dropped"))
  t.truthy(find_problem(r, "split"))
end)

t.test("solver: all-anchored split that disagrees is a conflict naming the split", function()
  local lines = underdetermined_lines()
  local r = solver.balance(lines, { f = 1, a3 = 0.5, ["a3'"] = 0.5 }, { { item = "a3", shares = { a3 = 80, ["a3'"] = 20 } } }, {})
  t.eq(r.status, "CONFLICT")
  local p = find_problem(r, "conflict")
  t.eq(p.splits[1], 1)
end)

t.test("solver: loop with no shared product suggests an anchor", function()
  local lines = {
    { id = "x", flow = { a = 1, b = -1 } },
    { id = "y", flow = { b = 1, a = -1 } },
  }
  local r = solver.balance(lines, {}, {}, {})
  t.eq(r.status, "NEEDS_SPLIT")
  t.truthy(find_problem(r, "anchor"))
end)

t.test("solver: require_anchor", function()
  local r = solver.balance({ { id = 1, flow = { ["item/a"] = 1 } } }, {}, {}, { ["item/a"] = true }, { require_anchor = true })
  t.eq(r.status, "NEEDS_SPLIT")
  t.truthy(find_problem(r, "anchor"))
end)

t.test("solver: input order does not change the result", function()
  local a = oil_lines()
  local b = {}
  for i = #a, 1, -1 do b[#b + 1] = a[i] end
  local split = { { item = "fluid/heavy-oil", shares = { [1] = 60, [2] = 40 } } }
  local ra = solver.balance(a, { [5] = 10 }, split, oil_external)
  local rb = solver.balance(b, { [5] = 10 }, split, oil_external)
  for id = 1, 5 do t.eq(ra.counts[id], rb.counts[id], "count " .. id) end
  for i, f in ipairs(ra.flow) do
    t.eq(f.item, rb.flow[i].item)
    for j, c in ipairs(f.components) do t.eq(c.source, rb.flow[i].components[j].source) end
  end
end)

-- Plan fixture from the old save: each factory's summary is a line, `lab` is a sink at 1.
t.test("solver: plan fixture from the old save", function()
  local state = json.read_file(TEST_ROOT .. "/tests/fixtures/old_state.json")
  local lines, anchors, copies = {}, {}, {}
  for name, f in pairs(state.factories) do
    lines[#lines + 1] = { id = name, flow = f.summary }
    copies[name] = f.factory.multiplier
    if f.factory.final then anchors[name] = f.factory.multiplier end
  end
  t.eq(#lines, 42)
  local r = solver.balance(lines, anchors, {}, {})
  t.eq(r.status, "EXACT")
  t.eq(r.unknowns, 41)
  t.eq(r.rank, 41)
  local expected = {
    ["green circuits"] = { 14.05, 4, 10.05 },
    ["lds"] = { 7.50, 1, 6.50 },
    ["light oil cracking"] = { 6.51, 1, 5.51 },
    ["oil refinery"] = { 5.54, 1, 4.54 },
    ["heavy oil cracking"] = { 5.05, 1, 4.05 },
    ["imersite crystal"] = { 5.04, 1, 4.04 },
    ["electronic components"] = { 6.15, 3, 3.15 },
    ["production card"] = { 0.95, 1, -0.05 },
    ["uranium processing"] = { 0.23, 1, -0.77 },
  }
  for name, e in pairs(expected) do
    t.near(r.counts[name], e[1], 0.01, name .. " needed")
    t.eq(copies[name], e[2], name .. " copies")
    t.near(r.counts[name] - copies[name], e[3], 0.01, name .. " shortage")
  end
end)

-- Review finding: after a split on heavy oil exists, the prompt must not ask for it again.
t.test("solver: prompt skips items that already have a split", function()
  local lines = {
    { id = 1, flow = { h = 1, l = 1 } },
    { id = 2, flow = { h = 1, l = 2 } },
    { id = 3, flow = { l = 1 } },
    { id = 4, flow = { l = -10 } },
  }
  local first = solver.balance(lines, { [4] = 1 }, {}, { h = true })
  t.eq(first.status, "NEEDS_SPLIT")
  t.eq(find_problem(first, "split").item, "h")
  local r = solver.balance(lines, { [4] = 1 }, { { item = "h", shares = { [1] = 50, [2] = 50 } } }, { h = true })
  t.eq(r.status, "NEEDS_SPLIT")
  local p = find_problem(r, "split")
  t.eq(p.item, "l")
  t.eq(#p.lines, 3)
  for _, c in ipairs(p.candidates) do t.truthy(c ~= "h", "h is not offered again") end
  -- shares for both splits from one count vector are consistent
  local flows = { [1] = lines[1].flow, [2] = lines[2].flow, [3] = lines[3].flow }
  local counts = { [1] = 2, [2] = 2, [3] = 1 }
  local splits = {
    { item = "h", shares = solver.shares_from_counts("h", { 1, 2 }, flows, counts) },
    { item = "l", shares = solver.shares_from_counts("l", { 1, 2, 3 }, flows, counts) },
  }
  local done = solver.balance(lines, { [4] = 1 }, splits, { h = true })
  t.eq(done.status, "EXACT")
  t.near(done.counts[1] / done.counts[3], 2)
end)

t.test("solver: only one anchor prompt", function()
  local lines = {
    { id = "x", flow = { a = 1, b = -1 } },
    { id = "y", flow = { b = 1, a = -1 } },
  }
  local r = solver.balance(lines, {}, {}, {}, { require_anchor = true })
  local n = 0
  for _, p in ipairs(r.problems) do if p.type == "anchor" then n = n + 1 end end
  t.eq(n, 1)
  t.eq(#find_problem(r, "anchor").lines, 2)
end)
