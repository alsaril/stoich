#!/bin/bash
# In-game test harness for Stoich (see README.md next to this script).
#
#   ./run_game.sh world        build the test world from the stoich-test scenario and save it (stoich-test-k2.zip)
#   ./run_game.sh shots        load that save with the stoich-shots driver: 27 screenshots -> screenshots/
#   ./run_game.sh desync       the shots run in heavy mode (save/load/CRC check every tick); reports desyncs
#   ./run_game.sh rates k2     rate check: Stoich's computed rates vs measured ones -> rates-k2.txt
#   ./run_game.sh rates vanilla    the same with base only (infinite crude oil) -> rates-vanilla.txt
#   ./run_game.sh churn        heavy mode while a driver keeps changing recipes, modules, machines and research -> churn.txt
#                              (churn --no-heavy: the same at full speed, to try the driver)
#   ./run_game.sh features     Space Age: plans per surface, recipe dialog with modules/beacons vs real machines,
#                              voids and imports (stoich-features scenario) -> screenshots/features, features.txt
#   ./run_game.sh dump "<save>"  load a copy of one of your saves with your own mod set and write
#                              every Stoich plan to dump-<save>.json (the save itself is not touched)
#   ./run_game.sh play         load the newest save to play/test by hand (stays open)
#
# Uses an isolated Factorio data folder (test-world/.game): its own config, mods
# and saves; your normal Factorio profile is never touched. The mod itself is
# linked from ../stoich, so it always runs the working copy.
# Where the game, your mods and your saves are: FACTORIO_BIN, FACTORIO_MODS and
# FACTORIO_SAVES, from test-world/local.env (see local.env.example) or the environment;
# found by themselves for the usual macOS and Linux installs.
# Needs Krastorio2 2.1.x, flib and ChangeInserterDropLane zips in your mods folder (K2 and
# Space Age don't go together: each mode turns on its own set and every other mod off).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
G="$HERE/.game"
# shellcheck source=/dev/null
[ -f "$HERE/local.env" ] && . "$HERE/local.env"

first_existing() { # the first argument that exists, else nothing
  for p in "$@"; do [ -e "$p" ] && { echo "$p"; return; }; done
}
B="${FACTORIO_BIN:-$(first_existing \
  "$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio" \
  "/Applications/factorio.app/Contents/MacOS/factorio" \
  "$HOME/.steam/steam/steamapps/common/Factorio/bin/x64/factorio" \
  "$HOME/.local/share/Steam/steamapps/common/Factorio/bin/x64/factorio" \
  "$HOME/factorio/bin/x64/factorio")}"
MODS="${FACTORIO_MODS:-$(first_existing "$HOME/Library/Application Support/factorio/mods" "$HOME/.factorio/mods")}"
SAVES="${FACTORIO_SAVES:-${MODS:+$MODS/../saves}}"
[ -n "$B" ] && [ -x "$B" ] || { echo "Factorio not found: set FACTORIO_BIN in $HERE/local.env (see local.env.example)"; exit 1; }
[ -n "$MODS" ] && [ -d "$MODS" ] || { echo "Your Factorio mods folder not found: set FACTORIO_MODS in $HERE/local.env"; exit 1; }
MODE="${1:-}"

setup() {
  mkdir -p "$G/config" "$G/mods" "$G/scenarios" "$G/saves"
  printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n[general]\nlocale=en\n[other]\ncheck-updates=false\n' "$G" > "$G/config/config.ini"
  for pattern in "Krastorio2_*.zip" "Krastorio2Assets_*.zip" "Krastorio2MenuSimulations_*.zip" "flib_*.zip" "ChangeInserterDropLane_*.zip"; do
    f=$(ls "$MODS"/$pattern 2>/dev/null | tail -1)
    [ -n "$f" ] && ln -sf "$f" "$G/mods/$(basename "$f")" || echo "missing mod: $pattern"
  done
  ln -sfn "$HERE/../stoich" "$G/mods/stoich"
  ln -sfn "$HERE/stoich-shots" "$G/mods/stoich-shots"
  ln -sfn "$HERE/stoich-churn" "$G/mods/stoich-churn"
  ln -sfn "$HERE/stoich-dump" "$G/mods/stoich-dump"
  ln -sfn "$HERE/stoich-test" "$G/scenarios/stoich-test"
  ln -sfn "$HERE/stoich-rates" "$G/scenarios/stoich-rates"
  ln -sfn "$HERE/stoich-features" "$G/scenarios/stoich-features"
  echo 427520 > "$G/steam_appid.txt" # keeps Steam from relaunching the game without our arguments
}

