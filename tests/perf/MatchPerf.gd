extends Node

# Long-match frame rate probe. Starts a match with AIs in every slot, the first slot watched as a
# human would (fog of war, minimap, HUD), and logs every --log-every game seconds how fast the
# game runs and how much it holds:
#
#   godot --headless --path . res://tests/perf/MatchPerf.tscn -- --map=desert_expanse \
#     --ai=balanced,raider,trader,turtle --minutes=10 --log-every=60 --out=/tmp/perf.json
#
# Headless runs have no renderer, so fps is how many frames the CPU side manages: on a PC with
# a decent graphics card that is what limits a big match. Physics runs at a fixed 60 ticks per
# second; once one tick costs more than 16.7 ms the engine runs several ticks per frame to catch
# up and fps collapses, so watch "speed" (game seconds per real second) drop below 1.
#
# --profile=1 additionally runs every script's _process/_physics_process (and the movement
# trait's avoidance callback) from here for 120 ticks at each log line and prints the costliest
# scripts in ms per physics tick. --profile-from=<s> delays that to later in the match.

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const PROFILE_TICKS = 120
const SLOW_FRAME_MS = 50.0

var _args = {
	"map": "desert_expanse",
	"ai": "balanced,raider,trader,turtle",
	"minutes": "10",
	"log-every": "60",
	"profile": "0",
	"profile-from": "1",
	"out": "user://match_perf.json",
}
var _match = null
var _elapsed_s = 0.0
var _next_log_s = 0.0
var _samples = []
var _frames = 0
var _real_start_us = 0
var _window_start_us = 0
var _window_start_s = 0.0
var _last_frame_us = 0
var _slow_frames = 0
var _worst_frame_ms = 0.0
var _rebakes = 0
var _profiling = false
var _profiled = []
var _profile_ms = {}


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	var map_path = null
	for path in Constants.Match.MAPS:
		if path.get_file().get_basename().to_snake_case() == _args["map"]:
			map_path = path
	assert(map_path != null, "unknown map " + _args["map"])
	preload("res://source/data-model/GameData.gd").register_generated_scenes()
	for scene_path in (
		Constants.Match.Units.PROJECTILES.values() + Constants.Match.Units.CONSTRUCTION_COSTS.keys()
	):
		Globals.cache[scene_path] = load(scene_path)
	var settings = MatchSettings.new()
	var personalities = _args["ai"].split(",")
	for index in range(min(personalities.size(), Constants.Match.MAPS[map_path]["players"])):
		var player_settings = PlayerSettings.new()
		player_settings.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		player_settings.ai_personality = personalities[index]
		player_settings.color = Constants.Player.COLORS[index]
		settings.players.append(player_settings)
	settings.visibility = settings.Visibility.PER_PLAYER
	settings.visible_player = 0
	FeatureFlags.handle_match_end = false
	MatchSignals.schedule_navigation_rebake.connect(func(_domain): _rebakes += 1)
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load(map_path).instantiate()
	get_tree().root.add_child.call_deferred(_match)
	print("PERF start map=%s ai=%s" % [_args["map"], _args["ai"]])


func _process(delta):
	if _match == null or not _match.is_node_ready():
		return
	_frames += 1
	var now = Time.get_ticks_usec()
	if _last_frame_us != 0:
		var frame_ms = (now - _last_frame_us) / 1000.0
		_worst_frame_ms = max(_worst_frame_ms, frame_ms)
		_slow_frames += 1 if frame_ms > SLOW_FRAME_MS else 0
	_last_frame_us = now
	_run_profiled(false, delta)


func _physics_process(delta):
	if _match == null or not _match.is_node_ready():
		return
	if _real_start_us == 0:
		_real_start_us = Time.get_ticks_usec()
		_window_start_us = _real_start_us
	_elapsed_s += delta
	_run_profiled(true, delta)
	if _elapsed_s >= _next_log_s and not _profiling:
		_next_log_s += float(_args["log-every"])
		_log()
	if _elapsed_s >= float(_args["minutes"]) * 60.0:
		set_physics_process(false)
		_finish()


