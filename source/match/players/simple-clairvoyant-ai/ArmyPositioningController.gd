extends Node

# Decides where an AI's army stands while it is not out attacking or raiding. Instead of
# waiting in a heap next to the factory, units take up spots in a few groups:
#
# - front: a line across the way the likely attack comes from, at the narrowest passage
#   found within the personality's front distance (a cheap chokepoint search on the navmesh);
# - flanks: two small groups to the sides; when a flank is closed by the map edge or by
#   ground units cannot cross, its share joins the front instead;
# - reserve: a block near the city on the threatened side;
# - guards: one or two units at the most exposed remote extractors (traders guard the middle
#   of the route to them instead).
#
# The turtle personality holds a tight ring around the city instead, and the raider keeps a
# staging area part of the way to its target. Settings are in data/ai/*.json under "defence".
#
# When enemy units come inside the defended zone, the nearest held units go for them and walk
# back to their spots once the fight is over or when it drags them too far away.
#
# Spots are only targets: avoidance and pathfinding sort out how units get there.

const Worker = preload("res://source/match/units/Worker.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
const MovingToUnit = preload("res://source/match/units/actions/MovingToUnit.gd")
const WaitingForTargets = preload("res://source/match/units/actions/WaitingForTargets.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")

const REFRESH_S = 1.0  # react to intruders, walk strays back
const RETHINK_S = 15.0  # place the spots again (threat, city size and army size change slowly)
const ARRIVED_M = 2.5  # closer than this to its spot a unit counts as in place
const EDGE_MARGIN_M = 6.0  # a flank this close to the map edge is covered by the edge itself
const NAV_TOLERANCE_M = 1.5  # a point farther than this from the navmesh is not walkable
const CROSS_SECTION_STEP_M = 3.0
const CROSS_SECTION_MAX_M = 24.0  # half width of the widest passage measured
const RESPONDERS_PER_INTRUDER = 2
const CELL_M = 1.0  # navmesh answers are cached per cell of this size
const CACHE_LIFETIME_S = 120.0
const NAV_QUERIES_PER_TICK = 40  # beyond this, unknown cells pass as walkable until next tick
const FRONT_SEARCH_STEP_M = 4.0
const FRONT_SEARCH_STEPS_PER_TICK = 2
const DEFAULTS = {
	"shape": "groups",  # "groups" or "ring"
	"front_m": 16.0,  # front line distance beyond the edge of the city
	"choke_search_m": 12.0,  # how much nearer or farther the front may move to a narrow spot
	"staging_share": 0.0,  # raider: front at this share of the way to the target's city
	"front": 0.5,  # shares of the held army per group
	"flanks": 0.2,
	"reserve": 0.2,
	"guards": 0.1,
	"guard_routes": false,  # guards stand halfway along the route, not at the extractor
	"max_guard_posts": 2,
	"spacing_m": 4.0,  # between neighbours in a formation
	"ring_m": 5.0,  # turtle: ring distance beyond the edge of the city
	"react_m": 22.0,  # intruders this far beyond the city edge (or near a guard post) are fought
	"leash_m": 30.0,  # units dragged farther than this from their spot are called back
}

var posts = []  # [{"kind": .., "position": Vector3, "facing": Vector3}] for tests and debugging
var cost_usec = 0  # time spent thinking, for the perf tests
var worst_usec = 0

var _player = null
var _settings = DEFAULTS.duplicate()
var _home = null
var _city_radius = 10.0
var _threat = null  # Vector3: where trouble is expected from
var _slots = {}  # unit -> Vector3 spot
var _guarded = []  # Vector3 places outside the city that are defended too
var _since_rethink_s = RETHINK_S
var _clock_s = 0.0
var _sent_to = {}  # unit -> the spot its current Moving action heads for
var _closest_cache = {}  # Vector2i cell -> closest navigable point
var _cache_age_s = 0.0
var _nav_queries_left = NAV_QUERIES_PER_TICK
var _layout = {}  # front and flank centres, worked out again only when city or threat change
var _front_search = {}  # the narrow pass search under way
var _first_seen = {}  # intruder -> when it was first seen inside the zone
var _match = null
var _map_rect = Rect2()

@onready var _ai = get_parent()


func setup(player):
	_player = player
	_match = find_parent("Match")
	if _match != null and _match.map != null:
		_map_rect = Rect2(Vector2.ZERO, _match.map.size)
	var personality_settings = _ai.get("defence")
	if personality_settings is Dictionary:
		for key in personality_settings:
			_settings[key] = personality_settings[key]
	# easier difficulties think less often (think_interval, if the AI has one)
	var interval = _ai.think_interval(REFRESH_S) if _ai.has_method("think_interval") else REFRESH_S
	var timer = Timer.new()
	timer.timeout.connect(_tick.bind(interval))
	add_child(timer)
	timer.start(interval * randf_range(0.9, 1.1))  # AIs should not all think in the same frame


func debug_posts():
	return posts.map(
		func(post):
			return {
				"kind": post["kind"],
				"x": post["position"].x,
				"z": post["position"].z,
				"slots": post["slots"].map(func(slot): return [slot.x, slot.z]),
			}
	)


func spot_of(unit):
	"""where 'unit' should stand, null if this controller does not hold it"""
	return _slots.get(unit)


func _tick(delta):
	if not is_inside_tree():
		return
	var started_usec = Time.get_ticks_usec()
	_think(delta)
	var spent_usec = Time.get_ticks_usec() - started_usec
	cost_usec += spent_usec
	worst_usec = max(worst_usec, spent_usec)


func _think(delta):
	_clock_s += delta
	_nav_queries_left = NAV_QUERIES_PER_TICK
	_cache_age_s += delta
	if _cache_age_s > CACHE_LIFETIME_S:
		_cache_age_s = 0.0
		_closest_cache = {}
		_layout["key"] = null  # look for the narrow pass again, hold the old front meanwhile
		_front_search = {}
	var units = _available_units()
	_since_rethink_s += delta
	var army_changed = units.size() != _slots.size() or units.any(func(u): return not u in _slots)
	if _since_rethink_s >= RETHINK_S or army_changed:
		_since_rethink_s = 0.0
		_rethink(units)
	if _home == null:
		return
	_advance_front_search()
	var responding = _respond_to_intruders(units)
	for unit in units:
		if not unit in responding:
			_keep_in_place(unit)


func _available_units():
	"""combat units of this AI that are not out attacking or raiding"""
	var committed = {}
	for controller_name in ["OffenseController", "RaidingController"]:
		var controller = _ai.get_node_or_null(controller_name)
		if controller != null and controller.has_method("committed_units"):
			for unit in controller.committed_units():
				committed[unit] = true
	return get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return (
				unit.player == _player
				and not unit is Structure
				and not unit is Worker
				and unit.attack_range != null
				and unit.movement_speed > 0.0
				and not committed.has(unit)
			)
	)


