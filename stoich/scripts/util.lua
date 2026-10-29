-- Small shared helpers: item keys, number formatting, table copies.
-- Pure Lua except the few functions marked "runtime".

local fp_util = {}

--- @param type string "item" | "fluid" | "custom"
--- @param name string
function fp_util.key(type, name)
  return type .. "/" .. name
end

--- Split an item key into type and name.
--- @return string type, string name
function fp_util.parse_key(key)
  local t, n = key:match("^([%w%-]+)/(.*)$")
  if not t then return "custom", key end
  return t, n
end

--- Item key for a choose-elem "signal" value or a {type, name} pair.
function fp_util.key_from_signal(signal)
  if not signal or not signal.name then return nil end
  local t = signal.type or "item"
  if t ~= "item" and t ~= "fluid" then t = "custom" end
  return fp_util.key(t, signal.name)
end

--- Signal ({type, name}) for a choose-elem button, or nil for custom keys.
function fp_util.signal_from_key(key)
  local t, n = fp_util.parse_key(key)
  if t == "item" or t == "fluid" then return { type = t, name = n } end
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

function fp_util.count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
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

--- Number with k/M suffix.
function fp_util.format_number(v)
  if v == nil then return "?" end
  local a = math.abs(v)
  if a >= 1e9 then return trim(string.format("%.2f", v / 1e9)) .. "G" end
  if a >= 1e6 then return trim(string.format("%.2f", v / 1e6)) .. "M" end
  if a >= 1e4 then return trim(string.format("%.1f", v / 1e3)) .. "k" end
  if a >= 100 then return trim(string.format("%.1f", v)) end
  if a < 0.005 then return "0" end
  return trim(string.format("%.2f", v))
end

--- Rate per second shown in a unit ("s", "min", "h").
function fp_util.format_rate(per_second, unit, with_suffix)
  local u = fp_util.UNITS[unit] or fp_util.UNITS.min
  local s = fp_util.format_number(per_second * u.factor)
  if with_suffix then s = s .. u.suffix end
  return s
end

--- Parse a typed number (accepts "," as decimal mark and k/M suffixes). nil when invalid.
function fp_util.parse_number(text)
  if type(text) ~= "string" then return nil end
  local s = text:gsub("%s", ""):gsub(",", ".")
  local mult = 1
  local last = s:sub(-1)
  if last == "k" or last == "K" then mult, s = 1e3, s:sub(1, -2)
  elseif last == "M" then mult, s = 1e6, s:sub(1, -2) end
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

--- Rich text icon for an item key (custom keys become their text).
function fp_util.rich(key)
  local t, n = fp_util.parse_key(key)
  if t == "item" or t == "fluid" then return "[" .. t .. "=" .. n .. "]" end
  return n
end

--- Localised name for an item key (runtime).
function fp_util.localised(key)
  local t, n = fp_util.parse_key(key)
  if t == "item" and prototypes.item[n] then return prototypes.item[n].localised_name end
  if t == "fluid" and prototypes.fluid[n] then return prototypes.fluid[n].localised_name end
  return n
end

--- Does the prototype behind an item key exist? Custom keys always do (runtime).
function fp_util.key_exists(key)
  local t, n = fp_util.parse_key(key)
  if t == "item" then return prototypes.item[n] ~= nil end
  if t == "fluid" then return prototypes.fluid[n] ~= nil end
  return true
end

return fp_util
