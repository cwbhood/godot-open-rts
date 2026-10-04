extends Node

# Where the AI keeps the troops it is not attacking with. Without this they stood wherever
# the factory dropped them, in one clump in the middle of the base. Now:
# - most of them hold a front line between the city and the faction it expects trouble
#   from, spread across the approach, out to the map edge when the edge is near, so the
#   line and the boundary close the way to the city,
# - with six or more at home, a quarter of them patrol the loop around the city and its
#   extractors (UnitCommands.base_circuit), fighting raiders on the way.
# Battlegroups and raids still take units from here; when an attack ends, the survivors
# come back to the line.

const UnitCommands = preload("res://source/match/players/human/UnitCommands.gd")
const AttackMoving = preload("res://source/match/units/actions/AttackMoving.gd")
const Patrolling = preload("res://source/match/units/actions/Patrolling.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")

const REFRESH_INTERVAL_S = 3.0
const FRONT_GAP_M = 9.0  # the line stands this far outside the outermost base building
const FRONT_MIN_M = 14.0
const FRONT_MAX_SHARE = 0.45  # never further than this share of the way to the enemy
const BASE_RADIUS_CAP_M = 30.0
const MIN_SPACING_M = 4.0
const MAX_SPACING_M = 7.0
const LINE_CAPACITY = 10  # more units form a second line behind the first
const ROW_GAP_M = 5.0
const MAP_MARGIN_M = 3.0
const AT_POST_M = 3.5
const PATROL_FROM = 6  # units at home before some of them patrol
const PATROL_SHARE = 4  # one in this many patrols

var front_posts = []  # for tests and screenshots: the posts of the last refresh
var front_direction = Vector3.ZERO

var _player = null
var _orders = {}  # unit -> the action this controller gave it

@onready var _ai = get_parent()


func setup(player):
	_player = player
	var timer = Timer.new()
	timer.timeout.connect(refresh)
	add_child(timer)
	timer.start(REFRESH_INTERVAL_S)


func refresh():
	if _player == null or not is_inside_tree():
		return
	_forget_lost_units()
	var home = _home_units()
	var center = _home_center()
	if center == null or home.is_empty():
		front_posts = []
		return
	home = _send_patrols(home)
	front_direction = _threat_direction(center)
	front_posts = posts(center, front_direction, home.size())
	_man_posts(home, front_posts)


func is_army_unit(unit):
	return (
		unit.player == _player
		and not unit is Structure
		and not unit is Worker
		and not unit is Hauler
		and unit.attack_range != null
		and unit.movement_speed > 0.0
		and unit.type != "Militia"
	)  # the city's own defense


func posts(center, direction, count):
	"""count posts on a line across the approach from direction, spread out to the map
	edges when they are close"""
	if count <= 0:
		return []
	var base_radius = _base_radius(center)
	var distance = max(FRONT_MIN_M, base_radius + FRONT_GAP_M)
	var enemy_distance = _threat_distance(center)
	if enemy_distance < INF:
		distance = min(distance, max(FRONT_MIN_M * 0.6, enemy_distance * FRONT_MAX_SHARE))
	var across = Vector3(-direction.z, 0.0, direction.x)
	var result = []
	var rows = int(ceil(float(count) / LINE_CAPACITY))
	for row in range(rows):
		var in_row = min(LINE_CAPACITY, count - row * LINE_CAPACITY)
		var line_center = _clamp_to_map(center + direction * (distance - row * ROW_GAP_M))
		var reach = _reach_along(line_center, across)  # [t_min, t_max] inside the map
		var spacing = MAX_SPACING_M
		if in_row > 1:
			spacing = clamp((reach[1] - reach[0]) / float(in_row - 1), MIN_SPACING_M, MAX_SPACING_M)
		var width = spacing * (in_row - 1)
		# centred on the approach, slid along the line to stay on the map
		var start = clamp(-width / 2.0, reach[0], max(reach[0], reach[1] - width))
		for i in range(in_row):
			var point = line_center + across * (start + spacing * i)
			result.append(UnitCommands.on_ground(get_tree(), point))
	return result


func _forget_lost_units():
	for unit in _orders.keys():
		if not is_instance_valid(unit) or not unit.is_inside_tree():
			_orders.erase(unit)


func _army():
	return get_tree().get_nodes_in_group("units").filter(is_army_unit)


func _ours(unit):
	var action = _orders.get(unit)
	return action != null and is_instance_valid(action) and unit.action == action


func _idle(unit):
	return unit.action == null or (unit.action.has_method("is_idle") and unit.action.is_idle())


func _home_units():
	"""idle units and the ones on their way to a post; not the patrols or attackers"""
	return _army().filter(
		func(unit): return _idle(unit) or (_ours(unit) and unit.action is AttackMoving)
	)


func _patrols():
	return _army().filter(func(unit): return _ours(unit) and unit.action is Patrolling)


