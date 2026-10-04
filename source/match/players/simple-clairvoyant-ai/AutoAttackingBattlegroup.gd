# TODO: monitor attached units and fix their actions if necessary
extends Node

# The owner AI's difficulty decides how well the group fights: when it may first attack,
# how long it takes to pick a new target, whether its units focus one target or spread out,
# and whether badly damaged units pull back home (see data/difficulties/).

signal unit_retreated(unit)

enum State { FORMING, ATTACKING }

const PLAYER_TO_ATTACK_SWITCHING_DELAY_S = 0.5
const NOBODY_TO_ATTACK_DELAY_S = 5.0
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const RETREAT_CHECK_INTERVAL_S = 1.0


class Actions:
	const MovingToUnit = preload("res://source/match/units/actions/MovingToUnit.gd")
	const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
	const Moving = preload("res://source/match/units/actions/Moving.gd")


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
	if _owner_ai != null and _owner_ai.retreat_below_hp > 0.0:
		var timer = Timer.new()
		timer.timeout.connect(_pull_back_damaged_units)
		add_child(timer)
		timer.start(RETREAT_CHECK_INTERVAL_S)


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
	if _owner_ai != null and not _owner_ai.may_launch_attacks():
		var wait_s = _owner_ai.first_attack_after_s - _owner_ai.match_time_s
		get_tree().create_timer(max(wait_s, 0.1)).timeout.connect(_start_attacking)
		return
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
	if not _focuses_fire():
		if _attack_spread_out(adversary_units):
			return
		_attack_next_player()
		return
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


func _focuses_fire():
	return _owner_ai == null or _owner_ai.focus_fire


func _attack_spread_out(adversary_units):
	"""every unit goes for the enemy closest to itself: damage is spread and targets
	survive longer than when the whole group focuses one; returns false if none reachable"""
	var any_target = false
	for attached_unit in _attached_units:
		var best = null
		var best_distance = INF
		for adversary_unit in adversary_units:
			if not Actions.AutoAttacking.is_applicable(attached_unit, adversary_unit):
				continue
			var distance = attached_unit.global_position.distance_to(adversary_unit.global_position)
			if distance < best_distance:
				best_distance = distance
				best = adversary_unit
		if best == null:
			continue
		any_target = true
		if not best.tree_exited.is_connected(_on_target_unit_died):
			best.tree_exited.connect(_on_target_unit_died, CONNECT_ONE_SHOT)
		attached_unit.action = Actions.AutoAttacking.new(best)
	return any_target


func _pull_back_damaged_units():
	"""micro on harder difficulties: badly damaged units drive home instead of dying"""
	if _state != State.ATTACKING or _attached_units.size() <= 1:
		return
	var home = _home_position()
	if home == null:
		return
	for unit in _attached_units.duplicate():
		if (
			not is_instance_valid(unit)
			or unit.hp == null
			or unit.hp_max == null
			or unit.hp_max <= 0
		):
			continue
		if float(unit.hp) / float(unit.hp_max) >= _owner_ai.retreat_below_hp:
			continue
		if unit.global_position.distance_to(home) < 8.0:
			continue
		_attached_units.erase(unit)
		unit.tree_exited.disconnect(_on_unit_died)
		unit.action = Actions.Moving.new(home)
		unit_retreated.emit(unit)
		if _attached_units.size() <= 1:
			break


func _home_position():
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _owner_ai and unit is CommandCenter:
			return unit.global_position + Vector3(3, 0, 3)
	return null


func _attack_next_player():
	_target_unit = null
	var player_to_attack_index = _players_to_attack.find(_player_to_attack)
	var next_player_to_attack_index = (player_to_attack_index + 1) % _players_to_attack.size()
	_player_to_attack = _players_to_attack[next_player_to_attack_index]
	if _retarget_pending:
		return
	_retarget_pending = true
	var delay = PLAYER_TO_ATTACK_SWITCHING_DELAY_S
	if _owner_ai != null:
		delay = max(delay, _owner_ai.reaction_delay_s)
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
	if not is_inside_tree() or _retarget_pending:
		return
	var delay = _owner_ai.reaction_delay_s if _owner_ai != null else 0.0
	if delay <= 0.0:
		_attack_next_adversary_unit()
		return
	_retarget_pending = true  # easier AIs are slow to notice that their target is gone
	get_tree().create_timer(delay).timeout.connect(_on_retarget_timeout)
