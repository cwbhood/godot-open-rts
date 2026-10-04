extends Node

# Movement on water, on Twin Isles (data/maps/twin_isles.json):
# - LAND_BLOCKED: a tank sent to a lookout islet (no ford) never enters deep water and
#   stops on the shore,
# - FORD: a tank wades the shallow ford to the centre island, slowed while in the water,
# - AMPHIBIOUS: an amphibious APC drives into the sea, swims to the islet and climbs out,
#   sinking into the water and rising again smoothly,
# - BOAT: a patrol boat sails around the islands without ever touching land,
# - FRAME TIME: physics/process time per frame while all of that runs, and the main
#   thread cost of a navigation rebake (land map plus the amphibious map) after a
#   structure appears.
#
#   godot --headless --path . res://tests/water/WaterMovement.tscn
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . res://tests/water/WaterMovement.tscn -- --shots=/tmp/water
#
# Prints one line per check ("WATER ok ..." / "WATER FAIL ...") and a frame time summary,
# writes report.json to --out (default user://water_test) and exits 1 on any failure.

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const GameData = preload("res://source/data-model/GameData.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const WaterLayout = preload("res://source/match/maps/WaterLayout.gd")
const TankScene = "res://source/match/units/Tank.tscn"
const TurretScene = "res://source/match/units/AntiGroundTurret.tscn"

const ISLET = Vector3(26, 0, 38)  # no ford: land units cannot get there
const CENTRE = Vector3(84, 0, 76)
const BOAT_GOAL = Vector3(150, 0, 10)  # past the far side of the enemy island
const TIMEOUT_S = 75.0

var _args = {}
var _match = null
var _results = []
var _tracks = {}  # name -> {unit, depths: {depth: frames}, ...}
var _frame_ms = []
var _physics_ms = []
var _shots_taken = {}


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
	_finish()


func _run():
	var player = get_tree().get_nodes_in_group("players")[0]
	var map = _match.map
	_check(map.has_water(), "map has water", "Twin Isles has no water layout")
	var apc_scene = GameData.unit_by_id("amphibious_apc")["scene"]
	var boat_scene = GameData.unit_by_id("patrol_boat")["scene"]
	var blocked = _spawn(TankScene, Vector3(30, 0, 104), player)
	var wader = _spawn(TankScene, Vector3(44, 0, 112), player)
	var apc = _spawn(apc_scene, Vector3(30, 0, 98), player)
	var boat = _spawn(boat_scene, Vector3(80, 0, 128), player)
	for _i in range(10):
		await get_tree().physics_frame
	_check(
		(
			boat.navigation_domain == Constants.Match.Navigation.Domain.WATER
			and apc.navigation_domain == Constants.Match.Navigation.Domain.AMPHIBIOUS
			and boat.movement_domain == Constants.Match.Navigation.Domain.TERRAIN
		),
		"domains",
		"boat {0}/{1}, apc {2}".format(
			[boat.navigation_domain, boat.movement_domain, apc.navigation_domain]
		)
	)
	_track("land_blocked", blocked, ISLET)
	_track("ford", wader, CENTRE)
	_track("amphibious", apc, ISLET)
	_track("boat", boat, BOAT_GOAL)
	var started = Time.get_ticks_msec()
	var game_time = 0.0
	while game_time < TIMEOUT_S:
		await get_tree().physics_frame
		game_time += 1.0 / Engine.physics_ticks_per_second
		_sample()
		if _tracks.values().all(func(track): return track.done):
			break
	print(
		"ran {0} s of game time in {1} s".format(
			[snappedf(game_time, 0.1), (Time.get_ticks_msec() - started) / 1000.0]
		)
	)
	_judge(map)
	await _check_rebake(player)


func _spawn(scene_path, position, player):
	var unit = load(scene_path).instantiate()
	MatchSignals.setup_and_spawn_unit.emit(unit, Transform3D(Basis(), position), player)
	return unit


func _track(name, unit, goal):
	unit.action = Moving.new(goal)
	_tracks[name] = {
		"unit": unit,
		"goal": goal,
		"depths": {0: 0, 1: 0, 2: 0},
		"done": false,
		"idle_frames": 0,
		"last": unit.global_position,
		"speed_land": [],
		"speed_shallow": [],
		"speed_deep": [],
		"offsets": [],
		"max_offset_step": 0.0,
		"path_length": 0.0,
	}


func _sample():
	_frame_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	var delta = 1.0 / Engine.physics_ticks_per_second
	for name in _tracks:
		var track = _tracks[name]
		var unit = track.unit
		if not is_instance_valid(unit) or track.done:
			continue
		var position = unit.global_position
		var depth = _match.map.water_depth_at(position)
		track.depths[depth] += 1
		var step = (position - track.last) * Vector3(1, 0, 1)
		track.path_length += step.length()
		var speed = step.length() / delta
		if speed > 0.05:
			track[["speed_land", "speed_shallow", "speed_deep"][depth]].append(speed)
		var geometry = unit.find_child("Geometry", false)
		if geometry != null:
			if not track.offsets.is_empty():
				track.max_offset_step = max(
					track.max_offset_step, abs(geometry.position.y - track.offsets[-1])
				)
			track.offsets.append(geometry.position.y)
		track.last = position
		track.idle_frames = track.idle_frames + 1 if speed < 0.02 else 0
		if not unit.action is Moving and track.idle_frames > 30:
			track.done = true
		_maybe_shoot(name, unit, depth)


func _judge(map):
	var land = _tracks.land_blocked
	_check(land.depths[2] == 0, "land unit never enters deep water", _describe(land))
	_check(
		land.unit.global_position.distance_to(ISLET) > 7.0 and land.done,
		"land unit stops on the shore when the target is cut off by deep water",
		_describe(land)
	)
	var ford = _tracks.ford
	_check(ford.depths[2] == 0, "ford: no deep water", _describe(ford))
	_check(ford.depths[1] > 0, "ford: wades shallow water", _describe(ford))
	_check(
		ford.unit.global_position.distance_to(CENTRE) < 3.0,
		"ford: reaches the centre island",
		_describe(ford)
	)
	var wading = _median(ford.speed_shallow) / max(_median(ford.speed_land), 0.01)
	_check(
		abs(wading - Constants.Match.Water.SHALLOW_WADING_SPEED_FACTOR) < 0.15,
		"ford: slowed to {0} of land speed in shallow water".format([snappedf(wading, 0.01)]),
		_describe(ford)
	)
	var apc = _tracks.amphibious
	_check(apc.depths[2] > 0, "amphibious: swims through deep water", _describe(apc))
	_check(
		apc.unit.global_position.distance_to(ISLET) < 4.0,
		"amphibious: reaches the islet",
		_describe(apc)
	)
	var deepest = apc.offsets.min() if not apc.offsets.is_empty() else 0.0
	_check(
		(
			deepest < Constants.Match.Water.FLOAT_OFFSET_DEEP * 0.7
			and abs(apc.offsets[-1] - apc.offsets[0]) < 0.06
		),
		"amphibious: sinks to {0} m in the sea and is back on its wheels ashore".format(
			[snappedf(deepest, 0.01)]
		),
		_describe(apc)
	)
	_check(
		apc.max_offset_step < 0.03,
		"amphibious: smooth shore transition (max {0} m per tick)".format(
			[snappedf(apc.max_offset_step, 0.001)]
		),
		_describe(apc)
	)
	var swim = _median(apc.speed_deep) / max(_median(apc.speed_land), 0.01)
	_check(
		swim < 0.95 and swim > 0.6,
		"amphibious: swims at {0} of its land speed".format([snappedf(swim, 0.01)]),
		_describe(apc)
	)
	var boat = _tracks.boat
	_check(boat.depths[0] == 0, "boat never touches land", _describe(boat))
	_check(
		boat.unit.global_position.distance_to(BOAT_GOAL) < 4.0,
		"boat sails around the islands to the far side",
		_describe(boat)
	)
	var direct = Vector3(80, 0, 128).distance_to(BOAT_GOAL)
	print("boat path {0} m, straight line {1} m".format([int(boat.path_length), int(direct)]))
	print(
		"amphibious path {0} m, land unit path {1} m".format(
			[int(apc.path_length), int(land.path_length)]
		)
	)


func _check_rebake(player):
	"""main-thread cost of a navigation rebake: parsing structures for the land map, and
	the extra work of handing them to the amphibious map (its bake runs on a thread)"""
	var terrain = _match.navigation.terrain
	var amphibious = _match.navigation.amphibious
	var turret = load(TurretScene).instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		turret, Transform3D(Basis(), Vector3(46, 0, 128)), player
	)
	await _wait_for_bake(terrain)
	var samples_land = []
	var samples_both = []
	for _i in range(5):
		terrain.obstacles_parsed.disconnect(amphibious.rebake_with)
		terrain._is_baking = true  # as TerrainNavigation._process does before a rebake
		var started = Time.get_ticks_usec()
		terrain._rebake()
		samples_land.append((Time.get_ticks_usec() - started) / 1000.0)
		await _wait_for_bake(terrain)
		terrain.obstacles_parsed.connect(amphibious.rebake_with)
		terrain._is_baking = true
		started = Time.get_ticks_usec()
		terrain._rebake()
		samples_both.append((Time.get_ticks_usec() - started) / 1000.0)
		await _wait_for_bake(terrain)
	var land_ms = _median(samples_land)
	var both_ms = _median(samples_both)
	print(
		"REBAKE main thread: land map {0} ms, land + amphibious {1} ms".format(
			[snappedf(land_ms, 0.01), snappedf(both_ms, 0.01)]
		)
	)
	_check(
		both_ms - land_ms < 2.0,
		"rebake: amphibious map adds {0} ms on the main thread".format(
			[snappedf(both_ms - land_ms, 0.01)]
		),
		""
	)
	_results.append({"name": "rebake_ms", "land": land_ms, "land_and_amphibious": both_ms})


