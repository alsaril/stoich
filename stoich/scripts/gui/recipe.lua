-- The recipe dialog: a recipe on a machine, with its modules and beacons, added by hand.
-- From the editor (Add recipe) it becomes a line of the open factory; from the plan
-- (New recipe) a factory of its own, one line (a recycler for copper cable, say).
-- The recipe is picked by item (its recycling first) or directly.

local common = require("scripts.gui.common")
local editor = require("scripts.gui.editor")
local model = require("scripts.model")
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
    if slot > modules.slots(machine) or not fit[name] then dlg.modules[slot] = nil end
  end
  local beacons = modules.beacons(machine)
  local has = false
  for _, b in ipairs(beacons) do if b == dlg.beacon then has = true end end
  if not has then dlg.beacon = beacons[1] end
  local beacon = dlg.beacon and prototypes.entity[dlg.beacon]
  fit = {}
  for _, name in ipairs(beacon and modules.for_beacon(beacon, machine, recipe) or {}) do fit[name] = true end
  for slot, name in pairs(dlg.beacon_modules) do
    if not beacon or slot > (beacon.module_inventory_size or 0) or not fit[name] then dlg.beacon_modules[slot] = nil end
  end
end

--- Speed and productivity of one machine, in %: modules, beacons, research and the
--- typed extras, capped as the game caps them.
function recipe_dialog.totals(player, dlg)
  local recipe, machine = chosen(dlg)
  if not (recipe and machine) then return nil end
  local effect = modules.effect(machine, recipe, dlg)
  local research = scanner.research_productivity_pct(player.force, recipe.name)
  -- the game never goes below -80% speed
  local speed = math.max(-80, 100 * effect.speed + (dlg.speed or 0))
  local prod = math.max(0, 100 * effect.productivity + research + (dlg.prod or 0))
  if recipe.maximum_productivity then prod = math.min(prod, 100 * recipe.maximum_productivity) end
  return { speed = speed, prod = prod, research = research }
end

local function signed(pct)
  return (pct >= 0 and "+" or "") .. fp_util.format_count(pct) .. "%"
end

local function result_caption(player, dlg)
  local totals = recipe_dialog.totals(player, dlg)
  if not totals then return "" end
  return L("module-result", signed(totals.speed), signed(totals.prod))
end

local function module_pickers(parent, names, chosen_names, slots, action, enabled)
  local flow = parent.add({ type = "flow", direction = "horizontal" })
  flow.style.horizontal_spacing = 2
  for slot = 1, slots do
    flow.add({ type = "choose-elem-button", elem_type = "item", item = chosen_names[slot], enabled = enabled,
      elem_filters = { { filter = "name", name = names } }, tags = { fp = action, slot = slot } })
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

  t.add({ type = "label", caption = L("machine") })
  local recipe_proto = dlg.recipe and prototypes.recipe[dlg.recipe]
  dlg.machines = recipe_proto and scanner.machines_for_recipe(recipe_proto) or {}
  local items = {}
  for i, name in ipairs(dlg.machines) do items[i] = { "", "[entity=" .. name .. "] ", prototypes.entity[name].localised_name } end
  if #items > 0 then dlg.machine_index = math.min(dlg.machine_index or 1, #items) end
  t.add({ type = "drop-down", items = items, selected_index = #items > 0 and dlg.machine_index or 0, tags = { fp = "dlg_machine" } })
  t.add({ type = "label", caption = L("count"), tooltip = L(dlg.target == "factory" and "recipe-count-tooltip" or "line-count-tooltip") })
  common.number_field(t, dlg.count or 1, { fp = "dlg_num", field = "count" })

  local recipe, machine = chosen(dlg)
  if recipe and machine then
    keep_fitting(dlg, recipe, machine)
    t.add({ type = "label", caption = L("modules") })
    local fit = modules.for_machine(machine, recipe)
    if #fit > 0 then
      module_pickers(t, fit, dlg.modules, modules.slots(machine), "dlg_module", true)
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
      local beacon = prototypes.entity[dlg.beacon]
      local bfit = modules.for_beacon(beacon, machine, recipe)
      if #bfit > 0 then module_pickers(row, bfit, dlg.beacon_modules, beacon.module_inventory_size or 0, "dlg_beacon_module", true) end
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

  local buttons = common.dialog_buttons(frame)
  buttons.add({ type = "button", caption = L("cancel"), style = "back_button", tags = { fp = "dialog_close" } })
  common.spacer(buttons)
  buttons.add({ type = "button", caption = L(dlg.target == "factory" and "create" or "add"), style = "confirm_button",
    enabled = recipe ~= nil and machine ~= nil, tags = { fp = "dlg_recipe_ok" } })
end

--- Open the dialog: target "line" adds to the open factory, "factory" makes a new one.
function recipe_dialog.open(player, target)
  recipe_dialog.build(player, {
    kind = "recipe", target = target, count = 1, speed = 0, prod = 0, machine_index = 1,
    modules = {}, beacon_count = 0, beacon_modules = {},
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

handlers.dlg_module = { elem = choice(function(dlg, element)
  dlg.modules[element.tags.slot] = element.elem_value
end) }

handlers.dlg_beacon = { selection = choice(function(dlg, element)
  local recipe, machine = chosen(dlg)
  local beacons = machine and modules.beacons(machine) or {}
  dlg.beacon = beacons[element.selected_index] or dlg.beacon
end) }

handlers.dlg_beacon_module = { elem = choice(function(dlg, element)
  dlg.beacon_modules[element.tags.slot] = element.elem_value
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
end }

handlers.dlg_recipe_ok = function(player)
  local dlg = state(player)
  if not dlg then return end
  local recipe, machine = chosen(dlg)
  local totals = recipe_dialog.totals(player, dlg)
  if not (recipe and machine and totals) then return end
  local count = math.max(0, dlg.count or 1)
  local line = {
    kind = "recipe", recipe = recipe.name, machine = machine.name, count = count,
    flow = scanner.manual_recipe_flow(recipe, machine, totals.speed, totals.prod),
    manual = true, speed_pct = totals.speed, prod_pct = totals.prod,
  }
  local target = dlg.target
  common.close_dialog(player)
  if target ~= "factory" then
    editor.add_manual_line(player, line)
    return
  end
  -- a factory of one line: a copy is `count` machines, everything it uses and makes
  -- crosses its boundary
  local f = model.new_factory("factory")
  local added = model.add_line(f, line)
  f.anchors[added.id] = count > 0 and count or 1
  for item in pairs(added.flow) do f.external[item] = true end
  f.name = fp_util.pretty_name(recipe.name)
  f.icon = { type = "recipe", name = recipe.name }
  editor.open_factory(player, f, { translate_name = recipe.localised_name })
end

return recipe_dialog
