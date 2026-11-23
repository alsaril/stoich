-- Notices above the plan table: something changed the plan's numbers outside the editor
-- (research, a mod update) and a player can take it in with one click. Each reason is a
-- provider; the rescanning feature can add its own.

local common = require("scripts.gui.common")
local window = require("scripts.gui.window")
local model = require("scripts.model")
local plan = require("scripts.plan")
local research = require("scripts.research")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local notices = {}

--- Providers in display order: fn(player, ctx) -> nil or
--- { caption, tooltip?, button = { caption, tooltip?, tags } (only for players who can edit) }.
notices.providers = {}

local MAX_LISTED = 10

local function count_text(v)
  return v and fp_util.format_count(v) or "?"
end

-- research (or a mod update) changed what captured or hand-added lines make
notices.providers[#notices.providers + 1] = function(player, ctx)
  local pending = storage.pending and storage.pending[ctx.plan]
  if not (pending and #pending.factories > 0) then return nil end
  local tip = { "", L("research-changes-tooltip") }
  for i, entry in ipairs(pending.factories) do
    if i > MAX_LISTED then
      tip[#tip + 1] = { "", "\n", L("research-changes-more", #pending.factories - MAX_LISTED) }
      break
    end
    tip[#tip + 1] = { "", "\n", L("research-change", entry.name or "?", count_text(entry.before), count_text(entry.after)) }
  end
  -- a LocalisedString takes 20 parameters: the entries are nested in pairs
  if #tip > 20 then
    local folded = { "" }
    for i = 2, #tip, 2 do folded[#folded + 1] = { "", tip[i], tip[i + 1] or "" } end
    tip = folded
  end
  return {
    caption = L("research-changes", #pending.factories),
    tooltip = tip,
    button = { caption = L("update-all"), tooltip = L("update-all-tooltip"), tags = { fp = "notice_update_all" } },
  }
end

--- Draw the notices (nothing when there are none).
--- @return integer how many
function notices.render(parent, player, ctx)
  local count = 0
  for _, provider in ipairs(notices.providers) do
    local n = provider(player, ctx)
    if n then
      count = count + 1
      local row = parent.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "horizontal" })
      row.style.horizontally_stretchable = true
      row.style.vertical_align = "center"
      local icon = row.add({ type = "sprite", sprite = "utility/tip_icon", tooltip = n.tooltip })
      icon.style.size = 16
      icon.style.stretch_image_to_widget_size = true
      local label = row.add({ type = "label", caption = n.caption, tooltip = n.tooltip })
      label.style.single_line = false
      common.spacer(row)
      if n.button and ctx.can_edit then
        row.add({ type = "button", caption = n.button.caption, tooltip = n.button.tooltip, tags = n.button.tags })
      end
    end
  end
  return count
end

handlers.notice_update_all = function(player)
  if not model.can_edit(player) then return end
  local key = model.selected(player.index)
  research.apply_pending(key, player.index)
  if storage.pending then storage.pending[key] = nil end
  window.plan_changed(key)
end

return notices