mod_list() { # $1 = test driver mod (shots, churn or none; shots also just turns the debug interface on), $2 = k2, vanilla, sa (Space Age) or user (your enabled mods)
  python3 - "$G/mods/mod-list.json" "$1" "${2:-k2}" "$MODS/mod-list.json" <<'PY'
import json, sys
if sys.argv[3] == "user":
    mods = {m["name"]: True for m in json.load(open(sys.argv[4]))["mods"] if m["enabled"]}
    mods.update({"stoich": True, "stoich-shots": True, "stoich-dump": True})
    json.dump({"mods": [{"name": k, "enabled": v} for k, v in mods.items()]}, open(sys.argv[1], "w"))
    sys.exit(0)
k2 = sys.argv[3] == "k2"
sa = sys.argv[3] == "sa"
mods = {"base": True, "elevated-rails": sa, "quality": sa, "recycler": sa, "space-age": sa,
        "Krastorio2": k2, "Krastorio2Assets": k2, "Krastorio2MenuSimulations": k2, "flib": k2,
        "ChangeInserterDropLane": k2, "stoich": True,
        "stoich-shots": sys.argv[2] == "shots", "stoich-churn": sys.argv[2] == "churn"}
# every other mod in the folder (left there by a dump of one of your saves) is off:
# Factorio enables a mod the list doesn't name
import os, re
for entry in os.listdir(os.path.dirname(sys.argv[1])):
    name = re.sub(r"_\d+\.\d+\.\d+(\.zip)?$", "", entry)
    if name not in mods and not entry.endswith((".json", ".dat")):
        mods[name] = False
json.dump({"mods": [{"name": k, "enabled": v} for k, v in mods.items()]}, open(sys.argv[1], "w"))
PY
}

heavy_verdict() { # heavy mode logs "Heavy mode check <point>-<tick> failed" and writes state dumps on a mismatch
  local checked failed
  checked=$(grep -c 'Heavy mode - tick .* finished' "$G/factorio-current.log")
  failed=$(grep -c 'Heavy mode check .* failed' "$G/factorio-current.log")
  echo "heavy mode: $checked ticks checked, $failed failed checks, $(ls "$G/dumps" 2>/dev/null | wc -l | tr -d ' ') dump files"
  grep -m1 'Heavy mode check .* failed' "$G/factorio-current.log"
  [ "$failed" = 0 ] && [ "$checked" -gt 0 ] && echo "DESYNC CHECK: PASS" || echo "DESYNC CHECK: FAIL"
}

stop() { # close the game we started: SIGTERM, then SIGKILL
  kill "$1" 2>/dev/null
  for _ in $(seq 1 15); do kill -0 "$1" 2>/dev/null || return 0; sleep 1; done
  kill -9 "$1" 2>/dev/null
}

wait_for() { # $1 = file that signals completion, $2 = pid, $3 = timeout in seconds
  for i in $(seq 1 $(( ${3:-480} / 2 ))); do
    [ -f "$1" ] && { echo "done after $((i * 2))s"; return 0; }
    kill -0 "$2" 2>/dev/null || { echo "game exited early"; return 1; }
    sleep 2
  done
  echo "timed out"
}

shots() { # $1 = extra game arguments (e.g. --heavy), $2 = timeout
  mod_list shots k2
  cp "$HERE/stoich-test-k2.zip" "$G/saves/_autosave-stoich-test.zip"
  rm -rf "$G/script-output/shots" "$G/dumps"
  "$B" --config "$G/config/config.ini" --mod-directory "$G/mods" --load-game "$G/saves/_autosave-stoich-test.zip" \
    --disable-audio --window-size 1920x1080 --disable-migration-window $1 > "$G/run.out" 2>&1 &
  PID=$!
  wait_for "$G/script-output/shots/done.txt" $PID "$2"; sleep 4; stop $PID
  grep -E "NOT SAVED|FAILED" "$G/script-output/shots/steps.log"
}

