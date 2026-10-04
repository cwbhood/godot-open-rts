extends Node

# Plays the pre-match start-zone screen like a player and checks the match that follows.
#
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . res://tests/start/StartZonesCheck.tscn \
#     -- --map=four_oases --players=4 --out=/tmp/start [--timeout]
#
# Opens the real Play menu, puts the human in slot 1 and AIs in the other slots, presses
# Start, takes screenshots of the start screen, clicks outside every zone (must be refused)
# and then inside one, starts the match and checks that the human's command center stands
# at the clicked spot and that no two players share a start zone. With --timeout it never
# clicks and checks that the countdown puts the human in their slot's zone.
# Prints PASS or FAIL lines and exits with code 1 on any failure.

const PlayScene = preload("res://source/main-menu/Play.tscn")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Human = preload("res://source/match/players/human/Human.gd")

var _args = {"map": "four_oases", "players": "4", "out": "/tmp/start", "timeout": "", "zone": "1"}
var _failures = 0


func _ready():
	for argument in OS.get_cmdline_user_args():
		var parts = argument.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else "yes"
	DirAccess.make_dir_recursive_absolute(_args["out"])
	await _run()
	print("start zones check: ", "FAIL" if _failures > 0 else "PASS")
	get_tree().quit(1 if _failures > 0 else 0)


func _run():
	var play = PlayScene.instantiate()
	get_tree().root.add_child.call_deferred(play)
	await _frames(5)
	var map_index = -1
	for index in range(play._map_paths.size()):
		if Constants.Match.MAPS[play._map_paths[index]].get("id", "") == _args["map"]:
			map_index = index
	_check(map_index != -1, "map {0} is in the Play menu".format([_args["map"]]))
	if map_index == -1:
		return
	play.find_child("MapList").select(map_index)
	play.find_child("MapList").item_selected.emit(map_index)
	var options = play.find_child("GridContainer").find_children("OptionButton*")
	for index in range(options.size()):
		var choice = Constants.PlayerType.NONE
		if index == 0:
			choice = Constants.PlayerType.HUMAN
		elif index < int(_args["players"]):
			choice = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		options[index].select(choice)
		options[index].item_selected.emit(choice)
	await _frames(2)
	play.find_child("StartButton").pressed.emit()
	var picker = null
	for _i in range(300):
		await _frames(1)
		picker = get_tree().root.get_node_or_null("StartPicker")
		if picker != null:
			break
	_check(picker != null, "the start screen opens after pressing Start")
	if picker == null:
		return
	await _frames(20)
	await _shot("1-start-screen")
	var zones = picker.get_start_zones()
	var overlay = picker.find_child("MapOverlay", true, false)
	var wanted_zone = clamp(int(_args["zone"]), 0, zones.size() - 1)
	var spot = zones[wanted_zone].center
	if _args["timeout"] == "":
		await _click(overlay, picker, Vector2(picker._map.size) / 2.0 + Vector2(3, 0))
		_check(picker._choice == null, "a click outside every start zone is refused")
		await _shot("2-click-outside-zone")
		var towards_center = (Vector2(picker._map.size) / 2.0 - spot).normalized()
		spot += towards_center * zones[wanted_zone].radius * 0.5
		await _click(overlay, picker, spot)
		_check(picker._choice != null, "a click inside a start zone places the city")
		if picker._choice != null:
			spot = picker._choice.position
		await _shot("3-city-placed")
		picker.find_child("StartMatchButton", true, false).pressed.emit()
	else:
		wanted_zone = 0  # the human sits in slot 1
		spot = zones[0].center
		picker._time_left = 2.0
	var a_match = null
	for _i in range(3000):
		await _frames(1)
		a_match = get_tree().root.get_node_or_null("Match")
		if a_match != null and a_match.is_node_ready():
			break
	_check(a_match != null, "the match starts")
	if a_match == null:
		return
	await _frames(30)
	_check_cities(zones, wanted_zone, spot)
	await _shot("4-match-start")


func _check_cities(zones, wanted_zone, spot):
	var zone_of_player = {}
	for unit in get_tree().get_nodes_in_group("units"):
		if not unit is CommandCenter:
			continue
		var position = Vector2(unit.global_position.x, unit.global_position.z)
		var zone = -1
		for index in range(zones.size()):
			if position.distance_to(zones[index].center) <= zones[index].radius + 0.5:
				zone = index
		_check(zone != -1, "{0}'s city stands inside a start zone".format([unit.player.name]))
		zone_of_player[unit.player] = zone
		if unit.player is Human:
			_check(zone == wanted_zone, "the human starts in zone {0}".format([wanted_zone + 1]))
			_check(
				position.distance_to(spot) < 0.5,
				"the human's city stands at the picked spot ({0} m off)".format(
					["%.2f" % position.distance_to(spot)]
				)
			)
	var used = zone_of_player.values()
	_check(used.size() == int(_args["players"]), "every player got a city")
	for zone in used:
		_check(used.count(zone) == 1, "zone {0} is used by one player only".format([zone + 1]))
	print("zones used: ", used.map(func(zone): return zone + 1))


func _click(overlay, picker, map_position):
	var local = map_position / Vector2(picker._map.size) * overlay.size
	var global = overlay.get_global_transform_with_canvas() * local
	for pressed in [true, false]:
		var event = InputEventMouseButton.new()
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		event.position = global
		event.global_position = global
		get_viewport().push_input(event)
		await _frames(2)


func _check(condition, what):
	print(("PASS " if condition else "FAIL ") + what)
	if not condition:
		_failures += 1


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame


func _shot(name):
	await RenderingServer.frame_post_draw
	var path = "{0}/{1}-{2}.png".format([_args["out"], _args["map"], name])
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)
