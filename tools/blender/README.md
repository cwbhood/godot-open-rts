# Ironbound procedural models

`build_assets.py` builds every Ironbound low-poly model from scratch with Blender's
`bmesh` API and exports one `.glb` per model. No external meshes or textures are
used: all geometry and colours come from the script, so the output is our own work
and can be licensed CC0/MIT along with the script.

## Running

From the repository root:

```sh
# Blender installed as a Python module (bpy)
python3.11 tools/blender/build_assets.py

# or a desktop Blender (4.x) in background mode; script options go after "--"
blender -b -P tools/blender/build_assets.py -- --no-preview
```

Options:

| option | effect |
| --- | --- |
| `--only NAME[,NAME]` | build only models whose name contains one of the substrings |
| `--category CAT` | build one category: `env`, `deposits`, `units`, `buildings` |
| `--no-preview` | skip the preview renders (fast, a few seconds) |
| `--preview-only` | re-render the contact sheets from the existing GLBs |
| `--scene-only` | render only the in-game-camera diorama previews |
| `--samples N` | Cycles samples for previews (default 16) |

A full run, with previews rendered by Cycles on the CPU, takes about 2-3 minutes. It
prints a table with each model's triangle count, size, footprint centre, whether
the count is within budget, and its animated sub-objects.

Output:

* `assets/models/ironbound/{env,deposits,units,buildings}/<name>.glb`
* `tools/blender/previews/<category>.png`: one tile per model, with a 3/4 view
  from 33 degrees down, warm sun and a 1 m sand checker on the ground
* `tools/blender/previews/scene.png` and `scene_far.png`: a true-scale diorama
  through the game's camera (orthographic, 30 degrees down, size 15 and 30)

In the previews, `TeamColor` is replaced by blue (player 1) or red (player 2) so
the team-coloured surfaces are easy to see. The GLBs keep the real `TeamColor`
material.

## Conventions (the game code relies on these)

* **Units:** 1 Blender unit = 1 m. Every model stands on z = 0 and its root
  object's origin is at the bottom centre. For buildings and deposits the
  ground footprint is centred on the origin automatically. Units are centred on
  the hull. Env props have the trunk or base at the origin.
* **Facing:** the front of vehicles and buildings faces Blender **+Y**. The
  exporter uses `export_yup`, so +Y becomes Godot **-Z**, the engine's forward.
* **Style:** flat-shaded faceted low poly with a handful of named Principled
  materials (roughness about 0.8, metallic 0 except bare metal at 0.6). There are
  no textures or UVs. Foliage, cloth and grass materials are double-sided and
  everything else is back-face culled. Lamps, lit windows and the battle tank's
  glow strips are emissive (`EMISSIVE` in the script).
* **Finishing pass (units and buildings):** every hard edge gets a narrow bevel so
  it catches the light, and ambient occlusion is ray-traced into the `COLOR_0`
  vertex colours (crevices, undersides and the ground contact darken). Godot
  multiplies the albedo by it, the team colour material included. Tune it in
  `FINISH`.
* **Readability at play zoom:** the camera is orthographic, 30 degrees down, and a
  unit is 60-120 px tall. Hulls and walls are dark and saturated so they stand out
  from the sand, team colour goes on big surfaces seen from above (turret tops,
  roofs, awnings), and military structures stand on a dark concrete pad that shows
  the footprint. Check changes with `tests/screenshots/ArtGallery.tscn`, which lines
  up every unit and structure from `data/` in the game camera.
* **Team colour:** every unit and building has visible, mostly top-facing
  surfaces using the material named exactly `TeamColor`. Its base colour is the
  linear equivalent of sRGB (0.99, 0.81, 0.48), about (0.977, 0.620, 0.195). The
  game swaps it for the owner's colour.
