-- The main window: every sink, plan split and factory, and what to build next.
-- Toolbar and status, problems, and one table with their flow, copies and
-- shortage. Also the split window, where one plan split is edited.

local common = require("scripts.gui.common")
local window = require("scripts.gui.window")
local splits = require("scripts.gui.splits")
local problems = require("scripts.gui.problems")
local editor = require("scripts.gui.editor")
local factories = require("scripts.gui.factories")
local items = require("scripts.gui.items")
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

local function key_matches(key, q)
  local _, n = fp_util.parse_key(key)
  return n:lower():find(q, 1, true) ~= nil
end

local function matches(f, filter)
  if filter == "" then return true end
  local q = filter:lower()
  if (f.name or ""):lower():find(q, 1, true) then return true end
  for key in pairs(f.result and f.result.net or {}) do
    if key_matches(key, q) then return true end
  end
  return false
end

local function split_index(item)
  for i, split in ipairs(model.plan().splits) do
    if split.item == item then return i end
  end
  return nil
end

-- Sections ------------------------------------------------------------------------------------

-- Toolbar on the left, the plan status on the right (as in the editor header).
local function build_header(parent, player, r, ctx)
  local bar = parent.add({ type = "frame", style = "subheader_frame", direction = "horizontal" })
  bar.style.horizontally_stretchable = true
  bar.style.height = 40
  bar.style.vertical_align = "center"
  factories.add_buttons(bar, ctx)
  common.spacer(bar)
  -- an empty plan has no status worth showing
  if next(model.plan().factories) then
    common.status_label(bar, r.status)
    local n = problems.count(r)
    if n > 0 then bar.add({ type = "label", caption = L("status-problems", n) }) end
  end
  bar.add({ type = "sprite-button", style = "tool_button", sprite = "utility/refresh", tooltip = L("recalculate"), tags = { fp = "plan_recalculate" } })
end

local function build_table(parent, player, r, ctx)
  local state = model.player(player.index)
  if #model.factory_ids() == 0 then
    parent.add({ type = "label", caption = L("no-factories") })
    return
  end
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

