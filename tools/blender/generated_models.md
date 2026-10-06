# AI-generated faction models

Nine faction models had no art of their own (they borrowed another unit's or building's
model). On 2026-10-06 they were generated with Higgsfield and cleaned up for the game.
Total cost: 94.5 credits (9 x 1.5 for the concept images, 9 x 9 for the 3D models).

## Pipeline

1. **Concept image:** GPT Image 2.5 (`gpt_image_2_5`), quality high, 1:1, opaque background,
   one image per model. Every prompt starts with "Single isolated 3D game asset render for a
   modern realistic real-time strategy game:", describes the object in the Grounded palette
   (weathered, dusty, muted olive for the Foundry League, rust red and sand for the Sandline
   Syndicate), paints the team-colour surfaces **flat bright cobalt blue**, and ends with
   "Three-quarter view from the front-left, camera raised about 35 degrees, the whole
   [vehicle/structure] visible and centred, plain flat light grey background, soft even
   studio light, no cast shadow, no ground, no text, no people."
2. **3D model:** Tripo H3.1 image-to-3D (`tripo_h3_1_image_to_3d`), standard quality,
   `face_limit` 8000 (10000 for the foundry and the trading post). The raw GLB is about
   4 MB with colour, ORM and normal maps.
3. **Clean-up:** `tools/blender/clean_generated.py` turns the cobalt blue faces into the
   `TeamColor` material, keeps one 1024 px base-colour JPEG, turns and scales the model and
   (gunship) adds spinning rotor blades. Result: 7.4k to 9k triangles, 0.3 to 0.6 MB.
4. **Size in game:** `model_scale` in `data/units/<id>.json` from
   `tools/art/fit_model_scale.gd` (same length as the model it replaced, which stays as
   `classic_model` for Options > Unit models > Classic). Three were then
   set by eye: gunship 0.8, rocket technical 0.9, SAM site 0.7.

| Model | Faction | Subject (prompt core) | Clean-up flags |
| --- | --- | --- | --- |
| `units/battle_tank.glb` | Foundry | super-heavy MBT, long 140 mm gun, slat armour; turret and skirt plates blue | `--yaw 90` |
| `buildings/bunker.glb` | Foundry | round squat concrete bunker, firing slit, sandbags, olive gun cupola; cupola band blue | `--yaw 90` |
| `buildings/flak_tower.glb` | Foundry | short round concrete tower, twin flak cannons on a railed platform; gun shield blue | `--yaw 180` |
| `buildings/foundry.glb` | Foundry | steel foundry on a concrete pad, blast furnace, brick chimneys, molten metal; roof edges blue | `--yaw 180` |
| `units/rocket_technical.glb` | Syndicate | desert pickup with a 12-tube rocket pod; doors and pod sides blue | `--yaw 90` |
| `units/gunship.glb` | Syndicate | attack helicopter with stub wings and rocket pods, shown without rotor blades; wings and fin blue | `--yaw 90 --rotors` |
| `buildings/gun_nest.glb` | Syndicate | circular sandbag and scrap-steel nest, HMG behind a shield, canvas shade; shield blue | `--yaw 180` |
| `buildings/sam_site.glb` | Syndicate | turntable with four missile tubes on a sandbagged pad, radar dish; launcher sides blue | `--yaw 90` |
| `buildings/trading_post.glb` | Syndicate | adobe trade house, market stalls, crates, containers, loading crane; awnings blue | `--yaw 180` |

All were run with `--length 2`. Facing: vehicles and turret guns point along Blender +Y
(Godot -Z); buildings are turned so the side shown in the concept faces the game camera.

```sh
python3 tools/blender/clean_generated.py -- --in raw/gunship.glb \
    --out assets/models/ironbound/units/gunship.glb --yaw 90 --length 2 --rotors \
    --render /tmp/previews/gunship
```

The raw downloads and concept images are not in the repository (they are 4 MB each).
