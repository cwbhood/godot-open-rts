extends Node

# Staged movement test: sets up the crowd situations that make units run into each other or
# get stuck, plays them out and counts what went wrong. Needs a real renderer (navmeshes are
# baked from meshes), so run it under xvfb:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
#     res://tests/movement/MovementScenarios.tscn -- --out=/tmp/movement
#
# --scenario=perf runs the frame time probe instead (--units=120, --seconds=60).
# --shots=0 skips the frame strips, --seed=N changes the random start offsets, --crowd=0 turns
# the crowd steering of data/movement.json off. Results go to <out>/report.json and report.txt, and
# "MOVEMENT <scenario> ..." lines are printed for every scenario.
#
# What is counted, sampled every 0.25 s per scenario:
# - overlap: two ground units whose centres are closer than OVERLAP_FACTOR x (sum of radii),
#   i.e. they visibly sit inside each other. Reported in pair-seconds, peak and at the end.
# - stuck: a unit that has somewhere to go but moved less than STUCK_DISTANCE_M in the last
#   STUCK_WINDOW_S. Reported as units that got stuck at least once and total stuck seconds.
# - in building: a ground unit whose centre is inside a structure's footprint.
# - unfinished: units still trying to reach their destination when the scenario ends.

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const MovingToUnit = preload("res://source/match/units/actions/MovingToUnit.gd")
const Placement = preload("res://source/match/utils/UnitPlacementUtils.gd")
const MovementUtils = preload("res://source/match/utils/UnitMovementUtils.gd")
const Structure = preload("res://source/match/units/Structure.gd")

const TANK = "res://source/match/units/Tank.tscn"
const RAIDER = "res://source/match/units/Raider.tscn"
const MISSILE_TRUCK = "res://source/match/units/MissileTruck.tscn"
const ARTILLERY = "res://source/match/units/Artillery.tscn"
const MINE = "res://source/match/units/Mine.tscn"
const WORKER = "res://source/match/units/Worker.tscn"
const IRON_DEPOSIT = "res://source/match/units/non-player/IronDeposit.tscn"
const SOLAR_PLANT = "res://source/match/units/SolarPlant.tscn"
const VEHICLE_FACTORY = "res://source/match/units/VehicleFactory.tscn"
const MIX = [TANK, RAIDER, MISSILE_TRUCK, TANK, RAIDER, ARTILLERY]

const SAMPLE_S = 0.25
const OVERLAP_FACTOR = 0.9
const DEEP_OVERLAP_FACTOR = 0.6
const STUCK_WINDOW_S = 3.0
const STUCK_DISTANCE_M = 0.25

var _args = {"out": "user://movement", "scenario": "all", "shots": "1", "units": "120"}
var _args_seconds = 60.0
var _match = null
var _player = null
var _scenarios = []
var _elapsed = 0.0
var _next_sample = 0.0
var _frame_ms = []
var _physics_ms = []
var _last_frame_us = 0
var _skip_frame_timing = false
var _order_ms = []  # perf: how long ordering the whole army around took


