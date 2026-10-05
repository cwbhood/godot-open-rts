extends "res://source/match/units/actions/Action.gd"

# Orders given with Shift held: they run one after another. Each order is
# {"kind": "move" | "fight", "position": Vector3} or {"kind": "patrol", "waypoints": [...]}.
# A patrol never ends, so it is always the last thing the unit does.

const Moving = preload("res://source/match/units/actions/Moving.gd")
const AttackMoving = preload("res://source/match/units/actions/AttackMoving.gd")
const Patrolling = preload("res://source/match/units/actions/Patrolling.gd")

var _orders = []
var _current = null
var _running_order = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


func _init(orders):
	_orders = orders.duplicate()


func _ready():
	_start_next()


func _to_string():
	return "{0}({1})".format([super(), str(_current) if _current != null else ""])


func get_plan():
	var points = []
	var kinds = []
	for order in [_running_order] + _orders:
		if order == null:
			continue
		if order["kind"] == "patrol":
			var waypoints = order["waypoints"]
			if order == _running_order and is_instance_valid(_current) and _current is Patrolling:
				waypoints = _current.get_waypoints()
			for point in waypoints:
				points.append(point)
				kinds.append("patrol")
		else:
			points.append(order["position"])
			kinds.append(order["kind"])
	return {"kind": "queue", "points": points, "kinds": kinds, "loop": false}


func append(order):
	if not _orders.is_empty() and _orders.back()["kind"] == "patrol":
		if order["kind"] == "patrol":
			_orders.back()["waypoints"] += order["waypoints"]
		return  # nothing comes after a patrol
	if _current is Patrolling:
		if order["kind"] == "patrol":
			for point in order["waypoints"]:
				_current.add_waypoint(point)
				_running_order["waypoints"].append(point)
		return
	_orders.append(order)
	_unit.action_updated.emit()


func _start_next():
	if _orders.is_empty():
		queue_free()
		return
	_running_order = _orders.pop_front()
	match _running_order["kind"]:
		"move":
			_current = Moving.new(_running_order["position"])
			_current.exact = true  # queued orders carry the unit's own slot
		"fight":
			_current = AttackMoving.new(_running_order["position"])
		"patrol":
			_current = Patrolling.new(_running_order["waypoints"])
	_current.tree_exited.connect(_on_order_finished)
	add_child(_current)
	_unit.action_updated.emit()


func _on_order_finished():
	if not is_inside_tree():
		return
	_current = null
	_running_order = null
	_start_next.call_deferred()
