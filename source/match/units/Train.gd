extends "res://source/match/units/Unit.gd"

# Freight train. It costs more than a truck but carries four truckloads, runs twice as
# fast and needs no driver's attention: it runs a loop from its depot (a command center)
# through up to a few extractors or storage yards and back, picking up whatever waits
# there. It needs track: the first time it runs a leg it lays rail as it goes, slowly,
# paying the track cost (data/logistics.json) metre by metre from the stock, and waits
# when the stock runs dry. After that the leg is built and every train runs it at full
# speed. Trains do not use the navigation agents of other units: they run on their
# rails, and an avoidance obstacle makes trucks and soldiers step out of the way.
#
# A new train plans its own line (Logistics.plan_train_line). Right-clicking an own
# extractor or storage with a train selected adds or removes that stop, and the line
# is then the player's until they ask for an automatic one again.

enum State { IDLE, TRAVELLING, STOPPED }

const STATUS_NO_LINE = "TRAIN_STATUS_NO_LINE"
const RADIUS_M = 0.8
const WAGONS = 3
const WAGON_SPACING_M = 1.75
const TRAIL_STEP_M = 0.15
const REPLAN_INTERVAL_S = 3.0

var is_train = true
var cargo = {}
var cargo_capacity = null
var automated = true
var manual_line = false
var stops = []  # extractors and storage yards, in the order they are visited
var depot = null
var recycling = false
var status_key = STATUS_NO_LINE
var status_args = []
var trips = 0

var _state = State.IDLE
var _route = []  # [depot, stop, stop, ...]; the train heads for _route[_index]
var _index = 0
var _leg = null
var _reversed = false
var _t = 0.0  # metres along the current leg, in the direction of travel
var _stop_left_s = 0.0
var _replan_left_s = 0.0
var _track_owed = {}  # fractional track cost not paid yet
var _trail = []  # recent head positions, newest first, for the wagons
var _velocity = Vector3.ZERO

@onready var _wagons = find_child("Wagons")
@onready var _avoidance = find_child("Avoidance")


func _ready():
	await super()
	if _wagons != null:
		_wagons.top_level = true
		Utils.Match.traverse_node_tree_and_replace_materials_matching_albedo(
			_wagons,
			MATERIAL_ALBEDO_TO_REPLACE,
			MATERIAL_ALBEDO_TO_REPLACE_EPSILON,
			player.get_color_material()
		)
	if _avoidance != null and _match.navigation != null:
		_avoidance.set_navigation_map(
			_match.navigation.get_navigation_map_rid_by_domain(
				Constants.Match.Navigation.Domain.TERRAIN
			)
		)
	global_position.y = 0.0
	_place_wagons()


func _get_radius():
	return RADIUS_M


func _get_movement_domain():
	return Constants.Match.Navigation.Domain.TERRAIN


func _handle_unit_death():
	if player != null:
		MatchSignals.route_raided.emit(player, global_position)
	super()


func get_cargo_total():
	return Utils.Dict.sum(cargo)


func get_free_capacity():
	return cargo_capacity - get_cargo_total()


func get_lootable_cargo():
	return cargo


func get_speed():
	var speed = float(Constants.Match.Units.SPEEDS.get(_scene_path(), 6.0))
	var weather = _match.get_node_or_null("WeatherEffects") if _match != null else null
	if weather != null:
		speed *= weather.get_speed_multiplier(global_position, movement_domain)
	return speed


func is_serving(source):
	return source in stops


func has_line():
	return not stops.is_empty() and depot != null and is_instance_valid(depot)


func set_line(new_stops, by_player = false):
	stops = new_stops.filter(func(stop): return is_instance_valid(stop))
	if by_player:
		manual_line = true
	_restart_route()


func toggle_stop(source):
	"""the player's right-click on an own extractor or storage"""
	var new_stops = stops.duplicate()
	if source in new_stops:
		new_stops.erase(source)
	else:
		new_stops.append(source)
	set_line(new_stops, true)


func use_automatic_line():
	manual_line = false
	automated = true
	stops = []
	_replan_left_s = 0.0
	_restart_route()


func get_status_text():
	return tr(status_key).format(status_args)


func _physics_process(delta):
	if not is_inside_tree() or player == null or player.logistics == null:
		return
	match _state:
		State.IDLE:
			_think_idle(delta)
		State.TRAVELLING:
			_travel(delta)
		State.STOPPED:
			_stop_left_s -= delta
			if _stop_left_s <= 0.0:
				_depart()
	if _avoidance != null:
		_avoidance.velocity = _velocity


