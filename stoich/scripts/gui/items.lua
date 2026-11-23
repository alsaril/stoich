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

local function plan_fluid_keys(key)
  local set = {}
  for _, id in ipairs(model.factory_ids(key)) do
    for k in pairs(plan.fluid_keys(model.get(id))) do set[k] = true end
  end
  return set
end

-- Column widths of the items table.
local W = { toggle = 28, name = 190, share = 160, info = 150 }
local COLUMNS = 7 -- cells in a row of the items table

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

--- Cells added to a table at a place (at its end when nil): a toggle opens rows where they
--- belong without a rebuild, so the scroll pane stays where it is (a mod can't read or set a
--- scroll position, only scroll to an element).
local function cursor(t, index)
  local c = { at = index }
  function c.add(def)
    if c.at then
      def.index = c.at
      c.at = c.at + 1
    end
    return t.add(def)
  end
  return c
end

--- The rows of the items table: the plan's items (by base item with quality), what is open,
--- and a builder for each kind of row. Each row's first cell carries tags { row_key,
--- row_base, row_level = "top" | "tier" | "source" }, so a toggle finds it.
local function rows_of(player, ctx)
  local r = model.plan(ctx.plan).result or plan.rebalance(ctx.plan)
  local state = model.player(player.index)
  state.expanded = state.expanded or {}
  local fluid_keys = plan_fluid_keys(ctx.plan)
  local quality = plan.has_quality(ctx.plan)
  local only = quality and state.stats_quality or nil -- one tier, as production statistics
  -- items with no flow at the needed counts (e.g. a factory the plan doesn't need) are left out
  local entries, unused = {}, 0
  for _, entry in ipairs(r.flow) do
    if entry.total > 1e-9 then
      if not only or fp_util.quality_of(entry.item) == only then entries[#entries + 1] = entry end
    else
      unused = unused + 1
    end
  end
  local B = { state = state, quality = quality, only = only, entries = entries, unused = unused,
    entry_of = {}, group_of = {}, groups = {} }
  for _, entry in ipairs(entries) do B.entry_of[entry.item] = entry end
  if quality then
    -- by base item, in the order of their largest tier's flow
    for _, entry in ipairs(entries) do
      local base = fp_util.base_key(entry.item)
      if not B.group_of[base] then
        B.group_of[base] = { base = base, entries = {} }
        B.groups[#B.groups + 1] = B.group_of[base]
      end
      table.insert(B.group_of[base].entries, entry)
    end
    for _, group in ipairs(B.groups) do
      table.sort(group.entries, function(a, b) return fp_util.key_less(a.item, b.item) end)
    end
  end
  local names = common.factory_names(ctx)

  -- a plan with quality: one row per item, its tiers under it
  function B.base_row(T, group)
    local base = group.base
    local open = state.expanded["base:" .. base]
    T.add({ type = "sprite-button", style = "frame_action_button", sprite = open and "utility/collapse" or "utility/expand",
      tags = { fp = "items_toggle", item = base, base = true, row_key = base, row_base = true, row_level = "top" } })
    local name = T.add({ type = "flow", direction = "horizontal" })
    name.style.vertical_align = "center"
    name.style.width = W.name
    local keys = {}
    local total, net = 0, nil
    for _, entry in ipairs(group.entries) do
      keys[#keys + 1] = entry.item
      total = total + entry.total
      if r.net[entry.item] then net = (net or 0) + r.net[entry.item] end
    end
    local icon = common.item_icon(name, { type = "sprite-button", style = "transparent_slot", tooltip = common.keys_name(keys) }, keys)
    icon.style.size = 28
    local label = name.add({ type = "label", caption = fp_util.localised(base), style = "bold_label" })
    label.style.single_line = true
    -- tiers share a belt: the total of all of them
    total_cells(T, ctx, total, base, fluid_keys)
    cell_label(T, L("quality-tiers", #keys), W.share, { style = "info_label" })
    local info = ""
    if net and math.abs(net) > 1e-12 then info = L(net > 0 and "net-output" or "net-input", fp_util.format_rate(math.abs(net), ctx.unit, true)) end
    cell_label(T, info, W.info)
    if state.focus_item and fp_util.base_key(state.focus_item) == base then B.focus = label end
    return open
  end

  function B.item_row(T, entry, indent)
    local key = entry.item
    local open = state.expanded[key]
    -- a quality under its item has its toggle in the name cell, under the item's icon, so it
    -- reads as nested (its sources are indented from there)
    local toggle = { type = "sprite-button", style = "frame_action_button", sprite = open and "utility/collapse" or "utility/expand",
      tags = { fp = "items_toggle", item = key } }
    if indent then
      T.add({ type = "empty-widget", tags = { row_key = key, row_level = "tier" } })
    else
      toggle.tags.row_key, toggle.tags.row_level = key, "top"
      T.add(toggle)
    end
    local name = T.add({ type = "flow", direction = "horizontal" })
    name.style.vertical_align = "center"
    name.style.width = W.name
    if indent then name.add(toggle) end
    if quality then
      local icon = common.item_icon(name, { type = "sprite-button", style = "transparent_slot", tooltip = fp_util.localised(key) }, { key })
      icon.style.size = 28
    else
      name.add({ type = "sprite", sprite = common.key_sprite(key) })
    end
    local label = name.add({ type = "label", caption = fp_util.localised(key), style = "bold_label" })
    label.style.single_line = true
    total_cells(T, ctx, entry.total, key, fluid_keys)
    local producers, consumers = 0, 0
    for _, c in ipairs(entry.components) do
      if not c.virtual then
        if c.count > 0 then producers = producers + 1 elseif c.count < 0 then consumers = consumers + 1 end
      end
    end
    cell_label(T, L("producers-consumers", producers, consumers), W.share, { style = "info_label" })
    local info = ""
    if r.net[key] then info = L(r.net[key] > 0 and "net-output" or "net-input", fp_util.format_rate(math.abs(r.net[key]), ctx.unit, true)) end
    cell_label(T, info, W.info)
    if state.focus_item == key then B.focus = label end
    if open then B.sources(T, entry, indent) end
  end

  --- An item's producers and consumers, a row each.
  function B.sources(T, entry, indent)
    local key = entry.item
    for _, c in ipairs(entry.components) do
      T.add({ type = "empty-widget", tags = { row_level = "source" } })
      local src = T.add({ type = "flow", direction = "horizontal" })
      src.style.vertical_align = "center"
      src.style.width = W.name
      src.style.left_padding = indent and (20 + W.toggle) or 20
      if c.virtual then
        src.add({ type = "sprite", sprite = "utility/indication_arrow" })
        local v = src.add({ type = "label", caption = L("virtual-" .. c.source), style = "info_label" })
        v.style.single_line = true
        total_cells(T, ctx, c.count, key, fluid_keys)
      else
        -- a void or import shows under its own name: the item is the row's
        local id = plan.unit_owner(c.source)
        local f = model.get(id)
        if f then common.factory_icon(src, f) else src.add({ type = "sprite", sprite = "utility/missing_icon" }) end
        src.add({ type = "button", caption = names[id] or "?", style = "list_box_item", tooltip = L("open-in-editor"),
          tags = { fp = "items_open", id = id } })
        total_cells(T, ctx, c.count, key, fluid_keys)
      end
      local share = T.add({ type = "flow", direction = "horizontal" })
      share.style.vertical_align = "center"
      share.style.width = W.share
      local pct = share.add({ type = "progressbar", value = math.min(1, math.abs(c.percent)) })
      pct.style.width = 100
      pct.style.color = c.count >= 0 and common.GREEN or common.BLUE
      share.add({ type = "label", caption = fp_util.format_count(100 * math.abs(c.percent)) .. "%" })
      cell_label(T, "", W.info)
    end
  end

  --- A base item's qualities, a row each (with their sources when open).
  function B.tiers(T, group)
    for _, entry in ipairs(group.entries) do B.item_row(T, entry, true) end
  end

  function B.top_rows(T)
    if not quality then
      for _, entry in ipairs(entries) do B.item_row(T, entry) end
      return
    end
    for _, group in ipairs(B.groups) do
      if #group.entries == 1 then
        B.item_row(T, group.entries[1])
      elseif B.base_row(T, group) then
        B.tiers(T, group)
      end
    end
  end

  return B
end

function items.build(player, parent, ctx)
  local B = rows_of(player, ctx)
  local state, quality, only = B.state, B.quality, B.only
  local bar = parent.add({ type = "flow", direction = "horizontal" })
  bar.style.vertical_align = "center"
  bar.add({ type = "label", caption = L("items-explain"), style = "info_label" })
  common.spacer(bar)
  if quality then
    -- any quality (the default) or one, as production statistics filters (the game's quality
    -- chooser can't hold "any")
    local q = common.quality_dropdown(bar, player.force, only or common.EVERY_QUALITY, { fp = "items_quality" }, "any")
    q.tooltip = L("quality-filter-tooltip")
  end
  bar.add({ type = "button", caption = L("collapse-all"), tags = { fp = "items_collapse" } })

  if B.unused > 0 then parent.add({ type = "label", caption = L("items-unused", B.unused), style = "info_label" }) end
  if #B.entries == 0 then
    parent.add({ type = "label", caption = L("plan-empty") })
    return
  end
  local pane = parent.add({ type = "scroll-pane", name = "stoich_items_pane", style = "scroll_pane" })
  pane.style.vertically_stretchable = true
  pane.style.horizontally_stretchable = true
  local t = pane.add({ type = "table", name = "stoich_items_table", column_count = COLUMNS })
  t.style.horizontal_spacing = 12
  t.style.vertical_spacing = 2
  t.add({ type = "empty-widget" }).style.width = W.toggle
  cell_label(t, L("col-item"), W.name, { style = "bold_label" })
  cell_label(t, { "", L("col-total"), " (", common.unit_suffix(ctx), ")" }, common.RATE_WIDTH, { style = "bold_label", right = true, tooltip = L("col-total-tooltip") })
  cell_label(t, L("col-belt"), common.BELT_WIDTH, { style = "bold_label", tooltip = L("col-belt-total-tooltip") })
  cell_label(t, L("col-fill"), common.FILL_WIDTH, { style = "bold_label", right = true, tooltip = L("col-fill-total-tooltip") })
  cell_label(t, L("col-share"), W.share, { style = "bold_label" })
  cell_label(t, "", W.info)

  B.top_rows(cursor(t))
  if B.focus then
    pane.scroll_to_element(B.focus, "top-third")
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
    state.expanded["base:" .. fp_util.base_key(focus_item)] = true
    state.focus_item = focus_item
  end
  window.open_child(player, "stoich_stats", L("statistics"),
    { width = window.SIZE.width, height = window.SIZE.height })
  items.refresh(player)
end

handlers.open_stats = function(player)
  items.open(player)
end

-- A row's sub-rows: an item's sources; a base item's qualities and their sources.
local SUB = { item = { source = true }, base = { tier = true, source = true } }

--- Open or close a row where it is, so the scroll pane keeps its place.
--- @return boolean done (false: the row isn't there, rebuild)
local function toggle_in_place(player, key, base, open)
  local content = window.child_content(player, "stoich_stats")
  local t = content and common.find(content, "stoich_items_table")
  if not t then return false end
  local at
  for i, cell in ipairs(t.children) do
    local tags = cell.tags
    if tags.row_key == key and (tags.row_base == true) == (base == true) then
      at = i
      break
    end
  end
  if not at then return false end
  local tier = t.children[at].tags.row_level == "tier"
  local after = at + COLUMNS
  -- what is open under it goes
  local sub = SUB[base and "base" or "item"]
  while true do
    local cell = t.children[after]
    if not (cell and sub[cell.tags.row_level]) then break end
    for _ = 1, COLUMNS do t.children[after].destroy() end
  end
  if not open then return true end
  local B = rows_of(player, common.ctx(player))
  if base then
    local group = B.group_of[key]
    if not group then return false end
    B.tiers(cursor(t, after), group)
  else
    local entry = B.entry_of[key]
    if not entry then return false end
    B.sources(cursor(t, after), entry, tier)
  end
  return true
end

handlers.items_toggle = function(player, element)
  local state = model.player(player.index)
  state.expanded = state.expanded or {}
  local key, base = element.tags.item, element.tags.base
  local id = base and ("base:" .. key) or key
  local open = not state.expanded[id]
  state.expanded[id] = open or nil
  element.sprite = open and "utility/collapse" or "utility/expand"
  if not toggle_in_place(player, key, base, open) then items.refresh(player) end
end

handlers.items_quality = { selection = function(player, element)
  local q = element.tags.choices[element.selected_index]
  model.player(player.index).stats_quality = q ~= common.EVERY_QUALITY and q or nil
  items.refresh(player)
end }

handlers.items_collapse = function(player)
  model.player(player.index).expanded = {}
  items.refresh(player)
end

handlers.items_open = function(player, element)
  editor.open_saved(player, element.tags.id)
end

return items
