extends RefCounted

# The player's railway, kept by Logistics (logistics.rails): one shared network of track
# that every train of the player runs on. It is a graph: nodes are stop platforms (one per
# depot, extractor or storage a train serves) and junctions, and "legs" are the smooth
# stretches of track between two nodes.
#
# Track is planned the first time a train needs to get somewhere it cannot reach yet.
# Instead of running a separate line to every stop, a new stretch branches off the
# nearest existing track when that is cheaper than a line of its own, so a base grows a
# trunk line with spurs and junctions. A leg is made unbuilt; trains lay it from either
# end (built_a from node a, built_b from node b) paying for it metre by metre, and it is
# complete once the two meet. See Train.gd.
#
# When a branch joins the middle of a leg, the leg is split in two at a new junction.
# The old leg is kept out of `legs` with a "dead" entry naming its two halves, so a
# train that was running on it carries on (resolve_piece, resolve_position).

const Storage = preload("res://source/match/units/Storage.gd")

const SAMPLE_M = 0.6  # spacing of the points along a leg
const PLATFORM_GAP_M = 1.8  # from a stop building's edge to its platform node
const JOIN_MIN_GAP_M = 4.0  # a branch joins a leg at least this far from its ends
const REUSE_DETOUR = 1.5  # existing track is used while no longer than this x direct
const NEW_TRACK_WEIGHT = 1.0
const OLD_TRACK_WEIGHT = 0.3
const MAX_DETOUR = 1.7  # a branch is only taken while the trip stays this short

var legs = {}  # key -> {a, b, points, cumulative, length, built_a, built_b, key}
var nodes = {}  # id -> {position: Vector3, legs: [key], stop: bool}
var changed = false  # set when track was laid or planned, RailVisuals redraws
var track_spent_total = {}  # statistics

var _logistics = null
var _stop_nodes = {}  # stop instance id -> node id
var _next_id = 1


func _init(logistics):
	_logistics = logistics


# ---------------------------------------------------------------------------
# Lines
# ---------------------------------------------------------------------------


func plan_line(train):
	"""up to 'auto_stops' sources nobody's train serves yet, the busiest far ones first,
	in the order a loop from the depot visits them"""
	var config = Constants.Match.Logistics.TRAIN
	var depot = _logistics.closest_depot(train.global_position)
	if depot == null:
		return []
	var served = []
	for other in _logistics.fleet.get_trains():
		if other != train:
			served.append_array(other.stops)
	var candidates = []
	for source in _logistics.get_sources():
		var distance = _distance(source.global_position, depot.global_position)
		if source in served or distance < float(config.get("auto_min_route_m", 18.0)):
			continue
		var rate = source.get_rate_per_s()
		if rate <= 0.0 and source.get_available_for_pickup() == 0:
			continue
		candidates.append([rate * distance + source.get_available_for_pickup(), source])
	if candidates.is_empty():
		return []
	candidates.sort_custom(func(a, b): return a[0] > b[0])
	var chosen = [candidates[0][1]]
	var max_leg = float(config.get("max_leg_m", 60.0))
	for candidate in candidates.slice(1):
		if chosen.size() >= int(config.get("auto_stops", 3)):
			break
		var near = false
		for stop in chosen:
			if _distance(stop.global_position, candidate[1].global_position) <= max_leg:
				near = true
		if near:
			chosen.append(candidate[1])
	# nearest neighbour from the depot
	var ordered = []
	var at = depot.global_position
	while not chosen.is_empty():
		var next = chosen[0]
		for stop in chosen:
			if _distance(stop.global_position, at) < _distance(next.global_position, at):
				next = stop
		ordered.append(next)
		chosen.erase(next)
		at = next.global_position
	return ordered


func wants_train():
	"""true when at least two busy far sources (or one storage) have no train yet"""
	var depot_count = _logistics.get_depots().size()
	if depot_count == 0:
		return false
	var served = _logistics._sources_served_by_trains()
	var far = 0
	for source in _logistics.get_sources():
		if source in served or source.get_rate_per_s() <= 0.0:
			continue
		var depot = _logistics.closest_depot(source.global_position)
		var distance = _distance(source.global_position, depot.global_position)
		if distance < float(Constants.Match.Logistics.TRAIN.get("auto_min_route_m", 18.0)):
			continue
		far += 2 if source is Storage else 1
	return far >= 2


# ---------------------------------------------------------------------------
# Nodes and routes
# ---------------------------------------------------------------------------


