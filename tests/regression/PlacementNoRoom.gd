extends Node

# Regression check for the mid-match freeze on Plain & Simple: once an AI base had no free
# spot left, the radial placement search never ended and the game stopped responding.
# Fills the whole map with one huge blocker, then asks for spots the way the AI, factories
# and trade caravans do. Every search must give up (Vector3.INF) instead of hanging; a
# watchdog thread kills the run if the main thread stops for WATCHDOG_S.
#
#   godot --headless --path . res://tests/regression/PlacementNoRoom.tscn
#
# Prints "PLACEMENT ok" and exits 0, or "PLACEMENT FAIL ..." and exits 1.

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const Placement = preload("res://source/match/utils/UnitPlacementUtils.gd")
const AGTurret = preload("res://source/match/units/AntiGroundTurret.gd")
const AGTurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const WATCHDOG_S = 20.0
const MAX_SEARCH_MS = 2000


class Blocker:
	extends Node3D
	var radius = 10000.0


var _match = null
var _failures = []
var _heartbeat_ms = 0
var _watchdog = Thread.new()
var _done = false


func _ready():
	_heartbeat_ms = Time.get_ticks_msec()
	_watchdog.start(_watch)
	preload("res://source/data-model/GameData.gd").register_generated_scenes()
	var settings = MatchSettings.new()
	for personality in ["turtle", "balanced"]:
		var player_settings = PlayerSettings.new()
		player_settings.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		player_settings.ai_personality = personality
		player_settings.color = Constants.Player.COLORS[settings.players.size()]
		settings.players.append(player_settings)
	settings.visible_player = 0
	FeatureFlags.handle_match_end = false
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load("res://source/match/maps/PlainAndSimple.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	for _i in range(30):
		await get_tree().physics_frame
	_check()
	_finish()


func _process(_delta):
	_heartbeat_ms = Time.get_ticks_msec()


func _watch():
	while not _done:
		OS.delay_msec(500)
		if Time.get_ticks_msec() - _heartbeat_ms > WATCHDOG_S * 1000.0:
			print(
				"PLACEMENT FAIL main thread hung for %ds (placement search never ends)" % WATCHDOG_S
			)
			OS.kill(OS.get_process_id())
			return


func _check():
	var terrain = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	var center = Vector3(27, 0, 27)
	_expect_found(
		Placement.find_valid_position_radially(center, 1.0, terrain, get_tree()), "open map"
	)

	var blocker = Blocker.new()
	blocker.add_to_group("resource_units")
	add_child(blocker)
	_expect_none(
		"AI structure search",
		func(): return Placement.find_valid_position_radially(center, 2.5, terrain, get_tree())
	)
	_expect_none(
		"factory exit search",
		func():
			return Placement.find_valid_position_radially_yet_skip_starting_radius(
				center, 2.0, 0.6, 0.1, Vector3(0, 0, 1), false, terrain, get_tree()
			)
	)
	# the AI asks for a turret with no room left: it must give up and pause its searches
	var ai = get_tree().get_nodes_in_group("players")[0]
	var defense = ai.find_child("DefenseController", true, false)
	if defense == null:
		_failures.append("no DefenseController on the AI")
	else:
		ai.add_resources(Constants.Match.Units.CONSTRUCTION_COSTS[AGTurretScene.resource_path])
		var turrets_before = _count_turrets(ai)
		var start = Time.get_ticks_msec()
		defense._construct_turret(AGTurretScene)
		defense._construct_turret(AGTurretScene)  # paused: must not search again
		if _count_turrets(ai) != turrets_before:
			_failures.append("AI placed a turret although there was no room")
		if not defense._no_room:
			_failures.append("AI did not pause its searches after finding no room")
		if Time.get_ticks_msec() - start > MAX_SEARCH_MS * 2:
			_failures.append("AI turret search took %d ms" % (Time.get_ticks_msec() - start))
	blocker.queue_free()


func _count_turrets(player):
	return (
		get_tree()
		. get_nodes_in_group("units")
		. filter(func(unit): return unit.player == player and unit is AGTurret)
		. size()
	)


func _expect_found(position, what):
	if position == Vector3.INF:
		_failures.append("%s: found no spot on an empty map" % what)


func _expect_none(what, search):
	var start = Time.get_ticks_msec()
	var position = search.call()
	var took = Time.get_ticks_msec() - start
	print("PLACEMENT %s gave %s in %d ms" % [what, position, took])
	if position != Vector3.INF:
		_failures.append("%s: returned %s on a full map" % [what, position])
	if took > MAX_SEARCH_MS:
		_failures.append("%s: took %d ms" % [what, took])


func _finish():
	_done = true
	_watchdog.wait_to_finish()
	if _failures.is_empty():
		print("PLACEMENT ok")
	for failure in _failures:
		print("PLACEMENT FAIL " + failure)
	get_tree().quit(0 if _failures.is_empty() else 1)
