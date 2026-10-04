"""Small modelling kit shared by the single-model build scripts (build_soldier.py,
build_raider.py). Primitives are bmeshes baked straight into world space and tagged with a
material and a group; `merge` turns a set of groups into one mesh object, with the groups
either as vertex groups (for skinning) or kept as separate objects.

Needs the pip `bpy` module (or `blender -b -P`). Blender's axes: Z up, models face +Y.
"""

import math
import os
import sys

import bpy  # noqa: I001 (bpy must load before bmesh)
import bmesh
from mathutils import Euler, Matrix, Vector

V = Vector
IDENTITY = Matrix.Identity(4)

# name: (sRGB colour, roughness, metallic[, emission strength]). Scripts add their own.
# "TeamColor" is recoloured per faction in-game.
PALETTE = {}

PARTS = []  # (bmesh, material name, group name, smooth)


def parse_args(defaults):
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    args = dict(defaults)
    i = 0
    while i < len(argv):
        if argv[i].startswith("--") and i + 1 < len(argv):
            args[argv[i][2:]] = argv[i + 1]
            i += 2
        else:
            i += 1
    return args


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def mat(name):
    m = bpy.data.materials.get(name)
    if m is not None:
        return m
    entry = PALETTE[name]
    srgb, rough, metal = entry[:3]
    lin = tuple(srgb_to_linear(c) for c in srgb)
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*lin, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    if len(entry) > 3:
        bsdf.inputs["Emission Color"].default_value = (*lin, 1.0)
        bsdf.inputs["Emission Strength"].default_value = entry[3]
    m.diffuse_color = (*lin, 1.0)
    return m


# --------------------------------------------------------------------------
# Transforms
# --------------------------------------------------------------------------

def rot_xyz(x=0, y=0, z=0):
    return Euler((math.radians(x), math.radians(y), math.radians(z)), "XYZ").to_matrix().to_4x4()


def look_matrix(p0, p1):
    """Rotation taking +Z to the direction p0 -> p1."""
    d = (Vector(p1) - Vector(p0)).normalized()
    return d.to_track_quat("Z", "Y").to_matrix().to_4x4()


def frame_from_dir(d, up=(0, 0, 1)):
    """Rotation with local +Y along d and local +Z as close to `up` as possible."""
    y = Vector(d).normalized()
    x = y.cross(Vector(up)).normalized()
    z = x.cross(y).normalized()
    return Matrix((x, y, z)).transposed().to_4x4()


# --------------------------------------------------------------------------
# Primitives
# --------------------------------------------------------------------------

def add(bm, m, group, smooth=True, matrix=None):
    if matrix is not None:
        bmesh.ops.transform(bm, matrix=matrix, verts=bm.verts)
    PARTS.append((bm, m, group, smooth))
    return bm


