-- The plan balance and its diagnosis on a set of plans, as text, against
-- tests/fixtures/balance_snapshot.txt: status, problems, fixes, splits in the way, and every
-- factory's copies. A guard for changes to the solver: a difference is a behaviour change to
-- look at. To accept one, run `STOICH_UPDATE_SNAPSHOT=1 lua tests/run.lua balance` and read
-- the diff before committing it.

local t = require("tests.t")
local fake = require("tests.fake_game")
local model = require("scripts.model")
local plan = require("scripts.plan")
local plan_lp = require("scripts.plan_lp") -- here, not in a test: the GUI tests' mock reloads the modules
local plans = require("tests.plans")

local SNAPSHOT = TEST_ROOT .. "/tests/fixtures/balance_snapshot.txt"

local function num(v)
  if v == nil then return "nil" end
  if math.abs(v) < 1e-9 then return "0" end
  return string.format("%.6g", v)
end

--- One balance as text lines.
local function describe(key, r)
  local out = { "status " .. r.status .. (r.complicated and " complicated" or "") .. (r.too_complicated and " too_complicated" or "")
    .. (r.with_fixes and " with_fixes" or "") .. (r.fixes and (r.fixes_close and " fixes_close" or " fixes_partial") or "") }
  local problems = {}
  for _, p in ipairs(r.problems) do
    local what = p.type
    if p.item then what = what .. " " .. p.item end
    if p.items then what = what .. " " .. table.concat(p.items, ",") end
    problems[#problems + 1] = what
  end
  table.sort(problems)
  for _, p in ipairs(problems) do out[#out + 1] = "problem " .. p end
  for _, fix in ipairs(r.fixes or {}) do
    local keys = {}
    for _, k in ipairs(fix.keys) do keys[#keys + 1] = k .. "=" .. num(fix.rates[k]) end
    out[#out + 1] = "fix " .. table.concat(keys, " ") .. (#fix.alternatives > 0 and (" or " .. table.concat(fix.alternatives, ",")) or "")
  end
  for _, item in ipairs(r.splits_in_way or {}) do out[#out + 1] = "split in the way " .. item end
  local names = {}
  for _, id in ipairs(model.factory_ids(key)) do
    local f = model.get(id)
    if not plan.is_list(f) then
      local c = r.undetermined[id] and "?" or num(r.counts[id])
      names[#names + 1] = f.name .. " #" .. id .. " " .. c
    end
  end
  table.sort(names)
  for _, n in ipairs(names) do out[#out + 1] = "copies " .. n end
  -- what sets the copies of a factory whose other outputs are voided
  local runs = {}
  for id, keys in pairs(r.binding or {}) do runs[#runs + 1] = model.get(id).name .. " #" .. id .. " " .. table.concat(keys, ",") end
  table.sort(runs)
  for _, line in ipairs(runs) do out[#out + 1] = "copies set by " .. line end
  -- the plan's voids and imports, by unit
  local units = {}
  for _, u in ipairs(plan.units(key)) do
    if u.item then units[#units + 1] = (u.flow[u.item] < 0 and "void " or "import ") .. u.item .. " " .. (r.undetermined[u.id] and "?" or num(r.counts[u.id])) end
  end
  table.sort(units)
  for _, u in ipairs(units) do out[#out + 1] = u end
  return out
end

local scenarios = {}
local function scenario(name, fn) scenarios[#scenarios + 1] = { name = name, fn = fn } end

local N = "nauvis"

scenario("fulgora, no quality: can't balance, then its fixes", function(say)
  fake.reset()
  plans.load("fulgora_plan.json")
  local r = plan.rebalance("fulgora")
  say("fulgora", r)
  plans.apply_fixes("fulgora", r)
  say("fulgora", plan.rebalance("fulgora"))
end)

scenario("a void the plan is short of", function(say)
  fake.reset()
  -- nothing makes the plates the gears use, and a void has them
  plans.factory(N, "gears", { ["item/iron-plate"] = -2, ["item/iron-gear-wheel"] = 1 })
  plans.sink(N, "gears out", { ["item/iron-gear-wheel"] = 1 })
  plans.boundary(N, "void", { "item/iron-plate" })
  say(N, plan.rebalance(N))
end)

scenario("a void short of its item while its rate is free: making more closes it", function(say)
  fake.reset()
  plans.factory(N, "plates", { ["item/iron-plate"] = 1, ["item/copper-plate"] = 1 })
  plans.factory(N, "science", { ["item/iron-plate"] = -2, ["item/automation-science-pack"] = 1 })
  plans.sink(N, "out", { ["item/copper-plate"] = 1, ["item/automation-science-pack"] = 1 })
  plans.boundary(N, "void", { "item/iron-plate", "item/automation-science-pack" })
  say(N, plan.rebalance(N))
end)

scenario("a void short of a legendary byproduct at 1e-7/s is named too", function(say)
  fake.reset({ quality = true })
  -- the gears use a trace of legendary plates nothing makes: the void would have to make them
  plans.factory(N, "gears", { ["item/iron-plate|legendary"] = -1e-7, ["item/iron-gear-wheel"] = 1 })
  plans.sink(N, "gears out", { ["item/iron-gear-wheel"] = 1 })
  plans.boundary(N, "void", { "item/iron-plate|legendary" })
  say(N, plan.rebalance(N))
end)

scenario("an import the plan has too much of", function(say)
  fake.reset()
  -- the mine's stone goes nowhere, and an import brings stone in
  plans.factory(N, "mine", { ["item/iron-ore"] = 2, ["item/stone"] = 1 })
  plans.factory(N, "smelter", { ["item/iron-ore"] = -1, ["item/iron-plate"] = 1 })
  plans.sink(N, "plates out", { ["item/iron-plate"] = 1 })
  plans.boundary(N, "import", { "item/stone" })
  say(N, plan.rebalance(N))
end)

scenario("a byproduct voided at its rate", function(say)
  fake.reset()
  plans.factory(N, "oil", { ["fluid/crude-oil"] = -10, ["fluid/heavy-oil"] = 3, ["fluid/light-oil"] = 4, ["fluid/petroleum-gas"] = 5 })
  plans.factory(N, "crude", { ["fluid/crude-oil"] = 10 })
  plans.sink(N, "gas out", { ["fluid/petroleum-gas"] = 10 })
  plans.boundary(N, "void", { "fluid/heavy-oil", "fluid/light-oil" })
  say(N, plan.rebalance(N))
end)

scenario("two makers of one item, no split", function(say)
  fake.reset()
  plans.factory(N, "plates a", { ["item/iron-plate"] = 1 })
  plans.factory(N, "plates b", { ["item/iron-plate"] = 2 })
  plans.sink(N, "plates out", { ["item/iron-plate"] = 3 })
  say(N, plan.rebalance(N))
end)

scenario("a factory backwards, no void or import", function(say)
  fake.reset()
  -- iron 2A + 3B = 1, coal B - A = 1: A = -0.4
  plans.factory(N, "A", { ["item/iron-plate"] = 2, ["item/coal"] = -1 })
  plans.factory(N, "B", { ["item/iron-plate"] = 3, ["item/coal"] = 1 })
  plans.sink(N, "out", { ["item/iron-plate"] = 1, ["item/coal"] = 1 })
  say(N, plan.rebalance(N))
end)

scenario("a split the void makes possible (the review's case)", function(say)
  fake.reset()
  local f1 = plans.factory(N, "F1", { ["item/iron-plate"] = 1, ["item/copper-plate"] = 1, ["item/iron-gear-wheel"] = 1 })
  local f3 = plans.factory(N, "F3", { ["item/iron-gear-wheel"] = 1, ["item/electronic-circuit"] = 1 })
  plans.factory(N, "G", { ["item/iron-plate"] = -1, ["item/automation-science-pack"] = 1 })
  plans.factory(N, "G2", { ["item/iron-plate"] = -2, ["item/automation-science-pack"] = 1 })
  plans.factory(N, "H", { ["item/copper-plate"] = -1, ["item/copper-cable"] = 1 })
  plans.sink(N, "S", { ["item/iron-gear-wheel"] = 1, ["item/electronic-circuit"] = 1, ["item/automation-science-pack"] = 0.2, ["item/copper-cable"] = 0.1 })
  plans.boundary(N, "void", { "item/iron-plate", "item/copper-plate", "item/iron-gear-wheel", "item/automation-science-pack" })
  say(N, plan.rebalance(N))
  model.plan(N).splits = { { item = "item/iron-gear-wheel", shares = { [f1.id] = 50, [f3.id] = 50 } } }
  say(N, plan.rebalance(N))
end)

scenario("a split that forces an import", function(say)
  fake.reset()
  local science = plans.factory(N, "science", { ["item/automation-science-pack"] = 1, ["item/coal"] = 1 })
  local burner = plans.factory(N, "wood to coal", { ["item/wood"] = -1, ["item/coal"] = 1 })
  model.plan(N).splits = { { item = "item/coal", shares = { [science.id] = 50, [burner.id] = 50 } } }
  plans.sink(N, "science out", { ["item/automation-science-pack"] = 1 })
  say(N, plan.rebalance(N))
end)

scenario("fulgora, recyclers of every quality", function(say)
  fake.reset({ quality = true })
  plans.load("fulgora_every_quality_plan.json")
  local r = plan.rebalance("fulgora")
  say("fulgora", r)
  plans.apply_fixes("fulgora", r)
  say("fulgora", plan.rebalance("fulgora"))
end)

scenario("fulgora, voided with splits pinning the recyclers", function(say)
  fake.reset({ quality = true })
  plans.load("fulgora_voided_plan.json")
  say("fulgora", plan.rebalance("fulgora"))
end)

scenario("settling out of budget: complicated, Find a fix settles it", function(say)
  fake.reset()
  -- science two ways (G, G2): the void rates are free, the program settles them
  plans.factory(N, "F1", { ["item/iron-plate"] = 1, ["item/copper-plate"] = 1, ["item/iron-gear-wheel"] = 1 })
  plans.factory(N, "F3", { ["item/iron-gear-wheel"] = 1, ["item/electronic-circuit"] = 1 })
  plans.factory(N, "G", { ["item/iron-plate"] = -1, ["item/automation-science-pack"] = 1 })
  plans.factory(N, "G2", { ["item/iron-plate"] = -2, ["item/automation-science-pack"] = 1 })
  plans.factory(N, "H", { ["item/copper-plate"] = -1, ["item/copper-cable"] = 1 })
  plans.sink(N, "S", { ["item/iron-gear-wheel"] = 1, ["item/electronic-circuit"] = 1, ["item/automation-science-pack"] = 0.2, ["item/copper-cable"] = 0.1 })
  plans.boundary(N, "void", { "item/iron-plate", "item/copper-plate", "item/iron-gear-wheel", "item/automation-science-pack" })
  local work = plan_lp.AUTO_WORK
  plan_lp.AUTO_WORK = 0
  say(N, plan.rebalance(N))
  say(N, plan.find_fix(N))
  plan_lp.AUTO_WORK = work
end)

scenario("the research notice's balance (no diagnosis) of a plan with no forward answer", function(say)
  fake.reset()
  plans.factory(N, "plates", { ["item/iron-plate"] = 1, ["item/copper-plate"] = 1 })
  plans.factory(N, "science", { ["item/iron-plate"] = -2, ["item/automation-science-pack"] = 1 })
  plans.sink(N, "out", { ["item/copper-plate"] = 1, ["item/automation-science-pack"] = 1 })
  plans.boundary(N, "void", { "item/iron-plate", "item/automation-science-pack" })
  say(N, plan.solve(N, nil, { diagnose = "none" }))
end)

scenario("a split that matches usage, and a sink at half its rates", function(say)
  fake.reset()
  local a = plans.factory(N, "plates a", { ["item/iron-plate"] = 1 })
  local b = plans.factory(N, "plates b", { ["item/iron-plate"] = 2 })
  model.get(a.id).copies, model.get(b.id).copies = 3, 1
  model.plan(N).splits = { { item = "item/iron-plate", shares = {}, match_usage = true } }
  plans.sink(N, "plates out", { ["item/iron-plate"] = 10 }, 0.5)
  say(N, plan.rebalance(N))
end)

scenario("a void row with a quality condition takes the tiers it matches", function(say)
  fake.reset({ quality = true })
  plans.factory(N, "upcycler", { ["item/iron-plate"] = -1, ["item/iron-gear-wheel"] = 0.4,
    ["item/iron-gear-wheel|uncommon"] = 0.05, ["item/iron-gear-wheel|rare"] = 0.01 })
  plans.factory(N, "plates", { ["item/iron-plate"] = 1 })
  plans.sink(N, "gears out", { ["item/iron-gear-wheel"] = 1 })
  plans.boundary(N, "void", { { "item/iron-gear-wheel", ">=uncommon" } })
  say(N, plan.rebalance(N))
end)

local function run_all()
  local out = {}
  for _, s in ipairs(scenarios) do
    out[#out + 1] = "== " .. s.name
    local n = 0
    s.fn(function(key, r)
      n = n + 1
      out[#out + 1] = "-- balance " .. n
      for _, line in ipairs(describe(key, r)) do out[#out + 1] = line end
    end)
  end
  return table.concat(out, "\n") .. "\n"
end

t.test("balance: the solver's answers on a set of plans are as recorded", function()
  local now = run_all()
  if os.getenv("STOICH_UPDATE_SNAPSHOT") then
    local h = assert(io.open(SNAPSHOT, "w"))
    h:write(now)
    h:close()
  end
  local h = assert(io.open(SNAPSHOT), "no snapshot: run with STOICH_UPDATE_SNAPSHOT=1")
  local before = h:read("*a")
  h:close()
  if now ~= before then
    local a, b = {}, {}
    for line in before:gmatch("[^\n]*") do a[#a + 1] = line end
    for line in now:gmatch("[^\n]*") do b[#b + 1] = line end
    for i = 1, math.max(#a, #b) do
      if a[i] ~= b[i] then t.eq(b[i], a[i], "line " .. i) end
    end
  end
end)
