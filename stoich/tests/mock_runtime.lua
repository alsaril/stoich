-- A small stand-in for the Factorio runtime, strict where the real game is:
-- GUI add() parameters, attribute writes, style names and types, sprite paths,
-- LocalisedString shape and use of destroyed elements are checked against the
-- 2.1 API data in tests/fixtures/api.lua. Used by gui_test.lua to drive
-- control.lua through whole scenarios offline.

local json = require("tests.json")
local API = dofile(TEST_ROOT .. "/tests/fixtures/api.lua")

local mock = {}

-- Style type each element type accepts.
local STYLE_TYPES = {
  ["button"] = { button_style = true }, ["sprite-button"] = { button_style = true },
  ["choose-elem-button"] = { button_style = true }, ["label"] = { label_style = true },
  ["frame"] = { frame_style = true }, ["flow"] = { horizontal_flow_style = true, vertical_flow_style = true },
  ["table"] = { table_style = true }, ["textfield"] = { textbox_style = true }, ["text-box"] = { textbox_style = true },
  ["scroll-pane"] = { scroll_pane_style = true }, ["drop-down"] = { dropdown_style = true },
  ["checkbox"] = { checkbox_style = true }, ["radiobutton"] = { radiobutton_style = true },
  ["progressbar"] = { progressbar_style = true }, ["slider"] = { slider_style = true, double_slider_style = true },
  ["tabbed-pane"] = { tabbed_pane_style = true }, ["tab"] = { tab_style = true }, ["sprite"] = { image_style = true },
  ["empty-widget"] = { empty_widget_style = true }, ["line"] = { line_style = true }, ["list-box"] = { list_box_style = true },
  ["switch"] = { switch_style = true },
}

local ELEM_VALUE_PARAM = {
  item = "item", fluid = "fluid", recipe = "recipe", entity = "entity", signal = "signal", technology = "technology",
}

-- LocalisedString --------------------------------------------------------------------------------

function mock.check_localised(v, where)
  local t = type(v)
  if v == nil or t == "string" or t == "number" or t == "boolean" then return end
  if t ~= "table" then error(where .. ": bad LocalisedString of type " .. t, 3) end
  local n = 0
  for k in pairs(v) do
    if type(k) ~= "number" then error(where .. ": LocalisedString with non-array key " .. tostring(k), 3) end
    if k > n then n = k end
  end
  if n == 0 then return end
  if type(v[1]) ~= "string" then error(where .. ": LocalisedString key must be a string", 3) end
  if n - 1 > 20 then error(where .. ": LocalisedString with more than 20 parameters (" .. (n - 1) .. ")", 3) end
  for i = 2, n do
    if v[i] == nil then error(where .. ": LocalisedString with a nil parameter at " .. i, 3) end
    mock.check_localised(v[i], where)
  end
end

-- Prototypes and sprites ---------------------------------------------------------------------------

function mock.sprite_valid(path)
  if type(path) ~= "string" then return false end
  local t, n = path:match("^([%w%-]+)/(.+)$")
  if not t then return false end
  if t == "utility" then return API.utility_sprites[n] == true end
  if t == "item" then return prototypes.item[n] ~= nil end
  if t == "fluid" then return prototypes.fluid[n] ~= nil end
  if t == "recipe" then return prototypes.recipe[n] ~= nil end
  if t == "entity" then return prototypes.entity[n] ~= nil end
  if t == "virtual-signal" then return prototypes.virtual_signal[n] ~= nil end
  return false
end

-- GUI elements -------------------------------------------------------------------------------------

local data_of = setmetatable({}, { __mode = "k" })
local Element = {}

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return out
end

local function check_tags(v, path)
  local t = type(v)
  if t == "table" then
    for k, x in pairs(v) do
      if type(k) ~= "string" and type(k) ~= "number" then error("tags: bad key at " .. path, 4) end
      check_tags(x, path .. "." .. tostring(k))
    end
  elseif t ~= "string" and t ~= "number" and t ~= "boolean" then
    error("tags: value of type " .. t .. " at " .. path, 4)
  end
end

