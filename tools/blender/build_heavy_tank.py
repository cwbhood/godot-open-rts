"""Builds the Heavy Tank: an olive main battle tank with bolted reactive-armour skirts, an
angular turret with team-coloured armour plates and hazard stripes, a long gun with a bore
evacuator and box muzzle brake, a cupola, sights, a searchlight, a roof machine gun and
stowage crates on the bustle. Exports a GLB at in-game size (same scale as the raider).

    python3 tools/blender/build_heavy_tank.py -- --out assets/models/ironbound/units/heavy_tank.glb \
        [--render /tmp/previews]

Modelled in real metres (7.9 m hull, 11 m with the gun), facing +Y, then scaled by
GAME_SCALE. Nodes: Hull (tracks, road wheels, skirts) and Turret (child of Hull, origin at the
centre of the turret ring, gun included) so the game can turn the turret about Z.
"""

import math
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
import bmesh  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
from mesh_kit import (  # noqa: E402
    GAME, PALETTE, V, add, ellipsoid, export_glb, extrude_x, frame_from_dir, merge, parse_args,
    pipe, rbox, render_views, rot_xyz, set_origin, stats, torus, tube,
)

GAME_SCALE = 0.245

PALETTE.update({
    "TeamColor": ((0.22, 0.42, 0.78), 0.55, 0.0),
    "Olive": ((0.23, 0.26, 0.18), 0.75, 0.0),
    "OliveDark": ((0.16, 0.18, 0.13), 0.8, 0.0),
    "OliveWorn": ((0.36, 0.37, 0.31), 0.85, 0.1),
    "TrackSteel": ((0.15, 0.14, 0.13), 0.7, 0.5),
    "Rubber": ((0.08, 0.08, 0.08), 0.9, 0.0),
    "DarkMetal": ((0.12, 0.12, 0.13), 0.5, 0.6),
    "Gunmetal": ((0.22, 0.23, 0.23), 0.45, 0.6),
    "Bore": ((0.03, 0.03, 0.03), 0.9, 0.0),
    "Hazard": ((0.92, 0.72, 0.12), 0.6, 0.0),
    "Glass": ((0.10, 0.13, 0.15), 0.15, 0.2),
    "Lamp": ((1.00, 0.95, 0.80), 0.4, 0.0, 0.5),
    "Strap": ((0.14, 0.15, 0.11), 0.8, 0.0),
})

TRACK_X = 1.52  # track centre line
TRACK_W = 0.62
WHEEL_R = 0.36
WHEEL_Z = 0.46
ROAD_WHEELS = [-2.75 + i * 1.04 for i in range(6)]
SPROCKET = (-3.38, 0.80, 0.36)  # y, z, r (rear drive)
IDLER = (3.28, 0.82, 0.33)  # front idler
DECK = 1.68
RING = V((0.0, -0.35, DECK))  # turret ring centre = turret origin
TURRET_Z = (1.71, 2.64)
GUN_Z = 2.12
TURRET_PLAN = [  # top view (x, y), counter-clockwise from the front
    (0.52, 2.0), (-0.52, 2.0), (-1.45, 1.0), (-1.52, -1.45), (-1.3, -2.3), (1.3, -2.3),
    (1.52, -1.45), (1.45, 1.0),
]

rng = random.Random(7)


def bolt(p, n, group, r=0.035):
    """Hex-ish bolt head on a surface at p facing n."""
    n = Vector(n).normalized()
    tube(p, p + n * 0.025, r, r * 0.85, "Gunmetal", group, n=6, rings=1)


def scratch(c, n, group, length=0.3):
    """A thin, lighter scuff on a surface at c facing n (painted wear stand-in)."""
    n = Vector(n).normalized()
    up = V((0, 0, 1)) if abs(n.z) < 0.9 else V((0, 1, 0))
    t = n.cross(up).normalized()
    b = n.cross(t)
    a = rng.uniform(-0.7, 0.7)
    d = t * math.cos(a) + b * math.sin(a)
    m = frame_from_dir(d, n)
    rbox(c + n * 0.004, (0.018, length, 0.006), "OliveWorn", group, rot=m, bevel=0.0)


# --------------------------------------------------------------------------
# Running gear
# --------------------------------------------------------------------------

def convex_hull(pts):
    pts = sorted(set(pts))
    if len(pts) < 3:
        return pts

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
    return lower[:-1] + upper[:-1]  # counter-clockwise in (y, z)


def track(sx):
    """Links following the belt around the sprocket, road wheels and idler."""
    circles = [(y, WHEEL_Z, WHEEL_R) for y in (ROAD_WHEELS[0], ROAD_WHEELS[-1])]
    circles += [SPROCKET, IDLER]
    pts = []
    for cy, cz, r in circles:
        for i in range(48):
            a = 2 * math.pi * i / 48
            pts.append((round(cy + math.cos(a) * (r + 0.05), 4),
                        round(cz + math.sin(a) * (r + 0.05), 4)))
    hull = convex_hull(pts)
    segs = []
    total = 0.0
    for i, a in enumerate(hull):
        b = hull[(i + 1) % len(hull)]
        seg = math.dist(a, b)
        segs.append((a, b, total, seg))
        total += seg
    count = int(total / 0.19)
    pitch = total / count
    x = sx * TRACK_X
    for k in range(count):
        s = k * pitch
        a, b, start, seg = next((g for g in segs if s < g[2] + g[3]), segs[-1])
        f = (s - start) / seg
        p = (a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f)
        t = V((0, b[0] - a[0], b[1] - a[1])).normalized()
        nrm = V((0, t.z, -t.y))  # outward for a counter-clockwise loop
        c = V((x, p[0], p[1]))
        m = frame_from_dir(t, nrm)
        rbox(c, (TRACK_W, 0.165, 0.08), "TrackSteel", "hull", rot=m, bevel=0.12,
             segments=1)
        for dx in (-0.17, 0.17):  # rubber pads in two rows
            rbox(c + nrm * 0.05 + V((dx, 0, 0)), (0.22, 0.12, 0.03), "Rubber", "hull", rot=m,
                 bevel=0.0)
        rbox(c - nrm * 0.06, (0.05, 0.08, 0.06), "TrackSteel", "hull", rot=m, bevel=0.0)


