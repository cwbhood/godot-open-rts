extends Node

# Every player has a Logistics node that runs their supply lines:
# - construction sites inside the yard of a depot (a constructed command center) get their
#   materials straight from the depot,
# - every other site waits for trucks (haulers) bringing the materials from the closest
#   depot,
# - extractors fill a small output buffer and stop when it is full; trucks or a train
#   empty it and drive the goods to the closest depot. Extractors next to a storage yard
#   feed it by conveyor instead, and trucks and trains collect from the storage in full
#   loads (Storage.gd),
# - goods delivered to a depot are split between the player's stock and the city
#   warehouse (see City.receive_delivery).
#
# Trucks get their work from a job board run twice a second: every open job (materials
# for a site, goods waiting at an extractor or storage) is scored for every free truck by
# value per second of driving (commodity value, the priority the player set on the
# building, what the city is short of, raids on the way) and the best pairs are matched
# first. A truck with no job does not sit at the depot: it drives to the extractor that
# will have a load ready soonest and waits there (standby); only when there is nothing
# to collect anywhere it parks at the depot. Trucks that stayed without a job for a
# while are reported as surplus, and recycling one refunds part of its cost.
#
# Trains (Train.gd) run loops between the depot and a few extractors or storages over
# track they lay themselves; the railway is kept in RailNetwork.gd (logistics.rails),
# the fleet as a whole (demand, upkeep, surplus, recycling) in Fleet.gd (logistics.fleet).
#
# Trucks and trains away from depots are exposed: destroying them loses the cargo (see
# Unit loot), and the route is avoided for a while. The route between an extractor and its
# depot starts as a dirt track and can be upgraded (data/roads.json) so that trucks on it
# drive faster. Tunables are in data/logistics.json.

const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Hauling = preload("res://source/match/units/actions/Hauling.gd")
const Standby = preload("res://source/match/units/actions/Standby.gd")
const Storage = preload("res://source/match/units/Storage.gd")
const RailVisuals = preload("res://source/match/economy/RailVisuals.gd")
const Fleet = preload("res://source/match/economy/Fleet.gd")
const RailNetwork = preload("res://source/match/economy/RailNetwork.gd")

const ROAD_WIDTH_M = 1.1
const HAULER_SCENE = "res://source/match/units/Hauler.tscn"
const PARKED = "PARKED"
const STANDBY_LIMIT_S = 120.0  # no point waiting at an extractor longer than this

var delivered_total = {}  # statistics: goods that reached a depot
var lost_total = {}  # statistics: goods destroyed on the way or in extractors
var looted_total = {}  # statistics: goods taken from other players
var fuel_burnt_total = {}  # statistics
var fleet = Fleet.new(self)  # truck demand, surplus, upkeep and recycling
var rails = RailNetwork.new(self)  # track legs and train lines

var out_of_fuel = false
var road_levels = {}  # extractor -> index into Constants.Match.Roads.LEVELS
var danger_zones = []  # [[position, time left]] where trucks or trains were destroyed
var route_stats = {}  # source instance id -> {delivered, trips, lost, trip_s}

var _road_visuals = {}  # extractor -> MeshInstance3D

var _site_loaders = {}  # site -> number of haulers on their way to load materials for it
var _fuel_accumulated = 0.0
var _since_links_s = 0.0
var _since_demand_s = 0.0
var _clock_s = 0.0

@onready var _player = get_parent()


func _ready():
	MatchSignals.cargo_destroyed.connect(_on_cargo_destroyed)
	MatchSignals.route_raided.connect(_on_route_raided)
	var timer = Timer.new()
	timer.timeout.connect(_tick)
	add_child(timer)
	timer.start(Constants.Match.Logistics.TICK_S)
	var rails = RailVisuals.new()
	rails.name = "Rails"
	add_child(rails)


func get_depots():
	return get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return unit is CommandCenter and unit.player == _player and unit.is_constructed()
	)


func get_haulers():
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Hauler and unit.player == _player
	)


func get_extractors():
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Extractor and unit.player == _player
	)


func get_storages():
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Storage and unit.player == _player
	)


func get_sites():
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Structure and unit.player == _player and unit.needs_materials()
	)


func get_sources():
	"""constructed extractors (unless a conveyor feeds a storage) and storages: the places
	trucks and trains collect goods from"""
	var sources = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player != _player or not unit is Structure or not unit.is_constructed():
			continue
		if unit is Extractor and not unit.is_linked() and unit.resource_kind != null:
			sources.append(unit)
		elif unit is Storage:
			sources.append(unit)
	return sources