-- LuaStyle subclasses that apply to each element type (attributes listed with
-- "subclasses" in the API only work on those).
local STYLE_CLASSES = {
  ["table"] = { LuaTableStyle = true }, ["frame"] = { LuaFrameStyle = true },
  ["label"] = { LuaLabelStyle = true, LabelStyle = true },
  ["button"] = { LuaButtonStyle = true }, ["sprite-button"] = { LuaButtonStyle = true }, ["choose-elem-button"] = { LuaButtonStyle = true },
  ["progressbar"] = { LuaProgressBarStyle = true }, ["tab"] = { LuaTabStyle = true, TabStyle = true },
  ["tabbed-pane"] = { LuaTabbedPaneStyle = true }, ["textfield"] = { LuaTextBoxStyle = true }, ["text-box"] = { LuaTextBoxStyle = true },
  ["scroll-pane"] = { ScrollPaneStyle = true }, ["sprite"] = { ImageStyle = true },
}

local function style_classes(element_data)
  if element_data.type == "flow" then
    -- the real game gives a flow a horizontal_flow or vertical_flow style by direction:
    -- horizontal_spacing on a vertical flow (or vertical_spacing on a horizontal one) is an error
    local dir = element_data.direction == "vertical" and "LuaVerticalFlowStyle" or "LuaHorizontalFlowStyle"
    return { [dir] = true }
  end
  return STYLE_CLASSES[element_data.type] or {}
end

local function new_style(element_data, name)
  local values = { name = name, column_alignments = setmetatable({}, {
    __newindex = function(t, k, v)
      if type(k) ~= "number" then error("column_alignments: index must be a number", 2) end
      rawset(t, k, v)
    end,
  }) }
  return setmetatable({}, {
    __index = function(_, k)
      if not element_data.valid then error("LuaStyle API call when the element was invalid", 2) end
      return values[k]
    end,
    __newindex = function(_, k, v)
      if not element_data.valid then error("LuaStyle API call when the element was invalid", 2) end
      if not API.style_write[k] then error("LuaStyle doesn't contain writable key " .. tostring(k), 2) end
      local applies = API.style_attr_types[k]
      if applies then
        local ok = false
        for class in pairs(style_classes(element_data)) do
          if applies[class] then ok = true end
        end
        if not ok then error("LuaStyle." .. k .. " doesn't apply to a " .. tostring(element_data.type) .. " (" .. tostring(element_data.direction or "") .. ")", 2) end
      end
      values[k] = v
    end,
  })
end

local function make_element(def, parent, player_index)
  local d = {
    valid = true, children = {}, parent = parent, player_index = player_index, type = def.type,
    tags = def.tags and deep_copy(def.tags) or {},
  }
  local e = setmetatable({}, Element)
  data_of[e] = d
  d.style = new_style(d, def.style)
  for k, v in pairs(def) do
    if k ~= "style" and k ~= "tags" and k ~= "type" then d[k] = v end
  end
  if def.type == "choose-elem-button" then
    local param = ELEM_VALUE_PARAM[def.elem_type] or def.elem_type
    d.elem_value = def[param]
  end
  if def.type == "slider" then
    d.slider_value = def.value or def.minimum_value or 0
    d.value = nil
  end
  if def.type == "drop-down" or def.type == "list-box" then
    d.items = def.items or {}
    d.selected_index = def.selected_index or 0
  end
  if def.type == "tabbed-pane" then
    d.tabs = {}
    d.selected_tab_index = nil
  end
  if def.type == "checkbox" or def.type == "radiobutton" then d.state = def.state and true or false end
  if def.type == "textfield" or def.type == "text-box" then d.text = def.text or "" end
  if d.enabled == nil then d.enabled = true end
  if d.visible == nil then d.visible = true end
  return e
end

local function invalidate(e)
  local d = data_of[e]
  d.valid = false
  for _, c in ipairs(d.children) do invalidate(c) end
end

local methods = {}

