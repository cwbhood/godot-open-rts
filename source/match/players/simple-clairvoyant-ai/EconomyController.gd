extends Node

# Keeps the AI's economy running: enough constructors and haulers, a command center,
# extractors on the closest free deposits of each commodity (as many as the personality
# asks for) and enough power plants to keep the grid out of a blackout. Haulers are run
# by the player's Logistics node like for any other player; the AI keeps as many as the
# logistics demand estimate asks for (capped by its personality), recycles the surplus,
# builds a storage next to clusters of extractors and a freight train once its city
# reaches the train's tier and far extractors call for one.

signal resources_required(resources, metadata)

const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const Worker = preload("res://source/match/units/Worker.gd")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const Hauler = preload("res://source/match/units/Hauler.gd")
const HaulerScene = preload("res://source/match/units/Hauler.tscn")
const Extractor = preload("res://source/match/units/Extractor.gd")
const WaterRules = preload("res://source/match/WaterRules.gd")
const PowerPlantScene = preload("res://source/match/units/PowerPlant.tscn")
const AirportScene = preload("res://source/match/units/Airport.tscn")
const GameData = preload("res://source/data-model/GameData.gd")
const StorageScene = preload("res://source/match/units/Storage.tscn")
const TrainScene = preload("res://source/match/units/Train.tscn")
const Train = preload("res://source/match/units/Train.gd")
const Storage = preload("res://source/match/units/Storage.gd")
const EXTRACTOR_PRIORITY = ["iron", "oil", "timber", "copper"]  # ties go to the first
const REFRESH_INTERVAL_S = 2.0
const MAX_DEPOSIT_DISTANCE_M = 55.0
const POWER_HEADROOM_MW = 2.0
const MAX_PLACEMENT_RINGS = 12
const MIN_EXTRACTORS_FIRST = 3  # before optional power plants
const ROAD_UPGRADE_INTERVAL_S = 20.0
const ROAD_UPGRADE_MIN_LENGTH_M = 15.0  # short routes are not worth paving
const RECYCLE_INTERVAL_S = 10.0
const EXTRACTORS_PER_TRAIN = 6

var _player = null
var _ccs = []
var _pending_unit_requests = {}  # scene path -> number of requests waiting for resources
var _pending_units = {}  # scene path -> number of units queued in production
var _pending_structure_request = false
var _cc_base_position = null
var _since_road_upgrade_s = 0.0
var _since_recycle_s = 0.0
var _extractor_scenes = _find_extractor_scenes()  # commodity -> scene of its extractor

@onready var _ai = get_parent()


func setup(player):
	_player = player
	_attach_current_ccs()
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	var timer = Timer.new()
	timer.timeout.connect(_refresh)
	add_child(timer)
	timer.start(_ai.think_interval(REFRESH_INTERVAL_S))
	_refresh()


func provision(resources, metadata):
	if metadata is Dictionary and metadata.get("kind") == "unit":
		var scene_path = metadata["scene"]
		_pending_unit_requests[scene_path] = _pending_unit_requests.get(scene_path, 1) - 1
		var cc = _first_cc()
		if cc == null:
			return
		if cc.production_queue.produce(load(scene_path), true) != null:
			_pending_units[scene_path] = _pending_units.get(scene_path, 0) + 1
	elif metadata is Dictionary and metadata.get("kind") == "structure":
		_pending_structure_request = false
		var scene_path = metadata["scene"]
		assert(
			resources == Constants.Match.Units.CONSTRUCTION_COSTS[scene_path],
			"unexpected amount of resources"
		)
		if _count_units(Worker) == 0:
			return
		_place_structure(load(scene_path), metadata["position"])
	else:
		assert(false, "unexpected flow")


func _refresh():
	_ccs = _ccs.filter(func(cc): return is_instance_valid(cc) and cc.is_inside_tree())
	# extractors come first: more constructors and haulers only pay off once there is
	# something to haul
	var extractors = _count_units(Extractor)
	_enforce_unit_count(
		WorkerScene, Worker, min(_ai.expected_number_of_workers, 2 + int(extractors / 2.0))
	)
	var logistics = _player.logistics
	var hauler_target = min(_ai.expected_number_of_haulers, 2 + int(extractors / 2.0))
	if logistics != null:
		hauler_target = min(_ai.expected_number_of_haulers, logistics.fleet.get_truck_target())
	_enforce_unit_count(HaulerScene, Hauler, hauler_target)
	_recycle_surplus_haulers(hauler_target)
	_maybe_order_a_train(extractors)
	_try_upgrading_a_road()
	if _pending_structure_request or _count_units(Worker) == 0:
		return
	var next = _next_airport() if not _ccs.is_empty() and _needs_airport() else null
	if next == null and extractors >= MIN_EXTRACTORS_FIRST and not _ccs.is_empty():
		next = _next_storage()
	if next == null:
		next = _next_structure()
	if next == null:
		return
	_pending_structure_request = true
	resources_required.emit(
		Constants.Match.Units.CONSTRUCTION_COSTS[next[0]],
		{"kind": "structure", "scene": next[0], "position": next[1]}
	)


