-- Shared GUI helpers: event dispatch by element tags, display context
-- (unit, belt tiers), rate labels, sprites, small dialogs.

local fp_util = require("scripts.util")
local belts = require("scripts.belts")
local model = require("scripts.model")
local plan = require("scripts.plan")

local common = {}

--- Handlers by action name. Elements carry tags = { fp = action, ... }.
--- A handler is handler(player, element, event), called for every event of its
--- elements (clicks only on buttons), or a table of them by event kind:
--- { click, checked, value, text, confirmed, selection, elem }.
common.handlers = {}

local KINDS -- event id -> kind name; built on first use (defines exists at runtime only)
local function kind_of(event_name)
  if not KINDS then
    local e = defines.events
    KINDS = {
      [e.on_gui_click] = "click", [e.on_gui_checked_state_changed] = "checked", [e.on_gui_value_changed] = "value",
      [e.on_gui_text_changed] = "text", [e.on_gui_confirmed] = "confirmed",
      [e.on_gui_selection_state_changed] = "selection", [e.on_gui_elem_changed] = "elem",
    }
  end
  return KINDS[event_name]
end

function common.L(key, ...)
  return { "stoich." .. key, ... }
end
local L = common.L

function common.dispatch(event)
  local element = event.element
  if not (element and element.valid) then return end
  local tags = element.tags
  local action = tags and tags.fp
  if not action then return end
  -- Only our own elements: another mod could use the same tag name.
  if element.get_mod() ~= script.mod_name then return end
  -- Clicking a checkbox, dropdown, textfield, slider or picker also raises
  -- on_gui_click; only buttons act on clicks, the rest on their own event.
  if event.name == defines.events.on_gui_click and element.type ~= "button" and element.type ~= "sprite-button" then return end
  local handler = common.handlers[action]
  if type(handler) == "table" then handler = handler[kind_of(event.name)] end
  if not handler then return end
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end
  handler(player, element, event)
end

--- Depth-first search for a named descendant.
function common.find(element, name)
  if not (element and element.valid) then return nil end
  for _, child in pairs(element.children) do
    if child.name == name then return child end
    local found = common.find(child, name)
    if found then return found end
  end
  return nil
end

-- Display context --------------------------------------------------------------------

--- Belts the force has researched (recipe enabled, or no recipe at all).
local function best_researched(tiers, force)
  local best = 1
  for i, tier in ipairs(tiers) do
    local recipe = force.recipes[tier.name]
    if recipe == nil or recipe.enabled then best = i end
  end
  return best
end

--- Per-player view settings: unit, belt tiers, the highest allowed tier, and the plan
--- (surface name) the player looks at.
function common.ctx(player)
  local unit = player.mod_settings["stoich-rate-unit"].value
  local tiers = belts.read_tiers(player.force)
  local chosen = settings.global["stoich-max-belt"].value
  local max_index = chosen ~= "" and belts.index_of(tiers, chosen) or best_researched(tiers, player.force)
  return {
    player = player,
    unit = unit,
    tiers = tiers,
    max_index = max_index,
    one_lane = settings.global["stoich-one-lane"].value,
    can_edit = model.can_edit(player),
    plan = model.selected(player.index),
  }
end

function common.unit_suffix(ctx)
  return fp_util.UNITS[ctx.unit].suffix
end

--- Convert a typed rate in the display unit to per second.
function common.to_per_second(ctx, v)
  return v / fp_util.UNITS[ctx.unit].factor
end

function common.from_per_second(ctx, v)
  return v * fp_util.UNITS[ctx.unit].factor
end

--- Localised name of an entity prototype (its own localised_name, which mods may customise).
function common.entity_name(name)
  local p = prototypes.entity[name]
  return p and p.localised_name or name
end

local RED = { r = 1, g = 0.35, b = 0.3 }
local GREEN = { r = 0.4, g = 0.9, b = 0.4 }
local YELLOW = { r = 1, g = 0.85, b = 0.3 }
local GREY = { r = 0.6, g = 0.6, b = 0.6 }
common.RED, common.GREEN, common.YELLOW, common.GREY = RED, GREEN, YELLOW, GREY
common.BLUE = { r = 0.35, g = 0.6, b = 1 } -- consumption: neutral, not an error

