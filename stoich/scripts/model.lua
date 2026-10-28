-- Storage access: structure, ids, revisions, edit log, permissions, validation.
-- All shared state lives in `storage`; nothing is kept in Lua locals between events.

local fp_util = require("scripts.util")

local model = {}

model.SCHEMA = 1
model.LOG_SIZE = 50
model.PLAN = "main"

local function new_plan()
  return { factories = {}, external = {}, splits = {}, result = nil }
end

function model.init()
  storage.schema = model.SCHEMA
  storage.next_id = storage.next_id or 1
  storage.plans = storage.plans or {}
  storage.plans[model.PLAN] = storage.plans[model.PLAN] or new_plan()
  storage.settings = storage.settings or {}
  storage.log = storage.log or {}
  storage.players = storage.players or {}
end

--- Bring older storage up to date. Called from on_configuration_changed.
function model.migrate()
  if not storage.schema then
    model.init()
  end
  -- schema 1 is the first; future migrations go here, one `if storage.schema < n` block each.
  storage.schema = model.SCHEMA
end

function model.plan()
  return storage.plans[model.PLAN]
end

function model.new_id()
  local id = storage.next_id
  storage.next_id = id + 1
  return id
end

--- Per-player GUI state.
function model.player(index)
  local p = storage.players[index]
  if not p then
    p = { tab = "plan", filter = "", hide_ok = false, expanded = {}, location = nil, draft = nil }
    storage.players[index] = p
  end
  return p
end

function model.remove_player(index)
  storage.players[index] = nil
end

--- A new factory or sink table (not yet in the plan).
function model.new_factory(kind)
  return {
    id = nil,
    name = "",
    icon = nil,
    kind = kind or "factory",
    lines = {},
    anchors = {},
    splits = {},
    external = {},
    copies = 1,
    pinned = false,
    group = nil,
    result = nil,
    source = nil,
    revision = 0,
    modified_by = nil,
    modified_tick = nil,
    next_line_id = 1,
  }
end

