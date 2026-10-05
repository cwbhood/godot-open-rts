extends Node3D

# Draws the supply route between every extractor and the depot its haulers use: a dirt
# track to begin with, then a paved road or a railway once the route is upgraded
# (Logistics.gd, data/roads.json). Routes are refreshed every REFRESH_S so new extractors,
# upgrades and moved depots show up without any extra signals.
#
# A route follows the path trucks actually drive (the land navigation map), so it goes
# around lakes and seas; where trucks ford shallow water the road crosses on a raised
# stone causeway, and an extractor with no land route to any depot gets no road at all.

const RoadShader = preload("res://source/shaders/3d/road.gdshader")
const WaterRules = preload("res://source/match/WaterRules.gd")

const REFRESH_S = 1.0
const WIDTHS = [1.0, 1.3, 1.1]  # dirt, paved, rail (m)
const HEIGHTS = [0.035, 0.045, 0.05]  # above the ground, so that better roads cover dirt
const DEPOT_CLEARANCE = 2.6  # route starts outside the depot's footprint
const EXTRACTOR_CLEARANCE = 1.2
const STEP_M = 1.0
const REDRAW_S = 30.0
const ROUTE_REACH_M = 6.0  # the truck route must end this close to the extractor
const WET_BED_Y = -0.12  # ground this far down is under water: the road becomes a causeway
const CAUSEWAY_TOP_Y = 0.12  # deck height, well above the water surface (-0.3)
const CAUSEWAY_FOOT_Y = -0.7  # below the shallow bed (-0.6)
const CAUSEWAY_SLOPE_M = 0.6
const CAUSEWAY_EXTRA_WIDTH_M = 0.4

var _routes = {}  # extractor instance id -> {key: Array, node: Node3D, retry_at: float}
var _materials = []
var _deck_materials = []  # the same looks drawn after the water surface, for causeways
var _causeway_material = StandardMaterial3D.new()
var _since_refresh = REFRESH_S


func _ready():
	for kind in range(3):
		var material = ShaderMaterial.new()
		material.shader = RoadShader
		material.set_shader_parameter("kind", kind)
		material.render_priority = -3 + kind
		_materials.append(material)
		var deck = material.duplicate()
		deck.render_priority = 1 + kind  # transparent: drawn after the water, or it hides them
		_deck_materials.append(deck)
	_causeway_material.albedo_color = Color(0.52, 0.47, 0.4)
	_causeway_material.roughness = 0.95


func _process(delta):
	_since_refresh += delta
	if _since_refresh < REFRESH_S:
		return
	_since_refresh = 0.0
	_refresh()


func _refresh():
	var seen = {}
	var now_s = Time.get_ticks_msec() / 1000.0
	for player in get_tree().get_nodes_in_group("players"):
		var logistics = player.get_node_or_null("Logistics")
		if logistics == null:
			continue
		_hide_placeholder_roads(logistics)
		for extractor in logistics.get_extractors():
			var depot = logistics.closest_depot(extractor.global_position)
			if depot == null:
				continue  # no land route to any depot: no road either
			var id = extractor.get_instance_id()
			seen[id] = true
			var level = clamp(logistics.get_road_level(extractor), 0, WIDTHS.size() - 1)
			var key = [depot.global_position.snapped(Vector3.ONE * 0.5), level]
			if id in _routes and _routes[id].key == key and _routes[id].retry_at > now_s:
				continue
			_set_route(id, key, depot.global_position, extractor.global_position, level, now_s)
	for id in _routes.keys():
		if not id in seen:
			_remove_route(id)


func _hide_placeholder_roads(logistics):
	"""Logistics.gd draws a plain strip for upgraded routes; this node replaces it"""
	for child in logistics.get_children():
		if child is MeshInstance3D and String(child.name).begins_with("Road"):
			child.visible = false


func get_route_runs(extractor):
	"""[{points, wet}] of the road drawn to an extractor, empty when it has none"""
	var route = _routes.get(extractor.get_instance_id())
	return route.get("runs", []) if route != null else []


func _remove_route(id):
	if id in _routes:
		if is_instance_valid(_routes[id].node):
			_routes[id].node.queue_free()
		_routes.erase(id)


func _set_route(id, key, from: Vector3, to: Vector3, level, now_s):
	var path = WaterRules.land_route(get_tree(), from, to, ROUTE_REACH_M)
	if path == null:
		return  # navigation not ready yet, next refresh tries again
	_remove_route(id)
	var node = Node3D.new()
	add_child(node)
	# routes are redrawn now and then, as new buildings change the way trucks drive; one
	# that is not found (deep water in the way) is looked for again sooner
	_routes[id] = {
		"key": key, "node": node, "retry_at": now_s + (REDRAW_S if not path.is_empty() else 8.0)
	}
	var points = _route_points(path)
	if points.size() < 2:
		return
	var length = 0.0
	for i in range(1, points.size()):
		length += points[i - 1].distance_to(points[i])
	var along = 0.0
	var runs = _split_by_water(points)
	_routes[id]["runs"] = runs  # for tests
	for run in runs:
		var surface = MeshInstance3D.new()
		surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var height = CAUSEWAY_TOP_Y if run.wet else HEIGHTS[level]
		var width = WIDTHS[level] + (CAUSEWAY_EXTRA_WIDTH_M if run.wet else 0.0)
		surface.mesh = _ribbon(run.points, width, height, along)
		surface.material_override = _deck_materials[level] if run.wet else _materials[level]
		surface.set_instance_shader_parameter("road_length", length)
		node.add_child(surface)
		if run.wet:
			var embankment = MeshInstance3D.new()
			embankment.mesh = _causeway_sides(run.points, width + 0.5, CAUSEWAY_TOP_Y)
			embankment.material_override = _causeway_material
			node.add_child(embankment)
		for i in range(1, run.points.size()):
			along += run.points[i - 1].distance_to(run.points[i])


