-- Module and beacon effects of a recipe line added by hand: which modules fit a
-- machine or beacon, and the speed and productivity they give, worked out as the game
-- does (normal quality only). Reads prototypes; no GUI.

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

--- Module slots of a machine (0 when it takes no modules).
function modules.slots(machine)
  if receiver(machine).uses_module_effects == false then return 0 end
  return machine.module_inventory_size or 0
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

--- Speed and productivity (fractions, 0.4 = +40%) of a machine from its own base effect,
--- its modules and its beacons, within the machine's limits. Research productivity is
--- not in it (the recipe line adds it).
--- @param config table { modules = { [slot] = name }, beacon = name?, beacon_count = n,
---   beacon_modules = { [slot] = name } }
--- @return table { speed, productivity }
function modules.effect(machine, recipe, config)
  local recv = receiver(machine)
  local base = recv.base_effect or {}
  local total = { speed = base.speed or 0, productivity = base.productivity or 0 }
  local function add(name, factor)
    local p = name and prototypes.item[name]
    local e = p and p.module_effects
    if not e then return end
    for k in pairs(total) do total[k] = total[k] + (e[k] or 0) * factor end
  end
  for slot = 1, modules.slots(machine) do add((config.modules or {})[slot], 1) end
  local beacon = config.beacon and prototypes.entity[config.beacon]
  local n = math.floor(config.beacon_count or 0)
  if beacon and n > 0 and recv.uses_beacon_effects ~= false then
    -- every beacon passes on its modules times its effectivity; together they are scaled
    -- by the profile entry for their number (the last entry beyond its end)
    local profile = beacon.profile or { 1 }
    local factor = n * (beacon.distribution_effectivity or 1) * (profile[math.min(n, #profile)] or 1)
    for slot = 1, beacon.module_inventory_size or 0 do add((config.beacon_modules or {})[slot], factor) end
  end
  total.speed = clamp(total.speed, recv.speed_limits)
  total.productivity = clamp(total.productivity, recv.productivity_limits)
  return total
end

return modules
