"""Small modelling kit shared by the single-model build scripts (build_soldier.py,
build_raider.py). Primitives are bmeshes baked straight into world space and tagged with a
material and a group; `merge` turns a set of groups into one mesh object, with the groups
either as vertex groups (for skinning) or kept as separate objects.

Needs the pip `bpy` module (or `blender -b -P`). Blender's axes: Z up, models face +Y.

Game mode (the default; pass `--detail full` for the original showcase meshes) makes the
models play-ready, because at play zoom a unit is 40 to 80 pixels long and fine detail turns
to noise while costing frame time:
  * fewer segments on round primitives, no bevels on small boxes, parts smaller than
    GAME["drop_size"] dropped and thin tubes thickened to GAME["min_radius"];
  * brighter, more saturated colours (GAME["brighten"], GAME["saturate"]);
  * every non-emissive material folded into one "Body" material whose colours live in the
    COLOR_0 vertex colours (Godot multiplies the albedo by them), with ambient occlusion
    baked in, so a part costs one draw call (two with team colour);
  * "TeamColor" exported with albedo (0.99, 0.81, 0.48) sRGB, the colour the game swaps for
    the player's colour (Unit.MATERIAL_ALBEDO_TO_REPLACE);
  * a final decimate down to GAME["max_tris"] when the mesh is still over budget.
Scripts adjust GAME before building (for example a higher drop size for big vehicles).
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

# the albedo the game recolours per player (Unit.MATERIAL_ALBEDO_TO_REPLACE), sRGB
GAME_TEAM_COLOR_SRGB = (0.99, 0.81, 0.48)

GAME = {
    "enabled": "--detail" not in sys.argv or "full" not in sys.argv,
    "segments": 0.45,      # multiplier on round primitives' segment counts
    "min_segments": 6,
    "drop_size": 0.07,     # parts whose largest side is under this (model metres) are dropped
    "min_radius": 0.03,    # thinner tubes and pipes are thickened to this
    "bevel_min": 0.14,     # boxes whose smallest side is under this get no bevel
    "brighten": 1.2,       # HSV value multiplier (plus a small lift)
    "saturate": 1.05,
    "max_tris": 4500,      # whole model, decimated down to this when over
    "ao_rays": 24,
    "ao_min": 0.45,
}


def _seg(n, lo=None):
    if not GAME["enabled"]:
        return n
    lo = GAME["min_segments"] if lo is None else lo
    return max(min(lo, n), int(round(n * GAME["segments"])))


def _radius(r):
    return max(r, GAME["min_radius"]) if GAME["enabled"] else r


def game_srgb(name):
    """The colour a material gets in game mode (brighter, team colour fixed)."""
    import colorsys
    if name == "TeamColor":
        return GAME_TEAM_COLOR_SRGB
    srgb = PALETTE[name][0]
    if not GAME["enabled"]:
        return srgb
    h, s, v = colorsys.rgb_to_hsv(*srgb)
    v = min(1.0, v * GAME["brighten"] + 0.04)
    s = min(1.0, s * GAME["saturate"])
    return colorsys.hsv_to_rgb(h, s, v)


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


def _game_slot(name):
    """Material a palette entry folds into in game mode."""
    if name == "TeamColor":
        return "TeamColor"
    if len(PALETTE[name]) > 3:
        return name  # emissive parts keep their own material
    return "Body"


def mat(name):
    m = bpy.data.materials.get(name)
    if m is not None:
        return m
    if GAME["enabled"] and name == "Body":
        m = bpy.data.materials.new("Body")
        m.use_nodes = True
        bsdf = m.node_tree.nodes.get("Principled BSDF")
        bsdf.inputs["Base Color"].default_value = (1.0, 1.0, 1.0, 1.0)
        bsdf.inputs["Roughness"].default_value = 0.75
        bsdf.inputs["Metallic"].default_value = 0.0
        attr = m.node_tree.nodes.new("ShaderNodeVertexColor")
        attr.layer_name = "Col"
        m.node_tree.links.new(attr.outputs["Color"], bsdf.inputs["Base Color"])
        return m
    entry = PALETTE[name]
    srgb, rough, metal = entry[:3]
    if GAME["enabled"]:
        srgb = game_srgb(name)
        if name == "TeamColor":
            rough, metal = 0.6, 0.0
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
    if GAME["enabled"] and bm.verts:
        lo = Vector((min(v.co[i] for v in bm.verts) for i in range(3)))
        hi = Vector((max(v.co[i] for v in bm.verts) for i in range(3)))
        if max(hi - lo) < GAME["drop_size"]:
            bm.free()
            return None
    PARTS.append((bm, m, group, smooth))
    return bm


def ellipsoid(c, r, m, group, seg=14, rings=9, rot=IDENTITY, cut=None):
    """r = (rx, ry, rz). cut: keep only the part with local z >= cut (a dome), capped."""
    bm = bmesh.new()
    seg, rings = _seg(seg), _seg(rings, 4)
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
    if GAME["enabled"]:
        n = _seg(n)
        rings = 1 if bulge == 0.0 else min(rings, 2)
        r0, r1 = _radius(r0), _radius(r1)
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
    r = _radius(r)
    if closed:
        pts = pts + [pts[0]]
    for a, b in zip(pts, pts[1:]):
        tube(a, b, r, r, m, group, n=n, rings=1)
    if GAME["enabled"]:
        return  # the joints are invisible at play zoom
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
    if GAME["enabled"]:
        segments = 1
        if min(size) < GAME["bevel_min"]:
            bevel = 0
    if bevel > 0:
        bmesh.ops.bevel(bm, geom=bm.edges[:], offset=min(size) * bevel, segments=segments,
                        affect="EDGES", profile=0.5)
    return add(bm, m, group, smooth, Matrix.Translation(Vector(c)) @ rot)


def torus(c, R, r, m, group, rot=IDENTITY, n=20, k=6, scale=(1, 1, 1), arc=(0.0, 360.0)):
    """Ring in the local XY plane; `arc` limits it to a range of degrees (open ends capped)."""
    bm = bmesh.new()
    if GAME["enabled"]:
        n, k, r = _seg(n, 8), _seg(k, 4), _radius(r)
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
        bmesh.ops.bevel(bm, geom=bm.edges[:], offset=bevel, segments=1 if GAME["enabled"] else 2,
                        affect="EDGES",
                        profile=0.5, clamp_overlap=True)
    return add(bm, m, group, smooth)


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def merge(name, groups=None, as_vertex_groups=False, sharp_angle=40.0):
    """Joins the parts of the given groups (all when None) into one object. Returns
    (object, vertex group names). In game mode the palette colours go to the "Col" corner
    colours and the materials fold into Body / TeamColor / emissive ones."""
    bm = bmesh.new()
    mats, names, group_of_vert = [], [], []
    face_colours = []
    keep = []
    for part, mname, group, smooth in PARTS:
        if groups is not None and group not in groups:
            keep.append((part, mname, group, smooth))
            continue
        slot = _game_slot(mname) if GAME["enabled"] else mname
        if slot not in mats:
            mats.append(slot)
        if group not in names:
            names.append(group)
        colour = (1.0, 1.0, 1.0) if slot != "Body" else \
            tuple(srgb_to_linear(c) for c in game_srgb(mname))
        vmap = {}
        for v in part.verts:
            vmap[v] = bm.verts.new(v.co)
            group_of_vert.append(names.index(group))
        for f in part.faces:
            nf = bm.faces.new([vmap[v] for v in f.verts])
            nf.material_index = mats.index(slot)
            nf.smooth = smooth
            face_colours.append(colour)
        part.free()
    PARTS[:] = keep
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    me.validate()
    for mname in mats:
        me.materials.append(mat(mname))
    if GAME["enabled"]:
        attr = me.color_attributes.new("Col", "FLOAT_COLOR", "CORNER")
        for poly in me.polygons:
            c = face_colours[poly.index]
            for li in poly.loop_indices:
                attr.data[li].color = (*c, 1.0)
        me.color_attributes.active_color = attr
        me.color_attributes.render_color_index = 0
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


def _mesh_objects():
    return [o for o in bpy.context.scene.objects if o.type == "MESH"]


def _decimate_to(objects, max_tris):
    _, tris = stats(objects)
    print(f"game mode: {tris} tris before decimation (budget {max_tris})")
    if tris <= max_tris:
        return
    ratio = max_tris / tris
    bpy.context.view_layer.update()
    for ob in objects:
        mod = ob.modifiers.new("Decimate", "DECIMATE")
        mod.decimate_type = "COLLAPSE"
        mod.ratio = ratio
        mod.use_collapse_triangulate = True
    dg = bpy.context.evaluated_depsgraph_get()
    for ob in objects:
        me = bpy.data.meshes.new_from_object(ob.evaluated_get(dg))
        old = ob.data
        ob.modifiers.clear()
        ob.data = me
        name = old.name
        bpy.data.meshes.remove(old)
        me.name = name
        me.validate()


def _hemisphere(count):
    dirs = []
    golden = math.pi * (3.0 - math.sqrt(5.0))
    for i in range(count):
        u = (i + 0.5) / count
        r = math.sqrt(u)
        dirs.append(Vector((r * math.cos(golden * i), r * math.sin(golden * i),
                            math.sqrt(max(0.0, 1 - u)))))
    return dirs


def bake_ao(objects):
    """Multiplies the "Col" corner colours by ambient occlusion from all the parts plus the
    ground under the model, so crevices and undersides darken at play zoom."""
    from mathutils.bvhtree import BVHTree
    bpy.context.view_layer.update()
    verts, polys = [], []
    lo = Vector((1e9, 1e9, 1e9))
    hi = -lo
    for ob in objects:
        mw = ob.matrix_world
        base = len(verts)
        for v in ob.data.vertices:
            w = mw @ v.co
            verts.append(w)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
        polys += [[base + i for i in p.vertices] for p in ob.data.polygons]
    size = max(hi - lo)
    ground = lo.z - 0.001 * size
    g = size * 4
    base = len(verts)
    verts += [Vector((-g, -g, ground)), Vector((g, -g, ground)), Vector((g, g, ground)),
              Vector((-g, g, ground))]
    polys.append([base, base + 1, base + 2, base + 3])
    bvh = BVHTree.FromPolygons(verts, polys)
    dirs = _hemisphere(GAME["ao_rays"])
    maxd = size * 0.18
    for ob in objects:
        me = ob.data
        attr = me.color_attributes.get("Col")
        if attr is None:
            continue
        mw = ob.matrix_world
        nm = mw.to_3x3().inverted().transposed()
        cache = {}
        for poly in me.polygons:
            n = (nm @ poly.normal).normalized()
            t = n.orthogonal().normalized()
            b = n.cross(t)
            centre = mw @ poly.center
            for li in poly.loop_indices:
                vi = me.loops[li].vertex_index
                key = (vi, round(n.x, 2), round(n.y, 2), round(n.z, 2))
                ao = cache.get(key)
                if ao is None:
                    p = mw @ me.vertices[vi].co
                    p = p + (centre - p) * 0.05 + n * size * 0.002
                    occ = 0.0
                    for d in dirs:
                        hit = bvh.ray_cast(p, t * d.x + b * d.y + n * d.z, maxd)
                        if hit[0] is not None:
                            occ += 1.0 - (hit[3] / maxd) ** 1.5
                    ao = GAME["ao_min"] + (1.0 - GAME["ao_min"]) * (1.0 - occ / len(dirs))
                    cache[key] = ao
                c = attr.data[li].color
                attr.data[li].color = (c[0] * ao, c[1] * ao, c[2] * ao, 1.0)


def export_glb(path, skins=False):
    path = os.path.abspath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if GAME["enabled"]:
        objects = _mesh_objects()
        _decimate_to(objects, GAME["max_tris"])
        bake_ao(objects)
        skins = False
        for ob in list(bpy.context.scene.objects):
            if ob.type == "ARMATURE":  # rigid parts, the game does not animate them
                for child in ob.children:
                    mw = child.matrix_world.copy()
                    child.parent = None
                    child.matrix_world = mw
                    child.modifiers.clear()
                bpy.data.objects.remove(ob)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True,
                              export_apply=False, export_skins=skins, export_animations=False,
                              export_yup=True,
                              export_vertex_color="ACTIVE" if GAME["enabled"] else "MATERIAL")
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
