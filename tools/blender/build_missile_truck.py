"""Builds the Missile Truck: a half-track with a forward-control truck cab and bonnet at the
front, tracks under a stowage bed at the rear, and a turntable carrying two angled missiles on
launch rails. The cab roof is team-coloured. Exports a GLB at in-game size.

    python3 tools/blender/build_missile_truck.py -- \
        --out assets/models/ironbound/units/missile_truck.glb [--render /tmp/previews]

Modelled in real metres (about 7 m long), facing +Y, then scaled by GAME_SCALE (the raider's).
The front wheels (Wheel_FL, Wheel_FR, origins at the hubs, spin about X) and the launcher
(Launcher: turntable, both rails and both missiles, origin at the turntable centre, turns about
Z) are separate nodes so the game can animate them. The launcher rests facing backwards, as in
the reference. The tracks are part of the body.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
import bmesh  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
from mesh_kit import (  # noqa: E402
    PALETTE, V, add, ellipsoid, export_glb, frame_from_dir, look_matrix, merge, parse_args,
    pipe, rbox, render_views, rot_xyz, set_origin, stats, torus, tube,
)

GAME_SCALE = 0.245

PALETTE.update({
    "TeamColor": ((0.22, 0.42, 0.80), 0.45, 0.0),
    "Olive": ((0.34, 0.36, 0.21), 0.8, 0.0),
    "OliveDark": ((0.25, 0.27, 0.16), 0.85, 0.0),
    "Steel": ((0.42, 0.42, 0.40), 0.45, 0.7),
    "DarkMetal": ((0.12, 0.12, 0.12), 0.55, 0.5),
    "Track": ((0.17, 0.17, 0.16), 0.6, 0.6),
    "Grille": ((0.06, 0.06, 0.06), 0.7, 0.2),
    "Glass": ((0.42, 0.55, 0.58), 0.08, 0.2),
    "Tyre": ((0.07, 0.07, 0.07), 0.9, 0.0),
    "Lamp": ((1.00, 0.95, 0.82), 0.3, 0.0, 1.2),
    "Band": ((0.78, 0.78, 0.72), 0.6, 0.0),
    "Jerry": ((0.33, 0.36, 0.20), 0.7, 0.0),
    "AmmoBox": ((0.35, 0.37, 0.22), 0.75, 0.0),
})

# front axle and wheels
WHEEL_R = 0.56
TYRE_W = 0.38
TRACK_X = 0.98
FRONT_Y = 2.15
# cab, bonnet, bumper
CAB_X = 1.05
CAB_BACK, CAB_FRONT = -0.05, 1.3
CAB_FLOOR, BELT, ROOF = 0.95, 1.88, 2.62
NOSE_Y = 2.98
BUMPER_Y = 3.2
# tracks and bed
TRK_X, TRK_W = 0.93, 0.44
SPROCKET = (-0.48, 0.66, 0.34)  # y, z, r
IDLER = (-3.42, 0.55, 0.29)
ROAD = [(-1.08, 0.33, 0.29), (-1.7, 0.33, 0.29), (-2.32, 0.33, 0.29), (-2.92, 0.33, 0.29)]
BED_BACK, BED_FRONT = -3.78, -0.3
SKIRT_X, SKIRT_Z = 1.21, (0.82, 1.56)
BED_X, BED_TOP = 0.86, 2.02
# launcher
TT = V((0, -2.0, 2.0))  # turntable pivot: top of the fixed pedestal
DISK_Z = 2.3
ELEV = 48.0  # missile elevation, degrees
MISSILE_X = 0.5


def hull(points, m, group, smooth=False):
    """Convex hull of a point cloud: armour panels, cab shell, bonnet."""
    bm = bmesh.new()
    for p in points:
        bm.verts.new(p)
    res = bmesh.ops.convex_hull(bm, input=bm.verts[:])
    junk = list({g for g in res["geom_interior"] + res["geom_unused"]
                 if isinstance(g, bmesh.types.BMVert)})
    if junk:
        bmesh.ops.delete(bm, geom=junk, context="VERTS")
    return add(bm, m, group, smooth)


def sym(points):
    """Mirrors (x, y, z) points across x = 0."""
    out = []
    for x, y, z in points:
        out += [V((x, y, z)), V((-x, y, z))]
    return out


def axle_disc(c, r, w, m, group, n=20):
    """Disc of radius r and width w centred on c, axis along X."""
    tube(c - V((w / 2, 0, 0)), c + V((w / 2, 0, 0)), r, r, m, group, n=n, rings=1)


# --------------------------------------------------------------------------
# Cab
# --------------------------------------------------------------------------

def cab():
    # lower cab: doors and back wall
    rbox(V((0, (CAB_BACK + CAB_FRONT) / 2, (CAB_FLOOR + BELT) / 2)),
         (2 * CAB_X, CAB_FRONT - CAB_BACK, BELT - CAB_FLOOR), "Olive", "body", bevel=0.06)
    # glasshouse: glass shell with an olive frame over it
    top_front = CAB_FRONT - 0.14
    hull(sym([(CAB_X - 0.05, CAB_BACK + 0.04, BELT - 0.02), (CAB_X - 0.05, CAB_BACK + 0.04, ROOF),
              (CAB_X - 0.05, CAB_FRONT - 0.02, BELT - 0.02), (CAB_X - 0.07, top_front, ROOF)]),
         "Glass", "body")

    fx = CAB_X - 0.03
    for sx in (-1, 1):
        x = sx * fx
        # A, B and C pillars
        a0, a1 = V((x, CAB_FRONT - 0.02, BELT)), V((sx * (fx - 0.02), top_front, ROOF))
        rbox((a0 + a1) / 2, (0.1, 0.12, (a1 - a0).length), "Olive", "body",
             rot=look_matrix(a0, a1), bevel=0.2)
        for y in (0.35, CAB_BACK + 0.07):
            rbox(V((x, y, (BELT + ROOF) / 2)), (0.1, 0.12, ROOF - BELT), "Olive", "body",
                 bevel=0.2)
        # door window frame top rail
        rbox(V((x, (CAB_BACK + top_front) / 2, ROOF - 0.03)), (0.1, top_front - CAB_BACK, 0.08),
             "Olive", "body", bevel=0.2)
    # windscreen frame: sill, header and centre divider (two panes)
    rake = math.degrees(math.atan2(CAB_FRONT - top_front, ROOF - BELT))
    for z, y in ((BELT + 0.03, CAB_FRONT - 0.02), (ROOF - 0.04, top_front + 0.005)):
        rbox(V((0, y, z)), (2 * fx, 0.12, 0.09), "Olive", "body", bevel=0.2)
    rbox(V((0, (CAB_FRONT + top_front) / 2 - 0.01, (BELT + ROOF) / 2)), (0.08, 0.1, ROOF - BELT),
         "Olive", "body", rot=rot_xyz(rake, 0, 0), bevel=0.2)
    # rear window frame
    for x in (-0.55, 0.55):
        rbox(V((x, CAB_BACK + 0.03, (BELT + ROOF) / 2)), (0.95, 0.06, 0.16), "Olive", "body",
             bevel=0.2)
    rbox(V((0, CAB_BACK + 0.03, BELT + 0.12)), (2 * fx, 0.07, 0.25), "Olive", "body", bevel=0.2)
    # team-coloured roof cap overhanging the frame
    rbox(V((0, (CAB_BACK + top_front) / 2 - 0.01, ROOF + 0.07)),
         (2 * CAB_X + 0.08, top_front - CAB_BACK + 0.14, 0.2), "TeamColor", "body", bevel=0.45,
         smooth=True, taper=0.96, segments=3)
    # wipers
    for x in (-0.45, 0.45):
        p0 = V((x, CAB_FRONT + 0.01, BELT + 0.08))
        p1 = p0 + V((-0.28 * (1 if x > 0 else -1), -0.07, 0.42))
        tube(p0, p1, 0.01, 0.01, "DarkMetal", "body", n=5, rings=1)
    # doors: panel grooves, handles and hinges
    for sx in (-1, 1):
        x = sx * (CAB_X + 0.004)
        y0, y1 = 0.4, CAB_FRONT - 0.08
        for y in (y0, y1):
            rbox(V((x, y, (CAB_FLOOR + ROOF) / 2 - 0.05)), (0.012, 0.018, ROOF - CAB_FLOOR - 0.1),
                 "OliveDark", "body", bevel=0.0)
        rbox(V((x, (y0 + y1) / 2, CAB_FLOOR + 0.06)), (0.012, y1 - y0, 0.018), "OliveDark",
             "body", bevel=0.0)
        rbox(V((x + sx * 0.02, y0 + 0.12, BELT - 0.12)), (0.03, 0.16, 0.035), "Steel", "body",
             bevel=0.3)  # handle
        for z in (1.2, 1.7, 2.2):
            tube(V((x, y1 + 0.03, z - 0.07)), V((x, y1 + 0.03, z + 0.07)), 0.025, 0.025,
                 "OliveDark", "body", n=6, rings=1)
        # rear cab panel seam
        rbox(V((x, 0.1, (CAB_FLOOR + BELT) / 2)), (0.012, 0.018, BELT - CAB_FLOOR - 0.1),
             "OliveDark", "body", bevel=0.0)
        # mirror on a bent arm off the A pillar
        base = V((sx * (CAB_X + 0.02), CAB_FRONT - 0.05, BELT + 0.15))
        tip = base + V((sx * 0.28, 0.08, 0.15))
        pipe([base, base + V((sx * 0.2, 0.05, -0.05)), tip], 0.018, "DarkMetal", "body", n=6)
        rbox(tip + V((sx * 0.04, 0, 0.12)), (0.06, 0.16, 0.3), "Olive", "body", bevel=0.3)
        rbox(tip + V((sx * 0.04, -0.082, 0.12)), (0.045, 0.01, 0.25), "Glass", "body", bevel=0.0)
        # grab handle beside the door
        pipe([V((sx * (CAB_X + 0.01), 0.22, 1.2)), V((sx * (CAB_X + 0.06), 0.22, 1.22)),
              V((sx * (CAB_X + 0.06), 0.22, 1.7)), V((sx * (CAB_X + 0.01), 0.22, 1.72))],
             0.015, "Steel", "body", n=5)
    # antenna with a ball top on the right front roof corner
    ab = V((CAB_X - 0.12, top_front - 0.02, ROOF + 0.15))
    tube(ab, ab + V((0, 0, 0.32)), 0.022, 0.014, "DarkMetal", "body", n=6, rings=1)
    ellipsoid(ab + V((0, 0, 0.35)), (0.05, 0.05, 0.045), "DarkMetal", "body", seg=8, rings=6)
    rbox(ab - V((0, 0, 0.02)), (0.1, 0.1, 0.06), "DarkMetal", "body", bevel=0.3)


# --------------------------------------------------------------------------
# Bonnet, grille, fenders, bumper
# --------------------------------------------------------------------------

def bonnet_z(y):
    t = (y - CAB_FRONT) / (NOSE_Y - CAB_FRONT)
    return 1.86 - 0.06 * t


def bonnet():
    pts = []
    for y in (CAB_FRONT - 0.02, NOSE_Y):
        top = bonnet_z(y)
        for x, z in ((0.84, 1.18), (0.84, top - 0.14), (0.76, top - 0.04), (0.5, top),
                     (0.0, top + 0.01)):
            pts += sym([(x, y, z)])
    hull(pts, "Olive", "body", smooth=False)
    # centre seam, hinge line and latches
    for sx in (-1, 1):
        y_mid = (CAB_FRONT + NOSE_Y) / 2
        rbox(V((sx * 0.55, y_mid, bonnet_z(y_mid) - 0.005)), (0.014, NOSE_Y - CAB_FRONT - 0.1,
             0.02), "OliveDark", "body", rot=rot_xyz(-2.1, 0, 0), bevel=0.0)
        for y in (2.15, 2.65):  # side latches
            rbox(V((sx * 0.85, y, bonnet_z(y) - 0.25)), (0.03, 0.08, 0.14), "OliveDark", "body",
                 bevel=0.25)
        # louvres on the bonnet side near the cab
        for i in range(6):
            rbox(V((sx * 0.847, 1.55 + i * 0.07, 1.48)), (0.02, 0.03, 0.22), "Grille", "body",
                 bevel=0.0)
        # tie-down cleats on the bonnet top
        for y in (1.85, 2.5):
            rbox(V((sx * 0.62, y, bonnet_z(y) + 0.01)), (0.05, 0.1, 0.04), "OliveDark", "body",
                 bevel=0.3)
    # vents on the bonnet top
    for y in (1.62, 2.2):
        rbox(V((0, y, bonnet_z(y) + 0.012)), (0.42, 0.14, 0.02), "Grille", "body", bevel=0.2)
        for i in range(4):
            rbox(V((0, y - 0.045 + i * 0.03, bonnet_z(y) + 0.026)), (0.4, 0.01, 0.01), "Olive",
                 "body", bevel=0.0)
    # grille: frame with horizontal bars
    gy = NOSE_Y + 0.03
    rbox(V((0, gy, 1.36)), (1.24, 0.08, 0.84), "Olive", "body", bevel=0.12)
    rbox(V((0, gy + 0.03, 1.36)), (1.0, 0.04, 0.66), "Grille", "body", bevel=0.0)
    for i in range(9):
        rbox(V((0, gy + 0.055, 1.08 + i * 0.07)), (0.98, 0.025, 0.03), "OliveDark", "body",
             bevel=0.2)
    for x in (-0.25, 0.25):
        rbox(V((x, gy + 0.06, 1.36)), (0.03, 0.025, 0.64), "OliveDark", "body", bevel=0.2)
    # headlights at the top corners, side lights below
    for sx in (-1, 1):
        for x, z, r, d in ((0.72, 1.6, 0.1, 0.1), (0.72, 1.22, 0.075, 0.08)):
            c = V((sx * x, NOSE_Y, z))
            tube(c, c + V((0, d, 0)), r + 0.02, r + 0.015, "Olive", "body", n=16, rings=1)
            ellipsoid(c + V((0, d, 0)), (r, 0.035, r), "Lamp", "body", seg=14, rings=6,
                      rot=rot_xyz(0, 0, 0))
            torus(c + V((0, d + 0.005, 0)), r + 0.01, 0.012, "Steel", "body",
                  rot=rot_xyz(90, 0, 0), n=16, k=5)


def fenders():
    for sx in (-1, 1):
        hub = V((sx * TRACK_X, FRONT_Y, WHEEL_R))
        r_in = WHEEL_R + 0.1
        x_in, x_out = sx * 0.72, sx * 1.22
        # arched mudguard: segments from the front around to the back
        n = 14
        a0, a1 = 8.0, 172.0
        prev = None
        for i in range(n + 1):
            a = math.radians(a0 + (a1 - a0) * i / n)
            p = hub + V((0, math.cos(a), math.sin(a))) * r_in
            if prev is not None:
                mid = (p + prev) / 2
                tang = (p - prev)
                out = V((0, math.cos(a), math.sin(a)))
                rbox(V((sx * 0.97, mid.y, mid.z)) + out * 0.03, (0.5, tang.length + 0.02, 0.06),
                     "Olive", "body", rot=frame_from_dir(tang, out), bevel=0.15, segments=1)
                # rolled outer lip
                rbox(V((x_out, mid.y, mid.z)) + out * 0.02, (0.05, tang.length + 0.02, 0.12),
                     "Olive", "body", rot=frame_from_dir(tang, out), bevel=0.3, segments=1)
            prev = p
        # flat fender top running into the bonnet side
        hull([V((x_in, FRONT_Y - 0.2, WHEEL_R + r_in)), V((x_in, FRONT_Y + 0.4, WHEEL_R + r_in - 0.1)),
              V((x_in, FRONT_Y - 0.2, WHEEL_R + r_in + 0.06)),
              V((sx * 0.84, CAB_FRONT, 1.25)), V((sx * 0.84, CAB_FRONT, 1.0)),
              V((sx * CAB_X, CAB_FRONT, 1.0)), V((sx * CAB_X, CAB_FRONT, 1.15))], "Olive", "body")
        # running board / step under the door
        rbox(V((sx * 1.08, 0.75, 0.68)), (0.32, 1.3, 0.06), "Olive", "body", bevel=0.2)
        for i in range(8):
            rbox(V((sx * 1.08, 0.2 + i * 0.15, 0.715)), (0.26, 0.04, 0.015), "OliveDark", "body",
                 bevel=0.0)
        for y in (0.25, 1.25):
            rbox(V((sx * 0.98, y, 0.82)), (0.05, 0.06, 0.26), "DarkMetal", "body", bevel=0.2)
        # inner apron between the cab and the rear of the arch
        hull([V((sx * 0.75, CAB_FRONT, 0.68)), V((sx * 1.21, CAB_FRONT, 0.68)),
              V((sx * 0.75, CAB_FRONT + 0.12, 0.68)), V((sx * 1.21, CAB_FRONT + 0.12, 0.68)),
              V((sx * 0.75, CAB_FRONT, 1.05)), V((sx * 1.21, CAB_FRONT, 1.05))], "Olive", "body")


def bumper():
    by, bz = BUMPER_Y, 0.78
    rbox(V((0, by, bz)), (2.3, 0.2, 0.26), "Olive", "body", bevel=0.15)
    for sx in (-1, 1):  # angled ends
        rbox(V((sx * 1.22, by - 0.12, bz)), (0.12, 0.3, 0.26), "Olive", "body",
             rot=rot_xyz(0, 0, sx * 35), bevel=0.15)
        # brackets back to the frame
        rbox(V((sx * 0.45, (by + NOSE_Y) / 2 - 0.1, bz)), (0.12, by - NOSE_Y + 0.2, 0.16),
             "OliveDark", "body", bevel=0.2)
        for x in (0.75, 1.0):
            ellipsoid(V((sx * x, by + 0.1, bz + 0.06)), (0.02, 0.015, 0.02), "Steel", "body",
                      seg=6, rings=4)
    # tow plate and shackle
    rbox(V((0.35, by + 0.1, bz - 0.02)), (0.22, 0.04, 0.18), "OliveDark", "body", bevel=0.2)
    torus(V((0.35, by + 0.17, bz - 0.13)), 0.07, 0.018, "Steel", "body",
          rot=rot_xyz(0, 90, 0), n=14, k=6, arc=(180, 360))
    tube(V((0.27, by + 0.17, bz - 0.13)), V((0.43, by + 0.17, bz - 0.13)), 0.022, 0.022, "Steel",
         "body", n=6, rings=1)
    rbox(V((-0.35, by + 0.1, bz)), (0.16, 0.04, 0.12), "DarkMetal", "body", bevel=0.2)


def chassis():
    for sx in (-1, 1):
        rbox(V((sx * 0.45, (BUMPER_Y + BED_FRONT) / 2, 0.72)), (0.12, BUMPER_Y - BED_FRONT, 0.2),
             "DarkMetal", "body", bevel=0.1)
        # leaf spring and shackles over the front axle
        for i, w in enumerate((1.1, 0.95, 0.8)):
            rbox(V((sx * 0.62, FRONT_Y, 0.66 - i * 0.03)), (0.1, w, 0.025), "DarkMetal", "body",
                 bevel=0.0)
        # steering arm
        tube(V((sx * 0.62, FRONT_Y + 0.3, 0.52)), V((sx * 0.25, FRONT_Y + 0.35, 0.52)), 0.02,
             0.02, "DarkMetal", "body", n=6, rings=1)
    tube(V((-0.82, FRONT_Y, WHEEL_R)), V((0.82, FRONT_Y, WHEEL_R)), 0.07, 0.07, "DarkMetal",
         "body", n=10, rings=1)
    ellipsoid(V((0.0, FRONT_Y, WHEEL_R)), (0.2, 0.18, 0.16), "DarkMetal", "body", seg=10, rings=6)
    # engine sump and gearbox under the bonnet, drive shaft back to the sprockets
    rbox(V((0, 2.1, 0.95)), (0.7, 1.1, 0.4), "DarkMetal", "body", bevel=0.1)
    tube(V((0, 1.5, 0.75)), V((0, BED_FRONT - 0.2, 0.68)), 0.05, 0.05, "DarkMetal", "body", n=8,
         rings=1)
    # cab floor pan
    rbox(V((0, (CAB_BACK + CAB_FRONT) / 2, CAB_FLOOR - 0.04)), (2 * CAB_X - 0.1, CAB_FRONT -
         CAB_BACK, 0.08), "DarkMetal", "body", bevel=0.2)


# --------------------------------------------------------------------------
# Tracks
# --------------------------------------------------------------------------

def convex_hull_2d(pts):
    pts = sorted(set(pts))

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]  # counter-clockwise


def track_path(wheels, pad, spacing):
    """Evenly spaced (point, tangent) pairs round the convex hull of the wheels, in the YZ
    plane, `pad` outside their rims."""
    pts = []
    for y, z, r in wheels:
        for i in range(72):
            a = 2 * math.pi * i / 72
            pts.append((round(y + math.cos(a) * (r + pad), 5), round(z + math.sin(a) * (r + pad), 5)))
    loop = convex_hull_2d(pts)
    loop.append(loop[0])
    seglen = [math.dist(a, b) for a, b in zip(loop, loop[1:])]
    total = sum(seglen)
    count = int(total / spacing)
    step = total / count
    out = []
    i, acc = 0, 0.0
    for k in range(count):
        s = k * step
        while acc + seglen[i] < s:
            acc += seglen[i]
            i += 1
        t = (s - acc) / seglen[i]
        a, b = loop[i], loop[i + 1]
        p = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        d = ((b[0] - a[0]) / seglen[i], (b[1] - a[1]) / seglen[i])
        out.append((p, d))
    return out


def road_wheel(c, r, sx):
    axle_disc(c, r, 0.36, "Tyre", "body", n=22)  # rubber tyres
    axle_disc(c + V((sx * 0.01, 0, 0)), r - 0.06, 0.38, "Olive", "body", n=22)
    hub = c + V((sx * 0.19, 0, 0))
    tube(hub, hub + V((sx * 0.05, 0, 0)), 0.11, 0.08, "OliveDark", "body", n=14, rings=1)
    for i in range(6):
        a = 2 * math.pi * i / 6
        ellipsoid(hub + V((sx * 0.005, math.cos(a) * 0.15, math.sin(a) * 0.15)),
                  (0.015, 0.018, 0.018), "Steel", "body", seg=6, rings=4)
    torus(hub, r - 0.1, 0.015, "OliveDark", "body", rot=rot_xyz(0, 90, 0), n=20, k=5)


def sprocket(c, r, sx):
    for dx in (-0.12, 0.12):
        axle_disc(c + V((dx, 0, 0)), r - 0.04, 0.06, "Olive", "body", n=24)
        for i in range(13):
            a = 2 * math.pi * (i + 0.5) / 13
            out = V((0, math.cos(a), math.sin(a)))
            rbox(c + V((dx, 0, 0)) + out * (r - 0.02), (0.06, 0.08, 0.1), "Olive", "body",
                 rot=frame_from_dir(V((0, -out.z, out.y)), out), bevel=0.0, taper=0.6)
        # lightening holes
        for i in range(6):
            a = 2 * math.pi * i / 6
            p = c + V((dx + sx * 0.032, math.cos(a) * 0.17, math.sin(a) * 0.17))
            tube(p - V((0.005, 0, 0)), p + V((0.005, 0, 0)), 0.045, 0.045, "Grille", "body",
                 n=10, rings=1)
    axle_disc(c, 0.1, 0.3, "OliveDark", "body", n=14)
    tube(c + V((sx * 0.15, 0, 0)), c + V((sx * 0.25, 0, 0)), 0.12, 0.09, "OliveDark", "body",
         n=14, rings=1)


def tracks():
    wheels = [SPROCKET, IDLER] + ROAD
    links = track_path(wheels, 0.035, 0.155)
    for sx in (-1, 1):
        x = sx * TRK_X
        for i, ((y, z), (ty, tz)) in enumerate(links):
            p = V((x, y, z))
            out = V((0, tz, -ty))  # hull is counter-clockwise in (y, z): outward is to the right
            tang = V((0, ty, tz))
            rot = frame_from_dir(tang, out)
            rbox(p, (TRK_W, 0.145, 0.05), "Track", "body", rot=rot, bevel=0.0)
            # grouser bar on the outside, guide horn on the inside
            rbox(p + out * 0.03, (TRK_W - 0.04, 0.04, 0.02), "Track", "body", rot=rot,
                 bevel=0.0)
            rbox(p - out * 0.05, (0.05, 0.07, 0.06), "Track", "body", rot=rot, bevel=0.0)
            # end connectors
            for ex in (-1, 1):
                rbox(p + V((ex * (TRK_W / 2 + 0.015), 0, 0)), (0.03, 0.06, 0.06), "DarkMetal",
                     "body", rot=rot, bevel=0.0)
        sprocket(V((x, SPROCKET[0], SPROCKET[1])), SPROCKET[2], sx)
        road_wheel(V((x, IDLER[0], IDLER[1])), IDLER[2], sx)
        for y, z, r in ROAD:
            road_wheel(V((x, y, z)), r, sx)
            # suspension arm up to the hull
            tube(V((sx * 0.68, y + 0.3, 0.75)), V((sx * 0.7, y, z)), 0.04, 0.04, "DarkMetal",
                 "body", n=8, rings=1)
        # return rollers on the top run
        for y in (-1.4, -2.6):
            axle_disc(V((x, y, 0.92)), 0.06, 0.2, "OliveDark", "body", n=10)


# --------------------------------------------------------------------------
# Bed, skirts and stowage
# --------------------------------------------------------------------------

def bed():
    # hull belly between the tracks
    rbox(V((0, (BED_BACK + BED_FRONT) / 2 + 0.05, 1.0)), (2 * 0.68, BED_FRONT - BED_BACK - 0.2,
         0.6), "OliveDark", "body", bevel=0.1)
    # deck over the tracks
    rbox(V((0, (BED_BACK + BED_FRONT) / 2, SKIRT_Z[1] - 0.03)),
         (2 * SKIRT_X, BED_FRONT - BED_BACK, 0.06), "Olive", "body", bevel=0.2)
    # skirt panels: a raked front plate and three bolted panels down each side
    panels = [(-0.95, -0.35), (-1.95, -0.98), (-2.95, -1.98), (BED_BACK + 0.02, -2.98)]
    z0, z1 = SKIRT_Z
    for sx in (-1, 1):
        for i, (y0, y1) in enumerate(panels):
            c = V((sx * SKIRT_X, (y0 + y1) / 2, (z0 + z1) / 2))
            rbox(c, (0.06, y1 - y0, z1 - z0), "Olive", "body", bevel=0.12)
            for y in (y0 + 0.07, y1 - 0.07):
                for z in (z0 + 0.08, z1 - 0.08):
                    ellipsoid(V((sx * (SKIRT_X + 0.03), y, z)), (0.015, 0.02, 0.02), "Steel",
                              "body", seg=6, rings=4)
        # raked mudguard over the sprocket, up to the cab back
        hull([V((sx * (SKIRT_X - 0.03), -0.35, z1)), V((sx * (SKIRT_X + 0.03), -0.35, z1)),
              V((sx * (SKIRT_X - 0.03), -0.35, z0 + 0.1)), V((sx * (SKIRT_X + 0.03), -0.35, z0 + 0.1)),
              V((sx * (SKIRT_X - 0.03), 0.02, z1)), V((sx * (SKIRT_X + 0.03), 0.02, z1)),
              V((sx * (SKIRT_X - 0.03), 0.08, 1.02)), V((sx * (SKIRT_X + 0.03), 0.08, 1.02))],
             "Olive", "body")
        hull([V((sx * 0.68, 0.02, z1)), V((sx * 0.68, 0.08, 1.02)), V((sx * SKIRT_X, 0.02, z1)),
              V((sx * SKIRT_X, 0.08, 1.02)), V((sx * 0.68, -0.05, z1)),
              V((sx * SKIRT_X, -0.05, z1))], "Olive", "body")
        # rear plate behind the idler
        rbox(V((sx * 0.95, BED_BACK + 0.03, (z0 + z1) / 2)), (0.5, 0.06, z1 - z0), "Olive",
             "body", bevel=0.12)
    # raised bed box: open top, walls round a floor
    t = 0.07
    yc, ly = (BED_BACK + BED_FRONT) / 2, BED_FRONT - BED_BACK
    hz = BED_TOP - SKIRT_Z[1]
    zc = SKIRT_Z[1] + hz / 2
    for sx in (-1, 1):
        rbox(V((sx * (BED_X - t / 2), yc, zc)), (t, ly, hz), "Olive", "body", bevel=0.15)
        rbox(V((sx * BED_X, yc, BED_TOP)), (0.1, ly + 0.04, 0.05), "OliveDark", "body", bevel=0.2)
        for y in (-0.9, -1.7, -2.5, -3.3):  # stiffening ribs on the outside
            rbox(V((sx * (BED_X + 0.015), y, zc)), (0.04, 0.06, hz - 0.04), "Olive", "body",
                 bevel=0.2)
    for y in (BED_BACK + t / 2, BED_FRONT - t / 2):
        rbox(V((0, y, zc)), (2 * BED_X, t, hz), "Olive", "body", bevel=0.15)
        rbox(V((0, y, BED_TOP)), (2 * BED_X + 0.04, 0.1, 0.05), "OliveDark", "body", bevel=0.2)
    # tail lamps and tow hook
    for sx in (-1, 1):
        rbox(V((sx * 0.7, BED_BACK - 0.01, BED_TOP - 0.18)), (0.12, 0.04, 0.08), "Grille", "body",
             bevel=0.2)
    rbox(V((0, BED_BACK - 0.06, 1.0)), (0.2, 0.14, 0.14), "DarkMetal", "body", bevel=0.2)
    # tall stowage locker on the right, behind the cab
    rbox(V((0.48, BED_FRONT - 0.32, 2.12)), (0.72, 0.5, 0.6), "Olive", "body", bevel=0.08)
    rbox(V((0.48, BED_FRONT - 0.32, 2.43)), (0.76, 0.54, 0.04), "OliveDark", "body", bevel=0.3)
    for x in (0.25, 0.71):
        rbox(V((x, BED_FRONT - 0.58, 2.25)), (0.08, 0.02, 0.06), "Steel", "body", bevel=0.2)


def jerrycan(c, yaw=0.0):
    r = rot_xyz(0, 0, yaw)

    def at(p):
        return c + (r @ V(p).to_4d()).to_3d()

    rbox(c, (0.17, 0.35, 0.47), "Jerry", "body", rot=r, bevel=0.12)
    # pressed X on both faces
    for sx in (-1, 1):
        for ang in (35, -35):
            rbox(at((sx * 0.087, 0, -0.02)), (0.012, 0.03, 0.42), "OliveDark", "body",
                 rot=r @ rot_xyz(ang, 0, 0), bevel=0.0)
    pipe([at(p) for p in ((0, -0.12, 0.23), (0, -0.1, 0.3), (0, 0.04, 0.3), (0, 0.06, 0.23))],
         0.015, "Jerry", "body", n=5)
    tube(at((0, 0.12, 0.23)), at((0, 0.12, 0.29)), 0.032, 0.032, "Jerry", "body", n=8, rings=1)


def crate(c, size, yaw=0.0):
    r = rot_xyz(0, 0, yaw)
    rbox(c, size, "AmmoBox", "body", rot=r, bevel=0.08)
    rbox(c + V((0, 0, size[2] / 2 - 0.01)), (size[0] + 0.02, size[1] + 0.02, 0.06), "AmmoBox",
         "body", rot=r, bevel=0.25)
    for s in (-1, 1):  # latches and handles
        off = (r @ V((s * size[0] / 4, size[1] / 2 + 0.01, 0.02)).to_4d()).to_3d()
        rbox(c + off, (0.05, 0.02, 0.09), "DarkMetal", "body", rot=r, bevel=0.2)
        side = (r @ V((s * (size[0] / 2 + 0.015), 0, 0.05)).to_4d()).to_3d()
        rbox(c + side, (0.02, 0.12, 0.03), "DarkMetal", "body", rot=r, bevel=0.2)


def stowage():
    shelf = SKIRT_Z[1]
    xs = (BED_X + SKIRT_X) / 2 + 0.02
    for sx in (-1, 1):
        crate(V((sx * xs, -1.25, shelf + 0.17)), (0.44, 0.62, 0.34), 90)
        crate(V((sx * xs, -2.05, shelf + 0.14)), (0.42, 0.52, 0.28), 90)
        crate(V((sx * xs, -2.7, shelf + 0.17)), (0.44, 0.58, 0.34), 90)
        crate(V((sx * xs, -2.05, shelf + 0.38)), (0.36, 0.42, 0.2), 90)
    jerrycan(V((xs + 0.02, -0.58, shelf + 0.24)), 0)
    jerrycan(V((-xs - 0.02, -0.58, shelf + 0.24)), 0)
    jerrycan(V((-xs, BED_BACK + 0.32, shelf + 0.24)), 0)
    jerrycan(V((xs, BED_BACK + 0.32, shelf + 0.24)), 0)
    jerrycan(V((-0.5, BED_FRONT - 0.3, shelf + 0.24)), 90)
    # straps over the side crates
    for sx in (-1, 1):
        for y in (-1.25, -2.7):
            rbox(V((sx * xs, y, shelf + 0.35)), (0.47, 0.05, 0.02), "OliveDark", "body",
                 bevel=0.0)


# --------------------------------------------------------------------------
# Launcher (its own node)
# --------------------------------------------------------------------------

def pedestal():
    c = TT
    tube(V((c.x, c.y, SKIRT_Z[1])), c - V((0, 0, 0.1)), 0.62, 0.6, "Olive", "body", n=32,
         rings=1)
    tube(c - V((0, 0, 0.12)), c, 0.72, 0.72, "OliveDark", "body", n=32, rings=1)  # flange
    for i in range(16):
        a = 2 * math.pi * i / 16
        ellipsoid(c + V((math.cos(a) * 0.66, math.sin(a) * 0.66, 0.0)), (0.025, 0.025, 0.02),
                  "Steel", "body", seg=6, rings=4)


def missile(tail, d, group):
    """A two-stage missile from `tail` along d: ogive nose, body bands, mid and tail fins."""
    d = d.normalized()
    length, r = 2.75, 0.085
    u = d.cross(V((1, 0, 0))).normalized()
    v = d.cross(u).normalized()
    nose0 = tail + d * (length - 0.5)
    tube(tail, nose0, r, r, "Olive", group, n=16, rings=1)
    ellipsoid(nose0, (r, r, 0.5), "Olive", group, seg=16, rings=10, rot=look_matrix(tail, nose0),
              cut=0.0)
    tube(tail - d * 0.08, tail, r * 0.75, r, "DarkMetal", group, n=12, rings=1)  # nozzle
    for t in (0.9, 1.75):
        p = tail + d * t
        tube(p, p + d * 0.035, r + 0.004, r + 0.004, "Band", group, n=16, rings=1)
    # booster joint ring
    p = tail + d * 1.0
    tube(p, p + d * 0.03, r + 0.012, r + 0.012, "OliveDark", group, n=16, rings=1)

    def fins(at, root, tip_back, span, thick, sweep_back):
        for k in range(4):
            a = math.radians(45 + 90 * k)
            out = u * math.cos(a) + v * math.sin(a)
            side = d.cross(out).normalized() * thick / 2
            root_f = at + out * r * 0.9
            root_b = at - d * root + out * r * 0.9
            tip_f = at - d * sweep_back + out * (r + span)
            tip_b = at - d * (sweep_back + tip_back) + out * (r + span)
            hull([p + s for p in (root_f, root_b, tip_f, tip_b) for s in (side, -side)], "Olive",
                 group)

    fins(tail + d * 1.62, 0.36, 0.05, 0.13, 0.02, 0.3)  # mid canards (delta)
    fins(tail + d * 0.36, 0.32, 0.1, 0.15, 0.02, 0.18)  # tail fins
    return u, v


def launcher():
    g = "launcher"
    c = TT
    # slewing ring and gear on the pedestal, turntable disk with a rim and ribs
    tube(c, c + V((0, 0, 0.18)), 0.55, 0.55, "OliveDark", g, n=32, rings=1)
    for i in range(36):
        a = 2 * math.pi * i / 36
        rbox(c + V((math.cos(a) * 0.56, math.sin(a) * 0.56, 0.09)), (0.04, 0.05, 0.12),
             "DarkMetal", g, rot=rot_xyz(0, 0, math.degrees(a)), bevel=0.0)
    tube(c + V((0, 0, 0.16)), V((c.x, c.y, DISK_Z)), 0.4, 0.4, "Olive", g, n=24, rings=1)
    disk0 = V((c.x, c.y, DISK_Z))
    tube(disk0, disk0 + V((0, 0, 0.08)), 0.98, 0.98, "Olive", g, n=48, rings=1)
    torus(disk0 + V((0, 0, 0.08)), 0.95, 0.03, "OliveDark", g, n=48, k=6)
    torus(disk0 + V((0, 0, -0.005)), 0.9, 0.025, "OliveDark", g, n=48, k=6)
    for i in range(24):
        a = 2 * math.pi * i / 24
        ellipsoid(disk0 + V((math.cos(a) * 0.86, math.sin(a) * 0.86, 0.085)), (0.02, 0.02, 0.015),
                  "Steel", g, seg=6, rings=4)
    for yaw in (0, 90):  # cross ribs over the top
        rbox(disk0 + V((0, 0, 0.11)), (1.7, 0.1, 0.06), "Olive", g, rot=rot_xyz(0, 0, yaw),
             bevel=0.25)
    tube(disk0 + V((0, 0, 0.08)), disk0 + V((0, 0, 0.2)), 0.22, 0.2, "OliveDark", g, n=20,
         rings=1)
    # hatch plates on the disk
    for y in (-0.55, 0.55):
        rbox(disk0 + V((0, y, 0.095)), (0.42, 0.24, 0.03), "OliveDark", g, bevel=0.3)

    # one launch arm per missile, pointing back over the bed
    a = math.radians(ELEV)
    d = V((0, -math.cos(a), math.sin(a)))
    n = V((0, math.sin(a), math.cos(a)))  # up, perpendicular to the rail
    for sx in (-1, 1):
        x = sx * MISSILE_X
        pivot = V((x, c.y + 0.1, DISK_Z + 0.62))
        base = V((x, c.y + 0.1, DISK_Z + 0.08))
        # trunnion: two cheek plates and a cross pin
        for dx in (-0.11, 0.11):
            hull([base + V((dx + s, yy, 0)) for s in (-0.02, 0.02) for yy in (-0.24, 0.24)] +
                 [pivot + V((dx + s, yy, zz)) for s in (-0.02, 0.02) for yy in (-0.08, 0.08)
                  for zz in (-0.06, 0.06)], "Olive", g)
        rbox(base + V((0, 0, 0.04)), (0.34, 0.56, 0.08), "OliveDark", g, bevel=0.2)
        tube(pivot - V((0.16, 0, 0)), pivot + V((0.16, 0, 0)), 0.05, 0.05, "Steel", g, n=10,
             rings=1)
        # rail under the missile
        rail_c = pivot - d * 0.05 + n * 0.08
        rbox(rail_c, (0.1, 1.5, 0.1), "Olive", g, rot=frame_from_dir(d, n), bevel=0.2)
        rbox(rail_c + n * 0.06, (0.05, 1.45, 0.03), "DarkMetal", g, rot=frame_from_dir(d, n),
             bevel=0.0)
        for t in (-0.55, 0.25):  # shoes holding the missile
            rbox(rail_c + d * t + n * 0.1, (0.07, 0.08, 0.1), "OliveDark", g,
                 rot=frame_from_dir(d, n), bevel=0.2)
        # elevation ram from the disk to the rail
        ram0 = V((x, c.y + 0.75, DISK_Z + 0.1))
        ram1 = rail_c + d * 0.55 - n * 0.04
        tube(ram0, ram0 + (ram1 - ram0) * 0.55, 0.05, 0.05, "OliveDark", g, n=10, rings=1)
        tube(ram0 + (ram1 - ram0) * 0.5, ram1, 0.03, 0.03, "Steel", g, n=8, rings=1)
        rbox(ram0, (0.14, 0.14, 0.08), "OliveDark", g, bevel=0.2)
        # the missile, tail just behind the pivot
        tail = rail_c - d * 0.75 + n * 0.19
        missile(tail, d, g)


# --------------------------------------------------------------------------
# Front wheels
# --------------------------------------------------------------------------

def truck_tyre(group, centre, side, seg=56, prof=16, lugs=22):
    rc, a, b, p = WHEEL_R - 0.17, 0.17, TYRE_W / 2, 4.0
    bm = bmesh.new()
    rings = []
    for i in range(seg):
        th = 2 * math.pi * i / seg
        ring = []
        for j in range(prof):
            phi = 2 * math.pi * j / prof
            s, c = math.sin(phi), math.cos(phi)
            x = b * math.copysign(abs(s) ** (2 / p), s)
            rho = rc + a * math.copysign(abs(c) ** (2 / p), c)
            ring.append(bm.verts.new((x, math.cos(th) * rho, math.sin(th) * rho)))
        rings.append(ring)
    for i in range(seg):
        r0, r1 = rings[i], rings[(i + 1) % seg]
        for j in range(prof):
            k = (j + 1) % prof
            bm.faces.new((r0[j], r0[k], r1[k], r1[j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    add(bm, "Tyre", group, True, Matrix.Translation(centre))
    # chevron tread lugs, alternating sides
    for i in range(lugs * 2):
        th = 2 * math.pi * i / (lugs * 2)
        s = 1 if i % 2 else -1
        radial = V((0, math.cos(th), math.sin(th)))
        rot = rot_xyz(math.degrees(th) - 90, 0, 0) @ rot_xyz(0, 0, s * 25)
        rbox(centre + V((s * 0.085, 0, 0)) + radial * (WHEEL_R - 0.005),
             (0.17, 0.075, 0.05), "Tyre", group, rot=rot, bevel=0.0)
    # olive dished rim, hub and wheel nuts
    out = V((side, 0, 0))
    tube(centre - out * 0.12, centre + out * 0.1, 0.27, 0.27, "Olive", group, n=28, rings=1)
    torus(centre + out * 0.1, 0.26, 0.02, "OliveDark", group, rot=rot_xyz(0, 90, 0), n=28, k=5)
    tube(centre + out * 0.1, centre + out * 0.15, 0.15, 0.12, "Olive", group, n=20, rings=1)
    tube(centre + out * 0.15, centre + out * 0.2, 0.065, 0.05, "OliveDark", group, n=12, rings=1)
    for i in range(8):
        ang = 2 * math.pi * i / 8
        dvec = V((0, math.cos(ang), math.sin(ang)))
        ellipsoid(centre + out * 0.15 + dvec * 0.1, (0.014, 0.016, 0.016), "Steel", group, seg=6,
                  rings=4)
        ellipsoid(centre + out * 0.1 + dvec * 0.21, (0.02, 0.03, 0.03), "Grille", group, seg=6,
                  rings=4)  # vent holes in the dish


def main():
    args = parse_args({"out": "assets/models/ironbound/units/missile_truck.glb", "render": None})
    bpy.ops.wm.read_factory_settings(use_empty=True)
    cab()
    bonnet()
    fenders()
    bumper()
    chassis()
    tracks()
    bed()
    stowage()
    pedestal()
    launcher()
    hubs = {}
    for side, tag in ((-1, "L"), (1, "R")):
        name = f"Wheel_F{tag}"
        hubs[name] = V((side * TRACK_X, FRONT_Y, WHEEL_R))
        truck_tyre(name, hubs[name], side)
    objects = []
    body, _ = merge("Body", groups={"body"})
    objects.append(body)
    launch, _ = merge("Launcher", groups={"launcher"})
    set_origin(launch, TT)
    launch.parent = body
    objects.append(launch)
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
            ("three_quarter", -55, 25, 2.3, wide), ("side", -90, 0, 2.0, wide),
            ("front", 0, 10, 2.4, wide), ("back", 155, 25, 2.7, wide),
            ("ref_angle", 55, 22, 2.3, wide), ("game_angle", -35, 50, 2.3, (800, 800)),
        ], target=(0, 0, 0.55))


main()
