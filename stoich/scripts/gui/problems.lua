-- The problems list under a balance: split prompts, conflicting items with
-- one-click Mark external / Add sink, anchors, negative counts.

local common = require("scripts.gui.common")
local scopes = require("scripts.gui.scopes")
local solver = require("scripts.solver")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local problems = {}


local function item_button(parent, mode, key)
  local b = parent.add({
    type = "sprite-button", style = "transparent_slot", sprite = common.key_sprite(key),
    tooltip = fp_util.localised(key), tags = { fp = "problem_item", mode = mode, item = key },
  })
  b.style.size = 24
  return b
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

--- Conflicting items across all conflict problems, once each, in order.
local function conflict_items(result)
  local out, seen = {}, {}
  local split_involved = false
  for _, p in ipairs(result.problems) do
    if p.type == "conflict" then
      for _, key in ipairs(p.items) do
        if not seen[key] then
          seen[key] = true
          out[#out + 1] = { key = key, reason = p.reasons[key] }
        end
      end
      if #p.splits > 0 then split_involved = true end
    end
  end
  return out, split_involved
end

-- A plan that can't balance lists what would close it (plan.diagnose) instead of every
-- item of the contradiction; the plain conflict rows stay when that isn't all of it.
local function fixes_of(mode, result)
  if mode == "plan" and result.fixes and #result.fixes > 0 then return result.fixes, result.fixes_close end
  return nil, false
end

--- Number of problem rows shown (conflicts count once per item).
function problems.count(result, mode)
  local fixes, closed = fixes_of(mode, result)
  local n = closed and 0 or #conflict_items(result)
  if fixes then n = n + #fixes end
  for _, p in ipairs(result.problems) do
    if p.type ~= "conflict" then n = n + 1 end
  end
  return n
end

--- Names of the lines (factory) or factories (plan) that make (sign > 0) or use (sign < 0) an item.
local function who(player, mode, key, sign)
  local target = scopes[mode]
  local ids = {}
  for _, unit in ipairs(target.units(player)) do
    local v = unit.flow[key] or 0
    if v * sign > 0 then ids[#ids + 1] = unit.id end
  end
  table.sort(ids, solver.id_less)
  return name_list(player, mode, ids)
end

local function conflict_row(list, player, mode, ctx, entry)
  local key, reason = entry.key, entry.reason
  local row = list.add({ type = "flow", direction = "horizontal" })
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 6
  row.add({ type = "sprite", sprite = "utility/status_not_working" })
  item_button(row, mode, key)
  local text
  if mode == "plan" then
    if reason == "no_producer" then
      text = L("plan-no-producer", "", fp_util.localised(key), who(player, mode, key, -1))
    elseif reason == "no_consumer" then
      text = L("plan-no-consumer", "", fp_util.localised(key), who(player, mode, key, 1))
    else
      text = L("conflict-item", "", fp_util.localised(key))
    end
  else
    if reason == "no_producer" then
      text = L("conflict-no-producer", "", fp_util.localised(key))
    elseif reason == "no_consumer" then
      text = L("conflict-no-consumer", "", fp_util.localised(key))
    else
      text = L("conflict-item", "", fp_util.localised(key))
    end
  end
  row.add({ type = "label", caption = text })
  local function button(caption, tooltip, action, kind)
    row.add({ type = "button", caption = L(caption), tooltip = tooltip and L(tooltip) or nil, enabled = ctx.can_edit,
      tags = { fp = action, mode = mode, item = key, kind = kind } })
  end
  if mode == "plan" then
    -- the plan is closed but for its voids and imports: a surplus goes to a sink or a
    -- void, a missing item comes from an import
    if reason == "no_consumer" then
      button("add-sink", "add-sink-tooltip-plan", "problem_sink")
      button("void-it", "void-it-tooltip", "problem_boundary", "void")
    elseif reason == "no_producer" then
      button("import-it", "import-it-tooltip", "problem_boundary", "import")
    end
  else
    if reason == "no_producer" then
      button("mark-input", "mark-input-tooltip", "problem_external")
    elseif reason == "no_consumer" then
      button("mark-output", "mark-output-tooltip", "problem_external")
      button("add-void", "add-sink-tooltip-factory", "problem_sink")
    else
      button("mark-external", nil, "problem_external")
    end
  end
end

-- A fix of a plan that can't balance: how much of an item is left over or missing, the
-- items that would do instead, and the one-click void, sink or import.
local function fix_row(list, player, mode, ctx, fix)
  local key = fix.item
  local row = list.add({ type = "flow", direction = "horizontal" })
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 6
  row.add({ type = "sprite", sprite = "utility/status_not_working" })
  item_button(row, mode, key)
  local rate = fix.rate and fp_util.format_rate(math.abs(fix.rate), ctx.unit, true)
  local text
  if fix.rate == nil then
    text = L("fix-unknown", "", fp_util.localised(key))
  elseif fix.rate >= 0 then
    text = L("fix-surplus", "", fp_util.localised(key), rate)
  else
    text = L("fix-short", "", fp_util.localised(key), rate)
  end
  row.add({ type = "label", caption = text, tooltip = L("fix-who", who(player, mode, key, 1), who(player, mode, key, -1)) })
  if #fix.alternatives > 0 then
    row.add({ type = "label", caption = L("fix-or"), style = "info_label", tooltip = L("fix-or-tooltip") })
    for i, other in ipairs(fix.alternatives) do
      if i > 8 then
        row.add({ type = "label", caption = "+" .. (#fix.alternatives - 8), style = "info_label" })
        break
      end
      item_button(row, mode, other)
    end
  end
  local function button(caption, tooltip, action, kind)
    row.add({ type = "button", caption = L(caption), tooltip = L(tooltip), enabled = ctx.can_edit,
      tags = { fp = action, mode = mode, item = key, kind = kind } })
  end
  if fix.rate == nil or fix.rate >= 0 then
    button("void-it", "void-it-tooltip", "problem_boundary", "void")
    if fix.rate then button("add-sink", "add-sink-tooltip-plan", "problem_sink") end
  end
  if fix.rate == nil or fix.rate < 0 then button("import-it", "import-it-tooltip", "problem_boundary", "import") end
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
  local rows = {}
  for _, p in ipairs(result.problems) do
    if FIRST[p.type] then rows[#rows + 1] = function() other_row(list, player, mode, ctx, p) end end
  end
  local fixes, closed = fixes_of(mode, result)
  if fixes then
    rows[#rows + 1] = function()
      local explain = list.add({ type = "label", caption = L(closed and "fixes-explain" or "fixes-explain-partial"), style = "info_label" })
      explain.style.single_line = false
    end
    for _, fix in ipairs(fixes) do rows[#rows + 1] = function() fix_row(list, player, mode, ctx, fix) end end
  end
  local conflicts, split_involved = conflict_items(result)
  if closed then conflicts, split_involved = {}, false end
  for _, entry in ipairs(conflicts) do rows[#rows + 1] = function() conflict_row(list, player, mode, ctx, entry) end end
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
  if a and a.mark_external and common.ctx(player).can_edit then a.mark_external(player, element.tags.item) end
end

handlers.problem_sink = function(player, element)
  local a = scopes[element.tags.mode]
  if a and common.ctx(player).can_edit then a.add_sink(player, element.tags.item) end
end

handlers.problem_boundary = function(player, element)
  local a = scopes[element.tags.mode]
  if a and a.add_boundary and common.ctx(player).can_edit then a.add_boundary(player, element.tags.kind, element.tags.item) end
end

handlers.problem_split = function(player, element)
  local a = scopes[element.tags.mode]
  if not (a and common.ctx(player).can_edit) then return end
  local item = element.tags.item
  local choice = element.parent.stoich_cand
  if choice then item = element.tags.cands[choice.selected_index] or item end
  a.add_split(player, item)
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