func closest_depot(position):
	var closest = null
	for depot in get_depots():
		if (
			closest == null
			or (
				_distance(depot.global_position, position)
				< _distance(closest.global_position, position)
			)
		):
			closest = depot
	return closest


func is_in_yard(position):
	var depot = closest_depot(position)
	return (
		depot != null
		and _distance(depot.global_position, position) <= Constants.Match.Logistics.YARD_RADIUS_M
	)


func deliver(goods):
	"""goods arriving at a depot"""
	for resource in goods:
		Utils.Dict.add_amount(delivered_total, resource, goods[resource])
	var remainder = goods
	if _player.city != null:
		remainder = _player.city.receive_delivery(goods)
	_player.add_resources(remainder)
	MatchSignals.goods_delivered.emit(_player, goods)


# --- the job board


func _run_job_board():
	var free = get_haulers().filter(Fleet.is_free)
	for hauler in free.duplicate():
		if not hauler.cargo.is_empty():
			free.erase(hauler)
			if not _assign_unloading(hauler):
				_park(hauler)
		elif hauler.dedicated_extractor != null:
			free.erase(hauler)
			_serve_dedicated(hauler)
	var jobs = _open_jobs()
	while not free.is_empty() and not jobs.is_empty():
		var best = null
		for hauler in free:
			for job in jobs:
				var score = _score(hauler, job)
				if score > 0.0 and (best == null or score > best[0]):
					best = [score, hauler, job]
		if best == null:
			break
		var job = best[2]
		free.erase(best[1])
		if not _take_job(best[1], job):
			jobs.erase(job)
			continue
		job["amount"] -= best[1].cargo_capacity
		if job["amount"] < job["min"]:
			jobs.erase(job)
	var standing_by = {}
	for hauler in free:
		_standby(hauler, standing_by)
	fleet.note_idle(free.size())


func _open_jobs():
	var jobs = []
	var capacity = _hauler_capacity()
	for site in get_sites():
		if is_in_yard(site.global_position):
			continue
		var depot = closest_depot(site.global_position)
		var pending = Utils.Dict.sum(site.materials_pending)
		var remaining = pending - _site_loaders.get(site.get_instance_id(), 0) * capacity
		if depot == null or remaining <= 0:
			continue
		(
			jobs
			. append(
				{
					"kind": "supply",
					"target": site,
					"depot": depot,
					"amount": remaining,
					"min": 1,
					"value": float(Constants.Match.Logistics.JOBS.get("site_value", 3.0)),
					"road": 1.0,
				}
			)
		)
	var served = _sources_served_by_trains()
	for source in get_sources():
		var depot = closest_depot(source.global_position)
		var available = source.get_available_for_pickup()
		if depot == null or available <= 0:
			continue
		if source in served and not source.is_full():
			continue  # the train takes it; trucks only help out when it overflows
		var minimum = _min_pickup(source)
		if available < minimum and not source.is_full():
			continue
		(
			jobs
			. append(
				{
					"kind": "pickup",
					"target": source,
					"depot": depot,
					"amount": available,
					"min": min(minimum, available),
					"value": _value_per_unit(source),
					"road": get_road_speed_multiplier(source) if source is Extractor else 1.0,
				}
			)
		)
	return jobs


func _score(hauler, job):
	"""value delivered per second of the truck's time"""
	var load = min(job["amount"], hauler.get_free_capacity())
	if load <= 0:
		return 0.0
	var speed = max(hauler.movement_speed, 0.1)
	var target = job["target"]
	var depot = job["depot"]
	if not is_instance_valid(target) or not is_instance_valid(depot):
		return 0.0
	var seconds = float(Constants.Match.Logistics.JOBS.get("load_overhead_s", 3.0))
	var value = load * job["value"]
	if job["kind"] == "supply":
		seconds += (
			(
				_distance(hauler.global_position, depot.global_position)
				+ _distance(depot.global_position, target.global_position)
			)
			/ speed
		)
		if _route_in_danger(depot.global_position, target.global_position):
			value /= float(Constants.Match.Logistics.RAIDS.get("penalty", 4.0))
	else:
		seconds += (
			_distance(hauler.global_position, target.global_position) / speed
			+ _distance(target.global_position, depot.global_position) / (speed * job["road"])
		)
		if (
			_route_in_danger(hauler.global_position, target.global_position)
			or _route_in_danger(target.global_position, depot.global_position)
		):
			value /= float(Constants.Match.Logistics.RAIDS.get("penalty", 4.0))
	return value / seconds


