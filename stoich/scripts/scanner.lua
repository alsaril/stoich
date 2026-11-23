-- Entities -> recipe lines, and the rate formulas behind them.
-- The *_flow functions are pure (plain tables in, flow maps out) so they are
-- tested offline; scan_entities() and friends read LuaEntity objects.

local fp_util = require("scripts.util")
local modules = require("scripts.modules")

local scanner = {}

scanner.PRODUCTION_TYPES = { "assembling-machine", "furnace", "rocket-silo", "mining-drill", "offshore-pump" }
scanner.GENERATOR_TYPES = { "boiler", "generator", "burner-generator", "reactor" }

local production_type, generator_type = {}, {}
for _, t in ipairs(scanner.PRODUCTION_TYPES) do production_type[t] = true end
for _, t in ipairs(scanner.GENERATOR_TYPES) do generator_type[t] = true end

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

-- Quality ----------------------------------------------------------------------------------------

--- Where a quality roll lands, as the game rolls it (2.1): from the base tier one step up with
--- chance × the base tier's next_probability, then each further step with the chain_probability
--- of the tier reached (a chance above 1 carries into the second step). Rolls stop at the last
--- tier and at the first locked one, which takes the rest. Pure.
--- @param tiers table<string, table> { [name] = { next = name?, next_probability, chain_probability } }
--- @param base string the tier the products start at
--- @param chance number quality effect (0.1 = 10%)
--- @param unlocked table<string, boolean>? tiers the force has (nil: all)
--- @return table<string, number> fraction by tier, summing to 1
function scanner.quality_split(tiers, base, chance, unlocked)
  local out = {}
  local tier = tiers[base]
  local function open(name) return name and tiers[name] and (unlocked == nil or unlocked[name]) end
  if not tier or not chance or chance <= 0 or not open(tier.next) then
    out[base] = 1
    return out
  end
  local first = chance * (tier.next_probability or 0)
  local step = math.min(1, first)
  out[base] = 1 - step
  local mass, name, overflow = step, tier.next, math.max(1, first)
  while true do
    local t = tiers[name]
    local q = math.min(1, (t.chain_probability or 0) * overflow)
    overflow = 1
    if q <= 0 or not open(t.next) then
      out[name] = (out[name] or 0) + mass
      break
    end
    out[name] = (out[name] or 0) + mass * (1 - q)
    mass = mass * q
    name = t.next
  end
  for k, v in pairs(out) do
    if v <= 0 then out[k] = nil end
  end
  return out
end

--- Split an amount of an item over the tiers a roll gives (into flow).
local function add_split(flow, name, amount, base, rolls)
  local split = rolls and rolls(base) or { [base] = 1 }
  for q, f in pairs(split) do add(flow, fp_util.key("item", name, q), amount * f) end
end

--- Flow of one crafting machine.
--- @param ingredients table[] Ingredient
--- @param products table[] Product
--- @param crafts_per_second number crafting_speed / recipe energy
--- @param productivity number bonus, 0.1 = +10%
--- @param quality table? { quality = recipe tier, rolls = fn(base tier) -> { [tier] = fraction }?,
---   ingredient_quality = { [i] = tier }?, product_quality = { [i] = tier }? }: item ingredients
---   are used at the recipe's tier (or their own), item products start there and are rolled
---   after productivity; fluids have no tier. nil: everything normal (no quality).
function scanner.recipe_flow(ingredients, products, crafts_per_second, productivity, quality)
  local flow = {}
  local rq = quality and quality.quality
  for i, ing in ipairs(ingredients) do
    local q = ing.type == "item" and (quality and quality.ingredient_quality and quality.ingredient_quality[i] or rq) or nil
    add(flow, fp_util.key(ing.type, ing.name, q), -ing.amount * crafts_per_second)
  end
  for i, product in ipairs(products) do
    if product.type == "item" or product.type == "fluid" then
      local expected = scanner.product_amount(product)
      local ignored = math.min(expected, product.ignored_by_productivity or 0)
      local amount = (ignored + (expected - ignored) * (1 + productivity)) * crafts_per_second
      if product.type == "item" and quality then
        local base = quality.product_quality and quality.product_quality[i] or rq or fp_util.NORMAL
        add_split(flow, product.name, amount, base, product.affected_by_quality ~= false and quality.rolls or nil)
      else
        add(flow, fp_util.key(product.type, product.name), amount)
      end
    end
  end
  return flow
