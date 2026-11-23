-- The factory editor's items panel: what comes in, what goes out, what is made and used up
-- inside, each item with its External toggle (and its qualities under it).

local common = require("scripts.gui.common")
local plan = require("scripts.plan")
local conditions = require("scripts.conditions")
local fp_util = require("scripts.util")

local L = common.L

local editor_items = {}

-- Items of the factory in three groups: what comes in, what goes out, and what
-- is made and used up inside. Each item can be marked external.
local ITEM_GROUPS = {
  { key = "inputs", caption = "items-inputs", tooltip = "items-inputs-tooltip" },
  { key = "outputs", caption = "items-outputs", tooltip = "items-outputs-tooltip" },
  { key = "inside", caption = "items-inside", tooltip = "items-inside-tooltip" },
  { key = "unused", caption = "items-not-used", tooltip = "items-not-used-tooltip", optional = true },
}

--- Fill the items panel of a draft.
function editor_items.render(box, player, d, ctx)
  box.clear()
  local f = d.factory
  local r = f.result
  local fluid_keys = plan.fluid_keys(f)
  local groups = { inputs = {}, outputs = {}, inside = {}, unused = {} }
  for _, entry in ipairs(r.flow) do
    local net = r.net[entry.item]
    local g
    if net then
      g = net > 0 and "outputs" or "inputs"
    elseif entry.total <= 1e-9 then
      g = "unused" -- nothing makes or uses it at this split (e.g. a recipe at 0%)
    else
      g = "inside"
    end
    table.insert(groups[g], entry.item)
  end
  -- one table, so the columns (and the External checkboxes) line up across the groups:
  -- icon, item, rate, belt, fill, external; a heading row per group
  local t = box.add({ type = "table", name = "stoich_items_table", column_count = 6 })
  t.style.horizontal_spacing = 6
  t.style.vertical_spacing = 2
  t.add({ type = "empty-widget" })
  t.add({ type = "label", caption = L("col-item"), style = "bold_label" })
  local rate_head = t.add({ type = "label", caption = { "", L("row-rate"), " (", common.unit_suffix(ctx), ")" }, style = "bold_label" })
  rate_head.style.width = 80
  rate_head.style.horizontal_align = "right"
  rate_head.style.single_line = true
  t.add({ type = "label", caption = L("col-belt"), style = "bold_label", tooltip = L("col-belt-tooltip") }).style.width = common.BELT_WIDTH
  local fill_head = t.add({ type = "label", caption = L("col-fill"), style = "bold_label", tooltip = L("col-fill-tooltip") })
  fill_head.style.width = common.FILL_WIDTH
  fill_head.style.horizontal_align = "right"
  local ext_head = t.add({ type = "label", caption = L("col-external"), style = "bold_label", tooltip = L("col-external-tooltip") })
  ext_head.style.single_line = true
  ext_head.style.minimal_width = 60 -- single-line labels would otherwise shrink to "Exte…"
  local quality = plan.has_quality(d.plan) or conditions.factory_has_quality(f)
  d.items_open = d.items_open or {}
  -- an item of several tiers: one row (their total), opening to a row per tier
  local function base_row(keys)
    local base = fp_util.base_key(keys[1])
    local icon = common.item_icon(t, { type = "sprite-button", style = "transparent_slot", tooltip = common.keys_name(keys) }, keys)
    icon.style.size = 28
    local cell = t.add({ type = "flow", direction = "horizontal" })
    cell.style.vertical_align = "center"
    local open = d.items_open[base]
    cell.add({ type = "sprite-button", style = "mini_button", sprite = open and "utility/collapse" or "utility/expand",
      tooltip = L("quality-tiers", #keys), tags = { fp = "editor_items_toggle", item = base } })
    local name = cell.add({ type = "label", caption = common.keys_name(keys) })
    name.style.maximal_width = 200
    local total, any_net, all_external = 0, false, true
    for _, key in ipairs(keys) do
      if r.net[key] then
        total = total + math.abs(r.net[key])
        any_net = true
      end
      if not f.external[key] then all_external = false end
    end
    if any_net then
      common.rate_cells(t, ctx, total, keys[1], fluid_keys, nil, 80)
    else
      local dash = t.add({ type = "label", caption = "—", tooltip = L("balanced-inside") })
      dash.style.width = 80
      dash.style.horizontal_align = "right"
      t.add({ type = "empty-widget" })
      t.add({ type = "empty-widget" })
    end
    local ext = t.add({ type = "checkbox", state = all_external, enabled = ctx.can_edit,
      tooltip = { "", L("col-external-tooltip"), "\n", L("external-all-tiers") }, tags = { fp = "editor_external", item = keys[1], keys = keys } })
    ext.style.left_margin = 16
    return open
  end
  local function item_row(key, indent)
    if quality then
      local icon = common.item_icon(t, { type = "sprite-button", style = "transparent_slot", tooltip = fp_util.localised(key) }, { key })
      icon.style.size = 28
    else
      t.add({ type = "sprite", sprite = common.key_sprite(key), tooltip = fp_util.localised(key) })
    end
    local name = t.add({ type = "label", caption = fp_util.localised(key) })
    name.style.maximal_width = 200
    if indent then name.style.left_padding = 24 end
    local net = r.net[key]
    if net then
      -- the group says which way it goes: no minus sign on inputs
      common.rate_cells(t, ctx, math.abs(net), key, fluid_keys, nil, 80)
    else
      local dash = t.add({ type = "label", caption = "—", tooltip = L("balanced-inside") })
      dash.style.width = 80
      dash.style.horizontal_align = "right"
      t.add({ type = "empty-widget" })
      t.add({ type = "empty-widget" })
    end
    local suggested = r.suggested_external[key]
    local ext = t.add({
      type = "checkbox", state = f.external[key] and true or false, enabled = ctx.can_edit,
      tooltip = suggested and { "", L("col-external-tooltip"), "\n", L("suggested-tooltip") } or L("col-external-tooltip"),
      tags = { fp = "editor_external", item = key },
    })
    ext.style.left_margin = 16
  end
  for _, group in ipairs(ITEM_GROUPS) do
    if not (group.optional and #groups[group.key] == 0) then
      t.add({ type = "empty-widget" })
      local count = #groups[group.key]
      local by_base = quality and common.by_base(groups[group.key]) or nil
      if by_base then count = #by_base end
      local head = t.add({ type = "label", caption = { "", L(group.caption), " (" .. count .. ")" }, style = "caption_label",
        tooltip = L(group.tooltip) })
      head.style.top_margin = 6
      for _ = 1, 4 do t.add({ type = "empty-widget" }) end
      local list = groups[group.key]
      if by_base then
        -- tiers of an item together; a single tier as its own row
        list = {}
        for _, g in ipairs(by_base) do
          if #g.keys == 1 then
            list[#list + 1] = g.keys[1]
          else
            list[#list + 1] = g
          end
        end
      end
      for _, item in ipairs(list) do
        if type(item) == "table" then
          -- several tiers: their row, then a row per tier when it is open
          if base_row(item.keys) then
            for _, k in ipairs(item.keys) do item_row(k, true) end
          end
        else
          item_row(item)
        end
      end
    end
  end
end

return editor_items
