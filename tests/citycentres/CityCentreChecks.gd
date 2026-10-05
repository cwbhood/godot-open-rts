extends Node

# Plays through the city centre rules in a running match (see CityCentres.gd): the limit of
# two city centres and their spacing, the AI rebuilding after losing its city centre, the
# white flag on an undefended city, defenders lowering it, the capture of the city with
# its buildings and houses, abandoning what lies outside a new circle, save and restore of
# the countdowns, and defeat when the countdown runs out. Saves screenshots.
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
#     res://tests/citycentres/CityCentreChecks.tscn -- --out=/tmp/citycentres
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const Human = preload("res://source/match/players/human/Human.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const TankScene = preload("res://source/match/units/Tank.tscn")
const Structure = preload("res://source/match/units/Structure.gd")
const CityCentres = preload("res://source/match/city/CityCentres.gd")
const GameData = preload("res://source/data-model/GameData.gd")

var _failures = 0
var _out = "user://citycentres"
var _match = null
var _centres = null
var _human = null
var _rival = null
var _signals = {}


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS  # keeps checking after the defeat screen pauses
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	for signal_name in [
		"city_centre_countdown_started",
		"city_rebuilt",
		"player_defeated",
		"city_surrender_started",
		"city_surrender_ended",
		"city_captured",
	]:
		_signals[signal_name] = []
		MatchSignals.get(signal_name).connect(
			func(a = null, b = null, c = null): _signals[signal_name].append([a, b, c])
		)
	_check_data()
	await _start_match()
	await _check_limit_and_spacing()
	await _check_ai_rebuilds()
	await _check_surrender_and_capture()
	await _check_rebuild_elsewhere_abandons()
	await _check_save_restore()
	await _check_defeat()
	print("city centre checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_data():
	var config = GameData.city_centres()
	_expect(int(config["max_per_player"]) == 2, "up to two city centres per player")
	_expect(float(config["rebuild_countdown_s"]) == 180.0, "3 minutes to rebuild")
	_expect(float(config["surrender_countdown_s"]) == 15.0, "15 seconds of white flag")
	_expect(float(config["radius_m"]) > 0.0, "city centres have a circle")


func _start_match():
	_match = load("res://tests/caps/CapsMatch.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await _frames(40)
	_centres = CityCentres.of(get_tree())
	_expect(_centres != null, "the match has the city centre rules")
	var players = get_tree().get_nodes_in_group("players")
	_human = players.filter(func(p): return p is Human)[0]
	_rival = players.filter(func(p): return not p is Human)[0]
	_human.add_resources({"timber": 400, "iron": 400, "copper": 400, "oil": 400})
	_rival.add_resources({"timber": 400, "iron": 400, "copper": 400, "oil": 400})
	_match.find_child("Diplomacy", true, false).declare_war(_human, _rival)


func _check_limit_and_spacing():
	var home = _centres.centres_of(_human)[0]
	_expect(_centres.can_place_more(_human), "one city centre: another one may be built")
	_expect(_human.can_produce(CommandCenterScene.resource_path), "the build menu offers it")
	_expect(
		_centres.too_close_to_own_centre(_human, home.global_position + Vector3(8, 0, 0)),
		"a second city centre right next to the first is refused"
	)
	var handler = _human.get_node("StructurePlacementHandler")
	handler._start_structure_placement(CommandCenterScene)
	handler._active_blueprint_node.global_position = home.global_position + Vector3(8, 0, 0)
	_expect(
		(
			handler._calculate_blueprint_position_validity()
			== handler.BlueprintPositionValidity.TOO_CLOSE_TO_CITY_CENTRE
		),
		"the blueprint says it is too close"
	)
	var second_spot = _free_spot_near(home.global_position + _away_from_rival(home) * 26.0)
	handler._active_blueprint_node.global_position = second_spot
	_focus(second_spot)
	await _shot("1-second-city-centre-blueprint")
	handler._cancel_structure_placement()
	var second = _spawn(CommandCenterScene, second_spot, _human, true)
	await _frames(10)
	_expect(_centres.centres_of(_human).size() == 2, "the second city centre stands")
	_expect(not _centres.can_place_more(_human), "two city centres: the limit is reached")
	_expect(
		not _human.can_produce(CommandCenterScene.resource_path),
		"the build menu greys out a third one"
	)
	handler._start_structure_placement(CommandCenterScene)
	handler._active_blueprint_node.global_position = home.global_position  # inside the map
	_expect(
		(
			handler._calculate_blueprint_position_validity()
			== handler.BlueprintPositionValidity.CITY_CENTRE_LIMIT
		),
		"a third blueprint is refused"
	)
	handler._cancel_structure_placement()
	_focus(home.global_position.lerp(second.global_position, 0.5))
	await _shot("2-two-city-circles")


func _check_ai_rebuilds():
	var old = _centres.centres_of(_rival)[0]
	var site = old.global_position_yless
	old.hp = 0  # destroyed
	var started = await _wait_for(func(): return _centres.rebuild_time_left(_rival) > 0.0, 60)
	_expect(started, "losing its only city centre starts the AI's rebuild countdown")
	_expect(
		_signals["city_centre_countdown_started"].any(func(s): return s[0] == _rival),
		"the countdown is announced"
	)
	var placed = await _wait_for(
		func(): return not _centres.centres_of(_rival, true).is_empty(), 60 * 30
	)
	_expect(placed, "the AI lays out a new city centre")
	if not placed:
		return
	var new_site = _centres.centres_of(_rival, true)[0]
	_expect(
		new_site.global_position_yless.distance_to(site) <= _centres.radius(),
		"... inside the old circle, so it keeps its city ({0} m from the old one)".format(
			[snapped(new_site.global_position_yless.distance_to(site), 0.1)]
		)
	)
	_finish(new_site)
	var ended = await _wait_for(func(): return _centres.rebuild_time_left(_rival) < 0.0, 60)
	_expect(ended, "a finished city centre ends the countdown")
	var rebuilt = _signals["city_rebuilt"].filter(func(s): return s[0] == _rival)
	_expect(
		not rebuilt.is_empty() and rebuilt[-1][1] > 0,
		"the AI kept the buildings of its old city ({0})".format([str(rebuilt)])
	)


func _check_surrender_and_capture():
	_quiet_rival()
	var centre = _centres.centres_of(_rival)[0]
	_clear_defenders(centre)
	if _rival.city._buildings.is_empty():  # rebuilt away from its houses: give it one
		var spot = _rival.city._find_building_position(centre)
		if spot != null:
			_rival.city._add_building("house", spot)
	var houses_before = _rival.city._buildings.size()
	_expect(houses_before > 0, "the AI city has houses ({0})".format([houses_before]))
	_centres.config["surrender_countdown_s"] = 4.0
	var tanks = []
	for i in range(3):
		var offset = Vector3(cos(i * 2.0), 0, sin(i * 2.0)) * (centre.radius + 4.0)
		tanks.append(_spawn(TankScene, _free_spot_near(centre.global_position + offset), _human))
	await _frames(5)
	centre.take_damage(1, tanks[0])
	var raised = await _wait_for(func(): return _centres.is_surrendering(centre), 60)
	_expect(raised, "an attacked city centre without defenders raises the white flag")
	_expect(centre.get_node_or_null("SurrenderFlag") != null, "the flag is on the building")
	var hp = centre.hp
	centre.take_damage(5, tanks[0])
	_expect(centre.hp == hp, "a city under the white flag takes no damage")
	_focus(centre.global_position)
	await _shot("3-white-flag")
	var defender = _spawn(
		TankScene, _free_spot_near(centre.global_position + Vector3(0, 0, -5)), _rival
	)
	var lowered = await _wait_for(func(): return not _centres.is_surrendering(centre), 60)
	_expect(lowered, "a defender reaching the circle lowers the flag")
	_expect(not centre.has_meta("surrendering"), "... and the city can be hit again")
	defender.queue_free()
	await _frames(5)
	centre.take_damage(1, tanks[0])
	await _wait_for(func(): return _centres.is_surrendering(centre), 60)
	var captured = await _wait_for(func(): return not _signals["city_captured"].is_empty(), 60 * 12)
	_expect(captured, "after the countdown the city surrenders")
	if not captured:
		return
	var event = _signals["city_captured"][-1]
	var new_centre = event[0]
	_expect(event[1] == _rival and event[2] == _human, "it goes to the attacker")
	_expect(
		is_instance_valid(new_centre) and new_centre.player == _human,
		"the city centre is the attacker's now"
	)
	var left_inside = get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return (
				unit.player == _rival
				and unit is Structure
				and (
					unit.global_position_yless.distance_to(new_centre.global_position_yless)
					<= _centres.radius()
				)
			)
	)
	_expect(left_inside.is_empty(), "every building in its circle changed hands")
	_expect(
		_rival.city._buildings.size() < houses_before,
		"the houses went with it ({0} -> {1} for the AI)".format(
			[houses_before, _rival.city._buildings.size()]
		)
	)
	_expect(
		_centres.centres_of(_human).size() == 3, "capturing may take a player past two city centres"
	)
	_expect(
		await _wait_for(func(): return _centres.rebuild_time_left(_rival) > 0.0, 60),
		"the AI has to rebuild now"
	)
	await _frames(20)
	_focus(new_centre.global_position)
	await _shot("4-city-captured")


func _check_rebuild_elsewhere_abandons():
	var far_spot = _free_spot_near(_far_corner_for(_rival))
	var before = _structures_of(_rival).size()
	var centre = _spawn(CommandCenterScene, far_spot, _rival, true)
	var ended = await _wait_for(func(): return _centres.rebuild_time_left(_rival) < 0.0, 60)
	_expect(ended, "the AI's new city centre far away ends its countdown")
	await _frames(5)
	var outside = _structures_of(_rival).filter(
		func(unit):
			return unit != centre and _centres.centre_covering(_rival, unit.global_position) == null
	)
	_expect(
		outside.is_empty(),
		"buildings outside the new circle are abandoned ({0} before, {1} now)".format(
			[before, _structures_of(_rival).size()]
		)
	)
	var houses_outside = _rival.city._buildings.filter(
		func(b): return _centres.centre_covering(_rival, b.global_position) == null
	)
	_expect(houses_outside.is_empty(), "houses outside the circle are abandoned too")


func _check_save_restore():
	var human_centres = _centres.centres_of(_human)
	for centre in human_centres:
		centre.hp = 0
	var started = await _wait_for(func(): return _centres.rebuild_time_left(_human) > 0.0, 60)
	_expect(started, "losing all of your city centres starts your countdown")
	_expect(_centres.lost_sites(_human).size() == 3, "the three old circles are marked")
	var banner = _centres.get_node("CityCentreBanner/Banner")
	await _frames(5)
	_expect(
		banner.visible and "build a new one" in banner.text,
		"the countdown is on screen ('{0}')".format([banner.text])
	)
	_focus(_centres.lost_sites(_human)[0])
	await _shot("5-rebuild-countdown")
	var players = get_tree().get_nodes_in_group("players")
	var saved = JSON.parse_string(JSON.stringify(_centres.capture(players, {})))
	var left = _centres.rebuild_time_left(_human)
	_centres.countdowns.clear()
	_centres._had_centre.clear()
	_centres.restore(saved, players, [])
	_expect(
		abs(_centres.rebuild_time_left(_human) - left) < 0.5,
		"the countdown survives saving and loading ({0} s)".format([int(left)])
	)
	_expect(_centres.lost_sites(_human).size() == 3, "... with the old circles")


func _check_defeat():
	_centres.countdowns[_human]["left_s"] = 0.5
	var defeated = await _wait_for(
		func(): return _signals["player_defeated"].any(func(s): return s[0] == _human), 120
	)
	_expect(defeated, "when the countdown runs out the player is defeated")
	await _frames(5)
	_expect(
		get_tree().get_nodes_in_group("units").all(func(unit): return unit.player != _human),
		"everything the player had left is lost"
	)
	var end_handler = _match.find_child("MatchEndHandler", true, false)
	_expect(
		(
			end_handler != null
			and end_handler.visible
			and end_handler.find_child("Defeat", true, false).visible
		),
		"the match ends in defeat"
	)
	await _shot("6-defeat")


# helpers


func _quiet_rival():
	"""the AI stops thinking, so it neither defends nor rebuilds during the next checks"""
	for child in _rival.get_children():
		if child.name.ends_with("Controller"):
			child.process_mode = Node.PROCESS_MODE_DISABLED
	if _rival.city != null and _rival.city.civil_defense != null:
		_rival.city.civil_defense.process_mode = Node.PROCESS_MODE_DISABLED


func _clear_defenders(centre):
	for unit in _centres.defenders_near(centre):
		unit.queue_free()


func _spawn(scene, position, player, constructed = false):
	var unit = scene.instantiate()
	if constructed:
		unit.set_meta("spawn_constructed", true)
	MatchSignals.setup_and_spawn_unit.emit(unit, Transform3D(Basis(), position), player)
	return unit


func _finish(site):
	site._construction_progress = 1.0
	site.hp = site.hp_max
	site._finish_construction()


func _structures_of(player):
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player and unit is Structure
	)


func _away_from_rival(home):
	var rival_centre = null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit is CommandCenter and unit.player == _rival:
			rival_centre = unit
	if rival_centre == null:
		return Vector3(1, 0, 0)
	return (home.global_position_yless - rival_centre.global_position_yless).normalized()


func _far_corner_for(player):
	var size = _match.map.size
	var centre = (
		_centres.lost_sites(player)[0]
		if not _centres.lost_sites(player).is_empty()
		else Vector3.ZERO
	)
	var best = null
	for corner in [
		Vector3(8, 0, 8),
		Vector3(size.x - 8, 0, 8),
		Vector3(8, 0, size.y - 8),
		Vector3(size.x - 8, 0, size.y - 8)
	]:
		var far_from_humans = _centres.centres_of(_human).all(
			func(c): return c.global_position_yless.distance_to(corner) > _centres.radius() * 2.0
		)
		if (
			far_from_humans
			and (best == null or corner.distance_to(centre) > best.distance_to(centre))
		):
			best = corner
	return best if best != null else Vector3(size.x * 0.5, 0, size.y * 0.5)


func _free_spot_near(position):
	var spot = Utils.Match.Unit.Placement.find_valid_position_radially(
		position * Vector3(1, 0, 1),
		2.5,
		_match.navigation.get_navigation_map_rid_by_domain(
			Constants.Match.Navigation.Domain.TERRAIN
		),
		get_tree()
	)
	return spot if spot != Vector3.INF else position


func _focus(position):
	_match.get_node("IsometricCamera3D").set_position_safely(position)


func _expect(condition, description):
	print(("PASS " if condition else "FAIL ") + description)
	if not condition:
		_failures += 1


func _wait_for(predicate, max_frames):
	for _i in range(max_frames):
		if predicate.call():
			return true
		await get_tree().process_frame
	return predicate.call()


func _shot(shot_name):
	var guide = _match.find_child("Guide", true, false)
	if guide != null:  # the tutorial and hints would cover the flag over the building
		guide.get("_tutorial").hide()
		guide.get("_hint_panel").hide()
	await _frames(5)
	var path = "{0}/{1}.png".format([_out, shot_name])
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
