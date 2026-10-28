-- Editing logic behind the factory editor, kept apart from the GUI so it is
-- testable offline: capture defaults, anchors, externals, splits, rescan.

local fp_util = require("scripts.util")
local solver = require("scripts.solver")
local model = require("scripts.model")
local plan = require("scripts.plan")
local scanner = require("scripts.scanner")

local draft = {}

-- Drafts -------------------------------------------------------------------------

-- Keys that are derived, not edited; ignored when checking for unsaved changes.
local DERIVED = { result = true, invalid = true }

local function strip(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do
    if not DERIVED[k] then out[k] = strip(x) end
  end
  return out
end

local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, x in pairs(a) do
    if not same(x, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

--- Open a draft for a player: a private copy of a factory (or a new one).
function draft.open(player_index, factory)
  local state = model.player(player_index)
  local copy = fp_util.deep_copy(factory)
  state.draft = {
    factory = copy,
    base = { revision = factory.revision, copies = factory.copies, pinned = factory.pinned },
    snapshot = strip(factory),
    name_auto = false,
  }
  plan.balance_factory(copy)
  return state.draft
end

--- Would closing this draft lose work? A new capture always counts, an empty
--- new factory doesn't, a saved one only when it differs from how it was opened.
function draft.is_dirty(d)
  if not d then return false end
  local f = d.factory
  if not f.id then
    if #f.lines > 0 and f.kind ~= "sink" then return true end
    for _, row in ipairs(f.sink_items or {}) do
      if row.key or (row.rate or 0) ~= 0 then return true end
    end
    return (f.name or "") ~= (d.snapshot.name or "")
  end
  return not same(strip(f), d.snapshot)
end

function draft.get(player_index)
  local state = storage.players[player_index]
  return state and state.draft
end

function draft.close(player_index)
  local state = storage.players[player_index]
  if state then state.draft = nil end
end

-- Capture defaults -----------------------------------------------------------------

--- Line producing the most of an item at its scanned count.
local function main_line(factory, item)
  local best, best_v = nil, 0
  for _, line in ipairs(factory.lines) do
    local p = line.flow[item]
    if p and p > 0 and not line.idle then
      local v = p * line.count
      if v > best_v then best, best_v = line, v end
    end
  end
  return best
end

--- Fill splits for every free choice from the scanned counts, so a captured
--- build balances at once. Each prompt's candidate items are tried in order;
--- one that makes the factory conflict or go negative is skipped.
--- Returns the final result.
function draft.prefill_splits(factory)
  local result = plan.balance_factory(factory)
  local lines = plan.solvable_lines(factory)
  local tried = {}
  for _ = 1, 20 do
    local prompt
    for _, p in ipairs(result.problems) do
      if p.type == "split" and not tried[p.item] then prompt = p break end
    end
    if not prompt then break end
    tried[prompt.item] = true
    local accepted = false
    for _, item in ipairs(prompt.candidates) do
      local saved = fp_util.deep_copy(factory.splits)
      draft.add_split(factory, item, solver.producers_of(lines, item))
      local r = plan.balance_factory(factory)
      if r.status ~= "CONFLICT" and r.status ~= "NEGATIVE" and r.unknowns - r.rank < result.unknowns - result.rank then
        result = r
        accepted = true
        break
      end
      factory.splits = saved
    end
    if not accepted then result = plan.balance_factory(factory) end
  end
  return result
end

--- Build a factory from scanned lines.
--- @param scan table from scanner.scan_entities (or a fake with .lines)
--- @param source table? { surface_index, areas }
function draft.from_scan(scan, source)
  local f = model.new_factory("factory")
  for _, line in ipairs(scan.lines) do model.add_line(f, line) end
  f.source = source
  local main = scanner.main_product(plan.solvable_lines(f))
  if main then
    local t, n = fp_util.parse_key(main)
    f.icon = { type = t, name = n }
    f.name = fp_util.pretty_name(n)
    local line = main_line(f, main)
    if line then f.anchors[line.id] = line.count end
  else
    f.name = "Factory"
  end
  -- Suggested externals: items with no producer or no consumer inside.
  local probe = solver.balance(plan.solvable_lines(f), {}, {}, {})
  for item in pairs(probe.suggested_external) do f.external[item] = true end
  draft.prefill_splits(f)
  f.main_product = main
  return f
end

--- A sink with the fuel of the selected generators prefilled at rate 0.
function draft.sink_from_generators(fuels)
  local f = model.new_factory("sink")
  model.add_line(f, { kind = "custom", label = "consumption", count = 1, flow = {} })
  f.sink_items = {}
  for _, key in ipairs(fp_util.sorted_keys(fuels)) do
    f.sink_items[#f.sink_items + 1] = { key = key, rate = 0 }
  end
  draft.sync_sink(f)
  f.name = "Generators"
  local first = f.sink_items[1]
  if first then
    local t, n = fp_util.parse_key(first.key)
    if t == "item" or t == "fluid" then f.icon = { type = t, name = n } end
  end
  return f
end

--- New empty sink.
function draft.new_sink()
  local f = model.new_factory("sink")
  model.add_line(f, { kind = "custom", label = "consumption", count = 1, flow = {} })
  f.sink_items = {}
  f.name = "Sink"
  return f
end

--- Rows of a sink (item, rate per second) -> its consumption line.
function draft.sync_sink(f)
  local line = f.lines[1]
  if not line then line = model.add_line(f, { kind = "custom", label = "consumption", count = 1, flow = {} }) end
  line.flow = {}
  line.fluid_keys = {}
  for _, row in ipairs(f.sink_items or {}) do
    if row.key and row.rate and row.rate ~= 0 then
      line.flow[row.key] = (line.flow[row.key] or 0) - math.abs(row.rate)
      if row.fluid then line.fluid_keys[row.key] = true end
    end
  end
  f.external = plan.flow_items(line.flow)
  f.anchors = { [line.id] = 1 }
  -- No icon chosen yet: use the first item.
  if not f.icon then
    for _, row in ipairs(f.sink_items or {}) do
      local t, n = fp_util.parse_key(row.key or "")
      if row.key and (t == "item" or t == "fluid") then
        f.icon = { type = t, name = n }
        break
      end
    end
  end
end

-- Anchors and externals ---------------------------------------------------------------

function draft.set_anchor(f, line_id, value)
  if value == nil then
    f.anchors[line_id] = nil
  else
    f.anchors[line_id] = math.max(0, value)
  end
end

function draft.set_external(f, item, on)
  f.external[item] = on and true or nil
end

-- Splits -----------------------------------------------------------------------------------

local function lines_by_id(lines)
  local by = {}
  for _, line in ipairs(lines) do by[line.id] = line end
  return by
end

--- Split rows in display order: sorted line ids that produce the item.
function draft.split_lines(lines, split)
  local by = lines_by_id(lines)
  local ids = {}
  for id in pairs(split.shares) do
    local line = by[id]
    if line and (line.flow[split.item] or 0) > 0 then ids[#ids + 1] = id end
  end
  table.sort(ids, solver.id_less)
  return ids
end

--- Add a split from a prompt, shares from current counts (scanned build).
--- @param lines table[]? the units (defaults to the factory's lines)
--- @param counts table? counts by id (defaults to line.count)
function draft.add_split(holder, item, ids, lines, counts)
  lines = lines or holder.lines
  local by = lines_by_id(lines)
  local flows, cnt = {}, {}
  for _, id in ipairs(ids) do
    flows[id] = by[id].flow
    cnt[id] = counts and counts[id] or by[id].count or 0
  end
  local shares = solver.shares_from_counts(item, ids, flows, cnt)
  -- Replace an existing split on the same item.
  for i, split in ipairs(holder.splits) do
    if split.item == item then
      holder.splits[i] = { item = item, shares = shares }
      return i
    end
  end
  holder.splits[#holder.splits + 1] = { item = item, shares = shares }
  return #holder.splits
end

function draft.remove_split(holder, index)
  table.remove(holder.splits, index)
end

--- Set one share. The last line's share is always 100 minus the rest; when the
--- new share doesn't fit next to the others, the others shrink proportionally.
function draft.set_share(holder, index, line_id, pct, lines)
  local split = holder.splits[index]
  if not split then return end
  local ids = draft.split_lines(lines or holder.lines, split)
  if #ids < 2 then return end
  local last = ids[#ids]
  if line_id == last then return end
  pct = math.max(0, math.min(pct, 100))
  local others = 0
  for _, id in ipairs(ids) do
    if id ~= line_id and id ~= last then others = others + (split.shares[id] or 0) end
  end
  local excess = pct + others - 100
  if excess > 0 and others > 0 then
    local keep = (others - excess) / others
    for _, id in ipairs(ids) do
      if id ~= line_id and id ~= last then split.shares[id] = (split.shares[id] or 0) * keep end
    end
    others = others - excess
  end
  split.shares[line_id] = pct
  split.shares[last] = math.max(0, 100 - others - pct)
end

--- Items a split could switch to: products of two or more of its lines.
function draft.split_candidates(lines, split)
  local by = lines_by_id(lines)
  local made = {}
  for id in pairs(split.shares) do
    local line = by[id]
    if line then
      for item, v in pairs(line.flow) do
        if v > 0 then made[item] = (made[item] or 0) + 1 end
      end
    end
  end
  local out = {}
  for item, k in pairs(made) do
    if k >= 2 then out[#out + 1] = item end
  end
  table.sort(out)
  return out
end

--- Switch the split to another shared item, keeping the current machine ratio.
--- The new split covers every line that makes the new item.
function draft.switch_split_item(holder, index, item, lines, counts)
  local split = holder.splits[index]
  if not split then return end
  lines = lines or holder.lines
  local by = lines_by_id(lines)
  local ids = solver.producers_of(lines, item)
  if #ids < 2 then return end
  local flows, cnt = {}, {}
  for _, id in ipairs(ids) do
    flows[id] = by[id].flow
    cnt[id] = counts and counts[id] or by[id].count or 0
  end
  holder.splits[index] = { item = item, shares = solver.shares_from_counts(item, ids, flows, cnt) }
end

-- Rescan ---------------------------------------------------------------------------------------

--- Apply a new scan to a factory: matching lines get new counts and flows
--- (unless overridden), vanished ones go to 0, new ones are added.
--- @return table { updated, added, missing }
function draft.apply_rescan(f, scan)
  local by_key = {}
  for _, line in ipairs(scan.lines) do by_key[line.key] = line end
  local seen = {}
  local stats = { updated = 0, added = 0, missing = 0 }
  for key in pairs(f.removed_keys or {}) do seen[key] = true end
  for _, line in ipairs(f.lines) do
    if line.assigned_from then
      -- machines that got a recipe in the editor are still idle on the map: follow their count
      seen[line.assigned_from] = true
      local idle = by_key[line.assigned_from]
      if idle and not line.overridden then
        local a = f.anchors[line.id]
        if a and math.abs(a - line.count) < 1e-9 then f.anchors[line.id] = idle.count end
        line.count = idle.count
      end
    end
    if line.key then
      local new = by_key[line.key]
      seen[line.key] = true
      if not line.overridden then
        local old_count = line.count
        if new then
          line.count = new.count
          line.flow = new.flow
          line.missing = nil
          stats.updated = stats.updated + 1
        else
          line.count = 0
          line.missing = true
          stats.missing = stats.missing + 1
        end
        -- An anchor at the old scanned count follows the new count.
        local a = f.anchors[line.id]
        if a and math.abs(a - old_count) < 1e-9 then f.anchors[line.id] = line.count end
      end
    end
  end
  for _, line in ipairs(scan.lines) do
    if not seen[line.key] then
      model.add_line(f, line)
      stats.added = stats.added + 1
    end
  end
  return stats
end

--- Replace a factory's contents with a fresh capture, keeping what identifies it:
--- id, name, icon, copies, Fixed flag, revision. Lines, anchors, splits, externals
--- and the captured area come from the new capture.
function draft.recapture(f, captured)
  f.lines = captured.lines
  f.anchors = captured.anchors
  f.splits = captured.splits
  f.external = captured.external
  f.source = captured.source
  f.next_line_id = captured.next_line_id
  f.main_product = captured.main_product
  f.removed_keys = nil
  if not f.icon then f.icon = captured.icon end
  return f
end

-- Manual and custom lines -------------------------------------------------------------------------

function draft.add_custom_line(f, label, rows)
  local line = model.add_line(f, { kind = "custom", label = label or "custom", count = 1, flow = {}, rows = rows or {} })
  draft.sync_custom(line)
  return line
end

--- Rows (item, amount per second, fluid flag) -> flow of a custom line.
function draft.sync_custom(line)
  line.flow = {}
  line.fluid_keys = {}
  for _, row in ipairs(line.rows or {}) do
    if row.key and row.amount and row.amount ~= 0 then
      line.flow[row.key] = (line.flow[row.key] or 0) + row.amount
      if row.fluid then line.fluid_keys[row.key] = true end
    end
  end
end

--- Turn a flow map into editable rows (for overrides of scanned lines).
function draft.rows_from_flow(line)
  local rows = {}
  for _, key in ipairs(fp_util.sorted_keys(line.flow)) do
    rows[#rows + 1] = { key = key, amount = line.flow[key], fluid = line.fluid_keys and line.fluid_keys[key] or nil }
  end
  return rows
end

return draft
