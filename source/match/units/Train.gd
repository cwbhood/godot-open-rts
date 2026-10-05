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
const RADIUS_M = 1.2
const WAGONS = 3
const FIRST_WAGON_M = 3.0  # locomotive centre to the first wagon's centre
const WAGON_SPACING_M = 2.6
const HornSound = preload("res://assets/audio/trains/horn.ogg")
const HudStyle = preload("res://source/match/hud/HudStyle.gd")
const TRAIL_STEP_M = 0.15
const REPLAN_INTERVAL_S = 3.0
const ACCELERATION = 1.2  # m/s per second
const DECELERATION = 1.6

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
var _node = null  # the rail node the train stands at or last passed
var _pieces = []  # [[leg, reversed], ...] still to run after _leg on the way to the stop
var _replan_at_node = false  # the line changed: plan again at the end of this leg
var _speed = 0.0
var _leg = null
var _reversed = false
var _t = 0.0  # metres along the current leg, in the direction of travel
var _stop_left_s = 0.0
var _replan_left_s = 0.0
var _track_owed = {}  # fractional track cost not paid yet
var _trail = []  # recent head positions, newest first, for the wagons
var _velocity = Vector3.ZERO
var _cargo_meshes = []  # each wagon's load: a mound that fills and takes the goods' colour
var _cargo_material = null
var _smoke = null
var _horn = null

var _pushing = false  # running wagons first, the locomotive pushing from the back

@onready var _wagons = find_child("Wagons")
@onready var _locomotive = find_child("Geometry")
@onready var _avoidance = find_child("Avoidance")


func _ready():
	await super()
	if _locomotive != null:
		_locomotive.top_level = true
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
	GameData.use_vertex_colours(self)
	_setup_cargo_looks()
	_setup_smoke()
	_horn = AudioStreamPlayer3D.new()
	_horn.stream = HornSound
	_horn.bus = "Effects"
	_horn.unit_size = 18.0
	_horn.max_db = -2.0
	add_child(_horn)
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
	_update_smoke()


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
		if _state == State.TRAVELLING and _leg != null:
			_pieces = []
			_replan_at_node = true  # roll on to the next node, then wait there
			return
		_state = State.IDLE
		_leg = null
		status_key = STATUS_NO_LINE
		status_args = []
		action_updated.emit()
		return
	_route = [depot] + stops
	var rails = player.logistics.rails
	if _node == null or not _node in rails.nodes:
		# a new train rolls out of its depot onto the depot's platform
		_node = rails.node_for_stop(depot, stops[0].global_position)
		_move_to(rails.nodes[_node]["position"])
		_trail.clear()
		_place_wagons()
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
	if _state == State.TRAVELLING and _leg != null:
		_pieces = []
		_replan_at_node = true
		return
	_plan_to_stop()


func _plan_to_stop():
	"""sets off from the node the train stands at towards _route[_index]"""
	_replan_at_node = false
	var target = _route[_index]
	if not is_instance_valid(target) or not target.is_inside_tree():
		_restart_route()
		return
	var rails = player.logistics.rails
	var target_node = rails.node_for_stop(target, rails.nodes[_node]["position"])
	_pieces = rails.route(_node, target_node)
	if _pieces.is_empty():
		_arrive()
		return
	_state = State.TRAVELLING
	_next_piece()


func _next_piece():
	var piece = _pieces.pop_front()
	var resolved = player.logistics.rails.resolve_piece(piece[0], piece[1])
	_pieces = resolved.slice(1) + _pieces
	var previous = _leg
	_leg = resolved[0][0]
	_reversed = resolved[0][1]
	_t = 0.0
	var heading = -global_transform.basis.z * Vector3(1, 0, 1)
	if heading.dot(_point_at(0.6) - _point_at(0.0)) < -0.05:
		_reverse(previous == _leg)


