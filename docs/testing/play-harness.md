# The play harness

One tool to play and test Ironbound from a script. It starts matches the way the game
does, gives orders through the same code the HUD uses, writes down what happened and
says plainly whether it worked.

It replaces the pile of one-off test scenes (the playthrough bot, `Simulate.tscn`,
`Shots.tscn`, `MatchPerf`, `HelperChecks` and the QA batch scripts). Those still work;
new tests should be scenario files instead.

## Quick start

On Windows, in the project folder:

```bat
play                      :: the quick batch: every scenario once
play smoke                :: one scenario
play watch line-orders    :: watch a scenario in a window at normal speed
play stress 60            :: 60 against 60 units, with frame-time budgets
play batch maps-vs-ais    :: the smoke match on 5 maps against 4 AIs (20 matches)
play serve                :: an open match a script can drive (port 7777)
```

On Linux or macOS use `./play.sh` with the same words. Both find Godot through the
`GODOT` environment variable first (`setx GODOT "C:\...\Godot_v4.7.2-stable_win64.exe"`
once on Windows), then `godot` on the PATH.

Everything a run produces goes into `harness-out/<date>-<name>/` (ignored by git):

| File | What it is |
| --- | --- |
| `report.md` | Read this first: PASS or FAIL, every check, who had what at the end, frame times, script errors, a timeline of what happened, screenshots |
| `report.json` | The same for scripts and the batch runner |
| `timeline.jsonl` | Every event: buildings finished, units lost, tiers, wars, trades, refused placements, orders given |
| `metrics.csv` | A sample every few game seconds: frame time, process time (Godot's own "Process" monitor), node count, units and stock per player. Opens in Excel |
| `shots/*.png` | Screenshots taken on a timer, on request, and at the end |
| `crash_report.txt` | Only after a crash, freeze or error storm (see [crash-reports.md](../crash-reports.md)) |

A batch writes `batch.md` (one table row per match), `batch.csv` and `batch.json`,
plus each match's own folder under `runs/`.

The exit code is 0 when everything passed and 1 when a check, a budget or a match
failed, so a CI job can run it as is.

### Your mouse stays yours

Matches on your PC run in their own window on your graphics card. The harness clicks,
drags and hovers with its own virtual mouse (the yellow arrow in the window and in
screenshots): it sends the same input events a mouse makes, but never moves or traps
your cursor, and it keeps your real mouse out of the scripted match so moving it over
the window changes nothing. Add `--real-mouse=on` to play along.

### Fast or real

`--view=fast` (the default for scenarios run from the command line) switches 3D drawing
off between screenshots, so a 10-minute match takes 2 to 3 minutes even on a laptop
without a graphics card. Frame times are then CPU only. `--view=window` (what `play.bat`
uses) draws every frame: that is the one to use for real frame-rate numbers.

## Options

Pass them after the scenario: `play smoke --speed=1 --seed=3 --ai=raider,turtle`.

| Option | Meaning |
| --- | --- |
| `--scenario=NAME` | A file from `tools/harness/scenarios/` (or any path) |
| `--batch=NAME` | A file from `tools/harness/batches/` |
| `--stress=N` | N against N mixed units in the middle of Big Arena |
| `--serve[=PORT]` | Keep the match running and take orders over TCP |
| `--view=fast\|window` | See above |
| `--speed=X` | Game speed, like the time scale (4 = four times as fast) |
| `--seed=N`, `--minutes=M`, `--map=ID` | Override the scenario's |
| `--ai=raider,turtle` | Replace the AI opponents |
| `--difficulty=hard` | Every AI's difficulty |
| `--helper=on` | Switch the player's helper on |
| `--shots-every=S` | A screenshot every S game seconds |
| `--out=DIR` | Where the report goes |
| `--baseline=FILE` | Batches: an earlier `batch.json` to compare with |
| `--parallel=N` | Batches: matches at once (each is its own Godot process) |
| `--budget-frame-ms=X` | Fail when the 95th percentile frame time is above X ms |
| `--budget-process-ms=X` | The same for process time (Godot's Process monitor) |
| `--real-mouse=on` | Let your mouse into the match |
| `--window=1600x900` | Window size |
| `--max-real-minutes=M` | Give up after M real minutes (default 90) |

## Scenario files

A scenario is a JSON file in `tools/harness/scenarios/`. Everything is optional except
what you want to test. A short one:

```json
{
  "name": "line-orders",
  "description": "Six tanks get a line order and must spread out along it.",
  "map": "plain_and_simple",
  "minutes": 2.5,
  "speed": 2,
  "fog": false,
  "players": [{"type": "human"}, {"type": "ai", "personality": "turtle"}],
  "setup": [
    {"do": "spawn", "player": "own", "unit": "tank", "count": 6,
     "spot": {"of": "base", "offset": [10, 10]}}
  ],
  "events": [
    {"at": 2, "do": "line", "units": "own:tank",
     "from": {"of": "base", "offset": [7, 20]}, "to": {"of": "base", "offset": [25, 20]},
     "expect_ok": true}
  ],
  "checks": [
    {"at": 40, "name": "the tanks stand on the line", "expect": "on_line",
     "units": "own:tank", "from": {"of": "base", "offset": [7, 20]},
     "to": {"of": "base", "offset": [25, 20]}, "within": 2.0, "min_spacing": 2.0},
    {"end": true, "expect": "no_errors"}
  ]
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `name`, `description` | file name | Shown at the top of the report |
| `map` | `plain_and_simple` | A map id from `data/maps/` |
| `seed` | 1 | Seeds Godot's random numbers. Navigation and frame timing still vary a little, so two runs of one seed are close, not identical |
| `minutes` (or `seconds`) | 5 | Game time limit |
| `speed` | 1 | Game speed |
| `view` | `fast` | `fast` or `window` |
| `players` | you + balanced AI | `{"type": "human", "helper": true, "color": "red", "start_zone": 0}` or `{"type": "ai", "personality": "raider", "difficulty": "hard"}` |
| `fog` | true | false reveals the whole map |
| `weather` | `clear` | `clear`, `overcast`, `rain`, `sandstorm`, or `random` for the map's own changing weather |
| `tutorial` | false | true keeps the tutorial panel |
| `city_build_up` | false | true plays the starter-city build-up first |
| `match_end` | false | true lets the match end on victory, defeat or the match limits |
| `sample_every` | 5 | Seconds between metric samples |
| `shots_every` | 0 | Seconds between screenshots (0: only requested ones and the last one) |
| `setup` | [] | Orders run right after the start, one after the other |
| `events` | [] | Orders with `"at": seconds`, or `"every": seconds` (with optional `"from"`/`"until"`) |
| `checks` | [] | Expectations, see below |
| `budgets` | {} | `{"frame_ms_p95": 33, "process_ms_p95": 10}`: checked at the end |
| `end_when` | none | A check; the match ends as soon as it passes |

Any order can carry `"expect_ok": true`: the report then lists it as a check that fails
when the order did not work (a refused placement, nothing to select...).

### Picking units and places

Units are picked with **selectors**: `own:tank`, `own:combat`, `own:workers`,
`own:structures`, `own:*`, `enemy:*` (at war with you), `p1:raider` (player 1),
`all:*`, a unit id from `state()`, or a list of ids. Add `"near": [x, z]`, `"radius"`
and `"limit"` to narrow them down.

Places are `[x, z]` in metres, `"base"` (your command center), any selector (the
first unit it picks), or `{"of": "base", "offset": [dx, dz]}`.

### Orders

These go in `setup` and `events`, and over the TCP API. All return `{"ok": true|false, ...}`
and an `"error"` when something did not work.

| Order | Fields | Goes through |
| --- | --- | --- |
| `select` | `units`, `"via": "mouse"` to click or box-drag | the units' Selection trait, or the virtual mouse |
| `move` | `units`, `to`, `queue` | the right-click-on-ground signal |
| `attack` | `units`, `target` | the right-click-on-enemy signal |
| `fight`, `patrol`, `guard` | `units`, `to` (`points` for patrol, `target` for guard), `queue` | `UnitCommandHandler.issue_at`, like the buttons |
| `line` | `units`, `from`, `to`, `kind` (move/fight), `"via": "mouse"` for a right-button drag | `UnitCommandHandler.issue_line`, or a real drag |
| `patrol_base`, `stop`, `retreat` | `units` | `UnitCommandHandler.run_instant` |
| `stance` | `units`, `stance`: at_will, return, hold | `UnitCommands.set_fire_stance` |
| `hold_position` | `units`, `on` | `UnitCommands.toggle_hold_position` |
| `build` | `structure` (unit id), `spot`, `offset`, `builder` | the build menu signal, then the virtual mouse points and clicks; refusals say why (`collides`, `not_navigable`, `no_deposit_nearby`...) |
| `extract` | `resource`, `builder` | hovers the nearest free deposit with a constructor selected and clicks, as the tooltip tells players |
| `produce` | `unit`, `count`, `producer` | the factory's production queue, as the build menu does |
| `helper` | `on`, `army`, `scouting` | the helper panel switch |
| `auto_expand` | `units`, `on` | `AutoExpand.set_enabled_on` |
| `speed` | `x` | time scale |
| `camera` | `spot` or `follow` | the match camera |
| `click`, `drag` | `screen: [x, y]` or `world: [x, z]`, `button`, `shift` | the virtual mouse |
| `key` | `key` ("G") or `action` ("command_patrol") | input events |
| `screenshot` | `name` | |
| `wait` | `seconds` | game time (for scripts) |
| `state` | `units` | returns the state below |
| `end` | `reason` | ends the match |
| `spawn` | `player`, `unit`, `count`, `spot`, `spacing` | test setup, like the sandbox panel |
| `give` | `player`, `resources` | test setup |
| `declare_war` | `player`, `on` | diplomacy |
| `weather` | `set` | the map's atmosphere |
| `reveal` | | lifts the fog |

AI units can be ordered too (`p1:combat`): the harness then calls the same
`UnitCommands` functions directly, since the handler only orders the player's units.

### Checks

Each check has `"at": seconds` (once), `"end": true` (when the match ends) or
`"always": true` (every sample; it fails the first time it is false). Numbers are
compared with `min`, `max` or `equals`. Give a `name` so the report reads well.

| `expect` | Fields | Passes when |
| --- | --- | --- |
| `units` | `units`, `near`, `radius` | the number of units picked is in range |
| `built` | `units` | the number of finished structures is in range |
| `stock` | `player`, `resource` | the stock is in range |
| `near` | `units`, `to`, `radius`, `share` | that share of the units is within the radius |
| `spread` | `units`, `min_m` | no two units are closer than `min_m` |
| `on_line` | `units`, `from`, `to`, `within`, `min_spacing` | every unit is within `within` m of the line, spread out |
| `no_errors` | | no script errors so far |
| `no_war_started_by` | `player` | that player struck first in no war |
| `helper` | `stat` | a helper statistic (`attack_orders`, `retreats`, `detours`, `constructors_ordered`...) is in range |
| `timeline` | `kind`, `contains` | the number of timeline events of that kind is in range (`built`, `losses`, `placement_refused`, `tier`, `diplomacy`, `trade`, `unit_cap`, `match_end`...) |
| `metric` | `metric` | an end metric is in range (`frame_ms_p95`, `process_ms_p95`, `fps_mean`, `script_errors`, `slow_frames_over_50ms`...) |
| `expr` | `code` | a Godot expression over `state` is true, e.g. `state.players[1].tier >= 2` |

## Batches

A batch either lists scenarios:

```json
{"name": "quick", "runs": ["smoke", "place-extractors", "line-orders"]}
```

or crosses one scenario with a matrix of `map`, `ai` (comma-separated opponents),
`difficulty` and `seed`:

```json
{
  "name": "maps-vs-ais",
  "scenario": "smoke",
  "matrix": {"map": ["plain_and_simple", "oil_and_iron"], "ai": ["raider", "turtle"]},
  "override": {"minutes": 8, "speed": 4},
  "parallel": 2,
  "timeout_minutes": 20
}
```

Every match runs in its own Godot process, so a crash or freeze costs only that match
(it shows as CRASH with the reason). Keep a `batch.json` from a good day and pass it
with `--baseline=` later: the table then lists **regressions**: a match that passed
and now fails, more script errors, a crash, or a 95th percentile frame time more than
25% (and 2 ms) worse.

## Stress

`play stress 60` (or `--stress=60`) puts 60 tanks, raiders, militia, artillery and heavy
tanks on each side of Big Arena, sends them at each other and measures the frame and
process time while they fight. The default budget is 50 ms frame time at the 95th percentile;
set your own with `--budget-frame-ms` and `--budget-process-ms`.
`scenarios/stress-40v40.json` is the same as a file, for batches and CI.

## Driving a match from a script (the API)

`play serve` starts an open match (the `sandbox` scenario) and listens on
127.0.0.1:7777. Send one JSON order per line, get one JSON line back.
`tools/harness/harness_client.py` (plain Python 3, no packages) does it for you:

```bash
python3 tools/harness/harness_client.py watch          # a status line every 5 game seconds
python3 tools/harness/harness_client.py state --units  # everything, as JSON
python3 tools/harness/harness_client.py do '{"do": "produce", "unit": "tank", "count": 3}'
```

```python
from harness_client import Game
game = Game()
game.do("extract", resource="iron")
game.wait(30)
print(game.state(units=False)["players"][0]["stock"])
```

`state` returns:

```json
{
  "t": 125.4, "fps": 58, "frame_ms": 16.9, "process_ms": 4.1, "physics_ms": 2.3,
  "nodes": 5120, "speed": 1.0, "unit_count": 63,
  "players": [{"index": 0, "type": "human", "stock": {"timber": 40, "iron": 12, ...},
               "tier": 1, "units": 7, "structures": 6, "combat": 2, "workers": 3,
               "population": 31, "science": 12.5, "at_war_with": [],
               "helper": {"enabled": false, "army_target": 8, "stats": {...}}}, ...],
  "units": [{"id": 3054, "player": 0, "kind": "tank", "x": 31.2, "z": 40.5,
             "hp": 10, "hp_max": 10, "action": "Moving", "selected": true}, ...],
  "selected": [3054],
  "threats": [{"id": 4410, "player": 1, "kind": "raider", "x": 50, "z": 44, "near": 3054}],
  "recent_events": [...]
}
```

`threats` are enemy units at war with you that one of your units can see.

## Writing a new test

1. Copy the closest file in `tools/harness/scenarios/`.
2. Set up only what the test needs (`spawn`, `give`, `fog: false`) so it is quick.
3. Give every order that must work `"expect_ok": true`, and every check a `name` a
   person understands.
4. Run it with `play watch <name>` once to see it, then `play <name>`.
5. Add it to `batches/quick.json`.

## Files

| File | Part |
| --- | --- |
| `tools/harness/Harness.gd` | Command line, modes |
| `tools/harness/HarnessApi.gd` | State as JSON, every order |
| `tools/harness/VirtualMouse.gd` | The harness's own mouse |
| `tools/harness/ScenarioRunner.gd` | Scenario files, checks |
| `tools/harness/Recorder.gd` | Timeline, metrics, screenshots, report |
| `tools/harness/BatchRunner.gd` | Many matches, tables, regressions |
| `tools/harness/ApiServer.gd`, `harness_client.py` | The TCP API |
| `source/utils/VirtualPointer.gd` | The one game hook: where the game reads the mouse position |
