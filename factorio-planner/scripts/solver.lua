-- balance(): builds the equations of a factory or plan, solves them exactly and
-- names what is missing (a split or anchor) or what can't balance.
-- Pure Lua: no game API, so it runs in the offline tests.

local linalg = require("scripts.linalg")

local solver = {}

local abs = math.abs

solver.NEGATIVE_TOL = 1e-6
solver.ZERO_TOL = 1e-9

--- Total order for line ids: numbers before strings, then natural order.
function solver.id_less(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta == "number" end
  return a < b
end
local id_less = solver.id_less

local function sorted_keys(t, less)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, less)
  return keys
end
solver.sorted_keys = sorted_keys

--- Order of flow components, ported from Kotlin FlowComponent.compareTo:
--- producers first (largest first), then consumers (largest first).
--- Ties are broken by source so the order is always the same.
local function sign_class(x)
  if x > 0 then return 0 elseif x == 0 then return 1 else return 2 end
end

function solver.component_less(a, b)
  local ca, cb = a.count, b.count
  local sa, sb = sign_class(ca), sign_class(cb)
  if sa ~= sb then return sa < sb end
  if ca ~= cb then
    -- positive: largest first; negative: most negative first
    if sa == 0 then return ca > cb end
    if sa == 2 then return ca < cb end
  end
  if a.virtual ~= b.virtual then return not a.virtual end
  return id_less(a.source, b.source)
end

