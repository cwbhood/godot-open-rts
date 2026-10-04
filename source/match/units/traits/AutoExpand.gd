extends Node

# Auto-expand: a constructor with this node keeps growing the economy on its own. Every
# few seconds, when it has nothing to do, it picks the most useful job:
#   1. get away from enemies that come close,
#   2. finish a construction site nobody is working on,
#   3. a power plant when the grid is short,
#   4. a pylon that wires an off-grid extractor to the grid,
#   5. an extractor on the best free deposit: the commodity you have the fewest extractors
#      and the smallest stock of, close to a command center, away from enemies,
#   6. a road upgrade on the longest dirt supply route.
# It pays from the bank like the player would, but never spends below the reserve the
# player chose (see AutoExpandPanel, or per commodity in the helper's panel while the
# helper is on). A manual order pauses it until the order is done. With the helper on it
# also avoids every enemy the player's units have seen, and builds the helper's factory.
# It also queues a hauler at a command center when extractors outnumber haulers.

enum Job { NONE, FLEEING, HELPING, BUILDING, PAUSED, WAITING }

const Worker = preload("res://source/match/units/Worker.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Constructing = preload("res://source/match/units/actions/Constructing.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const GameData = preload("res://source/data-model/GameData.gd")
const Helper = preload("res://source/match/players/human/Helper.gd")

const NODE_NAME = "AutoExpand"
const DEFAULT_RESERVE = 10
const RESERVE_META = "auto_expand_reserve"
const SPENT_META = "auto_expand_spent"
const THINK_INTERVAL_S = 1.5
const SAFE_DISTANCE_FROM_DEPOT_M = 45.0  # unguarded deposits further out are skipped
const GUARDED_DISTANCE_FROM_DEPOT_M = 70.0  # ...unless own armed units are near them
const GUARD_RADIUS_M = 14.0
const DANGER_RADIUS_M = 14.0  # enemies this close to a spot make it unsafe
const FLEE_RADIUS_M = 10.0  # enemies this close to the constructor make it run home
const POWER_HEADROOM_MW = 1.0
const MAX_PYLON_GAP_M = 40.0  # longer gaps are not worth a chain of pylons
const ROAD_MIN_LENGTH_M = 15.0
const EXTRACTORS_PER_HAULER = 2
const PLACEMENT_RINGS = 10

static var _radius_cache = {}  # scene path -> radius

var job = Job.NONE
var status_text = ""
var target = null  # site being built or helped

var _our_action = null
var _since_think_s = THINK_INTERVAL_S

@onready var _unit = get_parent()


static func is_enabled_on(unit):
	return unit.get_node_or_null(NODE_NAME) != null


static func set_enabled_on(unit, enabled):
	var existing = unit.get_node_or_null(NODE_NAME)
	if enabled and existing == null:
		var auto_expand = load("res://source/match/units/traits/AutoExpand.gd").new()
		auto_expand.name = NODE_NAME
		unit.add_child(auto_expand)
	elif not enabled and existing != null:
		existing.stop()


static func get_reserve(player):
	return int(player.get_meta(RESERVE_META, DEFAULT_RESERVE))


static func get_spent(player):
	return player.get_meta(SPENT_META, {})


func stop():
	if _unit.action != null and _unit.action == _our_action:
		_unit.action = null
	_unit.remove_child(self)  # gone right away, so menus refreshed this frame see it off
	queue_free()


func _ready():
	_set_status(Job.WAITING, tr("AUTO_STATUS_LOOKING"))


func _process(delta):
	_since_think_s += delta
	if _since_think_s < THINK_INTERVAL_S:
		return
	_since_think_s = 0.0
	_think()


func _think():
	if not _unit.is_inside_tree() or _unit.player == null:
		return
	var threat = _closest_enemy(_unit.global_position, FLEE_RADIUS_M)
	if threat != null:
		_flee()
		return
	if _unit.action != null and _unit.action != _our_action:
		_set_status(Job.PAUSED, tr("AUTO_STATUS_PAUSED"))
		return
	if _unit.action == null:
		_pick_a_job()  # otherwise still busy with our own job


func _pick_a_job():
	_order_hauler_if_short()
	var site = _abandoned_site()
	if site != null:
		var status = "AUTO_STATUS_RESUMING" if site == target else "AUTO_STATUS_HELPING"
		_construct(site, Job.HELPING, tr(status).format([_name_of(site)]))
		return
	if _too_many_sites_waiting_for_materials():
		_set_status(Job.WAITING, tr("AUTO_STATUS_WAITING_FOR_HAULERS"))
		return
	var plan = _next_plan()
	if plan == null:
		return  # _next_plan has set the status
	if plan.get("road") != null:
		_player().logistics.upgrade_road(plan["road"])
		_count_spent(plan["cost"])
		_set_status(Job.WAITING, tr("AUTO_STATUS_PAVED"))
		return
	_place_and_build(plan)


func _next_plan():
	"""{scene, position, reason} or {road, cost}; null when there is nothing to do"""
	var plans = [
		_power_plant_plan(), _helper_plan(), _pylon_plan(), _extractor_plan(), _road_plan()
	]
	var short_of = null
	for plan in plans:
		if plan == null:
			continue
		var missing = _missing_beyond_reserve(plan["cost"])
		if missing.is_empty():
			return plan
		if short_of == null:
			short_of = [plan, missing]
	if short_of != null:
		var parts = []
		for resource in short_of[1]:
			parts.append("{0} {1}".format([short_of[1][resource], tr(resource.to_upper())]))
		_set_status(
			Job.WAITING,
			tr("AUTO_STATUS_SAVING").format(
				[short_of[0]["label"], ", ".join(parts), _reserve_shown(short_of[1].keys()[0])]
			)
		)
	else:
		_set_status(Job.WAITING, tr("AUTO_STATUS_NOTHING_TO_DO"))
	return null


func _power_plant_plan():
	var grid = _player().power_grid
	var depot = _closest_depot(_unit.global_position)
	if grid == null or depot == null:
		return null
	if grid.total_supply_mw >= grid.total_demand_mw + POWER_HEADROOM_MW:
		return null
	var scene_path = _cheapest_power_plant()
	if scene_path == null or _site_of_scene_exists(scene_path):
		return null  # one plant at a time: the one being built will cover the shortage
	var position = _find_position_near(depot.global_position, scene_path, 6.0)
	if position == null:
		return null
	return _plan(scene_path, position, tr("AUTO_REASON_POWER"))


func _helper_plan():
	"""the structure the helper asks for (a factory for its army), near a command center"""
	var helper = Helper.active_for(_player())
	var scene_path = helper.wanted_structure() if helper != null else null
	if scene_path == null or _site_of_scene_exists(scene_path):
		return null
	var depot = _closest_depot(_unit.global_position)
	if depot == null:
		return null
	var position = _find_position_near(depot.global_position, scene_path, 8.0)
	if position == null:
		return null
	return _plan(scene_path, position, tr("AUTO_REASON_HELPER"))


func _pylon_plan():
	var grid = _player().power_grid
	var pylon = _scene_with_field("grid_radius_m", false)
	if grid == null or pylon == null or _site_of_scene_exists(pylon):
		return null
	var pylon_radius = float(Constants.Match.Power.GRID_RADIUS_M.get(pylon, 0.0))
	for extractor in _own_units(func(unit): return unit is Extractor and unit.is_constructed()):
		if grid.is_position_on_grid(extractor.global_position):
			continue
		var node = _closest_grid_node(extractor.global_position)
		if node == null:
			continue
		var node_radius = float(Constants.Match.Power.GRID_RADIUS_M[node._scene_path()])
		var gap = node.global_position_yless.distance_to(extractor.global_position_yless)
		if gap - node_radius > MAX_PYLON_GAP_M or not _spot_is_safe(extractor.global_position):
			continue
		var direction = (extractor.global_position_yless - node.global_position_yless).normalized()
		# as far towards the extractor as it can go while still connecting to the node
		var reach = min(gap - pylon_radius * 0.5, node_radius + pylon_radius - 1.0)
		var position = _find_position_near(
			node.global_position_yless + direction * max(reach, 1.0), pylon, 0.0, 3
		)
		if position != null:
			return _plan(pylon, position, tr("AUTO_REASON_PYLON"))
	return null


func _extractor_plan():
	var best = null
	for deposit in get_tree().get_nodes_in_group("deposits"):
		if not deposit.is_inside_tree() or _deposit_taken(deposit):
			continue
		var scene_path = _extractor_scene_for(deposit.kind)
		if scene_path == null:
			continue
		var depot = _closest_depot(deposit.global_position)
		if depot == null:
			continue
		var from_depot = depot.global_position_yless.distance_to(deposit.global_position_yless)
		var limit = (
			GUARDED_DISTANCE_FROM_DEPOT_M
			if _is_guarded(deposit.global_position)
			else SAFE_DISTANCE_FROM_DEPOT_M
		)
		if from_depot > limit or not _spot_is_safe(deposit.global_position):
			continue
		var score = (
			from_depot
			+ 0.3 * _unit.global_position_yless.distance_to(deposit.global_position_yless)
			+ 18.0 * _extractors_of_kind(deposit.kind)
			+ 10.0 * _stock_share(deposit.kind)
		)
		if best == null or score < best[0]:
			best = [score, deposit, scene_path]
	if best == null:
		return null
	var position = _extractor_spot(best[1], best[2])
	if position == null:
		return null
	return _plan(
		best[2],
		position,
		tr("AUTO_REASON_EXTRACTOR").format(
			[tr(best[1].kind.to_upper()), int(_unit.global_position_yless.distance_to(position))]
		)
	)


func _road_plan():
	var logistics = _player().logistics
	if logistics == null:
		return null
	var best = null
	for extractor in logistics.get_extractors():
		var length = logistics.get_road_length_m(extractor)
		if length < ROAD_MIN_LENGTH_M or logistics.get_road_level(extractor) > 0:
			continue  # one level at a time: further upgrades are the player's call
		var upgrade = logistics.get_road_upgrade_for(extractor)
		if upgrade == null or not _player().has_tier(int(upgrade["entry"].get("tier", 1))):
			continue
		if not extractor.is_constructed():
			continue
		if best == null or length > best[0]:
			best = [length, extractor, upgrade]
	if best == null:
		return null
	return {
		"road": best[1],
		"cost": best[2]["cost"],
		"label": tr(best[2]["entry"]["name"]),
	}


func _plan(scene_path, position, reason):
	var entry = GameData.unit_by_scene(scene_path)
	return {
		"scene": scene_path,
		"position": position,
		"cost": Constants.Match.Units.CONSTRUCTION_COSTS[scene_path],
		"reason": reason,
		"label": tr(entry["name"]) if entry != null else scene_path.get_file(),
	}


func _place_and_build(plan):
	var structure = load(plan["scene"]).instantiate()
	_player().subtract_resources(plan["cost"])
	_count_spent(plan["cost"])
	structure.set_meta("auto_expand", true)
	var position = plan["position"]
	MatchSignals.setup_and_spawn_unit.emit(
		structure,
		Transform3D(Basis(), position).looking_at(position + Vector3(0, 0, 1), Vector3.UP),
		_player()
	)
	_construct(structure, Job.BUILDING, plan["reason"])


func _construct(site, a_job, status):
	target = site
	_our_action = Constructing.new(site)
	_unit.action = _our_action
	_set_status(a_job, status)


func _flee():
	var depot = _closest_depot(_unit.global_position)
	if depot == null:
		_set_status(Job.FLEEING, tr("AUTO_STATUS_FLEEING"))
		return
	if _unit.action == null or _unit.action == _our_action:
		var away = depot.global_position_yless + Vector3(2, 0, 2)
		if _unit.global_position_yless.distance_to(away) > 4.0:
			_our_action = Moving.new(away)
			_unit.action = _our_action
	_set_status(Job.FLEEING, tr("AUTO_STATUS_FLEEING"))


func _order_hauler_if_short():
	var extractors = _own_units(func(unit): return unit is Extractor).size()
	var haulers = _own_units(func(unit): return unit is Hauler).size()
	if extractors <= haulers * EXTRACTORS_PER_HAULER:
		return
	var hauler_scene = "res://source/match/units/Hauler.tscn"
	var cost = Constants.Match.Units.PRODUCTION_COSTS.get(hauler_scene, {})
	if not _missing_beyond_reserve(cost).is_empty():
		return
	var logistics = _player().logistics
	if logistics == null:
		return
	for depot in logistics.get_depots():
		var queue = depot.production_queue
		if queue != null and queue.size() == 0:
			if queue.produce(load(hauler_scene)) != null:
				_count_spent(cost)
			return


func _abandoned_site():
	"""own unfinished site that no constructor is working on, closest first"""
	var best = null
	for site in _own_units(func(unit): return unit is Structure and unit.is_under_construction()):
		if not _spot_is_safe(site.global_position):
			continue
		var taken = _own_units(
			func(unit):
				return (
					unit is Worker
					and unit.action is Constructing
					and unit.action.get("_target_unit") == site
				)
		)
		if not taken.is_empty():
			continue
		var distance = _unit.global_position_yless.distance_to(site.global_position_yless)
		if best == null or distance < best[0]:
			best = [distance, site]
	return best[1] if best != null else null


func _too_many_sites_waiting_for_materials():
	var waiting = _own_units(func(unit): return unit is Structure and unit.needs_materials())
	var haulers = _own_units(func(unit): return unit is Hauler).size()
	return waiting.size() > max(1, haulers)


func _site_of_scene_exists(scene_path):
	var sites = _own_units(
		func(unit):
			return (
				unit is Structure
				and unit.is_under_construction()
				and unit._scene_path() == scene_path
			)
	)
	return not sites.is_empty()


func _missing_beyond_reserve(cost):
	var missing = {}
	var helper = Helper.active_for(_player())
	var reserve = get_reserve(_player())
	for resource in cost:
		if helper != null:
			reserve = helper.keep_of(resource)
		var short = int(cost[resource]) + reserve - int(_player().get(resource))
		if short > 0:
			missing[resource] = short
	return missing


func _reserve_shown(resource):
	var helper = Helper.active_for(_player())
	return helper.keep_of(resource) if helper != null else get_reserve(_player())


func _count_spent(cost):
	var spent = get_spent(_player()).duplicate()
	for resource in cost:
		spent[resource] = spent.get(resource, 0) + int(cost[resource])
	_player().set_meta(SPENT_META, spent)


func _set_status(a_job, text):
	job = a_job
	status_text = text


func _player():
	return _unit.player


func _own_units(filter):
	var player = _player()
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player and filter.call(unit)
	)