# placing the spots


func _rethink(units):
	_home = _find_home()
	if _home == null:
		_slots = {}
		posts = []
		return
	# small changes do not move the spots: units would shuffle around for nothing
	var city_radius = _measure_city_radius()
	if abs(city_radius - _city_radius) > 3.0:
		_city_radius = city_radius
	var threat = _find_threat()
	if (
		_threat == null
		or (threat - _home).normalized().dot(_threat_direction()) < cos(deg_to_rad(20.0))
	):
		_threat = threat
	_guarded = []
	posts = []
	var spacing = _spacing_for(units)
	if units.is_empty():
		_slots = {}
		return
	if _settings["shape"] != "ring":
		_place_groups(units.size(), spacing)
	var missing = units.size() - _number_of_slots()
	if missing > 0:  # the ring, or spots the groups could not find room for
		_place_ring(missing, spacing)
	_assign(units)


func _number_of_slots():
	var count = 0
	for post in posts:
		count += post["slots"].size()
	return count


func _place_ring(count, spacing):
	var radius = _city_radius + float(_settings["ring_m"])
	var facing = _threat_direction()
	var slots = []
	var occupied = _taken_spots()
	# fill from the threatened side outwards so that a small army faces the threat;
	# a second, wider ring starts once the first is full or blocked
	while slots.size() < count and radius < _city_radius + 40.0:
		var steps = max(int(TAU * radius / spacing), 6)
		for i in range(steps):
			var side = 1 if i % 2 == 0 else -1
			var angle = side * ceil(i / 2.0) * TAU / steps
			var spot = _home + facing.rotated(Vector3.UP, angle) * radius
			if _walkable(spot) and not _too_close(spot, occupied, spacing * 0.9):
				slots.append(spot)
				occupied.append(spot)
			if slots.size() >= count:
				break
		radius += spacing
	posts.append({"kind": "ring", "position": _home, "facing": facing, "slots": slots})