func _think_idle(delta):
	_velocity = Vector3.ZERO
	if recycling:
		player.logistics.fleet.complete_recycle(self)
		return
	_replan_left_s -= delta
	if _replan_left_s > 0.0:
		return
	_replan_left_s = REPLAN_INTERVAL_S
	if not has_line() and automated and not manual_line:
		var line = player.logistics.rails.plan_line(self)
		if not line.is_empty():
			stops = line
	_restart_route()


func _restart_route():
	stops = stops.filter(
		func(stop):
			return is_instance_valid(stop) and stop.is_inside_tree() and stop.player == player
	)
	if depot == null or not is_instance_valid(depot) or not depot.is_inside_tree():
		depot = player.logistics.closest_depot(global_position)
	if not has_line():
		_state = State.IDLE
		_leg = null
		status_key = STATUS_NO_LINE
		status_args = []
		action_updated.emit()
		return
	_route = [depot] + stops
	# start with whichever stop of the loop is closest, so a re-planned train does not
	# drive back across the map first
	var closest = 0
	for index in range(_route.size()):
		if (
			_route[index].global_position_yless.distance_to(global_position_yless)
			< _route[closest].global_position_yless.distance_to(global_position_yless)
		):
			closest = index
	_index = closest
	_leg = null
	_state = State.TRAVELLING
	_begin_leg_from_here()


func _begin_leg_from_here():
	"""joins the line: a straight run of new track from wherever the train stands"""
	var target = _route[_index]
	if global_position_yless.distance_to(target.global_position_yless) <= target.radius + 3.0:
		_arrive()
		return
	_leg = player.logistics.rails.get_leg_from_point(global_position, target)
	_reversed = false
	_t = 0.0


func _depart():
	if _route.is_empty():
		_restart_route()
		return
	var from = _route[_index]
	_index = (_index + 1) % _route.size()
	var to = _route[_index]
	if not is_instance_valid(from) or not is_instance_valid(to):
		_restart_route()
		return
	var found = player.logistics.rails.get_leg(from, to)
	_leg = found[0]
	_reversed = found[1]
	_t = 0.0
	_state = State.TRAVELLING


func _travel(delta):
	if _leg == null:
		_restart_route()
		return
	var length = _leg["length"]
	var speed = get_speed()
	var laying = not _is_built_ahead(_t)
	if laying:
		speed = float(Constants.Match.Logistics.TRAIN.get("laying_speed", 1.4))
	var step = min(speed * delta, length - _t)
	if laying and step > 0.0 and not _lay_track(step):
		_velocity = Vector3.ZERO
		status_key = "TRAIN_STATUS_WAITING_FOR_TRACK"
		status_args = [_track_cost_text()]
		return
	var before = global_position
	_t += step
	_move_to(_point_at(_t))
	_velocity = (global_position - before) / max(delta, 0.0001)
	if laying:
		status_key = "TRAIN_STATUS_LAYING"
		status_args = [int(ceil(_unbuilt_m()))]
	else:
		status_key = "TRAIN_STATUS_RUNNING"
		status_args = [_name_of(_route[_index])]
	if _t >= length - 0.01:
		_arrive()


func _arrive():
	_velocity = Vector3.ZERO
	var stop = _route[_index]
	if not is_instance_valid(stop) or not stop.is_inside_tree():
		_restart_route()
		return
	if stop == depot:
		if not cargo.is_empty():
			trips += 1
			player.logistics.deliver(cargo)
			cargo = {}
		if recycling:
			player.logistics.fleet.complete_recycle(self)
			return
		status_key = "TRAIN_STATUS_UNLOADING"
		status_args = []
	elif not recycling:
		var amount = min(stop.get_available_for_pickup(), get_free_capacity())
		if amount > 0:
			var goods = stop.take_goods(amount)
			for resource in goods:
				Utils.Dict.add_amount(cargo, resource, goods[resource])
				var stats = player.logistics.get_route_stats(stop)
				stats["delivered"] += goods[resource]
				stats["trips"] += 1
		status_key = "TRAIN_STATUS_LOADING"
		status_args = [_name_of(stop)]
	_state = State.STOPPED
	_stop_left_s = float(Constants.Match.Logistics.TRAIN.get("stop_s", 2.5))
	action_updated.emit()


