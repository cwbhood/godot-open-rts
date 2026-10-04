extends Node

# Checks the "Match rules" of the Play menu end to end: a Raw match must leave out the
# tutorial and tips, the AI assist and auto-building constructors, while plain unit
# orders (line, patrol) keep working. Saves screenshots of the menu and the start screen:
#
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --resolution 1600x900 \
#     res://tests/setup/MatchRulesCheck.tscn -- --out=/tmp/rules
#
# - Guided / Raw presets set the three boxes, changing one box shows Custom,
# - the choice reaches MatchSettings, is remembered for the next visit of the menu and is
#   shown on the start-zone screen,
# - in the Raw match: no tutorial, no hints, no helper panel, no auto-expand panel or
#   bar; G and H do nothing; scripts calling AutoExpand.set_enabled_on, adding an
#   AutoExpand node by hand or switching the helper on get nowhere,
# - unit orders still work: a patrol and a line order are carried out.
# Exits with code 1 when a check fails.

const PlayScene = preload("res://source/main-menu/Play.tscn")
const MatchRules = preload("res://source/data-model/MatchRules.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const AutoExpand = preload("res://source/match/units/traits/AutoExpand.gd")
const Helper = preload("res://source/match/players/human/Helper.gd")
const UnitCommands = preload("res://source/match/players/human/UnitCommands.gd")
const Patrolling = preload("res://source/match/units/actions/Patrolling.gd")

var _args = {"out": "user://rules-check", "map": "plain_and_simple"}
var _failures = []


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	DirAccess.make_dir_recursive_absolute(_args["out"])
	DirAccess.remove_absolute(MatchRules.SETTINGS_PATH)  # start as a new player would
	_check_outside_a_match()
	var play = await _open_menu()
	await _check_menu(play)
	await _start_raw(play)
	await _check_raw_match()
	await _check_menu_remembers()
	_report()


func _check_outside_a_match():
	_expect(MatchRules.allowed(null, "ai_assist"), "no match: everything is allowed")
	_expect(MatchRules.preset_of({}) == MatchRules.PRESET_GUIDED, "missing rules read as Guided")
	_expect(
		(
			MatchRules.preset_of({"tutorial": true, "ai_assist": false, "auto_build": true})
			== "custom"
		),
		"a mix of rules is Custom"
	)


func _open_menu():
	var play = PlayScene.instantiate()
	get_tree().root.add_child.call_deferred(play)
	await _frames(10)
	return play


func _check_menu(play):
	var options = play.get("_rules_options")
	_expect(options.preset_button.visible, "the Play menu shows the match rules")
	_expect(
		MatchRules.preset_of(options.rules()) == MatchRules.PRESET_GUIDED,
		"a new player starts on Guided"
	)
	await _frames(5)
	_screenshot("1-play-menu-guided.png")
	options.preset_button.show_popup()
	await _frames(5)
	_screenshot("2-rules-dropdown.png")
	options.preset_button.get_popup().hide()
	_pick_preset(options, MatchRules.PRESET_RAW)
	await _frames(3)
	_expect(options.rules().values().all(func(on): return not on), "Raw unticks all three boxes")
	_screenshot("3-play-menu-raw.png")
	options.check_boxes["tutorial"].button_pressed = true
	await _frames(3)
	_expect(
		options.preset_button.selected == options.PRESET_ORDER.find(MatchRules.PRESET_CUSTOM),
		"ticking one box shows Custom"
	)
	_screenshot("4-play-menu-custom.png")
	_pick_preset(options, MatchRules.PRESET_GUIDED)
	_expect(options.rules().values().all(func(on): return on), "Guided ticks all three boxes")
	_pick_preset(options, MatchRules.PRESET_RAW)


func _pick_preset(options, preset):
	var index = options.PRESET_ORDER.find(preset)
	options.preset_button.select(index)
	options.preset_button.item_selected.emit(index)


func _start_raw(play):
	var map_paths = play.get("_map_paths")
	for index in range(map_paths.size()):
		if map_paths[index].get_file().get_basename().to_snake_case() == _args["map"]:
			play.find_child("MapList").select(index)
			play.find_child("MapList").item_selected.emit(index)
	var options = play.find_child("GridContainer").find_children("OptionButton*")
	for slot in range(options.size()):
		if not options[slot].visible:
			continue
		var choice = Constants.PlayerType.NONE
		if slot == 0:
			choice = Constants.PlayerType.HUMAN
		elif slot == 1:
			choice = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		options[slot].select(choice)
		options[slot].item_selected.emit(choice)
	var settings = play.call("_create_match_settings")
	_expect(
		not settings.tutorial and not settings.ai_assist and not settings.auto_build,
		"Raw reaches MatchSettings"
	)
	play.find_child("StartButton").pressed.emit()
	var picker = null
	for _i in range(300):
		await _frames(1)
		picker = get_tree().root.get_node_or_null("StartPicker")
		if picker != null and picker.is_node_ready():
			break
	if picker == null:
		_expect(false, "the start-zone screen opened")
		return
	await _frames(20)
	var label = picker.find_child("MatchRulesLabel", true, false)
	_expect(
		label != null and tr("MATCH_RULES_PRESET_RAW") in label.text,
		"the start-zone screen shows the Raw rules (%s)" % (label.text if label else "no label")
	)
	_screenshot("5-start-screen-rules.png")
	picker.start_match()


func _check_raw_match():
	var match_node = null
	for _i in range(900):
		await _frames(1)
		match_node = get_tree().root.find_child("Match", true, false)
		if match_node != null and match_node.is_node_ready():
			break
	if match_node == null:
		_expect(false, "the match started")
		return
	await _frames(120)
	var human = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)[0]
	var guide = match_node.find_child("Guide", true, false)
	_expect(guide != null, "the guide (manual) is still there")
	_expect(not guide.find_child("Tutorial", true, false).visible, "no tutorial panel")
	for panel in ["HelperPanel", "AutoExpandPanel", "AutoExpandBar"]:
		_expect(match_node.find_child(panel, true, false) == null, "no %s in a Raw match" % panel)
	guide.show_hint("HINT_BLACKOUT")
	await _frames(5)
	_expect(not guide.find_child("Hint", true, false).visible, "hints stay hidden")
	_expect(guide.help_window != null, "the F1 manual is still available")

	var workers = _own(human, func(unit): return unit is Worker)
	_expect(not workers.is_empty(), "the player has constructors")
	if workers.is_empty():
		return
	var worker = workers[0]
	await _select([worker])
	await _key(KEY_G)
	await _frames(10)
	_expect(not AutoExpand.is_enabled_on(worker), "G does not start auto-expand")
	AutoExpand.set_enabled_on(worker, true)
	_expect(not AutoExpand.is_enabled_on(worker), "a script cannot switch auto-expand on")
	var sneaky = AutoExpand.new()
	sneaky.name = AutoExpand.NODE_NAME
	worker.add_child(sneaky)
	await _frames(5)
	_expect(not AutoExpand.is_enabled_on(worker), "an AutoExpand node added by hand removes itself")

	var helper = Helper.of(human)
	await _key(KEY_H)
	_expect(helper == null or not helper.enabled, "H does not switch the helper on")
	if helper != null:
		helper.enabled = true
		_expect(not helper.enabled, "a script cannot switch the helper on")
		helper.set("enabled", true)
		await _frames(5)
	_expect(Helper.active_for(human) == null, "the helper is not active")

	# plain unit orders are controls, not automation: they stay in Raw
	var target = worker.global_position + Vector3(4, 0, 0)
	UnitCommands.patrol([worker], [target, worker.global_position])
	await _frames(5)
	_expect(worker.action is Patrolling, "a patrol order still works")
	if workers.size() > 1:
		var from = workers[0].global_position + Vector3(0, 0, 4)
		var pairs = UnitCommands.line(workers, [from, from + Vector3(6, 0, 0)])
		_expect(pairs != null, "a line order still works")
	UnitCommands.stop(workers)
	var atmosphere = match_node.find_child("Atmosphere", true, false)
	if atmosphere != null:
		atmosphere.set_weather_immediately("clear")  # rain or a storm makes a black shot
	match_node.fog_of_war.reveal()
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(18.0)
	camera.set_position_safely(worker.global_position)
	await _frames(40)
	_screenshot("6-raw-match.png")
	match_node.queue_free()
	await _frames(10)


func _check_menu_remembers():
	var play = await _open_menu()
	var options = play.get("_rules_options")
	_expect(
		MatchRules.preset_of(options.rules()) == MatchRules.PRESET_RAW,
		"the menu remembers Raw for the next match"
	)
	_pick_preset(options, MatchRules.PRESET_GUIDED)  # leave the user's settings as new
	DirAccess.remove_absolute(MatchRules.SETTINGS_PATH)


func _own(player, filter):
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player and filter.call(unit)
	)


func _select(units):
	MatchSignals.deselect_all_units.emit()
	await _frames(1)
	for unit in units:
		unit.find_child("Selection").select()
	await _frames(3)


func _key(keycode):
	for state in [true, false]:
		var event = InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = state
		Input.parse_input_event(event)
		await _frames(2)


func _expect(condition, what):
	print(("PASS " if condition else "FAIL ") + what)
	if not condition:
		_failures.append(what)


func _report():
	print("%d check(s) failed" % _failures.size() if _failures else "all checks passed")
	get_tree().quit(1 if _failures else 0)


func _screenshot(file_name):
	var path = _args["out"].path_join(file_name)
	get_viewport().get_texture().get_image().save_png(path)
	print("screenshot ", ProjectSettings.globalize_path(path))


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
