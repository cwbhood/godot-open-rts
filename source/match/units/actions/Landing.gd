extends "res://source/match/units/actions/Action.gd"

# Flies a fixed-wing aircraft to its spot at an airport, lands and refuels it. The action
# ends once the tank is full; the aircraft then stays parked until it gets a new order.

const ARRIVAL_DISTANCE_M = 0.3

var airport = null
var _spot = null
var _flight = null

@onready var _unit = Utils.NodeEx.find_parent_with_group(self, "units")
@onready var _movement_trait = _unit.find_child("Movement")


static func is_applicable(unit, target_unit):
	return (
		unit.get_node_or_null("FixedWingFlight") != null
		and target_unit.is_in_group("airports")
		and target_unit.player == unit.player
		and target_unit.is_constructed()
	)


func _init(an_airport):
	airport = an_airport


func _ready():
	_flight = _unit.get_node_or_null("FixedWingFlight")
	if _flight.landed and _flight.airport != airport:
		_flight.take_off()  # sent over to another airfield
	_spot = airport.reserve_spot(_unit)
	_flight.airport = airport
	if _flight.landed:
		return
	_movement_trait.movement_finished.connect(_on_movement_finished)
	_movement_trait.move(_spot)


func _process(_delta):
	if not is_instance_valid(airport) or not airport.is_inside_tree():
		queue_free()
		return
	if _flight.landed:
		if _flight.is_full():
			queue_free()
	elif (
		(_unit.global_position * Vector3(1, 0, 1)).distance_to(_spot * Vector3(1, 0, 1))
		< (ARRIVAL_DISTANCE_M)
	):
		_on_movement_finished()


func _exit_tree():
	if not _flight.landed:
		_movement_trait.stop()
		if is_instance_valid(airport):
			airport.release_spot(_unit)


func _on_movement_finished():
	if not _flight.landed:
		_movement_trait.stop()
		_flight.land()
