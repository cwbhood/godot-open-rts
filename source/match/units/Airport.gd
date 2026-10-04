extends "res://source/match/units/Structure.gd"

# Fixed-wing aircraft (see FixedWingFlight) land here to refuel. Every aircraft gets a
# parking spot of its own: first along the runway, then in rings around the airfield.

const RUNWAY_SPOTS = [Vector3(-1.3, 0, 0), Vector3(0, 0, 0), Vector3(1.3, 0, 0)]
const RING_SPOTS = 8
const RING_DISTANCE_M = 2.8

var _spots = {}  # aircraft -> spot index


static func closest_to(player, position):
	"""closest constructed airport of 'player', null if it has none"""
	var closest = null
	for airport in player.get_tree().get_nodes_in_group("airports"):
		if airport.player != player or not airport.is_constructed():
			continue
		if (
			closest == null
			or (
				airport.global_position.distance_to(position)
				< closest.global_position.distance_to(position)
			)
		):
			closest = airport
	return closest


func _ready():
	add_to_group("airports")
	await super()


func reserve_spot(aircraft):
	"""global position of the parking spot of 'aircraft' (taken until released)"""
	if not aircraft in _spots:
		var taken = _spots.values()
		var index = 0
		while index in taken:
			index += 1
		_spots[aircraft] = index
	return _spot_position(_spots[aircraft])


func release_spot(aircraft):
	_spots.erase(aircraft)


func _spot_position(index):
	var local = Vector3.ZERO
	if index < RUNWAY_SPOTS.size():
		local = RUNWAY_SPOTS[index]
	else:
		var ring_index = index - RUNWAY_SPOTS.size()
		var ring = int(ring_index / float(RING_SPOTS))
		var angle = TAU * float(ring_index % RING_SPOTS) / RING_SPOTS + ring * 0.4
		local = Vector3(cos(angle), 0, sin(angle)) * RING_DISTANCE_M * (1.0 + ring * 0.5)
	return global_transform * local
