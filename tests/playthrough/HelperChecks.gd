extends "res://tests/playtest/PlaytestChecks.gd"

# Bot checks for the helper (source/match/players/human/Helper.gd) in a running match:
# - at peace it runs the economy, builds the army it was asked for and a scout, and
#   never attacks: no hits on the neutral rival, the relation stays neutral,
# - at war, a constructor sent by hand to a site behind an enemy squad that the scout
#   has seen is rerouted or held back and never gets near the squad,
# - a constructor whose site is threatened waits and resumes once the enemies are gone,
# - a constructor that enemies come close to is pulled back,
# - its scout holds fire next to enemies at war,
# - frame time with the helper on versus off.
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . \
#     res://tests/playthrough/HelperChecks.tscn -- --out=/tmp/helper
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const Helper = preload("res://source/match/players/human/Helper.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Constructing = preload("res://source/match/units/actions/Constructing.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
const AttackingWhileInRange = preload("res://source/match/units/actions/AttackingWhileInRange.gd")
const AutoExpand = preload("res://source/match/units/traits/AutoExpand.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const GameData = preload("res://source/data-model/GameData.gd")
const TankScene = preload("res://source/match/units/Tank.tscn")
const VehicleFactoryScene = preload("res://source/match/units/VehicleFactory.tscn")

var _rival = null
var _helper = null
var _panel = null
var _hits_by_human = 0
var _attack_actions_seen = 0


func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	_match = load("res://tests/playthrough/HelperMatch.tscn").instantiate()  # room for detours
	add_child(_match)
	await _frames(30)
	_human = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)[0]
	_rival = get_tree().get_nodes_in_group("players").filter(func(p): return p != _human)[0]
	_make_rival_inert()
	_helper = Helper.of(_human)
	_panel = _match.find_child("HelperPanel", true, false)
	MatchSignals.unit_damaged.connect(_on_unit_damaged)
	get_tree().physics_frame.connect(_watch_for_attacks)
	var only = ""  # e.g. --only=hold,retreat to run a few scenarios while working on them
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	for scenario in [
		["peace", _check_panel_and_peace],
		["detour", _check_detour_around_squad],
		["hold", _check_hold_and_resume],
		["retreat", _check_retreat],
		["scout", _check_scout_holds_fire],
		["frame", _check_frame_time],
		["manual", _check_manual],
	]:
		if only == "" or scenario[0] in only.split(","):
			await scenario[1].call()
	print("helper checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


# --- scenarios


func _check_panel_and_peace():
	_expect(_helper != null and not _helper.enabled, "every human player has a helper, off")
	_expect(_panel != null and _panel.visible, "the helper panel is on screen")
	if _helper == null or _panel == null:
		return
	await _shot("0-helper-panel-off")
	_rival.attacks_neutrals = false  # a peaceful neighbour: not a threat, not a target
	_human.add_resources({"timber": 200, "iron": 300, "copper": 100, "oil": 200})
	var cc = _own(func(unit): return unit is CommandCenter)
	var factory = VehicleFactoryScene.instantiate()
	factory.set_meta("spawn_constructed", true)
	MatchSignals.setup_and_spawn_unit.emit(
		factory, Transform3D(Basis(), _free_spot_near(cc.global_position, 9.0, 3.0)), _human
	)
	# rival tanks parked in plain view of the base
	var parked = _spawn_squad(_rival, cc.global_position + Vector3(-12, 0, 10), 2)
	_helper.army_target = 4
	_panel.get("_switch").button_pressed = true  # like a click on the switch
	await _frames(5)
	_expect(_helper.enabled, "the panel switch turns the helper on")
	var army_built = await _wait_for(
		func(): return _soldiers().size() >= 4 and _scout() != null, 4800
	)
	_expect(
		army_built,
		(
			"it builds the army size asked for (%d of 4) and a scout (%s)"
			% [_soldiers().size(), _scout()]
		)
	)
	_expect(
		_soldiers().size() <= 4 + 1, "it stops at the army size (%d units)" % _soldiers().size()
	)
	var constructors = _all_own(func(unit): return unit is Worker)
	_expect(
		constructors.all(func(unit): return AutoExpand.is_enabled_on(unit)),
		"it put the idle constructors on auto-expand (%d)" % constructors.size()
	)
	var scout = _scout()
	if scout != null:
		var start = scout.global_position
		await _wait_for(func(): return scout.global_position.distance_to(start) > 15.0, 1200)
		_expect(
			scout.global_position.distance_to(start) > 15.0 and scout.get_meta("hold_fire", false),
			"the scout drives out with orders to hold fire"
		)
	await _frames(600)
	_expect(
		Diplomacy.state_between(_human, _rival) == Diplomacy.State.NEUTRAL,
		"after %d s next to rival tanks the relation is still neutral" % 60
	)
	_expect(_hits_by_human == 0, "no unit of ours hit the rival (%d hits)" % _hits_by_human)
	_expect(_attack_actions_seen == 0, "none of our units got an attack order")
	_expect(_helper.stats["attack_orders"] == 0, "the helper counts no attack orders")
	camera_on(cc.global_position + Vector3(0, 0, 4), 22.0)
	_panel.call("_set_collapsed", false)
	await _frames(30)
	await _shot("1-helper-on-economy-and-army")
	for tank in parked:
		if is_instance_valid(tank):
			tank.queue_free()
	_rival.attacks_neutrals = true


func _check_detour_around_squad():
	await _at_war_with_helper_on()
	var worker = _idle_constructor()
	# far enough that neither end is within the danger radius of a squad half-way
	var site = _lay_out_site_away_from(worker.global_position, 54.0)
	_expect(site != null, "laid out a site about 50 m from a constructor")
	if site == null:
		return
	var middle = worker.global_position.lerp(site.global_position, 0.5) * Vector3(1, 0, 1)
	var squad = _spawn_squad(_rival, middle, 4)
	_spawn_spotter(middle, worker.global_position)
	await _frames(60)
	_expect(
		_helper.known_threats() >= 2,
		"the spotter's sighting is known: %d" % _helper.known_threats()
	)
	var detours_before = _helper.stats["detours"] + _helper.stats["holds"]
	worker.action = Constructing.new(site)
	var closest = [INF]
	var watch = func():
		for tank in squad:
			if is_instance_valid(tank) and is_instance_valid(worker):
				closest[0] = min(
					closest[0], tank.global_position_yless.distance_to(worker.global_position_yless)
				)
		return false
	await _wait_for(
		func():
			watch.call()
			return _helper.stats["detours"] + _helper.stats["holds"] > detours_before,
		600
	)
	_expect(
		_helper.stats["detours"] + _helper.stats["holds"] > detours_before,
		(
			"the order through the squad was rerouted or held back (detours %d, holds %d)"
			% [_helper.stats["detours"], _helper.stats["holds"]]
		)
	)
	camera_on(middle, 30.0)
	await _frames(40)
	await _shot("2-constructor-rerouted-around-squad")
	await _wait_for(
		func():
			watch.call()
			return (
				not is_instance_valid(worker)
				or not is_instance_valid(site)
				or Utils.Match.Unit.Movement.units_adhere(worker, site)
			),
		3600
	)
	print("  latest alert: ", _helper.alerts[0]["text"] if not _helper.alerts.is_empty() else "-")
	print("  helper stats: ", _helper.stats)
	print(
		"  worker ",
		worker.name,
		" site at ",
		site.global_position.round(),
		" squad at ",
		middle.round()
	)
	for event in _helper.events:
		print("    ", event)
	_expect(is_instance_valid(worker), "the constructor survived")
	_expect(
		closest[0] > 12.0, "it never came within 12 m of the squad (closest %.1f m)" % closest[0]
	)
	_expect(_helper.stats["detours"] > 0, "it went around the squad")
	_expect(
		(
			is_instance_valid(site)
			and is_instance_valid(worker)
			and Utils.Match.Unit.Movement.units_adhere(worker, site)
		),
		"and reached the site behind the squad"
	)
	_expect(not _helper.alerts.is_empty(), "the player was told")
	for tank in squad:
		if is_instance_valid(tank):
			tank.queue_free()
	if is_instance_valid(site) and not site.is_constructed():
		site.cancel_construction()
	await _frames(60)


func _check_hold_and_resume():
	await _at_war_with_helper_on()
	var worker = _idle_constructor()
	var site = _lay_out_site_away_from(worker.global_position, 30.0)
	if site == null:
		_expect(false, "laid out a site for the hold check")
		return
	# beyond the tanks' sight (8 m), so they leave the site alone, but well inside danger
	var near_site = site.global_position * Vector3(1, 0, 1) + Vector3(8, 0, 8)
	var squad = _spawn_squad(_rival, near_site, 3)
	for tank in squad:
		tank.set_meta("hold_fire", true)  # so they do not shoot the site (1 hit point)
	_spawn_spotter(near_site, worker.global_position)
	await _frames(60)
	if not is_instance_valid(site):
		_expect(false, "the site for the hold check still stands")
		return
	var holds_before = _helper.stats["holds"]
	worker.action = Constructing.new(site)
	print(
		(
			"  threats known %d, site in danger %s"
			% [_helper.known_threats(), _helper.is_dangerous(site.global_position)]
		)
	)
	var held = await _wait_for(func(): return _helper.stats["holds"] > holds_before, 300)
	print("  helper stats: ", _helper.stats)
	_expect(held, "an order to a site next to enemies is held back")
	await _frames(120)
	_expect(
		is_instance_valid(site) and site.get_construction_progress() == 0.0,
		"it does not go there while they stay"
	)
	for tank in squad:
		if is_instance_valid(tank):
			tank.queue_free()
	var resumed = await _wait_for(
		func():
			return (
				is_instance_valid(worker)
				and worker.action is Constructing
				and worker.action.get("_target_unit") == site
			),
		1500
	)
	_expect(resumed, "it resumes the order once the spot is seen empty")
	if is_instance_valid(site):
		site.cancel_construction()
	worker.action = null
	await _frames(30)


func _check_retreat():
	await _at_war_with_helper_on()
	var worker = _idle_constructor()
	var retreats_before = _helper.stats["retreats"]
	var away = worker.global_position + Vector3(9, 0, 0)
	var tank = _spawn_squad(_rival, away, 1)[0]
	tank.set_meta("hold_fire", true)  # keep it from chasing so the check stays simple
	_spawn_spotter(away, worker.global_position + Vector3(0, 0, 20))
	await _wait_for(func(): return _helper.stats["retreats"] > retreats_before, 300)
	_expect(
		_helper.stats["retreats"] > retreats_before,
		"a constructor with an enemy 9 m away is pulled back"
	)
	await _frames(240)
	_expect(
		(
			is_instance_valid(worker)
			and worker.global_position_yless.distance_to(away * Vector3(1, 0, 1)) > 11.0
		),
		"and gets away from where it was (the base guns may have killed it meanwhile)"
	)
	if is_instance_valid(tank):
		tank.queue_free()
	await _frames(30)


func _check_scout_holds_fire():
	var scout = _scout()
	if scout == null:
		_expect(false, "a scout exists for the hold-fire check")
		return
	var tank = _spawn_squad(_rival, scout.global_position + Vector3(4, 0, 0), 1)[0]
	tank.set_meta("hold_fire", true)
	var attacking = [0]
	await _wait_for(
		func():
			if is_instance_valid(scout) and scout.action != null:
				var sub = scout.action.get("_sub_action")
				if (
					scout.action is AutoAttacking
					or scout.action is AttackingWhileInRange
					or sub is AutoAttacking
					or sub is AttackingWhileInRange
				):
					attacking[0] += 1
			return false,
		240
	)
	_expect(attacking[0] == 0, "the scout never attacks an enemy tank next to it at war")
	if is_instance_valid(tank):
		tank.queue_free()


func _check_frame_time():
	"""the same match state measured with the helper off and then on"""
	_helper.enabled = false
	var frame_ms_off = await _average_frame_ms(150)
	_helper.enabled = true
	await _frames(10)
	var thinks_before = _helper.stats["thinks"]
	var usec_before = _helper.stats["think_usec_total"]
	var frame_ms_on = await _average_frame_ms(150)
	var thinks = max(1, _helper.stats["thinks"] - thinks_before)
	var per_tick_ms = (_helper.stats["think_usec_total"] - usec_before) / 1000.0 / thinks
	print(
		(
			"  frame time: helper off %.1f ms, on %.1f ms; the helper itself %.3f ms per tick"
			% [frame_ms_off, frame_ms_on, per_tick_ms]
		)
	)
	_expect(per_tick_ms < 2.0, "the helper costs under 2 ms per half-second tick")


func _check_manual():
	var guide = _match.find_child("Guide", true, false)
	guide.toggle_help("HELPER", true)
	await _frames(20)
	var body = guide.help_window.get("_body").text
	_expect("never attacks" in body, "the manual has a helper section")
	await _shot("3-manual-helper")
	guide.help_window.hide()


# --- helpers


func _at_war_with_helper_on():
	if not Diplomacy.at_war(_human, _rival):
		Diplomacy.instance.declare_war(_rival, _human)
	_helper.enabled = true
	await _frames(5)


func _make_rival_inert():
	"""no controllers: its units only do what this test tells them"""
	_rival.set_process(false)
	for child in _rival.get_children():
		if child.name.ends_with("Controller"):
			child.queue_free()


func _spawn_squad(player, center, count):
	var squad = []
	for index in range(count):
		var tank = TankScene.instantiate()
		var offset = Vector3(cos(index * 2.1), 0, sin(index * 2.1)) * (1.6 if index > 0 else 0.0)
		var spot = NavigationServer3D.map_get_closest_point(_terrain_map(), center + offset)
		MatchSignals.setup_and_spawn_unit.emit(tank, Transform3D(Basis(), spot), player)
		squad.append(tank)
	return squad


func _spawn_spotter(target, from):
	"""a human buggy 9.5 m to the side of 'target': it sees the squad from outside their sight"""
	var entry = GameData.unit_by_id("scout_buggy")
	var buggy = load(entry["scene"]).instantiate()
	buggy.set_meta("hold_fire", true)
	var direction = ((from - target) * Vector3(1, 0, 1)).normalized()
	var spot = NavigationServer3D.map_get_closest_point(
		_terrain_map(), target + Vector3(-direction.z, 0, direction.x) * 9.5
	)
	MatchSignals.setup_and_spawn_unit.emit(buggy, Transform3D(Basis(), spot), _human)
	return buggy


func _lay_out_site_away_from(origin, distance):
	"""a pylon site about 'distance' from 'origin' on free ground away from the rival's
	guns, null if none fits"""
	var best = null
	var size = _match.map.size
	for x in range(4, int(size.x) - 4, 3):
		for z in range(4, int(size.y) - 4, 3):
			var spot = Vector3(x, 0, z)
			var off = abs(spot.distance_to(origin * Vector3(1, 0, 1)) - distance)
			if off > 8.0 or (best != null and off >= best[0]):
				continue
			if _is_free(spot, 1.5) and not _near_rival(spot, 32.0):
				best = [off, spot]
	if best == null:
		return null
	var site = PylonScene.instantiate()
	site.set_meta("placed_by_hand", true)
	MatchSignals.setup_and_spawn_unit.emit(site, Transform3D(Basis(), best[1]), _human)
	return site


func _idle_constructor():
	"""the first constructor, off auto-expand, standing next to the command center"""
	var worker = _own(func(unit): return unit is Worker)
	var cc = _own(func(unit): return unit is CommandCenter)
	worker.global_position = NavigationServer3D.map_get_closest_point(
		_terrain_map(), cc.global_position + Vector3(4, 0, 4)
	)
	AutoExpand.set_enabled_on(worker, false)
	worker.set_meta("auto_expand_opt_out", true)  # as if the player switched it off
	worker.action = null
	return worker


func _free_spot_near(origin, distance, radius):
	for step in range(24):
		var angle = TAU * step / 24.0
		var spot = origin + Vector3(cos(angle), 0, sin(angle)) * distance
		if _is_free(spot, radius):
			return spot
	return origin + Vector3(distance, 0, 0)


func _near_rival(spot, distance):
	"""rival buildings and units shoot sites (one hit point) that come too close"""
	return get_tree().get_nodes_in_group("units").any(
		func(unit):
			return (
				unit.player == _rival
				and unit.global_position_yless.distance_to(spot * Vector3(1, 0, 1)) < distance
			)
	)


func _is_free(spot, radius):
	var size = _match.map.size
	if spot.x < 3 or spot.z < 3 or spot.x > size.x - 3 or spot.z > size.y - 3:
		return false
	return (
		Utils.Match.Unit.Placement.validate_agent_placement_position(
			spot,
			radius,
			(
				get_tree().get_nodes_in_group("units")
				+ get_tree().get_nodes_in_group("resource_units")
				+ get_tree().get_nodes_in_group("city_buildings")
			),
			_terrain_map()
		)
		== Utils.Match.Unit.Placement.VALID
	)


func _soldiers():
	return _all_own(func(unit): return _helper._is_soldier(unit))


func _scout():
	var scout = _helper.get("_scout")
	return scout if scout != null and is_instance_valid(scout) else null


func _all_own(predicate):
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == _human and predicate.call(unit)
	)


func _average_frame_ms(frames):
	var started = Time.get_ticks_usec()
	await _frames(frames)
	return (Time.get_ticks_usec() - started) / 1000.0 / frames


func _terrain_map():
	return _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)


func _on_unit_damaged(unit):
	if unit.player == _rival and unit.last_attacker_player == _human:
		_hits_by_human += 1


func _watch_for_attacks():
	"""while at peace no unit of ours may be attacking anything"""
	if Diplomacy.state_between(_human, _rival) != Diplomacy.State.NEUTRAL:
		return
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player != _human or unit.action == null:
			continue
		var sub = unit.action.get("_sub_action")
		if (
			unit.action is AutoAttacking
			or unit.action is AttackingWhileInRange
			or sub is AutoAttacking
			or sub is AttackingWhileInRange
		):
			_attack_actions_seen += 1
