"""Builds the starter city's build-up animation: assets/models/ironbound/construction/city_build_up.glb

Plays for a few seconds when a match starts: two tower cranes go up and swing loads, a
scaffold climbs the walls, small workers walk planks around and hammer, the command centre
rises in stages and dust puffs where each stage lands. Then the scaffold and the cranes come
down and the real command centre model takes over (source/match/city/CityBuildUp.gd).

Run (from the repository root):
    python3.11 tools/blender/build_construction.py              # bpy as a Python module
    python3.11 tools/blender/build_construction.py --preview    # also render a frame strip

Everything is ONE skinned mesh: every moving piece (crane mast, jib, trolley, hook, each
command-centre stage, scaffold level, worker, arm, dust puff) is a bone with rigid weights,
so the whole site costs one mesh instance (one draw call per material) and one skeleton.
Pieces that are not on stage yet are scaled to (almost) zero.

The command-centre stages are cut from the very same mesh build_assets.py exports for
command_center.glb (same bevel and baked AO), so the last frame matches the real model and
the hand-over is seamless. Timing comes from construction_timeline.json, which the sound
script (tools/audio/make_construction_sounds.py) reads too, so hammer hits and stage thuds
line up with the picture.

Conventions are those of build_assets.py: 1 unit = 1 m, front = +Y (Godot -Z), z up.
All geometry is generated here; the output is our own work (CC0).
"""

import json
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import bpy  # noqa: E402,I001
import bmesh  # noqa: E402
from mathutils import Vector  # noqa: E402

import build_assets as BA  # noqa: E402

OUT = os.path.join(BA.OUT_ROOT, "construction", "city_build_up.glb")
TIMELINE = json.load(open(os.path.join(HERE, "construction_timeline.json")))
FPS = TIMELINE["fps"]
LENGTH_S = TIMELINE["length_s"]
TINY = 0.0001  # "not on stage" scale; exactly 0 gives degenerate skinning matrices

BA.PALETTE.setdefault("Dust", ((0.90, 0.82, 0.68), 0.95, 0.0, False))
BA.PALETTE.setdefault("DustDark", ((0.76, 0.66, 0.50), 0.95, 0.0, False))


def F(seconds):
    return round(seconds * FPS)


# --------------------------------------------------------------------------
# Pieces: each piece is a Model part that becomes one bone
# --------------------------------------------------------------------------

class Piece:
    def __init__(self, name, pivot, parent=None, finish=True):
        self.name = name
        self.pivot = Vector(pivot)
        self.parent = parent
        self.part = BA.Part(name)
        self.finish = finish


PIECES = {}


def piece(name, pivot, parent=None):
    p = Piece(name, pivot, parent)
    PIECES[name] = p
    return p.part


# ---- tower crane ---------------------------------------------------------

MAST_H = 3.6
JIB_LEN = 2.7
COUNTER_LEN = 0.95


def truss(P, x0, x1, z, w, h, bays, m="SafetyYellow", t=0.035):
    """Triangular jib truss along X: two bottom chords, one top chord, zig-zag web."""
    bl = [Vector((x0, -w / 2, z)), Vector((x1, -w / 2, z))]
    br = [Vector((x0, w / 2, z)), Vector((x1, w / 2, z))]
    tp = [Vector((x0, 0, z + h)), Vector((x1, 0, z + h * 0.55))]
    P.beam(bl[0], bl[1], t, m)
    P.beam(br[0], br[1], t, m)
    P.beam(tp[0], tp[1], t, m)
    for i in range(bays):
        a, b = i / bays, (i + 1) / bays
        top_a = tp[0].lerp(tp[1], a)
        top_b = tp[0].lerp(tp[1], b)
        for side in (bl, br):
            p0 = side[0].lerp(side[1], a)
            p1 = side[0].lerp(side[1], b)
            P.beam(p0, top_b if i % 2 == 0 else top_a, t * 0.7, m, caps=False)
            if i % 2 == 0:
                P.beam(top_b, p1, t * 0.7, m, caps=False)
            else:
                P.beam(top_a, p1, t * 0.7, m, caps=False)
        P.beam(bl[0].lerp(bl[1], b), br[0].lerp(br[1], b), t * 0.6, m, caps=False)