func _reverse(retracing):
	"""the line runs back the way the train came: rather than turning round, it runs the
	other way with the locomotive at the other end of the train (push-pull), so the
	carriages stay where they stand"""
	_pushing = not _pushing
	_speed = 0.0
	var length = _consist_length_m()
	var new_trail = []
	var walked = 0.0
	for index in range(_trail.size()):
		if index > 0:
			walked += _trail[index - 1].distance_to(_trail[index])
		new_trail.push_front(_trail[index])
		if walked >= length:
			break
	if retracing and walked >= length - 0.2:
		# the new front of the train is already this far down the track
		_t = min(length, _leg["length"] - 0.05)
		_trail = new_trail
		global_position = _point_at(_t)
		look_at(global_position + (_point_at(_t + 0.3) - _point_at(_t)), Vector3.UP)
	else:
		_trail.clear()
		global_position = _point_at(0.0)
		look_at(global_position + (_point_at(0.6) - _point_at(0.0)), Vector3.UP)
	_place_wagons()


func _consist_length_m():
	return FIRST_WAGON_M + (WAGONS - 1) * WAGON_SPACING_M


func _depart():
	if _route.is_empty():
		_restart_route()
		return
	if _horn != null and _horn.is_inside_tree() and visible:
		_horn.pitch_scale = randf_range(0.96, 1.04)
		_horn.play()
	_index = (_index + 1) % _route.size()
	_plan_to_stop()


func _travel(delta):
	if _leg == null:
		_restart_route()
		return
	if "dead" in _leg:  # a branch joined the track under the train: it is two legs now
		var resolved = player.logistics.rails.resolve_position(_leg, _reversed, _t)
		_leg = resolved[0]
		_reversed = resolved[1]
		_t = resolved[2]
		if not _replan_at_node:
			_pieces = resolved[3] + _pieces
	var length = _leg["length"]
	var laying = not _is_built_ahead(_t)
	var top_speed = get_speed()
	if laying:
		top_speed = float(Constants.Match.Logistics.TRAIN.get("laying_speed", 1.4))
	# speed up gently and brake in time for the next stop
	var ahead_m = length - _t
	if not _replan_at_node:
		for piece in _pieces:
			ahead_m += piece[0]["length"]
	var braking = sqrt(2.0 * DECELERATION * max(ahead_m - 0.2, 0.0)) + 0.4
	var wanted = min(top_speed, braking)
	if _speed < wanted:
		_speed = min(wanted, _speed + ACCELERATION * delta)
	else:
		_speed = max(wanted, _speed - DECELERATION * 2.0 * delta)
	var step = min(_speed * delta, length - _t)
	if laying and step > 0.0 and not _lay_track(step):
		_velocity = Vector3.ZERO
		_speed = 0.0
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
	elif _route.size() > _index:
		status_key = "TRAIN_STATUS_RUNNING"
		status_args = [_name_of(_route[_index])]
	if _t >= length - 0.01:
		_node = player.logistics.rails.end_node(_leg, _reversed)
		if _replan_at_node:
			_leg = null
			if has_line():
				_plan_to_stop()
			else:
				_restart_route()
		elif not _pieces.is_empty():
			_next_piece()
		else:
			_arrive()


func _arrive():
	_velocity = Vector3.ZERO
	_speed = 0.0
	var stop = _route[_index]
	if not is_instance_valid(stop) or not stop.is_inside_tree():
		_leg = null
		_state = State.IDLE
		_restart_route()
		return
	if stop == depot:
		if not cargo.is_empty():
			trips += 1
			player.logistics.deliver(cargo)
			cargo = {}
			_show_cargo()
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
			_show_cargo()
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
	if _leg["built_a"] + _leg["built_b"] >= _leg["length"] - 0.05:
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
		var max_points = int((_consist_length_m() + 2.0) / TRAIL_STEP_M) + 4
		if _trail.size() > max_points:
			_trail.resize(max_points)


