"""Builds the Tank: a stubby riveted olive light tank with armoured side skirts over the
tracks, wedge fenders over the drive sprockets, a hull machine gun, and a round turret with a
short gun and a team-coloured roof. Exports a GLB at in-game size (raider scale, about 1.4 m
long).

    python3 tools/blender/build_tank.py -- --out assets/models/ironbound/units/tank.glb \
        [--render /tmp/previews]

Modelled in real metres (about 5.6 m long), facing +Y, then scaled by GAME_SCALE. The turret
(Turret, origin at the centre of the turret ring, gun included) is a separate node so the game
can turn it about Z. Tracks, road wheels and sprockets are part of the hull.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
from mesh_kit import (  # noqa: E402
    PALETTE, V, ellipsoid, export_glb, extrude_x, look_matrix, merge, parse_args, pipe,
    rbox, render_views, rot_xyz, set_origin, stats, torus, tube,
)

GAME_SCALE = 0.245

PALETTE.update({
    "TeamColor": ((0.22, 0.42, 0.78), 0.55, 0.0),
    "Olive": ((0.29, 0.33, 0.18), 0.7, 0.05),
    "OliveDark": ((0.21, 0.24, 0.13), 0.75, 0.05),
    "OliveWorn": ((0.38, 0.41, 0.27), 0.8, 0.05),
    "Track": ((0.13, 0.13, 0.14), 0.75, 0.4),
    "Rubber": ((0.07, 0.07, 0.07), 0.9, 0.0),
    "DarkMetal": ((0.12, 0.12, 0.13), 0.5, 0.6),
    "Gunmetal": ((0.20, 0.21, 0.22), 0.45, 0.6),
    "Slit": ((0.03, 0.03, 0.03), 0.6, 0.0),
})

HULL_W = 1.05          # half width of the hull between the sponsons
HULL_TOP = 1.72
TRACK_X = 1.25         # track centre line
TRACK_W = 0.5
WHEEL_R = 0.31
ROAD_WHEELS = (-1.4, -0.46, 0.48, 1.42)
SPROCKET = (2.28, 0.52, 0.3)   # y, z, r (front drive)
IDLER = (-2.06, 0.46, 0.28)     # y, z, r (rear)
SKIRT = (-2.04, 1.56)          # skirt y range
SKIRT_X = 1.58
SPONSON_TOP = 1.22
TURRET = V((0.0, 0.22, HULL_TOP))  # turret ring centre (pivot)
TURRET_R = 0.7
TURRET_TOP = HULL_TOP + 0.72


def rivet(c, normal, r=0.022, group="body", m="Olive"):
    ellipsoid(c, (r, r, r * 0.55), m, group, seg=6, rings=4,
              rot=look_matrix(V((0, 0, 0)), V(normal)))


def rivets(p0, p1, n, normal, **kw):
    p0, p1 = V(p0), V(p1)
    for i in range(n):
        rivet(p0.lerp(p1, (i + 0.5) / n), normal, **kw)


def ring_rivets(c, R, n, z_normal=1, group="body", m="Olive"):
    for i in range(n):
        a = 2 * math.pi * i / n
        rivet(c + V((math.cos(a) * R, math.sin(a) * R, 0)), (0, 0, z_normal), group=group, m=m)


# --------------------------------------------------------------------------
# Hull
# --------------------------------------------------------------------------

HULL_PROFILE = [(-2.12, 0.34), (1.98, 0.34), (2.3, 0.56), (2.32, 1.06), (1.86, HULL_TOP),
                (-2.0, HULL_TOP), (-2.16, 1.5), (-2.16, 0.6)]


def hull():
    extrude_x(HULL_PROFILE, -HULL_W, HULL_W, "Olive", "body", bevel=0.025)
    glacis_n = V((0, HULL_TOP - 1.06, 2.32 - 1.86)).normalized()
    # plate seams on the front: lower plate / glacis break and a mid seam on the glacis
    for z, y in ((1.06, 2.325), ):
        rbox(V((0, y, z)), (2 * HULL_W - 0.04, 0.03, 0.025), "OliveDark", "body", bevel=0.2)
    mid = V((0, 2.32, 1.06)).lerp(V((0, 1.86, HULL_TOP)), 0.5)
    rbox(mid + glacis_n * 0.006, (2 * HULL_W - 0.06, 0.02, 0.4), "OliveDark", "body",
         rot=look_matrix(V((0, 0, 0)), glacis_n) @ rot_xyz(90, 0, 0), bevel=0.2)
    # rivet rows: front plates, glacis edges, deck edges, hull sides
    for t in (0.06, 0.48, 0.56, 0.94):
        a = V((-HULL_W + 0.06, 2.32, 1.06)).lerp(V((-HULL_W + 0.06, 1.86, HULL_TOP)), t)
        rivets(a + glacis_n * 0.005, a + V((2 * HULL_W - 0.12, 0, 0)) + glacis_n * 0.005, 14,
               glacis_n)
    for z in (0.62, 0.98):
        rivets((-HULL_W + 0.06, 2.32, z), (HULL_W - 0.06, 2.32, z), 13, (0, 1, 0))
    for sx in (-1, 1):
        rivets((sx * (HULL_W - 0.05), 1.8, HULL_TOP + 0.004), (sx * (HULL_W - 0.05), -1.94,
               HULL_TOP + 0.004), 22, (0, 0, 1))
        rivets((sx * (HULL_W + 0.004), 1.72, HULL_TOP - 0.06), (sx * (HULL_W + 0.004), -1.96,
               HULL_TOP - 0.06), 22, (sx, 0, 0))
        rivets((sx * (HULL_W + 0.004), 1.7, 1.3), (sx * (HULL_W + 0.004), -1.96, 1.3), 20,
               (sx, 0, 0))
        # vertical seams on the upper hull sides
        for y in (1.0, -0.6):
            rivets((sx * (HULL_W + 0.004), y, 1.3), (sx * (HULL_W + 0.004), y, HULL_TOP - 0.06),
                   3, (sx, 0, 0))
    rivets((-HULL_W + 0.06, -2.0, HULL_TOP + 0.004), (HULL_W - 0.06, -2.0, HULL_TOP + 0.004),
           12, (0, 0, 1))
    # deck panels: a seam across the deck behind the turret, engine deck with louvres
    rbox(V((0, -0.82, HULL_TOP + 0.006)), (2 * HULL_W - 0.1, 0.03, 0.012), "OliveDark", "body",
         bevel=0.0)
    rivets((-HULL_W + 0.08, -0.86, HULL_TOP + 0.004), (HULL_W - 0.08, -0.86, HULL_TOP + 0.004),
           12, (0, 0, 1))
    rbox(V((0.25, -1.55, HULL_TOP + 0.02)), (0.9, 0.7, 0.04), "OliveDark", "body", bevel=0.15)
    for i in range(6):
        rbox(V((0.25, -1.78 + i * 0.1, HULL_TOP + 0.045)), (0.82, 0.04, 0.02), "Olive", "body",
             bevel=0.2)
    rbox(V((0.0, 1.2, HULL_TOP + 0.015)), (1.2, 0.5, 0.03), "OliveWorn", "body", bevel=0.2)
    # driver's hatch on the front deck
    hatch = V((0.55, 1.42, HULL_TOP))
    tube(hatch, hatch + V((0, 0, 0.05)), 0.22, 0.21, "Olive", "body", n=20, rings=1)
    tube(hatch + V((0, 0, 0.05)), hatch + V((0, 0, 0.07)), 0.17, 0.16, "OliveDark", "body",
         n=20, rings=1)
    rbox(hatch + V((0, -0.2, 0.06)), (0.16, 0.06, 0.05), "DarkMetal", "body", bevel=0.25)
    ring_rivets(hatch + V((0, 0, 0.052)), 0.195, 10)
    # periscope block ahead of the hatch
    rbox(hatch + V((-0.05, 0.3, 0.03)), (0.22, 0.1, 0.07), "OliveDark", "body", bevel=0.2)
    rbox(hatch + V((-0.05, 0.352, 0.035)), (0.17, 0.01, 0.025), "Slit", "body", bevel=0.0)
    # hull machine gun in a domed housing on the right of the glacis
    hm = V((0.52, 2.12, 1.3))
    ellipsoid(hm, (0.2, 0.22, 0.2), "Olive", "body", seg=16, rings=9,
              rot=look_matrix(V((0, 0, 0)), glacis_n))
    rbox(hm + V((0, 0.17, -0.04)), (0.11, 0.12, 0.13), "OliveDark", "body", bevel=0.2)
    tube(hm + V((0, 0.2, -0.08)), hm + V((0, 0.3, -0.16)), 0.025, 0.025, "DarkMetal", "body",
         n=8, rings=1)
    rbox(hm + V((0, 0.22, 0.04)), (0.08, 0.02, 0.025), "Slit", "body", bevel=0.0)
    # lifting eyes and tow rings
    for sx in (-1, 1):
        torus(V((sx * 0.62, 2.33, 0.86)), 0.07, 0.022, "OliveDark", "body",
              rot=rot_xyz(0, 90, 0), n=12, k=5)
        rbox(V((sx * 0.62, 2.32, 0.8)), (0.1, 0.04, 0.06), "Olive", "body", bevel=0.2)
        torus(V((sx * 0.55, 2.2, 0.42)), 0.08, 0.025, "DarkMetal", "body",
              rot=rot_xyz(0, 90, 0), n=12, k=5)
        torus(V((sx * (HULL_W + 0.01), 1.55, 1.58)), 0.05, 0.016, "OliveDark", "body",
              rot=rot_xyz(0, 0, 90), n=10, k=4, arc=(0, 180))
        torus(V((sx * 0.6, -2.18, 0.8)), 0.08, 0.025, "DarkMetal", "body",
              rot=rot_xyz(0, 90, 0), n=12, k=5)
        # exhausts on the rear plate
        tube(V((sx * 0.45, -2.14, 1.1)), V((sx * 0.45, -2.14, 1.5)), 0.07, 0.07, "DarkMetal",
             "body", n=12, rings=1)
        rbox(V((sx * 0.45, -2.19, 1.28)), (0.2, 0.06, 0.32), "OliveDark", "body", bevel=0.2)
    rivets((-HULL_W + 0.06, -2.165, 0.95), (HULL_W - 0.06, -2.165, 0.95), 12, (0, -1, 0))
    # stowage: box on the rear deck, jerrycan strapped to the left hull side
    box = V((-0.62, -1.45, HULL_TOP + 0.19))
    rbox(box, (0.55, 0.72, 0.36), "Olive", "body", bevel=0.08)
    rbox(box + V((0, 0, 0.19)), (0.58, 0.75, 0.04), "OliveDark", "body", bevel=0.25)
    for dy in (-0.18, 0.18):
        rbox(box + V((-0.28, dy, 0.08)), (0.02, 0.06, 0.08), "DarkMetal", "body", bevel=0.2)
    can = V((-HULL_W - 0.1, -0.35, 1.42))
    rbox(can, (0.17, 0.34, 0.42), "OliveDark", "body", bevel=0.12)
    rbox(can, (0.18, 0.28, 0.03), "OliveDark", "body", bevel=0.3)
    pipe([can + V((0, -0.1, 0.21)), can + V((0, -0.08, 0.27)), can + V((0, 0.05, 0.27)),
          can + V((0, 0.07, 0.21))], 0.013, "OliveDark", "body", n=5)
    for dy in (-0.1, 0.1):
        rbox(can + V((0.02, dy, 0)), (0.2, 0.025, 0.46), "DarkMetal", "body", bevel=0.2)
    # small box on the right side of the front deck (as in the reference)
    rbox(V((HULL_W - 0.2, 0.45, HULL_TOP + 0.07)), (0.28, 0.4, 0.14), "Olive", "body",
         bevel=0.15)


def sponsons():
    for sx in (-1, 1):
        x0, x1 = sx * (HULL_W - 0.05), sx * SKIRT_X
        lo, hi = min(x0, x1), max(x0, x1)
        y0, y1 = SKIRT
        # top deck of the sponson over the track
        rbox(V(((lo + hi) / 2, (y0 + y1) / 2, SPONSON_TOP - 0.06)), (hi - lo, y1 - y0, 0.12),
             "Olive", "body", bevel=0.1)
        rbox(V((sx * 1.2, -0.3, SPONSON_TOP + 0.005)), (0.38, 0.8, 0.02), "OliveWorn", "body",
             bevel=0.2)
        rbox(V((sx * 1.2, 0.85, SPONSON_TOP + 0.01)), (0.3, 0.35, 0.04), "Olive", "body",
             bevel=0.2)
        rivets((sx * (SKIRT_X - 0.04), y0 + 0.05, SPONSON_TOP + 0.003),
               (sx * (SKIRT_X - 0.04), y1 - 0.05, SPONSON_TOP + 0.003), 24, (0, 0, 1))
        # skirt panels, five per side with gaps, each with a hanger bracket and bolt rows
        n = 5
        pw = (y1 - y0) / n
        for i in range(n):
            yc = y0 + pw * (i + 0.5)
            c = V((sx * SKIRT_X, yc, 0.8))
            rbox(c, (0.05, pw - 0.03, 0.78), "Olive", "body", bevel=0.15)
            rbox(c + V((sx * 0.03, 0, 0.27)), (0.02, 0.1, 0.07), "OliveDark", "body",
                 bevel=0.25)
            rivets(c + V((sx * 0.027, -pw / 2 + 0.06, 0.34)),
                   c + V((sx * 0.027, pw / 2 - 0.06, 0.34)), 6, (sx, 0, 0))
            rivets(c + V((sx * 0.027, -pw / 2 + 0.05, -0.3)),
                   c + V((sx * 0.027, -pw / 2 + 0.05, 0.28)), 4, (sx, 0, 0))
            # bottom lip, slightly worn
            rbox(c + V((sx * 0.01, 0, -0.38)), (0.07, pw - 0.04, 0.04), "OliveWorn", "body",
                 bevel=0.2)
        # rear cap of the sponson
        rbox(V(((lo + hi) / 2, y0 - 0.02, 0.98)), (hi - lo, 0.05, 0.42), "Olive", "body",
             bevel=0.2)
        # wedge fender over the drive sprocket
        prof = [(y1 - 0.02, 0.92), (2.28, 0.84), (2.62, 0.92), (2.64, 1.13), (2.5, SPONSON_TOP),
                (y1 - 0.02, SPONSON_TOP)]
        extrude_x(prof, lo + (0.03 if sx > 0 else 0), hi + (0.02 if sx < 0 else 0.02),
                  "Olive", "body", bevel=0.03)
        rbox(V(((lo + hi) / 2, 2.635, 1.02)), (hi - lo - 0.04, 0.02, 0.16), "OliveWorn",
             "body", bevel=0.2)
        rivets((sx * (SKIRT_X + 0.022), y1 + 0.05, 1.12), (sx * (SKIRT_X + 0.022), 2.5, 1.12), 6,
               (sx, 0, 0))
        rivets((lo + 0.06, 2.6, 1.17), (hi - 0.06, 2.6, 1.17), 5, (0, 1, 0))


# --------------------------------------------------------------------------
# Running gear
# --------------------------------------------------------------------------

def convex_hull(points):
    pts = sorted(set(points))

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
    return lower[:-1] + upper[:-1]


def track_path(thick):
    """Centre line of the track belt (y, z), counter-clockwise, as a closed polygon."""
    circles = [(y, WHEEL_R, WHEEL_R) for y in ROAD_WHEELS]
    circles += [SPROCKET, IDLER, (1.0, 0.74, 0.07), (-0.93, 0.72, 0.07)]
    pts = []
    for y, z, r in circles:
        rr = r + thick / 2
        for k in range(48):
            a = 2 * math.pi * k / 48
            pts.append((round(y + math.cos(a) * rr, 5), round(z + math.sin(a) * rr, 5)))
    return convex_hull(pts)


def resample(poly, step):
    segs = list(zip(poly, poly[1:] + poly[:1]))
    lengths = [math.dist(a, b) for a, b in segs]
    total = sum(lengths)
    n = max(8, round(total / step))
    step = total / n
    out = []
    i, acc = 0, 0.0
    for k in range(n):
        d = k * step
        while acc + lengths[i] < d:
            acc += lengths[i]
            i += 1
        a, b = segs[i]
        t = (d - acc) / lengths[i]
        p = (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        tang = ((b[0] - a[0]) / lengths[i], (b[1] - a[1]) / lengths[i])
        out.append((p, tang))
    return out


def track(sx):
    thick = 0.07
    path = track_path(thick)
    for (y, z), (ty, tz) in resample(path, 0.14):
        ang = math.degrees(math.atan2(tz, ty))
        r = rot_xyz(ang, 0, 0)
        c = V((sx * TRACK_X, y, z))
        # CCW in (y, z) => outward normal is the tangent turned clockwise
        nrm = V((0, tz, -ty))
        rbox(c, (TRACK_W, 0.128, thick), "Track", "body", rot=r, bevel=0.0)
        rbox(c + nrm * (thick / 2 + 0.012), (TRACK_W - 0.04, 0.035, 0.03), "Track", "body",
             rot=r, bevel=0.0)  # grouser
        rbox(c - nrm * (thick / 2 + 0.03), (0.06, 0.06, 0.06), "Track", "body", rot=r,
             bevel=0.0)  # guide horn
        for ex in (-1, 1):  # end connectors
            rbox(c + V((ex * (TRACK_W / 2 + 0.015), 0, 0)) - nrm * 0.005, (0.03, 0.05, 0.05),
                 "DarkMetal", "body", rot=r, bevel=0.2, segments=1)


def road_wheel(sx, y):
    c = V((sx * TRACK_X, y, WHEEL_R))
    rot = rot_xyz(0, 90, 0)
    for ex in (-1, 1):  # twin wheels either side of the guide horns
        wc = c + V((ex * 0.12, 0, 0))
        torus(wc, WHEEL_R - 0.05, 0.05, "Rubber", "body", rot=rot, n=24, k=8,
              scale=(1, 1, 1.3))
        tube(wc - V((0.06, 0, 0)), wc + V((0.06, 0, 0)), WHEEL_R - 0.06, WHEEL_R - 0.06,
             "OliveDark", "body", n=24, rings=1)
        for i in range(6):
            a = 2 * math.pi * i / 6
            rivet(wc + V((ex * 0.062, math.cos(a) * 0.15, math.sin(a) * 0.15)), (ex, 0, 0),
                  r=0.02, m="Olive")
        tube(wc + V((ex * 0.06, 0, 0)), wc + V((ex * 0.1, 0, 0)), 0.09, 0.06, "Olive", "body",
             n=12, rings=1)
    # suspension arm back to the hull
    pivot = V((sx * (HULL_W + 0.02), y + 0.32, 0.62))
    arm = c + V((sx * -0.2, 0, 0))
    tube(arm, pivot, 0.05, 0.05, "OliveDark", "body", n=8, rings=1)
    tube(pivot - V((sx * 0.06, 0, 0)), pivot + V((sx * 0.12, 0, 0)), 0.07, 0.07, "Olive",
         "body", n=10, rings=1)
    rbox(pivot + V((sx * 0.02, 0.12, 0.08)), (0.1, 0.3, 0.06), "OliveDark", "body", bevel=0.2)


def sprocket(sx):
    y, z, r = SPROCKET
    c = V((sx * TRACK_X, y, z))
    for ex in (-1, 1):
        dc = c + V((ex * 0.1, 0, 0))
        tube(dc - V((0.03, 0, 0)), dc + V((0.03, 0, 0)), r - 0.05, r - 0.05, "OliveDark",
             "body", n=24, rings=1)
        for i in range(12):
            a = 2 * math.pi * (i + (0.5 if ex > 0 else 0)) / 12
            rbox(dc + V((0, math.cos(a) * (r - 0.03), math.sin(a) * (r - 0.03))),
                 (0.05, 0.06, 0.09), "DarkMetal", "body",
                 rot=rot_xyz(math.degrees(a) - 90, 0, 0), bevel=0.2, segments=1)
        for i in range(5):  # lightening holes
            a = 2 * math.pi * i / 5
            tube(dc + V((ex * 0.031, math.cos(a) * 0.14, math.sin(a) * 0.14)),
                 dc + V((ex * 0.035, math.cos(a) * 0.14, math.sin(a) * 0.14)), 0.045, 0.045,
                 "Slit", "body", n=10, rings=1)
    tube(c - V((0.2, 0, 0)), c + V((0.2, 0, 0)), 0.08, 0.08, "Olive", "body", n=12, rings=1)
    tube(c + V((sx * 0.2, 0, 0)), c + V((sx * 0.26, 0, 0)), 0.1, 0.07, "Gunmetal", "body",
         n=12, rings=1)


def idler(sx):
    y, z, r = IDLER
    c = V((sx * TRACK_X, y, z))
    for ex in (-1, 1):
        dc = c + V((ex * 0.1, 0, 0))
        tube(dc - V((0.04, 0, 0)), dc + V((0.04, 0, 0)), r, r, "OliveDark", "body", n=24,
             rings=1)
        torus(dc + V((ex * 0.04, 0, 0)), r * 0.62, 0.02, "Olive", "body",
              rot=rot_xyz(0, 90, 0), n=18, k=4)
    tube(c - V((0.2, 0, 0)), c + V((0.2, 0, 0)), 0.07, 0.07,
         "Gunmetal", "body", n=10, rings=1)
    for ry in (1.0, -0.93):  # return rollers
        rc = V((sx * TRACK_X, ry, 0.72 if ry < 0 else 0.74))
        tube(rc - V((0.2, 0, 0)), rc + V((0.2, 0, 0)), 0.07, 0.07, "OliveDark", "body", n=12,
             rings=1)


# --------------------------------------------------------------------------
# Turret (own node, pivot at the ring centre)
# --------------------------------------------------------------------------

def turret():
    p = TURRET
    g = "turret"
    tube(p, p + V((0, 0, 0.08)), TURRET_R + 0.08, TURRET_R + 0.06, "OliveDark", g, n=40,
         rings=1)  # race ring collar
    tube(p + V((0, 0, 0.08)), V((p.x, p.y, TURRET_TOP)), TURRET_R, TURRET_R - 0.02, "Olive", g,
         n=40, rings=2)
    torus(V((p.x, p.y, TURRET_TOP - 0.01)), TURRET_R - 0.04, 0.03, "Olive", g, n=40, k=6)
    # team-coloured roof with hatches and hinges
    top = V((p.x, p.y, TURRET_TOP))
    tube(top - V((0, 0, 0.01)), top + V((0, 0, 0.025)), TURRET_R - 0.05, TURRET_R - 0.06,
         "TeamColor", g, n=40, rings=1)
    for c, size in (((0.18, -0.08), (0.3, 0.42)), ((-0.22, 0.1), (0.26, 0.2)),
                    ((0.0, 0.32), (0.4, 0.12))):
        rbox(top + V((c[0], c[1], 0.035)), (size[0], size[1], 0.02), "TeamColor", g,
             bevel=0.25)
    for c in ((0.18, -0.29), (-0.22, 0.0), (0.12, 0.13), (-0.12, 0.13)):
        rbox(top + V((c[0], c[1], 0.04)), (0.08, 0.03, 0.025), "DarkMetal", g, bevel=0.2)
    ring_rivets(top + V((0, 0, 0.026)), TURRET_R - 0.1, 20, group=g, m="TeamColor")
    # rivets round the wall and the collar
    for z in (0.2, TURRET_TOP - HULL_TOP - 0.08):
        for i in range(28):
            a = 2 * math.pi * i / 28
            d = V((math.cos(a), math.sin(a), 0))
            rivet(p + d * (TURRET_R + 0.002) + V((0, 0, z)), d, group=g)
    # gun mantlet: a big rounded bulge on the left, the gun on the right with a collar
    front = p + V((0, TURRET_R - 0.05, 0.38))
    ellipsoid(front + V((-0.24, 0.05, -0.02)), (0.22, 0.2, 0.22), "Olive", g, seg=18,
              rings=10)
    ellipsoid(front + V((0.16, 0.05, -0.04)), (0.13, 0.13, 0.12), "Olive", g, seg=14,
              rings=8)
    gun0 = front + V((0.16, 0.12, -0.04))
    tube(gun0, gun0 + V((0, 0.18, 0)), 0.085, 0.075, "OliveDark", g, n=14, rings=1)
    tube(gun0 + V((0, 0.18, 0)), gun0 + V((0, 0.95, 0)), 0.055, 0.05, "Olive", g, n=14,
         rings=2)
    tube(gun0 + V((0, 0.9, 0)), gun0 + V((0, 1.02, 0)), 0.07, 0.07, "OliveDark", g, n=14,
         rings=1)  # muzzle
    tube(gun0 + V((0, 1.01, 0)), gun0 + V((0, 1.025, 0)), 0.04, 0.04, "Slit", g, n=12,
         rings=1)
    # vision port above the gun, periscope and mast at the back
    port = p + V((0.24, TURRET_R - 0.01, 0.58))
    rbox(port, (0.18, 0.08, 0.1), "OliveDark", g, bevel=0.2)
    rbox(port + V((0, 0.042, 0)), (0.12, 0.01, 0.025), "Slit", g, bevel=0.0)
    mast = p + V((-0.5, -0.38, 0.45))
    rbox(mast, (0.08, 0.1, 0.24), "OliveDark", g, bevel=0.2)
    tube(mast + V((0, 0, 0.12)), mast + V((0, 0, 0.42)), 0.022, 0.018, "DarkMetal", g, n=8,
         rings=1)
    rbox(mast + V((0, 0, 0.35)), (0.06, 0.08, 0.05), "DarkMetal", g, bevel=0.2)
    rbox(mast + V((0, 0.04, 0.25)), (0.03, 0.08, 0.03), "DarkMetal", g, bevel=0.2)
    # lifting hooks
    for a in (60, 200, 320):
        d = V((math.cos(math.radians(a)), math.sin(math.radians(a)), 0))
        torus(p + d * (TURRET_R + 0.03) + V((0, 0, 0.5)), 0.04, 0.014, "OliveDark", g,
              rot=look_matrix(V((0, 0, 0)), d.cross(V((0, 0, 1)))), n=10, k=4)


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
    args = parse_args({"out": "assets/models/ironbound/units/tank.glb", "render": None})
    bpy.ops.wm.read_factory_settings(use_empty=True)
    hull()
    sponsons()
    for sx in (-1, 1):
        track(sx)
        for y in ROAD_WHEELS:
            road_wheel(sx, y)
        sprocket(sx)
        idler(sx)
    turret()
    body, _ = merge("Hull", groups={"body"})
    tur, _ = merge("Turret", groups={"turret"})
    set_origin(tur, TURRET)
    tur.parent = body
    objects = [body, tur]
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
            ("three_quarter", 300, 28, 1.75, wide), ("side", 270, 0, 1.6, wide),
            ("front", 0, 10, 1.2, wide), ("back", 150, 28, 1.75, wide),
            ("game_angle", 325, 50, 1.75, (800, 800)),
        ], target=(0, 0, 0.3))
        preview_sheet(args["render"], os.path.join(args["render"], "tank-preview.png"))


main()
