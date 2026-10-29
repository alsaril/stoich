-- Factory list helpers for the Plan tab: the toolbar buttons and the per-copy flow chips.
-- Also the factory actions: new, capture, edit, delete, export / import.

local common = require("scripts.gui.common")
local editor = require("scripts.gui.editor")
local model = require("scripts.model")
local plan = require("scripts.plan")
local draft = require("scripts.draft")
local exchange = require("scripts.exchange")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local factories = {}

--- Net flow of one copy as plain slots: inputs → outputs (red slots would read as "missing").
--- The arrow is always there, so a sink reads "inputs →" and a mine "→ outputs".
function factories.flow_chips(parent, f, ctx, max_chips)
  local flow = parent.add({ type = "flow", direction = "horizontal" })
  flow.style.horizontal_spacing = 2
  flow.style.vertical_align = "center"
  local net = f.result and f.result.net or {}
  local inputs, outputs = {}, {}
  for _, key in ipairs(fp_util.sorted_keys(net)) do
    table.insert(net[key] > 0 and outputs or inputs, key)
  end
  local function by_size(a, b)
    if math.abs(net[a]) ~= math.abs(net[b]) then return math.abs(net[a]) > math.abs(net[b]) end
    return a < b
  end
  table.sort(inputs, by_size)
  table.sort(outputs, by_size)
  local shown = 0
  local function chip(key)
    local v = net[key]
    local b = flow.add({
      type = "sprite-button", style = "slot_button", sprite = common.key_sprite(key),
      number = math.abs(common.from_per_second(ctx, v)),
      tooltip = { "", fp_util.localised(key), "\n", (v > 0 and "+" or "") .. fp_util.format_rate(v, ctx.unit, true) },
    })
    b.style.size = 32
    shown = shown + 1
  end
  -- keep room for the outputs: inputs get what's left of the slots
  local out_slots = math.min(#outputs, max_chips)
  local in_slots = math.min(#inputs, max_chips - out_slots)
  for i = 1, in_slots do chip(inputs[i]) end
  if #inputs + #outputs > 0 then
    flow.add({ type = "label", caption = "→", style = "bold_label" }).style.horizontal_align = "center"
  end
  for i = 1, out_slots do chip(outputs[i]) end
  local hidden = #inputs + #outputs - shown
  if hidden > 0 then
    -- single line with room for the text, or a squeezed flow wraps "+5" onto two lines
    local more = flow.add({ type = "label", caption = "+" .. hidden, style = "info_label", tooltip = L("more-flows-tooltip", hidden) })
    more.style.single_line = true
    more.style.minimal_width = 24
  end
end

--- Toolbar buttons, added to the given (horizontal) bar.
function factories.add_buttons(bar, ctx)
  bar.add({ type = "button", caption = L("new-factory"), enabled = ctx.can_edit, tags = { fp = "fac_new" } })
  bar.add({ type = "button", caption = L("new-sink"), enabled = ctx.can_edit, tags = { fp = "fac_new_sink" } })
  bar.add({ type = "button", caption = L("capture"), tooltip = L("capture-tooltip"), enabled = ctx.can_edit, tags = { fp = "fac_capture" } })
  bar.add({ type = "empty-widget" }).style.width = 8
  bar.add({ type = "button", caption = L("statistics"), tooltip = L("statistics-tooltip"), tags = { fp = "open_stats" } })
  bar.add({ type = "empty-widget" }).style.width = 8
  bar.add({ type = "button", caption = L("export-all"), tags = { fp = "fac_export_all" } })
  bar.add({ type = "button", caption = L("import"), enabled = ctx.can_edit, tags = { fp = "fac_import" } })
end

-- Toolbar -------------------------------------------------------------------------------------

local function check_edit(player)
  if model.can_edit(player) then return true end
  player.print(L("no-permission"))
  return false
end

handlers.fac_new = function(player)
  if not check_edit(player) then return end
  local f = model.new_factory("factory")
  f.name = "Factory"
  editor.open_factory(player, f)
end

handlers.fac_new_sink = function(player)
  if not check_edit(player) then return end
  local f = draft.new_sink()
  f.sink_items[1] = {}
  editor.open_factory(player, f, { auto_name = true })
end

function factories.give_tool(player)
  if not check_edit(player) then return end
  if player.clear_cursor() then
    player.cursor_stack.set_stack({ name = "stoich-selection-tool", count = 1 })
  end
end

handlers.fac_capture = function(player)
  factories.give_tool(player)
end

handlers.fac_edit = function(player, element)
  editor.open_saved(player, element.tags.id)
end

handlers.show_map = function(player, element)
  local f = model.get(element.tags.id)
  if f then editor.show_on_map(player, f.source) end
end

-- Delete ---------------------------------------------------------------------------------------

function factories.confirm_delete(player, id)
  local f = model.get(id)
  if not f then return end
  local frame = common.open_dialog(player, "delete", L("delete"))
  local body = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  body.add({ type = "label", caption = L("delete-confirm", f.name) })
  local buttons = common.dialog_buttons(frame)
  buttons.add({ type = "button", caption = L("cancel"), style = "back_button", tags = { fp = "dialog_close" } })
  common.spacer(buttons)
  buttons.add({ type = "button", caption = L("delete"), style = "red_confirm_button", tags = { fp = "fac_delete_ok", id = id } })
end

handlers.fac_delete = function(player, element)
  if not check_edit(player) then return end
  factories.confirm_delete(player, element.tags.id)
end

handlers.fac_delete_ok = function(player, element)
  local id = element.tags.id -- read before the dialog (and this button) is destroyed
  common.close_dialog(player)
  if not check_edit(player) then return end
  if model.delete_factory(id, player.index) then plan.changed() end
end

-- Export / import ----------------------------------------------------------------------------------

local function export_dialog(player, list, with_plan)
  local text = exchange.encode(exchange.pack(list, with_plan))
  local frame = common.open_dialog(player, "export", L("export"))
  local box = frame.add({ type = "text-box", text = text or "" })
  box.style.width = 500
  box.style.height = 200
  box.word_wrap = true
  box.read_only = true
  box.select_all()
  box.focus()
  frame.add({ type = "label", caption = L("export-hint"), style = "info_label" })
end

handlers.fac_export_all = function(player)
  local list = {}
  for _, id in ipairs(model.factory_ids()) do list[#list + 1] = model.get(id) end
  export_dialog(player, list, true)
end

handlers.fac_import = function(player)
  if not check_edit(player) then return end
  local frame = common.open_dialog(player, "import", L("import"))
  local box = frame.add({ type = "text-box", name = "stoich_import_text", text = "" })
  box.style.width = 500
  box.style.height = 200
  box.word_wrap = true
  box.focus()
  frame.add({ type = "label", name = "stoich_import_error", caption = "" }).style.font_color = common.RED
  local buttons = common.dialog_buttons(frame)
  buttons.add({ type = "button", caption = L("cancel"), style = "back_button", tags = { fp = "dialog_close" } })
  common.spacer(buttons)
  buttons.add({ type = "button", caption = L("import"), style = "confirm_button", tags = { fp = "fac_import_ok" } })
end

local function finish_import(player, added)
  common.close_dialog(player)
  player.print(L("imported", #added))
  plan.changed()
end

handlers.fac_import_ok = function(player, element)
  if not check_edit(player) then return end
  local frame = player.gui.screen.stoich_dialog
  local text = frame and common.find(frame, "stoich_import_text")
  local err = frame and common.find(frame, "stoich_import_error")
  local data = text and exchange.decode(text.text)
  local unpacked, why = exchange.unpack(data)
  if not unpacked then
    if err then err.caption = L("import-error-" .. (why or "not-a-planner-string")) end
    return
  end
  local ok, added = pcall(exchange.add_to_plan, unpacked, player.index, plan.balance_factory, model.validate_factory)
  if not ok then
    if err then err.caption = L("import-error-not-a-planner-string") end
    plan.changed()
    return
  end
  finish_import(player, added)
end

return factories