func _value_per_unit(source):
	var kind = source.get_goods_kind()
	var value = float(Constants.Match.Trade.BASE_PRICES.get(kind, 1.0))
	var factors = Constants.Match.Logistics.JOBS.get("priority_factors", [0.4, 1.0, 2.5])
	value *= float(factors[clamp(source.logistics_priority, 0, factors.size() - 1)])
	if source.is_full():
		value *= 1.5  # a full extractor stands still: emptying it gains production too
	var city = _player.city
	if city != null and kind != null:
		var share = city.warehouse.get(kind, 0.0) / Constants.Match.City.WAREHOUSE_CAPACITY
		if share < float(Constants.Match.Logistics.JOBS.get("city_need_share", 0.3)):
			value *= float(Constants.Match.Logistics.JOBS.get("city_need_factor", 1.5))
	return value


func _min_pickup(source):
	if source is Extractor:
		return Constants.Match.Logistics.MIN_PICKUP
	return int(Constants.Match.Logistics.STORAGE.get("min_pickup", 8))


func _take_job(hauler, job):
	if job["kind"] == "supply":
		return assign_supply(hauler, job["target"])
	return _assign_pickup(hauler, job["target"])


func _serve_dedicated(hauler):
	var source = hauler.dedicated_extractor
	if not is_instance_valid(source) or not source.is_inside_tree():
		hauler.dedicated_extractor = null
		_park(hauler)
		return
	var available = source.get_available_for_pickup()
	if available > 0 and (available >= _min_pickup(source) or source.is_full()):
		_assign_pickup(hauler, source)
	else:
		_wait_at(hauler, source, "STANDBY")


func _standby(hauler, standing_by):
	"""no job right now: wait next to the source that will have a load ready soonest"""
	var best = null
	var speed = max(hauler.movement_speed, 0.1)
	var limit = int(Constants.Match.Logistics.STANDBY.get("max_per_source", 1))
	var served = _sources_served_by_trains()
	for source in get_sources():
		if source in served:
			continue
		var id = source.get_instance_id()
		var waiting = standing_by.get(id, 0)
		if waiting >= limit:
			continue
		var rate = source.get_rate_per_s()
		var missing = _min_pickup(source) - source.get_available_for_pickup()
		if rate <= 0.0 and missing > 0:
			continue
		if _route_in_danger(hauler.global_position, source.global_position):
			continue
		var ready_in = max(0.0, missing / max(rate, 0.001))
		var travel = _distance(hauler.global_position, source.global_position) / speed
		var eta = max(ready_in, travel)
		if eta <= STANDBY_LIMIT_S and (best == null or eta < best[0]):
			best = [eta, source]
	if best == null:
		_park(hauler)
		return
	var key = best[1].get_instance_id()
	standing_by[key] = standing_by.get(key, 0) + 1
	_wait_at(hauler, best[1], "STANDBY")


func _park(hauler):
	var depot = closest_depot(hauler.global_position)
	if depot == null:
		return
	_wait_at(hauler, depot, PARKED)


func _wait_at(hauler, target, description):
	if (
		hauler.action is Standby
		and hauler.action.is_waiting_at(target)
		and hauler.action.description == description
	):
		return
	var depot = closest_depot(target.global_position)
	var away = (
		(target.global_position_yless - depot.global_position_yless).normalized()
		if depot != null and depot != target
		else Vector3(1, 0, 0)
	)
	if away.length_squared() < 0.01:
		away = Vector3(1, 0, 0)
	# trucks wait on the depot side of an extractor, spread out a little
	var side = away.cross(Vector3.UP).normalized()
	var slot = (hauler.get_instance_id() % 5) - 2
	var radius = float(Constants.Match.Logistics.STANDBY.get("radius_m", 3.5))
	var spot = (
		target.global_position_yless
		+ (-away if description != PARKED else away) * (target.radius + radius * 0.6)
		+ side * slot * 1.4
	)
	hauler.road_speed_multiplier = 1.0
	hauler.action = Standby.new(target, spot, description)


func _sources_served_by_trains():
	var served = []
	for train in fleet.get_trains():
		if not train.recycling:
			served.append_array(train.stops)
	return served


