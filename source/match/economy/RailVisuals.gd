extends Node3D

# Draws the track trains have laid (RailNetwork.legs): sleepers and rails in the look
# of the railway road level, only the built part of each leg, so the track visibly grows
# behind a train that is laying it.

const RoadShader = preload("res://source/shaders/3d/road.gdshader")

const WIDTH_M = 1.2
const HEIGHT_M = 0.06
const REFRESH_S = 0.5

var _meshes = {}  # leg key -> [built metres when drawn, MeshInstance3D]
var _material = null
var _since_refresh_s = 0.0

@onready var _logistics = get_parent()


func _ready():
	_material = ShaderMaterial.new()
	_material.shader = RoadShader
	_material.set_shader_parameter("kind", 2)
	_material.render_priority = 0


func _process(delta):
	_since_refresh_s += delta
	if _since_refresh_s < REFRESH_S or not _logistics.rails.changed:
		return
	_since_refresh_s = 0.0
	_logistics.rails.changed = false
	for key in _logistics.rails.legs:
		var leg = _logistics.rails.legs[key]
		var built = leg["built_a"] + leg["built_b"]
		if key in _meshes and is_equal_approx(_meshes[key][0], built):
			continue
		var instance = _meshes[key][1] if key in _meshes else MeshInstance3D.new()
		if not key in _meshes:
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			instance.material_override = _material
			add_child(instance)
		instance.mesh = _mesh_for(leg)
		instance.set_instance_shader_parameter("road_length", max(built, 1.0))
		_meshes[key] = [built, instance]


func _mesh_for(leg):
	var mesh = ArrayMesh.new()
	var length = leg["length"]
	if leg["built_a"] >= length:
		_add_ribbon(mesh, _slice(leg, 0.0, length))
		return mesh
	if leg["built_a"] > 0.05:
		_add_ribbon(mesh, _slice(leg, 0.0, leg["built_a"]))
	if leg["built_b"] > 0.05:
		_add_ribbon(mesh, _slice(leg, length - leg["built_b"], length))
	return mesh


static func _slice(leg, from_m, to_m):
	"""the leg's polyline between two distances from its start"""
	var points = leg["points"]
	var cumulative = leg["cumulative"]
	var sliced = PackedVector3Array()
	for index in range(1, points.size()):
		var a = cumulative[index - 1]
		var b = cumulative[index]
		if b < from_m or a > to_m:
			continue
		var span = max(b - a, 0.0001)
		var start = points[index - 1].lerp(points[index], clamp((from_m - a) / span, 0.0, 1.0))
		var end = points[index - 1].lerp(points[index], clamp((to_m - a) / span, 0.0, 1.0))
		if sliced.is_empty():
			sliced.append(start)
		sliced.append(end)
	return sliced


static func _add_ribbon(mesh, points):
	if points.size() < 2:
		return
	var vertices = PackedVector3Array()
	var uvs = PackedVector2Array()
	var normals = PackedVector3Array()
	var indices = PackedInt32Array()
	var along = 0.0
	for i in range(points.size()):
		var previous = points[max(i - 1, 0)]
		var next = points[min(i + 1, points.size() - 1)]
		var direction = Vector2(next.x - previous.x, next.z - previous.z).normalized()
		var side = direction.orthogonal() * WIDTH_M * 0.5
		if i > 0:
			along += points[i - 1].distance_to(points[i])
		for sign_value in [-1.0, 1.0]:
			vertices.append(
				Vector3(
					points[i].x + side.x * sign_value, HEIGHT_M, points[i].z + side.y * sign_value
				)
			)
			uvs.append(Vector2(along, 0.5 + sign_value * 0.5))
			normals.append(Vector3.UP)
		if i > 0:
			var a = (i - 1) * 2
			indices.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