setup
cd "$G" || exit 1 # steam_appid.txt must be in the working directory
case "$MODE" in
  world)
    mod_list none k2
    rm -f "$G/script-output/stoich-test-saved.txt" "$G/saves/_autosave-stoich-test.zip"
    "$B" --config "$G/config/config.ini" --mod-directory "$G/mods" --load-scenario stoich-test \
      --disable-audio --window-size 1600x900 --disable-migration-window > "$G/run.out" 2>&1 &
    PID=$!
    wait_for "$G/script-output/stoich-test-saved.txt" $PID; sleep 4; stop $PID
    cp "$G/saves/_autosave-stoich-test.zip" "$HERE/stoich-test-k2.zip" && echo "saved $HERE/stoich-test-k2.zip"
    ;;
  shots)
    shots "" 480
    mkdir -p "$HERE/screenshots" && rm -f "$HERE/screenshots/"*.png && cp "$G/script-output/shots/"*.png "$HERE/screenshots/"
    echo "$(ls "$HERE/screenshots" | wc -l | tr -d ' ') screenshots in $HERE/screenshots (data: $G/script-output/shots/data.json)"
    ;;
  desync)
    shots --heavy 3000
    echo "screenshots taken: $(ls "$G/script-output/shots/"*.png 2>/dev/null | wc -l | tr -d ' ') of 24"
    heavy_verdict
    ;;
  rates)
    PROFILE="${2:-k2}"
    mod_list shots "$PROFILE"
    rm -rf "$G/script-output/stoich-rates"
    "$B" --config "$G/config/config.ini" --mod-directory "$G/mods" --load-scenario stoich-rates \
      --disable-audio --window-size 1600x900 --disable-migration-window > "$G/run.out" 2>&1 &
    PID=$!
    wait_for "$G/script-output/stoich-rates/done.txt" $PID 900; sleep 2; stop $PID
    cp "$G/script-output/stoich-rates/report.txt" "$HERE/rates-$PROFILE.txt" && tail -1 "$HERE/rates-$PROFILE.txt"
    ;;
  churn)
    # heavy mode while the world keeps changing under Stoich (stoich-churn driver)
    mod_list churn k2
    HEAVY=--heavy; [ "${2:-}" = "--no-heavy" ] && HEAVY=
    cp "$HERE/stoich-test-k2.zip" "$G/saves/_autosave-stoich-test.zip"
    rm -rf "$G/script-output/churn" "$G/dumps"
    "$B" --config "$G/config/config.ini" --mod-directory "$G/mods" --load-game "$G/saves/_autosave-stoich-test.zip" \
      --disable-audio --window-size 1920x1080 --disable-migration-window $HEAVY > "$G/run.out" 2>&1 &
    PID=$!
    wait_for "$G/script-output/churn/done.txt" $PID 3000; sleep 4; stop $PID
    cp "$G/script-output/churn/report.txt" "$HERE/churn.txt" && sed -n '1,/^$/p' "$HERE/churn.txt"
    [ -n "$HEAVY" ] && heavy_verdict
    ;;
  features)
    mod_list shots sa
    rm -rf "$G/script-output/features"
    "$B" --config "$G/config/config.ini" --mod-directory "$G/mods" --load-scenario stoich-features \
      --disable-audio --window-size 1920x1080 --disable-migration-window > "$G/run.out" 2>&1 &
    PID=$!
    wait_for "$G/script-output/features/done.txt" $PID 600; sleep 2; stop $PID
    mkdir -p "$HERE/screenshots/features" && rm -f "$HERE/screenshots/features/"*.png
    cp "$G/script-output/features/"*.png "$HERE/screenshots/features/" 2>/dev/null
    cp "$G/script-output/features/report.txt" "$HERE/features.txt" 2>/dev/null && grep -E "FAIL|failure" "$HERE/features.txt"
    ;;
  dump)
    # every enabled mod of yours (zips; a folder only when there is no zip of it), not Stoich's zips
    for f in "$MODS"/*.zip; do
      case "$(basename "$f")" in stoich_*) continue ;; esac
      ln -sf "$f" "$G/mods/$(basename "$f")"
    done
    mod_list none user
    rm -rf "$G/script-output/dump"
    cp "$SAVES/${2}.zip" "$G/saves/_dump.zip" || exit 1
    "$B" --config "$G/config/config.ini" --mod-directory "$G/mods" --load-game "$G/saves/_dump.zip" \
      --disable-audio --window-size 1600x900 --disable-migration-window > "$G/run.out" 2>&1 &
    PID=$!
    wait_for "$G/script-output/dump/done.txt" $PID 300; sleep 2; stop $PID
    cp "$G/script-output/dump/plans.json" "$HERE/dump-${2}.json" && echo "plans in $HERE/dump-${2}.json"
    mkdir -p "$HERE/screenshots/dump" && rm -f "$HERE/screenshots/dump/"*.png && cp "$G/script-output/dump/"*.png "$HERE/screenshots/dump/" 2>/dev/null
    ;;
  play)
    mod_list none k2
    SAVE=$(ls -t "$G/saves/"*.zip 2>/dev/null | head -1)
    [ -z "$SAVE" ] && { cp "$HERE/stoich-test-k2.zip" "$G/saves/stoich-test-k2.zip"; SAVE="$G/saves/stoich-test-k2.zip"; }
    nohup "$B" --config "$G/config/config.ini" --mod-directory "$G/mods" --load-game "$SAVE" > "$G/run.out" 2>&1 &
    disown
    echo "started with $SAVE"
    ;;
  *) echo "usage: $0 world|shots|desync|churn|rates [k2|vanilla]|features|dump \"<save>\"|play"; exit 1 ;;
esac
grep -E "Error|stoich-test:" "$G/factorio-current.log" 2>/dev/null | grep -vi steam | head -5 || true