func _hauler_capacity():
	return int(
		Constants.Match.Units.DEFAULT_PROPERTIES.get(HAULER_SCENE, {}).get("cargo_capacity", 10)
	)


# --- storage yards and conveyors


func _update_storage_links():
	"""each extractor feeds the closest storage in reach that takes its commodity"""
	var storages = get_storages().filter(func(storage): return storage.is_constructed())
	var reach = float(Constants.Match.Logistics.STORAGE.get("link_radius_m", 12.0))
	for extractor in get_extractors():
		if not extractor.is_constructed() or extractor.resource_kind == null:
			extractor.linked_storage = null
			continue
		var best = null
		for storage in storages:
			var distance = _distance(storage.global_position, extractor.global_position)
			if distance > reach:
				continue
			var keeps = (
				storage == extractor.linked_storage and storage.kind == extractor.resource_kind
			)
			if not keeps and not storage.accepts(extractor.resource_kind):
				continue
			if best == null or distance < best[0]:
				best = [distance, storage]
		extractor.linked_storage = best[1] if best != null else null


func suggest_storage_site():
	"""{position, extractors} where a storage would gather two or more unlinked
	extractors of one commodity away from the depot yard, or null"""
	var reach = float(Constants.Match.Logistics.STORAGE.get("link_radius_m", 12.0))
	var candidates = get_extractors().filter(
		func(extractor):
			return (
				extractor.is_constructed()
				and extractor.resource_kind != null
				and not extractor.is_linked()
				and not extractor.is_depleted()
				and not is_in_yard(extractor.global_position)
			)
	)
	var best = null
	for anchor in candidates:
		var group = candidates.filter(
			func(other):
				return (
					other.resource_kind == anchor.resource_kind
					and _distance(other.global_position, anchor.global_position) <= reach * 1.5
				)
		)
		if group.size() < 2:
			continue
		var center = Vector3.ZERO
		for extractor in group:
			center += extractor.global_position_yless
		center /= group.size()
		if best == null or group.size() > best["extractors"].size():
			best = {"position": center, "extractors": group, "kind": anchor.resource_kind}
	return best


# --- raids and route statistics


func _route_in_danger(from, to):
	var radius = float(Constants.Match.Logistics.RAIDS.get("radius_m", 9.0))
	for zone in danger_zones:
		var point = Geometry3D.get_closest_point_to_segment(
			zone[0], from * Vector3(1, 0, 1), to * Vector3(1, 0, 1)
		)
		if point.distance_to(zone[0]) <= radius:
			return true
	return false


func is_route_in_danger(source):
	var depot = closest_depot(source.global_position)
	return depot != null and _route_in_danger(source.global_position, depot.global_position)


func get_route_stats(source):
	return _stats_of(source)


func _stats_of(source):
	var id = source.get_instance_id()
	if not id in route_stats:
		route_stats[id] = {"delivered": 0, "trips": 0, "lost": 0, "trip_s": 0.0}
	return route_stats[id]


func get_road_level(extractor):
	return road_levels.get(extractor, 0)


func get_road_speed_multiplier(extractor):
	var levels = Constants.Match.Roads.LEVELS
	if levels.is_empty():
		return 1.0
	return float(levels[min(get_road_level(extractor), levels.size() - 1)]["speed_multiplier"])


func get_road_length_m(extractor):
	var depot = closest_depot(extractor.global_position)
	if depot == null:
		return 0.0
	return _distance(depot.global_position, extractor.global_position)


func get_road_upgrade_for(extractor):
	"""{"level", "entry", "cost"} of the next upgrade of the extractor's route, or null"""
	var levels = Constants.Match.Roads.LEVELS
	var next_level = get_road_level(extractor) + 1
	if next_level >= levels.size() or closest_depot(extractor.global_position) == null:
		return null
	var segments = max(1, int(ceil(get_road_length_m(extractor) / 10.0)))
	var cost = {}
	for resource in levels[next_level].get("cost_per_10_m", {}):
		cost[resource] = int(levels[next_level]["cost_per_10_m"][resource]) * segments
	return {"level": next_level, "entry": levels[next_level], "cost": cost}


func can_upgrade_road(extractor):
	var upgrade = get_road_upgrade_for(extractor)
	return (
		upgrade != null
		and extractor.is_constructed()
		and _player.has_tier(int(upgrade["entry"].get("tier", 1)))
		and _player.has_resources(upgrade["cost"])
	)