def tower_crane(tag, x, y):
    """Mast (with ballast base), slewing jib with cab, trolley, cable and hook with a load."""
    mast = piece("CraneMast" + tag, (x, y, 0))
    with mast.at(loc=(x, y, 0)):
        mast.box((0.7, 0.7, 0.18), base=True, m="Concrete")
        mast.box((0.5, 0.5, 0.12), loc=(0, 0, 0.18), base=True, m="ConcreteDark")
        BA.lattice(mast, 0.13, 0.13, 0.3, MAST_H, 9, m="SafetyYellow", w=0.035, leg_w=0.05)
        mast.box((0.34, 0.34, 0.06), loc=(0, 0, MAST_H), base=True, m="DarkMetal")
    jib = piece("CraneJib" + tag, (x, y, MAST_H + 0.06), parent="CraneMast" + tag)
    zj = MAST_H + 0.06
    with jib.at(loc=(x, y, zj)):
        jib.cyl(0.14, 0.08, m="DarkMetal", n=8)
        truss(jib, -0.1, JIB_LEN, 0.08, 0.2, 0.22, 7)
        truss(jib, 0.1, -COUNTER_LEN, 0.08, 0.2, 0.18, 3)
        jib.box((0.3, 0.26, 0.2), loc=(-COUNTER_LEN + 0.2, 0, 0.0), base=True, m="Concrete")
        # cab with team-coloured roof, apex with tie bars
        jib.box((0.2, 0.18, 0.16), loc=(0.06, -0.2, -0.02), base=True, m="SafetyYellow")
        jib.box((0.21, 0.19, 0.06), loc=(0.06, -0.2, 0.06), base=True, m="Glass")
        jib.box((0.24, 0.22, 0.03), loc=(0.06, -0.2, 0.14), base=True, m="TeamColor")
        jib.beam((0, 0, 0.08), (0, 0, 0.75), 0.05, m="SafetyYellow")
        jib.beam((0, 0, 0.75), (JIB_LEN * 0.6, 0, 0.27), 0.018, m="DarkMetal", caps=False)
        jib.beam((0, 0, 0.75), (-COUNTER_LEN + 0.1, 0, 0.24), 0.018, m="DarkMetal",
                 caps=False)
        jib.box((0.06, 0.06, 0.06), loc=(JIB_LEN, 0, 0.1), m="TailLight")
    trolley = piece("CraneTrolley" + tag, (x + 1.4, y, zj + 0.06), parent="CraneJib" + tag)
    with trolley.at(loc=(x + 1.4, y, zj + 0.06)):
        trolley.box((0.18, 0.24, 0.05), loc=(0, 0, -0.04), base=True, m="DarkMetal")
    # cable: 1 m long downwards from the trolley; its bone scales it to the hook depth
    cable = piece("CraneCable" + tag, (x + 1.4, y, zj + 0.02), parent="CraneTrolley" + tag)
    with cable.at(loc=(x + 1.4, y, zj + 0.02)):
        cable.box((0.012, 0.012, 1.0), loc=(-0.03, 0, -1.0), base=True, m="DarkMetal")
        cable.box((0.012, 0.012, 1.0), loc=(0.03, 0, -1.0), base=True, m="DarkMetal")
    hook = piece("CraneHook" + tag, (x + 1.4, y, zj + 0.02 - 1.0), parent="CraneTrolley" + tag)
    with hook.at(loc=(x + 1.4, y, zj + 0.02 - 1.0)):
        hook.box((0.1, 0.08, 0.1), loc=(0, 0, -0.1), base=True, m="SafetyYellow")
        hook.cyl(0.02, 0.12, loc=(0, 0, -0.22), m="DarkMetal", n=4)
        # load: a bundle of steel beams on two slings
        hook.beam((0, 0, -0.22), (-0.22, 0, -0.42), 0.012, m="DarkMetal", caps=False)
        hook.beam((0, 0, -0.22), (0.22, 0, -0.42), 0.012, m="DarkMetal", caps=False)
        for k in range(3):
            hook.box((0.7, 0.07, 0.06), loc=(0, -0.07 + k * 0.07, -0.48), base=True,
                     m="RedPaint" if k == 1 else "Rust")
        hook.box((0.7, 0.07, 0.06), loc=(0, -0.035, -0.42), base=True, m="Rust")
        hook.box((0.7, 0.07, 0.06), loc=(0, 0.035, -0.42), base=True, m="Rust")


# ---- scaffold --------------------------------------------------------------

