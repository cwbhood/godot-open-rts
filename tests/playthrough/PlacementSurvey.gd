extends Node

# Checks every deposit on every map: can its extractor be placed next to it the way the
# hover auto-pick does it (see StructurePlacementHandler._snap_blueprint_next_to_deposit)?
#
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
#     res://tests/playthrough/PlacementSurvey.tscn
#
# Prints one line per map and kind, and every deposit nobody can build on. Exits with
# code 1 if any deposit next to which nothing fits.

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const GameData = preload("res://source/data-model/GameData.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")

const GAP_M = 0.6  # StructurePlacementHandler.AUTO_PICK_GAP_M
const STEPS = 12  # StructurePlacementHandler.AUTO_PICK_SNAP_STEPS

var _blocked = 0
var _wait_s = 0.0  # let the match run this long first (sites, city houses, rebakes)
var _verbose = false


func _ready():
	var only = ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--map="):
			only = argument.trim_prefix("--map=")
		if argument.begins_with("--wait="):
			_wait_s = float(argument.trim_prefix("--wait="))
		if argument == "--verbose":
			_verbose = true
	for map_path in Constants.Match.MAPS:
		var map_id = map_path.get_file().get_basename().to_snake_case()
		if only != "" and map_id != only:
			continue
		await _survey(map_path)
	print("SURVEY done, {0} deposit(s) with no room for their extractor".format([_blocked]))
	get_tree().quit(1 if _blocked > 0 else 0)


func _survey(map_path):
	var settings = MatchSettings.new()
	for index in range(2):
		var player_settings = PlayerSettings.new()
		player_settings.controller = (
			Constants.PlayerType.HUMAN if index == 0 else Constants.PlayerType.NONE
		)
		player_settings.color = Constants.Player.COLORS[index]
		settings.players.append(player_settings)
	settings.players[1].controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
	var a_match = load("res://source/match/Match.tscn").instantiate()
	a_match.settings = settings
	a_match.map = load(map_path).instantiate()
	add_child(a_match)
	for _i in range(20 + int(_wait_s * 60)):
		await get_tree().physics_frame
	var navmap = a_match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	var per_kind = {}
	for deposit in get_tree().get_nodes_in_group("deposits"):
		var scene_path = _extractor_for(deposit.kind)
		if scene_path == null:
			continue
		var probe = load(scene_path).instantiate()
		var radius = probe.radius
		probe.free()
		var obstacles = (
			get_tree().get_nodes_in_group("units")
			+ get_tree().get_nodes_in_group("resource_units")
			+ get_tree().get_nodes_in_group("city_buildings")
		)
		var reasons = {}
		var valid = 0
		var center = deposit.global_position * Vector3(1, 0, 1)
		for step in range(2 * STEPS):
			var angle = step * PI / STEPS
			var spot = (
				center
				+ Vector3(0, 0, 1).rotated(Vector3.UP, angle) * (deposit.radius + radius + GAP_M)
			)
			var result = Utils.Match.Unit.Placement.validate_agent_placement_position(
				spot, radius, obstacles, navmap
			)
			if result == Utils.Match.Unit.Placement.VALID:
				if Extractor.find_deposit_near(scene_path, spot, radius, get_tree()) == deposit:
					valid += 1
				else:
					reasons["other deposit"] = reasons.get("other deposit", 0) + 1
			else:
				var key = ["valid", "collides", "not navigable"][result]
				reasons[key] = reasons.get(key, 0) + 1
		var tally = per_kind.get(deposit.kind, [0, 0])
		tally[0] += 1
		if _verbose:
			print(
				(
					"SURVEY   %s at %s: %d valid, %s"
					% [deposit.kind, center.snapped(Vector3.ONE * 0.1), valid, reasons]
				)
			)
		if valid == 0:
			tally[1] += 1
			_blocked += 1
			print(
				(
					"SURVEY %s: %s deposit at %s (r=%.1f) has no spot for %s: %s"
					% [
						map_path.get_file(),
						deposit.kind,
						center.snapped(Vector3.ONE * 0.1),
						deposit.radius,
						scene_path.get_file(),
						reasons
					]
				)
			)
		per_kind[deposit.kind] = tally
	for kind in per_kind:
		print(
			(
				"SURVEY %s %s: %d deposits, %d blocked"
				% [map_path.get_file(), kind, per_kind[kind][0], per_kind[kind][1]]
			)
		)
	a_match.queue_free()
	for _i in range(5):
		await get_tree().process_frame


func _extractor_for(kind):
	for entry in GameData.producible_by("worker"):
		if kind in entry.get("extracts", []):
			return entry["scene"]
	return null
