extends Node

# Gameplay side of the weather. The world/visuals code drives these values (a sandstorm
# sweeping over the map, low clouds) and the game systems read them:
# - speed multiplier: Movement trait (all moving units, haulers included),
# - vision multiplier: Unit.sight_range (fog of war, auto-targeting, unit visibility).
# Zones are dictionaries: {"center": Vector3, "radius": float, "speed": float,
# "vision": float, "air_vision": float}; missing keys mean 1.0. Global multipliers apply
# everywhere on top of zones.
#
# Lookups are hot: unit visibility reads every unit's sight range for every pair of units on
# every physics tick. So zones are indexed per key on a coarse grid when they are assigned, and
# a lookup only checks the zones of its own cell that carry the key it asks for.

const INDEX_CELL_SIZE = 12.0

@export var speed_multiplier = 1.0
@export var vision_multiplier = 1.0
@export var air_vision_multiplier = 1.0  # vision of aircraft, e.g. reduced by low clouds

var zones = []:
	set = _set_zones

var _index = {}  # key -> {Vector2i cell: [zone, ...]}


func get_speed_multiplier(position, _domain = null):
	return speed_multiplier * _zone_value(position, "speed")


func get_vision_multiplier(position, observer_domain = null):
	var multiplier = vision_multiplier * _zone_value(position, "vision")
	if observer_domain == Constants.Match.Navigation.Domain.AIR:
		multiplier *= air_vision_multiplier * _zone_value(position, "air_vision")
	return multiplier


func _set_zones(value):
	zones = value
	_index = {}
	for zone in zones:
		var center = zone["center"]
		var radius = zone["radius"]
		var low = _cell_of(center.x - radius, center.z - radius)
		var high = _cell_of(center.x + radius, center.z + radius)
		for key in zone:
			if key == "center" or key == "radius":
				continue
			var cells = _index.get_or_add(key, {})
			for x in range(low.x, high.x + 1):
				for z in range(low.y, high.y + 1):
					cells.get_or_add(Vector2i(x, z), []).append(zone)


func _zone_value(position, key):
	var cells = _index.get(key)
	if cells == null:
		return 1.0
	var candidates = cells.get(_cell_of(position.x, position.z))
	if candidates == null:
		return 1.0
	var value = 1.0
	var flat_position = Vector2(position.x, position.z)
	for zone in candidates:
		var center = zone["center"]
		if Vector2(center.x, center.z).distance_to(flat_position) <= zone["radius"]:
			value *= zone[key]
	return value


func _cell_of(x, z):
	return Vector2i(floori(x / INDEX_CELL_SIZE), floori(z / INDEX_CELL_SIZE))
