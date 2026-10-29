-- Factory actions of the main window: new factory or sink, capture, edit, show on
-- map, delete (with its question), export and import.

local common = require("scripts.gui.common")
local window = require("scripts.gui.window")
local editor = require("scripts.gui.editor")
local model = require("scripts.model")
local draft = require("scripts.draft")
local exchange = require("scripts.exchange")

local L = common.L
local handlers = common.handlers

local actions = {}

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

local function give_tool(player)
  if not check_edit(player) then return end
  if player.clear_cursor() then
    player.cursor_stack.set_stack({ name = "stoich-selection-tool", count = 1 })
  end
end

handlers.fac_capture = function(player)
  give_tool(player)
end

handlers.fac_edit = function(player, element)
  editor.open_saved(player, element.tags.id)
end

handlers.show_map = function(player, element)
  local f = model.get(element.tags.id)
  if f then window.show_on_map(player, f.source) end
end

-- Delete ---------------------------------------------------------------------------------------

function actions.confirm_delete(player, id)
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
  actions.confirm_delete(player, element.tags.id)
end

handlers.fac_delete_ok = function(player, element)
  local id = element.tags.id -- read before the dialog (and this button) is destroyed
  common.close_dialog(player)
  if not check_edit(player) then return end
  if model.delete_factory(id, player.index) then window.plan_changed() end
end

-- Export / import ----------------------------------------------------------------------------------

local function export_dialog(player, list)
  local text = exchange.encode(exchange.pack(list))
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
  export_dialog(player, list)
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
  window.plan_changed()
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
  -- a last guard: add_to_plan checks everything before it saves anything
  local ok, added = pcall(exchange.add_to_plan, unpacked, player.index)
  if not ok then
    if err then err.caption = L("import-error-not-a-planner-string") end
    return
  end
  finish_import(player, added)
end

return actions
