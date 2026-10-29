-- Belt tiers from transport-belt prototypes and the tier lookup per flow.
-- tiers_from() and tier_for() are pure; read_tiers() reads the game.

local belts = {}

-- Items per second on a full belt per unit of prototype speed:
-- speed is tiles per tick, a belt holds 8 items per tile (4 per lane), 60 ticks per second.
belts.ITEMS_PER_SPEED = 480

--- Build tiers sorted by capacity.
--- @param protos table[] { name, speed (tiles/tick), color? }
--- @param stack_size number? items per belt slot (1 without belt stacking)
--- @return table[] { name, speed, capacity (items/s full belt), color }
function belts.tiers_from(protos, stack_size)
  stack_size = stack_size or 1
  local tiers = {}
  for _, p in ipairs(protos) do
    if p.speed and p.speed > 0 then
      tiers[#tiers + 1] = { name = p.name, speed = p.speed, capacity = p.speed * belts.ITEMS_PER_SPEED * stack_size }
    end
  end
  table.sort(tiers, function(a, b)
    if a.capacity ~= b.capacity then return a.capacity < b.capacity end
    return a.name < b.name
  end)
  -- Belts of equal speed (e.g. two mods adding the same tier) collapse into the first.
  local unique = {}
  for _, t in ipairs(tiers) do
    local last = unique[#unique]
    if not last or math.abs(last.capacity - t.capacity) > 1e-9 then unique[#unique + 1] = t end
  end
  return unique
end

--- Index of a tier by belt name, or nil.
function belts.index_of(tiers, name)
  for i, t in ipairs(tiers) do
    if t.name == name then return i end
  end
end

--- Which belt a flow needs.
--- @param rate number items/s (sign ignored)
--- @param tiers table[] from tiers_from
--- @param max_index integer? highest allowed tier (default: the last)
--- @param one_lane boolean? plan with half a belt
--- @return table? nil for zero flow or no belts; else
---   { index, tier, exceeds = bool, belts = number of max-tier belts needed }
function belts.tier_for(rate, tiers, max_index, one_lane)
  rate = math.abs(rate or 0)
  if rate <= 0 or #tiers == 0 then return nil end
  max_index = math.min(max_index or #tiers, #tiers)
  local factor = one_lane and 0.5 or 1
  for i = 1, max_index do
    -- A tiny tolerance so 15/s exactly fits a 15/s belt despite float noise.
    if rate <= tiers[i].capacity * factor * (1 + 1e-9) then
      return { index = i, tier = tiers[i], exceeds = false, belts = rate / (tiers[i].capacity * factor) }
    end
  end
  local top = tiers[max_index]
  return { index = max_index, tier = top, exceeds = true, belts = rate / (top.capacity * factor) }
end

--- Is this item key a fluid? Decided by the prototype type in the key, never by name.
--- @param key string item key
--- @param fluid_keys table<string, boolean>? custom keys marked as fluid
function belts.is_fluid(key, fluid_keys)
  if key:sub(1, 6) == "fluid/" then return true end
  if key:sub(1, 7) == "custom/" then return (fluid_keys and fluid_keys[key]) and true or false end
  return false
end

--- Read transport-belt prototypes from the game (runtime only).
--- @param force LuaForce? for the belt stack size bonus
function belts.read_tiers(force)
  local protos = {}
  for name, proto in pairs(prototypes.get_entity_filtered({ { filter = "type", type = "transport-belt" } })) do
    if not proto.hidden then
      protos[#protos + 1] = { name = name, speed = proto.belt_speed }
    end
  end
  table.sort(protos, function(a, b) return a.name < b.name end)
  local stack = 1
  if force and force.valid then stack = 1 + (force.belt_stack_size_bonus or 0) end
  return belts.tiers_from(protos, stack)
end

return belts
