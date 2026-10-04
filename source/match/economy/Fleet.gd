extends RefCounted

# The player's delivery fleet as a whole, kept by Logistics (logistics.fleet): how many
# trucks the current extractors and storages keep busy (the demand estimate the AI and
# auto-expand build to), the oil upkeep every truck and train costs per minute, the
# trucks that had nothing to do for a whole window (surplus), and recycling: a truck or
# train drives to a depot and is taken apart for part of its cost back
# (data/logistics.json, "fleet").

const Hauler = preload("res://source/match/units/Hauler.gd")
const Hauling = preload("res://source/match/units/actions/Hauling.gd")
const Standby = preload("res://source/match/units/actions/Standby.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")

const HAULER_SCENE = "res://source/match/units/Hauler.tscn"
const PARKED = "PARKED"

var upkeep_total = {}  # statistics: oil burnt by the fleet's upkeep
var refunded_total = {}  # statistics: goods returned by recycling
var recycled_total = 0
var surplus_trucks = 0  # trucks that had nothing to do for the whole surplus window
var truck_demand = 0.0  # trucks the current sources keep busy, see estimate_truck_demand

var _logistics = null
var _upkeep_accumulated = 0.0
var _refund_owed = {}  # fractional refunds not paid out yet
var _idle_history = []  # trucks left without a job, one entry per job board run


func _init(logistics):
	_logistics = logistics


static func is_free(hauler):
	"""an automated truck with no job: idle, parked or standing by"""
	return (
		hauler.automated
		and not hauler.recycling
		and (hauler.action == null or hauler.action.get("description") in ["STANDBY", PARKED])
	)


func get_trains():
	return _logistics.get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.get("is_train") == true and unit.player == _logistics.get_parent()
	)


func note_idle(count):
	"""called by the job board after every run with the trucks it found no job for"""
	_idle_history.append(count)
	var window = int(
		(
			float(Constants.Match.Logistics.FLEET.get("surplus_window_s", 60.0))
			/ Constants.Match.Logistics.TICK_S
		)
	)
	while _idle_history.size() > window:
		_idle_history.pop_front()


func update(delta):
	_pay_upkeep(delta)


func refresh_estimates():
	truck_demand = estimate_truck_demand()
	_update_surplus()


func get_fleet_counts():
	var counts = {
		"total": 0,
		"working": 0,
		"standby": 0,
		"parked": 0,
		"manual": 0,
		"recycling": 0,
		"trains": get_trains().size(),
	}
	for hauler in _logistics.get_haulers():
		counts["total"] += 1
		if hauler.recycling:
			counts["recycling"] += 1
		elif not hauler.automated:
			counts["manual"] += 1
		elif hauler.action is Standby:
			counts["standby" if hauler.action.description != PARKED else "parked"] += 1
		elif hauler.action == null:
			counts["parked"] += 1
		else:
			counts["working"] += 1
	return counts


func estimate_truck_demand():
	"""trucks the current sources and sites keep busy: for every source not on a train
	line, goods per second times the round trip, over what a truck carries"""
	var demand = 0.0
	var capacity = float(_logistics._hauler_capacity())
	var speed = float(Constants.Match.Units.SPEEDS.get(HAULER_SCENE, 3.2))
	var overhead = float(Constants.Match.Logistics.JOBS.get("load_overhead_s", 3.0))
	var served = _logistics._sources_served_by_trains()
	for source in _logistics.get_sources():
		if source in served:
			continue
		var depot = _logistics.closest_depot(source.global_position)
		if depot == null:
			continue
		var road = _logistics.get_road_speed_multiplier(source) if source is Extractor else 1.0
		var distance = _distance(source.global_position, depot.global_position)
		var round_trip = distance / speed + distance / (speed * road) + overhead * 2.0
		demand += source.get_rate_per_s() * round_trip / capacity
	var pending = 0
	for site in _logistics.get_sites():
		if not _logistics.is_in_yard(site.global_position):
			pending += Utils.Dict.sum(site.materials_pending)
	demand += min(2.0, ceil(pending / capacity))
	return demand


func get_truck_target():
	"""how many trucks to keep: the demand rounded up, plus one spare, at least two"""
	return max(
		2, int(ceil(truck_demand)) + int(Constants.Match.Logistics.FLEET.get("surplus_spare", 1))
	)


func _update_surplus():
	var fleet = Constants.Match.Logistics.FLEET
	var window = int(float(fleet.get("surplus_window_s", 60.0)) / Constants.Match.Logistics.TICK_S)
	if _idle_history.size() < window:
		surplus_trucks = 0
		return
	var always_idle = _idle_history.min()
	var haulers = _logistics.get_haulers().filter(func(hauler): return not hauler.recycling).size()
	var spare = int(fleet.get("surplus_spare", 1))
	var surplus = min(always_idle - spare, haulers - get_truck_target())
	surplus_trucks = surplus if surplus >= int(fleet.get("surplus_min", 1)) else 0


