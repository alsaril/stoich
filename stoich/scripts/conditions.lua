-- Quality conditions of void and import rows ("any", ">=rare", as the game's filters) and
-- whether a factory has quality. Pure (item keys only).

local fp_util = require("scripts.util")

local conditions = {}

-- Quality conditions, as the game's filters: "any", or a comparator and a tier (">=rare").
conditions.QUALITY_OPS = { "any", "=", ">=", ">", "<=", "<" }

--- A condition's comparator and tier; nil for one that isn't valid.
--- @return string? op, string? tier
function conditions.parse_condition(cond)
  if cond == "any" then return "any", nil end
  if type(cond) ~= "string" then return nil end
  -- the comparator, then a tier name (">=" alone is no condition)
  for _, op in ipairs({ ">=", "<=", "=", ">", "<" }) do
    if cond:sub(1, #op) == op then
      local tier = cond:sub(#op + 1)
      if tier:match("^[%w%-_]+$") then return op, tier end
      return nil
    end
  end
  return nil
end

--- Does an item key match a row's item (its base key) and quality condition?
function conditions.matches_condition(key, base, cond)
  if fp_util.base_key(key) ~= base then return false end
  local op, tier = conditions.parse_condition(cond)
  if op == "any" then return true end
  if not op then return false end
  local q = fp_util.quality_of(key)
  if q == tier then return op == "=" or op == ">=" or op == "<=" end
  if op == "=" then return false end
  local higher = fp_util.quality_less(tier, q)
  if op == ">=" or op == ">" then return higher end
  return not higher
end

--- The items of a void or import, sorted, each once. A row with a quality condition stands
--- for the matching tiers of its item that the plan's factories make or use (`present`).
--- @param present table<string, boolean>? the plan's item keys (nil: rows with a condition give nothing)
function conditions.boundary_items(f, present)
  local set = {}
  for _, row in ipairs(f.sink_items or {}) do
    if row.key and row.quality then
      for key in pairs(present or {}) do
        if conditions.matches_condition(key, fp_util.base_key(row.key), row.quality) then set[key] = true end
      end
    elseif row.key then
      set[row.key] = true
    end
  end
  return fp_util.sorted_keys(set, fp_util.key_less)
end

--- Did a void's or import's item come from a row with a quality condition (not named itself)?
function conditions.row_condition(f, item)
  for _, row in ipairs(f.sink_items or {}) do
    if row.key == item and not row.quality then return false end
  end
  return true
end

local function tiered(key)
  return fp_util.quality_of(key) ~= fp_util.NORMAL
end

--- Does a factory have quality: an item of a tier above normal, a recipe or machine of one,
--- or a line with a quality chance?
function conditions.factory_has_quality(f)
  for _, line in ipairs(f.lines or {}) do
    if line.recipe_quality or line.machine_quality then return true end
    for key in pairs(line.flow or {}) do
      if tiered(key) then return true end
    end
    for _, v in ipairs(line.variants or {}) do
      if (v.quality_chance or 0) > 0 then return true end
    end
  end
  for _, row in ipairs(f.sink_items or {}) do
    if row.key and tiered(row.key) or row.quality then return true end
  end
  return false
end

--- Void or import rows that stand for exactly these tiers of one item: the key itself for
--- one, else a quality condition over the tiers the plan has of it ("any", ">=rare",
--- "<=epic"), else a row per tier.
--- @param keys string[] keys of one base item
--- @param present table<string, boolean> the plan's keys (plan.present_keys)
--- @return table[] rows { key, quality? }
function conditions.condition_rows(keys, present)
  if #keys == 1 then return { { key = keys[1] } } end
  local base = fp_util.base_key(keys[1])
  local wanted, all = {}, {}
  for _, k in ipairs(keys) do wanted[k] = true end
  for k in pairs(present) do
    if fp_util.base_key(k) == base then all[#all + 1] = k end
  end
  for _, k in ipairs(keys) do
    if not present[k] then all[#all + 1] = k end
  end
  table.sort(all, fp_util.key_less)
  local sorted = fp_util.sorted_keys(wanted, fp_util.key_less)
  local low, high = fp_util.quality_of(sorted[1]), fp_util.quality_of(sorted[#sorted])
  -- "any" only when it means from normal up (it would also take a tier the plan gets later)
  local conds = { ">=" .. low, "<=" .. high }
  if low == fp_util.NORMAL then conds[1] = "any" end
  for _, cond in ipairs(conds) do
    local same = true
    for _, k in ipairs(all) do
      if conditions.matches_condition(k, base, cond) ~= (wanted[k] == true) then same = false break end
    end
    if same then return { { key = base, quality = cond } } end
  end
  local rows = {}
  for _, k in ipairs(sorted) do rows[#rows + 1] = { key = k } end
  return rows
end

return conditions
