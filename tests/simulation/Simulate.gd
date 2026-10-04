extends Node

# Headless-ish match simulator for balancing and regression checks. It needs a renderer for
# navigation meshes, so run it under a virtual display:
#
#   xvfb-run -a godot --rendering-driver opengl3 --path . res://tests/simulation/Simulate.tscn \
#     -- --map=res://source/match/maps/PlainAndSimple.tscn --ai=balanced,raider \
#        --seconds=900 --time-scale=4 --scenario=match --out=user://sim.json
#
# Scenarios:
# - match: AI personalities play against each other.
# - control / raid: both AIs only build their economy (no armies, no AI raids). In 'raid' the
#   harness keeps a party of raiders of player 2 parked on the busiest supply route of
#   player 1 from --raid-start seconds on, so the two runs show what raiding costs.
#
# Every --log-every seconds it prints one line per player; at the end it writes a JSON
# summary to --out.

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const RaiderScene = preload("res://source/match/units/Raider.tscn")

var _args = {
	"map": "res://source/match/maps/PlainAndSimple.tscn",
	"ai": "balanced,balanced",
	"seconds": "900",
	"time-scale": "4",
	"scenario": "match",
	"log-every": "60",
	"raid-start": "240",
	"raiders": "3",
	"out": "user://simulation.json",
}
var _match = null
var _elapsed_s = 0.0
var _next_log_s = 0.0
var _samples = []
var _hauler_distance = {}  # hauler -> metres driven
var _hauler_last_position = {}
var _hauler_distance_by_player = {}
var _raid_spot = null
var _raiders = []
var _raiders_spawned = 0
var _delivered_at_raid_start = {}


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	Engine.time_scale = float(_args["time-scale"])
	print(
		"SIM start map=%s ai=%s scenario=%s seconds=%s"
		% [_args["map"], _args["ai"], _args["scenario"], _args["seconds"]]
	)
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
	MatchSignals.diplomacy_changed.connect(
		func(a, b, state):
			print(
				"SIM %.0fs diplomacy P%d-P%d -> %s"
				% [_elapsed_s, _player_index(a), _player_index(b), ["war", "neutral", "pact", "alliance"][state]]
			)
	)
	MatchSignals.treaty_signed.connect(
		func(a, b, kind, offered, requested):
			print(
				"SIM %.0fs treaty %s P%d-P%d gives %s asks %s"
				% [_elapsed_s, kind, _player_index(a), _player_index(b), offered, requested]
			)
	)
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load(_args["map"]).instantiate()
	add_child(_match)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	if _args["scenario"] in ["control", "raid"]:
		for player in _players():
			player.expected_number_of_battlegroups = 0
			player.expected_number_of_ag_turrets = 0
			player.expected_number_of_aa_turrets = 0
			player.raid_party_size = 0


func _physics_process(delta):
	if _match == null or not _match.is_node_ready() or _players().is_empty():
		return
	_elapsed_s += delta
	_track_haulers()
	if _args["scenario"] == "raid" and _elapsed_s >= float(_args["raid-start"]):
		_keep_raiding()
	if _elapsed_s >= _next_log_s:
		_next_log_s += float(_args["log-every"])
		_log()
		print("SIM real time %.0fs" % (Time.get_ticks_msec() / 1000.0))
	if _elapsed_s >= float(_args["seconds"]):
		set_physics_process(false)
		_finish()


func _players():
	return get_tree().get_nodes_in_group("players")


func _track_haulers():
	for unit in get_tree().get_nodes_in_group("units"):
		if not unit is Hauler:
			continue
		var position = unit.global_position * Vector3(1, 0, 1)
		if unit in _hauler_last_position:
			var step = position.distance_to(_hauler_last_position[unit])
			_hauler_distance[unit] = _hauler_distance.get(unit, 0.0) + step
			var key = unit.player.get_index()
			_hauler_distance_by_player[key] = _hauler_distance_by_player.get(key, 0.0) + step
		_hauler_last_position[unit] = position
	for unit in _hauler_last_position.keys():
		if not is_instance_valid(unit):
			_hauler_last_position.erase(unit)
			_hauler_distance.erase(unit)


