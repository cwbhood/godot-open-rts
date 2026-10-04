extends "res://source/match/units/actions/Action.gd"

# A delivery truck with no job right now: it drives to a waiting spot (next to the
# extractor that will have goods next, or the depot) and waits there. Logistics replaces
# this action with a real job as soon as there is one, so the truck counts as idle.

const Moving = preload("res://source/match/units/actions/Moving.gd")

var description = "STANDBY"
var target = null  # the extractor, storage or depot the truck waits next to

var _spot = null
var _sub_action = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")


func _init(a_target, spot, a_description = "STANDBY"):
	target = a_target
	_spot = spot
	description = a_description


func _ready():
	if _unit.global_position_yless.distance_to(_spot * Vector3(1, 0, 1)) > 1.0:
		_sub_action = Moving.new(_spot)
		add_child(_sub_action)
	_unit.action_updated.emit()


func _to_string():
	return "{0}({1})".format([super(), description])


func is_waiting_at(a_target):
	return target == a_target