def ellipsoid(c, r, m, group, seg=14, rings=9, rot=IDENTITY, cut=None):
    """r = (rx, ry, rz). cut: keep only the part with local z >= cut (a dome), capped."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=1.0)
    if cut is not None:
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(0, 0, cut), plane_no=(0, 0, 1),
                               clear_inner=True)
        edges = [e for e in bm.edges if e.is_boundary]
        if edges:
            bmesh.ops.edgeloop_fill(bm, edges=edges)
    s = Matrix.Diagonal((r[0], r[1], r[2], 1.0))
    return add(bm, m, group, True, Matrix.Translation(Vector(c)) @ rot @ s)


def tube(p0, p1, r0, r1, m, group, n=12, bulge=0.0, flat=(1.0, 1.0), rings=4, roll=0.0,
         smooth=True):
    """Tapered capped tube between two points; bulge widens the middle."""
    bm = bmesh.new()
    length = (Vector(p1) - Vector(p0)).length
    loops = []
    for i in range(rings + 1):
        t = i / rings
        r = r0 + (r1 - r0) * t + bulge * math.sin(math.pi * t)
        loop = []
        for k in range(n):
            a = 2 * math.pi * k / n + roll
            loop.append(bm.verts.new((math.cos(a) * r * flat[0], math.sin(a) * r * flat[1],
                                      t * length)))
        loops.append(loop)
    for a, b in zip(loops, loops[1:]):
        for k in range(n):
            bm.faces.new((a[k], a[(k + 1) % n], b[(k + 1) % n], b[k]))
    bm.faces.new(list(reversed(loops[0])))
    bm.faces.new(loops[-1])
    return add(bm, m, group, smooth, Matrix.Translation(Vector(p0)) @ look_matrix(p0, p1))


def pipe(points, r, m, group, n=8, closed=False):
    """A bent bar through a list of points (roll cages, bull bars, handles)."""
    pts = [Vector(p) for p in points]
    if closed:
        pts = pts + [pts[0]]
    for a, b in zip(pts, pts[1:]):
        tube(a, b, r, r, m, group, n=n, rings=1)
    for p in pts[1:-1] if not closed else pts[:-1]:
        ellipsoid(p, (r, r, r), m, group, seg=n, rings=max(4, n // 2))


def rbox(c, size, m, group, rot=IDENTITY, bevel=0.15, smooth=False, taper=1.0, segments=2):
    """Box with bevelled edges. size = full extents; bevel is a fraction of the smallest side;
    taper scales the +Z face."""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    for v in bm.verts:
        if v.co.z > 0:
            v.co.x *= taper
            v.co.y *= taper
    bmesh.ops.scale(bm, vec=Vector(size), verts=bm.verts)
    if bevel > 0:
        bmesh.ops.bevel(bm, geom=bm.edges[:], offset=min(size) * bevel, segments=segments,
                        affect="EDGES", profile=0.5)
    return add(bm, m, group, smooth, Matrix.Translation(Vector(c)) @ rot)


def torus(c, R, r, m, group, rot=IDENTITY, n=20, k=6, scale=(1, 1, 1), arc=(0.0, 360.0)):
    """Ring in the local XY plane; `arc` limits it to a range of degrees (open ends capped)."""
    bm = bmesh.new()
    full = arc[1] - arc[0] >= 360.0
    count = n if full else n + 1
    loops = []
    for i in range(count):
        a = math.radians(arc[0] + (arc[1] - arc[0]) * i / n)
        ca, sa = math.cos(a), math.sin(a)
        loop = []
        for j in range(k):
            b = 2 * math.pi * j / k
            rr = R + r * math.cos(b)
            loop.append(bm.verts.new((ca * rr, sa * rr, r * math.sin(b))))
        loops.append(loop)
    pairs = [(loops[i], loops[(i + 1) % n]) for i in range(n)] if full else \
        list(zip(loops, loops[1:]))
    for a, b in pairs:
        for j in range(k):
            bm.faces.new((a[j], b[j], b[(j + 1) % k], a[(j + 1) % k]))
    if not full:
        bm.faces.new(list(reversed(loops[0])))
        bm.faces.new(loops[-1])
    s = Matrix.Diagonal((scale[0], scale[1], scale[2], 1.0))
    return add(bm, m, group, True, Matrix.Translation(Vector(c)) @ rot @ s)


def extrude_x(profile, x0, x1, m, group, bevel=0.0, smooth=False):
    """Prism from a (y, z) polygon (counter-clockwise seen from +X) between x0 and x1."""
    bm = bmesh.new()
    left = [bm.verts.new((x0, y, z)) for y, z in profile]
    right = [bm.verts.new((x1, y, z)) for y, z in profile]
    n = len(profile)
    bm.faces.new(list(reversed(left)))
    bm.faces.new(right)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((left[i], left[j], right[j], right[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    if bevel > 0:
        bmesh.ops.bevel(bm, geom=bm.edges[:], offset=bevel, segments=2, affect="EDGES",
                        profile=0.5, clamp_overlap=True)
    return add(bm, m, group, smooth)


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def merge(name, groups=None, as_vertex_groups=False, sharp_angle=40.0):
    """Joins the parts of the given groups (all when None) into one object. Returns
    (object, vertex group names)."""
    bm = bmesh.new()
    mats, names, group_of_vert = [], [], []
    keep = []
    for part, mname, group, smooth in PARTS:
        if groups is not None and group not in groups:
            keep.append((part, mname, group, smooth))
            continue
        if mname not in mats:
            mats.append(mname)
        if group not in names:
            names.append(group)
        vmap = {}
        for v in part.verts:
            vmap[v] = bm.verts.new(v.co)
            group_of_vert.append(names.index(group))
        for f in part.faces:
            nf = bm.faces.new([vmap[v] for v in f.verts])
            nf.material_index = mats.index(mname)
            nf.smooth = smooth
        part.free()
    PARTS[:] = keep
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    for mname in mats:
        me.materials.append(mat(mname))
    ob = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(ob)
    if as_vertex_groups:
        vgroups = [ob.vertex_groups.new(name=g) for g in names]
        for vi, gi in enumerate(group_of_vert):
            vgroups[gi].add([vi], 1.0, "REPLACE")
    me.set_sharp_from_angle(angle=math.radians(sharp_angle))
    return ob, names


def set_origin(ob, point):
    """Moves the object's origin to `point` (world space) without moving the mesh."""
    point = Vector(point)
    ob.data.transform(Matrix.Translation(-point))
    ob.location = point


def stats(objects):
    verts = sum(len(o.data.vertices) for o in objects if o.type == "MESH")
    tris = sum(len(p.vertices) - 2 for o in objects if o.type == "MESH"
               for p in o.data.polygons)
    return verts, tris


def export_glb(path, skins=False):
    path = os.path.abspath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True,
                              export_apply=False, export_skins=skins, export_animations=False,
                              export_yup=True)
    return path


def render_views(out_dir, views, target=(0, 0, 0), samples=48):
    """views: list of (file name, yaw degrees, pitch degrees, ortho scale, (w, h)).
    Yaw 0 looks at the model's front; pitch looks down."""
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = samples
    scene.cycles.device = "CPU"
    scene.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new("Backdrop")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.92, 0.92, 0.92, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
    scene.world = world
    sun = bpy.data.objects.new("Sun", bpy.data.lights.new("Sun", "SUN"))
    sun.data.energy = 3.5
    sun.data.angle = math.radians(8)
    sun.rotation_euler = (math.radians(50), math.radians(10), math.radians(150))
    scene.collection.objects.link(sun)
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam"))
    cam.data.type = "ORTHO"
    scene.collection.objects.link(cam)
    scene.camera = cam
    os.makedirs(out_dir, exist_ok=True)
    target = Vector(target)
    for name, yaw, pitch, scale, (w, h) in views:
        a, p = math.radians(yaw), math.radians(pitch)
        dist = 20.0
        cam.location = target + Vector((math.sin(a) * math.cos(p), math.cos(a) * math.cos(p),
                                        math.sin(p))) * dist
        cam.rotation_euler = (math.radians(90) - p, 0, math.pi - a)
        cam.data.ortho_scale = scale
        cam.data.clip_end = 100
        scene.render.resolution_x, scene.render.resolution_y = w, h
        scene.render.filepath = os.path.join(out_dir, f"{name}.png")
        bpy.ops.render.render(write_still=True)
