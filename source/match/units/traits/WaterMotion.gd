extends Node

# Added by Movement to surface units on maps with water. It reads the water under the unit
# (a grid lookup, see WaterLayout.gd) and:
# - slows land units wading through shallow water,
# - floats boats in the water, gently bobbing,
# - lowers amphibious units into the water as they drive in and lifts them out at the
#   shore, slowing them while they climb in or out, and switches them to their water
#   speed ("water_speed" in data/units) while swimming.

const LAND_UNIT_CHECK_EVERY_N_FRAMES = 4
const SINK_SPEED_M_PER_S = 0.45
const BOB_AMPLITUDE_M = 0.03
const BOB_SPEED = 1.7

var speed_multiplier = 1.0
var depth = 0  # WaterLayout.Depth under the unit

var _domain = null
var _map = null
var _geometry = null
var _geometry_base_y = 0.0
var _offset = 0.0
var _water_speed_factor = 1.0
var _bob_phase = 0.0
var _frame = 0

@onready var _unit = get_parent()


func setup(domain, a_map, movement):
	_domain = domain
	_map = a_map
	var water_speed = Constants.Match.Water.WATER_SPEEDS.get(_unit._scene_path())
	if water_speed != null and movement.speed > 0.0:  # the speed from data is set by now
		_water_speed_factor = float(water_speed) / movement.speed


func _ready():
	_geometry = _unit.find_child("Geometry", false)
	if _geometry != null:
		_geometry_base_y = _geometry.position.y
	_bob_phase = randf() * TAU
	_frame = randi() % LAND_UNIT_CHECK_EVERY_N_FRAMES


func _physics_process(delta):
	if _map == null:
		return
	if _domain == Constants.Match.Navigation.Domain.TERRAIN:
		_frame += 1
		if _frame % LAND_UNIT_CHECK_EVERY_N_FRAMES != 0:
			return
		depth = _map.water_depth_at(_unit.global_position)
		speed_multiplier = (
			Constants.Match.Water.SHALLOW_WADING_SPEED_FACTOR if depth == 1 else 1.0
		)
		return
	depth = _map.water_depth_at(_unit.global_position)
	var target = 0.0
	if depth == 2:
		target = Constants.Match.Water.FLOAT_OFFSET_DEEP
	elif depth == 1:
		target = Constants.Match.Water.FLOAT_OFFSET_SHALLOW
	_offset = move_toward(_offset, target, SINK_SPEED_M_PER_S * delta)
	if _domain == Constants.Match.Navigation.Domain.AMPHIBIOUS:
		var climbing = clamp(abs(_offset - target) / 0.12, 0.0, 1.0)
		speed_multiplier = (
			(_water_speed_factor if depth != 0 else 1.0)
			* lerp(1.0, Constants.Match.Water.SHORE_TRANSITION_SPEED_FACTOR, climbing)
		)
	if _geometry != null:
		var floating = clamp(-_offset / 0.12, 0.0, 1.0)
		var bob = (
			sin(Time.get_ticks_msec() / 1000.0 * BOB_SPEED + _bob_phase)
			* BOB_AMPLITUDE_M
			* floating
		)
		_geometry.position.y = _geometry_base_y + _offset + bob
