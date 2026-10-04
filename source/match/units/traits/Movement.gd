extends NavigationAgent3D

signal movement_finished
signal passive_movement_started
signal passive_movement_finished

const INITIAL_DISPERSION_FACTOR = 0.1

const STUCK_PREVENTION_ENABLED = true
const STUCK_PREVENTION_WINDOW_SIZE = 10  # number of frames for accumulating distance traveled
const STUCK_PREVENTION_THRESHOLD = 0.3  # fraction of expected distance traveled at full speed
const STUCK_PREVENTION_SIDE_MOVES = 15  # number of forced moves to the side if stuck

const ROTATION_LOW_PASS_FILTER_ENABLED = true
const ROTATION_LOW_PASS_FILTER_WINDOW_SIZE = 10  # number of frames for accumulating directions
const ROTATION_LOW_PASS_FILTER_VELOCITY_THRESHOLD = 0.01  # velocities below will be dropped

const PASSIVE_MOVEMENT_TRACKING_ENABLED = true

# Crowd steering (data/movement.json, "crowd_steering"): avoidance works in m/s so units
# actually see each other coming, path queries are capped per frame, crowded destinations are
# spread out, units blocked near their destination stop pushing, stuck units re-path and give
# up eventually, and pushed units are kept on the navmesh. With it off, units move as before.
const GameData = preload("res://source/data-model/GameData.gd")
const DEFAULT_SETTINGS = {
	"crowd_steering": true,
	"avoidance_time_horizon_s": 1.5,
	"avoidance_neighbor_distance_m": 6.0,
	"avoidance_max_neighbors": 12,
	"avoidance_radius_padding_m": 0.0,
	"path_max_distance_m": 1.5,
	"path_requests_per_frame": 24,
	"spread_crowded_destinations": true,
	"destination_spacing_m": 0.4,
	"arrival_slack_radii": 4.0,
	"arrival_blocked_s": 1.0,
	"repath_when_stuck_s": 2.0,
	"give_up_when_stuck_s": 30.0,
	"keep_on_navmesh_every_ticks": 6,
	"parked_units_make_way": true,
}
const PROGRESS_EPSILON_M = 0.05
const MOVING_PRIORITY = 1.0
const PARKED_PRIORITY = 0.5
const SPOT_SEARCH_RINGS = 6
const ON_NAVMESH_TOLERANCE_M = 0.2

static var _settings = null
static var _path_budget_frame = -1
static var _path_budget_left = 0
static var _idle_units = {}
static var _idle_units_frame = -1
static var _claims = {}  # instance id -> [unit, destination] of units heading to a picked spot

@export var domain = Constants.Match.Navigation.Domain.TERRAIN
@export var speed: float = 4.0

var _interim_speed: float = 0.0

var _stuck_prevention_window = []
var _total_velocity_in_stuck_prevention_window = 0.0
var _number_of_forced_side_moves_left = 0

var _rotation_low_pass_filter_window = []
var _total_direction_in_the_low_pass_filter_window = Vector3.ZERO
var _previously_set_global_transform_of_unit = null

var _passive_movement_detected = false
var _weather = null

var _crowd = false
var _pending_target = null
var _best_distance = INF
var _stuck_s = 0.0
var _repathed = false
var _navmesh_tick = randi() % 64
var _moved_since_navmesh_check = true

@onready var _match = find_parent("Match")
@onready var _unit = get_parent()


func _physics_process(delta):
	if _crowd:
		_crowd_physics_process(delta)
		return
	_interim_speed = speed * get_speed_multiplier() * delta  # also caps how far a push moves
	if not _has_target():
		# idle: the velocity still has to be submitted so that avoidance can push the unit
		# aside, but asking the agent for a path to nowhere would run a path query every time
		set_velocity(Vector3.ZERO)
		return
	var fake_direction = _get_fake_direction_due_to_stuck_prevention()
	if fake_direction != null:
		set_velocity(fake_direction * _interim_speed)
		return
	var next_path_position: Vector3 = get_next_path_position()
	var current_agent_position: Vector3 = _unit.global_position
	var new_velocity: Vector3 = (
		(next_path_position - current_agent_position).normalized() * _interim_speed
	)
	set_velocity(new_velocity)


