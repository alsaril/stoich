# Stoich — mod spec

## Goal and scope

Build `stoich`, a Factorio 2.1+ mod that does what levels 1 and 2 of the existing Kotlin calculator (attached `calculator.zip`) did, entirely in-game. Factories are captured from the map instead of typed as JSON. The plan lives in the save and is shared by every player.

**In scope (v1)**

- Factory balance (old level 1): define a factory, balance its recipes against anchors and splits with an exact solver, save its net input/output.
- Plan balance (old level 2): balance all saved factories against sinks, show shortage per factory (needed minus copies).
- Belt limits: show which belt tier each item flow needs and warn when one copy would choke. Fluids are never limited.
- Sinks: factories that only consume at fixed rates, typed by the user. They model science demand ("10 green science/min") and generators.
- Capturing a factory by dragging a selection tool over machines on the map and giving it a name.
- A GUI for everything: no JSON, no console commands needed for normal use.
- Persistence in the save, shared live between all players in multiplayer.
- Works with any mod set; Krastorio 2 is the main test case.

**Deferred (keep hooks, don't build)**

- Level 3: groups with their own multiplier (keep a `group` field on factories, unused).
- Quality, and burner fuel use of crafting machines.
- An LP solver that chooses splits by itself (e.g. least ore used). v1 uses splits set by the user.

**Out of scope**

- Calculating electricity. Generators are modelled as sinks of their fuel.
- Reading lab speed or current research. Science demand is a fixed sink.
- Placing blueprints, building anything automatically.
- Live tracking that changes on its own each tick. All solving happens on user actions.

## Concepts

Names follow your own words and the Kotlin code where possible. All of them are user-facing and can still change.

| Term | Meaning | Kotlin equivalent |
| --- | --- | --- |
| Factory | A named minifactory, balanced on its own and saved as one net flow | `Factory` |
| Recipe | One line inside a factory: a recipe run by one kind of machine, or a mining, pump or custom line. It has a flow per machine and a machine count | entry of `Factory.recipes` |
| Sink | A factory that only consumes, at rates the user types (science demand, generators burning fuel). Always anchored in the plan | the old `lab` factory with `final` |
| Plan | All factories of a save, balanced together | the state file |
| Flow | Item → rate per second for one unit; inputs negative, outputs positive | `Map<String, Double>` |
| Item key | `item/<name>`, `fluid/<name>`, or `custom/<text>` for things that are not prototypes (e.g. `custom/space-data`) | plain string |
| Anchor | A recipe whose machine count the user fixes; the solver scales the rest | `Factory.anchors` |
| Split | For an item made by several parallel recipes (e.g. heavy oil from oil processing and coal liquefaction): the % each recipe makes, summing to 100. Scales with demand, unlike an anchor | none (new) |
| External | An item allowed to cross the factory boundary; all other items must net to zero inside | `Factory.external` |
| Net flow | The factory's balanced input/output; this is what the plan uses | `BalancedFactory.summary` |
| Copies | How many copies of the factory exist in the world | `Factory.multiplier` |
| Pinned | A normal factory whose copy count is also an anchor in the plan (rarely needed now that sinks exist) | `Factory.final` |
| Needed | How many copies the plan balance says you need | `balanced.recipes[k].multiplier` |
| Shortage | Needed − copies; positive means build more | `BalanceResult.shortage` |
| Status | `EXACT`, `NEEDS_SPLIT` (a free choice is left), `CONFLICT` (an item can't balance), `NEGATIVE` (a count below zero) | `SolutionType` + `Inconsistency` |
| Belt tier | The slowest belt that can carry an item flow; fluids have none | colour classes in the old UI |

&#91;embedded content: how the parts fit · capture to shortage view\]

A factory is captured and balanced once in the editor; every save re-runs the plan balance, and all players' open windows refresh.

## Feature parity

Every feature of the Kotlin tool that was used stays; the server, tokens and JSON editing are replaced by the game itself.

| Kotlin tool | Mod v1 |
| --- | --- |
| Factory = recipes as flow maps, anchors, external items (typed JSON) | Same model, filled by map selection and item pickers, plus splits |
| `POST /factory/check`: balance without saving | Live balance in the factory editor on every change |
| Save only if solution is `EXACT` | Same rule; Save is disabled with the reason shown |
| SVD least squares; `FREE` / `APPROXIMATE` with warnings | Exact solver (Gaussian elimination); `NEEDS_SPLIT` / `CONFLICT` name what to fix |
| `recalculateAnchors` when inconsistent | Dropped: a conflict is shown, not rescaled |
| Inconsistencies `INPUT`, `OUTPUT`, `WEIGHT` | Conflicting items named; `WEIGHT` dropped; `NEGATIVE` added |
| Parallel recipes (oil processing vs coal liquefaction) left unresolved | Split prompt with % per recipe, pre-filled from the scanned build |
| Final factories anchored by their multiplier (the lab factory) | Sinks with typed rates; any factory can still be pinned |
| Shortage = needed − built, sorted descending | Plan tab table, same sort |
| Flow view: per item, producers/consumers with %, virtual input/output | Items tab, same data |
| Belt colours on flows (yellow 15, red 30, blue 45, green 60, violet 90 items/s) | Belt tiers read from the game; fluids never coloured or limited (fixes the old item/fluid mix-up) |
| `GET /products` | Item list in Items tab |
| Token → separate state file | Plans per save (optional, see Data model) |
| `X-Version` conflict check | Per-factory revision check on save |
| Remove factory | Delete factory (with confirmation) |
| Groups (`/group`, multiplier) | Deferred, `group` field kept |
| Rounding to 2 decimals | Display only; storage keeps full precision |

## Capturing factories from the map

A player drags a selection tool over a group of machines, and the mod opens the factory editor prefilled with one recipe line per recipe and machine type, named after the main product.

**Selection tool**

- A `selection-tool` item, given by a shortcut-bar button or a hotkey (no crafting needed).
- One action only: drag to capture a new factory. Factorio requires an alt-select definition in the prototype; make it do the same thing.
- Copies are counted with +/− buttons in the GUI, not by selecting each copy.
- Filter to entity types: `assembling-machine`, `furnace`, `rocket-silo`, `mining-drill`, `offshore-pump`. Ignore everything else (belts, inserters, beacons, poles, labs).
- Remember the selected area and surface on the factory, so "Show on map" can highlight it and "Rescan" can recount it without the tool.

**Grouping into recipe lines**

- Group entities by (kind, recipe or resource, machine prototype). Different module or beacon setups in one group are summed: the line's flow per machine is the average of its entities, and its count is the number of entities.
- Entities with no recipe set (idle furnaces, empty assemblers) are listed as a warning line the user can assign a recipe to or drop.
- Default name = localised name of the product with the largest positive net flow; default icon = that product.

**Rate per entity (per second)**

All formulas must be checked against the 2.1 Lua API docs; field names flagged *verify* are the ones most likely to be off.

| Entity | Crafts or cycles per second | Flow |
| --- | --- | --- |
| Assembler, furnace, rocket silo | `entity.crafting_speed / recipe.energy` (crafting\_speed already includes modules and beacons) | ingredients × rate; products × rate × expected amount, with productivity on the part not `ignored_by_productivity` |
| Mining drill, solid resource | `mining_speed × (1 + productivity) / mineable_properties.mining_time` | resource products × rate; required fluid × rate × `fluid_amount / 10` (*verify*) |
| Pumpjack-style drill on fluid resource | same, × `resource.amount / resource_prototype.normal_resource_amount` (*verify*) | fluid product × rate |
| Offshore pump | `pumping_speed × 60` (per tick to per second, *verify*), fluid from the tile | fluid output only |

- Expected product amount = `amount`, or `(amount_min + amount_max) / 2`, times `probability`, plus `extra_count_fraction` if present.
- Productivity = entity productivity bonus (modules, beacons, machine base effect) + the force's recipe productivity for that recipe, or `force.mining_drill_productivity_bonus` for drills. Cap at the game's maximum. Check whether `entity.productivity_bonus` already includes the research part so it is not counted twice.
- Burner fuel of crafting machines and electricity are not calculated.

**Sinks**

- A sink is a factory with no recipes: a list of (item picker or custom text, rate) typed by the user. Rates are entered per minute by default.
- Science demand: e.g. "Science" sink with 10 automation science/min. Lab speed and current research are never read, so research bonuses don't change the plan.
- Generators: e.g. "Boilers" sink with 30 coal/min, or "Reactors" with fuel cells. Electricity itself is not modelled.
- Optional shortcut: if a selection contains only generators, boilers or reactors, offer "Make a sink" with their fuel items prefilled and the rates left for the user to type.
- Sinks are always anchored in the plan at their typed rates and have no copies counter.

**Manual and custom lines**

- "Add recipe": recipe picker + machine picker + count; flow computed from prototypes at the machine's base speed, with optional speed and productivity % fields.
- "Add custom line": a name plus a list of (item picker or custom text, amount per second). This covers what isn't a machine: rocket launches giving space science, flare stacks, imports from another planet.
- Every line's flow is editable by hand as an override; overridden lines show a marker and are not changed by Rescan.

## Solver

An exact solver replaces the old SVD least squares. A factory is only valid when its equations have exactly one solution. When they don't, the solver says what is missing (a split) or what is too much (an item that can't balance), and the GUI asks the user to fix it. One function, `balance(lines, anchors, splits, external)`, serves both the factory and the plan balance.

**Equations**

Unknowns are the machine counts `m` of the free (unanchored) lines. Every row below is linear in `m`:

1. **Balance**, one per item not marked external: the sum over lines of `m × flow(item)` = 0. Anchored lines are fixed numbers and move to the right-hand side.
2. **Split**, for an item made by k recipes with user shares `s` (in %, summing to 100): for k − 1 of them, `m_r × p_r(item) − s_r/100 × Σ m_j × p_j(item)` = 0, where `p` is that recipe's production of the item.
3. **Anchors** are fixed counts; they are substituted, not added as rows.

Sort item keys, line ids and splits before building the matrix, so the order is always the same.

**Elimination**

- Reduce `[A | b]` to reduced row echelon form with partial pivoting. Treat a pivot as zero below `1e-9 ×` the largest entry in its column.
- Carry an identity block next to it, so every reduced row knows which original equations it came from. This is how problems get named.
- About 50 lines of pure Lua using only arithmetic, so it is deterministic and runs outside the game for tests.

**Results**

| Status | Detected by | What the GUI says |
| --- | --- | --- |
| `EXACT` | rank = number of unknowns, no inconsistent row, all counts ≥ 0 | nothing; Save is enabled |
| `NEEDS_SPLIT` | rank < number of unknowns | "Heavy oil comes from 2 recipes. Choose a split" (one prompt per free choice) |
| `CONFLICT` | a row reduces to 0 = non-zero | "Hydrogen can't balance: nothing consumes it", naming the items from that row's origin, with one-click Mark external / Add sink |
| `NEGATIVE` | a solved count < −1e-6 | "Splits or anchors give a negative count for \<recipe>" |

- **Finding the split to ask for:** for each free column, set it to 1 and the others to 0, and back-solve. The lines with non-zero values form a parallel group (e.g. oil processing + coal liquefaction). Suggest an item that two or more recipes in the group produce, preferring one that is external or an output of the factory. The user can switch to another shared item in a dropdown, which gives the same ratio.
- If a group shares no product (rare, e.g. a loop with no anchor), suggest an anchor instead.
- Old statuses map as: `FREE` → `NEEDS_SPLIT`, `APPROXIMATE` → `CONFLICT`. `recalculateAnchors` and the `WEIGHT` inconsistency are dropped.

**Factory balance**

- Lines = the factory's recipe lines; external = items the user ticks. The editor suggests externals: items with no producer or no consumer inside the factory.
- A factory needs at least one anchor. Default: the line making the main product, fixed at its scanned count.
- When a capture contains parallel recipes, the editor pre-fills the split from the scanned machines (e.g. 6 refineries and 2 liquefaction plants give their current shares of heavy oil), so a captured build is `EXACT` right away and the user only adjusts the numbers.
- The editor shows scanned count, solved count and the difference per line, so an unbalanced build is visible (e.g. 5 gear assemblers built, 4.3 needed).
- Save is allowed only for `EXACT`; the saved net flow is the balanced one.

**Plan balance**

- Lines = each factory's net flow, and each sink's typed consumption.
- Anchors = every sink at 1, plus pinned factories at their copy count.
- Splits work the same way between factories, e.g. two green circuit designs feeding one plan.
- External = a plan-wide list, empty by default. Every surplus item must be external or go to a sink, since the exact solver has no tolerance for leftovers; `CONFLICT` offers both as one click.
- Needed = solved count per factory. Shortage = needed − copies, sorted from largest to smallest.

**Units and cost**

- Store rates per second; display per minute by default (setting: /s, /min, /h).
- Balance only on user actions, never in `on_tick`. Around 50 factories × 60 items solves in milliseconds.

**Flow view**

- Kept from Kotlin: per item, components (line, amount, amount / max(produced, consumed)), plus a virtual `input` or `output` component for the net, sorted as in `FlowComponent.compareTo`.

**Porting the Kotlin tests**

- `should solve exact system`: unchanged.
- `should solve underdetermined system`: now expects `NEEDS_SPLIT` with the group {a3, a3'}; with a 50/50 split on a3 it expects the old numbers (0.5 / 0.5).
- `should solve overdetermined system`: now expects `CONFLICT` naming item a1 (consumed, never produced); marking a1 external makes it `EXACT`.

## Belt limits

Every item flow shows the belt tier it needs, in that belt's colour, as the old UI did. A flow that no allowed belt can carry is flagged, because that factory will choke. Fluids are never limited.

**Belt tiers**

- Read all `transport-belt` prototypes at runtime, so Krastorio 2's extra belts appear on their own. The old tool hardcoded yellow 15, red 30, blue 45, green 60 and violet 90 items/s; use these as the expected K2 test values.
- Capacity of a full belt = belt speed × 480 items/s (*verify*), times the belt stack size where stacking is researched (Space Age, *verify*).
- Colour per tier from the belt's own map colour or a fixed table, close to the old CSS (yellow, red, blue, green, violet backgrounds).
- Setting: the highest belt tier you plan with (default: the best one researched). An optional toggle checks one lane (half capacity) instead of a full belt.

**Where it is shown**

- Factory editor: each external input and output of one copy, and each recipe line's output, gets the tier it needs. If it exceeds the highest allowed tier, show "2.3 × blue" in red with a tooltip: split the factory or add belts.
- Plan tab: a "chokes" warning icon on any factory where an external item flow of one copy exceeds the highest allowed tier.
- Items tab: per item, the total flow and each producer/consumer amount (per copy and in total) get a tier colour, like the old flow table.

**Fluids vs items**

- Item or fluid is decided by the prototype type in the item key (`item/` vs `fluid/`), never guessed from the name.
- Fluids get a pipe icon, no colour and no warning, whatever the rate.
- Custom keys (`custom/...`) default to item, with a fluid toggle in the custom-line editor.
- This fixes the old tool's problem where fluid flows were coloured and limited like belts.

## Data model and persistence

All shared state lives in the `storage` table, so it is saved with the game and identical for every player. Nothing is kept in plain Lua locals between events.

```lua
storage = {
  schema = 1,                      -- bump + migrate on change
  next_id = 1,
  plans = {                        -- optional; v1 may ship with only "main"
    main = {
      factories = { [id] = Factory },
      external = { [item_key] = true },
      splits = { Split },          -- between factories making the same item
      result = nil,                -- cached plan balance, rebuilt on change
    },
  },
  settings = { edit = "everyone", max_belt = name?, one_lane = false },
  log = {},                        -- last 50 edits: {tick, player, action, factory}
  players = { [player_index] = { open_tab, editor_draft, window_location } },
}

Factory = {
  id, name, icon = {type, name},
  kind = "factory" | "sink",
  lines = { Line },                -- for a sink: one custom line of negative rates
  anchors = { [line_id] = number },
  splits = { Split },
  external = { [item_key] = true },
  copies = 1, pinned = false,
  group = nil,                     -- reserved for level 3
  result = { status, counts, net, flow, problems },
  source = { surface_index, areas = { {left_top, right_bottom} } },
  revision = 1, modified_by = player_index, modified_tick = tick,
}

Split = {
  item = item_key,                 -- the item the shares refer to
  shares = { [line_id] = percent },-- sums to 100; 0 allowed (recipe unused)
}

Line = {
  id, kind = "recipe" | "mining" | "pump" | "custom",
  recipe = name?, machine = name?, resource = name?, label = string?,
  count = number,                  -- scanned or typed
  flow = { [item_key] = per_second_per_unit },
  fluid_keys = { [custom_key] = true },  -- custom keys marked as fluid
  overridden = false,
}
```

- A split whose lines were deleted, or whose item no longer comes from two or more of its lines, is dropped and the user is prompted again.

* Keep full precision in storage; round only for display.
* Store no `LuaEntity` or GUI references in shared data; store names, positions and areas.
* `on_init` creates the structure. `on_configuration_changed` re-validates every line: if a recipe, item or machine no longer exists, mark the line and factory invalid and keep the data. Never delete it silently.
* Migrations go in `migrations/` or in a `schema` check in `on_configuration_changed`.
* Export / import: a factory or the whole plan to a string with `helpers.table_to_json` + `helpers.encode_string`, and back, for moving plans between saves.
* Optional importer for the old Kotlin `state/def` JSON: paste into a text box, map each factory's `summary` to a factory with `custom/` item keys, and the old `lab` factory to a sink. Let the user pick the unit the old numbers used, and mark which custom keys are fluids.

## Multiplayer

Factorio runs mod code on every client in lockstep, so shared state comes for free; the work is keeping the code deterministic and the GUIs in sync.

**Sharing and editing**

- Everyone sees the same plan. Editing is allowed for everyone or admins only (runtime-global setting, changeable by admins in the GUI).
- Each player's editor works on a draft in `storage.players[i].editor_draft`. Other players don't see it until Save.
- Stale edit check (replaces `X-Version`): a draft remembers the factory's revision when opened. On Save, if the revision changed, show "Edited by \<player> \<time> ago" with Overwrite, Reload and Cancel.
- After any change to factories, sinks, copies or pinned flags: run the plan balance once, then refresh the open windows of all players who have them open.
- Copy count changes (+/−) apply at once with no draft, since they are small and frequent.
- Edit log: last 50 actions (who, what, when), shown in a small panel. It helps when several people change the plan.

**Determinism rules for the code**

- No `math.random`, no `os`/`io`, nothing that depends on one player's machine, except the GUI for that player.
- Never write to `storage` in `on_load`. Rebuild only local caches there (or rebuild them lazily).
- Iterate in sorted order wherever results feed the solver or the display order.
- Check `.valid` on every `LuaEntity` and GUI element before use; players join, leave and mine entities at any time.
- GUI elements are per player: create them under `player.gui.screen` and key their state by `player_index`.
- Handle `on_player_joined_game` (build button, restore window) and `on_player_removed` (drop that player's draft).
- Test with `/toggle-heavy-mode`: it runs desync checks in single player and catches most mistakes before a real multiplayer test.

## GUI

One draggable window with three tabs, opened from a shortcut-bar button or hotkey. The Plan tab is the home screen: it answers "what do I build next" at a glance.

**Plan tab (shortage stats)**

- Header: status badge (`EXACT` green, `NEEDS_SPLIT` yellow, `CONFLICT` and `NEGATIVE` red) with a one-line reason, the rate unit switch, and a Recalculate button.
- Main table, one row per factory, sorted by shortage (largest first), with columns: icon, name, copies (with − / + buttons), needed, shortage, a bar of copies / needed, a "chokes" icon from the belt check, pin toggle, and buttons for Edit, Show on map and Delete.
- Shortage colour: red when > 0.05, green within ±0.05, grey when overbuilt.
- Sinks are listed in their own small section above the table, with their rates editable in place.
- Plan splits (two factories making the same item) appear as a small section with the same % controls as the editor.
- Filter box (name or item) and a toggle to hide factories within tolerance.
- Below the table: the problems list (split prompts and conflicting items, with Mark external / Add sink buttons). Clicking an item opens the Items tab on it.

**Factories tab**

- List of factories and sinks with icon, name, number of recipe lines, net outputs and modified-by. Buttons: New factory, New sink, Capture (gives the selection tool), Duplicate, Export, Import.
- The factory editor opens over this tab:
  - Name text field, icon picker (`choose-elem-button`), copies, pinned checkbox.
  - Recipe lines table: recipe or resource icon, machine icon, scanned count, anchor checkbox + value, solved count, difference, flow per machine on hover, override marker. Per line: edit flow, delete.
  - Splits panel, one card per split: the item icon with a dropdown to switch to another shared item, then one row per recipe with its icon, a slider and a number field in %. The last recipe's share is shown as 100% minus the rest, so the total is always 100. Pre-filled from the scanned build; a `NEEDS_SPLIT` prompt adds a new card with the suggested item.
  - Items table: item icon, net flow after balancing with its belt-tier colour (pipe icon for fluids), and an external checkbox (suggested ones pre-ticked and marked).
  - Problems line: the status badge and, for `CONFLICT`, the items involved with Mark external / Add sink buttons.
  - Actions: Add recipe, Add custom line, Rescan area, Show on map, Save, Cancel. Save is disabled with the reason unless the status is `EXACT`.
  - The balance runs live on every edit, sliders included; it is fast enough to need no delay.
- The sink editor is a name, an icon and a list of (item, rate) rows.

**Items tab (flow view)**

- Every item with total flow, sorted by flow (as in `renderFlow`). Expand one to see each producing and consuming factory with amount, percent bar and belt-tier colour, plus the virtual input/output line.
- Click a factory in the list to open it in the editor.

**General**

- Use item and fluid sprites everywhere (`item/<name>`, `fluid/<name>`), and localised names in tooltips.
- Numbers: 2 decimals for counts, rates with k/M suffix.
- Remember window position and the open tab per player.
- `flib` (Factorio Library) may be used for GUI helpers; plain `LuaGuiElement` is also fine.

## Mod structure and API notes

Mod name: `stoich`. Target Factorio 2.1 and later (`"factorio_version": "2.1"`, dependency `base >= 2.1`), with Space Age and Krastorio 2 as optional test mods. If it will be published, check the name is free on the mod portal first.

```
stoich/
  info.json
  data.lua              -- selection tool, shortcut, custom-input hotkey, GUI styles
  settings.lua          -- rate unit, edit permission, max belt tier, one-lane toggle
  control.lua           -- event wiring only
  scripts/
    linalg.lua          -- Gaussian elimination to RREF, row origins (pure Lua)
    solver.lua          -- balance(): equations, statuses, split suggestions (pure Lua)
    belts.lua           -- belt tiers from prototypes, tier lookup per flow
    scanner.lua         -- entities -> recipe lines, rate formulas
    model.lua           -- storage access, revisions, log, migrations
    plan.lua            -- plan balance, shortage, refresh of all GUIs
    exchange.lua        -- export/import strings, old JSON importer
    gui/
      window.lua  plan.lua  factories.lua  editor.lua  sink.lua  items.lua
  locale/en/locale.cfg
  migrations/
  tests/                -- plain Lua 5.2, run outside the game
    run.lua  solver_test.lua  linalg_test.lua  belts_test.lua  fixtures/
```

**API points to verify in the 2.1 docs before relying on them**

- Global names: `storage`, `prototypes`, `helpers` (JSON and string encoding).
- Selection tool prototype: `select` and `alt_select` tables with `mode` and `entity_type_filters`. Events: `on_player_selected_area` and `on_player_alt_selected_area`, with `event.entities`, `event.area`, `event.surface`.
- `LuaEntity.get_recipe()` (returns recipe and quality) and how to read an idle furnace's last recipe (`previous_recipe`).
- `LuaEntity.crafting_speed` and `productivity_bonus`: what each includes (modules, beacons, base effect, research).
- Recipe productivity from research: `LuaForce.recipes[name].productivity_bonus`.
- `LuaRecipePrototype.products` fields: `amount`, `amount_min`, `amount_max`, `probability`, `ignored_by_productivity`, `extra_count_fraction`.
- Mining: `mining_target`, `prototype.mining_speed`, `mineable_properties` (`mining_time`, `products`, `required_fluid`, `fluid_amount`), `normal_resource_amount` for fluid resources.
- Offshore pump: `pumping_speed` units, and how the fluid is chosen by tile.
- Belts: transport-belt prototype `speed` and its conversion to items/s; belt stacking size from research (Space Age).
- Generators for the optional "Make a sink" shortcut: how to read the fuel item or fluid of boilers, burner generators and reactors.
- Krastorio 2: check its machines (e.g. its fluid extraction) map to the five entity types above, or add them to the filter.

## Milestones and tests

Build in this order. Each milestone ends in something that runs, and the solver is proven outside the game before any GUI exists.

1. **Solver offline.** `linalg.lua`, `solver.lua` and `belts.lua` with the three tests ported (as described under Solver) from `FactoryLogicTest.kt`, the plan fixture below and belt-tier tests, all passing in plain Lua 5.2.
2. **Capture.** Selection tool, `scanner.lua`, `model.lua`. A debug command prints the recipe lines of a selection. Check rates by hand against the in-game machine tooltips for a K2 assembler with modules, a furnace, a drill and a pumpjack.
3. **Factory and sink editors.** Create, edit, balance live, save (`EXACT` only), delete, rescan, belt colours on flows.
4. **Plan and Items tabs.** Plan balance, shortage table, chokes warnings, inconsistencies, flow view, show on map.
5. **Multiplayer polish.** Permissions, revision check, edit log, refresh of all open GUIs, export/import, optional old-JSON importer.
6. **Later.** Level 3 groups, quality, an LP solver that picks splits by itself, a machine-level view counting every machine on the map by recipe.

**Plan fixture from the old save**

Load `state/def` from the zip, treat each factory's `summary` as a line and the old `lab` factory (final, multiplier 1) as a sink anchored at 1. The result is `EXACT` (42 factories: 41 free plus the lab sink; 41 items; full rank). Expected needed counts, ±0.01:

| Factory | Needed | Copies | Shortage |
| --- | --- | --- | --- |
| green circuits | 14.05 | 4 | +10.05 |
| lds | 7.50 | 1 | +6.50 |
| light oil cracking | 6.51 | 1 | +5.51 |
| oil refinery | 5.54 | 1 | +4.54 |
| heavy oil cracking | 5.05 | 1 | +4.05 |
| imersite crystal | 5.04 | 1 | +4.04 |
| electronic components | 6.15 | 3 | +3.15 |
| production card | 0.95 | 1 | −0.05 |
| uranium processing | 0.23 | 1 | −0.77 |

**Acceptance criteria**

- [ ] All solver and belt tests pass offline, including the fixture.
- [ ] A K2 green circuit build can be captured, named and saved in under a minute with no typing beyond the name.
- [ ] Captured rates match in-game tooltips within 1%.
- [ ] With K2 loaded, belt tiers show 15 / 30 / 45 / 60 / 90 items/s, and a factory exporting more than the allowed tier is flagged.
- [ ] Fluid flows of any size are never coloured or flagged.
- [ ] A "10 green science/min" sink and a "30 coal/min" boiler sink drive the plan, and changing research does not change it.
- [ ] Save, quit and reload keep every factory, sink, copy count and setting.
- [ ] Two players on a local server: one edits a factory, the other sees the Plan tab update without reopening it; a stale save shows the conflict dialog.
- [ ] Admins-only mode stops non-admins from editing but not from viewing.
- [ ] No desync in an hour of `/toggle-heavy-mode` with frequent edits.
- [ ] Removing a mod that a factory uses marks the factory invalid and keeps its data.

* [ ] A K2 oil setup with oil processing and coal liquefaction, captured from the map, is `EXACT` at once with pre-filled splits; moving a split slider updates the solved counts and the plan.
* [ ] A byproduct with no consumer shows `CONFLICT` naming that item, and Mark external fixes it in one click.