func _next_structure():
	"""[scene path, position] of the next structure to build or null"""
	if _ccs.is_empty():
		var worker = _first_worker()
		if worker == null:
			return null
		return [
			CommandCenterScene.resource_path,
			_find_position_near(
				_cc_base_position if _cc_base_position != null else worker.global_position,
				CommandCenterScene
			)
		]
	var grid = _player.power_grid
	var plants = _count_scene(PowerPlantScene.resource_path)
	var extractors = _count_units(Extractor)
	if (
		grid != null
		and plants < _ai.expected_number_of_power_plants + 2
		and (
			(plants < _ai.expected_number_of_power_plants and extractors >= MIN_EXTRACTORS_FIRST)
			or (
				grid.total_supply_mw
				< (
					grid.total_demand_mw
					+ (POWER_HEADROOM_MW if extractors >= MIN_EXTRACTORS_FIRST else 0.0)
				)
			)
		)
		and _player.has_tier(
			int(Constants.Match.Units.TIER_REQUIREMENTS.get(PowerPlantScene.resource_path, 1))
		)
		and _obtainable(PowerPlantScene.resource_path)
	):
		var position = _find_position_near(_ccs[0].global_position, PowerPlantScene, 6.0)
		if position != null:
			return [PowerPlantScene.resource_path, position]
	var best = null
	for kind in EXTRACTOR_PRIORITY + _ai.extractor_targets.keys():
		if not kind in _ai.extractor_targets or not kind in _extractor_scenes:
			continue
		var have = _extractors_of_kind(kind)
		var target = int(_ai.extractor_targets[kind])
		if have >= target:
			continue
		var ratio = float(have) / float(target)
		if not _obtainable(_extractor_scenes[kind]):
			continue
		if (
			(best == null or ratio < best[0])
			and _find_extractor_spot(kind, _extractor_scenes[kind]) != null
		):
			best = [ratio, kind]
	if best == null:
		return null
	var kind = best[1]
	var scene_path = _extractor_scenes[kind]
	var spot = _find_extractor_spot(kind, scene_path)
	if spot == null:
		return null
	return [scene_path, spot]


func _recycle_surplus_haulers(target):
	"""one idle hauler at a time, only when it has had nothing to do for a while"""
	_since_recycle_s += REFRESH_INTERVAL_S
	var logistics = _player.logistics
	if logistics == null or _since_recycle_s < RECYCLE_INTERVAL_S:
		return
	if logistics.fleet.surplus_trucks > 0 and _count_units(Hauler) > target:
		_since_recycle_s = 0.0
		logistics.fleet.recycle_surplus(1)


func _maybe_order_a_train(extractors):
	var logistics = _player.logistics
	var path = TrainScene.resource_path
	if (
		logistics == null
		or _ccs.is_empty()
		or not _player.meets_tier_requirement(path)
		or not logistics.rails.wants_train()
		or _count_units(Train) >= 1 + int(extractors / float(EXTRACTORS_PER_TRAIN))
		or _pending_unit_requests.get(path, 0) + _pending_units.get(path, 0) > 0
		or not _ai._has_resources_beyond_trade_reserve(Constants.Match.Units.PRODUCTION_COSTS[path])
	):
		return
	_enforce_unit_count(TrainScene, Train, _count_units(Train) + 1)


func _next_storage():
	"""[scene path, position] of a storage gathering a cluster of extractors, or null"""
	var logistics = _player.logistics
	if logistics == null or _count_scene_under_construction(StorageScene.resource_path) > 0:
		return null
	if not _obtainable(StorageScene.resource_path):
		return null
	var site = logistics.suggest_storage_site()
	if site == null:
		return null
	var position = _find_position_near(site["position"], StorageScene)
	if position == null:
		return null
	var reach = float(Constants.Match.Logistics.STORAGE.get("link_radius_m", 12.0))
	var linked = site["extractors"].filter(
		func(extractor): return extractor.global_position_yless.distance_to(position) <= reach
	)
	if linked.size() < 2:
		return null
	return [StorageScene.resource_path, position]