func _ready():
	if _match.navigation == null:
		await _match.ready
	velocity_computed.connect(_on_velocity_computed)
	navigation_finished.connect(_on_navigation_finished)
	set_navigation_map(_match.navigation.get_navigation_map_rid_by_domain(domain))
	_setup_crowd_steering()
	_align_unit_position_to_navigation()
	move(
		(
			_unit.global_position
			+ Vector3(randf(), 0, randf()).normalized() * INITIAL_DISPERSION_FACTOR
		)
	)


func get_speed_multiplier():
	"""weather and running out of fuel slow units down, roads speed haulers up"""
	var multiplier = 1.0
	if _weather == null or not is_instance_valid(_weather):
		_weather = _match.get_node_or_null("WeatherEffects")
	if _weather != null:
		multiplier *= _weather.get_speed_multiplier(_unit.global_position, domain)
	var logistics = _unit.player.get_node_or_null("Logistics") if "player" in _unit else null
	if logistics != null and logistics.is_unit_out_of_fuel(_unit):
		multiplier *= Constants.Match.Fuel.OUT_OF_FUEL_SPEED_FACTOR
	var road_speed_multiplier = _unit.get("road_speed_multiplier")
	if road_speed_multiplier != null:
		multiplier *= road_speed_multiplier
	return multiplier


static func settings():
	if _settings == null:
		_settings = DEFAULT_SETTINGS.duplicate()
		_settings.merge(GameData.movement(), true)
	return _settings


func move(movement_target: Vector3):
	if not _crowd:
		target_position = movement_target
		return
	_best_distance = INF
	_stuck_s = 0.0
	_repathed = false
	if _take_path_budget():
		_pending_target = null
		target_position = movement_target
	else:
		_pending_target = movement_target  # asked for its path on a later frame


func stop():
	_pending_target = null
	_release_claim()
	target_position = Vector3.INF


func free_spot_near(point: Vector3) -> Vector3:
	"""a reachable spot near point that no idle unit stands on and no other unit is heading
	to, so that a crowd sent to one place spreads out instead of fighting over it"""
	if not _crowd or not settings()["spread_crowded_destinations"]:
		return point
	var map = get_navigation_map()
	var center = NavigationServer3D.map_get_closest_point(map, point)
	var occupants = _occupants_near(center, _spot_step() * (SPOT_SEARCH_RINGS + 1))
	var step = _spot_step()
	var start_angle = (
		Vector2(_unit.global_position.x - center.x, _unit.global_position.z - center.z).angle()
	)
	# the first ring with a free spot and the one after it are both considered, and the spot
	# nearest to the unit wins: a unit should not cross a parked crowd to its far side
	var best = null
	var best_cost = INF
	var last_ring = SPOT_SEARCH_RINGS
	for ring in range(SPOT_SEARCH_RINGS + 1):
		if ring > last_ring:
			break
		var count = 1 if ring == 0 else int(ceil(TAU * ring))
		for index in range(count):
			var angle = start_angle + _alternating(index) * TAU / count
			var candidate = center + Vector3(cos(angle), 0, sin(angle)) * ring * step
			if not _is_spot_free(candidate, occupants):
				continue  # cheap test first, navmesh queries are the costly part
			var spot = _reachable(map, candidate)
			if spot == null or not _is_spot_free(spot, occupants):
				continue
			if ring == 0:
				_claim(spot)
				return spot
			var cost = ring * step + 0.5 * spot.distance_to(_unit.global_position)
			if cost < best_cost:
				best = spot
				best_cost = cost
				last_ring = min(last_ring, ring + 1)
	if best == null:
		return center
	_claim(best)
	return best


func approach_spot_for(target_unit) -> Variant:
	"""a free reachable spot next to target_unit, close enough to count as adhering to it;
	null when every side is taken"""
	if not _crowd or not settings()["spread_crowded_destinations"]:
		return null
	var map = get_navigation_map()
	var center = target_unit.global_position_yless
	var reach = target_unit.radius + radius + Constants.Match.Units.ADHERENCE_MARGIN_M - 0.05
	var ring = max(target_unit.radius + radius - target_desired_distance, target_unit.radius)
	var occupants = _occupants_near(center, reach + _spot_step() * 2.0)
	# spots snap out to the navmesh edge, which can lie further out than the ring
	var count = max(6, int(ceil(TAU * reach / _spot_step())))
	var start_angle = (
		Vector2(_unit.global_position.x - center.x, _unit.global_position.z - center.z).angle()
	)
	for index in range(count):
		var angle = start_angle + _alternating(index) * TAU / count
		var candidate = center + Vector3(cos(angle), 0, sin(angle)) * ring
		var spot = NavigationServer3D.map_get_closest_point(map, candidate)
		if (spot * Vector3(1, 0, 1)).distance_to(center) > reach:
			continue
		if _is_spot_free(spot, occupants):
			_claim(spot)
			return spot
	return null


