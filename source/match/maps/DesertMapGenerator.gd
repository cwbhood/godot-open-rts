@tool
extends "res://source/match/Map.gd"

# Builds a desert map procedurally from a seed: flat playable sand at y=0, lakes sunk below
# the navmesh baking volume (so they are impassable), wooded areas and rock outcrops that act
# as obstacles, dunes and sandstone mesas beyond the playable area, and resource deposit
# markers (see Map.get_resource_deposits()). Everything is point-symmetric around the map
# center so that opposite spawns get equivalent surroundings.
#
# A map is described by a JSON definition (see data/maps/desert_expanse.json and
# docs/making-maps.md): generator settings, and optionally an explicit "layout" listing every
# spawn, lake, forest, rock outcrop and deposit (the in-game map editor writes those). With no
# layout, features are placed from the seed.

enum ResourceLayout { SYMMETRIC, ASYMMETRIC }
enum Symmetry { POINT, ROTATIONAL }

const TerrainMaterial = preload(
	"res://source/match/resources/materials/desert_terrain.material.tres"
)
const WaterMaterial = preload("res://source/match/resources/materials/water.material.tres")
const Scatter = preload("res://source/match/maps/DesertScatter.gd")

const WATER_LEVEL = -0.3
const LAKE_DEPTH = 1.6
const LAKE_SHORE_RATIO = 1.35
const SPAWN_CLEARANCE = 15.0
const DEPOSIT_CLEARANCE = 3.5
const LAKE_OUTLINE_POINTS = 24
const LAKE_WATER_LINE_RATIO = 1.2  # lake bed reaches the water level at about this ratio
const INNER_MARGIN = 6.0
const FOREST_KINDS = [&"acacia", &"pine", &"mixed"]
const RESOURCE_LAYOUTS = {
	"symmetric": ResourceLayout.SYMMETRIC, "asymmetric": ResourceLayout.ASYMMETRIC
}
const SYMMETRIES = {"point": Symmetry.POINT, "rotational": Symmetry.ROTATIONAL}

## JSON map definition; its settings override the exports below
@export_file("*.json") var map_definition = "":
	set(value):
		map_definition = value
		# a scene that instances a desert map and points it at another definition
		if _generated and not Engine.is_editor_hint():
			load_definition()
			generate()
@export var map_seed = 7
@export var outer_margin = 110.0
@export var resource_layout = ResourceLayout.SYMMETRIC
@export_range(0, 4) var extra_lake_pairs = 2
@export_range(0, 6) var forest_pairs = 3
@export_range(0, 8) var outcrop_pairs = 4
## start zones the map is made for; 4 on a square map gives 4-fold rotational symmetry
@export_range(2, 8) var players = 4
## POINT mirrors everything through the center; ROTATIONAL turns it 4 ways (square maps)
@export var symmetry = Symmetry.ROTATIONAL
## start zones sit this far in from the corners, as a fraction of the map size
@export var spawn_inset = 0.16
@export var center_lake = true
## commodities placed next to every start zone
@export var home_deposits = ["iron", "oil"]
## commodities placed anywhere in the open (each one copied for every start zone)
@export var contested_deposits = ["oil", "oil", "copper", "copper", "iron", "iron"]
@export var contested_richness = 1.5
## commodities placed near the middle, the richest deposits on the map
@export var middle_deposits = []
@export var middle_richness = 2.5
## how far from the center the middle deposits may be, as a fraction of half the map size
@export var middle_reach = 0.35
## spawns the harvestable deposit units (data/resources.json "deposit_scene") at deposit sites
@export var spawn_deposits = true
@export var regenerate_in_editor = false:
	set(value):
		if value and is_inside_tree():
			generate()

var lakes = []  # [{center: Vector2, radius: float}]
var forests = []  # [{circles: [{center: Vector2, radius: float}], kind: StringName}]
var outcrops = []  # [{center: Vector2, radius: float}]
var deposits = []  # [{kind: StringName, center: Vector2, amount: int, owner_hint: int}]
var spawns = []  # [Vector2]
var layout = null  # explicit layout from the map definition or the map editor, if any

