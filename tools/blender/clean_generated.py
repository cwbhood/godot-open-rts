"""Makes an AI-generated GLB (Higgsfield: GPT Image 2.5 concept, then Tripo H3.1 image-to-3D)
play-ready for Ironbound.

The concept images paint every team-colour surface flat bright cobalt blue. This script:
  * joins the meshes, turns the model so its front faces Blender +Y (Godot -Z), stands it on
    z = 0 centred on its footprint and scales its longest side to --length metres;
  * moves the faces whose texture is that blue into a "TeamColor" material with the albedo
    the game swaps for the player's colour (Unit.MATERIAL_ALBEDO_TO_REPLACE), and greys the
    blue texels left in the texture so seams do not show blue;
  * keeps only the base colour texture (resized to --tex pixels, JPEG), drops the normal and
    ORM maps (invisible at play zoom) and makes the material matte, as in the Grounded look;
  * decimates down to --max-tris when over;
  * with --rotors, adds spinning "RotorMain" and "RotorTail" blades (see RotorSpin.gd) at the
    rotor hub and the tail, for helicopters generated without blades.

  python3 tools/blender/clean_generated.py -- --in raw.glb --out model.glb --yaw 90 \
      --length 3.2 [--rotors] [--render previews/dir]
"""

import math
import os
import sys

import bpy  # noqa: I001 (bpy must load before bmesh)
import bmesh
import numpy as np
from mathutils import Matrix, Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

TEAM_COLOR_SRGB = (0.99, 0.81, 0.48)


def _args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = {"yaw": 0.0, "length": 0.0, "tex": 1024, "max_tris": 9000, "rotors": False,
            "render": None, "blue": 0.16}
    i = 0
    while i < len(argv):
        key = argv[i].lstrip("-").replace("-", "_")
        if key == "rotors":
            opts["rotors"] = True
            i += 1
            continue
        value = argv[i + 1]
        if key in ("yaw", "length", "blue"):
            value = float(value)
        elif key in ("tex", "max_tris"):
            value = int(value)
        opts[key] = value
        i += 2
    return opts


def _srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _import(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=os.path.abspath(path))
    meshes = [ob for ob in bpy.context.scene.objects if ob.type == "MESH"]
    for ob in bpy.context.scene.objects:
        ob.select_set(ob in meshes)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.parent = None
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for other in list(bpy.context.scene.objects):
        if other != ob:
            bpy.data.objects.remove(other)
    ob.name = "Model"
    return ob


