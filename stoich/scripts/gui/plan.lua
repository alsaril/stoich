-- The main window: every sink, plan split and factory, and what to build next.
-- Toolbar and status, problems, and one table with their flow, copies and
-- shortage. Also the split window, where one plan split is edited.

local common = require("scripts.gui.common")
local window = require("scripts.gui.window")
local splits = require("scripts.gui.splits")
local problems = require("scripts.gui.problems")
local scopes = require("scripts.gui.scopes")
local editor = require("scripts.gui.editor")
local items = require("scripts.gui.items")
local model = require("scripts.model")
local plan = require("scripts.plan")
local draft = require("scripts.draft")
local solver = require("scripts.solver")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local plan_window = {}

local function result()
  local p = model.plan()
  return p.result or plan.rebalance()
end

local function units()
  return (plan.units())
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

-- Pieces of the table -----------------------------------------------------------------------

--- Net flow of one copy as plain slots: inputs → outputs (red slots would read as "missing").
--- The arrow is always there, so a sink reads "inputs →" and a mine "→ outputs".
local function flow_chips(parent, f, ctx, max_chips)
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
  local out_slots = math.min(#outputs, max_chips)
  local in_slots = math.min(#inputs, max_chips - out_slots)
  for i = 1, in_slots do chip(inputs[i]) end
  if #inputs + #outputs > 0 then
    flow.add({ type = "label", caption = "→", style = "bold_label" }).style.horizontal_align = "center"
  end
  for i = 1, out_slots do chip(outputs[i]) end
  local hidden = #inputs + #outputs - shown
  if hidden > 0 then
    -- single line with room for the text, or a squeezed flow wraps "+5" onto two lines
    local more = flow.add({ type = "label", caption = "+" .. hidden, style = "info_label", tooltip = L("more-flows-tooltip", hidden) })
    more.style.single_line = true
    more.style.minimal_width = 24
  end
end

--- Toolbar buttons, added to the given (horizontal) bar.
local function add_buttons(bar, ctx)
  -- capturing a block is the usual way in: first, and the one green button
  bar.add({ type = "button", caption = L("capture"), style = "green_button", tooltip = L("capture-tooltip"), enabled = ctx.can_edit,
    tags = { fp = "fac_capture" } })
  bar.add({ type = "button", caption = L("new-factory"), enabled = ctx.can_edit, tags = { fp = "fac_new" } })
  bar.add({ type = "button", caption = L("new-sink"), enabled = ctx.can_edit, tags = { fp = "fac_new_sink" } })
  bar.add({ type = "empty-widget" }).style.width = 8
  -- the rest needs a plan to work on
  local empty = next(model.plan().factories) == nil
  bar.add({ type = "button", caption = L("statistics"), tooltip = L("statistics-tooltip"), enabled = not empty, tags = { fp = "open_stats" } })
  bar.add({ type = "empty-widget" }).style.width = 8
  bar.add({ type = "button", caption = L("export-all"), enabled = not empty, tags = { fp = "fac_export_all" } })
  bar.add({ type = "button", caption = L("import"), enabled = ctx.can_edit, tags = { fp = "fac_import" } })
end

-- Sections ------------------------------------------------------------------------------------

-- Toolbar on the left, the plan status on the right (as in the editor header).
local function build_header(parent, player, r, ctx)
  local bar = parent.add({ type = "frame", style = "subheader_frame", direction = "horizontal" })
  bar.style.horizontally_stretchable = true
  bar.style.height = 40
  bar.style.vertical_align = "center"
  add_buttons(bar, ctx)
  common.spacer(bar)
  -- an empty plan has no status worth showing
  if next(model.plan().factories) then
    common.status_label(bar, r.status)
    local n = problems.count(r)
    if n > 0 then bar.add({ type = "label", caption = L("status-problems", n) }) end
  end
end

local function build_table(parent, player, r, ctx)
  local state = model.player(player.index)
  if #model.factory_ids() == 0 then
    -- the empty plan explains the three steps
    local guide = parent.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
    guide.add({ type = "label", caption = L("empty-title"), style = "caption_label" })
    for i = 1, 3 do
      local step = guide.add({ type = "label", caption = L("empty-step-" .. i) })
      step.style.single_line = false
    end
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
  plan_window.fill_rows(player, box.stoich_plan_rows, r, ctx)
end

--- Factories keep the order they had when the window opened, so a row doesn't jump
--- away under the cursor when − / + changes its shortage; new ones go at the end.
local function stable_order(state, ids)
  local wanted, placed, out = {}, {}, {}
  for _, id in ipairs(ids) do wanted[id] = true end
  for _, id in ipairs(state.plan_order or {}) do
    if wanted[id] and not placed[id] then
      out[#out + 1] = id
      placed[id] = true
    end
  end
  for _, id in ipairs(ids) do
    if not placed[id] then out[#out + 1] = id end
  end
  state.plan_order = out
  return out
end

--- Row order: sinks by name (then the plan splits), factories by shortage (as when the
--- window opened), then the ones the plan can't use.
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

-- copies (with − / +) against the need, what is still to build, and chokes; sinks and
-- splits leave them empty
local PLAN_CELLS = 3
local function plan_cells(t, f, r, ctx)
  local id = f.id
  if f.kind == "sink" then
    for _ = 1, PLAN_CELLS do t.add({ type = "empty-widget" }) end
    return
  end
  local shortage = r.shortage[id]
  local class = plan.shortage_class(shortage)
  local needed = r.counts[id]
  local known = needed ~= nil and not r.undetermined[id]
  local tip
  if shortage and known then
    local covered = needed > 0 and math.min(100, math.floor(100 * f.copies / needed + 0.5)) or 100
    tip = L("shortage-tooltip", fp_util.format_count(needed), fp_util.format_count(f.copies),
      fp_util.format_count(math.max(0, shortage)), covered)
    if shortage < -0.005 then tip = { "", tip, "\n", L("surplus-tooltip", fp_util.format_count(-shortage)) } end
  end
  -- [−] 2 [+] of 2.09
  local copies = t.add({ type = "flow", direction = "horizontal", tooltip = tip })
  copies.style.vertical_align = "center"
  copies.add({ type = "button", caption = "−", style = "mini_button", enabled = ctx.can_edit, tags = { fp = "plan_copies", id = id, delta = -1 } })
  local c = copies.add({ type = "label", caption = fp_util.format_count(f.copies), tooltip = tip })
  c.style.minimal_width = 28
  c.style.horizontal_align = "center"
  copies.add({ type = "button", caption = "+", style = "mini_button", enabled = ctx.can_edit, tags = { fp = "plan_copies", id = id, delta = 1 } })
  local of = copies.add({ type = "label", caption = L("copies-of", known and fp_util.format_count(needed) or "?"), style = "info_label", tooltip = tip })
  of.style.single_line = true
  of.style.minimal_width = 56
  -- copies still to build, one decimal, never below 0; a green tick when covered
  local caption = "?"
  if shortage and known then caption = class == "short" and ("+" .. fp_util.format_count(shortage, 1)) or "✓" end
  local sl = t.add({ type = "label", caption = caption, style = "bold_label", tooltip = tip })
  if known and class == "short" then sl.style.font_color = common.RED
  elseif known and class == "ok" then sl.style.font_color = common.GREEN end
  local chokes = plan.chokes(f, ctx.tiers, ctx.max_index, ctx.one_lane)
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

function plan_window.fill_rows(player, holder, r, ctx)
  holder.clear()
  local state = model.player(player.index)
  local filter = state.filter or ""
  local pane = holder.add({ type = "scroll-pane", style = "scroll_pane" })
  pane.style.vertically_stretchable = true
  pane.style.horizontally_stretchable = true
  -- widths: nil = natural, true = takes the spare width (the flow, so it starts right after the name)
  -- the recipe column gets the room: long recipes show up to MAX_CHIPS slots
  local heads = { { "", 24 }, { "col-name" }, { "col-recipe", true }, { "col-copies", 130 }, { "col-to-build", 50 }, { "", 24 }, { "" } }
  local t = pane.add({ type = "table", column_count = #heads, draw_horizontal_lines = true })
  t.style.horizontally_stretchable = true
  t.style.horizontal_spacing = 8
  t.style.column_alignments[5] = "right"
  for _, h in ipairs(heads) do
    local head
    if h[1] == "" then head = t.add({ type = "empty-widget" }) else
      local caption = L(h[1])
      if h[1] == "col-recipe" then caption = { "", caption, " (", common.unit_suffix(ctx), ")" } end
      head = t.add({ type = "label", caption = caption, style = "bold_label", tooltip = L(h[1] .. "-tooltip") })
    end
    if h[2] == true then head.style.horizontally_stretchable = true elseif h[2] then head.style.width = h[2] end
  end
  local shown = 0
  local names = common.factory_names(ctx)
  local max_chips, name_width = 10, 180
  local function factory_row(id)
    local f = model.get(id)
    local class = f and f.kind ~= "sink" and plan.shortage_class(r.shortage[id])
    if not (f and matches(f, filter) and not (state.hide_ok and class == "ok")) then return end
    shown = shown + 1
    t.add({ type = "sprite", sprite = common.factory_sprite(f) })
    name_cell(t, f, names[id], ctx, name_width)
    flow_chips(t, f, ctx, max_chips)
    plan_cells(t, f, r, ctx)
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
    for _ = 1, PLAN_CELLS do t.add({ type = "empty-widget" }) end -- no copies or shortage
    local buttons = t.add({ type = "flow", direction = "horizontal" })
    buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/rename_icon", tooltip = L("edit-split"),
      tags = { fp = "plan_split_edit", item = split.item } })
    buttons.add({ type = "empty-widget" }).style.width = 28
    buttons.add({ type = "sprite-button", style = "tool_button", sprite = "utility/trash", tooltip = L("split-remove"), enabled = ctx.can_edit,
      tags = { fp = "split_remove", mode = "plan", index = index } })
  end
  local sinks, rest = row_order(r)
  rest = stable_order(state, rest)
  for _, id in ipairs(sinks) do factory_row(id) end
  for i, split in ipairs(model.plan().splits) do split_row(i, split) end
  for _, id in ipairs(rest) do factory_row(id) end
  if shown == 0 then holder.add({ type = "label", caption = L("plan-filtered") }) end
end

-- A long list shows its first rows only, so the factory table keeps its room.
local PROBLEMS_SHOWN = 4

local function build_problems(box, player, r, ctx)
  if #r.problems > 0 then
    local state = model.player(player.index)
    local list, hidden = problems.render(box, player, "plan", r, ctx, not state.all_problems and PROBLEMS_SHOWN or nil)
    if hidden > 0 or state.all_problems then
      list.add({ type = "button", caption = L(state.all_problems and "problems-fewer" or "problems-all", hidden),
        tags = { fp = "plan_all_problems" } })
    end
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

function plan_window.build(player, parent, ctx)
  local r = result()
  build_header(section(parent, "stoich_plan_header"), player, r, ctx)
  -- problems first: they are what needs doing
  build_problems(section(parent, "stoich_plan_problems"), player, r, ctx)
  build_table(section(parent, "stoich_plan_main"), player, r, ctx)
end

window.builder = plan_window.build

-- Split window ------------------------------------------------------------------------------------

local function fill_split(player, content, index)
  content.clear()
  local explain = content.add({ type = "label", caption = L("splits-explain"), style = "info_label" })
  explain.style.single_line = false
  explain.style.maximal_width = 440
  splits.build_card(content, player, "plan", index, model.plan().splits[index])
end

--- Open the split window on the plan split of an item (with each factory's needed copies).
function plan_window.open_split(player, item)
  local index = split_index(item)
  if not index then return window.destroy_child(player, "stoich_split") end
  model.player(player.index).split_item = item
  local _, content = window.open_child(player, "stoich_split", L("split-title", fp_util.localised(item)))
  fill_split(player, content, index)
end

-- After a plan change: rebuilt, or closed when its split is gone. The player dragging
-- its slider gets the values updated in place, so the slider keeps working.
local function refresh_split(player, opts)
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

window.register_child("stoich_split", {
  refresh = refresh_split,
  rebuild = function(player) refresh_split(player, {}) end,
})

-- Scope of the split cards and problems ------------------------------------------------------------

scopes.plan = {
  holder = function() return model.plan() end,
  units = function() return units() end,
  counts = function() return result().counts end,
  names = function(player)
    return common.factory_names(common.ctx(player))
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
      window.plan_changed()
    else
      window.plan_changed({ keep_split = player.index, line = line })
    end
  end,
  can_edit = function(player) return model.can_edit(player) end,
  -- problem actions
  add_sink = function(player, item)
    local f = draft.new_sink()
    f.name = fp_util.pretty_name(select(2, fp_util.parse_key(item)))
    f.sink_items[1] = { key = item, rate = 0 }
    local t, n = fp_util.parse_key(item)
    if t == "item" or t == "fluid" then f.icon = { type = t, name = n } end
    editor.open_factory(player, f, { translate = item })
  end,
  add_split = function(player, item)
    local list = units()
    local index = draft.add_split(model.plan(), item, solver.producers_of(list, item), list)
    model.log(player.index, { "stoich.log-plan-split", fp_util.rich(item) }, nil)
    window.plan_changed()
    plan_window.open_split(player, model.plan().splits[index].item)
  end,
  show_item = function(player, item)
    items.open(player, item)
  end,
}

-- Handlers ------------------------------------------------------------------------------------------

handlers.plan_all_problems = function(player)
  local state = model.player(player.index)
  state.all_problems = not state.all_problems or nil
  window.refresh(player)
end

handlers.plan_split_edit = function(player, element)
  plan_window.open_split(player, element.tags.item)
end

handlers.plan_copies = function(player, element)
  if not model.can_edit(player) then return end
  local f = model.get(element.tags.id)
  if not f then return end
  if model.set_copies(f.id, (f.copies or 0) + element.tags.delta, player.index) then window.plan_changed() end
end

handlers.plan_filter = { text = function(player, element, event)
  local state = model.player(player.index)
  state.filter = element.text
  local w = window.get(player)
  local rows = w and common.find(w, "stoich_plan_rows")
  if rows then plan_window.fill_rows(player, rows, result(), common.ctx(player)) end
end }

handlers.plan_hide_ok = function(player, element)
  local state = model.player(player.index)
  state.hide_ok = element.state
  local w = window.get(player)
  local rows = w and common.find(w, "stoich_plan_rows")
  if rows then plan_window.fill_rows(player, rows, result(), common.ctx(player)) end
end

return plan_window