function methods.add(e, def)
  local d = data_of[e]
  if type(def) ~= "table" then error("add: expected a table", 2) end
  if not API.element_types[def.type] then error("add: unknown element type " .. tostring(def.type), 2) end
  local variant = API.add_variant[def.type] or {}
  for k in pairs(def) do
    if k ~= "type" and not API.add_common[k] and not variant[k] then
      error("add: parameter '" .. tostring(k) .. "' is not valid for " .. def.type, 2)
    end
  end
  if def.name ~= nil then
    if type(def.name) ~= "string" then error("add: name must be a string", 2) end
    for _, c in ipairs(d.children) do
      if data_of[c].name == def.name then error("add: element with name " .. def.name .. " already present in the parent", 2) end
    end
  end
  if def.style then
    local st = API.styles[def.style]
    if not st then error("add: unknown style " .. def.style, 2) end
    local ok = STYLE_TYPES[def.type]
    if ok and not ok[st] then error("add: style " .. def.style .. " (" .. st .. ") can't be used on " .. def.type, 2) end
  end
  for _, k in ipairs({ "sprite", "hovered_sprite", "clicked_sprite" }) do
    if def[k] ~= nil and not mock.sprite_valid(def[k]) then error("add: invalid sprite path " .. tostring(def[k]), 2) end
  end
  mock.check_localised(def.caption, "caption")
  mock.check_localised(def.tooltip, "tooltip")
  if def.tags ~= nil then check_tags(def.tags, "tags") end
  if def.type == "drop-down" or def.type == "list-box" then
    for i, item in ipairs(def.items or {}) do mock.check_localised(item, "items[" .. i .. "]") end
    local n = #(def.items or {})
    if def.selected_index and (def.selected_index < 0 or def.selected_index > n) then
      error("add: selected_index " .. def.selected_index .. " out of range 0.." .. n, 2)
    end
  end
  if def.type == "choose-elem-button" then
    if not def.elem_type then error("add: choose-elem-button needs elem_type", 2) end
    for param in pairs(ELEM_VALUE_PARAM) do
      if def[param] ~= nil and param ~= (ELEM_VALUE_PARAM[def.elem_type] or def.elem_type) then
        error("add: " .. param .. "= given for elem_type " .. def.elem_type, 2)
      end
    end
  end
  if def.type == "slider" then
    local v, lo, hi = def.value or 0, def.minimum_value or 0, def.maximum_value or 30
    if v < lo or v > hi then error("add: slider value " .. v .. " outside " .. lo .. ".." .. hi, 2) end
  end
  if def.type == "textfield" and def.text ~= nil and type(def.text) ~= "string" then error("add: text must be a string", 2) end
  local child = make_element(def, e, d.player_index)
  d.children[#d.children + 1] = child
  return child
end

function methods.clear(e)
  local d = data_of[e]
  for _, c in ipairs(d.children) do invalidate(c) end
  d.children = {}
end

function methods.destroy(e)
  local d = data_of[e]
  local p = d.parent and data_of[d.parent]
  if p then
    for i, c in ipairs(p.children) do
      if c == e then table.remove(p.children, i) break end
    end
  end
  invalidate(e)
end

function methods.add_tab(e, tab, content)
  local d = data_of[e]
  if data_of[tab].parent ~= e or data_of[content].parent ~= e then error("add_tab: tab and content must be children of the tabbed pane", 2) end
  if data_of[tab].type ~= "tab" then error("add_tab: first argument must be a tab", 2) end
  d.tabs[#d.tabs + 1] = { tab = tab, content = content }
end

function methods.get_mod() return "stoich" end
function methods.bring_to_front() end
function methods.focus() end
function methods.select_all() end
function methods.scroll_to_element(_, el)
  if not data_of[el].valid then error("scroll_to_element: invalid element", 2) end
end
function methods.swap_children(e, i, j)
  local d = data_of[e]
  d.children[i], d.children[j] = d.children[j], d.children[i]
end

Element.__index = function(e, k)
  local d = data_of[e]
  if k == "valid" then return d.valid end
  if not d.valid then error("LuaGuiElement API call when LuaGuiElement was invalid (reading " .. tostring(k) .. ")", 2) end
  if methods[k] then
    -- Factorio methods are called with a dot: element.add{...}
    return function(...)
      if mock.is_element((...)) and (...) == e then error("LuaGuiElement method called with ':' (" .. k .. ")", 2) end
      return methods[k](e, ...)
    end
  end
  if k == "children" then
    local out = {}
    for i, c in ipairs(d.children) do out[i] = c end
    return out
  end
  if k == "tags" then return deep_copy(d.tags) end
  if k == "style" then return d.style end
  if k == "gui" then return d.gui end
  if API.element_read[k] then return d[k] end
  for _, c in ipairs(d.children) do
    if data_of[c].name == k then return c end
  end
  return nil
end

-- The game rejects anything but true/false here (nil included).
local BOOLEAN_ATTRIBUTES = { state = true, enabled = true, visible = true, ignored_by_interaction = true }

Element.__newindex = function(e, k, v)
  local d = data_of[e]
  if not d.valid then error("LuaGuiElement API call when LuaGuiElement was invalid (writing " .. tostring(k) .. ")", 2) end
  if not API.element_write[k] then error("LuaGuiElement doesn't contain writable key " .. tostring(k), 2) end
  local types = API.attr_types[k]
  if types and not types[d.type] then error("LuaGuiElement." .. k .. " can't be written on a " .. d.type, 2) end
  if k == "caption" or k == "tooltip" then mock.check_localised(v, k) end
  if k == "tags" then
    check_tags(v, "tags")
    v = deep_copy(v)
  end
  if k == "sprite" and not mock.sprite_valid(v) then error("invalid sprite path " .. tostring(v), 2) end
  if k == "style" then
    if not API.styles[v] then error("unknown style " .. tostring(v), 2) end
    d.style = new_style(d, v)
    return
  end
  if k == "selected_tab_index" then
    if v ~= nil and (v < 1 or v > #d.tabs) then error("selected_tab_index out of range", 2) end
  end
  if BOOLEAN_ATTRIBUTES[k] and type(v) ~= "boolean" then error("bool expected, got " .. type(v), 2) end
  d[k] = v
  -- as in the game: a script moving a window raises the event too
  if k == "location" then mock.fire("on_gui_location_changed", { player_index = d.player_index, element = e }) end
end

Element.__eq = function(a, b) return rawequal(a, b) end

function mock.is_element(v) return data_of[v] ~= nil end

-- Players, forces, surfaces ---------------------------------------------------------------------

local function new_root(player_index)
  local e = setmetatable({}, Element)
  data_of[e] = { valid = true, children = {}, type = "empty-widget", name = "screen", player_index = player_index, tags = {} }
  data_of[e].style = new_style(data_of[e], nil)
  return e
end

function mock.new_player(index, opts)
  opts = opts or {}
  local p
  local values = { ["stoich-rate-unit"] = { value = opts.unit or "min" } }
  local mod_settings = setmetatable({}, {
    __index = values,
    __newindex = function(_, k, v)
      if not values[k] then error("unknown per-user setting " .. k, 2) end
      values[k] = v
      mock.fire("on_runtime_mod_setting_changed", { player_index = index, setting = k, setting_type = "runtime-per-user" })
    end,
  })
  p = {
    index = index, name = opts.name or ("player" .. index), admin = opts.admin or false, valid = true, connected = true,
    gui = { screen = new_root(index) },
    mod_settings = mod_settings,
    force = mock.force,
    printed = {},
    cursor_stack = setmetatable({}, { __index = function(_, k)
      if k == "valid_for_read" then return p.cursor ~= nil end
      if k == "name" then
        if not p.cursor then error("LuaItemStack: not valid for read", 2) end
        return p.cursor
      end
      if k == "set_stack" then
        return function(stack)
          p.cursor = stack.name
          mock.fire("on_player_cursor_stack_changed", { player_index = index })
          return true
        end
      end
    end }),
    controller = nil,
    display_resolution = { width = 2560, height = 1440 }, display_scale = 1,
  }
  function p.print(msg) mock.check_localised(msg, "print") p.printed[#p.printed + 1] = msg end
  function p.clear_cursor()
    local had = p.cursor ~= nil
    p.cursor = nil
    if had then mock.fire("on_player_cursor_stack_changed", { player_index = index }) end
    return true
  end
  p.translations = {}
  function p.request_translation(ls)
    mock.check_localised(ls, "request_translation")
    p.translations[#p.translations + 1] = ls
    return #p.translations
  end
  function p.set_controller(params)
    for k in pairs(params) do
      if not API.set_controller[k] then error("set_controller: unknown parameter " .. k, 2) end
    end
    p.controller = params
    p.opened = nil -- the game closes the open GUI on a controller change
  end
  -- player.opened as in the game: writing nil or a new GUI asks the current one to
  -- close (on_gui_closed, raised instantly); a destroyed element reads as nil.
  -- Esc / E (mock.press_esc) closes it first and then raises the event, so a GUI the
  -- handler opens stays open.
  local opened
  function p.press_esc()
    local old = opened
    if old and not old.valid then old = nil end
    opened = nil
    if old then mock.fire("on_gui_closed", { player_index = index, element = old }) end
  end
  setmetatable(p, {
    __index = function(_, k)
      if k ~= "opened" then return nil end
      if opened and not opened.valid then opened = nil end
      return opened
    end,
    __newindex = function(t, k, v)
      if k ~= "opened" then return rawset(t, k, v) end
      local old = opened
      if old and not old.valid then old = nil end
      opened = nil
      if old and old ~= v then mock.fire("on_gui_closed", { player_index = index, element = old }) end
      opened = v
    end,
  })
  game.players[index] = p
  game.connected_players[#game.connected_players + 1] = p
  return p
end

-- World -------------------------------------------------------------------------------------------------

local function proto(name, extra)
  local t = { name = name, localised_name = { "item-name." .. name }, hidden = false, valid = true }
  for k, v in pairs(extra or {}) do t[k] = v end
  return t
end

local function I(name, amount) return { type = "item", name = name, amount = amount } end
local function F(name, amount) return { type = "fluid", name = name, amount = amount } end
local function P(type, name, amount) return { type = type, name = name, amount = amount, independent_probability = 1, shared_probability = { min = 0, max = 1 } } end

function mock.recipe_protos()
  local list = {
    proto("iron-plate", { energy = 3.2, categories = { "smelting" }, ingredients = { I("iron-ore", 1) }, products = { P("item", "iron-plate", 1) } }),
    proto("copper-cable", { energy = 0.5, categories = { "crafting" }, ingredients = { I("copper-plate", 1) }, products = { P("item", "copper-cable", 2) } }),
    proto("electronic-circuit", { energy = 0.5, categories = { "crafting" }, ingredients = { I("iron-plate", 1), I("copper-cable", 3) }, products = { P("item", "electronic-circuit", 1) } }),
    proto("advanced-oil-processing", { energy = 5, categories = { "oil-processing" }, ingredients = { F("crude-oil", 100), F("water", 50) },
      products = { P("fluid", "heavy-oil", 25), P("fluid", "light-oil", 45), P("fluid", "petroleum-gas", 55) } }),
    proto("coal-liquefaction", { energy = 5, categories = { "oil-processing" }, ingredients = { I("coal", 10), F("heavy-oil", 25), F("steam", 50) },
      products = { P("fluid", "heavy-oil", 90), P("fluid", "light-oil", 20), P("fluid", "petroleum-gas", 10) } }),
    proto("heavy-oil-cracking", { energy = 2, categories = { "chemistry" }, ingredients = { F("heavy-oil", 40), F("water", 30) }, products = { P("fluid", "light-oil", 30) } }),
    proto("light-oil-cracking", { energy = 2, categories = { "chemistry" }, ingredients = { F("light-oil", 30), F("water", 30) }, products = { P("fluid", "petroleum-gas", 20) } }),
    proto("plastic-bar", { energy = 1, categories = { "chemistry" }, ingredients = { F("petroleum-gas", 20), I("coal", 1) }, products = { P("item", "plastic-bar", 2) } }),
    proto("transport-belt", { energy = 0.5, categories = { "crafting" }, ingredients = { I("iron-plate", 1), I("iron-gear-wheel", 1) }, products = { P("item", "transport-belt", 2) } }),
    proto("fast-transport-belt", { energy = 0.5, categories = { "crafting" }, ingredients = { I("iron-gear-wheel", 5), I("transport-belt", 1) }, products = { P("item", "fast-transport-belt", 1) } }),
    proto("express-transport-belt", { energy = 0.5, categories = { "crafting" }, ingredients = { I("iron-gear-wheel", 10), I("fast-transport-belt", 1) }, products = { P("item", "express-transport-belt", 1) } }),
  }
  local t = {}
  for _, r in ipairs(list) do
    r.maximum_productivity = 3
    t[r.name] = r
  end
  return t
end

function mock.reset(opts)
  opts = opts or {}
  storage = {}
  local handlers, custom = {}, {}
  mock.handlers, mock.custom, mock.init = handlers, custom, {}
  local ids = {}
  local n = 0
  for name in pairs(API.events) do
    n = n + 1
    ids[name] = n
  end
  defines = {
    events = ids,
    controllers = { character = 1, god = 2, editor = 3, remote = 4, spectator = 5, cutscene = 6, ghost = 7 },
    mouse_button_type = { left = 2, right = 4, middle = 8 },
  }
  mock.surface = {
    index = 1, name = "nauvis", valid = true, entities = {},
    find_entities_filtered = function(f)
      local out = {}
      local types = {}
      if type(f.type) == "table" then for _, t in ipairs(f.type) do types[t] = true end elseif f.type then types[f.type] = true end
      for _, e in ipairs(mock.surface.entities) do
        local p = e.position
        local inside = not f.area or (p.x >= f.area.left_top.x and p.x <= f.area.right_bottom.x and p.y >= f.area.left_top.y and p.y <= f.area.right_bottom.y)
        if e.valid and inside and (not f.type or types[e.type]) then out[#out + 1] = e end
      end
      return out
    end,
  }
  game = {
    tick = 0, players = {}, connected_players = {},
    get_player = function(i) return game.players[i] end,
    get_surface = function(i) if i == 1 or i == "nauvis" then return mock.surface end end,
    printed = {},
    print = function(msg) mock.check_localised(msg, "game.print") game.printed[#game.printed + 1] = msg end,
  }
  local global_settings = {
    ["stoich-edit-permission"] = { value = opts.edit or "everyone" },
    ["stoich-max-belt"] = { value = "" },
    ["stoich-one-lane"] = { value = false },
  }
  settings = {
    startup = { ["stoich-debug-interface"] = { value = opts.debug_interface or false } },
    global = setmetatable({}, {
      __index = global_settings,
      __newindex = function(_, k, v)
        if not global_settings[k] then error("unknown setting " .. k, 2) end
        global_settings[k] = v
        mock.fire("on_runtime_mod_setting_changed", { setting = k, setting_type = "runtime-global" })
      end,
    }),
  }
  local recipes = mock.recipe_protos()
  local items, fluids = {}, {}
  for _, n2 in ipairs({ "iron-plate", "copper-plate", "copper-cable", "electronic-circuit", "iron-gear-wheel", "coal", "plastic-bar", "iron-ore",
    "automation-science-pack", "transport-belt", "fast-transport-belt", "express-transport-belt" }) do items[n2] = proto(n2) end
  for _, n2 in ipairs({ "water", "steam", "crude-oil", "heavy-oil", "light-oil", "petroleum-gas" }) do fluids[n2] = proto(n2) end
  local entities = {
    ["assembling-machine-2"] = proto("assembling-machine-2", { type = "assembling-machine", crafting_categories = { crafting = true }, get_crafting_speed = function() return 0.75 end }),
    ["oil-refinery"] = proto("oil-refinery", { type = "assembling-machine", crafting_categories = { ["oil-processing"] = true }, get_crafting_speed = function() return 1 end }),
    ["chemical-plant"] = proto("chemical-plant", { type = "assembling-machine", crafting_categories = { chemistry = true }, get_crafting_speed = function() return 1 end }),
    ["stone-furnace"] = proto("stone-furnace", { type = "furnace", crafting_categories = { smelting = true }, get_crafting_speed = function() return 1 end }),
    ["electric-mining-drill"] = proto("electric-mining-drill", { type = "mining-drill", mining_speed = 0.5, resource_categories = { basic = true }, fluidbox_prototypes = {} }),
    ["iron-ore"] = proto("iron-ore", { type = "resource", resource_category = "basic", infinite_resource = false, normal_resource_amount = 0,
      mineable_properties = { minable = true, mining_time = 1, products = { P("item", "iron-ore", 1) } } }),
    ["offshore-pump"] = proto("offshore-pump", { type = "offshore-pump", get_pumping_speed = function() return 20 end }),
    ["boiler"] = proto("boiler", { type = "boiler" }),
    ["transport-belt"] = proto("transport-belt", { type = "transport-belt", belt_speed = 0.03125 }),
    ["fast-transport-belt"] = proto("fast-transport-belt", { type = "transport-belt", belt_speed = 0.0625 }),
    ["express-transport-belt"] = proto("express-transport-belt", { type = "transport-belt", belt_speed = 0.09375 }),
  }
  prototypes = {
    item = items, fluid = fluids, recipe = recipes, entity = entities, virtual_signal = { ["signal-A"] = proto("signal-A") },
    quality = {}, space_location = {}, asteroid_chunk = {},
    get_entity_filtered = function(filters)
      local out = {}
      for name, p in pairs(entities) do
        for _, f in ipairs(filters) do
          if f.filter == "type" and p.type == f.type then out[name] = p end
        end
      end
      return out
    end,
  }
  -- like LuaPrototypes: an unknown key is an error, not nil
  setmetatable(prototypes, { __index = function(_, k) error("LuaPrototypes doesn't contain key " .. tostring(k), 2) end })
  local force_recipes = {}
  for name, r in pairs(recipes) do
    force_recipes[name] = { name = name, energy = r.energy, ingredients = r.ingredients, products = r.products, productivity_bonus = 0, prototype = r, enabled = true, valid = true }
  end
  force_recipes["express-transport-belt"].enabled = false
  mock.force = { name = "player", valid = true, recipes = force_recipes, belt_stack_size_bonus = 0 }
  helpers = {
    is_valid_sprite_path = mock.sprite_valid,
    table_to_json = function(t) return json.encode(t) end,
    json_to_table = function(s)
      local ok, v = pcall(json.decode, s)
      if ok then return v end
      return nil
    end,
    encode_string = function(s) return "0" .. s end,
    decode_string = function(s) if s:sub(1, 1) == "0" then return s:sub(2) end return nil end,
  }
  mock.drawn = {}
  rendering = {
    draw_rectangle = function(params)
      for k in pairs(params) do
        if not API.draw_rectangle[k] then error("draw_rectangle: unknown parameter " .. k, 2) end
      end
      mock.drawn[#mock.drawn + 1] = params
    end,
  }
  mock.commands = {}
  commands = { add_command = function(name, help, fn) mock.check_localised(help, "command help") mock.commands[name] = fn end }
  mock.interfaces = {}
  remote = { add_interface = function(name, functions) mock.interfaces[name] = functions end }
  script = {
    mod_name = "stoich",
    on_init = function(fn) mock.init.on_init = fn end,
    on_load = function(fn) mock.init.on_load = fn end,
    on_configuration_changed = function(fn) mock.init.on_configuration_changed = fn end,
    on_event = function(event, fn)
      if type(event) == "string" then
        custom[event] = fn
      else
        if event == nil then error("on_event: nil event id", 2) end
        handlers[event] = fn
      end
    end,
  }
  -- Fresh copies of the mod's modules for every scenario.
  for name in pairs(package.loaded) do
    if name:match("^scripts%.") or name == "control" then package.loaded[name] = nil end
  end
  return mock
end

--- The player presses Esc / E: the GUI they have open closes.
function mock.press_esc(player)
  player.press_esc()
end

-- Events ------------------------------------------------------------------------------------------------

function mock.fire(name, data)
  data = data or {}
  local id = defines.events[name]
  if not id then error("unknown event " .. name, 2) end
  data.name = id
  data.tick = game.tick
  local h = mock.handlers[id]
  if h then h(data) end
end

function mock.fire_custom(name, player_index)
  local h = mock.custom[name]
  if not h then error("no handler for custom input " .. name, 2) end
  h({ name = name, player_index = player_index, tick = game.tick })
end

mock.hits = {}

local function gui_event(name, player, element, extra)
  if not element.valid then error("event on an invalid element", 3) end
  local action = data_of[element].tags.fp
  if action then mock.hits[action] = true end
  local data = extra or {}
  data.element = element
  data.player_index = player.index
  mock.fire(name, data)
end

function mock.click(player, element)
  if not element.enabled then error("clicked a disabled element (" .. tostring(element.tags.fp) .. ")", 2) end
  if element.type == "checkbox" then
    -- real checkboxes toggle on click and raise the checked event too
    data_of[element].state = not data_of[element].state
    gui_event("on_gui_checked_state_changed", player, element)
    if not element.valid then return end
  end
  gui_event("on_gui_click", player, element, { button = defines.mouse_button_type.left })
end

-- The game raises on_gui_click before the element's own event when the
-- player clicks into a checkbox, textfield, dropdown, slider or picker.
local function pre_click(player, element)
  if not element.enabled then error("interacted with a disabled element (" .. tostring(element.tags.fp) .. ")", 3) end
  gui_event("on_gui_click", player, element, { button = defines.mouse_button_type.left })
  if not element.valid then error("element destroyed by its own on_gui_click (" .. tostring(data_of[element].tags.fp) .. ")", 3) end
end

function mock.check(player, element, state)
  pre_click(player, element)
  data_of[element].state = state
  gui_event("on_gui_checked_state_changed", player, element)
end

function mock.type_text(player, element, text, confirm)
  pre_click(player, element)
  data_of[element].text = text
  gui_event("on_gui_text_changed", player, element, { text = text })
  if confirm and element.valid then gui_event("on_gui_confirmed", player, element) end
end

function mock.slide(player, element, value)
  pre_click(player, element)
  data_of[element].slider_value = value
  gui_event("on_gui_value_changed", player, element)
end

function mock.select(player, element, index)
  pre_click(player, element)
  data_of[element].selected_index = index
  gui_event("on_gui_selection_state_changed", player, element)
end

function mock.pick(player, element, value)
  pre_click(player, element)
  data_of[element].elem_value = value
  gui_event("on_gui_elem_changed", player, element)
end

--- All elements under root (depth first).
function mock.all(root, out)
  out = out or {}
  for _, c in ipairs(data_of[root].children) do
    out[#out + 1] = c
    mock.all(c, out)
  end
  return out
end

--- First element with tags.fp == action whose other tags match.
function mock.find(root, action, match)
  for _, e in ipairs(mock.all(root)) do
    local tags = data_of[e].tags
    if tags.fp == action then
      local ok = true
      for k, v in pairs(match or {}) do
        if tags[k] ~= v then ok = false end
      end
      if ok then return e end
    end
  end
  return nil
end

function mock.find_all(root, action)
  local out = {}
  for _, e in ipairs(mock.all(root)) do
    if data_of[e].tags.fp == action then out[#out + 1] = e end
  end
  return out
end

function mock.named(root, name)
  for _, e in ipairs(mock.all(root)) do
    if data_of[e].name == name then return e end
  end
  return nil
end

--- Text of every label/button caption under root, flattened, for asserts.
function mock.text(root)
  local parts = {}
  local function flat(v)
    if type(v) == "table" then
      for i = 2, #v do flat(v[i]) end
      if type(v[1]) == "string" and v[1] ~= "" then parts[#parts + 1] = "<" .. v[1] .. ">" end
    elseif v ~= nil then
      parts[#parts + 1] = tostring(v)
    end
  end
  for _, e in ipairs(mock.all(root)) do flat(data_of[e].caption) end
  return table.concat(parts, " ")
end

-- Entities -------------------------------------------------------------------------------------------------

local next_unit = 1

function mock.crafter(type, name, recipe_name, x, y, opts)
  opts = opts or {}
  local r = recipe_name and mock.force.recipes[recipe_name] or nil
  local proto_ = prototypes.entity[name]
  local e = {
    valid = true, type = type, name = name, position = { x = x, y = y }, unit_number = next_unit,
    crafting_speed = opts.speed or proto_.get_crafting_speed(), productivity_bonus = opts.prod or 0, speed_bonus = 0,
    prototype = proto_, surface = mock.surface, quality = { name = "normal" },
    get_recipe = function() if opts.idle then return nil end return r end,
    previous_recipe = opts.previous and { name = mock.force.recipes[opts.previous], quality = "normal" } or nil,
  }
  next_unit = next_unit + 1
  mock.surface.entities[#mock.surface.entities + 1] = e
  return e
end

function mock.boiler(x, y, fuel)
  local e = {
    valid = true, type = "boiler", name = "boiler", position = { x = x, y = y }, unit_number = next_unit,
    burner = { currently_burning = { name = prototypes.item[fuel], quality = "normal" }, inventory = { get_contents = function() return {} end } },
    fluids_count = 2, get_fluid = function() return nil end, surface = mock.surface,
  }
  next_unit = next_unit + 1
  mock.surface.entities[#mock.surface.entities + 1] = e
  return e
end

return mock