SCAFFOLD_X = 1.62
SCAFFOLD_Y0, SCAFFOLD_Y1 = -1.55, 0.95
SCAFFOLD_LEVELS = [0.0, 0.5, 1.0]  # bottom of each lift
SCAFFOLD_LIFT = 0.5


def scaffold_level(index):
    z0 = SCAFFOLD_LEVELS[index]
    z1 = z0 + SCAFFOLD_LIFT
    P = piece("Scaffold%d" % index, (0, 0, z0))
    # back and the two sides; the front stays open so the entrance shows
    runs = [
        ((-SCAFFOLD_X, SCAFFOLD_Y0), (SCAFFOLD_X, SCAFFOLD_Y0), (0, -1)),
        ((-SCAFFOLD_X, SCAFFOLD_Y0), (-SCAFFOLD_X, SCAFFOLD_Y1), (-1, 0)),
        ((SCAFFOLD_X, SCAFFOLD_Y0), (SCAFFOLD_X, SCAFFOLD_Y1), (1, 0)),
    ]
    depth = 0.28
    for (ax, ay), (bx, by), (ox, oy) in runs:
        a = Vector((ax, ay, 0))
        b = Vector((bx, by, 0))
        length = (b - a).length
        posts = max(2, int(length / 0.6) + 1)
        out = Vector((ox, oy, 0)) * depth
        for i in range(posts):
            p = a.lerp(b, i / (posts - 1))
            for q in (p, p + out):
                P.beam(q + Vector((0, 0, z0)), q + Vector((0, 0, z1)), 0.028, m="Steel",
                       caps=False)
            P.beam(p + Vector((0, 0, z1 - 0.02)), p + out + Vector((0, 0, z1 - 0.02)), 0.022,
                   m="Steel", caps=False)
        # guard rail and a diagonal brace on the outside, planks on top
        P.beam(a + out + Vector((0, 0, z1 - 0.02)), b + out + Vector((0, 0, z1 - 0.02)),
               0.022, m="Steel", caps=False)
        P.beam(a + out + Vector((0, 0, z0 + 0.25)), b + out + Vector((0, 0, z0 + 0.25)),
               0.018, m="SafetyYellow", caps=False)
        P.beam(a + out + Vector((0, 0, z0)), b + out + Vector((0, 0, z1)), 0.018, m="Steel",
               caps=False)
        mid = (a + b) / 2 + out / 2
        rot = math.degrees(math.atan2(b.y - a.y, b.x - a.x))
        P.box((length + 0.1, depth, 0.025), loc=(mid.x, mid.y, z1), rot=(0, 0, rot), base=True,
              m="Wood")


# ---- workers ---------------------------------------------------------------

def worker_body(P, carry=None):
    """A 0.45 m worker facing +Y (the game's unit scale): team vest, yellow hard hat."""
    for sx in (-1, 1):
        P.box((0.055, 0.06, 0.17), loc=(sx * 0.035, 0, 0.0), base=True, m="FatigueDark")
        P.box((0.06, 0.08, 0.03), loc=(sx * 0.035, 0.01, 0.0), base=True, m="DarkMetal")
    P.box((0.14, 0.09, 0.15), loc=(0, 0, 0.17), base=True, taper=(1.0, 0.9), m="TeamColor")
    P.box((0.15, 0.1, 0.03), loc=(0, 0.002, 0.24), base=True, m="SafetyYellow")
    P.box((0.07, 0.07, 0.07), loc=(0, 0.0, 0.32), base=True, m="Skin")
    P.ico(0.056, loc=(0, -0.005, 0.385), scale=(1, 1.1, 0.62), m="SafetyYellow", subdiv=1)
    P.box((0.04, 0.1, 0.04), loc=(-0.09, 0.03, 0.26), m="TeamColor")  # left arm
    if carry == "plank":
        P.box((0.06, 0.62, 0.03), loc=(0.07, 0.04, 0.35), m="Wood")
        P.box((0.04, 0.06, 0.12), loc=(0.09, 0.0, 0.27), m="TeamColor")
    elif carry == "beam":
        P.box((0.05, 0.5, 0.05), loc=(0.07, 0.02, 0.35), m="Rust")
        P.box((0.04, 0.06, 0.12), loc=(0.09, 0.0, 0.27), m="TeamColor")


