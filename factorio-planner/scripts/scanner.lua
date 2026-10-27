-- Entities -> recipe lines, and the rate formulas behind them.
-- The *_flow functions are pure (plain tables in, flow maps out) so they are
-- tested offline; scan_entities() and friends read LuaEntity objects.

local fp_util = require("scripts.util")

local scanner = {}

scanner.PRODUCTION_TYPES = { "assembling-machine", "furnace", "rocket-silo", "mining-drill", "offshore-pump" }
scanner.GENERATOR_TYPES = { "boiler", "generator", "burner-generator", "reactor" }

local production_type, generator_type = {}, {}
for _, t in ipairs(scanner.PRODUCTION_TYPES) do production_type[t] = true end
for _, t in ipairs(scanner.GENERATOR_TYPES) do generator_type[t] = true end
scanner.is_production_type = production_type
scanner.is_generator_type = generator_type

--- Expected amount of one product per craft, before productivity
--- (same as core util.product_amount; 2.1 split probability into independent and shared).
function scanner.product_amount(product)
  local amount = product.amount or ((product.amount_min + product.amount_max) / 2)
  if product.extra_count_fraction then amount = amount + product.extra_count_fraction end
  if product.independent_probability then
    amount = amount * product.independent_probability
  elseif product.probability then
    amount = amount * product.probability
  end
  if product.shared_probability then
    amount = amount * (product.shared_probability.max - product.shared_probability.min)
  end
  return amount
end

local function add(flow, key, v)
  local x = (flow[key] or 0) + v
  if math.abs(x) < 1e-12 then x = nil end
  flow[key] = x
end

--- Flow of one crafting machine.
--- @param ingredients table[] Ingredient
--- @param products table[] Product
--- @param crafts_per_second number crafting_speed / recipe energy
--- @param productivity number bonus, 0.1 = +10%
function scanner.recipe_flow(ingredients, products, crafts_per_second, productivity)
  local flow = {}
  for _, ing in ipairs(ingredients) do
    add(flow, fp_util.key(ing.type, ing.name), -ing.amount * crafts_per_second)
  end
  for _, product in ipairs(products) do
    if product.type == "item" or product.type == "fluid" then
      local expected = scanner.product_amount(product)
      local ignored = math.min(expected, product.ignored_by_productivity or 0)
      local amount = ignored + (expected - ignored) * (1 + productivity)
      add(flow, fp_util.key(product.type, product.name), amount * crafts_per_second)
    end
  end
  return flow
end

--- Flow of one mining drill.
--- @param resources table[] { products, mining_time, required_fluid?, fluid_amount?, share }
---   share = fraction of the drill's resource tiles of this resource (sums to 1)
--- @param mining_speed number prototype mining speed × (1 + speed bonus)
--- @param productivity number entity productivity bonus (includes mining research)
function scanner.mining_flow(resources, mining_speed, productivity)
  local flow = {}
  for _, res in ipairs(resources) do
    local cycles = mining_speed / res.mining_time * (res.share or 1)
    for _, product in ipairs(res.products or {}) do
      if product.type == "item" or product.type == "fluid" then
        add(flow, fp_util.key(product.type, product.name), scanner.product_amount(product) * cycles * (1 + productivity))
      end
    end
    if res.required_fluid then
      -- fluid_amount is per ten mining operations; productivity doesn't apply to it
      add(flow, fp_util.key("fluid", res.required_fluid), -(res.fluid_amount or 0) / 10 * cycles)
    end
  end
  return flow
end

--- Flow of one offshore pump.
--- @param pumping_speed number per tick
function scanner.pump_flow(fluid, pumping_speed)
  if not fluid then return {} end
  return { [fp_util.key("fluid", fluid)] = pumping_speed * 60 }
end

--- Line grouping key: (kind, recipe or resource, machine).
function scanner.group_key(kind, what, machine)
  return kind .. "|" .. (what or "") .. "|" .. (machine or "")
end

