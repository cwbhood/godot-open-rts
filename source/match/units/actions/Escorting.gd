extends "res://source/match/units/actions/Action.gd"

# Convoy escort: the unit sticks to a friendly unit (usually a hauler) and engages any
# enemy that comes within ESCORT_RADIUS_M of it, then returns to the convoy. The escort
# ends when the escorted unit is gone.

const Following = preload("res://source/match/units/actions/Following.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")

const REFRESH_INTERVAL = 0.25
const ESCORT_RADIUS_M = 7.0
const MAX_CHASE_M = 12.0  # gives up a chase this far from the convoy

var _escorted = null
var _sub_action = null
var _attacking = null
var _timer = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


static func is_applicable(source_unit, target_unit):
	return (
		source_unit.attack_range != null
		and source_unit.movement_speed > 0.0
		and "player" in target_unit
		and target_unit.player == source_unit.player
		and target_unit != source_unit
		and target_unit.movement_speed > 0.0
	)


func _init(escorted_unit):
	_escorted = escorted_unit


func _ready():
	_escorted.tree_exited.connect(queue_free)
	_timer = Timer.new()
	_timer.timeout.connect(_refresh)
	add_child(_timer)
	_timer.start(REFRESH_INTERVAL)
	_follow()


func _to_string():
	return "{0}({1})".format([super(), str(_sub_action) if _sub_action != null else ""])


func get_escorted_unit():
	return _escorted


func _refresh():
	if not is_instance_valid(_escorted) or not _escorted.is_inside_tree():
		return
	if _attacking != null:
		if (
			not is_instance_valid(_attacking)
			or not _attacking.is_inside_tree()
			or (
				_escorted.global_position_yless.distance_to(_attacking.global_position_yless)
				> MAX_CHASE_M
			)
		):
			_follow()
		return
	var threat = _closest_threat()
	if threat != null:
		_attack(threat)


func _closest_threat():
	var closest = null
	var closest_distance = INF
	for unit in get_tree().get_nodes_in_group("units"):
		if not AutoAttacking.is_applicable(_unit, unit):
			continue
		var distance = _escorted.global_position_yless.distance_to(unit.global_position_yless)
		if distance <= ESCORT_RADIUS_M and distance < closest_distance:
			closest = unit
			closest_distance = distance
	return closest


func _replace_sub_action(new_sub_action):
	if _sub_action != null and is_instance_valid(_sub_action):
		_sub_action.tree_exited.disconnect(_on_sub_action_finished)
		_sub_action.queue_free()
	_sub_action = new_sub_action
	_sub_action.tree_exited.connect(_on_sub_action_finished)
	add_child(_sub_action)
	_unit.action_updated.emit()


func _follow():
	_attacking = null
	_replace_sub_action(Following.new(_escorted))


func _attack(target):
	_attacking = target
	_replace_sub_action(AutoAttacking.new(target))


func _on_sub_action_finished():
	if not is_inside_tree() or not is_instance_valid(_escorted) or not _escorted.is_inside_tree():
		return
	_sub_action = null
	_follow.call_deferred()