func upgrade_road(extractor):
	if not can_upgrade_road(extractor):
		return false
	var upgrade = get_road_upgrade_for(extractor)
	_player.subtract_resources(upgrade["cost"])
	road_levels[extractor] = upgrade["level"]
	_update_road_visual(extractor)
	if not extractor.tree_exiting.is_connected(_on_extractor_removed):
		extractor.tree_exiting.connect(_on_extractor_removed.bind(extractor))
	MatchSignals.road_upgraded.emit(_player, extractor, upgrade["level"])
	return true


func _on_extractor_removed(extractor):
	road_levels.erase(extractor)
	var visual = _road_visuals.get(extractor)
	if visual != null and is_instance_valid(visual):
		visual.queue_free()
	_road_visuals.erase(extractor)
	MatchSignals.road_upgraded.emit(_player, extractor, 0)


func _update_road_visual(extractor):
	"""a simple strip between the depot and the extractor so upgraded routes are visible"""
	var depot = closest_depot(extractor.global_position)
	if depot == null:
		return
	var visual = _road_visuals.get(extractor)
	if visual == null or not is_instance_valid(visual):
		visual = MeshInstance3D.new()
		visual.name = "Road"
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(visual)
		_road_visuals[extractor] = visual
	var start = depot.global_position * Vector3(1, 0, 1)
	var end = extractor.global_position * Vector3(1, 0, 1)
	var length = start.distance_to(end)
	var mesh = BoxMesh.new()
	mesh.size = Vector3(ROAD_WIDTH_M, 0.04, max(0.1, length))
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(
		Constants.Match.Roads.LEVELS[get_road_level(extractor)].get("color", "#555555")
	)
	material.roughness = 0.95
	mesh.material = material
	visual.mesh = mesh
	visual.global_transform = Transform3D(Basis(), (start + end) * 0.5 + Vector3(0, 0.03, 0))
	if length > 0.01:
		visual.look_at(end + Vector3(0, 0.03, 0), Vector3.UP)


func is_unit_out_of_fuel(unit):
	return out_of_fuel and Constants.Match.Units.FUEL_PER_S.get(unit._scene_path(), 0.0) > 0.0


func _tick():
	var delta = Constants.Match.Logistics.TICK_S
	_clock_s += delta
	_burn_fuel(delta)
	fleet.update(delta)
	_supply_sites_in_yards()
	_since_links_s += delta
	if _since_links_s >= 1.0:
		_since_links_s = 0.0
		_update_storage_links()
	for zone in danger_zones:
		zone[1] -= delta
	danger_zones = danger_zones.filter(func(zone): return zone[1] > 0.0)
	_run_job_board()
	_since_demand_s += delta
	if _since_demand_s >= 2.0:
		_since_demand_s = 0.0
		fleet.refresh_estimates()


func _burn_fuel(delta):
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player != _player:
			continue
		var movement = unit.find_child("Movement")
		if movement == null or movement.velocity.length_squared() < 0.0001:
			continue
		_fuel_accumulated += Constants.Match.Units.FUEL_PER_S.get(unit._scene_path(), 0.0) * delta
	var whole = int(floor(_fuel_accumulated))
	if whole > 0:
		var burnt = min(whole, _player.oil)
		if burnt > 0:
			_player.subtract_resources({"oil": burnt})
		_fuel_accumulated -= whole
		Utils.Dict.add_amount(fuel_burnt_total, "oil", burnt)
	out_of_fuel = _player.oil <= 0 and not FeatureFlags.allow_resources_deficit_spending


func _supply_sites_in_yards():
	var budget_per_site = (
		Constants.Match.Logistics.YARD_DELIVERY_PER_S * Constants.Match.Logistics.TICK_S
	)
	for site in get_sites():
		site.repay_lost_materials()
		if not is_in_yard(site.global_position):
			continue
		var budget = int(ceil(budget_per_site))
		for resource in site.materials_pending.keys():
			var amount = min(site.materials_pending[resource], budget)
			if amount <= 0:
				continue
			budget -= amount
			Utils.Dict.add_amount(site.materials_pending, resource, -amount)
			site.receive_materials({resource: amount}, false)


