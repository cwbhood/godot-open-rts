extends Node3D

# Draws the player's railway (RailNetwork): a gravel bed, wooden sleepers and two steel
# rails along the built part of each leg, so the track visibly grows behind a train that
# is laying it, plus a loading gantry over the track at every stop the track has reached
# and a station platform at each depot.

const GameData = preload("res://source/data-model/GameData.gd")
const LoaderScene = preload("res://assets/models/ironbound/units/train_loader.glb")
const StationScene = preload("res://assets/models/ironbound/units/train_station.glb")

const GAUGE_M = 0.316  # standard gauge at the train models' scale (0.22)
const RAIL_W = 0.045
const RAIL_H = 0.05
const SLEEPER_LEN = 0.62
const SLEEPER_W = 0.12
const SLEEPER_H = 0.035
const SLEEPER_EVERY_M = 0.42
const BED_TOP_W = 0.8
const BED_BOTTOM_W = 1.15
const BED_H = 0.06
const BED_COLOR = Color(0.5, 0.47, 0.43)
const BED_EDGE_COLOR = Color(0.42, 0.39, 0.35)
const SLEEPER_COLOR = Color(0.33, 0.23, 0.16)
const RAIL_COLOR = Color(0.36, 0.35, 0.36)
const RAIL_TOP_COLOR = Color(0.78, 0.78, 0.8)
const REFRESH_S = 0.4
const PROP_CLEARANCE_M = 1.1
const LINE_COLOR = Color(1.0, 0.78, 0.25, 0.85)
const LINE_PLANNED_COLOR = Color(1.0, 0.78, 0.25, 0.35)
const TEAM_ALBEDO = Color(0.99, 0.81, 0.48)  # Unit.MATERIAL_ALBEDO_TO_REPLACE

var _meshes = {}  # leg key -> [built metres when drawn, MeshInstance3D]
var _platforms = {}  # node id -> Node3D
var _material = null
var _line_mesh = null  # the line of the selected trains
var _line_signature = []
var _props = null  # [[MultiMesh, {cell: [instance index]}]] of the map's scattered props
var _since_refresh_s = 0.0

@onready var _logistics = get_parent()


func _ready():
	_material = StandardMaterial3D.new()
	_material.vertex_color_use_as_albedo = true
	_material.roughness = 0.85
	_material.metallic = 0.1


func _process(delta):
	_since_refresh_s += delta
	var rails = _logistics.rails
	if _since_refresh_s < REFRESH_S:
		return
	_update_line_of_selected_trains(rails)
	if not rails.changed:
		return
	_since_refresh_s = 0.0
	rails.changed = false
	for key in _meshes.keys():
		if not key in rails.legs:  # split by a junction or gone
			_meshes[key][1].queue_free()
			_meshes.erase(key)
	var index = 0
	for key in rails.legs:
		index += 1
		var leg = rails.legs[key]
		var built = leg["built_a"] + leg["built_b"]
		if key in _meshes and is_equal_approx(_meshes[key][0], built):
			continue
		if built <= 0.05 and not key in _meshes:
			continue
		var instance = _meshes[key][1] if key in _meshes else MeshInstance3D.new()
		if not key in _meshes:
			instance.material_override = _material
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			instance.position.y = 0.0015 * (index % 4)  # no flicker where two legs meet
			add_child(instance)
		instance.mesh = mesh_for(leg)
		_meshes[key] = [built, instance]
		_clear_props_along(leg)
	_update_platforms(rails)


func _update_platforms(rails):
	for id in rails.get_stop_node_ids():
		if id in _platforms or not id in rails.nodes or not rails.is_node_reached(id):
			continue
		var node = rails.nodes[id]
		var model = (StationScene if node.get("depot", false) else LoaderScene).instantiate()
		GameData.use_vertex_colours(model)
		add_child(model)
		var along = rails.tangent_at_node(id)
		var x = Vector3.UP.cross(-along).normalized()  # the side the platform stands on
		if (
			not node.get("depot", false)
			and node.has("source")
			and (node["source"] - node["position"]).dot(x) < 0.0
		):
			x = -x  # the gantry's conveyor reaches back to its extractor or storage
		model.global_transform = Transform3D(
			Basis(x, Vector3.UP, x.cross(Vector3.UP)).orthonormalized(), node["position"]
		)
		_recolour(model)
		_platforms[id] = model


