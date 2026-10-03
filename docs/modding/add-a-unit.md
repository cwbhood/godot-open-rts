# Add a unit in 10 minutes

New units are JSON files. You copy an existing unit, change its numbers and give it a
model; the game builds the rest. No code and no Godot editor needed.

## 1. Copy the template

`data/units/scout_buggy.json` is the template. It is a real unit in the game, made only
from data on top of the raider:

```json
{
  "id": "scout_buggy",
  "base": "raider",
  "name": "SCOUT_BUGGY",
  "description": "SCOUT_BUGGY_DESCRIPTION",
  "model": "res://assets/models/kenney-spacekit/craft_speederB.glb",
  "model_scale": 0.45,
  "model_offset": [-0.9, 0, -0.675],
  "icon_tint": "#9fe0ff",
  "cost": {"iron": 2, "oil": 2},
  "build_time_s": 3.0,
  "speed": 5.2,
  "properties": {
    "sight_range": 12.0, "hp": 4, "hp_max": 4,
    "attack_damage": 1, "attack_interval": 0.8
  },
  "fuel_per_s": 0.008
}
```

Copy it to `data/units/<your_id>.json` (or `mods/<your_mod>/data/units/` to keep your
work separate) and change `id` to match the file name.

## 2. Pick a base

`base` is the unit whose behaviour you reuse. Everything you leave out is taken from it.

| Base | Behaves like |
| --- | --- |
| `raider`, `tank`, `heavy_tank`, `battle_tank`, `artillery`, `missile_truck` | Ground combat vehicle |
| `helicopter`, `gunship` | Aircraft attacking ground and air |
| `drone` | Unarmed scout aircraft |
| `hauler` | Supply truck (set `properties.cargo_capacity`) |
| `worker` | Constructor |
| `ag_turret`, `aa_turret` | Defensive structure |
| `mine`, `lumber_mill`, `oil_derrick` | Extractor (set `extracts`) |
| `power_plant`, `solar_plant`, `pylon` | Power grid structure (set `power`) |

## 3. Change the numbers

- `cost`: what it costs, in commodity ids from `data/resources.json`.
- `speed` (m/s), `fuel_per_s` (oil per second while moving).
- `properties`: `hp`, `hp_max`, `sight_range`, and for armed units `attack_damage`,
  `attack_interval` (seconds between shots), `attack_range`, `attack_domains`.
  When you list `properties`, list every one you want to change; the rest come from
  the base.
- `tier`: city tier needed (1 Frontier, 2 Industrial, 3 Electric).
- `produced_by`: which structure makes it, e.g. `["vehicle_factory"]`.

## 4. Give it a model

`model` is any `.glb`, `.gltf` or `.tscn` inside the project. Make one in Blender and
export glTF binary (`.glb`) with +Y up, about 1-2 m long, facing -Z. Put it in your mod
folder, e.g. `mods/my_mod/models/rover.glb`, and open the project in Godot once so it
gets imported.

`model_scale`, `model_offset` ([x, y, z] in metres) and `model_rotation_y_deg` move the
model so it sits centred on the unit. The base model is hidden automatically.

## 5. Name it

Add your `name` and `description` keys to `assets/translations/match.csv`:

```
SCOUT_BUGGY,Scout buggy,Łazik zwiadowczy
SCOUT_BUGGY_DESCRIPTION,"fast, sharp-eyed and fragile","szybki, dalekowzroczny i kruchy"
```

## 6. Check and try it

```
godot --headless --path . -s res://tools/validate_data.gd
```

Then start the game, tick **Sandbox** in the Play menu and start a match. The sandbox
panel lets you spawn your unit for any faction by clicking the map and top up every
commodity. Your unit also appears in the build menu of its `produced_by` structure.