def worker(tag, x, y, kind):
    body = piece("Worker" + tag, (x, y, 0))
    with body.at(loc=(x, y, 0)):
        worker_body(body, carry=kind if kind in ("plank", "beam") else None)
    if kind == "hammer":
        arm = piece("Arm" + tag, (x + 0.09, y, 0.3), parent="Worker" + tag)
        with arm.at(loc=(x + 0.09, y, 0.3)):
            arm.box((0.04, 0.04, 0.13), loc=(0, 0.0, -0.12), base=True, m="TeamColor")
            arm.box((0.02, 0.02, 0.14), loc=(0, 0.0, -0.22), base=True, m="WoodDark")
            arm.box((0.05, 0.035, 0.035), loc=(0, 0.0, -0.24), base=True, m="DarkMetal")


# ---- dust ----------------------------------------------------------------------

def dust_puff(tag, x, y, z, size):
    P = piece("Dust" + tag, (x, y, z))
    with P.at(loc=(x, y, z)):
        P.ico(0.22 * size, loc=(0, 0, 0.1 * size), scale=(1.3, 1.1, 0.8), m="Dust", subdiv=1,
              rough=0.25, seed=hash(tag) % 97)
        P.ico(0.16 * size, loc=(0.16 * size, 0.08 * size, 0.06 * size), scale=(1.2, 1, 0.8),
              m="DustDark", subdiv=1, rough=0.25, seed=hash(tag) % 89 + 1)
        P.ico(0.14 * size, loc=(-0.15 * size, -0.05 * size, 0.05 * size), scale=(1.2, 1, 0.8),
              m="Dust", subdiv=1, rough=0.25, seed=hash(tag) % 83 + 2)


# --------------------------------------------------------------------------
# The command centre, cut into stages
# --------------------------------------------------------------------------

def command_centre_objects():
    """Builds command_center exactly like build_assets.py does (same bevel and AO)."""
    M = BA.Model("command_center", "buildings")
    BA.command_center(M)
    objs = M.finalize(recenter=True)
    bpy.context.view_layer.update()
    BA.finish_objects(objs, "buildings")
    assert len(objs) == 1, "command_center is expected to be one object"
    return list(objs.values())[0]


def split_by_height(ob, bands):
    """One copy of ob per (name, z0, z1) band, keeping the faces whose centre lies in it."""
    out = []
    for name, z0, z1 in bands:
        copy = ob.copy()
        copy.data = ob.data.copy()
        copy.name = name
        bpy.context.scene.collection.objects.link(copy)
        bm = bmesh.new()
        bm.from_mesh(copy.data)
        drop = [f for f in bm.faces if not (z0 <= f.calc_center_median().z < z1)]
        bmesh.ops.delete(bm, geom=drop, context="FACES")
        bm.to_mesh(copy.data)
        bm.free()
        out.append(copy)
    bpy.data.objects.remove(ob)
    return out


STAGE_BANDS = [  # name, bottom, top (m); a face belongs to the band its centre is in
    ("Stage0", -1.0, 0.09),  # pad
    ("Stage1", 0.09, 0.42),  # armoured plinth, yard clutter
    ("Stage2", 0.42, 1.08),  # main hall
    ("Stage3", 1.08, 1.8),  # upper command block, radar, tower shaft
    ("Stage4", 1.8, 99.0),  # tower top, antenna, flag
]


# --------------------------------------------------------------------------
# Assembling the rig
# --------------------------------------------------------------------------

def make_objects():
    """Creates every piece as an object with a vertex group named after its bone."""
    objects = []
    hq = command_centre_objects()
    for ob in split_by_height(hq, STAGE_BANDS):
        z0 = max(0.0, next(b[1] for b in STAGE_BANDS if b[0] == ob.name))
        PIECES[ob.name] = Piece(ob.name, (0, 0, z0))
        PIECES[ob.name].prebuilt = ob
        objects.append(ob)
    for name, piece_ in PIECES.items():
        if getattr(piece_, "prebuilt", None) is not None:
            continue
        part = piece_.part
        mesh = bpy.data.meshes.new(name)
        part.bm.to_mesh(mesh)
        for mn in part.mats:
            mesh.materials.append(BA.get_mat(mn))
        ob = bpy.data.objects.new(name, mesh)
        bpy.context.scene.collection.objects.link(ob)
        objects.append(ob)
    # props get the baked AO but no bevel (thin struts would triple in triangles)
    props = {ob.name: ob for ob in objects if not ob.name.startswith("Stage")}
    real_bevel = BA._bevel
    BA._bevel = lambda ob, width: None
    try:
        BA.finish_objects(props, "units")
    finally:
        BA._bevel = real_bevel
    for ob in objects:
        group = ob.vertex_groups.new(name=ob.name)
        group.add(list(range(len(ob.data.vertices))), 1.0, "REPLACE")
    return objects