--- Row order: sinks by name (then the plan splits), factories by shortage, then the
--- ones the plan can't use.
--- @return number[] sinks, number[] factories
local function row_order(r)
  local p = model.plan()
  local sinks, rest, seen = {}, {}, {}
  for _, id in ipairs(r.order or {}) do seen[id] = true end
  for _, id in ipairs(model.factory_ids()) do
    local f = p.factories[id]
    if f.kind == "sink" then sinks[#sinks + 1] = id elseif not seen[id] then rest[#rest + 1] = id end
  end
  local function by_name(a, b)
    local na, nb = p.factories[a].name, p.factories[b].name
    if na ~= nb then return na < nb end
    return a < b
  end
  table.sort(sinks, by_name)
  table.sort(rest, by_name)
  local out = {}
  for _, id in ipairs(r.order or {}) do out[#out + 1] = id end
  for _, id in ipairs(rest) do out[#out + 1] = id end
  return sinks, out
end

local function name_cell(t, f, name, ctx, max_width)
  local cell = t.add({ type = "flow", direction = "horizontal" })
  cell.style.vertical_align = "center"
  local label = cell.add({ type = "label", caption = name, tooltip = common.flow_tooltip(ctx, f.result and f.result.net or {}, L("per-copy")) })
  label.style.maximal_width = max_width
  if f.invalid then
    label.style.font_color = common.RED
    local warn = cell.add({ type = "sprite", sprite = "utility/warning_icon",
      tooltip = L("invalid-missing", table.concat(f.invalid, ", ")) })
    warn.style.size = 16
    warn.style.stretch_image_to_widget_size = true
  end
  if f.kind == "sink" then
    local mark = cell.add({ type = "label", caption = L("sink-mark"), style = "info_label", tooltip = L("sink-explain") })
    mark.style.single_line = true
    mark.style.minimal_width = 36
  end
end

-- copies, needed, shortage, coverage (large window only) and chokes of a factory;
-- sinks leave them empty
local function plan_cells(t, f, r, ctx, coverage)
  local id = f.id
  if f.kind == "sink" then
    for _ = 1, coverage and 5 or 4 do t.add({ type = "empty-widget" }) end
    return
  end
  local shortage = r.shortage[id]
  local class = plan.shortage_class(shortage)
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
  -- copies still to build, one decimal; never below 0, green when covered; the exact need in the tooltip
  local caption, tip = "?", nil
  if shortage and known then
    caption = class == "short" and ("+" .. fp_util.format_count(shortage, 1)) or "0"
    local covered = needed > 0 and math.min(100, math.floor(100 * f.copies / needed + 0.5)) or 100
    tip = L("shortage-tooltip", fp_util.format_count(needed), fp_util.format_count(f.copies),
      fp_util.format_count(math.max(0, shortage)), covered)
    if shortage < -0.005 then tip = { "", tip, "\n", L("surplus-tooltip", fp_util.format_count(-shortage)) } end
  end
  local sl = t.add({ type = "label", caption = caption, style = "bold_label", tooltip = tip })
  if known and class == "short" then sl.style.font_color = common.RED
  elseif known and class == "ok" then sl.style.font_color = common.GREEN end
  if coverage then
    if known and shortage then
      local bar = t.add({ type = "progressbar", value = needed > 0 and math.min(1, f.copies / needed) or 1, tooltip = tip })
      bar.style.width = 90
      -- same colours as the shortage: red short, green covered
      bar.style.color = class == "short" and common.RED or common.GREEN
    else
      t.add({ type = "empty-widget" }) -- no coverage to show while the need is unknown
    end
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
end

function plan_tab.fill_rows(player, holder, r, ctx)
  holder.clear()
  local state = model.player(player.index)
  local filter = state.filter or ""
  -- the compact window has no room for the coverage bars: the shortage says the same
  local coverage = not state.compact
  local pane = holder.add({ type = "scroll-pane", style = "scroll_pane" })
  pane.style.vertically_stretchable = true
  pane.style.horizontally_stretchable = true
  -- widths: nil = natural, true = takes the spare width (the flow, so it starts right after the name)
  local heads = { { "", 24 }, { "col-name" }, { "col-per-copy", true }, { "col-copies", 80 }, { "col-needed", 64 }, { "col-shortage", 70 } }
  if coverage then heads[#heads + 1] = { "col-progress", 96 } end
  heads[#heads + 1] = { "", 24 }
  heads[#heads + 1] = { "" }
  local t = pane.add({ type = "table", column_count = #heads, draw_horizontal_lines = true })
  t.style.horizontally_stretchable = true
  t.style.horizontal_spacing = 12
  t.style.column_alignments[5] = "right"
  t.style.column_alignments[6] = "right"
  for _, h in ipairs(heads) do
    local head
    if h[1] == "" then head = t.add({ type = "empty-widget" }) else
      local caption = L(h[1])
      if h[1] == "col-per-copy" then caption = { "", caption, " (", common.unit_suffix(ctx), ")" } end
      head = t.add({ type = "label", caption = caption, style = "bold_label", tooltip = L(h[1] .. "-tooltip") })
    end
    if h[2] == true then head.style.horizontally_stretchable = true elseif h[2] then head.style.width = h[2] end
  end
  local shown = 0
  local names = common.factory_names(ctx)
  local max_chips = state.compact and 4 or 8
  local name_width = state.compact and 160 or 260
  local function factory_row(id)
    local f = model.get(id)
    local class = f and f.kind ~= "sink" and plan.shortage_class(r.shortage[id])
    if not (f and matches(f, filter) and not (state.hide_ok and class == "ok")) then return end
    shown = shown + 1
    t.add({ type = "sprite", sprite = common.factory_sprite(f) })
    name_cell(t, f, names[id], ctx, name_width)
    factories.flow_chips(t, f, ctx, max_chips)
    plan_cells(t, f, r, ctx, coverage)
    local buttons = t.add({ type = "flow", direction = "horizontal" })
    buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/rename_icon", tooltip = L("edit"),
      tags = { fp = "fac_edit", id = id } })
    if f.source then
      buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/center", tooltip = L("show-on-map"),
        tags = { fp = "show_map", id = id } })
    else
      buttons.add({ type = "empty-widget" }).style.width = 28 -- nothing on the map; keeps the buttons aligned
    end
    buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/trash", tooltip = L("delete"), enabled = ctx.can_edit,
      tags = { fp = "fac_delete", id = id } })
  end
  -- a plan split: the item, a "split" mark, and each factory's share as a chip
  local list = units()
  local function split_row(index, split)
    if filter ~= "" and not key_matches(split.item, filter:lower()) then return end
    shown = shown + 1
    t.add({ type = "sprite", sprite = common.key_sprite(split.item), tooltip = fp_util.localised(split.item) })
    local cell = t.add({ type = "flow", direction = "horizontal" })
    cell.style.vertical_align = "center"
    local label = cell.add({ type = "label", caption = fp_util.localised(split.item) })
    label.style.maximal_width = name_width
    local mark = cell.add({ type = "label", caption = L("split-mark"), style = "info_label", tooltip = L("split-mark-tooltip") })
    mark.style.single_line = true
    mark.style.minimal_width = 36
    local chips = t.add({ type = "flow", direction = "horizontal" })
    chips.style.horizontal_spacing = 2
    for _, id in ipairs(draft.split_lines(list, split)) do
      local f = model.get(id)
      local share = split.shares[id] or 0
      local chip = chips.add({
        type = "sprite-button", style = "slot_button", sprite = f and common.factory_sprite(f) or "utility/missing_icon",
        number = share, tooltip = { "", names[id] or "?", "\n", L("split-share", fp_util.format_count(share)) },
      })
      chip.style.size = 32
    end
    for _ = 1, coverage and 5 or 4 do t.add({ type = "empty-widget" }) end -- no copies or shortage
    local buttons = t.add({ type = "flow", direction = "horizontal" })
    buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/rename_icon", tooltip = L("edit-split"),
      tags = { fp = "plan_split_edit", item = split.item } })
    buttons.add({ type = "empty-widget" }).style.width = 28
    buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/trash", tooltip = L("split-remove"), enabled = ctx.can_edit,
      tags = { fp = "split_remove", mode = "plan", index = index } })
  end
  local sinks, rest = row_order(r)
  for _, id in ipairs(sinks) do factory_row(id) end
  for i, split in ipairs(model.plan().splits) do split_row(i, split) end
  for _, id in ipairs(rest) do factory_row(id) end
  if shown == 0 then holder.add({ type = "label", caption = L("plan-filtered") }) end
