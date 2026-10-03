# Make a map

A map is a Godot scene plus a small JSON file registering it.

## 1. Start from an existing map

Duplicate `source/match/maps/PlainAndSimple.tscn` in the Godot editor (or copy the file)
and open the copy. A map scene needs:

- the map root using `source/match/Map.gd`, with `size` set to the playable area in
  metres (for example 50 x 50),
- a `SpawnPoints` node with one `Marker3D` per player, where each faction's command
  center will stand,
- terrain and obstacles (the terrain generator from the world thread produces these),
- resource deposits.

## 2. Place deposits

Deposits are where constructors build extractors. Drag these scenes into the map:

| Commodity | Scene |
| --- | --- |
| Timber | `source/match/units/non-player/TimberStand.tscn` |
| Iron | `source/match/units/non-player/IronDeposit.tscn` |
| Copper | `source/match/units/non-player/CopperDeposit.tscn` |
| Oil | `source/match/units/non-player/OilDeposit.tscn` |

Each has a `kind` (the commodity id) and an `amount` (`-1` uses the default from
`data/resources.json`). Leave about 4 m of free ground around a deposit for the
extractor.

How you place them shapes the game:

- Put timber and one iron deposit close to each spawn so every faction can start.
- Put some deposits far away or in the middle: supply lines to them are long and can be
  raided, which is where fights happen.
- Give spawns different strengths (oil-rich next to one, metal-rich next to another).
  Factions then need to trade, which grows both cities.

## 3. Register it

Create `data/maps/<id>.json` (or `mods/<your_mod>/data/maps/<id>.json`):

```json
{
  "id": "dune_crossing",
  "name": "Dune Crossing",
  "scene": "res://source/match/maps/DuneCrossing.tscn",
  "players": 2,
  "size": [80, 60]
}
```

`players` cannot be more than the number of spawn points, and `size` must match the
scene's `size`.

## 4. Check and play it

```
godot --headless --path . -s res://tools/validate_data.gd
```

The map now shows up in the Play menu. To watch how the AIs handle it without playing:

```
xvfb-run -a godot --rendering-driver opengl3 --path . res://tests/simulation/Simulate.tscn \
  -- --map=res://source/match/maps/DuneCrossing.tscn --ai=balanced,trader --seconds=600
```
