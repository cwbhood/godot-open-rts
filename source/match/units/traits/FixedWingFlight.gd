extends Node

# Fixed-wing aircraft (drones, planes) cannot hover forever: they burn airtime whenever
# they are in the air, loiter where they were sent, and head back to the closest airport
# of their player when the tank runs low. Without an airport they crash once the tank is
# empty. Landed aircraft refuel and stay parked until they get a new order. Helicopters
# do not get this trait. Added by Unit.gd to units with "flight_endurance_s" in data/units.

const Landing = preload("res://source/match/units/actions/Landing.gd")

const LOITER_TURN_DEG_PER_S = 40.0

var endurance_s = 60.0
var fuel_s = 60.0
var landed = false
var airport = null  # where it is parked or heading to

var _geometry_tween = null
var _warning_label = Label3D.new()

@onready var _unit = get_parent()


func _ready():
	fuel_s = endurance_s
	_unit.action_changed.connect(_on_action_changed)
	_warning_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_warning_label.no_depth_test = true
	_warning_label.font_size = 40
	_warning_label.outline_size = 10
	_warning_label.modulate = Color(1.0, 0.75, 0.2)
	_warning_label.position = Vector3(0, 1.0, 0)
	_warning_label.hide()
	_unit.add_child.call_deferred(_warning_label)


func is_full():
	return fuel_s >= endurance_s - 0.01


func get_fuel_ratio():
	return clamp(fuel_s / endurance_s, 0.0, 1.0) if endurance_s > 0.0 else 1.0


func land():
	if landed:
		return
	landed = true
	_unit.find_child("Movement").avoidance_enabled = false  # parked, not in anyone's way
	_animate_geometry_drop(_landed_drop())


func take_off():
	if not landed:
		return
	landed = false
	_unit.find_child("Movement").avoidance_enabled = true
	if is_instance_valid(airport):
		airport.release_spot(_unit)
	airport = null
	_animate_geometry_drop(0.0)


func _physics_process(delta):
	if not _unit.is_inside_tree():
		return
	if landed:
		if not is_instance_valid(airport) or not airport.is_inside_tree():
			take_off()  # the airport was destroyed under it
		else:
			fuel_s = min(
				endurance_s, fuel_s + endurance_s / Constants.Match.Air.REFUEL_TIME_S * delta
			)
		_update_warning(null)
		return
	fuel_s -= delta
	if fuel_s <= 0.0:
		_crash()
		return
	var home = _closest_airport()
	if not _unit.action is Landing and home != null and fuel_s < _time_to_reach(home):
		_unit.action = Landing.new(home)
	if _unit.action == null:
		_unit.rotate_y(deg_to_rad(LOITER_TURN_DEG_PER_S) * delta)  # circling where it was sent
	_update_warning(home)


func _closest_airport():
	var closest = null
	for an_airport in get_tree().get_nodes_in_group("airports"):
		if an_airport.player != _unit.player or not an_airport.is_constructed():
			continue
		if (
			closest == null
			or (
				an_airport.global_position.distance_to(_unit.global_position)
				< closest.global_position.distance_to(_unit.global_position)
			)
		):
			closest = an_airport
	return closest


func _time_to_reach(an_airport):
	var speed = max(0.1, _unit.movement_speed)
	return (
		(
			(an_airport.global_position * Vector3(1, 0, 1)).distance_to(
				_unit.global_position * Vector3(1, 0, 1)
			)
			/ speed
		)
		+ Constants.Match.Air.RETURN_RESERVE_S
	)


func _update_warning(home):
	var low = not landed and get_fuel_ratio() < Constants.Match.Air.LOW_FUEL_WARNING_RATIO
	_warning_label.visible = low and _unit.is_in_group("controlled_units")
	if _warning_label.visible:
		_warning_label.text = tr("AIRCRAFT_LOW_FUEL" if home != null else "AIRCRAFT_NO_AIRPORT")


func _crash():
	MatchSignals.aircraft_crashed.emit(_unit)
	_unit.hp = 0


func _landed_drop():
	"""how far the model has to sink to sit on the ground"""
	return max(0.0, _unit.global_position.y - 0.08)


func _animate_geometry_drop(drop):
	var geometry = _unit.find_child("Geometry")
	if geometry == null:
		return
	if _geometry_tween != null:
		_geometry_tween.kill()
	_geometry_tween = create_tween()
	_geometry_tween.tween_property(
		geometry, "position:y", -drop, Constants.Match.Air.LANDING_DURATION_S
	)


func _on_action_changed(new_action):
	if landed and new_action != null and not new_action is Landing:
		take_off()