def road_wheel(c, r, group="hull"):
    rot = rot_xyz(0, 90, 0)
    for dx in (-0.17, 0.17):
        p = c + V((dx, 0, 0))
        tube(p - V((0.1, 0, 0)), p + V((0.1, 0, 0)), r - 0.04, r - 0.04, "OliveDark", group,
             n=20, rings=1)
        torus(p, r - 0.05, 0.05, "Rubber", group, rot=rot, n=20, k=6, scale=(1, 1, 1.8))
    out = 1 if c.x > 0 else -1
    tube(c + V((out * 0.27, 0, 0)), c + V((out * 0.33, 0, 0)), 0.12, 0.09, "Gunmetal", group,
         n=10, rings=1)
    for i in range(6):  # hub bolts
        a = 2 * math.pi * i / 6
        bolt(c + V((out * 0.27, math.cos(a) * 0.19, math.sin(a) * 0.19)), (out, 0, 0), group,
             r=0.022)


def sprocket(sx):
    y, z, r = SPROCKET
    c = V((sx * TRACK_X, y, z))
    for dx in (-0.17, 0.17):
        p = c + V((dx, 0, 0))
        tube(p - V((0.06, 0, 0)), p + V((0.06, 0, 0)), r - 0.06, r - 0.06, "DarkMetal",
             "hull", n=24, rings=1)
        for i in range(12):  # teeth
            a = 2 * math.pi * (i + 0.5 * (dx > 0)) / 12
            q = p + V((0, math.cos(a) * (r - 0.04), math.sin(a) * (r - 0.04)))
            rbox(q, (0.1, 0.09, 0.1), "DarkMetal", "hull", rot=rot_xyz(math.degrees(a), 0, 0),
                 bevel=0.2, segments=1)
    tube(c + V((sx * 0.22, 0, 0)), c + V((sx * 0.32, 0, 0)), 0.16, 0.12, "Gunmetal", "hull",
         n=12, rings=1)


def running_gear():
    for sx in (-1, 1):
        track(sx)
        for y in ROAD_WHEELS:
            road_wheel(V((sx * TRACK_X, y, WHEEL_Z)), WHEEL_R)
        road_wheel(V((sx * TRACK_X, IDLER[0], IDLER[1])), IDLER[2])
        sprocket(sx)
        for y in (-1.6, 0.0, 1.6):  # return rollers
            tube(V((sx * (TRACK_X - 0.12), y, 1.1)), V((sx * (TRACK_X + 0.12), y, 1.1)), 0.1,
                 0.1, "DarkMetal", "hull", n=10, rings=1)
        for y in ROAD_WHEELS:  # suspension arms
            rbox(V((sx * 1.2, y + 0.2, 0.62)), (0.12, 0.5, 0.12), "DarkMetal", "hull",
                 rot=rot_xyz(20, 0, 0), bevel=0.2, segments=1)


# --------------------------------------------------------------------------
# Hull
# --------------------------------------------------------------------------

def hull():
    # lower hull between the tracks with a sloped lower front plate
    extrude_x([(-3.7, 0.38), (3.15, 0.38), (3.95, 1.0), (3.95, 1.3), (-3.7, 1.3)], -1.2, 1.2,
              "OliveDark", "hull", bevel=0.03)
    # upper hull over the tracks: deck with a shallow glacis
    extrude_x([(-3.88, 1.26), (3.72, 1.26), (3.98, 1.36), (2.75, DECK), (-3.88, DECK)],
              -1.97, 1.97, "Olive", "hull", bevel=0.04)
    glacis = -math.degrees(math.atan2(DECK - 1.36, 3.98 - 2.75))
    rbox(V((0, 3.35, 1.55)), (1.6, 1.05, 0.08), "Olive", "hull", rot=rot_xyz(glacis, 0, 0),
         bevel=0.25)  # bolted applique on the glacis
    for x in (-0.72, 0.72):
        for y in (2.92, 3.8):
            bolt(V((x, y, 1.62 - (y - 2.92) * 0.27)), (0, 0.25, 1), "hull")
    # lower front: tow shackles and a centre plate
    rbox(V((0, 3.62, 0.72)), (1.1, 0.05, 0.4), "Olive", "hull", rot=rot_xyz(-52, 0, 0),
         bevel=0.2)
    for x in (-0.82, 0.82):
        rbox(V((x, 3.98, 1.12)), (0.16, 0.12, 0.16), "DarkMetal", "hull", bevel=0.2)
        torus(V((x, 4.05, 0.98)), 0.09, 0.03, "DarkMetal", "hull", rot=rot_xyz(0, 90, 0),
              n=12, k=6, arc=(-200, 20))
        torus(V((x * 0.75, 3.5, 0.6)), 0.08, 0.028, "DarkMetal", "hull",
              rot=rot_xyz(0, 90, 0), n=12, k=6, arc=(-200, 20))
    # driver's hatch and periscopes
    tube(V((0, 2.25, DECK)), V((0, 2.25, DECK + 0.06)), 0.34, 0.32, "OliveDark", "hull", n=18,
         rings=1)
    for i, a in enumerate((-30, 0, 30)):
        d = rot_xyz(0, 0, a)
        p = V((math.sin(math.radians(-a)) * 0.38, 2.25 + math.cos(math.radians(a)) * 0.38,
               DECK + 0.07))
        rbox(p, (0.2, 0.1, 0.12), "OliveDark", "hull", rot=d, bevel=0.2, segments=1)
        rbox(p + V((0, 0.05, 0.01)), (0.15, 0.01, 0.06), "Glass", "hull", rot=d, bevel=0.0)
    # fenders: headlights in guards, stowage boxes
    for sx in (-1, 1):
        lamp_c = V((sx * 1.6, 3.62, DECK + 0.1))
        rbox(lamp_c, (0.3, 0.2, 0.2), "OliveDark", "hull", bevel=0.2)
        ellipsoid(lamp_c + V((0, 0.1, 0)), (0.08, 0.03, 0.08), "Lamp", "hull", seg=10, rings=6)
        pipe([lamp_c + V((-0.16, 0.06, -0.08)), lamp_c + V((-0.16, 0.2, 0.12)),
              lamp_c + V((0.16, 0.2, 0.12)), lamp_c + V((0.16, 0.06, -0.08))], 0.018,
             "DarkMetal", "hull", n=5)
        box = V((sx * 1.55, 2.55, DECK + 0.17))
        rbox(box, (0.55, 0.62, 0.34), "OliveDark", "hull", bevel=0.1)
        rbox(box + V((0, 0, 0.18)), (0.58, 0.65, 0.04), "OliveDark", "hull", bevel=0.25)
        for dy in (-0.16, 0.16):
            rbox(box + V((0, dy, 0.02)), (0.58, 0.04, 0.38), "Strap", "hull", bevel=0.0)
        for y in (-0.6, 0.9):  # small deck boxes along the turret
            rbox(V((sx * 1.62, y, DECK + 0.1)), (0.4, 0.5, 0.2), "OliveDark", "hull",
                 bevel=0.15)
            rbox(V((sx * 1.62, y, DECK + 0.21)), (0.3, 0.12, 0.03), "DarkMetal", "hull",
                 bevel=0.2)
    # engine deck: grille slats, access panels, exhausts
    for i in range(9):
        rbox(V((0, -2.55 - i * 0.12, DECK + 0.01)), (2.1, 0.05, 0.03), "DarkMetal", "hull",
             bevel=0.0)
    rbox(V((0, -3.05, DECK - 0.005)), (2.3, 1.15, 0.02), "Bore", "hull", bevel=0.0)
    for x in (-0.6, 0.6):
        rbox(V((x, -1.95, DECK + 0.02)), (0.9, 0.5, 0.04), "OliveDark", "hull", bevel=0.25)
    for sx in (-1, 1):
        rbox(V((sx * 1.4, -3.92, 1.45)), (0.4, 0.08, 0.26), "DarkMetal", "hull", bevel=0.2)
    # rear plate: toolbox and tow hooks
    rbox(V((0, -3.95, 1.1)), (1.4, 0.2, 0.4), "OliveDark", "hull", bevel=0.12)
    for x in (-0.82, 0.82):
        torus(V((x, -3.78, 0.6)), 0.08, 0.028, "DarkMetal", "hull", rot=rot_xyz(0, 90, 0),
              n=12, k=6, arc=(160, 380))


