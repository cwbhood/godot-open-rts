enum { VALID, COLLIDES_WITH_AGENT, NOT_NAVIGABLE }

const FALLBACK_SEARCH_M = 256.0


static func find_valid_position_radially(
	starting_position: Vector3, radius: float, navigation_map_rid: RID, scene_tree
):
	return find_valid_position_radially_yet_skip_starting_radius(
		starting_position, 0.0, radius, 0.0, Vector3(0, 0, 1), true, navigation_map_rid, scene_tree
	)


static func find_valid_position_radially_yet_skip_starting_radius(
	starting_position: Vector3,
	starting_radius: float,
	radius: float,
	spacing: float,
	starting_direction: Vector3,
	shuffle: bool,
	navigation_map_rid: RID,
	scene_tree
):
	var starting_position_yless = starting_position * Vector3(1, 0, 1)
	var units = (
		scene_tree.get_nodes_in_group("units")
		+ scene_tree.get_nodes_in_group("resource_units")
		+ scene_tree.get_nodes_in_group("city_buildings")
	)
	var starting_distance = (
		0 if is_zero_approx(starting_radius) else starting_radius + radius + spacing
	)
	var starting_offset = 1 if is_zero_approx(starting_radius) else 0
	var land_water = _water_to_avoid(navigation_map_rid, scene_tree)
	if (
		is_zero_approx(starting_radius)
		and not _is_wet(land_water, starting_position_yless, radius)
		and _is_agent_placement_position_valid(
			starting_position_yless, radius, units, navigation_map_rid
		)
	):
		return starting_position_yless
	# rings grow until they lie wholly outside the navigation mesh; past that nothing can be
	# valid, and searching on (rings get longer each time) would hang the game. A crowded
	# small map runs out of space for a big structure mid-match, so this is a real outcome.
	var bounds = _navigation_bounds(navigation_map_rid).grow(radius)
	var max_distance = _farthest_corner_distance(starting_position_yless, bounds)
	for ring_number in range(starting_offset, 999999):
		var ring_distance_from_starting_position: float = (
			starting_distance + radius * 0.5 * ring_number
		)
		if ring_distance_from_starting_position > max_distance:
			break
		var rotation_angle_rad = asin((radius + spacing) / ring_distance_from_starting_position)
		var radial_positions = []
		var next_rotation_angle_rad = 0.0
		while next_rotation_angle_rad <= PI * 2.0 - rotation_angle_rad:
			radial_positions.append(
				(
					starting_position_yless
					+ (
						starting_direction.normalized().rotated(Vector3.UP, next_rotation_angle_rad)
						* ring_distance_from_starting_position
					)
				)
			)
			next_rotation_angle_rad += rotation_angle_rad
		if shuffle:
			radial_positions.shuffle()
		for radial_position in radial_positions:
			if not _flat_has_point(bounds, radial_position):
				continue  # off the map: cheap to rule out before checking every unit
			if _is_wet(land_water, radial_position, radius):
				continue  # fords are walkable, but nothing is built or parked in them
			if _is_agent_placement_position_valid(
				radial_position, radius, units, navigation_map_rid
			):
				return radial_position
	return Vector3.INF  # no room anywhere; callers must handle it


static func _water_to_avoid(navigation_map_rid, scene_tree):
	"""the map's WaterLayout when placing on the land map of a map with water, else null"""
	var a_match = scene_tree.get_first_node_in_group("match") if scene_tree != null else null
	if a_match == null or a_match.navigation == null or a_match.map == null:
		return null
	if not a_match.map.has_method("has_water") or not a_match.map.has_water():
		return null
	if a_match.navigation.terrain.navigation_map_rid != navigation_map_rid:
		return null
	return a_match.map.water


static func _is_wet(water, position, radius):
	return water != null and water.is_wet_near(Vector2(position.x, position.z), radius * 0.8)


static func _navigation_bounds(navigation_map_rid):
	var bounds = null
	for region in NavigationServer3D.map_get_regions(navigation_map_rid):
		var region_bounds = NavigationServer3D.region_get_bounds(region)
		bounds = region_bounds if bounds == null else bounds.merge(region_bounds)
	if bounds == null:  # nothing baked yet: allow a generous search, but a bounded one
		bounds = AABB(
			Vector3(-FALLBACK_SEARCH_M, -1.0, -FALLBACK_SEARCH_M),
			Vector3.ONE * FALLBACK_SEARCH_M * 2.0
		)
	return bounds


static func _farthest_corner_distance(position, bounds):
	var farthest = 0.0
	for x in [bounds.position.x, bounds.end.x]:
		for z in [bounds.position.z, bounds.end.z]:
			farthest = max(farthest, Vector2(x, z).distance_to(Vector2(position.x, position.z)))
	return farthest


static func _flat_has_point(bounds, position):
	return (
		position.x >= bounds.position.x
		and position.x <= bounds.end.x
		and position.z >= bounds.position.z
		and position.z <= bounds.end.z
	)


static func validate_agent_placement_position(position, radius, existing_units, navigation_map_rid):
	for existing_unit in existing_units:
		if (
			(existing_unit.global_position * Vector3(1, 0, 1)).distance_to(
				position * Vector3(1, 0, 1)
			)
			<= existing_unit.radius + radius
		):
			return COLLIDES_WITH_AGENT
	# the navmesh is eroded by the max agent radius around every obstacle (deposits,
	# structures), so a footprint's rim may lie in that margin: test the core of it only.
	# Without this nothing fits next to a deposit once the first rebake carved it out.
	var core_radius = max(radius - Constants.Match.Terrain.Navmesh.MAX_AGENT_RADIUS, 0.2)
	var points_expected_to_be_navigable = []
	for x in [-1, 0, 1]:
		for z in [-1, 0, 1]:
			points_expected_to_be_navigable.append(
				position + Vector3(x, 0, z).normalized() * core_radius
			)
	for point_expected_to_be_navigable in points_expected_to_be_navigable:
		if not (point_expected_to_be_navigable * Vector3(1, 0, 1)).is_equal_approx(
			(
				NavigationServer3D.map_get_closest_point(
					navigation_map_rid, point_expected_to_be_navigable
				)
				* Vector3(1, 0, 1)
			)
		):
			return NOT_NAVIGABLE
	return VALID


static func _is_agent_placement_position_valid(
	position, radius, existing_units, navigation_map_rid
):
	return (
		validate_agent_placement_position(position, radius, existing_units, navigation_map_rid)
		== VALID
	)
