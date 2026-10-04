"""Builds the Scout Buggy: an open desert buggy with a full tube roll cage, a wedge nose with a
team-coloured hood plate, fat low-pressure balloon tyres, two bucket seats, jerrycans and ammo
boxes on the rear deck, and a post-mounted machine gun. Exports a GLB at in-game size.

    python3 tools/blender/build_scout_buggy.py -- \
        --out assets/models/ironbound/units/scout_buggy_v2.glb [--render /tmp/previews]

Modelled in real metres (about 4 m long), facing +Y, then scaled by GAME_SCALE (the raider's).
The four wheels (Wheel_FL, Wheel_FR, Wheel_RL, Wheel_RR, origins at the hubs, spin about X)
and the gun (Gun, origin at the top of its post, turns about Z) are separate nodes so the game
can animate them.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
import bmesh  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
from mesh_kit import (  # noqa: E402
    GAME, PALETTE, V, add, ellipsoid, export_glb, merge, parse_args, pipe, rbox, render_views,
    rot_xyz, set_origin, stats, torus, tube,
)

GAME_SCALE = 0.245

PALETTE.update({
    "TeamColor": ((0.22, 0.42, 0.78), 0.6, 0.0),
    "Olive": ((0.43, 0.40, 0.27), 0.85, 0.0),
    "OliveDust": ((0.52, 0.48, 0.36), 0.95, 0.0),
    "Steel": ((0.44, 0.44, 0.44), 0.45, 0.7),
    "DarkMetal": ((0.12, 0.12, 0.13), 0.5, 0.6),
    "Gunmetal": ((0.20, 0.21, 0.22), 0.45, 0.6),
    "Grille": ((0.06, 0.06, 0.06), 0.7, 0.2),
    "Tyre": ((0.62, 0.57, 0.45), 0.95, 0.0),
    "Rim": ((0.10, 0.10, 0.11), 0.6, 0.4),
    "Seat": ((0.11, 0.11, 0.12), 0.8, 0.0),
    "Strap": ((0.55, 0.47, 0.33), 0.9, 0.0),
    "Lamp": ((1.00, 0.95, 0.80), 0.4, 0.0, 1.5),
    "Jerry": ((0.34, 0.35, 0.21), 0.7, 0.0),
    "AmmoBox": ((0.36, 0.37, 0.24), 0.7, 0.0),
    "Brass": ((0.80, 0.65, 0.20), 0.4, 0.5),
})

WHEEL_R = 0.53
TYRE_W = 0.5
TRACK = 1.0  # wheel centre x
AXLES = {"F": 1.3, "R": -1.35}
SIDE = 0.66  # half width of the tub
FLOOR = 0.5
SILL = 0.98  # top of the side panels / door bars
COWL = (-0.15, 1.25)  # y, z where the hood meets the cockpit
NOSE = (1.75, 0.98)  # y, z at the front edge of the hood
HOOP_Y = -0.95
ROOF = 1.95
TAIL = -2.0
DECK = 0.78
GUN_PIVOT = V((0.42, -1.12, 2.3))


def hull(points, m, group, smooth=False):
    """Convex hull of a point cloud: angular armour panels and wedges."""
    bm = bmesh.new()
    for p in points:
        bm.verts.new(p)
    res = bmesh.ops.convex_hull(bm, input=bm.verts[:])
    junk = [g for g in res["geom_interior"] + res["geom_unused"] if isinstance(g, bmesh.types.BMVert)]
    if junk:
        bmesh.ops.delete(bm, geom=junk, context="VERTS")
    return add(bm, m, group, smooth)


def sym(points):
    """Mirrors (x, y, z) points across x = 0."""
    out = []
    for x, y, z in points:
        out += [V((x, y, z)), V((-x, y, z))]
    return out


def hood_z(y):
    t = (y - COWL[0]) / (NOSE[0] - COWL[0])
    return COWL[1] + (NOSE[1] - COWL[1]) * t


# --------------------------------------------------------------------------
# Tub, nose and hood
# --------------------------------------------------------------------------

def nose():
    # wedge from the cowl to the nose; the underside rakes up and in like a skid plate
    hull(sym([(SIDE, COWL[0], COWL[1]), (SIDE - 0.04, COWL[0], FLOOR + 0.02),
              (0.52, NOSE[0], NOSE[1]), (0.46, NOSE[0] + 0.2, NOSE[1] - 0.16),
              (0.36, NOSE[0] + 0.05, FLOOR + 0.12), (0.5, 0.9, FLOOR)]), "Olive", "body")
    # team-coloured armour plate on the hood, with a raised centre scoop
    y0, y1 = 0.25, NOSE[0] - 0.02
    plate = []
    for x, y in ((0.3, y0), (0.5, y0 + 0.3), (0.47, y1 - 0.15), (0.3, y1)):
        for dz in (-0.01, 0.03):
            plate += sym([(x, y, hood_z(y) + dz)])
    hull(plate, "TeamColor", "body")
    scoop = []
    for x, y, h in ((0.14, y0 + 0.15, 0.06), (0.24, 0.8, 0.1), (0.2, y1 - 0.3, 0.07),
                    (0.1, y1 - 0.1, 0.035)):
        scoop += sym([(x, y, hood_z(y) + 0.02), (x * 0.7, y, hood_z(y) + 0.02 + h)])
    hull(scoop, "TeamColor", "body")
    # vents fore and aft of the plate, bolt heads around it
    for y, w in ((0.12, 0.34), (y1 - 0.12, 0.3)):
        slope = math.degrees(math.atan2(COWL[1] - NOSE[1], NOSE[0] - COWL[0]))
        rbox(V((0, y, hood_z(y) + 0.035)), (w, 0.09, 0.02), "Grille", "body",
             rot=rot_xyz(slope, 0, 0), bevel=0.2)
        for i in range(5):
            rbox(V((0, y - 0.03 + i * 0.015, hood_z(y) + 0.047)), (w * 0.9, 0.006, 0.006),
                 "DarkMetal", "body", rot=rot_xyz(slope, 0, 0), bevel=0.0)
    for x, y in ((0.27, y0 + 0.04), (0.47, y0 + 0.32), (0.44, y1 - 0.17), (0.27, y1 - 0.03),
                 (0.47, 0.95)):
        for sx in (-1, 1):
            ellipsoid(V((sx * x, y, hood_z(y) + 0.035)), (0.016, 0.016, 0.01), "Steel",
                      "body", seg=6, rings=4)
    # side access panels on the nose
    for sx in (-1, 1):
        rbox(V((sx * (SIDE - 0.03), 0.55, 0.98)), (0.02, 0.5, 0.14), "OliveDust", "body",
             rot=rot_xyz(0, 0, sx * -5), bevel=0.2)
    # square work lamps on stalks at the nose corners
    for sx in (-1, 1):
        base = V((sx * 0.56, NOSE[0] - 0.05, NOSE[1] - 0.06))
        tube(base, base + V((0, 0, 0.12)), 0.018, 0.018, "DarkMetal", "body", n=6, rings=1)
        lamp = base + V((0, 0.02, 0.18))
        rbox(lamp, (0.13, 0.08, 0.12), "DarkMetal", "body", bevel=0.15)
        rbox(lamp + V((0, 0.042, 0)), (0.1, 0.01, 0.09), "Lamp", "body", bevel=0.0)


def tub():
    # cockpit side skins below the door bars and the floor pan
    y0, y1 = TAIL + 0.35, COWL[0]
    for sx in (-1, 1):
        rbox(V((sx * SIDE, (y0 + y1) / 2, (FLOOR + SILL) / 2 - 0.05)),
             (0.03, y1 - y0, SILL - FLOOR - 0.12), "Olive", "body", bevel=0.2)
        rbox(V((sx * (SIDE + 0.012), (y0 + y1) / 2 - 0.2, 0.72)), (0.01, 0.7, 0.2), "OliveDust",
             "body", bevel=0.2)
        for y in (y0 + 0.08, (y0 + y1) / 2, y1 - 0.08):  # bolt heads
            ellipsoid(V((sx * (SIDE + 0.018), y, SILL - 0.1)), (0.01, 0.015, 0.015), "Steel",
                      "body", seg=6, rings=4)
    rbox(V((0, (TAIL + COWL[0]) / 2 + 0.2, FLOOR)), (2 * SIDE, COWL[0] - TAIL - 0.4, 0.04),
         "DarkMetal", "body", bevel=0.2)
    # rear deck with a low olive box round the engine
    rbox(V((0, (TAIL + HOOP_Y) / 2, DECK - 0.02)), (2 * SIDE - 0.04, HOOP_Y - TAIL, 0.04),
         "Olive", "body", bevel=0.2)
    hull(sym([(SIDE - 0.05, TAIL + 0.1, DECK - 0.02), (SIDE - 0.05, HOOP_Y, DECK - 0.02),
              (0.4, TAIL + 0.15, FLOOR + 0.05), (0.4, HOOP_Y, FLOOR + 0.05)]), "DarkMetal",
         "body")
    for sx in (-1, 1):  # rear quarter panels
        hull([V((sx * SIDE, HOOP_Y + 0.05, SILL - 0.05)), V((sx * SIDE, HOOP_Y + 0.05, FLOOR)),
              V((sx * SIDE, TAIL + 0.35, DECK)), V((sx * (SIDE - 0.03), HOOP_Y + 0.05, FLOOR)),
              V((sx * (SIDE - 0.03), HOOP_Y + 0.05, SILL - 0.05)),
              V((sx * (SIDE - 0.03), TAIL + 0.35, DECK))], "Olive", "body")


def chassis():
    # lower frame rails nose to tail and the suspension: A-arms, uprights and coil-overs
    for sx in (-1, 1):
        x = sx * (SIDE - 0.02)
        pipe([V((sx * 0.4, NOSE[0] + 0.05, FLOOR + 0.1)), V((x, 1.0, FLOOR)),
              V((x, TAIL + 0.3, FLOOR)), V((sx * 0.5, TAIL, FLOOR + 0.12))], 0.035, "Steel",
             "body", n=8)
    for y in AXLES.values():
        for sx in (-1, 1):
            hub = V((sx * (TRACK - 0.2), y, WHEEL_R))
            for dz, r in ((-0.1, 0.028), (0.12, 0.024)):
                inner = sx * 0.42
                pipe([V((inner, y - 0.18, WHEEL_R + dz)), hub + V((0, 0, dz)),
                      V((inner, y + 0.18, WHEEL_R + dz))], r, "DarkMetal", "body", n=6)
            tube(hub + V((0, 0, -0.16)), hub + V((0, 0, 0.18)), 0.04, 0.04, "DarkMetal", "body",
                 n=8, rings=1)
            tube(hub, V((sx * 0.08, y, WHEEL_R + 0.05)), 0.025, 0.025, "Gunmetal", "body", n=6,
                 rings=1)  # half shaft
            top = V((sx * 0.48, y + 0.05, SILL + 0.15))
            low = hub + V((-sx * 0.12, 0.05, -0.05))
            tube(low, top, 0.045, 0.045, "Gunmetal", "body", n=8, rings=1)
            d = (top - low)
            coil_pts = []
            for i in range(41):
                a = 2 * math.pi * i / 8
                side = d.orthogonal().normalized()
                other = d.normalized().cross(side)
                coil_pts.append(low + d * (0.15 + 0.6 * i / 40) +
                                side * math.cos(a) * 0.075 + other * math.sin(a) * 0.075)
            pipe(coil_pts, 0.013, "Grille", "body", n=5)
    # tow eye and exhaust at the back
    rbox(V((0, TAIL - 0.05, FLOOR + 0.12)), (0.14, 0.12, 0.08), "DarkMetal", "body", bevel=0.2)
    pipe([V((-0.3, TAIL + 0.3, FLOOR + 0.2)), V((-0.3, TAIL - 0.05, FLOOR + 0.25)),
          V((-0.3, TAIL - 0.1, FLOOR + 0.35))], 0.04, "DarkMetal", "body", n=8)


# --------------------------------------------------------------------------
# Roll cage
# --------------------------------------------------------------------------

def roll_cage():
    r = 0.035
    w_top = 0.56
    front_y = COWL[0] - 0.12
    # main hoop behind the seats with a diagonal brace
    pipe([V((-SIDE, HOOP_Y, FLOOR)), V((-SIDE, HOOP_Y, SILL + 0.3)), V((-w_top, HOOP_Y, ROOF)),
          V((w_top, HOOP_Y, ROOF)), V((SIDE, HOOP_Y, SILL + 0.3)), V((SIDE, HOOP_Y, FLOOR))],
         r, "Steel", "body", n=8)
    pipe([V((-SIDE + 0.02, HOOP_Y, SILL)), V((w_top - 0.02, HOOP_Y, ROOF - 0.03))], r * 0.85,
         "Steel", "body", n=8)
    pipe([V((-SIDE + 0.02, HOOP_Y, SILL)), V((SIDE - 0.02, HOOP_Y, SILL))], r * 0.85, "Steel",
         "body", n=8)
    for sx in (-1, 1):
        # A-pillars from the cowl up to the roof and on back to the hoop
        pipe([V((sx * SIDE, COWL[0] + 0.25, COWL[1] - 0.02)), V((sx * w_top, front_y, ROOF)),
              V((sx * w_top, HOOP_Y, ROOF))], r, "Steel", "body", n=8)
        # door bars and a gusset brace from the pillar down to the nose
        pipe([V((sx * (SIDE + 0.02), COWL[0] + 0.05, SILL)),
              V((sx * (SIDE + 0.02), HOOP_Y, SILL))], r, "Steel", "body", n=8)
        pipe([V((sx * (SIDE + 0.02), COWL[0] + 0.05, SILL)),
              V((sx * (SIDE + 0.02), HOOP_Y + 0.4, FLOOR))], r * 0.85, "Steel", "body", n=8)
        pipe([V((sx * SIDE, COWL[0] + 0.3, COWL[1] - 0.05)), V((sx * 0.6, 0.9, 0.95)),
              V((sx * 0.5, NOSE[0] - 0.1, FLOOR + 0.15))], r * 0.85, "Steel", "body", n=8)
        # rear cage: braces from the hoop top down to a box frame over the deck
        pipe([V((sx * w_top, HOOP_Y, ROOF - 0.02)), V((sx * (SIDE - 0.04), TAIL + 0.3, 1.32)),
              V((sx * (SIDE - 0.04), TAIL + 0.05, 1.32)),
              V((sx * (SIDE - 0.04), TAIL + 0.05, FLOOR + 0.1))], r, "Steel", "body", n=8)
        pipe([V((sx * SIDE, HOOP_Y, SILL + 0.05)), V((sx * (SIDE - 0.04), TAIL + 0.05, 1.05))],
             r * 0.85, "Steel", "body", n=8)
    pipe([V((-w_top, front_y, ROOF)), V((w_top, front_y, ROOF))], r, "Steel", "body", n=8)
    # X brace across the roof
    pipe([V((-w_top, front_y, ROOF)), V((w_top, HOOP_Y, ROOF))], r * 0.85, "Steel", "body", n=8)
    pipe([V((w_top, front_y, ROOF)), V((-w_top, HOOP_Y, ROOF))], r * 0.85, "Steel", "body", n=8)
    for z in (1.32, 1.05):
        pipe([V((-SIDE + 0.04, TAIL + 0.05, z)), V((SIDE - 0.04, TAIL + 0.05, z))], r * 0.85,
             "Steel", "body", n=8)
    # bull bar round the nose
    yb = NOSE[0] + 0.28
    pipe([V((-0.62, 1.45, FLOOR + 0.2)), V((-0.6, yb - 0.1, FLOOR + 0.3)),
          V((-0.42, yb, FLOOR + 0.42)), V((0.42, yb, FLOOR + 0.42)),
          V((0.6, yb - 0.1, FLOOR + 0.3)), V((0.62, 1.45, FLOOR + 0.2))], r, "Steel", "body",
         n=8)
    for sx in (-1, 1):
        pipe([V((sx * 0.3, yb - 0.01, FLOOR + 0.42)), V((sx * 0.3, NOSE[0] + 0.1, FLOOR + 0.2))],
             r * 0.8, "Steel", "body", n=6)


# --------------------------------------------------------------------------
# Cockpit
# --------------------------------------------------------------------------

def seat(x):
    y = HOOP_Y + 0.38
    base = V((x, y, FLOOR + 0.2))
    rbox(base, (0.44, 0.48, 0.14), "Seat", "body", bevel=0.25, smooth=True)
    for sx in (-1, 1):  # side bolsters
        rbox(base + V((sx * 0.2, 0, 0.07)), (0.07, 0.46, 0.1), "Seat", "body", bevel=0.35,
             smooth=True)
    back_c = V((x, y - 0.27, FLOOR + 0.58))
    tilt = rot_xyz(-12, 0, 0)
    rbox(back_c, (0.44, 0.12, 0.66), "Seat", "body", rot=tilt, bevel=0.3, smooth=True)
    for sx in (-1, 1):
        rbox(back_c + V((sx * 0.2, 0.05, -0.05)), (0.07, 0.1, 0.55), "Seat", "body", rot=tilt,
             bevel=0.35, smooth=True)
    rbox(V((x, y - 0.34, FLOOR + 1.0)), (0.26, 0.1, 0.18), "Seat", "body", rot=tilt, bevel=0.35,
         smooth=True)
    # harness straps over the shoulders and lap
    for sx in (-1, 1):
        rbox(V((x + sx * 0.1, y - 0.2, FLOOR + 0.6)), (0.05, 0.015, 0.62), "Strap", "body",
             rot=tilt, bevel=0.0)
        rbox(V((x + sx * 0.1, y - 0.2, FLOOR + 0.3)), (0.03, 0.025, 0.05), "Steel", "body",
             bevel=0.2)
    rbox(V((x, y + 0.02, FLOOR + 0.29)), (0.4, 0.04, 0.02), "Strap", "body", bevel=0.0)


def cockpit():
    seat(-0.32)
    seat(0.32)
    # dash, steering column and wheel (right-hand drive, as in the reference)
    rbox(V((0, COWL[0] + 0.02, COWL[1] - 0.12)), (2 * SIDE - 0.08, 0.12, 0.2), "DarkMetal",
         "body", bevel=0.25)
    col0, col1 = V((0.32, COWL[0] + 0.1, COWL[1] - 0.15)), V((0.32, COWL[0] - 0.22, 1.22))
    tube(col0, col1, 0.025, 0.025, "DarkMetal", "body", n=6, rings=1)
    torus(col1, 0.17, 0.02, "Seat", "body", rot=rot_xyz(65, 0, 0), n=20, k=6)
    pipe([col1 + V((-0.16, 0.0, 0)), col1 + V((0.16, 0.0, 0))], 0.012, "DarkMetal", "body", n=5)
    # gear lever and a fire extinguisher between the seats
    tube(V((0, HOOP_Y + 0.6, FLOOR)), V((0, HOOP_Y + 0.7, FLOOR + 0.4)), 0.012, 0.012,
         "DarkMetal", "body", n=5, rings=1)
    ellipsoid(V((0, HOOP_Y + 0.7, FLOOR + 0.42)), (0.03, 0.03, 0.03), "Seat", "body", seg=8,
              rings=5)
    tube(V((0, HOOP_Y + 0.1, FLOOR + 0.04)), V((0, HOOP_Y + 0.1, FLOOR + 0.4)), 0.06, 0.06,
         "Grille", "body", n=10, rings=1)


# --------------------------------------------------------------------------
# Cargo and gun
# --------------------------------------------------------------------------

def jerrycan(c, yaw=0.0):
    r = rot_xyz(0, 0, yaw)

    def at(p):
        return c + (r @ V(p).to_4d()).to_3d()

    rbox(c, (0.17, 0.35, 0.46), "Jerry", "body", rot=r, bevel=0.12)
    for dz in (0.1, -0.1):
        rbox(at((0, 0, dz)), (0.18, 0.28, 0.03), "Jerry", "body", rot=r, bevel=0.3)
    pipe([at(p) for p in ((0, -0.12, 0.23), (0, -0.1, 0.29), (0, 0.02, 0.29), (0, 0.04, 0.23))],
         0.014, "Jerry", "body", n=5)
    tube(at((0, 0.12, 0.23)), at((0, 0.12, 0.28)), 0.03, 0.03, "Jerry", "body", n=8, rings=1)


def cargo():
    z = DECK + 0.23
    jerrycan(V((0.5, TAIL + 0.32, z)), 90)
    jerrycan(V((0.5, TAIL + 0.68, z)), 90)
    jerrycan(V((-0.45, TAIL + 0.3, z)), 0)
    # ammo boxes stacked behind the seats, and a strap over them
    for x, y, h in ((-0.25, HOOP_Y - 0.25, 0.0), (-0.25, HOOP_Y - 0.25, 0.22),
                    (0.05, HOOP_Y - 0.6, 0.0), (-0.3, HOOP_Y - 0.62, 0.0)):
        c = V((x, y, DECK + 0.11 + h))
        rbox(c, (0.36, 0.22, 0.2), "AmmoBox", "body", bevel=0.1)
        rbox(c + V((0, 0, 0.105)), (0.38, 0.24, 0.025), "AmmoBox", "body", bevel=0.2)
        rbox(c + V((0, 0, 0.125)), (0.1, 0.03, 0.015), "DarkMetal", "body", bevel=0.2)
    rbox(V((-0.25, HOOP_Y - 0.25, DECK + 0.25)), (0.04, 0.24, 0.5), "Strap", "body", bevel=0.0)


def gun_mount():
    p = GUN_PIVOT
    # post from the deck up past the cage, braced to the hoop (body)
    post_top = p - V((0, 0, 0.16))
    tube(V((p.x, p.y, DECK)), post_top, 0.05, 0.045, "Steel", "body", n=10, rings=1)
    rbox(V((p.x, p.y, DECK + 0.02)), (0.24, 0.24, 0.04), "DarkMetal", "body", bevel=0.3)
    tube(V((p.x, p.y, ROOF - 0.15)), V((p.x, p.y, ROOF + 0.05)), 0.065, 0.065, "DarkMetal",
         "body", n=10, rings=1)  # clamp collar
    pipe([V((p.x, p.y, ROOF - 0.05)), V((0.5, HOOP_Y, ROOF - 0.03))], 0.025, "Steel", "body",
         n=6)
    # the gun (its own node): swivel, yoke, receiver, barrel with bipod, stock, ammo can
    tube(post_top, p, 0.035, 0.035, "Gunmetal", "gun", n=8, rings=1)
    rbox(p + V((0, 0, 0.02)), (0.16, 0.08, 0.05), "Gunmetal", "gun", bevel=0.2)
    for sx in (-1, 1):
        rbox(p + V((sx * 0.07, 0, 0.09)), (0.02, 0.06, 0.14), "Gunmetal", "gun", bevel=0.2)
    recv = p + V((0, 0.0, 0.16))
    rbox(recv, (0.08, 0.42, 0.12), "DarkMetal", "gun", bevel=0.15)
    rbox(recv + V((0, 0.02, 0.075)), (0.07, 0.24, 0.03), "DarkMetal", "gun", bevel=0.25)
    for i in range(6):  # cooling slots on the receiver cover
        rbox(recv + V((0.041, -0.1 + i * 0.04, 0.02)), (0.004, 0.02, 0.05), "Grille", "gun",
             bevel=0.0)
    tube(recv + V((0, 0.2, 0.0)), recv + V((0, 0.85, 0.0)), 0.02, 0.02, "DarkMetal", "gun",
         n=8, rings=1)
    tube(recv + V((0, 0.2, 0.0)), recv + V((0, 0.42, 0.0)), 0.035, 0.03, "Gunmetal", "gun",
         n=8, rings=1)
    tube(recv + V((0, 0.82, 0.0)), recv + V((0, 0.92, 0.0)), 0.03, 0.03, "Gunmetal", "gun",
         n=8, rings=1)  # flash hider
    rbox(recv + V((0, 0.78, 0.05)), (0.015, 0.02, 0.07), "DarkMetal", "gun", bevel=0.2)
    rbox(recv + V((0, 0.05, 0.11)), (0.03, 0.06, 0.05), "DarkMetal", "gun", bevel=0.2)
    for sx in (-1, 1):  # folded bipod legs
        pipe([recv + V((sx * 0.015, 0.55, -0.02)), recv + V((sx * 0.03, 0.3, -0.06))], 0.008,
             "DarkMetal", "gun", n=5)
    rbox(recv + V((0, -0.32, -0.02)), (0.06, 0.24, 0.1), "DarkMetal", "gun", bevel=0.2,
         taper=0.9)  # stock
    rbox(recv + V((0, -0.06, -0.12)), (0.04, 0.06, 0.12), "DarkMetal", "gun",
         rot=rot_xyz(-15, 0, 0), bevel=0.2)  # pistol grip
    pipe([recv + V((0, 0.1, 0.075)), recv + V((0, 0.12, 0.13)), recv + V((0, 0.22, 0.13)),
          recv + V((0, 0.24, 0.075))], 0.01, "DarkMetal", "gun", n=5)  # carry handle
    can = recv + V((-0.14, 0.02, -0.06))
    rbox(can, (0.15, 0.22, 0.18), "AmmoBox", "gun", bevel=0.12)
    rbox(can + V((0, 0, 0.1)), (0.16, 0.23, 0.025), "AmmoBox", "gun", bevel=0.2)
    pipe([can + V((0.07, 0.0, 0.06)), recv + V((-0.04, 0.02, 0.01))], 0.018, "Brass", "gun",
         n=6)  # ammo belt


# --------------------------------------------------------------------------
# Wheels
# --------------------------------------------------------------------------

def balloon_tyre(group, centre, side, folds=26, seg=78, prof=18):
    """Fat low-pressure tyre revolved from an elliptical section, with soft radial folds in
    the sidewalls like the fabric-looking sand tyres in the reference."""
    rc, a, b = 0.375, WHEEL_R - 0.375, TYRE_W / 2
    bm = bmesh.new()
    rings = []
    for i in range(seg):
        th = 2 * math.pi * i / seg
        fold = math.sin(folds * th + 0.6 * math.sin(3 * th))
        ring = []
        for j in range(prof):
            phi = 2 * math.pi * j / prof
            wall = abs(math.sin(phi))  # 1 on the sidewalls, 0 at tread and bead
            tread = max(0.0, math.cos(phi))
            rho = rc + a * math.cos(phi) * (1 + 0.012 * fold * tread)
            x = b * math.sin(phi) * (1 + 0.07 * fold * wall)
            rho += 0.012 * fold * wall * tread
            ring.append(bm.verts.new((x, math.cos(th) * rho, math.sin(th) * rho)))
        rings.append(ring)
    for i in range(seg):
        r0, r1 = rings[i], rings[(i + 1) % seg]
        for j in range(prof):
            k = (j + 1) % prof
            bm.faces.new((r0[j], r0[k], r1[k], r1[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    add(bm, "Tyre", group, True, Matrix.Translation(centre))
    # deep dark rim: a dish recessed behind the sidewall, with a hub and lug nuts
    out = V((side, 0, 0))
    tube(centre - out * 0.16, centre + out * 0.07, 0.24, 0.235, "Rim", group, n=24, rings=1)
    tube(centre + out * 0.07, centre + out * 0.1, 0.11, 0.09, "Rim", group, n=16, rings=1)
    tube(centre + out * 0.1, centre + out * 0.14, 0.05, 0.04, "Gunmetal", group, n=10, rings=1)
    for i in range(6):
        ang = 2 * math.pi * i / 6
        d = V((0, math.cos(ang), math.sin(ang)))
        ellipsoid(centre + out * 0.1 + d * 0.075, (0.012, 0.014, 0.014), "Gunmetal", group,
                  seg=6, rings=4)
    # brake disc on the inside
    tube(centre - out * 0.2, centre - out * 0.17, 0.17, 0.17, "Gunmetal", group, n=18, rings=1)


# --------------------------------------------------------------------------
# Game mode: a chunky, low-poly build of the same buggy for play zoom (about 45 px long), in
# the Sandline Syndicate colours of the raider. Bolts, vents, straps, coils and the thin
# braces go; the cage, gun and tyres get thicker; the hood plate and the tub sides are big
# team-coloured panels.
# --------------------------------------------------------------------------

# Sandline Syndicate palette, shared with build_raider.py (keep the two in step).
SANDLINE = {
    "TeamColor": ((0.22, 0.42, 0.78), 0.6, 0.0),
    "BodyRed": ((0.64, 0.22, 0.16), 0.8, 0.0),
    "BodyRust": ((0.44, 0.25, 0.16), 0.9, 0.0),
    "Sand": ((0.70, 0.58, 0.40), 0.9, 0.0),
    "Mud": ((0.40, 0.31, 0.21), 0.95, 0.0),
    "Rubber": ((0.09, 0.085, 0.08), 0.9, 0.0),
    "Rim": ((0.62, 0.52, 0.36), 0.6, 0.2),
    "DarkMetal": ((0.12, 0.12, 0.13), 0.5, 0.6),
    "Gunmetal": ((0.20, 0.21, 0.22), 0.45, 0.6),
    "Grille": ((0.06, 0.06, 0.06), 0.7, 0.2),
    "Glass": ((0.10, 0.12, 0.14), 0.15, 0.2),
    "Seat": ((0.11, 0.11, 0.12), 0.8, 0.0),
    "Lamp": ((1.00, 0.92, 0.65), 0.4, 0.0, 1.2),
    "Amber": ((0.95, 0.60, 0.10), 0.4, 0.0, 0.6),
    "Jerry": ((0.30, 0.38, 0.20), 0.7, 0.0),
    "AmmoBox": ((0.33, 0.37, 0.22), 0.7, 0.0),
    "Brass": ((0.80, 0.65, 0.20), 0.4, 0.5),
    "Canvas": ((0.66, 0.58, 0.42), 0.95, 0.0),
    "Rope": ((0.62, 0.50, 0.34), 0.95, 0.0),
    "Toolbox": ((0.36, 0.30, 0.22), 0.8, 0.1),
}


def chunky_wheel(group, centre, side, radius, width, segs=12):
    """Sandline game-mode wheel (same code in build_raider.py): a low-segment tyre with
    chamfered shoulders and staggered tread blocks, a recessed sand-painted rim and a hub."""
    lug = radius * 0.08
    rt, c, rim_r = radius - lug, width * 0.18, radius * 0.6
    hw = width / 2
    prof = [(-hw * 0.84, rim_r), (-hw, rt * 0.8), (-hw, rt - c), (-hw + c, rt), (0.0, rt),
            (hw - c, rt), (hw, rt - c), (hw, rt * 0.8), (hw * 0.84, rim_r)]
    bm = bmesh.new()
    rings = []
    for i in range(segs):
        th = 2 * math.pi * (i + 0.5) / segs
        rings.append([bm.verts.new((x, math.cos(th) * r, math.sin(th) * r)) for x, r in prof])
    n = len(prof)
    faces = []
    for i in range(segs):
        r0, r1 = rings[i], rings[(i + 1) % segs]
        faces.append([bm.faces.new((r0[j], r0[(j + 1) % n], r1[(j + 1) % n], r1[j]))
                      for j in range(n)])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    for i in range(segs):
        lane = (2, 3) if i % 2 == 0 else (4, 5)
        res = bmesh.ops.extrude_face_region(bm, geom=[faces[i][j] for j in lane])
        for v in res["geom"]:
            if isinstance(v, bmesh.types.BMVert):
                v.co += Vector((0.0, v.co.y, v.co.z)).normalized() * lug
        bmesh.ops.delete(bm, geom=[faces[i][j] for j in lane], context="FACES_ONLY")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    add(bm, "Rubber", group, False, Matrix.Translation(centre))
    out = V((side, 0, 0))
    tube(centre - out * hw * 0.8, centre + out * hw * 0.7, rim_r * 1.04, rim_r * 1.04, "Rim",
         group, n=segs, rings=1, smooth=False)
    tube(centre + out * hw * 0.7, centre + out * hw * 0.92, radius * 0.22, radius * 0.17,
         "Gunmetal", group, n=6, rings=1, smooth=False)


def g_nose():
    hull(sym([(SIDE, COWL[0], COWL[1]), (SIDE - 0.04, COWL[0], FLOOR + 0.02),
              (0.52, NOSE[0], NOSE[1]), (0.46, NOSE[0] + 0.2, NOSE[1] - 0.16),
              (0.36, NOSE[0] + 0.05, FLOOR + 0.12), (0.5, 0.9, FLOOR)]), "BodyRed", "body")
    # big team-coloured hood plate with a raised centre scoop
    y0, y1 = 0.02, NOSE[0] - 0.04
    plate = []
    for x, y in ((0.42, y0), (0.6, y0 + 0.28), (0.5, y1 - 0.12), (0.36, y1)):
        for dz in (-0.01, 0.04):
            plate += sym([(x, y, hood_z(y) + dz)])
    hull(plate, "TeamColor", "body")
    scoop = []
    for x, y, h in ((0.16, y0 + 0.2, 0.07), (0.26, 0.8, 0.12), (0.22, y1 - 0.3, 0.08),
                    (0.12, y1 - 0.1, 0.04)):
        scoop += sym([(x, y, hood_z(y) + 0.03), (x * 0.7, y, hood_z(y) + 0.03 + h)])
    hull(scoop, "TeamColor", "body")
    slope = math.degrees(math.atan2(COWL[1] - NOSE[1], NOSE[0] - COWL[0]))
    rbox(V((0, -0.06, hood_z(-0.06) + 0.03)), (0.5, 0.1, 0.03), "Grille", "body",
         rot=rot_xyz(slope, 0, 0), bevel=0)
    for sx in (-1, 1):  # square work lamps at the nose corners
        lamp = V((sx * 0.5, NOSE[0] - 0.06, NOSE[1] + 0.08))
        rbox(lamp, (0.16, 0.1, 0.14), "DarkMetal", "body", bevel=0)
        rbox(lamp + V((0, 0.055, 0)), (0.12, 0.02, 0.1), "Lamp", "body", bevel=0)


def g_tub():
    y0, y1 = TAIL + 0.35, COWL[0]
    for sx in (-1, 1):
        rbox(V((sx * SIDE, (y0 + y1) / 2, (FLOOR + SILL) / 2 - 0.05)),
             (0.04, y1 - y0, SILL - FLOOR - 0.12), "BodyRed", "body", bevel=0)
        rbox(V((sx * (SIDE + 0.03), (y0 + y1) / 2, 0.7)), (0.03, y1 - y0 - 0.12, 0.3),
             "TeamColor", "body", bevel=0)  # team-coloured side panel
    rbox(V((0, (TAIL + COWL[0]) / 2 + 0.2, FLOOR)), (2 * SIDE, COWL[0] - TAIL - 0.4, 0.04),
         "DarkMetal", "body", bevel=0)
    rbox(V((0, (TAIL + HOOP_Y) / 2, DECK - 0.02)), (2 * SIDE - 0.04, HOOP_Y - TAIL, 0.05),
         "BodyRust", "body", bevel=0)
    hull(sym([(SIDE - 0.05, TAIL + 0.1, DECK - 0.02), (SIDE - 0.05, HOOP_Y, DECK - 0.02),
              (0.4, TAIL + 0.15, FLOOR + 0.05), (0.4, HOOP_Y, FLOOR + 0.05)]), "DarkMetal",
         "body")
    for sx in (-1, 1):  # rear quarter panels
        hull([V((sx * SIDE, HOOP_Y + 0.05, SILL - 0.05)), V((sx * SIDE, HOOP_Y + 0.05, FLOOR)),
              V((sx * SIDE, TAIL + 0.35, DECK)), V((sx * (SIDE - 0.04), HOOP_Y + 0.05, FLOOR)),
              V((sx * (SIDE - 0.04), HOOP_Y + 0.05, SILL - 0.05)),
              V((sx * (SIDE - 0.04), TAIL + 0.35, DECK))], "BodyRed", "body")


def g_chassis():
    for sx in (-1, 1):
        x = sx * (SIDE - 0.02)
        pipe([V((sx * 0.4, NOSE[0] + 0.05, FLOOR + 0.1)), V((x, 1.0, FLOOR)),
              V((x, TAIL + 0.3, FLOOR)), V((sx * 0.5, TAIL, FLOOR + 0.12))], 0.05, "DarkMetal",
             "body", n=6)
    for y in AXLES.values():
        for sx in (-1, 1):
            hub = V((sx * (TRACK - 0.2), y, WHEEL_R))
            tube(V((sx * 0.42, y, WHEEL_R - 0.05)), hub + V((0, 0, -0.05)), 0.05, 0.05,
                 "DarkMetal", "body", n=4)  # A-arm
            top = V((sx * 0.48, y + 0.05, SILL + 0.15))
            low = hub + V((-sx * 0.12, 0.05, -0.05))
            d = top - low
            tube(low, top, 0.045, 0.045, "Gunmetal", "body", n=6)  # coil-over
            tube(low + d * 0.15, low + d * 0.75, 0.085, 0.085, "Rim", "body", n=6)  # spring
    rbox(V((0, TAIL - 0.05, FLOOR + 0.12)), (0.16, 0.14, 0.1), "DarkMetal", "body", bevel=0)
    pipe([V((-0.3, TAIL + 0.3, FLOOR + 0.2)), V((-0.3, TAIL - 0.05, FLOOR + 0.25)),
          V((-0.3, TAIL - 0.1, FLOOR + 0.35))], 0.05, "DarkMetal", "body", n=6)


def g_roll_cage():
    r = 0.055
    w_top = 0.56
    front_y = COWL[0] - 0.12
    m = "DarkMetal"
    pipe([V((-SIDE, HOOP_Y, FLOOR)), V((-SIDE, HOOP_Y, SILL + 0.3)), V((-w_top, HOOP_Y, ROOF)),
          V((w_top, HOOP_Y, ROOF)), V((SIDE, HOOP_Y, SILL + 0.3)), V((SIDE, HOOP_Y, FLOOR))],
         r, m, "body", n=6)
    pipe([V((-SIDE + 0.02, HOOP_Y, SILL)), V((w_top - 0.02, HOOP_Y, ROOF - 0.03))], r * 0.85,
         m, "body", n=6)
    for sx in (-1, 1):
        pipe([V((sx * SIDE, COWL[0] + 0.25, COWL[1] - 0.02)), V((sx * w_top, front_y, ROOF)),
              V((sx * w_top, HOOP_Y, ROOF))], r, m, "body", n=6)
        pipe([V((sx * (SIDE + 0.03), COWL[0] + 0.05, SILL)),
              V((sx * (SIDE + 0.03), HOOP_Y, SILL))], r, m, "body", n=6)
        pipe([V((sx * SIDE, COWL[0] + 0.3, COWL[1] - 0.05)), V((sx * 0.6, 0.9, 0.95)),
              V((sx * 0.5, NOSE[0] - 0.1, FLOOR + 0.15))], r * 0.85, m, "body", n=6)
        pipe([V((sx * w_top, HOOP_Y, ROOF - 0.02)), V((sx * (SIDE - 0.04), TAIL + 0.3, 1.32)),
              V((sx * (SIDE - 0.04), TAIL + 0.05, 1.32)),
              V((sx * (SIDE - 0.04), TAIL + 0.05, FLOOR + 0.1))], r, m, "body", n=6)
    pipe([V((-w_top, front_y, ROOF)), V((w_top, front_y, ROOF))], r, m, "body", n=6)
    pipe([V((-w_top, front_y, ROOF)), V((w_top, HOOP_Y, ROOF))], r * 0.85, m, "body", n=6)
    pipe([V((-SIDE + 0.04, TAIL + 0.05, 1.32)), V((SIDE - 0.04, TAIL + 0.05, 1.32))], r, m,
         "body", n=6)
    yb = NOSE[0] + 0.28
    pipe([V((-0.62, 1.45, FLOOR + 0.2)), V((-0.6, yb - 0.1, FLOOR + 0.3)),
          V((-0.42, yb, FLOOR + 0.42)), V((0.42, yb, FLOOR + 0.42)),
          V((0.6, yb - 0.1, FLOOR + 0.3)), V((0.62, 1.45, FLOOR + 0.2))], r, m, "body", n=6)


def g_cockpit():
    y = HOOP_Y + 0.38
    for x in (-0.32, 0.32):
        rbox(V((x, y, FLOOR + 0.2)), (0.46, 0.5, 0.16), "Seat", "body", bevel=0)
        rbox(V((x, y - 0.28, FLOOR + 0.66)), (0.46, 0.14, 0.82), "Seat", "body",
             rot=rot_xyz(-12, 0, 0), bevel=0)
    rbox(V((0, COWL[0] + 0.02, COWL[1] - 0.12)), (2 * SIDE - 0.08, 0.14, 0.22), "DarkMetal",
         "body", bevel=0)
    col0, col1 = V((0.32, COWL[0] + 0.1, COWL[1] - 0.15)), V((0.32, COWL[0] - 0.22, 1.22))
    tube(col0, col1, 0.03, 0.03, "DarkMetal", "body", n=4)
    torus(col1, 0.16, 0.03, "Seat", "body", rot=rot_xyz(65, 0, 0), n=8, k=4)


def g_cargo():
    z = DECK + 0.23
    for x, y, yaw in ((0.5, TAIL + 0.32, 90), (0.5, TAIL + 0.68, 90), (-0.45, TAIL + 0.3, 0)):
        rbox(V((x, y, z)), (0.18, 0.36, 0.46), "Jerry", "body", rot=rot_xyz(0, 0, yaw),
             bevel=0.12)
    for x, y, h in ((-0.25, HOOP_Y - 0.25, 0.0), (-0.25, HOOP_Y - 0.25, 0.22),
                    (0.05, HOOP_Y - 0.6, 0.0)):
        rbox(V((x, y, DECK + 0.12 + h)), (0.38, 0.24, 0.22), "AmmoBox", "body", bevel=0)


def g_gun_mount():
    p = GUN_PIVOT
    post_top = p - V((0, 0, 0.16))
    tube(V((p.x, p.y, DECK)), post_top, 0.065, 0.055, "DarkMetal", "body", n=8)
    rbox(V((p.x, p.y, DECK + 0.03)), (0.28, 0.28, 0.06), "DarkMetal", "body", bevel=0)
    tube(V((p.x, p.y, ROOF - 0.15)), V((p.x, p.y, ROOF + 0.05)), 0.085, 0.085, "Gunmetal",
         "body", n=8)
    tube(V((p.x, p.y, ROOF - 0.05)), V((0.5, HOOP_Y, ROOF - 0.03)), 0.035, 0.035, "DarkMetal",
         "body", n=4)
    # the gun (its own node): swivel, yoke, bold receiver, thick barrel, stock and ammo can
    tube(post_top, p, 0.045, 0.045, "Gunmetal", "gun", n=6)
    rbox(p + V((0, 0, 0.05)), (0.18, 0.1, 0.12), "Gunmetal", "gun", bevel=0)
    recv = p + V((0, 0.0, 0.17))
    rbox(recv, (0.11, 0.48, 0.15), "DarkMetal", "gun", bevel=0)
    rbox(recv + V((0, 0.02, 0.09)), (0.09, 0.28, 0.04), "Gunmetal", "gun", bevel=0)
    tube(recv + V((0, 0.22, 0.0)), recv + V((0, 0.88, 0.0)), 0.032, 0.032, "DarkMetal", "gun",
         n=6)
    tube(recv + V((0, 0.22, 0.0)), recv + V((0, 0.46, 0.0)), 0.052, 0.048, "Gunmetal", "gun",
         n=6)
    tube(recv + V((0, 0.84, 0.0)), recv + V((0, 0.95, 0.0)), 0.045, 0.045, "Gunmetal", "gun",
         n=6)
    rbox(recv + V((0, 0.8, 0.06)), (0.03, 0.03, 0.1), "DarkMetal", "gun", bevel=0)
    rbox(recv + V((0, -0.34, -0.02)), (0.08, 0.26, 0.13), "DarkMetal", "gun", bevel=0,
         taper=0.9)
    rbox(recv + V((0, -0.07, -0.13)), (0.05, 0.07, 0.14), "DarkMetal", "gun",
         rot=rot_xyz(-15, 0, 0), bevel=0)
    can = recv + V((-0.15, 0.02, -0.06))
    rbox(can, (0.17, 0.24, 0.2), "AmmoBox", "gun", bevel=0.12)
    tube(can + V((0.08, 0.0, 0.06)), recv + V((-0.05, 0.02, 0.01)), 0.028, 0.028, "Brass",
         "gun", n=4)


def build_game():
    GAME.update(segments=1.0, min_segments=3)  # the counts below are already low
    PALETTE.update(SANDLINE)
    g_nose()
    g_tub()
    g_chassis()
    g_roll_cage()
    g_cockpit()
    g_cargo()
    g_gun_mount()


def main():
    args = parse_args({"out": "assets/models/ironbound/units/scout_buggy_v2.glb", "render": None})
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if GAME["enabled"]:
        build_game()
    else:
        nose()
        tub()
        chassis()
        roll_cage()
        cockpit()
        cargo()
        gun_mount()
    hubs = {}
    for axle, y in AXLES.items():
        for side, tag in ((-1, "L"), (1, "R")):
            name = f"Wheel_{axle}{tag}"
            hubs[name] = V((side * TRACK, y, WHEEL_R))
            if GAME["enabled"]:
                chunky_wheel(name, hubs[name], side, WHEEL_R, TYRE_W)
            else:
                balloon_tyre(name, hubs[name], side)
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
            ("three_quarter", -55, 25, 1.45, wide), ("side", -90, 0, 1.3, wide),
            ("front", 0, 10, 1.3, wide), ("back", 155, 25, 1.45, wide),
            ("game_angle", -35, 50, 1.5, (800, 800)),
        ], target=(0, 0, 0.32))


main()
