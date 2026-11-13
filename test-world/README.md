# In-game tests

The offline tests (`cd stoich && lua tests/run.lua`) cover the solver, storage and the whole
GUI against a strict mock of the game. This folder runs Stoich in the real game: it builds
test worlds, drives the GUI the way a player would, checks computed rates against real
machines, looks for multiplayer desyncs and takes screenshots of every screen.

Everything runs in an isolated Factorio data folder (`test-world/.game`) with its own
config, mods and saves. Your own profile, saves and mod settings are never touched; your
mods are only linked (never copied or changed). Each run closes the game it started.

## Requirements

- Factorio 2.1, bash and python3 (macOS or Linux).
- For the Krastorio 2 modes (`world`, `shots`, `desync`, `churn`, `rates k2`): these mods
  in your Factorio mods folder: Krastorio2, Krastorio2Assets, Krastorio2MenuSimulations
  (2.1.x), flib and ChangeInserterDropLane. Download them through the game once.
- For `features`: the Space Age expansion.
- Krastorio 2 and Space Age don't go together: each mode turns on its own mod set and
  every other mod in the folder off.

## Setup

`run_game.sh` finds the usual installs by itself (Steam or standalone, macOS or Linux). If
it says it can't find the game or your mods, copy `local.env.example` to `local.env` (not
committed) and set the paths:

```sh
cp local.env.example local.env
$EDITOR local.env   # FACTORIO_BIN, FACTORIO_MODS, FACTORIO_SAVES
```

The same variables can also be set in the environment.

## Modes

```sh
./run_game.sh world      # build the K2 test world once (stoich-test-k2.zip)
./run_game.sh shots      # GUI session on that world: screenshots/*.png
```

| Mode | What it does | Output |
|------|--------------|--------|
| `world` | Builds the test world from the `stoich-test` scenario (K2): labelled zones of factories on a lab surface, everything researched, saved once. Run it first, and again after changing the scenario. | `stoich-test-k2.zip` |
| `shots` | Loads that world with the `stoich-shots` driver: captures every zone, makes sinks, splits, the plan's import and void, a recipe factory, and opens every window and dialog. | `screenshots/*.png`, plan data in `.game/script-output/shots/` |
| `desync` | The `shots` session in heavy mode (the game saves, reloads and compares its state every tick). | `DESYNC CHECK: PASS` or `FAIL` |
| `churn` | Heavy mode while the `stoich-churn` driver keeps changing the world (recipes, modules, beacons, machines, research) and Stoich reads it (capture, rescan, save, delete). `churn --no-heavy` runs it at full speed. | `churn.txt` |
| `rates k2` / `rates vanilla` | Builds one machine per cell (`stoich-rates` scenario), captures each, runs them five game minutes and compares measured output with Stoich's rates (pass: within 1%). | `rates-k2.txt`, `rates-vanilla.txt` |
| `features` | Space Age (`stoich-features` scenario): plans per surface (a capture from Vulcanus's map), the recipe dialog with modules and beacons against real machines (must match exactly), voids, imports, splits. | `features.txt`, `screenshots/features/` |
| `dump "<save>"` | Loads a copy of one of your saves with your own enabled mods and writes every Stoich plan to JSON, then screenshots the plan window. For looking into a plan that misbehaves. | `dump-<save>.json`, `screenshots/dump/` |
| `play` | Loads the newest save of the test folder to play by hand (stays open). | |

`dump` output is your save's data: delete it when done. A failing step is logged in the
driver's log (`FAILED`, `NOT SAVED`); the game log is `.game/factorio-current.log`.

## How it works

- The game runs with `--config`, `--mod-directory` and `--load-game` pointing into
  `.game`; `.game/steam_appid.txt` keeps Steam from restarting it without them.
- Stoich itself is linked from `../stoich`, so a run always uses the working copy.
- The driver mods (`stoich-shots`, `stoich-churn`, `stoich-dump`) turn on Stoich's hidden
  startup setting `stoich-debug-interface`, which adds the `stoich-debug` remote
  interface: open a window, capture an area, operate a GUI element by its action tag
  (`act`), read the open draft or dialog. Scripts can't raise GUI events, so this is how a
  driver clicks. Normal installs don't have the interface.
- A driver is a list of steps run a few ticks apart (`step(function() ... end)`); add a
  step and a `shot("name")` to cover a new screen.
- The script waits for the driver's `done.txt`, then closes the game (SIGTERM, then
  SIGKILL). If a run hangs on a dialog, it times out the same way.
