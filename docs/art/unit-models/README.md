# Play-ready unit models: old vs new

Shots from `tests/screenshots/UnitModelCompare.tscn` on Desert Expanse, made into strips with
`tools/art/compare_strips.py`. In each strip: play zoom at real pixels on the left, close zoom
on the right; columns are old blue, new blue, old red, new red.

Frame cost from `tests/perf/UnitModelBench.tscn` (30 copies in a bare lit scene with shadows,
software renderer in the cloud box, so the ratios matter, not the absolute numbers):

Empty scene: 96.4 ms per frame.

| Unit | Tris per model classic → new | Surfaces | 30 copies: cost ms classic → new | Draw calls | Triangles drawn |
|---|---|---|---|---|---|
| artillery | 4856 → 4020 | 12 → 14 | 51.9 → 50.1 | 39 → 45 | 224k → 190k |
| heavy_tank | 4160 → 5000 | 12 → 4 | 56.1 → 73.6 | 38 → 16 | 165k → 286k |
| helicopter | 3232 → 4124 | 15 → 6 | 33.7 → 46.5 | 48 → 22 | 155k → 170k |
| militia | 2504 → 3366 | 10 → 2 | 19.6 → 24.2 | 32 → 8 | 114k → 110k |
| missile_truck | 3928 → 4260 | 11 → 7 | 42.1 → 55.8 | 39 → 23 | 159k → 187k |
| raider | 2688 → 3688 | 12 → 9 | 27.1 → 36.6 | 39 → 29 | 131k → 172k |
| scout_buggy | 2736 → 3492 | 9 → 8 | 30.9 → 37.4 | 29 → 26 | 129k → 160k |
| tank | 4024 → 3632 | 12 → 4 | 41.7 → 44.2 | 38 → 14 | 157k → 152k |
