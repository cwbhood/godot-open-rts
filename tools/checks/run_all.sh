#!/usr/bin/env bash
# Runs every automated check scene and the data validator, then prints a pass/fail table.
#
#   tools/checks/run_all.sh [OUT_DIR]          # default: ./checks-out
#   JOBS=2 GODOT=/path/to/godot tools/checks/run_all.sh
#   ONLY="VoiceCheck SaveMenuCheck" tools/checks/run_all.sh   # just these
#
# Needs Godot 4.7.2 (GODOT or godot on PATH) and, on a machine without a display, xvfb-run.
# Each check gets OUT_DIR/<name>/ for its log and screenshots; summary.md lists the results.
# The play harness batches are separate: ./play.sh batch quick (see docs/testing/play-harness.md).
set -u
cd "$(dirname "$0")/../.."
OUT="${1:-checks-out}"
GODOT="${GODOT:-godot}"
JOBS="${JOBS:-2}"
TIMEOUT="${TIMEOUT:-1800}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

XVFB=""
if [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null; then
  XVFB='xvfb-run -a -s "-screen 0 1280x720x24"'
fi

# name|scene or script|extra arguments after --
CHECKS=(
  "validate_data|-s res://tools/validate_data.gd|"
  "VoiceCheck|res://tests/audio/VoiceCheck.tscn|"
  "MusicCheck|res://tests/audio/MusicCheck.tscn|"
  "WarSoundsCheck|res://tests/audio/WarSoundsCheck.tscn|"
  "BuildUpCheck|res://tests/buildup/BuildUpCheck.tscn|"
  "CapsChecks|res://tests/caps/CapsChecks.tscn|"
  "CityCentreChecks|res://tests/citycentres/CityCentreChecks.tscn|"
  "CommandChecks|res://tests/commands/CommandChecks.tscn|"
  "CrashPromptCheck|res://tests/crash/CrashPromptCheck.tscn|"
  "DiplomacyChecks|res://tests/diplomacy/DiplomacyChecks.tscn|"
  "LogisticsChecks|res://tests/logistics/LogisticsChecks.tscn|"
  "RailNetworkCheck|-s res://tests/logistics/RailNetworkCheck.gd|"
  "MovementScenarios|res://tests/movement/MovementScenarios.tscn|"
  "OptionsShots|res://tests/options/OptionsShots.tscn|--no-build-up"
  "ConstructorChecks|res://tests/playtest/ConstructorChecks.tscn|"
  "PlaytestChecks|res://tests/playtest/PlaytestChecks.tscn|"
  "HelperChecks|res://tests/playthrough/HelperChecks.tscn|"
  "PlacementNoRoom|res://tests/regression/PlacementNoRoom.tscn|"
  "MatchRulesCheck|res://tests/setup/MatchRulesCheck.tscn|"
  "MatchSetupCheck|res://tests/setup/MatchSetupCheck.tscn|"
  "StartZonesCheck|res://tests/start/StartZonesCheck.tscn|"
  "WaterMovement|res://tests/water/WaterMovement.tscn|"
  "SaveMenuCheck|res://tests/save/SaveMenuCheck.tscn|--no-build-up"
  "ArmyPositions|res://tests/ai/ArmyPositions.tscn|"
  "BuildingInfoCheck|res://tests/hud/BuildingInfoCheck.tscn|"
)

run_one() {
  local name="$1" target="$2" extra="$3"
  local dir="$OUT/$name"
  mkdir -p "$dir"
  local start=$(date +%s)
  if [ "$name" = "CrashPromptCheck" ]; then
    # the prompt only shows with a pending report: crash a run on purpose first
    eval timeout 120 $XVFB "$GODOT" --path . -- --crash-test=crash >"$dir/crash-prep.txt" 2>&1
  fi
  # shellcheck disable=SC2086
  eval timeout "$TIMEOUT" $XVFB "$GODOT" --path . --resolution 1280x720 $target -- --out="$dir" $extra \
    >"$dir/log.txt" 2>&1
  local code=$?
  local seconds=$(( $(date +%s) - start ))
  local result="PASS"
  [ $code -eq 124 ] && result="TIMEOUT"
  [ $code -ne 0 ] && [ $code -ne 124 ] && result="FAIL ($code)"
  grep -q "SCRIPT ERROR" "$dir/log.txt" && [ "$result" = "PASS" ] && result="PASS (script errors in log)"
  echo "$name|$result|${seconds}s" >"$dir/result.txt"
  echo "$name: $result (${seconds}s)"
}
export -f run_one
export OUT GODOT TIMEOUT XVFB

if [ -n "${ONLY:-}" ]; then
  SELECTED=()
  for entry in "${CHECKS[@]}"; do
    [[ " $ONLY " == *" ${entry%%|*} "* ]] && SELECTED+=("$entry")
  done
  CHECKS=("${SELECTED[@]}")
fi

printf '%s\n' "${CHECKS[@]}" | xargs -P "$JOBS" -I{} bash -c 'IFS="|" read -r n t e <<<"{}"; run_one "$n" "$t" "$e"'

{
  echo "# Checks ($(date -u +%Y-%m-%dT%H:%MZ))"
  echo
  echo "| Check | Result | Time |"
  echo "| --- | --- | --- |"
  for entry in "${CHECKS[@]}"; do
    name="${entry%%|*}"
    if [ -f "$OUT/$name/result.txt" ]; then
      sed 's/|/ | /g; s/^/| /; s/$/ |/' "$OUT/$name/result.txt"
    fi
  done
} >"$OUT/summary.md"
cat "$OUT/summary.md"
! grep -qE "FAIL|TIMEOUT" "$OUT/summary.md"
