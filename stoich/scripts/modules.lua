-- Module and beacon effects of a recipe line added by hand: which modules fit a
-- machine or beacon, and the speed, productivity and quality chance they give, worked out
-- as the game does, with the quality of modules, beacons and machine. Reads prototypes; no GUI.

local modules = {}

-- Effects whose sign is a bonus: only bonuses need to be allowed by a machine or beacon
-- (a speed module's small quality malus doesn't keep it out of a beacon).
local BONUS_SIGN = { speed = 1, productivity = 1, quality = 1, consumption = -1, pollution = -1 }

local DEFAULT_LIMITS = { low = -0.8, high = 1000 }

--- Can this module go where these effects and categories are allowed (nil: all)?
local function fits(module, allowed_effects, categories)
  if categories and not categories[module.category] then return false end
  if allowed_effects then
    for effect, v in pairs(module.module_effects or {}) do
      local sign = BONUS_SIGN[effect]
      if sign and v * sign > 0 and not allowed_effects[effect] then return false end
    end
  end
  return true
end
modules.fits = fits

local function sorted_modules(keep)
  local out = {}
  for name, p in pairs(prototypes.item) do
    if p.type == "module" and not p.hidden and keep(p) then out[#out + 1] = p end
  end
  table.sort(out, function(a, b)
    if a.category ~= b.category then return (a.category or "") < (b.category or "") end
    if (a.tier or 0) ~= (b.tier or 0) then return (a.tier or 0) < (b.tier or 0) end
    return a.name < b.name
  end)
  local names = {}
  for i, p in ipairs(out) do names[i] = p.name end
  return names
end

local function receiver(machine)
  return machine.effect_receiver or {}
end

local NORMAL = "normal"

--- A tier the game has, else nil (normal): an unknown name never reaches the API.
local function known(quality)
  if quality and quality ~= NORMAL and prototypes.quality[quality] then return quality end
  return nil
end
modules.known_quality = known

--- Module slots of a machine or beacon at a quality (0 when it takes no modules).
function modules.slots(machine, quality)
  if receiver(machine).uses_module_effects == false then return 0 end
  quality = known(quality)
  if quality and machine.get_inventory_size and defines and defines.inventory then
    local index = machine.type == "beacon" and defines.inventory.beacon_modules or defines.inventory.crafter_modules
    local n = index and machine.get_inventory_size(index, quality)
    if n then return n end
  end
  return machine.module_inventory_size or 0
end

--- A module's effects at a quality: bonuses grow with it, maluses don't.
function modules.module_effects(proto, quality)
  quality = known(quality)
  if quality and proto.get_module_effects then return proto.get_module_effects(quality) or {} end
  return proto.module_effects or {}
end

--- A beacon's distribution effectivity at a quality.
function modules.beacon_effectivity(beacon, quality)
  local e = beacon.distribution_effectivity or 1
  quality = known(quality)
  local level = quality and prototypes.quality[quality].level or 0
  return e + (beacon.distribution_effectivity_bonus_per_quality_level or 0) * level
end

--- A crafting machine's speed at a quality.
function modules.crafting_speed(machine, quality)
  quality = known(quality)
  if quality then return machine.get_crafting_speed(quality) or 1 end
  return machine.get_crafting_speed() or 1
end

--- Modules that fit a machine's slots for a recipe, sorted.
function modules.for_machine(machine, recipe)
  if modules.slots(machine) == 0 then return {} end
  return sorted_modules(function(m)
    return fits(m, machine.allowed_effects, machine.allowed_module_categories)
      and fits(m, recipe.allowed_effects, recipe.allowed_module_categories)
  end)
end

--- Beacons that can reach this machine, sorted by name.
function modules.beacons(machine)
  if receiver(machine).uses_beacon_effects == false then return {} end
  local out = {}
  for name, p in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "beacon" } })) do
    if not p.hidden and (p.module_inventory_size or 0) > 0 then out[#out + 1] = name end
  end
  table.sort(out)
  return out
end

--- Modules a beacon can hold that also work on this machine and recipe, sorted.
function modules.for_beacon(beacon, machine, recipe)
  return sorted_modules(function(m)
    return fits(m, beacon.allowed_effects, beacon.allowed_module_categories)
      and fits(m, machine.allowed_effects, machine.allowed_module_categories)
      and fits(m, recipe.allowed_effects, recipe.allowed_module_categories)
  end)
end

local function clamp(v, limits)
  limits = limits or DEFAULT_LIMITS
  return math.max(limits.low or DEFAULT_LIMITS.low, math.min(limits.high or DEFAULT_LIMITS.high, v))
end

--- Speed, productivity and quality chance (fractions, 0.4 = +40%) of a machine from its own
--- base effect, its modules and its beacons, within the machine's limits. Research
--- productivity is not in it (the recipe line adds it).
--- @param config table { modules = { [slot] = name }, module_qualities = { [slot] = tier }?,
---   machine_quality?, beacon = name?, beacon_quality?, beacon_count = n,
---   beacon_modules = { [slot] = name }, beacon_module_qualities = { [slot] = tier }? }
--- @return table { speed, productivity, quality }
function modules.effect(machine, recipe, config)
  local recv = receiver(machine)
  local base = recv.base_effect or {}
  local total = { speed = base.speed or 0, productivity = base.productivity or 0, quality = base.quality or 0 }
  local function add(name, quality, factor)
    local p = name and prototypes.item[name]
    if not (p and p.module_effects) then return end
    local e = modules.module_effects(p, quality)
    for k in pairs(total) do total[k] = total[k] + (e[k] or 0) * factor end
  end
  local mq = config.module_qualities or {}
  for slot = 1, modules.slots(machine, config.machine_quality) do add((config.modules or {})[slot], mq[slot], 1) end
  local beacon = config.beacon and prototypes.entity[config.beacon]
  local n = math.floor(config.beacon_count or 0)
  if beacon and n > 0 and recv.uses_beacon_effects ~= false then
    -- every beacon passes on its modules times its effectivity; together they are scaled
    -- by the profile entry for their number (the last entry beyond its end)
    local profile = beacon.profile or { 1 }
    local factor = n * modules.beacon_effectivity(beacon, config.beacon_quality) * (profile[math.min(n, #profile)] or 1)
    local bq = config.beacon_module_qualities or {}
    for slot = 1, modules.slots(beacon, config.beacon_quality) do add((config.beacon_modules or {})[slot], bq[slot], factor) end
  end
  total.speed = clamp(total.speed, recv.speed_limits)
  total.productivity = clamp(total.productivity, recv.productivity_limits)
  -- a negative quality effect (speed modules) does nothing unless the machine allows it
  total.quality = clamp(total.quality, recv.quality_limits or { low = 0, high = 1000 })
  if total.quality < 0 then total.quality = 0 end
  return total
end

--- Speed and productivity of one machine, in %: modules, beacons, research and the typed
--- extras, capped as the game caps them.
--- @param config table dialog shape (see modules.effect) with speed / prod: typed extras in %
--- @param research_pct number the recipe's research productivity, in %
--- @return table { speed, prod, research, quality } (quality: the chance, a fraction)
function modules.totals(machine, recipe, config, research_pct)
  local effect = modules.effect(machine, recipe, config)
  -- the game never goes below -80% speed
  local speed = math.max(-80, 100 * effect.speed + (config.speed or 0))
  local prod = math.max(0, 100 * effect.productivity + research_pct + (config.prod or 0))
  if recipe.maximum_productivity then prod = math.min(prod, 100 * recipe.maximum_productivity) end
  -- a recipe that doesn't allow quality gets none
  local quality = effect.quality
  if recipe.allowed_effects and recipe.allowed_effects.quality == false then quality = 0 end
  return { speed = speed, prod = prod, research = research_pct, quality = quality }
end

-- A line keeps its configuration as lists (they travel in export strings as they are);
-- the dialog works with maps by slot.

local function tier(q)
  if q == nil or q == NORMAL then return nil end
  return q
end

local function to_list(map, qualities)
  local slots = {}
  for slot in pairs(map or {}) do slots[#slots + 1] = slot end
  table.sort(slots)
  local out = {}
  for _, slot in ipairs(slots) do out[#out + 1] = { slot = slot, name = map[slot], quality = tier((qualities or {})[slot]) } end
  return out
end

local function to_map(list)
  local out, qualities = {}, {}
  for _, m in ipairs(list or {}) do
    if type(m) == "table" and m.slot and m.name then
      out[m.slot] = m.name
      qualities[m.slot] = m.quality
    end
  end
  return out, qualities
end

--- What a recipe line added by hand keeps: machine, modules, beacons, typed extras.
--- @param dlg table the recipe dialog's state
--- @param machine string machine name
function modules.line_config(dlg, machine)
  local beacons = (dlg.beacon_count or 0) > 0
  return {
    machine = machine,
    machine_quality = tier(dlg.machine_quality),
    recipe_quality = tier(dlg.recipe_quality),
    modules = to_list(dlg.modules, dlg.module_qualities),
    beacon = beacons and dlg.beacon or nil,
    beacon_quality = beacons and tier(dlg.beacon_quality) or nil,
    beacon_count = beacons and dlg.beacon_count or nil,
    beacon_modules = beacons and to_list(dlg.beacon_modules, dlg.beacon_module_qualities) or nil,
    speed = (dlg.speed or 0) ~= 0 and dlg.speed or nil,
    prod = (dlg.prod or 0) ~= 0 and dlg.prod or nil,
  }
end

--- A line's configuration in the dialog's shape (maps by slot), for modules.effect / totals.
function modules.dialog_config(config)
  local mods, mq = to_map(config.modules)
  local bmods, bq = to_map(config.beacon_modules)
  return {
    modules = mods, module_qualities = mq, machine_quality = config.machine_quality, recipe_quality = config.recipe_quality,
    beacon = config.beacon, beacon_quality = config.beacon_quality, beacon_count = config.beacon_count or 0,
    beacon_modules = bmods, beacon_module_qualities = bq, speed = config.speed or 0, prod = config.prod or 0,
  }
end

return modules