end

--- Flow of one mining drill.
--- @param resources table[] { products, mining_time, required_fluid?, fluid_amount?, share }
---   share = fraction of the drill's resource tiles of this resource (sums to 1)
--- @param mining_speed number prototype mining speed × (1 + speed bonus)
--- @param productivity number entity productivity bonus (includes mining research)
--- @param rolls function? fn(base tier) -> { [tier] = fraction }: mined items start normal
function scanner.mining_flow(resources, mining_speed, productivity, rolls)
  local flow = {}
  for _, res in ipairs(resources) do
    local cycles = mining_speed / res.mining_time * (res.share or 1)
    for _, product in ipairs(res.products or {}) do
      local amount = scanner.product_amount(product) * cycles * (1 + productivity)
      if product.type == "item" and rolls then
        add_split(flow, product.name, amount, fp_util.NORMAL, rolls)
      elseif product.type == "item" or product.type == "fluid" then
        add(flow, fp_util.key(product.type, product.name), amount)
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

--- Line grouping key: (kind, recipe or resource, machine), and the recipe's and the
--- machine's tier when not normal (rescans of factories from before quality still match).
function scanner.group_key(kind, what, machine, recipe_quality, machine_quality)
  local key = kind .. "|" .. (what or "") .. "|" .. (machine or "")
  if recipe_quality or machine_quality then key = key .. "|" .. (recipe_quality or "") .. "|" .. (machine_quality or "") end
  return key
end

--- A machine's own values (no research) as a variant key: machines of one line with the
--- same modules and beacons share a variant. A drill's speed is in its `base` flow.
local function variant_key(e)
  local speed = e.kind == "mining" and 0 or (e.speed or 0)
  return string.format("%.12g|%.12g|%.12g", speed, e.own_productivity or 0, e.quality_chance or 0)
end

