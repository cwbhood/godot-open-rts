"""Builds the freight train: a hood-unit diesel locomotive, an open hopper wagon whose load
is a separate "Cargo" node the game fills and tints, the loading gantry that stands over
the track at every train stop and the station platform at the depot. Exports four GLBs at
in-game size.

    python3 tools/blender/build_train.py -- --out assets/models/ironbound/units \
        [--render /tmp/previews]

Modelled in real metres (the locomotive is 15 m long), facing +Y, then scaled by GAME_SCALE.
Standard gauge track: rails 1.435 m apart (RailVisuals.gd draws them to the same scale).
The locomotive has an "Exhaust" empty at the top of its stack and a "Headlight" empty on the
nose for the game's smoke and light.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
from mathutils import Matrix  # noqa: E402
from mesh_kit import (  # noqa: E402
    GAME, PALETTE, PARTS, V, ellipsoid, export_glb, merge, parse_args, pipe, rbox,
    render_views, rot_xyz, stats, tube,
)

GAME_SCALE = 0.22
GAUGE = 1.435

PALETTE.update({
    "TeamColor": ((0.22, 0.42, 0.78), 0.55, 0.0),
    "Hood": ((0.33, 0.35, 0.36), 0.7, 0.1),
    "HoodDark": ((0.22, 0.23, 0.24), 0.75, 0.1),
    "Frame": ((0.12, 0.12, 0.13), 0.7, 0.3),
    "Wheel": ((0.18, 0.17, 0.16), 0.5, 0.6),
    "Steel": ((0.45, 0.46, 0.47), 0.45, 0.6),
    "Glass": ((0.08, 0.11, 0.14), 0.2, 0.0),
    "Hazard": ((0.95, 0.72, 0.12), 0.6, 0.0),
    "HazardDark": ((0.10, 0.10, 0.10), 0.6, 0.0),
    "Rust": ((0.45, 0.27, 0.16), 0.85, 0.1),
    "RustDark": ((0.30, 0.18, 0.11), 0.85, 0.1),
    "Hollow": ((0.07, 0.06, 0.05), 0.9, 0.0),
    "Cargo": ((0.85, 0.85, 0.85), 0.9, 0.0),
    "Concrete": ((0.62, 0.60, 0.56), 0.9, 0.0),
    "Lamp": ((1.0, 0.92, 0.7), 0.3, 0.0, 4.0),
    "Rubber": ((0.07, 0.07, 0.07), 0.9, 0.0),
})


# --------------------------------------------------------------------------
# Shared running gear
# --------------------------------------------------------------------------

def bogie(y, group, wheel_r=0.48, axles=(-0.95, 0.95)):
    """A two-axle bogie centred at y: side frames, springs and four wheels."""
    half = GAUGE / 2
    for sx in (-1, 1):
        x = sx * (half + 0.12)
        for a in axles:
            tube(V((x - 0.09, y + a, wheel_r)), V((x + 0.09, y + a, wheel_r)), wheel_r, wheel_r,
                 "Wheel", group, n=14)
            tube(V((x + sx * 0.08, y + a, wheel_r)), V((x + sx * 0.12, y + a, wheel_r)), 0.18,
                 0.18, "Steel", group, n=8)
        rbox(V((x + sx * 0.18, y, wheel_r + 0.08)), (0.16, 2.9, 0.42), "Frame", group)
        rbox(V((x + sx * 0.2, y, wheel_r + 0.38)), (0.2, 0.7, 0.3), "HoodDark", group)
    rbox(V((0, y, wheel_r + 0.42)), (GAUGE + 0.3, 0.9, 0.3), "Frame", group)


def coupler(y, sign, group):
    tube(V((0, y, 1.0)), V((0, y + sign * 0.55, 1.0)), 0.1, 0.1, "Frame", group, n=8)
    rbox(V((0, y + sign * 0.6, 1.0)), (0.36, 0.2, 0.28), "Frame", group)


# --------------------------------------------------------------------------
# Locomotive
# --------------------------------------------------------------------------

LOCO_LEN = 15.0
DECK_Z = 1.45
HOOD_W = 2.3
CAB = (2.6, 5.4)  # y range of the cab


def locomotive():
    g = "loco"
    half = LOCO_LEN / 2
    # deck and fuel tank
    rbox(V((0, 0, DECK_Z - 0.18)), (3.0, LOCO_LEN, 0.36), "Frame", g, bevel=0.05)
    rbox(V((0, -0.4, DECK_Z - 0.75)), (2.2, 5.0, 0.8), "HoodDark", g)
    # hazard stripes on the deck ends
    for sy in (-1, 1):
        rbox(V((0, sy * (half - 0.12), DECK_Z - 0.18)), (3.02, 0.26, 0.38), "Hazard", g,
             bevel=0.02)
        for i in range(-3, 4):
            rbox(V((i * 0.42, sy * (half - 0.11), DECK_Z - 0.18)), (0.16, 0.28, 0.4),
                 "HazardDark", g, bevel=0.0, rot=rot_xyz(y=35))
    for y in (-4.6, 4.6):
        bogie(y, g)
    coupler(-half, -1, g)
    coupler(half, 1, g)
    # long hood behind the cab, with a team-coloured band along it
    hood_top = DECK_Z + 2.35
    rbox(V((0, (-half + 0.5 + CAB[0]) / 2, DECK_Z + 1.17)),
         (HOOD_W, CAB[0] - (-half + 0.5), 2.34), "Hood", g, bevel=0.08)
    band_z = DECK_Z + 1.55
    for sx in (-1, 1):
        rbox(V((sx * (HOOD_W / 2 + 0.01), (-half + 0.5 + CAB[0]) / 2, band_z)),
             (0.04, CAB[0] - (-half + 0.5) - 0.1, 0.42), "TeamColor", g, bevel=0.0)
        # access doors and louvres
        for i in range(5):
            y = -half + 1.3 + i * 1.75
            rbox(V((sx * (HOOD_W / 2 + 0.015), y, DECK_Z + 0.7)), (0.03, 1.4, 0.95),
                 "HoodDark", g, bevel=0.0)
    # radiator grille and fans at the back of the hood
    rbox(V((0, -half + 1.6, hood_top + 0.05)), (1.9, 2.2, 0.12), "HoodDark", g)
    for y in (-half + 1.1, -half + 2.1):
        tube(V((0, y, hood_top + 0.08)), V((0, y, hood_top + 0.16)), 0.55, 0.55, "Frame", g,
             n=16)
    # exhaust stack and dynamic brake blister
    tube(V((0, -0.6, hood_top)), V((0, -0.6, hood_top + 0.45)), 0.2, 0.18, "Frame", g, n=10)
    rbox(V((0, 0.9, hood_top + 0.12)), (1.6, 1.8, 0.24), "Hood", g)
    # cab
    cab_top = DECK_Z + 3.0
    rbox(V((0, (CAB[0] + CAB[1]) / 2, DECK_Z + 1.5)), (2.9, CAB[1] - CAB[0], 3.0), "Hood", g,
         bevel=0.06)
    rbox(V((0, (CAB[0] + CAB[1]) / 2, cab_top + 0.08)), (3.0, CAB[1] - CAB[0] + 0.2, 0.18),
         "TeamColor", g, bevel=0.1)
    # cab windows: front pair, side pair each side
    for sx in (-1, 1):
        rbox(V((sx * 0.62, CAB[1] + 0.01, DECK_Z + 2.25)), (0.95, 0.04, 0.85), "Glass", g,
             bevel=0.0)
        rbox(V((sx * 1.46, (CAB[0] + CAB[1]) / 2 + 0.35, DECK_Z + 2.25)), (0.04, 1.5, 0.8),
             "Glass", g, bevel=0.0)
        rbox(V((sx * 1.46, (CAB[0] + CAB[1]) / 2 + 0.35, DECK_Z + 1.55)), (0.04, 1.5, 0.08),
             "TeamColor", g, bevel=0.0)
    # short nose with the headlight and number boards
    nose_y0, nose_y1 = CAB[1], half - 0.45
    rbox(V((0, (nose_y0 + nose_y1) / 2, DECK_Z + 0.85)), (2.2, nose_y1 - nose_y0, 1.7), "Hood",
         g, bevel=0.1, taper=0.9)
    rbox(V((0, nose_y1 + 0.01, DECK_Z + 1.05)), (1.6, 0.04, 0.5), "TeamColor", g, bevel=0.0)
    tube(V((0, nose_y1, DECK_Z + 1.5)), V((0, nose_y1 + 0.12, DECK_Z + 1.5)), 0.2, 0.2, "Lamp",
         g, n=10)
    for sx in (-1, 1):
        tube(V((sx * 1.1, half - 0.05, DECK_Z - 0.2)), V((sx * 1.1, half + 0.08, DECK_Z - 0.2)),
             0.12, 0.12, "Lamp", g, n=8)
    # handrails along the walkways
    for sx in (-1, 1):
        x = sx * 1.42
        posts = [V((x, -half + 0.6 + i * 1.6, DECK_Z)) for i in range(6)]
        for p in posts:
            tube(p, p + V((0, 0, 0.9)), 0.035, 0.035, "Hazard", g, n=6)
        pipe([posts[0] + V((0, 0, 0.9)), posts[-1] + V((0, 0, 0.9))], 0.035, "Hazard", g, n=6)
    # steps at the four corners
    for sx in (-1, 1):
        for sy in (-1, 1):
            rbox(V((sx * 1.3, sy * (half - 0.6), DECK_Z - 0.7)), (0.5, 0.6, 0.06), "Frame", g,
                 bevel=0.0)
    return V((0, -0.6, hood_top + 0.5)), V((0, nose_y1 + 0.3, DECK_Z + 1.5))


# --------------------------------------------------------------------------
# Hopper wagon
# --------------------------------------------------------------------------

WAGON_LEN = 11.0


def wagon():
    g = "wagon"
    half = WAGON_LEN / 2
    rbox(V((0, 0, 1.3)), (2.8, WAGON_LEN, 0.3), "Frame", g, bevel=0.05)
    for y in (-3.4, 3.4):
        bogie(y, g, wheel_r=0.46)
    coupler(-half, -1, g)
    coupler(half, 1, g)
    # the hopper: wider at the top, ribbed sides, a team-coloured band along the top
    top = 4.0
    rbox(V((0, 0, 2.7)), (2.6, WAGON_LEN - 0.9, 2.6), "Rust", g, bevel=0.03, taper=1.12)
    for sx in (-1, 1):
        for i in range(7):
            y = -half + 1.0 + i * (WAGON_LEN - 2.0) / 6
            rbox(V((sx * 1.42, y, 2.7)), (0.1, 0.16, 2.5), "RustDark", g, bevel=0.0,
                 rot=rot_xyz(y=sx * -3.5))
        rbox(V((sx * 1.47, 0, top - 0.25)), (0.06, WAGON_LEN - 1.0, 0.36), "TeamColor", g,
             bevel=0.0)
    rbox(V((0, 0, top - 0.04)), (2.6, WAGON_LEN - 1.15, 0.06), "Hollow", g, bevel=0.0)
    # discharge chutes under the hopper
    for y in (-1.6, 0.0, 1.6):
        rbox(V((0, y, 1.0)), (1.1, 0.9, 0.5), "RustDark", g, taper=1.5)
    # load: a long mound, its own node so the game can fill and colour it
    ellipsoid(V((0, 0, top - 0.05)), (1.15, half - 0.75, 0.75), "Cargo", "cargo", seg=16,
              rings=8, cut=0.0)


# --------------------------------------------------------------------------
# Loading gantry
# --------------------------------------------------------------------------

def loader():
    g = "loader"
    span = 4.6
    # concrete footings and steel legs either side of the track
    for sx in (-1, 1):
        for sy in (-1, 1):
            p = V((sx * span / 2, sy * 1.6, 0))
            rbox(p + V((0, 0, 0.2)), (0.8, 0.8, 0.4), "Concrete", g)
            tube(p + V((0, 0, 0.4)), p + V((0, 0, 6.0)), 0.16, 0.16, "Hazard", g, n=8)
        # cross bracing on each side frame
        pipe([V((sx * span / 2, -1.6, 0.5)), V((sx * span / 2, 1.6, 5.8))], 0.07, "Hazard", g)
        pipe([V((sx * span / 2, 1.6, 0.5)), V((sx * span / 2, -1.6, 5.8))], 0.07, "Hazard", g)
    # deck girders and the hopper bin over the track
    for sy in (-1, 1):
        rbox(V((0, sy * 1.6, 6.1)), (span + 0.6, 0.3, 0.45), "Frame", g)
    rbox(V((0, 0, 7.6)), (2.8, 2.8, 2.6), "Steel", g, taper=1.0)
    rbox(V((0, 0, 6.0)), (1.4, 1.4, 1.0), "Steel", g, taper=2.0)
    rbox(V((0, 0, 9.0)), (3.0, 3.0, 0.25), "TeamColor", g, bevel=0.05)
    tube(V((0, 0, 5.5)), V((0, 0, 4.6)), 0.38, 0.3, "Frame", g, n=10)
    # conveyor running up to the bin from the side the source stands on
    conv0 = V((span / 2 + 4.5, 0, 0.6))
    conv1 = V((1.4, 0, 8.6))
    tube(conv0, conv1, 0.42, 0.42, "HoodDark", g, n=4, roll=45)
    rbox(conv0 + V((0, 0, -0.2)), (1.2, 1.2, 0.8), "Concrete", g)
    rbox(V((0, 0, 9.4)), (0.6, 0.6, 0.6), "Lamp", g)


# --------------------------------------------------------------------------
# Station platform (at the depot)
# --------------------------------------------------------------------------

def station():
    g = "station"
    x = 2.9  # platform centre, beside the track
    rbox(V((x, 0, 0.55)), (2.6, 16.0, 1.1), "Concrete", g, bevel=0.03)
    rbox(V((x - 1.25, 0, 1.08)), (0.25, 16.0, 0.06), "Hazard", g, bevel=0.0)
    for y in (-6.0, -2.0, 2.0, 6.0):
        tube(V((x + 0.5, y, 1.1)), V((x + 0.5, y, 4.4)), 0.12, 0.12, "Frame", g, n=8)
    rbox(V((x, 0, 4.5)), (3.4, 14.0, 0.22), "TeamColor", g, bevel=0.1, rot=rot_xyz(y=-6))
    # a small office at the far end of the platform and crates waiting for the train
    rbox(V((x + 0.3, -6.6, 2.2)), (1.8, 2.4, 2.2), "Hood", g, bevel=0.05)
    rbox(V((x - 0.62, -6.6, 2.4)), (0.04, 1.4, 0.7), "Glass", g, bevel=0.0)
    for y, h in ((3.5, 0.7), (4.4, 0.5), (-1.5, 0.6)):
        rbox(V((x + 0.6, y, 1.1 + h / 2)), (0.8, 0.8, h), "RustDark", g, bevel=0.05)
    # buffer stop at the end of the track
    rbox(V((0, -8.6, 0.7)), (2.2, 0.5, 1.0), "Frame", g)
    rbox(V((0, -8.3, 1.0)), (2.4, 0.2, 0.35), "Hazard", g, bevel=0.0)


def preview_sheet(render_dir, names, out):
    try:
        from PIL import Image
    except ImportError:
        return
    ims = [Image.open(os.path.join(render_dir, f"{n}.png")).convert("RGB") for n in names]
    w, h = ims[0].size
    sheet = Image.new("RGB", (w * len(ims), h), (235, 235, 235))
    for i, im in enumerate(ims):
        sheet.paste(im, (i * w, 0))
    sheet.save(out)


def finish(objects):
    scale = Matrix.Scale(GAME_SCALE, 4)
    for ob in objects:
        if ob.type == "MESH":
            ob.data.transform(scale)
        ob.location = ob.location * GAME_SCALE


def build(kind, out_dir, render_dir):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    PARTS.clear()
    GAME["drop_size"] = 0.12
    GAME["max_tris"] = 3500
    objects = []
    if kind == "train_locomotive":
        exhaust, headlight = locomotive()
        body, _ = merge("Locomotive")
        objects.append(body)
        for name, at in (("Exhaust", exhaust), ("Headlight", headlight)):
            empty = bpy.data.objects.new(name, None)
            bpy.context.scene.collection.objects.link(empty)
            empty.location = at
            empty.parent = body
            objects.append(empty)
    elif kind == "train_wagon":
        wagon()
        body, _ = merge("Wagon", groups={"wagon"})
        cargo, _ = merge("Cargo", groups={"cargo"})
        cargo.parent = body
        objects += [body, cargo]
    elif kind == "train_station":
        station()
        body, _ = merge("Station")
        objects.append(body)
    else:
        loader()
        body, _ = merge("Loader")
        objects.append(body)
    finish(objects)
    out = export_glb(os.path.join(out_dir, f"{kind}.glb"))
    verts, tris = stats([o for o in objects if o.type == "MESH"])
    print(f"exported {out}: {verts} verts, {tris} tris")
    if render_dir:
        sub = os.path.join(render_dir, kind)
        size = 4.0
        render_views(sub, [
            ("three_quarter", 300, 28, size, (900, 600)), ("side", 270, 0, size, (900, 600)),
            ("game_angle", 325, 50, size, (600, 600)),
        ], target=(0, 0, 0.4))
        preview_sheet(sub, ["three_quarter", "side", "game_angle"],
                      os.path.join(render_dir, f"{kind}-preview.png"))


def main():
    args = parse_args({"out": "assets/models/ironbound/units", "render": None,
                       "only": "train_locomotive,train_wagon,train_loader,train_station"})
    for kind in args["only"].split(","):
        build(kind, args["out"], args["render"])


main()
