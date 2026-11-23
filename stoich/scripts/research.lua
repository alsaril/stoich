-- Research and mod updates change numbers only when a player says so: lines keep what they
-- were worked out from, the plan lists the factories that would change, and Update all takes
-- the new numbers in (runtime).

local model = require("scripts.model")
local plan = require("scripts.plan")
local scanner = require("scripts.scanner")
local fp_util = require("scripts.util")

local research = {}

--- Lines of a factory that research or a mod update would change: { [line id] = new flow }.
--- Overridden, custom and old lines (without inputs) are never worked out again (runtime).
function research.changed_lines(f, force)
  local out, any = {}, false
  if plan.is_list(f) then return out, false end
  for _, line in ipairs(f.lines) do
    if not line.invalid and scanner.has_inputs(line) then
      local flow = scanner.line_flow(line, force)
      if flow and scanner.flows_differ(line.flow, flow) then
        out[line.id] = flow
        any = true
      end
    end
  end
  return out, any
end

--- The force whose research a factory follows (runtime): the force of whoever saved it
--- last (teams in a PvP game share a surface's plan), else the player force.
function research.force_of(f)
  local forces = game.forces
  if not forces then return nil end
  local own = f and f.force_name and forces[f.force_name]
  if own and own.valid ~= false then return own end
  return forces.player or forces[1]
end

--- Factories of a plan whose numbers research (or a mod update) changed, with the copies
--- the plan needs of each before and after (runtime).
--- @return table? { factories = { { id, name, lines, before, after } } } or nil when nothing changes
--- @param force LuaForce? one force for every factory (tests); nil: each factory's own
function research.pending_changes(key, force)
  local p = model.plan(key)
  local override, list = {}, {}
  for _, id in ipairs(model.factory_ids(key)) do
    local f = p.factories[id]
    local changed, any = research.changed_lines(f, force or research.force_of(f))
    if any then
      local copy = fp_util.deep_copy(f)
      local n = 0
      for _, line in ipairs(copy.lines) do
        if changed[line.id] then
          line.flow = changed[line.id]
          n = n + 1
        end
      end
      plan.balance_factory(copy)
      override[id] = copy
      list[#list + 1] = { id = id, name = f.name, lines = n }
    end
  end
  if #list == 0 then return nil end
  local before = p.result or plan.solve(key, nil, { diagnose = "none" })
  local after = plan.solve(key, override, { diagnose = "none" })
  for _, entry in ipairs(list) do
    local function needed(r)
      if not r.counts or r.undetermined[entry.id] then return nil end
      return r.counts[entry.id]
    end
    entry.before, entry.after = needed(before), needed(after)
  end
  return { factories = list }
end

--- Write what research changed into the plan's factories (Update all): new flows, a new
--- revision (an open draft of one of them then has a stale save), one log entry (runtime).
--- @return integer factories updated
function research.apply_pending(key, player_index, force)
  local p = model.plan(key)
  local n = 0
  for _, id in ipairs(model.factory_ids(key)) do
    local f = p.factories[id]
    local changed, any = research.changed_lines(f, force or research.force_of(f))
    if any then
      for _, line in ipairs(f.lines) do
        if changed[line.id] then line.flow = changed[line.id] end
      end
      f.revision = (f.revision or 0) + 1
      f.modified_by = player_index
      f.modified_tick = game.tick
      plan.balance_factory(f)
      n = n + 1
    end
  end
  if n > 0 then model.log(player_index, { "stoich.log-research-update", n }, nil, key) end
  return n
end

--- Work out again what research changed, for every plan (runtime). Cheap: only plans with a
--- changed line are balanced (twice).
function research.check_pending()
  storage.pending = {}
  for _, key in ipairs(model.plan_keys()) do
    storage.pending[key] = research.pending_changes(key)
  end
end

return research
