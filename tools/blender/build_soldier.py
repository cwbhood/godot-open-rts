"""Builds a single detailed infantry soldier (desert fatigues, team-coloured helmet band and
shoulder guards, carbine at the low ready) with a simple skeleton, and exports it as a GLB.

Run with the pip `bpy` module (or `blender -b -P`):
    python3 tools/blender/build_soldier.py -- --out assets/models/ironbound/units/rifleman.glb \
        [--render /tmp/previews]

Real-world scale: 1.8 m tall, feet on z=0, facing +Y (the convention build_assets.py uses).
Every part is rigidly bound to one bone, so the model can be posed or animated later.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy  # noqa: E402
from mesh_kit import (  # noqa: E402
    PALETTE, V, ellipsoid, export_glb, frame_from_dir, look_matrix, merge, parse_args, rbox,
    render_views, rot_xyz, stats, torus, tube,
)
import math  # noqa: E402

PALETTE.update({
    "TeamColor": ((0.22, 0.42, 0.78), 0.6, 0.0),
    "Fatigue": ((0.66, 0.57, 0.41), 0.9, 0.0),
    "FatigueDark": ((0.55, 0.47, 0.33), 0.9, 0.0),
    "Webbing": ((0.55, 0.47, 0.33), 0.85, 0.0),
    "Pouch": ((0.50, 0.43, 0.30), 0.85, 0.0),
    "Scarf": ((0.70, 0.60, 0.43), 0.95, 0.0),
    "Helmet": ((0.64, 0.56, 0.41), 0.8, 0.0),
    "KneePad": ((0.62, 0.55, 0.40), 0.6, 0.0),
    "Boot": ((0.45, 0.35, 0.24), 0.85, 0.0),
    "Sole": ((0.20, 0.17, 0.14), 0.9, 0.0),
    "Skin": ((0.74, 0.54, 0.40), 0.7, 0.0),
    "Stubble": ((0.45, 0.34, 0.27), 0.9, 0.0),
    "Lens": ((0.10, 0.12, 0.14), 0.15, 0.3),
    "GoggleFrame": ((0.14, 0.14, 0.14), 0.6, 0.0),
    "Gun": ((0.10, 0.10, 0.11), 0.45, 0.5),
    "GunPolymer": ((0.14, 0.14, 0.15), 0.7, 0.0),
    "Buckle": ((0.12, 0.12, 0.12), 0.6, 0.2),
})

# --------------------------------------------------------------------------
# Skeleton (bone name: head, tail, parent)
# --------------------------------------------------------------------------

HIP_Z = 0.93
SHOULDER = {+1: V((0.205, 0.0, 1.43)), -1: V((-0.205, 0.0, 1.43))}

# carbine held at the low ready across the body, stock at the right hip, muzzle to the left
STOCK = V((0.25, 0.10, 1.17))
GUN_DIR = V((-0.86, 0.46, -0.08)).normalized()
GUN_LEN = 0.86
GRIP = STOCK + GUN_DIR * 0.29 + V((0, 0, -0.06))
FOREGRIP = STOCK + GUN_DIR * 0.53 + V((0, 0, -0.035))
HAND = {+1: GRIP, -1: FOREGRIP}
ELBOW = {+1: V((0.30, -0.02, 1.13)), -1: V((-0.17, 0.12, 1.08))}

HIP = {+1: V((0.10, 0.0, HIP_Z)), -1: V((-0.10, 0.0, HIP_Z))}
KNEE = {+1: V((0.12, 0.02, 0.5)), -1: V((-0.12, 0.02, 0.5))}
ANKLE = {+1: V((0.145, -0.01, 0.10)), -1: V((-0.145, -0.01, 0.10))}

BONES = [
    ("root", V((0, 0, 0)), V((0, 0.25, 0)), None),
    ("hips", V((0, 0, HIP_Z - 0.04)), V((0, 0, 1.08)), "root"),
    ("spine", V((0, 0, 1.08)), V((0, 0, 1.28)), "hips"),
    ("chest", V((0, 0, 1.28)), V((0, 0, 1.48)), "spine"),
    ("neck", V((0, 0, 1.48)), V((0, 0.01, 1.56)), "chest"),
    ("head", V((0, 0.01, 1.56)), V((0, 0.01, 1.80)), "neck"),
    ("rifle", STOCK, STOCK + GUN_DIR * GUN_LEN, "hand.R"),
]
for side, tag in ((+1, "R"), (-1, "L")):
    BONES += [
        (f"upper_arm.{tag}", SHOULDER[side], ELBOW[side], "chest"),
        (f"forearm.{tag}", ELBOW[side], HAND[side], f"upper_arm.{tag}"),
        (f"hand.{tag}", HAND[side], HAND[side] + (HAND[side] - ELBOW[side]).normalized() * 0.08,
         f"forearm.{tag}"),
        (f"thigh.{tag}", HIP[side], KNEE[side], "hips"),
        (f"shin.{tag}", KNEE[side], ANKLE[side], f"thigh.{tag}"),
        (f"foot.{tag}", ANKLE[side], ANKLE[side] + V((0, 0.16, -0.06)), f"shin.{tag}"),
    ]


# --------------------------------------------------------------------------
# The soldier
# --------------------------------------------------------------------------

def legs():
    for side, tag in ((+1, "R"), (-1, "L")):
        h, k, a = HIP[side], KNEE[side], ANKLE[side]
        # baggy trousers: thigh and shin
        tube(h + V((0, 0, 0.06)), k, 0.095, 0.072, "Fatigue", f"thigh.{tag}", bulge=0.012,
             rings=5)
        tube(k + V((0, 0, 0.02)), a + V((0, 0, 0.1)), 0.072, 0.074, "Fatigue", f"shin.{tag}",
             bulge=0.006, rings=4)
        # trousers bloused over the boot top
        ellipsoid(a + V((0, 0, 0.1)), (0.08, 0.08, 0.035), "Fatigue", f"shin.{tag}", seg=12,
                  rings=6)
        # cargo pocket on the outer thigh with a flap
        out = V((side * 0.088, 0.0, 0))
        pc = h + (k - h) * 0.45 + out
        rbox(pc, (0.03, 0.12, 0.15), "FatigueDark", f"thigh.{tag}", bevel=0.2,
             rot=rot_xyz(0, side * -3, 0))
        rbox(pc + V((side * 0.006, 0, 0.07)), (0.034, 0.125, 0.03), "Fatigue", f"thigh.{tag}",
             bevel=0.25)
        # knee pad with a strap
        kp = k + V((0, 0.07, 0.0))
        ellipsoid(kp, (0.068, 0.04, 0.075), "KneePad", f"shin.{tag}", seg=12, rings=8)
        tube(k + V((0, 0, -0.035)), k + V((0, 0, -0.015)), 0.078, 0.078, "Webbing",
             f"shin.{tag}", rings=1)
        # boot: shaft, foot, toe cap, sole
        tube(a + V((0, 0, -0.05)), a + V((0, 0, 0.09)), 0.068, 0.064, "Boot", f"foot.{tag}",
             rings=2)
        foot_c = V((a.x, a.y + 0.06, 0.055))
        rbox(foot_c, (0.11, 0.25, 0.09), "Boot", f"foot.{tag}", bevel=0.35, smooth=True)
        ellipsoid(foot_c + V((0, 0.10, -0.01)), (0.056, 0.07, 0.048), "Boot", f"foot.{tag}",
                  seg=10, rings=6)
        rbox(V((foot_c.x, foot_c.y + 0.01, 0.012)), (0.12, 0.29, 0.025), "Sole", f"foot.{tag}",
             bevel=0.3)


def torso():
    # trouser seat / hips and the jacket skirt below the belt
    ellipsoid(V((0, 0, HIP_Z + 0.02)), (0.19, 0.12, 0.11), "Fatigue", "hips")
    tube(V((0, 0, 0.88)), V((0, 0, 1.06)), 0.19, 0.2, "Fatigue", "hips", flat=(1.0, 0.66),
         rings=2)
    # jacket body
    tube(V((0, 0, 1.02)), V((0, 0, 1.44)), 0.195, 0.21, "Fatigue", "spine", flat=(1.0, 0.62),
         bulge=0.02, rings=5)
    ellipsoid(V((0, 0, 1.43)), (0.215, 0.13, 0.07), "Fatigue", "chest")  # shoulder line
    # chest pockets
    for side in (+1, -1):
        rbox(V((side * 0.09, 0.13, 1.30)), (0.1, 0.03, 0.11), "FatigueDark", "chest", bevel=0.2)
        rbox(V((side * 0.09, 0.145, 1.355)), (0.105, 0.02, 0.035), "Fatigue", "chest", bevel=0.25)
    # lower jacket pockets peeking under the belt
    for side in (+1, -1):
        rbox(V((side * 0.1, 0.12, 0.93)), (0.12, 0.03, 0.1), "FatigueDark", "hips", bevel=0.2)
    # load-bearing harness: shoulder straps and a back panel
    for side in (+1, -1):
        p0 = V((side * 0.1, -0.12, 1.08))
        p1 = V((side * 0.11, -0.08, 1.46))
        p2 = V((side * 0.1, 0.12, 1.42))
        p3 = V((side * 0.1, 0.14, 1.08))
        for a, b, bone in ((p0, p1, "chest"), (p1, p2, "chest"), (p2, p3, "chest")):
            tube(a, b, 0.024, 0.024, "Webbing", bone, n=6, flat=(1.0, 0.35), rings=1,
                 roll=math.pi / 2 if b.y != a.y and abs(b.z - a.z) < 0.1 else 0.0)
        # strap buckles
        rbox(V((side * 0.1, 0.143, 1.2)), (0.04, 0.012, 0.03), "Buckle", "chest", bevel=0.2)
    rbox(V((0, -0.12, 1.25)), (0.26, 0.04, 0.3), "Webbing", "chest", bevel=0.25)
    # belt with buckle and pouches
    tube(V((0, 0, 1.02)), V((0, 0, 1.075)), 0.205, 0.205, "Webbing", "hips", flat=(1.0, 0.66),
         rings=1, n=16)
    rbox(V((0, 0.14, 1.047)), (0.07, 0.02, 0.05), "Buckle", "hips", bevel=0.2)
    for x, w, h in ((0.2, 0.09, 0.12), (0.1, 0.085, 0.11), (-0.1, 0.085, 0.11),
                    (-0.2, 0.09, 0.12)):
        ang = math.degrees(math.atan2(x, 0.14))
        y = 0.135 * math.cos(math.radians(ang)) + 0.01
        c = V((x, y, 1.0))
        rbox(c, (w, 0.06, h), "Pouch", "hips", rot=rot_xyz(0, 0, -ang * 0.8), bevel=0.25,
             smooth=False)
        rbox(c + V((0, 0.005, h * 0.42)), (w * 1.04, 0.065, 0.03), "Webbing", "hips",
             rot=rot_xyz(0, 0, -ang * 0.8), bevel=0.3)
    # canteen at the back hip
    tube(V((-0.12, -0.15, 0.93)), V((-0.12, -0.15, 1.06)), 0.045, 0.045, "Pouch", "hips",
         n=10, rings=1)


def arms():
    for side, tag in ((+1, "R"), (-1, "L")):
        s, e, h = SHOULDER[side], ELBOW[side], HAND[side]
        tube(s, e, 0.07, 0.06, "Fatigue", f"upper_arm.{tag}", bulge=0.01, rings=4)
        ellipsoid(e, (0.062, 0.062, 0.062), "Fatigue", f"forearm.{tag}", seg=10, rings=6)
        tube(e, h - (h - e).normalized() * 0.05, 0.06, 0.048, "Fatigue", f"forearm.{tag}",
             bulge=0.008, rings=3)
        # rolled cuff and hand
        cuff = h - (h - e).normalized() * 0.06
        tube(cuff, cuff + (h - e).normalized() * 0.02, 0.052, 0.052, "FatigueDark",
             f"forearm.{tag}", rings=1)
        d = (h - e).normalized()
        ellipsoid(h, (0.042, 0.05, 0.04), "Skin", f"hand.{tag}", seg=10, rings=6,
                  rot=look_matrix(e, h))
        # team-coloured shoulder guard: two overlapping plates over the deltoid
        out = V((side, 0, 0))
        up_dir = (e - s).normalized()
        frame = frame_from_dir(-up_dir, up=out)
        ellipsoid(s + out * 0.03 + V((0, 0, 0.0)), (0.11, 0.1, 0.075), "TeamColor",
                  f"upper_arm.{tag}", rot=rot_xyz(0, side * 28, 0), cut=-0.15, seg=14,
                  rings=10)
        ellipsoid(s + out * 0.05 + V((0, 0.0, -0.08)), (0.1, 0.095, 0.06), "TeamColor",
                  f"upper_arm.{tag}", rot=rot_xyz(0, side * 55, 0), cut=-0.1, seg=14,
                  rings=10)
        # strap holding the guard
        tube(s + up_dir * 0.15 - V((0, 0, 0.0)), s + up_dir * 0.17, 0.073, 0.072, "Webbing",
             f"upper_arm.{tag}", rings=1)
        del d, frame


def head():
    hc = V((0, 0.015, 1.645))
    # neck and head
    tube(V((0, 0, 1.46)), V((0, 0.01, 1.6)), 0.058, 0.055, "Skin", "neck", rings=2)
    ellipsoid(hc, (0.083, 0.098, 0.11), "Skin", "head", seg=16, rings=12)
    # jaw / chin and stubble
    ellipsoid(hc + V((0, 0.035, -0.055)), (0.07, 0.07, 0.055), "Stubble", "head", seg=12,
              rings=8)
    ellipsoid(hc + V((0, 0.095, -0.012)), (0.014, 0.022, 0.025), "Skin", "head", seg=8,
              rings=6)  # nose
    for side in (+1, -1):
        ellipsoid(hc + V((side * 0.083, 0.0, 0.0)), (0.012, 0.025, 0.032), "Skin", "head",
                  seg=8, rings=6)  # ears
    # scarf: a thick cowl round the neck and a draped fold on the chest
    torus(V((0, 0.0, 1.49)), 0.085, 0.045, "Scarf", "neck", n=20, k=8, scale=(1.15, 1.0, 1.0))
    torus(V((0, 0.0, 1.53)), 0.075, 0.035, "Scarf", "neck", n=18, k=7, rot=rot_xyz(8, 0, 0),
          scale=(1.1, 1.05, 1.0))
    tube(V((0.03, 0.1, 1.47)), V((0.0, 0.135, 1.33)), 0.05, 0.03, "Scarf", "chest", n=8,
         flat=(1.3, 0.5), bulge=0.01, rings=3)
    tube(V((-0.04, 0.1, 1.46)), V((-0.06, 0.13, 1.36)), 0.04, 0.025, "Scarf", "chest", n=8,
         flat=(1.2, 0.5), rings=2)
    # helmet: dome, rim, cover seam, team band
    dome_c = hc + V((0, -0.005, 0.03))
    ellipsoid(dome_c, (0.125, 0.14, 0.13), "Helmet", "head", seg=20, rings=12, cut=-0.08)
    torus(dome_c + V((0, 0, -0.008)), 0.125, 0.012, "Helmet", "head", n=24, k=5,
          scale=(1.0, 1.12, 1.0))
    tube(dome_c + V((0, 0, 0.012)), dome_c + V((0, 0, 0.045)), 0.128, 0.122, "TeamColor",
         "head", n=24, flat=(1.0, 1.1), rings=1)
    # chin strap
    for side in (+1, -1):
        tube(dome_c + V((side * 0.115, 0.01, -0.01)), hc + V((side * 0.05, 0.06, -0.1)),
             0.008, 0.008, "Webbing", "head", n=5, rings=1)
    # goggles: frame and two dark lenses across the eyes
    gz = hc.z + 0.012
    for side in (+1, -1):
        c = V((side * 0.036, hc.y + 0.088, gz))
        ellipsoid(c, (0.034, 0.016, 0.024), "GoggleFrame", "head", seg=10, rings=6,
                  rot=rot_xyz(0, 0, side * -18))
        ellipsoid(c + V((0, 0.01, 0)), (0.028, 0.012, 0.019), "Lens", "head", seg=10,
                  rings=6, rot=rot_xyz(0, 0, side * -18))
    torus(V((0, hc.y - 0.005, gz)), 0.088, 0.008, "GoggleFrame", "head", n=24, k=4,
          scale=(1.0, 1.1, 1.0))


def rifle():
    """M4-style carbine laid along GUN_DIR from the stock."""
    frame = frame_from_dir(GUN_DIR)

    def at(dist, up=0.0, side=0.0):
        return STOCK + GUN_DIR * dist + (frame @ V((side, 0, up)).to_4d()).to_3d()

    def piece(dist0, dist1, sy, sz, up=0.0, m="Gun", bevel=0.15):
        c = at((dist0 + dist1) / 2, up)
        return rbox(c, (sy, dist1 - dist0, sz), m, "rifle", rot=frame, bevel=bevel)

    piece(0.0, 0.13, 0.04, 0.08, up=-0.005, m="GunPolymer", bevel=0.2)  # stock
    piece(0.12, 0.22, 0.02, 0.03, up=0.0)  # buffer tube
    piece(0.2, 0.42, 0.045, 0.06, up=0.0)  # receiver
    piece(0.24, 0.38, 0.03, 0.03, up=0.045)  # carry handle
    piece(0.36, 0.40, 0.012, 0.03, up=0.03)
    piece(0.24, 0.27, 0.012, 0.03, up=0.03)
    piece(0.40, 0.62, 0.05, 0.055, up=0.0, m="GunPolymer", bevel=0.25)  # handguard
    for i in range(6):
        piece(0.42 + i * 0.033, 0.435 + i * 0.033, 0.054, 0.059, up=0.0, m="Gun", bevel=0.2)
    piece(0.6, 0.64, 0.012, 0.07, up=0.04)  # front sight post
    # barrel and flash hider
    tube(at(0.62), at(GUN_LEN - 0.04), 0.009, 0.009, "Gun", "rifle", n=8, rings=1)
    tube(at(GUN_LEN - 0.045), at(GUN_LEN), 0.013, 0.013, "Gun", "rifle", n=8, rings=1)
    # magazine (curved forward), pistol grip, trigger guard
    mag_top = at(0.33, -0.03)
    mag_bot = at(0.36, -0.2)
    m_frame = frame_from_dir((mag_bot - mag_top).normalized(), up=GUN_DIR)
    rbox((mag_top + mag_bot) / 2, (0.025, 0.17, 0.06), "GunPolymer", "rifle",
         rot=m_frame, bevel=0.2)
    g_top = at(0.27, -0.03)
    g_bot = at(0.24, -0.12)
    g_frame = frame_from_dir((g_bot - g_top).normalized(), up=GUN_DIR)
    rbox((g_top + g_bot) / 2, (0.03, 0.09, 0.035), "GunPolymer", "rifle", rot=g_frame,
         bevel=0.25)
    piece(0.27, 0.32, 0.01, 0.008, up=-0.05)



def build_armature():
    arm = bpy.data.armatures.new("RiflemanSkeleton")
    ob = bpy.data.objects.new("Skeleton", arm)
    bpy.context.scene.collection.objects.link(ob)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.mode_set(mode="EDIT")
    made = {}
    for name, head, tail, parent in BONES:
        b = arm.edit_bones.new(name)
        b.head, b.tail = head, tail
        made[name] = b
    for name, _h, _t, parent in BONES:
        if parent:
            made[name].parent = made[parent]
    bpy.ops.object.mode_set(mode="OBJECT")
    return ob


def main():
    args = parse_args({"out": "assets/models/ironbound/units/rifleman.glb", "render": None})
    bpy.ops.wm.read_factory_settings(use_empty=True)
    legs()
    torso()
    arms()
    head()
    rifle()
    body, _groups = merge("Rifleman", as_vertex_groups=True)
    skel = build_armature()
    body.parent = skel
    body.modifiers.new("Skeleton", "ARMATURE").object = skel
    out = export_glb(args["out"], skins=True)
    verts, tris = stats([body])
    print(f"exported {out}: {verts} verts, {tris} tris, {len(BONES)} bones, "
          f"{len(body.data.materials)} materials")
    if args["render"]:
        tall = (700, 1100)
        render_views(args["render"], [
            ("front", 0, 0, 2.0, tall), ("three_quarter", 35, 0, 2.0, tall),
            ("side", 90, 0, 2.0, tall), ("back", 180, 0, 2.0, tall),
            ("game_angle", 135, 48, 2.4, (700, 700)),
        ], target=(0, 0, 0.95))


main()
