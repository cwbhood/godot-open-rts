"""Builds the Raider: a lifted, rusty pickup "technical" with a roll cage, a pintle-mounted
machine gun on a ring mount, jerrycans, a rolled tarp and rope in the bed, and team-coloured
doors. Exports a GLB at in-game size (about 1.1 m long, like raider_technical.glb).

    python3 tools/blender/build_raider.py -- --out assets/models/ironbound/units/raider.glb \
        [--render /tmp/previews]

Modelled in real metres (4.5 m long), facing +Y, then scaled by GAME_SCALE. The four wheels
(Wheel_FL, Wheel_FR, Wheel_RL, Wheel_RR, origins at the hubs, spin about X) and the gun
(Gun, origin at the pintle, turns about Z) are separate nodes so the game can animate them.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
from mesh_kit import (  # noqa: E402
    PALETTE, V, ellipsoid, export_glb, extrude_x, merge, parse_args, pipe,
    rbox, render_views, rot_xyz, set_origin, stats, torus, tube,
)

GAME_SCALE = 0.245

PALETTE.update({
    "TeamColor": ((0.22, 0.42, 0.78), 0.6, 0.0),
    "BodyRed": ((0.64, 0.22, 0.16), 0.8, 0.0),
    "BodyRust": ((0.44, 0.25, 0.16), 0.9, 0.0),
    "Mud": ((0.40, 0.31, 0.21), 0.95, 0.0),
    "Rubber": ((0.08, 0.08, 0.08), 0.9, 0.0),
    "Rim": ((0.32, 0.32, 0.33), 0.45, 0.6),
    "DarkMetal": ((0.12, 0.12, 0.13), 0.5, 0.6),
    "Gunmetal": ((0.20, 0.21, 0.22), 0.45, 0.6),
    "Grille": ((0.06, 0.06, 0.06), 0.7, 0.2),
    "Glass": ((0.10, 0.12, 0.14), 0.15, 0.2),
    "Lamp": ((1.00, 0.92, 0.65), 0.4, 0.0, 1.2),
    "Amber": ((0.95, 0.60, 0.10), 0.4, 0.0, 0.6),
    "Jerry": ((0.30, 0.38, 0.20), 0.7, 0.0),
    "Brass": ((0.80, 0.65, 0.20), 0.4, 0.5),
    "Canvas": ((0.66, 0.58, 0.42), 0.95, 0.0),
    "Rope": ((0.62, 0.50, 0.34), 0.95, 0.0),
    "AmmoBox": ((0.33, 0.37, 0.22), 0.7, 0.0),
    "Toolbox": ((0.36, 0.30, 0.22), 0.8, 0.1),
})

WHEEL_R = 0.45
WHEEL_W = 0.34
TRACK = 0.84  # wheel centre x
AXLES = {"F": 1.38, "R": -1.38}
BODY_W = 1.74
SILL = 0.7  # bottom of the body panels
DECK = 1.12  # top of the lower body / bed floor
BELT = 1.45  # bed rails, door tops, hood line at the cowl
ROOF = 1.97
CAB = (-0.22, 0.95)  # cab back and front (windshield base)
BED = (-2.15, -0.26)
GUN_PIVOT = V((0.0, -1.3, 2.12))


def arch_profile():
    """Side profile of the lower body with both wheel arches cut out."""
    r = WHEEL_R + 0.11
    pts = [(-2.2, SILL)]
    for y in (AXLES["R"], AXLES["F"]):
        lo = math.degrees(math.asin(min(1.0, (SILL - WHEEL_R) / r)))
        for i in range(11):
            a = math.radians(180 - lo - (180 - 2 * lo) * i / 10)
            pts.append((y + math.cos(a) * r, WHEEL_R + math.sin(a) * r))
    pts += [(2.22, SILL), (2.24, DECK - 0.03), (2.2, DECK), (-2.2, DECK)]
    return pts


def lower_body():
    extrude_x(arch_profile(), -BODY_W / 2, BODY_W / 2, "BodyRust", "body", bevel=0.03)
    # fender flares over all four arches
    for y in AXLES.values():
        for sx in (-1, 1):
            torus(V((sx * (BODY_W / 2 + 0.01), y, WHEEL_R)), WHEEL_R + 0.12, 0.045, "Mud",
                  "body", rot=rot_xyz(0, -90, 0), n=16, k=6, arc=(-62, 62))
    # frame rails, axles, differentials and springs under the body
    for sx in (-1, 1):
        rbox(V((sx * 0.42, 0, 0.72)), (0.1, 4.0, 0.16), "DarkMetal", "body", bevel=0.1)
    for name, y in AXLES.items():
        tube(V((-TRACK + 0.12, y, WHEEL_R)), V((TRACK - 0.12, y, WHEEL_R)), 0.05, 0.05,
             "DarkMetal", "body", n=8, rings=1)
        ellipsoid(V((0.08, y, WHEEL_R)), (0.16, 0.14, 0.13), "DarkMetal", "body", seg=10,
                  rings=6)
        for sx in (-1, 1):
            if name == "F":
                coil(V((sx * 0.56, y + 0.12, WHEEL_R + 0.04)), 0.09, 0.42)
                tube(V((sx * 0.56, y + 0.12, WHEEL_R)), V((sx * 0.56, y + 0.12, 0.92)), 0.03,
                     0.03, "Gunmetal", "body", n=6, rings=1)
            else:
                rbox(V((sx * 0.5, y, 0.6)), (0.08, 1.1, 0.06), "DarkMetal", "body",
                     bevel=0.2)  # leaf spring
    # running gear seen from behind: spare-wheel-less rear with tow hitch
    rbox(V((0, -2.25, 0.72)), (0.12, 0.2, 0.08), "DarkMetal", "body", bevel=0.2)


def coil(base, r, h, turns=6):
    pts = []
    steps = turns * 8
    for i in range(steps + 1):
        a = 2 * math.pi * i / 8
        pts.append(base + V((math.cos(a) * r * 0.6, math.sin(a) * r, h * i / steps)))
    pipe(pts, 0.016, "Gunmetal", "body", n=5)


def cab():
    y0, y1 = CAB
    # lower cab between the bed and the cowl; doors are separate team-coloured panels
    rbox(V((0, (y0 + y1) / 2, (DECK + BELT) / 2)), (BODY_W - 0.02, y1 - y0, BELT - DECK),
         "BodyRed", "body", bevel=0.06)
    # greenhouse: windshield slopes back from the cowl
    prof = [(y0, BELT), (y1, BELT), (y1 - 0.42, ROOF), (y0 + 0.04, ROOF)]
    extrude_x(prof, -0.78, 0.78, "BodyRed", "body", bevel=0.035)
    rbox(V((0, (y0 + y1 - 0.38) / 2, ROOF + 0.01)), (1.5, y1 - y0 - 0.5, 0.04), "BodyRust",
         "body", bevel=0.3)  # sun-baked roof skin
    # glass: windshield, rear window, door windows
    ws_c = V((0, y1 - 0.21 + 0.012, (BELT + ROOF) / 2 + 0.01))
    rbox(ws_c + V((0, 0.006, 0)), (1.36, 0.02, 0.5), "Glass", "body",
         rot=rot_xyz(math.degrees(math.atan2(0.42, ROOF - BELT)), 0, 0), bevel=0.0)
    rbox(V((0, y0 - 0.008, (BELT + ROOF) / 2 + 0.03)), (1.2, 0.02, 0.32), "Glass", "body",
         bevel=0.0)
    for sx in (-1, 1):
        x = sx * 0.785
        side = [(y0 + 0.1, BELT + 0.05), (y1 - 0.08, BELT + 0.05), (y1 - 0.4, ROOF - 0.07),
                (y0 + 0.12, ROOF - 0.07)]
        extrude_x(side, x - 0.012, x + 0.012, "Glass", "body")
        # door panel, handle, mirror
        door = V((sx * (BODY_W / 2 + 0.008), (y0 + y1) / 2 + 0.03, (SILL + BELT) / 2 + 0.06))
        rbox(door, (0.03, y1 - y0 - 0.08, BELT - SILL - 0.1), "TeamColor", "body", bevel=0.25)
        rbox(door + V((sx * 0.02, -0.28, 0.12)), (0.025, 0.14, 0.035), "DarkMetal", "body",
             bevel=0.3)
        mirror = V((sx * (BODY_W / 2 + 0.12), y1 - 0.05, BELT + 0.12))
        rbox(mirror, (0.04, 0.12, 0.16), "DarkMetal", "body", bevel=0.25)
        pipe([V((sx * (BODY_W / 2 - 0.02), y1 - 0.05, BELT + 0.02)), mirror], 0.012,
             "DarkMetal", "body", n=5)
    # dashboard glimpse and seats through the glass
    rbox(V((0, y1 - 0.1, BELT + 0.04)), (1.4, 0.18, 0.1), "DarkMetal", "body", bevel=0.3)
    rbox(V((0, y0 + 0.2, BELT + 0.18)), (1.3, 0.14, 0.38), "Toolbox", "body", bevel=0.3)


def hood_and_front():
    y0, y1 = CAB[1], 2.18
    rbox(V((0, (y0 + y1) / 2, (DECK + 1.4) / 2)), (BODY_W - 0.02, y1 - y0, 1.4 - DECK + 0.02),
         "BodyRed", "body", bevel=0.08, taper=0.98)
    for sx in (-1, 1):
        rbox(V((sx * 0.22, y0 + 0.28, 1.4)), (0.22, 0.1, 0.02), "Grille", "body", bevel=0.0)
    rbox(V((0, 1.62, 1.405)), (0.9, 0.9, 0.02), "BodyRust", "body", bevel=0.4)  # hood scuff
    # grille, lamps, indicators
    rbox(V((0, y1 + 0.01, 1.22)), (1.1, 0.05, 0.24), "Grille", "body", bevel=0.15)
    for sx in (-1, 1):
        tube(V((sx * 0.68, y1 - 0.01, 1.24)), V((sx * 0.68, y1 + 0.04, 1.24)), 0.09, 0.085,
             "Gunmetal", "body", n=12, rings=1)
        ellipsoid(V((sx * 0.68, y1 + 0.04, 1.24)), (0.075, 0.025, 0.075), "Lamp", "body",
                  seg=12, rings=6)
        rbox(V((sx * 0.68, y1 + 0.02, 1.09)), (0.14, 0.04, 0.05), "Amber", "body", bevel=0.2)
    # bumper and bull bar
    rbox(V((0, y1 + 0.1, 0.98)), (BODY_W + 0.06, 0.16, 0.18), "BodyRust", "body", bevel=0.2)
    yb = y1 + 0.24
    for sx in (-1, 1):
        pipe([V((sx * 0.62, y1 + 0.12, 0.92)), V((sx * 0.62, yb, 1.0)), V((sx * 0.6, yb, 1.38)),
              V((sx * 0.46, yb - 0.04, 1.46)), V((sx * 0.46, y1 + 0.05, 1.38))], 0.035,
             "DarkMetal", "body", n=8)
        pipe([V((sx * 0.8, y1 + 0.12, 0.98)), V((sx * 0.8, yb - 0.02, 1.04)),
              V((sx * 0.62, yb, 1.1))], 0.03, "DarkMetal", "body", n=8)
    pipe([V((-0.62, yb, 1.18)), V((0.62, yb, 1.18))], 0.03, "DarkMetal", "body", n=8)
    pipe([V((-0.62, yb, 1.32)), V((0.62, yb, 1.32))], 0.03, "DarkMetal", "body", n=8)
    for sx in (-1, 1):
        pipe([V((sx * 0.25, yb, 1.18)), V((sx * 0.25, yb, 1.32))], 0.025, "DarkMetal", "body",
             n=6)


def bed():
    y0, y1 = BED
    h = BELT - DECK
    for sx in (-1, 1):
        rbox(V((sx * (BODY_W / 2 - 0.025), (y0 + y1) / 2, DECK + h / 2)), (0.05, y1 - y0, h),
             "BodyRed", "body", bevel=0.2)
        rbox(V((sx * (BODY_W / 2 - 0.02), (y0 + y1) / 2, BELT + 0.012)), (0.08, y1 - y0, 0.03),
             "BodyRust", "body", bevel=0.25)  # rail cap
        for y in (y0 + 0.25, (y0 + y1) / 2, y1 - 0.25):  # stake pockets / tie-down hooks
            rbox(V((sx * (BODY_W / 2 + 0.01), y, BELT - 0.06)), (0.03, 0.05, 0.08), "DarkMetal",
                 "body", bevel=0.2)
        # tail lights
        rbox(V((sx * 0.74, y0 - 0.03, DECK + 0.16)), (0.14, 0.04, 0.2), "Amber", "body",
             bevel=0.2)
    rbox(V((0, y0 + 0.02, DECK + h / 2)), (BODY_W - 0.04, 0.05, h), "BodyRed", "body",
         bevel=0.2)  # tailgate
    rbox(V((0, y0 - 0.005, DECK + h * 0.55)), (BODY_W * 0.8, 0.02, h * 0.45), "BodyRust",
         "body", bevel=0.2)
    rbox(V((0, y1 - 0.02, DECK + h / 2)), (BODY_W - 0.04, 0.05, h), "BodyRed", "body",
         bevel=0.2)  # bulkhead
    rbox(V((0, (y0 + y1) / 2, DECK + 0.005)), (BODY_W - 0.1, y1 - y0 - 0.1, 0.02), "Mud",
         "body", bevel=0.0)  # dirty floor


def roll_cage():
    hoop_y, front_y, z = BED[1] - 0.06, 0.62, ROOF + 0.14
    w = 0.74
    pipe([V((-w, hoop_y, BELT)), V((-w, hoop_y, z)), V((w, hoop_y, z)), V((w, hoop_y, BELT))],
         0.035, "DarkMetal", "body", n=8)
    for sx in (-1, 1):
        # rails forward over the cab roof, braces back down to the bed rails
        pipe([V((sx * w, hoop_y, z)), V((sx * w, front_y, z)), V((sx * 0.7, front_y, ROOF))],
             0.035, "DarkMetal", "body", n=8)
        pipe([V((sx * w, hoop_y, z - 0.05)), V((sx * w, hoop_y - 0.6, BELT))], 0.03,
             "DarkMetal", "body", n=8)
    pipe([V((-w, front_y, z)), V((w, front_y, z))], 0.035, "DarkMetal", "body", n=8)
    pipe([V((-w, (hoop_y + front_y) / 2, z)), V((w, (hoop_y + front_y) / 2, z))], 0.03,
         "DarkMetal", "body", n=8)


def gun_mount():
    p = GUN_PIVOT
    # pedestal and ring (part of the body)
    tube(V((p.x, p.y, DECK)), V((p.x, p.y, p.z - 0.18)), 0.07, 0.06, "DarkMetal", "body", n=10,
         rings=1)
    rbox(V((p.x, p.y, DECK + 0.03)), (0.34, 0.34, 0.06), "DarkMetal", "body", bevel=0.3)
    ring_z = p.z - 0.36
    torus(V((p.x, p.y, ring_z)), 0.38, 0.03, "DarkMetal", "body", n=28, k=6)
    for a in (0, 120, 240):
        d = V((math.cos(math.radians(a)), math.sin(math.radians(a)), 0))
        pipe([V((p.x, p.y, ring_z)) + d * 0.06, V((p.x, p.y, ring_z)) + d * 0.37], 0.018,
             "DarkMetal", "body", n=6)
    # the gun (its own node): cradle, receiver, ribbed barrel jacket, spade grips, ammo can
    tube(V((p.x, p.y, p.z - 0.18)), V((p.x, p.y, p.z - 0.04)), 0.045, 0.045, "Gunmetal", "gun",
         n=10, rings=1)
    rbox(p + V((0, 0, 0.0)), (0.14, 0.2, 0.12), "Gunmetal", "gun", bevel=0.2)  # cradle
    recv = p + V((0, -0.05, 0.12))
    rbox(recv, (0.13, 0.6, 0.16), "DarkMetal", "gun", bevel=0.15)
    rbox(recv + V((0, 0.05, 0.1)), (0.11, 0.36, 0.04), "DarkMetal", "gun", bevel=0.25)  # cover
    tube(recv + V((0, 0.3, 0.0)), recv + V((0, 1.05, 0.0)), 0.035, 0.035, "DarkMetal", "gun",
         n=10, rings=1)
    tube(recv + V((0, 0.3, 0.0)), recv + V((0, 0.62, 0.0)), 0.05, 0.05, "Gunmetal", "gun",
         n=10, rings=1)
    for i in range(9):
        torus(recv + V((0, 0.33 + i * 0.033, 0.0)), 0.05, 0.012, "DarkMetal", "gun",
              rot=rot_xyz(90, 0, 0), n=12, k=4)
    tube(recv + V((0, 1.02, 0.0)), recv + V((0, 1.12, 0.0)), 0.05, 0.05, "Gunmetal", "gun",
         n=10, rings=1)  # muzzle brake
    rbox(recv + V((0, 0.95, 0.07)), (0.02, 0.03, 0.1), "DarkMetal", "gun", bevel=0.2)  # sight
    rbox(recv + V((0, 0.1, 0.13)), (0.02, 0.05, 0.08), "DarkMetal", "gun", bevel=0.2)
    for sx in (-1, 1):  # spade grips
        pipe([recv + V((sx * 0.04, -0.3, 0.0)), recv + V((sx * 0.1, -0.42, -0.02)),
              recv + V((sx * 0.1, -0.42, -0.14))], 0.022, "DarkMetal", "gun", n=6)
    rbox(recv + V((0, -0.22, -0.12)), (0.06, 0.08, 0.1), "DarkMetal", "gun", bevel=0.2)
    can = recv + V((-0.2, 0.06, -0.04))
    rbox(can, (0.22, 0.32, 0.22), "AmmoBox", "gun", bevel=0.12)
    rbox(can + V((0, 0, 0.12)), (0.24, 0.34, 0.03), "AmmoBox", "gun", bevel=0.2)
    pipe([can + V((0.02, -0.06, 0.14)), can + V((0.02, -0.06, 0.18)),
          can + V((0.02, 0.06, 0.18)), can + V((0.02, 0.06, 0.14))], 0.012, "DarkMetal", "gun",
         n=5)
    pipe([can + V((0.11, 0.0, 0.08)), recv + V((-0.07, 0.04, 0.02))], 0.025, "Brass", "gun",
         n=6)  # ammo belt


def jerrycan(c, yaw=0.0):
    r = rot_xyz(0, 0, yaw)
    rbox(c, (0.17, 0.35, 0.46), "Jerry", "body", rot=r, bevel=0.12)
    for dz in (0.1, -0.1):  # pressed ribs
        rbox(c + (r @ V((0, 0, dz)).to_4d()).to_3d(), (0.18, 0.28, 0.03), "Jerry", "body",
             rot=r, bevel=0.3)
    top = c + V((0, 0, 0.23))
    hp = [top + (r @ V((0, y, z)).to_4d()).to_3d()
          for y, z in ((-0.12, 0.0), (-0.1, 0.06), (0.02, 0.06), (0.04, 0.0))]
    pipe(hp, 0.014, "Jerry", "body", n=5)
    tube(top + (r @ V((0, 0.12, 0)).to_4d()).to_3d(),
         top + (r @ V((0, 0.12, 0.05)).to_4d()).to_3d(), 0.03, 0.03, "Brass", "body", n=8,
         rings=1)


def cargo():
    z = DECK + 0.23
    for x, y, yaw in ((-0.6, -1.95, 0), (-0.4, -1.95, 0), (-0.6, -1.55, 0),
                      (0.62, -0.55, 90), (0.62, -0.75, 90), (-0.62, -0.5, 0)):
        jerrycan(V((x, y, z)), yaw)
    # rolled tarp across the bed and a coil of rope
    tube(V((-0.05, -1.75, DECK + 0.14)), V((0.72, -1.75, DECK + 0.14)), 0.14, 0.14, "Canvas",
         "body", n=12, rings=2, bulge=0.01)
    for sx in (0.12, 0.55):
        torus(V((sx, -1.75, DECK + 0.14)), 0.145, 0.012, "Rope", "body",
              rot=rot_xyz(0, 90, 0), n=14, k=4)
    for i in range(3):
        torus(V((0.42, -1.25, DECK + 0.03 + i * 0.045)), 0.2 - i * 0.012, 0.025, "Rope", "body",
              n=18, k=5)
    rbox(V((-0.2, -0.55, DECK + 0.13)), (0.5, 0.3, 0.26), "Toolbox", "body", bevel=0.1)


def wheel(group, centre, side):
    rot = rot_xyz(0, 90, 0)
    torus(centre, WHEEL_R - 0.15, 0.15, "Rubber", group, rot=rot, n=24, k=10,
          scale=(1.0, 1.0, WHEEL_W / 0.3))
    # chunky tread lugs in two staggered rows
    for i in range(18):
        for row in (-1, 1):
            a = 2 * math.pi * (i + (0.5 if row > 0 else 0)) / 18
            p = centre + V((row * WHEEL_W * 0.22, math.cos(a) * (WHEEL_R - 0.005),
                            math.sin(a) * (WHEEL_R - 0.005)))
            rbox(p, (WHEEL_W * 0.4, 0.09, 0.05), "Rubber", group,
                 rot=rot_xyz(math.degrees(a) - 90, 0, 0), bevel=0.25)
    # rim: dish, five spokes, hub
    out = V((side * WHEEL_W * 0.32, 0, 0))
    tube(centre - out * 0.6, centre + out, 0.26, 0.24, "Rim", group, n=16, rings=1)
    for i in range(5):
        a = 2 * math.pi * i / 5
        d = V((0, math.cos(a), math.sin(a)))
        rbox(centre + out * 1.02 + d * 0.13, (0.03, 0.06, 0.2), "Rim", group,
             rot=rot_xyz(math.degrees(a) - 90, 0, 0), bevel=0.3)
    tube(centre + out, centre + out * 1.25, 0.07, 0.05, "Gunmetal", group, n=10, rings=1)


def main():
    args = parse_args({"out": "assets/models/ironbound/units/raider.glb", "render": None})
    bpy.ops.wm.read_factory_settings(use_empty=True)
    lower_body()
    cab()
    hood_and_front()
    bed()
    roll_cage()
    gun_mount()
    cargo()
    hubs = {}
    for axle, y in AXLES.items():
        for side, tag in ((-1, "L"), (1, "R")):
            name = f"Wheel_{axle}{tag}"
            hubs[name] = V((side * TRACK, y, WHEEL_R))
            wheel(name, hubs[name], side)
    objects = []
    body, _ = merge("Body", groups={"body"})
    objects.append(body)
    gun, _ = merge("Gun", groups={"gun"})
    set_origin(gun, GUN_PIVOT)
    gun.parent = body
    objects.append(gun)
    for name, hub in hubs.items():
        ob, _ = merge(name, groups={name})
        set_origin(ob, hub)
        ob.parent = body
        objects.append(ob)
    # scale everything to game size around the ground point under the centre
    scale = Matrix.Scale(GAME_SCALE, 4)
    for ob in objects:
        ob.data.transform(scale)
        ob.location = ob.location * GAME_SCALE
    out = export_glb(args["out"])
    verts, tris = stats(objects)
    print(f"exported {out}: {verts} verts, {tris} tris, {len(objects)} nodes")
    if args["render"]:
        wide = (1100, 750)
        render_views(args["render"], [
            ("three_quarter", 55, 25, 1.6, wide), ("side", 90, 0, 1.4, wide),
            ("front", 0, 10, 1.4, wide), ("back", 200, 25, 1.6, wide),
            ("game_angle", 35, 50, 1.6, (800, 800)),
        ], target=(0, 0, 0.3))


main()
