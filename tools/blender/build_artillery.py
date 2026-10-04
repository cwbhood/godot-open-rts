"""Builds the Artillery: a 6x6 forward-control truck carrying a 48-tube rocket launcher box on
a hinged cradle, with hydraulic rams, side lockers, a fuel tank and team-coloured jerrycans,
cab roof and air-intake cap. Exports a GLB at in-game size (same GAME_SCALE as the raider).

    python3 tools/blender/build_artillery.py -- --out assets/models/ironbound/units/artillery.glb \
        [--render /tmp/previews]

Modelled in real metres (about 7.8 m long), facing +Y, then scaled by GAME_SCALE. Nodes:
- Body: chassis, cab, deck, turntable and the hinge brackets.
- Wheel_FL/FR, Wheel_ML/MR, Wheel_RL/RR: origins at the hubs, spin about X.
- Launcher: origin on the rear hinge pin, elevates about X. Built level (rotation 0 = stowed
  flat on the deck) and exported at LAUNCH_ELEVATION degrees, like the reference image.
- Ram_L/Ram_R: hydraulic rams, origin at the lower pivot, local +Y (Blender) along the ram,
  aimed at the launcher's ram lugs at the exported elevation. To keep them attached when the
  launcher moves, point each at Launcher's RamLug position (look_at) and stretch along Y by
  distance / RAM_LEN.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
from mesh_kit import (  # noqa: E402
    PALETTE, V, ellipsoid, export_glb, extrude_x, frame_from_dir, merge, parse_args, pipe,
    rbox, render_views, rot_xyz, set_origin, stats, torus, tube,
)

GAME_SCALE = 0.245
LAUNCH_ELEVATION = 22.0

PALETTE.update({
    "TeamColor": ((0.22, 0.42, 0.78), 0.6, 0.0),
    "Olive": ((0.37, 0.42, 0.19), 0.75, 0.0),
    "OliveDark": ((0.26, 0.30, 0.14), 0.8, 0.0),
    "OliveLight": ((0.45, 0.49, 0.26), 0.8, 0.0),
    "Rubber": ((0.09, 0.09, 0.09), 0.9, 0.0),
    "DarkMetal": ((0.13, 0.13, 0.14), 0.5, 0.6),
    "Steel": ((0.62, 0.63, 0.62), 0.3, 0.9),
    "Grille": ((0.07, 0.07, 0.07), 0.7, 0.2),
    "Glass": ((0.13, 0.20, 0.32), 0.12, 0.2),
    "Lamp": ((1.00, 0.93, 0.68), 0.4, 0.0, 1.2),
    "TailRed": ((0.85, 0.10, 0.08), 0.4, 0.0, 0.8),
    "TubeDark": ((0.04, 0.04, 0.04), 0.9, 0.0),
    "Crate": ((0.36, 0.38, 0.30), 0.8, 0.1),
})

WHEEL_R = 0.62
WHEEL_W = 0.48
TRACK = 1.06  # wheel centre x
AXLES = {"F": 2.45, "M": -1.05, "R": -2.5}
BODY_W = 2.5
DECK = 1.55  # top of the load deck
CAB = (1.45, 3.62)  # cab back and front face
CAB_FLOOR = 1.0
ROOF = 3.05
ARCH_R = WHEEL_R + 0.13
PIVOT = V((0.0, -3.05, 2.15))  # launcher hinge pin
BOX = {"y0": -0.4, "y1": 5.75, "z0": 0.15, "z1": 2.05, "w": 2.5}  # launcher, pivot-local
RAM_X = 0.72
RAM_BASE_Y, RAM_BASE_Z = -1.75, 1.95
RAM_LUG = 2.4  # pivot-local y of the lugs under the box


def bolt(c, m="OliveDark", s=0.045):
    rbox(c, (s, s, s), m, "body", bevel=0.3, segments=1)


def arch_profile(y0, y1, z0, z1, arches, front_slope=None):
    """Side profile from y0 (back) to y1 (front) between z0 and z1 with wheel arches cut out
    of the bottom edge. arches: wheel centre y values."""
    pts = [(y0, z0)]
    for y in sorted(arches):
        dz = z0 - WHEEL_R
        half = math.sqrt(max(ARCH_R ** 2 - dz ** 2, 0.0))
        lo = math.degrees(math.atan2(dz, half))
        for i in range(13):
            a = math.radians(180 - lo - (180 - 2 * lo) * i / 12)
            pts.append((y + math.cos(a) * ARCH_R, WHEEL_R + math.sin(a) * ARCH_R))
    pts.append((y1, z0))
    if front_slope:
        pts += front_slope
    else:
        pts.append((y1, z1))
    pts.append((y0, z1))
    return pts


# --------------------------------------------------------------------------
# Truck body
# --------------------------------------------------------------------------

def chassis():
    for sx in (-1, 1):
        rbox(V((sx * 0.5, -0.2, 1.12)), (0.16, 7.4, 0.3), "DarkMetal", "body", bevel=0.1)
    for y in (-3.6, -1.8, 0.0, 1.5):  # cross members
        rbox(V((0, y, 1.12)), (1.0, 0.14, 0.2), "DarkMetal", "body", bevel=0.1)
    for name, y in AXLES.items():
        tube(V((-TRACK + 0.15, y, WHEEL_R)), V((TRACK - 0.15, y, WHEEL_R)), 0.07, 0.07,
             "DarkMetal", "body", n=8, rings=1)
        ellipsoid(V((0.0, y, WHEEL_R)), (0.22, 0.2, 0.18), "DarkMetal", "body", seg=10, rings=6)
        for sx in (-1, 1):
            coil(V((sx * 0.72, y + (0.0 if name == "F" else 0.0), WHEEL_R + 0.08)), 0.11, 0.38)
    # propeller shafts
    tube(V((0, 1.6, 0.9)), V((0, AXLES["M"], WHEEL_R + 0.05)), 0.06, 0.06, "Steel", "body",
         n=8, rings=1)
    tube(V((0, AXLES["M"], WHEEL_R)), V((0, AXLES["R"], WHEEL_R)), 0.06, 0.06, "Steel", "body",
         n=8, rings=1)


def coil(base, r, h, turns=5):
    pts = []
    steps = turns * 8
    for i in range(steps + 1):
        a = 2 * math.pi * i / 8
        pts.append(base + V((math.cos(a) * r * 0.7, math.sin(a) * r, h * i / steps)))
    for a, b in zip(pts, pts[1:]):  # plain segments: joint spheres would cost ~10k tris
        tube(a, b, 0.022, 0.022, "Steel", "body", n=5, rings=1)
    tube(base, base + V((0, 0, h + 0.06)), 0.035, 0.035, "DarkMetal", "body", n=6, rings=1)


def cab():
    y0, y1 = CAB
    hw = BODY_W / 2
    front = [(y1, 2.15), (y1 - 0.2, ROOF - 0.08), (y1 - 0.3, ROOF)]
    prof = arch_profile(y0, y1, CAB_FLOOR, ROOF, [AXLES["F"]], front_slope=front)
    extrude_x(prof, -hw, hw, "Olive", "body", bevel=0.05)
    # fender lip around the front arch
    for sx in (-1, 1):
        torus(V((sx * (hw + 0.02), AXLES["F"], WHEEL_R)), ARCH_R + 0.04, 0.05, "OliveDark",
              "body", rot=rot_xyz(0, -90, 0), n=18, k=6, arc=(-100, 100))
    # team-coloured roof: two chamfered plates and a visor over the windshield
    rbox(V((0, (y0 + y1) / 2 - 0.15, ROOF + 0.09)), (BODY_W - 0.08, y1 - y0 - 0.25, 0.2),
         "TeamColor", "body", bevel=0.25, taper=0.92)
    rbox(V((0, y0 + 0.75, ROOF + 0.23)), (BODY_W - 0.5, 1.0, 0.1), "TeamColor", "body",
         bevel=0.3, taper=0.9)
    rbox(V((0, y1 - 0.28, ROOF + 0.06)), (BODY_W + 0.04, 0.35, 0.12), "TeamColor", "body",
         bevel=0.25, rot=rot_xyz(-8, 0, 0))
    # split windshield on the sloped front
    tilt = math.degrees(math.atan2(0.2, ROOF - 0.08 - 2.15))
    for sx in (-1, 1):
        rbox(V((sx * 0.57, y1 - 0.09, 2.6)), (1.0, 0.04, 0.7), "Glass", "body",
             rot=rot_xyz(tilt, 0, 0), bevel=0.2)
        rbox(V((sx * 0.57, y1 - 0.1, 2.6)), (1.1, 0.03, 0.8), "DarkMetal", "body",
             rot=rot_xyz(tilt, 0, 0), bevel=0.2)
    rbox(V((0, y1 - 0.085, 2.6)), (0.1, 0.06, 0.82), "Olive", "body", rot=rot_xyz(tilt, 0, 0),
         bevel=0.2)
    for sx in (-1, 1):
        x = sx * (hw + 0.01)
        # door window and rear quarter window, each in a dark gasket
        for wy0, wy1 in ((2.2, 3.15), (1.6, 2.05)):
            rbox(V((x, (wy0 + wy1) / 2, 2.55)), (0.03, wy1 - wy0 + 0.08, 0.68), "DarkMetal",
                 "body", bevel=0.2)
            rbox(V((x + sx * 0.012, (wy0 + wy1) / 2, 2.55)), (0.03, wy1 - wy0, 0.6), "Glass",
                 "body", bevel=0.2)
        # door outline, handle, hinges
        rbox(V((x, 2.65, 1.75)), (0.025, 1.12, 0.06), "OliveDark", "body", bevel=0.2)
        rbox(V((x, 2.1, 2.3)), (0.025, 0.05, 1.7), "OliveDark", "body", bevel=0.2)
        rbox(V((x + sx * 0.03, 2.3, 2.05)), (0.04, 0.2, 0.05), "DarkMetal", "body", bevel=0.3)
        for z in (1.95, 2.7):
            rbox(V((x + sx * 0.02, 3.17, z)), (0.04, 0.06, 0.14), "DarkMetal", "body", bevel=0.3)
        # mirror on an arm from the front corner
        mirror = V((sx * (hw + 0.32), y1 - 0.05, 2.65))
        pipe([V((sx * (hw - 0.02), y1 - 0.15, 2.3)), V((sx * (hw + 0.25), y1 - 0.1, 2.35)),
              mirror + V((0, 0, -0.2))], 0.025, "DarkMetal", "body", n=6)
        rbox(mirror, (0.08, 0.06, 0.38), "DarkMetal", "body", bevel=0.3)
        # boarding steps behind the front wheel
        for i, z in enumerate((0.55, 0.85)):
            rbox(V((sx * (hw - 0.12), y0 + 0.25, z)), (0.3, 0.36, 0.04), "DarkMetal", "body",
                 bevel=0.2)
        rbox(V((sx * (hw - 0.02), y0 + 0.25, 0.75)), (0.03, 0.36, 0.5), "OliveDark", "body",
             bevel=0.2)
        # side lockers on the cab's rear quarter
        rbox(V((sx * (hw + 0.1), y0 + 0.2, 1.65)), (0.22, 0.4, 0.45), "Olive", "body",
             bevel=0.12)
        rbox(V((sx * (hw + 0.22), y0 + 0.2, 1.75)), (0.02, 0.12, 0.08), "DarkMetal", "body",
             bevel=0.3)
        # vent slats on the cab front face corners
        for i in range(3):
            rbox(V((sx * 0.95, y1 + 0.01, 2.0 - i * 0.07)), (0.28, 0.03, 0.03), "Grille", "body",
                 bevel=0.2)
    # dashboard and seats through the glass
    rbox(V((0, y1 - 0.4, 2.15)), (2.2, 0.3, 0.15), "DarkMetal", "body", bevel=0.3)
    for sx in (-1, 1):
        rbox(V((sx * 0.6, y0 + 0.5, 2.25)), (0.5, 0.12, 0.6), "Crate", "body", bevel=0.3)


def cab_front():
    y1 = CAB[1]
    # headlamps in round bezels, grille slats, bumper with reflectors and tow eyes
    for sx in (-1, 1):
        tube(V((sx * 0.92, y1 - 0.02, 1.55)), V((sx * 0.92, y1 + 0.07, 1.55)), 0.15, 0.14,
             "OliveDark", "body", n=16, rings=1)
        ellipsoid(V((sx * 0.92, y1 + 0.07, 1.55)), (0.11, 0.035, 0.11), "Lamp", "body", seg=14,
                  rings=6)
    rbox(V((0, y1 + 0.02, 1.52)), (0.95, 0.04, 0.4), "OliveDark", "body", bevel=0.15)
    for i in range(9):
        rbox(V((-0.4 + i * 0.1, y1 + 0.045, 1.52)), (0.04, 0.03, 0.32), "Grille", "body",
             bevel=0.2)
    rbox(V((0, y1 + 0.02, 1.85)), (1.6, 0.025, 0.04), "OliveDark", "body", bevel=0.2)
    rbox(V((0, y1 + 0.12, 1.12)), (BODY_W + 0.1, 0.24, 0.28), "Olive", "body", bevel=0.15)
    for sx in (-1, 1):
        rbox(V((sx * 1.05, y1 + 0.245, 1.14)), (0.12, 0.02, 0.06), "TailRed", "body", bevel=0.2)
        torus(V((sx * 0.55, y1 + 0.28, 1.05)), 0.07, 0.022, "DarkMetal", "body",
              rot=rot_xyz(0, 90, 0), n=10, k=4)
        for x in (0.25, 0.45):
            rbox(V((sx * x, y1 + 0.245, 1.18)), (0.1, 0.02, 0.08), "OliveDark", "body",
                 bevel=0.2)
    # little bonnet hatch lines on the front face
    rbox(V((0, y1 + 0.005, 1.95)), (2.0, 0.02, 0.03), "OliveDark", "body", bevel=0.2)


def behind_cab():
    """Equipment housing between the cab and the deck, with the air intake (team cap)."""
    y0, y1 = 0.62, CAB[0] - 0.02
    rbox(V((0, (y0 + y1) / 2, 2.15)), (2.1, y1 - y0, 1.3), "Olive", "body", bevel=0.06)
    for sx in (-1, 1):
        for i in range(4):
            rbox(V((sx * 1.055, (y0 + y1) / 2 + 0.1, 2.5 - i * 0.09)), (0.03, 0.4, 0.04),
                 "Grille", "body", bevel=0.2)
        rbox(V((sx * 1.06, (y0 + y1) / 2 - 0.05, 1.95)), (0.02, 0.6, 0.45), "OliveDark", "body",
             bevel=0.15)
    # air intake snorkel with a team-coloured hood
    base = V((-0.75, CAB[0] + 0.12, ROOF + 0.05))
    tube(V((-0.75, CAB[0] - 0.1, 2.6)), base + V((0, -0.22, 0.45)), 0.08, 0.08, "OliveDark",
         "body", n=10, rings=1)
    rbox(base + V((0, -0.22, 0.58)), (0.22, 0.3, 0.26), "TeamColor", "body", bevel=0.3)
    rbox(base + V((0, -0.05, 0.6)), (0.18, 0.06, 0.16), "Grille", "body", bevel=0.3)
    # exhaust stack on the right
    tube(V((0.8, y0 + 0.1, 2.5)), V((0.8, y0 + 0.1, 3.1)), 0.07, 0.07, "DarkMetal", "body",
         n=10, rings=1)


def deck():
    y0, y1 = -3.85, 0.6
    hw = BODY_W / 2
    rbox(V((0, (y0 + y1) / 2, DECK - 0.12)), (BODY_W, y1 - y0, 0.24), "Olive", "body",
         bevel=0.12)
    # side beams with a step-down at the front, fender lips over the rear axles
    for sx in (-1, 1):
        rbox(V((sx * (hw + 0.02), (y0 + y1) / 2, DECK - 0.28)), (0.06, y1 - y0, 0.14),
             "OliveDark", "body", bevel=0.25)
        for y in (AXLES["M"], AXLES["R"]):
            torus(V((sx * (hw - 0.1), y, WHEEL_R)), ARCH_R, 0.05, "OliveDark", "body",
                  rot=rot_xyz(0, -90, 0), n=16, k=6, arc=(-75, 75))
            rbox(V((sx * (hw - 0.1), y, WHEEL_R + ARCH_R + 0.02)), (0.5, 1.15, 0.04), "Olive",
                 "body", bevel=0.25)
        # rear lights and mud flap
        rbox(V((sx * 1.05, y0 - 0.02, DECK - 0.15)), (0.16, 0.05, 0.12), "TailRed", "body",
             bevel=0.2)
        rbox(V((sx * 1.0, y0 + 0.15, 0.95)), (0.38, 0.03, 0.66), "Rubber", "body", bevel=0.1)
        for y in (-3.4, -2.2, -0.9, 0.2):
            bolt(V((sx * (hw + 0.05), y, DECK - 0.28)))
    rbox(V((0, y0 - 0.1, 1.15)), (BODY_W - 0.2, 0.18, 0.2), "OliveDark", "body", bevel=0.2)
    # turntable, ram pedestals and hinge brackets
    tube(V((0, -2.1, DECK)), V((0, -2.1, DECK + 0.2)), 0.95, 0.9, "OliveDark", "body", n=28,
         rings=1)
    rbox(V((0, -2.3, DECK + 0.32)), (1.7, 1.9, 0.3), "Olive", "body", bevel=0.12)
    for sx in (-1, 1):
        rbox(V((sx * RAM_X, RAM_BASE_Y, (DECK + RAM_BASE_Z) / 2 + 0.05)), (0.3, 0.4, 0.45),
             "Olive", "body", bevel=0.15)
        tube(V((sx * (RAM_X - 0.2), RAM_BASE_Y, RAM_BASE_Z)),
             V((sx * (RAM_X + 0.2), RAM_BASE_Y, RAM_BASE_Z)), 0.07, 0.07, "Steel", "body", n=10,
             rings=1)
        rbox(V((sx * 1.0, PIVOT.y, (DECK + PIVOT.z) / 2 + 0.1)), (0.16, 0.6, PIVOT.z - DECK + 0.3),
             "Olive", "body", bevel=0.15, taper=0.7)
        tube(V((sx * 0.9, PIVOT.y, PIVOT.z)), V((sx * 1.12, PIVOT.y, PIVOT.z)), 0.12, 0.12,
             "Steel", "body", n=12, rings=1)


def jerrycan(c, yaw=0.0, m="TeamColor"):
    r = rot_xyz(0, 0, yaw)
    rbox(c, (0.2, 0.42, 0.55), m, "body", rot=r, bevel=0.12)
    for dz in (0.12, -0.12):
        rbox(c + (r @ V((0, 0, dz)).to_4d()).to_3d(), (0.21, 0.34, 0.035), m, "body", rot=r,
             bevel=0.3)
    top = c + V((0, 0, 0.275))
    hp = [top + (r @ V((0, y, z)).to_4d()).to_3d()
          for y, z in ((-0.14, 0.0), (-0.12, 0.07), (0.02, 0.07), (0.04, 0.0))]
    pipe(hp, 0.016, m, "body", n=5)
    tube(top + (r @ V((0, 0.14, 0)).to_4d()).to_3d(),
         top + (r @ V((0, 0.14, 0.06)).to_4d()).to_3d(), 0.035, 0.035, "DarkMetal", "body",
         n=8, rings=1)
    rbox(c + (r @ V((0.105, 0, 0)).to_4d()).to_3d(), (0.02, 0.44, 0.05), "DarkMetal", "body",
         rot=r, bevel=0.3)  # strap


def locker(c, size, m="Olive"):
    rbox(c, size, m, "body", bevel=0.1)
    rbox(c + V((0, 0, size[2] / 2)), (size[0] + 0.03, size[1] + 0.03, 0.05), "OliveDark",
         "body", bevel=0.3)
    for sx in (-1, 1):
        rbox(c + V((size[0] / 2 + 0.01, sx * size[1] * 0.3, size[2] * 0.25)), (0.03, 0.08, 0.1),
             "DarkMetal", "body", bevel=0.3)


def stowage():
    hw = BODY_W / 2
    for sx in (-1, 1):
        # fuel tank and battery box hanging between the front and middle wheels
        tube(V((sx * 1.0, -0.2, 0.95)), V((sx * 1.0, 1.15, 0.95)), 0.27, 0.27, "Olive", "body",
             n=16, rings=1, flat=(0.9, 1.0))
        for y in (0.1, 0.85):
            torus(V((sx * 1.0, y, 0.95)), 0.27, 0.025, "DarkMetal", "body",
                  rot=rot_xyz(90, 0, 0), n=16, k=4, scale=(0.9, 1.0, 1.0))
        rbox(V((sx * 1.08, 1.32, 1.05)), (0.36, 0.22, 0.42), "OliveDark", "body", bevel=0.12)
        # deck lockers, crates and team-coloured jerrycans
        locker(V((sx * 0.85, 0.15, DECK + 0.3)), (0.7, 0.6, 0.6))
        jerrycan(V((sx * (hw - 0.12), -0.35, DECK + 0.29)))
        jerrycan(V((sx * (hw - 0.36), -0.35, DECK + 0.29)))
        locker(V((sx * 0.9, -3.55, DECK + 0.22)), (0.6, 0.5, 0.44))
    locker(V((0.1, -0.75, DECK + 0.2)), (0.5, 0.4, 0.4), "Crate")
    rbox(V((-0.35, -0.8, DECK + 0.12)), (0.35, 0.5, 0.24), "Crate", "body", bevel=0.15)
    locker(V((-0.35, -0.8, DECK + 0.39)), (0.32, 0.45, 0.3), "Olive")


# --------------------------------------------------------------------------
# Launcher, rams, wheels
# --------------------------------------------------------------------------

def L(x, y, z):
    """Pivot-local point of the launcher, built level."""
    return PIVOT + V((x, y, z))


def launcher():
    g = "launcher"
    y0, y1, z0, z1, w = BOX["y0"], BOX["y1"], BOX["z0"], BOX["z1"], BOX["w"]
    yc, zc, h = (y0 + y1) / 2, (z0 + z1) / 2, z1 - z0
    rbox(L(0, yc, zc), (w, y1 - y0, h), "Olive", g, bevel=0.03)
    # armour plates with seams on the sides and top, bolts and latches
    seg = [(y0 + 0.1, 1.4), (1.5, 2.85), (3.05, 4.35), (4.45, y1 - 0.45)]
    for sx in (-1, 1):
        for i, (a, b) in enumerate(seg):
            rows = [(z0 + 0.08, zc - 0.04), (zc + 0.04, z1 - 0.08)] if i % 2 == 0 else \
                [(z0 + 0.08, z1 - 0.08)]
            for c, d in rows:
                rbox(L(sx * (w / 2 + 0.02), (a + b) / 2, (c + d) / 2), (0.05, b - a, d - c),
                     "OliveLight" if (i + len(rows)) % 3 == 0 else "Olive", g, bevel=0.2)
                for yy in (a + 0.08, b - 0.08):
                    for zz in (c + 0.08, d - 0.08):
                        rbox(L(sx * (w / 2 + 0.05), yy, zz), (0.03, 0.05, 0.05), "OliveDark", g,
                             bevel=0.3, segments=1)
            # latch
            rbox(L(sx * (w / 2 + 0.06), (a + b) / 2, zc), (0.05, 0.16, 0.12), "DarkMetal", g,
                 bevel=0.25)
            rbox(L(sx * (w / 2 + 0.06), (a + b) / 2 + 0.25, zc + 0.35), (0.04, 0.2, 0.14),
                 "OliveDark", g, bevel=0.25)
    for a, b in seg:
        for sx in (-1, 1):
            rbox(L(sx * w / 4, (a + b) / 2, z1 + 0.02), (w / 2 - 0.1, b - a, 0.05), "Olive", g,
                 bevel=0.2)
        rbox(L(0.6, (a + b) / 2 + 0.2, z1 + 0.06), (0.25, 0.2, 0.05), "OliveDark", g, bevel=0.3)
    # reinforcing bands: rear, middle, front collar
    for yy, depth in ((y0 + 0.05, 0.2), (2.95, 0.18)):
        rbox(L(0, yy, zc), (w + 0.12, depth, h + 0.12), "OliveDark", g, bevel=0.15)
    # front collar framing the tube pack
    fw, fh, t = w + 0.14, h + 0.14, 0.17
    fy = y1 + 0.02
    rbox(L(0, fy, z1 + 0.07 - t / 2), (fw, 0.42, t), "Olive", g, bevel=0.15)
    rbox(L(0, fy, z0 - 0.07 + t / 2), (fw, 0.42, t), "Olive", g, bevel=0.15)
    for sx in (-1, 1):
        rbox(L(sx * (fw / 2 - t / 2), fy, zc), (t, 0.42, fh), "Olive", g, bevel=0.15)
        for zz in (z0 + 0.1, z1 - 0.1):
            rbox(L(sx * (fw / 2 + 0.01), fy - 0.1, zz), (0.04, 0.12, 0.12), "OliveDark", g,
                 bevel=0.3)
    # 8 x 6 rocket tubes, recessed behind the collar
    face = y1 + 0.1
    rbox(L(0, y1 - 0.02, zc), (fw - 2 * t + 0.02, 0.06, fh - 2 * t + 0.02), "OliveDark", g,
         bevel=0.0)
    for i in range(8):
        for j in range(6):
            x, z = (i - 3.5) * 0.275, zc + (j - 2.5) * 0.275
            tube(L(x, y1 - 0.02, z), L(x, face, z), 0.125, 0.125, "OliveDark", g, n=12, rings=1)
            torus(L(x, face, z), 0.105, 0.025, "OliveDark", g, rot=rot_xyz(90, 0, 0), n=12, k=3)
            tube(L(x, face - 0.01, z), L(x, face + 0.004, z), 0.095, 0.095, "TubeDark", g,
                 n=12, rings=1)
    # rear cap and cable conduits
    rbox(L(0, y0 - 0.05, zc), (w - 0.3, 0.06, h - 0.3), "OliveDark", g, bevel=0.2)
    for sx in (-1, 1):
        pipe([L(sx * 0.5, y0 - 0.08, z0 + 0.4), L(sx * 0.5, y0 - 0.2, z0 + 0.1),
              L(sx * 0.4, 0.2, -0.05)], 0.03, "DarkMetal", g, n=6)
    # cradle beams, hinge eye and ram lugs underneath
    for sx in (-1, 1):
        rbox(L(sx * 0.65, 2.0, z0 - 0.06), (0.18, 4.6, 0.14), "OliveDark", g, bevel=0.15)
        rbox(L(sx * RAM_X, RAM_LUG, z0 - 0.1), (0.24, 0.3, 0.18), "OliveDark", g, bevel=0.2)
    tube(L(-0.88, 0, 0), L(0.88, 0, 0), 0.15, 0.15, "OliveDark", g, n=14, rings=1)
    rbox(L(0, 0.12, z0 / 2), (1.5, 0.3, 0.2), "OliveDark", g, bevel=0.15)


def elevation_matrix():
    return (Matrix.Translation(PIVOT) @ rot_xyz(LAUNCH_ELEVATION, 0, 0)
            @ Matrix.Translation(-PIVOT))


RAM_LEN = 0.0


def rams():
    """Each ram is built along its own axis from the deck pivot to the launcher lug."""
    global RAM_LEN
    em = elevation_matrix()
    ends = {}
    for sx, tag in ((-1, "L"), (1, "R")):
        g = f"Ram_{tag}"
        p0 = V((sx * RAM_X, RAM_BASE_Y, RAM_BASE_Z))
        p1 = em @ L(sx * RAM_X, RAM_LUG, BOX["z0"] - 0.17)
        d = p1 - p0
        RAM_LEN = d.length
        u = d.normalized()
        tube(p0 - u * 0.05, p0 + u * RAM_LEN * 0.55, 0.11, 0.11, "Olive", g, n=14, rings=1)
        tube(p0 + u * RAM_LEN * 0.5, p0 + u * RAM_LEN * 0.56, 0.13, 0.13, "OliveDark", g,
             n=14, rings=1)
        tube(p0 + u * RAM_LEN * 0.55, p1, 0.06, 0.06, "Steel", g, n=12, rings=1)
        for p in (p0, p1):  # clevis eyes across X
            tube(p - V((0.08, 0, 0)), p + V((0.08, 0, 0)), 0.09, 0.09, "DarkMetal", g, n=10,
                 rings=1)
        tube(p0 + u * 0.15, p0 + u * 0.15 + V((sx * 0.14, 0, 0.05)), 0.025, 0.025, "DarkMetal",
             g, n=6, rings=1)  # hydraulic hose stub
        ends[g] = (p0, u)
    return ends


def wheel(group, centre, side):
    rot = rot_xyz(0, 90, 0)
    torus(centre, WHEEL_R - 0.2, 0.2, "Rubber", group, rot=rot, n=28, k=10,
          scale=(1.0, 1.0, WHEEL_W / 0.4))
    # chevron tread: two staggered rows of slanted lugs
    for i in range(20):
        for row in (-1, 1):
            a = 2 * math.pi * (i + (0.5 if row > 0 else 0)) / 20
            p = centre + V((row * WHEEL_W * 0.2, math.cos(a) * (WHEEL_R - 0.005),
                            math.sin(a) * (WHEEL_R - 0.005)))
            rbox(p, (WHEEL_W * 0.42, 0.12, 0.06), "Rubber", group,
                 rot=rot_xyz(math.degrees(a) - 90, 0, 0) @ rot_xyz(0, 0, row * 18), bevel=0.25,
                 segments=1)
    # olive disc rim with a raised hub ring and eight wheel nuts
    out = V((side * WHEEL_W * 0.3, 0, 0))
    tube(centre - out * 0.6, centre + out, 0.36, 0.34, "Olive", group, n=20, rings=1)
    torus(centre + out * 1.02, 0.3, 0.025, "OliveDark", group, rot=rot, n=20, k=4)
    tube(centre + out, centre + out * 1.3, 0.17, 0.15, "Olive", group, n=14, rings=1)
    for i in range(8):
        a = 2 * math.pi * i / 8
        p = centre + out * 1.3 + V((0, math.cos(a) * 0.11, math.sin(a) * 0.11))
        tube(p, p + out * 0.18, 0.022, 0.022, "OliveDark", group, n=6, rings=1)
    tube(centre + out * 1.3, centre + out * 1.5, 0.07, 0.05, "OliveDark", group, n=10, rings=1)


def main():
    args = parse_args({"out": "assets/models/ironbound/units/artillery.glb", "render": None})
    bpy.ops.wm.read_factory_settings(use_empty=True)
    chassis()
    cab()
    cab_front()
    behind_cab()
    deck()
    stowage()
    launcher()
    ram_ends = rams()
    hubs = {}
    for axle, y in AXLES.items():
        for side, tag in ((-1, "L"), (1, "R")):
            name = f"Wheel_{axle}{tag}"
            hubs[name] = V((side * TRACK, y, WHEEL_R))
            wheel(name, hubs[name], side)
    objects = []
    body, _ = merge("Body", groups={"body"})
    objects.append(body)
    launch, _ = merge("Launcher", groups={"launcher"})
    set_origin(launch, PIVOT)
    launch.parent = body
    objects.append(launch)
    for name, (p0, u) in ram_ends.items():
        ob, _ = merge(name, groups={name})
        # origin at the lower pivot, local +Y along the ram
        frame = frame_from_dir(u, up=(0, 0, 1)) if abs(u.x) < 0.99 else Matrix.Identity(4)
        ob.data.transform(Matrix.Translation(-p0))
        ob.data.transform(frame.inverted())
        ob.matrix_world = Matrix.Translation(p0) @ frame
        ob.parent = body
        objects.append(ob)
    for name, hub in hubs.items():
        ob, _ = merge(name, groups={name})
        set_origin(ob, hub)
        ob.parent = body
        objects.append(ob)
    # lug marker so the game can re-aim the rams (empty child of the launcher)
    for sx, tag in ((-1, "L"), (1, "R")):
        e = bpy.data.objects.new(f"RamLug_{tag}", None)
        bpy.context.scene.collection.objects.link(e)
        e.location = V((sx * RAM_X, RAM_LUG, BOX["z0"] - 0.17))
        e.parent = launch
        objects.append(e)
    # scale to game size, then raise the launcher to its exported elevation
    scale = Matrix.Scale(GAME_SCALE, 4)
    for ob in objects:
        if ob.type == "MESH":
            ob.data.transform(scale)
        ob.location = ob.location * GAME_SCALE
    launch.rotation_euler = (math.radians(LAUNCH_ELEVATION), 0, 0)
    out = export_glb(args["out"])
    verts, tris = stats(objects)
    print(f"exported {out}: {verts} verts, {tris} tris, {len(objects)} nodes, "
          f"ram length {RAM_LEN * GAME_SCALE:.3f}")
    if args["render"]:
        wide = (1100, 750)
        render_views(args["render"], [
            ("three_quarter", 50, 18, 3.1, wide), ("side", 90, 0, 3.0, wide),
            ("front", 0, 10, 3.0, wide), ("back", 215, 25, 3.3, wide),
            ("game_angle", 35, 50, 3.1, (800, 800)),
        ], target=(0, 0, 0.75))


main()
