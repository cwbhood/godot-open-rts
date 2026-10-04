extends Node

# Puts each unit that has a "classic_model" in data/units next to its new model, for a blue
# and a red player, on a desert map, and screenshots every unit through the game camera:
# classic blue, new blue, classic red, new red from left to right.
# Usage (needs a real renderer, e.g. under xvfb-run):
#   godot --path . res://tests/screenshots/UnitModelCompare.tscn -- --unit-models=new \
#     --out=/tmp/compare --sizes=15,8
# Options: --scene (default TestDesert), --map (a map scene to use instead of the scene's),
# --at=x,z (open ground; default next to the first player's depot), --only=tank,raider,
# --warmup, --settle frames. tools/art/compare_strips.py turns the shots into strips.

const GameData = preload("res://source/data-model/GameData.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Human = preload("res://source/match/players/human/Human.gd")

const SPACING = 3.2

var _args = {}
var _match = null


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var out_dir = _args.get("out", "user://unit_compare")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var match_node = load(_args.get("scene", "res://tests/manual/TestDesert.tscn")).instantiate()
	if "map" in _args:
		var old_map = match_node.get_node("Map")
		var new_map = load(_args["map"]).instantiate()
		new_map.name = "Map"
		match_node.remove_child(old_map)
		old_map.free()
		match_node.add_child(new_map)
		match_node.move_child(new_map, 0)
	add_child(match_node)
	_match = match_node
	await _frames(int(_args.get("warmup", "30")))
	for player in get_tree().get_nodes_in_group("players"):
		if not player is Human:
			for child in player.get_children():
				child.process_mode = Node.PROCESS_MODE_DISABLED  # the rival only stands by
	for layer in match_node.find_children("*", "CanvasLayer", true, false):
		layer.visible = false
	var atmosphere = match_node.find_child("Atmosphere", true, false)
	if atmosphere != null:
		atmosphere.set_weather_immediately("clear")
	var players = get_tree().get_nodes_in_group("players")
	var only = _args.get("only", "").split(",", false)
	var entries = GameData.units().filter(
		func(entry): return "classic_model" in entry and (only.is_empty() or entry["id"] in only)
	)
	var origin = (
		_parse_xz(_args["at"])
		if "at" in _args
		else _open_ground_near(players[0].get_node("Logistics").get_depots()[0].global_position)
	)
	_clear_area(origin, 14.0)
	var camera = get_viewport().get_camera_3d()
	# one unit at a time on the same patch of open ground
	for entry in entries:
		var units = []
		var column = 0
		for player in players:
			for classic in [true, false]:
				var position = origin + Vector3((column - 1.5) * SPACING, 0, 0)
				units.append(_spawn(entry, classic, player, position))
				column += 1
		await _frames(int(_args.get("spawn_frames", "40")))
		for size_text in _args.get("sizes", "15").split(","):
			camera.set_size_safely(float(size_text))
			_centre_camera_on(camera, units)
			await _frames(int(_args.get("settle", "12")))
			var path = "{0}/{1}_{2}.png".format([out_dir, entry["id"], size_text])
			get_viewport().get_texture().get_image().save_png(path)
			print("saved ", path)
		for unit in units:
			unit.queue_free()
		await _frames(5)
	get_tree().quit()


func _spawn(entry, classic, player, position):
	var unit = load(entry["scene"]).instantiate()
	var facing = Transform3D(Basis(), position).looking_at(
		position + Vector3(0, 0, -1).rotated(Vector3.UP, PI * 0.75), Vector3.UP
	)
	unit.set_meta("hold_fire", true)
	MatchSignals.setup_and_spawn_unit.emit(unit, facing, player)
	if classic:
		var classic_entry = {}
		for field in GameData.MODEL_FIELDS:
			if "classic_" + field in entry:
				classic_entry[field] = entry["classic_" + field]
		GameData.apply_model(unit, classic_entry)
		unit._setup_color()
	return unit


func _centre_camera_on(camera, units):
	"""puts the units' centre (in the air for aircraft) in the middle of the screen"""
	var centre = Vector3.ZERO
	for unit in units:
		centre += unit.global_position / units.size()
	camera.set_position_safely(Vector3(centre.x, 0, centre.z))
	var ground = Plane(Vector3.UP, 0.0)
	var screen_centre = get_viewport().get_visible_rect().size / 2.0
	var under_centre = camera.get_ray_intersection_with_plane(screen_centre, ground)
	var under_units = camera.get_ray_intersection_with_plane(
		camera.unproject_position(centre), ground
	)
	if under_centre != null and under_units != null:
		camera.set_position_safely(Vector3(centre.x, 0, centre.z) + under_units - under_centre)


func _open_ground_near(depot_position):
	"""the first spot 10 to 30 m from the depot whose line-up cells are all on the navmesh"""
	var map_rid = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	for distance in [12.0, 16.0, 20.0, 24.0, 28.0]:
		for step in range(16):
			var centre = (
				depot_position + Vector3(distance, 0, 0).rotated(Vector3.UP, step * TAU / 16)
			)
			var clear = true
			for dx in range(-7, 8):
				for dz in [-1.5, 0.0, 1.5]:
					var probe = centre + Vector3(dx, 0, dz)
					var snapped = NavigationServer3D.map_get_closest_point(map_rid, probe)
					if Vector2(snapped.x, snapped.z).distance_to(Vector2(probe.x, probe.z)) > 0.2:
						clear = false
			if clear:
				return Vector3(centre.x, 0, centre.z)
	return depot_position + Vector3(14, 0, 0)


func _parse_xz(text):
	var xz = text.split(",")
	return Vector3(float(xz[0]), 0, float(xz[1]))


func _clear_area(centre, radius):
	"""hides scatter props and drops other units around the line-up"""
	for node in get_tree().get_nodes_in_group("units"):
		if node is Structure:
			continue  # keeps the depots, a player without one may lose the match
		if node.global_position.distance_to(centre) < radius:
			node.queue_free()
	for node in get_tree().get_nodes_in_group("city_buildings"):
		if node.global_position.distance_to(centre) < radius:
			node.visible = false


func _frames(count):
	for i in range(count):
		await get_tree().process_frame