class Scenario:
	var name = ""
	var center = Vector3.ZERO
	var units = []
	var structures = []
	var duration = 30.0
	var started_at = 0.0
	var finished = false
	var overlap_pair_s = 0.0
	var overlap_peak = 0
	var overlap_end = 0
	var deep_overlap_pair_s = 0.0
	var closest_ratio = 99.0
	var stuck_units = {}
	var stuck_s = 0.0
	var in_building_s = 0.0
	var settled_at = -1.0
	var unfinished = 0
	var reached = -1
	var history = {}  # unit -> [[t, position]]
	var spawn_queue = []  # [[t, callable]]
	var shots = []


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	_args_seconds = float(_args.get("seconds", "60"))
	seed(int(_args.get("seed", "1")))
	DirAccess.make_dir_recursive_absolute(_args["out"])
	var movement_script = load("res://source/match/units/traits/Movement.gd")
	if _args.has("crowd") and movement_script.has_method("settings"):
		movement_script.settings()["crowd_steering"] = _args["crowd"] == "1"
	if _args.has("movement") and movement_script.has_method("settings"):
		for pair in _args["movement"].split(","):  # e.g. --movement=path_requests_per_frame:8
			var key_value = pair.split(":")
			movement_script.settings()[key_value[0]] = str_to_var(key_value[1])
	preload("res://source/data-model/GameData.gd").register_generated_scenes()
	var settings = MatchSettings.new()
	var player_settings = PlayerSettings.new()
	player_settings.controller = Constants.PlayerType.HUMAN
	player_settings.color = Constants.Player.COLORS[0]
	settings.players.append(player_settings)
	settings.visibility = settings.Visibility.FULL
	settings.visible_player = 0
	FeatureFlags.handle_match_end = false
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://tests/movement/maps/MovementArena.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await _match.ready
	for _i in range(20):
		await get_tree().physics_frame
	_player = get_tree().get_nodes_in_group("players")[0]
	for unit in get_tree().get_nodes_in_group("units"):
		if not unit is Structure:
			unit.queue_free()  # starting workers and haulers would wander through the rigs
	for layer in _match.find_children("*", "CanvasLayer", true, false):
		layer.visible = false
	var fog_overlay = _match.get_node_or_null("FogOfWar/ScreenOverlay")
	if fog_overlay != null:
		fog_overlay.visible = false
	var atmosphere = get_tree().get_first_node_in_group("atmosphere")
	if atmosphere != null:
		atmosphere.set_weather_immediately("clear")  # weather changes ground speed
		atmosphere.set("_time_to_next_weather", 1.0e9)
		for node_name in ["CloudShadows"]:
			var node = atmosphere.find_child(node_name, true, false)
			if node != null:
				node.visible = false  # cloud shadows make the strips hard to read
	var camera = get_viewport().get_camera_3d()
	camera.set_physics_process(false)
	camera.set_process_unhandled_input(false)
	if _args["scenario"] == "perf":
		await _run_perf()
	else:
		await _run_scenarios()
	get_tree().quit(0)


# scenarios ---------------------------------------------------------------------------------


func _run_scenarios():
	var wanted = _args["scenario"]
	var builders = {
		"head_on": _build_head_on,
		"narrow_gap": _build_narrow_gap,
		"same_point": _build_same_point,
		"factory_queue": _build_factory_queue,
		"crossing": _build_crossing,
		"building_target": _build_building_target,
		"squeezed_mine": _build_squeezed_mine,
	}
	for scenario_name in builders:
		if wanted == "all" or scenario_name in wanted.split(","):
			var scenario = Scenario.new()
			scenario.name = scenario_name
			builders[scenario_name].call(scenario)
			_scenarios.append(scenario)
	# structures change the navmesh: let it rebake before anyone moves
	for _i in range(90):
		await get_tree().physics_frame
	var map = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	var path = NavigationServer3D.map_get_path(map, Vector3(80, 0, 16), Vector3(100, 0, 16), true)
	var length = 0.0
	for i in range(1, path.size()):
		length += path[i - 1].distance_to(path[i])
	print("MOVEMENT navcheck path across the wall: %.1f m (straight 20 m)" % length)
	path = NavigationServer3D.map_get_path(map, Vector3(46, 0, 106), Vector3(58, 0, 106), true)
	length = 0.0
	for i in range(1, path.size()):
		length += path[i - 1].distance_to(path[i])
	print("MOVEMENT navcheck path across the factory: %.1f m (straight 12 m) %s" % [length, path])
	for scenario in _scenarios:
		_start(scenario)
	var longest = 0.0
	for scenario in _scenarios:
		longest = max(longest, scenario.duration)
	_last_frame_us = Time.get_ticks_usec()
	while _elapsed < longest + SAMPLE_S:
		await get_tree().physics_frame
		_elapsed += get_physics_process_delta_time()
		_track_frame()
		for scenario in _scenarios:
			_run_spawn_queue(scenario)
		if _elapsed >= _next_sample:
			_next_sample += SAMPLE_S
			for scenario in _scenarios:
				if not scenario.finished:
					_sample(scenario)
		if _args["shots"] != "0":
			await _take_due_shots()
	_report()


