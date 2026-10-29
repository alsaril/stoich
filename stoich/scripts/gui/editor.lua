-- Factory and sink editor, in its own window over the plan. Works on the player's
-- private draft (storage.players[i].draft); others see changes only after Save.
-- The draft and the window live together: closing the window drops the draft
-- (after asking when it has unsaved changes).

local common = require("scripts.gui.common")
local window = require("scripts.gui.window")
local splits = require("scripts.gui.splits")
local problems = require("scripts.gui.problems")
local scopes = require("scripts.gui.scopes")
local rows = require("scripts.gui.rows")
local model = require("scripts.model")
local plan = require("scripts.plan")
local draft = require("scripts.draft")
local scanner = require("scripts.scanner")
local solver = require("scripts.solver")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local editor = {}

local function get_draft(player)
  return draft.get(player.index)
end

--- A handler that needs the player's draft: fn(player, element, event, draft);
--- nothing happens when there is none (an element outliving its draft).
local function with_draft(fn)
  return function(player, element, event)
    local d = get_draft(player)
    if d then return fn(player, element, event, d) end
  end
end

local function find_line(d, id)
  return (model.find_line(d.factory, id))
end

local function rebalance(player)
  local d = get_draft(player)
  if d then
    -- re-check prototypes so deleting or overriding a broken line repairs the factory
    model.validate_factory(d.factory)
    plan.balance_factory(d.factory)
  end
  return d
end

local function container(player)
  return window.child_content(player, "stoich_editor")
end

-- Opening ------------------------------------------------------------------------------------

--- Open the editor window on the player's draft (in place of the main window), built afresh.
local function show_editor(player)
  local d = get_draft(player)
  if not d then return end
  local caption = L(d.factory.kind == "sink" and "editor-title-sink" or "editor-title")
  -- always the one-column layout, just wide enough for the recipe lines table;
  -- a sink is only a short list of items and rates
  local sink = d.factory.kind == "sink"
  -- the width is set on every open: the same window can switch between a factory and a sink
  local _, content = window.open_child(player, "stoich_editor", caption,
    { width = sink and window.SINK_WIDTH or window.EDITOR_WIDTH, height = window.SIZE.height })
  content.clear()
  editor.build(player, content, common.ctx(player))
end

local function really_open(player, factory, opts)
  local d = draft.open(player.index, factory)
  if opts and opts.notice then d.notice = opts.notice end
  -- Default name: the localised name of the main product, once translated.
  if opts and opts.translate then
    d.name_auto = true
    d.name_request = player.request_translation(fp_util.localised(opts.translate))
  elseif opts and opts.auto_name then
    d.name_auto = true -- named after the first item picked, unless the player types a name
  end
  show_editor(player)
end

--- Open a factory table (new or a copy of a saved one) in the player's editor.
--- An unsaved draft is never dropped silently: the player is asked first.
--- @param opts table? { notice = LocalisedString, translate = item key for the default name }
--- @return boolean opened now (false: waiting for the discard question)
function editor.open_factory(player, factory, opts)
  local current = draft.get(player.index)
  if current and factory.id and current.factory.id == factory.id then
    show_editor(player) -- already editing this one
    return true
  end
  if draft.is_dirty(current) then
    model.player(player.index).pending_open = { factory = fp_util.deep_copy(factory), opts = opts }
    show_editor(player)
    editor.discard_dialog(player)
    return false
  end
  really_open(player, factory, opts)
  return true
end

--- Ask before dropping unsaved changes. What happens on "discard" is in
--- state.pending_open (open another factory) or state.pending_close ("editor" or "all").
--- @param confirm string? locale key of the discard button (default "discard-open")
function editor.discard_dialog(player, confirm)
  local d = draft.get(player.index)
  local frame = common.open_dialog(player, "discard", L("discard-title"))
  local body = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  body.add({ type = "label", caption = L("discard-question", d and d.factory.name or "") })
  local buttons = common.dialog_buttons(frame)
  buttons.add({ type = "button", caption = L("keep-editing"), style = "back_button", tags = { fp = "discard_keep" } })
  common.spacer(buttons)
  buttons.add({ type = "button", caption = L(confirm or "discard-open"), style = "red_confirm_button", tags = { fp = "discard_ok" } })
end

--- Drop the draft and close the editor window.
local function close_editor(player)
  local state = model.player(player.index)
  state.recapture = nil
  state.pending_open = nil
  state.pending_close = nil
  draft.close(player.index)
  common.close_dialog(player)
  window.destroy_child(player, "stoich_editor")
end

local function ask_before_closing(player, what)
  model.player(player.index).pending_close = what
  editor.discard_dialog(player, "discard-close")
  window.refocus(player) -- the window stays open: Esc / E goes back to it
end