func _closest_depot(position):
	var logistics = _player().logistics
	if logistics != null:
		return logistics.closest_depot(position)
	var depots = _own_units(func(unit): return unit is CommandCenter and unit.is_constructed())
	return depots[0] if not depots.is_empty() else null


func _closest_grid_node(position):
	var best = null
	for node in _own_units(
		func(unit):
			return (
				unit is Structure
				and unit.is_constructed()
				and Constants.Match.Power.GRID_RADIUS_M.get(unit._scene_path(), 0.0) > 0.0
			)
	):
		var distance = node.global_position_yless.distance_to(position * Vector3(1, 0, 1))
		if best == null or distance < best[0]:
			best = [distance, node]
	return best[1] if best != null else null


func _closest_enemy(position, radius):
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _player() or unit.attack_damage == null or not unit.visible:
			continue
		if unit is Structure and not unit.is_constructed():
			continue
		if unit.global_position_yless.distance_to(position * Vector3(1, 0, 1)) <= radius:
			return unit
	return null


func _spot_is_safe(position):
	var helper = Helper.active_for(_player())
	if helper != null and helper.is_unsafe(position):
		return false
	return _closest_enemy(position, DANGER_RADIUS_M) == null


func _is_guarded(position):
	var spot = position * Vector3(1, 0, 1)
	var guards = _own_units(
		func(unit):
			return (
				unit.attack_damage != null
				and unit.global_position_yless.distance_to(spot) <= GUARD_RADIUS_M
			)
	)
	return not guards.is_empty()