* **Animated parts:** each one is a separate child object of the root, with its
  origin at the pivot:

  | model | object | motion |
  | --- | --- | --- |
  | tank_light, tank_heavy, aa_halftrack, defense_turret, defense_aa | `Turret` | yaw around local up |
  | oil_derrick | `Beam` (walking beam + horse head) | pitch around local X |
  | helicopter_attack | `Rotor`, `RotorTail` | main rotor: local up; tail rotor: local X |
  | helicopter_transport | `Rotor` (front), `Rotor2` (rear) | local up |
  | drone | `Rotor`, `Rotor2`, `Rotor3`, `Rotor4` | local up |

  The game spins every `Rotor*` object of an aircraft model (`RotorSpin.gd`); a
  turret's whole model turns, so turret bases are rotationally symmetric.

  Every rotor object's name starts with `Rotor`.
* **Polycount budgets (triangles, after bevelling):** env 50-600, units 300-9000,
  buildings 500-24000, deposits up to 1500. The build table flags anything outside them.
* **Scale guide:** units and buildings are built at their in-game size: tank
  1.5 m long, heavy and battle tanks about 1.85 m, trucks 1.3-1.6 m, command centre
  4 m square, factories 3.2 m, power plant 2.3 m, extractors 1.9 m, turrets 1.3 m,
  city buildings 2 m. In data, `model_scale` compensates the base scene's Geometry
  scale. Trees are 1.5-3.5 m tall, shrubs 0.3-0.6 m. Deposits are 2.5-3.5 m across and sit low.
  Each ore, oil and timber deposit has a smaller `_depleted` variant.

## Adding a model

1. Write a function that takes a `Model` and draws into `M.main` (a `Part`).
   For animated pieces, call `M.part("Name", origin=pivot)`.
2. Decorate it with `@register("<category>", "<name>")`. For seeded variants
   use `@register_many(category, [(name, kwargs), ...])`.
3. Use the primitives on `Part`: `box`, `cyl`, `cone`, `lathe`, `prism`,
   `extrude_x`/`extrude_y` (profile extrusions), `sweep` (tube along a path),
   `beam` (strut between two points), `ico` (noise-displaced rocks and foliage),
   `poly`/`strip` (thin sheets). Group with `with P.at(loc, rot):`.
   Coordinates are model-space metres and angles are degrees. `m=` takes a
   material name from `PALETTE` or a function `(face_centre, normal) -> name`;
   `by_normal(top, side, bottom)` covers the common case.
4. New colours go in `PALETTE` as (sRGB colour, roughness, metallic,
   double-sided).
5. Run `python3.11 tools/blender/build_assets.py --only <name>` and check the tile
   in `tools/blender/previews/<category>.png`.

## Starter city build-up animation

`build_construction.py` builds `assets/models/ironbound/construction/city_build_up.glb`,
the few seconds of construction shown when a match starts (played by
`source/match/city/CityBuildUp.gd`):

```sh
python3.11 tools/blender/build_construction.py            # about 5 seconds
python3.11 tools/blender/build_construction.py --preview  # plus previews/city_build_up.jpg
```

* The whole site is **one skinned mesh**: every moving piece (crane masts, jibs,
  trolleys, cables, hooks, the five command-centre stages, three scaffold lifts,
  six workers and their hammer arms, dust puffs) is a bone with rigid weights.
  It costs one mesh instance with one draw call per material, about 11k triangles,
  and it is freed when the animation ends. Pieces that are off stage are scaled to
  almost zero.
* The command-centre stages are cut by height from the same mesh `build_assets.py`
  exports (same bevel and baked AO), so the last frame matches `command_center.glb`
  and the game swaps the real model in without a jump. Rebuild this file after
  changing `command_center`.
* All timing lives in `construction_timeline.json`; `tools/audio/make_construction_sounds.py`
  reads the same file, so rebuild the sound after changing it.
* The animation is the glTF animation `build`; the root keeps the command centre's
  model space (front +Y, origin at the footprint centre).
