extends Node

# Checks the playtest fixes in a running match and saves screenshots of them.
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . \
#     res://tests/playtest/PlaytestChecks.tscn -- --out=/tmp/playtest
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const Trade = preload("res://source/match/city/Trade.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const Drone = preload("res://source/match/units/Drone.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const AirportScene = preload("res://source/match/units/Airport.tscn")
const PylonScene = preload("res://source/match/units/Pylon.tscn")

var _failures = 0
var _out = "user://playtest"
var _damage_events = []
var _match = null
var _human = null


func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	_match = load("res://tests/manual/TestOneCityOneRival.tscn").instantiate()
	add_child(_match)
	await _frames(30)
	_human = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)[0]
	MatchSignals.unit_damaged.connect(func(unit): _damage_events.append(unit))
	await _check_construction_is_not_an_attack()
	await _check_bigger_menu_and_auto_pick()
	await _check_drone_lands_at_airport()
	await _check_trade_advice()
	print("playtest checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_construction_is_not_an_attack():
	_damage_events.clear()
	var cc = _own(func(unit): return unit.has_method("is_constructed") and unit.find_child("ProductionQueue") != null)
	var site = cc.global_position + Vector3(6, 0, -6)
	_human.add_resources({"iron": 10, "copper": 10})
	MatchSignals.setup_and_spawn_unit.emit(
		PylonScene.instantiate(), Transform3D(Basis(), site), _human
	)
	await _frames(20)
	_expect(_damage_events.is_empty(), "laying out a construction site raises no damage event")
	var pylon = _own(func(unit): return unit.scene_file_path == PylonScene.resource_path)
	pylon.take_damage(1, null)
	_expect(_damage_events.size() == 1, "a real hit still raises a damage event")


func _check_bigger_menu_and_auto_pick():
	var worker = _own(func(unit): return unit is Worker)
	MatchSignals.deselect_all_units.emit()
	worker.find_child("Selection").select()
	await _frames(10)
	var menu = _match.find_child("WorkerMenu", true, false)
	_expect(menu.visible, "worker menu shows")
	_expect(menu.size.x >= 4 * 80, "worker menu is 4 x 80 px wide or more (is %d)" % menu.size.x)
	var camera = get_viewport().get_camera_3d()
	var deposit = _closest_deposit(worker.global_position)
	camera.set_position_safely(deposit.global_position)
	await _frames(10)
	var screen = camera.unproject_position(deposit.global_position)
	var motion = InputEventMouseMotion.new()
	motion.position = screen + Vector2(6, 4)
	motion.global_position = motion.position
	get_viewport().warp_mouse(motion.position)
	Input.parse_input_event(motion)
	await _frames(10)
	var handler = _human.find_child("StructurePlacementHandler")
	var picked = handler.get("_pending_structure_prototype")
	_expect(
		handler.get("_auto_deposit") == deposit and picked != null,
		"hovering a {0} deposit with a constructor picks {1}".format(
			[deposit.kind, picked.resource_path.get_file() if picked != null else "nothing"]
		)
	)
	var blueprint = handler.get("_active_blueprint_node")
	if blueprint != null:
		var gap = (
			(blueprint.global_position * Vector3(1, 0, 1)).distance_to(
				deposit.global_position * Vector3(1, 0, 1)
			)
			- deposit.radius
		)
		_expect(gap < 3.0, "blueprint snapped next to the deposit (gap %.1f m)" % gap)
	await _shot("1-worker-menu-and-auto-pick")
	handler.call("_cancel_structure_placement")


func _check_drone_lands_at_airport():
	MatchSignals.deselect_all_units.emit()
	var drone = _own(func(unit): return unit is Drone)
	var flight = drone.get_node_or_null("FixedWingFlight")
	_expect(flight != null, "drone has limited airtime")
	var helicopter_scene = load("res://source/match/units/Helicopter.tscn")
	_expect(
		not helicopter_scene.resource_path in Constants.Match.Air.FLIGHT_ENDURANCE_S,
		"helicopters fly without an airport"
	)
	var drone_scene = load("res://source/match/units/Drone.tscn").resource_path
	_expect(not _human.can_produce(drone_scene), "drones cannot be produced without an airport")
	var cc = _own(func(unit): return unit.find_child("ProductionQueue") != null)
	var airport = AirportScene.instantiate()
	airport.set_meta("spawn_constructed", true)
	MatchSignals.setup_and_spawn_unit.emit(
		airport, Transform3D(Basis(), cc.global_position + Vector3(-7, 0, 6)), _human
	)
	await _frames(10)
	_expect(_human.can_produce(drone_scene) or not _human.meets_tier_requirement(drone_scene),
		"an airport unlocks drone production")
	drone.action = Moving.new(airport.global_position + Vector3(10, 0, 10))
	await _frames(60)
	flight.fuel_s = 9.0  # low: it has to head home
	var landed = await _wait_for(func(): return flight.landed, 900)
	_expect(landed, "low on fuel the drone flies to the airport and lands")
	camera_on(airport.global_position, 9.0)
	await _frames(40)
	await _shot("2-drone-landed-at-airport")
	var refuelled = await _wait_for(func(): return flight.is_full(), 900)
	_expect(refuelled, "the drone refuels while landed")
	_expect(flight.landed, "the refuelled drone stays parked")
	drone.action = Moving.new(airport.global_position + Vector3(8, 0, -8))
	await _frames(5)
	_expect(not flight.landed, "a new order makes it take off")
	airport.queue_free()
	await _frames(5)
	flight.fuel_s = 2.0
	var drone_ref = weakref(drone)
	var crashed = await _wait_for(func(): return drone_ref.get_ref() == null, 600)
	_expect(crashed, "without an airport a drone out of fuel crashes")


func _check_trade_advice():
	_human.subtract_resources(_human.get_stock())
	_human.add_resources({"timber": 60, "iron": 60, "copper": 5, "oil": 40})
	var good = Trade.assess(_human, {"timber": 10}, {"copper": 10})
	var bad = Trade.assess(_human, {"copper": 4}, {"timber": 4})
	var drain = Trade.assess(_human, {"iron": 55}, {"oil": 80})
	var fair = Trade.assess(_human, {"iron": 4}, {"timber": 6})  # iron is worth 1.5 timber
	print("  good: ", good, "\n  bad: ", bad, "\n  drain: ", drain, "\n  fair: ", fair)
	_expect(good["verdict"] == Trade.Verdict.GOOD, "giving surplus for what you lack is good")
	_expect(bad["verdict"] == Trade.Verdict.BAD, "giving away what you lack is bad")
	_expect(drain["verdict"] == Trade.Verdict.BAD, "trading a stock down to nothing is bad")
	_expect(fair["verdict"] == Trade.Verdict.FAIR, "swapping equal stocks is fair")
	var rival = get_tree().get_nodes_in_group("players").filter(func(p): return p != _human)[0]
	MatchSignals.trade_offered.emit(rival, _human, {"timber": 6}, {"copper": 4})
	await _frames(10)
	var hud = _match.find_child("CityHud", true, false)
	var label = hud.get("_offer_verdict_label")
	_expect(label.visible and label.text.length() > 0, "incoming offers show advice: " + label.text)
	await _shot("3-trade-offer-advice")


func camera_on(position, size):
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(size)
	camera.set_position_safely(position)


func _own(predicate):
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _human and predicate.call(unit):
			return unit
	return null


func _closest_deposit(position):
	var closest = null
	for deposit in get_tree().get_nodes_in_group("deposits"):
		if (
			closest == null
			or deposit.global_position.distance_to(position)
			< closest.global_position.distance_to(position)
		):
			closest = deposit
	return closest


func _expect(condition, description):
	print(("PASS " if condition else "FAIL ") + description)
	if not condition:
		_failures += 1


func _wait_for(predicate, max_frames):
	for _i in range(max_frames):
		if predicate.call():
			return true
		await get_tree().physics_frame
	return predicate.call()


func _shot(name):
	await _frames(5)
	var path = "{0}/{1}.png".format([_out, name])
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
