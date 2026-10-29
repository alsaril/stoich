-- Export / import of factories and plans as strings. The table conversions are
-- pure; encode() and decode() use helpers.* in game.

local fp_util = require("scripts.util")
local model = require("scripts.model")
local plan = require("scripts.plan")

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

local function key_list(set)
  return fp_util.sorted_keys(set or {})
end

local function serialize_line(line)
  return {
    id = line.id, kind = line.kind, recipe = line.recipe, machine = line.machine, resource = line.resource,
    label = line.label, count = line.count, flow = line.flow, fluid_keys = key_list(line.fluid_keys),
    overridden = line.overridden or false, idle = line.idle, key = line.key,
    speed_pct = line.speed_pct, prod_pct = line.prod_pct, manual = line.manual, assigned_from = line.assigned_from,
  }
end

function exchange.serialize_factory(f)
  local lines = {}
  for _, line in ipairs(f.lines) do lines[#lines + 1] = serialize_line(line) end
  local splits = {}
  for _, s in ipairs(f.splits or {}) do splits[#splits + 1] = { item = s.item, shares = pairs_of(s.shares) } end
  local sink_items
  if f.kind == "sink" then
    sink_items = {}
    for i, row in ipairs(f.sink_items or {}) do sink_items[i] = model.clean_sink_row(row) end
  end
  return {
    id = f.id, name = f.name, icon = f.icon, kind = f.kind, copies = f.copies,
    lines = lines, anchors = pairs_of(f.anchors), splits = splits, external = key_list(f.external),
    sink_items = sink_items, next_line_id = f.next_line_id, removed_keys = key_list(f.removed_keys),
  }
end

-- Reading a string: everything is checked and rebuilt, nothing is taken as it comes,
-- so a hand-edited or foreign string can't leave data the GUI would trip over later.

local LINE_KINDS = { recipe = true, mining = true, pump = true, custom = true }

local function str(v, max)
  if type(v) ~= "string" then return nil end
  return v:sub(1, max or 200)
end

local function num(v)
  local n = tonumber(v)
  if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
  return n
end

-- An item key: "item/…", "fluid/…" or "custom/…".
local function item_key(v)
  if type(v) ~= "string" then return nil end
  local t, n = v:match("^(%a+)/(.+)$")
  if (t == "item" or t == "fluid" or t == "custom") and #n <= 200 then return v end
  return nil
end

local function key_set(list)
  local out = {}
  for _, k in ipairs(type(list) == "table" and list or {}) do
    if item_key(k) then out[k] = true end
  end
  return out
end

local function flow_of(v)
  local out = {}
  for k, x in pairs(type(v) == "table" and v or {}) do
    local key, n = item_key(k), num(x)
    if key and n and n ~= 0 then out[key] = n end
  end
  return out
end

-- { [id] = number } from pairs, keeping only the given ids.
local function id_numbers(list, ids)
  local out = {}
  for _, pair in ipairs(type(list) == "table" and list or {}) do
    local id = type(pair) == "table" and num(pair[1])
    local v = type(pair) == "table" and num(pair[2])
    if id and v and ids[id] then out[id] = v end
  end
  return out
end

local function deserialize_line(l, id)
  return {
    id = id, kind = LINE_KINDS[l.kind] and l.kind or "custom",
    recipe = str(l.recipe), machine = str(l.machine), resource = str(l.resource), label = str(l.label),
    count = math.max(0, num(l.count) or 0), flow = flow_of(l.flow), fluid_keys = key_set(l.fluid_keys),
    overridden = l.overridden == true, idle = l.idle == true or nil, key = str(l.key),
    speed_pct = num(l.speed_pct), prod_pct = num(l.prod_pct), manual = l.manual == true or nil,
    assigned_from = str(l.assigned_from),
  }
end

function exchange.deserialize_factory(s)
  if type(s) ~= "table" then error("factory is not a table") end
  local f = model.new_factory(s.kind == "sink" and "sink" or "factory")
  f.name = str(s.name) or "Imported"
  local icon = s.icon
  if type(icon) == "table" and model.ICON_TABLES[icon.type or "item"] and str(icon.name) then
    f.icon = { type = icon.type or "item", name = str(icon.name) }
  end
  f.copies = math.max(0, num(s.copies) or 1)
  if f.kind == "sink" then
    -- a sink is its items: lines, anchors and splits of older strings are ignored
    f.sink_items = {}
    for _, row in ipairs(type(s.sink_items) == "table" and s.sink_items or {}) do
      local key = type(row) == "table" and item_key(row.key)
      if key then
        local fluid = row.fluid == true and key:sub(1, 7) == "custom/" or nil
        f.sink_items[#f.sink_items + 1] = { key = key, rate = math.abs(num(row.rate) or 0), fluid = fluid }
      end
    end
    return f
  end
  -- line ids must be unique positive integers: others get a new id after the highest
  local ids, pending, max_id = {}, {}, 0
  for _, l in ipairs(type(s.lines) == "table" and s.lines or {}) do
    if type(l) ~= "table" then error("line is not a table") end
    local id = num(l.id)
    if id and id >= 1 and id == math.floor(id) and not ids[id] then
      ids[id] = true
      if id > max_id then max_id = id end
      f.lines[#f.lines + 1] = deserialize_line(l, id)
    else
      pending[#pending + 1] = l
    end
  end
  for _, l in ipairs(pending) do
    max_id = max_id + 1
    ids[max_id] = true
    f.lines[#f.lines + 1] = deserialize_line(l, max_id)
  end
  f.next_line_id = math.max(math.floor(num(s.next_line_id) or 0), max_id + 1)
  f.anchors = id_numbers(s.anchors, ids)
  for _, sp in ipairs(type(s.splits) == "table" and s.splits or {}) do
    local item = type(sp) == "table" and item_key(sp.item)
    if item then f.splits[#f.splits + 1] = { item = item, shares = id_numbers(sp.shares, ids) } end
  end
  f.external = key_set(s.external)
  local removed = {}
  for _, k in ipairs(type(s.removed_keys) == "table" and s.removed_keys or {}) do
    if str(k) then removed[k] = true end
  end
  if next(removed) then f.removed_keys = removed end
  return f
end

--- Envelope for factories with the plan's splits between them (kept on import when
--- at least two of their factories come along).
function exchange.pack(factories)
  local out = { fp = exchange.FORMAT, kind = "plan", factories = {}, splits = {} }
  for _, f in ipairs(factories) do out.factories[#out.factories + 1] = exchange.serialize_factory(f) end
  for _, s in ipairs(model.plan().splits) do out.splits[#out.splits + 1] = { item = s.item, shares = pairs_of(s.shares) } end
  return out
end

--- Unpack an envelope into new factory tables (ids not assigned yet).
--- Malformed data never raises: it returns nil and an error key.
--- @return table? { factories = { {old_id, factory} }, splits } or nil, error
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
  local out = { factories = {}, splits = {} }
  for _, s in ipairs(data.factories) do
    out.factories[#out.factories + 1] = { old_id = num(type(s) == "table" and s.id), factory = exchange.deserialize_factory(s) }
  end
  for _, sp in ipairs(type(data.splits) == "table" and data.splits or {}) do
    local item = type(sp) == "table" and item_key(sp.item)
    if item then
      local shares = {}
      for _, pair in ipairs(type(sp.shares) == "table" and sp.shares or {}) do
        local id = type(pair) == "table" and num(pair[1])
        local v = type(pair) == "table" and num(pair[2])
        if id and v then shares[id] = v end
      end
      out.splits[#out.splits + 1] = { item = item, shares = shares }
    end
  end
  return out
end

--- Add unpacked factories to the plan with new ids. Plan splits are remapped.
--- All or nothing: every factory is checked and balanced before the first one is saved.
--- @return table[] new factories
function exchange.add_to_plan(unpacked, player_index)
  local p = model.plan()
  for _, entry in ipairs(unpacked.factories) do
    entry.factory.id = nil
    model.validate_factory(entry.factory)
    plan.balance_factory(entry.factory)
  end
  local remap, added = {}, {}
  for _, entry in ipairs(unpacked.factories) do
    local _, saved = model.save_factory(entry.factory, {}, player_index, true)
    if entry.old_id then remap[entry.old_id] = saved.id end
    added[#added + 1] = saved
  end
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