func _build_head_on(s):
	"""two groups swap places through each other, as when a player sends an army into another"""
	s.center = Vector3(30, 0, 30)
	s.duration = 35.0
	var left = _grid(Vector3(18, 0, 30), 4, 3, 2.2)
	var right = _grid(Vector3(42, 0, 30), 4, 3, 2.2)
	var a = _spawn_many(s, left)
	var b = _spawn_many(s, right)
	s.set_meta("orders", [[a, Vector3(42, 0, 30)], [b, Vector3(18, 0, 30)]])


func _build_narrow_gap(s):
	"""a wall of buildings with one gap, like a choke point between buildings or at a bridge"""
	s.center = Vector3(90, 0, 30)
	s.duration = 45.0
	for i in range(-8, 9):
		if i == 0:
			continue  # the gap: one plant left out leaves a lane about one tank wide
		_spawn_structure(s, SOLAR_PLANT, Vector3(90, 0, 30 + i * 2.4))
	var units = _spawn_many(s, _grid(Vector3(80, 0, 30), 4, 4, 2.2))
	s.set_meta("orders", [[units, Vector3(100, 0, 30)]])


func _build_same_point(s):
	"""a scattered crowd sent to one point, as rally points and the AI do"""
	s.center = Vector3(30, 0, 86)
	s.duration = 30.0
	var positions = []
	for i in range(20):
		var angle = TAU * i / 20.0
		positions.append(Vector3(30, 0, 78) + Vector3(cos(angle), 0, sin(angle)) * (5.0 + i % 3))
	var units = _spawn_many(s, positions)
	s.set_meta("same_point", [units, Vector3(30, 0, 96)])


func _build_factory_queue(s):
	"""a factory keeps producing into its rally point"""
	s.center = Vector3(96, 0, 92)
	s.duration = 40.0
	var factory = _spawn_structure(s, VEHICLE_FACTORY, Vector3(96, 0, 88))
	for i in range(14):
		s.spawn_queue.append([1.4 * i, _produce.bind(s, factory, MIX[i % MIX.size()])])


func _build_crossing(s):
	"""two columns cross at right angles"""
	s.center = Vector3(66, 0, 62)
	s.duration = 30.0
	var west = _spawn_many(s, _grid(Vector3(52, 0, 62), 4, 2, 2.2), RAIDER)
	var south = _spawn_many(s, _grid(Vector3(66, 0, 48), 2, 4, 2.2), TANK)
	s.set_meta("orders", [[west, Vector3(80, 0, 62)], [south, Vector3(66, 0, 76)]])


func _build_building_target(s):
	"""units ordered onto a building and others delivering to it from one side"""
	s.center = Vector3(52, 0, 104)
	s.duration = 30.0
	var factory = _spawn_structure(s, VEHICLE_FACTORY, Vector3(52, 0, 106))
	var onto = _spawn_many(s, _grid(Vector3(40, 0, 104), 3, 2, 2.2))
	# trucks rather than haulers, whose job logic would send them elsewhere once they arrive;
	# both move with the same movement trait and the same approach to a building
	var deliver = _spawn_many(s, _grid(Vector3(64, 0, 104), 3, 2, 2.2), MISSILE_TRUCK)
	s.set_meta("orders", [[onto, factory.global_position]])
	s.set_meta("to_unit", [deliver, factory])


func _build_squeezed_mine(s):
	"""constructors and trucks heading for a mine wedged between two deposits, as the
	auto-placement packs extractors: only slivers of ground next to it are walkable"""
	s.center = Vector3(14, 0, 52)
	s.duration = 30.0
	for x in [11.6, 16.4]:
		var deposit = load(IRON_DEPOSIT).instantiate()
		deposit.position = Vector3(x, 0, 50)
		_match.map.find_child("Resources").add_child(deposit)
	var mine = _spawn_structure(s, MINE, Vector3(14, 0, 50))
	var workers = _spawn_many(s, _grid(Vector3(14, 0, 58), 4, 1, 2.2), WORKER)
	var trucks = _spawn_many(s, _grid(Vector3(14, 0, 43), 4, 1, 2.2), MISSILE_TRUCK)
	s.set_meta("to_unit", [workers + trucks, mine])


