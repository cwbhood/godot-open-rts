extends Node3D

# Draws the supply route between every extractor and the depot its haulers use: a dirt
# track to begin with, then a paved road or a railway once the route is upgraded
# (Logistics.gd, data/roads.json). Routes are refreshed every REFRESH_S so new extractors,
# upgrades and moved depots show up without any extra signals.

const RoadShader = preload("res://source/shaders/3d/road.gdshader")

const REFRESH_S = 1.0
const WIDTHS = [1.0, 1.3, 1.1]  # dirt, paved, rail (m)
const HEIGHTS = [0.035, 0.045, 0.05]  # above the ground, so that better roads cover dirt
const DEPOT_CLEARANCE = 2.6  # route starts outside the depot's footprint
const EXTRACTOR_CLEARANCE = 1.2
const STEP_M = 1.0

var _routes = {}  # extractor instance id -> {key: Array, mesh: MeshInstance3D}
var _materials = []
var _since_refresh = REFRESH_S


func _ready():
	for kind in range(3):
		var material = ShaderMaterial.new()
		material.shader = RoadShader
		material.set_shader_parameter("kind", kind)
		material.render_priority = -3 + kind
		_materials.append(material)


func _process(delta):
	_since_refresh += delta
	if _since_refresh < REFRESH_S:
		return
	_since_refresh = 0.0
	_refresh()


func _refresh():
	var seen = {}
	for player in get_tree().get_nodes_in_group("players"):
		var logistics = player.get_node_or_null("Logistics")
		if logistics == null:
			continue
		_hide_placeholder_roads(logistics)
		for extractor in logistics.get_extractors():
			var depot = logistics.closest_depot(extractor.global_position)
			if depot == null:
				continue
			var id = extractor.get_instance_id()
			seen[id] = true
			var level = clamp(logistics.get_road_level(extractor), 0, WIDTHS.size() - 1)
			var key = [depot.global_position.snapped(Vector3.ONE * 0.5), level]
			if id in _routes and _routes[id].key == key:
				continue
			_set_route(id, key, depot.global_position, extractor.global_position, level)
	for id in _routes.keys():
		if not id in seen:
			_routes[id].mesh.queue_free()
			_routes.erase(id)


func _hide_placeholder_roads(logistics):
	"""Logistics.gd draws a plain strip for upgraded routes; this node replaces it"""
	for child in logistics.get_children():
		if child is MeshInstance3D and String(child.name).begins_with("Road"):
			child.visible = false


func _set_route(id, key, from: Vector3, to: Vector3, level):
	var instance = _routes[id].mesh if id in _routes else MeshInstance3D.new()
	if not id in _routes:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(instance)
	var points = _route_points(Vector2(from.x, from.z), Vector2(to.x, to.z), level, id)
	var length = 0.0
	for i in range(1, points.size()):
		length += points[i - 1].distance_to(points[i])
	instance.mesh = _ribbon(points, WIDTHS[level], HEIGHTS[level])
	instance.material_override = _materials[level]
	instance.set_instance_shader_parameter("road_length", length)
	_routes[id] = {"key": key, "mesh": instance}


func _route_points(from: Vector2, to: Vector2, level, seed_value) -> PackedVector2Array:
	var direction = (to - from).normalized()
	var start = from + direction * DEPOT_CLEARANCE
	var end = to - direction * EXTRACTOR_CLEARANCE
	var length = start.distance_to(end)
	var points = PackedVector2Array()
	if length < 0.5:
		return points
	var side = direction.orthogonal()
	# dirt tracks wander a little; built roads and rails run straight
	var bend = 0.0
	if level == 0:
		var rng = RandomNumberGenerator.new()
		rng.seed = seed_value
		bend = rng.randf_range(-1.0, 1.0) * min(length * 0.08, 2.5)
	var steps = max(1, int(ceil(length / STEP_M)))
	for i in range(steps + 1):
		var t = float(i) / steps
		points.append(start.lerp(end, t) + side * sin(t * PI) * bend)
	return points


func _ribbon(points: PackedVector2Array, width: float, height: float) -> ArrayMesh:
	var vertices = PackedVector3Array()
	var uvs = PackedVector2Array()
	var normals = PackedVector3Array()
	var indices = PackedInt32Array()
	var along = 0.0
	for i in range(points.size()):
		var previous = points[max(i - 1, 0)]
		var next = points[min(i + 1, points.size() - 1)]
		var side = (next - previous).normalized().orthogonal() * width * 0.5
		if i > 0:
			along += points[i - 1].distance_to(points[i])
		for sign_value in [-1.0, 1.0]:
			var p = points[i] + side * sign_value
			vertices.append(Vector3(p.x, height, p.y))
			uvs.append(Vector2(along, 0.5 + sign_value * 0.5))
			normals.append(Vector3.UP)
		if i > 0:
			var a = (i - 1) * 2
			indices.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	var mesh = ArrayMesh.new()
	if points.size() < 2:
		return mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
