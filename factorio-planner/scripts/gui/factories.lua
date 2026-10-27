-- Factories tab: the list of factories and sinks, or the editor when a draft is open.
-- Also the export / import dialogs and delete confirmation.

local common = require("scripts.gui.common")
local window = require("scripts.gui.window")
local editor = require("scripts.gui.editor")
local model = require("scripts.model")
local plan = require("scripts.plan")
local draft = require("scripts.draft")
local exchange = require("scripts.exchange")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local factories = {}

-- Net flow of one copy as plain slots: inputs → outputs (red slots would read as "missing").
local MAX_CHIPS = 8

local function outputs_flow(parent, f, ctx)
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
  local out_slots = math.min(#outputs, MAX_CHIPS)
  local in_slots = math.min(#inputs, MAX_CHIPS - out_slots)
  for i = 1, in_slots do chip(inputs[i]) end
  if #inputs > 0 and #outputs > 0 then
    flow.add({ type = "label", caption = "→", style = "bold_label" }).style.horizontal_align = "center"
  end
  for i = 1, out_slots do chip(outputs[i]) end
  local hidden = #inputs + #outputs - shown
  if hidden > 0 then flow.add({ type = "label", caption = "+" .. hidden, style = "info_label", tooltip = L("more-flows-tooltip", hidden) }) end
end

function factories.build(player, parent, ctx)
  local d = draft.get(player.index)
  if d then
    editor.build(player, parent, ctx)
    return
  end
  local bar = parent.add({ type = "flow", direction = "horizontal" })
  bar.style.horizontal_spacing = 8
  bar.add({ type = "button", caption = L("new-factory"), enabled = ctx.can_edit, tags = { fp = "fac_new" } })
  bar.add({ type = "button", caption = L("new-sink"), enabled = ctx.can_edit, tags = { fp = "fac_new_sink" } })
  bar.add({ type = "button", caption = L("capture"), tooltip = L("capture-tooltip"), enabled = ctx.can_edit, tags = { fp = "fac_capture" } })
  common.spacer(bar)
  bar.add({ type = "button", caption = L("export-all"), tags = { fp = "fac_export_all" } })
  bar.add({ type = "button", caption = L("import"), enabled = ctx.can_edit, tags = { fp = "fac_import" } })

  local state = model.player(player.index)
  local details = state.factories_details or false
  bar.add({ type = "checkbox", caption = L("details"), tooltip = L("details-tooltip"), state = details, tags = { fp = "fac_details" } })

  local ids = model.factory_ids()
  if #ids == 0 then
    parent.add({ type = "label", caption = L("no-factories") })
    return
  end
  local pane = parent.add({ type = "scroll-pane", style = "scroll_pane" })
  pane.style.vertically_stretchable = true
  pane.style.horizontally_stretchable = true
  -- Saved factories are always EXACT (Save requires it), so there is no status column;
  -- an invalid one (a mod it uses was removed) gets a red name and a warning icon.
  local heads = { "", "col-name", "col-lines", "col-net-flow" }
  if details then heads[#heads + 1] = "col-modified" end
  heads[#heads + 1] = ""
  heads[#heads + 1] = ""
  local t = pane.add({ type = "table", column_count = #heads, draw_horizontal_lines = true })
  t.style.horizontally_stretchable = true
  t.style.horizontal_spacing = 10
  t.style.vertical_spacing = 4
  for _, h in ipairs(heads) do
    if h == "" then t.add({ type = "empty-widget" }) else
      local caption = L(h)
      if h == "col-net-flow" then caption = { "", L(h), " (", common.unit_suffix(ctx), ")" } end
      -- stretchable headers: the data columns share the spare width (invisible spacing)
      t.add({ type = "label", caption = caption, style = "bold_label" }).style.horizontally_stretchable = true
    end
  end
  -- sinks first, then factories, each by name
  table.sort(ids, function(a, b)
    local fa, fb = model.get(a), model.get(b)
    if (fa.kind == "sink") ~= (fb.kind == "sink") then return fa.kind == "sink" end
    if fa.name ~= fb.name then return fa.name < fb.name end
    return a < b
  end)
  local names = common.factory_names(ctx)
  for _, id in ipairs(ids) do
    local f = model.get(id)
    t.add({ type = "sprite", sprite = common.factory_sprite(f) })
    local name_cell = t.add({ type = "flow", direction = "horizontal" })
    name_cell.style.vertical_align = "center"
    local name = name_cell.add({ type = "label", caption = names[id] })
    name.style.maximal_width = 220
    if f.invalid then
      name.style.font_color = common.RED
      local warn = name_cell.add({ type = "sprite", sprite = "utility/warning_icon",
        tooltip = L("invalid-missing", table.concat(f.invalid, ", ")) })
      warn.style.size = 16
      warn.style.stretch_image_to_widget_size = true
    end
    if f.kind == "sink" then
      -- sinks have no lines; mark them here instead of in the name
      local mark = t.add({ type = "label", caption = L("sink-mark"), style = "info_label", tooltip = L("sink-explain") })
      mark.style.single_line = true
      mark.style.minimal_width = 36
    else
      t.add({ type = "label", caption = tostring(#f.lines) })
    end
    outputs_flow(t, f, ctx)
    if details then
      t.add({ type = "label", caption = { "", common.player_name(f.modified_by), " ", common.time_ago(f.modified_tick) } })
    end
    local buttons = t.add({ type = "flow", direction = "horizontal" })
    buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/rename_icon", tooltip = L("edit"),
      tags = { fp = "fac_edit", id = id } })
    if f.source then
      buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/center", tooltip = L("show-on-map"),
        tags = { fp = "show_map", id = id } })
    else
      buttons.add({ type = "empty-widget" }).style.width = 28 -- keep the columns aligned
    end
    if details then
      buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/copy", tooltip = L("duplicate"), enabled = ctx.can_edit,
        tags = { fp = "fac_duplicate", id = id } })
      buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/export", tooltip = L("export"),
        tags = { fp = "fac_export", id = id } })
    end
    t.add({ type = "sprite-button", style = "tool_button", sprite = "utility/trash", tooltip = L("delete"), enabled = ctx.can_edit,
      tags = { fp = "fac_delete", id = id } })
  end
end

handlers.fac_details = function(player, element)
  model.player(player.index).factories_details = element.state
  window.refresh(player)
end

window.builders.factories = factories.build

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
    player.cursor_stack.set_stack({ name = "fp-selection-tool", count = 1 })
  end
end

handlers.fac_capture = function(player)
  factories.give_tool(player)
end

handlers.fac_edit = function(player, element)
  editor.open_saved(player, element.tags.id)
end

handlers.fac_duplicate = function(player, element)
  if not check_edit(player) then return end
  local f = model.get(element.tags.id)
  if not f then return end
  local copy = fp_util.deep_copy(f)
  copy.id = nil
  copy.revision = 0
  copy.name = f.name .. " (copy)"
  -- a new design: nothing of it is built yet, and not at the original's area
  if copy.kind ~= "sink" then copy.copies = 1 end
  copy.pinned = false
  copy.source = nil
  plan.balance_factory(copy)
  model.save_factory(copy, {}, player.index)
  plan.changed()
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

handlers.fac_export = function(player, element)
  local f = model.get(element.tags.id)
  if f then export_dialog(player, { f }, false) end
end

handlers.fac_export_all = function(player)
  local list = {}
  for _, id in ipairs(model.factory_ids()) do list[#list + 1] = model.get(id) end
  export_dialog(player, list, true)
end

handlers.fac_import = function(player)
  if not check_edit(player) then return end
  local frame = common.open_dialog(player, "import", L("import"))
  local box = frame.add({ type = "text-box", name = "fp_import_text", text = "" })
  box.style.width = 500
  box.style.height = 200
  box.word_wrap = true
  box.focus()
  frame.add({ type = "label", name = "fp_import_error", caption = "" }).style.font_color = common.RED
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
  local frame = player.gui.screen.fp_dialog
  local text = frame and common.find(frame, "fp_import_text")
  local err = frame and common.find(frame, "fp_import_error")
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