func _align_unit_position_to_navigation():
	await get_tree().process_frame  # wait for navigation to be operational
	_unit.global_transform.origin = (
		NavigationServer3D.map_get_closest_point(
			get_navigation_map(), get_parent().global_transform.origin
		)
		- Vector3(0, path_height_offset, 0)
	)


func _has_target():
	return target_position != Vector3.INF or _pending_target != null


func _is_moving_actively():
	# stop() parks the target at infinity, which never has a path: the agent then reports the
	# unit's own position as the next one, so there is no need to ask it
	return target_position != Vector3.INF and get_next_path_position() != _unit.global_position


func _get_fake_direction_due_to_stuck_prevention():
	if (
		not STUCK_PREVENTION_ENABLED
		or _crowd  # its blind sidesteps pinned queueing units against walls; see _track_progress
		or not _is_moving_actively()
		or _number_of_forced_side_moves_left == 0
	):
		return null
	_number_of_forced_side_moves_left -= 1
	var next_path_position: Vector3 = get_next_path_position()
	var direction_to_target = (next_path_position - _unit.global_position).normalized()
	var current_navigation_path = get_current_navigation_path()
	var current_navigation_path_index = get_current_navigation_path_index()
	if current_navigation_path.size() <= 1 or current_navigation_path_index == 0:
		return direction_to_target.rotated(Vector3.UP, PI / 2.0)
	# rotate +90*/-90* and choose the one that goes further from path
	var option_a = direction_to_target.rotated(Vector3.UP, PI / 2.0)
	var option_b = direction_to_target.rotated(Vector3.UP, -PI / 2.0)
	var previous_path_position = current_navigation_path[current_navigation_path_index - 1]
	if (
		(_unit.global_position + option_a).distance_to(previous_path_position)
		> (_unit.global_position + option_b).distance_to(previous_path_position)
	):
		return option_a
	return option_b


func _update_stuck_prevention(safe_velocity: Vector3, moving_actively):
	if not moving_actively:
		return
	_stuck_prevention_window.append(safe_velocity.length())
	_total_velocity_in_stuck_prevention_window += safe_velocity.length()
	if _stuck_prevention_window.size() > STUCK_PREVENTION_WINDOW_SIZE:
		_total_velocity_in_stuck_prevention_window -= _stuck_prevention_window.pop_front()
	var stuck_prevention_threshold = (
		_interim_speed * STUCK_PREVENTION_WINDOW_SIZE * STUCK_PREVENTION_THRESHOLD
	)
	if (
		_stuck_prevention_window.size() == STUCK_PREVENTION_WINDOW_SIZE
		and _total_velocity_in_stuck_prevention_window < stuck_prevention_threshold
	):
		_number_of_forced_side_moves_left = STUCK_PREVENTION_SIDE_MOVES


func _get_filtered_rotation_direction(safe_velocity: Vector3):
	var direction = safe_velocity.normalized()
	if (
		_previously_set_global_transform_of_unit != null
		and not _previously_set_global_transform_of_unit.is_equal_approx(_unit.global_transform)
	):
		# reset filter if a global_transform of unit was altered from the outside
		_rotation_low_pass_filter_window = []
		_total_direction_in_the_low_pass_filter_window = Vector3.ZERO
	if safe_velocity.length() >= ROTATION_LOW_PASS_FILTER_VELOCITY_THRESHOLD:
		_rotation_low_pass_filter_window.append(direction)
		_total_direction_in_the_low_pass_filter_window += direction
	if _rotation_low_pass_filter_window.size() > ROTATION_LOW_PASS_FILTER_WINDOW_SIZE:
		_total_direction_in_the_low_pass_filter_window -= (
			_rotation_low_pass_filter_window.pop_front()
		)
	if _rotation_low_pass_filter_window.size() == ROTATION_LOW_PASS_FILTER_WINDOW_SIZE:
		return (
			_total_direction_in_the_low_pass_filter_window
			/ float(ROTATION_LOW_PASS_FILTER_WINDOW_SIZE)
		)
	return direction


