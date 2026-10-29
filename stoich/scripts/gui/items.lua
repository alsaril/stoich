-- Statistics window: the plan's flow view. Every item with its total flow; expand
-- one to see its producers and consumers and what is left over or missing.

local common = require("scripts.gui.common")
local window = require("scripts.gui.window")
local editor = require("scripts.gui.editor")
local model = require("scripts.model")
local plan = require("scripts.plan")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local items = {}

local function plan_fluid_keys()
  local set = {}
  for _, id in ipairs(model.factory_ids()) do
    for k in pairs(plan.fluid_keys(model.get(id))) do set[k] = true end
  end
  return set
end

-- Column widths of the items table.
local W = { toggle = 28, name = 190, share = 160, info = 150 }

local function cell_label(t, caption, width, opts)
  opts = opts or {}
  local label = t.add({ type = "label", caption = caption, style = opts.style, tooltip = opts.tooltip })
  label.style.width = width
  label.style.single_line = true
  if opts.right then label.style.horizontal_align = "right" end
  return label
end

-- Belts are shown for the total (plan-wide, may span several belts); a single copy's
-- belts belong to the factory's design and show in the editor.
local function total_cells(t, ctx, rate, key, fluid_keys)
  return common.rate_cells(t, ctx, rate, key, fluid_keys, nil, nil, { total = true })
end

