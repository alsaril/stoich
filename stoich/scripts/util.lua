-- Small shared helpers: item keys, number formatting, table copies.
-- Pure Lua except the few functions marked "runtime".

local fp_util = {}

-- Quality: an item of a tier above normal is its own key, the tier after this separator
-- ("item/iron-plate|rare"). Normal items keep the plain key; fluids never carry quality.
fp_util.QUALITY_SEP = "|"
local SEP = fp_util.QUALITY_SEP
local SEP_PATTERN = "^(.*)" .. SEP:gsub("%p", "%%%0") .. "([^" .. SEP:gsub("%p", "%%%0") .. "]+)$"
local NORMAL = "normal"
fp_util.NORMAL = NORMAL

--- @param type string "item" | "fluid" | "custom"
--- @param name string
--- @param quality string? quality name (nil or "normal": none)
function fp_util.key(type, name, quality)
  if quality and quality ~= NORMAL and type == "item" then return type .. "/" .. name .. SEP .. quality end
  return type .. "/" .. name
end

--- Split an item key into type, name and quality ("normal" when it has none).
--- @return string type, string name, string quality
function fp_util.parse_key(key)
  local t, n = key:match("^([%w%-]+)/(.*)$")
  if not t then return "custom", key, NORMAL end
  if t == "item" then
    local base, q = n:match(SEP_PATTERN)
    if base and base ~= "" then return t, base, q end
  end
  return t, n, NORMAL
end

--- The key without its tier ("item/iron-plate|rare" -> "item/iron-plate").
function fp_util.base_key(key)
  local t, n = fp_util.parse_key(key)
  return fp_util.key(t, n)
end

--- The key of the same item at another tier.
function fp_util.with_quality(key, quality)
  local t, n = fp_util.parse_key(key)
  return fp_util.key(t, n, quality)
end

--- The tier of a key ("normal" when it has none).
function fp_util.quality_of(key)
  return (select(3, fp_util.parse_key(key)))
end

-- Vanilla levels, for the offline tests and tiers the game doesn't know (any order works
-- for those: after the known ones, by name).
local DEFAULT_LEVELS = { normal = 0, uncommon = 1, rare = 2, epic = 3, legendary = 5 }

--- Level of a quality (runtime prototypes when there are any).
function fp_util.quality_level(name)
  local q = prototypes and prototypes.quality[name]
  if q then return q.level end
  return DEFAULT_LEVELS[name]
end

--- Qualities that can be shown, by level: the visible tiers (normal always first) (runtime).
--- @return string[]
function fp_util.quality_levels()
  local out = {}
  for name, q in pairs(prototypes.quality) do
    if name == NORMAL or not q.hidden then out[#out + 1] = name end
  end
  table.sort(out, function(a, b)
    local la, lb = fp_util.quality_level(a) or 0, fp_util.quality_level(b) or 0
    if la ~= lb then return la < lb end
    return a < b
  end)
  return out
end

--- Order of tiers: by level, never by name; unknown ones last, by name.
function fp_util.quality_less(a, b)
  if a == b then return false end
  local la, lb = fp_util.quality_level(a), fp_util.quality_level(b)
  if la and lb and la ~= lb then return la < lb end
  if (la == nil) ~= (lb == nil) then return la ~= nil end
  return a < b
end

--- Order of item keys for display: by base key, then by tier level.
function fp_util.key_less(a, b)
  local ta, na, qa = fp_util.parse_key(a)
  local tb, nb, qb = fp_util.parse_key(b)
  if ta ~= tb or na ~= nb then return fp_util.key(ta, na) < fp_util.key(tb, nb) end
  return fp_util.quality_less(qa, qb)
end

--- Item key for a choose-elem "signal" value, a {type, name, quality?} pair or an
--- item-with-quality value ({name, quality}).
function fp_util.key_from_signal(signal)
  if not signal or not signal.name then return nil end
  local t = signal.type or "item"
  if t ~= "item" and t ~= "fluid" then t = "custom" end
  local q = signal.quality
  if type(q) == "table" then q = q.name end
  return fp_util.key(t, signal.name, q)
end

--- Signal ({type, name, quality?}) for a choose-elem button, or nil for custom keys.
function fp_util.signal_from_key(key)
  local t, n, q = fp_util.parse_key(key)
  if t == "item" or t == "fluid" then return { type = t, name = n, quality = q ~= NORMAL and q or nil } end
  return nil
end

function fp_util.deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = fp_util.deep_copy(x) end
  return out
end

function fp_util.sorted_keys(t, less)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, less)
  return keys
end

--- Turn an internal name into a readable default: "electronic-circuit" -> "Electronic circuit".
function fp_util.pretty_name(name)
  local s = (name or ""):gsub("^kr%-", ""):gsub("[-_]", " ")
  return (s:gsub("^%l", string.upper))
end

-- Units for display. Storage is always per second.
fp_util.UNITS = {
  s = { factor = 1, suffix = "/s" },
  min = { factor = 60, suffix = "/min" },
  h = { factor = 3600, suffix = "/h" },
}
fp_util.UNIT_ORDER = { "s", "min", "h" }

