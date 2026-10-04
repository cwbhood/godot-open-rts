extends "res://tests/playtest/PlaytestChecks.gd"

# Checks the delivery system in a running match and saves screenshots of it: full
# extractors stop and say so, the job board sends a truck, idle trucks stand by instead
# of sitting at the depot, a storage takes conveyor deliveries, a train lays track and
# delivers, surplus trucks raise the alert and recycling refunds 75%, and a destroyed
# truck makes the others avoid its route. Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
#     res://tests/logistics/LogisticsChecks.tscn -- --out=/tmp/logistics
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const Hauler = preload("res://source/match/units/Hauler.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const Standby = preload("res://source/match/units/actions/Standby.gd")
const MineScene = preload("res://source/match/units/Mine.tscn")
const StorageScene = preload("res://source/match/units/Storage.tscn")
const TrainScene = preload("res://source/match/units/Train.tscn")
const HaulerScene = preload("res://source/match/units/Hauler.tscn")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")

var _logistics = null
var _depot = null
var _mines = []


func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	_match = load("res://tests/manual/TestOneCityOneRival.tscn").instantiate()
	add_child(_match)
	await _frames(30)
	_human = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)[0]
	_logistics = _human.logistics
	var atmosphere = _match.find_child("Atmosphere", true, false)
	if atmosphere != null:  # screenshots in clear weather
		atmosphere.random_weather = false
		atmosphere.set_weather_immediately("clear")
	_depot = _own(func(unit): return unit is CommandCenter)
	_human.add_resources({"timber": 300, "iron": 300, "copper": 100, "oil": 200})
	_stop_the_rival()
	await _check_full_extractor_stops()
	await _check_job_board_and_standby()
	await _check_storage()
	await _check_train()
	await _check_surplus_and_recycling()
	await _check_raided_route()
	Engine.time_scale = 1.0
	print("logistics checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _stop_the_rival():
	"""the rival keeps building its economy but sends nobody our way"""
	for player in get_tree().get_nodes_in_group("players"):
		if player != _human and "expected_number_of_battlegroups" in player:
			player.expected_number_of_battlegroups = 0
			player.raid_party_size = 0


func _haulers():
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Hauler and unit.player == _human
	)


func _spawn(scene, position, constructed = true):
	var unit = scene.instantiate()
	if constructed:
		unit.set_meta("spawn_constructed", true)
	MatchSignals.setup_and_spawn_unit.emit(
		unit, Transform3D(Basis(), position).looking_at(position + Vector3(0, 0, 1)), _human
	)
	return unit


func _iron_deposits_by_distance():
	var deposits = get_tree().get_nodes_in_group("deposits").filter(
		func(deposit): return deposit.kind in ["iron", "copper"]
	)
	deposits.sort_custom(
		func(a, b):
			return (
				a.global_position.distance_to(_depot.global_position)
				< b.global_position.distance_to(_depot.global_position)
			)
	)
	return deposits


func _check_full_extractor_stops():
	for hauler in _haulers():
		hauler.automated = false  # nobody collects for now
		hauler.action = null
	var deposits = _iron_deposits_by_distance().filter(
		func(deposit): return deposit.global_position.distance_to(_depot.global_position) > 14.0
	)
	_expect(deposits.size() >= 2, "the map has two mine deposits away from the yard")
	for deposit in deposits.slice(0, 2):
		var towards_depot = (_depot.global_position_yless - deposit.global_position_yless).normalized()
		var spot = deposit.global_position_yless + towards_depot * (deposit.radius + 1.3)
		_mines.append(_spawn(MineScene, spot))
	await _frames(10)
	_expect(
		_mines.all(func(mine): return mine.deposit != null), "both mines sit on a deposit"
	)
	Engine.time_scale = 4.0
	var mine = _mines[0]
	var filled = await _wait_for(func(): return mine.is_full(), 3000)
	_expect(filled, "a mine nobody empties fills its buffer ({0}/{1})".format([mine.stored, mine.get_buffer_capacity()]))
	var left = mine.deposit.amount if is_instance_valid(mine.deposit) else -1
	await _wait_seconds(8.0)
	_expect(
		is_instance_valid(mine.deposit) and mine.deposit.amount == left and mine.is_full(),
		"a full mine stops extracting"
	)
	var gauge = mine.get_node_or_null("BufferGauge")
	_expect(
		gauge != null and gauge.visible and gauge.text.contains(tr("GAUGE_FULL")),
		"its gauge says it is full: " + (gauge.text.replace("\n", " / ") if gauge != null else "none")
	)
	Engine.time_scale = 1.0
	camera_on(mine.global_position, 14.0)
	await _shot("1-full-mine-waits-for-a-truck")