func _start(s):
	s.started_at = _elapsed
	for order in s.get_meta("orders", []):
		for pair in MovementUtils.crowd_moved_to_new_pivot(order[0], order[1]):
			pair[0].action = Moving.new(pair[1])
	if s.has_meta("same_point"):
		for unit in s.get_meta("same_point")[0]:
			unit.action = Moving.new(s.get_meta("same_point")[1])
	if s.has_meta("to_unit"):
		var pair = s.get_meta("to_unit")
		for unit in pair[0]:
			unit.action = MovingToUnit.new(pair[1])
	for fraction in [0.0, 0.2, 0.5, 1.0]:
		s.shots.append([s.duration * fraction, false])


func _produce(s, factory, scene_path):
	var unit = load(scene_path).instantiate()
	var position = Placement.find_valid_position_radially_yet_skip_starting_radius(
		factory.global_position,
		factory.radius,
		0.9,
		0.1,
		Vector3(0, 0, 1),
		false,
		_match.navigation.get_navigation_map_rid_by_domain(
			Constants.Match.Navigation.Domain.TERRAIN
		),
		get_tree()
	)
	if position == Vector3.INF:
		position = factory.global_position + Vector3(0, 0, factory.radius + 0.9)
	MatchSignals.setup_and_spawn_unit.emit(unit, Transform3D(Basis(), position), _player)
	s.units.append(unit)
	unit.action = Moving.new(factory.global_position + Vector3(0, 0, 5))


func _run_spawn_queue(s):
	while not s.spawn_queue.is_empty() and _elapsed - s.started_at >= s.spawn_queue[0][0]:
		s.spawn_queue.pop_front()[1].call()


# measuring ---------------------------------------------------------------------------------


func _sample(s):
	_skip_frame_timing = true
	var t = _elapsed - s.started_at
	var alive = s.units.filter(func(unit): return is_instance_valid(unit) and unit.is_inside_tree())
	var overlaps = 0
	for i in range(alive.size()):
		for j in range(i + 1, alive.size()):
			var a = alive[i]
			var b = alive[j]
			var ratio = (
				a.global_position_yless.distance_to(b.global_position_yless) / (a.radius + b.radius)
			)
			s.closest_ratio = min(s.closest_ratio, ratio)
			if ratio < OVERLAP_FACTOR:
				overlaps += 1
			if ratio < DEEP_OVERLAP_FACTOR:
				s.deep_overlap_pair_s += SAMPLE_S
	s.overlap_pair_s += overlaps * SAMPLE_S
	s.overlap_peak = max(s.overlap_peak, overlaps)
	var moving = 0
	for unit in alive:
		var movement = unit.find_child("Movement")
		var has_target = movement.target_position != Vector3.INF
		if has_target:
			moving += 1
		var history = s.history.get(unit, [])
		history.append([t, unit.global_position_yless])
		while history.size() > 1 and t - history[0][0] > STUCK_WINDOW_S:
			history.pop_front()
		s.history[unit] = history
		if (
			has_target
			and t - history[0][0] >= STUCK_WINDOW_S - SAMPLE_S
			and history[0][1].distance_to(unit.global_position_yless) < STUCK_DISTANCE_M
		):
			s.stuck_units[unit.get_instance_id()] = true
			s.stuck_s += SAMPLE_S
		for structure in s.structures:
			if (
				is_instance_valid(structure)
				and (
					structure.global_position_yless.distance_to(unit.global_position_yless)
					< structure.radius * 0.8
				)
			):
				s.in_building_s += SAMPLE_S
	if moving == 0 and s.spawn_queue.is_empty() and s.settled_at < 0.0:
		s.settled_at = t
	elif moving > 0:
		s.settled_at = -1.0
	if _args.has("debug") and int(t * 4) % 20 == 0:
		for unit in alive:
			var movement = unit.find_child("Movement")
			if movement.target_position != Vector3.INF and movement.get("_stuck_s") > 1.5:
				var nearest = INF
				for structure in s.structures:
					nearest = min(
						nearest,
						structure.global_position_yless.distance_to(unit.global_position_yless)
					)
				print(
					(
						"MOVEMENT debug t=%.1f %s %s pos %s next %s target %s vel %s idx %d/%d struct %.2f"
						% [
							t,
							s.name,
							unit.name,
							unit.global_position,
							movement.get_next_path_position(),
							movement.target_position,
							movement.velocity,
							movement.get_current_navigation_path_index(),
							movement.get_current_navigation_path().size(),
							nearest
						]
					)
				)
	if t >= s.duration:
		s.finished = true
		s.overlap_end = overlaps
		s.unfinished = moving
		if s.has_meta("to_unit"):
			s.reached = _count_next_to(s.get_meta("to_unit")[0], s.get_meta("to_unit")[1])