window.register_child("stoich_editor", {
  -- the player closed it: ask first when there are unsaved changes
  close = function(player)
    if draft.is_dirty(get_draft(player)) then return ask_before_closing(player, "editor") end
    close_editor(player)
  end,
  -- the main window takes the editor with it: ask first, then drop the draft
  before_close_all = function(player)
    if draft.is_dirty(get_draft(player)) then
      ask_before_closing(player, "all")
      return false
    end
    close_editor(player)
    return true
  end,
  dismiss = function(player) close_editor(player) end,
  -- the windows are hidden while the capture tool is out for a recapture
  keep_open = function(player)
    return model.player(player.index).recapture and get_draft(player) ~= nil
  end,
  -- shared state (permissions, belt settings) may have changed: the draft itself didn't
  refresh = function(player) editor.update_results(player) end,
  rebuild = function(player) editor.rebuild(player) end,
})

handlers.discard_keep = function(player)
  local state = model.player(player.index)
  state.pending_open = nil
  state.pending_close = nil
  common.close_dialog(player)
  window.refocus(player)
end

handlers.discard_ok = function(player)
  local state = model.player(player.index)
  local pending, closing = state.pending_open, state.pending_close
  state.pending_open = nil
  state.pending_close = nil
  common.close_dialog(player)
  if pending then
    really_open(player, pending.factory, pending.opts)
  elseif closing == "editor" then
    close_editor(player)
  elseif closing == "all" then
    close_editor(player)
    window.close_all(player)
  end
end

function editor.open_saved(player, id)
  local f = model.get(id)
  if not f then return end
  editor.open_factory(player, f)
end

function editor.rebuild(player)
  local content = container(player)
  if not content then return end
  content.clear()
  editor.build(player, content, common.ctx(player))
end

--- Reopen the editor window if the player has a draft (after a mod update or a rejoin).
function editor.restore(player)
  if get_draft(player) then show_editor(player) end
end

-- Line helpers -----------------------------------------------------------------------------

local function main_output(line)
  local best, best_v = nil, 0
  for _, key in ipairs(fp_util.sorted_keys(line.flow)) do
    if line.flow[key] > best_v then best, best_v = key, line.flow[key] end
  end
  return best
end

local function line_name(line)
  local caption = common.line_caption(line)
  if line.overridden then return { "", caption, " ", L("overridden-mark") } end
  return caption
end

-- In-place updates ------------------------------------------------------------------------------

local function save_state(player, d, ctx)
  local f = d.factory
  local r = f.result
  if not ctx.can_edit then return false, L("save-no-permission") end
  if (f.name or "") == "" then return false, L("save-no-name") end
  if f.kind ~= "sink" and #plan.solvable_lines(f) == 0 then return false, L("save-no-lines") end
  if r.status ~= "EXACT" then return false, L("save-not-exact", L("status-" .. r.status)) end
  return true, nil
end

-- Items of the factory in three groups: what comes in, what goes out, and what
-- is made and used up inside. Each item can be marked external.
local ITEM_GROUPS = {
  { key = "inputs", caption = "items-inputs", tooltip = "items-inputs-tooltip" },
  { key = "outputs", caption = "items-outputs", tooltip = "items-outputs-tooltip" },
  { key = "inside", caption = "items-inside", tooltip = "items-inside-tooltip" },
  { key = "unused", caption = "items-not-used", tooltip = "items-not-used-tooltip", optional = true },
}

