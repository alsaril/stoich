-- Interface text: every key the code names exists in locale/en/locale.cfg, and every
-- [stoich] key there is used (directly, or through one of the dynamic prefixes below).

local t = require("tests.t")

local function read(path)
  local f = assert(io.open(TEST_ROOT .. "/" .. path))
  local s = f:read("*a")
  f:close()
  return s
end

local function sources()
  local out = { "control.lua" }
  local p = assert(io.popen('cd "' .. TEST_ROOT .. '" && find scripts -name "*.lua" | sort'))
  for line in p:lines() do out[#out + 1] = line end
  p:close()
  return out
end

local function locale_keys()
  local keys, section = {}, nil
  for line in read("locale/en/locale.cfg"):gmatch("[^\n]+") do
    local s = line:match("^%[(.-)%]$")
    if s then section = s
    elseif section == "stoich" then
      local k = line:match("^([%w%-_]+)=")
      if k then keys[k] = true end
    end
  end
  return keys
end

-- Keys built at runtime: a prefix and a value ("status-" .. status), or a key and a suffix.
local DYNAMIC_PREFIXES = { "status-", "edit-", "virtual-", "import-error-", "empty-step-" }
-- "stoich.log-" .. action in model.save_factory
local DYNAMIC_KEYS = { ["log-created"] = true, ["log-edited"] = true }

t.test("locale: every key the code names exists, every key is used", function()
  local keys = locale_keys()
  local code = {}
  for _, path in ipairs(sources()) do code[#code + 1] = read(path) end
  code = table.concat(code, "\n")
  -- named: L("key") and "stoich.key"
  local missing = {}
  local function check(k)
    -- "status-" .. x: a prefix, checked through DYNAMIC_PREFIXES below
    if not keys[k] and k:sub(-1) ~= "-" then missing[#missing + 1] = k end
  end
  for k in code:gmatch('L%("([%w%-_]+)"') do check(k) end
  for k in code:gmatch('"stoich%.([%w%-_]+)"') do check(k) end
  table.sort(missing)
  t.eq(table.concat(missing, ", "), "", "keys missing from locale.cfg")
  -- used: any string literal equal to the key (L("x"), { "col-x", 80 }, caption = "items-x"...),
  -- a dynamic prefix, or a "<used key>-tooltip" built from a column / group key
  local literals = {}
  for s in code:gmatch('"([%w%-_%.]+)"') do literals[s:gsub("^stoich%.", "")] = true end
  local unused = {}
  for k in pairs(keys) do
    local used = literals[k] or DYNAMIC_KEYS[k]
    for _, prefix in ipairs(DYNAMIC_PREFIXES) do
      if k:sub(1, #prefix) == prefix then used = true end
    end
    local base = k:match("^(.*)%-tooltip$")
    if base and literals[base] then used = true end
    if not used then unused[#unused + 1] = k end
  end
  table.sort(unused)
  t.eq(table.concat(unused, ", "), "", "locale keys nothing uses")
end)
