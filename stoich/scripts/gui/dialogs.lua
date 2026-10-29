-- Small dialogs of the main window's title bar: settings and the edit log.

local common = require("scripts.gui.common")
local model = require("scripts.model")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local dialogs = {}

-- Settings ------------------------------------------------------------------------------------

local function settings_dialog(player)
  local ctx = common.ctx(player)
  local frame = common.open_dialog(player, "settings", L("settings"))
  local body = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  local t = body.add({ type = "table", column_count = 2 })
  t.style.vertical_spacing = 8
  t.style.horizontal_spacing = 12

  -- the rate unit applies to every window; it lives here only
  t.add({ type = "label", caption = L("setting-unit") })
  local units, selected = {}, 2
  for i, u in ipairs(fp_util.UNIT_ORDER) do
    units[i] = fp_util.UNITS[u].suffix
    if u == ctx.unit then selected = i end
  end
  t.add({ type = "drop-down", name = "stoich_unit", items = units, selected_index = selected, tags = { fp = "set_unit" } })

  t.add({ type = "label", caption = L("setting-edit"), tooltip = L("setting-edit-tooltip") })
  t.add({
    type = "drop-down", items = { L("edit-everyone"), L("edit-admins") },
    selected_index = model.edit_mode() == "admins" and 2 or 1,
    enabled = player.admin, tags = { fp = "set_edit_mode" },
  })

  t.add({ type = "label", caption = L("setting-max-belt") })
  local items = { L("best-researched") }
  local current = settings.global["stoich-max-belt"].value
  local sel = 1
  for i, tier in ipairs(ctx.tiers) do
    items[#items + 1] = { "", "[entity=" .. tier.name .. "] ", common.entity_name(tier.name), " (" .. fp_util.format_number(tier.capacity) .. "/s)" }
    if tier.name == current then sel = i + 1 end
  end
  t.add({ type = "drop-down", items = items, selected_index = sel, enabled = ctx.can_edit, tags = { fp = "set_max_belt" } })

  t.add({ type = "label", caption = L("setting-one-lane") })
  t.add({ type = "checkbox", state = ctx.one_lane, enabled = ctx.can_edit, tags = { fp = "set_one_lane" } })
end

handlers.open_settings = function(player)
  settings_dialog(player)
end

handlers.set_unit = function(player, element)
  local u = fp_util.UNIT_ORDER[element.selected_index]
  if u then player.mod_settings["stoich-rate-unit"] = { value = u } end
end

handlers.set_edit_mode = function(player, element)
  if not player.admin then return end
  settings.global["stoich-edit-permission"] = { value = element.selected_index == 2 and "admins" or "everyone" }
  model.log(player.index, { "stoich.log-edit-mode", L("edit-" .. model.edit_mode()) }, nil)
end

handlers.set_max_belt = function(player, element)
  if not model.can_edit(player) then return end
  local tiers = common.ctx(player).tiers
  local i = element.selected_index
  settings.global["stoich-max-belt"] = { value = i > 1 and tiers[i - 1].name or "" }
end

handlers.set_one_lane = function(player, element)
  if not model.can_edit(player) then return end
  settings.global["stoich-one-lane"] = { value = element.state }
end

-- Edit log -------------------------------------------------------------------------------------

handlers.open_log = function(player)
  local frame = common.open_dialog(player, "log", L("log"))
  local pane = frame.add({ type = "scroll-pane", style = "scroll_pane" })
  pane.style.maximal_height = 500
  pane.style.minimal_width = 420
  if #storage.log == 0 then
    pane.add({ type = "label", caption = L("log-empty") })
    return
  end
  local t = pane.add({ type = "table", column_count = 4, draw_horizontal_lines = true })
  t.style.horizontal_spacing = 12
  for _, head in ipairs({ "log-when", "log-who", "log-what", "log-factory" }) do
    t.add({ type = "label", caption = L(head), style = "bold_label" })
  end
  for i = #storage.log, 1, -1 do
    local e = storage.log[i]
    t.add({ type = "label", caption = common.time_ago(e.tick) })
    t.add({ type = "label", caption = common.player_name(e.player) })
    t.add({ type = "label", caption = e.action })
    t.add({ type = "label", caption = e.factory or "" })
  end
end

--- Show the current rate unit in an open settings dialog (it can also change in the game's mod settings).
function dialogs.sync_unit(player)
  local d = player.gui.screen.stoich_dialog
  local dd = d and d.valid and common.find(d, "stoich_unit")
  if not dd then return end
  local unit = player.mod_settings["stoich-rate-unit"].value
  for i, u in ipairs(fp_util.UNIT_ORDER) do
    if u == unit then dd.selected_index = i end
  end
end

return dialogs
