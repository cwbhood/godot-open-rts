# Where structures may stand on maps with water (see source/match/maps/WaterLayout.gd):
# never in water, shallow fords included, and structures with "placement": "shore" in
# data/units (the shipyard) only on land with deep water close to their edge.

enum { OK, IN_WATER, NEEDS_SHORE }


static func structure_problem(a_map, scene_path, position: Vector3, radius: float) -> int:
	var shore = Constants.Match.Water.PLACEMENT.get(scene_path) == "shore"
	if a_map == null or not a_map.has_method("has_water") or not a_map.has_water():
		return NEEDS_SHORE if shore else OK
	var water = a_map.water
	var pos = Vector2(position.x, position.z)
	if water.is_wet_near(pos, radius * 0.8):
		return IN_WATER
	if shore and not water.has_deep_water_near(pos, radius + Constants.Match.Water.SHORE_REACH_M):
		return NEEDS_SHORE
	return OK


static func find_shore_spot(a_map, near: Vector3, radius: float, max_distance: float):
	"""closest land spot to 'near' fit for a shore structure, or null; for AI and tests"""
	if a_map == null or not a_map.has_method("has_water") or not a_map.has_water():
		return null
	var water = a_map.water
	var step = 1.0
	var distance = 0.0
	while distance <= max_distance:
		var count = max(1, int(TAU * distance / step))
		for i in range(count):
			var pos = Vector2(near.x, near.z) + Vector2.from_angle(TAU * i / count) * distance
			if (
				not water.is_wet_near(pos, radius * 0.8)
				and water.has_deep_water_near(pos, radius + Constants.Match.Water.SHORE_REACH_M)
			):
				return Vector3(pos.x, 0.0, pos.y)
		distance += step
	return null
