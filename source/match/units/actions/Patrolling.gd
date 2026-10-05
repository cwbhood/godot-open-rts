extends "res://source/match/units/actions/Action.gd"

# Patrol: the unit loops through its waypoints for good, fighting what it meets on the way
# (each leg is a fight order) and carrying on afterwards. A patrol given with one point goes
# back and forth between where the unit stood and that point. Shift-clicking more patrol
# points adds them to the loop.
#
# A base patrol (UnitCommands.patrol_base) follows its owner's base instead of fixed points:
# when a building goes up or is lost, the loop is redrawn at the end of the current leg, so
# new outposts and extractors join the round.

const AttackMoving = preload("res://source/match/units/actions/AttackMoving.gd")
const Structure = preload("res://source/match/units/Structure.gd")

var _waypoints = []
var _index = 0
var _leg = null
var _base_player = null  # set for a base patrol: the player whose base the loop follows
var _base_changed = false

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


static func is_applicable(unit):
	return AttackMoving.is_applicable(unit)


func _init(waypoints, start_index = 0, base_player = null):
	_waypoints = waypoints.duplicate()
	_index = start_index % max(1, _waypoints.size())
	_base_player = base_player


func _ready():
	if _base_player != null:
		MatchSignals.unit_spawned.connect(_on_base_unit_changed)
		MatchSignals.unit_construction_finished.connect(_on_base_unit_changed)
		MatchSignals.unit_died.connect(_on_base_unit_changed)
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


func is_base_patrol():
	return _base_player != null


func add_waypoint(position):
	_waypoints.append(position)
	_base_player = null  # a hand-made loop from now on


func refresh_base_circuit():
	"""redraws a base patrol's loop around the base as it stands now and carries on from
	the point of the new loop closest to the one just reached; false when nothing changed"""
	_base_changed = false
	if _base_player == null or not is_instance_valid(_base_player):
		return false
	var circuit = load("res://source/match/players/human/UnitCommands.gd").base_circuit(
		_base_player
	)
	if circuit.is_empty() or circuit == _waypoints:
		return false
	var reached = _waypoints[_index] if _index < _waypoints.size() else _unit.global_position
	var closest = 0
	for i in range(circuit.size()):
		if circuit[i].distance_to(reached) < circuit[closest].distance_to(reached):
			closest = i
	_waypoints = circuit
	_index = closest
	return true


func _on_base_unit_changed(unit):
	if is_instance_valid(unit) and unit is Structure and unit.player == _base_player:
		_base_changed = true


func _next_leg():
	_leg = AttackMoving.new(_waypoints[_index])
	_leg.tree_exited.connect(_on_leg_finished)
	add_child(_leg)
	_unit.action_updated.emit()


func _on_leg_finished():
	if not is_inside_tree():
		return
	_leg = null
	if _base_changed:
		refresh_base_circuit()
	_index = (_index + 1) % _waypoints.size()
	_next_leg.call_deferred()