func _update_line_of_selected_trains(rails):
	"""a selected train shows its whole line on the ground: the track it runs (planned
	track paler) and a marker over every stop"""
	var trains = []
	for unit in get_tree().get_nodes_in_group("selected_units"):
		if unit.get("is_train") == true and unit.player == _logistics.get_parent():
			trains.append(unit)
	var signature = []
	for train in trains:
		signature.append(
			[
				train.get_instance_id(),
				train.stops.size(),
				rails.legs.size(),
				int(rails.get_length_m())
			]
		)
	if signature == _line_signature:
		return
	_line_signature = signature
	if _line_mesh == null:
		_line_mesh = MeshInstance3D.new()
		_line_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.vertex_color_use_as_albedo = true
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.no_depth_test = true
		material.render_priority = 2
		_line_mesh.material_override = material
		add_child(_line_mesh)
	if trains.is_empty():
		_line_mesh.visible = false
		return
	var surface = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var drawn = {}
	for train in trains:
		if not train.has_line():
			continue
		var route = [train.depot] + train.stops
		for index in range(route.size()):
			var a = rails.stop_node_of(route[index])
			var b = rails.stop_node_of(route[(index + 1) % route.size()])
			if a != null:
				_add_marker(surface, rails.nodes[a]["position"])
			if a == null or b == null:
				continue
			for piece in rails.path_between(a, b):
				var leg = piece[0]
				if leg["key"] in drawn:
					continue
				drawn[leg["key"]] = true
				var built = min(leg["built_a"] + leg["built_b"], leg["length"])
				var colour = LINE_COLOR if built >= leg["length"] - 0.05 else LINE_PLANNED_COLOR
				_add_strip(
					surface, _frames(leg["points"]), [[0.13, 0.2, colour], [-0.13, 0.2, colour]]
				)
	_line_mesh.mesh = surface.commit()
	_line_mesh.visible = true


static func _add_marker(surface, at):
	"""a diamond over a stop"""
	var colour = LINE_COLOR
	var size = 0.55
	var points = []
	for step in range(4):
		points.append(at + Vector3(size, 0.22, 0).rotated(Vector3.UP, step * PI / 2.0))
	_quad(
		surface, [points[0], colour], [points[3], colour], [points[2], colour], [points[1], colour]
	)


func _clear_props_along(leg):
	"""trees, bushes and grass the map scattered where the track now runs are cut down"""
	if _props == null:
		_index_props()
	var length = leg["length"]
	var ranges = [[0.0, min(leg["built_a"], length)], [length - leg["built_b"], length]]
	for index in range(leg["points"].size()):
		var t = leg["cumulative"][index]
		if not ranges.any(func(span): return t >= span[0] - 1.0 and t <= span[1] + 1.0):
			continue
		var point = leg["points"][index]
		var cell = _cell_of(point)
		for entry in _props:
			for dx in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					var key = cell + Vector2i(dx, dz)
					if not key in entry[1]:
						continue
					for i in entry[1][key]:
						var transform = entry[0].get_instance_transform(i)
						var flat = Vector3(transform.origin.x, 0.0, transform.origin.z)
						if flat.distance_to(point) < PROP_CLEARANCE_M:
							entry[0].set_instance_transform(
								i, Transform3D(Basis().scaled(Vector3.ZERO), transform.origin)
							)


func _index_props():
	_props = []
	var match_node = find_parent("Match")
	var scatter = match_node.find_child("Scatter", true, false) if match_node != null else null
	if scatter == null:
		return
	for child in scatter.get_children():
		if not child is MultiMeshInstance3D or child.multimesh == null:
			continue
		var cells = {}
		for i in range(child.multimesh.instance_count):
			var cell = _cell_of(child.multimesh.get_instance_transform(i).origin)
			if not cell in cells:
				cells[cell] = []
			cells[cell].append(i)
		_props.append([child.multimesh, cells])


static func _cell_of(point):
	return Vector2i(floori(point.x / 2.0), floori(point.z / 2.0))


func _recolour(model):
	var player = _logistics.get_parent()
	if player == null or not player.has_method("get_color_material"):
		return
	Utils.Match.traverse_node_tree_and_replace_materials_matching_albedo(
		model, TEAM_ALBEDO, 0.05, player.get_color_material()
	)


