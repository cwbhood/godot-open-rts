# TODO: monitor attached units and fix their actions if necessary
extends Node

enum State { FORMING, ATTACKING }

const PLAYER_TO_ATTACK_SWITCHING_DELAY_S = 0.5
const NOBODY_TO_ATTACK_DELAY_S = 5.0


class Actions:
	const MovingToUnit = preload("res://source/match/units/actions/MovingToUnit.gd")
	const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")


var _expected_number_of_units = null
var _players_to_attack = null
var _player_to_attack = null
var _owner_ai = null  # decides who may be attacked (treaties, personality)
var _retarget_pending = false

var _state = State.FORMING
var _attached_units = []
var _target_unit = null  # what the group is going for, null while it has nobody to attack


func _init(expected_number_of_units, players_to_attack, owner_ai = null):
	_expected_number_of_units = expected_number_of_units
	_players_to_attack = players_to_attack
	_player_to_attack = _players_to_attack.front()
	_owner_ai = owner_ai


func _ready():
	MatchSignals.diplomacy_changed.connect(_on_diplomacy_changed)


func size():
	return _attached_units.size()


func units():
	return _attached_units.duplicate()


func is_attacking():
	"""on its way to or fighting a target; a formed group with nobody to attack is not"""
	if _state != State.ATTACKING:
		return false
	if _target_unit != null and is_instance_valid(_target_unit) and _target_unit.is_inside_tree():
		return true
	# between two targets: still on the attack if anybody may be attacked
	if _retarget_pending and _players_to_attack.any(_may_attack):
		return true
	# units sent at targets one by one (no single group target); units the AI's army
	# positioning sent at intruders near home do not count, they defend
	return _attached_units.any(
		func(unit):
			return (
				is_instance_valid(unit)
				and (unit.action is Actions.AutoAttacking or unit.action is Actions.MovingToUnit)
				and not unit.get_meta("defending", false)
			)
	)


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
	for tuple in adversary_units_sorted_by_distance:
		var target_unit = tuple["unit"]
		if _attached_units.any(
			func(attached_unit):
				return Actions.AutoAttacking.is_applicable(attached_unit, target_unit)
		):
			_target_unit = target_unit
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


func _attack_next_player():
	_target_unit = null
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
