local production = { "assembling-machine", "furnace", "rocket-silo", "mining-drill", "offshore-pump" }
local generators = { "boiler", "generator", "burner-generator", "reactor" }
local filter = {}
for _, t in ipairs(production) do filter[#filter + 1] = t end
for _, t in ipairs(generators) do filter[#filter + 1] = t end

-- Both selection modes capture a new factory (Factorio requires an alt_select).
local function mode(color)
  return {
    border_color = color,
    cursor_box_type = "copy",
    mode = { "any-entity", "same-force" },
    entity_type_filters = filter,
  }
end

data:extend({
  {
    type = "selection-tool",
    name = "stoich-selection-tool",
    icons = { { icon = "__base__/graphics/icons/blueprint.png", icon_size = 64, tint = { r = 0.55, g = 0.95, b = 0.6, a = 1 } } },
    flags = { "only-in-cursor", "not-stackable", "spawnable" },
    hidden = true,
    subgroup = "other",
    order = "z[stoich-selection-tool]",
    stack_size = 1,
    select = mode({ r = 0.3, g = 0.9, b = 0.4 }),
    alt_select = mode({ r = 0.3, g = 0.9, b = 0.4 }),
  },
  {
    type = "shortcut",
    name = "stoich-give-tool",
    order = "f[fp]-a[capture]",
    action = "spawn-item",
    item_to_spawn = "stoich-selection-tool",
    associated_control_input = "stoich-give-tool",
    icon = "__base__/graphics/icons/shortcut-toolbar/mip/new-blueprint-x56.png",
    icon_size = 56,
    small_icon = "__base__/graphics/icons/shortcut-toolbar/mip/new-blueprint-x24.png",
    small_icon_size = 24,
    style = "green",
  },
  {
    type = "shortcut",
    name = "stoich-toggle-window",
    order = "f[fp]-b[window]",
    action = "lua",
    associated_control_input = "stoich-toggle-window",
    icon = "__base__/graphics/icons/assembling-machine-2.png",
    icon_size = 64,
    small_icon = "__base__/graphics/icons/assembling-machine-2.png",
    small_icon_size = 64,
  },
  {
    type = "custom-input",
    name = "stoich-toggle-window",
    key_sequence = "CONTROL + ALT + P",
    action = "lua",
  },
  {
    type = "custom-input",
    name = "stoich-give-tool",
    key_sequence = "CONTROL + ALT + C",
    action = "spawn-item",
    item_to_spawn = "stoich-selection-tool",
  },
})
