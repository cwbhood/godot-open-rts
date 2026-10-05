extends "res://source/match/units/actions/Moving.gd"

const RETRY_WHEN_SURROUNDED_S = 1.0

var _target_unit = null
var _waiting = false


func _init(target_unit):
	_target_unit = target_unit


func _process(_delta):
	if Utils.Match.Unit.Movement.units_adhere(_unit, _target_unit):
		queue_free()


func _ready():
	_target_unit.tree_exited.connect(queue_free)
	_target_position = (
		_target_unit.global_position_yless
		+ (
			(_unit.global_position_yless - _target_unit.global_position_yless).normalized()
			* _target_unit.radius
		)
	)
	super()


func _pick_destination():
	"""a free side of the target, so that units delivering to one building don't queue up
	behind each other at the same spot; when every side is taken, a spot nearby to wait at"""
	if not _movement_trait.has_method("approach_spot_for"):
		return _target_position
	var spot = _movement_trait.approach_spot_for(_target_unit)
	_waiting = spot == null and _movement_trait.get("_crowd") == true
	if _waiting:
		return _movement_trait.free_spot_near(_target_position)
	return spot if spot != null else _target_position


func _on_movement_finished():
	if Utils.Match.Unit.Movement.units_adhere(_unit, _target_unit):
		queue_free()
		return
	if _waiting:
		# every side was taken: wait a moment next to the target, then look again
		if not is_inside_tree():
			return  # the order was replaced on this frame
		await get_tree().create_timer(RETRY_WHEN_SURROUNDED_S).timeout
		if not is_inside_tree() or not is_instance_valid(_target_unit):
			return
		_movement_trait.move(_pick_destination())
		return
	# arrived at the picked spot but a little short of touching the target (units stop
	# within their target_desired_distance of a spot): head for the target itself, which
	# takes the unit to the closest walkable point next to it, as before
	_target_position = _target_unit.global_position
	_movement_trait.move(_target_position)