var _generated = false
var _rng = RandomNumberGenerator.new()
var _dune_noise = FastNoiseLite.new()
var _warp_noise = FastNoiseLite.new()
var _mesa_noise = FastNoiseLite.new()
var _shape_noise = FastNoiseLite.new()
var _patch_noise = FastNoiseLite.new()


func _notification(what):
	# generating right after instantiation (not only in _ready) lets tools such as the data
	# validator inspect spawn points and deposits without adding the map to a scene tree
	if what == NOTIFICATION_SCENE_INSTANTIATED and not _generated:
		load_definition()
		generate()


func _ready():
	if not _generated:
		load_definition()
		generate()


func load_definition():
	if map_definition == "" or not FileAccess.file_exists(map_definition):
		return
	var definition = JSON.parse_string(FileAccess.get_file_as_string(map_definition))
	if not definition is Dictionary:
		push_error("cannot parse map definition '{0}'".format([map_definition]))
		return
	if "size" in definition:
		size = Vector2(definition.size[0], definition.size[1])
	var settings = definition.get("generator", {})
	map_seed = int(settings.get("seed", map_seed))
	resource_layout = RESOURCE_LAYOUTS.get(settings.get("resource_layout"), resource_layout)
	extra_lake_pairs = int(settings.get("lake_pairs", extra_lake_pairs))
	forest_pairs = int(settings.get("forest_pairs", forest_pairs))
	outcrop_pairs = int(settings.get("outcrop_pairs", outcrop_pairs))
	players = int(definition.get("players", players))
	var default_symmetry = "rotational" if players == 4 else "point"
	symmetry = SYMMETRIES.get(settings.get("symmetry", default_symmetry), symmetry)
	spawn_inset = float(settings.get("spawn_inset", spawn_inset))
	center_lake = bool(settings.get("center_lake", center_lake))
	home_deposits = settings.get("home_deposits", home_deposits)
	contested_deposits = settings.get("contested_deposits", contested_deposits)
	contested_richness = float(settings.get("contested_richness", contested_richness))
	middle_deposits = settings.get("middle_deposits", middle_deposits)
	middle_richness = float(settings.get("middle_richness", middle_richness))
	middle_reach = float(settings.get("middle_reach", middle_reach))
	start_zone_radius = float(definition.get("start_zone_radius", start_zone_radius))
	start_pick_seconds = float(definition.get("start_pick_seconds", start_pick_seconds))
	layout = definition.get("layout", null)


func generate():
	_generated = true
	_clear_generated()
	_setup_noise()
	if layout != null:
		_apply_layout(layout)
	else:
		_plan_layout()
	_build_terrain()
	_build_water()
	_build_spawn_points()
	_build_obstacles()
	_build_deposit_markers()
	Scatter.new().populate(self)


func get_height(pos: Vector2) -> float:
	var edge_distance = _distance_outside_playable_area(pos)
	if edge_distance <= 0.0:
		return _lake_height(pos)
	var ramp = smoothstep(3.0, 30.0, edge_distance)
	return ramp * (_dune_height(pos) + _mesa_height(pos) * smoothstep(18.0, 55.0, edge_distance))


func is_in_lake(pos: Vector2, margin = 0.0) -> bool:
	for lake in lakes:
		if pos.distance_to(lake.center) < _lake_radius_at(lake, pos) * LAKE_SHORE_RATIO + margin:
			return true
	return false


func lake_proximity(pos: Vector2) -> float:
	"""0 at the water line, 1 at the outer edge of the shore band, greater further away"""
	var best = 999.0
	for lake in lakes:
		var radius = _lake_radius_at(lake, pos)
		best = min(best, (pos.distance_to(lake.center) - radius) / (radius * 0.6))
	return best


