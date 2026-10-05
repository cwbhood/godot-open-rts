extends RefCounted

# Per-unit stances set by the player (or the helper):
# - fire stance: fire at will (default), return fire (shoot back only at whoever hit this
#   unit lately) or hold fire (never shoot on its own; the old "hold_fire" meta),
# - hold position: an idle unit shoots what is in weapon range but never chases.
# Explicit orders (attack this unit) always win over a stance.

enum Fire { AT_WILL, RETURN, HOLD }

const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")

const RETURN_FIRE_MEMORY_S = 8.0  # an attacker is remembered this long for return fire


static func fire_stance(unit):
	if unit.get_meta("hold_fire", false):
		return Fire.HOLD
	return unit.get_meta("fire_stance", Fire.AT_WILL)


static func set_fire_stance(unit, stance):
	unit.set_meta("fire_stance", stance)
	unit.set_meta("hold_fire", stance == Fire.HOLD)
	unit.action_updated.emit()


static func holds_position(unit):
	return unit.get_meta("hold_position", false)


static func set_hold_position(unit, value):
	unit.set_meta("hold_position", value)
	unit.action_updated.emit()


static func recently_hit_by(unit, other):
	"""Unit.take_damage remembers the last unit that hit it"""
	if not unit.has_meta("last_hit_by") or unit.get_meta("last_hit_by") != other:
		return false
	return Time.get_ticks_msec() - unit.get_meta("last_hit_at_ms", 0) <= RETURN_FIRE_MEMORY_S * 1000


static func may_engage_on_sight(unit, other):
	"""whether the unit opens fire on its own at other (no distance check)"""
	if other.player == unit.player:
		return false
	if not Diplomacy.engages_on_sight(unit.player, other.player):
		return false
	if not other.movement_domain in unit.attack_domains:
		return false
	if other.has_method("is_protected_from") and other.is_protected_from(unit.player):
		return false
	match fire_stance(unit):
		Fire.HOLD:
			return false
		Fire.RETURN:
			return recently_hit_by(unit, other)
	return true


static func closest_target(unit, center, radius):
	"""closest unit within radius of center the unit would open fire on, or null"""
	if unit.attack_range == null or fire_stance(unit) == Fire.HOLD:
		return null
	var closest = null
	var closest_distance = INF
	for other in unit.get_tree().get_nodes_in_group("units"):
		var distance = center.distance_to(other.global_position_yless)
		if distance > radius or distance >= closest_distance:
			continue
		if may_engage_on_sight(unit, other):
			closest = other
			closest_distance = distance
	return closest
