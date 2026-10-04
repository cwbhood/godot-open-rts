#!/usr/bin/env bash
# One command to play-test Ironbound with the play harness (Linux and macOS).
#
#   ./play.sh                      the quick batch: every scenario once
#   ./play.sh smoke                one scenario from tools/harness/scenarios/
#   ./play.sh batch maps-vs-ais    a batch from tools/harness/batches/
#   ./play.sh stress 60            60 against 60 units, with frame-time budgets
#   ./play.sh serve                an open match that takes orders on port 7777
#   ./play.sh watch smoke          a scenario in a window at normal speed, to watch it
#
# Extra options go after, e.g. ./play.sh smoke --speed=1 --view=window --seed=3
# Godot is taken from $GODOT, then godot on the PATH. Reports land in harness-out/.
# On a machine without a screen, it runs under xvfb-run when that is installed.
set -euo pipefail
cd "$(dirname "$0")"

GODOT="${GODOT:-$(command -v godot || command -v godot4 || true)}"
if [ -z "$GODOT" ]; then
  echo "Godot not found: set GODOT=/path/to/godot or put godot on your PATH" >&2
  exit 2
fi

what="${1:-batch}"
[ $# -gt 0 ] && shift
case "$what" in
  batch) args=(--batch="${1:-quick}"); [ $# -gt 0 ] && shift ;;
  stress) args=(--stress="${1:-40}"); [ $# -gt 0 ] && shift ;;
  serve) args=(--serve=7777 --scenario=sandbox) ;;
  watch) args=(--scenario="${1:-smoke}" --view=window --speed=1); [ $# -gt 0 ] && shift ;;
  *) args=(--scenario="$what") ;;
esac

run=("$GODOT" --path . res://tools/harness/Harness.tscn -- "${args[@]}" "$@")
if [ -z "${DISPLAY:-}" ] && [ "$(uname)" = "Linux" ] && command -v xvfb-run >/dev/null; then
  run=(xvfb-run -a -s "-screen 0 1600x900x24" "$GODOT" --path . --resolution 1600x900
    res://tools/harness/Harness.tscn -- "${args[@]}" "$@")
fi
exec "${run[@]}"
