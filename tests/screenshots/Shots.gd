extends Node

# Renders a match scene and saves screenshots at several camera zoom levels.
# Usage (needs a real renderer, e.g. under xvfb-run):
#   godot --path . res://tests/screenshots/Shots.tscn -- \
#     --scene=res://tests/manual/TestDesert.tscn --out=/tmp/shots \
#     --sizes=12,25,45,80 --target=60,0,60 --weather=clear --warmup=90

var _args = {}


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var out_dir = _args.get("out", "user://shots")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var match_scene = load(_args.get("scene", "res://tests/manual/TestOneCityOneRival.tscn"))
	var match_node = match_scene.instantiate()
	add_child(match_node)
	await _frames(int(_args.get("warmup", "60")))
	var atmosphere = match_node.find_child("Atmosphere", true, false)
	if atmosphere != null and _args.has("weather"):
		atmosphere.set_weather_immediately(_args["weather"])
		await _frames(int(_args.get("weather_frames", "40")))
	if _args.has("debug_atmosphere") and atmosphere != null:
		var decal = atmosphere.find_child("CloudShadows")
		print("decal ", decal.global_position, " size ", decal.size, " mod ", decal.modulate)
		print(" visible ", decal.is_visible_in_tree(), " tex ", decal.texture_albedo)
		print(" layers ", decal.layers, " cull ", decal.cull_mask, " mix ", decal.albedo_mix)
		if _args["debug_atmosphere"] == "extra":
			var extra = Decal.new()
			extra.texture_albedo = decal.texture_albedo
			extra.size = Vector3(800, 24, 800)
			extra.upper_fade = 0.0
			extra.lower_fade = 0.0
			extra.modulate = Color(1, 1, 1, 0.55)
			match_node.add_child(extra)
			extra.global_position = Vector3(float(_args.get("dx", "60")), 9, float(_args.get("dz", "60")))
		if _args["debug_atmosphere"] == "move":
			decal.reparent(match_node)
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
	for _i in range(count):
		await get_tree().process_frame