func _wait_for_bake(terrain):
	for _i in range(600):
		await get_tree().physics_frame
		if not terrain._is_baking and not _match.navigation.amphibious._is_baking:
			return


func _maybe_shoot(name, unit, depth):
	"""with --shots=DIR, saves a picture of each unit the first time it is in water"""
	if not _args.has("shots") or DisplayServer.get_name() == "headless":
		return
	var key = name + str(depth)
	if key in _shots_taken or depth == 0 and name != "land_blocked":
		return
	if name == "land_blocked" and not _tracks[name].done:
		return
	_shots_taken[key] = true
	_shoot.call_deferred(name, unit, depth)


func _shoot(name, unit, depth):
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(float(_args.get("size", "14")))
	camera.set_position_safely(unit.global_position)
	for _i in range(3):
		await get_tree().process_frame
	DirAccess.make_dir_recursive_absolute(_args["shots"])
	var path = "{0}/{1}_{2}.png".format([_args["shots"], name, ["land", "shallow", "deep"][depth]])
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _describe(track):
	var movement = track.unit.find_child("Movement")
	return (
		"at {0}, frames on land/shallow/deep {1}, path {2} m, action {3}, finished {4}, idle {5}"
		. format(
			[
				track.unit.global_position.snapped(Vector3.ONE * 0.1),
				track.depths,
				int(track.path_length),
				track.unit.action,
				movement.is_navigation_finished(),
				track.idle_frames,
			]
		)
	)


