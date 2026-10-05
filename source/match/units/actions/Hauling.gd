extends "res://source/match/units/actions/Action.gd"

# Runs a hauler through a list of stops. Each stop is [target_unit, on_arrival] where
# on_arrival is a Callable returning false to stop the trip early. If the trip ends
# before all stops are visited (a target is destroyed, the player gives another order),
# on_abort gets called so that reservations can be released.

const MovingToUnit = preload("res://source/match/units/actions/MovingToUnit.gd")

const MAX_MOVE_ATTEMPTS = 3

var description = ""

var _stops = []
var _on_abort = null
var _finished = false
var _sub_action = null
var _move_attempts = 0

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


func _init(stops, on_abort = null, a_description = ""):
	_stops = stops
	_on_abort = on_abort
	description = a_description


func _ready():
	_go_to_next_stop()


func _exit_tree():
	if not _finished and _on_abort != null:
		_finished = true
		_on_abort.call()


func _to_string():
	return "{0}({1})".format([super(), description])


func get_stop_targets():
	"""the units still to visit, in order (the building card shows where trucks go)"""
	var targets = []
	for stop in _stops:
		targets.append(stop[0])
	return targets


func get_next_stop_target():
	return _stops.front()[0] if not _stops.is_empty() else null


func _go_to_next_stop():
	if _stops.is_empty():
		_finished = true
		queue_free()
		return
	var target = _stops.front()[0]
	if not is_instance_valid(target) or not target.is_inside_tree():
		queue_free()
		return
	if Utils.Match.Unit.Movement.units_adhere(_unit, target):
		_arrive()
		return
	_move_attempts += 1
	if _move_attempts > MAX_MOVE_ATTEMPTS:
		queue_free()
		return
	_sub_action = MovingToUnit.new(target)
	_sub_action.tree_exited.connect(_on_sub_action_finished, CONNECT_DEFERRED)
	add_child(_sub_action)
	_unit.action_updated.emit()


func _arrive():
	_move_attempts = 0
	var stop = _stops.pop_front()
	if stop[1].call() == false:
		queue_free()
		return
	_go_to_next_stop()


func _on_sub_action_finished():
	if not is_inside_tree():
		return
	_sub_action = null
	_go_to_next_stop()