func forest_density(pos: Vector2) -> float:
	var density = 0.0
	for forest in forests:
		for circle in forest.circles:
			var distance = pos.distance_to(circle.center)
			density = max(density, smoothstep(circle.radius + 4.0, circle.radius - 1.0, distance))
	return density


func is_obstructed(pos: Vector2, margin = 0.0) -> bool:
	for forest in forests:
		for circle in forest.circles:
			if pos.distance_to(circle.center) < circle.radius + margin:
				return true
	for outcrop in outcrops:
		if pos.distance_to(outcrop.center) < outcrop.radius + margin:
			return true
	return is_in_lake(pos, margin)


func is_reserved(pos: Vector2, margin = 0.0) -> bool:
	"""true near spawns and deposits - places that must stay clear of props"""
	for spawn in spawns:
		var clearance = max(SPAWN_CLEARANCE * 0.6, start_zone_radius + 4.0)
		if pos.distance_to(spawn) < clearance + margin:
			return true
	for deposit in deposits:
		if pos.distance_to(deposit.center) < DEPOSIT_CLEARANCE + margin:
			return true
	return false


func get_spawn_resource_bias(spawn_index: int) -> StringName:
	"""in ASYMMETRIC layouts one side is oil-rich and the other metal-rich"""
	if resource_layout != ResourceLayout.ASYMMETRIC or _symmetry() != 2:
		return &"balanced"
	return &"oil" if spawn_index % 2 == 0 else &"metal"


func _clear_generated():
	for node_name in ["Water", "Obstacles", "Deposits", "Scatter"]:
		var node = get_node_or_null(node_name)
		if node != null:
			remove_child(node)
			node.queue_free()
	for container in [find_child("SpawnPoints"), find_child("Resources")]:
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()
	lakes.clear()
	forests.clear()
	outcrops.clear()
	deposits.clear()
	spawns.clear()


func _setup_noise():
	_rng.seed = map_seed
	var noises = [_dune_noise, _warp_noise, _mesa_noise, _shape_noise, _patch_noise]
	for i in range(noises.size()):
		noises[i].seed = map_seed * 31 + i
		noises[i].noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_dune_noise.frequency = 0.02
	_warp_noise.frequency = 0.012
	_mesa_noise.frequency = 0.018
	_mesa_noise.fractal_octaves = 3
	_shape_noise.frequency = 0.35
	_patch_noise.frequency = 0.03


# layout planning


func _mirror(pos: Vector2) -> Vector2:
	return size - pos


func _copies(pos: Vector2) -> Array:
	"""pos and its symmetric copies, one per start zone. Copy i of anything placed for
	start zone 0 ends up in the same spot relative to start zone i."""
	if _symmetry() == 2:
		return [pos, _mirror(pos)]
	var center = size / 2.0
	var offset = pos - center
	var quarter = Vector2(-offset.y, offset.x)
	return [pos, center - offset, center + quarter, center - quarter]


func _symmetry() -> int:
	"""4-fold rotation needs a square map; anything else mirrors through the center"""
	return 4 if symmetry == Symmetry.ROTATIONAL and is_equal_approx(size.x, size.y) else 2


func _plan_layout():
	var corner = Vector2(spawn_inset, spawn_inset) * size
	spawns = _copies(corner)
	if _symmetry() == 2 and players > 2:
		spawns.append_array(_copies(Vector2(size.x - corner.x, corner.y)))
	if center_lake:
		lakes.append({"center": size / 2.0, "radius": min(size.x, size.y) * 0.065, "phase": 0.0})
	for _i in range(extra_lake_pairs):
		_place_symmetric_feature(lakes, _rng.randf_range(4.0, 6.5), 9.0, true)
	for _i in range(forest_pairs):
		_place_symmetric_forest()
	for _i in range(outcrop_pairs):
		_place_symmetric_feature(outcrops, _rng.randf_range(1.5, 3.0), 5.0, false)
	_plan_deposits()


func _random_point(margin: float) -> Vector2:
	return Vector2(
		_rng.randf_range(margin, size.x - margin), _rng.randf_range(margin, size.y - margin)
	)