def make_armature():
    data = bpy.data.armatures.new("CityBuildUpRig")
    rig = bpy.data.objects.new("CityBuildUp", data)
    bpy.context.scene.collection.objects.link(rig)
    bpy.context.view_layer.objects.active = rig
    rig.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bones = {}
    # bones point along +Y with no roll, so their local axes are the model's axes
    for name, p in PIECES.items():
        eb = data.edit_bones.new(name)
        eb.head = p.pivot
        eb.tail = p.pivot + Vector((0, 0.15, 0))
        eb.roll = 0.0
        bones[name] = eb
    for name, p in PIECES.items():
        if p.parent:
            bones[name].parent = bones[p.parent]
            bones[name].use_connect = False
    bpy.ops.object.mode_set(mode="OBJECT")
    for pb in rig.pose.bones:
        pb.rotation_mode = "XYZ"
    return rig


def join_into_mesh(objects, rig):
    target = objects[0]
    with bpy.context.temp_override(active_object=target, selected_editable_objects=objects,
                                   selected_objects=objects):
        bpy.ops.object.join()
    target.name = "CityBuildUpMesh"
    target.data.name = "CityBuildUpMesh"
    target.parent = rig
    mod = target.modifiers.new("Armature", "ARMATURE")
    mod.object = rig
    return target


# --------------------------------------------------------------------------
# Animation
# --------------------------------------------------------------------------

class Keys:
    def __init__(self, rig):
        self.rig = rig

    def key(self, bone, t, loc=None, rot=None, scale=None):
        pb = self.rig.pose.bones[bone]
        frame = F(t)
        if loc is not None:
            pb.location = loc
            pb.keyframe_insert("location", frame=frame)
        if rot is not None:
            pb.rotation_euler = [math.radians(a) for a in rot]
            pb.keyframe_insert("rotation_euler", frame=frame)
        if scale is not None:
            pb.scale = (scale, scale, scale) if isinstance(scale, (int, float)) else scale
            pb.keyframe_insert("scale", frame=frame)

    def hidden_until(self, bone, t, end=None):
        self.key(bone, 0, scale=TINY)
        if t > 0:
            self.key(bone, max(0.0, t - 1.0 / FPS), scale=TINY)
        if end is not None:
            self.key(bone, end, scale=TINY)
            self.key(bone, LENGTH_S, scale=TINY)


def ease_out_back(x, overshoot=1.4):
    x -= 1.0
    return 1.0 + x * x * ((overshoot + 1.0) * x + overshoot)