func _taken_spots():
	var spots = []
	for post in posts:
		spots += post["slots"]
	return spots


func _place_groups(count, spacing):
	var facing = _threat_direction()
	var shares = {
		"front": float(_settings["front"]),
		"flank_left": float(_settings["flanks"]) / 2.0,
		"flank_right": float(_settings["flanks"]) / 2.0,
		"reserve": float(_settings["reserve"]),
		"guards": float(_settings["guards"]),
	}
	var layout = _group_layout(facing)
	var front_center = layout["front"]
	var guard_spots = _guard_spots()
	if guard_spots.is_empty():
		shares["reserve"] += shares["guards"]
		shares["guards"] = 0.0
	var flank_centers = layout["flanks"]
	for side in ["flank_left", "flank_right"]:
		if not flank_centers.has(side):
			shares["front"] += shares[side]  # the edge covers this side
			shares[side] = 0.0
	var counts = _split(count, shares)
	if counts["front"] > 0:
		_add_line_post("front", front_center, facing, counts["front"], spacing)
	for side in flank_centers:
		if counts[side] > 0:
			var side_facing = (flank_centers[side] - _home).normalized()
			_add_line_post(side, flank_centers[side], side_facing, counts[side], spacing)
	if counts["reserve"] > 0:
		var reserve_center = _home + facing * (_city_radius * 0.6)
		_add_line_post("reserve", reserve_center, facing, counts["reserve"], spacing, 3)
	var guards_left = counts["guards"]
	var guard_posts = []
	for spot in guard_spots:
		if guards_left <= 0:
			break
		var size = int(ceil(float(guards_left) / max(guard_spots.size() - guard_posts.size(), 1)))
		guard_posts.append(spot)
		_guarded.append(spot)
		_add_line_post("guard", spot, (spot - _home).normalized(), size, spacing, 2)
		guards_left -= size


func _group_layout(facing):
	"""front and flank centres; the narrow pass search behind the front is the costly part,
	so it runs a few steps per tick (see _advance_front_search) and only when the city grew
	or the threat moved; until it is done the old front, or a plain one, is held"""
	var key = [_city_radius, facing, _home]
	if _layout.get("key") == key:
		return _layout
	var front_distance = _front_distance()
	if _front_search.get("key") != key:
		var search = float(_settings["choke_search_m"])
		var distances = []
		var distance = max(front_distance - search, _city_radius + 4.0)
		while distance <= front_distance + search:
			distances.append(distance)
			distance += FRONT_SEARCH_STEP_M
		_front_search = {
			"key": key,
			"facing": facing,
			"preferred": front_distance,
			"distances": distances,
			"best": null,
			"best_score": INF,
		}
	var front = _layout.get("front", _snap(_home + facing * front_distance))
	return {"key": null, "front": front, "flanks": _flank_centers(facing, front_distance)}


func _flank_centers(facing, front_distance):
	var flanks = {}
	for side in ["flank_left", "flank_right"]:
		var angle = deg_to_rad(55.0) * (1 if side == "flank_left" else -1)
		var center = _home + facing.rotated(Vector3.UP, angle) * front_distance * 0.85
		if not _closed_by_edge(center):
			flanks[side] = _snap(center)
	return flanks