func _deposit_taken(deposit):
	for extractor in get_tree().get_nodes_in_group("units"):
		if not extractor is Extractor:
			continue
		if extractor.deposit == deposit:
			return true
		if (
			extractor.is_under_construction()
			and (
				Extractor.find_deposit_near(
					extractor._scene_path(), extractor.global_position, extractor.radius, get_tree()
				)
				== deposit
			)
		):
			return true
	return false


func _extractors_of_kind(kind):
	var count = 0
	for extractor in _own_units(func(unit): return unit is Extractor):
		var extractor_kind = extractor.resource_kind
		if extractor_kind == null:
			var deposit = Extractor.find_deposit_near(
				extractor._scene_path(), extractor.global_position, extractor.radius, get_tree()
			)
			extractor_kind = deposit.kind if deposit != null else null
		if extractor_kind == kind:
			count += 1
	return count


func _stock_share(kind):
	"""0.0 when the stock is empty, 1.0 at the starting stock or more"""
	var starting = float(Constants.Match.Resources.STARTING_STOCK.get(kind, 20))
	return clamp(float(_player().get(kind)) / max(starting, 1.0), 0.0, 1.0)


func _extractor_scene_for(kind):
	for entry in GameData.producible_by("worker"):
		if kind in entry.get("extracts", []) and _player().meets_tier_requirement(entry["scene"]):
			return entry["scene"]
	return null


