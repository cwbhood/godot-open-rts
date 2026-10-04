extends Node

# Where do AI armies stand? Plays an AI-only match and, every --sample-every game seconds,
# measures how bunched up each AI's combat units are. At the minutes listed in --shots it
# saves a top-down screenshot of every AI's base and dumps unit positions to JSON, so runs
# before and after a change can be compared side by side. Needs a renderer for navigation:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 --path . \
#     --resolution 1280x720 res://tests/ai/ArmyPositions.tscn -- --map=desert_expanse \
#     --ai=balanced,raider,trader,turtle --minutes=10 --shots=5,10 --out=/tmp/army
#
# Between screenshots 3D rendering is switched off, so the match runs as fast as the CPU
# allows (--time-scale, default 4).
#
# Overlap: two units overlap when their centres are closer than the sum of their radii.
# "touching" uses 1.5x that distance. Numbers are per AI and averaged over all samples.

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")

var _args = {
	"map": "desert_expanse",
	"ai": "balanced,raider,trader,turtle",
	"minutes": "10",
	"shots": "5,10",
	"sample-every": "10",
	"time-scale": "4",
	"view": "64",
	"out": "user://army_positions",
}
var _match = null
var _elapsed_s = 0.0
var _next_sample_s = 30.0
var _shots = []
var _stats = {}  # player index -> accumulated numbers
var _snapshots = []
var _busy = false
var _ai_ms = 0.0  # time spent in the AI positioning controllers, if any
var _real_start_us = 0
var _last_gap = {}  # unit -> distance to its spot at the last sample


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	for minute in _args["shots"].split(","):
		_shots.append(float(minute) * 60.0)
	DirAccess.make_dir_recursive_absolute(_args["out"])
	var map_path = null
	for path in Constants.Match.MAPS:
		if path.get_file().get_basename().to_snake_case() == _args["map"]:
			map_path = path
	assert(map_path != null, "unknown map " + _args["map"])
	preload("res://source/data-model/GameData.gd").register_generated_scenes()
	var settings = MatchSettings.new()
	var personalities = _args["ai"].split(",")
	for index in range(min(personalities.size(), Constants.Match.MAPS[map_path]["players"])):
		var player_settings = PlayerSettings.new()
		player_settings.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		player_settings.ai_personality = personalities[index]
		player_settings.color = Constants.Player.COLORS[index]
		settings.players.append(player_settings)
	settings.visibility = settings.Visibility.ALL_PLAYERS
	settings.visible_player = 0
	FeatureFlags.handle_match_end = false
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load(map_path).instantiate()
	get_tree().root.add_child.call_deferred(_match)
	Engine.time_scale = float(_args["time-scale"])
	Engine.max_physics_steps_per_frame = 32
	get_viewport().disable_3d = true
	print("ARMY start map=%s ai=%s" % [_args["map"], _args["ai"]])


func _physics_process(delta):
	if _match == null or not _match.is_node_ready() or _busy:
		return
	if _real_start_us == 0:
		_real_start_us = Time.get_ticks_usec()
		# with 3D off its pivot ray finds no ground; nobody steers it here anyway
		for camera in _match.find_children("*", "Camera3D", true, false):
			camera.set_process(false)
			camera.set_physics_process(false)
			camera.set_process_input(false)
			camera.set_process_unhandled_input(false)
	_elapsed_s += delta
	if _elapsed_s >= _next_sample_s:
		_next_sample_s += float(_args["sample-every"])
		_sample()
	if not _shots.is_empty() and _elapsed_s >= _shots[0]:
		_shots.pop_front()
		_busy = true
		await _snapshot()
		_busy = false
	if _elapsed_s >= float(_args["minutes"]) * 60.0 and _shots.is_empty():
		set_physics_process(false)
		_finish()


static func is_combat_unit(unit):
	return (
		not unit is Structure
		and not unit is Worker
		and unit.attack_range != null
		and unit.movement_speed > 0.0
	)


func _ai_players():
	return get_tree().get_nodes_in_group("players")


func _combat_units_of(player):
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player and is_combat_unit(unit)
	)