--- Group per-entity results into lines. Pure.
--- @param entries table[] { kind, recipe?, resource?, machine, flow?, idle? }
--- @return table[] lines without ids, sorted by key; flow is the average per machine
function scanner.group(entries)
  local groups, keys = {}, {}
  for _, e in ipairs(entries) do
    local what = e.recipe or e.resource
    local key = scanner.group_key(e.idle and "idle" or e.kind, what, e.machine)
    local g = groups[key]
    if not g then
      g = { kind = e.kind, recipe = e.recipe, resource = e.resource, machine = e.machine, count = 0, sum = {}, idle = e.idle or nil, key = key, speed = 0, productivity = 0, measured = 0 }
      groups[key] = g
      keys[#keys + 1] = key
    end
    g.count = g.count + 1
    for k, v in pairs(e.flow or {}) do g.sum[k] = (g.sum[k] or 0) + v end
    if e.speed then
      g.speed = g.speed + e.speed
      g.productivity = g.productivity + (e.productivity or 0)
      g.measured = g.measured + 1
    end
  end
  -- Idle machines last, the rest by key.
  table.sort(keys, function(a, b)
    local ia, ib = groups[a].idle and 1 or 0, groups[b].idle and 1 or 0
    if ia ~= ib then return ia < ib end
    return a < b
  end)
  local lines = {}
  for _, key in ipairs(keys) do
    local g = groups[key]
    local flow = {}
    for k, v in pairs(g.sum) do flow[k] = v / g.count end
    lines[#lines + 1] = {
      kind = g.kind, recipe = g.recipe, resource = g.resource, machine = g.machine,
      count = g.count, flow = flow, idle = g.idle, key = key, overridden = false, fluid_keys = {},
      -- averages, for the /fp-lines check against machine tooltips
      speed = g.measured > 0 and g.speed / g.measured or nil,
      productivity = g.measured > 0 and g.productivity / g.measured or nil,
    }
  end
  return lines
end

--- Net flow of lines at their counts. Pure.
function scanner.net_at_counts(lines)
  local net = {}
  for _, line in ipairs(lines) do
    for k, v in pairs(line.flow) do net[k] = (net[k] or 0) + v * (line.count or 0) end
  end
  return net
end

--- Main product: among items no line consumes (the build's real outputs), the
--- one with the largest net flow; if every product is also consumed somewhere,
--- the largest positive net flow. Ties by key.
function scanner.main_product(lines)
  local net = scanner.net_at_counts(lines)
  local consumed = {}
  for _, line in ipairs(lines) do
    for k, v in pairs(line.flow) do
      if v < 0 then consumed[k] = true end
    end
  end
  local function best(only_final)
    local key, value = nil, 0
    for _, k in ipairs(fp_util.sorted_keys(net)) do
      if (not only_final or not consumed[k]) and net[k] > value + 1e-12 then key, value = k, net[k] end
    end
    return key
  end
  return best(true) or best(false)
end

-- Runtime -------------------------------------------------------------------

local function recipe_name(id)
  if id == nil then return nil end
  if type(id) == "string" then return id end
  return id.name
end

local function crafter_entry(entity, force)
  local recipe = entity.get_recipe()
  if not recipe and entity.type == "furnace" then
    local prev = entity.previous_recipe
    local name = prev and recipe_name(prev.name)
    if name then recipe = force.recipes[name] end
  end
  if not recipe then
    return { kind = "recipe", machine = entity.name, idle = true }
  end
  local cps = entity.crafting_speed / recipe.energy
  local prod = math.min(entity.productivity_bonus + recipe.productivity_bonus, recipe.prototype.maximum_productivity)
  return {
    kind = "recipe",
    recipe = recipe.name,
    machine = entity.name,
    flow = scanner.recipe_flow(recipe.ingredients, recipe.products, cps, prod),
    speed = entity.crafting_speed,
    productivity = prod,
  }
end

local function drill_entry(entity)
  local proto = entity.prototype
  local categories = proto.resource_categories or {}
  local has_fluidbox = next(proto.fluidbox_prototypes) ~= nil
  local found = entity.surface.find_entities_filtered({ area = entity.mining_area, type = "resource" })
  local by_name, names, total = {}, {}, 0
  for _, res in ipairs(found) do
    local rp = res.prototype
    local mp = rp.mineable_properties
    if categories[rp.resource_category] and mp.minable and (has_fluidbox or not mp.required_fluid) then
      local data = by_name[res.name]
      if not data then
        local mining_time = mp.mining_time
        if rp.infinite_resource and rp.normal_resource_amount > 0 then
          mining_time = mining_time / (res.amount / rp.normal_resource_amount)
        end
        data = { products = mp.products, mining_time = mining_time, required_fluid = mp.required_fluid, fluid_amount = mp.fluid_amount, share = 0, n = 0 }
        by_name[res.name] = data
        names[#names + 1] = res.name
      end
      data.n = data.n + 1
      total = total + 1
    end
  end
  if total == 0 then
    return { kind = "mining", machine = entity.name, idle = true }
  end
  table.sort(names)
  local resources = {}
  local main, main_n = nil, -1
  for _, name in ipairs(names) do
    local data = by_name[name]
    data.share = data.n / total
    resources[#resources + 1] = data
    if data.n > main_n then main, main_n = name, data.n end
  end
  local target = entity.mining_target
  if target and target.valid and by_name[target.name] then main = target.name end
  local speed = proto.mining_speed * (1 + entity.speed_bonus)
  return {
    kind = "mining",
    resource = main,
    machine = entity.name,
    flow = scanner.mining_flow(resources, speed, entity.productivity_bonus),
    speed = speed,
    productivity = entity.productivity_bonus,
  }
end

local function pump_entry(entity)
  local fluid = entity.get_fluid_source_fluid and entity.get_fluid_source_fluid()
  if not fluid then
    local f = entity.get_fluid(1)
    fluid = f and f.name
  end
  if not fluid then
    return { kind = "pump", machine = entity.name, idle = true }
  end
  return {
    kind = "pump",
    resource = fluid,
    machine = entity.name,
    flow = scanner.pump_flow(fluid, entity.prototype.get_pumping_speed(entity.quality) or 0),
  }
end

--- Per-entity entry for a production entity, or nil for other types.
function scanner.entity_entry(entity, force)
  if not (entity and entity.valid) then return nil end
  local t = entity.type
  if t == "assembling-machine" or t == "furnace" or t == "rocket-silo" then return crafter_entry(entity, force) end
  if t == "mining-drill" then return drill_entry(entity) end
  if t == "offshore-pump" then return pump_entry(entity) end
  return nil
end

--- Fuel items or fluids burnt by a generator-like entity.
local function generator_fuel(entity)
  local keys = {}
  local burner = entity.burner
  if burner then
    local burning = burner.currently_burning
    local name = burning and recipe_name(burning.name)
    if not name and burner.inventory then
      local contents = burner.inventory.get_contents()
      name = contents[1] and contents[1].name
    end
    if name then keys[#keys + 1] = fp_util.key("item", name) end
  end
  if entity.type == "generator" or (entity.type == "boiler" and not burner) then
    local f = entity.fluids_count > 0 and entity.get_fluid(1)
    if f then keys[#keys + 1] = fp_util.key("fluid", f.name) end
  end
  return keys
end

--- Scan entities into lines.
--- @return table { lines, idle = number of idle machines, generators = { [item_key] = true } , production = number }
function scanner.scan_entities(entities, force)
  local entries, generators, production = {}, {}, 0
  for _, entity in ipairs(entities) do
    if entity.valid then
      if production_type[entity.type] then
        local e = scanner.entity_entry(entity, force)
        if e then
          entries[#entries + 1] = e
          production = production + 1
        end
      elseif generator_type[entity.type] then
        for _, key in ipairs(generator_fuel(entity)) do generators[key] = true end
      end
    end
  end
  local lines = scanner.group(entries)
  local idle = 0
  for _, line in ipairs(lines) do
    if line.idle then idle = idle + line.count end
  end
  return { lines = lines, idle = idle, generators = generators, production = production }
end

--- Find production entities again in saved areas (for Rescan).
function scanner.find_in_areas(surface, areas, force)
  local seen, out = {}, {}
  for _, area in ipairs(areas) do
    local found = surface.find_entities_filtered({ area = area, type = scanner.PRODUCTION_TYPES, force = force })
    for _, e in ipairs(found) do
      local id = e.unit_number
      if id and not seen[id] then
        seen[id] = true
        out[#out + 1] = e
      elseif not id then
        out[#out + 1] = e
      end
    end
  end
  return out
end

--- Flow of a manually added recipe line from prototypes, at the machine's base speed.
--- @param speed_pct number? extra speed in %
--- @param prod_pct number? productivity in %
function scanner.manual_recipe_flow(recipe_proto, machine_proto, speed_pct, prod_pct)
  local speed = (machine_proto.get_crafting_speed() or 1) * (1 + (speed_pct or 0) / 100)
  local prod = (prod_pct or 0) / 100
  local max = recipe_proto.maximum_productivity
  if max and prod > max then prod = max end
  return scanner.recipe_flow(recipe_proto.ingredients, recipe_proto.products, speed / recipe_proto.energy, prod)
end

--- Machines that can craft a recipe (runtime), sorted by crafting speed then name.
function scanner.machines_for_recipe(recipe_proto)
  local out = {}
  -- 2.1 recipes have a list of categories; 2.0 had a single `category`.
  local cats = recipe_proto.categories or { recipe_proto.category }
  local function supports(proto)
    local supported = proto.crafting_categories
    if not supported then return false end
    for _, cat in ipairs(cats) do
      if supported[cat] then return true end
    end
    return false
  end
  for name, proto in pairs(prototypes.get_entity_filtered({
    { filter = "type", type = "assembling-machine" },
    { filter = "type", type = "furnace" },
    { filter = "type", type = "rocket-silo" },
  })) do
    if supports(proto) and not proto.hidden then
      out[#out + 1] = { name = name, speed = proto.get_crafting_speed() or 1 }
    end
  end
  table.sort(out, function(a, b)
    if a.speed ~= b.speed then return a.speed < b.speed end
    return a.name < b.name
  end)
  local names = {}
  for _, m in ipairs(out) do names[#names + 1] = m.name end
  return names
end

return scanner
