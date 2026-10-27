-- The problems list under a balance: split prompts, conflicting items with
-- one-click Mark external / Add sink, anchors, negative counts.

local common = require("scripts.gui.common")
local splits = require("scripts.gui.splits")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local problems = {}

--- Extra per-mode actions, set by the editor and plan tab:
--- actions[mode] = { mark_external(player, item), add_sink(player, item),
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

--- One-line summary of a result for headers.
function problems.summary(player, mode, result)
  local p = result.problems[1]
  if result.status == "EXACT" then return "" end
  if not p then return "" end
  if p.type == "split" then
    return L("prompt-split", fp_util.rich(p.item), fp_util.localised(p.item), #p.lines)
  elseif p.type == "conflict" then
    local key = p.items[1]
    local reason = p.reasons[key]
    if reason == "no_consumer" then return L("conflict-no-consumer", fp_util.rich(key), fp_util.localised(key)) end
    if reason == "no_producer" then return L("conflict-no-producer", fp_util.rich(key), fp_util.localised(key)) end
    return L("conflict-items", #p.items)
  elseif p.type == "anchor" then
    return L("prompt-anchor")
  elseif p.type == "negative" then
    return L("negative", names(player, mode, p.lines))
  elseif p.type == "invalid" then
    return L("invalid-factory")
  elseif p.type == "empty_sink" then
    return L("empty-sink")
  end
  return ""
end

--- Render all problems with their buttons.
function problems.render(parent, player, mode, result, ctx)
  local list = parent.add({ type = "flow", name = "fp_problems", direction = "vertical" })
  list.style.vertical_spacing = 4
  for _, p in ipairs(result.problems) do
    local row = list.add({ type = "flow", direction = "horizontal" })
    row.style.vertical_align = "center"
    row.style.horizontal_spacing = 6
    if p.type == "split" then
      row.add({ type = "sprite", sprite = "utility/status_yellow" })
      row.add({ type = "label", caption = L("prompt-split", fp_util.rich(p.item), fp_util.localised(p.item), #p.lines) })
      local cands = p.candidates or { p.item }
      if #cands > 1 then
        local items = {}
        for i, key in ipairs(cands) do items[i] = { "", fp_util.rich(key), " ", fp_util.localised(key) } end
        row.add({ type = "drop-down", name = "fp_cand", items = items, selected_index = 1, enabled = ctx.can_edit,
          tooltip = L("split-candidate-tooltip") })
      end
      row.add({ type = "button", caption = L("choose-split"), enabled = ctx.can_edit,
        tags = { fp = "problem_split", mode = mode, item = p.item, cands = cands } })
    elseif p.type == "conflict" then
      -- one row per item: status, the item (click: show it), text, fixes
      row.destroy()
      for _, key in ipairs(p.items) do
        local item_row = list.add({ type = "flow", direction = "horizontal" })
        item_row.style.vertical_align = "center"
        item_row.style.horizontal_spacing = 6
        item_row.add({ type = "sprite", sprite = "utility/status_not_working" })
        item_button(item_row, mode, key)
        local reason = p.reasons[key]
        local text
        if reason == "no_consumer" then
          text = L("conflict-no-consumer", "", fp_util.localised(key))
        elseif reason == "no_producer" then
          text = L("conflict-no-producer", "", fp_util.localised(key))
        else
          text = L("conflict-item", "", fp_util.localised(key))
        end
        item_row.add({ type = "label", caption = text })
        item_row.add({ type = "button", caption = L("mark-external"), enabled = ctx.can_edit,
          tags = { fp = "problem_external", mode = mode, item = key } })
        -- In the plan a sink only helps with a surplus; in a factory the "sink" line can also supply an input.
        if not (mode == "plan" and reason == "no_producer") then
          item_row.add({ type = "button", caption = L("add-sink"), enabled = ctx.can_edit,
            tooltip = L("add-sink-tooltip-" .. mode), tags = { fp = "problem_sink", mode = mode, item = key } })
        end
      end
      if #p.splits > 0 then list.add({ type = "label", caption = L("conflict-split") }) end
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
  if a and common.ctx(player).can_edit then a.mark_external(player, element.tags.item) end
end

handlers.problem_sink = function(player, element)
  local a = problems.actions[element.tags.mode]
  if a and common.ctx(player).can_edit then a.add_sink(player, element.tags.item) end
end

handlers.problem_split = function(player, element)
  local a = problems.actions[element.tags.mode]
  if not (a and common.ctx(player).can_edit) then return end
  local item = element.tags.item
  local choice = element.parent.fp_cand
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