func _rotate_in_direction(direction: Vector3):
	if ROTATION_LOW_PASS_FILTER_ENABLED:
		direction = _get_filtered_rotation_direction(direction)
	var rotation_target = _unit.global_transform.origin + direction
	if (
		not is_zero_approx(direction.length())
		and not rotation_target.is_equal_approx(_unit.global_transform.origin)
	):
		_unit.global_transform = _unit.global_transform.looking_at(rotation_target)


func _update_passive_movement_tracking(safe_velocity, moving_actively):
	if not PASSIVE_MOVEMENT_TRACKING_ENABLED:
		return
	if moving_actively or safe_velocity.is_zero_approx():
		if _passive_movement_detected:
			_passive_movement_detected = false
			passive_movement_finished.emit()
		return
	if not _passive_movement_detected:
		_passive_movement_detected = true
		passive_movement_started.emit()


func _on_velocity_computed(safe_velocity: Vector3):
	var moving_actively = _is_moving_actively()
	if not moving_actively and safe_velocity.is_zero_approx():
		# an idle unit nobody pushes: nothing moves, so skip touching its transform
		_update_passive_movement_tracking(safe_velocity, moving_actively)
		return
	var step = safe_velocity
	if _crowd:
		# avoidance works in m/s here: turn the velocity into this tick's displacement
		step = safe_velocity * get_physics_process_delta_time()
	if not _crowd:
		_update_stuck_prevention(step, moving_actively)
	_rotate_in_direction(step * Vector3(1, 0, 1))
	var origin = _unit.global_position
	_unit.global_position = origin.move_toward(origin + step, _interim_speed)
	_moved_since_navmesh_check = true
	_previously_set_global_transform_of_unit = _unit.global_transform
	_update_passive_movement_tracking(safe_velocity, moving_actively)


func _on_navigation_finished():
	_release_claim()
	target_position = Vector3.INF
	movement_finished.emit()


# crowd steering ----------------------------------------------------------------------------


func _setup_crowd_steering():
	var tunables = settings()
	_crowd = tunables["crowd_steering"]
	if not _crowd:
		return
	time_horizon_agents = tunables["avoidance_time_horizon_s"]
	neighbor_distance = tunables["avoidance_neighbor_distance_m"]
	max_neighbors = int(tunables["avoidance_max_neighbors"])
	path_max_distance = max(path_max_distance, tunables["path_max_distance_m"])
	# a little more room than the gameplay radius, so hulls don't brush; the radius itself
	# stays as it is because adherence, placement and attack ranges are measured with it
	NavigationServer3D.agent_set_radius(get_rid(), radius + tunables["avoidance_radius_padding_m"])


func _crowd_physics_process(delta):
	var full_speed = speed * get_speed_multiplier()
	_interim_speed = full_speed * delta  # also caps how far a push moves
	if not is_equal_approx(max_speed, full_speed):
		max_speed = full_speed
	if _pending_target != null and _take_path_budget():
		target_position = _pending_target
		_pending_target = null
	_keep_on_navmesh()
	# units on the move don't steer around parked ones, the parked ones make way instead:
	# otherwise a parked crowd (at a rally point, say) walls in every newcomer
	var priority = MOVING_PRIORITY if target_position != Vector3.INF else PARKED_PRIORITY
	if avoidance_priority != priority and settings()["parked_units_make_way"]:
		avoidance_priority = priority
	if target_position == Vector3.INF:
		set_velocity(Vector3.ZERO)  # idle: avoidance can still push the unit aside
		return
	if _track_progress(delta):
		return
	var next_path_position: Vector3 = get_next_path_position()
	set_velocity((next_path_position - _unit.global_position).normalized() * full_speed)


