extends Node

# Keeps the AI's economy running: enough constructors and haulers, a command center,
# extractors on the closest free deposits of each commodity (as many as the personality
# asks for) and enough power plants to keep the grid out of a blackout. Haulers are run
# by the player's Logistics node like for any other player.

signal resources_required(resources, metadata)

const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const CommandCenterScene = preload("res://source/match/units/CommandCenter.tscn")
const Worker = preload("res://source/match/units/Worker.gd")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const Hauler = preload("res://source/match/units/Hauler.gd")
const HaulerScene = preload("res://source/match/units/Hauler.tscn")
const Extractor = preload("res://source/match/units/Extractor.gd")
const PowerPlantScene = preload("res://source/match/units/PowerPlant.tscn")
const EXTRACTOR_SCENES = {
	"timber": "res://source/match/units/LumberMill.tscn",
	"iron": "res://source/match/units/Mine.tscn",
	"copper": "res://source/match/units/Mine.tscn",
	"oil": "res://source/match/units/OilDerrick.tscn",
}
const REFRESH_INTERVAL_S = 2.0
const MAX_DEPOSIT_DISTANCE_M = 45.0
const POWER_HEADROOM_MW = 2.0

var _player = null
var _ccs = []
var _pending_unit_requests = {}  # scene path -> number of requests waiting for resources
var _pending_units = {}  # scene path -> number of units queued in production
var _pending_structure_request = false
var _cc_base_position = null

@onready var _ai = get_parent()


func setup(player):
	_player = player
	_attach_current_ccs()
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	var timer = Timer.new()
	timer.timeout.connect(_refresh)
	add_child(timer)
	timer.start(REFRESH_INTERVAL_S)
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
	_enforce_unit_count(WorkerScene, Worker, _ai.expected_number_of_workers)
	_enforce_unit_count(HaulerScene, Hauler, _ai.expected_number_of_haulers)
	if _pending_structure_request or _count_units(Worker) == 0:
		return
	var next = _next_structure()
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
	if (
		grid != null
		and plants < _ai.expected_number_of_power_plants + 2
		and (
			plants < _ai.expected_number_of_power_plants
			or grid.total_supply_mw < grid.total_demand_mw + POWER_HEADROOM_MW
		)
		and _player.has_tier(
			int(Constants.Match.Units.TIER_REQUIREMENTS.get(PowerPlantScene.resource_path, 1))
		)
	):
		var position = _find_position_near(_ccs[0].global_position, PowerPlantScene, 6.0)
		if position != null:
			return [PowerPlantScene.resource_path, position]
	var best = null
	for kind in _ai.extractor_targets:
		var have = _extractors_of_kind(kind)
		var target = int(_ai.extractor_targets[kind])
		if have >= target:
			continue
		var ratio = float(have) / float(target)
		if best == null or ratio < best[0]:
			best = [ratio, kind]
	if best == null:
		return null
	var kind = best[1]
	var scene_path = EXTRACTOR_SCENES[kind]
	var spot = _find_extractor_spot(kind, scene_path)
	if spot == null:
		return null
	return [scene_path, spot]


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
	var prototype = scene.instantiate()
	var radius = prototype.radius
	prototype.free()
	return Utils.Match.Unit.Placement.find_valid_position_radially_yet_skip_starting_radius(
		origin,
		min_distance,
		radius + Constants.Match.Units.EMPTY_SPACE_RADIUS_SURROUNDING_STRUCTURE_M,
		0.0,
		Vector3(0, 0, 1),
		true,
		_terrain_map(),
		get_tree()
	)


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
		position = _find_position_near(
			_ccs[0].global_position if not _ccs.is_empty() else _first_worker().global_position,
			scene
		)
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
