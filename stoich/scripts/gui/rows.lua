-- Editable rows of (item picker or custom text, rate, fluid flag), used by the
-- sink editor and the custom / override line dialog. A row is only
-- { key, <field>, fluid }: the picker shows an item/fluid key, the text field a
-- custom one. Rates are typed in the player's display unit and stored per second.

local common = require("scripts.gui.common")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local rows = {}

--- targets[mode] = { rows(player) -> array, field = "rate"|"amount", changed(player, structural),
---   allow_negative? }
rows.targets = {}

--- The signal picker also offers recipes and buildings: turn those into the
--- item or fluid they stand for (a recipe's main product, a building's item).
function rows.normalize_signal(signal)
  if not (signal and signal.name) then return signal end
  local t = signal.type or "item"
  if t == "recipe" then
    local r = prototypes.recipe[signal.name]
    local p = r and (r.main_product or (r.products and r.products[1]))
    if p and (p.type == "item" or p.type == "fluid") then return { type = p.type, name = p.name } end
  elseif t == "entity" then
    local e = prototypes.entity[signal.name]
    local place = e and e.items_to_place_this and e.items_to_place_this[1]
    if place then return { type = "item", name = place.name } end
  end
  return signal
end

local function is_custom(key)
  return key ~= nil and key:sub(1, 7) == "custom/"
end

--- What the picker and the text field show for a row's key.
local function display(row)
  if not row.key then return nil, "" end
  local signal = fp_util.signal_from_key(row.key)
  if signal then return signal, "" end
  return nil, select(2, fp_util.parse_key(row.key))
end

--- @param opts table? { stretch = true }: the rows fill the parent's width (the custom
---   name field takes the spare room)
function rows.build(parent, player, mode, ctx, enabled, opts)
  local stretch = opts and opts.stretch
  local target = rows.targets[mode]
  local list = target.rows(player)
  -- The fluid flag only means something for custom names; real items and fluids know what they are.
  -- A picked item shows its name; the custom-name field is there only for rows without one.
  local any_custom, any_free = false, false
  for _, row in ipairs(list) do
    if is_custom(row.key) then any_custom = true end
    if not row.key or is_custom(row.key) then any_free = true end
  end
  local box = parent.add({ type = "flow", name = "stoich_rows_" .. mode, direction = "vertical" })
  local t = box.add({ type = "table", name = "stoich_rows_table", column_count = any_custom and 5 or 4 })
  t.style.horizontal_spacing = 8
  if stretch then
    box.style.horizontally_stretchable = true
    t.style.horizontally_stretchable = true
  end
  t.add({ type = "label", caption = L("row-item"), style = "bold_label" })
  if any_free then
    t.add({ type = "label", caption = L("row-custom"), style = "bold_label", tooltip = L("row-custom-tooltip") })
  else
    t.add({ type = "empty-widget" })
  end
  t.add({ type = "label", caption = { "", L("row-rate"), " (", common.unit_suffix(ctx), ")" }, style = "bold_label" })
  if any_custom then t.add({ type = "label", caption = L("row-fluid"), style = "bold_label", tooltip = L("row-fluid-tooltip") }) end
  t.add({ type = "empty-widget" })
  for i, row in ipairs(list) do
    local key = row.key
    local signal, custom = display(row)
    t.add({ type = "choose-elem-button", elem_type = "signal", signal = signal, enabled = enabled,
      tooltip = key and fp_util.localised(key) or L("row-item-tooltip"), tags = { fp = "row_signal", mode = mode, i = i } })
    local text
    if key and not is_custom(key) then
      text = t.add({ type = "label", caption = fp_util.localised(key) })
    else
      text = t.add({ type = "textfield", text = custom, enabled = enabled, tooltip = L("row-custom-tooltip"),
        tags = { fp = "row_text", mode = mode, i = i } })
    end
    if stretch then
      text.style.minimal_width = 140
      text.style.maximal_width = 1000 -- the textfield style caps the width otherwise
      text.style.horizontally_stretchable = true
    else
      text.style.width = 140
    end
    local v = row[target.field]
    common.number_field(t, v and common.from_per_second(ctx, v) or nil, { fp = "row_rate", mode = mode, i = i },
      { width = 80, enabled = enabled, negative = target.allow_negative })
    if any_custom then
      if is_custom(key) then
        t.add({ type = "checkbox", state = row.fluid and true or false, enabled = enabled, tooltip = L("row-fluid-tooltip"),
          tags = { fp = "row_fluid", mode = mode, i = i } })
      else
        t.add({ type = "empty-widget" })
      end
    end
    t.add({ type = "sprite-button", style = "tool_button", sprite = "utility/trash", enabled = enabled,
      tags = { fp = "row_delete", mode = mode, i = i } })
  end
  box.add({ type = "button", caption = L("add-row"), enabled = enabled, tags = { fp = "row_add", mode = mode } })
  return box
end

local function row_of(player, element)
  local target = rows.targets[element.tags.mode]
  local list = target.rows(player)
  return list[element.tags.i], target, list
end

local function set_key(row, key)
  row.key = key
  if not is_custom(key) then row.fluid = nil end
end

handlers.row_signal = { elem = function(player, element, event)
  local row, target = row_of(player, element)
  if not row then return end
  local signal = rows.normalize_signal(element.elem_value)
  -- an emptied picker keeps a custom name (the text field shows it)
  if signal then set_key(row, fp_util.key_from_signal(signal))
  elseif not is_custom(row.key) then set_key(row, nil) end
  target.changed(player, true)
end }

local function typed_text(player, element, confirmed)
  local row, target = row_of(player, element)
  if not row then return end
  -- a custom name replaces the picked item; clearing it leaves the row empty
  if element.text ~= "" then set_key(row, fp_util.key("custom", element.text))
  elseif is_custom(row.key) then set_key(row, nil) end
  -- rebuild only on Enter (rebuilding while typing would steal the focus); the fluid column appears then
  target.changed(player, confirmed)
end

handlers.row_text = {
  text = function(player, element) typed_text(player, element, false) end,
  confirmed = function(player, element) typed_text(player, element, true) end,
}

local function typed_rate(player, element)
  local row, target = row_of(player, element)
  if not row then return end
  local v = fp_util.parse_number(element.text)
  if not v then return end
  row[target.field] = common.to_per_second(common.ctx(player), v)
  target.changed(player, false)
end

handlers.row_rate = { text = typed_rate, confirmed = typed_rate }

handlers.row_fluid = function(player, element)
  local row, target = row_of(player, element)
  if not row then return end
  row.fluid = element.state or nil
  target.changed(player, false)
end

handlers.row_delete = function(player, element)
  local _, target, list = row_of(player, element)
  table.remove(list, element.tags.i)
  target.changed(player, true)
end

handlers.row_add = function(player, element)
  local target = rows.targets[element.tags.mode]
  local list = target.rows(player)
  list[#list + 1] = {}
  target.changed(player, true)
end

return rows