--- A rate split for display: the number, the slowest belt that carries it, and how
--- full that belt is. Fluids get no belt.
--- @param per_second number
--- @param key string item key
--- @param fluid_keys table? custom keys marked fluid
--- @param opts table? { total = true }: a plan-wide total, which may span several belts
---   by design, so it is never shown as a problem
--- @return table { text, belt (rich text or ""), fill, color?, fill_color?, tooltip?, exceeds? }
function common.rate_display(ctx, per_second, key, fluid_keys, opts)
  local text = fp_util.format_rate(per_second, ctx.unit)
  if belts.is_fluid(key, fluid_keys) then
    return { text = text, belt = "—", fill = "", tooltip = L("fluid-no-limit") }
  end
  -- a trickle (a legendary byproduct): its exact value, and no belt
  if math.abs(per_second) < 0.01 then
    local exact = per_second ~= 0 and L("rate-exact", string.format("%.6g", common.from_per_second(ctx, per_second)), common.unit_suffix(ctx)) or nil
    return { text = text, belt = "", fill = "", tooltip = exact }
  end
  local check = belts.tier_for(per_second, ctx.tiers, ctx.max_index, ctx.one_lane)
  if not check then return { text = text, belt = "", fill = "" } end
  local tier = check.tier
  local capacity = fp_util.format_rate(tier.capacity * (ctx.one_lane and 0.5 or 1), ctx.unit, true)
  local lane = ctx.one_lane and L("belt-one-lane") or ""
  if check.exceeds and opts and opts.total then
    return {
      text = text, belt = "[entity=" .. tier.name .. "]", fill = fp_util.format_count(check.belts) .. "×",
      tooltip = L("belt-total-tooltip", fp_util.format_count(check.belts), common.entity_name(tier.name), capacity, lane),
    }
  end
  if check.exceeds then
    -- the only red: more than the highest allowed belt carries
    return {
      text = text, belt = "[entity=" .. tier.name .. "]", fill = fp_util.format_count(check.belts) .. "×",
      color = RED, fill_color = RED, exceeds = true,
      tooltip = L("chokes-tooltip", fp_util.format_count(check.belts), common.entity_name(tier.name), capacity, lane),
    }
  end
  return {
    text = text, belt = "[entity=" .. tier.name .. "]", fill = math.floor(check.belts * 100 + 0.5) .. "%",
    fill_color = check.belts >= 0.9 and YELLOW or nil, -- near capacity
    tooltip = L("belt-tooltip", common.entity_name(tier.name), capacity, math.floor(check.belts * 100 + 0.5), lane),
  }
end

local WHITE = { r = 1, g = 1, b = 1 }

common.RATE_WIDTH, common.BELT_WIDTH, common.FILL_WIDTH = 96, 36, 44

--- Add three table cells: rate, belt icon, fill. Named prefix_rate/_belt/_fill when a prefix is given.
function common.rate_cells(parent, ctx, per_second, key, fluid_keys, prefix, rate_width, opts)
  local d = per_second and common.rate_display(ctx, per_second, key, fluid_keys, opts) or { text = "", belt = "", fill = "" }
  local rate = parent.add({ type = "label", name = prefix and (prefix .. "_rate"), caption = d.text, tooltip = d.tooltip })
  rate.style.width = rate_width or common.RATE_WIDTH
  rate.style.horizontal_align = "right"
  rate.style.font_color = d.color or WHITE
  local belt = parent.add({ type = "label", name = prefix and (prefix .. "_belt"), caption = d.belt, tooltip = d.tooltip })
  belt.style.width = common.BELT_WIDTH
  belt.style.horizontal_align = "center"
  local fill = parent.add({ type = "label", name = prefix and (prefix .. "_fill"), caption = d.fill, tooltip = d.tooltip })
  fill.style.width = common.FILL_WIDTH
  fill.style.horizontal_align = "right"
  fill.style.font_color = d.fill_color or common.GREY
  return d
end

