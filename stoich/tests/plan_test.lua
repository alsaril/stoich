local t = require("tests.t")
local fake = require("tests.fake_game")
local model = require("scripts.model")
local plan = require("scripts.plan")
local draft = require("scripts.draft")
local scanner = require("scripts.scanner")
local fp_util = require("scripts.util")

local function find_problem(result, kind)
  for _, p in ipairs(result.problems) do
    if p.type == kind then return p end
  end
end

-- A captured gear + circuit build: 5 gear assemblers where 4.3 would do.
local function gear_scan()
  return {
    lines = scanner.group({
      { kind = "recipe", recipe = "copper-cable", machine = "assembling-machine-2", flow = { ["item/copper-plate"] = -1, ["item/copper-cable"] = 2 } },
      { kind = "recipe", recipe = "copper-cable", machine = "assembling-machine-2", flow = { ["item/copper-plate"] = -1, ["item/copper-cable"] = 2 } },
      { kind = "recipe", recipe = "copper-cable", machine = "assembling-machine-2", flow = { ["item/copper-plate"] = -1, ["item/copper-cable"] = 2 } },
      { kind = "recipe", recipe = "electronic-circuit", machine = "assembling-machine-2", flow = { ["item/iron-plate"] = -1, ["item/copper-cable"] = -3, ["item/electronic-circuit"] = 1 } },
      { kind = "recipe", recipe = "electronic-circuit", machine = "assembling-machine-2", flow = { ["item/iron-plate"] = -1, ["item/copper-cable"] = -3, ["item/electronic-circuit"] = 1 } },
      { kind = "recipe", machine = "assembling-machine-2", idle = true },
    }),
  }
end

t.test("draft: capture defaults name, icon, anchor and externals", function()
  fake.reset()
  local f = draft.from_scan(gear_scan(), { surface_index = 1, areas = { { left_top = { x = 0, y = 0 }, right_bottom = { x = 10, y = 10 } } } })
  t.eq(f.name, "Electronic circuit")
  t.eq(f.icon.name, "electronic-circuit")
  t.truthy(f.external["item/iron-plate"])
  t.truthy(f.external["item/copper-plate"])
  t.truthy(f.external["item/electronic-circuit"])
  t.eq(f.external["item/copper-cable"], nil)
  -- anchored at the scanned 2 circuit assemblers
  local circuit_line
  for _, l in ipairs(f.lines) do if l.recipe == "electronic-circuit" then circuit_line = l end end
  t.eq(f.anchors[circuit_line.id], 2)
  local r = f.result
  t.eq(r.status, "EXACT")
  -- 3 cable assemblers are scanned, 3 needed (2 circuits × 3 cable / 2 per cable assembler)
  for _, l in ipairs(f.lines) do
    if l.recipe == "copper-cable" then t.near(r.counts[l.id], 3) end
  end
  t.near(r.net["item/electronic-circuit"], 2)
  t.near(r.net["item/iron-plate"], -2)
  t.near(r.net["item/copper-plate"], -3)
end)