func node_for_stop(stop, towards):
	"""the platform node of a depot, extractor or storage, made on first use on the side
	facing 'towards'"""
	var id = stop.get_instance_id()
	if id in _stop_nodes and _stop_nodes[id] in nodes:
		return _stop_nodes[id]
	var direction = (towards - stop.global_position) * Vector3(1, 0, 1)
	if direction.length_squared() < 0.0001:
		direction = Vector3(1, 0, 0)
	var at = stop.global_position_yless + direction.normalized() * (stop.radius + PLATFORM_GAP_M)
	var node = _snap_to_terrain(at)
	var id_node = _add_node(node, true)
	nodes[id_node]["source"] = stop.global_position_yless
	nodes[id_node]["depot"] = stop in _logistics.get_depots()
	_stop_nodes[id] = id_node
	return id_node


func has_stop_node(stop):
	return stop.get_instance_id() in _stop_nodes


func get_stop_node_ids():
	return _stop_nodes.values()


func route(from_node, to_node):
	"""[[leg, reversed], ...] from one node to another, planning new track (unbuilt) when
	the network does not connect them well yet; [] when they are the same node"""
	if from_node == to_node:
		return []
	var direct = _distance(nodes[from_node]["position"], nodes[to_node]["position"])
	var found = _dijkstra(to_node)
	var reach = found[0]
	if reach.get(from_node, INF) > direct * REUSE_DETOUR + 8.0:
		_connect(from_node, to_node, reach)
		found = _dijkstra(to_node)
	return _path_from(from_node, found)


func path_between(from_node, to_node):
	"""the pieces along existing (built or planned) track, [] when not connected; plans
	nothing"""
	if from_node == to_node or not from_node in nodes or not to_node in nodes:
		return []
	return _path_from(from_node, _dijkstra(to_node))


func stop_node_of(stop):
	"""the platform node of a stop, or null when no train has gone there yet"""
	return _stop_nodes.get(stop.get_instance_id())


func resolve_piece(leg, reversed):
	"""the live legs a leg that may have been split since stands for, in travel order"""
	if not "dead" in leg:
		return [[leg, reversed]]
	var dead = leg["dead"]
	if reversed:
		return resolve_piece(dead["second"], true) + resolve_piece(dead["first"], true)
	return resolve_piece(dead["first"], false) + resolve_piece(dead["second"], false)


func resolve_position(leg, reversed, t):
	"""[live leg, reversed, t, [pieces after it]] for a train t metres into a leg"""
	if not "dead" in leg:
		return [leg, reversed, t, []]
	var dead = leg["dead"]
	var at = dead["at"]
	var from_a = leg["length"] - t if reversed else t
	var inside = null
	var after = []
	if from_a < at:
		var t_first = t - (leg["length"] - at) if reversed else t
		inside = resolve_position(dead["first"], reversed, t_first)
		if not reversed:
			after = resolve_piece(dead["second"], false)
	else:
		inside = resolve_position(dead["second"], reversed, t - at if not reversed else t)
		if reversed:
			after = resolve_piece(dead["first"], true)
	return [inside[0], inside[1], inside[2], inside[3] + after]


func end_node(leg, reversed):
	return leg["a"] if reversed else leg["b"]


func nearest_node(position, within_m = INF):
	var best = null
	var best_d = within_m
	for id in nodes:
		var d = _distance(nodes[id]["position"], position)
		if d < best_d:
			best = id
			best_d = d
	return best


func tangent_at_node(id):
	"""the direction the track leaves a node in, for platform buildings"""
	for key in nodes[id]["legs"]:
		var leg = legs.get(key)
		if leg == null or leg["points"].size() < 2:
			continue
		var points = leg["points"]
		if leg["a"] == id:
			return (points[min(3, points.size() - 1)] - points[0]).normalized()
		return (points[max(points.size() - 4, 0)] - points[points.size() - 1]).normalized()
	return Vector3.FORWARD


func is_node_reached(id):
	"""true when built track touches the node"""
	for key in nodes[id]["legs"]:
		var leg = legs.get(key)
		if leg == null:
			continue
		if leg["built_a"] + leg["built_b"] >= leg["length"] - 0.05:
			return true
		if (leg["a"] == id and leg["built_a"] > 0.5) or (leg["b"] == id and leg["built_b"] > 0.5):
			return true
	return false


func get_length_m(built_only = true):
	var total = 0.0
	for leg in legs.values():
		total += (
			min(leg["length"], leg["built_a"] + leg["built_b"]) if built_only else leg["length"]
		)
	return total


func note_track_spent(goods):
	for resource in goods:
		Utils.Dict.add_amount(track_spent_total, resource, goods[resource])


# ---------------------------------------------------------------------------
# Planning track
# ---------------------------------------------------------------------------