func _home_of(player):
	for unit in get_tree().get_nodes_in_group("units"):
		if unit is CommandCenter and unit.player == player:
			return unit.global_position_yless
	return null


func _measure(units, home):
	var overlapping = 0
	var touching = 0
	var overlap_pairs = 0
	var near_home = 0
	var nearest_sum = 0.0
	for a in units:
		var overlaps = false
		var touches = false
		var nearest = INF
		for b in units:
			if a == b or a.movement_domain != b.movement_domain:
				continue
			var distance = a.global_position_yless.distance_to(b.global_position_yless)
			nearest = min(nearest, distance)
			var limit = a.radius + b.radius
			if distance < limit:
				overlaps = true
				if a.get_instance_id() < b.get_instance_id():
					overlap_pairs += 1
			if distance < limit * 1.5:
				touches = true
		overlapping += 1 if overlaps else 0
		touching += 1 if touches else 0
		nearest_sum += nearest if nearest != INF else 0.0
		if home != null and a.global_position_yless.distance_to(home) < 15.0:
			near_home += 1
	return {
		"units": units.size(),
		"overlapping": overlapping,
		"touching": touching,
		"overlap_pairs": overlap_pairs,
		"near_home": near_home,
		"mean_nearest_m": nearest_sum / max(units.size(), 1),
	}


func _sample():
	for player in _ai_players():
		var index = player.get_index()
		var units = _combat_units_of(player)
		var numbers = _measure(units, _home_of(player))
		# units sent to their spots that did not get 1 m closer since the last sample
		numbers["moving"] = 0
		numbers["stalled"] = 0
		var controller = player.get_node_or_null("ArmyPositioningController")
		for unit in units:
			var spot = controller.spot_of(unit) if controller != null else null
			if spot == null or not unit.action is Moving:
				_last_gap.erase(unit)
				continue
			var gap = unit.global_position_yless.distance_to(spot)
			numbers["moving"] += 1
			if _last_gap.has(unit) and _last_gap[unit] - gap < 1.0:
				numbers["stalled"] += 1
			_last_gap[unit] = gap
		var total = _stats.get(index, {"samples": 0})
		total["samples"] += 1
		for key in numbers:
			total[key] = total.get(key, 0.0) + numbers[key]
		_stats[index] = total


func _snapshot():
	var minute = int(round(_elapsed_s / 60.0))
	var snapshot = {"minute": minute, "players": []}
	get_viewport().disable_3d = false
	var camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = float(_args["view"])
	get_tree().root.add_child(camera)
	camera.make_current()
	var saved_scale = Engine.time_scale
	Engine.time_scale = 0.0
	# a clear view: no HUD, fog of war, ground fog, clouds or weather
	var hidden = []
	for path in [
		"FogOfWar/ScreenOverlay",
		"Fog",
		"Atmosphere/Clouds",
		"Atmosphere/Rain",
		"Atmosphere/Dust",
		"Atmosphere/DustHaze",
	]:
		var node = _match.get_node_or_null(path)
		if node != null and node.visible:
			hidden.append(node)
	for layer in _match.find_children("*", "CanvasLayer", true, false):
		if layer.visible:
			hidden.append(layer)
	for node in hidden:
		node.visible = false
	var atmosphere = _match.get_node_or_null("Atmosphere")
	var weather = atmosphere.get_weather() if atmosphere != null else null
	if atmosphere != null:
		atmosphere.set_weather_immediately("clear")
	for player in _ai_players():
		var index = player.get_index()
		var home = _home_of(player)
		var units = _combat_units_of(player)
		var numbers = _measure(units, home)
		var entry = {
			"player": index,
			"personality": player.personality_id if "personality_id" in player else "",
			"home": [home.x, home.z] if home != null else null,
			"units": _unit_rows(units, player.get_node_or_null("ArmyPositioningController")),
			"structures": _structures_of(player),
			"posts": _posts_of(player),
			"numbers": numbers,
		}
		snapshot["players"].append(entry)
		print(
			(
				"ARMY min=%d P%d %-8s units=%d overlapping=%d touching=%d near_home=%d nn=%.1fm"
				% [
					minute,
					index,
					entry["personality"],
					numbers["units"],
					numbers["overlapping"],
					numbers["touching"],
					numbers["near_home"],
					numbers["mean_nearest_m"],
				]
			)
		)
		if home == null:
			continue
		camera.global_transform = Transform3D(Basis(), Vector3(home.x, 60.0, home.z)).looking_at(
			Vector3(home.x, 0.0, home.z), Vector3.FORWARD
		)
		for _i in range(4):
			await RenderingServer.frame_post_draw
		var image = get_viewport().get_texture().get_image()
		image.save_png(
			"%s/min%02d-p%d-%s.png" % [_args["out"], minute, index, entry["personality"]]
		)
	camera.queue_free()
	for node in hidden:
		node.visible = true
	if atmosphere != null:
		atmosphere.set_weather_immediately(weather)
	Engine.time_scale = saved_scale
	get_viewport().disable_3d = true
	_snapshots.append(snapshot)


