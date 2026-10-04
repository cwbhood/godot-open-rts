"""Builds the Helicopter: a tandem-rotor transport with a boxy rounded fuselage, a glazed
nose with dark chin windows, a short front rotor pylon and a tall rear one flanked by two
turboshaft engines, long side fuel sponsons with a roundel, wheeled landing gear and a
team-coloured stripe down the side. Exports a GLB at in-game size.

    python3 tools/blender/build_helicopter.py -- \
        --out assets/models/ironbound/units/helicopter.glb [--render /tmp/previews]

Modelled in real metres (a 15.5 m fuselage, 17 m rotors), facing +Y, then scaled by
GAME_SCALE so it sits at about the size of the stock transport helicopter. The two rotors are
separate nodes named "Rotor" (front) and "Rotor2" (rear) with origins at their hubs, which is
what RotorSpin.gd looks for, so they spin about their up axis in-game.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
import bmesh  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402
from mesh_kit import (  # noqa: E402
    PALETTE, V, add, ellipsoid, export_glb, extrude_x, merge, parse_args, pipe, rbox,
    render_views, rot_xyz, set_origin, stats, torus, tube,
)

GAME_SCALE = 0.09

PALETTE.update({
    "TeamColor": ((0.22, 0.42, 0.78), 0.6, 0.0),
    "Khaki": ((0.60, 0.56, 0.38), 0.85, 0.0),
    "KhakiDark": ((0.49, 0.45, 0.30), 0.9, 0.0),
    "KhakiLight": ((0.66, 0.62, 0.45), 0.9, 0.0),
    "Glass": ((0.07, 0.08, 0.09), 0.15, 0.4),
    "Blade": ((0.27, 0.29, 0.32), 0.55, 0.2),
    "DarkMetal": ((0.12, 0.12, 0.13), 0.5, 0.6),
    "Gunmetal": ((0.22, 0.23, 0.24), 0.45, 0.6),
    "Steel": ((0.62, 0.62, 0.62), 0.35, 0.8),
    "Grille": ((0.06, 0.06, 0.06), 0.7, 0.2),
    "Tyre": ((0.10, 0.10, 0.11), 0.9, 0.0),
    "Rim": ((0.30, 0.31, 0.32), 0.5, 0.5),
    "RedLamp": ((0.9, 0.12, 0.1), 0.4, 0.0, 1.5),
    "Lamp": ((1.00, 0.95, 0.80), 0.4, 0.0, 1.5),
})

# Lofted shells: stations of (y, centre x, half width, bottom z, top z, squareness). The
# section is a superellipse |x/hw|^p + |(z - zc)/hh|^p = 1, so p = 2 is an ellipse and larger
# p is a box with rounded corners.
FUSELAGE = [
    (8.4, 0, 0.3, 1.75, 2.25, 2.0),
    (8.2, 0, 0.85, 1.45, 2.65, 2.3),
    (7.8, 0, 1.18, 1.2, 3.0, 2.7),
    (7.1, 0, 1.42, 1.06, 3.45, 3.1),
    (6.4, 0, 1.55, 1.0, 3.85, 3.6),
    (5.6, 0, 1.6, 1.0, 4.0, 4.0),
    (-4.4, 0, 1.6, 1.0, 4.0, 4.0),
    (-5.2, 0, 1.6, 1.25, 4.0, 4.0),
    (-6.2, 0, 1.55, 1.9, 4.0, 3.8),
    (-7.0, 0, 1.45, 2.7, 4.0, 3.5),
    (-7.45, 0, 1.25, 3.25, 3.95, 3.0),
    (-7.6, 0, 0.9, 3.45, 3.85, 2.6),
]
FRONT_PYLON = [
    (6.75, 0, 0.45, 3.2, 3.4, 2.4),
    (6.3, 0, 0.85, 3.3, 4.35, 2.8),
    (5.7, 0, 0.95, 3.4, 4.8, 3.0),
    (4.3, 0, 0.95, 3.4, 4.8, 3.0),
    (3.7, 0, 0.88, 3.4, 4.55, 3.0),
    (3.25, 0, 0.55, 3.4, 4.1, 2.6),
]
REAR_PYLON = [
    (-3.5, 0, 0.6, 3.6, 4.05, 2.6),
    (-4.0, 0, 0.98, 3.6, 5.6, 3.0),
    (-4.5, 0, 1.05, 3.6, 6.25, 3.2),
    (-6.6, 0, 1.05, 3.6, 6.35, 3.4),
    (-7.25, 0, 0.92, 3.5, 6.05, 3.0),
    (-7.65, 0, 0.6, 3.6, 5.3, 2.5),
]
SPINE = [
    (3.6, 0, 0.3, 3.8, 4.2, 2.4),
    (3.2, 0, 0.55, 3.8, 4.35, 3.0),
    (-3.4, 0, 0.55, 3.8, 4.35, 3.0),
    (-3.8, 0, 0.3, 3.8, 4.2, 2.4),
]


def sponson(sx):
    cx = sx * 1.85
    return [
        (1.75, cx, 0.15, 1.45, 1.75, 2.0),
        (1.55, cx, 0.45, 1.12, 2.2, 2.2),
        (1.2, cx, 0.6, 1.0, 2.35, 2.5),
        (-3.9, cx, 0.6, 1.0, 2.35, 2.5),
        (-4.3, cx, 0.48, 1.08, 2.25, 2.3),
        (-4.55, cx, 0.2, 1.35, 1.85, 2.0),
    ]


FRONT_HUB = V((0, 5.0, 5.2))
REAR_HUB = V((0, -5.6, 6.8))
ROTOR_R = 8.5
ENGINE = (1.55, 4.6, -3.2, -6.4)  # x, z, front y, back y
ENGINE_R = 0.55


def sgnpow(v, e):
    return math.copysign(abs(v) ** e, v)


def station(st, y):
    """Interpolated (cx, hw, zb, zt, p) at y (stations run nose to tail)."""
    if y >= st[0][0]:
        return st[0][1:]
    for a, b in zip(st, st[1:]):
        if b[0] <= y <= a[0]:
            t = (a[0] - y) / (a[0] - b[0])
            t = t * t * (3 - 2 * t)  # ease so the shells have no hard creases at stations
            return tuple(pa + (pb - pa) * t for pa, pb in zip(a[1:], b[1:]))
    return st[-1][1:]


def surf(st, y, t):
    cx, hw, zb, zt, p = station(st, y)
    zc, hh = (zb + zt) / 2, (zt - zb) / 2
    return V((cx + hw * sgnpow(math.cos(t), 2 / p), y, zc + hh * sgnpow(math.sin(t), 2 / p)))


def normal(st, y, t):
    e = 1e-3
    du = surf(st, y, t + e) - surf(st, y, t - e)
    dv = surf(st, y + e, t) - surf(st, y - e, t)
    n = du.cross(dv)
    if n.length < 1e-9:
        cx, hw, zb, zt, _ = station(st, y)
        n = surf(st, y, t) - V((cx, y, (zb + zt) / 2))
    n.normalize()
    cx, _, zb, zt, _ = station(st, y)
    if n.dot(surf(st, y, t) - V((cx, y, (zb + zt) / 2))) < 0:
        n = -n
    return n


def t_at(st, y, z, side=1):
    """Section angle on the +x (side=1) or -x flank where the shell passes height z."""
    _, _, zb, zt, p = station(st, y)
    zc, hh = (zb + zt) / 2, (zt - zb) / 2
    u = max(-0.999, min(0.999, (z - zc) / hh))
    t = math.asin(sgnpow(u, p / 2))
    return t if side > 0 else math.pi - t


def loft(st, m, group, n=40, step=0.25, grow=0.0, y0=None, y1=None):
    """Closed shell through the stations (or a slice of it between y0 and y1)."""
    top, bot = st[0][0], st[-1][0]
    ya = top if y0 is None else y0
    yb = bot if y1 is None else y1
    count = max(2, int(math.ceil((ya - yb) / step)) + 1)
    ys = [ya + (yb - ya) * i / (count - 1) for i in range(count)]
    for s in st:  # always ring at the stations themselves
        if yb < s[0] < ya and all(abs(s[0] - y) > 1e-3 for y in ys):
            ys.append(s[0])
    ys.sort(reverse=True)
    bm = bmesh.new()
    rings = []
    for y in ys:
        ring = []
        for k in range(n):
            t = 2 * math.pi * k / n
            p = surf(st, y, t)
            if grow:
                p = p + normal(st, y, t) * grow
            ring.append(bm.verts.new(p))
        rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        for k in range(n):
            bm.faces.new((a[k], a[(k + 1) % n], b[(k + 1) % n], b[k]))
    bm.faces.new(rings[0])
    bm.faces.new(list(reversed(rings[-1])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return add(bm, m, group, True)


def patch(st, ya, yb, t0, t1, m, group, lift=0.015, thick=0.03, ny=None, nt=None, smooth=True):
    """A thin slab lying on a shell: windows, stripes, access panels. t0/t1 are angles or
    functions of y, so a patch can slant (the stripe climbing the rear pylon)."""
    f0 = t0 if callable(t0) else (lambda y, v=t0: v)
    f1 = t1 if callable(t1) else (lambda y, v=t1: v)
    ny = ny or max(2, int(abs(ya - yb) / 0.25) + 2)
    nt = nt or max(2, int(abs(f1(ya) - f0(ya)) / 0.12) + 2)
    bm = bmesh.new()
    outer, inner = [], []
    for i in range(ny):
        y = ya + (yb - ya) * i / (ny - 1)
        ro, ri = [], []
        for j in range(nt):
            t = f0(y) + (f1(y) - f0(y)) * j / (nt - 1)
            p, n = surf(st, y, t), normal(st, y, t)
            ro.append(bm.verts.new(p + n * (lift + thick)))
            ri.append(bm.verts.new(p + n * lift))
        outer.append(ro)
        inner.append(ri)
    for i in range(ny - 1):
        for j in range(nt - 1):
            bm.faces.new((outer[i][j], outer[i][j + 1], outer[i + 1][j + 1], outer[i + 1][j]))
            bm.faces.new((inner[i][j], inner[i + 1][j], inner[i + 1][j + 1], inner[i][j + 1]))
    edges = ([(i, 0) for i in range(ny)] + [(ny - 1, j) for j in range(nt)] +
             [(i, nt - 1) for i in reversed(range(ny))] + [(0, j) for j in reversed(range(nt))])
    for (i0, j0), (i1, j1) in zip(edges, edges[1:]):
        if (i0, j0) == (i1, j1):
            continue
        bm.faces.new((outer[i0][j0], outer[i1][j1], inner[i1][j1], inner[i0][j0]))
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return add(bm, m, group, smooth)


def side_patch(st, ya, yb, za, zb, m, group, side=1, **kw):
    """Patch on a flank between heights za and zb (numbers or functions of y)."""
    fa = za if callable(za) else (lambda y, v=za: v)
    fb = zb if callable(zb) else (lambda y, v=zb: v)
    return patch(st, ya, yb, lambda y: t_at(st, y, fa(y), side), lambda y: t_at(st, y, fb(y), side),
                 m, group, **kw)


def flank_x(st, y, z):
    return surf(st, y, t_at(st, y, z)).x


def window(st, y, z, w, h, side, frame=True, group="body"):
    if frame:
        side_patch(st, y + w / 2 + 0.08, y - w / 2 - 0.08, z - h / 2 - 0.08, z + h / 2 + 0.08,
                   "KhakiDark", group, side=side, lift=0.0, thick=0.04)
    side_patch(st, y + w / 2, y - w / 2, z - h / 2, z + h / 2, "Glass", group, side=side,
               lift=0.02, thick=0.03)


# --------------------------------------------------------------------------
# Fuselage
# --------------------------------------------------------------------------

def fuselage():
    loft(FUSELAGE, "Khaki", "body", n=48, step=0.3)
    loft(FRONT_PYLON, "Khaki", "body", n=36)
    loft(REAR_PYLON, "Khaki", "body", n=36)
    loft(SPINE, "Khaki", "body", n=24, step=0.5)
    # windscreen panes wrapping the nose, with an eyebrow pane above
    for a, b in ((22, 52), (57, 86), (94, 123), (128, 158)):
        patch(FUSELAGE, 8.05, 6.75, math.radians(a), math.radians(b), "Glass", "body",
              lift=0.01, thick=0.03, ny=8, nt=6)
    patch(FUSELAGE, 8.05, 6.75, math.radians(18), math.radians(162), "KhakiDark", "body",
          lift=0.0, thick=0.025, ny=8, nt=18)
    # dark chin windows and the dark nose cap under the windscreen
    patch(FUSELAGE, 8.38, 7.45, math.radians(200), math.radians(340), "Glass", "body",
          lift=0.01, thick=0.03, ny=6, nt=14)
    for sx in (-1, 1):
        # cockpit side windows: a big one and a lower one in the crew door
        window(FUSELAGE, 6.25, 3.0, 0.8, 0.9, sx)
        window(FUSELAGE, 5.3, 3.15, 0.55, 0.65, sx)
        # cabin windows above the stripe
        for y in (2.7, 1.1, -0.5, -2.1):
            window(FUSELAGE, y, 3.05, 0.72, 0.72, sx)
        # team stripe: along the cabin, then climbing toward the rear pylon
        def lo(y):
            return 2.15 + max(0.0, (-3.3 - y)) * 1.55

        side_patch(FUSELAGE, 6.95, -4.35, lo, lambda y: lo(y) + 0.38, "TeamColor", "body",
                   side=sx, lift=0.0, thick=0.03, ny=60)
        # access panels on the rear pylon and under the cockpit
        side_patch(REAR_PYLON, -4.7, -6.3, 4.4, 5.6, "KhakiLight", "body", side=sx,
                   lift=0.0, thick=0.02)
        side_patch(FUSELAGE, 6.5, 5.9, 1.45, 2.0, "KhakiDark", "body", side=sx, lift=0.0,
                   thick=0.02)
        # louvred vents low on the flank behind the sponson
        for i in range(6):
            side_patch(FUSELAGE, -4.6 - i * 0.12, -4.66 - i * 0.12, 1.75, 2.15, "Grille",
                       "body", side=sx, lift=0.0, thick=0.02, ny=2, nt=3)
    # crew door outline on the right side, with its handle
    for ya, yb, za, zb in ((5.72, 5.66, 1.4, 3.65), (4.94, 4.88, 1.4, 3.65),
                           (5.72, 4.88, 3.6, 3.66), (5.72, 4.88, 1.4, 1.46)):
        side_patch(FUSELAGE, ya, yb, za, zb, "KhakiDark", "body", lift=0.0, thick=0.035, ny=2,
                   nt=3 if zb - za < 0.2 else 8)
    rbox(V((flank_x(FUSELAGE, 5.05, 2.5) + 0.04, 5.05, 2.5)), (0.04, 0.16, 0.05), "DarkMetal",
         "body")
    # rear loading ramp seam under the tail
    patch(FUSELAGE, -4.6, -7.3, math.radians(225), math.radians(315), "KhakiDark", "body",
          lift=0.0, thick=0.02, nt=10)
    # rib bands round the cabin roof
    for y in (3.9, -3.0):
        patch(FUSELAGE, y + 0.05, y - 0.05, math.radians(20), math.radians(160), "KhakiDark",
              "body", lift=0.0, thick=0.03, ny=2, nt=18)


def details():
    for sx in (-1, 1):
        # pitot probes and lamps on the nose
        base = V((sx * 0.9, 7.85, 2.0))
        tube(base, base + V((sx * 0.1, 0.9, 0.0)), 0.035, 0.025, "Steel", "body", n=6, rings=1)
        ellipsoid(V((sx * 1.1, 7.45, 1.5)), (0.07, 0.07, 0.07), "RedLamp", "body", seg=8, rings=5)
        # boarding ladders up the flank
        for y in (-3.6, 3.6):
            x = flank_x(FUSELAGE, y, 3.0) + 0.09
            for dy in (-0.18, 0.18):
                pipe([V((sx * (x - 0.07), y + dy, 2.45)), V((sx * x, y + dy, 2.5)),
                      V((sx * x, y + dy, 3.6)), V((sx * (x - 0.07), y + dy, 3.65))], 0.025,
                     "KhakiDark", "body", n=6)
            for z in (2.7, 2.95, 3.2, 3.45):
                tube(V((sx * x, y - 0.18, z)), V((sx * x, y + 0.18, z)), 0.02, 0.02,
                     "KhakiDark", "body", n=6, rings=1)
        # fairing hump on the cabin roof edge behind the front pylon
        tube(V((sx * 0.9, 1.6, 4.0)), V((sx * 0.9, 0.0, 4.0)), 0.22, 0.22, "Khaki", "body",
             n=12, rings=1)
        ellipsoid(V((sx * 0.9, 1.6, 4.0)), (0.22, 0.2, 0.22), "Khaki", "body", seg=12, rings=6)
        ellipsoid(V((sx * 0.9, 0.0, 4.0)), (0.22, 0.2, 0.22), "Khaki", "body", seg=12, rings=6)
        # vent box on the front pylon
        rbox(V((sx * 0.95, 4.9, 4.3)), (0.08, 0.5, 0.3), "Grille", "body", bevel=0.2)
    # antenna posts on the spine
    for y in (2.4, -0.4, -2.6):
        tube(V((0, y, 4.3)), V((0, y, 4.75)), 0.04, 0.04, "DarkMetal", "body", n=6, rings=1)
        rbox(V((0, y, 4.78)), (0.35, 0.22, 0.04), "DarkMetal", "body", bevel=0.2)
    tube(V((0, 6.6, 3.75)), V((0, 6.4, 4.1)), 0.02, 0.01, "DarkMetal", "body", n=5, rings=1)
    ellipsoid(surf(REAR_PYLON, -7.3, math.pi / 2), (0.08, 0.08, 0.08), "RedLamp", "body", seg=8, rings=5)
    ellipsoid(V((0, -0.8, 1.0)), (0.12, 0.12, 0.06), "RedLamp", "body", seg=8, rings=5)
    # grille above the rear pylon slope
    rbox(V((0, -3.9, 5.15)), (0.9, 0.06, 0.45), "Grille", "body", rot=rot_xyz(-40, 0, 0),
         bevel=0.2)


def sponsons():
    for sx in (-1, 1):
        st = sponson(sx)
        loft(st, "Khaki", "body", n=28, step=0.4)
        # segment bands along the tank
        for y in (0.7, -0.4, -1.5, -2.6, -3.5):
            loft(st, "KhakiDark", "body", n=28, grow=0.025, y0=y + 0.04, y1=y - 0.04)
        # fuel cap, front lamp and intake grille
        cap = surf(st, -3.0, math.radians(60))
        tube(cap, cap + V((0, 0, 0.1)), 0.12, 0.12, "KhakiDark", "body", n=10, rings=1)
        ellipsoid(V((sx * 1.85, 1.68, 1.7)), (0.1, 0.06, 0.1), "Lamp", "body", seg=10, rings=6)
        for i in range(5):
            z = 1.3 + i * 0.07
            rbox(V((sx * 2.42, 0.5, z)), (0.04, 0.45, 0.025), "Grille", "body", bevel=0.0)
        # roundel: ring and star in team colour
        c = V((sx * 2.46, -2.0, 1.68))
        torus(c, 0.3, 0.035, "TeamColor", "body", rot=rot_xyz(0, 90, 0), n=24, k=6)
        star = []
        for i in range(10):
            a = math.pi / 2 + i * math.pi / 5
            r = 0.24 if i % 2 == 0 else 0.1
            star.append((c.y + r * math.cos(a) * -sx, c.z + r * math.sin(a)))
        x0, x1 = (c.x - 0.03, c.x + 0.02) if sx > 0 else (c.x - 0.02, c.x + 0.03)
        if sx < 0:
            star.reverse()
        extrude_x(star, x0, x1, "TeamColor", "body")


def engines():
    x, z, yf, yb = ENGINE
    for sx in (-1, 1):
        cx = sx * x
        tube(V((cx, yb, z)), V((cx, yf, z)), ENGINE_R * 0.8, ENGINE_R, "Khaki", "body", n=24,
             rings=4, bulge=0.05)
        # stacked intake rings and a bullet nose with a probe
        for i in range(5):
            torus(V((cx, yf + 0.08 + i * 0.1, z)), ENGINE_R * 0.82, 0.05, "Steel", "body",
                  rot=rot_xyz(90, 0, 0), n=24, k=6)
        tube(V((cx, yf, z)), V((cx, yf + 0.5, z)), ENGINE_R * 0.7, ENGINE_R * 0.7, "Grille",
             "body", n=20, rings=1)
        ellipsoid(V((cx, yf + 0.55, z)), (0.3, 0.38, 0.3), "Khaki", "body", seg=16, rings=8)
        tube(V((cx, yf + 0.85, z)), V((cx, yf + 1.35, z)), 0.05, 0.035, "DarkMetal", "body",
             n=6, rings=1)
        # exhaust and the strut to the pylon
        tube(V((cx, yb + 0.02, z)), V((cx, yb - 0.35, z)), ENGINE_R * 0.55, ENGINE_R * 0.6,
             "DarkMetal", "body", n=16, rings=1)
        rbox(V((sx * 1.05, (yf + yb) / 2, z)), (0.5, 1.6, 0.35), "Khaki", "body", bevel=0.3)
        tube(V((cx, (yf + yb) / 2 - 0.6, z + ENGINE_R - 0.05)),
             V((cx, (yf + yb) / 2 + 0.6, z + ENGINE_R - 0.05)), 0.07, 0.07, "KhakiDark", "body",
             n=8, rings=1)


def gear():
    for sx in (-1, 1):
        for y, x, top in ((4.4, 1.2, V((sx * 1.05, 4.5, 1.15))),
                          (-3.75, 1.85, V((sx * 1.85, -3.75, 1.1)))):
            hub = V((sx * x, y, 0.42))
            tube(top, hub + V((-sx * 0.12, 0, 0.1)), 0.07, 0.06, "Gunmetal", "body", n=8,
                 rings=1)
            tube(hub + V((-sx * 0.12, 0.25, 0.3)), top + V((0, 0.4, 0.05)), 0.04, 0.04,
                 "Gunmetal", "body", n=6, rings=1)  # drag brace
            tube(hub + V((-sx * 0.2, 0, 0)), hub + V((-sx * 0.05, 0, 0)), 0.06, 0.06,
                 "Gunmetal", "body", n=8, rings=1)  # axle
            torus(hub, 0.3, 0.13, "Tyre", "body", rot=rot_xyz(0, 90, 0), n=20, k=8,
                  scale=(1, 1, 1.25))
            tube(hub - V((0.12, 0, 0)), hub + V((0.12, 0, 0)), 0.22, 0.22, "Rim", "body", n=16,
                 rings=1)
            tube(hub + V((sx * 0.1, 0, 0)), hub + V((sx * 0.15, 0, 0)), 0.09, 0.07, "Gunmetal",
                 "body", n=10, rings=1)


# --------------------------------------------------------------------------
# Rotors
# --------------------------------------------------------------------------

def rotor(hub, group, phase):
    # mast and swashplate stay on the body; head and blades spin
    tube(hub - V((0, 0, 0.75)), hub - V((0, 0, 0.1)), 0.18, 0.16, "Gunmetal", "body", n=12,
         rings=1)
    tube(hub - V((0, 0, 0.55)), hub - V((0, 0, 0.45)), 0.5, 0.5, "DarkMetal", "body", n=20,
         rings=1)
    tube(hub - V((0, 0, 0.12)), hub + V((0, 0, 0.3)), 0.3, 0.26, "DarkMetal", group, n=16,
         rings=1)
    ellipsoid(hub + V((0, 0, 0.3)), (0.26, 0.26, 0.12), "Gunmetal", group, seg=14, rings=6)
    for i in range(3):
        a = math.radians(phase + i * 120)
        r = rot_xyz(0, 0, math.degrees(a))
        d = V((math.cos(a), math.sin(a), 0))
        perp = V((-math.sin(a), math.cos(a), 0))
        # hinge block, damper and pitch link
        rbox(hub + d * 0.55 + V((0, 0, 0.1)), (0.6, 0.28, 0.28), "DarkMetal", group, rot=r,
             bevel=0.2)
        tube(hub + d * 0.3 + perp * 0.2 + V((0, 0, 0.1)), hub + d * 0.85 + perp * 0.17 +
             V((0, 0, 0.12)), 0.05, 0.05, "Steel", group, n=6, rings=1)
        tube(hub + d * 0.65 - perp * 0.18 - V((0, 0, 0.45)), hub + d * 0.65 - perp * 0.18 +
             V((0, 0, 0.05)), 0.03, 0.03, "Steel", group, n=6, rings=1)
        rbox(hub + d * 1.05 + V((0, 0, 0.1)), (0.5, 0.32, 0.2), "Gunmetal", group, rot=r,
             bevel=0.25)  # blade cuff
        # the blade: wide flat paddle with a rounded tip
        mid = (1.25 + ROTOR_R) / 2
        rbox(hub + d * mid + V((0, 0, 0.1)), (ROTOR_R - 1.25, 1.0, 0.14), "Blade", group,
             rot=r @ rot_xyz(4, 0, 0), bevel=0.45, segments=3)
        rbox(hub + d * (ROTOR_R - 0.35) + V((0, 0, 0.1)), (0.7, 1.0, 0.14), "KhakiDark", group,
             rot=r @ rot_xyz(4, 0, 0), bevel=0.45, segments=3)  # tip cap


def main():
    args = parse_args({"out": "assets/models/ironbound/units/helicopter.glb", "render": None})
    bpy.ops.wm.read_factory_settings(use_empty=True)
    fuselage()
    details()
    sponsons()
    engines()
    gear()
    rotor(FRONT_HUB, "rotor_f", 0)
    rotor(REAR_HUB, "rotor_r", 60)
    objects = []
    body, _ = merge("Body", groups={"body"})
    objects.append(body)
    for name, group, hub in (("Rotor", "rotor_f", FRONT_HUB), ("Rotor2", "rotor_r", REAR_HUB)):
        ob, _ = merge(name, groups={group})
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
        wide = (1200, 750)
        render_views(args["render"], [
            ("three_quarter", 62, 18, 2.9, wide), ("side", 90, 0, 2.7, wide),
            ("front", 0, 12, 2.0, wide), ("back", -145, 25, 2.9, wide),
            ("game_angle", 35, 50, 2.9, (800, 800)),
        ], target=(0, 0, 0.3))


main()