def skirts():
    """Hanging reactive-armour blocks along the side and a heavy angled front fender."""
    for sx in (-1, 1):
        x = sx * 1.97
        nrm = V((sx, 0, 0))
        y = -3.78
        while y < 1.9:
            w = 0.42
            c = V((x, y + w / 2, 1.0 - 0.03 * ((int((y + 4) / w)) % 2)))
            rbox(c, (0.2, w - 0.025, 1.0), "Olive", "hull", bevel=0.08)
            rbox(c + V((sx * 0.11, 0, 0.4)), (0.03, w - 0.1, 0.14), "OliveDark", "hull",
                 bevel=0.2)
            bolt(c + V((sx * 0.1, -0.12, 0.4)), nrm, "hull")
            bolt(c + V((sx * 0.1, 0.12, 0.4)), nrm, "hull")
            bolt(c + V((sx * 0.1, 0.0, -0.35)), nrm, "hull", r=0.03)
            if rng.random() < 0.6:
                scratch(c + V((sx * 0.1, rng.uniform(-0.1, 0.1), rng.uniform(-0.3, 0.2))), nrm,
                        "hull", rng.uniform(0.15, 0.35))
            y += w
        rbox(V((x, -0.95, 1.53)), (0.24, 5.72, 0.1), "OliveDark", "hull", bevel=0.2)  # top rail
        # front fender block over the idler
        extrude_x([(1.9, 0.52), (3.3, 0.52), (3.85, 0.98), (3.85, 1.56), (1.9, 1.56)],
                  min(x - sx * 0.42, x + sx * 0.04), max(x - sx * 0.42, x + sx * 0.04),
                  "Olive", "hull", bevel=0.05)
        xo = x + sx * 0.05
        rbox(V((xo, 2.85, 1.4)), (0.03, 1.7, 0.12), "OliveDark", "hull", bevel=0.2)
        for yy in (2.1, 2.55, 3.0, 3.45):
            bolt(V((xo, yy, 1.4)), nrm, "hull")
            bolt(V((xo, yy, 0.62)), nrm, "hull", r=0.03)
        for _ in range(4):
            scratch(V((xo - sx * 0.035, rng.uniform(2.1, 3.4), rng.uniform(0.7, 1.25))), nrm,
                    "hull", rng.uniform(0.2, 0.45))
        for _ in range(3):  # scuffs on the fender front face
            scratch(V((x - sx * rng.uniform(0.05, 0.35), 3.86, rng.uniform(1.05, 1.5))),
                    (0, 1, 0), "hull", rng.uniform(0.12, 0.25))


# --------------------------------------------------------------------------
# Turret
# --------------------------------------------------------------------------