func _count_scene_under_construction(scene_path):
	var count = 0
	for unit in get_tree().get_nodes_in_group("units"):
		if (
			unit.player == _player
			and unit._scene_path() == scene_path
			and unit.is_under_construction()
		):
			count += 1
	return count


func _try_upgrading_a_road():
	"""paves the longest route first, once the economy has goods to spare"""
	_since_road_upgrade_s += _ai.think_interval(REFRESH_INTERVAL_S)
	var logistics = _player.logistics
	if (
		not _ai.upgrades_roads
		or logistics == null
		or _since_road_upgrade_s < ROAD_UPGRADE_INTERVAL_S
		or _count_units(Extractor) < MIN_EXTRACTORS_FIRST
	):
		return
	var best = null
	for extractor in logistics.get_extractors():
		var length = logistics.get_road_length_m(extractor)
		if length < ROAD_UPGRADE_MIN_LENGTH_M or not logistics.can_upgrade_road(extractor):
			continue
		var upgrade = logistics.get_road_upgrade_for(extractor)
		if not _ai._has_resources_beyond_trade_reserve(upgrade["cost"]):
			continue
		if best == null or length > best[0]:
			best = [length, extractor]
	if best != null and logistics.upgrade_road(best[1]):
		_since_road_upgrade_s = 0.0


func _next_airport():
	var position = _find_position_near(_ccs[0].global_position, AirportScene, 7.0)
	return [AirportScene.resource_path, position] if position != null else null


func _needs_airport():
	"""fixed-wing aircraft (the starting drone) crash without an airport to land at"""
	var has_aircraft = get_tree().get_nodes_in_group("units").any(
		func(unit):
			return unit.player == _player and unit.get_node_or_null("FixedWingFlight") != null
	)
	return (
		has_aircraft
		and _count_scene(AirportScene.resource_path) == 0
		and _player.meets_tier_requirement(AirportScene.resource_path)
		and _obtainable(AirportScene.resource_path)
	)


func _obtainable(scene_path):
	"""false when the structure needs a commodity the AI neither has nor extracts, so that
	such a request does not block the economy forever (e.g. copper on a copper-less map)"""
	var cost = Constants.Match.Units.CONSTRUCTION_COSTS.get(scene_path, {})
	for resource in cost:
		if _player.get(resource) < cost[resource] and _extractors_of_kind(resource) == 0:
			return false
	return true


static func _find_extractor_scenes():
	"""the cheapest tier-1 structure from data/units/ extracting each commodity"""
	var scenes = {}
	for unit in GameData.units():
		if int(unit.get("tier", 1)) != 1:
			continue
		for kind in unit.get("extracts", []):
			if (
				not kind in scenes
				or (
					Utils.Dict.sum(unit.get("cost", {}))
					< Utils.Dict.sum(GameData.unit_by_scene(scenes[kind]).get("cost", {}))
				)
			):
				scenes[kind] = unit["scene"]
	return scenes


func _extractors_of_kind(kind):
	var count = 0
	for unit in get_tree().get_nodes_in_group("units"):
		if unit is Extractor and unit.player == _player:
			var unit_kind = unit.resource_kind
			if unit_kind == null and unit.is_under_construction():
				var deposit = Extractor.find_deposit_near(
					unit._scene_path(), unit.global_position, unit.radius, get_tree()
				)
				unit_kind = deposit.kind if deposit != null else null
			if unit_kind == kind:
				count += 1
	return count


func _find_extractor_spot(kind, scene_path):
	var base = _ccs[0].global_position
	var deposits = get_tree().get_nodes_in_group("deposits").filter(
		func(deposit):
			return (
				deposit.kind == kind
				and deposit.global_position.distance_to(base) <= MAX_DEPOSIT_DISTANCE_M
				and not _deposit_taken(deposit)
				and WaterRules.land_reaches(
					get_tree(), base, deposit.global_position, deposit.radius + 6.0
				)
			)
	)
	deposits.sort_custom(
		func(a, b): return a.global_position.distance_to(base) < b.global_position.distance_to(base)
	)
	var prototype = load(scene_path).instantiate()
	var radius = prototype.radius
	prototype.free()
	for deposit in deposits:
		var towards_base = (base - deposit.global_position) * Vector3(1, 0, 1)
		var start_angle = atan2(towards_base.z, towards_base.x)
		for step in range(12):
			var angle = start_angle + (step + 1) / 2 * (PI / 6.0) * (1 if step % 2 == 0 else -1)
			var position = (
				deposit.global_position_yless
				+ Vector3(cos(angle), 0, sin(angle)) * (deposit.radius + radius + 0.5)
			)
			if (
				_placement_valid(position, radius)
				and Extractor.find_deposit_near(scene_path, position, radius, get_tree()) == deposit
			):
				return position
	return null