function items.build(player, parent, ctx)
  local r = model.plan().result or plan.rebalance()
  local state = model.player(player.index)
  state.expanded = state.expanded or {}
  local fluid_keys = plan_fluid_keys()

  local bar = parent.add({ type = "flow", direction = "horizontal" })
  bar.style.vertical_align = "center"
  bar.add({ type = "label", caption = L("items-explain"), style = "info_label" })
  common.spacer(bar)
  bar.add({ type = "button", caption = L("collapse-all"), tags = { fp = "items_collapse" } })

  -- items with no flow at the needed counts (e.g. a factory the plan doesn't need) are left out
  local entries, unused = {}, 0
  for _, entry in ipairs(r.flow) do
    if entry.total > 1e-9 then entries[#entries + 1] = entry else unused = unused + 1 end
  end
  if unused > 0 then parent.add({ type = "label", caption = L("items-unused", unused), style = "info_label" }) end
  if #entries == 0 then
    parent.add({ type = "label", caption = L("plan-empty") })
    return
  end
  local pane = parent.add({ type = "scroll-pane", name = "stoich_items_pane", style = "scroll_pane" })
  pane.style.vertically_stretchable = true
  pane.style.horizontally_stretchable = true
  local t = pane.add({ type = "table", name = "stoich_items_table", column_count = 7 })
  t.style.horizontal_spacing = 12
  t.style.vertical_spacing = 2
  t.add({ type = "empty-widget" }).style.width = W.toggle
  cell_label(t, L("col-item"), W.name, { style = "bold_label" })
  cell_label(t, { "", L("col-total"), " (", common.unit_suffix(ctx), ")" }, common.RATE_WIDTH, { style = "bold_label", right = true, tooltip = L("col-total-tooltip") })
  cell_label(t, L("col-belt"), common.BELT_WIDTH, { style = "bold_label", tooltip = L("col-belt-total-tooltip") })
  cell_label(t, L("col-fill"), common.FILL_WIDTH, { style = "bold_label", right = true, tooltip = L("col-fill-total-tooltip") })
  cell_label(t, L("col-share"), W.share, { style = "bold_label" })
  cell_label(t, "", W.info)

  local focus_element
  local names = common.factory_names(ctx)
  for _, entry in ipairs(entries) do
    local key = entry.item
    local open = state.expanded[key]
    -- item row
    t.add({ type = "sprite-button", style = "frame_action_button", sprite = open and "utility/collapse" or "utility/expand",
      tags = { fp = "items_toggle", item = key } })
    local name = t.add({ type = "flow", direction = "horizontal" })
    name.style.vertical_align = "center"
    name.style.width = W.name
    name.add({ type = "sprite", sprite = common.key_sprite(key) })
    local label = name.add({ type = "label", caption = fp_util.localised(key), style = "bold_label" })
    label.style.single_line = true
    total_cells(t, ctx, entry.total, key, fluid_keys)
    local producers, consumers = 0, 0
    for _, c in ipairs(entry.components) do
      if not c.virtual then
        if c.count > 0 then producers = producers + 1 elseif c.count < 0 then consumers = consumers + 1 end
      end
    end
    cell_label(t, L("producers-consumers", producers, consumers), W.share, { style = "info_label" })
    local info = ""
    if r.net[key] then info = L(r.net[key] > 0 and "net-output" or "net-input", fp_util.format_rate(math.abs(r.net[key]), ctx.unit, true)) end
    cell_label(t, info, W.info)
    if state.focus_item == key then focus_element = label end

    if open then
      for _, c in ipairs(entry.components) do
        t.add({ type = "empty-widget" })
        local src = t.add({ type = "flow", direction = "horizontal" })
        src.style.vertical_align = "center"
        src.style.width = W.name
        src.style.left_padding = 20
        if c.virtual then
          src.add({ type = "sprite", sprite = "utility/indication_arrow" })
          local v = src.add({ type = "label", caption = L("virtual-" .. c.source), style = "info_label" })
          v.style.single_line = true
          total_cells(t, ctx, c.count, key, fluid_keys)
        else
          local f = model.get(c.source)
          src.add({ type = "sprite", sprite = f and common.factory_sprite(f) or "utility/missing_icon" })
          src.add({ type = "button", caption = names[c.source] or "?", style = "list_box_item", tooltip = L("open-in-editor"),
            tags = { fp = "items_open", id = c.source } })
          total_cells(t, ctx, c.count, key, fluid_keys)
        end
        local share = t.add({ type = "flow", direction = "horizontal" })
        share.style.vertical_align = "center"
        share.style.width = W.share
        local pct = share.add({ type = "progressbar", value = math.min(1, math.abs(c.percent)) })
        pct.style.width = 100
        pct.style.color = c.count >= 0 and common.GREEN or common.BLUE
        share.add({ type = "label", caption = fp_util.format_count(100 * math.abs(c.percent)) .. "%" })
        cell_label(t, "", W.info)
      end
    end
  end
  if focus_element then
    pane.scroll_to_element(focus_element, "top-third")
    state.focus_item = nil
  end
end

--- Rebuild the open statistics window.
function items.refresh(player, ctx)
  local content = window.child_content(player, "stoich_stats")
  if not content then return end
  content.clear()
  items.build(player, content, ctx or common.ctx(player))
end

window.register_child("stoich_stats", {
  refresh = function(player, _, ctx) items.refresh(player, ctx) end,
  rebuild = items.refresh,
})

--- Open the statistics window (or bring it forward), optionally expanded and scrolled to an item.
function items.open(player, focus_item)
  local state = model.player(player.index)
  if focus_item then
    state.expanded = state.expanded or {}
    state.expanded[focus_item] = true
    state.focus_item = focus_item
  end
  window.open_child(player, "stoich_stats", L("statistics"),
    { width = window.SIZE.width, height = window.SIZE.height })
  items.refresh(player)
end

handlers.open_stats = function(player)
  items.open(player)
end

handlers.items_toggle = function(player, element)
  local state = model.player(player.index)
  state.expanded = state.expanded or {}
  local key = element.tags.item
  state.expanded[key] = not state.expanded[key] or nil
  state.focus_item = key
  items.refresh(player)
end

handlers.items_collapse = function(player)
  model.player(player.index).expanded = {}
  items.refresh(player)
end

handlers.items_open = function(player, element)
  editor.open_saved(player, element.tags.id)
end

return items