func _connect(from_node, to_node, reach_to):
	"""plans the cheapest new track that joins the two nodes: a line of its own, or a
	branch from either end to the nearest track the other end already reaches"""
	var a = nodes[from_node]["position"]
	var b = nodes[to_node]["position"]
	var direct = _distance(a, b)
	var best = {"cost": direct * NEW_TRACK_WEIGHT, "kind": "direct"}
	var reach_from = _dijkstra(from_node)[0]
	for side in [[from_node, a, reach_to], [to_node, b, reach_from]]:
		var origin = side[1]
		var reach = side[2]
		for target in _join_candidates(side[0], reach):
			var spur = _distance(origin, target["position"])
			var travel = spur + target["rest"]
			if travel > direct * MAX_DETOUR + 6.0:
				continue
			var cost = spur * NEW_TRACK_WEIGHT + target["rest"] * OLD_TRACK_WEIGHT
			if cost < best["cost"]:
				best = {"cost": cost, "kind": "branch", "from": side[0], "target": target}
	if best["kind"] == "direct":
		_add_leg(from_node, to_node)
		return
	var target = best["target"]
	var join = target["node"]
	if join == null:
		join = _split(target["leg"], target["index"])
	if join != best["from"]:
		_add_leg(best["from"], join)


func _join_candidates(exclude_node, reach):
	"""points on the network the other end can reach: nodes, and samples along legs
	({position, rest: metres of track from there on, node or leg + index})"""
	var found = []
	for id in nodes:
		if id != exclude_node and id in reach:
			found.append(
				{"position": nodes[id]["position"], "rest": reach[id], "node": id, "leg": null}
			)
	for leg in legs.values():
		if not leg["a"] in reach and not leg["b"] in reach:
			continue
		if leg["a"] == exclude_node or leg["b"] == exclude_node:
			continue
		var cumulative = leg["cumulative"]
		var step = max(1, int(3.0 / SAMPLE_M))
		for index in range(step, leg["points"].size() - 1, step):
			var t = cumulative[index]
			if t < JOIN_MIN_GAP_M or leg["length"] - t < JOIN_MIN_GAP_M:
				continue
			var rest = min(
				t + reach.get(leg["a"], INF), leg["length"] - t + reach.get(leg["b"], INF)
			)
			found.append(
				{
					"position": leg["points"][index],
					"rest": rest,
					"node": null,
					"leg": leg,
					"index": index
				}
			)
	return found


func _split(leg, index):
	"""a junction at the leg's point 'index': the leg becomes two"""
	var points = leg["points"]
	var at = leg["cumulative"][index]
	var length = leg["length"]
	var junction = _add_node(points[index], false)
	var first = _make_leg(leg["a"], junction, points.slice(0, index + 1))
	var second = _make_leg(junction, leg["b"], points.slice(index))
	var built_a = leg["built_a"]
	var built_b = leg["built_b"]
	if built_a >= length:
		first["built_a"] = first["length"]
		second["built_a"] = second["length"]
	else:
		first["built_a"] = min(built_a, first["length"])
		first["built_b"] = clamp(built_b - (length - at), 0.0, first["length"])
		second["built_a"] = clamp(built_a - at, 0.0, second["length"])
		second["built_b"] = min(built_b, second["length"])
		for half in [first, second]:
			if half["built_a"] + half["built_b"] >= half["length"]:
				half["built_a"] = half["length"]
				half["built_b"] = 0.0
	_remove_leg(leg)
	leg["dead"] = {"at": at, "first": first, "second": second}
	_register_leg(first)
	_register_leg(second)
	return junction


func _add_leg(from_node, to_node):
	var points = _smooth_path(nodes[from_node]["position"], nodes[to_node]["position"])
	var leg = _make_leg(from_node, to_node, points)
	_register_leg(leg)
	return leg


func _make_leg(a, b, points):
	var cumulative = PackedFloat32Array([0.0])
	for index in range(1, points.size()):
		cumulative.append(cumulative[index - 1] + points[index - 1].distance_to(points[index]))
	var leg = {
		"a": a,
		"b": b,
		"points": PackedVector3Array(points),
		"cumulative": cumulative,
		"length": max(cumulative[cumulative.size() - 1], 0.01),
		"built_a": 0.0,
		"built_b": 0.0,
	}
	leg["key"] = "{0}-{1}-{2}".format([a, b, _next_id])
	_next_id += 1
	return leg


func _register_leg(leg):
	legs[leg["key"]] = leg
	nodes[leg["a"]]["legs"].append(leg["key"])
	nodes[leg["b"]]["legs"].append(leg["key"])
	changed = true


func _remove_leg(leg):
	legs.erase(leg["key"])
	for id in [leg["a"], leg["b"]]:
		nodes[id]["legs"].erase(leg["key"])
	changed = true


