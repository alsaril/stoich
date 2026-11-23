-- The problems list under a balance: split prompts, conflicting items with
-- one-click Mark external / Add sink, anchors, negative counts.

local common = require("scripts.gui.common")
local scopes = require("scripts.gui.scopes")
local solver = require("scripts.solver")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local problems = {}

-- A problem row's sentence wraps rather than squeeze what follows it (the alternatives'
-- "or instead:", the buttons), which would wrap mid-word.
local TEXT_WIDTH = 460
local MAX_ALTERNATIVES = 6

local function sentence(row, caption, tooltip)
  local label = row.add({ type = "label", caption = caption, tooltip = tooltip })
  label.style.single_line = false
  label.style.maximal_width = TEXT_WIDTH
  return label
end

--- A button as wide as its caption.
local function row_button(row, def)
  local b = row.add(def)
  b.style.minimal_width = 0
  return b
end



--- The icon of an item (or of several tiers of one: the "any quality" mark).
local function item_button(parent, mode, key, keys)
  keys = keys or { key }
  local b = common.item_icon(parent, {
    type = "sprite-button", style = "transparent_slot",
    tooltip = common.keys_name(keys), tags = { fp = "problem_item", mode = mode, item = key },
  }, keys)
  b.style.size = 24
  return b
end

--- The four cells of an item's problem in the problems table: icon | problem | actions |
--- alternatives, so the buttons and the alternatives line up across rows.
--- @return LuaGuiElement icon, LuaGuiElement actions, LuaGuiElement alternatives (flows)
local function item_cells(t, mode, keys, text, tooltip)
  local icon = t.add({ type = "flow", direction = "horizontal" })
  icon.style.vertical_align = "center"
  icon.style.horizontal_spacing = 4
  icon.add({ type = "sprite", sprite = "utility/status_not_working" })
  item_button(icon, mode, keys[1], keys)
  sentence(t, text, tooltip)
  local actions = t.add({ type = "flow", direction = "horizontal" })
  actions.style.horizontal_spacing = 4
  local alternatives = t.add({ type = "flow", direction = "horizontal" })
  alternatives.style.vertical_align = "center"
  alternatives.style.horizontal_spacing = 2
  return icon, actions, alternatives
end