def animate(rig):
    K = Keys(rig)
    T = TIMELINE
    step = 2.0 / FPS
    # ---- stages: each grows up from its base with a little overshoot, then dust ----
    for stage in T["stages"]:
        name, t0, t1 = stage["bone"], stage["start_s"], stage["land_s"]
        K.hidden_until(name, t0)
        t = t0
        while t < t1:
            x = (t - t0) / (t1 - t0)
            s = ease_out_back(x, 1.2)
            if name == "Stage0":  # the pad spreads out instead of growing up
                K.key(name, t, scale=(0.25 + 0.75 * s, 0.25 + 0.75 * s, 1.0))
            else:
                K.key(name, t, scale=(0.9 + 0.1 * min(1.0, x * 1.5), 0.9 + 0.1 * min(1.0, x * 1.5),
                                      max(0.02, s)))
            t += step
        K.key(name, t1, scale=1.0)
        K.key(name, LENGTH_S, scale=1.0)
    for puff in T["dust"]:
        name, t0 = puff["bone"], puff["t_s"]
        life = puff.get("life_s", 0.7)
        K.hidden_until(name, t0, end=t0 + life)
        K.key(name, t0 + life * 0.25, loc=(0, 0, 0.05), scale=1.0)
        K.key(name, t0 + life * 0.6, loc=(0, 0, 0.18), scale=1.25)
        K.key(name, t0, loc=(0, 0, 0))
        K.key(name, t0 + life * 0.97, loc=(0, 0, 0.3), scale=0.5)
    # ---- scaffold: each lift snaps up just before its stage; all come down at the end ----
    for lift in T["scaffold"]:
        name, t0, t_down = lift["bone"], lift["up_s"], lift["down_s"]
        K.hidden_until(name, t0, end=t_down + 0.35)
        K.key(name, t0, scale=(1, 1, 0.05))
        K.key(name, t0 + 0.3, scale=1.0)
        K.key(name, t_down, scale=1.0)
        K.key(name, t_down + 0.3, scale=(1, 1, 0.05))
    # ---- cranes ----
    for crane in T["cranes"]:
        tag = crane["tag"]
        mast, jib = "CraneMast" + tag, "CraneJib" + tag
        trolley, cable, hook = "CraneTrolley" + tag, "CraneCable" + tag, "CraneHook" + tag
        up, down = crane["up_s"], crane["down_s"]
        K.hidden_until(mast, up)
        K.key(mast, up, scale=(1, 1, 0.05))
        K.key(mast, up + 0.6, scale=1.0)
        K.key(mast, down, scale=1.0)
        K.key(mast, down + 0.55, scale=(1, 1, 0.03))
        K.key(mast, down + 0.6, scale=TINY)
        K.key(mast, LENGTH_S, scale=TINY)
        # the jib unfolds, then slews between the stock pile and the building
        K.key(jib, 0, rot=(0, 0, crane["swing_deg"][0]), scale=(0.05, 1, 1))
        K.key(jib, up + 0.45, scale=(0.05, 1, 1))
        K.key(jib, up + 0.8, scale=1.0)
        K.key(jib, down - 0.3, scale=1.0)
        K.key(jib, down, scale=(0.05, 1, 1))
        for t, ang in zip(crane["swing_t_s"], crane["swing_deg"]):
            K.key(jib, t, rot=(0, 0, ang))
        for t, x in zip(crane["trolley_t_s"], crane["trolley_m"]):
            K.key(trolley, t, loc=(x, 0, 0))
        for t, depth in zip(crane["hook_t_s"], crane["hook_m"]):
            K.key(cable, t, scale=(1, 1, depth))
            K.key(hook, t, loc=(0, 0, 1.0 - depth))
    # ---- workers ----
    for w in T["workers"]:
        bone = "Worker" + w["tag"]
        K.hidden_until(bone, w["in_s"], end=w["out_s"])
        K.key(bone, w["in_s"], scale=0.2)
        K.key(bone, w["in_s"] + 0.2, scale=1.0)
        K.key(bone, w["out_s"] - 0.2, scale=1.0)
        if w["kind"] == "hammer":
            K.key(bone, 0, rot=(0, 0, w["facing_deg"]))
            arm = "Arm" + w["tag"]
            t = w["in_s"] + w.get("phase_s", 0.0)
            period = w.get("period_s", 0.42)
            while t < w["out_s"] - 0.3:
                K.key(arm, t, rot=(-150, 0, 0))  # raised behind the head
                K.key(arm, t + period * 0.65, rot=(-160, 0, 0))
                K.key(arm, t + period * 0.85, rot=(-45, 0, 0))  # strike
                K.key(bone, t + period * 0.85, loc=(0, 0, 0))
                K.key(bone, t + period * 0.92, loc=(0, 0, -0.012))
                t += period
            K.key(arm, w["out_s"], rot=(0, 0, 0))
        else:
            pts = [Vector((p[0], p[1], 0)) for p in w["path"]]
            home = pts[0]
            seg = [(pts[i], pts[(i + 1) % len(pts)]) for i in range(len(pts))]
            total = sum((b - a).length for a, b in seg)
            speed = w.get("speed_mps", 0.55)
            t = w["in_s"]
            heading = None
            while t <= w["out_s"]:
                d = ((t - w["in_s"]) * speed) % total
                for a, b in seg:
                    length = (b - a).length
                    if d <= length:
                        pos = a + (b - a) * (d / length)
                        direction = (b - a).normalized()
                        break
                    d -= length
                angle = math.degrees(math.atan2(-direction.x, direction.y))
                if heading is not None:  # no 350-degree spins between keys
                    while angle - heading > 180:
                        angle -= 360
                    while angle - heading < -180:
                        angle += 360
                heading = angle
                bob = abs(math.sin((t - w["in_s"]) * math.pi * 3.4)) * 0.018
                rel = pos - home
                K.key(bone, t, loc=(rel.x, rel.y, bob), rot=(0, 0, angle))
                t += step


