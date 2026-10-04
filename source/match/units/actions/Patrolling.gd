extends "res://source/match/units/actions/Action.gd"

# Patrol: the unit loops through its waypoints for good, fighting what it meets on the way
# (each leg is a fight order) and carrying on afterwards. A patrol given with one point goes
# back and forth between where the unit stood and that point. Shift-clicking more patrol
# points adds them to the loop.

const AttackMoving = preload("res://source/match/units/actions/AttackMoving.gd")

var _waypoints = []
var _index = 0
var _leg = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


static func is_applicable(unit):
	return AttackMoving.is_applicable(unit)


func _init(waypoints, start_index = 0):
	_waypoints = waypoints.duplicate()
	_index = start_index % max(1, _waypoints.size())


func _ready():
	if _waypoints.size() == 1:
		_waypoints.push_front(_unit.global_position)
		_index = 1
	_next_leg()


func _to_string():
	return "{0}({1})".format([super(), str(_leg) if _leg != null else ""])


func get_plan():
	var points = []
	for offset in range(_waypoints.size()):
		points.append(_waypoints[(_index + offset) % _waypoints.size()])
	return {"kind": "patrol", "points": points, "loop": true}


func get_waypoints():
	return _waypoints.duplicate()


func add_waypoint(position):
	_waypoints.append(position)


func _next_leg():
	_leg = AttackMoving.new(_waypoints[_index])
	_leg.tree_exited.connect(_on_leg_finished)
	add_child(_leg)
	_unit.action_updated.emit()


func _on_leg_finished():
	if not is_inside_tree():
		return
	_leg = null
	_index = (_index + 1) % _waypoints.size()
	_next_leg.call_deferred()
