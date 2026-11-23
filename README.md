# Stoich

A Factorio 2.1 mod for planning a base out of **minifactories**: self-contained blocks
(a green circuit block, an oil block, a smelting column…) that you build several copies of.
Capture a block from the map, let the mod balance it exactly, and it tells you how many
copies of each block your goals need, which ones you're short of, and which belts will choke.

Everything happens in game: one plan window; the factory editor, statistics and a split
open in its place and give it back when closed. Every surface (Nauvis, Fulgora…) has its
own plan. Plans are stored in the save and shared live by every player in multiplayer. Krastorio 2 is the main test case; any mod set should work.

## What it does

- **Capture from the map.** Drag the capture tool over machines: assemblers, furnaces,
  rocket silos, mining drills, pumpjacks and offshore pumps become recipe lines with rates
  read from the game, including modules, beacons, productivity research and quality.
  Machines with no recipe are listed, left out of the balance.
- **Exact balancing.** Each factory is solved exactly from the lines you anchor. When
  several recipes make the same item (oil processing vs coal liquefaction), you set a
  **split** in percent; a captured build comes pre-filled with the split it was built with.
  Problems are named: "Hydrogen can't balance: nothing consumes it", with one-click fixes.
  When the whole plan can't balance, it says which items would close it and how much of
  each is left over or missing ("Ice: 42.5/min left over, or instead water or light oil"); a
  plan too big to work that out after every change gets a **Find a fix** button. A split
  that would make the plan bring things in is named, with **Remove split**.
- **Plan balance.** All factories are balanced together against **sinks**: fixed demands
  you type, such as "10 science/min" or "30 coal/min for boilers". The plan window lists
  every sink, split and factory with its recipe (what one copy takes in and sends out), how
  many copies you have of how many are **needed**, and what is still **to build**.
- **Voids and imports.** A **void** takes whatever the plan has left over of its items (a
  recycler loop, a flare stack); an **import** brings in whatever is missing (rockets from
  another planet). The balance sets their rates, and only to what the plan can't do
  without: the factories make what they can, no factory runs only to make something voided,
  and nothing is imported that a factory could make. A factory with several outputs says
  what it runs for (scrap recycling: for circuits; the holmium ore is left over).
- **One plan per surface.** The window opens on the plan of the surface you are on, or the
  one the map shows; the selector in its title bar switches to another. It lists every
  planet, and any other surface (a space platform, a modded factory floor) once something
  was captured there. Plans don't interact; what moves between planets is an import on one
  and a sink on the other. Saves from before 0.4 keep their plan on Nauvis.
- **Recipes without a build.** New recipe makes a factory of one recipe on a machine, with
  its modules and beacons (of any quality), worked out as the game does: a recycler for one
  item, say, picked by the item. **Copy from a machine** takes the modules and beacons of a
  machine on the map. Recipe quality **Every quality** makes one per unlocked quality at
  once (recyclers take whatever quality comes).
- **Quality** (Space Age). Each quality of an item is an item of its own: a rare recipe
  uses rare ingredients, and a machine's quality chance spreads its products over the
  qualities as the game rolls them (stopping at the highest your force has unlocked). Machine,
  module and beacon quality count, so recycler upcycling loops balance like any other build.
  A void or import row can stand for several qualities of its item (any, or at least, above,
  at most, below one), so one **Void** takes a loop's rare, epic and legendary byproducts in one
  row. Quality shows only in plans that have it (or after ticking Quality in a sink, void or
  import): one icon per item with its quality badge, or the "any quality" mark for several,
  that open to a row per quality in the editor and Statistics, and a quality filter there.
  Small rates read in m, µ and n (4.5m/s).
- **Research follows, when you say so.** Captured and hand-added lines keep what they were
  worked out from (machine speed, modules, quality chance). After research or a mod update
  the plan says which factories would change and the copies needed before and after;
  **Update all** takes the new numbers in. Lines captured before 0.5 stay as they are
  (rescan them to follow research).