func _deposit_taken(deposit):
	for unit in get_tree().get_nodes_in_group("units"):
		if (
			unit is Extractor
			and (
				unit.deposit == deposit
				or (
					unit.is_under_construction()
					and (
						Extractor.find_deposit_near(
							unit._scene_path(), unit.global_position, unit.radius, get_tree()
						)
						== deposit
					)
				)
			)
		):
			return true
	return false


func _find_position_near(origin, scene, min_distance = 0.0):
	"""closest valid spot around 'origin' within a bounded search, null if there is none"""
	var prototype = scene.instantiate()
	var radius = prototype.radius + Constants.Match.Units.EMPTY_SPACE_RADIUS_SURROUNDING_STRUCTURE_M
	prototype.free()
	origin = origin * Vector3(1, 0, 1)
	if min_distance <= 0.0 and _placement_valid(origin, radius):
		return origin
	for ring in range(MAX_PLACEMENT_RINGS):
		var distance = max(min_distance, radius) + ring * radius
		var slots = max(6, int(TAU * distance / (radius * 2.0)))
		var start_angle = randf_range(0.0, TAU)
		for slot in range(slots):
			var angle = start_angle + TAU * slot / slots
			var position = origin + Vector3(cos(angle), 0, sin(angle)) * distance
			if _placement_valid(position, radius):
				return position
	return null


func _placement_valid(position, radius):
	if not Geometry2D.is_point_in_polygon(
		Vector2(position.x, position.z), find_parent("Match").map.get_topdown_polygon_2d()
	):
		return false
	return (
		Utils.Match.Unit.Placement.validate_agent_placement_position(
			position,
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


func _place_structure(scene, position):
	var unit_to_spawn = scene.instantiate()
	if position == null or not _placement_valid(position, unit_to_spawn.radius):
		var worker = _first_worker()
		if _ccs.is_empty() and worker == null:
			unit_to_spawn.free()
			return
		position = _find_position_near(
			_ccs[0].global_position if not _ccs.is_empty() else worker.global_position, scene
		)
		if position == null:
			unit_to_spawn.free()
			return
	var construction_cost = Constants.Match.Units.CONSTRUCTION_COSTS[scene.resource_path]
	_player.subtract_resources(construction_cost)
	var target_transform = Transform3D(Basis(), position).looking_at(
		position + Vector3(0, 0, 1), Vector3.UP
	)
	MatchSignals.setup_and_spawn_unit.emit(unit_to_spawn, target_transform, _player)


func _enforce_unit_count(scene, script, expected):
	var path = scene.resource_path
	var current = (
		_count_units(script) + _pending_unit_requests.get(path, 0) + _pending_units.get(path, 0)
	)
	for _i in range(expected - current):
		_pending_unit_requests[path] = _pending_unit_requests.get(path, 0) + 1
		resources_required.emit(
			Constants.Match.Units.PRODUCTION_COSTS[path], {"kind": "unit", "scene": path}
		)


func _count_units(script):
	return (
		get_tree()
		. get_nodes_in_group("units")
		. filter(func(unit): return unit.player == _player and is_instance_of(unit, script))
		. size()
	)


func _count_scene(scene_path):
	return (
		get_tree()
		. get_nodes_in_group("units")
		. filter(func(unit): return unit.player == _player and unit._scene_path() == scene_path)
		. size()
	)


func _first_cc():
	return _ccs[0] if not _ccs.is_empty() else null


func _first_worker():
	var workers = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Worker and unit.player == _player
	)
	return workers[0] if not workers.is_empty() else null


func _terrain_map():
	return find_parent("Match").navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)


func _attach_current_ccs():
	var ccs = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is CommandCenter and unit.player == _player
	)
	if not ccs.is_empty():
		_cc_base_position = ccs[0].global_position
	for cc in ccs:
		_ccs.append(cc)


func _on_unit_spawned(unit):
	if unit.player != _player:
		return
	var path = unit._scene_path()
	if _pending_units.get(path, 0) > 0:
		_pending_units[path] -= 1
	if unit is CommandCenter and not unit in _ccs:
		_ccs.append(unit)
