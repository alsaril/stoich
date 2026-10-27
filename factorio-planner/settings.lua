data:extend({
  {
    type = "string-setting",
    name = "fp-rate-unit",
    setting_type = "runtime-per-user",
    default_value = "min",
    allowed_values = { "s", "min", "h" },
    order = "a",
  },
  {
    type = "string-setting",
    name = "fp-edit-permission",
    setting_type = "runtime-global",
    default_value = "everyone",
    allowed_values = { "everyone", "admins" },
    order = "b",
  },
  {
    -- Name of the highest belt to plan with; empty = the best one researched.
    type = "string-setting",
    name = "fp-max-belt",
    setting_type = "runtime-global",
    default_value = "",
    allow_blank = true,
    order = "c",
  },
  {
    -- Test tooling only: exposes the "factorio-planner-debug" remote interface.
    -- Hidden; the screenshot helper mod switches it on in its settings-updates.
    type = "bool-setting",
    name = "fp-debug-interface",
    setting_type = "startup",
    default_value = false,
    hidden = true,
    order = "z",
  },
  {
    type = "bool-setting",
    name = "fp-one-lane",
    setting_type = "runtime-global",
    default_value = false,
    order = "d",
  },
})
