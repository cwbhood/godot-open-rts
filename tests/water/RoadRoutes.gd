extends Node

# Supply roads on Twin Isles (data/maps/twin_isles.json), from a depot on the home island:
# - HOME: a mine on the same island gets a road that never touches water,
# - FORD: a mine on the centre island gets a road that runs over the shallow ford as a
#   raised causeway and never over deep water,
# - ISLET: a mine on the lookout islet (deep water all round) has no depot trucks can
#   reach and no road.
#
#   godot --headless --path . res://tests/water/RoadRoutes.tscn
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . res://tests/water/RoadRoutes.tscn -- --shots=/tmp/roads
#
# Prints "ROADS ok ..." / "ROADS FAIL ..." per check and exits 1 on any failure.

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const GameData = preload("res://source/data-model/GameData.gd")
const WaterLayout = preload("res://source/match/maps/WaterLayout.gd")
const CC_SCENE = "res://source/match/units/CommandCenter.tscn"
const MINE_SCENE = "res://source/match/units/Mine.tscn"

const DEPOT = Vector3(40, 0, 126)
const HOME_MINE = Vector3(36, 0, 102)
const FORD_MINE = Vector3(66, 0, 80)
const ISLET_MINE = Vector3(26, 0, 38)

var _args = {}
var _match = null
var _failures = 0


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	GameData.register_generated_scenes()
	FeatureFlags.handle_match_end = false
	var settings = MatchSettings.new()
	var human = PlayerSettings.new()
	human.controller = Constants.PlayerType.HUMAN
	human.color = Constants.Player.COLORS[0]
	settings.players.append(human)
	settings.visible_player = 0
	settings.visibility = MatchSettings.Visibility.FULL
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/TwinIsles.tscn").instantiate()
	add_child(_match)
	for _i in range(40):
		await get_tree().physics_frame
	await _run()
	print("road routes: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _run():
	var player = get_tree().get_nodes_in_group("players")[0]
	var logistics = player.get_node("Logistics")
	var roads = _match.find_child("RoadVisuals", true, false)
	var water = _match.map.water
	_spawn(CC_SCENE, DEPOT, player)
	var mines = {
		"home": _spawn(MINE_SCENE, HOME_MINE, player),
		"ford": _spawn(MINE_SCENE, FORD_MINE, player),
		"islet": _spawn(MINE_SCENE, ISLET_MINE, player),
	}
	# the land map is rebaked after the buildings go up; roads are refreshed every second
	for _i in range(300):
		await get_tree().physics_frame
		if (
			not roads.get_route_runs(mines.home).is_empty()
			and not roads.get_route_runs(mines.ford).is_empty()
		):
			break
	for _i in range(90):
		await get_tree().process_frame
	var home_depot = logistics.closest_depot(HOME_MINE)
	var ford_depot = logistics.closest_depot(FORD_MINE)
	_check(home_depot != null, "the home mine is served by a depot")
	_check(ford_depot != null, "the centre mine is served over the ford")
	if ford_depot == null:
		return
	_check(
		logistics.closest_depot(ISLET_MINE) == null,
		"the islet mine has no depot trucks can drive to"
	)
	var home = _describe(roads.get_route_runs(mines.home), water)
	_check(home.length > 10.0, "the home mine has a road (%.0f m)" % home.length)
	_check(home.wet_m == 0.0 and home.deep == 0, "the home road stays on land")
	var ford = _describe(roads.get_route_runs(mines.ford), water)
	_check(ford.length > 20.0, "the centre mine has a road (%.0f m)" % ford.length)
	_check(ford.deep == 0, "the centre road never lies on deep water (%d points)" % ford.deep)
	_check(
		ford.wet_m > 3.0 and ford.causeway_shallow,
		"it crosses the ford on a causeway (%.0f m)" % ford.wet_m
	)
	_check(ford.dry_in_water == 0, "no plain road on water (%d points)" % ford.dry_in_water)
	_check(roads.get_route_runs(mines.islet).is_empty(), "the islet mine gets no road")
	await _shoot("ford-causeway", Vector3(62, 0, 98), 22.0)
	await _shoot("home-road", (DEPOT + HOME_MINE) * 0.5, 22.0)


func _describe(runs, water):
	var out = {"length": 0.0, "wet_m": 0.0, "deep": 0, "dry_in_water": 0, "causeway_shallow": true}
	for run in runs:
		var points = run.points
		for i in range(points.size()):
			var depth = water.depth_fast(points[i])
			if depth == WaterLayout.Depth.DEEP:
				out.deep += 1
			var shared = i == 0 and run != runs[0]  # the joint with the run before
			if not run.wet and not shared and depth != WaterLayout.Depth.LAND:
				out.dry_in_water += 1
			if i > 0:
				var step = points[i - 1].distance_to(points[i])
				out.length += step
				if run.wet:
					out.wet_m += step
	return out


func _shoot(name, at, size):
	if not _args.has("shots") or DisplayServer.get_name() == "headless":
		return
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(size)
	camera.set_position_safely(at)
	for _i in range(5):
		await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute(_args["shots"])
	var path = "{0}/{1}.png".format([_args["shots"], name])
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _spawn(scene_path, position, player):
	var unit = load(scene_path).instantiate()
	unit.set_meta("spawn_constructed", true)
	MatchSignals.setup_and_spawn_unit.emit(unit, Transform3D(Basis(), position), player)
	return unit


func _check(ok, text):
	print("ROADS ", "ok " if ok else "FAIL ", text)
	if not ok:
		_failures += 1