--- Update cells added by rate_cells (by prefix) in place; per_second nil clears them.
--- @param icon string? rich text shown before the rate (e.g. the product)
function common.set_rate_cells(parent, prefix, ctx, per_second, key, fluid_keys, icon)
  local rate, belt, fill = parent[prefix .. "_rate"], parent[prefix .. "_belt"], parent[prefix .. "_fill"]
  if not (rate and belt and fill) then return end
  local d = per_second and common.rate_display(ctx, per_second, key, fluid_keys) or { text = "", belt = "", fill = "" }
  rate.caption = icon and (icon .. " " .. d.text) or d.text
  rate.tooltip, rate.style.font_color = d.tooltip, d.color or WHITE
  belt.caption, belt.tooltip = d.belt, d.tooltip
  fill.caption, fill.tooltip, fill.style.font_color = d.fill, d.tooltip, d.fill_color or common.GREY
  return d
end

-- Sprites -------------------------------------------------------------------------------

local function valid_sprite(path)
  if path and helpers.is_valid_sprite_path(path) then return path end
  return "utility/missing_icon"
end

function common.key_sprite(key)
  return valid_sprite(fp_util.sprite(key))
end

function common.icon_sprite(icon)
  if not (icon and icon.name) then return "utility/missing_icon" end
  local t = icon.type or "item"
  if t == "virtual" then t = "virtual-signal" end
  return valid_sprite(t .. "/" .. icon.name)
end

