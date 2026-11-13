-- Churn driver for heavy-mode desync checks on the stoich-test world: every few ticks
-- it changes the world (recipes, modules, beacons, machines built and removed,
-- research, resource amounts, mod settings) or makes Stoich read it (capture, rescan,
-- recapture, save, copies, duplicate, delete). Choices come from a seeded generator in
-- storage; all driver state is in storage, since heavy mode reloads the game every tick.
-- Writes script-output/churn/report.txt and done.txt.

local D = "stoich-debug"
local P = 1
local EVERY, ACTIONS, SEED = 10, 450, 20261028
local CRAFTERS = { "assembling-machine", "furnace" }

local function note(s)
  local n = storage.notes
  n[#n + 1] = game.tick .. " " .. s
  log("stoich-churn: " .. s)
end

-- Park-Miller: products stay below 2^53, so it is exact in doubles
local function rand(n)
  storage.seed = (storage.seed * 16807) % 2147483647
  return storage.seed % n + 1
end
local function pick(list) return list[rand(#list)] end

local function zones() return remote.call("stoich-test-world", "zones") end
local function zone_keys() return remote.call("stoich-test-world", "zone_order") end
local function surface() return game.get_player(P).surface end

local function crafters_in(key, types)
  return surface().find_entities_filtered({ area = zones()[key].area, type = types or CRAFTERS, force = "player" })
end

--- Enabled, visible recipes a machine can make, sorted by name.
local function recipes_for(machine)
  local cache = storage.recipes[machine]
  if cache then return cache end
  local cats = prototypes.entity[machine].crafting_categories or {}
  local out = {}
  for name, recipe in pairs(game.forces.player.recipes) do
    local rcats = recipe.prototype.categories or { recipe.category }
    local ok = false
    for _, c in ipairs(rcats) do
      if cats[c] then ok = true end
    end
    if ok and recipe.enabled and not recipe.prototype.hidden then out[#out + 1] = name end
  end
  table.sort(out)
  storage.recipes[machine] = out
  return out
end

local MODULES = { "speed-module", "speed-module-2", "speed-module-3", "productivity-module", "productivity-module-2",
  "productivity-module-3", "efficiency-module", "efficiency-module-3" }

-- Stoich, driven like a player. act() returns false when the control isn't on screen.
local function act(action, match, value) return remote.call(D, "act", P, action, match or {}, value) end
local function draft() return remote.call(D, "draft", P) end
local function open(tab) remote.call(D, "open", P, tab) end

local function factory_ids()
  local ids = {}
  for id in pairs(remote.call(D, "factories")) do ids[#ids + 1] = id end
  table.sort(ids)
  return ids
end

--- Save the open draft half the time, otherwise (or if it can't be saved) cancel it.
local function finish_draft()
  if not draft() then return "no draft" end
  if rand(2) == 1 then
    act("editor_save")
    if not draft() then return "saved" end
  end
  act("editor_cancel")
  act("discard_ok")
  if draft() then
    act("conflict_reload")
    act("editor_cancel")
    act("discard_ok")
  end
  return draft() and "still open" or "cancelled"
end

local world = {}

world.set_recipe = function()
  local machines = crafters_in(pick(zone_keys()), { "assembling-machine" })
  if #machines == 0 then return "no machine" end
  local e = pick(machines)
  local choice = pick(recipes_for(e.name))
  if not choice then return "no recipe" end
  e.set_recipe(choice)
  return e.name .. " -> " .. choice
end

world.clear_recipe = function()
  local machines = crafters_in(pick(zone_keys()), { "assembling-machine" })
  if #machines == 0 then return "no machine" end
  pick(machines).set_recipe(nil)
  return "cleared"
end

world.modules = function()
  local machines = crafters_in(pick(zone_keys()), { "assembling-machine", "furnace", "mining-drill" })
  if #machines == 0 then return "no machine" end
  local inv = pick(machines).get_module_inventory()
  if not inv then return "no slots" end
  if rand(3) == 1 then
    inv.clear()
    return "modules cleared"
  end
  local m = pick(MODULES)
  if not prototypes.item[m] then return "no " .. m end
  return m .. " x" .. inv.insert({ name = m, count = rand(4) })
end

world.beacon = function()
  local key = pick(zone_keys())
  local machines = crafters_in(key, { "assembling-machine", "furnace", "mining-drill" })
  if #machines == 0 then return "no machine" end
  local e = pick(machines)
  local pos = surface().find_non_colliding_position("beacon", e.position, 6, 1, true)
  if not pos then return "no room" end
  local b = surface().create_entity({ name = "beacon", position = pos, force = "player", raise_built = true })
  if not b then return "not placed" end
  b.get_module_inventory().insert({ name = "speed-module-3", count = 2 })
  storage.placed[#storage.placed + 1] = b
  return "beacon near " .. e.name
end

world.build = function()
  local key = pick(zone_keys())
  local area = zones()[key].area
  local name = pick({ "assembling-machine-2", "assembling-machine-3", "chemical-plant", "electric-mining-drill" })
  local centre = { x = (area.left_top.x + area.right_bottom.x) / 2, y = (area.left_top.y + area.right_bottom.y) / 2 }
  local pos = surface().find_non_colliding_position(name, centre, 14, 1, true)
  if not pos then return "no room" end
  local recipe = prototypes.entity[name].type == "assembling-machine" and pick(recipes_for(name)) or nil
  local e = surface().create_entity({ name = name, position = pos, force = "player", recipe = recipe, raise_built = true })
  if not e then return "not placed" end
  storage.placed[#storage.placed + 1] = e
  return name .. " " .. tostring(recipe) .. " in " .. key
end

world.destroy = function()
  if rand(2) == 1 and #storage.placed > 0 then
    local i = rand(#storage.placed)
    local e = table.remove(storage.placed, i)
    if e.valid then e.destroy({ raise_destroy = true }) end
    return "removed a placed entity"
  end
  local machines = crafters_in(pick(zone_keys()), { "assembling-machine", "furnace", "mining-drill" })
  if #machines < 2 then return "kept the last machine" end
  local e = pick(machines)
  local name = e.name
  e.destroy({ raise_destroy = true })
  return "destroyed " .. name
end

world.research = function()
  local force = game.forces.player
  local r = rand(3)
  if r == 1 then
    force.mining_drill_productivity_bonus = force.mining_drill_productivity_bonus + 0.1
    return "mining productivity " .. force.mining_drill_productivity_bonus
  elseif r == 2 then
    local names = {}
    for name, tech in pairs(force.technologies) do
      if tech.researched and not tech.prototype.research_unit_count_formula then -- skip infinite ones
        names[#names + 1] = name
      end
    end
    table.sort(names)
    local tech = force.technologies[pick(names)]
    tech.researched = false
    tech.researched = true
    return "re-researched " .. tech.name
  end
  force.reset_technology_effects()
  storage.recipes = {}
  return "reset technology effects"
end

world.resource = function()
  local res = surface().find_entities_filtered({ area = zones()[pick(zone_keys())].area, type = "resource" })
  if #res == 0 then return "no resource" end
  local e = pick(res)
  e.amount = math.max(1, math.floor(e.amount * (0.5 + rand(10) / 10)))
  return e.name .. " amount " .. e.amount
end

-- Through Stoich's own settings dialog: a mod can't change another mod's settings.
world.setting = function()
  open("plan")
  act("open_settings")
  local r = rand(3)
  local done
  if r == 1 then
    done = "one lane toggled " .. tostring(act("set_one_lane"))
  elseif r == 2 then
    local i = rand(2) -- 1 = best researched, 2 = the first belt
    done = "max belt #" .. i .. " " .. tostring(act("set_max_belt", {}, i))
  else
    local i = rand(3)
    done = "unit #" .. i .. " " .. tostring(act("set_unit", {}, i))
  end
  act("dialog_close")
  return done
end

local mod = {}

mod.capture = function()
  finish_draft()
  local key = pick(zone_keys())
  remote.call(D, "capture", P, zones()[key].area)
  local d = draft()
  return "capture " .. key .. ": " .. (d and d.factory.result.status or "no draft") .. ", " .. tostring(finish_draft())
end

mod.rescan = function()
  finish_draft()
  local ids = factory_ids()
  if #ids == 0 then return "no factories" end
  open("factories")
  local id = pick(ids)
  if not act("fac_edit", { id = id }) then return "no edit button" end
  act("editor_rescan")
  local d = draft()
  return "rescan " .. id .. ": " .. (d and d.factory.result.status or "no draft") .. ", " .. tostring(finish_draft())
end

mod.recapture = function()
  finish_draft()
  local ids = factory_ids()
  if #ids == 0 then return "no factories" end
  open("factories")
  local id = pick(ids)
  if not act("fac_edit", { id = id }) then return "no edit button" end
  act("editor_recapture")
  local key = pick(zone_keys())
  remote.call(D, "capture", P, zones()[key].area)
  game.get_player(P).clear_cursor()
  local d = draft()
  return "recapture " .. id .. " from " .. key .. ": " .. (d and d.factory.result.status or "no draft") .. ", " .. tostring(finish_draft())
end

mod.plan = function()
  finish_draft()
  local ids = factory_ids()
  if #ids == 0 then return "no factories" end
  open("plan")
  local id = pick(ids)
  local moved = act("plan_copies", { id = id, delta = rand(2) == 1 and 1 or -1 })
  act("plan_recalculate")
  local result = remote.call("stoich", "plan_result")
  return "copies " .. id .. " " .. tostring(moved) .. ", plan " .. tostring(result and result.status)
end

mod.duplicate_or_delete = function()
  finish_draft()
  local ids = factory_ids()
  if #ids < 3 then return "too few factories" end
  open("factories")
  local id = pick(ids)
  if rand(2) == 1 then
    act("fac_details")
    return "duplicate " .. id .. " " .. tostring(act("fac_duplicate", { id = id })) .. ", " .. tostring(finish_draft())
  end
  act("fac_delete", { id = id })
  return "delete " .. id .. " " .. tostring(act("fac_delete_ok"))
end

local ACTIONS_TABLE = {
  { "set_recipe", world.set_recipe, 6 }, { "clear_recipe", world.clear_recipe, 1 }, { "modules", world.modules, 3 },
  { "beacon", world.beacon, 2 }, { "build", world.build, 2 }, { "destroy", world.destroy, 2 },
  { "research", world.research, 1 }, { "resource", world.resource, 1 }, { "setting", world.setting, 1 },
  { "capture", mod.capture, 3 }, { "rescan", mod.rescan, 4 }, { "recapture", mod.recapture, 2 },
  { "plan", mod.plan, 2 }, { "duplicate_or_delete", mod.duplicate_or_delete, 1 },
}

local function weighted()
  local total = 0
  for _, a in ipairs(ACTIONS_TABLE) do total = total + a[3] end
  local r = rand(total)
  for _, a in ipairs(ACTIONS_TABLE) do
    r = r - a[3]
    if r <= 0 then return a end
  end
end

local function report()
  local names = {}
  for name in pairs(storage.counts) do names[#names + 1] = name end
  table.sort(names)
  local lines = { string.format("Stoich churn: %d actions, every %d ticks, seed %d, ended at tick %d", storage.done, EVERY, SEED, game.tick) }
  for _, name in ipairs(names) do
    lines[#lines + 1] = string.format("  %-20s %4d run, %3d errors", name, storage.counts[name], storage.errors[name] or 0)
  end
  local result = remote.call("stoich", "plan_result")
  lines[#lines + 1] = string.format("factories at the end: %d; plan status %s", #factory_ids(), tostring(result and result.status))
  lines[#lines + 1] = ""
  for _, n in ipairs(storage.notes) do lines[#lines + 1] = n end
  helpers.write_file("churn/report.txt", table.concat(lines, "\n"))
  helpers.write_file("churn/done.txt", "done")
end

script.on_init(function()
  storage.seed, storage.done, storage.counts, storage.errors = SEED, 0, {}, {}
  storage.notes, storage.placed, storage.recipes = {}, {}, {}
end)

script.on_event(defines.events.on_tick, function(event)
  if not remote.interfaces["stoich-test-world"] or not storage.seed then return end
  if not storage.start then storage.start = event.tick + 60 end
  local since = event.tick - storage.start
  if since < 0 or since % EVERY ~= 0 or storage.done > ACTIONS then return end
  if storage.done == ACTIONS then
    storage.done = storage.done + 1
    finish_draft()
    report()
    return
  end
  storage.done = storage.done + 1
  if storage.done == 1 then open("plan") end
  local a = weighted()
  storage.counts[a[1]] = (storage.counts[a[1]] or 0) + 1
  local ok, result = pcall(a[2])
  if ok then
    note(a[1] .. ": " .. tostring(result))
  else
    storage.errors[a[1]] = (storage.errors[a[1]] or 0) + 1
    note(a[1] .. " ERROR " .. tostring(result))
  end
end)
