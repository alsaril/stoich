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
    type = "bool-setting",
    name = "fp-one-lane",
    setting_type = "runtime-global",
    default_value = false,
    order = "d",
  },
})