function common.factory_sprite(f)
  -- a void or import always shows what it is (older ones took their first item's icon):
  -- the game's own signals, white and item-sized
  if f.kind == "void" then return valid_sprite("virtual-signal/signal-trash-bin") end
  if f.kind == "import" then return valid_sprite("virtual-signal/signal-input") end
  if f.icon then return common.icon_sprite(f.icon) end
  if f.kind == "sink" then return "utility/custom_tag_icon" end
  if f.kind == "void" then return "utility/trash_white" end
  if f.kind == "import" then return "utility/import_slot" end
  return "utility/missing_icon"
end

--- A factory's icon as a sprite.
function common.factory_icon(parent, f)
  return parent.add({ type = "sprite", sprite = common.factory_sprite(f) })
end

--- Recipe or resource sprite of a line.
function common.line_sprite(line)
  if line.kind == "recipe" and line.recipe then return valid_sprite("recipe/" .. line.recipe) end
  if line.kind == "mining" and line.resource then return valid_sprite("entity/" .. line.resource) end
  if line.kind == "pump" and line.resource then return valid_sprite("fluid/" .. line.resource) end
  return "utility/custom_tag_icon"
end

function common.machine_sprite(line)
  if line.machine then return valid_sprite("entity/" .. line.machine) end
  return nil
end

function common.line_caption(line)
  if line.kind == "recipe" and line.recipe then
    local p = prototypes.recipe[line.recipe]
    return p and p.localised_name or line.recipe
  end
  if line.kind == "mining" and line.resource then
    local p = prototypes.entity[line.resource]
    return p and p.localised_name or line.resource
  end
  if line.kind == "pump" and line.resource then
    local p = prototypes.fluid[line.resource]
    return p and p.localised_name or line.resource
  end
  return line.label or "custom"
end

--- Tooltip: flow per machine.
function common.flow_tooltip(ctx, flow, title)
  return { "", title or "", "\n", common.rates_text(ctx, flow, fp_util.sorted_keys(flow, fp_util.key_less)) }
end

--- Every rate of these keys as plain text, a line per item with its qualities side by side
--- ("+30.97/min [circuit]  +3.23/min [circuit, uncommon]"): one string, so no limit on how
--- many (a LocalisedString takes 20 parameters).
--- @param keys string[] in the order to show (an item's qualities next to each other)
function common.rates_text(ctx, flow, keys)
  local lines, last = {}, nil
  for _, key in ipairs(keys) do
    local v = flow[key]
    local text = (v > 0 and "+" or "") .. fp_util.format_rate(v, ctx.unit, true) .. " " .. fp_util.rich(key)
    local base = fp_util.base_key(key)
    if base == last then
      lines[#lines] = lines[#lines] .. "    " .. text
    else
      lines[#lines + 1] = text
    end
    last = base
  end
  return table.concat(lines, "\n")
end

-- Item icons --------------------------------------------------------------------------------

--- An item icon for the keys of one base item: the base sprite with its tier's badge when
--- there is one tier (none for normal), the "any quality" mark when there are several.
--- @param def table the sprite-button's definition (sprite and quality are set here)
--- @param keys string[] keys of one base item (one or more tiers)
function common.item_icon(parent, def, keys)
  def.sprite = common.key_sprite(keys[1])
  local tiers = {}
  for _, k in ipairs(keys) do tiers[fp_util.quality_of(k)] = true end
  local n = 0
  for _ in pairs(tiers) do n = n + 1 end
  local q = fp_util.quality_of(keys[1])
  if n == 1 and q ~= fp_util.NORMAL and prototypes.quality[q] then def.quality = q end
  local b = parent.add(def)
  if n > 1 then
    -- several tiers: the game's "any quality" mark in the corner
    local mark = b.add({ type = "sprite", sprite = "utility/any_quality", ignored_by_interaction = true, tooltip = nil })
    mark.style.size = 12
    mark.style.stretch_image_to_widget_size = true
  end
  return b
end

--- Keys grouped by base item, in the order their first key comes; each group's keys by
--- tier: { { base, keys = { ... } } }.
function common.by_base(keys)
  local groups, order = {}, {}
  for _, k in ipairs(keys) do
    local base = fp_util.base_key(k)
    if not groups[base] then
      groups[base] = { base = base, keys = {} }
      order[#order + 1] = groups[base]
    end
    table.insert(groups[base].keys, k)
  end
  for _, g in ipairs(order) do table.sort(g.keys, fp_util.key_less) end
  return order
end

--- "Gear (rare, epic)" for several tiers of one item, else the item's own name.
function common.keys_name(keys)
  if #keys == 1 then return fp_util.localised(keys[1]) end
  local out = { "", fp_util.localised(fp_util.base_key(keys[1])), " (" }
  for i, k in ipairs(keys) do
    if i > 6 then
      out[#out + 1] = ", …"
      break
    end
    if i > 1 then out[#out + 1] = ", " end
    out[#out + 1] = fp_util.quality_name(fp_util.quality_of(k))
  end
  out[#out + 1] = ")"
  return out
end

-- Quality --------------------------------------------------------------------------------------

--- Tiers a player can pick, by level: normal and every other tier the force has unlocked.
function common.quality_choices(force)
  local out = {}
  for _, name in ipairs(fp_util.quality_levels()) do
    if name == fp_util.NORMAL or (force and force.is_quality_unlocked and force.is_quality_unlocked(name)) then out[#out + 1] = name end
  end
  return out
end

--- Has the force unlocked a tier above normal (Space Age's quality research)?
function common.quality_unlocked(force)
  return #common.quality_choices(force) > 1
end

--- The drop-down choice "every quality" (common.picked_quality returns it as is).
common.EVERY_QUALITY = "*"

--- A drop-down of tiers; tags carry the choices so the handler maps the index back.
--- @param every boolean|string? true: an "Every quality" choice at the end; "any": an "Any
---   quality" choice first (a filter); selected as common.EVERY_QUALITY
function common.quality_dropdown(parent, force, selected, tags, every)
  local choices = common.quality_choices(force)
  if every == "any" then
    table.insert(choices, 1, common.EVERY_QUALITY)
  elseif every then
    choices[#choices + 1] = common.EVERY_QUALITY
  end
  local items, index = {}, 1
  for i, name in ipairs(choices) do
    if name == common.EVERY_QUALITY then
      items[i] = { "", "[img=utility/any_quality] ", L(every == "any" and "any-quality" or "every-quality") }
    else
      items[i] = { "", "[quality=" .. name .. "] ", fp_util.quality_name(name) }
    end
    if name == (selected or fp_util.NORMAL) then index = i end
  end
  local t = fp_util.deep_copy(tags)
  t.choices = choices
  local dd = parent.add({ type = "drop-down", items = items, selected_index = index, tags = t })
  -- "Any quality" / "Every quality" need the room (with the icon); a tier alone fits 120
  dd.style.width = every and 165 or 120
  return dd
end

-- A quality condition: the item picker gives the tier (as the game's pickers do), this
-- comparator how the row compares to it ("any" ignores the tier).
local OP_CAPTIONS = { ["="] = "=", [">="] = "≥", [">"] = ">", ["<="] = "≤", ["<"] = "<" }
common.COMPARATORS = { "=", ">=", ">", "<=", "<", "any" }

--- A narrow drop-down of comparators for a quality condition.
function common.comparator_dropdown(parent, op, tags, enabled)
  local items, index = {}, 1
  for i, o in ipairs(common.COMPARATORS) do
    items[i] = OP_CAPTIONS[o] or L("quality-any")
    if o == op then index = i end
  end
  local dd = parent.add({ type = "drop-down", items = items, selected_index = index, tags = tags, enabled = enabled ~= false,
    tooltip = L("quality-condition-tooltip") })
  dd.style.width = 72
  return dd
end

--- A condition's comparator and tier: ">=rare" -> ">=", "rare"; "any" -> "any", nil.
function common.split_condition(cond)
  if cond == nil or cond == "any" then return cond or "=", nil end
  local op, tier = cond:match("^([<>=]+)(.+)$")
  return op or "=", tier
end

--- The tier picked in a quality_dropdown (nil for normal).
function common.picked_quality(element)
  local name = element.tags.choices and element.tags.choices[element.selected_index]
  if name == fp_util.NORMAL then return nil end
  return name
end

-- Display names ----------------------------------------------------------------------------

--- A factory's name as shown: a void or import is the plan's "Void" or "Import" (older ones
--- were named after their first item).
function common.display_name(f)
  if f.kind == "void" then return L("void-button") end
  if f.kind == "import" then return L("import-button") end
  return f.name
end

--- Names for factories, made unique where several share a name: the main
--- output per copy is appended ("Iron plate · 300/min"), then the id if needed.
--- @return table<integer, string>
function common.factory_names(ctx)
  local groups = {}
  local names = {}
  for _, id in ipairs(model.factory_ids(ctx.plan)) do
    local f = model.get(id)
    if model.BOUNDARY_KINDS[f.kind] then
      -- one of each per plan: it is the plan's void or import, whatever it was called
      names[id] = common.display_name(f)
    else
      local name = f.name or ""
      groups[name] = groups[name] or {}
      table.insert(groups[name], id)
    end
  end
  for name, ids in pairs(groups) do
    if #ids == 1 then
      names[ids[1]] = name
    else
      local used = {}
      for _, id in ipairs(ids) do
        local f = model.get(id)
        local net = f.result and f.result.net or {}
        local best, best_v = nil, 0
        for _, key in ipairs(fp_util.sorted_keys(net, fp_util.key_less)) do
          if math.abs(net[key]) > math.abs(best_v) then best, best_v = key, net[key] end
        end
        local caption = name
        if best then caption = name .. " · " .. fp_util.format_rate(math.abs(best_v), ctx.unit, true) end
        if used[caption] then caption = caption .. " #" .. id end
        used[caption] = true
        names[id] = caption
      end
    end
  end
  return names
end

--- Names for the units of the plan balance: factories by id, and each item of a void
--- or import by its unit id ("Void · [item]").
--- @return table<any, LocalisedString>
function common.unit_names(ctx)
  local names = common.factory_names(ctx)
  for _, id in ipairs(model.factory_ids(ctx.plan)) do
    local f = model.get(id)
    if model.BOUNDARY_KINDS[f.kind] then
      for _, row in ipairs(f.sink_items or {}) do
        if row.key and not row.quality then names[id .. ":" .. row.key] = { "", names[id] or "", " · ", fp_util.rich(row.key) } end
      end
    end
  end
  -- the tiers a quality condition stands for are units of their own
  for _, unit in ipairs((plan.units(ctx.plan))) do
    if unit.item then names[unit.id] = { "", names[unit.factory] or "", " · ", fp_util.rich(unit.item) } end
  end
  return names
end

--- Names for the recipe lines of a factory: lines that share a recipe get their
--- machine's icon appended, then the line id if even that is the same.
--- @param caption_of function(line) -> LocalisedString
--- @return table<any, LocalisedString>
function common.line_names(lines, caption_of)
  local groups = {}
  for _, line in ipairs(lines) do
    local key = (line.recipe or line.resource or line.label or "") .. "|" .. line.kind
    groups[key] = groups[key] or {}
    table.insert(groups[key], line)
  end
  local names = {}
  for _, group in pairs(groups) do
    local machines = {}
    for _, line in ipairs(group) do machines[line.machine or ""] = (machines[line.machine or ""] or 0) + 1 end
    for _, line in ipairs(group) do
      local caption = caption_of(line)
      if #group > 1 then
        local suffix = line.machine and ("[entity=" .. line.machine .. "]") or ""
        if (machines[line.machine or ""] or 0) > 1 then suffix = suffix .. " #" .. line.id end
        caption = { "", caption, " · ", suffix }
      end
      names[line.id] = caption
    end
  end
  return names
end

-- Status -------------------------------------------------------------------------------------

local STATUS_COLOR = {
  EXACT = GREEN, NEEDS_SPLIT = YELLOW, CONFLICT = RED, NEGATIVE = RED, INVALID = RED,
}

function common.status_color(status)
  return STATUS_COLOR[status] or GREY
end

function common.status_label(parent, status, name)
  local label = parent.add({ type = "label", name = name, caption = L("status-" .. status), style = "bold_label" })
  label.style.font_color = common.status_color(status)
  return label
end

function common.player_name(index)
  local p = index and game.get_player(index)
  if not p then return "?" end
  -- single-player games can have an empty user name
  if p.name == "" then return "player " .. p.index end
  return p.name
end

function common.time_ago(tick)
  if not tick then return "?" end
  local s = math.floor((game.tick - tick) / 60)
  if s < 60 then return L("ago-seconds", s) end
  local m = math.floor(s / 60)
  if m < 60 then return L("ago-minutes", m) end
  return L("ago-hours", math.floor(m / 60))
end

-- Layout bits ---------------------------------------------------------------------------------------

function common.spacer(parent)
  local s = parent.add({ type = "empty-widget" })
  s.style.horizontally_stretchable = true
  return s
end

--- @param extra table[]? element definitions before the close button
--- @param after_title table[]? element definitions right after the title
function common.titlebar(frame, caption, close_action, extra, after_title)
  local bar = frame.add({ type = "flow", name = "stoich_titlebar", direction = "horizontal" })
  bar.drag_target = frame
  bar.add({ type = "label", caption = caption, style = "frame_title", ignored_by_interaction = true })
  for _, b in ipairs(after_title or {}) do bar.add(b) end
  local filler = bar.add({ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true })
  filler.style.height = 24
  filler.style.horizontally_stretchable = true
  filler.style.right_margin = 4
  for _, b in ipairs(extra or {}) do bar.add(b) end
  bar.add({
    type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
    tooltip = { "gui.close-instruction" }, tags = { fp = close_action },
  })
  return bar
end

function common.number_field(parent, value, tags, opts)
  opts = opts or {}
  local f = parent.add({
    type = "textfield",
    name = opts.name,
    text = value ~= nil and fp_util.format_count(value) or "",
    numeric = true, allow_decimal = true, allow_negative = opts.negative or false,
    lose_focus_on_confirm = true,
    tags = tags,
    tooltip = opts.tooltip,
    enabled = opts.enabled ~= false,
  })
  f.style.width = opts.width or 60
  return f
end


-- Dialogs -----------------------------------------------------------------------------------------------

--- One dialog per player, centred, on top of the open window. It is not made
--- player.opened (that would close the window under it).
--- @param data table? the dialog's state (storage.players[i].dialog) while it is open
function common.open_dialog(player, name, caption, data)
  common.close_dialog(player)
  if data then model.player(player.index).dialog = data end
  local frame = player.gui.screen.add({ type = "frame", name = "stoich_dialog", direction = "vertical", tags = { dialog = name } })
  common.titlebar(frame, caption, "dialog_close")
  frame.auto_center = true
  frame.bring_to_front()
  return frame
end

function common.close_dialog(player)
  local d = player.gui.screen.stoich_dialog
  if d and d.valid then d.destroy() end
  local state = storage.players[player.index]
  if state then state.dialog = nil end
end

common.handlers.dialog_close = function(player)
  common.close_dialog(player)
end

function common.dialog_buttons(frame)
  local flow = frame.add({ type = "flow", name = "stoich_buttons", style = "dialog_buttons_horizontal_flow" })
  flow.style.horizontal_spacing = 8
  return flow
end

return common