--- Splits that still make sense: at least two existing lines in `shares` that
--- produce the split item, and a positive total share.
--- @return table[] valid { index, item, lines = {id...}, shares = {[id]=pct}, total }
--- @return integer[] dropped indices into `splits`
local function check_splits(splits, by_id)
  local valid, dropped = {}, {}
  for index, split in ipairs(splits) do
    local lines, total = {}, 0
    for id, share in pairs(split.shares or {}) do
      local line = by_id[id]
      local p = line and line.flow[split.item]
      if p and p > 0 and share >= 0 then
        lines[#lines + 1] = id
        total = total + share
      end
    end
    table.sort(lines, id_less)
    if #lines >= 2 and total > 0 then
      valid[#valid + 1] = { index = index, item = split.item, lines = lines, shares = split.shares, total = total }
    else
      dropped[#dropped + 1] = index
    end
  end
  table.sort(valid, function(x, y)
    if x.item ~= y.item then return x.item < y.item end
    if x.lines[1] ~= y.lines[1] then return id_less(x.lines[1], y.lines[1]) end
    return x.index < y.index
  end)
  return valid, dropped
end

--- Balance lines against anchors and splits.
--- @param lines table[] { id = any, flow = { [item_key] = rate per unit } }
--- @param anchors table<any, number> fixed counts by line id
--- @param splits table[]? { item = item_key, shares = { [line_id] = percent } }
--- @param external table<string, boolean>? items allowed to cross the boundary
--- @param opts table? { require_anchor = bool }
--- @return table result { status, counts, undetermined, net, flow, problems, suggested_external }
function solver.balance(lines, anchors, splits, external, opts)
  anchors = anchors or {}
  splits = splits or {}
  external = external or {}
  opts = opts or {}

  local L, by_id = {}, {}
  for _, line in ipairs(lines) do
    L[#L + 1] = line
    by_id[line.id] = line
  end
  table.sort(L, function(x, y) return id_less(x.id, y.id) end)

  -- Items and who makes / uses them.
  local item_set, producers, consumers = {}, {}, {}
  for _, line in ipairs(L) do
    for item, v in pairs(line.flow) do
      if v ~= 0 then
        item_set[item] = true
        if v > 0 then producers[item] = (producers[item] or 0) + 1 end
        if v < 0 then consumers[item] = (consumers[item] or 0) + 1 end
      end
    end
  end
  local items = sorted_keys(item_set)

  local free_ids, col_of = {}, {}
  local any_anchor = false
  for _, line in ipairs(L) do
    if anchors[line.id] == nil then
      free_ids[#free_ids + 1] = line.id
      col_of[line.id] = #free_ids
    else
      any_anchor = true
    end
  end
  local n = #free_ids

  -- Equations.
  local A, b, origins = {}, {}, {}
  local function add_row(row, rhs, origin)
    A[#A + 1] = row
    b[#b + 1] = rhs
    origins[#origins + 1] = origin
  end

  for _, item in ipairs(items) do
    if not external[item] then
      local row, rhs = {}, 0
      for _, line in ipairs(L) do
        local v = line.flow[item]
        if v and v ~= 0 then
          local a = anchors[line.id]
          if a then
            rhs = rhs - a * v
          else
            local c = col_of[line.id]
            row[c] = (row[c] or 0) + v
          end
        end
      end
      add_row(row, rhs, { kind = "item", item = item })
    end
  end

  local valid_splits, dropped_splits = check_splits(splits, by_id)
  for _, split in ipairs(valid_splits) do
    local item, P = split.item, split.lines
    for k = 1, #P - 1 do
      local r = P[k]
      local row, rhs = {}, 0
      local function add(id, coef)
        local a = anchors[id]
        if a then
          rhs = rhs - coef * a
        else
          local c = col_of[id]
          row[c] = (row[c] or 0) + coef
        end
      end
      add(r, by_id[r].flow[item])
      local s = split.shares[r] / split.total
      for _, j in ipairs(P) do add(j, -s * by_id[j].flow[item]) end
      add_row(row, rhs, { kind = "split", split = split.index, item = item, line = r })
    end
  end

  local split_items = {}
  for _, split in ipairs(valid_splits) do split_items[split.item] = true end

  local rr = linalg.rref(A, b, n)

  -- Counts: anchors fixed, free lines from the solution (free columns at 0).
  local counts = {}
  for _, line in ipairs(L) do
    local a = anchors[line.id]
    counts[line.id] = a or rr.solution[col_of[line.id]]
  end

  local problems = {}
  local status = "EXACT"

  -- Conflicts: rows that reduce to 0 = non-zero.
  if #rr.inconsistent > 0 then
    status = "CONFLICT"
    local seen = {}
    for _, bad in ipairs(rr.inconsistent) do
      local origin_items, origin_splits, one_sided = {}, {}, {}
      for _, eq in ipairs(bad.origin) do
        local o = origins[eq]
        if o.kind == "item" then
          origin_items[#origin_items + 1] = o.item
          if not producers[o.item] then
            one_sided[#one_sided + 1] = o.item
          elseif not consumers[o.item] then
            one_sided[#one_sided + 1] = o.item
          end
        else
          origin_splits[#origin_splits + 1] = o.split
        end
      end
      local named = #one_sided > 0 and one_sided or origin_items
      local reasons = {}
      for _, item in ipairs(named) do
        if not producers[item] then
          reasons[item] = "no_producer"
        elseif not consumers[item] then
          reasons[item] = "no_consumer"
        end
      end
      local key = table.concat(named, "\0") .. "|" .. table.concat(origin_splits, ",")
      if not seen[key] then
        seen[key] = true
        problems[#problems + 1] = {
          type = "conflict",
          items = named,
          reasons = reasons,
          involved = origin_items,
          splits = origin_splits,
        }
      end
    end
  end

  -- Free choices: one prompt per free column, merged by suggested item.
  local undetermined = {}
  if rr.rank < n then
    if status == "EXACT" then status = "NEEDS_SPLIT" end
    local by_item, order = {}, {}
    for _, f in ipairs(rr.free) do
      local v = rr.null(f)
      local vmax = 0
      for c = 1, n do if abs(v[c]) > vmax then vmax = abs(v[c]) end end
      local group = {}
      for c = 1, n do
        if abs(v[c]) > solver.ZERO_TOL * vmax then
          group[#group + 1] = free_ids[c]
          undetermined[free_ids[c]] = true
        end
      end
      table.sort(group, id_less)
      -- Candidate items: made by a line of the group and by at least one other line.
      -- A split over k producers adds k - 1 equations, so items with the fewest
      -- producers come first (they fix the free choice without over-constraining),
      -- then external ones, then by name.
      -- An item that already has a valid split can't help: its rows are in the
      -- system, so the free direction already satisfies them.
      local made = {}
      for _, id in ipairs(group) do
        for item, p in pairs(by_id[id].flow) do
          if p > 0 and (producers[item] or 0) >= 2 and not split_items[item] then made[item] = true end
        end
      end
      local candidates = sorted_keys(made)
      table.sort(candidates, function(x, y)
        if producers[x] ~= producers[y] then return producers[x] < producers[y] end
        local ex, ey = external[x] and 1 or 0, external[y] and 1 or 0
        if ex ~= ey then return ex > ey end
        return x < y
      end)
      if #candidates > 0 then
        local item = candidates[1]
        if not by_item[item] then
          local lines_of = {}
          for _, line in ipairs(L) do
            if (line.flow[item] or 0) > 0 then lines_of[#lines_of + 1] = line.id end
          end
          local prompt = { type = "split", item = item, candidates = candidates, lines = lines_of }
          by_item[item] = prompt
          order[#order + 1] = prompt
        end
      else
        order[#order + 1] = { type = "anchor", lines = group }
      end
    end
    for _, prompt in ipairs(order) do problems[#problems + 1] = prompt end
  end

  if opts.require_anchor and not any_anchor and #L > 0 then
    if status == "EXACT" then status = "NEEDS_SPLIT" end
    local ids = {}
    for _, line in ipairs(L) do ids[#ids + 1] = line.id end
    -- one anchor prompt is enough: widen an existing one to all lines
    local existing
    for _, p in ipairs(problems) do
      if p.type == "anchor" then existing = p end
    end
    if existing then existing.lines = ids else problems[#problems + 1] = { type = "anchor", lines = ids } end
  end

  -- Negative counts only matter once the rest is solved.
  if status == "EXACT" then
    local negative = {}
    for _, line in ipairs(L) do
      if counts[line.id] < -solver.NEGATIVE_TOL then negative[#negative + 1] = line.id end
    end
    if #negative > 0 then
      status = "NEGATIVE"
      problems[#problems + 1] = { type = "negative", lines = negative }
    end
  end

  for _, index in ipairs(dropped_splits) do
    problems[#problems + 1] = { type = "split_dropped", split = index, item = splits[index].item }
  end

  -- Net flow and flow view.
  local net, flow = {}, {}
  for _, item in ipairs(items) do
    local comps, pos, neg = {}, 0, 0
    for _, line in ipairs(L) do
      local v = line.flow[item]
      if v and v ~= 0 then
        local c = counts[line.id] * v
        if c > 0 then pos = pos + c else neg = neg - c end
        comps[#comps + 1] = { source = line.id, virtual = false, count = c }
      end
    end
    local total = pos > neg and pos or neg
    local diff = pos - neg
    local tol = solver.ZERO_TOL * (pos + neg)
    if abs(diff) > tol and abs(diff) > 1e-12 then
      net[item] = diff
      comps[#comps + 1] = { source = diff > 0 and "output" or "input", virtual = true, count = -diff }
    end
    for _, comp in ipairs(comps) do
      comp.percent = total > 0 and comp.count / total or 0
    end
    table.sort(comps, solver.component_less)
    if total > 0 or #comps > 0 then
      flow[#flow + 1] = { item = item, total = total, components = comps }
    end
  end
  table.sort(flow, function(x, y)
    if x.total ~= y.total then return x.total > y.total end
    return x.item < y.item
  end)

  local suggested_external = {}
  for _, item in ipairs(items) do
    if not producers[item] or not consumers[item] then suggested_external[item] = true end
  end

  return {
    status = status,
    counts = counts,
    undetermined = undetermined,
    net = net,
    flow = flow,
    problems = problems,
    suggested_external = suggested_external,
    rank = rr.rank,
    unknowns = n,
  }
end

--- Ids of lines that produce an item, sorted.
function solver.producers_of(lines, item)
  local ids = {}
  for _, line in ipairs(lines) do
    if (line.flow[item] or 0) > 0 then ids[#ids + 1] = line.id end
  end
  table.sort(ids, id_less)
  return ids
end

--- Shares that reproduce the given counts for a split item, in %.
--- Used to pre-fill splits from a scanned build.
function solver.shares_from_counts(item, ids, flows, counts)
  local total = 0
  for _, id in ipairs(ids) do
    total = total + math.max(0, (counts[id] or 0) * (flows[id][item] or 0))
  end
  local shares = {}
  for _, id in ipairs(ids) do
    if total > 0 then
      shares[id] = 100 * math.max(0, (counts[id] or 0) * (flows[id][item] or 0)) / total
    else
      shares[id] = 100 / #ids
    end
  end
  return shares
end

return solver
