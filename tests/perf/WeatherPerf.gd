extends Node

# Measures how much each weather costs per frame in a busy match.
# Usage (needs a real renderer, e.g. under xvfb-run):
#   godot --path . res://tests/perf/WeatherPerf.tscn -- --units=40 --frames=120
# Prints, per weather, the average frame, process and physics times in milliseconds.
# Physics time is the script work (visibility, targeting, weather lookups); on a software
# renderer the frame time is dominated by drawing, so compare the physics column.

const TankScene = preload("res://source/match/units/Tank.tscn")
const WEATHERS = ["clear", "overcast", "rain", "sandstorm"]

var _args = {"units": "40", "frames": "120", "warmup": "60"}


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var match_node = load("res://tests/manual/TestDesert.tscn").instantiate()
	add_child(match_node)
	await _frames(int(_args["warmup"]))
	var atmosphere = match_node.find_child("Atmosphere", true, false)
	atmosphere.random_weather = false
	_spawn_armies(int(_args["units"]))
	await _frames(30)
	print("units: ", get_tree().get_nodes_in_group("units").size())
	var viewport_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport_rid, true)
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(float(_args.get("camera_size", "25")))
	for weather in WEATHERS:
		atmosphere.set_weather_immediately(weather)
		atmosphere.set("_cloud_zone_timer", 0.0)
		await _frames(30)
		var zones = match_node.get_node("WeatherEffects").zones.size()
		var totals = {"frame": 0.0, "process": 0.0, "physics": 0.0, "gpu": 0.0, "cpu": 0.0}
		var count = int(_args["frames"])
		for i in range(count):
			var started = Time.get_ticks_usec()
			await get_tree().process_frame
			totals["frame"] += (Time.get_ticks_usec() - started) / 1000.0
			totals["process"] += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
			totals["physics"] += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
			totals["gpu"] += RenderingServer.viewport_get_measured_render_time_gpu(viewport_rid)
			totals["cpu"] += RenderingServer.viewport_get_measured_render_time_cpu(viewport_rid)
		print(
			(
				"PERF {0}: zones={1} frame={2} process={3} physics={4} render_cpu={5} render_gpu={6}"
				. format(
					[
						weather.rpad(10),
						zones,
						snappedf(totals["frame"] / count, 0.01),
						snappedf(totals["process"] / count, 0.01),
						snappedf(totals["physics"] / count, 0.01),
						snappedf(totals["cpu"] / count, 0.01),
						snappedf(totals["gpu"] / count, 0.01),
					]
				)
			)
		)
	get_tree().quit()


func _spawn_armies(per_player):
	var players = get_tree().get_nodes_in_group("players")
	for player in players:
		var home = Vector3.ZERO
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.player == player:
				home = unit.global_position
				break
		for i in range(per_player):
			var offset = Vector3((i % 8) * 2.5 - 9.0, 0.0, int(i / 8.0) * 2.5 + 8.0)
			MatchSignals.setup_and_spawn_unit.emit(
				TankScene.instantiate(), Transform3D(Basis(), home + offset), player
			)


func _frames(count):
	for i in range(count):
		await get_tree().process_frame