func _check_job_board_and_standby():
	for hauler in _haulers():
		hauler.automated = true
	var delivered_before = Utils.Dict.sum(_logistics.delivered_total)
	Engine.time_scale = 4.0
	var mine = _mines[0]
	var collected = await _wait_for(func(): return mine.stored < mine.get_buffer_capacity() / 2, 4000)
	_expect(collected, "the job board sends a truck to the full mine (left {0})".format([mine.stored]))
	var delivered = await _wait_for(
		func(): return Utils.Dict.sum(_logistics.delivered_total) > delivered_before, 4000
	)
	_expect(delivered, "the goods reach the depot")
	var counts = _logistics.fleet.get_fleet_counts()
	print("  fleet: ", counts)
	var waiting = _haulers().filter(func(hauler): return hauler.action is Standby)
	var unemployed = _haulers().filter(func(hauler): return hauler.action == null)
	_expect(unemployed.is_empty(), "no automated truck is left without an order")
	_expect(
		not waiting.is_empty() or counts["working"] == counts["total"],
		"trucks without a job stand by or park instead of idling ({0} waiting)".format([waiting.size()])
	)
	var stats = _logistics.get_route_stats(mine)
	_expect(stats["trips"] >= 1 and stats["delivered"] > 0, "the route counts its trips: " + str(stats))
	Engine.time_scale = 1.0
	camera_on(mine.global_position.lerp(_depot.global_position, 0.4), 20.0)
	await _shot("2-trucks-collect-and-stand-by")


func _check_storage():
	var center = (_mines[0].global_position_yless + _mines[1].global_position_yless) * 0.5
	var suggestion = _logistics.suggest_storage_site()
	print("  storage suggestion: ", suggestion["position"] if suggestion != null else null)
	var reach = float(Constants.Match.Logistics.STORAGE.get("link_radius_m", 12.0))
	var spot = center + (_depot.global_position_yless - center).normalized() * 2.5
	var close_enough = _mines.all(func(mine): return mine.global_position_yless.distance_to(spot) <= reach)
	if not close_enough:
		spot = _mines[0].global_position_yless + (_depot.global_position_yless - _mines[0].global_position_yless).normalized() * 3.5
	var storage = _spawn(StorageScene, spot)
	Engine.time_scale = 4.0
	var linked = await _wait_for(func(): return _mines[0].linked_storage == storage, 600)
	_expect(linked, "a mine next to a storage feeds it by conveyor")
	var filling = await _wait_for(func(): return storage.stored >= 6, 3000)
	_expect(filling, "the storage fills up ({0}) and holds {1}".format([storage.stored, storage.kind]))
	_expect(not _mines[0].is_full(), "the linked mine keeps working ({0} in its buffer)".format([_mines[0].stored]))
	Engine.time_scale = 1.0
	camera_on(storage.global_position, 16.0)
	await _shot("3-storage-fed-by-conveyors")
	_mines.append(storage)