func assign_supply(hauler, site):
	var depot = closest_depot(site.global_position)
	if depot == null:
		return false
	# keyed by id: the lambda below may outlive the site (freed objects can't be captured)
	var site_id = site.get_instance_id()
	_site_loaders[site_id] = _site_loaders.get(site_id, 0) + 1
	var state = {"loading": true}
	var release_loader = func():
		if state["loading"]:
			state["loading"] = false
			_site_loaders[site_id] = max(0, _site_loaders.get(site_id, 1) - 1)
			if _site_loaders[site_id] == 0:
				_site_loaders.erase(site_id)
	var site_ref = weakref(site)
	var load_materials = func():
		release_loader.call()
		var target = site_ref.get_ref()
		if target == null or not target.is_inside_tree():
			return false
		var materials = target.take_pending_materials(hauler.get_free_capacity())
		if materials.is_empty():
			return false
		hauler.load_cargo(materials, target)
		return true
	var unload_materials = func():
		var target = site_ref.get_ref()
		if target == null or not target.is_inside_tree():
			return false
		target.receive_materials(hauler.unload_cargo())
		return true
	hauler.road_speed_multiplier = 1.0
	hauler.action = Hauling.new(
		[[depot, load_materials], [site, unload_materials]], release_loader, "SUPPLYING"
	)
	return true


func _assign_pickup(hauler, source):
	var depot = closest_depot(source.global_position)
	if depot == null:
		return false
	var amount = min(source.get_available_for_pickup(), hauler.get_free_capacity())
	if amount <= 0:
		return false
	source.reserve_pickup(amount)
	var state = {"reserved": true, "started": _clock_s}
	var source_ref = weakref(source)  # the lambdas may outlive the source
	var release_reservation = func():
		if state["reserved"]:
			state["reserved"] = false
			var target = source_ref.get_ref()
			if target != null:
				target.cancel_pickup_reservation(amount)
	var take_goods = func():
		var target = source_ref.get_ref()
		if target == null or not target.is_inside_tree():
			state["reserved"] = false
			return false
		state["reserved"] = false
		var goods = target.take_goods(amount)
		if goods.is_empty():
			return false
		hauler.load_cargo(goods)
		return true
	var source_id = source.get_instance_id()
	var unload_goods = func():
		var goods = hauler.unload_cargo()
		if source_id in route_stats:
			route_stats[source_id]["delivered"] += Utils.Dict.sum(goods)
			route_stats[source_id]["trips"] += 1
			route_stats[source_id]["trip_s"] += _clock_s - state["started"]
		deliver(goods)
		return true
	_stats_of(source)
	hauler.cargo_source_id = source_id
	hauler.road_speed_multiplier = (
		get_road_speed_multiplier(source) if source is Extractor else 1.0
	)
	hauler.action = Hauling.new(
		[[source, take_goods], [depot, unload_goods]], release_reservation, "COLLECTING"
	)
	return true


func _assign_unloading(hauler):
	hauler.road_speed_multiplier = 1.0
	var site = hauler.cargo_site
	if (
		site != null
		and is_instance_valid(site)
		and site.is_inside_tree()
		and site.is_under_construction()
	):
		var site_ref = weakref(site)
		var unload_materials = func():
			var target = site_ref.get_ref()
			if target == null or not target.is_inside_tree():
				return false
			target.receive_materials(hauler.unload_cargo())
			return true
		hauler.action = Hauling.new([[site, unload_materials]], null, "SUPPLYING")
		return true
	var depot = closest_depot(hauler.global_position)
	if depot == null:
		return false
	var unload_goods = func():
		hauler.cargo_site = null
		deliver(hauler.unload_cargo())
		return true
	hauler.action = Hauling.new([[depot, unload_goods]], null, "RETURNING")
	return true


func _on_cargo_destroyed(_unit, owner, cargo, looter, loot):
	if owner == _player:
		for resource in cargo:
			Utils.Dict.add_amount(lost_total, resource, cargo[resource])
		var source_id = _unit.get("cargo_source_id") if is_instance_valid(_unit) else null
		if source_id != null and source_id in route_stats:
			route_stats[source_id]["lost"] += Utils.Dict.sum(cargo)
	if looter == _player:
		for resource in loot:
			Utils.Dict.add_amount(looted_total, resource, loot[resource])


func _on_route_raided(player, position):
	"""a truck or train was destroyed: its route is avoided for a while"""
	if player != _player:
		return
	danger_zones.append(
		[position * Vector3(1, 0, 1), float(Constants.Match.Logistics.RAIDS.get("avoid_s", 45.0))]
	)


static func _distance(a, b):
	return (a * Vector3(1, 0, 1)).distance_to(b * Vector3(1, 0, 1))
