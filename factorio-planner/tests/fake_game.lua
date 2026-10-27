-- Minimal stand-ins for the game globals used by model/plan/draft/scanner.
-- reset() gives every test a fresh world.

local fake = {}

local function proto_table(names)
  local t = {}
  for _, n in ipairs(names) do t[n] = { name = n, localised_name = { "item-name." .. n } } end
  return t
end

function fake.reset(opts)
  opts = opts or {}
  storage = {}
  local players = {}
  game = {
    tick = 0,
    players = players,
    get_player = function(i) return players[i] end,
    print = function() end,
  }
  settings = { global = { ["fp-edit-permission"] = { value = opts.edit or "everyone" } } }
  prototypes = {
    item = proto_table({ "iron-plate", "copper-plate", "iron-gear-wheel", "electronic-circuit", "copper-cable", "coal", "plastic-bar", "iron-ore", "automation-science-pack" }),
    fluid = proto_table({ "water", "steam", "crude-oil", "heavy-oil", "light-oil", "petroleum-gas", "sulfuric-acid" }),
    recipe = proto_table({ "iron-gear-wheel", "electronic-circuit", "copper-cable", "advanced-oil-processing", "coal-liquefaction" }),
    entity = proto_table({ "assembling-machine-2", "oil-refinery", "electric-mining-drill", "iron-ore", "stone-furnace" }),
    virtual_signal = proto_table({ "signal-A" }),
  }
  local model = require("scripts.model")
  model.init()
  return fake
end

function fake.add_player(index, admin)
  game.players[index] = { index = index, name = "player" .. index, admin = admin or false, valid = true }
  return game.players[index]
end

return fake