func _unit_rows(units, controller):
	var rows = []
	for unit in units:
		var spot = controller.spot_of(unit) if controller != null else null
		var row = [
			unit.global_position.x,
			unit.global_position.z,
			unit.radius,
			unit.get_script().resource_path.get_file().get_basename(),
			str(unit.action),
			unit.global_position_yless.distance_to(spot) if spot != null else -1.0,
		]
		rows.append(row)
	return rows


func _structures_of(player):
	var found = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == player and unit is Structure:
			found.append([unit.global_position.x, unit.global_position.z, unit.radius])
	return found


func _posts_of(player):
	var controller = player.get_node_or_null("ArmyPositioningController")
	if controller == null or not controller.has_method("debug_posts"):
		return []
	return controller.debug_posts()


func _finish():
	var summary = {
		"map": _args["map"],
		"ai": _args["ai"],
		"real_s": (Time.get_ticks_usec() - _real_start_us) / 1e6,
		"players": {},
		"snapshots": _snapshots,
	}
	print("ARMY summary over %.0f game minutes" % (_elapsed_s / 60.0))
	for index in _stats:
		var total = _stats[index]
		var samples = max(total["samples"], 1)
		var units = max(total["units"], 1)
		var player = _ai_players()[index] if index < _ai_players().size() else null
		var row = {
			"personality": player.personality_id if player != null else "",
			"samples": total["samples"],
			"avg_units": total["units"] / samples,
			"overlapping_share": total["overlapping"] / units,
			"touching_share": total["touching"] / units,
			"overlap_pairs_per_sample": total["overlap_pairs"] / samples,
			"near_home_share": total["near_home"] / units,
			"mean_nearest_m": total["mean_nearest_m"] / samples,
			"stalled_share_of_moving": total["stalled"] / max(total["moving"], 1),
		}
		summary["players"][str(index)] = row
		print(
			(
				(
					"ARMY P%d %-8s avg_units=%.1f overlapping=%.0f%% touching=%.0f%% "
					+ "pairs=%.1f near_home=%.0f%% nn=%.1fm stalled=%.0f%%"
				)
				% [
					index,
					row["personality"],
					row["avg_units"],
					row["overlapping_share"] * 100.0,
					row["touching_share"] * 100.0,
					row["overlap_pairs_per_sample"],
					row["near_home_share"] * 100.0,
					row["mean_nearest_m"],
					row["stalled_share_of_moving"] * 100.0,
				]
			)
		)
	var cost_usec = 0
	var worst_usec = 0
	for player in _ai_players():
		var controller = player.get_node_or_null("ArmyPositioningController")
		if controller != null:
			cost_usec += controller.cost_usec
			worst_usec = max(worst_usec, controller.worst_usec)
	summary["positioning_worst_ms"] = worst_usec / 1000.0
	summary["positioning_ms_per_game_s"] = cost_usec / 1000.0 / max(_elapsed_s, 1.0)
	print(
		(
			"ARMY positioning cost: %.3f ms per game second, all AIs together, worst %.2f ms"
			% [summary["positioning_ms_per_game_s"], summary["positioning_worst_ms"]]
		)
	)
	var file = FileAccess.open(_args["out"] + "/positions.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(summary, "  "))
	file.close()
	print("ARMY done real=%.0fs" % summary["real_s"])
	get_tree().quit()
