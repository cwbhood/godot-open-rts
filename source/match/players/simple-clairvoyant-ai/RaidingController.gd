extends Node

# Sends small parties of fast raiders against the supply lines of other factions:
# haulers and caravans on the road first, then remote extractors and pylons. How often
# and how many depends on the AI personality. The raiders are the faction's "raider" role
# (see Factions.gd): the Syndicate's raiders, the Foundry's tanks.

signal resources_required(resources, metadata)

const Factions = preload("res://source/data-model/Factions.gd")
const VehicleFactory = preload("res://source/match/units/VehicleFactory.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const Pylon = preload("res://source/match/units/Pylon.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")

const RETARGET_INTERVAL_S = 2.0

var raids_launched = 0  # statistics

var _player = null
var _forming = []
var _raiding = []
var _pending_requests = 0
var _awaited = 0  # raiders ordered from the factory and not out yet
var _since_last_raid_s = 0.0
var _raider_scene = null

@onready var _ai = get_parent()


func setup(player):
	_player = player
	var path = Factions.role_scene_of(player, "raider")
	_raider_scene = load(path) if path != null else null
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	var timer = Timer.new()
	var interval = _ai.think_interval(RETARGET_INTERVAL_S)
	timer.timeout.connect(_tick.bind(interval))
	add_child(timer)
	timer.start(interval)


func provision(resources, _metadata):
	_pending_requests -= 1
	var factory = _factory()
	if factory == null or _raider_scene == null or not _player.has_resources(resources):
		return
	if factory.production_queue.produce(_raider_scene, true) != null:
		_awaited += 1


func committed_units():
	"""raiders out on a raid; the ones still forming wait with the rest of the army"""
	return _raiding.filter(func(unit): return is_instance_valid(unit))


func claims(unit):
	"""whether the unit is one of the raiders; a new unit of the raider's kind is taken
	when one was ordered (the main army may build the same kind)"""
	if unit in _forming or unit in _raiding:
		return true
	if (
		_awaited <= 0
		or unit.player != _player
		or _raider_scene == null
		or unit._scene_path() != _raider_scene.resource_path
	):
		return false
	_awaited -= 1
	_forming.append(unit)
	return true


func _tick(delta):
	if _ai.raid_party_size <= 0 or _ai.raid_interval_s <= 0 or _raider_scene == null:
		return
	_forming = _forming.filter(func(unit): return is_instance_valid(unit) and unit.is_inside_tree())
	_raiding = _raiding.filter(func(unit): return is_instance_valid(unit) and unit.is_inside_tree())
	_since_last_raid_s += delta
	_awaited = min(_awaited, _queued_raiders())  # orders cancelled by the army are dropped
	if (
		_since_last_raid_s >= _ai.raid_interval_s
		and _ai.may_launch_attacks()
		and _forming.size() + _pending_requests + _awaited < _ai.raid_party_size
		and _factory() != null
	):
		_pending_requests += 1
		resources_required.emit(
			Constants.Match.Units.PRODUCTION_COSTS[_raider_scene.resource_path], "raider"
		)
	if _forming.size() >= _ai.raid_party_size:
		_since_last_raid_s = 0.0
		raids_launched += 1
		_raiding += _forming
		_forming = []
	for raider in _raiding:
		if not raider.action is AutoAttacking:
			var target = _pick_target(raider)
			if target != null:
				raider.action = AutoAttacking.new(target)


func _pick_target(raider):
	var best = null
	var best_score = INF
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _player or not AutoAttacking.is_applicable(raider, unit):
			continue
		if not _ai.wants_to_attack(unit.player):
			continue
		var weight = 0.0
		if unit is Hauler:
			weight = 1.0
		elif unit is Extractor or unit is Pylon:
			weight = 1.6
		else:
			continue
		# remote targets are safer to hit than the ones next to the enemy depot
		var score = unit.global_position.distance_to(raider.global_position) * weight
		score -= _distance_to_enemy_depot(unit) * 0.5
		if score < best_score:
			best_score = score
			best = unit
	return best


func _distance_to_enemy_depot(unit):
	var closest = INF
	for other in get_tree().get_nodes_in_group("units"):
		if other is CommandCenter and other.player == unit.player:
			closest = min(closest, other.global_position.distance_to(unit.global_position))
	return closest if closest != INF else 0.0


func _queued_raiders():
	var factory = _factory()
	if factory == null:
		return 0
	return (
		factory
		. production_queue
		. get_elements()
		. filter(func(element): return element.unit_prototype == _raider_scene)
		. size()
	)


func _factory():
	for unit in get_tree().get_nodes_in_group("units"):
		if unit is VehicleFactory and unit.player == _player and unit.is_constructed():
			return unit
	return null


func _on_unit_spawned(unit):
	claims(unit)