func _copies_apart(pos: Vector2, distance: float) -> bool:
	var copies = _copies(pos)
	for i in range(1, copies.size()):
		if pos.distance_to(copies[i]) < distance:
			return false
	return true


func _is_free(pos: Vector2, radius: float, gap: float) -> bool:
	if not _copies_apart(pos, (radius + gap) * 2.0):
		return false
	var blockers = []  # [center, clearance]
	for spawn in spawns:
		blockers.append([spawn, SPAWN_CLEARANCE + radius - gap])
	for lake in lakes:
		blockers.append([lake.center, lake.radius * LAKE_SHORE_RATIO + radius])
	for forest in forests:
		for circle in forest.circles:
			blockers.append([circle.center, circle.radius + radius])
	for outcrop in outcrops:
		blockers.append([outcrop.center, outcrop.radius + radius])
	for deposit in deposits:
		blockers.append([deposit.center, DEPOSIT_CLEARANCE + radius])
	return blockers.all(func(blocker): return pos.distance_to(blocker[0]) >= blocker[1] + gap)


func _place_symmetric_feature(target, radius, gap, is_lake):
	for _attempt in range(200):
		var pos = _random_point(radius * 1.5 + 4.0)
		if _is_free(pos, radius * (LAKE_SHORE_RATIO if is_lake else 1.0), gap):
			var phase = _rng.randf() * 100.0
			for copy in _copies(pos):
				target.append({"center": copy, "radius": radius, "phase": phase})
			return


func _place_symmetric_forest():
	var kind = [&"acacia", &"pine", &"mixed"][_rng.randi() % 3]
	for _attempt in range(200):
		var center = _random_point(14.0)
		var circles = [{"center": center, "radius": _rng.randf_range(2.5, 3.5)}]
		for _i in range(_rng.randi_range(2, 4)):
			var offset = Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(2.5, 4.5)
			circles.append({"center": center + offset, "radius": _rng.randf_range(1.8, 3.0)})
		if circles.all(func(circle): return _is_free(circle.center, circle.radius, 4.0)):
			for copy_index in range(_symmetry()):
				var copied = circles.map(
					func(circle):
						return {
							"center": _copies(circle.center)[copy_index], "radius": circle.radius
						}
				)
				forests.append({"circles": copied, "kind": kind})
			return


func _plan_deposits():
	var asymmetric = resource_layout == ResourceLayout.ASYMMETRIC and _symmetry() == 2
	# deposits close to each start zone, a safe-ish start economy. They are planned around
	# zone 0 and copied, so every zone gets the same kinds at the same distances.
	var home_spawns = spawns.size() / _symmetry()
	for spawn_index in range(home_spawns):
		var spawn = spawns[spawn_index * _symmetry()]
		var towards_center = (size / 2.0 - spawn).angle()
		var kinds = home_deposits
		for i in range(kinds.size()):
			var spread = 0.0 if kinds.size() == 1 else lerp(-0.9, 0.9, i / (kinds.size() - 1.0))
			for _attempt in range(80):
				var angle = towards_center + spread + _rng.randf_range(-0.3, 0.3)
				var distance = start_zone_radius + _rng.randf_range(7.0, 9.0)
				var pos = spawn + Vector2.from_angle(angle) * distance
				if _deposit_spot_ok(pos):
					var copy_kinds = []
					for copy_index in range(_symmetry()):
						copy_kinds.append(_home_kind(kinds[i], copy_index, asymmetric, i))
					_add_symmetric_deposits(copy_kinds, pos, 1.0)
					break
	# contested deposits in the open, copied for fairness
	for kind in contested_deposits:
		_place_open_deposit(kind, contested_richness, 0.0, asymmetric)
	# the richest deposits, close to the middle of the map: worth fighting over
	for kind in middle_deposits:
		_place_open_deposit(kind, middle_richness, middle_reach, asymmetric)
	# timber at forest edges; forests come in groups of copies
	for forest_index in range(0, forests.size(), _symmetry()):
		var circle = forests[forest_index].circles[0]
		for _attempt in range(30):
			var outward = Vector2.from_angle(_rng.randf() * TAU)
			var pos = circle.center + outward * (circle.radius + 4.5)
			if _deposit_spot_ok(pos):
				_add_symmetric_deposits(_same_kind(&"timber"), pos, 1.0)
				break