- **Belts.** Every flow shows how full the slowest belt that carries it is, and that belt's
  icon; belts are read from your game (Krastorio 2's included). A factory whose one copy
  needs more than the best allowed belt is flagged. Fluids are never limited.
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
2. **Check the balance.** The status in the editor header must be **Balanced** to save
   (otherwise the reason shows above Save).
   - **Anchor** (checkbox next to a line's count) fixes that line's machine count; the
     solver scales the other lines to match. A capture anchors the main product line.
   - **Inputs / Outputs / Balanced inside** list the factory's items. Tick **External** on
     an item that crosses the factory boundary (ore coming in, a byproduct going out).
   - **Splits** appear when several recipes make the same item; drag the sliders.
   - **Solved** vs **Built** shows where the build is off (e.g. 5 assemblers built,
     4.3 needed).
   - Use **Add recipe** or **Add custom line** for things you didn't capture (imports,
     rocket launches, flare stacks), and the pencil on a line to override its flow. Add
     recipe picks a recipe by item (its recycling first) or directly, on a machine with
     its module slots and beacons; the dialog shows the resulting speed and productivity.
   - **New recipe** in the plan makes a factory of one such recipe without building
     anything: a recycler for copper cable, say. One copy is that many machines.
   - **Recapture area** hides the windows while you drag the new area (Q cancels).
3. **Save**, then set **Copies** (− / + in the plan) to how many of that block you have.
4. **Add sinks** (**New sink**) for what the plan must deliver: science per
   minute, fuel for boilers, items you ship elsewhere. Capturing only boilers or generators
   creates a sink with their fuel filled in. A sink's **Scale** (0 to 1) sets how much of
   its rates the plan delivers: 0.5 for half, 0 to keep it in the plan asking for nothing.
   Each plan has one **Void** and one **Import** (the toolbar buttons open them, made on
   first use): a list of items, no rates. A problem row adds to them in one click:
   **Void** for an item nothing uses, **Import** for one nothing makes, **Sink** for a surplus
   you want delivered.
5. **Read the plan.** Each factory shows its copies against the need (`2 of 3.05`) and
   what is still to build: a red `+1.1`, or a green ✓ when demand is covered. Factories are
   sorted by shortage when the plan opens or comes back from the editor, statistics or a
   split, and keep their place while you click − / +. Clicking an item opens it in
   Statistics. If two factories make the same item, the plan asks for a split; it shows as
   a row with each factory's share, and its pencil opens it. A new plan split **matches
   usage**: every factory in it runs at the same share of its built copies (two ore mines,
   say), so the shares follow copies, edits and new factories making the item; its row
   says "match". Untick it to set the shares by hand with the sliders. The plan is closed
   but for its voids and imports: everything else it uses must be made by one of its
   factories. **Statistics** shows every item's flow.

Esc or E closes the open window: the editor (asking first if there are unsaved changes),
statistics or a split go back to the plan, then the plan itself closes.

The title bar holds the surface selector, the settings button (rate unit, who can edit, the
highest belt to plan with, one-lane planning) and the edit log (the clock). The icons at
the end of the toolbar export the plan as a string, import one into the plan shown, and
clear the plan (after asking).

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

In the real game, `test-world/` builds test worlds, drives the GUI like a player, checks
rates against real machines and looks for desyncs, in a Factorio data folder of its own:
see [`test-world/README.md`](test-world/README.md).

GUI tests drive `control.lua` through `tests/mock_runtime.lua`, a strict stand-in for the
game that rejects GUI parameters, styles, sprites and attribute writes the real 2.1 API
would reject; a locale test checks every interface text key both ways. Its API data (`tests/fixtures/api.lua`) is generated from a local Factorio
install by `tests/tools/gen_api.py`.

## Release

Bump `version` in `stoich/info.json`, add its entry to `stoich/changelog.txt`, commit,
then run `./release.sh`. It stops on uncommitted changes, an existing tag or a missing
changelog entry, runs the tests, builds `dist/stoich_<version>.zip` from the committed
code (without `tests/`) and tags `v<version>`. Push the tag yourself.

## Limits

- **Not modelled:** spoilage, negative quality effects (a machine that allows them),
  burner fuel of crafting machines, electricity (generators become a sink of their fuel).
- **Captured from the map:** assemblers, furnaces, rocket silos, mining drills, pumpjacks
  and offshore pumps; generators make a sink. Agricultural towers and asteroid collectors
  aren't captured yet: add them as custom lines.
- **Rates** were checked against real machines running in the game (`test-world`): within
  0.25% for pumpjacks at any yield, drills, crafters with modules and up to eight beacons,
  and exact for recipes added by hand with modules and beacons. A drill over mixed ores
  mines one tile at a time, so its split between ores is a long-run average.
- **Plans per surface don't interact:** what one surface ships to another is a sink on
  one and an import on the other.
- **Can't balance:** what would close the plan is a linear program: the least voided (and,
  only when nothing else closes it, imported) per second with every factory running forwards
  and the sinks getting their rates. It minimises what is voided, not how many items are:
  it may list one more item than a person would. After each change it gets about half a second
  (in the game), alternatives included; a plan that needs more offers Find a fix, which lists them all.
- **Quality:** the qualities of an item share its belt (its belt check sums them). A chance
  above 100% is modelled as the game's tooltip shows it; rates of quality byproducts are
  long-run averages of random rolls.
- Mod windows can't be resized by dragging (a Factorio API limit).

## License

MIT, see [LICENSE](LICENSE).
