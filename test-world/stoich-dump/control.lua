-- Writes every Stoich plan of the loaded save (factories with their results, splits,
-- the plan balance) to script-output/dump/plans.json, then screenshots the plan window
-- (problems collapsed and expanded) and writes done.txt. Test only.
local D = "stoich-debug"
local start

local function shot(name)
  game.take_screenshot({ player = 1, by_player = 1, path = "dump/" .. name .. ".png", show_gui = true, force_render = true })
end

local steps = {
  function()
    local out = {}
    for _, key in ipairs(remote.call(D, "plan_keys")) do
      out[key] = { result = remote.call("stoich", "plan_result", key), factories = remote.call(D, "factories", key),
        splits = remote.call(D, "splits", key) }
    end
    helpers.write_file("dump/plans.json", helpers.table_to_json(out))
  end,
  function()
    for _ = 1, 4 do
      if not remote.call(D, "act", 1, "child_close", {}) then break end
    end
    remote.call(D, "act", 1, "window_close", {})
    -- on Fulgora's map, when it has a plan: the window opens there
    if game.surfaces.fulgora then
      game.get_player(1).set_controller({ type = defines.controllers.remote, surface = "fulgora", position = { 0, 0 } })
    end
    remote.call(D, "open", 1)
  end,
  function() shot("plan") end,
  function() remote.call(D, "act", 1, "plan_all_problems", {}) end,
  function() shot("plan-all-problems") end,
  function() helpers.write_file("dump/done.txt", "done") end,
}

script.on_event(defines.events.on_tick, function(event)
  if not remote.interfaces[D] or not game.get_player(1) then return end
  start = start or event.tick
  local i = (event.tick - start) / 20 + 1
  if i == math.floor(i) and steps[i] then steps[i]() end
end)