func _count_next_to(units, target):
	var count = 0
	for unit in units:
		if is_instance_valid(unit) and MovementUtils.units_adhere(unit, target):
			count += 1
	return count


func _track_frame():
	var now = Time.get_ticks_usec()
	if _skip_frame_timing:
		_skip_frame_timing = false  # the test's own bookkeeping ran in the last tick
		_last_frame_us = now
		return
	_frame_ms.append((now - _last_frame_us) / 1000.0)
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_last_frame_us = now


func _take_due_shots():
	for s in _scenarios:
		for shot in s.shots:
			if shot[1] or _elapsed - s.started_at < shot[0]:
				continue
			shot[1] = true
			var camera = get_viewport().get_camera_3d()
			camera.set_size_safely(16)
			camera.set_position_safely(s.center)
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
			var image = get_viewport().get_texture().get_image()
			image.resize(image.get_width() / 2, image.get_height() / 2)
			shot.append(image)
			_last_frame_us = Time.get_ticks_usec()  # shots stall frames, keep them out of timings


func _report():
	var lines = []
	var json = {"scenarios": {}, "frames": _frame_stats()}
	for s in _scenarios:
		var data = {
			"units": s.units.size(),
			"overlap_pair_seconds": snappedf(s.overlap_pair_s, 0.01),
			"overlap_peak_pairs": s.overlap_peak,
			"overlap_pairs_at_end": s.overlap_end,
			"deep_overlap_pair_seconds": snappedf(s.deep_overlap_pair_s, 0.01),
			"closest_centre_distance_vs_radii": snappedf(s.closest_ratio, 0.01),
			"units_stuck_at_least_once": s.stuck_units.size(),
			"stuck_unit_seconds": snappedf(s.stuck_s, 0.01),
			"unit_seconds_inside_buildings": snappedf(s.in_building_s, 0.01),
			"units_unfinished_at_end": s.unfinished,
			"units_next_to_their_target_building_at_end": s.reached,
			"settled_after_s": snappedf(s.settled_at, 0.01),
			"duration_s": s.duration,
		}
		json["scenarios"][s.name] = data
		if _args.has("debug"):
			for unit in s.units:
				if (
					is_instance_valid(unit)
					and unit.find_child("Movement").target_position != Vector3.INF
				):
					var movement = unit.find_child("Movement")
					print(
						(
							"MOVEMENT debug %s %s at %s -> %s next %s path %d"
							% [
								s.name,
								unit.name,
								unit.global_position,
								movement.target_position,
								movement.get_next_path_position(),
								movement.get_current_navigation_path().size()
							]
						)
					)
		var line = "MOVEMENT %s %s" % [s.name, JSON.stringify(data)]
		print(line)
		lines.append(line)
		_save_strip(s)
	var frames_line = "MOVEMENT frames %s" % JSON.stringify(json["frames"])
	print(frames_line)
	lines.append(frames_line)
	var file = FileAccess.open(_args["out"] + "/report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(json, "  "))
	file = FileAccess.open(_args["out"] + "/report.txt", FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")


func _save_strip(s):
	var images = []
	for shot in s.shots:
		if shot.size() > 2:
			images.append(shot[2])
	if images.is_empty():
		return
	var w = images[0].get_width()
	var h = images[0].get_height()
	var strip = Image.create(w * images.size(), h, false, images[0].get_format())
	for i in range(images.size()):
		strip.blit_rect(images[i], Rect2i(0, 0, w, h), Vector2i(w * i, 0))
	strip.save_png(_args["out"] + "/" + s.name + ".png")


func _frame_stats():
	if _frame_ms.is_empty():
		return {}
	var frames = _frame_ms.duplicate()
	frames.sort()
	var physics = _physics_ms.duplicate()
	physics.sort()
	var total = 0.0
	for value in frames:
		total += value
	var physics_total = 0.0
	for value in physics:
		physics_total += value
	return {
		"orders_ms": _order_ms.map(func(value): return snappedf(value, 0.1)),
		"frames": frames.size(),
		"frame_ms_avg": snappedf(total / frames.size(), 0.01),
		"frame_ms_p95": snappedf(frames[int(frames.size() * 0.95)], 0.01),
		"frame_ms_max": snappedf(frames[-1], 0.01),
		"physics_ms_avg": snappedf(physics_total / physics.size(), 0.01),
		"physics_ms_p95": snappedf(physics[int(physics.size() * 0.95)], 0.01),
		"physics_ms_max": snappedf(physics[-1], 0.01),
	}


# perf --------------------------------------------------------------------------------------


func _run_perf():
	"""many units ordered around in big groups; reports frame and physics time"""
	var count = int(_args["units"])
	var s = Scenario.new()
	s.name = "perf"
	s.duration = _args_seconds
	var side = int(ceil(sqrt(count)))
	var positions = _grid(Vector3(40, 0, 40), side, side, 2.4).slice(0, count)
	_spawn_many(s, positions)
	_scenarios.append(s)
	for _i in range(60):
		await get_tree().physics_frame
	var rng = RandomNumberGenerator.new()
	rng.seed = 7
	var next_order = 0.0
	_last_frame_us = Time.get_ticks_usec()
	while _elapsed < s.duration:
		await get_tree().physics_frame
		_elapsed += get_physics_process_delta_time()
		_track_frame()
		if _elapsed >= next_order:
			next_order += 8.0
			# split the army in four groups that each get a far destination
			var groups = [[], [], [], []]
			for i in range(s.units.size()):
				groups[i % 4].append(s.units[i])
			var order_start = Time.get_ticks_usec()
			for group in groups:
				var target = Vector3(rng.randf_range(15, 105), 0, rng.randf_range(15, 105))
				for pair in MovementUtils.crowd_moved_to_new_pivot(group, target):
					pair[0].action = Moving.new(pair[1])
			var order_ms = (Time.get_ticks_usec() - order_start) / 1000.0
			_order_ms.append(order_ms)
		if _elapsed >= _next_sample:
			_next_sample += SAMPLE_S
			_sample(s)
	s.finished = true
	_report()


# helpers -----------------------------------------------------------------------------------


func _grid(center, columns, rows, spacing):
	var positions = []
	for row in range(rows):
		for column in range(columns):
			positions.append(
				(
					center
					+ Vector3(
						(column - (columns - 1) / 2.0) * spacing,
						0,
						(row - (rows - 1) / 2.0) * spacing
					)
				)
			)
	return positions


func _spawn_many(s, positions, scene_path = null):
	var units = []
	for i in range(positions.size()):
		var path = scene_path if scene_path != null else MIX[i % MIX.size()]
		var unit = load(path).instantiate()
		MatchSignals.setup_and_spawn_unit.emit(unit, Transform3D(Basis(), positions[i]), _player)
		units.append(unit)
		s.units.append(unit)
	return units


func _spawn_structure(s, scene_path, position):
	var structure = load(scene_path).instantiate()
	structure.set_meta("spawn_constructed", true)
	MatchSignals.setup_and_spawn_unit.emit(structure, Transform3D(Basis(), position), _player)
	s.structures.append(structure)
	return structure
