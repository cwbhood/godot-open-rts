extends Node

# Screenshots of every options tab (main menu version) and of the pause menu in a match,
# plus a few checks of the pause menu (pauses the game, Esc closes the options first,
# surrender ends the match as a defeat).
# Usage (needs a real renderer; the window is fullscreen by default, so match the screen):
#   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --resolution 1920x1080 \
#     res://tests/options/OptionsShots.tscn -- --out=/tmp/options --suffix=1080p --no-build-up
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const OptionsScene = preload("res://source/main-menu/Options.tscn")
const LoadingScene = preload("res://source/main-menu/Loading.tscn")
# match settings borrowed from a manual test scene; loaded only while copying them, since
# holding that scene would keep Match.tscn (and its baked navmeshes) cached across restarts
const SETTINGS_SOURCE = "res://tests/manual/TestOneCityOneRival.tscn"
const MAP_PATH = "res://source/match/maps/PlainAndSimple.tscn"
const TABS = ["audio", "video", "interface", "camera", "controls"]

var _out = "user://options-shots"
var _suffix = ""
var _failures = 0
var _options_only = false


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--suffix="):
			_suffix = "_" + arg.trim_prefix("--suffix=")
		elif arg.begins_with("--ui-scale="):  # not saved: Options' setter applies it
			Globals.options.ui_scale = float(arg.trim_prefix("--ui-scale="))
		elif arg == "--options-only":
			_options_only = true
	DirAccess.make_dir_recursive_absolute(_out)
	await _frames(5)
	await _options_screen()
	if not _options_only:
		await _pause_menu()
	print("DONE failures=", _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _options_screen():
	var options = OptionsScene.instantiate()
	add_child(options)
	for index in range(TABS.size()):
		options.select_tab(index)
		await _shot("options_" + TABS[index])
	options.find_child("ResetDialog", true, false).popup_centered()
	await _shot("options_reset_confirm")
	options.find_child("ResetDialog", true, false).hide()
	var panel = options.find_child("Panel", true, false)
	_check(
		"options panel fits the window",
		get_viewport().get_visible_rect().encloses(panel.get_global_rect())
	)
	options.queue_free()
	await _frames(2)


func _pause_menu():
	var a_match = await _start_match()
	_check_quality_preset(a_match)
	var menu = a_match.find_child("Menu", true, false)
	_press_escape()
	await _frames(3)
	_check("Esc opens the pause menu", menu.visible)
	_check("the pause menu pauses the game", get_tree().paused)
	await _shot("pause_menu")
	var options = menu.open_options()
	await _frames(2)
	options.select_tab(1)
	await _shot("pause_options_video")
	_check("Video tab is visible", options.find_child("Tabs", true, false).current_tab == 1)
	_press_escape()
	await _frames(3)
	_check(
		"Esc closes the options first",
		not is_instance_valid(options) or not options.is_inside_tree()
	)
	_check("the menu stays open after closing the options", menu.visible and get_tree().paused)
	menu._on_exit_button_pressed()
	await _shot("pause_exit_confirm")
	menu.find_child("ConfirmDialog", true, false).hide()
	_press_escape()
	await _frames(3)
	_check("Esc closes the pause menu", not menu.visible)
	_check("closing the menu resumes the game", not get_tree().paused)
	_press_escape()
	await _frames(3)
	menu._restart()
	var restarted = await _wait_for_match(a_match)
	_check("restart starts a new match", restarted != null and restarted != a_match)
	_check("restart unpauses", not get_tree().paused)
	_check("the old match is gone", not is_instance_valid(a_match))
	a_match = restarted
	menu = a_match.find_child("Menu", true, false)
	_press_escape()
	await _frames(3)
	menu._surrender()
	await _frames(5)
	var end = a_match.find_child("MatchEndHandler", true, false)
	_check("surrender shows the defeat screen", end != null and end.visible)
	_check("surrender shows Defeat", end != null and end.find_child("Defeat").visible)
	await _shot("surrender_defeat")


func _check_quality_preset(a_match):
	var environment = a_match.find_child("WorldEnvironment", true, false).environment
	var light = a_match.find_child("DirectionalLight3D", true, false)
	var before = Globals.options.graphics_quality
	var scene_ssao = environment.ssao_enabled
	var scene_mode = light.directional_shadow_mode
	Globals.options.graphics_quality = Globals.options.Quality.LOW  # not saved
	_check("Low quality turns ambient occlusion off", not environment.ssao_enabled)
	_check("Low quality turns glow off", not environment.glow_enabled)
	_check(
		"Low quality uses one shadow split",
		light.directional_shadow_mode == DirectionalLight3D.SHADOW_ORTHOGONAL
	)
	Globals.options.graphics_quality = Globals.options.Quality.ULTRA
	_check("Ultra restores the scene's ambient occlusion", environment.ssao_enabled == scene_ssao)
	_check("Ultra restores the scene's shadow splits", light.directional_shadow_mode == scene_mode)
	Globals.options.graphics_quality = before


func _start_match():
	var loading = LoadingScene.instantiate()
	loading.match_settings = _copy_settings()
	loading.map_path = MAP_PATH
	get_tree().root.add_child(loading)
	get_tree().current_scene = loading
	return await _wait_for_match(null)


func _copy_settings():
	var source = load(SETTINGS_SOURCE).instantiate()
	var settings = source.settings.duplicate(true)
	source.free()
	return settings


func _wait_for_match(previous):
	for _i in range(600):
		await get_tree().process_frame
		var scene = get_tree().current_scene
		if scene != null and scene != previous and scene.name == "Match" and scene.is_node_ready():
			await _frames(60)
			return scene
	return null


func _press_escape():
	var event = InputEventKey.new()
	event.physical_keycode = KEY_ESCAPE
	event.keycode = KEY_ESCAPE
	event.pressed = true
	Input.parse_input_event(event)
	var release = event.duplicate()
	release.pressed = false
	Input.parse_input_event(release)


func _shot(shot_name):
	await _frames(6)
	await RenderingServer.frame_post_draw
	var path = "{0}/{1}{2}.png".format([_out, shot_name, _suffix])
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _check(text, ok):
	print(("PASS " if ok else "FAIL ") + text)
	if not ok:
		_failures += 1


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