local function render_items(box, player, d, ctx)
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
  for _, group in ipairs(ITEM_GROUPS) do
    if not (group.optional and #groups[group.key] == 0) then
      t.add({ type = "empty-widget" })
      local head = t.add({ type = "label", caption = { "", L(group.caption), " (" .. #groups[group.key] .. ")" }, style = "caption_label",
        tooltip = L(group.tooltip) })
      head.style.top_margin = 6
      for _ = 1, 4 do t.add({ type = "empty-widget" }) end
      for _, key in ipairs(groups[group.key]) do
        t.add({ type = "sprite", sprite = common.key_sprite(key), tooltip = fp_util.localised(key) })
        local name = t.add({ type = "label", caption = fp_util.localised(key) })
        name.style.maximal_width = 200
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
    end
  end
end

--- Update everything that depends on the balance without touching inputs.
function editor.update_results(player, skip_split, skip_line)
  local d = get_draft(player)
  local root = container(player)
  if not (d and root and root.valid) then return end
  local ctx = common.ctx(player)
  local f = d.factory
  local r = f.result

  local status = common.find(root, "stoich_status")
  if status then
    status.caption = L("status-" .. r.status)
    status.style.font_color = common.status_color(r.status)
  end
  local count = common.find(root, "stoich_problem_count")
  if count then
    local n = problems.count(r)
    count.caption = n > 0 and L("status-problems", n) or ""
  end

  local lines_table = common.find(root, "stoich_lines")
  if lines_table then
    for _, line in ipairs(f.lines) do
      local solved = lines_table["solved_" .. line.id]
      local diff = lines_table["diff_" .. line.id]
      local c = r.counts[line.id]
      local unknown = r.undetermined[line.id] or c == nil
      if solved then solved.caption = unknown and "?" or fp_util.format_count(c) end
      if diff then
        if unknown or line.idle then
          diff.caption = ""
        else
          -- machines still to build; extra machines in grey with a tooltip
          local dv = c - (line.count or 0)
          diff.caption = (dv > 0.005 and "+" or "") .. fp_util.format_count(dv)
          diff.style.font_color = dv > 0.005 and common.YELLOW or common.GREY
          diff.tooltip = dv < -0.005 and L("more-machines-tooltip", fp_util.format_count(-dv)) or nil
        end
      end
      if lines_table["out_" .. line.id .. "_rate"] then
        local out = main_output(line)
        local rate = (out and c and not unknown) and c * line.flow[out] or nil
        -- the product's icon in front when it isn't the line's own item (a recipe with
        -- several products, say); the line's icon already shows the rest
        local _, out_name = fp_util.parse_key(out or "")
        local own = out_name == line.recipe or out_name == line.resource
        common.set_rate_cells(lines_table, "out_" .. line.id, ctx, rate, out, line.fluid_keys, rate and not own and fp_util.rich(out) or nil)
      end
    end
  end

  local items = common.find(root, "stoich_items_box")
  if items then render_items(items, player, d, ctx) end
  local pbox = common.find(root, "stoich_problems_box")
  if pbox then
    pbox.clear()
    problems.render(pbox, player, "factory", r, ctx)
  end
  local splits_box = common.find(root, "stoich_splits_box")
  if splits_box then
    for i in ipairs(f.splits) do
      splits.update_card(splits_box, player, "factory", i, i == skip_split and skip_line or nil)
    end
  end
  local save = common.find(root, "stoich_save")
  if save then
    local ok, why = save_state(player, d, ctx)
    save.enabled = ok
    save.tooltip = why
    local note = common.find(root, "stoich_save_note")
    if note then
      note.visible = why ~= nil
      note.stoich_save_reason.caption = why or ""
    end
  end
end

-- Building -----------------------------------------------------------------------------------

local function build_header(parent, player, d, ctx)
  local f = d.factory
  local bar = parent.add({ type = "frame", style = "subheader_frame", direction = "horizontal" })
  bar.style.horizontally_stretchable = true
  bar.style.height = 44
  bar.style.vertical_align = "center"
  bar.add({ type = "label", caption = L(f.kind == "sink" and "sink-name" or "factory-name") })
  local name = bar.add({ type = "textfield", name = "stoich_name", text = f.name or "", enabled = ctx.can_edit, tags = { fp = "editor_name" } })
  name.style.width = 180
  bar.add({ type = "choose-elem-button", elem_type = "signal", signal = f.icon and { type = f.icon.type, name = f.icon.name } or nil,
    enabled = ctx.can_edit, tooltip = L("icon"), tags = { fp = "editor_icon" } })
  common.spacer(bar)
  -- a sink is always balanced: no status there
  if f.kind ~= "sink" then
    common.status_label(bar, f.result.status, "stoich_status")
    bar.add({ type = "label", name = "stoich_problem_count", caption = "" })
  end
end

--- A notice (idle machines found, recapture in progress…) on its own line under the header.
local function build_notice(parent, d)
  if not d.notice then return end
  local row = parent.add({ type = "flow", direction = "horizontal" })
  row.style.vertical_align = "center"
  local icon = row.add({ type = "sprite", sprite = "utility/tip_icon" })
  icon.style.size = 16
  icon.style.stretch_image_to_widget_size = true
  row.add({ type = "label", caption = d.notice, style = "info_label" })
end

local function build_lines(parent, player, d, ctx)
  local f = d.factory
  parent.add({ type = "label", caption = L("section-lines"), style = "caption_label" })
  local t = parent.add({ type = "table", name = "stoich_lines", column_count = 13, draw_horizontal_line_after_headers = true })
  t.style.horizontal_spacing = 10
  -- numbers right-aligned; the anchor (checkbox + count) left-aligned with a gap after "Built"
  for _, i in ipairs({ 4, 7, 8, 9, 11 }) do t.style.column_alignments[i] = "right" end
  local heads = { "", "col-line", "col-machine", "col-scanned", "col-anchor", "", "col-solved", "col-diff", "col-output", "col-belt", "col-fill", "", "" }
  for _, h in ipairs(heads) do
    if h == "" then t.add({ type = "empty-widget" }) else
      local caption = L(h)
      if h == "col-output" then caption = { "", L(h), " (", common.unit_suffix(ctx), ")" } end
      local head = t.add({ type = "label", caption = caption, style = "bold_label", tooltip = L(h .. "-tooltip") })
      if h == "col-anchor" then head.style.left_margin = 16 end
    end
  end
  for _, line in ipairs(f.lines) do
    local id = line.id
    if line.idle then
      -- same size as the recipe icons in the other rows
      local warn = t.add({ type = "sprite", sprite = "utility/warning_icon", tooltip = L("idle-tooltip") })
      warn.style.size = 16
      warn.style.stretch_image_to_widget_size = true
      t.add({ type = "label", caption = L("idle-line", line.count), tooltip = L("idle-tooltip") })
      local m = common.machine_sprite(line)
      if m then t.add({ type = "sprite", sprite = m }) else t.add({ type = "empty-widget" }) end
      t.add({ type = "label", caption = fp_util.format_count(line.count) })
      if line.kind == "recipe" then
        -- only recipes this machine can craft
        local machine = line.machine and prototypes.entity[line.machine]
        local filters
        if machine and machine.crafting_categories then
          filters = {}
          for _, cat in ipairs(fp_util.sorted_keys(machine.crafting_categories)) do
            filters[#filters + 1] = { filter = "category", category = cat }
          end
        end
        -- labelled, so it doesn't read as another empty field
        local assign = t.add({ type = "flow", direction = "horizontal" })
        assign.style.vertical_align = "center"
        assign.style.left_margin = 16
        assign.add({ type = "label", caption = L("assign-recipe-label") })
        local picker = assign.add({ type = "choose-elem-button", elem_type = "recipe", elem_filters = filters, enabled = ctx.can_edit,
          tooltip = L("assign-recipe"), tags = { fp = "editor_assign_recipe", line = id } })
        picker.style.size = 28
      else
        t.add({ type = "empty-widget" })
      end
      for _ = 1, 7 do t.add({ type = "empty-widget" }) end
    else
      t.add({ type = "sprite", sprite = common.line_sprite(line), tooltip = common.flow_tooltip(ctx, line.flow, { "", line_name(line), " ", L("per-machine") }) })
      -- the Machine column already tells same-recipe lines apart; split cards use the suffixed names
      local name = t.add({ type = "label", caption = line_name(line), tooltip = common.flow_tooltip(ctx, line.flow, L("per-machine")) })
      name.style.maximal_width = 200
      if line.invalid then name.style.font_color = common.RED end
      if line.missing then name.style.font_color = common.GREY end
      local m = common.machine_sprite(line)
      if m then t.add({ type = "sprite", sprite = m }) else t.add({ type = "empty-widget" }) end
      if line.kind == "custom" or line.manual then
        common.number_field(t, line.count, { fp = "editor_line_count", line = id }, { enabled = ctx.can_edit, width = 50, tooltip = L("line-count-tooltip") })
      else
        t.add({ type = "label", caption = fp_util.format_count(line.count), tooltip = line.missing and L("missing-tooltip") or nil })
      end
      local anchored = f.anchors[id] ~= nil
      local a = t.add({ type = "flow", direction = "horizontal" })
      a.style.vertical_align = "center"
      a.style.left_margin = 16
      a.add({ type = "checkbox", state = anchored, enabled = ctx.can_edit, tooltip = L("col-anchor-tooltip"),
        tags = { fp = "editor_anchor", line = id } })
      -- the count field only on anchored lines; a same-width gap keeps the columns aligned
      if anchored then
        common.number_field(a, f.anchors[id], { fp = "editor_anchor_value", line = id },
          { enabled = ctx.can_edit, width = 56, name = "anchor_" .. id })
      else
        a.add({ type = "empty-widget" }).style.width = 56
      end
      t.add({ type = "empty-widget" })
      t.add({ type = "label", name = "solved_" .. id, caption = "" })
      t.add({ type = "label", name = "diff_" .. id, caption = "" })
      common.rate_cells(t, ctx, nil, nil, nil, "out_" .. id)
      t.add({ type = "sprite-button", style = "tool_button", sprite = "utility/rename_icon", enabled = ctx.can_edit,
        tooltip = L("edit-flow"), tags = { fp = "editor_edit_flow", line = id } })
    end
    t.add({ type = "sprite-button", style = "tool_button", sprite = "utility/trash", enabled = ctx.can_edit,
      tooltip = L("delete-line"), tags = { fp = "editor_delete_line", line = id } })
  end
  if #f.lines == 0 then parent.add({ type = "label", caption = L("no-lines") }) end
end

local function build_splits(parent, player, d)
  local f = d.factory
  if #f.splits == 0 then return end
  parent.add({ type = "label", caption = L("section-splits"), style = "caption_label" })
  local box = parent.add({ type = "table", name = "stoich_splits_box", column_count = 2 })
  box.style.horizontal_spacing = 8
  box.style.vertical_spacing = 8
  for i, split in ipairs(f.splits) do splits.build_card(box, player, "factory", i, split) end
end

local function build_actions(parent, player, d, ctx)
  local f = d.factory
  -- why Save is disabled, on its own line right above it (set by update_results; hidden
  -- when there is nothing to say). In the button row it would be squeezed to nothing.
  local note = parent.add({ type = "flow", name = "stoich_save_note", direction = "horizontal", visible = false })
  common.spacer(note)
  note.add({ type = "label", name = "stoich_save_reason", caption = "", style = "info_label" })
  local bar = parent.add({ type = "flow", direction = "horizontal" })
  bar.style.horizontal_spacing = 8
  bar.style.top_margin = 4
  if f.kind ~= "sink" then
    bar.add({ type = "button", caption = L("add-recipe"), enabled = ctx.can_edit, tags = { fp = "editor_add_recipe" } })
    bar.add({ type = "button", caption = L("add-custom"), enabled = ctx.can_edit, tags = { fp = "editor_add_custom" } })
    local has_source = f.source and f.source.areas and #f.source.areas > 0
    bar.add({ type = "button", caption = L("rescan"), enabled = ctx.can_edit and has_source or false,
      tooltip = has_source and L("rescan-tooltip") or L("no-area"), tags = { fp = "editor_rescan" } })
    bar.add({ type = "button", caption = L("show-on-map"), enabled = has_source or false, tags = { fp = "editor_show_map" } })
    bar.add({ type = "button", caption = L("recapture"), tooltip = L("recapture-tooltip"), enabled = ctx.can_edit,
      tags = { fp = "editor_recapture" } })
  end
  common.spacer(bar)
  bar.add({ type = "button", caption = L("cancel"), style = "back_button", tags = { fp = "editor_cancel" } })
  bar.add({ type = "button", name = "stoich_save", caption = L("save"), style = "confirm_button", tags = { fp = "editor_save" } })
end

function editor.build(player, parent, ctx)
  local d = get_draft(player)
  local f = d.factory
  if not f.result then plan.balance_factory(f) end
  build_header(parent, player, d, ctx)
  build_notice(parent, d)
  -- problems right under the header: they are what needs doing
  parent.add({ type = "flow", name = "stoich_problems_box", direction = "vertical" })

  local scroll = parent.add({ type = "scroll-pane", style = "scroll_pane" })
  scroll.style.vertically_stretchable = true
  scroll.style.horizontally_stretchable = true
  if f.kind == "sink" then
    local pane = scroll.add({ type = "flow", direction = "vertical" })
    pane.style.vertical_spacing = 6
    pane.style.horizontally_stretchable = true
    local explain = pane.add({ type = "label", caption = L("sink-explain"), style = "info_label" })
    explain.style.single_line = false
    explain.style.maximal_width = window.SINK_WIDTH - 40
    rows.build(pane, player, "sink", ctx, ctx.can_edit, { stretch = true })
  else
    -- one column: recipe lines, splits, then the items
    local body = scroll.add({ type = "flow", direction = "vertical" })
    body.style.vertical_spacing = 6
    build_lines(body, player, d, ctx)
    build_splits(body, player, d)
    body.add({ type = "label", caption = L("section-items"), style = "caption_label" })
    body.add({ type = "flow", name = "stoich_items_box", direction = "vertical" })
  end
  build_actions(parent, player, d, ctx)
  editor.update_results(player)
end

-- Scope of the split cards and problems ------------------------------------------------------------

scopes.factory = {
  holder = function(player) return get_draft(player).factory end,
  units = function(player) return plan.solvable_lines(get_draft(player).factory) end,
  counts = function(player) return get_draft(player).factory.result.counts end,
  names = function(player)
    return common.line_names(get_draft(player).factory.lines, line_name)
  end,
  sprite_of = function(player, id)
    local line = find_line(get_draft(player), id)
    return line and common.line_sprite(line) or "utility/missing_icon"
  end,
  changed = function(player, structural, index, line)
    rebalance(player)
    if structural then editor.rebuild(player) else editor.update_results(player, index, line) end
  end,
  can_edit = function(player) return model.can_edit(player) end,
  -- problem actions
  mark_external = function(player, item)
    local d = get_draft(player)
    draft.set_external(d.factory, item, true)
    rebalance(player)
    editor.rebuild(player)
  end,
  add_sink = function(player, item)
    -- In a factory, a sink is a line that voids the surplus (or supplies a missing input).
    local d = get_draft(player)
    local producers = 0
    for _, line in ipairs(plan.solvable_lines(d.factory)) do
      if (line.flow[item] or 0) > 0 then producers = producers + 1 end
    end
    local amount = producers > 0 and -1 or 1
    local _, name = fp_util.parse_key(item)
    draft.add_custom_line(d.factory, (amount < 0 and "void " or "source ") .. name, { { key = item, amount = amount } })
    rebalance(player)
    editor.rebuild(player)
  end,
  add_split = function(player, item)
    local d = get_draft(player)
    local units = plan.solvable_lines(d.factory)
    draft.add_split(d.factory, item, solver.producers_of(units, item), units)
    rebalance(player)
    editor.rebuild(player)
  end,
  anchor = function(player, line_id)
    local d = get_draft(player)
    local line = find_line(d, line_id)
    if not line then return end
    draft.set_anchor(d.factory, line_id, (line.count or 0) > 0 and line.count or 1)
    rebalance(player)
    editor.rebuild(player)
  end,
}

rows.targets.sink = {
  rows = function(player)
    local f = get_draft(player).factory
    f.sink_items = f.sink_items or {}
    return f.sink_items
  end,
  field = "rate",
  changed = function(player, structural)
    local d = get_draft(player)
    draft.sink_icon(d.factory)
    -- a new sink is named after its first item until the player types a name
    local first = d.factory.sink_items[1]
    if d.name_auto and first and first.key and first.key ~= d.name_key then
      d.name_key = first.key
      local _, n = fp_util.parse_key(first.key)
      d.factory.name = fp_util.pretty_name(n)
      d.name_request = player.request_translation(fp_util.localised(first.key))
      editor.set_name_field(player, d.factory.name)
    end
    rebalance(player)
    if structural then editor.rebuild(player) else editor.update_results(player) end
  end,
}

-- Header handlers ---------------------------------------------------------------------------------

function editor.set_name_field(player, text)
  local root = player and container(player)
  local field = root and root.valid and common.find(root, "stoich_name")
  if field then field.text = text end
end

handlers.editor_name = { text = with_draft(function(player, element, event, d)
  d.name_auto = false
  d.factory.name = element.text
  editor.update_results(player)
end) }

handlers.editor_icon = { elem = with_draft(function(player, element, event, d)
  local v = element.elem_value
  d.factory.icon = v and { type = v.type or "item", name = v.name } or nil
end) }

-- Line handlers ---------------------------------------------------------------------------------------

handlers.editor_anchor = with_draft(function(player, element, _, d)
  local line = find_line(d, element.tags.line)
  if not line then return end
  if element.state then
    local solved = d.factory.result.counts[line.id]
    local v = (line.count or 0) > 0 and line.count or (solved and solved > 0 and solved) or 1
    draft.set_anchor(d.factory, line.id, v)
  else
    draft.set_anchor(d.factory, line.id, nil)
  end
  rebalance(player)
  editor.rebuild(player) -- the count field appears / disappears
end)

handlers.editor_anchor_value = { text = with_draft(function(player, element, event, d)
  local id = element.tags.line
  if d.factory.anchors[id] == nil then return end
  local v = fp_util.parse_number(element.text)
  if not v then return end
  draft.set_anchor(d.factory, id, v)
  rebalance(player)
  editor.update_results(player)
end) }

handlers.editor_line_count = { text = with_draft(function(player, element, event, d)
  local line = find_line(d, element.tags.line)
  local v = fp_util.parse_number(element.text)
  if line and v then
    line.count = math.max(0, v)
    editor.update_results(player)
  end
end) }

handlers.editor_external = with_draft(function(player, element, _, d)
  draft.set_external(d.factory, element.tags.item, element.state)
  rebalance(player)
  editor.update_results(player)
end)

handlers.editor_delete_line = with_draft(function(player, element, _, d)
  model.remove_line(d.factory, element.tags.line)
  rebalance(player)
  editor.rebuild(player)
end)

handlers.editor_assign_recipe = { elem = with_draft(function(player, element, event, d)
  local line = find_line(d, element.tags.line)
  local name = element.elem_value
  if not (line and name) then return end
  local recipe = prototypes.recipe[name]
  local machine = line.machine and prototypes.entity[line.machine]
  if not (recipe and machine) then return end
  local can = false
  for _, m in ipairs(scanner.machines_for_recipe(recipe)) do
    if m == line.machine then can = true end
  end
  if not can then
    player.print(L("recipe-not-for-machine"))
    editor.rebuild(player)
    return
  end
  line.recipe = name
  line.idle = nil
  line.manual = true
  line.prod_pct = scanner.research_productivity_pct(player.force, name)
  line.flow = scanner.manual_recipe_flow(recipe, machine, 0, line.prod_pct)
  -- Rescan won't touch this line, nor re-add the idle machines it came from.
  line.assigned_from = line.key
  line.key = nil
  rebalance(player)
  editor.rebuild(player)
end) }

-- Bottom actions ---------------------------------------------------------------------------------------

handlers.editor_show_map = function(player)
  local d = get_draft(player)
  window.show_on_map(player, d and d.factory.source)
end

handlers.editor_rescan = function(player)
  local d = get_draft(player)
  local source = d and d.factory.source
  if not (source and source.areas) then return end
  local surface = game.get_surface(source.surface_index)
  if not surface then
    player.print(L("no-surface"))
    return
  end
  local entities = scanner.find_in_areas(surface, source.areas, player.force)
  local scan = scanner.scan_entities(entities, player.force)
  local stats = draft.apply_rescan(d.factory, scan)
  rebalance(player)
  d.notice = L("rescan-done", stats.updated, stats.added, stats.missing)
  editor.rebuild(player)
end

-- Recapture: the next area selected with the tool replaces this draft's contents.
handlers.editor_recapture = function(player)
  local d = get_draft(player)
  if not (d and model.can_edit(player)) then return end
  local state = model.player(player.index)
  if player.clear_cursor() then
    state.recapture = true -- set after clearing, which would cancel it
    player.cursor_stack.set_stack({ name = "stoich-selection-tool", count = 1 })
    d.notice = L("recapture-notice")
    editor.rebuild(player)
    -- out of the way while the player drags the new area; back when it is done or cancelled
    window.set_hidden(player, true, L("recapture-hint", d.factory.name or ""))
  end
end

--- Put a fresh capture into the open draft (called by the capture handler);
--- captured nil: the area had no machines, the draft stays as it was.
function editor.recapture(player, captured)
  window.set_hidden(player, false)
  local d = get_draft(player)
  if not d then return false end
  if captured then
    draft.recapture(d.factory, captured)
    d.notice = L("recaptured", #d.factory.lines)
    rebalance(player)
  else
    d.notice = nil
  end
  show_editor(player)
  return true
end

--- The tool left the cursor without a selection: cancel a pending recapture.
function editor.cancel_recapture(player)
  local state = model.player(player.index)
  if not state.recapture then return end
  state.recapture = nil
  window.set_hidden(player, false)
  local d = get_draft(player)
  if d then
    d.notice = nil
    editor.rebuild(player)
  end
end

handlers.editor_cancel = function(player)
  close_editor(player)
end

local function do_save(player, force)
  local d = get_draft(player)
  if not d then return end
  local ctx = common.ctx(player)
  plan.balance_factory(d.factory)
  local ok, why = save_state(player, d, ctx)
  if not ok then
    player.print(why)
    return
  end
  local saved, result = model.save_factory(d.factory, d.base, player.index, force)
  if not saved then
    editor.conflict_dialog(player, result)
    return
  end
  close_editor(player)
  window.plan_changed()
end

handlers.editor_save = function(player)
  do_save(player, false)
end

function editor.conflict_dialog(player, conflict)
  local frame = common.open_dialog(player, "conflict", L("conflict-title"))
  local body = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  if conflict.deleted then
    body.add({ type = "label", caption = L("conflict-deleted") })
  else
    body.add({ type = "label", caption = L("conflict-edited", common.player_name(conflict.modified_by), common.time_ago(conflict.modified_tick)) })
  end
  local buttons = common.dialog_buttons(frame)
  buttons.add({ type = "button", caption = L("cancel"), style = "back_button", tags = { fp = "dialog_close" } })
  common.spacer(buttons)
  if not conflict.deleted then
    buttons.add({ type = "button", caption = L("reload"), tooltip = L("reload-tooltip"), tags = { fp = "conflict_reload" } })
  end
  buttons.add({ type = "button", caption = L(conflict.deleted and "save-again" or "overwrite"), style = "red_confirm_button", tags = { fp = "conflict_overwrite" } })
end

handlers.conflict_overwrite = function(player)
  common.close_dialog(player)
  do_save(player, true)
end

handlers.conflict_reload = function(player)
  common.close_dialog(player)
  local d = get_draft(player)
  local f = d and model.get(d.factory.id)
  if f then
    draft.open(player.index, f)
    editor.rebuild(player)
  end
end

-- Line dialogs --------------------------------------------------------------------------------------------

rows.targets.dialog = {
  rows = function(player)
    local state = model.player(player.index)
    return state.dialog and state.dialog.rows or {}
  end,
  field = "amount",
  allow_negative = true,
  changed = function(player, structural)
    if structural then editor.build_line_dialog(player) end
  end,
}

--- Dialog for a custom line (new) or a flow override of an existing line.
--- @param dlg table? its state; nil rebuilds the open one
function editor.build_line_dialog(player, dlg)
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
  editor.build_line_dialog(player, { kind = "custom", label = "", rows = { {} } })
end

handlers.editor_edit_flow = with_draft(function(player, element, _, d)
  local line = find_line(d, element.tags.line)
  if not line then return end
  editor.build_line_dialog(player, { kind = "override", line = line.id, label = line.label or "", rows = draft.rows_from_flow(line) })
end)

handlers.dlg_line_ok = function(player)
  local state = model.player(player.index)
  local dlg = state.dialog
  local d = get_draft(player)
  if not (dlg and d) then return end
  if dlg.kind == "override" then
    local line = find_line(d, dlg.line)
    if line then
      draft.set_flow(line, dlg.rows)
      line.overridden = line.kind ~= "custom"
      if dlg.label ~= "" then line.label = dlg.label end
    end
  else
    draft.add_custom_line(d.factory, dlg.label ~= "" and dlg.label or "custom", dlg.rows)
  end
  common.close_dialog(player)
  rebalance(player)
  editor.rebuild(player)
end

-- Add recipe dialog

--- @param dlg table? its state; nil rebuilds the open one
function editor.build_recipe_dialog(player, dlg)
  dlg = dlg or model.player(player.index).dialog
  local frame = common.open_dialog(player, "recipe", L("add-recipe"), dlg)
  local body = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  local t = body.add({ type = "table", column_count = 2 })
  t.style.vertical_spacing = 8
  t.style.horizontal_spacing = 12
  t.add({ type = "label", caption = L("recipe") })
  t.add({ type = "choose-elem-button", elem_type = "recipe", recipe = dlg.recipe, tags = { fp = "dlg_recipe" } })
  t.add({ type = "label", caption = L("machine") })
  local machines = dlg.recipe and prototypes.recipe[dlg.recipe] and scanner.machines_for_recipe(prototypes.recipe[dlg.recipe]) or {}
  dlg.machines = machines
  local items = {}
  for i, name in ipairs(machines) do items[i] = { "", "[entity=" .. name .. "] ", prototypes.entity[name].localised_name } end
  t.add({ type = "drop-down", items = items, selected_index = (#items > 0) and math.min(dlg.machine_index or 1, #items) or 0, tags = { fp = "dlg_machine" } })
  t.add({ type = "label", caption = L("count") })
  common.number_field(t, dlg.count or 1, { fp = "dlg_num", field = "count" })
  t.add({ type = "label", caption = L("speed-pct"), tooltip = L("speed-pct-tooltip") })
  common.number_field(t, dlg.speed or 0, { fp = "dlg_num", field = "speed" }, { negative = true })
  t.add({ type = "label", caption = L("prod-pct"), tooltip = L("prod-pct-tooltip") })
  common.number_field(t, dlg.prod or 0, { fp = "dlg_num", field = "prod" })
  local buttons = common.dialog_buttons(frame)
  buttons.add({ type = "button", caption = L("cancel"), style = "back_button", tags = { fp = "dialog_close" } })
  common.spacer(buttons)
  buttons.add({ type = "button", caption = L("add"), style = "confirm_button", enabled = dlg.recipe ~= nil and #machines > 0, tags = { fp = "dlg_recipe_ok" } })
end

handlers.editor_add_recipe = function(player)
  editor.build_recipe_dialog(player, { kind = "recipe", count = 1, speed = 0, prod = 0, machine_index = 1 })
end

handlers.dlg_recipe = { elem = function(player, element, event)
  local dlg = model.player(player.index).dialog
  if not dlg then return end
  dlg.recipe = element.elem_value
  dlg.machine_index = 1
  -- productivity research of this recipe as the default
  if dlg.recipe then dlg.prod = scanner.research_productivity_pct(player.force, dlg.recipe) end
  editor.build_recipe_dialog(player)
end }

handlers.dlg_machine = { selection = function(player, element, event)
  local dlg = model.player(player.index).dialog
  if dlg then dlg.machine_index = element.selected_index end
end }

handlers.dlg_num = { text = function(player, element, event)
  local dlg = model.player(player.index).dialog
  local v = fp_util.parse_number(element.text)
  if dlg and v then dlg[element.tags.field] = v end
end }

handlers.dlg_recipe_ok = function(player)
  local dlg = model.player(player.index).dialog
  local d = get_draft(player)
  if not (dlg and d and dlg.recipe) then return end
  local recipe = prototypes.recipe[dlg.recipe]
  local machine_name = dlg.machines and dlg.machines[dlg.machine_index or 1]
  local machine = machine_name and prototypes.entity[machine_name]
  if not (recipe and machine) then return end
  model.add_line(d.factory, {
    kind = "recipe", recipe = dlg.recipe, machine = machine_name, count = math.max(0, dlg.count or 1),
    flow = scanner.manual_recipe_flow(recipe, machine, dlg.speed, dlg.prod),
    manual = true, speed_pct = dlg.speed, prod_pct = dlg.prod,
  })
  common.close_dialog(player)
  rebalance(player)
  editor.rebuild(player)
end

return editor