func _track_progress(delta):
	"""stops units that keep pushing into a crowd at their destination, re-paths and finally
	gives up on units that make no progress at all; returns true when movement was ended"""
	var tunables = settings()
	var distance = _unit.global_position_yless.distance_to(target_position * Vector3(1, 0, 1))
	if distance < _best_distance - PROGRESS_EPSILON_M:
		_best_distance = distance
		_stuck_s = 0.0
		_repathed = false
		return false
	_stuck_s += delta
	if (
		distance <= radius * tunables["arrival_slack_radii"]
		and _stuck_s >= tunables["arrival_blocked_s"]
	):
		_on_navigation_finished()  # close enough, the spot is taken
		return true
	if _stuck_s >= tunables["give_up_when_stuck_s"]:
		_on_navigation_finished()
		return true
	if not _repathed and _stuck_s >= tunables["repath_when_stuck_s"]:
		_repathed = true
		if _take_path_budget():
			target_position = target_position  # asks the agent for a fresh path
	return false


func _keep_on_navmesh():
	"""avoidance pushes are not bound to the navmesh: pull units that were pushed off it
	(into a building's footprint or off the map) back onto it"""
	var every = int(settings()["keep_on_navmesh_every_ticks"])
	if every <= 0 or domain != Constants.Match.Navigation.Domain.TERRAIN:
		return
	_navmesh_tick += 1
	if _navmesh_tick % every != 0 or not _moved_since_navmesh_check:
		return  # units standing still cost nothing here
	_moved_since_navmesh_check = false
	var position = _unit.global_position
	var closest = NavigationServer3D.map_get_closest_point(get_navigation_map(), position)
	if Vector2(closest.x - position.x, closest.z - position.z).length() > ON_NAVMESH_TOLERANCE_M:
		_unit.global_position = Vector3(closest.x, position.y, closest.z)


static func _take_path_budget():
	var frame = Engine.get_physics_frames()
	if frame != _path_budget_frame:
		_path_budget_frame = frame
		_path_budget_left = int(settings()["path_requests_per_frame"])
	if _path_budget_left <= 0:
		return false
	_path_budget_left -= 1
	return true


func _spot_step():
	return radius * 2.0 + settings()["destination_spacing_m"]


static func _alternating(index):
	"""0, 1, -1, 2, -2, ... so that the search fans out from the preferred direction"""
	return int((index + 1) / 2.0) * (1 if index % 2 == 1 else -1)


func _reachable(map, candidate):
	var spot = NavigationServer3D.map_get_closest_point(map, candidate)
	if Vector2(spot.x - candidate.x, spot.z - candidate.z).length() > ON_NAVMESH_TOLERANCE_M:
		return null
	return spot


func _occupants_near(center, distance):
	"""[position, radius] of idle units standing near center and of spots others head to"""
	var occupants = []
	var center_yless = center * Vector3(1, 0, 1)
	for idle in _idle_units_by_domain().get(domain, []):
		if idle[0] != _unit and idle[1].distance_to(center_yless) <= distance:
			occupants.append([idle[1], idle[2]])
	for id in _claims:
		var claim = _claims[id]
		if id == _unit.get_instance_id() or not is_instance_valid(claim[0]):
			continue
		if claim[1].distance_to(center_yless) <= distance:
			occupants.append([claim[1], claim[0].radius])
	return occupants


func _idle_units_by_domain():
	"""domain -> [[unit, position, radius]] of units standing still, gathered once per frame:
	a big group order asks for it once per unit"""
	var frame = Engine.get_physics_frames()
	if frame == _idle_units_frame:
		return _idle_units
	_idle_units_frame = frame
	_idle_units = {}
	for unit in get_tree().get_nodes_in_group("units"):
		var movement = unit.get_movement_trait() if unit.has_method("get_movement_trait") else null
		if movement == null or not is_instance_valid(movement) or movement._has_target():
			continue  # structures are off the navmesh already; moving units have a claim
		_idle_units.get_or_add(movement.domain, []).append(
			[unit, unit.global_position_yless, movement.radius]
		)
	return _idle_units


func _is_spot_free(spot, occupants):
	var spot_yless = spot * Vector3(1, 0, 1)
	var spacing = settings()["destination_spacing_m"]
	for occupant in occupants:
		if spot_yless.distance_to(occupant[0]) < radius + occupant[1] + spacing:
			return false
	return true


func _claim(spot):
	_claims[_unit.get_instance_id()] = [_unit, spot * Vector3(1, 0, 1)]


func _release_claim():
	if _unit != null:
		_claims.erase(_unit.get_instance_id())


func _exit_tree():
	_release_claim()
