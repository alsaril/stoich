-- Minimal stand-ins for the game globals used by model/plan/draft/scanner.
-- reset() gives every test a fresh world.

local fake = {}

local function proto_table(names)
  local t = {}
  for _, n in ipairs(names) do t[n] = { name = n, localised_name = { "item-name." .. n } } end
  return t
end

--- Quality tiers as the game has them: normal only (base game), or Space Age's five.
function fake.qualities(with_tiers)
  local list = { { "normal", 0, "uncommon" } }
  if with_tiers then
    list = { { "normal", 0, "uncommon" }, { "uncommon", 1, "rare" }, { "rare", 2, "epic" }, { "epic", 3, "legendary" }, { "legendary", 5 } }
  else
    list[1][3] = nil
  end
  local t = {}
  for _, q in ipairs(list) do
    t[q[1]] = { name = q[1], level = q[2], localised_name = { "quality-name." .. q[1] }, hidden = q[1] == "normal",
      next_probability = q[3] and 1 or 0, chain_probability = q[3] and 0.1 or 0, valid = true }
  end
  for _, q in ipairs(list) do
    if q[3] then t[q[1]].next = t[q[3]] end
  end
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
  settings = { global = { ["stoich-edit-permission"] = { value = opts.edit or "everyone" } } }
  prototypes = {
    item = proto_table({ "iron-plate", "copper-plate", "iron-gear-wheel", "electronic-circuit", "copper-cable", "coal", "plastic-bar", "iron-ore", "automation-science-pack" }),
    fluid = proto_table({ "water", "steam", "crude-oil", "heavy-oil", "light-oil", "petroleum-gas", "sulfuric-acid" }),
    recipe = proto_table({ "iron-gear-wheel", "electronic-circuit", "copper-cable", "advanced-oil-processing", "coal-liquefaction" }),
    entity = proto_table({ "assembling-machine-2", "oil-refinery", "electric-mining-drill", "iron-ore", "stone-furnace" }),
    virtual_signal = proto_table({ "signal-A" }),
    quality = fake.qualities(opts.quality),
  }
  -- the crafters (a drill or a resource has no crafting categories)
  for _, name in ipairs({ "assembling-machine-2", "oil-refinery", "stone-furnace" }) do
    prototypes.entity[name].crafting_categories = { crafting = true }
  end
  local model = require("scripts.model")
  model.init()
  return fake
end

function fake.add_player(index, admin)
  game.players[index] = { index = index, name = "player" .. index, admin = admin or false, valid = true }
  return game.players[index]
end

return fake
