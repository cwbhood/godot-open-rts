extends "res://source/match/units/actions/Action.gd"

# Fight order (attack-move): the unit drives to a point, but engages enemies it sees on the
# way and resumes the drive once they are gone. It does not chase further than LEASH_M from
# where it left its route. Patrols and the AI's defensive posts are built on it.

const Moving = preload("res://source/match/units/actions/Moving.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
const AttackingWhileInRange = preload("res://source/match/units/actions/AttackingWhileInRange.gd")
const Stances = preload("res://source/match/units/actions/Stances.gd")

const REFRESH_INTERVAL = 0.3
const LEASH_M = 14.0

var _target_position = null
var _sub_action = null
var _engaged = null
var _engaged_from = null
var _timer = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


static func is_applicable(unit):
	return Moving.is_applicable(unit)


func _init(target_position):
	_target_position = target_position


func _ready():
	if _unit.attack_range != null:
		_timer = Timer.new()
		_timer.timeout.connect(_refresh)
		add_child(_timer)
		_timer.start(REFRESH_INTERVAL)
	_drive()


func _to_string():
	return "{0}({1})".format([super(), str(_sub_action) if _sub_action != null else ""])


func get_plan():
	"""where the unit is headed, for the order lines drawn under selected units"""
	return {"kind": "fight", "points": [_target_position], "loop": false}


func _refresh():
	if _engaged != null:
		if (
			not is_instance_valid(_engaged)
			or not _engaged.is_inside_tree()
			or _unit.global_position_yless.distance_to(_engaged_from) > LEASH_M
		):
			_drive()
		return
	var threat = Stances.closest_target(_unit, _unit.global_position_yless, _unit.sight_range)
	if threat != null:
		_engage(threat)


func _replace_sub_action(new_sub_action):
	if _sub_action != null and is_instance_valid(_sub_action):
		_sub_action.tree_exited.disconnect(_on_sub_action_finished)
		_sub_action.queue_free()
		remove_child(_sub_action)
	_sub_action = new_sub_action
	_sub_action.tree_exited.connect(_on_sub_action_finished)
	add_child(_sub_action)
	_unit.action_updated.emit()


func _drive():
	_engaged = null
	_replace_sub_action(Moving.new(_target_position))


func _engage(target):
	_engaged = target
	_engaged_from = _unit.global_position_yless
	_replace_sub_action(
		(
			AutoAttacking.new(target)
			if _unit.movement_speed > 0.0
			else AttackingWhileInRange.new(target)
		)
	)


func _on_sub_action_finished():
	if not is_inside_tree():
		return
	_sub_action = null
	if _engaged == null:
		queue_free()  # arrived
		return
	_drive.call_deferred()  # the enemy is gone: back on the route
