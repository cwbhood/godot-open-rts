# TODO: monitor attached units and fix their actions if necessary
extends Node

enum State { FORMING, ATTACKING }

const PLAYER_TO_ATTACK_SWITCHING_DELAY_S = 0.5
const NOBODY_TO_ATTACK_DELAY_S = 5.0
const MAX_TARGETS_TRIED = 12  # path queries per retarget on maps with water


class Actions:
	const MovingToUnit = preload("res://source/match/units/actions/MovingToUnit.gd")
	const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")


const WaterRules = preload("res://source/match/WaterRules.gd")

var _expected_number_of_units = null
var _players_to_attack = null
var _player_to_attack = null
var _owner_ai = null  # decides who may be attacked (treaties, personality)
var _retarget_pending = false

var _state = State.FORMING
var _attached_units = []


func _init(expected_number_of_units, players_to_attack, owner_ai = null):
	_expected_number_of_units = expected_number_of_units
	_players_to_attack = players_to_attack
	_player_to_attack = _players_to_attack.front()
	_owner_ai = owner_ai


func _ready():
	MatchSignals.diplomacy_changed.connect(_on_diplomacy_changed)


func size():
	return _attached_units.size()


func attach_unit(unit):
	assert(_state == State.FORMING, "unexpected state")
	_attached_units.append(unit)
	unit.tree_exited.connect(_on_unit_died.bind(unit))
	if size() == _expected_number_of_units:
		_start_attacking()


func _start_attacking():
	_state = State.ATTACKING
	_attack_next_adversary_unit()


func _attack_next_adversary_unit():
	if not is_inside_tree() or _attached_units.is_empty():
		return
	if not _may_attack(_player_to_attack):
		_attack_next_player()
		return
	var adversary_units = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == _player_to_attack
	)
	if adversary_units.is_empty():
		_attack_next_player()
		return
	var battlegroup_position = _attached_units[0].global_position
	var adversary_units_sorted_by_distance = adversary_units.map(
		func(adversary_unit):
			return {
				"distance":
				(adversary_unit.global_position * Vector3(1, 0, 1)).distance_to(
					battlegroup_position
				),
				"unit": adversary_unit
			}
	)
	adversary_units_sorted_by_distance.sort_custom(
		func(tuple_a, tuple_b): return tuple_a["distance"] < tuple_b["distance"]
	)
	for tuple in adversary_units_sorted_by_distance.slice(0, MAX_TARGETS_TRIED):
		var target_unit = tuple["unit"]
		if _attached_units.any(
			func(attached_unit):
				return (
					Actions.AutoAttacking.is_applicable(attached_unit, target_unit)
					and _can_reach(attached_unit, target_unit)
				)
		):
			if not target_unit.tree_exited.is_connected(_on_target_unit_died):
				target_unit.tree_exited.connect(_on_target_unit_died, CONNECT_ONE_SHOT)
			for attached_unit in _attached_units:
				if Actions.AutoAttacking.is_applicable(attached_unit, target_unit):
					attached_unit.action = Actions.AutoAttacking.new(target_unit)
				else:
					attached_unit.action = Actions.MovingToUnit.new(target_unit)
			return
	# if not possible to attack remaining units:
	_attack_next_player()


func _can_reach(attached_unit, target_unit):
	"""land units leave targets across deep water alone (always true on maps without water)"""
	var reach = (
		attached_unit.attack_range + target_unit.radius + 1.0
		if "attack_range" in attached_unit and attached_unit.attack_range != null
		else target_unit.radius + 4.0
	)
	return WaterRules.can_reach(attached_unit, target_unit.global_position, reach)


func _attack_next_player():
	var player_to_attack_index = _players_to_attack.find(_player_to_attack)
	var next_player_to_attack_index = (player_to_attack_index + 1) % _players_to_attack.size()
	_player_to_attack = _players_to_attack[next_player_to_attack_index]
	if _retarget_pending:
		return
	_retarget_pending = true
	var delay = PLAYER_TO_ATTACK_SWITCHING_DELAY_S
	if not _players_to_attack.any(_may_attack):
		delay = NOBODY_TO_ATTACK_DELAY_S  # everybody is protected or left alone: wait
	get_tree().create_timer(delay).timeout.connect(_on_retarget_timeout)


func _on_retarget_timeout():
	_retarget_pending = false
	_attack_next_adversary_unit()


func _may_attack(player):
	return is_instance_valid(player) and (_owner_ai == null or _owner_ai.wants_to_attack(player))


func _on_diplomacy_changed(_a, _b, _relation):
	# a treaty may have stopped the attack, or a new war (ours or our ally's) begun
	if _state == State.ATTACKING and _owner_ai != null and not _retarget_pending:
		_attack_next_adversary_unit()


func _on_unit_died(unit):
	if not is_inside_tree():
		return
	_attached_units.erase(unit)
	if _state == State.ATTACKING and _attached_units.is_empty():
		queue_free()


func _on_target_unit_died():
	if not is_inside_tree():
		return
	_attack_next_adversary_unit()
