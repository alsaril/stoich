-- The custom line dialog of the factory editor: a line of its own (amounts in and out), or
-- a flow typed over a scanned line.

local common = require("scripts.gui.common")
local rows = require("scripts.gui.rows")
local editor = require("scripts.gui.editor")
local model = require("scripts.model")
local draft = require("scripts.draft")

local L = common.L
local handlers = common.handlers

local line_dialog = {}

rows.targets.dialog = {
  rows = function(player)
    local state = model.player(player.index)
    return state.dialog and state.dialog.rows or {}
  end,
  field = "amount",
  allow_negative = true,
  changed = function(player, structural)
    if structural then line_dialog.build(player) end
  end,
}

--- Dialog for a custom line (new) or a flow override of an existing line.
--- @param dlg table? its state; nil rebuilds the open one
function line_dialog.build(player, dlg)
  dlg = dlg or model.player(player.index).dialog
  if not dlg then return end
  local ctx = common.ctx(player)
  local frame = common.open_dialog(player, "line", L(dlg.kind == "override" and "edit-flow" or "add-custom"), dlg)
  local outer = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  local body = outer.add({ type = "flow", direction = "vertical" })
  body.style.vertical_spacing = 8
  local top = body.add({ type = "flow", direction = "horizontal" })
  top.add({ type = "label", caption = L("line-label") })
  local label = top.add({ type = "textfield", text = dlg.label or "", tags = { fp = "dlg_label" } })
  label.style.width = 200
  body.add({ type = "label", caption = L(dlg.kind == "override" and "override-explain" or "custom-explain"), style = "info_label" })
  rows.build(body, player, "dialog", ctx, true)
  local buttons = common.dialog_buttons(frame)
  buttons.add({ type = "button", caption = L("cancel"), style = "back_button", tags = { fp = "dialog_close" } })
  common.spacer(buttons)
  buttons.add({ type = "button", caption = L(dlg.kind == "override" and "apply" or "add"), style = "confirm_button", tags = { fp = "dlg_line_ok" } })
end

handlers.dlg_label = { text = function(player, element, event)
  local state = model.player(player.index)
  if state.dialog then state.dialog.label = element.text end
end }

handlers.editor_add_custom = function(player)
  line_dialog.build(player, { kind = "custom", label = "", rows = { {} } })
end

handlers.editor_edit_flow = editor.with_draft(function(player, element, _, d)
  local line = editor.find_line(d, element.tags.line)
  if not line then return end
  line_dialog.build(player, { kind = "override", line = line.id, label = line.label or "", rows = draft.rows_from_flow(line) })
end)

handlers.dlg_line_ok = function(player)
  local state = model.player(player.index)
  local dlg = state.dialog
  local d = editor.get_draft(player)
  if not (dlg and d) then return end
  if dlg.kind == "override" then
    local line = editor.find_line(d, dlg.line)
    if line then
      draft.set_flow(line, dlg.rows)
      line.overridden = line.kind ~= "custom"
      if dlg.label ~= "" then line.label = dlg.label end
    end
  else
    draft.add_custom_line(d.factory, dlg.label ~= "" and dlg.label or "custom", dlg.rows)
  end
  common.close_dialog(player)
  editor.rebalance(player)
  editor.rebuild(player)
end

return line_dialog