func _advance_front_search():
	"""the narrowest walkable passage near the preferred distance on the way to the threat;
	a narrow front needs fewer units to hold and cannot be walked around easily"""
	if _front_search.is_empty() or _front_search["distances"].is_empty():
		return
	var facing = _front_search["facing"]
	var across = Vector3(-facing.z, 0, facing.x)
	for _i in range(FRONT_SEARCH_STEPS_PER_TICK):
		if _front_search["distances"].is_empty():
			break
		var distance = _front_search["distances"].pop_front()
		var spot = _home + facing * distance
		if not _walkable(spot):
			continue
		var width = _cross_section(spot, across)
		var score = width * (1.0 + 0.03 * abs(distance - _front_search["preferred"]))
		if score < _front_search["best_score"]:
			_front_search["best_score"] = score
			_front_search["best"] = spot
	if not _front_search["distances"].is_empty():
		return
	var best = _front_search["best"]
	if best == null:  # nothing walkable that way: hold the edge of the city
		best = _home + facing * (_city_radius + 3.0)
	_layout = {
		"key": _front_search["key"],
		"front": _snap(best),
		"flanks": _flank_centers(facing, _front_search["preferred"]),
	}
	_front_search = {}
	_since_rethink_s = RETHINK_S  # move the army to the new front


func _add_line_post(kind, center, facing, count, spacing, max_per_row = 0):
	"""rows across 'facing', the first row in front, the next ones behind it"""
	var across = Vector3(-facing.z, 0, facing.x)
	var per_row = max_per_row
	if per_row <= 0:
		var width = _cross_section(center, across)
		per_row = clampi(int(width / spacing), 3, 8)
	var slots = []
	var row = 0
	while slots.size() < count and row < 8:
		var in_row = min(per_row, count - slots.size())
		for i in range(per_row):
			if slots.size() >= count:
				break
			# centre the row and stagger every other one so back rows look through gaps
			var offset = (i - (in_row - 1) / 2.0) + (0.5 if row % 2 == 1 else 0.0)
			var spot = center + across * offset * spacing - facing * row * spacing
			if _walkable(spot):
				slots.append(_snap(spot))
		row += 1
	posts.append({"kind": kind, "position": center, "facing": facing, "slots": slots})


func _assign(units):
	"""closest unit and spot pairs first: units already in place keep their spots"""
	var spots = []
	for post in posts:
		spots += post["slots"]
	var pairs = []
	for unit in units:
		for index in range(spots.size()):
			pairs.append(
				[unit.global_position_yless.distance_squared_to(spots[index]), unit, index]
			)
	pairs.sort_custom(func(a, b): return a[0] < b[0])
	var new_slots = {}
	var taken = {}
	for pair in pairs:
		if new_slots.has(pair[1]) or taken.has(pair[2]):
			continue
		new_slots[pair[1]] = spots[pair[2]]
		taken[pair[2]] = true
	# units left without a spot (every spot blocked) wait at the reserve
	for unit in units:
		if not new_slots.has(unit):
			new_slots[unit] = _home + _threat_direction() * _city_radius * 0.5
	_slots = new_slots
	var sent_to = {}
	for unit in _sent_to:
		if new_slots.has(unit):
			sent_to[unit] = _sent_to[unit]
	_sent_to = sent_to


func _split(count, shares):
	"""shares to whole numbers of units that add up to count"""
	var total = 0.0
	for key in shares:
		total += shares[key]
	var counts = {}
	var given = 0
	var remainders = []
	for key in shares:
		var exact = count * shares[key] / max(total, 0.001)
		counts[key] = int(floor(exact))
		given += counts[key]
		remainders.append([exact - floor(exact), key])
	remainders.sort_custom(func(a, b): return a[0] > b[0])
	for i in range(count - given):
		counts[remainders[i % remainders.size()][1]] += 1
	return counts


func _front_distance():
	var distance = _city_radius + float(_settings["front_m"])
	var staging_share = float(_settings["staging_share"])
	if staging_share > 0.0 and _threat != null:
		distance = max(distance, _home.distance_to(_threat) * staging_share)
	return distance


func _cross_section(center, across):
	"""how wide the walkable ground is across 'center', capped on each side"""
	var width = 0.0
	for side in [1.0, -1.0]:
		var step = CROSS_SECTION_STEP_M
		while step <= CROSS_SECTION_MAX_M and _walkable(center + across * side * step):
			step += CROSS_SECTION_STEP_M
		width += step - CROSS_SECTION_STEP_M
	return width


