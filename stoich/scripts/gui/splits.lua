-- Split cards, shared by the factory editor (mode "factory") and the split window
-- (mode "plan"). A card shows the split item with a dropdown of shared items,
-- then one row per line: icon, name, slider and % field. The last line shows
-- 100% minus the rest.

local common = require("scripts.gui.common")
local draft = require("scripts.draft")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local splits = {}

--- Per-mode access, set by the editor and plan tab modules:
--- targets[mode] = {
---   holder(player) -> table with .splits,
---   units(player) -> lines { id, flow, count },
---   counts(player) -> current solved counts by id,
---   name_of(player, id) -> LocalisedString, sprite_of(player, id) -> SpritePath,
---   changed(player, structural, index?, line?) -> called after a change (index: the
---     split whose item was switched, or whose share moved; line: the share moved),
---   extra_of(player, id)? -> caption of an extra column (plan: needed copies),
---   can_edit(player) -> bool }
splits.targets = {}

local function card_name(index) return "stoich_split_" .. index end

function splits.build_card(parent, player, mode, index, split)
  local target = splits.targets[mode]
  local units = target.units(player)
  local ids = draft.split_lines(units, split)
  local enabled = target.can_edit(player)
  local card = parent.add({ type = "frame", name = card_name(index), style = "inside_shallow_frame_with_padding", direction = "vertical" })
  card.style.minimal_width = 300
  local head = card.add({ type = "flow", direction = "horizontal" })
  head.style.vertical_align = "center"
  head.add({ type = "sprite", sprite = common.key_sprite(split.item), tooltip = fp_util.localised(split.item) })
  local cands = draft.split_candidates(units, split)
  local items, selected = {}, 1
  for i, key in ipairs(cands) do
    items[i] = { "", fp_util.rich(key), " ", fp_util.localised(key) }
    if key == split.item then selected = i end
  end
  if #items > 1 then
    head.add({ type = "drop-down", items = items, selected_index = selected, enabled = enabled,
      tags = { fp = "split_item", mode = mode, index = index, cands = cands }, tooltip = L("split-item-tooltip") })
  else
    head.add({ type = "label", caption = fp_util.localised(split.item), style = "bold_label" })
  end
  common.spacer(head)
  head.add({ type = "sprite-button", style = "tool_button", sprite = "utility/trash", tooltip = L("split-remove"),
    enabled = enabled, tags = { fp = "split_remove", mode = mode, index = index } })

  local extra = target.extra_of
  -- icon, name, slider, share, "%" (, extra)
  local t = card.add({ type = "table", name = "stoich_split_table", column_count = extra and 6 or 5 })
  t.style.horizontal_spacing = 8
  t.style.column_alignments[4] = "right"
  for i, id in ipairs(ids) do
    t.add({ type = "sprite", sprite = target.sprite_of(player, id) })
    local name = t.add({ type = "label", caption = target.name_of(player, id) })
    name.style.maximal_width = 180
    local share = split.shares[id] or 0
    if i < #ids then
      local slider = t.add({ type = "slider", name = "s_" .. id, minimum_value = 0, maximum_value = 100, value = share,
        value_step = 0.5, enabled = enabled, tags = { fp = "split_slider", mode = mode, index = index, line = id } })
      slider.style.width = 140
      -- shown with at most 2 decimals; the share itself keeps full precision
      local field = t.add({ type = "textfield", name = "f_" .. id, text = fp_util.format_count(share), numeric = true,
        allow_decimal = true, lose_focus_on_confirm = true, enabled = enabled,
        tags = { fp = "split_share", mode = mode, index = index, line = id } })
      field.style.width = 64
      field.style.horizontal_align = "right"
    else
      t.add({ type = "empty-widget" })
      local last = t.add({ type = "label", name = "l_" .. id, caption = fp_util.format_count(share), tooltip = L("split-last-tooltip") })
      last.style.width = 64
      last.style.horizontal_align = "right"
    end
    t.add({ type = "label", caption = L("row-percent") })
    if extra then
      local x = t.add({ type = "label", name = "x_" .. id, caption = extra(player, id), style = "info_label" })
      x.style.left_margin = 8
    end
  end
  return card
end

--- Update slider/field values of a card in place (no rebuild, so a dragged slider keeps working).
function splits.update_card(container, player, mode, index, except_line)
  local card = container and common.find(container, card_name(index))
  if not card then return end
  local target = splits.targets[mode]
  local split = target.holder(player).splits[index]
  if not split then return end
  local t = card.stoich_split_table
  for _, id in ipairs(draft.split_lines(target.units(player), split)) do
    local share = split.shares[id] or 0
    local slider, field, last = t["s_" .. id], t["f_" .. id], t["l_" .. id]
    if id ~= except_line then
      if slider then slider.slider_value = share end
      if field then field.text = fp_util.format_count(share) end
    end
    if last then last.caption = fp_util.format_count(share) end
    local x = t["x_" .. id]
    if x and target.extra_of then x.caption = target.extra_of(player, id) end
  end
end

local function apply_share(player, element, value)
  local tags = element.tags
  local target = splits.targets[tags.mode]
  if not target.can_edit(player) then return end
  local holder = target.holder(player)
  draft.set_share(holder, tags.index, tags.line, value, target.units(player))
  target.changed(player, false, tags.index, tags.line)
end

handlers.split_slider = function(player, element, event)
  if event.name ~= defines.events.on_gui_value_changed then return end
  apply_share(player, element, element.slider_value)
  -- keep this row's field in sync with the slider
  local field = element.parent["f_" .. element.tags.line]
  local split = splits.targets[element.tags.mode].holder(player).splits[element.tags.index]
  if field and split then field.text = fp_util.format_count(split.shares[element.tags.line] or 0) end
end

handlers.split_share = function(player, element, event)
  if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
  local v = fp_util.parse_number(element.text)
  if not v then return end
  apply_share(player, element, v)
  local slider = element.parent["s_" .. element.tags.line]
  local split = splits.targets[element.tags.mode].holder(player).splits[element.tags.index]
  if slider and split then slider.slider_value = split.shares[element.tags.line] or 0 end
end

handlers.split_item = function(player, element, event)
  if event.name ~= defines.events.on_gui_selection_state_changed then return end
  local tags = element.tags
  local target = splits.targets[tags.mode]
  if not target.can_edit(player) then return end
  local item = tags.cands[element.selected_index]
  if not item then return end
  draft.switch_split_item(target.holder(player), tags.index, item, target.units(player), target.counts(player))
  target.changed(player, true, tags.index)
end

handlers.split_remove = function(player, element)
  local tags = element.tags
  local target = splits.targets[tags.mode]
  if not target.can_edit(player) then return end
  draft.remove_split(target.holder(player), tags.index)
  target.changed(player, true)
end

return splits