func _median(values):
	if values.is_empty():
		return 0.0
	var sorted = values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _check(ok, what, details):
	_results.append({"name": what, "ok": ok, "details": details})
	print(("WATER ok " if ok else "WATER FAIL ") + what + ("" if ok else " (" + details + ")"))


func _finish():
	var physics = _physics_ms.duplicate()
	physics.sort()
	var frame = _frame_ms.duplicate()
	frame.sort()
	var summary = {
		"physics_ms_avg": _avg(_physics_ms),
		"physics_ms_p95": physics[int(physics.size() * 0.95)] if not physics.is_empty() else 0.0,
		"physics_ms_max": physics[-1] if not physics.is_empty() else 0.0,
		"process_ms_avg": _avg(_frame_ms),
		"process_ms_p95": frame[int(frame.size() * 0.95)] if not frame.is_empty() else 0.0,
	}
	var lookups = 100000
	var started = Time.get_ticks_usec()
	for i in range(lookups):
		_match.map.water_depth_at(Vector3(i % 160, 0, (i * 7) % 160))
	summary["water_lookup_us"] = float(Time.get_ticks_usec() - started) / lookups
	print("FRAME TIME ", summary)
	_check(
		summary.water_lookup_us < 5.0,
		"water lookup costs {0} us per unit per tick".format(
			[snappedf(summary.water_lookup_us, 0.01)]
		),
		str(summary)
	)
	_check(
		summary.physics_ms_p95 < 16.7,
		"frame time: physics p95 {0} ms (budget 16.7 ms per tick)".format(
			[snappedf(summary.physics_ms_p95, 0.01)]
		),
		str(summary)
	)
	var out_dir = _args.get("out", "user://water_test")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var file = FileAccess.open(out_dir + "/report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": _results, "frame_time": summary}, "  "))
	file.close()
	var failed = _results.filter(func(result): return result.get("ok") == false)
	print(
		"WATER {0} checks, {1} failed".format(
			[_results.filter(func(r): return "ok" in r).size(), failed.size()]
		)
	)
	get_tree().quit(1 if not failed.is_empty() else 0)


func _avg(values):
	if values.is_empty():
		return 0.0
	var total = 0.0
	for value in values:
		total += value
	return total / values.size()
