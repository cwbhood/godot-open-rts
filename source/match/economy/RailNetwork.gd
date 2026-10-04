extends RefCounted

# The player's railway, kept by Logistics (logistics.rails): the track legs trains run
# on and how much of each is built, plus the planning of train lines. A leg is the track
# between two stops (a depot, an extractor or a storage), following the terrain
# navigation path around obstacles. It is made unbuilt the first time a train needs it;
# trains lay it from either end (built_a from the first stop, built_b from the other)
# and it is complete once the two meet. See Train.gd.

const Storage = preload("res://source/match/units/Storage.gd")

var legs = {}  # "id:id" -> {points, cumulative, length, built_a, built_b, from_id}
var changed = false  # set when track was laid, RailVisuals redraws
var track_spent_total = {}  # statistics

var _logistics = null


func _init(logistics):
	_logistics = logistics


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
		var near = chosen.any(
			func(stop):
				return _distance(stop.global_position, candidate[1].global_position) <= max_leg
		)
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


func get_leg(from_unit, to_unit):
	"""[leg, reversed]: the track between two stops, made on first use (unbuilt)"""
	var a = from_unit.get_instance_id()
	var b = to_unit.get_instance_id()
	var key = "{0}:{1}".format([min(a, b), max(a, b)])
	if key in legs:
		return [legs[key], legs[key]["from_id"] != a]
	var leg = _make_leg(
		_edge_point(from_unit, to_unit.global_position),
		_edge_point(to_unit, from_unit.global_position)
	)
	leg["from_id"] = a
	legs[key] = leg
	return [leg, false]


func get_leg_from_point(point, to_unit):
	"""a spur from where a train stands to its first stop"""
	var key = "{0}:{1}".format([point.snapped(Vector3.ONE * 2.0), to_unit.get_instance_id()])
	if not key in legs:
		legs[key] = _make_leg(point, _edge_point(to_unit, point))
		legs[key]["from_id"] = -1
	return legs[key]


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


func _make_leg(from, to):
	var map = _terrain_map()
	var path = PackedVector3Array()
	if map.is_valid():
		path = NavigationServer3D.map_get_path(map, from, to, true)
	if path.size() < 2:
		path = PackedVector3Array([from, to])
	var points = PackedVector3Array()
	for point in path:
		var flat = Vector3(point.x, 0.0, point.z)
		if points.is_empty() or points[points.size() - 1].distance_to(flat) > 0.05:
			points.append(flat)
	if points.size() < 2:
		points.append(Vector3(to.x, 0.0, to.z) + Vector3(0.01, 0, 0))
	var cumulative = PackedFloat32Array([0.0])
	for index in range(1, points.size()):
		cumulative.append(cumulative[index - 1] + points[index - 1].distance_to(points[index]))
	return {
		"points": points,
		"cumulative": cumulative,
		"length": cumulative[cumulative.size() - 1],
		"built_a": 0.0,
		"built_b": 0.0,
	}


func _edge_point(unit, towards):
	var direction = (towards - unit.global_position) * Vector3(1, 0, 1)
	if direction.length_squared() < 0.0001:
		direction = Vector3(1, 0, 0)
	return unit.global_position_yless + direction.normalized() * (unit.radius + 1.2)


func _terrain_map():
	var match_node = _logistics.find_parent("Match")
	if match_node == null or match_node.navigation == null:
		return RID()
	return match_node.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)


static func _distance(a, b):
	return (a * Vector3(1, 0, 1)).distance_to(b * Vector3(1, 0, 1))