local function name_list(player, mode, ids)
  local names = scopes[mode].names(player)
  local out = { "" }
  for i, id in ipairs(ids) do
    if i > 6 then
      out[#out + 1] = ", …"
      break
    end
    if i > 1 then out[#out + 1] = ", " end
    out[#out + 1] = names[id] or tostring(id)
  end
  return out
end

--- Conflicting items across all conflict problems, once each, in order; the tiers of one
--- item with the same reason are one entry ("Gear (rare, epic, legendary)").
local function conflict_items(result)
  local out, seen, by_group = {}, {}, {}
  local split_involved = false
  for _, p in ipairs(result.problems) do
    if p.type == "conflict" then
      for _, key in ipairs(p.items) do
        if not seen[key] then
          seen[key] = true
          local reason = p.reasons[key]
          local group = fp_util.base_key(key) .. "\0" .. (reason or "")
          local entry = by_group[group]
          if entry then
            table.insert(entry.keys, key)
            table.sort(entry.keys, fp_util.key_less)
            entry.key = entry.keys[1]
          else
            entry = { key = key, keys = { key }, reason = reason }
            by_group[group] = entry
            out[#out + 1] = entry
          end
        end
      end
      if #p.splits > 0 then split_involved = true end
    end
  end
  return out, split_involved
end

-- A plan that can't balance lists what would close it (plan_lp.diagnose) instead of every
-- item of the contradiction; the plain conflict rows stay when that isn't all of it.
local function fixes_of(mode, result)
  if not (mode == "plan" and result.fixes and #result.fixes > 0) then return nil, false end
  -- what has to come in first (an item, or some of its qualities, missing), then the rest;
  -- each in the search's order
  local imports, rest = {}, {}
  for _, fix in ipairs(result.fixes) do
    local short = fix.rate ~= nil and fix.rate < 0
    for _, v in pairs(fix.rates or {}) do
      if v < 0 then short = true end
    end
    table.insert(short and imports or rest, fix)
  end
  for _, fix in ipairs(rest) do imports[#imports + 1] = fix end
  return imports, result.fixes_close
end

--- Number of problem rows shown (conflicts count once per item).
function problems.count(result, mode)
  local fixes, closed = fixes_of(mode, result)
  local n = closed and 0 or #conflict_items(result)
  if fixes then n = n + #fixes end
  for _, p in ipairs(result.problems) do
    if p.type ~= "conflict" then n = n + 1 end
  end
  if mode == "plan" and result.splits_in_way then n = n + #result.splits_in_way end
  if mode == "plan" and result.too_complicated then n = n + 1 end
  return n
end

--- A split of the player's that keeps the plan from closing without imports, as a row.
local function split_in_way_row(list, mode, ctx, item)
  local row = list.add({ type = "flow", direction = "horizontal" })
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 6
  row.add({ type = "sprite", sprite = "utility/status_not_working" })
  sentence(row, L("split-in-way", fp_util.rich(item), fp_util.localised(item)))
  row.add({ type = "button", caption = L("remove-split"), tooltip = L("remove-split-tooltip"), enabled = ctx.can_edit,
    tags = { fp = "problem_remove_split", mode = mode, item = item } })
end

--- Names of the lines (factory) or factories (plan) that make (sign > 0) or use (sign < 0) an item.
local function who(player, mode, key, sign, keys)
  local target = scopes[mode]
  local ids = {}
  for _, unit in ipairs(target.units(player)) do
    local hit = false
    for _, k in ipairs(keys or { key }) do
      if (unit.flow[k] or 0) * sign > 0 then hit = true end
    end
    if hit then ids[#ids + 1] = unit.id end
  end
  table.sort(ids, solver.id_less)
  return name_list(player, mode, ids)
end

local function conflict_row(t, player, mode, ctx, entry)
  local key, reason, keys = entry.key, entry.reason, entry.keys
  local many = #keys > 1
  local name = common.keys_name(keys)
  local text
  if mode == "plan" then
    if reason == "no_producer" then
      text = L("plan-no-producer", "", name, who(player, mode, key, -1, keys))
    elseif reason == "no_consumer" then
      text = L("plan-no-consumer", "", name, who(player, mode, key, 1, keys))
    else
      text = L("conflict-item", "", name)
    end
  else
    if reason == "no_producer" then
      text = L("conflict-no-producer", "", name)
    elseif reason == "no_consumer" then
      text = L("conflict-no-consumer", "", name)
    else
      text = L("conflict-item", "", name)
    end
  end
  local _, actions = item_cells(t, mode, keys, text)
  local function button(caption, tooltip, action, kind)
    row_button(actions, { type = "button", caption = L(caption), tooltip = tooltip and L(tooltip) or nil, enabled = ctx.can_edit,
      tags = { fp = action, mode = mode, item = key, keys = keys, kind = kind } })
  end
  if mode == "plan" then
    -- the plan is closed but for its voids and imports: a surplus goes to a void or a
    -- sink, a missing item comes from an import; several tiers go in one row
    if reason == "no_consumer" then
      button(many and "void-all" or "void-it", many and "void-all-tooltip" or "void-it-tooltip", "problem_boundary", "void")
      if not many then button("add-sink", "add-sink-tooltip-plan", "problem_sink") end
    elseif reason == "no_producer" then
      button(many and "import-all" or "import-it", many and "import-all-tooltip" or "import-it-tooltip", "problem_boundary", "import")
    end
  else
    if reason == "no_producer" then
      button("mark-input", "mark-input-tooltip", "problem_external")
    elseif reason == "no_consumer" then
      button("mark-output", "mark-output-tooltip", "problem_external")
      if not many then button("add-void", "add-sink-tooltip-factory", "problem_sink") end
    else
      button("mark-external", nil, "problem_external")
    end
  end
end

-- A fix of a plan that can't balance: how much of an item is left over or missing, the
-- items that would do instead, and the one-click void, sink or import.
local function fix_row(t, player, mode, ctx, fix)
  local key = fix.item
  local keys = fix.keys or { key }
  local many = #keys > 1
  local name = common.keys_name(keys)
  local rate = fix.rate and fp_util.format_rate(math.abs(fix.rate), ctx.unit, true)
  -- tiers of one item can go both ways (normal missing, rare left over): each way its button
  local surplus, short = {}, {}
  for _, k in ipairs(keys) do
    local v = fix.rates and fix.rates[k]
    if v and v < 0 then short[#short + 1] = k elseif v then surplus[#surplus + 1] = k end
  end
  local mixed = #surplus > 0 and #short > 0
  local text
  if mixed then
    text = L("fix-mixed", "", name)
  elseif fix.rate == nil then
    text = L("fix-unknown", "", name)
  elseif fix.rate >= 0 then
    text = L("fix-surplus", "", name, rate)
  else
    text = L("fix-short", "", name, rate)
  end
  local tip = L("fix-who", who(player, mode, key, 1, keys), who(player, mode, key, -1, keys))
  if many then
    -- each tier with its rate
    local tiers = { "" }
    for i, k in ipairs(keys) do
      if i <= 8 and fix.rates and fix.rates[k] then
        tiers[#tiers + 1] = { "", "\n", fp_util.rich(k), " ", fp_util.format_rate(fix.rates[k], ctx.unit, true) }
      end
    end
    tip = { "", tip, tiers }
  end
  local _, actions, row = item_cells(t, mode, keys, text, tip)
  if #fix.alternatives > 0 then
    local orl = row.add({ type = "label", caption = L("fix-or"), style = "info_label", tooltip = L("fix-or-tooltip") })
    orl.style.single_line = true
    orl.style.minimal_width = 64 -- single-line labels shrink to "…" otherwise
    for i, other in ipairs(fix.alternatives) do
      if i > MAX_ALTERNATIVES then
        local more = row.add({ type = "label", caption = "+" .. (#fix.alternatives - MAX_ALTERNATIVES), style = "info_label",
          tooltip = L("fix-or-tooltip") })
        more.style.single_line = true
        more.style.minimal_width = 24
        break
      end
      item_button(row, mode, other)
    end
  end
  local function button(caption, tooltip, action, kind, these)
    row_button(actions, { type = "button", caption = L(caption), tooltip = L(tooltip), enabled = ctx.can_edit,
      tags = { fp = action, mode = mode, item = these[1], keys = these, kind = kind } })
  end
  if mixed then
    button(#surplus > 1 and "void-all" or "void-it", #surplus > 1 and "void-all-tooltip" or "void-it-tooltip", "problem_boundary", "void", surplus)
    button(#short > 1 and "import-all" or "import-it", #short > 1 and "import-all-tooltip" or "import-it-tooltip", "problem_boundary", "import", short)
    return
  end
  if fix.rate == nil or fix.rate >= 0 then
    button(many and "void-all" or "void-it", many and "void-all-tooltip" or "void-it-tooltip", "problem_boundary", "void", keys)
    if fix.rate and not many then button("add-sink", "add-sink-tooltip-plan", "problem_sink", nil, keys) end
  end
  if fix.rate == nil or fix.rate < 0 then
    button(many and "import-all" or "import-it", many and "import-all-tooltip" or "import-it-tooltip", "problem_boundary", "import", keys)
  end
end

-- One problem that isn't a conflict, as a row.
local function other_row(list, player, mode, ctx, p)
  local row = list.add({ type = "flow", direction = "horizontal" })
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 6
  if p.type == "split" then
    row.add({ type = "sprite", sprite = "utility/status_yellow" })
    row.add({ type = "label", caption = L(mode == "plan" and "prompt-split-plan" or "prompt-split", fp_util.rich(p.item),
      fp_util.localised(p.item), #p.lines) })
    local cands = p.candidates or { p.item }
    if #cands > 1 then
      local items = {}
      for i, key in ipairs(cands) do items[i] = { "", fp_util.rich(key), " ", fp_util.localised(key) } end
      row.add({ type = "drop-down", name = "stoich_cand", items = items, selected_index = 1, enabled = ctx.can_edit,
        tooltip = L("split-candidate-tooltip") })
    end
    row.add({ type = "button", caption = L("choose-split"), enabled = ctx.can_edit,
      tags = { fp = "problem_split", mode = mode, item = p.item, cands = cands } })
  elseif p.type == "anchor" then
    row.add({ type = "sprite", sprite = "utility/status_yellow" })
    row.add({ type = "label", caption = L("prompt-anchor-lines", name_list(player, mode, p.lines)) })
    if mode == "factory" and p.lines[1] then
      row.add({ type = "button", caption = L("anchor-first"), enabled = ctx.can_edit,
        tags = { fp = "problem_anchor", mode = mode, line = p.lines[1] } })
    end
  elseif p.type == "negative" then
    row.add({ type = "sprite", sprite = "utility/status_not_working" })
    row.add({ type = "label", caption = L("negative", name_list(player, mode, p.lines)) })
  elseif p.type == "split_dropped" then
    row.add({ type = "sprite", sprite = "utility/status_yellow" })
    row.add({ type = "label", caption = L("split-dropped", fp_util.rich(p.item or "custom/?")) })
  elseif p.type == "invalid" then
    row.add({ type = "sprite", sprite = "utility/status_not_working" })
    row.add({ type = "label", caption = L("invalid-missing", table.concat(p.missing or {}, ", ")) })
  elseif p.type == "empty_sink" then
    row.add({ type = "sprite", sprite = "utility/status_yellow" })
    row.add({ type = "label", caption = L("empty-sink") })
  elseif p.type == "void_short" or p.type == "import_surplus" then
    row.add({ type = "sprite", sprite = "utility/status_not_working" })
    row.add({ type = "label", caption = L(p.type == "void_short" and "void-short" or "import-surplus", fp_util.rich(p.item), fp_util.localised(p.item)) })
    if p.type == "void_short" then
      row.add({ type = "button", caption = L("import-it"), tooltip = L("import-it-tooltip"), enabled = ctx.can_edit,
        tags = { fp = "problem_boundary", mode = mode, item = p.item, kind = "import" } })
    end
  elseif p.type == "empty_list" then
    row.add({ type = "sprite", sprite = "utility/status_yellow" })
    row.add({ type = "label", caption = L("empty-list") })
  end
end

-- Choices to make (a split, an anchor) come first: they are what the player can act on.
local FIRST = { split = true, anchor = true }

--- Render the problems with their buttons.
--- @param limit number? at most this many rows; a "show all" toggle for the rest
--- @return LuaGuiElement list, number hidden rows
function problems.render(parent, player, mode, result, ctx, limit)
  local list = parent.add({ type = "flow", name = "stoich_problems", direction = "vertical" })
  list.style.vertical_spacing = 4
  -- the items' rows (fixes, conflicts) share one table: icon | problem | actions | alternatives
  local items_table
  local function item_table()
    if not (items_table and items_table.valid) then
      items_table = list.add({ type = "table", name = "stoich_problem_items", column_count = 4 })
      items_table.style.horizontal_spacing = 8
      items_table.style.vertical_spacing = 4
    end
    return items_table
  end
  local rows = {}
  if mode == "plan" and result.too_complicated then
    rows[#rows + 1] = function()
      local row = list.add({ type = "flow", direction = "horizontal" })
      row.style.vertical_align = "center"
      row.style.horizontal_spacing = 6
      row.add({ type = "sprite", sprite = "utility/status_not_working" })
      sentence(row, L("too-complicated"))
    end
  end
  -- a split in the way first: the fixes below are without it
  for _, item in ipairs(mode == "plan" and result.splits_in_way or {}) do
    rows[#rows + 1] = function() split_in_way_row(list, mode, ctx, item) end
  end
  for _, p in ipairs(result.problems) do
    if FIRST[p.type] then rows[#rows + 1] = function() other_row(list, player, mode, ctx, p) end end
  end
  local fixes, closed = fixes_of(mode, result)
  if mode == "plan" and result.complicated and not result.fixes then
    -- the search for what would close the plan runs on demand (it takes a while on big plans)
    rows[#rows + 1] = function()
      local row = list.add({ type = "flow", direction = "horizontal" })
      row.style.vertical_align = "center"
      row.style.horizontal_spacing = 6
      row.add({ type = "sprite", sprite = "utility/status_yellow" })
      local explain = row.add({ type = "label", caption = L(result.status == "UNSETTLED" and "find-fix-explain-settle" or "find-fix-explain"),
        style = "info_label" })
      explain.style.single_line = false
      explain.style.maximal_width = 480
      row.add({ type = "button", caption = L("find-fix"), tooltip = L("find-fix-tooltip"), tags = { fp = "problem_find_fix", mode = mode } })
    end
  end
  if fixes then
    rows[#rows + 1] = function()
      local explain = list.add({ type = "label", caption = L(closed and "fixes-explain" or "fixes-explain-partial"), style = "info_label" })
      explain.style.single_line = false
    end
    for _, fix in ipairs(fixes) do rows[#rows + 1] = function() fix_row(item_table(), player, mode, ctx, fix) end end
  end
  local conflicts, split_involved = conflict_items(result)
  if closed then conflicts, split_involved = {}, false end
  for _, entry in ipairs(conflicts) do rows[#rows + 1] = function() conflict_row(item_table(), player, mode, ctx, entry) end end
  if split_involved then
    rows[#rows + 1] = function() list.add({ type = "label", caption = L("conflict-split"), style = "info_label" }) end
  end
  for _, p in ipairs(result.problems) do
    if p.type ~= "conflict" and not FIRST[p.type] then rows[#rows + 1] = function() other_row(list, player, mode, ctx, p) end end
  end
  local shown = limit and math.min(limit, #rows) or #rows
  for i = 1, shown do rows[i]() end
  return list, #rows - shown
end

handlers.problem_external = function(player, element)
  local a = scopes[element.tags.mode]
  if not (a and a.mark_external and common.ctx(player).can_edit) then return end
  for _, key in ipairs(element.tags.keys or { element.tags.item }) do a.mark_external(player, key) end
end

handlers.problem_remove_split = function(player, element)
  local a = scopes[element.tags.mode]
  if a and a.remove_split and common.ctx(player).can_edit then a.remove_split(player, element.tags.item) end
end

handlers.problem_sink = function(player, element)
  local a = scopes[element.tags.mode]
  if a and common.ctx(player).can_edit then a.add_sink(player, element.tags.item) end
end

handlers.problem_boundary = function(player, element)
  local a = scopes[element.tags.mode]
  if a and a.add_boundary and common.ctx(player).can_edit then
    a.add_boundary(player, element.tags.kind, element.tags.item, element.tags.keys)
  end
end

handlers.problem_split = function(player, element)
  local a = scopes[element.tags.mode]
  if not (a and common.ctx(player).can_edit) then return end
  local item = element.tags.item
  local choice = element.parent.stoich_cand
  if choice then item = element.tags.cands[choice.selected_index] or item end
  a.add_split(player, item)
end

handlers.problem_find_fix = function(player, element)
  local a = scopes[element.tags.mode]
  if a and a.find_fix then a.find_fix(player) end
end

handlers.problem_anchor = function(player, element)
  local a = scopes[element.tags.mode]
  if a and a.anchor and common.ctx(player).can_edit then a.anchor(player, element.tags.line) end
end

handlers.problem_item = function(player, element)
  local a = scopes[element.tags.mode]
  if a and a.show_item then a.show_item(player, element.tags.item) end
end

return problems
