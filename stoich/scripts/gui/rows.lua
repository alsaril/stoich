-- Editable rows of (item picker or custom text, rate, fluid flag), used by the
-- sink editor and the custom / override line dialog. Rates are typed in the
-- player's display unit and stored per second.

local common = require("scripts.gui.common")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local rows = {}

--- targets[mode] = { rows(player) -> array, field = "rate"|"amount", changed(player, structural), sign = 1|-1 }
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

--- Item key of a row: custom text wins over the picker.
function rows.key_of(row)
  if row.text and row.text ~= "" then return fp_util.key("custom", row.text) end
  if row.signal then return fp_util.key_from_signal(row.signal) end
  return row.key
end

local function is_custom(key)
  return key ~= nil and key:sub(1, 7) == "custom/"
end

--- Fill .signal/.text from .key for editing.
function rows.prepare(list)
  for _, row in ipairs(list) do
    if row.key and not row.signal and not row.text then
      local t, n = fp_util.parse_key(row.key)
      if t == "item" or t == "fluid" then row.signal = { type = t, name = n } else row.text = n end
    end
  end
  return list
end

function rows.build(parent, player, mode, ctx, enabled)
  local target = rows.targets[mode]
  local list = target.rows(player)
  -- The fluid flag only means something for custom names; real items and fluids know what they are.
  local any_custom = false
  for _, row in ipairs(list) do
    if is_custom(rows.key_of(row)) then any_custom = true end
  end
  local box = parent.add({ type = "flow", name = "stoich_rows_" .. mode, direction = "vertical" })
  local t = box.add({ type = "table", name = "stoich_rows_table", column_count = any_custom and 5 or 4 })
  t.style.horizontal_spacing = 8
  t.add({ type = "label", caption = L("row-item"), style = "bold_label" })
  t.add({ type = "label", caption = L("row-custom"), style = "bold_label", tooltip = L("row-custom-tooltip") })
  t.add({ type = "label", caption = { "", L("row-rate"), " (", common.unit_suffix(ctx), ")" }, style = "bold_label" })
  if any_custom then t.add({ type = "label", caption = L("row-fluid"), style = "bold_label", tooltip = L("row-fluid-tooltip") }) end
  t.add({ type = "empty-widget" })
  for i, row in ipairs(list) do
    local key = rows.key_of(row)
    t.add({ type = "choose-elem-button", elem_type = "signal", signal = row.signal, enabled = enabled,
      tooltip = key and fp_util.localised(key) or L("row-item-tooltip"), tags = { fp = "row_signal", mode = mode, i = i } })
    local text = t.add({ type = "textfield", text = row.text or "", enabled = enabled, tags = { fp = "row_text", mode = mode, i = i } })
    text.style.width = 140
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

local function sync_key(row)
  row.key = rows.key_of(row)
  if not is_custom(row.key) then row.fluid = nil end
end

handlers.row_signal = function(player, element, event)
  if event.name ~= defines.events.on_gui_elem_changed then return end
  local row, target = row_of(player, element)
  if not row then return end
  row.signal = rows.normalize_signal(element.elem_value)
  if row.signal then row.text = nil end
  sync_key(row)
  target.changed(player, true)
end

handlers.row_text = function(player, element, event)
  if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
  local row, target = row_of(player, element)
  if not row then return end
  row.text = element.text
  sync_key(row)
  -- rebuild only on Enter (rebuilding while typing would steal the focus); the fluid column appears then
  target.changed(player, event.name == defines.events.on_gui_confirmed)
end

handlers.row_rate = function(player, element, event)
  if event.name ~= defines.events.on_gui_text_changed and event.name ~= defines.events.on_gui_confirmed then return end
  local row, target = row_of(player, element)
  if not row then return end
  local v = fp_util.parse_number(element.text)
  if not v then return end
  row[target.field] = common.to_per_second(common.ctx(player), v)
  target.changed(player, false)
end

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