-- Oil build: 6 refineries + 2 liquefaction, crackers and plastic.
local function oil_scan(n_ref, n_liq)
  local entries = {}
  for _ = 1, n_ref do
    entries[#entries + 1] = { kind = "recipe", recipe = "advanced-oil-processing", machine = "oil-refinery",
      flow = { ["fluid/crude-oil"] = -20, ["fluid/water"] = -10, ["fluid/heavy-oil"] = 5, ["fluid/light-oil"] = 9, ["fluid/petroleum-gas"] = 11 } }
  end
  for _ = 1, n_liq do
    entries[#entries + 1] = { kind = "recipe", recipe = "coal-liquefaction", machine = "oil-refinery",
      flow = { ["item/coal"] = -2, ["fluid/steam"] = -10, ["fluid/heavy-oil"] = 13, ["fluid/light-oil"] = 4, ["fluid/petroleum-gas"] = 2 } }
  end
  for _ = 1, 3 do
    entries[#entries + 1] = { kind = "recipe", recipe = "heavy-oil-cracking", machine = "chemical-plant", flow = { ["fluid/heavy-oil"] = -20, ["fluid/water"] = -15, ["fluid/light-oil"] = 15 } }
  end
  for _ = 1, 7 do
    entries[#entries + 1] = { kind = "recipe", recipe = "light-oil-cracking", machine = "chemical-plant", flow = { ["fluid/light-oil"] = -15, ["fluid/water"] = -15, ["fluid/petroleum-gas"] = 10 } }
  end
  for _ = 1, 8 do
    entries[#entries + 1] = { kind = "recipe", recipe = "plastic-bar", machine = "chemical-plant", flow = { ["fluid/petroleum-gas"] = -20, ["item/coal"] = -1, ["item/plastic-bar"] = 2 } }
  end
  return { lines = scanner.group(entries) }
end

t.test("draft: captured oil setup is EXACT at once with a pre-filled split", function()
  fake.reset()
  local f = draft.from_scan(oil_scan(6, 2))
  t.eq(f.icon.name, "plastic-bar")
  t.eq(f.result.status, "EXACT")
  t.eq(#f.splits, 1)
  local split = f.splits[1]
  local ref, liq
  for _, l in ipairs(f.lines) do
    if l.recipe == "advanced-oil-processing" then ref = l end
    if l.recipe == "coal-liquefaction" then liq = l end
  end
  t.near(split.shares[ref.id] + split.shares[liq.id], 100)
  -- shares follow the scanned build: 6 x 5 vs 2 x 13 heavy oil
  t.near(split.shares[ref.id], 100 * 30 / 56)
  t.near(f.result.counts[ref.id] / f.result.counts[liq.id], 3, 1e-9)
end)

t.test("draft: moving a split share changes solved counts and keeps 100%", function()
  fake.reset()
  local f = draft.from_scan(oil_scan(6, 2))
  local ref, liq
  for _, l in ipairs(f.lines) do
    if l.recipe == "advanced-oil-processing" then ref = l end
    if l.recipe == "coal-liquefaction" then liq = l end
  end
  local ids = draft.split_lines(f.lines, f.splits[1])
  t.eq(#ids, 2)
  local first, last = ids[1], ids[2]
  draft.set_share(f, 1, first, 70)
  t.near(f.splits[1].shares[first], 70)
  t.near(f.splits[1].shares[last], 30)
  draft.set_share(f, 1, first, 140)
  t.near(f.splits[1].shares[first], 100)
  t.near(f.splits[1].shares[last], 0)
  draft.set_share(f, 1, first, 50)
  local r = plan.balance_factory(f)
  t.eq(r.status, "EXACT")
  t.near(r.counts[ref.id] * 5, r.counts[liq.id] * 13, 1e-9)
end)

t.test("draft: switching the split item keeps the ratio", function()
  fake.reset()
  local f = draft.from_scan(oil_scan(6, 2))
  local before = f.result.counts
  local cands = draft.split_candidates(f.lines, f.splits[1])
  t.eq(#cands, 3)
  draft.switch_split_item(f, 1, "fluid/petroleum-gas", nil, before)
  local r = plan.balance_factory(f)
  t.eq(r.status, "EXACT")
  for id, c in pairs(before) do t.near(r.counts[id], c, 1e-9) end
end)

t.test("draft: byproduct conflict fixed by marking it external", function()
  fake.reset()
  local f = draft.from_scan(gear_scan())
  local cable
  for _, l in ipairs(f.lines) do if l.recipe == "copper-cable" then cable = l end end
  cable.flow["fluid/steam"] = 1 -- a byproduct nothing consumes
  local r = plan.balance_factory(f)
  t.eq(r.status, "CONFLICT")
  local p = find_problem(r, "conflict")
  t.eq(p.items[1], "fluid/steam")
  draft.set_external(f, "fluid/steam", true)
  t.eq(plan.balance_factory(f).status, "EXACT")
end)

t.test("draft: rescan updates counts, keeps overrides, follows anchors", function()
  fake.reset()
  local f = draft.from_scan(gear_scan())
  local circuit, cable
  for _, l in ipairs(f.lines) do
    if l.recipe == "electronic-circuit" then circuit = l end
    if l.recipe == "copper-cable" then cable = l end
  end
  cable.overridden = true
  cable.flow = { ["item/copper-plate"] = -2, ["item/copper-cable"] = 4 }
  local scan = gear_scan()
  -- one more circuit assembler appeared
  for _, l in ipairs(scan.lines) do if l.recipe == "electronic-circuit" then l.count = 3 end end
  local stats = draft.apply_rescan(f, scan)
  t.eq(circuit.count, 3)
  t.eq(f.anchors[circuit.id], 3)
  t.near(cable.flow["item/copper-cable"], 4) -- overridden line untouched
  t.eq(stats.added, 0)
end)

t.test("model: save, revision conflict, overwrite", function()
  fake.reset()
  game.tick = 100
  local f = draft.from_scan(gear_scan())
  local ok, saved = model.save_factory(f, {}, 1)
  t.truthy(ok)
  t.eq(saved.revision, 1)
  t.eq(saved.modified_by, 1)
  local id = saved.id

  local d1 = draft.open(1, model.get(id))
  local d2 = draft.open(2, model.get(id))
  d2.factory.name = "Player 2 name"
  game.tick = 200
  t.truthy(model.save_factory(d2.factory, d2.base, 2))
  d1.factory.name = "Player 1 name"
  local ok1, conflict = model.save_factory(d1.factory, d1.base, 1)
  t.eq(ok1, false)
  t.eq(conflict.modified_by, 2)
  t.eq(conflict.modified_tick, 200)
  t.eq(model.get(id).name, "Player 2 name")
  t.truthy(model.save_factory(d1.factory, d1.base, 1, true))
  t.eq(model.get(id).name, "Player 1 name")
  t.eq(model.get(id).revision, 3)
end)

t.test("model: copies changed live survive a draft save", function()
  fake.reset()
  local ok, saved = model.save_factory(draft.from_scan(gear_scan()), {}, 1)
  local d = draft.open(1, saved)
  model.set_copies(saved.id, 4, 2)
  d.factory.name = "renamed"
  t.truthy(model.save_factory(d.factory, d.base, 1))
  t.eq(model.get(saved.id).copies, 4)
  t.truthy(ok)
end)

t.test("model: saving a factory deleted meanwhile is a conflict", function()
  fake.reset()
  local _, saved = model.save_factory(draft.from_scan(gear_scan()), {}, 1)
  local d = draft.open(1, saved)
  model.delete_factory(saved.id, 2)
  local ok, conflict = model.save_factory(d.factory, d.base, 1)
  t.eq(ok, false)
  t.truthy(conflict.deleted)
end)

t.test("model: log keeps the last 50 actions", function()
  fake.reset()
  for i = 1, 60 do model.log(1, "a" .. i, "f") end
  t.eq(#storage.log, 50)
  t.eq(storage.log[1].action, "a11")
end)

t.test("model: permissions", function()
  fake.reset({ edit = "admins" })
  local admin = fake.add_player(1, true)
  local other = fake.add_player(2, false)
  t.eq(model.can_edit(admin), true)
  t.eq(model.can_edit(other), false)
  settings.global["stoich-edit-permission"].value = "everyone"
  t.eq(model.can_edit(other), true)
end)

-- Plan -------------------------------------------------------------------------------------------

local function save(f)
  plan.balance_factory(f)
  local ok, saved = model.save_factory(f, {}, 1)
  assert(ok)
  return saved
end

local function custom_factory(name, net, copies)
  local f = model.new_factory("factory")
  local line = model.add_line(f, { kind = "custom", label = name, count = 1, flow = net })
  f.name = name
  f.anchors[line.id] = 1
  f.external = plan.flow_items(net)
  f.copies = copies or 1
  return save(f)
end

local function sink(name, rates_per_min)
  local f = draft.new_sink()
  f.name = name
  for _, key in ipairs(fp_util.sorted_keys(rates_per_min)) do
    f.sink_items[#f.sink_items + 1] = { key = key, rate = rates_per_min[key] / 60 }
  end
  draft.sink_icon(f)
  return save(f)
end

t.test("plan: science and boiler sinks drive the plan", function()
  fake.reset()
  local gears = custom_factory("gears", { ["item/iron-plate"] = -2, ["item/iron-gear-wheel"] = 1 }, 1)
  local sci = custom_factory("red science", { ["item/iron-gear-wheel"] = -1, ["item/copper-plate"] = -1, ["item/automation-science-pack"] = 1 }, 1)
  local plates = custom_factory("plates", { ["item/iron-plate"] = 5, ["item/copper-plate"] = 2.5, ["item/coal"] = -1 }, 1)
  local coal = custom_factory("coal", { ["item/coal"] = 2 }, 1)
  sink("science", { ["item/automation-science-pack"] = 600 }) -- 10/s
  sink("boilers", { ["item/coal"] = 30 }) -- 0.5/s
  local r = plan.rebalance()
  t.eq(r.status, "EXACT")
  t.near(r.counts[sci.id], 10)
  t.near(r.counts[gears.id], 10)
  t.near(r.counts[plates.id], 4) -- 20 iron/s for gears, 10 copper/s for science
  t.near(r.counts[coal.id], (4 + 0.5) / 2) -- plates burn 4 coal/s, boilers 0.5
end)

t.test("plan: the plan is closed: a surplus is a conflict until a sink takes it", function()
  fake.reset()
  local gears = custom_factory("gears", { ["item/iron-plate"] = -2, ["item/iron-gear-wheel"] = 1 }, 1)
  local sci = custom_factory("red science", { ["item/iron-gear-wheel"] = -1, ["item/copper-plate"] = -1, ["item/automation-science-pack"] = 1 }, 1)
  local plates = custom_factory("plates", { ["item/iron-plate"] = 5, ["item/copper-plate"] = 5 }, 1)
  sink("science", { ["item/automation-science-pack"] = 600 })
  local r = plan.rebalance()
  t.eq(r.status, "CONFLICT")
  local p = find_problem(r, "conflict")
  t.truthy(p)
  -- a void for the surplus: whatever copper the plates make goes into it
  local void = custom_factory("copper void", { ["item/copper-plate"] = -1 }, 1)
  r = plan.rebalance()
  t.eq(r.status, "EXACT")
  t.near(r.counts[plates.id], 4)
  t.near(r.shortage[plates.id], 3)
  t.near(r.shortage[gears.id], 9)
  t.near(r.shortage[sci.id], 9)
  t.near(r.counts[void.id], 10) -- 20 copper/s made, 10 used by science
  -- sorted by shortage, largest first; ties by name
  t.eq(r.order[1], void.id)
  t.eq(r.order[2], gears.id)
  t.eq(r.order[3], sci.id)
  t.eq(r.order[4], plates.id)
end)

t.test("plan: research does not change sinks (fixed rates)", function()
  fake.reset()
  local sci = custom_factory("red science", { ["item/automation-science-pack"] = 0.5 }, 2)
  sink("science", { ["item/automation-science-pack"] = 60 })
  local r = plan.rebalance()
  t.near(r.counts[sci.id], 2)
  t.near(r.shortage[sci.id], 0)
  t.eq(plan.shortage_class(r.shortage[sci.id]), "ok")
end)

t.test("plan: old saves lose fixed copies and plan externals; sinks keep only their items", function()
  fake.reset()
  local a = custom_factory("a", { ["item/iron-plate"] = 1 }, 3)
  local s = sink("use", { ["item/iron-plate"] = 60 })
  -- as schema 1 stored them
  storage.schema = 1
  storage.settings = {}
  model.plan().external = { ["item/iron-plate"] = true }
  model.get(a.id).pinned = true
  local old = model.get(s.id)
  old.lines = { { id = 1, kind = "custom", label = "consumption", count = 1, flow = { ["item/iron-plate"] = -1 } } }
  old.anchors, old.external = { [1] = 1 }, { ["item/iron-plate"] = true }
  old.sink_items[1].signal = { type = "item", name = "iron-plate" }
  model.migrate()
  t.eq(storage.schema, model.SCHEMA)
  t.eq(model.plan().external, nil)
  t.eq(model.get(a.id).pinned, nil)
  t.eq(#model.get(s.id).lines, 0)
  t.eq(next(model.get(s.id).anchors), nil)
  t.eq(model.get(s.id).sink_items[1].signal, nil, "editing state dropped")
  t.eq(model.get(s.id).sink_items[1].key, "item/iron-plate")
  plan.balance_factory(model.get(s.id))
  local r = plan.rebalance()
  t.eq(r.status, "EXACT")
  t.near(r.counts[a.id], 1) -- needed copies from the sink, not fixed at 3
end)

t.test("plan: two designs for one item need a plan split", function()
  fake.reset()
  local a = custom_factory("circuits A", { ["item/electronic-circuit"] = 1 }, 1)
  local b = custom_factory("circuits B", { ["item/electronic-circuit"] = 2 }, 1)
  sink("use", { ["item/electronic-circuit"] = 180 }) -- 3/s
  local r = plan.rebalance()
  t.eq(r.status, "NEEDS_SPLIT")
  local p = find_problem(r, "split")
  t.eq(p.item, "item/electronic-circuit")
  local p_ = model.plan()
  local units = {}
  for _, id in ipairs({ a.id, b.id }) do units[#units + 1] = { id = id, flow = model.get(id).result.net, count = model.get(id).copies } end
  draft.add_split(p_, p.item, p.lines, units)
  r = plan.rebalance()
  t.eq(r.status, "EXACT")
  -- copies 1 and 1 -> shares 1/3 and 2/3 of 3/s
  t.near(r.counts[a.id], 1)
  t.near(r.counts[b.id], 1)
end)

t.test("plan: removed mod marks factory invalid, keeps data, drops it from the plan", function()
  fake.reset()
  local f = draft.from_scan(gear_scan())
  local saved = save(f)
  sink("use", { ["item/electronic-circuit"] = 60 })
  t.eq(plan.rebalance().status, "CONFLICT") -- plates are not produced in this plan
  prototypes.recipe["copper-cable"] = nil
  local bad = model.validate_all()
  t.eq(bad, 1)
  local kept = model.get(saved.id)
  t.truthy(kept.invalid)
  t.eq(#kept.lines, 3)
  plan.balance_factory(kept)
  t.eq(kept.result.status, "INVALID")
  local r = plan.rebalance()
  t.contains(r.excluded, saved.id)
end)

t.test("draft: rescan keeps deleted lines deleted and follows assigned idle machines", function()
  fake.reset()
  local f = draft.from_scan(gear_scan())
  local cable, idle
  for _, l in ipairs(f.lines) do
    if l.recipe == "copper-cable" then cable = l end
    if l.idle then idle = l end
  end
  model.remove_line(f, cable.id)
  -- assign a recipe to the idle machine line, as the editor does
  idle.recipe, idle.idle, idle.manual, idle.assigned_from, idle.key = "copper-cable", nil, true, idle.key, nil
  idle.flow = { ["item/copper-plate"] = -1, ["item/copper-cable"] = 2 }
  local scan = gear_scan()
  for _, l in ipairs(scan.lines) do if l.idle then l.count = 4 end end
  local stats = draft.apply_rescan(f, scan)
  t.eq(stats.added, 0, "deleted cable line not re-added, idle not re-added")
  t.eq(idle.count, 4)
  for _, l in ipairs(f.lines) do t.truthy(l.id ~= cable.id) end
end)

t.test("draft: raising a share shrinks the other shares proportionally", function()
  fake.reset()
  local holder = { lines = {
    { id = 1, flow = { h = 1 } }, { id = 2, flow = { h = 2 } }, { id = 3, flow = { h = 3 } }, { id = 4, flow = { h = 1 } },
  }, splits = { { item = "h", shares = { [1] = 20, [2] = 30, [3] = 10, [4] = 40 } } } }
  draft.set_share(holder, 1, 1, 70)
  local s = holder.splits[1].shares
  -- 2 and 3 had 40 together, 30 is left: they keep their 3:1 ratio; the last gets 0
  t.near(s[1], 70)
  t.near(s[2], 22.5)
  t.near(s[3], 7.5)
  t.near(s[4], 0)
  draft.set_share(holder, 1, 1, 10)
  t.near(s[1] + s[2] + s[3] + s[4], 100)
  t.near(s[4], 60)
end)
