-- The recipe dialog: a recipe on a machine, with its modules and beacons, added by hand.
-- From the editor (Add recipe) it becomes a line of the open factory; from the plan
-- (New recipe) a factory of its own, one line (a recycler for copper cable, say).
-- The recipe is picked by item (its recycling first) or directly.

local common = require("scripts.gui.common")
local editor = require("scripts.gui.editor")
local window = require("scripts.gui.window")
local model = require("scripts.model")
local plan = require("scripts.plan")
local scanner = require("scripts.scanner")
local modules = require("scripts.modules")
local fp_util = require("scripts.util")

local L = common.L
local handlers = common.handlers

local recipe_dialog = {}

local function is_recycling(r)
  for _, cat in ipairs(r.categories or {}) do
    if cat == "recycling" then return true end
  end
  return false
end

local function has_item(list, item)
  for _, x in ipairs(list or {}) do
    if x.type == "item" and x.name == item then return true end
  end
  return false
end

--- Recipes for an item: its recycling, the recipes that make it, the ones that use it,
--- then other items' recycling that gives it back; each needs a machine that can craft
--- it. Recycling recipes are hidden in the game: they are the only hidden ones listed.
function recipe_dialog.recipes_for_item(item)
  local own, makes, uses, recycled = {}, {}, {}, {}
  for name, r in pairs(prototypes.recipe) do
    local recycling = is_recycling(r)
    if not r.hidden or recycling then
      local group
      if has_item(r.ingredients, item) then
        group = recycling and own or uses
      elseif has_item(r.products, item) then
        group = recycling and recycled or makes
      end
      if group then group[#group + 1] = { name = name } end
    end
  end
  local by_name = function(a, b) return a.name < b.name end
  local out = {}
  for _, group in ipairs({ own, makes, uses, recycled }) do
    table.sort(group, by_name)
    for _, r in ipairs(group) do
      if #scanner.machines_for_recipe(prototypes.recipe[r.name]) > 0 then out[#out + 1] = r.name end
    end
  end
  return out
end

local function state(player)
  return model.player(player.index).dialog
end

--- The dialog's recipe and machine prototypes, if both are chosen.
local function chosen(dlg)
  local recipe = dlg.recipe and prototypes.recipe[dlg.recipe]
  local name = dlg.machines and dlg.machines[dlg.machine_index or 1]
  local machine = name and prototypes.entity[name]
  return recipe, machine
end

--- Forget modules that no longer fit (another machine, recipe or beacon).
local function keep_fitting(dlg, recipe, machine)
  local fit = {}
  for _, name in ipairs(modules.for_machine(machine, recipe)) do fit[name] = true end
  for slot, name in pairs(dlg.modules) do
    if slot > modules.slots(machine, dlg.machine_quality) or not fit[name] then dlg.modules[slot] = nil end
  end
  local beacons = modules.beacons(machine)
  local has = false
  for _, b in ipairs(beacons) do if b == dlg.beacon then has = true end end
  if not has then dlg.beacon = beacons[1] end
  local beacon = dlg.beacon and prototypes.entity[dlg.beacon]
  fit = {}
  for _, name in ipairs(beacon and modules.for_beacon(beacon, machine, recipe) or {}) do fit[name] = true end
  for slot, name in pairs(dlg.beacon_modules) do
    if not beacon or slot > modules.slots(beacon, dlg.beacon_quality) or not fit[name] then dlg.beacon_modules[slot] = nil end
  end
end

--- Speed and productivity of one machine, in %: modules, beacons, research and the
--- typed extras, capped as the game caps them.
function recipe_dialog.totals(player, dlg)
  local recipe, machine = chosen(dlg)
  if not (recipe and machine) then return nil end
  return modules.totals(machine, recipe, dlg, scanner.research_productivity_pct(player.force, recipe.name))
end

local function signed(pct)
  return (pct >= 0 and "+" or "") .. fp_util.format_count(pct) .. "%"
end

--- Does the dialog show quality: the plan has it, or the player turned it on here.
local function shows_quality(player, dlg)
  return dlg.quality or plan.has_quality(model.selected(player.index))
end

--- Tiers the player can't see don't count: everything normal.
local function drop_qualities(dlg)
  dlg.recipe_quality, dlg.machine_quality, dlg.beacon_quality = nil, nil, nil
  dlg.every_quality = nil
  dlg.module_qualities, dlg.beacon_module_qualities = {}, {}
end

--- Where the main product's rolls land, "[quality=normal] 90%  [quality=uncommon] 9%…".
local function split_caption(player, dlg, totals)
  local recipe = chosen(dlg)
  if dlg.every_quality then
    local parts = { "" }
    for _, q in ipairs(common.quality_choices(player.force)) do parts[#parts + 1] = "[quality=" .. q .. "]" end
    return L(dlg.target == "factory" and "every-quality-factories" or "every-quality-lines", parts)
  end
  if not (recipe and totals and totals.quality > 0) then return "" end
  local rolls = scanner.rolls(totals.quality, player.force)
  local split = rolls(dlg.recipe_quality or fp_util.NORMAL)
  local parts = { "" }
  for _, q in ipairs(fp_util.quality_levels()) do
    if split[q] and #parts < 19 then parts[#parts + 1] = "[quality=" .. q .. "] " .. fp_util.format_count(100 * split[q], 3) .. "%  " end
  end
  return L("quality-split", fp_util.format_count(100 * totals.quality, 2), parts)
end

local function result_caption(player, dlg)
  local totals = recipe_dialog.totals(player, dlg)
  if not totals then return "" end
  return L("module-result", signed(totals.speed), signed(totals.prod))
end

--- @param qualities table? { [slot] = tier }: pickers with a tier (item-with-quality)
local function module_pickers(parent, names, chosen_names, slots, action, enabled, qualities)
  local flow = parent.add({ type = "flow", direction = "horizontal" })
  flow.style.horizontal_spacing = 2
  for slot = 1, slots do
    if qualities then
      local name = chosen_names[slot]
      flow.add({ type = "choose-elem-button", elem_type = "item-with-quality",
        ["item-with-quality"] = name and { name = name, quality = qualities[slot] or fp_util.NORMAL } or nil, enabled = enabled,
        elem_filters = { { filter = "name", name = names } }, tags = { fp = action, slot = slot } })
    else
      flow.add({ type = "choose-elem-button", elem_type = "item", item = chosen_names[slot], enabled = enabled,
        elem_filters = { { filter = "name", name = names } }, tags = { fp = action, slot = slot } })
    end
  end
  return flow
end

--- Build (or rebuild) the dialog.
--- @param dlg table? its state; nil rebuilds the open one
function recipe_dialog.build(player, dlg)
  dlg = dlg or state(player)
  if not dlg then return end
  local frame = common.open_dialog(player, "recipe", L(dlg.target == "factory" and "new-recipe" or "add-recipe"), dlg)
  local body = frame.add({ type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical" })
  local t = body.add({ type = "table", column_count = 2 })
  t.style.vertical_spacing = 8
  t.style.horizontal_spacing = 12

  local quality = shows_quality(player, dlg)
  if not plan.has_quality(model.selected(player.index)) and common.quality_unlocked(player.force) then
    -- quality before anything in the plan has it: for this dialog
    body.add({ type = "checkbox", caption = L("quality-toggle"), tooltip = L("quality-toggle-tooltip"), state = dlg.quality == true,
      tags = { fp = "dlg_quality_toggle" } })
  end
  t.add({ type = "label", caption = L("recipe-item"), tooltip = L("recipe-item-tooltip") })
  t.add({ type = "choose-elem-button", elem_type = "item", item = dlg.item, tooltip = L("recipe-item-tooltip"), tags = { fp = "dlg_item" } })
  t.add({ type = "label", caption = L("recipe") })
  if dlg.item then
    -- the item's recipes (recycling ones are hidden, so the recipe picker can't show them)
    if dlg.recipes_for ~= dlg.item then
      dlg.recipes = recipe_dialog.recipes_for_item(dlg.item)
      dlg.recipes_for = dlg.item
    end
    if #dlg.recipes == 0 then
      t.add({ type = "label", caption = L("no-recipes"), style = "info_label" })
    else
      local captions, selected = {}, 0
      for i, name in ipairs(dlg.recipes) do
        captions[i] = { "", "[recipe=" .. name .. "] ", prototypes.recipe[name].localised_name }
        if name == dlg.recipe then selected = i end
      end
      t.add({ type = "drop-down", items = captions, selected_index = selected, tooltip = L("recipe-item-tooltip"), tags = { fp = "dlg_recipe_pick" } })
    end
  else
    t.add({ type = "choose-elem-button", elem_type = "recipe", recipe = dlg.recipe, tags = { fp = "dlg_recipe" } })
  end

  if quality then
    t.add({ type = "label", caption = L("recipe-quality"), tooltip = L("recipe-quality-tooltip") })
    -- or every quality: a line (a factory) each, the same machine, modules and beacons
    common.quality_dropdown(t, player.force, dlg.every_quality and common.EVERY_QUALITY or dlg.recipe_quality,
      { fp = "dlg_quality", field = "recipe_quality" }, true)
  end
  t.add({ type = "label", caption = L("machine") })
  local recipe_proto = dlg.recipe and prototypes.recipe[dlg.recipe]
  dlg.machines = recipe_proto and scanner.machines_for_recipe(recipe_proto) or {}
  local items = {}
  for i, name in ipairs(dlg.machines) do items[i] = { "", "[entity=" .. name .. "] ", prototypes.entity[name].localised_name } end
  if #items > 0 then dlg.machine_index = math.min(dlg.machine_index or 1, #items) end
  local machine_row = quality and t.add({ type = "flow", direction = "horizontal" }) or t
  machine_row.add({ type = "drop-down", items = items, selected_index = #items > 0 and dlg.machine_index or 0, tags = { fp = "dlg_machine" } })
  if quality then common.quality_dropdown(machine_row, player.force, dlg.machine_quality, { fp = "dlg_quality", field = "machine_quality" }) end
  t.add({ type = "label", caption = L("count"), tooltip = L(dlg.target == "factory" and "recipe-count-tooltip" or "line-count-tooltip") })
  common.number_field(t, dlg.count or 1, { fp = "dlg_num", field = "count" })

  local recipe, machine = chosen(dlg)
  if recipe and machine then
    keep_fitting(dlg, recipe, machine)
    t.add({ type = "label", caption = L("modules") })
    local fit = modules.for_machine(machine, recipe)
    if #fit > 0 then
      module_pickers(t, fit, dlg.modules, modules.slots(machine, dlg.machine_quality), "dlg_module", true, quality and dlg.module_qualities or nil)
    else
      t.add({ type = "label", caption = L("modules-none"), style = "info_label" })
    end
    local beacons = modules.beacons(machine)
    if #beacons > 0 then
      t.add({ type = "label", caption = L("beacons"), tooltip = L("beacons-tooltip") })
      local row = t.add({ type = "flow", direction = "horizontal" })
      row.style.vertical_align = "center"
      common.number_field(row, dlg.beacon_count or 0, { fp = "dlg_num", field = "beacon_count" }, { width = 50, tooltip = L("beacons-tooltip") })
      local captions, selected = {}, 1
      for i, name in ipairs(beacons) do
        captions[i] = { "", "[entity=" .. name .. "] ", prototypes.entity[name].localised_name }
        if name == dlg.beacon then selected = i end
      end
      row.add({ type = "drop-down", items = captions, selected_index = selected, tags = { fp = "dlg_beacon" } })
      if quality then common.quality_dropdown(row, player.force, dlg.beacon_quality, { fp = "dlg_quality", field = "beacon_quality" }) end
      local beacon = prototypes.entity[dlg.beacon]
      local bfit = modules.for_beacon(beacon, machine, recipe)
      if #bfit > 0 then
        module_pickers(row, bfit, dlg.beacon_modules, modules.slots(beacon, dlg.beacon_quality), "dlg_beacon_module", true,
          quality and dlg.beacon_module_qualities or nil)
      end
    end
  end

  t.add({ type = "label", caption = L("speed-pct"), tooltip = L("speed-pct-tooltip") })
  common.number_field(t, dlg.speed or 0, { fp = "dlg_num", field = "speed" }, { negative = true })
  t.add({ type = "label", caption = L("prod-pct"), tooltip = L("prod-pct-tooltip") })
  common.number_field(t, dlg.prod or 0, { fp = "dlg_num", field = "prod" })
  local totals = recipe_dialog.totals(player, dlg)
  if totals and totals.research > 0 then
    body.add({ type = "label", caption = L("research-prod", fp_util.format_count(totals.research)), style = "info_label" })
  end
  body.add({ type = "label", name = "stoich_module_result", caption = result_caption(player, dlg), style = "bold_label" })
  if quality then
    local split = body.add({ type = "label", name = "stoich_quality_split", caption = split_caption(player, dlg, totals), tooltip = L("quality-split-tooltip") })
    split.style.single_line = false
  end

  local buttons = common.dialog_buttons(frame)
  buttons.add({ type = "button", caption = L("cancel"), style = "back_button", tags = { fp = "dialog_close" } })
  common.spacer(buttons)
  -- modules and beacons as a machine on the map has them (the recipe stays this one)
  buttons.add({ type = "button", caption = L("pick-machine"), tooltip = L("pick-machine-tooltip"),
    enabled = recipe ~= nil and #(dlg.machines or {}) > 0, tags = { fp = "dlg_pick_machine" } })
  buttons.add({ type = "button", caption = L(dlg.target == "factory" and "create" or "add"), style = "confirm_button",
    enabled = recipe ~= nil and machine ~= nil, tags = { fp = "dlg_recipe_ok" } })
end

--- Open the dialog: target "line" adds to the open factory, "factory" makes a new one.
function recipe_dialog.open(player, target)
  recipe_dialog.build(player, {
    kind = "recipe", target = target, count = 1, speed = 0, prod = 0, machine_index = 1,
    modules = {}, beacon_count = 0, beacon_modules = {}, module_qualities = {}, beacon_module_qualities = {},
  })
end

handlers.editor_add_recipe = function(player)
  recipe_dialog.open(player, "line")
end

handlers.fac_new_recipe = function(player)
  if not model.can_edit(player) then
    player.print(L("no-permission"))
    return
  end
  recipe_dialog.open(player, "factory")
end

-- Every choice rebuilds the dialog: what fits depends on it.
local function choice(fn)
  return function(player, element)
    local dlg = state(player)
    if not dlg then return end
    fn(dlg, element)
    recipe_dialog.build(player)
  end
end

handlers.dlg_item = { elem = choice(function(dlg, element)
  dlg.item = element.elem_value
  -- its first recipe (the recycling, when it has one) is picked at once
  dlg.recipe = dlg.item and recipe_dialog.recipes_for_item(dlg.item)[1] or nil
  dlg.machine_index = 1
end) }

handlers.dlg_recipe = { elem = choice(function(dlg, element)
  dlg.recipe = element.elem_value
  dlg.machine_index = 1
end) }

handlers.dlg_recipe_pick = { selection = choice(function(dlg, element)
  dlg.recipe = dlg.recipes and dlg.recipes[element.selected_index] or dlg.recipe
  dlg.machine_index = 1
end) }

handlers.dlg_machine = { selection = choice(function(dlg, element)
  dlg.machine_index = element.selected_index
end) }

-- a module picker's value: a name, or { name, quality } when it shows tiers
local function set_module(names, qualities, slot, value)
  if type(value) == "table" then
    names[slot] = value.name
    qualities[slot] = value.quality ~= fp_util.NORMAL and value.quality or nil
  else
    names[slot] = value
    qualities[slot] = nil
  end
end

handlers.dlg_module = { elem = choice(function(dlg, element)
  dlg.module_qualities = dlg.module_qualities or {}
  set_module(dlg.modules, dlg.module_qualities, element.tags.slot, element.elem_value)
end) }

handlers.dlg_quality = { selection = choice(function(dlg, element)
  local q = common.picked_quality(element)
  if element.tags.field == "recipe_quality" then
    dlg.every_quality = q == common.EVERY_QUALITY or nil
    if dlg.every_quality then q = nil end
  end
  dlg[element.tags.field] = q
end) }

handlers.dlg_quality_toggle = { checked = choice(function(dlg, element)
  dlg.quality = element.state or nil
  if not dlg.quality then drop_qualities(dlg) end
end) }

handlers.dlg_beacon = { selection = choice(function(dlg, element)
  local recipe, machine = chosen(dlg)
  local beacons = machine and modules.beacons(machine) or {}
  dlg.beacon = beacons[element.selected_index] or dlg.beacon
end) }

handlers.dlg_beacon_module = { elem = choice(function(dlg, element)
  dlg.beacon_module_qualities = dlg.beacon_module_qualities or {}
  set_module(dlg.beacon_modules, dlg.beacon_module_qualities, element.tags.slot, element.elem_value)
end) }

-- Typed numbers update the result in place (a rebuild would take the focus away).
handlers.dlg_num = { text = function(player, element)
  local dlg = state(player)
  local v = fp_util.parse_number(element.text)
  if not (dlg and v) then return end
  dlg[element.tags.field] = v
  local frame = player.gui.screen.stoich_dialog
  local result = frame and common.find(frame, "stoich_module_result")
  if result then result.caption = result_caption(player, dlg) end
  local split = frame and common.find(frame, "stoich_quality_split")
  if split then split.caption = split_caption(player, dlg, recipe_dialog.totals(player, dlg)) end
end }

-- Copy from a machine ----------------------------------------------------------------------------

local CRAFTERS = { ["assembling-machine"] = true, ["furnace"] = true, ["rocket-silo"] = true }

local function tier_of(q)
  local name = q and (type(q) == "string" and q or q.name)
  if name == nil or name == fp_util.NORMAL then return nil end
  return name
end

--- The modules in an inventory by slot: names, and tiers above normal (empty slots are
--- holes), and how many slots it has.
local function slots_of(inv)
  local names, tiers = {}, {}
  if not inv then return names, tiers, 0 end
  for i = 1, #inv do
    local stack = inv[i]
    if stack and stack.valid_for_read then
      names[i] = stack.name
      tiers[i] = tier_of(stack.quality)
    end
  end
  return names, tiers, #inv
end

--- A machine on the map as the dialog's settings: the machine and its tier, its modules,
--- and its beacons (the most common kind of them: type, tier, modules; how many) (runtime).
--- @return table { machine, machine_quality, modules, module_qualities, beacon?, beacon_quality?,
---   beacon_count, beacon_modules, beacon_module_qualities, mixed (beacons of several kinds) }
function recipe_dialog.read_machine(entity)
  local out = { machine = entity.name, machine_quality = tier_of(entity.quality), beacon_count = 0, beacon_modules = {}, beacon_module_qualities = {} }
  out.modules, out.module_qualities = slots_of(entity.get_module_inventory())
  local kinds, order = {}, {}
  for _, b in ipairs(entity.get_beacons() or {}) do
    if b.valid then
      local names, tiers, slots = slots_of(b.get_module_inventory())
      -- by every slot (a module in slot 2 only isn't an empty beacon; # stops at a hole)
      local parts = { b.name, tier_of(b.quality) or "" }
      for slot = 1, slots do parts[#parts + 1] = (names[slot] or "") .. "/" .. (tiers[slot] or "") end
      local id = table.concat(parts, "|")
      local k = kinds[id]
      if not k then
        k = { n = 0, name = b.name, quality = tier_of(b.quality), modules = names, tiers = tiers }
        kinds[id] = k
        order[#order + 1] = id
      end
      k.n = k.n + 1
    end
  end
  table.sort(order)
  local best
  for _, id in ipairs(order) do
    if not best or kinds[id].n > best.n then best = kinds[id] end
  end
  if best then
    out.beacon, out.beacon_quality, out.beacon_count = best.name, best.quality, best.n
    out.beacon_modules, out.beacon_module_qualities = best.modules, best.tiers
  end
  out.mixed = #order > 1
  return out
end

--- Copy from a machine: the dialog waits (hidden) while the player selects one with the tool.
handlers.dlg_pick_machine = function(player)
  local state = model.player(player.index)
  local dlg = state.dialog
  if not dlg then return end
  if not player.clear_cursor() then return end
  common.close_dialog(player)
  state.pick_machine = dlg -- set after clearing the cursor, which would cancel it
  player.cursor_stack.set_stack({ name = "stoich-selection-tool", count = 1 })
  window.set_hidden(player, true, L("pick-machine-hint"))
end

--- The player selected an area with the tool: the first machine that can craft the
--- dialog's recipe gives its machine, modules and beacons; the dialog comes back.
function recipe_dialog.machine_picked(player, entities, dlg)
  window.set_hidden(player, false)
  local machines = {}
  for i, name in ipairs(dlg.machines or {}) do machines[name] = i end
  local found, other
  for _, e in ipairs(entities or {}) do
    if e.valid and CRAFTERS[e.type] then
      if machines[e.name] and not found then found = e end
      other = other or e
    end
  end
  if found then
    local m = recipe_dialog.read_machine(found)
    dlg.machine_index = machines[m.machine]
    dlg.machine_quality = m.machine_quality
    dlg.modules, dlg.module_qualities = m.modules, m.module_qualities
    dlg.beacon_count = m.beacon_count
    if m.beacon then dlg.beacon, dlg.beacon_quality = m.beacon, m.beacon_quality end
    dlg.beacon_modules, dlg.beacon_module_qualities = m.beacon_modules, m.beacon_module_qualities
    -- tiers to show: the dialog turns quality on when the machine has some
    local tiered = m.machine_quality or m.beacon_quality
    for _, q in pairs(m.module_qualities) do tiered = tiered or q end
    for _, q in pairs(m.beacon_module_qualities) do tiered = tiered or q end
    if tiered then dlg.quality = true end
    if m.mixed then player.print(L("pick-machine-mixed", m.beacon_count, common.entity_name(m.beacon))) end
  elseif other then
    player.print(L("pick-machine-wrong", common.entity_name(other.name)))
  else
    player.print(L("pick-machine-none"))
  end
  recipe_dialog.build(player, dlg)
end

--- The tool left the cursor without a selection: the dialog comes back as it was.
function recipe_dialog.cancel_pick(player)
  local state = model.player(player.index)
  local dlg = state.pick_machine
  state.pick_machine = nil
  window.set_hidden(player, false)
  if dlg then recipe_dialog.build(player, dlg) end
end

--- The line the dialog adds, at a recipe quality (nil: normal).
local function make_line(player, dlg, recipe, machine, count, recipe_quality)
  -- the line keeps its configuration, so research changes it later (Update all)
  local config = modules.line_config(dlg, machine.name)
  config.recipe_quality = recipe_quality
  return {
    kind = "recipe", recipe = recipe.name, machine = machine.name, count = count,
    flow = scanner.config_flow(recipe.name, config, player.force),
    manual = true, config = config, recipe_quality = config.recipe_quality, machine_quality = config.machine_quality,
  }
end

--- A factory of one line: a copy is `count` machines, everything it uses and makes
--- crosses its boundary.
local function one_line_factory(line, count)
  local f = model.new_factory("factory")
  local added = model.add_line(f, line)
  f.anchors[added.id] = count > 0 and count or 1
  for item in pairs(added.flow) do f.external[item] = true end
  return f
end

handlers.dlg_recipe_ok = function(player)
  local dlg = state(player)
  if not dlg then return end
  local recipe, machine = chosen(dlg)
  local totals = recipe_dialog.totals(player, dlg)
  if not (recipe and machine and totals) then return end
  local count = math.max(0, dlg.count or 1)
  if not shows_quality(player, dlg) then drop_qualities(dlg) end
  local target = dlg.target
  if dlg.every_quality then
    -- a line (a factory) per unlocked quality: a recycler takes whatever comes, so each
    -- quality of its input needs one
    local lines = {}
    for _, q in ipairs(common.quality_choices(player.force)) do
      lines[#lines + 1] = make_line(player, dlg, recipe, machine, count, q ~= fp_util.NORMAL and q or nil)
    end
    common.close_dialog(player)
    if target ~= "factory" then
      editor.add_manual_lines(player, lines)
      return
    end
    -- factories of their own (the plan balance sets each one's copies), saved at once
    if not model.can_edit(player) then return player.print(L("no-permission")) end
    local key = model.selected(player.index)
    for _, line in ipairs(lines) do
      local f = one_line_factory(line, count)
      local q = line.recipe_quality
      f.name = fp_util.pretty_name(recipe.name) .. (q and (" (" .. fp_util.pretty_name(q) .. ")") or "")
      f.icon = { type = "recipe", name = recipe.name }
      plan.balance_factory(f)
      model.save_factory(f, nil, player.index, false, key)
    end
    player.print(L("every-quality-added", #lines))
    window.plan_changed(key)
    return
  end
  local line = make_line(player, dlg, recipe, machine, count, modules.line_config(dlg, machine.name).recipe_quality)
  common.close_dialog(player)
  if target ~= "factory" then
    editor.add_manual_line(player, line)
    return
  end
  local f = one_line_factory(line, count)
  f.name = fp_util.pretty_name(recipe.name)
  f.icon = { type = "recipe", name = recipe.name }
  editor.open_factory(player, f, { translate_name = recipe.localised_name })
end

return recipe_dialog