func _route_points(path: PackedVector3Array) -> PackedVector2Array:
	"""the truck route on the ground, trimmed clear of both buildings, smoothed and cut in
	steps of about STEP_M"""
	var raw = PackedVector2Array()
	for point in path:
		var flat = Vector2(point.x, point.z)
		if raw.is_empty() or raw[raw.size() - 1].distance_to(flat) > 0.05:
			raw.append(flat)
	raw = _trim(raw, DEPOT_CLEARANCE)
	raw.reverse()
	raw = _trim(raw, EXTRACTOR_CLEARANCE)
	raw.reverse()
	if raw.size() < 2:
		return PackedVector2Array()
	for i in range(2):
		raw = _chaikin(raw)
	var points = PackedVector2Array([raw[0]])
	for i in range(1, raw.size()):
		var segment = raw[i] - raw[i - 1]
		var steps = max(1, int(ceil(segment.length() / STEP_M)))
		for step in range(1, steps + 1):
			points.append(raw[i - 1] + segment * float(step) / steps)
	return points


static func _trim(points: PackedVector2Array, distance: float) -> PackedVector2Array:
	"""drops the first 'distance' metres of a polyline"""
	var left = distance
	for i in range(1, points.size()):
		var segment = points[i - 1].distance_to(points[i])
		if segment >= left:
			var out = PackedVector2Array([points[i - 1].lerp(points[i], left / segment)])
			out.append_array(points.slice(i))
			return out
		left -= segment
	return PackedVector2Array()


static func _chaikin(points: PackedVector2Array) -> PackedVector2Array:
	"""rounds the corners of the navigation path, keeping both ends"""
	if points.size() < 3:
		return points
	var out = PackedVector2Array([points[0]])
	for i in range(points.size() - 1):
		var a = points[i]
		var b = points[i + 1]
		if i > 0:
			out.append(a.lerp(b, 0.25))
		if i < points.size() - 2:
			out.append(a.lerp(b, 0.75))
	out.append(points[points.size() - 1])
	return out


func _split_by_water(points: PackedVector2Array) -> Array:
	"""runs of [{points, wet}]: on land the road lies on the ground, where trucks ford
	shallow water it becomes a raised causeway; neighbouring runs share their end point"""
	var match_node = get_tree().get_first_node_in_group("match")
	var map = match_node.map if match_node != null else null
	var water = (
		map.water if map != null and map.has_method("has_water") and map.has_water() else null
	)
	var runs = []
	for point in points:
		var wet = (
			water != null and (water.depth_fast(point) != 0 or water.bed_height(point) < WET_BED_Y)
		)
		if runs.is_empty() or runs.back().wet != wet:
			var run = {"points": PackedVector2Array(), "wet": wet}
			if not runs.is_empty():
				run.points.append(runs.back().points[runs.back().points.size() - 1])
			runs.append(run)
		runs.back().points.append(point)
	return runs.filter(func(run): return run.points.size() >= 2)


func _causeway_sides(points: PackedVector2Array, width: float, top: float) -> ArrayMesh:
	"""the stone body of a causeway: a flat deck under the road surface and banks sloping
	from its edges down into the river bed"""
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var indices = PackedInt32Array()
	for i in range(points.size()):
		var previous = points[max(i - 1, 0)]
		var next = points[min(i + 1, points.size() - 1)]
		var side = (next - previous).normalized().orthogonal()
		# left foot, left edge, right edge, right foot
		for corner in [[-1.0, true], [-1.0, false], [1.0, false], [1.0, true]]:
			var sign_value = corner[0]
			var foot = corner[1]
			var reach = width * 0.5 + (CAUSEWAY_SLOPE_M if foot else 0.0)
			var p = points[i] + side * reach * sign_value
			vertices.append(Vector3(p.x, CAUSEWAY_FOOT_Y if foot else top - 0.01, p.y))
			var outward = Vector3(side.x * sign_value, 0.0, side.y * sign_value)
			normals.append((outward + Vector3.UP * 1.2).normalized())
		if i > 0:
			for corner in range(3):
				var a = (i - 1) * 4 + corner
				var b = i * 4 + corner
				indices.append_array([a, a + 1, b, a + 1, b + 1, b])
	var mesh = ArrayMesh.new()
	if points.size() < 2:
		return mesh
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _ribbon(points: PackedVector2Array, width: float, height: float, along = 0.0) -> ArrayMesh:
	var vertices = PackedVector3Array()
	var uvs = PackedVector2Array()
	var normals = PackedVector3Array()
	var indices = PackedInt32Array()
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
