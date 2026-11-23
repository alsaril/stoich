-- A session on a plan without quality, as text: every GUI element's type, name, caption,
-- sprite, quality and action. tests/fixtures/no_quality_snapshot.txt is this session
-- recorded on Stoich 0.4 (before quality); gui_test.lua checks it is still the same.
-- Since then: the recipe dialog's Copy from a machine button, the toolbar's Clear plan
-- button, and flow tooltips as one text (the same lines, no longer cut at 16; in the plan,
-- in the order of the row's icons): not quality
-- changes.
-- Uses only what the 0.4 mock had, so it runs on both.

return function(mock)
  local function flat(v)
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    for i = 1, #v do parts[#parts + 1] = flat(v[i]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  local function snap(root)
    local out = {}
    local function walk(e, depth)
      local tags = e.tags or {}
      local q = e.type == "sprite-button" and e.quality or nil
      out[#out + 1] = string.rep(" ", depth) .. e.type .. (e.name ~= "" and e.name and (" #" .. e.name) or "")
        .. (e.caption and e.caption ~= "" and (" '" .. flat(e.caption) .. "'") or "")
        .. ((e.type == "sprite" or e.type == "sprite-button") and (" [" .. tostring(e.sprite) .. "]") or "")
        .. (q and (" q=" .. tostring(q.name or q)) or "")
        .. (tags.fp and (" <" .. tags.fp .. ">") or "")
        .. (e.type == "label" and e.tooltip and (" ~" .. flat(e.tooltip)) or "")
      for _, c in ipairs(e.children) do walk(c, depth + 1) end
    end
    for _, c in ipairs(root.children) do walk(c, 0) end
    return table.concat(out, "\n")
  end
  local TOOL = "stoich-selection-tool"
  mock.reset()
  require("control")
  mock.init.on_init()
  local p = mock.new_player(1, { admin = true })
  mock.fire("on_player_joined_game", { player_index = 1 })
  local shots = {}
  local list, x = {}, 0
  local function add(n, type, name, recipe)
    for _ = 1, n do
      list[#list + 1] = mock.crafter(type, name, recipe, x, 0)
      x = x + 1
    end
  end
  add(6, "assembling-machine", "oil-refinery", "advanced-oil-processing")
  add(2, "assembling-machine", "oil-refinery", "coal-liquefaction")
  add(3, "assembling-machine", "chemical-plant", "heavy-oil-cracking")
  add(7, "assembling-machine", "chemical-plant", "light-oil-cracking")
  add(8, "assembling-machine", "chemical-plant", "plastic-bar")
  local area = { left_top = { x = -1, y = -1 }, right_bottom = { x = 100, y = 10 } }
  mock.fire("on_player_selected_area", { player_index = 1, item = TOOL, entities = list, area = area, surface = mock.surface })
  shots[#shots + 1] = "== editor\n" .. snap(p.gui.screen)
  mock.click(p, mock.named(p.gui.screen, "stoich_save"))
  if not p.gui.screen.stoich_window then mock.fire("on_lua_shortcut", { player_index = 1, prototype_name = "stoich-toggle-window" }) end
  shots[#shots + 1] = "== plan\n" .. snap(p.gui.screen)
  mock.click(p, mock.find(p.gui.screen, "open_stats"))
  for _, e in ipairs(mock.find_all(p.gui.screen, "items_toggle")) do
    if e.valid then mock.click(p, e) break end
  end
  shots[#shots + 1] = "== statistics\n" .. snap(p.gui.screen)
  mock.press_esc(p)
  mock.click(p, mock.find(p.gui.screen, "fac_new_sink"))
  shots[#shots + 1] = "== sink\n" .. snap(p.gui.screen)
  mock.click(p, mock.find(p.gui.screen, "editor_cancel"))
  mock.click(p, mock.find(p.gui.screen, "fac_new_recipe"))
  mock.pick(p, mock.find(p.gui.screen, "dlg_item"), "copper-cable")
  shots[#shots + 1] = "== recipe dialog\n" .. snap(p.gui.screen)
  return table.concat(shots, "\n\n") .. "\n"
end