func _home_kind(kind, copy_index, asymmetric, slot):
	"""asymmetric maps give one side oil and the other metals"""
	if not asymmetric:
		return StringName(kind)
	if copy_index == 0:
		return &"oil"
	return [&"iron", &"copper"][slot % 2]


func _place_open_deposit(kind, richness, reach, asymmetric):
	var center = size / 2.0
	for _attempt in range(300):
		var pos = _random_point(8.0)
		if reach > 0.0:
			var max_distance = reach * min(size.x, size.y) / 2.0
			pos = (
				center
				+ Vector2.from_angle(_rng.randf() * TAU) * _rng.randf_range(0.0, max_distance)
			)
		if spawns.any(func(spawn): return pos.distance_to(spawn) < 24.0):
			continue
		if not _copies_apart(pos, 12.0) or not _deposit_spot_ok(pos):
			continue
		var copy_kinds = _same_kind(StringName(kind))
		if asymmetric:
			var oil_side = pos.distance_to(spawns[0]) < pos.distance_to(spawns[1])
			var metal = [&"iron", &"copper"][_rng.randi() % 2]
			copy_kinds = [&"oil", metal] if oil_side else [metal, &"oil"]
		_add_symmetric_deposits(copy_kinds, pos, richness)
		return


func _same_kind(kind) -> Array:
	var kinds = []
	kinds.resize(_symmetry())
	kinds.fill(kind)
	return kinds


func _add_symmetric_deposits(kinds, pos, richness):
	var copies = _copies(pos)
	for copy_index in range(copies.size()):
		_add_deposit(kinds[copy_index], copies[copy_index], richness, -1)


func _deposit_spot_ok(pos: Vector2) -> bool:
	var margin = 5.0
	for copy in _copies(pos):
		if copy.x < margin or copy.y < margin or copy.x > size.x - margin:
			return false
		if copy.y > size.y - margin or is_obstructed(copy, 3.0):
			return false
		for spawn in spawns:
			if copy.distance_to(spawn) < start_zone_radius + 6.0:
				return false
		for deposit in deposits:
			if copy.distance_to(deposit.center) < 9.0:
				return false
	return true


func _add_deposit(kind, pos, richness, owner_hint):
	var base_amount = Constants.Match.Resources.DEFAULT_DEPOSIT_AMOUNT.get(String(kind), 500)
	(
		deposits
		. append(
			{
				"kind": kind,
				"center": pos,
				"amount": int(base_amount * richness),
				"owner_hint": owner_hint,
			}
		)
	)


# layout (de)serialization, used by map definitions and the map editor


func export_layout() -> Dictionary:
	var forest_list = []
	for forest in forests:
		forest_list.append(
			{"kind": String(forest.kind), "circles": forest.circles.map(_circle_to_dict)}
		)
	var deposit_list = []
	for deposit in deposits:
		(
			deposit_list
			. append(
				{
					"kind": String(deposit.kind),
					"center": _vector_to_list(deposit.center),
					"amount": deposit.amount,
				}
			)
		)
	return {
		"spawns": spawns.map(_vector_to_list),
		"lakes": lakes.map(_circle_to_dict),
		"forests": forest_list,
		"outcrops": outcrops.map(_circle_to_dict),
		"deposits": deposit_list,
	}


func _vector_to_list(vector):
	return [snappedf(vector.x, 0.01), snappedf(vector.y, 0.01)]


func _circle_to_dict(circle):
	return {"center": _vector_to_list(circle.center), "radius": snappedf(circle.radius, 0.01)}


