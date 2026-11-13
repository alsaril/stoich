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

local function result(key)
  return model.plan(key).result or plan.rebalance(key)
end

local function units(key)
  return (plan.units(key))
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
  for _, row in ipairs(plan.is_list(f) and f.sink_items or {}) do
    if row.key and key_matches(row.key, q) then return true end
  end
  return false
end

local function split_index(key, item)
  for i, split in ipairs(model.plan(key).splits) do
    if split.item == item then return i end
  end
  return nil
end

-- Pieces of the table -----------------------------------------------------------------------

--- Net flow of one copy, what a sink asks for at its scale, or what a void takes and
--- an import brings in the plan's balance.
local function shown_net(f, r)
  if plan.is_boundary(f) then
    local sign = f.kind == "import" and 1 or -1
    local net = {}
    for key, v in pairs(plan.boundary_rates(f, r)) do net[key] = sign * v end
    return net
  end
  local net = f.result and f.result.net or {}
  if f.kind ~= "sink" or plan.sink_scale(f) == 1 then return net end
  local scaled = {}
  for key, v in pairs(net) do scaled[key] = v * plan.sink_scale(f) end
  return scaled
end

--- Net flow of one copy as plain slots: inputs → outputs (red slots would read as "missing").
--- The arrow is always there, so a sink reads "inputs →" and a mine "→ outputs".
local function flow_chips(parent, f, ctx, max_chips, r)
  local flow = parent.add({ type = "flow", direction = "horizontal" })
  flow.style.horizontal_spacing = 2
  flow.style.vertical_align = "center"
  local net = shown_net(f, r)
  local inputs, outputs = {}, {}
  for _, key in ipairs(fp_util.sorted_keys(net)) do
    -- a void's items always go in and an import's come out, at 0 too
    local out = net[key] > 0
    if f.kind == "void" then out = false elseif f.kind == "import" then out = true end
    table.insert(out and outputs or inputs, key)
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
      tooltip = { "", fp_util.localised(key), "\n", (v > 0 and "+" or "") .. fp_util.format_rate(v, ctx.unit, true), "\n", L("item-click") },
      tags = { fp = "plan_item", item = key },
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
  bar.add({ type = "button", caption = L("new-recipe"), tooltip = L("new-recipe-tooltip"), enabled = ctx.can_edit, tags = { fp = "fac_new_recipe" } })
  bar.add({ type = "button", caption = L("new-sink"), enabled = ctx.can_edit, tags = { fp = "fac_new_sink" } })
  -- the plan's one void and one import: opened, or made on first use
  bar.add({ type = "button", caption = L("void-button"), tooltip = { "", L("void-explain"), "\n", L("one-per-plan") },
    tags = { fp = "fac_boundary", kind = "void" } })
  bar.add({ type = "button", caption = L("import-button"), tooltip = { "", L("import-explain"), "\n", L("one-per-plan") },
    tags = { fp = "fac_boundary", kind = "import" } })
  bar.add({ type = "empty-widget" }).style.width = 8
  -- the rest needs a plan to work on
  local empty = next(model.plan(ctx.plan).factories) == nil
  bar.add({ type = "button", caption = L("statistics"), tooltip = L("statistics-tooltip"), enabled = not empty, tags = { fp = "open_stats" } })
  bar.add({ type = "empty-widget" }).style.width = 8
  -- strings: icons, so "Import" means one thing in this bar (the import of items)
  bar.add({ type = "sprite-button", style = "tool_button", sprite = "utility/export", tooltip = L("export-all"), enabled = not empty,
    tags = { fp = "fac_export_all" } })
  bar.add({ type = "sprite-button", style = "tool_button", sprite = "utility/import", tooltip = L("import-string"), enabled = ctx.can_edit,
    tags = { fp = "fac_import" } })
  -- buttons as wide as their captions (not the default 108 px): the status keeps its room
  for _, b in ipairs(bar.children) do
    if b.type == "button" then b.style.minimal_width = 0 end
  end
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
  if next(model.plan(ctx.plan).factories) then
    common.status_label(bar, r.status)
    local n = problems.count(r, "plan")
    if n > 0 then bar.add({ type = "label", caption = L("status-problems", n) }) end
  end
end