func get_recycle_refund(unit):
	"""what recycling 'unit' gives back, whole goods only (fractions carry over)"""
	var share = float(Constants.Match.Logistics.FLEET.get("recycle_refund", 0.75))
	var refund = {}
	var cost = Constants.Match.Units.PRODUCTION_COSTS.get(unit._scene_path(), {})
	for resource in cost:
		refund[resource] = cost[resource] * share
	return refund


func get_recycle_refund_text(trucks = 1):
	"""e.g. "4 IRON, 3 TIMBER, 3 OIL" for recycling that many trucks"""
	var share = float(Constants.Match.Logistics.FLEET.get("recycle_refund", 0.75))
	var cost = Constants.Match.Units.PRODUCTION_COSTS.get(HAULER_SCENE, {})
	var parts = []
	for resource in cost:
		parts.append(
			"{0} {1}".format(
				[
					int(floor(cost[resource] * share * trucks)),
					TranslationServer.translate(resource.to_upper())
				]
			)
		)
	return ", ".join(parts)


func recycle(unit):
	"""sends a truck or a train to the closest depot, where it is taken apart"""
	if (
		not is_instance_valid(unit)
		or unit.player != _logistics.get_parent()
		or unit.get("recycling") == true
	):
		return false
	unit.recycling = true
	if unit is Hauler:
		unit.automated = false
		unit.dedicated_extractor = null
		var depot = _logistics.closest_depot(unit.global_position)
		if depot == null:
			complete_recycle(unit)
			return true
		var unit_ref = weakref(unit)
		var take_apart = func():
			var target = unit_ref.get_ref()
			if target != null:
				complete_recycle.call_deferred(target)
			return true
		unit.road_speed_multiplier = 1.0
		unit.action = Hauling.new([[depot, take_apart]], null, "RECYCLING")
	return true


func recycle_surplus(count = -1):
	"""recycles the trucks that are idle, parked ones and those closest to a depot first"""
	if count < 0:
		count = surplus_trucks
	var idle = _logistics.get_haulers().filter(is_free)
	idle.sort_custom(
		func(a, b):
			return (
				[
					0 if a.action == null or a.action.description == PARKED else 1,
					_distance_to_depot(a)
				]
				< [
					0 if b.action == null or b.action.description == PARKED else 1,
					_distance_to_depot(b)
				]
			)
	)
	var recycled = 0
	for hauler in idle.slice(0, count):
		if recycle(hauler):
			recycled += 1
	surplus_trucks = max(0, surplus_trucks - recycled)
	_idle_history.clear()
	return recycled


func complete_recycle(unit):
	if not is_instance_valid(unit) or unit.is_queued_for_deletion():
		return
	if unit.get("cargo") != null and not unit.cargo.is_empty():
		_logistics.deliver(unit.cargo)
		unit.cargo = {}
	var refund = {}
	var share = get_recycle_refund(unit)
	for resource in share:
		var owed = _refund_owed.get(resource, 0.0) + share[resource]
		var whole = int(floor(owed + 0.0001))
		_refund_owed[resource] = owed - whole
		if whole > 0:
			refund[resource] = whole
	_logistics.get_parent().add_resources(refund)
	for resource in refund:
		Utils.Dict.add_amount(refunded_total, resource, refund[resource])
	recycled_total += 1
	MatchSignals.unit_recycled.emit(unit, refund)
	unit.queue_free()


func _distance_to_depot(unit):
	var depot = _logistics.closest_depot(unit.global_position)
	return _distance(unit.global_position, depot.global_position) if depot != null else INF


func get_upkeep_per_min():
	"""oil the fleet costs per minute whether it works or not"""
	var rates = Constants.Match.Logistics.FLEET.get("upkeep_oil_per_min", {})
	return (
		_logistics.get_haulers().size() * float(rates.get("hauler", 0.0))
		+ get_trains().size() * float(rates.get("train", 0.0))
	)


func _pay_upkeep(delta):
	_upkeep_accumulated += get_upkeep_per_min() / 60.0 * delta
	var whole = int(floor(_upkeep_accumulated))
	if whole <= 0:
		return
	_upkeep_accumulated -= whole
	var paid = min(whole, _logistics.get_parent().oil)
	if paid > 0:
		_logistics.get_parent().subtract_resources({"oil": paid})
		Utils.Dict.add_amount(upkeep_total, "oil", paid)


static func _distance(a, b):
	return (a * Vector3(1, 0, 1)).distance_to(b * Vector3(1, 0, 1))
