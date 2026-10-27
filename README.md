# Factory Block Balancer (factorio-planner)

A Factorio 2.1 mod for planning a base out of minifactories. Drag a capture tool over a
group of machines, and the mod turns them into a factory: one line per recipe and machine,
with rates read from the game (modules, beacons, research productivity). An exact solver
balances each factory and then the whole plan against fixed sinks (science demand,
generators), and shows how many copies of each factory you need and which belts will choke.
The plan lives in the save and is shared live in multiplayer.

Krastorio 2 is the main test case; any mod set should work.

## Install

Copy or link the `factorio-planner` folder into your Factorio `mods` folder:

```sh
ln -s "$PWD/factorio-planner" ~/Library/Application\ Support/factorio/mods/factorio-planner   # macOS
```

In game: **Ctrl+Alt+C** gives the capture tool, **Ctrl+Alt+P** opens the planner window
(both also on the shortcut bar).

## Tests

The solver, rate formulas, storage model and the whole GUI run offline in plain Lua
(written for Factorio's Lua 5.2, tested with newer Lua too):

```sh
cd factorio-planner && lua tests/run.lua
```

GUI tests drive `control.lua` through `tests/mock_runtime.lua`, a strict stand-in for the
game that rejects GUI parameters, styles, sprites and attribute writes the real 2.1 API
would reject. Its API data (`tests/fixtures/api.lua`) is generated from a local Factorio
install by `tests/tools/gen_api.py`.

## Design

See [`Factory Block Balancer — mod spec.md`](Factory%20Block%20Balancer%20—%20mod%20spec.md)
for the full spec.
