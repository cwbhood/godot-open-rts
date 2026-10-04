extends Node

# Lines up every unit, structure and city building from data/ next to the first player's
# depot and screenshots them through the game camera, to judge the art at play zoom.
# Usage (needs a real renderer, e.g. under xvfb-run):
#   godot --path . res://tests/screenshots/ArtGallery.tscn -- --out=/tmp/gallery --sizes=15
# Options: --scene (default TestDesert), --warmup frames, --settle frames, --prefix,
# --units_at=x,z and --structures_at=x,z (block centres), --weather.

const GameData = preload("res://source/data-model/GameData.gd")
const CityBuilding = preload("res://source/match/city/CityBuilding.gd")
const Structure = preload("res://source/match/units/Structure.gd")

const UNIT_SPACING = Vector2(3.0, 3.6)
const UNIT_COLUMNS = 5
const STRUCTURE_SPACING = Vector2(6.4, 5.6)
const STRUCTURE_COLUMNS = 5

var _args = {}


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var out_dir = _args.get("out", "user://gallery")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var match_node = load(_args.get("scene", "res://tests/manual/TestDesert.tscn")).instantiate()
	match_node.settings.players = match_node.settings.players.filter(
		func(player_settings): return player_settings.controller == Constants.PlayerType.HUMAN
	)
	add_child(match_node)
	await _frames(int(_args.get("warmup", "30")))
	for layer in match_node.find_children("*", "CanvasLayer", true, false):
		layer.visible = false
	var atmosphere = match_node.find_child("Atmosphere", true, false)
	if atmosphere != null:
		atmosphere.set_weather_immediately(_args.get("weather", "clear"))
	var player = get_tree().get_nodes_in_group("players")[0]
	var depots = player.get_node("Logistics").get_depots()
	# defaults: open ground next to the first player's base on TestDesert
	var unit_centre = _parse_xz(_args.get("units_at", "28,32"))
	var structure_centre = _parse_xz(_args.get("structures_at", "42,13"))
	_clear_area(unit_centre, 16.0, depots)
	_clear_area(structure_centre, 20.0, depots)
	var units = []
	var structures = []
	for entry in GameData.units():
		if entry.get("category", "unit") == "structure":
			structures.append(entry)
		else:
			units.append(entry)
	_place_grid(units, unit_centre, UNIT_SPACING, UNIT_COLUMNS, player)
	var city_buildings = []  # [kind, variant] for every city building model
	for kind in Constants.Match.City.BUILDING_MODELS:
		for variant in range(Constants.Match.City.BUILDING_MODELS[kind].size()):
			city_buildings.append([kind, variant])
	_place_grid(
		structures + city_buildings, structure_centre, STRUCTURE_SPACING, STRUCTURE_COLUMNS, player
	)
	await _frames(int(_args.get("spawn_frames", "30")))
	var camera = get_viewport().get_camera_3d()
	var prefix = _args.get("prefix", "gallery")
	for size_text in _args.get("sizes", "15").split(","):
		camera.set_size_safely(float(size_text))
		for shot in [["units", unit_centre], ["buildings", structure_centre]]:
			camera.set_position_safely(shot[1])
			await _frames(int(_args.get("settle", "20")))
			var path = "{0}/{1}_{2}_{3}.png".format([out_dir, prefix, shot[0], size_text])
			get_viewport().get_texture().get_image().save_png(path)
			print("saved ", path)
	get_tree().quit()


func _place_grid(items, centre, spacing, columns, player):
	var rows = ceili(items.size() / float(columns))
	for i in range(items.size()):
		var column = i % columns
		var row = i / columns
		var position = (
			centre
			+ Vector3(
				(column - (columns - 1) / 2.0) * spacing.x, 0, (row - (rows - 1) / 2.0) * spacing.y
			)
		)
		if items[i] is Array:
			var building = CityBuilding.new()
			building.kind = items[i][0]
			building.variant = items[i][1]
			building.player = player
			add_child(building)
			building.global_position = position
			building.rotation.y = PI * 0.75
			continue
		var unit = load(items[i]["scene"]).instantiate()
		if unit is Structure:
			unit.set_meta("spawn_constructed", true)
		# face the camera three-quarters, like a freshly placed structure blueprint
		var facing = Transform3D(Basis(), position).looking_at(
			position + Vector3(0, 0, -1).rotated(Vector3.UP, PI * 0.75), Vector3.UP
		)
		MatchSignals.setup_and_spawn_unit.emit(unit, facing, player)


func _parse_xz(text):
	var xz = text.split(",")
	return Vector3(float(xz[0]), 0, float(xz[1]))


func _clear_area(centre, radius, keep):
	"""hides scatter props and drops other units around the gallery"""
	for node in get_tree().get_nodes_in_group("units"):
		if node in keep:
			continue
		if node.global_position.distance_to(centre) < radius:
			node.queue_free()
	for node in get_tree().get_nodes_in_group("city_buildings"):
		if node.global_position.distance_to(centre) < radius:
			node.visible = false


func _frames(count):
	for i in range(count):
		await get_tree().process_frame
