extends Node

# Sends small parties of fast raiders against the supply lines of other factions:
# haulers and caravans on the road first, then remote extractors and pylons. How often
# and how many depends on the AI personality.

signal resources_required(resources, metadata)

const RaiderScene = preload("res://source/match/units/Raider.tscn")
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
var _since_last_raid_s = 0.0

@onready var _ai = get_parent()


func setup(player):
	_player = player
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	var timer = Timer.new()
	var interval = _ai.think_interval(RETARGET_INTERVAL_S)
	timer.timeout.connect(_tick.bind(interval))
	add_child(timer)
	timer.start(interval)


func provision(resources, _metadata):
	_pending_requests -= 1
	var factory = _factory()
	if factory == null or not _player.has_resources(resources):
		return
	factory.production_queue.produce(RaiderScene, true)


func committed_units():
	"""raiders out on a raid; the ones still forming wait with the rest of the army"""
	return _raiding.filter(func(unit): return is_instance_valid(unit))


func _tick(delta):
	if _ai.raid_party_size <= 0 or _ai.raid_interval_s <= 0:
		return
	_forming = _forming.filter(func(unit): return is_instance_valid(unit) and unit.is_inside_tree())
	_raiding = _raiding.filter(func(unit): return is_instance_valid(unit) and unit.is_inside_tree())
	_since_last_raid_s += delta
	if (
		_since_last_raid_s >= _ai.raid_interval_s
		and _ai.may_launch_attacks()
		and _forming.size() + _pending_requests < _ai.raid_party_size
		and _factory() != null
	):
		_pending_requests += 1
		resources_required.emit(
			Constants.Match.Units.PRODUCTION_COSTS[RaiderScene.resource_path], "raider"
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


func _factory():
	for unit in get_tree().get_nodes_in_group("units"):
		if unit is VehicleFactory and unit.player == _player and unit.is_constructed():
			return unit
	return null


func _on_unit_spawned(unit):
	if unit.player == _player and unit._scene_path() == RaiderScene.resource_path:
		_forming.append(unit)