static func mesh_for(leg):
	var surface = SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var length = leg["length"]
	var ranges = []
	if leg["built_a"] >= length:
		ranges.append([0.0, length])
	else:
		if leg["built_a"] > 0.05:
			ranges.append([0.0, leg["built_a"]])
		if leg["built_b"] > 0.05:
			ranges.append([length - leg["built_b"], length])
	for span in ranges:
		var points = _slice(leg, span[0], span[1])
		if points.size() < 2:
			continue
		_add_bed(surface, points)
		_add_sleepers(surface, leg, span[0], span[1])
		for side in [-1.0, 1.0]:
			_add_rail(surface, points, side * GAUGE_M * 0.5)
	surface.generate_normals()
	return surface.commit()


static func _frames(points):
	"""[point, side vector] along a polyline"""
	var frames = []
	for i in range(points.size()):
		var previous = points[max(i - 1, 0)]
		var next = points[min(i + 1, points.size() - 1)]
		var direction = Vector3(next.x - previous.x, 0.0, next.z - previous.z).normalized()
		frames.append([points[i], Vector3(-direction.z, 0.0, direction.x)])
	return frames


static func _add_strip(surface, frames, profile):
	"""extrudes a cross-section [[offset, height, colour], ...] (left to right) along the
	frames"""
	for i in range(1, frames.size()):
		for k in range(1, profile.size()):
			var corners = []
			for frame in [frames[i - 1], frames[i]]:
				for p in [profile[k - 1], profile[k]]:
					corners.append([frame[0] + frame[1] * p[0] + Vector3.UP * p[1], p[2]])
			_quad(surface, corners[0], corners[1], corners[3], corners[2])


static func _quad(surface, a, b, c, d):
	for corner in [a, b, c, a, c, d]:
		surface.set_color(corner[1])
		surface.add_vertex(corner[0])


static func _add_bed(surface, points):
	var top = BED_TOP_W * 0.5
	var bottom = BED_BOTTOM_W * 0.5
	_add_strip(
		surface,
		_frames(points),
		[
			[bottom, 0.002, BED_EDGE_COLOR],
			[top, BED_H, BED_COLOR],
			[-top, BED_H, BED_COLOR],
			[-bottom, 0.002, BED_EDGE_COLOR],
		]
	)


static func _add_rail(surface, points, offset):
	var base = BED_H + SLEEPER_H
	var half = RAIL_W * 0.5
	_add_strip(
		surface,
		_frames(points).map(func(frame): return [frame[0] + frame[1] * offset, frame[1]]),
		[
			[half, base, RAIL_COLOR],
			[half, base + RAIL_H, RAIL_COLOR],
			[half * 0.6, base + RAIL_H + 0.004, RAIL_TOP_COLOR],
			[-half * 0.6, base + RAIL_H + 0.004, RAIL_TOP_COLOR],
			[-half, base + RAIL_H, RAIL_COLOR],
			[-half, base, RAIL_COLOR],
		]
	)


static func _add_sleepers(surface, leg, from_m, to_m):
	var t = ceil(from_m / SLEEPER_EVERY_M) * SLEEPER_EVERY_M
	while t <= to_m:
		var around = _slice(leg, max(t - 0.1, 0.0), min(t + 0.1, leg["length"]))
		if around.size() >= 2:
			var along = (around[around.size() - 1] - around[0]).normalized()
			var side = Vector3(-along.z, 0.0, along.x)
			var centre = _point_at(leg, t) + Vector3.UP * BED_H
			_box(surface, centre, side * SLEEPER_LEN * 0.5, along * SLEEPER_W * 0.5, SLEEPER_H)
		t += SLEEPER_EVERY_M


static func _box(surface, centre, half_side, half_along, height):
	var up = Vector3.UP * height
	var c = SLEEPER_COLOR
	var dark = SLEEPER_COLOR.darkened(0.25)
	var p = [
		centre - half_side - half_along,
		centre + half_side - half_along,
		centre + half_side + half_along,
		centre - half_side + half_along,
	]
	_quad(surface, [p[0] + up, c], [p[3] + up, c], [p[2] + up, c], [p[1] + up, c])
	for i in range(4):
		var a = p[i]
		var b = p[(i + 1) % 4]
		_quad(surface, [a, dark], [b, dark], [b + up, dark], [a + up, dark])


static func _point_at(leg, t):
	var points = leg["points"]
	var cumulative = leg["cumulative"]
	for index in range(1, points.size()):
		if cumulative[index] >= t:
			var span = cumulative[index] - cumulative[index - 1]
			var weight = (t - cumulative[index - 1]) / span if span > 0.0 else 1.0
			return points[index - 1].lerp(points[index], weight)
	return points[points.size() - 1]


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