end

local function build_problems(box, player, r, ctx)
  if #r.problems > 0 then
    -- a long list scrolls in its own box, so the factory table keeps its room
    local pane = box.add({ type = "scroll-pane", style = "naked_scroll_pane", horizontal_scroll_policy = "never" })
    pane.style.maximal_height = model.player(player.index).compact and 100 or 160
    pane.style.horizontally_stretchable = true
    problems.render(pane, player, "plan", r, ctx)
  end
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
  build_table(section(parent, "stoich_plan_main"), player, r, ctx)
end

window.builder = plan_tab.build

-- Split window ------------------------------------------------------------------------------------

local function fill_split(player, content, index)
  content.clear()
  local explain = content.add({ type = "label", caption = L("splits-explain"), style = "info_label" })
  explain.style.single_line = false
  explain.style.maximal_width = 440
  splits.build_card(content, player, "plan", index, model.plan().splits[index])
end

--- Open the split window on the plan split of an item (with each factory's needed copies).
function plan_tab.open_split(player, item)
  local index = split_index(item)
  if not index then return window.destroy_child(player, "stoich_split") end
  model.player(player.index).split_item = item
  window.open(player)
  local _, content = window.open_child(player, "stoich_split", L("split-title", fp_util.localised(item)))
  fill_split(player, content, index)
end

-- After a plan change: rebuilt, or closed when its split is gone. The player dragging
-- its slider gets the values updated in place, so the slider keeps working.
window.child_refresh.stoich_split = function(player, opts)
  local item = model.player(player.index).split_item
  local index = item and split_index(item)
  if not index then return window.destroy_child(player, "stoich_split") end
  local content = window.child_content(player, "stoich_split")
  if opts.keep_split == player.index then
    splits.update_card(content, player, "plan", index, opts.line)
  else
    fill_split(player, content, index)
  end
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
      -- the split window follows its split when the player switched its item
      local split = index and model.plan().splits[index]
      if split then model.player(player.index).split_item = split.item end
      plan.changed()
    else
      plan.changed({ keep_split = player.index, line = line })
    end
  end,
  can_edit = function(player) return model.can_edit(player) end,
}

problems.actions.plan = {
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
    local index = draft.add_split(model.plan(), item, solver.producers_of(list, item), list)
    model.log(player.index, { "stoich.log-plan-split", fp_util.rich(item) }, nil)
    plan.changed()
    plan_tab.open_split(player, model.plan().splits[index].item)
  end,
  show_item = function(player, item)
    items.open(player, item)
  end,
}

-- Handlers ------------------------------------------------------------------------------------------

handlers.plan_split_edit = function(player, element)
  plan_tab.open_split(player, element.tags.item)
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

return plan_tab