func _is_built_ahead(t):
	var length = _leg["length"]
	var near_end = _leg["built_b"] if not _reversed else _leg["built_a"]
	var from_start = _leg["built_a"] if not _reversed else _leg["built_b"]
	return t + 0.05 <= from_start or t >= length - near_end - 0.05


func _unbuilt_m():
	return max(0.0, _leg["length"] - _leg["built_a"] - _leg["built_b"])


func _lay_track(step):
	"""pays for 'step' metres of rail; false when the stock cannot cover it"""
	var cost = Constants.Match.Logistics.TRAIN.get("track_cost_per_10_m", {})
	var due = {}
	for resource in cost:
		var owed = _track_owed.get(resource, 0.0) + float(cost[resource]) * step / 10.0
		var whole = int(floor(owed))
		if whole > 0:
			due[resource] = whole
	if not due.is_empty():
		if not player.has_resources(due):
			return false
		player.subtract_resources(due)
		player.logistics.rails.note_track_spent(due)
	for resource in cost:
		_track_owed[resource] = (
			_track_owed.get(resource, 0.0)
			+ float(cost[resource]) * step / 10.0
			- due.get(resource, 0)
		)
	var key = "built_a" if not _reversed else "built_b"
	_leg[key] = max(_leg[key], _t + step)
	if _leg["built_a"] + _leg["built_b"] >= _leg["length"]:
		_leg["built_a"] = _leg["length"]
	player.logistics.rails.changed = true
	return true


func _track_cost_text():
	var parts = []
	var cost = Constants.Match.Logistics.TRAIN.get("track_cost_per_10_m", {})
	for resource in cost:
		parts.append("{0} {1}".format([cost[resource], tr(resource.to_upper())]))
	return ", ".join(parts)


func _point_at(t):
	var points = _leg["points"]
	var cumulative = _leg["cumulative"]
	var length = _leg["length"]
	if _reversed:
		t = length - t
	t = clamp(t, 0.0, length)
	for index in range(1, points.size()):
		if cumulative[index] >= t:
			var span = cumulative[index] - cumulative[index - 1]
			var weight = (t - cumulative[index - 1]) / span if span > 0.0 else 1.0
			return points[index - 1].lerp(points[index], weight)
	return points[points.size() - 1]


func _move_to(point):
	var flat = Vector3(point.x, 0.0, point.z)
	var direction = flat - global_position * Vector3(1, 0, 1)
	global_position = flat
	if direction.length_squared() > 0.0001:
		look_at(flat + direction, Vector3.UP)
	_record_trail()
	_place_wagons()


func _record_trail():
	if _trail.is_empty() or _trail[0].distance_to(global_position) >= TRAIL_STEP_M:
		_trail.push_front(global_position)
		var max_points = int((WAGONS + 1) * WAGON_SPACING_M / TRAIL_STEP_M) + 4
		if _trail.size() > max_points:
			_trail.resize(max_points)


func _place_wagons():
	if _wagons == null:
		return
	var index = 0
	for wagon in _wagons.get_children():
		index += 1
		var wanted = index * WAGON_SPACING_M
		var position = _trail_point(wanted)
		var ahead = _trail_point(wanted - WAGON_SPACING_M * 0.5)
		wagon.global_position = position
		if ahead.distance_squared_to(position) > 0.0001:
			wagon.look_at(ahead, Vector3.UP)
		else:
			wagon.global_rotation = global_rotation


func _trail_point(distance_back):
	"""a point 'distance_back' metres behind the locomotive along where it has been"""
	var behind = global_transform.basis.z  # the locomotive faces -Z
	if _trail.size() < 2:
		return global_position + behind * distance_back
	var walked = 0.0
	for index in range(1, _trail.size()):
		var span = _trail[index - 1].distance_to(_trail[index])
		if walked + span >= distance_back:
			return _trail[index - 1].lerp(
				_trail[index], (distance_back - walked) / max(span, 0.0001)
			)
		walked += span
	var last = _trail[_trail.size() - 1]
	return last + behind * (distance_back - walked)


static func _name_of(unit):
	if not is_instance_valid(unit):
		return ""  # the stop was destroyed this frame; the route is rebuilt on arrival
	var entry = GameData.unit_by_scene(unit._scene_path())
	return TranslationServer.translate(entry["name"]) if entry != null else str(unit.name)