def _place(ob, yaw, length):
    ob.data.transform(Matrix.Rotation(math.radians(yaw), 4, "Z"))
    co = np.empty(len(ob.data.vertices) * 3)
    ob.data.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    lo, hi = co.min(axis=0), co.max(axis=0)
    centre = Vector(((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, lo[2]))
    ob.data.transform(Matrix.Translation(-centre))
    if length > 0:
        side = max(hi[0] - lo[0], hi[1] - lo[1])
        ob.data.transform(Matrix.Scale(length / side, 4))
    ob.data.update()


def _base_image(ob):
    mat = ob.data.materials[0]
    for node in mat.node_tree.nodes:
        if node.type == "BSDF_PRINCIPLED":
            link = node.inputs["Base Color"].links
            if link:
                return link[0].from_node.image
    raise SystemExit("no base colour texture")


def _blue_mask(pixels, threshold):
    """pixels: (h, w, 4) floats in sRGB; True where the texel is the team-colour blue"""
    r, g, b = pixels[..., 0], pixels[..., 1], pixels[..., 2]
    return (b - np.maximum(r, g) > threshold) & (b > 0.3)


def _split_team_colour(ob, image, threshold):
    w, h = image.size
    px = np.empty(w * h * 4, dtype=np.float32)
    image.pixels.foreach_get(px)
    px = px.reshape(h, w, 4)
    mask = _blue_mask(px, threshold)

    mesh = ob.data
    uv = np.empty(len(mesh.loops) * 2)
    mesh.uv_layers.active.data.foreach_get("uv", uv)
    uv = uv.reshape(-1, 2)

    def sample(u, v):
        x = np.clip((u % 1.0) * w, 0, w - 1).astype(int)
        y = np.clip((v % 1.0) * h, 0, h - 1).astype(int)
        return mask[y, x]

    team_faces = []
    for poly in mesh.polygons:
        loops = list(poly.loop_indices)
        pts = uv[loops]
        samples = [pts.mean(axis=0)] + [(p * 2 + pts.mean(axis=0)) / 3 for p in pts]
        votes = sum(bool(sample(s[0], s[1])) for s in samples)
        if votes * 2 > len(samples):
            team_faces.append(poly.index)

    team = bpy.data.materials.new("TeamColor")
    team.use_nodes = True
    bsdf = team.node_tree.nodes["Principled BSDF"]
    lin = [_srgb_to_linear(c) for c in TEAM_COLOR_SRGB]
    bsdf.inputs["Base Color"].default_value = (*lin, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.6
    bsdf.inputs["Metallic"].default_value = 0.0
    team.diffuse_color = (*lin, 1.0)
    mesh.materials.append(team)
    for i in team_faces:
        mesh.polygons[i].material_index = 1

    # grey out the blue texels so the edges of the split faces do not show blue
    lum = (0.3 * px[..., 0] + 0.59 * px[..., 1] + 0.11 * px[..., 2]) * 0.9
    for c in range(3):
        px[..., c] = np.where(mask, lum, px[..., c])
    image.pixels.foreach_set(px.ravel())
    image.update()
    return len(team_faces), len(mesh.polygons)


def _flatten_material(ob, image, tex):
    """base colour only, matte, resized; named "Textured" so GameData does not treat it as
    the vertex-coloured "Body" of the hand-built models"""
    mat = ob.data.materials[0]
    mat.name = "Textured"
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")
    for name in ("Metallic", "Roughness", "Normal"):
        for link in list(bsdf.inputs[name].links):
            links.remove(link)
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = 0.85
    for node in list(nodes):
        if node.type == "TEX_IMAGE" and node.image != image:
            nodes.remove(node)
        elif node.type in ("NORMAL_MAP", "SEPRGB", "SEPARATE_COLOR"):
            nodes.remove(node)
    if max(image.size) > tex:
        image.scale(tex, tex)
    image.file_format = "JPEG"
    image.name = "Color"  # Godot extracts it beside the GLB as <model>_Color.jpg
    for m in ob.data.materials:
        m.use_backface_culling = True


def _decimate(ob, max_tris):
    tris = sum(len(p.vertices) - 2 for p in ob.data.polygons)
    if tris <= max_tris:
        return tris
    mod = ob.modifiers.new("Decimate", "DECIMATE")
    mod.ratio = max_tris / tris
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.modifier_apply(modifier=mod.name)
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def _blade_object(name, length, chord, count, axis, hub, material):
    """`count` thin blades around `axis` ("Z" spins flat like a main rotor, "X" like a tail
    rotor), with the object's origin at the hub"""
    bm = bmesh.new()
    for k in range(count):
        a = 2 * math.pi * k / count
        geom = bmesh.ops.create_cube(bm, size=1.0)["verts"]
        bmesh.ops.scale(bm, verts=geom, vec=(length, chord, chord * 0.12))
        bmesh.ops.translate(bm, verts=geom, vec=(length / 2, 0, 0))
        bmesh.ops.rotate(bm, verts=geom, cent=(0, 0, 0), matrix=Matrix.Rotation(a, 3, "Z"))
    hub_geom = bmesh.ops.create_cone(bm, cap_ends=True, segments=8, radius1=chord * 0.9,
                                     radius2=chord * 0.9, depth=chord * 0.5)["verts"]
    if axis == "X":
        bmesh.ops.rotate(bm, verts=bm.verts, cent=(0, 0, 0),
                         matrix=Matrix.Rotation(math.radians(90), 3, "Y"))
    del hub_geom
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(material)
    ob = bpy.data.objects.new(name, mesh)
    ob.location = hub
    bpy.context.scene.collection.objects.link(ob)
    return ob


def _add_rotors(ob):
    co = np.empty(len(ob.data.vertices) * 3)
    ob.data.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    length = co[:, 1].max() - co[:, 1].min()
    # main hub: the highest vertices in the middle third of the fuselage
    mid = co[np.abs(co[:, 1] - np.median(co[:, 1])) < length / 4]
    top = mid[mid[:, 2] > mid[:, 2].max() - length * 0.03]
    hub = Vector((0.0, float(top[:, 1].mean()), float(mid[:, 2].max()) + length * 0.01))
    # tail: the rear-most vertices; the tail rotor sits on the left side of the fin
    rear = co[co[:, 1] < co[:, 1].min() + length * 0.08]
    tail = Vector((float(rear[:, 0].min()) - length * 0.01, float(rear[:, 1].mean()),
                   float(rear[:, 2].mean())))
    blade = bpy.data.materials.new("Rotor")
    blade.use_nodes = True
    blade.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (
        0.035, 0.035, 0.03, 1.0)
    blade.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.7
    blade.use_backface_culling = False
    main = _blade_object("RotorMain", length * 0.52, length * 0.045, 4, "Z", hub, blade)
    tail_rotor = _blade_object("RotorTail", length * 0.11, length * 0.025, 2, "X", tail, blade)
    for rotor in (main, tail_rotor):
        rotor.parent = ob
    return hub, tail


def _export(path):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(filepath=os.path.abspath(path), export_format="GLB",
                              use_selection=True, export_yup=True, export_animations=False,
                              export_image_format="JPEG", export_jpeg_quality=85)


def _render(out_dir, ob):
    import mesh_kit  # noqa: E402 (only for the preview renders)

    co = np.empty(len(ob.data.vertices) * 3)
    ob.data.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    size = float(max(co.max(axis=0) - co.min(axis=0)))
    height = float(co[:, 2].max())
    for m in ob.data.materials:  # show team colour as blue in the previews
        if m.name.startswith("TeamColor"):
            m.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (
                0.05, 0.12, 0.6, 1.0)
    views = [
        ("three_quarter", 35, 30, size * 1.5, (800, 800)),
        ("side", 90, 0, size * 1.3, (800, 800)),
        ("front", 0, 10, size * 1.3, (800, 800)),
        ("top", 0, 89, size * 1.3, (800, 800)),
    ]
    mesh_kit.render_views(out_dir, views, target=(0, 0, height / 2), samples=24)


def main():
    opts = _args()
    ob = _import(opts["in"])
    _place(ob, opts["yaw"], opts["length"])
    image = _base_image(ob)
    team, faces = _split_team_colour(ob, image, opts["blue"])
    _flatten_material(ob, image, opts["tex"])
    tris = _decimate(ob, opts["max_tris"])
    if opts["rotors"]:
        _add_rotors(ob)
    _export(opts["out"])
    co = np.empty(len(ob.data.vertices) * 3)
    ob.data.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    dims = co.max(axis=0) - co.min(axis=0)
    print("%s: %d tris, %d of %d faces team colour, %.2f x %.2f x %.2f m (x, y, z)"
          % (opts["out"], tris, team, faces, dims[0], dims[1], dims[2]))
    if opts["render"]:
        _render(opts["render"], ob)


main()
