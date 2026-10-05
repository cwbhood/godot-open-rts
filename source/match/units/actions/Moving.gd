extends "res://source/match/units/actions/Action.gd"

# the spot was picked for this unit already (a line or a group order): go exactly there
var exact = false
var _target_position = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _movement_trait = _unit.find_child("Movement")


static func is_applicable(unit):
	return unit.find_child("Movement") != null


func _init(target_position):
	_target_position = target_position


func _ready():
	_movement_trait.move(_pick_destination())
	_movement_trait.movement_finished.connect(_on_movement_finished)


func get_plan():
	"""where the unit is headed, for the order lines drawn under selected units"""
	return {"kind": "move", "points": [_target_position], "loop": false}


func _exit_tree():
	if is_inside_tree():
		_movement_trait.stop()


func _pick_destination():
	"""a free spot near the ordered point, so that units sent to one place spread out"""
	if not exact and _movement_trait.has_method("free_spot_near"):
		return _movement_trait.free_spot_near(_target_position)
	return _target_position


func _on_movement_finished():
	queue_free()