func _apply_layout(a_layout: Dictionary):
	var to_vector = func(list): return Vector2(float(list[0]), float(list[1]))
	for spawn in a_layout.get("spawns", []):
		spawns.append(to_vector.call(spawn))
	for lake in a_layout.get("lakes", []):
		var center = to_vector.call(lake.center)
		lakes.append(
			{"center": center, "radius": float(lake.radius), "phase": center.x * 0.37 + center.y}
		)
	for forest in a_layout.get("forests", []):
		var circles = forest.get("circles", []).map(
			func(c): return {"center": to_vector.call(c.center), "radius": float(c.radius)}
		)
		forests.append({"circles": circles, "kind": StringName(forest.get("kind", "mixed"))})
	for outcrop in a_layout.get("outcrops", []):
		outcrops.append({"center": to_vector.call(outcrop.center), "radius": float(outcrop.radius)})
	for deposit in a_layout.get("deposits", []):
		var kind = StringName(deposit.kind)
		_add_deposit(kind, to_vector.call(deposit.center), 1.0, -1)
		if "amount" in deposit:
			deposits[-1].amount = int(deposit.amount)


# height field


func _distance_outside_playable_area(pos: Vector2) -> float:
	var dx = max(-pos.x, pos.x - size.x, 0.0)
	var dz = max(-pos.y, pos.y - size.y, 0.0)
	return Vector2(dx, dz).length()


func _lake_radius_at(lake, pos: Vector2) -> float:
	var angle = (pos - lake.center).angle()
	var wobble = (
		sin(angle * 3.0 + lake.phase) * 0.12
		+ sin(angle * 5.0 + lake.phase * 1.7) * 0.07
		+ sin(angle * 2.0 + lake.phase * 0.3) * 0.1
	)
	return lake.radius * (1.0 + wobble)


func _lake_height(pos: Vector2) -> float:
	var height = 0.0
	for lake in lakes:
		var distance = pos.distance_to(lake.center)
		if distance > lake.radius * 2.0:
			continue
		var normalized = distance / _lake_radius_at(lake, pos)
		height = min(height, -LAKE_DEPTH * smoothstep(LAKE_SHORE_RATIO, 0.8, normalized))
	return height


func _dune_height(pos: Vector2) -> float:
	var warp = _warp_noise.get_noise_2dv(pos) * 9.0
	var along = pos.dot(Vector2(0.83, 0.56)) * 0.11 + warp
	var crest = pow(0.5 + 0.5 * sin(along), 2.2)
	var amplitude = 2.0 + 3.5 * (0.5 + 0.5 * _dune_noise.get_noise_2dv(pos))
	return crest * amplitude + 0.6 * _dune_noise.get_noise_2dv(pos * 2.3)


func _mesa_height(pos: Vector2) -> float:
	var value = _mesa_noise.get_noise_2dv(pos)
	var plateau = smoothstep(0.08, 0.2, value)
	var terraces = floor(plateau * 3.0) / 3.0
	return lerp(plateau, terraces, 0.6) * 15.0


func _rock_weight(pos: Vector2, height: float, slope: float) -> float:
	var weight = smoothstep(0.45, 0.8, slope)
	if _distance_outside_playable_area(pos) > 0.0:
		weight = max(weight, smoothstep(4.0, 8.0, height - _dune_height(pos)))
	for outcrop in outcrops:
		var distance = pos.distance_to(outcrop.center)
		weight = max(weight, smoothstep(outcrop.radius + 2.5, outcrop.radius * 0.5, distance))
	return weight


# geometry


func _axis_coordinates(length: float) -> PackedFloat32Array:
	var inner = PackedFloat32Array()
	var x = -INNER_MARGIN
	while x <= length + INNER_MARGIN + 0.001:
		inner.append(x)
		x += 1.0
	var outer_steps = PackedFloat32Array()
	var step = 1.0
	var offset = INNER_MARGIN
	while offset < outer_margin:
		step *= 1.09
		offset += step
		outer_steps.append(offset)
	var coordinates = PackedFloat32Array()
	for i in range(outer_steps.size() - 1, -1, -1):
		coordinates.append(-outer_steps[i])
	coordinates.append_array(inner)
	for offset_value in outer_steps:
		coordinates.append(length + offset_value)
	return coordinates


