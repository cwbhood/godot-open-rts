extends Node

# Saving and loading the way a player does it: F5 quicksave and F9 quickload, Save game and
# Load game in the pause menu, and Continue / Load game in the main menu. Each load must
# start a match with the same units as the one saved. Takes screenshots of the windows.
# Usage (needs a renderer):
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
#     res://tests/save/SaveMenuCheck.tscn -- --out=/tmp/save-shots --no-build-up
# The longer check that a loaded match plays on is the play harness scenario save-load.
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const LoadingScene = preload("res://source/main-menu/Loading.tscn")
const SaveGame = preload("res://source/match/SaveGame.gd")
const SaveLoadPanel = preload("res://source/main-menu/SaveLoadPanel.gd")
const SETTINGS_SOURCE = "res://tests/manual/TestOneCityOneRival.tscn"
const MAP_PATH = "res://source/match/maps/PlainAndSimple.tscn"
const TEST_SAVE = "menu check"

var _out = "user://save-shots"
var _failures = 0
var _loaded = 0
var _count_on_load = -1  # units right when the save was put back, before the match runs on


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	MatchSignals.match_loaded.connect(_on_match_loaded)
	var had_quicksave = FileAccess.file_exists(SaveGame.path_of(SaveGame.QUICKSAVE_NAME))
	await _frames(5)
	var a_match = await _start_match()
	await _quicksave_and_load(a_match)
	if not had_quicksave:
		SaveGame.delete(SaveGame.path_of(SaveGame.QUICKSAVE_NAME))
	SaveGame.delete(SaveGame.path_of(TEST_SAVE))
	print("DONE failures=", _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _quicksave_and_load(a_match):
	await get_tree().create_timer(4.0).timeout  # the cities raise their defense first
	var count = _unit_count()
	_press(KEY_F5)
	await _frames(3)
	_check(
		"F5 writes the quicksave", FileAccess.file_exists(SaveGame.path_of(SaveGame.QUICKSAVE_NAME))
	)
	_check("a note says the game was saved", _note_visible())
	await _shot("1-quicksave-note")

	var menu = a_match.find_child("Menu", true, false)
	_press(KEY_ESCAPE)
	await _frames(3)
	_check("the pause menu has Save game", menu.find_child("SaveButton", true, false) != null)
	_check("the pause menu has Load game", menu.find_child("LoadButton", true, false) != null)
	await _shot("2-pause-menu")
	var panel = menu.open_save_load(SaveLoadPanel.Mode.SAVE)
	await _frames(2)
	panel.find_child("SaveName", true, false).text = TEST_SAVE
	await _shot("3-save-window")
	panel._on_action()
	await _frames(3)
	_check("Save game writes the named save", FileAccess.file_exists(SaveGame.path_of(TEST_SAVE)))
	_check("the pause menu is back after saving", menu.visible and get_tree().paused)

	panel = menu.open_save_load(SaveLoadPanel.Mode.LOAD)
	await _frames(2)
	var names = panel._saves.map(func(save): return save["name"])
	_check("the load window lists the save", TEST_SAVE in names)
	panel._list.select(names.find(TEST_SAVE))
	await _shot("4-load-window")
	var loaded_before = _loaded
	panel._on_action()
	var loaded = await _wait_for_match(a_match)
	_check("Load game starts the saved match", loaded != null and _loaded == loaded_before + 1)
	_check("the loaded match is not paused", not get_tree().paused)
	_check(
		"the loaded match has the same units (%d, loaded %d)" % [count, _count_on_load],
		_count_on_load == count
	)
	await _shot("5-loaded")

	loaded_before = _loaded
	_press(KEY_F9)
	var quick = await _wait_for_match(loaded)
	_check("F9 loads the quicksave", quick != null and _loaded == loaded_before + 1)
	_check(
		"the quickloaded match has the same units (%d, loaded %d)" % [count, _count_on_load],
		_count_on_load == count
	)

	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
	await _frames(20)
	var main = get_tree().current_scene
	_check("the main menu has Continue", main.find_child("ContinueButton", true, false) != null)
	_check("the main menu has Load game", main.find_child("LoadButton", true, false) != null)
	main._open_load()
	await _frames(3)
	await _shot("6-main-menu-load")
	main.find_child("LoadButton", true, false).grab_focus()


func _on_match_loaded():
	_loaded += 1
	_count_on_load = _unit_count()


func _start_match():
	var loading = LoadingScene.instantiate()
	var source = load(SETTINGS_SOURCE).instantiate()
	loading.match_settings = source.settings.duplicate(true)
	source.free()
	loading.map_path = MAP_PATH
	get_tree().root.add_child(loading)
	get_tree().current_scene = loading
	return await _wait_for_match(null)


func _wait_for_match(previous):
	for _i in range(900):
		await get_tree().process_frame
		var scene = get_tree().current_scene
		if (
			scene != null
			and scene != previous
			and is_instance_valid(scene)
			and scene.name.begins_with("Match")
			and scene.is_node_ready()
		):
			await _frames(30)
			return scene
	return null


func _unit_count():
	return (
		get_tree()
		. get_nodes_in_group("units")
		. filter(func(unit): return not unit.is_queued_for_deletion())
		. size()
	)


func _note_visible():
	var note = get_tree().root.find_child("SaveNote", true, false)
	return note != null and note.visible


func _press(keycode):
	var event = InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = true
	Input.parse_input_event(event)
	var release = event.duplicate()
	release.pressed = false
	Input.parse_input_event(release)


func _shot(shot_name):
	await _frames(6)
	await RenderingServer.frame_post_draw
	var path = "{0}/{1}.png".format([_out, shot_name])
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _check(text, ok):
	print(("PASS " if ok else "FAIL ") + text)
	if not ok:
		_failures += 1


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
