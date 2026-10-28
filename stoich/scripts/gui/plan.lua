-- Plan tab: what to build next. Status, sinks, plan splits, the shortage table
-- and the problems list.

local common = require("scripts.gui.common")
local window = require("scripts.gui.window")
local splits = require("scripts.gui.splits")
local problems = require("scripts.gui.problems")
local editor = require("scripts.gui.editor")
local model = require("scripts.model")
local plan = require("scripts.plan")
local draft = require("scripts.draft")
local belts = require("scripts.belts")
local solver = require("scripts.solver")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local plan_tab = {}

local function result()
  local p = model.plan()
  return p.result or plan.rebalance()
end

--- Plan units: one per usable factory/sink, as the solver saw them.
local function units()
  local out = {}
  for _, id in ipairs(model.factory_ids()) do
    local f = model.get(id)
    if plan.usable(f) then
      out[#out + 1] = { id = id, flow = f.kind == "sink" and plan.sink_flow(f) or f.result.net, count = f.copies or 1 }
    end
  end
  return out
end

local function matches(f, filter)
  if filter == "" then return true end
  local q = filter:lower()
  if (f.name or ""):lower():find(q, 1, true) then return true end
  for key in pairs(f.result and f.result.net or {}) do
    local _, n = fp_util.parse_key(key)
    if n:lower():find(q, 1, true) then return true end
  end
  return false
end

-- Sections ------------------------------------------------------------------------------------

local function build_header(parent, player, r, ctx)
  local bar = parent.add({ type = "frame", style = "subheader_frame", direction = "horizontal" })
  bar.style.horizontally_stretchable = true
  bar.style.height = 40
  bar.style.vertical_align = "center"
  -- an empty plan has no status worth showing
  if #(r.order or {}) > 0 or next(model.plan().factories) then
    common.status_label(bar, r.status)
    local n = problems.count(r)
    if n > 0 then bar.add({ type = "label", caption = L("status-problems", n) }) end
  end
  common.spacer(bar)
  bar.add({ type = "sprite-button", style = "tool_button", sprite = "utility/refresh", tooltip = L("recalculate"), tags = { fp = "plan_recalculate" } })
end

local function build_sinks(parent, player, ctx)
  local ids = {}
  for _, id in ipairs(model.factory_ids()) do
    if model.get(id).kind == "sink" then ids[#ids + 1] = id end
  end
  if #ids == 0 then return end
  parent.add({ type = "label", caption = { "", L("section-sinks"), " (", common.unit_suffix(ctx), ")" }, style = "caption_label" })
  -- top-aligned rows: a sink whose rates wrap keeps its name next to the first row
  local t = parent.add({ type = "table", column_count = 4, vertical_centering = false })
  t.style.horizontal_spacing = 10
  t.style.vertical_spacing = 6
  for _, id in ipairs(ids) do
    local f = model.get(id)
    -- nudged down to the centre line of the first row of rate fields
    local icon = t.add({ type = "sprite", sprite = common.factory_sprite(f) })
    icon.style.top_margin = 2
    local name = t.add({ type = "label", caption = f.name, style = "bold_label" })
    name.style.minimal_width = 120
    name.style.top_margin = 4
    -- each item is one unit (icon + rate), with a clear gap between units; they wrap
    -- onto more rows so a long sink doesn't widen the window
    local per_row = model.player(player.index).compact and 4 or 8
    local grid = t.add({ type = "table", column_count = per_row })
    grid.style.horizontal_spacing = 16
    grid.style.vertical_spacing = 4
    for i, row in ipairs(f.sink_items or {}) do
      if row.key then
        local unit = grid.add({ type = "flow", direction = "horizontal" })
        unit.style.vertical_align = "center"
        unit.style.horizontal_spacing = 4
        unit.add({ type = "sprite", sprite = common.key_sprite(row.key), tooltip = fp_util.localised(row.key) })
        common.number_field(unit, common.from_per_second(ctx, row.rate or 0), { fp = "plan_sink_rate", id = id, i = i },
          { width = 64, enabled = ctx.can_edit, tooltip = { "", fp_util.localised(row.key), "\n", L("sink-rate-tooltip", common.unit_suffix(ctx)) } })
      end
    end
    local buttons = t.add({ type = "flow", direction = "horizontal" })
    buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/rename_icon", tooltip = L("edit"),
      tags = { fp = "fac_edit", id = id } })
    buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/trash", tooltip = L("delete"),
      enabled = ctx.can_edit, tags = { fp = "fac_delete", id = id } })
  end
end

