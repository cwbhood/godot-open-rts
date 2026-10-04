extends Node

# Checks the starter city build-up (source/match/city/CityBuildUp.gd) in a real match and
# saves frames of it. Needs a renderer, e.g. under xvfb-run:
#   godot --path . res://tests/buildup/BuildUpCheck.tscn -- --out=/tmp/buildup
# Options: --scene=res://tests/manual/TestDesert.tscn, --frames=0.1 (seconds between saved
# frames; the animation is stepped by seeking, so the frames do not depend on frame rate),
# --skip (end it with a Space key press instead of letting it play out), --size=11 (camera).
# Prints PASS/FAIL lines and exits with code 1 on any failure.

const Structure = preload("res://source/match/units/Structure.gd")

var _args = {}
var _failures = 0


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var out_dir = _args.get("out", "user://buildup")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var match_node = load(_args.get("scene", "res://tests/manual/TestDesert.tscn")).instantiate()
	match_node.play_city_build_up = true
	match_node.process_mode = Node.PROCESS_MODE_PAUSABLE  # this checker runs through the pause
	add_child(match_node)
	await _frames(3)

	var build_up = match_node.get_node("CityBuildUp")
	var human = match_node.visible_player
	var command_center = _first_command_center(human)
	var rig = command_center.find_child("CityBuildUp", true, false)
	var model = command_center.find_child("Model", true, false)
	var animation_player = rig.find_child("AnimationPlayer", true, false) if rig else null
	_check(build_up.playing, "build-up is playing at match start")
	_check(get_tree().paused, "the match is paused while it plays")
	_check(rig != null and rig.visible, "the construction site is shown at the command centre")
	_check(model == null or not model.visible, "the finished command centre is hidden")
	_check(
		_own_units(human).filter(func(u): return not u.visible).size() >= 4,
		"the starting units wait out of sight"
	)
	var ticks_before = human.get_node("City")._elapsed_s
	var stock_before = human.get_stock().duplicate()

	# frames: step through the animation by seeking, so lavapipe's low frame rate does not
	# matter; the camera looks at the command centre as in a normal start
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(float(_args.get("size", "11")))
	camera.set_position_safely(command_center.global_position)
	animation_player.speed_scale = 0.0
	var step = float(_args.get("frames", "0.1"))
	var length = animation_player.current_animation_length
	var index = 0
	var t = 0.0
	while t < length - 0.05:  # the last frame would end it
		animation_player.seek(t, true)
		await _frames(2)
		var image = get_viewport().get_texture().get_image()
		image.save_png("{0}/frame_{1}.png".format([out_dir, "%03d" % index]))
		index += 1
		t += step
	print("saved {0} frames to {1}".format([index, out_dir]))

	_check(
		human.get_node("City")._elapsed_s == ticks_before,
		"the city economy did not tick during the build-up"
	)
	_check(human.get_stock() == stock_before, "no resources were gathered or spent meanwhile")

	if _args.has("skip"):
		animation_player.speed_scale = 1.0
		var key = InputEventKey.new()
		key.keycode = KEY_SPACE
		key.pressed = true
		Input.parse_input_event(key)
		await _frames(3)
	else:
		animation_player.speed_scale = 1.0
		animation_player.seek(length - 0.3, true)
		var started_ms = Time.get_ticks_msec()
		while build_up.playing and Time.get_ticks_msec() - started_ms < 20000:
			await get_tree().process_frame
		await _frames(2)
	_check(not build_up.playing, "the build-up ended" + (" on Space" if _args.has("skip") else ""))
	_check(not get_tree().paused, "the match runs again")
	_check(
		not is_instance_valid(rig) or rig.is_queued_for_deletion(), "cranes and workers are removed"
	)
	_check(model == null or model.visible, "the real command centre took over")
	_check(_own_units(human).all(func(u): return u.visible), "the starting units are back")
	_check(match_node.get_node("HUD").visible, "the HUD is back")
	await _frames(int(_args.get("after_frames", "30")))
	_check(
		human.get_node("City")._elapsed_s > ticks_before,
		"the city economy started ticking afterwards"
	)
	get_viewport().get_texture().get_image().save_png(out_dir + "/after.png")
	print("RESULT: ", "FAIL" if _failures > 0 else "PASS")
	get_tree().quit(1 if _failures > 0 else 0)


func _first_command_center(player):
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == player and unit.get_script().resource_path.ends_with("CommandCenter.gd"):
			return unit
	return null


func _own_units(player):
	return get_tree().get_nodes_in_group("units").filter(
		func(u): return u.player == player and not u is Structure
	)


func _check(ok, what):
	print(("PASS " if ok else "FAIL ") + what)
	if not ok:
		_failures += 1


func _frames(count):
	for i in range(count):
		await get_tree().process_frame