local function build_table(parent, player, r, ctx)
  local state = model.player(player.index)
  if #model.factory_ids(ctx.plan) == 0 then
    parent.clear()
    -- the empty plan explains the three steps
    local guide = parent.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
    guide.add({ type = "label", caption = L("empty-title"), style = "caption_label" })
    for i = 1, 3 do
      local step = guide.add({ type = "label", caption = L("empty-step-" .. i) })
      step.style.single_line = false
    end
    return
  end
  -- kept between refreshes: the filter field and the scroll position stay as they are
  local box = parent.stoich_plan_table_box
  if box then
    plan_window.fill_rows(player, box.stoich_plan_rows, r, ctx)
    return
  end
  parent.clear()
  box = parent.add({ type = "flow", name = "stoich_plan_table_box", direction = "vertical" })
  local filters = box.add({ type = "flow", direction = "horizontal" })
  filters.style.vertical_align = "center"
  filters.add({ type = "label", caption = L("filter") })
  local filter = filters.add({ type = "textfield", text = state.filter or "", tags = { fp = "plan_filter" }, tooltip = L("filter-tooltip") })
  filter.style.width = 160
  filters.add({ type = "checkbox", caption = L("hide-ok"), state = state.hide_ok or false, tags = { fp = "plan_hide_ok" } })
  box.add({ type = "flow", name = "stoich_plan_rows", direction = "vertical" })
  plan_window.fill_rows(player, box.stoich_plan_rows, r, ctx)
end

--- Factories keep their order while the player works in the window, so a row doesn't
--- jump away under the cursor when − / + changes its shortage; new ones go at the end.
--- Closing a child window clears the order, so the plan comes back sorted afresh.
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

-- Order of the item-list rows at the top: what the plan delivers, then what crosses
-- its boundary.
local LIST_ORDER = { sink = 1, import = 2, void = 3 }