func _guard_spots():
	"""remote extractors, the ones nearest the threat first"""
	var max_posts = int(_settings["max_guard_posts"])
	if float(_settings["guards"]) <= 0.0 or max_posts <= 0:
		return []
	var remote = get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return (
				unit.player == _player
				and unit is Extractor
				and unit.global_position_yless.distance_to(_home) > _city_radius + 8.0
			)
	)
	var threat = _threat if _threat != null else _home
	remote.sort_custom(
		func(a, b):
			return (
				a.global_position_yless.distance_to(threat)
				< b.global_position_yless.distance_to(threat)
			)
	)
	var spots = []
	for extractor in remote:
		var spot = extractor.global_position_yless
		if _settings["guard_routes"]:
			spot = (spot + _home) / 2.0
		else:
			spot += (threat - spot).normalized() * (extractor.radius + 3.0)
		if _walkable(spot) and not _too_close(spot, spots, 10.0):
			spots.append(_snap(spot))
		if spots.size() >= max_posts:
			break
	return spots


# holding the spots


func _keep_in_place(unit):
	var spot = _slots.get(unit)
	if spot == null:
		return
	if unit.get_meta("defending", false) and not unit.action is AutoAttacking:
		unit.remove_meta("defending")
	var distance = unit.global_position_yless.distance_to(spot)
	if unit.action is Moving:
		if distance <= ARRIVED_M:
			unit.action = WaitingForTargets.new()  # there (a crowded spot may never "arrive")
		elif _sent_to.get(unit, spot).distance_to(spot) > ARRIVED_M:
			_send(unit, spot)  # its spot moved since
		return  # on its way
	var managed = (
		unit.action == null
		or unit.action is WaitingForTargets
		or unit.action is AutoAttacking
		or unit.action is MovingToUnit
	)
	if not managed:
		return  # e.g. landing to refuel: leave it be
	if _is_busy_fighting(unit) and distance < float(_settings["leash_m"]):
		return  # fighting something nearby: let it
	if distance > ARRIVED_M:
		_send(unit, spot)


func _send(unit, spot):
	_sent_to[unit] = spot
	unit.action = Moving.new(spot)


func _respond_to_intruders(units):
	"""the nearest held units go for enemies inside the defended zone"""
	var responding = {}
	var intruders = _intruders()
	if intruders.is_empty():
		return responding
	for intruder in intruders:
		var candidates = units.filter(
			func(unit):
				return (
					not responding.has(unit)
					and AutoAttacking.is_applicable(unit, intruder)
					and not _is_busy_fighting(unit)
				)
		)
		candidates.sort_custom(
			func(a, b):
				return (
					a.global_position_yless.distance_squared_to(intruder.global_position_yless)
					< b.global_position_yless.distance_squared_to(intruder.global_position_yless)
				)
		)
		for unit in candidates.slice(0, RESPONDERS_PER_INTRUDER):
			unit.action = AutoAttacking.new(intruder)
			unit.set_meta("defending", true)
			responding[unit] = true
	# units already fighting an intruder stay on it
	for unit in units:
		if _is_busy_fighting(unit):
			responding[unit] = true
	return responding


func _is_busy_fighting(unit):
	if unit.action is AutoAttacking:
		return true
	return unit.action is WaitingForTargets and not unit.action.is_idle()


func _intruders():
	var react = float(_settings["react_m"])
	var found = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _player or unit.player == null:
			continue
		if unit is Structure or not Diplomacy.engages_on_sight(_player, unit.player):
			continue
		var position = unit.global_position_yless
		var inside = position.distance_to(_home) < _city_radius + react
		if not inside:
			for spot in _guarded:
				if position.distance_to(spot) < react * 0.6:
					inside = true
					break
		if inside:
			found.append(unit)
	# easier difficulties notice intruders later (reaction_delay_s, if the AI has one)
	var delay = float(_ai.get("reaction_delay_s")) if _ai.get("reaction_delay_s") != null else 0.0
	var seen = {}
	for unit in found:
		seen[unit] = _first_seen.get(unit, _clock_s)
	_first_seen = seen
	return found.filter(func(unit): return _clock_s - seen[unit] >= delay)