func _build_terrain():
	var xs = _axis_coordinates(size.x)
	var zs = _axis_coordinates(size.y)
	var heights = PackedFloat32Array()
	heights.resize(xs.size() * zs.size())
	for j in range(zs.size()):
		for i in range(xs.size()):
			heights[j * xs.size() + i] = get_height(Vector2(xs[i], zs[j]))
	var vertices = PackedVector3Array()
	var normals = PackedVector3Array()
	var colors = PackedColorArray()
	for j in range(zs.size()):
		for i in range(xs.size()):
			var i0 = max(i - 1, 0)
			var i1 = min(i + 1, xs.size() - 1)
			var j0 = max(j - 1, 0)
			var j1 = min(j + 1, zs.size() - 1)
			var row = j * xs.size()
			var slope_x = (heights[row + i1] - heights[row + i0]) / (xs[i1] - xs[i0])
			var slope_z = (
				(heights[j1 * xs.size() + i] - heights[j0 * xs.size() + i]) / (zs[j1] - zs[j0])
			)
			var normal = Vector3(-slope_x, 1.0, -slope_z).normalized()
			var pos = Vector2(xs[i], zs[j])
			var height = heights[row + i]
			vertices.append(Vector3(pos.x, height, pos.y))
			normals.append(normal)
			colors.append(_terrain_color(pos, height, 1.0 - normal.y))
	var indices = PackedInt32Array()
	for j in range(zs.size() - 1):
		for i in range(xs.size() - 1):
			var a = j * xs.size() + i
			var b = a + 1
			var c = a + xs.size()
			var d = c + 1
			if (i + j) % 2 == 0:
				indices.append_array([a, b, d, a, d, c])
			else:
				indices.append_array([a, b, c, b, d, c])
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh = ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, TerrainMaterial)
	var terrain = find_child("Terrain")
	terrain.mesh = mesh
	terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	find_child("BlackBackgroundFixingAntiAliasingBug").visible = false


func _terrain_color(pos: Vector2, height: float, slope: float) -> Color:
	"""r: vegetation, g: rock, b: wet ground, a: hardpan / salt flat"""
	var vegetation = forest_density(pos)
	var wet = 0.0
	if not lakes.is_empty():
		var proximity = lake_proximity(pos)
		wet = smoothstep(1.4, 0.3, proximity)
		vegetation = max(vegetation, smoothstep(2.6, 0.9, proximity) * 0.85)
	var rock = _rock_weight(pos, height, slope)
	var hardpan = 0.0
	if _distance_outside_playable_area(pos) <= 0.0:
		hardpan = smoothstep(0.25, 0.45, _patch_noise.get_noise_2dv(pos))
		hardpan *= 1.0 - max(vegetation, wet)
	return Color(vegetation, rock, wet, hardpan)


func _build_water():
	if lakes.is_empty():
		return
	var water = MeshInstance3D.new()
	water.name = "Water"
	var plane = PlaneMesh.new()
	plane.size = size + Vector2(8.0, 8.0)
	plane.subdivide_width = 0
	plane.subdivide_depth = 0
	plane.material = WaterMaterial
	water.mesh = plane
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	water.position = Vector3(size.x / 2.0, WATER_LEVEL, size.y / 2.0)
	add_child(water)


func _build_spawn_points():
	var spawn_points = find_child("SpawnPoints")
	for i in range(spawns.size()):
		var marker = Marker3D.new()
		marker.name = "Spawn{0}".format([i])
		var facing = Basis(Vector3.UP, PI)
		marker.transform = Transform3D(facing, Vector3(spawns[i].x, 0.0, spawns[i].y))
		marker.set_meta("resource_bias", get_spawn_resource_bias(i))
		spawn_points.add_child(marker)


