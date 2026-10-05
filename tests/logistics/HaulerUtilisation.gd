extends Node

# Measures how well a faction's delivery trucks are used, for comparing logistics changes.
# Two AIs build their economy only (no armies, no raids) and the probe samples every
# truck twice a second:
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --rendering-driver opengl3 --path . \
#     res://tests/logistics/HaulerUtilisation.tscn -- --map=oil_and_iron --seconds=900 \
#     --out=/tmp/util.json
#
# A truck counts as working while it drives to a pickup, carries goods or materials, or
# unloads. Parked or standing by (waiting at an extractor for goods) counts as idle, so
# pre-positioning does not inflate the number. It also reports goods delivered per truck
# and how long extractors sat full waiting for a truck.

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const GameData = preload("res://source/data-model/GameData.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")

const SAMPLE_S = 0.5
const IDLE_DESCRIPTIONS = ["STANDBY", "PARKED", "RECYCLING"]

var _args = {
	"map": "oil_and_iron",
	"ai": "balanced,trader",
	"seconds": "900",
	"log-every": "60",
	"out": "user://hauler_utilisation.json",
}
var _match = null
var _elapsed_s = 0.0
var _since_sample_s = 0.0
var _next_log_s = 60.0
var _stats = {}  # player index -> counters
var _timeline = []


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	var map_scene = _args["map"]
	for entry in GameData.get_data()["maps"]:
		if entry["id"] == map_scene:
			map_scene = entry["scene"]
	var settings = MatchSettings.new()
	var personalities = _args["ai"].split(",")
	for index in range(personalities.size()):
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
	_match.map = load(map_scene).instantiate()
	add_child(_match)
	_next_log_s = float(_args["log-every"])
	print("UTIL start map=%s ai=%s seconds=%s" % [map_scene, _args["ai"], _args["seconds"]])
	for _i in range(3):
		await get_tree().physics_frame
	for player in _players():
		player.expected_number_of_battlegroups = 0
		player.expected_number_of_ag_turrets = 0
		player.expected_number_of_aa_turrets = 0
		player.raid_party_size = 0


func _physics_process(delta):
	if _match == null or not _match.is_node_ready() or _players().is_empty():
		return
	_elapsed_s += delta
	_since_sample_s += delta
	if _since_sample_s >= SAMPLE_S:
		_sample(_since_sample_s)
		_since_sample_s = 0.0
	if _elapsed_s >= _next_log_s:
		_next_log_s += float(_args["log-every"])
		_log()
	if _elapsed_s >= float(_args["seconds"]):
		set_physics_process(false)
		_finish()


func _players():
	return get_tree().get_nodes_in_group("players")


static func is_working(hauler):
	if hauler.action == null:
		return false
	var description = hauler.action.get("description")
	return description == null or not description in IDLE_DESCRIPTIONS


func _sample(dt):
	for player in _players():
		var key = player.get_index()
		if not key in _stats:
			_stats[key] = {
				"truck_s": 0.0,
				"working_s": 0.0,
				"loaded_s": 0.0,
				"extractor_s": 0.0,
				"extractor_full_s": 0.0,
				"trains_s": 0.0,
				"recycled": 0,
			}
		var stats = _stats[key]
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.player != player:
				continue
			if unit is Hauler:
				stats["truck_s"] += dt
				if is_working(unit):
					stats["working_s"] += dt
				if not unit.cargo.is_empty():
					stats["loaded_s"] += dt
			elif unit is Extractor and unit.is_constructed() and not unit.is_depleted():
				stats["extractor_s"] += dt
				if unit.stored >= _extractor_capacity(unit):
					stats["extractor_full_s"] += dt
			elif unit.get("is_train") == true:
				stats["trains_s"] += dt


static func _extractor_capacity(extractor):
	if extractor.has_method("get_buffer_capacity"):
		return extractor.get_buffer_capacity()
	return Constants.Match.Extraction.STORAGE_MAX


func _summary(player):
	var stats = _stats.get(player.get_index(), {})
	var haulers = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Hauler and unit.player == player
	)
	var delivered = Utils.Dict.sum(player.logistics.delivered_total)
	var truck_minutes = stats.get("truck_s", 0.0) / 60.0
	return {
		"player": player.get_index(),
		"personality": player.get("personality_id"),
		"haulers_now": haulers.size(),
		"haulers_working_now": haulers.filter(is_working).size(),
		"utilisation": stats.get("working_s", 0.0) / max(stats.get("truck_s", 0.0), 0.001),
		"loaded_share": stats.get("loaded_s", 0.0) / max(stats.get("truck_s", 0.0), 0.001),
		"delivered": delivered,
		"delivered_per_truck_minute": delivered / max(truck_minutes, 0.001),
		"extractor_full_share":
		stats.get("extractor_full_s", 0.0) / max(stats.get("extractor_s", 0.0), 0.001),
		"trains_avg": stats.get("trains_s", 0.0) / max(_elapsed_s, 0.001),
		"recycled": player.logistics.fleet.recycled_total if "fleet" in player.logistics else 0,
	}


func _log():
	var row = {"t": int(_elapsed_s), "players": []}
	for player in _players():
		var data = _summary(player)
		row["players"].append(data)
		print(
			(
				(
					"UTIL t=%4d p%d %-8s trucks=%d working=%d util=%3.0f%% loaded=%3.0f%% "
					+ "delivered=%4d per-truck-min=%4.1f extractors-full=%3.0f%%"
				)
				% [
					row["t"],
					data["player"],
					data["personality"],
					data["haulers_now"],
					data["haulers_working_now"],
					data["utilisation"] * 100.0,
					data["loaded_share"] * 100.0,
					data["delivered"],
					data["delivered_per_truck_minute"],
					data["extractor_full_share"] * 100.0,
				]
			)
		)
	_timeline.append(row)


func _finish():
	_log()
	var file = FileAccess.open(_args["out"], FileAccess.WRITE)
	file.store_string(JSON.stringify({"args": _args, "timeline": _timeline}, "  "))
	file.close()
	print("UTIL done ", ProjectSettings.globalize_path(_args["out"]))
	get_tree().quit()