--- Group per-entity results into lines. Pure.
--- @param entries table[] { kind, recipe?, resource?, machine, flow?, idle?, speed?, productivity?,
---   own_productivity?, quality_chance?, base? (a drill's flow at no productivity) }
--- @return table[] lines without ids, sorted by key; flow is the average per machine.
---   Lines of entries with own_productivity keep their inputs: `variants`, one per distinct
---   set of machine values ({ n, speed, productivity, quality_chance, base? }), sorted.
function scanner.group(entries)
  local groups, keys = {}, {}
  for _, e in ipairs(entries) do
    local what = e.recipe or e.resource
    local key = scanner.group_key(e.idle and "idle" or e.kind, what, e.machine, e.recipe_quality, e.machine_quality)
    local g = groups[key]
    if not g then
      g = { kind = e.kind, recipe = e.recipe, resource = e.resource, machine = e.machine, count = 0, sum = {}, idle = e.idle or nil, key = key, speed = 0, productivity = 0, measured = 0,
        recipe_quality = e.recipe_quality, machine_quality = e.machine_quality,
        variants = {}, variant_keys = {}, inputs = true }
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
    if e.own_productivity == nil or e.idle then
      g.inputs = false
    else
      local vk = variant_key(e)
      local v = g.variants[vk]
      if not v then
        v = { n = 0, speed = e.kind ~= "mining" and e.speed or nil, productivity = e.own_productivity, quality_chance = e.quality_chance or 0,
          base = e.base and {} or nil }
        g.variants[vk] = v
        g.variant_keys[#g.variant_keys + 1] = vk
      end
      v.n = v.n + 1
      for k, x in pairs(e.base or {}) do v.base[k] = (v.base[k] or 0) + x end
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
    local variants
    if g.inputs and #g.variant_keys > 0 then
      variants = {}
      table.sort(g.variant_keys)
      for i, vk in ipairs(g.variant_keys) do
        local v = g.variants[vk]
        -- a drill's base flow is the average of its machines
        for k, x in pairs(v.base or {}) do v.base[k] = x / v.n end
        variants[i] = v
      end
    end
    lines[#lines + 1] = {
      kind = g.kind, recipe = g.recipe, resource = g.resource, machine = g.machine,
      count = g.count, flow = flow, idle = g.idle, key = key, overridden = false, fluid_keys = {},
      -- averages, for the /stoich-lines check against machine tooltips
      speed = g.measured > 0 and g.speed / g.measured or nil,
      productivity = g.measured > 0 and g.productivity / g.measured or nil,
      variants = variants,
      recipe_quality = g.recipe_quality, machine_quality = g.machine_quality,
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
--- the largest positive net flow. Ties by key. Tiers of one item count together, and the
--- highest of them that is an output names the build (an upcycling loop is named and
--- anchored after its legendary output).
function scanner.main_product(lines)
  local net = scanner.net_at_counts(lines)
  local consumed = {}
  for _, line in ipairs(lines) do
    for k, v in pairs(line.flow) do
      if v < 0 then consumed[k] = true end
    end
  end
  local function best(only_final)
    -- by base item first
    local sums, tops = {}, {}
    for _, k in ipairs(fp_util.sorted_keys(net, fp_util.key_less)) do
      if (not only_final or not consumed[k]) and net[k] > 1e-12 then
        local base = fp_util.base_key(k)
        sums[base] = (sums[base] or 0) + net[k]
        tops[base] = k -- sorted by tier: the last is the highest
      end
    end
    local key, value = nil, 0
    for _, base in ipairs(fp_util.sorted_keys(sums, fp_util.key_less)) do
      if sums[base] > value + 1e-12 then key, value = tops[base], sums[base] end
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

--- The game's quality tiers as plain tables for quality_split, and the ones a force has (runtime).
function scanner.quality_tiers(force)
  local tiers, unlocked = {}, {}
  for name, q in pairs(prototypes.quality) do
    tiers[name] = { name = name, level = q.level, next = q.next and q.next.name or nil,
      next_probability = q.next_probability or 0, chain_probability = q.chain_probability or 0 }
    if not force or not force.is_quality_unlocked or force.is_quality_unlocked(name) then unlocked[name] = true end
  end
  return tiers, unlocked
end

--- Where a force's rolls land with this quality effect: fn(base tier) -> { [tier] = fraction },
--- or nil without quality effect (runtime). The game's own get_roll_chances when it has it.
function scanner.rolls(chance, force)
  if not chance or chance <= 0 then return nil end
  local tiers, unlocked
  local cache = {}
  return function(base)
    if cache[base] then return cache[base] end
    local proto = prototypes.quality[base]
    local split
    if proto and proto.get_roll_chances then
      split = proto.get_roll_chances(chance, force)
    else
      if not tiers then tiers, unlocked = scanner.quality_tiers(force) end
      split = scanner.quality_split(tiers, base, chance, unlocked)
    end
    cache[base] = split
    return split
  end
end

--- Quality of a recipe's craft for recipe_flow, or nil when everything is normal (runtime).
--- @param recipe_proto LuaRecipePrototype
--- @param recipe_quality string? its tier (nil: normal)
--- @param chance number quality effect of the machine
function scanner.quality_opts(recipe_proto, recipe_quality, chance, force)
  local rq = modules.known_quality(recipe_quality) or fp_util.NORMAL
  local q = { quality = rq, rolls = scanner.rolls(chance, force) }
  local any = q.rolls ~= nil or rq ~= fp_util.NORMAL
  -- 2.1: an ingredient or product can have a tier of its own (quality_change, min, max)
  if recipe_proto and recipe_proto.get_ingredient_quality then
    q.ingredient_quality, q.product_quality = {}, {}
    for i, ing in ipairs(recipe_proto.ingredients or {}) do
      if ing.type == "item" then
        local name = recipe_proto.get_ingredient_quality(i, rq).name
        q.ingredient_quality[i] = name
        if name ~= fp_util.NORMAL then any = true end
      end
    end
    for i, product in ipairs(recipe_proto.products or {}) do
      if product.type == "item" then
        local name = recipe_proto.get_product_quality(i, rq).name
        q.product_quality[i] = name
        if name ~= fp_util.NORMAL then any = true end
      end
    end
  end
  return any and q or nil
end

--- A quality's name from a LuaQualityPrototype, a name or nil; nil for normal.
local function tier_name(q)
  if q == nil then return nil end
  local name = type(q) == "string" and q or q.name
  if name == fp_util.NORMAL then return nil end
  return name
end
scanner.tier_name = tier_name

--- The quality effect on a machine: modules, beacons, its base effect (runtime).
local function quality_chance(entity)
  local ok, effects = pcall(function() return entity.effects end)
  local q = ok and effects and effects.quality or 0
  return q > 0 and q or 0
end

local function crafter_entry(entity, force)
  -- the recipe and its tier; an idle furnace or recycler its last one (the tier of its input)
  local recipe, rq = entity.get_recipe()
  if not recipe and entity.type == "furnace" then
    local prev = entity.previous_recipe
    local name = prev and recipe_name(prev.name)
    if name then
      recipe = force.recipes[name]
      rq = prev.quality
    end
  end
  local mq = tier_name(entity.quality)
  if not recipe then
    return { kind = "recipe", machine = entity.name, idle = true, machine_quality = mq }
  end
  rq = tier_name(rq)
  local chance = quality_chance(entity)
  -- a recipe that doesn't allow quality rolls none (as the recipe dialog counts it)
  local allowed = recipe.prototype.allowed_effects
  if allowed and allowed.quality == false then chance = 0 end
  local cps = entity.crafting_speed / recipe.energy
  local prod = math.min(entity.productivity_bonus + recipe.productivity_bonus, recipe.prototype.maximum_productivity)
  return {
    kind = "recipe",
    recipe = recipe.name,
    machine = entity.name,
    recipe_quality = rq,
    machine_quality = mq,
    quality_chance = chance,
    flow = scanner.recipe_flow(recipe.ingredients, recipe.products, cps, prod, scanner.quality_opts(recipe.prototype, rq, chance, force)),
    speed = entity.crafting_speed,
    productivity = prod,
    -- the machine's own: research comes on top when the line is worked out again
    own_productivity = entity.productivity_bonus,
  }
end

--- Mining productivity research a drill takes (runtime).
function scanner.mining_research(drill_proto, force)
  if drill_proto.uses_force_mining_productivity_bonus == false then return 0 end
  return force and force.mining_drill_productivity_bonus or 0
end

local function drill_entry(entity, force)
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
  local chance = quality_chance(entity)
  return {
    kind = "mining",
    resource = main,
    machine = entity.name,
    machine_quality = tier_name(entity.quality),
    quality_chance = chance,
    flow = scanner.mining_flow(resources, speed, entity.productivity_bonus, scanner.rolls(chance, force)),
    speed = speed,
    productivity = entity.productivity_bonus,
    -- without mining research (it is in productivity_bonus), and the flow at no productivity
    own_productivity = entity.productivity_bonus - scanner.mining_research(proto, force),
    base = scanner.mining_flow(resources, speed, 0),
  }
end

local function pump_entry(entity)
  local fluid = entity.get_fluid_source_fluid and entity.get_fluid_source_fluid()
  if not fluid then
    local f = entity.get_fluid(1)
    fluid = f and f.name
  end
  if not fluid then
    return { kind = "pump", machine = entity.name, idle = true, machine_quality = tier_name(entity.quality) }
  end
  return {
    kind = "pump",
    resource = fluid,
    machine = entity.name,
    machine_quality = tier_name(entity.quality),
    flow = scanner.pump_flow(fluid, entity.prototype.get_pumping_speed(entity.quality) or 0),
  }
end

--- Per-entity entry for a production entity, or nil for other types.
function scanner.entity_entry(entity, force)
  if not (entity and entity.valid) then return nil end
  local t = entity.type
  if t == "assembling-machine" or t == "furnace" or t == "rocket-silo" then return crafter_entry(entity, force) end
  if t == "mining-drill" then return drill_entry(entity, force) end
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
--- @param quality table? { machine_quality?, recipe_quality?, chance?, force? }
function scanner.manual_recipe_flow(recipe_proto, machine_proto, speed_pct, prod_pct, quality)
  quality = quality or {}
  local speed = modules.crafting_speed(machine_proto, quality.machine_quality) * (1 + (speed_pct or 0) / 100)
  local prod = (prod_pct or 0) / 100
  local max = recipe_proto.maximum_productivity
  if max and prod > max then prod = max end
  return scanner.recipe_flow(recipe_proto.ingredients, recipe_proto.products, speed / recipe_proto.energy, prod,
    scanner.quality_opts(recipe_proto, quality.recipe_quality, quality.chance or 0, quality.force))
end

-- Working a line out again --------------------------------------------------------------------

--- Does this line keep what it was worked out from (so research can change it)?
--- Overridden and custom lines are their flow; lines captured before 0.5 have no inputs.
function scanner.has_inputs(line)
  if line.overridden or line.kind == "custom" or line.idle then return false end
  return line.variants ~= nil or line.config ~= nil
end

--- A line captured or added by hand, worked out again from its inputs with the force's
--- current research (runtime). nil when it has no inputs or its prototypes are gone.
function scanner.line_flow(line, force)
  if not scanner.has_inputs(line) then return nil end
  if line.config then return scanner.config_flow(line.recipe, line.config, force) end
  local sum, n = {}, 0
  local function add_flow(flow, k)
    for key, v in pairs(flow) do sum[key] = (sum[key] or 0) + v * k end
    n = n + k
  end
  if line.kind == "recipe" then
    local proto = line.recipe and prototypes.recipe[line.recipe]
    if not proto then return nil end
    local r = force and force.recipes[line.recipe]
    local research = r and r.productivity_bonus or 0
    local energy = r and r.energy or proto.energy
    local ingredients, products = r and r.ingredients or proto.ingredients, r and r.products or proto.products
    for _, v in ipairs(line.variants) do
      if not v.speed then return nil end -- a crafter's variant needs its speed
      local prod = math.min(v.productivity + research, proto.maximum_productivity or math.huge)
      local quality = scanner.quality_opts(proto, line.recipe_quality, v.quality_chance or 0, force)
      add_flow(scanner.recipe_flow(ingredients, products, v.speed / energy, prod, quality), v.n)
    end
  elseif line.kind == "mining" then
    local drill = line.machine and prototypes.entity[line.machine]
    if not drill then return nil end
    local research = scanner.mining_research(drill, force)
    for _, v in ipairs(line.variants) do
      if not v.base then return nil end -- a drill's variant needs its flow
      local flow = {}
      local rolls = scanner.rolls(v.quality_chance or 0, force)
      -- products take productivity and are rolled (mined items start normal), a required fluid doesn't
      for key, x in pairs(v.base or {}) do
        if x > 0 then
          local amount = x * (1 + v.productivity + research)
          local t, name = fp_util.parse_key(key)
          for q, f in pairs(t == "item" and rolls and rolls(fp_util.NORMAL) or { [fp_util.NORMAL] = 1 }) do
            local k = fp_util.with_quality(key, q)
            flow[k] = (flow[k] or 0) + amount * f
          end
        else
          flow[key] = (flow[key] or 0) + x
        end
      end
      add_flow(flow, v.n)
    end
  else
    return nil
  end
  if n <= 0 then return nil end
  local flow = {}
  for key, v in pairs(sum) do
    local x = v / n
    if math.abs(x) >= 1e-12 then flow[key] = x end
  end
  return flow
end

--- Do two flows differ (relative tolerance per item)?
function scanner.flows_differ(a, b, tol)
  tol = tol or 1e-6
  for k, v in pairs(a) do
    local w = b[k] or 0
    if math.abs(v - w) > tol * math.max(math.abs(v), math.abs(w)) then return true end
  end
  for k, w in pairs(b) do
    if a[k] == nil and w ~= 0 then return true end
  end
  return false
end

--- Flow of one machine of a recipe line added by hand, from its configuration: machine,
--- modules, beacons and typed extras, with the force's research (runtime). nil when a
--- prototype is gone.
function scanner.config_flow(recipe_name, config, force)
  local recipe = recipe_name and prototypes.recipe[recipe_name]
  local machine = config.machine and prototypes.entity[config.machine]
  -- only a crafter has a crafting speed
  if not (recipe and machine and machine.crafting_categories) then return nil end
  local research = scanner.research_productivity_pct(force, recipe_name)
  local totals = modules.totals(machine, recipe, modules.dialog_config(config), research)
  return scanner.manual_recipe_flow(recipe, machine, totals.speed, totals.prod,
    { machine_quality = config.machine_quality, recipe_quality = config.recipe_quality, chance = totals.quality, force = force })
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

--- The force's research productivity for a recipe, in % (what a manually added line gets).
function scanner.research_productivity_pct(force, recipe_name)
  local r = force and force.recipes[recipe_name]
  return r and (r.productivity_bonus or 0) * 100 or 0
end

return scanner