func _cheapest_power_plant():
	return _scene_with_field("output_mw", true)


func _scene_with_field(power_field, producer):
	"""cheapest unlocked structure with the power field; producer: also no grid-only nodes"""
	var best = null
	for entry in GameData.producible_by("worker"):
		var power = entry.get("power", {})
		if float(power.get(power_field, 0.0)) <= 0.0:
			continue
		if not producer and float(power.get("output_mw", 0.0)) > 0.0:
			continue  # a pylon, not a plant
		if entry["scene"].ends_with("CommandCenter.tscn"):
			continue
		if not _player().meets_tier_requirement(entry["scene"]):
			continue
		var cost = Utils.Dict.sum(entry.get("cost", {}))
		if best == null or cost < best[0]:
			best = [cost, entry["scene"]]
	return best[1] if best != null else null


func _extractor_spot(deposit, scene_path):
	var radius = _radius_of(scene_path)
	var depot = _closest_depot(deposit.global_position)
	var towards = (
		(depot.global_position_yless - deposit.global_position_yless)
		if depot != null
		else Vector3(0, 0, 1)
	)
	var start_angle = atan2(towards.z, towards.x)
	for step in range(12):
		var angle = start_angle + (step + 1) / 2 * (PI / 6.0) * (1 if step % 2 == 0 else -1)
		var position = (
			deposit.global_position_yless
			+ Vector3(cos(angle), 0, sin(angle)) * (deposit.radius + radius + 0.5)
		)
		if (
			_placement_valid(position, radius)
			and Extractor.find_deposit_near(scene_path, position, radius, get_tree()) == deposit
		):
			return position
	return null