func _build_obstacles():
	"""navigation input made of colliders only: a flat ground slab, a prism per lake and a
	cylinder per forest or outcrop circle. The detailed terrain mesh is left out of the
	navigation group because parsing it on every rebake reads it back from the GPU."""
	var obstacles = Node3D.new()
	obstacles.name = "Obstacles"
	add_child(obstacles)
	find_child("Terrain").remove_from_group("terrain_navigation_input")
	var ground = BoxShape3D.new()
	ground.size = Vector3(size.x + INNER_MARGIN * 2.0, 1.0, size.y + INNER_MARGIN * 2.0)
	obstacles.add_child(_navigation_body(ground, Vector3(size.x / 2.0, -0.5, size.y / 2.0)))
	for lake in lakes:
		var center = Vector3(lake.center.x, 0.0, lake.center.y)
		obstacles.add_child(_navigation_body(_lake_shape(lake), center))
	var circles = []
	for forest in forests:
		circles.append_array(forest.circles)
	circles.append_array(outcrops)
	for circle in circles:
		var shape = CylinderShape3D.new()
		shape.radius = circle.radius
		shape.height = 3.0
		var center = Vector3(circle.center.x, 1.5, circle.center.y)
		obstacles.add_child(_navigation_body(shape, center))


func _navigation_body(shape, position_value):
	var body = StaticBody3D.new()
	body.collision_layer = 2
	body.collision_mask = 0
	body.input_ray_pickable = false
	body.add_to_group("terrain_navigation_input")
	var collision = CollisionShape3D.new()
	collision.shape = shape
	body.add_child(collision)
	body.position = position_value
	return body


func _lake_shape(lake):
	"""a 3 m high prism following the lake's wobbly water line"""
	var outline = PackedVector3Array()
	for i in range(LAKE_OUTLINE_POINTS):
		var direction = Vector2.from_angle(TAU * i / LAKE_OUTLINE_POINTS)
		var radius = _lake_radius_at(lake, lake.center + direction * lake.radius)
		var point = direction * radius * LAKE_WATER_LINE_RATIO
		outline.append(Vector3(point.x, 0.0, point.y))
	var faces = PackedVector3Array()
	var up = Vector3(0.0, 3.0, 0.0)
	for i in range(outline.size()):
		var a = outline[i]
		var b = outline[(i + 1) % outline.size()]
		faces.append_array([Vector3.ZERO + up, b + up, a + up])
		faces.append_array([a, b, b + up, a, b + up, a + up])
	var shape = ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	return shape


func _build_deposit_markers():
	var deposits_node = Node3D.new()
	deposits_node.name = "Deposits"
	add_child(deposits_node)
	for i in range(deposits.size()):
		var deposit = deposits[i]
		var marker = Marker3D.new()
		marker.name = "{0}{1}".format([String(deposit.kind).capitalize(), i])
		marker.position = Vector3(deposit.center.x, 0.0, deposit.center.y)
		marker.rotation.y = _rng.randf() * TAU
		marker.set_meta("kind", deposit.kind)
		marker.set_meta("amount", deposit.amount)
		marker.set_meta("owner_hint", deposit.owner_hint)
		deposits_node.add_child(marker)
		if spawn_deposits and not Engine.is_editor_hint():
			_spawn_deposit(deposit, marker.rotation.y)


func _spawn_deposit(deposit, rotation_y):
	var scene_path = Constants.Match.Resources.DEPOSIT_SCENES.get(String(deposit.kind))
	if scene_path == null or not ResourceLoader.exists(scene_path):
		return
	var unit = load(scene_path).instantiate()
	unit.transform = Transform3D(
		Basis(Vector3.UP, rotation_y), Vector3(deposit.center.x, 0.0, deposit.center.y)
	)
	if "amount" in unit:
		unit.amount = deposit.amount
	find_child("Resources").add_child(unit)
