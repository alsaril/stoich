-- Shared GUI helpers: event dispatch by element tags, display context
-- (unit, belt tiers), rate labels, sprites, small dialogs.

local fp_util = require("scripts.util")
local belts = require("scripts.belts")
local model = require("scripts.model")

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

--- Per-player view settings: unit, belt tiers and the highest allowed tier.
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
  -- the basic belt is the usual case: only a faster one gets its icon (the tooltip names it)
  local basic = ctx.tiers[1] and ctx.tiers[1].name == tier.name
  return {
    text = text, belt = basic and "" or "[entity=" .. tier.name .. "]", fill = math.floor(check.belts * 100 + 0.5) .. "%",
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
  if f.icon then return common.icon_sprite(f.icon) end
  if f.kind == "sink" then return "utility/custom_tag_icon" end
  return "utility/missing_icon"
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
  local parts = { "", title or "", "\n" }
  local n = 0
  for _, key in ipairs(fp_util.sorted_keys(flow)) do
    local v = flow[key]
    -- LocalisedString concatenation is limited to 20 parameters; keep it compact.
    if n < 16 then
      parts[#parts + 1] = (v > 0 and "+" or "") .. fp_util.format_rate(v, ctx.unit, true) .. " " .. fp_util.rich(key) .. "\n"
      n = n + 1
    end
  end
  return parts
end

-- Display names ----------------------------------------------------------------------------

--- Names for factories, made unique where several share a name: the main
--- output per copy is appended ("Iron plate · 300/min"), then the id if needed.
--- @return table<integer, string>
function common.factory_names(ctx)
  local groups = {}
  for _, id in ipairs(model.factory_ids()) do
    local name = model.get(id).name or ""
    groups[name] = groups[name] or {}
    table.insert(groups[name], id)
  end
  local names = {}
  for name, ids in pairs(groups) do
    if #ids == 1 then
      names[ids[1]] = name
    else
      local used = {}
      for _, id in ipairs(ids) do
        local f = model.get(id)
        local net = f.result and f.result.net or {}
        local best, best_v = nil, 0
        for _, key in ipairs(fp_util.sorted_keys(net)) do
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

function common.titlebar(frame, caption, close_action, extra)
  local bar = frame.add({ type = "flow", name = "stoich_titlebar", direction = "horizontal" })
  bar.drag_target = frame
  bar.add({ type = "label", caption = caption, style = "frame_title", ignored_by_interaction = true })
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
