-- Export / import of factories and plans as strings. The table conversions are
-- pure; encode() and decode() use helpers.* in game.

local fp_util = require("scripts.util")
local model = require("scripts.model")

local exchange = {}

exchange.FORMAT = 1

-- Maps keyed by numeric ids don't survive JSON (keys become strings), so they
-- travel as arrays of pairs.
local function pairs_of(map)
  local out = {}
  for _, k in ipairs(fp_util.sorted_keys(map or {}, function(a, b)
    if type(a) ~= type(b) then return type(a) == "number" end
    return a < b
  end)) do
    out[#out + 1] = { k, map[k] }
  end
  return out
end

local function map_of(list, key_fn)
  local out = {}
  for _, pair in ipairs(type(list) == "table" and list or {}) do
    local k = pair[1]
    if key_fn then k = key_fn(k) end
    if k ~= nil then out[k] = pair[2] end
  end
  return out
end

local function key_list(set)
  return fp_util.sorted_keys(set or {})
end

local function key_set(list)
  local out = {}
  for _, k in ipairs(type(list) == "table" and list or {}) do
    if type(k) == "string" then out[k] = true end
  end
  return out
end

local function serialize_line(line)
  return {
    id = line.id, kind = line.kind, recipe = line.recipe, machine = line.machine, resource = line.resource,
    label = line.label, count = line.count, flow = line.flow, fluid_keys = key_list(line.fluid_keys),
    overridden = line.overridden or false, idle = line.idle, key = line.key, rows = line.rows,
    speed_pct = line.speed_pct, prod_pct = line.prod_pct, manual = line.manual, assigned_from = line.assigned_from,
  }
end

function exchange.serialize_factory(f)
  local lines = {}
  for _, line in ipairs(f.lines) do lines[#lines + 1] = serialize_line(line) end
  local splits = {}
  for _, s in ipairs(f.splits or {}) do splits[#splits + 1] = { item = s.item, shares = pairs_of(s.shares) } end
  return {
    id = f.id, name = f.name, icon = f.icon, kind = f.kind, copies = f.copies, pinned = f.pinned or false,
    lines = lines, anchors = pairs_of(f.anchors), splits = splits, external = key_list(f.external),
    sink_items = f.sink_items, next_line_id = f.next_line_id, removed_keys = key_list(f.removed_keys),
  }
end

local function to_number(k) return tonumber(k) end

function exchange.deserialize_factory(s)
  local f = model.new_factory(s.kind == "sink" and "sink" or "factory")
  f.name = tostring(s.name or "Imported")
  if type(s.icon) == "table" and s.icon.name then f.icon = { type = s.icon.type or "item", name = s.icon.name } end
  f.copies = tonumber(s.copies) or 1
  f.pinned = s.pinned and true or false
  local max_id = 0
  if type(s) ~= "table" then error("factory is not a table") end
  for _, l in ipairs(type(s.lines) == "table" and s.lines or {}) do
    if type(l) ~= "table" then error("line is not a table") end
    local line = {
      id = tonumber(l.id), kind = l.kind or "custom", recipe = l.recipe, machine = l.machine, resource = l.resource,
      label = l.label, count = tonumber(l.count) or 0, flow = {}, fluid_keys = key_set(l.fluid_keys),
      overridden = l.overridden and true or false, idle = l.idle or nil, key = l.key, rows = l.rows,
      speed_pct = l.speed_pct, prod_pct = l.prod_pct, manual = l.manual or nil, assigned_from = l.assigned_from,
    }
    for k, v in pairs(type(l.flow) == "table" and l.flow or {}) do
      if type(k) == "string" then line.flow[k] = tonumber(v) end
    end
    if not line.id then line.id = max_id + 1 end
    if line.id > max_id then max_id = line.id end
    f.lines[#f.lines + 1] = line
  end
  f.next_line_id = math.max(tonumber(s.next_line_id) or 0, max_id + 1)
  f.anchors = map_of(s.anchors, to_number)
  for _, sp in ipairs(s.splits or {}) do
    f.splits[#f.splits + 1] = { item = sp.item, shares = map_of(sp.shares, to_number) }
  end
  f.external = key_set(s.external)
  local removed = key_set(s.removed_keys)
  if next(removed) then f.removed_keys = removed end
  if f.kind == "sink" then
    f.sink_items = {}
    for _, row in ipairs(s.sink_items or {}) do
      f.sink_items[#f.sink_items + 1] = { key = row.key, rate = tonumber(row.rate) or 0, fluid = row.fluid }
    end
  end
  return f
end

--- Envelope for one or more factories, optionally with the plan's externals and splits.
function exchange.pack(factories, with_plan)
  local out = { fp = exchange.FORMAT, kind = with_plan and "plan" or "factories", factories = {} }
  for _, f in ipairs(factories) do out.factories[#out.factories + 1] = exchange.serialize_factory(f) end
  if with_plan then
    local p = model.plan()
    out.external = key_list(p.external)
    out.splits = {}
    for _, s in ipairs(p.splits) do out.splits[#out.splits + 1] = { item = s.item, shares = pairs_of(s.shares) } end
  end
  return out
end

--- Unpack an envelope into new factory tables (ids not assigned yet).
--- Malformed data never raises: it returns nil and an error key.
--- @return table? { factories = { {old_id, factory} }, external, splits } or nil, error
function exchange.unpack(data)
  if type(data) ~= "table" or tonumber(data.fp) == nil or type(data.factories) ~= "table" then
    return nil, "not-a-planner-string"
  end
  if tonumber(data.fp) > exchange.FORMAT then return nil, "newer-format" end
  local ok, result = pcall(exchange.unpack_unchecked, data)
  if not ok then return nil, "not-a-planner-string" end
  return result
end

function exchange.unpack_unchecked(data)
  local out = { factories = {}, external = key_set(data.external), splits = {} }
  for _, s in ipairs(data.factories) do
    out.factories[#out.factories + 1] = { old_id = tonumber(s.id), factory = exchange.deserialize_factory(s) }
  end
  for _, sp in ipairs(data.splits or {}) do
    out.splits[#out.splits + 1] = { item = sp.item, shares = map_of(sp.shares, to_number) }
  end
  return out
end

--- Add unpacked factories to the plan with new ids. Plan splits are remapped.
--- @param balance function(factory) balances a factory (plan.balance_factory)
--- @return table[] new factories
function exchange.add_to_plan(unpacked, player_index, balance, validate)
  local p = model.plan()
  local remap, added = {}, {}
  for _, entry in ipairs(unpacked.factories) do
    local f = entry.factory
    f.id = nil
    if validate then validate(f) end
    balance(f)
    local ok, saved = model.save_factory(f, {}, player_index, true)
    if ok then
      if entry.old_id then remap[entry.old_id] = saved.id end
      added[#added + 1] = saved
    end
  end
  for k in pairs(unpacked.external or {}) do p.external[k] = true end
  for _, sp in ipairs(unpacked.splits or {}) do
    local shares, n = {}, 0
    for old, pct in pairs(sp.shares) do
      if remap[old] then
        shares[remap[old]] = pct
        n = n + 1
      end
    end
    if n >= 2 then p.splits[#p.splits + 1] = { item = sp.item, shares = shares } end
  end
  return added
end

-- Strings (runtime) ---------------------------------------------------------------------

function exchange.encode(data)
  return helpers.encode_string(helpers.table_to_json(data))
end

function exchange.decode(text)
  if type(text) ~= "string" then return nil end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  local json = helpers.decode_string(text)
  if not json then return nil end
  return helpers.json_to_table(json)
end

return exchange
