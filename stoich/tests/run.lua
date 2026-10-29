-- Offline test runner. From the mod folder: lua tests/run.lua [filter]
-- Written for plain Lua 5.2 (Factorio's dialect); also runs on newer versions.

local root = arg and arg[0] and arg[0]:match("^(.*)[/\\]tests[/\\]run%.lua$") or "."
package.path = root .. "/?.lua;" .. package.path
TEST_ROOT = root

local t = { cases = {}, failures = 0, passed = 0 }

function t.test(name, fn)
  t.cases[#t.cases + 1] = { name = name, fn = fn }
end

local function fmt(v)
  if type(v) == "table" then
    local parts = {}
    for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. fmt(x) end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(v)
end
t.fmt = fmt

function t.eq(actual, expected, msg)
  if actual ~= expected then
    error((msg and msg .. ": " or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
  end
end

function t.near(actual, expected, tol, msg)
  tol = tol or 1e-6
  if type(actual) ~= "number" or math.abs(actual - expected) > tol then
    error((msg and msg .. ": " or "") .. "expected " .. tostring(expected) .. " ±" .. tol .. ", got " .. tostring(actual), 2)
  end
end

function t.truthy(v, msg)
  if not v then error(msg or "expected a truthy value", 2) end
end

function t.contains(list, value, msg)
  for _, v in ipairs(list) do
    if v == value then return end
  end
  error((msg and msg .. ": " or "") .. fmt(list) .. " does not contain " .. fmt(value), 2)
end

--- Compare a map of numbers, ignoring keys whose expected and actual are both ~0.
function t.map_near(actual, expected, tol, msg)
  tol = tol or 1e-6
  for k, v in pairs(expected) do
    t.near(actual[k] or 0, v, tol, (msg or "map") .. "[" .. tostring(k) .. "]")
  end
  for k, v in pairs(actual) do
    if expected[k] == nil and math.abs(v) > tol then
      error((msg or "map") .. ": unexpected key " .. tostring(k) .. "=" .. tostring(v), 2)
    end
  end
end

package.loaded["tests.t"] = t

local files = { "linalg_test", "solver_test", "belts_test", "scanner_test", "plan_test", "exchange_test", "format_test",
  "locale_test", "gui_test" }
local filter = arg and arg[1]

for _, f in ipairs(files) do
  -- a missing file is an error too: a renamed test must not vanish quietly
  local ok, e = pcall(require, "tests." .. f)
  if not ok then
    print("LOAD ERROR " .. f .. ": " .. tostring(e))
    t.failures = t.failures + 1
  end
end

for _, case in ipairs(t.cases) do
  if not filter or case.name:find(filter, 1, true) then
    local ok, e = xpcall(case.fn, debug.traceback)
    if ok then
      t.passed = t.passed + 1
      print("ok    " .. case.name)
    else
      t.failures = t.failures + 1
      print("FAIL  " .. case.name .. "\n      " .. tostring(e):gsub("\n", "\n      "))
    end
  end
end

print(("\n%d passed, %d failed"):format(t.passed, t.failures))
os.exit(t.failures == 0 and 0 or 1)