-- In the Plan tab only a summary; the cards live in the Splits tab.
local function build_splits(parent, player)
  local p = model.plan()
  if #p.splits == 0 then return end
  local row = parent.add({ type = "flow", direction = "horizontal" })
  row.style.vertical_align = "center"
  row.style.horizontal_spacing = 8
  row.add({ type = "label", caption = L("section-plan-splits"), style = "caption_label" })
  for _, split in ipairs(p.splits) do
    local n = 0
    for _ in pairs(split.shares) do n = n + 1 end
    row.add({ type = "sprite", sprite = common.key_sprite(split.item), tooltip = fp_util.localised(split.item) })
    row.add({ type = "label", caption = L("split-summary", fp_util.localised(split.item), n) })
  end
  row.add({ type = "button", caption = L("open-splits"), tags = { fp = "open_splits_tab" } })
end

--- Splits tab: one card per plan split, with the needed count of each factory.
function plan_tab.build_splits_tab(player, parent, ctx)
  parent.add({ type = "label", caption = L("splits-explain"), style = "info_label" }).style.single_line = false
  local p = model.plan()
  if #p.splits == 0 then
    parent.add({ type = "label", caption = L("no-plan-splits") })
    return
  end
  local pane = parent.add({ type = "scroll-pane", style = "scroll_pane" })
  pane.style.vertically_stretchable = true
  pane.style.horizontally_stretchable = true
  local box = pane.add({ type = "table", name = "stoich_plan_splits", column_count = 2 })
  box.style.horizontal_spacing = 12
  box.style.vertical_spacing = 12
  for i, split in ipairs(p.splits) do splits.build_card(box, player, "plan", i, split) end
end

window.builders.splits = plan_tab.build_splits_tab

local function build_table(parent, player, r, ctx)
  local state = model.player(player.index)
  local box = parent.add({ type = "flow", name = "stoich_plan_table_box", direction = "vertical" })
  local filters = box.add({ type = "flow", direction = "horizontal" })
  filters.style.vertical_align = "center"
  filters.add({ type = "label", caption = L("filter") })
  local filter = filters.add({ type = "textfield", text = state.filter or "", tags = { fp = "plan_filter" }, tooltip = L("filter-tooltip") })
  filter.style.width = 160
  filters.add({ type = "checkbox", caption = L("hide-ok"), state = state.hide_ok or false, tags = { fp = "plan_hide_ok" } })
  box.add({ type = "flow", name = "stoich_plan_rows", direction = "vertical" })
  plan_tab.fill_rows(player, box.stoich_plan_rows, r, ctx)
end

