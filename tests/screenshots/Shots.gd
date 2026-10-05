extends Node

# Renders a match scene and saves screenshots at several camera zoom levels.
# Usage (needs a real renderer, e.g. under xvfb-run):
#   godot --path . res://tests/screenshots/Shots.tscn -- \
#     --scene=res://tests/manual/TestDesert.tscn --out=/tmp/shots \
#     --sizes=12,25,45,80 --target=60,0,60 --weather=clear --warmup=90
# --time_scale=6 fast-forwards the warmup, --target_player=1 centres on that player's
# depot, --demo_routes sets the routes of player 'target_player' to dirt, paved and rail
# and mines its deposits down so that road and depletion visuals can be checked.

var _args = {}


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var out_dir = _args.get("out", "user://shots")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var match_scene = load(_args.get("scene", "res://tests/manual/TestOneCityOneRival.tscn"))
	var match_node = match_scene.instantiate()
	if _args.has("no_ai"):
		# drop AI players: useful when only the world needs checking
		match_node.settings.players = match_node.settings.players.filter(
			func(player_settings): return player_settings.controller == Constants.PlayerType.HUMAN
		)
	add_child(match_node)
	Engine.time_scale = float(_args.get("time_scale", "1"))
	if Engine.time_scale > 1.0:
		Engine.max_physics_steps_per_frame = 32
	await _frames(int(_args.get("warmup", "60")))
	Engine.time_scale = 1.0
	Engine.max_physics_steps_per_frame = 8
	var atmosphere = match_node.find_child("Atmosphere", true, false)
	if atmosphere != null and _args.has("weather"):
		atmosphere.set_weather_immediately(_args["weather"])
		await _frames(int(_args.get("weather_frames", "40")))
	if _args.has("hide_hud"):
		for layer in match_node.find_children("*", "CanvasLayer", true, false):
			layer.visible = false
	var camera = get_viewport().get_camera_3d()
	if _args.has("rotate"):
		camera.rotate_y(deg_to_rad(float(_args["rotate"])))
	var target = null
	if _args.has("target"):
		var xyz = _args["target"].split(",")
		target = Vector3(float(xyz[0]), float(xyz[1]), float(xyz[2]))
	if _args.has("target_player"):
		var players = get_tree().get_nodes_in_group("players")
		var player = players[int(_args["target_player"])]
		print("target player: ", player.name, " of ", players.size())
		var logistics = player.get_node("Logistics")
		var depots = logistics.get_depots()
		if not depots.is_empty():
			target = depots[0].global_position
		if _args.has("demo_routes"):
			_demo_routes(logistics)
			await _frames(40)
	var sizes = _args.get("sizes", "15").split(",")
	var prefix = _args.get("prefix", "shot")
	for size_text in sizes:
		camera.set_size_safely(float(size_text))
		if target != null:
			camera.set_position_safely(target)
		await _frames(int(_args.get("settle", "20")))
		var image = get_viewport().get_texture().get_image()
		var path = "{0}/{1}_{2}.png".format([out_dir, prefix, size_text])
		image.save_png(path)
		print("saved ", path)
	get_tree().quit()


func _frames(count):
	for i in range(count):
		await get_tree().process_frame
		if i % 100 == 99:
			print("frame {0}/{1} at {2} s".format([i + 1, count, Time.get_ticks_msec() / 1000]))


func _demo_routes(logistics):
	var extractors = logistics.get_extractors()
	print("extractors: ", extractors.size())
	for i in range(extractors.size()):
		logistics.road_levels[extractors[i]] = i % 3
	for deposit in get_tree().get_nodes_in_group("deposits"):
		for extractor in extractors:
			if extractor.global_position.distance_to(deposit.global_position) < 6.0:
				deposit.amount = int(deposit.amount * 0.3)