def build():
    BA.reset_scene()
    scene = bpy.context.scene
    scene.render.fps = FPS
    scene.frame_start = 0
    scene.frame_end = F(LENGTH_S)
    for c in TIMELINE["cranes"]:
        tower_crane(c["tag"], *c["at"])
    for i in range(len(SCAFFOLD_LEVELS)):
        scaffold_level(i)
    for w in TIMELINE["workers"]:
        start = w["at"] if w["kind"] == "hammer" else w["path"][0]
        worker(w["tag"], start[0], start[1], w["kind"])
    for d in TIMELINE["dust"]:
        dust_puff(d["bone"][4:], d["at"][0], d["at"][1], d["at"][2] if len(d["at"]) > 2 else 0,
                  d.get("size", 1.0))
    objects = make_objects()
    tris = sum(len(p.vertices) - 2 for ob in objects for p in ob.data.polygons)
    rig = make_armature()
    mesh = join_into_mesh(objects, rig)
    rig.animation_data_create()
    action = bpy.data.actions.new("build")
    rig.animation_data.action = action
    animate(rig)
    for fc in _fcurves(action):
        for kp in fc.keyframe_points:
            kp.interpolation = "LINEAR"
    scene.frame_set(0)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=OUT, export_format="GLB", export_yup=True, export_apply=False,
        export_cameras=False, export_lights=False, export_texcoords=False,
        export_normals=True, export_materials="EXPORT", use_selection=False,
        export_extras=False, export_animations=True, export_skins=True,
        export_animation_mode="ACTIONS", export_force_sampling=True,
        export_vertex_color="ACTIVE", export_def_bones=False)
    mats = len(mesh.data.materials)
    print("city_build_up: %d tris, %d bones, %d materials, %.1f s -> %s"
          % (tris, len(rig.data.bones), mats, LENGTH_S, os.path.relpath(OUT, BA.REPO)))
    return rig


def _fcurves(action):
    if hasattr(action, "fcurves") and len(getattr(action, "fcurves", [])):
        return list(action.fcurves)
    out = []  # Blender 4.4+ layered actions
    for layer in getattr(action, "layers", []):
        for strip in layer.strips:
            for bag in strip.channelbags:
                out += list(bag.fcurves)
    return out


# --------------------------------------------------------------------------
# Preview: a strip of frames through the game's camera
# --------------------------------------------------------------------------

def render_strip(rig, times, path):
    scene = bpy.context.scene
    BA.add_preview_ground()
    BA.add_sun()
    for ob in scene.objects:
        if ob.type == "MESH" and ob.name == "CityBuildUpMesh":
            BA.apply_team([ob], 0)
    cam, back = BA.make_camera(30.0, 200.0)
    cam.data.ortho_scale = 11.0
    cam.location = Vector((0, 0, 1.2)) + back * 60
    BA.setup_render(16, 640, 480)
    files = []
    for i, t in enumerate(times):
        scene.frame_set(F(t))
        files.append(os.path.join(BA.PREVIEW_DIR, "_frame%d.png" % i))
        BA.render_to(files[-1])
    _save_strip(files, times, path)
    for f in files:
        os.remove(f)


def _save_strip(files, times, path):
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("pillow missing, frames not combined")
        return
    frames = [Image.open(f).convert("RGB") for f in files]
    w, h = frames[0].size
    cols = min(4, len(frames))
    rows = (len(frames) + cols - 1) // cols
    sheet = Image.new("RGB", (w * cols, h * rows), (20, 20, 20))
    for i, img in enumerate(frames):
        sheet.paste(img, ((i % cols) * w, (i // cols) * h))
        ImageDraw.Draw(sheet).text(((i % cols) * w + 10, (i // cols) * h + 10),
                                   "%.1f s" % times[i], fill=(0, 0, 0))
    sheet.save(path, quality=82)
    print("preview:", path)


if __name__ == "__main__":
    rig = build()
    if "--preview" in sys.argv:
        render_strip(rig, [0.3, 0.9, 1.6, 2.4, 3.2, 4.0, 4.8, 5.6],
                     os.path.join(BA.PREVIEW_DIR, "city_build_up.jpg"))