func _log():
	var units = get_tree().get_nodes_in_group("units")
	var by_player = {}
	for unit in units:
		var key = unit.player.get_index() if is_instance_valid(unit.player) else -1
		by_player[key] = by_player.get(key, 0) + 1
	var now_us = Time.get_ticks_usec()
	var wall_s = max((now_us - _window_start_us) / 1e6, 0.001)
	var sample = {
		"t": int(_elapsed_s),
		"real_s": (now_us - _real_start_us) / 1e6,
		"fps": _frames / wall_s,
		"game_speed": (_elapsed_s - _window_start_s) / wall_s,
		"slow_frames": _slow_frames,
		"worst_frame_ms": _worst_frame_ms,
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
		"orphans": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"units": units.size(),
		"units_by_player": by_player,
		"rebake_requests": _rebakes,
	}
	_window_start_us = now_us
	_window_start_s = _elapsed_s
	_frames = 0
	_slow_frames = 0
	_worst_frame_ms = 0.0
	print(
		(
			(
				"PERF t=%4ds real=%5.0fs fps=%6.1f speed=%4.2fx slow=%d worst=%.0fms"
				% [
					sample["t"],
					sample["real_s"],
					sample["fps"],
					sample["game_speed"],
					sample["slow_frames"],
					sample["worst_frame_ms"],
				]
			)
			+ (
				" nodes=%d orphans=%d units=%d rebakes=%d %s"
				% [sample["nodes"], sample["orphans"], sample["units"], _rebakes, by_player]
			)
		)
	)
	_samples.append(sample)
	if _args["profile"] == "1" and _elapsed_s >= float(_args["profile-from"]):
		_profile(sample)


func _profile(sample):
	"""runs every script's process callbacks from here for a while, timing each script"""
	_profiling = true
	_profiled = []
	_profile_ms = {}
	for node in get_tree().root.find_children("*", "", true, false):
		var script = node.get_script()
		if script == null or node == self:
			continue
		var states = [node.is_processing(), node.is_physics_processing()]
		if not (states[0] or states[1]):
			continue
		node.set_process(false)
		node.set_physics_process(false)
		_profiled.append([node, script.resource_path.get_file(), states])
	var wrapped = []
	for agent in get_tree().root.find_children("*", "NavigationAgent3D", true, false):
		if (
			agent.has_method("_on_velocity_computed")
			and agent.velocity_computed.is_connected(agent._on_velocity_computed)
		):
			var timed = func(velocity): _timed(agent, "_on_velocity_computed", velocity)
			agent.velocity_computed.disconnect(agent._on_velocity_computed)
			agent.velocity_computed.connect(timed)
			wrapped.append([agent, timed])
	for _i in range(PROFILE_TICKS):
		await get_tree().physics_frame
	for entry in wrapped:
		if is_instance_valid(entry[0]):
			entry[0].velocity_computed.disconnect(entry[1])
			entry[0].velocity_computed.connect(entry[0]._on_velocity_computed)
	for entry in _profiled:
		if is_instance_valid(entry[0]):
			entry[0].set_process(entry[2][0])
			entry[0].set_physics_process(entry[2][1])
	_profiled = []
	var keys = _profile_ms.keys()
	keys.sort_custom(func(a, b): return _profile_ms[a][0] > _profile_ms[b][0])
	var total = 0.0
	for key in keys:
		total += _profile_ms[key][0]
	print("PERF   scripts %.2f ms per physics tick" % (total / PROFILE_TICKS))
	sample["profile_ms_per_tick"] = {}
	for key in keys:
		sample["profile_ms_per_tick"][key] = _profile_ms[key][0] / PROFILE_TICKS
	for key in keys.slice(0, 12):
		print(
			(
				"PERF   %-44s x%-5d %6.3f ms/tick"
				% [key, _profile_ms[key][1], _profile_ms[key][0] / PROFILE_TICKS]
			)
		)
	_profiling = false


func _run_profiled(physics, delta):
	for entry in _profiled:
		var node = entry[0]
		if not is_instance_valid(node) or not node.is_inside_tree():
			continue
		if not entry[2][1 if physics else 0]:
			continue
		var start = Time.get_ticks_usec()
		if physics:
			node._physics_process(delta)
		else:
			node._process(delta)
		_add_cost(entry[1], start)


func _timed(node, method, argument):
	var start = Time.get_ticks_usec()
	node.call(method, argument)
	_add_cost("%s:%s" % [node.get_script().resource_path.get_file(), method], start)


func _add_cost(key, start_us):
	if not key in _profile_ms:
		_profile_ms[key] = [0.0, 0]
	_profile_ms[key][0] += (Time.get_ticks_usec() - start_us) / 1000.0
	_profile_ms[key][1] += 1


func _finish():
	var file = FileAccess.open(_args["out"], FileAccess.WRITE)
	file.store_string(JSON.stringify({"args": _args, "samples": _samples}, "  "))
	file.close()
	print("PERF done")
	get_tree().quit()