func _check_train():
	var storage = _mines[2]
	var spent_before = Utils.Dict.sum(_logistics.rails.track_spent_total)
	var train = _spawn(TrainScene, _depot.global_position_yless + Vector3(3.5, 0, 3.5))
	await _frames(10)
	train.set_line([storage], true)
	Engine.time_scale = 3.0
	var laying = await _wait_for(func(): return _logistics.rails.get_length_m() > 3.0, 2000)
	_expect(laying, "the train lays track as it goes ({0} m)".format([snapped(_logistics.rails.get_length_m(), 0.1)]))
	_expect(
		Utils.Dict.sum(_logistics.rails.track_spent_total) > spent_before,
		"track is paid for: " + str(_logistics.rails.track_spent_total)
	)
	Engine.time_scale = 1.0
	camera_on(train.global_position, 14.0)
	await _shot("4-train-laying-track")
	Engine.time_scale = 4.0
	var stats = _logistics.get_route_stats(storage)
	var trips_before = stats["trips"]
	var loaded = await _wait_for(func(): return stats["trips"] > trips_before, 9000)
	_expect(loaded, "the train loads at the storage: " + str(stats))
	var delivered_before = Utils.Dict.sum(_logistics.delivered_total)
	var back = await _wait_for(
		func(): return Utils.Dict.sum(_logistics.delivered_total) > delivered_before and train.cargo.is_empty(),
		9000
	)
	_expect(back, "and delivers at the depot ({0})".format([train.get_status_text()]))
	var running_fast = await _wait_for(func(): return train.status_key == "TRAIN_STATUS_RUNNING", 3000)
	_expect(running_fast, "on the built track it runs at full speed")
	_expect(storage in _logistics._sources_served_by_trains(), "trucks leave the train's stop alone")
	Engine.time_scale = 1.0
	camera_on(train.global_position.lerp(_depot.global_position, 0.3), 26.0)
	await _shot("5-train-running-the-loop")


func _check_surplus_and_recycling():
	Constants.Match.Logistics.FLEET["surplus_window_s"] = 8.0  # a short window for the test
	for i in range(4):
		_spawn(HaulerScene, _depot.global_position_yless + Vector3(-4 - i, 0, 4), false)
	Engine.time_scale = 4.0
	var alerted = await _wait_for(func(): return _logistics.fleet.surplus_trucks > 0, 4000)
	_expect(
		alerted,
		"too many trucks raise the surplus alert ({0} surplus, work for {1})".format(
			[_logistics.fleet.surplus_trucks, snapped(_logistics.fleet.truck_demand, 0.1)]
		)
	)
	Engine.time_scale = 1.0
	var row = _match.find_child("CityHud", true, false)
	var button = row.get("_recycle_button") if row != null else null
	await _frames(60)
	_expect(button != null and button.is_visible_in_tree(), "the city panel offers to recycle them")
	camera_on(_depot.global_position, 18.0)
	await _shot("6-surplus-alert-and-recycle-button")
	var haulers_before = _haulers().size()
	var surplus = _logistics.fleet.surplus_trucks
	var refunded_before = _logistics.fleet.refunded_total.duplicate()
	if button != null:
		button.pressed.emit()
	Engine.time_scale = 4.0
	var recycled = await _wait_for(func(): return _haulers().size() <= haulers_before - surplus, 4000)
	_expect(recycled, "{0} trucks drove to the depot and were taken apart".format([surplus]))
	var refund = {}
	for resource in _logistics.fleet.refunded_total:
		refund[resource] = _logistics.fleet.refunded_total[resource] - refunded_before.get(resource, 0)
	var cost = Constants.Match.Units.PRODUCTION_COSTS[HaulerScene.resource_path]
	var paid = Utils.Dict.sum(cost) * surplus
	var share = Utils.Dict.sum(refund) / float(paid)
	_expect(
		abs(share - 0.75) <= 1.0 / paid + 0.001,
		"recycling refunds 75% of their cost: {0} of {1} ({2}%)".format([refund, paid, int(share * 100)])
	)
	Engine.time_scale = 1.0


func _check_raided_route():
	var hauler = _haulers()[0]
	var position = hauler.global_position
	hauler.hp = 0
	await _frames(5)
	_expect(not _logistics.danger_zones.is_empty(), "a destroyed truck marks its route as dangerous")
	_expect(
		_logistics._route_in_danger(position + Vector3(2, 0, 0), position - Vector3(2, 0, 0)),
		"and routes through that spot are avoided"
	)


func _wait_seconds(seconds):
	var start = Time.get_ticks_msec()
	var game_s = 0.0
	while game_s < seconds:
		await get_tree().physics_frame
		game_s += get_physics_process_delta_time() * Engine.time_scale
		if Time.get_ticks_msec() - start > 600000:
			return