# reading the map


func _find_home():
	for unit in get_tree().get_nodes_in_group("units"):
		if unit is CommandCenter and unit.player == _player:
			return unit.global_position_yless
	return null


func _measure_city_radius():
	"""how far the base reaches: most of its buildings, not the odd far one (remote
	extractors and outlying turrets would push every spot too far out)"""
	var distances = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _player and unit is Structure:
			distances.append(unit.global_position_yless.distance_to(_home) + unit.radius)
	for building in get_tree().get_nodes_in_group("city_buildings"):
		if building.get("player") == _player:
			distances.append(
				(building.global_position * Vector3(1, 0, 1)).distance_to(_home) + building.radius
			)
	distances = distances.filter(func(distance): return distance < 30.0)
	if distances.is_empty():
		return 10.0
	distances.sort()
	return max(10.0, distances[int(floor((distances.size() - 1) * 0.85))])


func _find_threat():
	"""the city of the faction most likely to attack: at war first, then the ones this AI
	would attack itself, then simply the nearest one"""
	var best = null
	var best_score = INF
	for unit in get_tree().get_nodes_in_group("units"):
		if not unit is CommandCenter or unit.player == _player:
			continue
		if (
			not Diplomacy.can_attack(_player, unit.player)
			and not Diplomacy.at_war(_player, unit.player)
		):
			continue  # under a treaty: not a threat for now
		var score = unit.global_position_yless.distance_to(_home)
		if Diplomacy.at_war(_player, unit.player):
			score *= 0.25
		elif _ai.has_method("wants_to_attack") and _ai.wants_to_attack(unit.player):
			score *= 0.6
		if score < best_score:
			best_score = score
			best = unit.global_position_yless
	if best == null:  # everybody is friendly: face the middle of the map
		best = Vector3(_map_rect.get_center().x, 0, _map_rect.get_center().y)
	return best


func _threat_direction():
	if _threat == null or _threat.distance_to(_home) < 1.0:
		return Vector3(0, 0, 1)
	return (_threat - _home).normalized()


func _closed_by_edge(spot):
	if not _map_rect.grow(-EDGE_MARGIN_M).has_point(Vector2(spot.x, spot.z)):
		return true
	return not _walkable(spot)


func _walkable(spot):
	if _map_rect.size != Vector2.ZERO and not _map_rect.has_point(Vector2(spot.x, spot.z)):
		return false
	var closest = _closest_navigable_point(spot)
	return closest == null or closest.distance_to(spot * Vector3(1, 0, 1)) < NAV_TOLERANCE_M


func _snap(spot):
	if _walkable(spot):
		return spot * Vector3(1, 0, 1)
	var closest = _closest_navigable_point(spot)
	return closest if closest != null else spot * Vector3(1, 0, 1)


func _closest_navigable_point(spot):
	"""navmesh queries are slow on big maps (~0.1 ms each), so answers are kept per cell
	for a while; the navmesh only changes a little when buildings go up"""
	var map_rid = _navigation_map()
	if not map_rid.is_valid():
		return null
	var cell = Vector2i(floori(spot.x / CELL_M), floori(spot.z / CELL_M))
	if not _closest_cache.has(cell):
		if _nav_queries_left <= 0:
			return null  # over budget: the spot is taken as it is, checked on a later tick
		_nav_queries_left -= 1
		var center = Vector3((cell.x + 0.5) * CELL_M, spot.y, (cell.y + 0.5) * CELL_M)
		_closest_cache[cell] = (
			NavigationServer3D.map_get_closest_point(map_rid, center) * Vector3(1, 0, 1)
		)
	return _closest_cache[cell]


func _navigation_map():
	if _match == null or _match.navigation == null:
		return RID()
	return _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)


func _spacing_for(units):
	var spacing = float(_settings["spacing_m"])
	for unit in units:
		spacing = max(spacing, unit.radius * 2.0 + 2.0)
	return spacing


static func _too_close(spot, spots, distance):
	for other in spots:
		if other.distance_to(spot) < distance:
			return true
	return false
