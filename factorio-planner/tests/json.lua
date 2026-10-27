-- Minimal JSON decoder for the offline tests (in game, helpers.json_to_table is used).

local json = {}

local function err(s, i, msg)
  error(("json: %s at %d near %q"):format(msg, i, s:sub(i, i + 10)), 0)
end

local function skip(s, i)
  local _, e = s:find("^[ \t\r\n]*", i)
  return e + 1
end

local decode_value

local escapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function decode_string(s, i)
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == "" then err(s, i, "unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      if e == "u" then
        local code = tonumber(s:sub(j + 2, j + 5), 16)
        if code < 0x80 then
          out[#out + 1] = string.char(code)
        elseif code < 0x800 then
          out[#out + 1] = string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
        else
          out[#out + 1] = string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
        end
        j = j + 6
      else
        out[#out + 1] = escapes[e] or err(s, j, "bad escape")
        j = j + 2
      end
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
end

decode_value = function(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local obj = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      local key
      key, i = decode_string(s, skip(s, i))
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then err(s, i, "expected ':'") end
      obj[key], i = decode_value(s, i + 1)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "}" then return obj, i + 1 end
      if d ~= "," then err(s, i, "expected ','") end
      i = i + 1
    end
  elseif c == "[" then
    local arr = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      arr[#arr + 1], i = decode_value(s, i)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == "]" then return arr, i + 1 end
      if d ~= "," then err(s, i, "expected ','") end
      i = i + 1
    end
  elseif c == '"' then
    return decode_string(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if not num or num == "" then err(s, i, "unexpected character") end
    return tonumber(num), i + #num
  end
end

function json.decode(s)
  local v, i = decode_value(s, 1)
  i = skip(s, i)
  if i <= #s then err(s, i, "trailing data") end
  return v
end

local function is_array(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' end
    if c == "\\" then return "\\\\" end
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

--- Encode like helpers.table_to_json: sequences become arrays, other keys strings.
function json.encode(v)
  local t = type(v)
  if t == "nil" then return "null" end
  if t == "boolean" then return tostring(v) end
  if t == "number" then return string.format("%.17g", v) end
  if t == "string" then return encode_string(v) end
  if t == "table" then
    if next(v) == nil then return "[]" end
    local parts = {}
    if is_array(v) then
      for _, x in ipairs(v) do parts[#parts + 1] = json.encode(x) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local by_string = {}
    for k, x in pairs(v) do by_string[tostring(k)] = x end
    for _, k in ipairs(keys) do parts[#parts + 1] = encode_string(k) .. ":" .. json.encode(by_string[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("json: cannot encode " .. t)
end

function json.read_file(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return json.decode(s)
end

return json
