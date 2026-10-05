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


static func can_reach(unit, target_position: Vector3, reach: float) -> bool:
	"""whether the unit can get within reach of target_position over its own navigation
	map: false for a land unit and a target across deep water. Always true on maps without
	water, so callers need not care whether a map has any"""
	var a_match = _match_with_water(unit.get_tree() if unit.is_inside_tree() else null)
	if a_match == null or unit.movement_domain == Constants.Match.Navigation.Domain.AIR:
		return true
	return path_reaches(
		a_match.navigation.get_navigation_map_rid_by_domain(unit.navigation_domain),
		unit.global_position,
		target_position,
		reach
	)


static func land_reaches(scene_tree, from: Vector3, to: Vector3, reach: float) -> bool:
	"""can_reach for land units that do not exist yet (builders sent to a deposit)"""
	var a_match = _match_with_water(scene_tree)
	if a_match == null:
		return true
	return path_reaches(
		a_match.navigation.get_navigation_map_rid_by_domain(
			Constants.Match.Navigation.Domain.TERRAIN
		),
		from,
		to,
		reach
	)


static func path_reaches(map_rid, from: Vector3, to: Vector3, reach: float) -> bool:
	"""whether a path on the navigation map from 'from' ends within reach of 'to'"""
	var path = NavigationServer3D.map_get_path(map_rid, from, to, true)
	if path.is_empty():
		return false
	var end = path[path.size() - 1]
	return Vector2(end.x, end.z).distance_to(Vector2(to.x, to.z)) <= reach


static func _match_with_water(scene_tree):
	var a_match = scene_tree.get_first_node_in_group("match") if scene_tree != null else null
	if a_match == null or not a_match.map.has_method("has_water") or not a_match.map.has_water():
		return null
	return a_match
