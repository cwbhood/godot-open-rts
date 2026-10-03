# Add a resource

Commodities are defined in `data/resources.json`. Everything that deals with them (the
resource bar, costs, the city's needs, trade prices, the minimap, AI extractor planning)
reads that list, so a new commodity needs data and one deposit scene, no code.

This example adds sulfur.

## 1. Define it

Add an entry to `data/resources.json` (a mod uses `mods/<mod>/data/resources.json` with
just the new entry):

```json
{
  "id": "sulfur",
  "name": "SULFUR",
  "color": "#e3d34a",
  "starting_stock": 0,
  "deposit_scene": "res://mods/chemistry/SulfurDeposit.tscn",
  "deposit_amount": 400,
  "extraction_rate_per_s": 0.3,
  "base_price": 2.0,
  "city_upkeep_per_population_per_min": 0.0,
  "city_starting_warehouse": 0
}
```

- `base_price` is its trade value compared to the others (timber is 1).
- A `city_upkeep_per_population_per_min` above 0 makes cities need it: they grow more
  slowly and earn less science when it runs short.

## 2. Make a deposit

Copy `source/match/units/non-player/IronDeposit.tscn` to the path you used in
`deposit_scene`, and set its `kind` to `"sulfur"`. Swap the rock model for your own if
you like (anything under the `Geometry` node).

## 3. Let something extract it

Add the id to the `extracts` list of an extractor, or make a new extractor with `base`:

```json
{
  "id": "sulfur_pit",
  "base": "mine",
  "name": "SULFUR_PIT",
  "description": "SULFUR_PIT_DESCRIPTION",
  "extracts": ["sulfur"],
  "cost": {"timber": 4, "iron": 4}
}
```

The AI builds one when its personality asks for it in `extractor_targets`, for example
`"extractor_targets": {"sulfur": 1, ...}` in `data/ai/balanced.json`.

## 4. Use it

Put it in the `cost` of units and structures, e.g. `"cost": {"iron": 6, "sulfur": 2}`
for a missile unit.

## 5. Place deposits and name it

Place your deposit scene on maps (see [Make a map](make-a-map.md)) and add `SULFUR`,
`SULFUR_PIT` and `SULFUR_PIT_DESCRIPTION` to `assets/translations/match.csv`. Then run
the validator:

```
godot --headless --path . -s res://tools/validate_data.gd
```
