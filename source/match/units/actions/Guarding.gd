extends "res://source/match/units/actions/Escorting.gd"

# Guard order: like a convoy escort, but for any own unit or building. The guard stays
# with it and fights enemies that come near it, within its fire stance (a unit on hold
# fire only follows).

const Stances = preload("res://source/match/units/actions/Stances.gd")

const GUARD_RADIUS_M = 9.0
const GUARD_MAX_CHASE_M = 14.0


static func is_applicable(source_unit, target_unit):
	return (
		source_unit.movement_speed > 0.0
		and "player" in target_unit
		and target_unit.player == source_unit.player
		and target_unit != source_unit
	)


func _init(guarded_unit):
	super(guarded_unit)
	escort_radius_m = GUARD_RADIUS_M
	max_chase_m = GUARD_MAX_CHASE_M


func get_plan():
	if not is_instance_valid(_escorted):
		return {}
	return {"kind": "guard", "points": [_escorted.global_position], "loop": false}


func _may_engage(unit_to_attack):
	return (
		_unit.attack_range != null
		and Stances.fire_stance(_unit) != Stances.Fire.HOLD
		and (
			Stances.fire_stance(_unit) != Stances.Fire.RETURN
			or Stances.recently_hit_by(_unit, unit_to_attack)
			or Stances.recently_hit_by(_escorted, unit_to_attack)
		)
	)