def turret_body(segments=2):
    """Angular turret prism from TURRET_PLAN with the roof inset; returns side quads."""
    z0, z1 = TURRET_Z
    cx = sum(p[0] for p in TURRET_PLAN) / len(TURRET_PLAN)
    cy = sum(p[1] for p in TURRET_PLAN) / len(TURRET_PLAN)
    bot = [V((x, y, z0)) for x, y in TURRET_PLAN]
    top = [V((cx + (x - cx) * 0.9, cy + (y - cy) * 0.92, z1)) for x, y in TURRET_PLAN]
    bm = bmesh.new()
    vb = [bm.verts.new(p) for p in bot]
    vt = [bm.verts.new(p) for p in top]
    n = len(TURRET_PLAN)
    bm.faces.new(list(reversed(vb)))
    bm.faces.new(vt)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((vb[i], vb[j], vt[j], vt[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bmesh.ops.bevel(bm, geom=bm.edges[:], offset=0.035, segments=segments, affect="EDGES",
                    profile=0.5, clamp_overlap=True)
    add(bm, "Olive", "turret", False)
    centre = V((cx, cy, (z0 + z1) / 2))
    quads = []
    for i in range(n):
        j = (i + 1) % n
        q = [bot[i], bot[j], top[j], top[i]]
        nrm = (q[1] - q[0]).cross(q[3] - q[0]).normalized()
        if nrm.dot(sum(q, Vector()) / 4 - centre) < 0:
            nrm = -nrm
        quads.append((q, nrm))
    return quads


def plate(quad, nrm, inset=(0.07, 0.08), stripes=True):
    """Team-coloured armour plate with chamfered corners, bolts and hazard stripes."""
    b0, b1, t1, t0 = quad
    along = (b1 - b0).normalized()
    pts = []
    corners = [b0 + along * inset[0] + (t0 - b0) * 0.0, b1 - along * inset[0],
               t1 - (t1 - t0).normalized() * inset[0], t0 + (t1 - t0).normalized() * inset[0]]
    # pull the top and bottom edges in
    corners[0] = corners[0] + (t0 - b0) * inset[1]
    corners[1] = corners[1] + (t1 - b1) * inset[1]
    corners[2] = corners[2] - (t1 - b1) * inset[1]
    corners[3] = corners[3] - (t0 - b0) * inset[1]
    for i in range(4):
        a, b, c = corners[i - 1], corners[i], corners[(i + 1) % 4]
        pts.append(b + (a - b) * 0.16)
        pts.append(b + (c - b) * 0.16)
    bm = bmesh.new()
    back = [bm.verts.new(p + nrm * 0.005) for p in pts]
    front = [bm.verts.new(p + nrm * 0.04) for p in pts]
    bm.faces.new(back)
    bm.faces.new(front)
    k = len(pts)
    for i in range(k):
        j = (i + 1) % k
        bm.faces.new((back[i], back[j], front[j], front[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    add(bm, "TeamColor", "turret", False)
    for p in pts[1::2]:
        bolt(p + nrm * 0.04 + (sum(pts, Vector()) / k - p) * 0.08, nrm, "turret", r=0.03)
    # panel lines across the plate
    mid = sum(pts, Vector()) / k
    up = ((t0 + t1) / 2 - (b0 + b1) / 2).normalized()
    m = frame_from_dir(up, nrm)
    rbox(mid + nrm * 0.042 + along * 0.18, (0.012, (t0 - b0).length * 0.5, 0.004), "OliveDark",
         "turret", rot=m, bevel=0.0)
    if stripes:
        base = (corners[0] + corners[1]) / 2 + up * 0.05 + nrm * 0.043
        length = (corners[1] - corners[0]).length * 0.55
        m2 = frame_from_dir(along, nrm)
        count = 9
        for i in range(count):
            p = base + along * (-length / 2 + length * (i + 0.5) / count)
            rbox(p, (0.05, length / count * 0.95, 0.004), "Hazard" if i % 2 == 0 else "Bore",
                 "turret", rot=m2 @ rot_xyz(0, 0, 0), bevel=0.0)
    for _ in range(2):
        c = mid + along * rng.uniform(-0.3, 0.3) + up * rng.uniform(-0.15, 0.15)
        scratch(c + nrm * 0.04, nrm, "turret", rng.uniform(0.08, 0.2))


def gun():
    z = GUN_Z
    rbox(V((0, 2.12, z)), (0.86, 0.5, 0.62), "Olive", "turret", bevel=0.12)  # mantlet
    rbox(V((0, 2.4, z)), (0.62, 0.3, 0.46), "OliveDark", "turret", bevel=0.15)
    tube(V((0, 2.5, z)), V((0, 3.35, z)), 0.25, 0.22, "Olive", "turret", n=18, rings=1)
    tube(V((0, 3.35, z)), V((0, 3.5, z)), 0.22, 0.19, "OliveDark", "turret", n=18, rings=1)
    tube(V((0, 3.5, z)), V((0, 7.0, z)), 0.17, 0.15, "Olive", "turret", n=18, rings=2)
    tube(V((0, 4.35, z)), V((0, 5.25, z)), 0.18, 0.18, "Olive", "turret", n=18, rings=4,
         bulge=0.05)  # bore evacuator
    for y in (4.35, 5.25):
        torus(V((0, y, z)), 0.18, 0.02, "OliveDark", "turret", rot=rot_xyz(90, 0, 0), n=18,
              k=5)
    # box muzzle brake with side ports and a dark bore
    rbox(V((0, 7.2, z)), (0.46, 0.5, 0.42), "Gunmetal", "turret", bevel=0.2)
    tube(V((0, 7.42, z)), V((0, 7.52, z)), 0.2, 0.19, "Gunmetal", "turret", n=18, rings=1)
    tube(V((0, 7.45, z)), V((0, 7.525, z)), 0.11, 0.11, "Bore", "turret", n=14, rings=1)
    for sx in (-1, 1):
        rbox(V((sx * 0.22, 7.2, z)), (0.03, 0.26, 0.24), "Bore", "turret", bevel=0.0)
    for _ in range(4):
        scratch(V((rng.uniform(-0.1, 0.1), rng.uniform(3.8, 6.8), z + 0.165)), (0, 0, 1),
                "turret", rng.uniform(0.15, 0.3))


def roof_mg(p):
    """Pintle machine gun on the roof, facing forward."""
    tube(p, p + V((0, 0, 0.18)), 0.04, 0.04, "DarkMetal", "turret", n=8, rings=1)
    recv = p + V((0, 0.05, 0.25))
    rbox(recv, (0.11, 0.42, 0.13), "DarkMetal", "turret", bevel=0.15)
    tube(recv + V((0, 0.2, 0.0)), recv + V((0, 0.85, 0.0)), 0.025, 0.025, "DarkMetal", "turret",
         n=8, rings=1)
    tube(recv + V((0, 0.2, 0.0)), recv + V((0, 0.45, 0.0)), 0.04, 0.04, "Gunmetal", "turret",
         n=8, rings=1)
    tube(recv + V((0, 0.8, 0.0)), recv + V((0, 0.9, 0.0)), 0.035, 0.035, "Gunmetal", "turret",
         n=8, rings=1)
    rbox(recv + V((-0.14, 0.02, -0.03)), (0.16, 0.22, 0.16), "OliveDark", "turret", bevel=0.12)
    for sx in (-1, 1):
        pipe([recv + V((sx * 0.03, -0.2, 0)), recv + V((sx * 0.07, -0.3, -0.02)),
              recv + V((sx * 0.07, -0.3, -0.12))], 0.016, "DarkMetal", "turret", n=5)


def crate(c, size, group="turret", yaw=0.0):
    r = rot_xyz(0, 0, yaw)
    rbox(c, size, "OliveDark", group, rot=r, bevel=0.08)
    rbox(c + V((0, 0, size[2] / 2)), (size[0] + 0.02, size[1] + 0.02, 0.03), "Olive", group,
         rot=r, bevel=0.25)
    for f in (-0.28, 0.28):
        off = (r @ V((f * size[0], 0, 0)).to_4d()).to_3d()
        rbox(c + off, (0.05, size[1] + 0.02, size[2] + 0.02), "Strap", group, rot=r, bevel=0.0)
    off = (r @ V((0, size[1] / 2 + 0.01, size[2] * 0.15)).to_4d()).to_3d()
    rbox(c + off, (0.12, 0.03, 0.06), "DarkMetal", group, rot=r, bevel=0.2)


def turret_details():
    top = TURRET_Z[1]
    # ring and lower skirt under the turret
    torus(V((RING.x, RING.y, DECK + 0.02)), 1.25, 0.05, "OliveDark", "turret", n=36, k=6)
    # commander's cupola with periscopes and hatch
    cup = V((0.72, -0.75, top))
    tube(cup, cup + V((0, 0, 0.2)), 0.36, 0.33, "OliveDark", "turret", n=20, rings=1)
    tube(cup + V((0, 0, 0.2)), cup + V((0, 0, 0.26)), 0.3, 0.27, "Olive", "turret", n=20,
         rings=1)
    for i in range(6):
        a = 2 * math.pi * i / 6 + 0.3
        d = V((math.cos(a), math.sin(a), 0))
        m = frame_from_dir(d)
        rbox(cup + d * 0.35 + V((0, 0, 0.11)), (0.14, 0.06, 0.08), "OliveDark", "turret",
             rot=m, bevel=0.2, segments=1)
        rbox(cup + d * 0.385 + V((0, 0, 0.11)), (0.1, 0.01, 0.05), "Glass", "turret", rot=m,
             bevel=0.0)
    rbox(cup + V((0, -0.1, 0.29)), (0.14, 0.1, 0.05), "DarkMetal", "turret", bevel=0.2)
    roof_mg(cup + V((-0.05, 0.3, 0.2)))
    # gunner's primary sight: armoured box with a dark window and doors
    sight = V((-0.62, 0.75, top + 0.24))
    rbox(sight, (0.5, 0.55, 0.48), "Olive", "turret", bevel=0.1)
    rbox(sight + V((0, 0.28, 0.04)), (0.36, 0.02, 0.28), "Bore", "turret", bevel=0.0)
    rbox(sight + V((0, 0.29, 0.04)), (0.28, 0.01, 0.2), "Glass", "turret", bevel=0.0)
    for sx in (-1, 1):
        rbox(sight + V((sx * 0.23, 0.31, 0.04)), (0.03, 0.06, 0.34), "OliveDark", "turret",
             bevel=0.2)
    # loader's hatch, vents and small boxes on the roof
    tube(V((-0.65, -0.75, top)), V((-0.65, -0.75, top + 0.06)), 0.3, 0.28, "OliveDark",
         "turret", n=18, rings=1)
    rbox(V((-0.65, -0.95, top + 0.08)), (0.1, 0.12, 0.05), "DarkMetal", "turret", bevel=0.2)
    rbox(V((0.05, 0.2, top + 0.04)), (0.5, 0.35, 0.08), "OliveDark", "turret", bevel=0.2)
    rbox(V((0.2, -1.5, top + 0.06)), (0.35, 0.3, 0.12), "OliveDark", "turret", bevel=0.2)
    rbox(V((0.0, 1.45, top + 0.03)), (0.6, 0.12, 0.05), "OliveDark", "turret", bevel=0.2)
    # coax machine gun beside the mantlet
    rbox(V((0.62, 2.0, GUN_Z + 0.22)), (0.18, 0.4, 0.16), "DarkMetal", "turret", bevel=0.15)
    tube(V((0.62, 2.2, GUN_Z + 0.22)), V((0.62, 2.75, GUN_Z + 0.22)), 0.025, 0.025,
         "DarkMetal", "turret", n=8, rings=1)
    # searchlight on the right cheek and antenna at the rear
    sl = V((1.2, 0.65, top + 0.2))
    tube(sl + V((0, 0, -0.2)), sl + V((0, 0, -0.08)), 0.03, 0.03, "DarkMetal", "turret", n=8,
         rings=1)
    tube(sl + V((0, -0.12, 0)), sl + V((0, 0.12, 0)), 0.13, 0.14, "OliveDark", "turret", n=16,
         rings=1)
    tube(sl + V((0, 0.12, 0)), sl + V((0, 0.13, 0)), 0.11, 0.11, "Lamp", "turret", n=16,
         rings=1)
    ant = V((-0.35, -1.75, top))
    tube(ant, ant + V((0, 0, 0.12)), 0.06, 0.05, "DarkMetal", "turret", n=8, rings=1)
    tube(ant + V((0, 0, 0.12)), ant + V((0, 0, 1.15)), 0.014, 0.008, "DarkMetal", "turret",
         n=6, rings=1)
    for dz in (0.35, 0.5):
        tube(ant + V((0, 0, dz)), ant + V((0, 0, dz + 0.05)), 0.03, 0.03, "DarkMetal", "turret",
             n=6, rings=1)
    # smoke dischargers on the rear corners of the cheeks
    for sx in (-1, 1):
        base = V((sx * 1.45, -1.55, top - 0.12))
        rbox(base, (0.12, 0.42, 0.22), "OliveDark", "turret", bevel=0.2)
        for i in range(3):
            p = base + V((sx * 0.06, -0.12 + i * 0.12, 0.05))
            tube(p, p + V((sx * 0.18, 0.06, 0.1)), 0.04, 0.04, "OliveDark", "turret", n=8,
                 rings=1)
    # stowage on the bustle: stacked crates at the back and the left rear, a box on top
    for x in (-0.82, -0.27, 0.28, 0.83):
        crate(V((x, -2.55, 1.98)), (0.5, 0.42, 0.4))
    for x in (-0.82, -0.27, 0.28):
        crate(V((x, -2.55, 2.4)), (0.5, 0.42, 0.4))
    for y in (-1.95, -1.45):
        crate(V((-1.72, y, 2.0)), (0.36, 0.46, 0.42), yaw=0)
        crate(V((-1.72, y, 2.43)), (0.36, 0.46, 0.42), yaw=0)
    rbox(V((0, -2.33, 2.0)), (2.1, 0.05, 0.05), "DarkMetal", "turret", bevel=0.2)
    crate(V((0.95, -1.95, top + 0.2)), (0.45, 0.6, 0.38), yaw=8)
    pipe([V((0.68, -1.6, top + 0.4)), V((1.2, -1.65, top + 0.4))], 0.012, "Strap", "turret",
         n=4)


def turret():
    quads = turret_body()
    # quads[i] runs from TURRET_PLAN[i] to [i + 1]: 1 = left cheek, 2 = left side,
    # 6 = right side, 7 = right cheek
    for i in (1, 2, 6, 7):
        q, nrm = quads[i]
        plate(q, nrm, stripes=i in (1, 7))
    for i in (3, 4, 5):  # bolts along the bustle
        q, nrm = quads[i]
        for f in (0.2, 0.5, 0.8):
            p = q[0] + (q[1] - q[0]) * f
            bolt(p + (q[3] - q[0]) * 0.75, nrm, "turret", r=0.03)
    for _ in range(10):  # roof scuffs
        scratch(V((rng.uniform(-1.1, 1.1), rng.uniform(-1.8, 1.6), TURRET_Z[1])), (0, 0, 1),
                "turret", rng.uniform(0.1, 0.3))
    gun()
    turret_details()

# --------------------------------------------------------------------------
# Game mode (Foundry League kit; the same block is in build_tank.py and
# build_heavy_tank.py so the two tanks share palette, tracks and wheels)
# --------------------------------------------------------------------------

FOUNDRY_PALETTE = {
    "TeamColor": ((0.22, 0.42, 0.78), 0.55, 0.0),
    "Olive": ((0.27, 0.30, 0.18), 0.75, 0.0),
    "OliveDark": ((0.19, 0.21, 0.13), 0.8, 0.0),
    "OliveWorn": ((0.36, 0.38, 0.27), 0.85, 0.0),
    "Track": ((0.14, 0.14, 0.14), 0.75, 0.4),
    "Rubber": ((0.08, 0.08, 0.08), 0.9, 0.0),
    "DarkMetal": ((0.12, 0.12, 0.13), 0.5, 0.6),
    "Gunmetal": ((0.21, 0.22, 0.22), 0.45, 0.6),
    "Bore": ((0.03, 0.03, 0.03), 0.9, 0.0),
}


def foundry_game_setup():
    """Segment counts in the game builders are exact; colours stay olive drab, not lime."""
    GAME.update({"segments": 1.0, "min_segments": 3, "saturate": 0.95})
    PALETTE.update(FOUNDRY_PALETTE)


def _unit2(v):
    d = math.hypot(v[0], v[1]) or 1.0
    return (v[0] / d, v[1] / d)


def band_track(x, width, circles, thick, grouser, pitch, group, seg=12):
    """One continuous track belt round the given (y, z, r) wheels: a closed band of
    thickness `thick` plus grouser ridges every `pitch` (none on the hidden top run)."""
    pts = []
    for y, z, r in circles:
        for k in range(seg):
            a = 2 * math.pi * k / seg
            pts.append((round(y + math.cos(a) * r, 5), round(z + math.sin(a) * r, 5)))
    inner = convex_hull(pts)  # counter-clockwise in (y, z)
    n = len(inner)
    outer = []
    for i in range(n):
        a, b, c = inner[i - 1], inner[i], inner[(i + 1) % n]
        n1 = _unit2((b[1] - a[1], -(b[0] - a[0])))
        n2 = _unit2((c[1] - b[1], -(c[0] - b[0])))
        m = _unit2((n1[0] + n2[0], n1[1] + n2[1]))
        s = thick / max(0.5, m[0] * n1[0] + m[1] * n1[1])
        outer.append((b[0] + m[0] * s, b[1] + m[1] * s))
    bm = bmesh.new()
    x0, x1 = x - width / 2, x + width / 2
    rings = [[bm.verts.new((x0, *inner[i])), bm.verts.new((x1, *inner[i])),
              bm.verts.new((x1, *outer[i])), bm.verts.new((x0, *outer[i]))] for i in range(n)]
    for i in range(n):
        A, B = rings[i], rings[(i + 1) % n]
        for k in range(4):
            bm.faces.new((A[k], A[(k + 1) % 4], B[(k + 1) % 4], B[k]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    add(bm, "Track", group, smooth=False)
    segs = list(zip(outer, outer[1:] + outer[:1]))
    total = sum(math.dist(a, b) for a, b in segs)
    count = max(4, round(total / pitch))
    step = total / count
    i, acc = 0, 0.0
    for k in range(count):
        d = (k + 0.5) * step
        while acc + math.dist(*segs[i]) < d:
            acc += math.dist(*segs[i])
            i += 1
        a, b = segs[i]
        ln = math.dist(a, b)
        t = (d - acc) / ln
        ty, tz = (b[0] - a[0]) / ln, (b[1] - a[1]) / ln
        ny, nz = tz, -ty  # outward
        if nz > 0.5:
            continue  # top run, hidden under the fenders
        p = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        c = V((x, p[0] + ny * (grouser / 2 - 0.005), p[1] + nz * (grouser / 2 - 0.005)))
        rbox(c, (width - 0.06, 0.08, grouser + 0.01), "Track", group,
             rot=rot_xyz(math.degrees(math.atan2(tz, ty)), 0, 0), bevel=0.0)


def chunky_wheel(c, r, width, out, group, n=12, cap=True):
    """Road wheel: a rubber drum, an olive hub disc proud of the outer face and a cap."""
    tube(c - V((width / 2, 0, 0)), c + V((width / 2, 0, 0)), r, r, "Rubber", group, n=n)
    face = c + V((out * (width / 2 - 0.01), 0, 0))
    tube(face, face + V((out * 0.05, 0, 0)), r * 0.8, r * 0.74, "OliveDark", group, n=n)
    if cap:
        tube(face + V((out * 0.04, 0, 0)), face + V((out * 0.1, 0, 0)), r * 0.3, r * 0.24,
             "Gunmetal", group, n=6)


def chunky_sprocket(c, r, width, out, group, teeth=8):
    """Drive sprocket: a dark drum with chunky teeth and the same hub as the wheels."""
    tube(c - V((width / 2, 0, 0)), c + V((width / 2, 0, 0)), r - 0.03, r - 0.03, "DarkMetal",
         group, n=teeth * 2)
    xo = out * (width / 2 - 0.06)
    for i in range(teeth):
        a = 2 * math.pi * (i + 0.5) / teeth
        q = c + V((xo, math.cos(a) * (r - 0.02), math.sin(a) * (r - 0.02)))
        rbox(q, (0.12, 0.1, 0.14), "DarkMetal", group,
             rot=rot_xyz(math.degrees(a) - 90, 0, 0), bevel=0.0)
    face = c + V((out * (width / 2 - 0.01), 0, 0))
    tube(face, face + V((out * 0.05, 0, 0)), r * 0.66, r * 0.6, "OliveDark", group, n=10)
    tube(face + V((out * 0.04, 0, 0)), face + V((out * 0.1, 0, 0)), r * 0.3, r * 0.24,
         "Gunmetal", group, n=6)


def game_setup_heavy():
    foundry_game_setup()
    GAME["max_tris"] = 5200  # bigger unit, a little more budget; built to stay under it
    PALETTE["Lamp"] = ((0.85, 0.82, 0.70), 0.4, 0.0)  # no emission: folds into Body
    PALETTE["Glass"] = ((0.10, 0.13, 0.15), 0.3, 0.2)


def game_running_gear():
    for sx in (-1, 1):
        x = sx * TRACK_X
        circles = [(y, WHEEL_Z, WHEEL_R + 0.01) for y in (ROAD_WHEELS[0], ROAD_WHEELS[-1])]
        circles += [(SPROCKET[0], SPROCKET[1], SPROCKET[2] + 0.01),
                    (IDLER[0], IDLER[1], IDLER[2] + 0.01)]
        band_track(x, TRACK_W, circles, 0.08, 0.035, 0.44, "hull")
        for y in ROAD_WHEELS:
            chunky_wheel(V((x, y, WHEEL_Z)), WHEEL_R, 0.48, sx, "hull", n=8, cap=False)
        chunky_wheel(V((x, IDLER[0], IDLER[1])), IDLER[2], 0.48, sx, "hull", n=10)
        chunky_sprocket(V((x, SPROCKET[0], SPROCKET[1])), SPROCKET[2], 0.5, sx, "hull")


def game_hull():
    extrude_x([(-3.7, 0.38), (3.15, 0.38), (3.95, 1.0), (3.95, 1.3), (-3.7, 1.3)], -1.2, 1.2,
              "OliveDark", "hull", bevel=0.04)
    extrude_x([(-3.88, 1.26), (3.72, 1.26), (3.98, 1.36), (2.75, DECK), (-3.88, DECK)],
              -1.97, 1.97, "Olive", "hull", bevel=0.05)
    glacis = -math.degrees(math.atan2(DECK - 1.36, 3.98 - 2.75))
    rbox(V((0, 3.35, 1.55)), (1.6, 1.05, 0.1), "OliveWorn", "hull", rot=rot_xyz(glacis, 0, 0))
    rbox(V((0, 3.62, 0.72)), (1.1, 0.06, 0.4), "Olive", "hull", rot=rot_xyz(-52, 0, 0))
    for x in (-0.82, 0.82):
        rbox(V((x, 3.98, 1.1)), (0.2, 0.16, 0.2), "DarkMetal", "hull", bevel=0.2)
    tube(V((0, 2.25, DECK)), V((0, 2.25, DECK + 0.08)), 0.34, 0.32, "OliveDark", "hull", n=10)
    rbox(V((0, 2.66, DECK + 0.07)), (0.5, 0.14, 0.14), "OliveDark", "hull")
    for sx in (-1, 1):
        lamp_c = V((sx * 1.6, 3.62, DECK + 0.1))
        rbox(lamp_c, (0.3, 0.2, 0.2), "OliveDark", "hull", bevel=0.2)
        rbox(lamp_c + V((0, 0.1, 0)), (0.18, 0.04, 0.12), "Lamp", "hull")
        rbox(V((sx * 1.55, 2.55, DECK + 0.18)), (0.56, 0.64, 0.36), "OliveDark", "hull",
             bevel=0.1)
        for y in (-0.6, 0.9):
            rbox(V((sx * 1.62, y, DECK + 0.1)), (0.42, 0.5, 0.2), "OliveDark", "hull",
                 bevel=0.0)
        rbox(V((sx * 1.4, -3.92, 1.45)), (0.42, 0.1, 0.28), "DarkMetal", "hull")
    # engine deck: one dark grille, two access panels
    rbox(V((0, -3.05, DECK + 0.01)), (2.2, 1.1, 0.03), "DarkMetal", "hull")
    for x in (-0.6, 0.6):
        rbox(V((x, -1.95, DECK + 0.025)), (0.9, 0.5, 0.05), "OliveDark", "hull")
    rbox(V((0, -3.95, 1.1)), (1.4, 0.2, 0.4), "OliveDark", "hull", bevel=0.12)


def game_skirts():
    for sx in (-1, 1):
        x = sx * 1.97
        y0, y1 = -3.78, 1.9
        n = 5
        pw = (y1 - y0) / n
        for i in range(n):
            c = V((x, y0 + pw * (i + 0.5), 1.0 - 0.03 * (i % 2)))
            rbox(c, (0.2, pw - 0.05, 1.0), "Olive", "hull", bevel=0.08)
        rbox(V((x + sx * 0.115, (y0 + y1) / 2, 1.2)), (0.03, y1 - y0 - 0.12, 0.3),
             "TeamColor", "hull")
        rbox(V((x, -0.95, 1.53)), (0.24, 5.72, 0.1), "OliveDark", "hull")  # top rail
        # front fender block over the idler, the team band carried along it
        extrude_x([(1.9, 0.52), (3.3, 0.52), (3.85, 0.98), (3.85, 1.56), (1.9, 1.56)],
                  min(x - sx * 0.42, x + sx * 0.04), max(x - sx * 0.42, x + sx * 0.04),
                  "Olive", "hull", bevel=0.05)
        rbox(V((x + sx * 0.055, 2.8, 1.2)), (0.03, 1.6, 0.3), "TeamColor", "hull")


def game_plate(quad, nrm, shrink=0.12):
    """Plain team-coloured armour plate with chamfered corners on a turret face."""
    b0, b1, t1, t0 = quad
    corners = [b0.lerp(t1, shrink * 0.7), b1.lerp(t0, shrink * 0.7),
               t1.lerp(b0, shrink * 0.7), t0.lerp(b1, shrink * 0.7)]
    pts = []
    for i in range(4):
        a, b, c = corners[i - 1], corners[i], corners[(i + 1) % 4]
        pts.append(b + (a - b) * 0.14)
        pts.append(b + (c - b) * 0.14)
    bm = bmesh.new()
    back = [bm.verts.new(p - nrm * 0.01) for p in pts]
    front = [bm.verts.new(p + nrm * 0.05) for p in pts]
    bm.faces.new(back)
    bm.faces.new(front)
    k = len(pts)
    for i in range(k):
        j = (i + 1) % k
        bm.faces.new((back[i], back[j], front[j], front[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    add(bm, "TeamColor", "turret", False)


def game_roof_plate(scale=0.72):
    """Team-coloured plate covering most of the turret roof."""
    z1 = TURRET_Z[1]
    cx = sum(p[0] for p in TURRET_PLAN) / len(TURRET_PLAN)
    cy = sum(p[1] for p in TURRET_PLAN) / len(TURRET_PLAN)
    plan = [(cx + (x - cx) * 0.9 * scale, cy + (y - cy) * 0.92 * scale) for x, y in TURRET_PLAN]
    bm = bmesh.new()
    lo = [bm.verts.new((x, y, z1 - 0.01)) for x, y in plan]
    hi = [bm.verts.new((x, y, z1 + 0.045)) for x, y in plan]
    bm.faces.new(lo)
    bm.faces.new(hi)
    k = len(plan)
    for i in range(k):
        j = (i + 1) % k
        bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    add(bm, "TeamColor", "turret", False)


def game_gun():
    z = GUN_Z
    rbox(V((0, 2.12, z)), (0.86, 0.5, 0.62), "Olive", "turret", bevel=0.12)  # mantlet
    rbox(V((0, 2.4, z)), (0.62, 0.3, 0.46), "OliveDark", "turret", bevel=0.15)
    tube(V((0, 2.5, z)), V((0, 3.35, z)), 0.25, 0.22, "Olive", "turret", n=10)
    tube(V((0, 3.35, z)), V((0, 3.5, z)), 0.22, 0.19, "OliveDark", "turret", n=10)
    tube(V((0, 3.5, z)), V((0, 7.0, z)), 0.17, 0.15, "Olive", "turret", n=10)
    tube(V((0, 4.35, z)), V((0, 5.25, z)), 0.2, 0.2, "OliveDark", "turret", n=10, rings=2,
         bulge=0.04)  # bore evacuator
    rbox(V((0, 7.2, z)), (0.48, 0.5, 0.44), "Gunmetal", "turret", bevel=0.2)  # muzzle brake
    tube(V((0, 7.44, z)), V((0, 7.52, z)), 0.2, 0.19, "Gunmetal", "turret", n=10)
    tube(V((0, 7.5, z)), V((0, 7.525, z)), 0.12, 0.12, "Bore", "turret", n=8)
    for sx in (-1, 1):
        rbox(V((sx * 0.235, 7.2, z)), (0.03, 0.28, 0.26), "Bore", "turret", bevel=0.0)


def game_turret_details():
    top = TURRET_Z[1]
    tube(V((RING.x, RING.y, DECK - 0.02)), V((RING.x, RING.y, DECK + 0.06)), 1.32, 1.3,
         "OliveDark", "turret", n=12)
    # commander's cupola with a pintle machine gun
    cup = V((0.72, -0.75, top))
    tube(cup, cup + V((0, 0, 0.2)), 0.37, 0.34, "OliveDark", "turret", n=10)
    tube(cup + V((0, 0, 0.2)), cup + V((0, 0, 0.27)), 0.3, 0.27, "Olive", "turret", n=10)
    mg = cup + V((-0.05, 0.3, 0.2))
    tube(mg, mg + V((0, 0, 0.18)), 0.04, 0.04, "DarkMetal", "turret", n=6)
    recv = mg + V((0, 0.05, 0.25))
    rbox(recv, (0.14, 0.44, 0.15), "DarkMetal", "turret")
    tube(recv + V((0, 0.2, 0)), recv + V((0, 0.85, 0)), 0.045, 0.04, "DarkMetal", "turret", n=6)
    rbox(recv + V((-0.15, 0.02, -0.03)), (0.18, 0.24, 0.18), "OliveDark", "turret")
    # gunner's sight: armoured box with a dark window
    sight = V((-0.62, 0.75, top + 0.24))
    rbox(sight, (0.5, 0.55, 0.48), "Olive", "turret", bevel=0.1)
    rbox(sight + V((0, 0.28, 0.04)), (0.36, 0.03, 0.26), "Glass", "turret", bevel=0.0)
    # loader's hatch
    tube(V((-0.62, -1.05, top)), V((-0.62, -1.05, top + 0.09)), 0.3, 0.28, "OliveDark",
         "turret", n=10)
    # coax machine gun beside the mantlet
    rbox(V((0.62, 2.0, GUN_Z + 0.22)), (0.2, 0.4, 0.18), "DarkMetal", "turret", bevel=0.15)
    tube(V((0.62, 2.2, GUN_Z + 0.22)), V((0.62, 2.75, GUN_Z + 0.22)), 0.045, 0.04,
         "DarkMetal", "turret", n=6)
    # searchlight on the right cheek and antenna at the rear
    sl = V((1.2, 0.65, top + 0.2))
    tube(sl + V((0, 0, -0.22)), sl + V((0, 0, -0.08)), 0.05, 0.05, "DarkMetal", "turret", n=6)
    tube(sl + V((0, -0.14, 0)), sl + V((0, 0.12, 0)), 0.15, 0.16, "OliveDark", "turret", n=10)
    tube(sl + V((0, 0.12, 0)), sl + V((0, 0.14, 0)), 0.12, 0.12, "Lamp", "turret", n=10)
    ant = V((-0.35, -1.75, top))
    tube(ant, ant + V((0, 0, 0.14)), 0.08, 0.07, "DarkMetal", "turret", n=6)
    tube(ant + V((0, 0, 0.14)), ant + V((0, 0, 1.15)), 0.03, 0.03, "DarkMetal", "turret", n=4)
    # smoke dischargers on the rear corners of the cheeks
    for sx in (-1, 1):
        base = V((sx * 1.45, -1.55, top - 0.12))
        rbox(base, (0.14, 0.44, 0.24), "OliveDark", "turret")
        for i in range(2):
            p = base + V((sx * 0.06, -0.1 + i * 0.2, 0.05))
            tube(p, p + V((sx * 0.18, 0.06, 0.1)), 0.05, 0.05, "OliveDark", "turret", n=6)
    # stowage on the bustle: a row of crates at the back, a stack on the left rear, one on top
    for x in (-0.82, -0.27, 0.28, 0.83):
        rbox(V((x, -2.55, 1.98)), (0.52, 0.44, 0.42), "OliveDark", "turret", bevel=0.08)
    for x in (-0.82, -0.27, 0.28):
        rbox(V((x, -2.55, 2.4)), (0.52, 0.44, 0.42), "Olive", "turret", bevel=0.08)
    rbox(V((-1.72, -1.7, 2.21)), (0.38, 0.96, 0.84), "OliveDark", "turret", bevel=0.08)
    rbox(V((0.95, -1.95, top + 0.2)), (0.46, 0.62, 0.4), "OliveDark", "turret",
         rot=rot_xyz(0, 0, 8), bevel=0.08)


def game_turret():
    quads = turret_body(segments=1)
    for i in (1, 2, 6, 7):  # cheeks and sides
        q, nrm = quads[i]
        game_plate(q, nrm)
    game_roof_plate()
    game_gun()
    game_turret_details()


def preview_sheet(render_dir, out):
    try:
        from PIL import Image
    except ImportError:
        return
    names = ["three_quarter", "side", "front", "back"]
    ims = [Image.open(os.path.join(render_dir, f"{n}.png")).convert("RGB") for n in names]
    w, h = ims[0].size
    sheet = Image.new("RGB", (w * 2, h * 2), (235, 235, 235))
    for i, im in enumerate(ims):
        sheet.paste(im, ((i % 2) * w, (i // 2) * h))
    sheet.save(out)


def main():
    args = parse_args({"out": "assets/models/ironbound/units/heavy_tank.glb", "render": None})
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if GAME["enabled"]:
        game_setup_heavy()
        game_running_gear()
        game_hull()
        game_skirts()
        game_turret()
    else:
        running_gear()
        hull()
        skirts()
        for _ in range(14):
            scratch(V((rng.uniform(-1.8, 1.8), rng.uniform(-3.6, 2.6), DECK)), (0, 0, 1),
                    "hull", rng.uniform(0.15, 0.4))
        turret()
    body, _ = merge("Hull", groups={"hull"})
    top, _ = merge("Turret", groups={"turret"})
    set_origin(top, RING)
    top.parent = body
    objects = [body, top]
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
            ("three_quarter", 60, 22, 3.1, wide), ("side", 90, 0, 3.0, wide),
            ("front", 0, 10, 2.4, wide), ("back", 215, 28, 3.0, wide),
            ("game_angle", 35, 50, 3.0, (800, 800)),
        ], target=(0, 0.35, 0.35))
        preview_sheet(args["render"], os.path.join(args["render"], "heavy_tank-preview.png"))


main()
