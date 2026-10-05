# Game data

Everything players can build, mine, trade or fight with is defined here as JSON, so
content can be added or tuned without touching code. The game reads this folder at start;
mods add to it or patch it (see [mods](#mods)).

| File or folder | What it defines |
| --- | --- |
| `resources.json` | Commodities: timber, iron, copper, oil |
| `tiers.json` | City tiers and the science each one needs |
| `roads.json` | Road levels of supply routes and their cost and speed |
| `caps.json` | Unit cap, match-wide unit cap, match length and end-of-match score |
| `logistics.json` | Trucks' job board, extractor buffers, storage, trains, fleet upkeep and recycling |
| `movement.json` | How ground and air units steer around each other and through crowds |
| `units/*.json` | One file per unit or structure |
| `maps/*.json` | One file per playable map |
| `ai/*.json` | One file per rival AI personality (its play style) |
| `factions/*.json` | One file per playable faction: its units, roles, start units and perks |
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
  {"name": "TIER_FRONTIER", "science": 0, "max_population": 60},
  {"name": "TIER_INDUSTRIAL", "science": 150, "max_population": 100},
  {"name": "TIER_ELECTRIC", "science": 450, "max_population": 130}
]}
```

The city earns science on its own (population, how well it is supplied, power). It
moves to the next tier once science passes the threshold. The first tier must be at 0.
`max_population` is the largest the city can grow at that tier: it stops growing and
building houses there until the next tier. It must not shrink from tier to tier.

## caps.json

```json
{
  "unit_slots_per_player": 150,   // the most unit slots one player can fill
  "unit_slots_per_match": 400,    // all players together; split evenly between them
  "default_unit_slots": 1,        // for units without "unit_slots"
  "time_limit_min": 45,           // the match ends after this long (0: no limit)
  "depletion_countdown_min": 5,   // ...or this long after the last deposit ran dry
  "score": {"per_citizen": 1, "per_unit_slot": 1, "per_structure": 5, "per_science": 0.1}
}
```

Every unit takes `unit_slots` (see units below); units in a production queue count as
soon as they are ordered. A player's cap is `unit_slots_per_player`, or
`unit_slots_per_match` divided by the number of players when that is lower (400 / 4
players = 100 each). At the cap, factories refuse new units for everyone alike: the
player, the helper and the AI. When the match runs out of time, the player with the best
score wins: citizens + unit slots in use + finished structures + science, each times its
weight. Destroying everyone else still wins at once. Sandbox matches have no time limit.

A map can change any of these for itself with a `"caps"` object in its `maps/*.json`
entry, e.g. `"caps": {"time_limit_min": 60, "unit_slots_per_match": 600}` for a big map.
A mod's `caps.json` replaces just the keys it lists.

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

## logistics.json

Tunables of the delivery system (source/match/economy/Logistics.gd, Fleet.gd,
RailNetwork.gd, units Storage and Train). Mods can patch single values: nested objects
are merged key by key.

| Key | Meaning |
| --- | --- |
| `extractor_buffer` | Goods an extractor holds before it stops and waits for a truck |
| `jobs.min_pickup` | Trucks do not drive out for fewer goods than this (unless the extractor is full) |
| `jobs.site_value` | Worth of one unit of construction materials, against commodity prices |
| `jobs.priority_factors` | Value multipliers for the low, normal and high priority a player sets on a building |
| `jobs.city_need_share`, `jobs.city_need_factor` | Goods the city warehouse holds less than this share of are worth this much more |
| `jobs.load_overhead_s` | Seconds added to every trip for loading and unloading |
| `standby.radius_m`, `standby.max_per_source` | Where and how many idle trucks wait next to an extractor |
| `raids.avoid_s`, `raids.radius_m`, `raids.penalty` | Where a truck or train was destroyed, routes within the radius are worth `penalty` times less for that long |
| `storage.capacity`, `storage.link_radius_m`, `storage.conveyor_per_s`, `storage.min_pickup` | Storage size, conveyor reach and speed, smallest load trucks collect |
| `train.capacity`, `train.laying_speed`, `train.track_cost_per_10_m`, `train.stop_s` | Train load, speed while laying track, track cost, time at each stop |
| `train.auto_stops`, `train.auto_min_route_m`, `train.max_leg_m` | How a train plans its own line: number of stops, how far a stop must be from the depot, how far apart stops may be |
| `fleet.upkeep_oil_per_min` | Oil each `hauler` and `train` costs per minute, working or not |
| `fleet.surplus_window_s`, `fleet.surplus_spare`, `fleet.surplus_min` | Trucks without a job for the whole window, minus the spare, are reported as surplus once there are at least `surplus_min` |
| `fleet.recycle_refund` | Share of its cost a recycled truck or train gives back |

The train's speed, cost, tier and capacity shown in menus come from `units/train.json`,
the storage's cost from `units/storage.json`.

## movement.json

Tunables of unit steering, shared by every unit that moves (tanks, haulers, constructors,
aircraft). A mod's `movement.json` patches single fields.

| Field | Meaning |
| --- | --- |
| `crowd_steering` | `false` restores the old movement: everything below is then ignored |
| `avoidance_time_horizon_s` | How far ahead (seconds) units look for others in their way |
| `avoidance_neighbor_distance_m`, `avoidance_max_neighbors` | How many nearby units each one steers around |
| `avoidance_radius_padding_m` | Extra room kept between hulls on top of the unit radius |
| `path_max_distance_m` | How far a unit may be pushed off its path before it asks for a new one |
| `path_requests_per_frame` | Cap on new paths per frame; the rest wait a frame, so a big group order does not stutter |
| `spread_crowded_destinations` | Units sent to the same point, or delivering to the same building, pick free spots next to each other |
| `destination_spacing_m` | Gap kept between those spots |
| `arrival_slack_radii`, `arrival_blocked_s` | A unit within this many of its radii of its destination that cannot get closer for this long counts as arrived |
| `repath_when_stuck_s`, `give_up_when_stuck_s` | A unit that gets no closer for this many seconds asks for a new path (first value) or stops trying (second value, a last resort) |
| `parked_units_make_way` | Units standing still move aside for units on the move, instead of both steering around each other |
| `keep_on_navmesh_every_ticks` | How often units that were pushed are put back onto walkable ground (0 turns it off) |

Check movement in a staged test (head-on groups, a choke point, a crowd sent to one point, a
factory producing into its rally point, crossing columns, orders onto a building):

```
xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
  res://tests/movement/MovementScenarios.tscn -- --out=/tmp/movement
```

## units/*.json

| Field | Meaning |
| --- | --- |
| `id` | Unique id, also the file name |
| `category` | `"unit"` or `"structure"` |
| `scene` | The Godot scene of the unit. Leave it out when you use `base` |
| `base` | Id of an existing unit to copy. The new unit inherits every field but `factions` and you only list what changes (`properties`, `power` and `cost` merge key by key; a `null` value drops the base's field, e.g. `"power": null`) |
| `factions` | Optional: ids of the [factions](#factionsjson) that may build it, e.g. `["syndicate"]`. Left out, the unit is shared by all |
| `model` | `.glb` / `.gltf` / `.tscn` model replacing the scene's own model (for any unit, with or without `base`) |
| `model_scale`, `model_offset`, `model_rotation_y_deg` | Placement of `model` |
| `classic_model`, `classic_model_scale`, `classic_model_offset`, `classic_model_rotation_y_deg` | Art used instead of `model` when the player picks classic unit models in Options (or the game runs with `--unit-models=classic`) |
| `name`, `description` | Translation keys (see `assets/translations/match.csv`) |
| `icon`, `icon_tint` | Build menu button image and tint |
| `tier` | City tier needed to build it |
| `cost` | Commodities, e.g. `{"iron": 6, "oil": 3}` |
| `build_time_s` | Production time of units |
| `unit_slots` | Units only: slots it takes under the unit cap (see [caps.json](#capsjson)); 0 for free units like militia |
| `produced_by` | Ids of structures producing this unit, e.g. `["vehicle_factory"]` |
| `built_by` | For structures: ids of units constructing it, normally `["worker"]` |
| `speed` | Movement speed in m/s |
| `movement` | `"land"` (default), `"water"` (boats) or `"amphibious"`; see [docs/modding/water.md](../docs/modding/water.md) |
| `water_speed` | Amphibious units: speed in m/s on water (default: `speed`) |
| `placement` | Structures: `"shore"` must stand on land next to deep water (the shipyard) |
| `fuel_per_s` | Oil burnt per second while moving |
| `flight_endurance_s` | Air units only: seconds it can stay airborne before it has to land at an airport to refuel (it crashes when it runs dry). Leave it out for helicopters, which hover freely |
| `properties` | `hp`, `hp_max`, `sight_range`, `attack_damage`, `attack_interval`, `attack_range`, `attack_domains` (`"terrain"`, `"air"`), `cargo_capacity` |
| `projectile` | `"cannon_shell"` or `"rocket"` |
| `extracts` | Structures only: commodities it extracts from a deposit next to it |
| `role` | Structures: what the building card calls it, one of `headquarters`, `resource`, `logistics`, `factory`, `power`, `defence`, `support` |
| `info` | Structures: translation key of the longer explanation on the building card (what it is, what it does, how to use it); without it the card shows `description` |
| `power` | `output_mw`, `demand_mw`, `grid_radius_m`, `burns` (commodity per MW per second) |
| `blueprint` | Structures only: the ghost shown while placing it |
| `voice` | Optional: id of the voice set it answers with, overriding `sounds/voices.json` |
| `production_bonus` | Structures with a `demand_mw`: while powered, the factories on the same power grid produce this much faster (0.2 = +20%, the Foundry). Several do not stack |
| `trade_depot` | Structures: `true` makes it a caravan depot like the command center (the Trading Post) |

## factions/*.json

```json
{
  "id": "syndicate",
  "order": 2,                              // place in the Play menu
  "name": "FACTION_SYNDICATE",             // translation keys
  "description": "FACTION_SYNDICATE_DESCRIPTION",
  "color_hint": "#b4532a",                 // the faction's colour, for menus
  "start_units": ["drone", "worker", "worker", "hauler", "hauler"],
  "hidden_units": ["ag_turret", "aa_turret"],   // shared units it replaces with its own
  "roles": {"main_t1": "raider", "ag_turret": "gun_nest", "raider": "raider"},
  "city": {"trade_growth": 1.5, "production_speed": 1.0},
  "armed_caravans": {"attack_damage": 1, "attack_interval": 0.8, "attack_range": 5.0},
  "ai_personalities": ["raider", "trader", "balanced"]
}
```

A player's faction decides what it can build: every unit without `factions` plus the
units that list this faction, minus `hidden_units`. Each slot of the Play menu picks one
(or Random, which an AI picks among the factions listing its personality in
`ai_personalities`). `roles` tell the AI and the city which of its units fill each job:

| Role | Used for |
| --- | --- |
| `main_t1`, `main_t2`, `main_t3` | The AI's main battle unit at each city tier (vehicle factory) |
| `air_t2`, `air_t3` | The AI's aircraft at tier 2 and 3 |
| `support_t2` | A support unit (artillery) |
| `raider` | What the AI sends on raids against supply lines |
| `scout` | What the helper scouts with |
| `ag_turret`, `aa_turret` | Turrets the AI builds and the city puts up as defense posts |
| `militia` | The city's militia |
| `production_boost`, `trade_depot` | The faction's Foundry and Trading Post, which the AI builds |

A role left out uses the unit the game used before factions (`tank`, `heavy_tank`,
`battle_tank`, `helicopter`, `gunship`, `raider`, `scout_buggy`, `ag_turret`, `aa_turret`,
`militia`) when that unit is in the roster. `city.trade_growth` multiplies the city growth
a trade gives (and its cap), `city.production_speed` the speed of every factory.
`armed_caravans` lets the faction's trade caravans shoot back at raiders.

Players created without a faction (test scenes, old saves of the match settings) may build
everything and use the default roles.

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

Each spawn point is the center of a **start zone**. Before the match the player sees the
whole map and clicks inside a zone to place their starter city; AIs take the remaining
zones in secret. Optional fields:

```json
{
  "start_zone_radius": 7,      // metres around a spawn point the city may be placed in
  "start_pick_seconds": 30     // countdown on the start screen
}
```

Generated desert maps (scenes using `DesertMapGenerator.gd`) take their layout from a
`"generator"` block, or from an explicit `"layout"` written by the map editor. Generator
settings for balanced maps:

```json
"generator": {
  "seed": 11,
  "symmetry": "rotational",        // "rotational" (4 zones, square maps) or "point" (2 zones)
  "spawn_inset": 0.11,             // zones sit this far in from the corners (fraction of size)
  "center_lake": true,
  "home_deposits": ["timber", "iron", "oil"],     // next to every zone
  "contested_deposits": ["copper", "iron", "oil"], // anywhere in the open
  "contested_richness": 1.5,
  "middle_deposits": ["oil", "iron", "copper"],   // near the center, the richest
  "middle_richness": 3.0,
  "middle_reach": 0.35             // how far from the center, as a fraction of half the size
}
```

Everything is planned around zone 1 and copied to the other zones, so every zone gets the
same deposits at the same distances. The validator fails a map whose zones differ by more
than 2 m (or 5 %) in distance to any commodity, or by more than 10 % in the amount within
30 m and 60 m. `godot --headless --path . -s res://tools/check_fair_starts.gd` prints the
numbers per zone.

A layout can also hold water (`sea`, `islands`, `water`); see
[docs/modding/map-editor.md](../docs/modding/map-editor.md#the-map-file) and
[docs/modding/water.md](../docs/modding/water.md).

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

`defence` says where the army stands while it is home (not attacking or raiding). Every
field is optional; missing ones take the defaults shown:

```json
"defence": {
  "shape": "groups",      // "groups" (front, flanks, reserve, guards) or "ring" around the city
  "front_m": 16,          // front line distance beyond the edge of the city
  "choke_search_m": 12,   // the front may move this much nearer or farther to a narrow pass
  "staging_share": 0,     // above 0: front at this share of the way to the rival's city
  "front": 0.5,           // shares of the army per group
  "flanks": 0.2,          // a flank closed by the map edge or impassable ground joins the front
  "reserve": 0.2,
  "guards": 0.1,          // at the remote extractors nearest the threat
  "guard_routes": false,  // guards stand halfway along the road instead of at the extractor
  "max_guard_posts": 2,
  "spacing_m": 4,         // between neighbours in a formation
  "ring_m": 5,            // "ring": distance beyond the edge of the city
  "react_m": 22,          // enemies this far beyond the city edge are fought by the nearest units
  "leash_m": 30           // units dragged farther than this from their spot walk back
}
```

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
  "faction_voices": {"syndicate": {"militia": "syndicate_infantry"}},  // shared units, per faction
  "land_voices": {"amphibious_apc": {"default": "vehicle_crew", "syndicate": "syndicate_crew"}},
  "default_voices": {"unit": "vehicle_crew", "air_unit": "pilot", "structure": "structure"},
  "advisor": "advisor",
  "advisor_events": ["base_under_attack", "low_oil", "storage_full", "..."]
}
```

A unit's own `"voice"` field wins, then `faction_voices` for its owner's faction (so a
Syndicate militia sounds like a Syndicate hired gun, a Foundry one like a Foundry soldier),
then `unit_voices`; units in none get the default. `land_voices` is for amphibious units:
while one stands on land it speaks with that set (a set id, or one per faction with a
`"default"`), and only switches to its marine set once it is actually in the water.

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
- a mod's `factions/*.json` adds factions or patches one by id like units (give a whole
  `roles` object when you change it),
- a mod's `tiers.json` or `roads.json` replaces the base one,
- a mod's `sounds/voices.json` patches `unit_voices`, `default_voices`, `land_voices` and each faction of `faction_voices` key by key, and a
  voice set with a known id replaces only the actions it lists (its `folder` applies to its
  own lines), so a mod can give the drone new beeps without copying the rest.
