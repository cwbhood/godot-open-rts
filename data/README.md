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
| `ai/*.json` | One file per rival AI personality |

How-to guides:

- [Add a unit in 10 minutes](../docs/modding/add-a-unit.md)
- [Make a map](../docs/modding/make-a-map.md), or paint one in the [map editor](../docs/modding/map-editor.md)
- [Add a resource](../docs/modding/add-a-resource.md)

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
| `classic_model`, `classic_model_scale`, `classic_model_offset`, `classic_model_rotation_y_deg` | Art used instead of `model` when the player picks classic unit models in Options (or the game runs with `--unit-models=classic`) |
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

## Mods

A mod is a folder `mods/<name>/data/` (inside the game folder) or
`user://mods/<name>/data/` (the user data folder, see Godot's `user://`) laid out like
this folder. Mods are loaded in alphabetical order on top of the base data:

- a file whose `id` is new adds an entry,
- a file whose `id` already exists replaces just the fields it lists, so a mod
  rebalancing the tank only needs `{"id": "tank", "cost": {"iron": 5, "oil": 3}}`
  (a listed field is replaced as a whole: give the full `cost` or `properties`),
- a mod's `tiers.json` or `roads.json` replaces the base one.