local function trim(s)
  if s:find("%.") then s = s:gsub("0+$", ""):gsub("%.$", "") end
  if s == "-0" then s = "0" end
  return s
end

--- Number with 2 decimals (or `decimals`), trailing zeros trimmed.
function fp_util.format_count(v, decimals)
  if v == nil then return "?" end
  if math.abs(v) < 0.005 then return "0" end
  return trim(string.format("%." .. (decimals or 2) .. "f", v))
end

-- Small numbers (a legendary byproduct's rate): milli, micro, nano below 0.01.
fp_util.SMALL = { { 1e-3, "m" }, { 1e-6, "µ" }, { 1e-9, "n" } }

--- Number with k/M suffix; below 0.01 with m, µ or n (zero stays "0").
function fp_util.format_number(v)
  if v == nil then return "?" end
  local a = math.abs(v)
  if a >= 1e9 then return trim(string.format("%.2f", v / 1e9)) .. "G" end
  if a >= 1e6 then return trim(string.format("%.2f", v / 1e6)) .. "M" end
  if a >= 1e4 then return trim(string.format("%.1f", v / 1e3)) .. "k" end
  if a >= 100 then return trim(string.format("%.1f", v)) end
  if a >= 0.00995 then return trim(string.format("%.2f", v)) end
  for i, s in ipairs(fp_util.SMALL) do
    -- 3 significant digits at most ("4.5m", "123µ"); n takes what is left, down to 0.005n
    local floor = i == #fp_util.SMALL and s[1] * 0.005 or s[1] * 0.9995
    if a >= floor then
      local x = v / s[1]
      local digits = math.abs(x) >= 99.95 and 0 or (math.abs(x) >= 9.995 and 1 or 2)
      return trim(string.format("%." .. digits .. "f", x)) .. s[2]
    end
  end
  return "0"
end

--- Rate per second shown in a unit ("s", "min", "h").
function fp_util.format_rate(per_second, unit, with_suffix)
  local u = fp_util.UNITS[unit] or fp_util.UNITS.min
  local s = fp_util.format_number(per_second * u.factor)
  if with_suffix then s = s .. u.suffix end
  return s
end

--- Parse a typed number (accepts "," as decimal mark, k/M and m/µ (or u)/n suffixes). nil when invalid.
function fp_util.parse_number(text)
  if type(text) ~= "string" then return nil end
  local s = text:gsub("%s", ""):gsub(",", ".")
  local mult = 1
  local last = s:sub(-1)
  if last == "k" or last == "K" then mult, s = 1e3, s:sub(1, -2)
  elseif last == "M" then mult, s = 1e6, s:sub(1, -2)
  elseif last == "m" then mult, s = 1e-3, s:sub(1, -2)
  elseif last == "u" then mult, s = 1e-6, s:sub(1, -2)
  elseif last == "n" then mult, s = 1e-9, s:sub(1, -2)
  elseif s:sub(-2) == "µ" then mult, s = 1e-6, s:sub(1, -3) end
  if not s:match("^[-+]?%d*%.?%d+$") and not s:match("^[-+]?%d+%.?$") then return nil end
  local v = tonumber(s)
  if not v then return nil end
  return v * mult
end

--- Sprite path for an item key; custom keys get a generic signal sprite.
function fp_util.sprite(key)
  local t, n = fp_util.parse_key(key)
  if t == "item" or t == "fluid" then return t .. "/" .. n end
  return "utility/custom_tag_icon"
end

--- Rich text icon for an item key, with its tier (custom keys become their text).
function fp_util.rich(key)
  local t, n, q = fp_util.parse_key(key)
  if t == "item" and q ~= NORMAL then return "[item=" .. n .. ",quality=" .. q .. "]" end
  if t == "item" or t == "fluid" then return "[" .. t .. "=" .. n .. "]" end
  return n
end

--- Localised name of a quality (runtime).
function fp_util.quality_name(quality)
  local q = prototypes.quality[quality]
  return q and q.localised_name or quality
end

--- Localised name for an item key: "Iron plate (rare)" for a tier above normal (runtime).
function fp_util.localised(key)
  local t, n, q = fp_util.parse_key(key)
  local name = n
  if t == "item" and prototypes.item[n] then name = prototypes.item[n].localised_name end
  if t == "fluid" and prototypes.fluid[n] then name = prototypes.fluid[n].localised_name end
  if q ~= NORMAL then return { "", name, " (", fp_util.quality_name(q), ")" } end
  return name
end

--- Does the prototype behind an item key exist (its quality too)? Custom keys always do (runtime).
function fp_util.key_exists(key)
  local t, n, q = fp_util.parse_key(key)
  if q ~= NORMAL and not prototypes.quality[q] then return false end
  if t == "item" then return prototypes.item[n] ~= nil end
  if t == "fluid" then return prototypes.fluid[n] ~= nil end
  return true
end

return fp_util
