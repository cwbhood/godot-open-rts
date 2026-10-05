extends RefCounted

# The unit orders behind the command buttons, hotkeys and mouse gestures, in one place so
# the HUD, the hotkeys, the AI and the tests all issue them the same way:
# - line: units spread out evenly along a drawn line (in several rows if it is short),
# - fight (attack-move), patrol, patrol my base, guard, stop, retreat to base,
# - fire stance (fire at will / return fire / hold fire) and hold position.
# Orders given with queue = true (Shift held) are carried out after the current ones.

const Structure = preload("res://source/match/units/Structure.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const AttackMoving = preload("res://source/match/units/actions/AttackMoving.gd")
const Patrolling = preload("res://source/match/units/actions/Patrolling.gd")
const Guarding = preload("res://source/match/units/actions/Guarding.gd")
const QueuedOrders = preload("res://source/match/units/actions/QueuedOrders.gd")
const Stances = preload("res://source/match/units/actions/Stances.gd")

const MIN_SPACING_M = 2.2
const SPACING_MARGIN_M = 1.0
const BASE_RING_RADIUS_M = 13.0
const BASE_RING_POINTS = 6
const BASE_POINT_OUTSET_M = 3.5
const BASE_POINT_MERGE_M = 6.0
const MAP_MARGIN_M = 2.0


static func movable(units):
	return units.filter(
		func(unit):
			return is_instance_valid(unit) and unit.is_inside_tree() and Moving.is_applicable(unit)
	)


# --- line formation ---------------------------------------------------------------------


static func spacing_for(units):
	var spacing = MIN_SPACING_M
	for unit in units:
		if unit.radius != null:
			spacing = max(spacing, unit.radius * 2.0 + SPACING_MARGIN_M)
	return spacing


static func path_length(path):
	var length = 0.0
	for i in range(1, path.size()):
		length += path[i - 1].distance_to(path[i])
	return length


static func _point_and_tangent_at(path, distance):
	"""point at the given arc length along the path, and the path direction there"""
	var walked = 0.0
	for i in range(1, path.size()):
		var segment = path[i - 1].distance_to(path[i])
		if segment <= 0.0001:
			continue
		if walked + segment >= distance or i == path.size() - 1:
			var t = clamp((distance - walked) / segment, 0.0, 1.0)
			return [path[i - 1].lerp(path[i], t), (path[i] - path[i - 1]).normalized()]
		walked += segment
	return [path.back(), Vector3.RIGHT]


static func formation_slots(path, count, spacing, rear_point = null):
	"""count points spread evenly along the drawn path; when the path is too short for one
	row, extra rows form behind it, on the side of rear_point (where the units come from)"""
	if count <= 0 or path.is_empty():
		return []
	var length = path_length(path)
	if length < 0.5:
		return []
	var per_row = max(1, int(floor(length / spacing)) + 1)
	var rows = int(ceil(float(count) / float(per_row)))
	per_row = int(ceil(float(count) / float(rows)))  # balanced rows
	var middle = _point_and_tangent_at(path, length / 2.0)
	var back = Vector3(-middle[1].z, 0.0, middle[1].x)
	if rear_point != null and (rear_point - middle[0]).dot(back) < 0.0:
		back = -back
	var slots = []
	for row in range(rows):
		var in_row = min(per_row, count - row * per_row)
		for i in range(in_row):
			var distance = length / 2.0 if in_row == 1 else length * float(i) / float(in_row - 1)
			var at = _point_and_tangent_at(path, distance)
			var row_back = Vector3(-at[1].z, 0.0, at[1].x)
			if row_back.dot(back) < 0.0:
				row_back = -row_back
			slots.append(at[0] + row_back * spacing * row)
	return slots


static func assign_slots(units, slots, path):
	"""pairs units with slots so that they do not cross each other's way: both are ordered
	along the line's direction"""
	var direction = (path.back() - path.front()) * Vector3(1, 0, 1)
	if direction.length() < 0.01:
		direction = Vector3.RIGHT
	direction = direction.normalized()
	var sorted_units = units.duplicate()
	sorted_units.sort_custom(
		func(a, b): return a.global_position.dot(direction) < b.global_position.dot(direction)
	)
	var sorted_slots = slots.duplicate()
	sorted_slots.sort_custom(func(a, b): return a.dot(direction) < b.dot(direction))
	var pairs = []
	for i in range(min(sorted_units.size(), sorted_slots.size())):
		pairs.append([sorted_units[i], sorted_slots[i]])
	return pairs


static func line(units, path, kind = "move", queue = false):
	"""spreads the units evenly along the path; returns the [unit, point] pairs"""
	units = movable(units)
	if units.is_empty():
		return []
	var rear = Utils.Match.Unit.Movement.calculate_aabb_crowd_pivot_yless(units)
	var slots = formation_slots(path, units.size(), spacing_for(units), rear)
	if slots.is_empty():
		return point_order(units, path.front(), kind, queue)
	var pairs = assign_slots(units, slots, path)
	for pair in pairs:
		_give(pair[0], {"kind": kind, "position": pair[1]}, queue)
	return pairs


# --- point orders -----------------------------------------------------------------------


static func crowd_targets(units, point):
	var pairs = []
	for domain_units in _by_domain(units):
		pairs += Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(domain_units, point)
	return pairs


static func point_order(units, point, kind = "move", queue = false):
	"""move or fight order to a point; the units keep their shape around it"""
	var pairs = crowd_targets(movable(units), point)
	for pair in pairs:
		_give(pair[0], {"kind": kind, "position": pair[1]}, queue)
	return pairs


static func fight(units, point, queue = false):
	return point_order(units, point, "fight", queue)


static func patrol(units, waypoints, queue = false):
	"""every unit patrols the waypoints, offset like its place in the group"""
	units = movable(units)
	if units.is_empty() or waypoints.is_empty():
		return
	var per_unit = {}
	for unit in units:
		per_unit[unit] = []
	for waypoint in waypoints:
		for pair in crowd_targets(units, waypoint):
			per_unit[pair[0]].append(pair[1])
	for unit in units:
		_give(unit, {"kind": "patrol", "waypoints": per_unit[unit]}, queue)


static func patrol_base(units, player = null):
	"""a loop around the city and out past every extractor and outlying building; the
	units spread over the loop instead of following each other"""
	units = movable(units)
	if units.is_empty():
		return []
	if player == null:
		player = units[0].player
	var circuit = base_circuit(player)
	if circuit.is_empty():
		return []
	for i in range(units.size()):
		var start = int(floor(float(i) * circuit.size() / units.size()))
		units[i].action = Patrolling.new(circuit, start)
	return circuit


static func guard(units, target):
	var guards = units.filter(
		func(unit): return is_instance_valid(unit) and Guarding.is_applicable(unit, target)
	)
	for unit in guards:
		unit.action = Guarding.new(target)
	return guards


static func stop(units):
	for unit in units:
		if is_instance_valid(unit) and not unit is Structure:
			unit.action = null


static func retreat(units):
	"""back to the nearest own command center, without stopping to fight"""
	units = movable(units)
	var by_cc = {}
	for unit in units:
		var cc = nearest_command_center(unit.player, unit.global_position)
		if cc == null:
			continue
		if not cc in by_cc:
			by_cc[cc] = []
		by_cc[cc].append(unit)
	for cc in by_cc:
		var pairs = crowd_targets(by_cc[cc], cc.global_position)
		for pair in pairs:
			_give(pair[0], {"kind": "move", "position": pair[1]}, false)
	return by_cc.keys()


static func set_fire_stance(units, stance):
	for unit in units:
		if is_instance_valid(unit) and unit.attack_range != null:
			Stances.set_fire_stance(unit, stance)


static func cycle_fire_stance(units):
	"""at will -> return fire -> hold fire -> at will, starting from the first armed unit"""
	var armed = units.filter(
		func(unit): return is_instance_valid(unit) and unit.attack_range != null
	)
	if armed.is_empty():
		return null
	var stance = (Stances.fire_stance(armed[0]) + 1) % 3
	set_fire_stance(armed, stance)
	return stance


static func toggle_hold_position(units):
	var armed = units.filter(
		func(unit):
			return is_instance_valid(unit) and unit.attack_range != null and not unit is Structure
	)
	if armed.is_empty():
		return null
	var hold = not Stances.holds_position(armed[0])
	for unit in armed:
		Stances.set_hold_position(unit, hold)
	return hold


# --- helpers ----------------------------------------------------------------------------


static func _give(unit, order, queue):
	if unit is Hauler and order["kind"] != "fight":
		unit.automated = false  # manually driven haulers wait for orders
		unit.dedicated_extractor = null
		unit.road_speed_multiplier = 1.0
	var current = unit.action
	if queue and current != null and current.has_method("get_plan"):
		if current is QueuedOrders:
			current.append(order)
			return
		if current is Patrolling and order["kind"] == "patrol":
			for point in order["waypoints"]:
				current.add_waypoint(point)
			return
		var orders = []  # the current move or fight order goes first
		if current is Moving or current is AttackMoving:
			var plan = current.get_plan()
			orders.append({"kind": plan["kind"], "position": plan["points"][0]})
		orders.append(order)
		unit.action = QueuedOrders.new(orders)
		return
	match order["kind"]:
		"move":
			var moving = Moving.new(order["position"])
			moving.exact = true  # the slot in the line or group was picked for this unit
			unit.action = moving
		"fight":
			unit.action = AttackMoving.new(order["position"])
		"patrol":
			unit.action = Patrolling.new(order["waypoints"])


static func _by_domain(units):
	var groups = {}
	for unit in units:
		if not unit.movement_domain in groups:
			groups[unit.movement_domain] = []
		groups[unit.movement_domain].append(unit)
	return groups.values()


static func nearest_command_center(player, position):
	var best = null
	var best_distance = INF
	for unit in player.get_tree().get_nodes_in_group("units"):
		if unit is CommandCenter and unit.player == player and unit.is_constructed():
			var distance = unit.global_position.distance_to(position)
			if distance < best_distance:
				best = unit
				best_distance = distance
	return best


static func base_circuit(player):
	var tree = player.get_tree()
	var structures = tree.get_nodes_in_group("units").filter(
		func(unit): return unit is Structure and unit.player == player
	)
	var centers = structures.filter(func(unit): return unit is CommandCenter)
	if centers.is_empty():
		return []
	var center = Vector3.ZERO
	for cc in centers:
		center += cc.global_position_yless
	center /= centers.size()
	var points = []
	for cc in centers:
		for i in range(BASE_RING_POINTS):
			var angle = TAU * i / BASE_RING_POINTS
			points.append(
				cc.global_position_yless + Vector3(cos(angle), 0, sin(angle)) * BASE_RING_RADIUS_M
			)
	for structure in structures:
		var position = structure.global_position_yless
		if position.distance_to(center) <= BASE_RING_RADIUS_M:
			continue
		var outward = (position - center).normalized()
		var outset = (structure.radius if structure.radius != null else 1.0) + BASE_POINT_OUTSET_M
		points.append(position + outward * outset)
	points.sort_custom(
		func(a, b):
			return atan2(a.z - center.z, a.x - center.x) < atan2(b.z - center.z, b.x - center.x)
	)
	var merged = []
	for point in points:
		if merged.is_empty() or merged.back().distance_to(point) >= BASE_POINT_MERGE_M:
			merged.append(point)
	if merged.size() > 2 and merged.front().distance_to(merged.back()) < BASE_POINT_MERGE_M:
		merged.pop_back()
	return merged.map(func(point): return on_ground(tree, point))


static func on_ground(tree, point):
	"""clamped into the map and onto the terrain navmesh"""
	var match_node = tree.get_first_node_in_group("match")
	if match_node == null:
		return point
	var map = match_node.map
	if map != null:
		point.x = clamp(point.x, MAP_MARGIN_M, map.size.x - MAP_MARGIN_M)
		point.z = clamp(point.z, MAP_MARGIN_M, map.size.y - MAP_MARGIN_M)
	if match_node.navigation != null:
		var rid = match_node.navigation.get_navigation_map_rid_by_domain(
			Constants.Match.Navigation.Domain.TERRAIN
		)
		var snapped = NavigationServer3D.map_get_closest_point(rid, point)
		if snapped.distance_to(point) < 10.0:
			point = snapped * Vector3(1, 0, 1)
	return point
