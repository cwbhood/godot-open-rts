extends Node

# Gameplay side of the weather. The world/visuals code drives these values (a sandstorm
# sweeping over the map, low clouds) and the game systems read them:
# - speed multiplier: Movement trait (all moving units, haulers included),
# - vision multiplier: Unit.sight_range (fog of war, auto-targeting, unit visibility).
# Zones are dictionaries: {"center": Vector3, "radius": float, "speed": float,
# "vision": float, "air_vision": float}; missing keys mean 1.0. Global multipliers apply
# everywhere on top of zones.

@export var speed_multiplier = 1.0
@export var vision_multiplier = 1.0
@export var air_vision_multiplier = 1.0  # vision of aircraft, e.g. reduced by low clouds

var zones = []


func get_speed_multiplier(position, _domain = null):
	return speed_multiplier * _zone_value(position, "speed")


func get_vision_multiplier(position, observer_domain = null):
	var multiplier = vision_multiplier * _zone_value(position, "vision")
	if observer_domain == Constants.Match.Navigation.Domain.AIR:
		multiplier *= air_vision_multiplier * _zone_value(position, "air_vision")
	return multiplier


func _zone_value(position, key):
	var value = 1.0
	for zone in zones:
		if (
			(zone["center"] * Vector3(1, 0, 1)).distance_to(position * Vector3(1, 0, 1))
			<= zone["radius"]
		):
			value *= zone.get(key, 1.0)
	return value