func _send_patrols(home):
	var patrols = _patrols()
	var total = home.size() + patrols.size()
	var wanted = floori(total / float(PATROL_SHARE)) if total >= PATROL_FROM else 0
	if patrols.size() >= wanted:
		return home
	var circuit = UnitCommands.base_circuit(_player)
	if circuit.is_empty():
		return home
	var idle = home.filter(_idle)
	while patrols.size() < wanted and not idle.is_empty():
		var unit = idle.pop_back()
		var start = int(floor(float(patrols.size()) * circuit.size() / max(1, wanted)))
		var action = Patrolling.new(circuit, start)
		unit.action = action
		_orders[unit] = action
		patrols.append(unit)
		home.erase(unit)
	return home


func _man_posts(units, post_list):
	"""units keep the free post nearest to them, the ones that are not there go"""
	var free = post_list.duplicate()
	var ordered = units.duplicate()
	ordered.sort_custom(func(a, b): return _nearest_distance(a, free) < _nearest_distance(b, free))
	for unit in ordered:
		if free.is_empty():
			return
		var best = 0
		for i in range(free.size()):
			if (
				unit.global_position_yless.distance_to(free[i])
				< unit.global_position_yless.distance_to(free[best])
			):
				best = i
		var post = free[best]
		free.remove_at(best)
		if unit.global_position_yless.distance_to(post) <= AT_POST_M:
			continue
		if _ours(unit) and unit.action.get_plan()["points"][0].distance_to(post) <= AT_POST_M:
			continue  # already on the way
		if not _idle(unit) and not _ours(unit):
			continue
		var action = AttackMoving.new(post)
		unit.action = action
		_orders[unit] = action


static func _nearest_distance(unit, points):
	var best = INF
	for point in points:
		best = min(best, unit.global_position_yless.distance_to(point))
	return best


func _home_center():
	var ccs = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is CommandCenter and unit.player == _player
	)
	if ccs.is_empty():
		return null
	return ccs[0].global_position_yless


func _base_radius(center):
	var radius = 0.0
	for unit in get_tree().get_nodes_in_group("units"):
		if unit is Structure and unit.player == _player:
			var distance = unit.global_position_yless.distance_to(center)
			if distance <= BASE_RADIUS_CAP_M:
				radius = max(radius, distance)
	return radius


func _rivals():
	"""the players this AI expects trouble from: at war or wanted targets first"""
	var others = get_tree().get_nodes_in_group("players").filter(
		func(player): return player != _player and Diplomacy.ally_of(_player) != player
	)
	var hostile = others.filter(
		func(player):
			return (
				Diplomacy.at_war(_player, player)
				or (_ai.has_method("wants_to_attack") and _ai.wants_to_attack(player))
			)
	)
	return hostile if not hostile.is_empty() else others


func _nearest_rival_base(center):
	var best = null
	var best_distance = INF
	var rivals = _rivals()
	for unit in get_tree().get_nodes_in_group("units"):
		if not unit is Structure or not unit.player in rivals:
			continue
		var distance = unit.global_position_yless.distance_to(center)
		var weight = 0.0 if unit is CommandCenter else 8.0  # command centers mark the base
		if distance + weight < best_distance:
			best = unit.global_position_yless
			best_distance = distance + weight
	return best


func _threat_direction(center):
	var target = _nearest_rival_base(center)
	if target == null:
		var map = _map()
		target = Vector3(map.size.x / 2.0, 0, map.size.y / 2.0) if map != null else center
	var direction = (target - center) * Vector3(1, 0, 1)
	return direction.normalized() if direction.length() > 0.5 else Vector3(1, 0, 0)


func _threat_distance(center):
	var target = _nearest_rival_base(center)
	return center.distance_to(target) if target != null else INF


func _map():
	var match_node = get_tree().get_first_node_in_group("match")
	return match_node.map if match_node != null else null


func _clamp_to_map(point):
	var map = _map()
	if map == null:
		return point
	return Vector3(
		clamp(point.x, MAP_MARGIN_M, map.size.x - MAP_MARGIN_M),
		0.0,
		clamp(point.z, MAP_MARGIN_M, map.size.y - MAP_MARGIN_M)
	)


func _reach_along(origin, across):
	"""how far the line through origin along across can go each way inside the map"""
	var map = _map()
	if map == null:
		return [-INF, INF]
	var t_min = -INF
	var t_max = INF
	for axis in [[origin.x, across.x, map.size.x], [origin.z, across.z, map.size.y]]:
		if abs(axis[1]) < 0.0001:
			continue
		var a = (MAP_MARGIN_M - axis[0]) / axis[1]
		var b = (axis[2] - MAP_MARGIN_M - axis[0]) / axis[1]
		t_min = max(t_min, min(a, b))
		t_max = min(t_max, max(a, b))
	return [t_min, t_max]
