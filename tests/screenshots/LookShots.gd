extends Node

# The same match scene in every art direction (data/looks), for side-by-side comparison.
#   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --resolution 1920x1080 \
#     res://tests/screenshots/LookShots.tscn -- --out=/tmp/looks --looks=classic,grounded,stylised \
#     --sizes=15,30 --target_player=0 --warmup=200 --time_scale=4
# Saves <look>_<size>.png; --hide_hud leaves only the world, --weather=clear fixes the weather.

var _args = {}


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var out_dir = _args.get("out", "user://looks")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var match_node = load(_args.get("scene", "res://tests/manual/TestDesert.tscn")).instantiate()
	if _args.has("no_ai"):
		match_node.settings.players = match_node.settings.players.filter(
			func(player_settings): return player_settings.controller == Constants.PlayerType.HUMAN
		)
	match_node.process_mode = Node.PROCESS_MODE_PAUSABLE  # this node runs while paused, the match not
	add_child(match_node)
	Engine.time_scale = float(_args.get("time_scale", "1"))
	if Engine.time_scale > 1.0:
		Engine.max_physics_steps_per_frame = 32
	await _frames(int(_args.get("warmup", "60")))
	Engine.time_scale = 1.0
	Engine.max_physics_steps_per_frame = 8
	get_tree().paused = true  # the same moment in every look
	var atmosphere = match_node.find_child("Atmosphere", true, false)
	if atmosphere != null:
		atmosphere.process_mode = Node.PROCESS_MODE_ALWAYS
		atmosphere.set_weather_immediately(_args.get("weather", "clear"))
	var look = match_node.get_node("Look")
	look.process_mode = Node.PROCESS_MODE_ALWAYS
	if _args.has("hide_hud"):
		for layer in match_node.find_children("*", "CanvasLayer", true, false):
			if layer.name != "LookGrade":
				layer.visible = false
	var camera = get_viewport().get_camera_3d()
	var target = null
	if _args.has("target"):
		var xyz = _args["target"].split(",")
		target = Vector3(float(xyz[0]), float(xyz[1]), float(xyz[2]))
	if _args.has("target_player"):
		var player = get_tree().get_nodes_in_group("players")[int(_args["target_player"])]
		var depots = player.get_node("Logistics").get_depots()
		if not depots.is_empty():
			target = depots[0].global_position
	if target != null and _args.has("offset"):  # e.g. --offset=12,0,10 from the player's depot
		var xyz = _args["offset"].split(",")
		target += Vector3(float(xyz[0]), float(xyz[1]), float(xyz[2]))
	for look_id in _args.get("looks", ",".join(look.available_looks())).split(","):
		look.apply(look_id)
		for size_text in _args.get("sizes", "15").split(","):
			camera.set_size_safely(float(size_text))
			if target != null:
				camera.set_position_safely(target)
			await _frames(int(_args.get("settle", "12")))
			var path = "{0}/{1}_{2}.png".format([out_dir, look_id, size_text])
			get_viewport().get_texture().get_image().save_png(path)
			print("saved ", path)
	get_tree().quit()


func _frames(count):
	for i in range(count):
		await get_tree().process_frame