func _place_wagons():
	"""puts the locomotive and the wagons along the track behind the front of the train"""
	if _wagons == null or _locomotive == null:
		return
	var cars = [_locomotive] + _wagons.get_children()
	var offsets = [0.0]
	for index in range(1, cars.size()):
		offsets.append(FIRST_WAGON_M + (index - 1) * WAGON_SPACING_M)
	if _pushing:  # the last wagon leads; mirror the offsets
		var total = offsets[offsets.size() - 1]
		offsets = offsets.map(func(offset): return total - offset)
	for index in range(cars.size()):
		var car = cars[index]
		var position = _trail_point(offsets[index])
		var ahead = _trail_point(offsets[index] - 0.6)
		car.global_position = position
		var facing = ahead - position
		if car == _locomotive and _pushing:
			facing = -facing  # its nose points to the back of the train
		if facing.length_squared() > 0.0001:
			car.look_at(position + facing, Vector3.UP)
		else:
			car.global_rotation = global_rotation


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


func _setup_cargo_looks():
	if _wagons == null:
		return
	_cargo_material = StandardMaterial3D.new()
	_cargo_material.roughness = 0.95
	for wagon in _wagons.get_children():
		var mesh = wagon.find_child("Cargo", true, false)
		if mesh is MeshInstance3D:
			mesh.material_override = _cargo_material
			_cargo_meshes.append(mesh)
	_show_cargo()


func _show_cargo():
	"""fills the wagons front to back with the load, coloured like the main good"""
	if _cargo_meshes.is_empty():
		return
	var total = get_cargo_total()
	var main = null
	for resource in cargo:
		if main == null or cargo[resource] > cargo[main]:
			main = resource
	if main != null:
		_cargo_material.albedo_color = HudStyle.resource_color(main).darkened(0.15)
	var per_wagon = float(cargo_capacity if cargo_capacity != null else 40) / _cargo_meshes.size()
	var left = float(total)
	for mesh in _cargo_meshes:
		var fill = clamp(left / per_wagon, 0.0, 1.0)
		left -= per_wagon
		mesh.visible = fill > 0.02
		mesh.scale = Vector3(1.0, 0.35 + 0.65 * fill, 1.0)


func _setup_smoke():
	var exhaust = find_child("Exhaust", true, false)
	if exhaust == null:
		return
	_smoke = CPUParticles3D.new()
	_smoke.amount = 14
	_smoke.lifetime = 2.2
	_smoke.local_coords = false
	_smoke.direction = Vector3.UP
	_smoke.spread = 12.0
	_smoke.gravity = Vector3(0.3, 0.6, 0.0)
	_smoke.initial_velocity_min = 0.6
	_smoke.initial_velocity_max = 1.0
	_smoke.scale_amount_min = 0.25
	_smoke.scale_amount_max = 0.45
	var curve = Curve.new()
	curve.add_point(Vector2(0.0, 0.4))
	curve.add_point(Vector2(1.0, 1.6))
	_smoke.scale_amount_curve = curve
	var gradient = Gradient.new()
	gradient.set_color(0, Color(0.25, 0.24, 0.23, 0.55))
	gradient.set_color(1, Color(0.6, 0.58, 0.55, 0.0))
	_smoke.color_ramp = gradient
	var puff = SphereMesh.new()
	puff.radius = 0.5
	puff.height = 1.0
	puff.radial_segments = 6
	puff.rings = 3
	var material = StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	puff.material = material
	_smoke.mesh = puff
	_smoke.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	exhaust.add_child(_smoke)


func _update_smoke():
	if _smoke == null:
		return
	var working = _state == State.TRAVELLING and _speed > 0.05
	_smoke.emitting = working or _state == State.STOPPED
	_smoke.speed_scale = 1.4 if working and _speed < get_speed() * 0.9 else 1.0


static func _name_of(unit):
	var entry = GameData.unit_by_scene(unit._scene_path())
	return TranslationServer.translate(entry["name"]) if entry != null else str(unit.name)