func _find_position_near(origin, scene_path, min_distance = 0.0, rings = PLACEMENT_RINGS):
	var radius = (
		_radius_of(scene_path) + Constants.Match.Units.EMPTY_SPACE_RADIUS_SURROUNDING_STRUCTURE_M
	)
	origin = origin * Vector3(1, 0, 1)
	if min_distance <= 0.0 and _placement_valid(origin, radius):
		return origin
	for ring in range(rings):
		var distance = max(min_distance, radius) + ring * radius
		var slots = max(6, int(TAU * distance / (radius * 2.0)))
		for slot in range(slots):
			var angle = TAU * slot / slots
			var position = origin + Vector3(cos(angle), 0, sin(angle)) * distance
			if _placement_valid(position, radius):
				return position
	return null


func _placement_valid(position, radius):
	var a_match = find_parent("Match")
	if not Geometry2D.is_point_in_polygon(
		Vector2(position.x, position.z), a_match.map.get_topdown_polygon_2d()
	):
		return false
	return (
		Utils.Match.Unit.Placement.validate_agent_placement_position(
			position,
			radius,
			(
				get_tree().get_nodes_in_group("units")
				+ get_tree().get_nodes_in_group("resource_units")
				+ get_tree().get_nodes_in_group("city_buildings")
			),
			a_match.navigation.get_navigation_map_rid_by_domain(
				Constants.Match.Navigation.Domain.TERRAIN
			)
		)
		== Utils.Match.Unit.Placement.VALID
	)


static func _radius_of(scene_path):
	if not scene_path in _radius_cache:
		var prototype = load(scene_path).instantiate()
		_radius_cache[scene_path] = prototype.radius
		prototype.free()
	return _radius_cache[scene_path]


static func _name_of(unit):
	var entry = GameData.unit_by_scene(unit._scene_path())
	return TranslationServer.translate(entry["name"]) if entry != null else unit.name
