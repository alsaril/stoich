-- The problems list under a balance: split prompts, conflicting items with
-- one-click Mark external / Add sink, anchors, negative counts.

local common = require("scripts.gui.common")
local splits = require("scripts.gui.splits")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local problems = {}

--- Extra per-mode actions, set by the editor and plan tab:
--- actions[mode] = { mark_external(player, item) (factory only), add_sink(player, item),
---   add_split(player, item) (over every line making the item), anchor(player, line_id), show_item(player, item)? }
problems.actions = {}

local function item_button(parent, mode, key)
  local b = parent.add({
    type = "sprite-button", style = "transparent_slot", sprite = common.key_sprite(key),
    tooltip = fp_util.localised(key), tags = { fp = "problem_item", mode = mode, item = key },
  })
  b.style.size = 24
  return b
end

local function names(player, mode, ids)
  local target = splits.targets[mode]
  local out = { "" }
  for i, id in ipairs(ids) do
    if i > 6 then
      out[#out + 1] = ", …"
      break
    end
    if i > 1 then out[#out + 1] = ", " end
    out[#out + 1] = target.name_of(player, id)
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

--- Number of problem rows shown (conflicts count once per item).
function problems.count(result)
  local n = #conflict_items(result)
  for _, p in ipairs(result.problems) do
    if p.type ~= "conflict" then n = n + 1 end
  end
  return n
end

--- Names of the lines (factory) or factories (plan) that make (sign > 0) or use (sign < 0) an item.
local function who(player, mode, key, sign)
  local target = splits.targets[mode]
  local ids = {}
  for _, unit in ipairs(target.units(player)) do
    local v = unit.flow[key] or 0
    if v * sign > 0 then ids[#ids + 1] = unit.id end
  end
  table.sort(ids, function(a, b)
    if type(a) ~= type(b) then return type(a) == "number" end
    return a < b
  end)
  return names(player, mode, ids)
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
  local function button(caption, tooltip, action)
    row.add({ type = "button", caption = L(caption), tooltip = tooltip and L(tooltip) or nil, enabled = ctx.can_edit,
      tags = { fp = action, mode = mode, item = key } })
  end
  if mode == "plan" then
    -- the plan is closed: no "comes from / leaves the plan" here (plan.external stays in
    -- the model and still applies); a surplus can go to a sink
    if reason == "no_consumer" then button("add-sink", "add-sink-tooltip-plan", "problem_sink") end
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

--- Render all problems with their buttons.
function problems.render(parent, player, mode, result, ctx)
  local list = parent.add({ type = "flow", name = "stoich_problems", direction = "vertical" })
  list.style.vertical_spacing = 4
  local conflicts, split_involved = conflict_items(result)
  for _, entry in ipairs(conflicts) do conflict_row(list, player, mode, ctx, entry) end
  if split_involved then list.add({ type = "label", caption = L("conflict-split"), style = "info_label" }) end
  for _, p in ipairs(result.problems) do
    local row
    if p.type ~= "conflict" then
      row = list.add({ type = "flow", direction = "horizontal" })
      row.style.vertical_align = "center"
      row.style.horizontal_spacing = 6
    end
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
      row.add({ type = "label", caption = L("prompt-anchor-lines", names(player, mode, p.lines)) })
      if mode == "factory" and p.lines[1] then
        row.add({ type = "button", caption = L("anchor-first"), enabled = ctx.can_edit,
          tags = { fp = "problem_anchor", mode = mode, line = p.lines[1] } })
      end
    elseif p.type == "negative" then
      row.add({ type = "sprite", sprite = "utility/status_not_working" })
      row.add({ type = "label", caption = L("negative", names(player, mode, p.lines)) })
    elseif p.type == "split_dropped" then
      row.add({ type = "sprite", sprite = "utility/status_yellow" })
      row.add({ type = "label", caption = L("split-dropped", fp_util.rich(p.item or "custom/?")) })
    elseif p.type == "invalid" then
      row.add({ type = "sprite", sprite = "utility/status_not_working" })
      row.add({ type = "label", caption = L("invalid-missing", table.concat(p.missing or {}, ", ")) })
    elseif p.type == "empty_sink" then
      row.add({ type = "sprite", sprite = "utility/status_yellow" })
      row.add({ type = "label", caption = L("empty-sink") })
    end
  end
  return list
end

handlers.problem_external = function(player, element)
  local a = problems.actions[element.tags.mode]
  if a and a.mark_external and common.ctx(player).can_edit then a.mark_external(player, element.tags.item) end
end

handlers.problem_sink = function(player, element)
  local a = problems.actions[element.tags.mode]
  if a and common.ctx(player).can_edit then a.add_sink(player, element.tags.item) end
end

handlers.problem_split = function(player, element)
  local a = problems.actions[element.tags.mode]
  if not (a and common.ctx(player).can_edit) then return end
  local item = element.tags.item
  local choice = element.parent.stoich_cand
  if choice then item = element.tags.cands[choice.selected_index] or item end
  a.add_split(player, item)
end

handlers.problem_anchor = function(player, element)
  local a = problems.actions[element.tags.mode]
  if a and a.anchor and common.ctx(player).can_edit then a.anchor(player, element.tags.line) end
end

handlers.problem_item = function(player, element)
  local a = problems.actions[element.tags.mode]
  if a and a.show_item then a.show_item(player, element.tags.item) end
end

return problems