func _keep_raiding():
	var victim = _players()[0]
	var raider_owner = _players()[1]
	if _raid_spot == null:
		_raid_spot = _busiest_route_midpoint(victim)
		if _raid_spot == null:
			return
		_delivered_at_raid_start = victim.logistics.delivered_total.duplicate()
		print("SIM raid starts at %.0fs, spot %s" % [_elapsed_s, _raid_spot])
	_raiders = _raiders.filter(func(unit): return is_instance_valid(unit) and unit.is_inside_tree())
	while _raiders.size() < int(_args["raiders"]):
		var raider = RaiderScene.instantiate()
		var offset = Vector3(randf_range(-1.5, 1.5), 0, randf_range(-1.5, 1.5))
		MatchSignals.setup_and_spawn_unit.emit(
			raider, Transform3D(Basis(), _raid_spot + offset), raider_owner
		)
		_raiders.append(raider)
		_raiders_spawned += 1


func _busiest_route_midpoint(player):
	"""midpoint between the player's depot and its farthest working extractor"""
	var best = null
	for extractor in player.logistics.get_extractors():
		if not extractor.is_constructed():
			continue
		var depot = player.logistics.closest_depot(extractor.global_position)
		if depot == null:
			continue
		var distance = extractor.global_position.distance_to(depot.global_position)
		if best == null or distance > best[0]:
			best = [distance, (extractor.global_position + depot.global_position) * 0.5]
	if best == null:
		return null
	return best[1] * Vector3(1, 0, 1)


func _player_sample(player):
	var units = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player
	)
	var haulers = units.filter(func(unit): return unit is Hauler)
	var city = player.city
	return {
		"player": player.get_index(),
		"personality": player.get("personality_id"),
		"stock": player.get_stock(),
		"units": units.size(),
		"haulers": haulers.size(),
		"haulers_busy": haulers.filter(func(unit): return unit.action != null).size(),
		"hauler_distance_m": snapped(_hauler_distance_by_player.get(player.get_index(), 0.0), 0.1),
		"extractors": units.filter(func(unit): return unit is Extractor and unit.is_constructed()).size(),
		"sites": units.filter(func(unit): return unit is Structure and unit.is_under_construction()).size(),
		"delivered": player.logistics.delivered_total.duplicate(),
		"lost": player.logistics.lost_total.duplicate(),
		"looted": player.logistics.looted_total.duplicate(),
		"fuel_burnt": player.logistics.fuel_burnt_total.duplicate(),
		"power_supply_mw": snapped(player.power_grid.total_supply_mw, 0.1),
		"power_demand_mw": snapped(player.power_grid.total_demand_mw, 0.1),
		"population": snapped(city.population, 0.1),
		"science": snapped(city.science, 0.1),
		"tier": city.tier,
		"satisfaction": snapped(city.get_satisfaction(), 0.01),
		"city_buildings": city.get_buildings_count(),
	}


func _log():
	var sample = {"t": int(_elapsed_s), "players": []}
	for player in _players():
		var data = _player_sample(player)
		sample["players"].append(data)
		print(
			(
				"SIM t=%4d p%d %-8s units=%2d haulers=%d/%d dist=%6.0fm extr=%d sites=%d "
				+ "delivered=%4d lost=%3d looted=%3d pop=%5.1f sci=%6.1f tier=%d sat=%.2f "
				+ "power=%.0f/%.0f stock=%s"
			)
			% [
				sample["t"],
				data["player"],
				data["personality"],
				data["units"],
				data["haulers_busy"],
				data["haulers"],
				data["hauler_distance_m"],
				data["extractors"],
				data["sites"],
				Utils.Dict.sum(data["delivered"]),
				Utils.Dict.sum(data["lost"]),
				Utils.Dict.sum(data["looted"]),
				data["population"],
				data["science"],
				data["tier"],
				data["satisfaction"],
				data["power_supply_mw"],
				data["power_demand_mw"],
				data["stock"],
			]
		)
	_samples.append(sample)


func _finish():
	_log()
	var market = _match.get_node_or_null("Market")
	var summary = {
		"args": _args,
		"samples": _samples,
		"raiders_spawned": _raiders_spawned,
		"delivered_at_raid_start": _delivered_at_raid_start,
		"caravans_shipped": market.shipped_total if market != null else 0,
		"caravans_raided": market.raided_total if market != null else 0,
		"agreements_active": market.agreements.size() if market != null else 0,
	}
	var file = FileAccess.open(_args["out"], FileAccess.WRITE)
	file.store_string(JSON.stringify(summary, "  "))
	file.close()
	print("SIM done, summary written to ", ProjectSettings.globalize_path(_args["out"]))
	get_tree().quit()


func _player_index(player):
	return _players().find(player)