function model.add_line(factory, line)
  line.id = factory.next_line_id or (#factory.lines + 1)
  factory.next_line_id = line.id + 1
  line.fluid_keys = line.fluid_keys or {}
  line.overridden = line.overridden or false
  factory.lines[#factory.lines + 1] = line
  return line
end

function model.find_line(factory, id)
  for i, line in ipairs(factory.lines) do
    if line.id == id then return line, i end
  end
end

function model.remove_line(factory, id)
  local line, i = model.find_line(factory, id)
  if i then table.remove(factory.lines, i) end
  factory.anchors[id] = nil
  -- Rescan must not bring back a scanned line the user deleted.
  local key = line and (line.key or line.assigned_from)
  if key then
    factory.removed_keys = factory.removed_keys or {}
    factory.removed_keys[key] = true
  end
end

--- Sorted factory ids of the plan.
function model.factory_ids()
  return fp_util.sorted_keys(model.plan().factories)
end

function model.get(id)
  return id and model.plan().factories[id]
end

-- Permissions ----------------------------------------------------------------

function model.edit_mode()
  local s = settings.global["stoich-edit-permission"]
  return s and s.value or "everyone"
end

function model.can_edit(player)
  if not (player and player.valid) then return false end
  if model.edit_mode() == "admins" then return player.admin end
  return true
end

-- Log ------------------------------------------------------------------------

--- @param action LocalisedString what happened, e.g. { "stoich.log-deleted" }
function model.log(player_index, action, factory_name)
  local log = storage.log
  log[#log + 1] = { tick = game.tick, player = player_index, action = action, factory = factory_name }
  while #log > model.LOG_SIZE do table.remove(log, 1) end
end

-- Changes ----------------------------------------------------------------------

--- Save a factory from a draft copy.
--- @param factory table the edited copy (draft.factory)
--- @param base table { revision, copies, pinned } as they were when the draft was opened
--- @param player_index integer
--- @param force boolean? overwrite even if someone saved or deleted it in between
--- @return boolean ok
--- @return table result the saved factory, or the conflict { modified_by, modified_tick, deleted? }
function model.save_factory(factory, base, player_index, force)
  local plan = model.plan()
  base = base or {}
  local existing = factory.id and plan.factories[factory.id]
  if not force then
    if existing and existing.revision ~= base.revision then
      return false, { modified_by = existing.modified_by, modified_tick = existing.modified_tick, revision = existing.revision }
    end
    if factory.id and not existing then
      return false, { deleted = true }
    end
  end
  local saved = fp_util.deep_copy(factory)
  local action = "edited"
  if existing then
    -- Copies and pin change live without a draft; keep the current ones unless this draft changed them.
    if saved.copies == base.copies then saved.copies = existing.copies end
    if saved.pinned == base.pinned then saved.pinned = existing.pinned end
  else
    saved.id = saved.id or model.new_id()
    action = "created"
  end
  saved.revision = (existing and existing.revision or 0) + 1
  saved.modified_by = player_index
  saved.modified_tick = game.tick
  plan.factories[saved.id] = saved
  model.log(player_index, { "stoich.log-" .. action }, saved.name)
  return true, saved
end

function model.delete_factory(id, player_index)
  local plan = model.plan()
  local f = plan.factories[id]
  if not f then return false end
  plan.factories[id] = nil
  -- Drop this factory from plan splits.
  for _, split in ipairs(plan.splits) do split.shares[id] = nil end
  model.log(player_index, { "stoich.log-deleted" }, f.name)
  return true
end

function model.set_copies(id, copies, player_index)
  local f = model.get(id)
  if not f or f.kind == "sink" then return false end
  copies = math.max(0, copies)
  if f.copies == copies then return false end
  f.copies = copies
  f.modified_by = player_index
  f.modified_tick = game.tick
  model.log(player_index, { "stoich.log-copies", fp_util.format_count(copies) }, f.name)
  return true
end

function model.set_pinned(id, pinned, player_index)
  local f = model.get(id)
  if not f or f.kind == "sink" then return false end
  f.pinned = pinned and true or false
  model.log(player_index, { pinned and "stoich.log-pinned" or "stoich.log-unpinned" }, f.name)
  return true
end

-- Validation -----------------------------------------------------------------

local function line_problems(line)
  local problems = {}
  -- An overridden or custom line is defined by its flow; its recipe name is only a label.
  if line.kind ~= "custom" and not line.overridden then
    if line.recipe and not prototypes.recipe[line.recipe] then problems[#problems + 1] = "recipe " .. line.recipe end
    if line.machine and not prototypes.entity[line.machine] then problems[#problems + 1] = "machine " .. line.machine end
    if line.kind == "mining" and line.resource and not prototypes.entity[line.resource] then
      problems[#problems + 1] = "resource " .. line.resource
    end
  end
  for _, key in ipairs(fp_util.sorted_keys(line.flow or {})) do
    if not fp_util.key_exists(key) then problems[#problems + 1] = key end
  end
  return problems
end

-- Prototype table for each signal type an icon can have.
local ICON_TABLES = {
  item = "item", fluid = "fluid", virtual = "virtual_signal", entity = "entity", recipe = "recipe",
  ["space-location"] = "space_location", quality = "quality", ["asteroid-chunk"] = "asteroid_chunk",
}

--- Factory-level invalid list from its lines (no prototype lookups).
function model.collect_invalid(f)
  local missing = {}
  for _, line in ipairs(f.lines) do
    for _, p in ipairs(line.invalid or {}) do missing[#missing + 1] = p end
  end
  return #missing > 0 and missing or nil
end

--- Mark lines and factories whose prototypes are gone. Never deletes data.
--- @return boolean invalid
function model.validate_factory(f)
  for _, line in ipairs(f.lines) do
    local problems = line_problems(line)
    line.invalid = #problems > 0 and problems or nil
  end
  if f.icon and f.icon.name then
    local tbl = prototypes[ICON_TABLES[f.icon.type or "item"] or ""]
    if tbl and not tbl[f.icon.name] then f.icon = nil end
  end
  f.invalid = model.collect_invalid(f)
  return f.invalid ~= nil
end

function model.validate_all()
  local bad = 0
  for _, id in ipairs(model.factory_ids()) do
    if model.validate_factory(model.plan().factories[id]) then bad = bad + 1 end
  end
  for _, p in pairs(storage.players) do
    if p.draft and p.draft.factory then model.validate_factory(p.draft.factory) end
  end
  return bad
end

return model
