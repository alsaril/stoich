# Stoich

A Factorio 2.1 mod for planning a base out of **minifactories**: self-contained blocks
(a green circuit block, an oil block, a smelting column…) that you build several copies of.
Capture a block from the map, let the mod balance it exactly, and it tells you how many
copies of each block your goals need, which ones you're short of, and which belts will choke.

Everything happens in game: one plan window, with the factory editor, statistics and splits
opening over it. The plan is stored in the save and shared live
by every player in multiplayer. Krastorio 2 is the main test case; any mod set should work.

## What it does

- **Capture from the map.** Drag the capture tool over machines: assemblers, furnaces,
  rocket silos, mining drills, pumpjacks and offshore pumps become recipe lines with rates
  read from the game, including modules, beacons and productivity research (quality isn't
  modelled yet). Machines with no recipe are listed so you can assign one or drop them.
- **Exact balancing.** Each factory is solved exactly from the lines you anchor. When
  several recipes make the same item (oil processing vs coal liquefaction), you set a
  **split** in percent; a captured build comes pre-filled with the split it was built with.
  Problems are named: "Hydrogen can't balance: nothing consumes it", with one-click fixes.
- **Plan balance.** All factories are balanced together against **sinks**: fixed demands
  you type, such as "10 science/min" or "30 coal/min for boilers". The plan window lists
  every factory and sink with what one copy takes in and sends out, how many copies are
  **needed**, how many you have, and the **shortage**.
- **Belts.** Every flow shows the slowest belt that carries it and how full it is, read
  from the belts your game has (Krastorio 2's included). A factory whose one copy needs more
  than the best allowed belt is flagged. Fluids are never limited.
- **Statistics.** Every item in the plan with its total flow, belts needed for it, and
  which factories make and use it.
- **Multiplayer.** Everyone sees the same plan; edits are private drafts until saved; a
  stale save shows who changed the factory meanwhile; editing can be limited to admins;
  an edit log shows who did what.
- **Export / import** factories or the whole plan as a string, to move them between saves.

## How to use it

**Ctrl+Alt+C** gives the capture tool and **Ctrl+Alt+P** opens the window (both are also
on the shortcut bar).

1. **Capture a factory.** Drag the capture tool over one copy of a block. The editor opens
   in its own window with one line per recipe and machine, named after its main product.
   Closing it with unsaved changes asks first.
2. **Check the balance.** The status in the editor header must be **EXACT** to save.
   - **Anchor** (checkbox next to a line's count) fixes that line's machine count; the
     solver scales the other lines to match. A capture anchors the main product line.
   - **Inputs / Outputs / Balanced inside** list the factory's items. Tick **External** on
     an item that crosses the factory boundary (ore coming in, a byproduct going out).
   - **Splits** appear when several recipes make the same item; drag the sliders.
   - **Solved** vs **Built** shows where the build is off (e.g. 5 assemblers built,
     4.3 needed).
   - Use **Add recipe** or **Add custom line** for things you didn't capture (imports,
     rocket launches, flare stacks), and the pencil on a line to override its flow.
3. **Save**, then set **Copies** (− / + in the plan) to how many of that block you have.
4. **Add sinks** (**New sink**) for what the plan must deliver: science per
   minute, fuel for boilers, items you ship elsewhere. Capturing only boilers or generators
   creates a sink with their fuel filled in.
5. **Read the plan.** Factories are sorted by shortage: red means build more, green
   means demand is covered. If two factories make the same item, the plan asks for a split;
   it shows as a row with each factory's share, and its pencil opens the sliders. The plan
   is closed: everything it uses must be made by one of its factories, and a surplus can go
   to a sink with one click. **Statistics** shows every item's flow.

The settings button in the window title bar holds the rate unit (/s, /min, /h), who can
edit, the highest belt to plan with, and one-lane planning. Next to it, the clock button
opens the edit log and the grid button switches between a plan window that fills most of
the screen and a compact one.

## Install

Copy or link the `stoich` folder into your Factorio `mods` folder, e.g. on macOS:

```sh
ln -s "$PWD/stoich" ~/Library/Application\ Support/factorio/mods/stoich
```

Requires Factorio 2.1. Space Age and Krastorio 2 are optional.

## Tests

The solver, rate formulas, storage model and the whole GUI run offline in plain Lua
(written for Factorio's Lua 5.2, tested with newer Lua too):

```sh
cd stoich && lua tests/run.lua
```

GUI tests drive `control.lua` through `tests/mock_runtime.lua`, a strict stand-in for the
game that rejects GUI parameters, styles, sprites and attribute writes the real 2.1 API
would reject. Its API data (`tests/fixtures/api.lua`) is generated from a local Factorio
install by `tests/tools/gen_api.py`.

## Release

Bump `version` in `stoich/info.json`, add its entry to `stoich/changelog.txt`, commit,
then run `./release.sh`. It stops on uncommitted changes, an existing tag or a missing
changelog entry, runs the tests, builds `dist/stoich_<version>.zip` from the committed
code (without `tests/`) and tags `v<version>`. Push the tag yourself.

## Design

See [`Stoich — mod spec.md`](Stoich%20—%20mod%20spec.md)
for the original spec. Changes made while building it: the old Kotlin JSON importer was
dropped, there are no tabs (the plan window lists factories, sinks and splits; the
editor, statistics and splits open in their own windows), and shortage is shown as copies
still to build (never below 0).

## License

MIT, see [LICENSE](LICENSE).