--- Row order: sinks, imports and voids by name (then the plan splits), factories by
--- shortage (as when the window opened or a child window closed), then the ones the
--- plan can't use.
--- @return number[] sinks, imports and voids, number[] factories
local function row_order(r, key)
  local p = model.plan(key)
  local sinks, rest, seen = {}, {}, {}
  for _, id in ipairs(r.order or {}) do seen[id] = true end
  for _, id in ipairs(model.factory_ids(key)) do
    local f = p.factories[id]
    if plan.is_list(f) then sinks[#sinks + 1] = id elseif not seen[id] then rest[#rest + 1] = id end
  end
  local function by_name(a, b)
    local na, nb = p.factories[a].name, p.factories[b].name
    if na ~= nb then return na < nb end
    return a < b
  end
  table.sort(sinks, function(a, b)
    local ka, kb = LIST_ORDER[p.factories[a].kind], LIST_ORDER[p.factories[b].kind]
    if ka ~= kb then return ka < kb end
    return by_name(a, b)
  end)
  table.sort(rest, by_name)
  local out = {}
  for _, id in ipairs(r.order or {}) do out[#out + 1] = id end
  for _, id in ipairs(rest) do out[#out + 1] = id end
  return sinks, out
end

local NET_TITLE = { sink = "sink-demand", void = "void-rates", import = "import-rates" }

local function name_cell(t, f, name, ctx, max_width, r)
  local cell = t.add({ type = "flow", direction = "horizontal" })
  cell.style.vertical_align = "center"
  local label = cell.add({ type = "label", caption = name,
    tooltip = common.flow_tooltip(ctx, shown_net(f, r), L(NET_TITLE[f.kind] or "per-copy")) })
  label.style.maximal_width = max_width
  if f.invalid then
    label.style.font_color = common.RED
    local warn = cell.add({ type = "sprite", sprite = "utility/warning_icon",
      tooltip = L("invalid-missing", table.concat(f.invalid, ", ")) })
    warn.style.size = 16
    warn.style.stretch_image_to_widget_size = true
  end
  if f.kind == "sink" then
    local scale = plan.sink_scale(f)
    local mark = cell.add({ type = "label", caption = scale < 1 and L("sink-mark-scale", fp_util.format_count(scale)) or L("sink-mark"),
      style = "info_label", tooltip = L("sink-explain") })
    mark.style.single_line = true
    mark.style.minimal_width = scale < 1 and 70 or 36
  elseif plan.is_boundary(f) then
    local void = f.kind == "void"
    local mark = cell.add({ type = "label", caption = L(void and "void-mark" or "import-mark"), style = "info_label",
      tooltip = L(void and "void-explain" or "import-explain") })
    mark.style.single_line = true
    mark.style.minimal_width = void and 36 or 50
  end
end

-- copies (with − / +) against the need, what is still to build, and chokes; sinks and
-- splits leave them empty
local PLAN_CELLS = 3
local function plan_cells(t, f, r, ctx)
  local id = f.id
  if plan.is_list(f) then
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
  local state = model.player(player.index)
  local filter = state.filter or ""
  -- the scroll pane outlives its rows, so − / + doesn't scroll the list back to the top
  local pane = holder.stoich_plan_pane
  if pane then
    pane.clear()
  else
    pane = holder.add({ type = "scroll-pane", name = "stoich_plan_pane", style = "scroll_pane" })
    pane.style.vertically_stretchable = true
    pane.style.horizontally_stretchable = true
  end
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
    local class = f and not plan.is_list(f) and plan.shortage_class(r.shortage[id])
    if not (f and matches(f, filter) and not (state.hide_ok and class == "ok")) then return end
    shown = shown + 1
    t.add({ type = "sprite", sprite = common.factory_sprite(f) })
    name_cell(t, f, names[id], ctx, name_width, r)
    flow_chips(t, f, ctx, max_chips, r)
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
  local list = units(ctx.plan)
  local unit_names = common.unit_names(ctx)
  local function split_row(index, split)
    if filter ~= "" and not key_matches(split.item, filter:lower()) then return end
    shown = shown + 1
    t.add({ type = "sprite", sprite = common.key_sprite(split.item), tooltip = fp_util.localised(split.item) })
    local cell = t.add({ type = "flow", direction = "horizontal" })
    cell.style.vertical_align = "center"
    local label = cell.add({ type = "label", caption = fp_util.localised(split.item) })
    label.style.maximal_width = name_width
    local usage = split.match_usage
    local mark = cell.add({ type = "label", caption = L(usage and "split-mark-usage" or "split-mark"), style = "info_label",
      tooltip = L(usage and "split-mark-usage-tooltip" or "split-mark-tooltip") })
    mark.style.single_line = true
    mark.style.minimal_width = usage and 40 or 36
    local chips = t.add({ type = "flow", direction = "horizontal" })
    chips.style.horizontal_spacing = 2
    -- a click on an icon opens the split window, as the pencil does
    local open_tags = { fp = "plan_split_edit", item = split.item }
    for _, id in ipairs(draft.split_lines(list, split)) do
      -- an import's share is one of its items: shown with the import's icon and name
      local f = model.get(plan.unit_owner(id))
      local share = split.shares[id] or 0
      -- whole percents on the icon, the exact share in its tooltip
      local chip = chips.add({
        type = "sprite-button", style = "slot_button", sprite = f and common.factory_sprite(f) or "utility/missing_icon",
        number = math.floor(share + 0.5), tooltip = { "", unit_names[id] or "?", "\n", L("split-share", fp_util.format_count(share)) },
        tags = open_tags,
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
  local sinks, rest = row_order(r, ctx.plan)
  rest = stable_order(state, rest)
  for _, id in ipairs(sinks) do factory_row(id) end
  for i, split in ipairs(model.plan(ctx.plan).splits) do split_row(i, split) end
  for _, id in ipairs(rest) do factory_row(id) end
  if shown == 0 then pane.add({ type = "label", caption = L("plan-filtered") }) end
end

-- A long list shows its first rows only, so the factory table keeps its room; all of
-- them scroll in a pane of their own, the toggle stays under it.
local PROBLEMS_SHOWN = 4
local PROBLEMS_HEIGHT = 220

local function build_problems(box, player, r, ctx)
  if #r.problems > 0 then
    local state = model.player(player.index)
    local pane = box.add({ type = "scroll-pane", name = "stoich_problems_pane", style = "naked_scroll_pane",
      horizontal_scroll_policy = "never" })
    pane.style.maximal_height = PROBLEMS_HEIGHT
    pane.style.horizontally_stretchable = true
    local _, hidden = problems.render(pane, player, "plan", r, ctx, not state.all_problems and PROBLEMS_SHOWN or nil)
    if hidden > 0 or state.all_problems then
      box.add({ type = "button", caption = L(state.all_problems and "problems-fewer" or "problems-all", hidden),
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

--- A section of the window, made on the first build and reused after (the table keeps
--- its scroll position); cleared unless the builder keeps parts of it.
local function section(parent, name, keep)
  local box = parent[name]
  if box then
    if not keep then box.clear() end
    return box
  end
  box = parent.add({ type = "flow", name = name, direction = "vertical" })
  box.style.vertical_spacing = 6
  box.style.horizontally_stretchable = true
  return box
end

--- A surface's name in the selector: a planet with its icon, a space platform by its
--- name, a surface that is gone marked so.
local function surface_caption(key)
  local surface = game.get_surface(key)
  if not surface then return { "", key, " ", L("surface-gone") } end
  if surface.planet then return { "", "[planet=" .. surface.planet.name .. "] ", surface.planet.prototype.localised_name } end
  if surface.platform then return { "", "[img=utility/space_age_icon] ", surface.platform.name } end
  return surface.localised_name or surface.name
end

--- Plans to choose from: every planet that has a surface (in the order the game made
--- them), then any other surface with something saved in its plan, and the chosen one.
function plan_window.surface_choices(selected)
  local planets = {}
  for _, surface in pairs(game.surfaces) do
    if surface.planet then planets[#planets + 1] = surface end
  end
  table.sort(planets, function(a, b) return a.index < b.index end)
  local keys, seen = {}, {}
  local function add(key)
    if not seen[key] then
      seen[key] = true
      keys[#keys + 1] = key
    end
  end
  for _, surface in ipairs(planets) do add(surface.name) end
  for _, key in ipairs(model.plan_keys()) do
    if model.has_plan(key) then add(key) end
  end
  add(selected)
  return keys
end

--- The surface selector in the title bar shows the plans there are and the chosen one.
local function update_selector(player, ctx)
  local w = window.get(player)
  local dd = w and w.stoich_titlebar.stoich_plan_select
  if not dd then return end
  local keys = plan_window.surface_choices(ctx.plan)
  local captions, selected = {}, 1
  for i, key in ipairs(keys) do
    captions[i] = surface_caption(key)
    if key == ctx.plan then selected = i end
  end
  dd.items = captions
  dd.selected_index = selected
  dd.tags = { fp = "plan_surface", keys = keys }
end

--- Build the main window's content, or rebuild it in place.
function plan_window.build(player, parent, ctx)
  update_selector(player, ctx)
  local r = result(ctx.plan)
  build_header(section(parent, "stoich_plan_header"), player, r, ctx)
  -- problems first: they are what needs doing
  build_problems(section(parent, "stoich_plan_problems"), player, r, ctx)
  build_table(section(parent, "stoich_plan_main", true), player, r, ctx)
end

window.builder = plan_window.build

-- Split window ------------------------------------------------------------------------------------

local function fill_split(player, content, index)
  content.clear()
  local explain = content.add({ type = "label", caption = L("splits-explain"), style = "info_label" })
  explain.style.single_line = false
  explain.style.maximal_width = 440
  splits.build_card(content, player, "plan", index, model.plan(model.selected(player.index)).splits[index])
end

--- Open the split window on the plan split of an item (with each factory's needed copies).
function plan_window.open_split(player, item)
  local index = split_index(model.selected(player.index), item)
  if not index then return window.destroy_child(player, "stoich_split") end
  model.player(player.index).split_item = item
  local _, content = window.open_child(player, "stoich_split", L("split-title", fp_util.localised(item)))
  fill_split(player, content, index)
end

-- After a plan change: rebuilt, or closed when its split is gone. The player dragging
-- its slider gets the values updated in place, so the slider keeps working.
local function refresh_split(player, opts)
  local item = model.player(player.index).split_item
  local index = item and split_index(model.selected(player.index), item)
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

local function selected(player)
  return model.selected(player.index)
end

scopes.plan = {
  holder = function(player) return model.plan(selected(player)) end,
  units = function(player) return units(selected(player)) end,
  counts = function(player) return result(selected(player)).counts end,
  names = function(player)
    return common.unit_names(common.ctx(player))
  end,
  extra_of = function(player, id)
    local r = result(selected(player))
    -- an import's share is a rate, not copies
    if select(2, plan.unit_owner(id)) then
      if r.undetermined[id] or r.counts[id] == nil then return L("needed-unknown") end
      return fp_util.format_rate(r.counts[id], common.ctx(player).unit, true)
    end
    local needed = r.counts[id]
    if needed == nil or r.undetermined[id] then return L("needed-unknown") end
    return L("needed-count", fp_util.format_count(needed))
  end,
  sprite_of = function(_, id)
    local f = model.get(plan.unit_owner(id))
    return f and common.factory_sprite(f) or "utility/missing_icon"
  end,
  changed = function(player, structural, index, line)
    local key = selected(player)
    if structural then
      -- the split window follows its split when the player switched its item
      local split = index and model.plan(key).splits[index]
      if split then model.player(player.index).split_item = split.item end
      window.plan_changed(key)
    else
      window.plan_changed(key, { keep_split = player.index, line = line })
    end
  end,
  can_edit = function(player) return model.can_edit(player) end,
  match_usage = true,
  can_match_usage = function(player, split)
    return not plan.imported(split.item, units(selected(player)))
  end,
  log_match_usage = function(player, split)
    model.log(player.index, { split.match_usage and "stoich.log-split-match-usage" or "stoich.log-split-manual", fp_util.rich(split.item) }, nil,
      selected(player))
  end,
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
    local key = selected(player)
    local p = model.plan(key)
    local list = units(key)
    local index = draft.add_split(p, item, solver.producers_of(list, item), list)
    local split = p.splits[index]
    if plan.imported(item, list) then
      -- an import has nothing built to match: it starts with all of the item, the
      -- factories with none, and the player moves the shares (always a balance)
      local imports = {}
      for _, unit in ipairs(list) do
        if unit.item and (unit.flow[item] or 0) > 0 then imports[#imports + 1] = unit.id end
      end
      for id in pairs(split.shares) do split.shares[id] = 0 end
      for _, id in ipairs(imports) do split.shares[id] = 100 / #imports end
    else
      -- the plan knows what is built: a new split matches usage until the player unticks it
      split.match_usage = true
    end
    model.log(player.index, { "stoich.log-plan-split", fp_util.rich(item) }, nil, key)
    window.plan_changed(key)
    plan_window.open_split(player, p.splits[index].item)
  end,
  -- the item goes to the plan's void or import (one is made when there is none)
  add_boundary = function(player, kind, item)
    local key = selected(player)
    if draft.add_boundary_item(key, kind, item, player.index) then window.plan_changed(key) end
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

handlers.plan_item = function(player, element)
  items.open(player, element.tags.item)
end

handlers.plan_split_edit = function(player, element)
  plan_window.open_split(player, element.tags.item)
end

handlers.plan_copies = function(player, element)
  if not model.can_edit(player) then return end
  local f = model.get(element.tags.id)
  if not f then return end
  if model.set_copies(f.id, (f.copies or 0) + element.tags.delta, player.index) then window.plan_changed(model.plan_of(f.id)) end
end

local function refill_rows(player)
  local w = window.get(player)
  local rows = w and common.find(w, "stoich_plan_rows")
  if rows then plan_window.fill_rows(player, rows, result(selected(player)), common.ctx(player)) end
end

handlers.plan_filter = { text = function(player, element, event)
  model.player(player.index).filter = element.text
  refill_rows(player)
end }

handlers.plan_hide_ok = function(player, element)
  model.player(player.index).hide_ok = element.state
  refill_rows(player)
end

-- Another surface's plan: the table starts afresh (sorted, scrolled to the top).
handlers.plan_surface = { selection = function(player, element)
  local key = element.tags.keys[element.selected_index]
  local state = model.player(player.index)
  if not key or key == state.plan then return end
  state.plan = key
  state.plan_order = nil
  local w = window.get(player)
  local main = w and common.find(w, "stoich_plan_main")
  if main then main.clear() end
  window.refresh(player)
end }

return plan_window
