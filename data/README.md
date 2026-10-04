# Game data

Everything players can build, mine, trade or fight with is defined here as JSON, so
content can be added or tuned without touching code. The game reads this folder at start;
mods add to it or patch it (see [mods](#mods)).

| File or folder | What it defines |
| --- | --- |
| `resources.json` | Commodities: timber, iron, copper, oil |
| `tiers.json` | City tiers and the science each one needs |
| `roads.json` | Road levels of supply routes and their cost and speed |
| `units/*.json` | One file per unit or structure |
| `maps/*.json` | One file per playable map |
| `ai/*.json` | One file per rival AI personality (its play style) |
| `difficulties/*.json` | One file per AI difficulty, applied on top of the play style |
| `player_colors.json` | The colours players and AIs can pick in the Play menu |
| `sounds/voices.json`, `sounds/voice_sets/*.json` | Which voice each unit answers with, and the advisor's announcements |

How-to guides:

- [Add a unit in 10 minutes](../docs/modding/add-a-unit.md)
- [Make a map](../docs/modding/make-a-map.md), or paint one in the [map editor](../docs/modding/map-editor.md)
- [Add a resource](../docs/modding/add-a-resource.md)
- [Give units new voices](../docs/modding/voices.md)

Check your changes with the validator before starting the game:

```
godot --headless --path . -s res://tools/validate_data.gd
```

It lists every problem it finds (unknown commodity, missing model, a unit nobody can
build, a map with too few spawn points, a missing translation) and exits with code 1 if
any of them is an error.

## resources.json

```json
{"resources": [
  {
    "id": "iron",                       // used everywhere else to refer to it
    "name": "IRON",                     // translation key
    "color": "#9e614d",                 // HUD, minimap, deposits
    "starting_stock": 50,               // what each faction starts with
    "deposit_scene": "res://source/match/units/non-player/IronDeposit.tscn",
    "deposit_amount": 600,              // how much one deposit holds by default
    "extraction_rate_per_s": 0.5,       // per extractor, at full power
    "base_price": 1.5,                  // trade value; local prices move around it
    "city_upkeep_per_population_per_min": 0.04,
    "city_starting_warehouse": 8
  }
]}
```

## tiers.json

```json
{"tiers": [
  {"name": "TIER_FRONTIER", "science": 0},
  {"name": "TIER_INDUSTRIAL", "science": 150},
  {"name": "TIER_ELECTRIC", "science": 450}
]}
```

The city earns science on its own (population, how well it is supplied, power). It
moves to the next tier once science passes the threshold. The first tier must be at 0.

## roads.json

```json
{"roads": [
  {"id": "paved", "name": "ROAD_PAVED", "speed_multiplier": 1.4, "tier": 2,
   "cost_per_10_m": {"timber": 2, "iron": 2}, "color": "#46474a"}
]}
```

The first entry is the dirt track every route starts with. Upgrading the route of an
extractor costs `cost_per_10_m` for every started 10 m between it and its depot. Haulers
working that route drive `speed_multiplier` times faster.

## units/*.json

| Field | Meaning |
| --- | --- |
| `id` | Unique id, also the file name |
| `category` | `"unit"` or `"structure"` |
| `scene` | The Godot scene of the unit. Leave it out when you use `base` |
| `base` | Id of an existing unit to copy. The new unit inherits every field and you only list what changes |
| `model` | `.glb` / `.gltf` / `.tscn` model replacing the scene's own model (for any unit, with or without `base`) |
| `model_scale`, `model_offset`, `model_rotation_y_deg` | Placement of `model` |
| `name`, `description` | Translation keys (see `assets/translations/match.csv`) |
| `icon`, `icon_tint` | Build menu button image and tint |
| `tier` | City tier needed to build it |
| `cost` | Commodities, e.g. `{"iron": 6, "oil": 3}` |
| `build_time_s` | Production time of units |
| `produced_by` | Ids of structures producing this unit, e.g. `["vehicle_factory"]` |
| `built_by` | For structures: ids of units constructing it, normally `["worker"]` |
| `speed` | Movement speed in m/s |
| `fuel_per_s` | Oil burnt per second while moving |
| `flight_endurance_s` | Air units only: seconds it can stay airborne before it has to land at an airport to refuel (it crashes when it runs dry). Leave it out for helicopters, which hover freely |
| `properties` | `hp`, `hp_max`, `sight_range`, `attack_damage`, `attack_interval`, `attack_range`, `attack_domains` (`"terrain"`, `"air"`), `cargo_capacity` |
| `projectile` | `"cannon_shell"` or `"rocket"` |
| `extracts` | Structures only: commodities it extracts from a deposit next to it |
| `power` | `output_mw`, `demand_mw`, `grid_radius_m`, `burns` (commodity per MW per second) |
| `blueprint` | Structures only: the ghost shown while placing it |
| `voice` | Optional: id of the voice set it answers with, overriding `sounds/voices.json` |

## maps/*.json

```json
{
  "id": "plain_and_simple",
  "name": "Plain & Simple",
  "scene": "res://source/match/maps/PlainAndSimple.tscn",
  "players": 4,
  "size": [50, 50]
}
```

The scene must have a `SpawnPoints` node with at least `players` markers and resource
deposits placed as instances of the `deposit_scene` of each commodity.

## ai/*.json

```json
{
  "id": "raider",
  "name": "AI_RAIDER",
  "description": "AI_RAIDER_DESCRIPTION",
  "expected_number_of_workers": 3,
  "expected_number_of_haulers": 3,
  "extractor_targets": {"timber": 1, "iron": 2, "copper": 1, "oil": 2},
  "expected_number_of_power_plants": 1,
  "expected_number_of_ag_turrets": 0,
  "expected_number_of_aa_turrets": 0,
  "expected_number_of_battlegroups": 1,
  "expected_number_of_units_in_battlegroup": 3,
  "raid_party_size": 3,
  "raid_interval_s": 75,
  "trade_hoarding_factor": 1.0,
  "trade_profit_margin": 1.25,
  "trade_offer_interval_s": 60,
  "proposes_agreements": false,
  "peacefulness": 0.5,
  "accepts_alliances": false,
  "attacks_neutrals": true,
  "upgrades_roads": false
}
```

Diplomacy fields: `peacefulness` scales how cheaply the AI signs non-aggression pacts and
alliances (1.0 is average, below 1 it asks for more goods, above 1 it signs for free and
offers pacts itself), `accepts_alliances` says whether it ever allies, and
`attacks_neutrals` whether it attacks factions it is not at war with (which starts a war).

Every personality shows up in the player list of the Play menu.

## difficulties/*.json

Each AI slot in the Play menu has a play style (the personality above) and, in its own
dropdown, a difficulty. The difficulty scales the personality's numbers and decides how
well the AI plays, so an Easy raider still raids, just later, less often and worse.

```json
{
  "id": "easy",
  "name": "DIFFICULTY_EASY",
  "description": "DIFFICULTY_EASY_DESCRIPTION",
  "order": 1,
  "cheats": false,
  "gather_rate": 0.85,
  "production_speed": 0.85,
  "think_interval_multiplier": 2.0,
  "reaction_delay_s": 5.0,
  "economy_scale": 0.75,
  "defense_scale": 0.5,
  "army_size_scale": 0.75,
  "max_attack_groups": 1,
  "first_attack_after_s": 480,
  "raid_interval_scale": 2.0,
  "scouting": false,
  "tech_upgrades": false,
  "retreat_below_hp": 0.0,
  "focus_fire": false
}
```

| Field | What it does | Normal |
| --- | --- | --- |
| `order` | Position in the dropdown, easiest first | |
| `cheats` | Must be `true` for any bonus a human player cannot get (`gather_rate` or `production_speed` above 1). The validator refuses a bonus without it, and the name should say so, like "Brutal (cheats)" | `false` |
| `gather_rate` | Share of hauled goods that reaches its stock and city. Below 1 is a handicap, above 1 a cheat | 1.0 |
| `production_speed` | Speed of its factories and command center. Below 1 is a handicap, above 1 a cheat | 1.0 |
| `think_interval_multiplier` | How often its economy, defense, army and raid planners look at the game: 2.0 means half as often, so its build order is slower | 1.0 |
| `reaction_delay_s` | Seconds an attacking group waits before it picks a new target after its target dies or a faction becomes attackable | 0.5 |
| `economy_scale` | Scales the personality's extractor targets, constructors and haulers (never down to 0) | 1.0 |
| `defense_scale` | Scales its turrets (rounded down, so 0.5 of one turret is none) | 1.0 |
| `army_size_scale` | Scales how many units an attack group waits for before it attacks | 1.0 |
| `max_attack_groups` | Caps the personality's number of attack groups (0 keeps the personality's) | 0 |
| `first_attack_after_s` | No attack group or raid leaves before this many seconds of the match | 0 |
| `raid_interval_scale` | Scales the time between raids; 0 means it never raids | 1.0 |
| `scouting` | Whether its drones scout the map | `true` |
| `tech_upgrades` | Whether it switches to heavier tanks and gunships at higher city tiers | `true` |
| `retreat_below_hp` | Micro: units below this share of their hit points drive home and join the next attack instead of dying (0 = never) | 0.0 |
| `focus_fire` | Micro: the whole group shoots the same target. `false` spreads its fire, so targets live longer | `true` |

The game ships with:

| Difficulty | Cheats | How it plays |
| --- | --- | --- |
| Very easy | no | 70% gathering, 75% build speed, thinks 3x slower, half the extractors, no turrets, no raids, one small attack group from minute 12, no scouting, no unit upgrades, spreads its fire |
| Easy | no | 85% gathering and build speed, thinks 2x slower, 3/4 of the extractors, half the turrets, one 3/4-size attack group from minute 8, raids half as often, no scouting, no unit upgrades, spreads its fire |
| Normal | no | the play style as it is, no bonus and no handicap |
| Hard | no | thinks 2x faster and reacts in a quarter second, 25% more extractors and bigger attack groups, 50% more turrets, raids more often, pulls units below 30% hit points back |
| Brutal (cheats) | **yes** | everything Hard does with 50% more extractors and army, double turrets, and +20% gathering and +15% build speed |

`normal` must exist: it is the default for new AI slots, for `PlayerSettings.ai_difficulty`
and for older match setups. Play difficulties against each other with the same play style:

```
python3 tests/simulation/difficulty_ladder.py --style=balanced --seconds=1500 --jobs=4 \
    --out=/tmp/ladder
```

## player_colors.json

```json
{"player_colors": [{"id": "blue", "name": "COLOR_BLUE", "color": "#66b1ff"}]}
```

Every slot of the Play menu, human or AI, has a colour dropdown with these colours.
Two slots never share one: picking a colour another slot has swaps the two. The picked
colour is `PlayerSettings.color` and becomes the player's team colour on every unit,
structure and city building. The validator checks that there are enough colours for the
biggest map and that no two are too alike.

Team colour goes on the surfaces of a model whose material is named `TeamColor` (what the
Blender scripts in `tools/blender/` export) or whose albedo is the key colour
`(0.99, 0.81, 0.48)` of the older models, so any colour in this list works on both.
## sounds/

`sounds/voices.json` says which voice set every unit uses and which actions need a sound:

```json
{
  "unit_actions": ["select", "move", "attack", "retreat", "build", "cannot", "under_attack", "ready"],
  "optional_unit_actions": ["select_repeat"],   // played when the same unit is clicked 3 times
  "unit_voices": {"militia": "infantry", "drone": "drone"},
  "default_voices": {"unit": "vehicle_crew", "air_unit": "pilot", "structure": "structure"},
  "advisor": "advisor",
  "advisor_events": ["base_under_attack", "low_oil", "storage_full", "..."]
}
```

A unit's own `"voice"` field wins over `unit_voices`; units in neither get the default.

`sounds/voice_sets/<id>.json` lists the lines of one voice. The game picks a line at random
but plays every line of an action once before repeating any, and never the same line twice in
a row. `kind` is `"speech"`, `"machine"` (unmanned units and buildings) or `"advisor"`.

```json
{
  "id": "infantry",
  "kind": "speech",
  "folder": "res://assets/audio/voices/infantry/",
  "lines": {
    "move": [{"file": "move_01.ogg", "text": "Moving out!"}, {"file": "move_02.ogg", "text": "On our way."}]
  }
}
```

`file` is relative to `folder` unless it starts with `res://` or `user://`. The unit actions:
`select` (clicked), `move`, `attack`, `retreat` (a move order while hurt or just hit),
`build`, `cannot` (no valid order for the click), `under_attack` and `ready` (produced).
Check every unit has every sound with `godot --headless --path . res://tests/audio/VoiceCheck.tscn`.

## Mods

A mod is a folder `mods/<name>/data/` (inside the game folder) or
`user://mods/<name>/data/` (the user data folder, see Godot's `user://`) laid out like
this folder. Mods are loaded in alphabetical order on top of the base data:

- a file whose `id` is new adds an entry,
- a file whose `id` already exists replaces just the fields it lists, so a mod
  rebalancing the tank only needs `{"id": "tank", "cost": {"iron": 5, "oil": 3}}`
  (a listed field is replaced as a whole: give the full `cost` or `properties`),
- a mod's `tiers.json` or `roads.json` replaces the base one,
- a mod's `sounds/voices.json` patches `unit_voices` and `default_voices` key by key, and a
  voice set with a known id replaces only the actions it lists (its `folder` applies to its
  own lines), so a mod can give the drone new beeps without copying the rest.