function plan_tab.fill_rows(player, holder, r, ctx)
  holder.clear()
  local state = model.player(player.index)
  local filter = state.filter or ""
  local order = r.order or {}
  if #order == 0 then
    holder.add({ type = "label", caption = L("plan-empty") })
    return
  end
  local pane = holder.add({ type = "scroll-pane", style = "scroll_pane" })
  pane.style.vertically_stretchable = true
  pane.style.horizontally_stretchable = true
  -- fixed column widths (only the name stretches), so the table also fits the compact window
  local t = pane.add({ type = "table", column_count = 10, draw_horizontal_lines = true })
  t.style.horizontally_stretchable = true
  t.style.horizontal_spacing = 14
  t.style.column_alignments[4] = "right"
  t.style.column_alignments[5] = "right"
  local heads = {
    { "", 24 }, { "col-name", nil }, { "col-copies", 80 }, { "col-needed", 64 }, { "col-shortage", 70 },
    { "col-progress", 96 }, { "", 24 }, { "col-pin", 40 }, { "", 28 }, { "", 28 },
  }
  for _, h in ipairs(heads) do
    local head
    if h[1] == "" then head = t.add({ type = "empty-widget" }) else
      head = t.add({ type = "label", caption = L(h[1]), style = "bold_label", tooltip = L(h[1] .. "-tooltip") })
    end
    if h[2] then head.style.width = h[2] else head.style.horizontally_stretchable = true end
  end
  local shown = 0
  local names = common.factory_names(ctx)
  for _, id in ipairs(order) do
    local f = model.get(id)
    local shortage = r.shortage[id]
    local class = plan.shortage_class(shortage)
    if f and matches(f, filter) and not (state.hide_ok and class == "ok") then
      shown = shown + 1
      t.add({ type = "sprite", sprite = common.factory_sprite(f) })
      local name = t.add({ type = "label", caption = names[id], tooltip = common.flow_tooltip(ctx, f.result.net, L("per-copy")) })
      name.style.maximal_width = 360
      local copies = t.add({ type = "flow", direction = "horizontal" })
      copies.style.vertical_align = "center"
      copies.add({ type = "button", caption = "−", style = "mini_button", enabled = ctx.can_edit, tags = { fp = "plan_copies", id = id, delta = -1 } })
      local c = copies.add({ type = "label", caption = fp_util.format_count(f.copies) })
      c.style.minimal_width = 28
      c.style.horizontal_align = "center"
      copies.add({ type = "button", caption = "+", style = "mini_button", enabled = ctx.can_edit, tags = { fp = "plan_copies", id = id, delta = 1 } })
      local needed = r.counts[id]
      local known = needed ~= nil and not r.undetermined[id]
      t.add({ type = "label", caption = known and fp_util.format_count(needed) or "?" })
      -- whole copies still to build; never below 0, green when covered; the exact need in the tooltip
      local caption, tip = "?", nil
      if shortage and known then
        caption = class == "short" and ("+" .. math.ceil(shortage - 1e-6)) or "0"
        local covered = needed > 0 and math.min(100, math.floor(100 * f.copies / needed + 0.5)) or 100
        tip = L("shortage-tooltip", fp_util.format_count(needed), fp_util.format_count(f.copies),
          fp_util.format_count(math.max(0, shortage)), covered)
        if shortage < -0.005 then tip = { "", tip, "\n", L("surplus-tooltip", fp_util.format_count(-shortage)) } end
      end
      local sl = t.add({ type = "label", caption = caption, style = "bold_label", tooltip = tip })
      if known and class == "short" then sl.style.font_color = common.RED
      elseif known and class == "ok" then sl.style.font_color = common.GREEN end
      if known then
        local bar = t.add({ type = "progressbar", value = needed > 0 and math.min(1, f.copies / needed) or 1, tooltip = tip })
        bar.style.width = 90
        -- same colours as the shortage: red short, green covered
        bar.style.color = class == "short" and common.RED or common.GREEN
      else
        t.add({ type = "empty-widget" }) -- no coverage to show while the need is unknown
      end
      local chokes = plan.chokes(f, ctx.tiers, ctx.max_index, ctx.one_lane, belts)
      if #chokes > 0 then
        local ctip = { "", L("chokes") }
        for i, ch in ipairs(chokes) do
          if i <= 6 then ctip[#ctip + 1] = { "", "\n", fp_util.rich(ch.item), " ", fp_util.format_rate(ch.rate, ctx.unit, true), " = ", fp_util.format_count(ch.check.belts), "×[entity=" .. ch.check.tier.name .. "]" } end
        end
        t.add({ type = "sprite", sprite = "utility/warning_icon", tooltip = ctip })
      else
        t.add({ type = "empty-widget" })
      end
      t.add({ type = "checkbox", state = f.pinned or false, enabled = ctx.can_edit, tooltip = L("pinned-tooltip"), tags = { fp = "plan_pin", id = id } })
      t.add({ type = "sprite-button", style = "tool_button", sprite = "utility/rename_icon", tooltip = L("edit"), tags = { fp = "fac_edit", id = id } })
      -- delete lives in the Factories tab
      t.add({ type = "sprite-button", style = "tool_button", sprite = "utility/center", tooltip = L("show-on-map"), enabled = f.source ~= nil,
        tags = { fp = "show_map", id = id } })
    end
  end
  if shown == 0 then holder.add({ type = "label", caption = L("plan-filtered") }) end
end

local function build_problems(box, player, r, ctx)
  if #r.problems > 0 then problems.render(box, player, "plan", r, ctx) end
  if r.excluded and #r.excluded > 0 then
    local names = { "" }
    for i, id in ipairs(r.excluded) do
      if i <= 10 then
        local f = model.get(id)
        if i > 1 then names[#names + 1] = ", " end
        names[#names + 1] = f and f.name or "?"
      end
    end
    box.add({ type = "label", caption = L("excluded", names), style = "info_label" })
  end
end

local function section(parent, name)
  local box = parent.add({ type = "flow", name = name, direction = "vertical" })
  box.style.vertical_spacing = 6
  box.style.horizontally_stretchable = true
  return box
end

function plan_tab.build(player, parent, ctx)
  local r = result()
  build_header(section(parent, "stoich_plan_header"), player, r, ctx)
  -- problems first: they are what needs doing
  build_problems(section(parent, "stoich_plan_problems"), player, r, ctx)
  build_sinks(section(parent, "stoich_plan_sinks"), player, ctx)
  build_splits(section(parent, "stoich_plan_splits_box"), player)
  build_table(section(parent, "stoich_plan_main"), player, r, ctx)
end

window.builders.plan = plan_tab.build

--- Refresh for the player who moved a plan split slider: rebuild everything
--- except the split cards, which are updated in place.
function plan_tab.refresh_except_splits(player, index, line)
  -- the cards are in the Splits tab now: update them (and their needed counts) in place
  local w = window.get(player)
  local root = w and w.stoich_inner.stoich_tabs.stoich_content_splits
  if not root then return end
  for i in ipairs(model.plan().splits) do splits.update_card(root, player, "plan", i, i == index and line or nil) end
end

-- Targets for split cards and problems ------------------------------------------------------------

splits.targets.plan = {
  holder = function() return model.plan() end,
  units = function() return units() end,
  counts = function() return result().counts end,
  name_of = function(player, id)
    return common.factory_names(common.ctx(player))[id] or tostring(id)
  end,
  extra_of = function(_, id)
    local r = result()
    local needed = r.counts[id]
    if needed == nil or r.undetermined[id] then return L("needed-unknown") end
    return L("needed-count", fp_util.format_count(needed))
  end,
  sprite_of = function(_, id)
    local f = model.get(id)
    return f and common.factory_sprite(f) or "utility/missing_icon"
  end,
  changed = function(player, structural, index, line)
    if structural then
      plan.changed()
    else
      plan.changed({ except = player.index })
      plan_tab.refresh_except_splits(player, index, line)
    end
  end,
  can_edit = function(player) return model.can_edit(player) end,
}

problems.actions.plan = {
  mark_external = function(player, item)
    model.plan().external[item] = true
    model.log(player.index, { "stoich.log-external", fp_util.rich(item) }, nil)
    plan.changed()
  end,
  add_sink = function(player, item)
    local f = draft.new_sink()
    f.name = fp_util.pretty_name(select(2, fp_util.parse_key(item)))
    f.sink_items[1] = { key = item, rate = 0 }
    local t, n = fp_util.parse_key(item)
    if t == "item" or t == "fluid" then f.icon = { type = t, name = n } end
    draft.sync_sink(f)
    editor.open_factory(player, f, { translate = item })
  end,
  add_split = function(player, item)
    local list = units()
    draft.add_split(model.plan(), item, solver.producers_of(list, item), list)
    model.log(player.index, { "stoich.log-plan-split", fp_util.rich(item) }, nil)
    plan.changed()
    window.select_tab(player, "splits")
  end,
  show_item = function(player, item)
    local state = model.player(player.index)
    state.expanded = state.expanded or {}
    state.expanded[item] = true
    state.focus_item = item
    window.select_tab(player, "items")
  end,
}

-- Handlers ------------------------------------------------------------------------------------------

handlers.open_splits_tab = function(player)
  window.select_tab(player, "splits")
end

handlers.plan_recalculate = function()
  plan.changed()
end

handlers.plan_copies = function(player, element)
  if not model.can_edit(player) then return end
  local f = model.get(element.tags.id)
  if not f then return end
  if model.set_copies(f.id, (f.copies or 0) + element.tags.delta, player.index) then plan.changed() end
end

handlers.plan_pin = function(player, element)
  if not model.can_edit(player) then return end
  if model.set_pinned(element.tags.id, element.state, player.index) then plan.changed() end
end

handlers.plan_filter = function(player, element, event)
  if event.name ~= defines.events.on_gui_text_changed then return end
  local state = model.player(player.index)
  state.filter = element.text
  local w = window.get(player)
  local rows = w and common.find(w, "stoich_plan_rows")
  if rows then plan_tab.fill_rows(player, rows, result(), common.ctx(player)) end
end

handlers.plan_hide_ok = function(player, element)
  local state = model.player(player.index)
  state.hide_ok = element.state
  local w = window.get(player)
  local rows = w and common.find(w, "stoich_plan_rows")
  if rows then plan_tab.fill_rows(player, rows, result(), common.ctx(player)) end
end

handlers.plan_sink_rate = function(player, element, event)
  if event.name ~= defines.events.on_gui_confirmed then return end
  if not model.can_edit(player) then return end
  local f = model.get(element.tags.id)
  local v = fp_util.parse_number(element.text)
  if not (f and v and f.sink_items and f.sink_items[element.tags.i]) then return end
  f.sink_items[element.tags.i].rate = math.abs(common.to_per_second(common.ctx(player), v))
  draft.sync_sink(f)
  plan.balance_factory(f)
  f.revision = f.revision + 1
  f.modified_by = player.index
  f.modified_tick = game.tick
  model.log(player.index, { "stoich.log-rate" }, f.name)
  plan.changed()
end

return plan_tab