func _add_node(position, is_stop):
	var id = _next_id
	_next_id += 1
	nodes[id] = {"position": Vector3(position.x, 0.0, position.z), "legs": [], "stop": is_stop}
	return id


func _dijkstra(source):
	"""[distance by node, previous [node, leg key] by node] over the whole network"""
	var distance = {source: 0.0}
	var previous = {}
	var open = [source]
	var done = {}
	while not open.is_empty():
		var best = 0
		for index in range(open.size()):
			if distance[open[index]] < distance[open[best]]:
				best = index
		var id = open[best]
		open.remove_at(best)
		if id in done:
			continue
		done[id] = true
		for key in nodes[id]["legs"]:
			var leg = legs[key]
			var other = leg["b"] if leg["a"] == id else leg["a"]
			var d = distance[id] + leg["length"]
			if d < distance.get(other, INF):
				distance[other] = d
				previous[other] = [id, key]
				open.append(other)
	return [distance, previous]


func _path_from(from_node, found):
	"""the pieces from 'from_node' to the source of a _dijkstra result"""
	var previous = found[1]
	var pieces = []
	var at = from_node
	while at in previous:
		var step = previous[at]
		var leg = legs[step[1]]
		pieces.append([leg, leg["a"] != at])  # leg runs a -> b; reversed when we start at b
		at = step[0]
	return pieces


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------


func _smooth_path(from, to):
	"""the terrain navigation path between two points, straightened (corners cut) and
	rounded into gentle curves, sampled every SAMPLE_M metres"""
	var map = _terrain_map()
	var path = PackedVector3Array()
	if map.is_valid():
		path = NavigationServer3D.map_get_path(map, from, to, true)
	var flat = []
	for point in path:
		var p = Vector3(point.x, 0.0, point.z)
		if flat.is_empty() or flat[flat.size() - 1].distance_to(p) > 0.05:
			flat.append(p)
	if flat.size() < 2 or flat[0].distance_to(from) > 3.0:
		flat = [Vector3(from.x, 0, from.z), Vector3(to.x, 0, to.z)]
	flat[0] = Vector3(from.x, 0, from.z)
	flat[flat.size() - 1] = Vector3(to.x, 0, to.z)
	flat = _simplify(flat, 0.6)
	for _i in range(3):
		flat = _chaikin(flat)
	return _resample(flat, SAMPLE_M)


static func _simplify(points, epsilon):
	"""Ramer-Douglas-Peucker"""
	if points.size() < 3:
		return points
	var first = points[0]
	var last = points[points.size() - 1]
	var worst = 0
	var worst_d = 0.0
	for index in range(1, points.size() - 1):
		var d = _point_to_segment(points[index], first, last)
		if d > worst_d:
			worst = index
			worst_d = d
	if worst_d <= epsilon:
		return [first, last]
	var left = _simplify(points.slice(0, worst + 1), epsilon)
	var right = _simplify(points.slice(worst), epsilon)
	return left.slice(0, left.size() - 1) + right


static func _chaikin(points):
	if points.size() < 3:
		return points
	var out = [points[0]]
	for index in range(points.size() - 1):
		var a = points[index]
		var b = points[index + 1]
		if index > 0:
			out.append(a.lerp(b, 0.25))
		if index < points.size() - 2:
			out.append(a.lerp(b, 0.75))
	out.append(points[points.size() - 1])
	return out


static func _resample(points, step):
	var out = [points[0]]
	var carry = 0.0
	for index in range(1, points.size()):
		var a = points[index - 1]
		var b = points[index]
		var span = a.distance_to(b)
		var t = step - carry
		while t < span:
			out.append(a.lerp(b, t / span))
			t += step
		carry = span - (t - step)
	if out[out.size() - 1].distance_to(points[points.size() - 1]) > 0.05:
		out.append(points[points.size() - 1])
	return out


static func _point_to_segment(p, a, b):
	var ab = b - a
	var length_sq = ab.length_squared()
	if length_sq < 0.000001:
		return p.distance_to(a)
	var t = clamp((p - a).dot(ab) / length_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _snap_to_terrain(point):
	var map = _terrain_map()
	if not map.is_valid():
		return point
	var closest = NavigationServer3D.map_get_closest_point(map, point)
	return Vector3(closest.x, 0.0, closest.z)


func _terrain_map():
	var match_node = _logistics.find_parent("Match")
	if match_node == null or match_node.navigation == null:
		return RID()
	return match_node.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)


static func _distance(a, b):
	return (a * Vector3(1, 0, 1)).distance_to(b * Vector3(1, 0, 1))
