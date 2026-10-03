extends Node3D

# Every player owns a city that grows by itself around its first command center.
# Population fills houses and workshops in rings around the core. Workshops speed up
# unit production, population produces science, and science unlocks technologies.
# Trading with other factions temporarily speeds up growth for both sides.

signal changed
signal building_added(building)
signal tech_unlocked(tech)

const CityBuilding = preload("res://source/match/city/CityBuilding.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")

var population = Constants.Match.City.STARTING_POPULATION
var science = 0.0
var trade_growth_boost = 0.0
var unlocked_techs = []
var growth_per_s:
	get = _get_growth_per_s
var production_multiplier:
	get:
		return (
			1.0
			+ (
				get_buildings_count("workshop")
				* Constants.Match.City.PRODUCTION_SPEED_BONUS_PER_WORKSHOP
			)
		)
var science_per_s:
	get:
		return population * Constants.Match.City.SCIENCE_PER_POPULATION_PER_S if has_core() else 0.0
var player:
	get:
		return get_parent()

var _buildings = []
var _elapsed_s = 0.0
var _last_trade_time_s = {}  # partner instance id -> _elapsed_s at the time of the trade

@onready var _match = find_parent("Match")


func _ready():
	if not _match.is_node_ready():
		await _match.ready
	var timer = Timer.new()
	timer.timeout.connect(_tick.bind(Constants.Match.City.TICK_S))
	add_child(timer)
	timer.start(Constants.Match.City.TICK_S)


func has_core():
	return _find_core() != null


func has_tech(tech):
	return tech in unlocked_techs


func get_buildings_count(kind = null):
	if kind == null:
		return _buildings.size()
	return _buildings.filter(func(building): return building.kind == kind).size()


func get_next_tech():
	for tech in Constants.Match.Tech.SCIENCE_COSTS:
		if not has_tech(tech):
			return tech
	return null


func seconds_since_last_trade_with(partner):
	var partner_id = partner.get_instance_id()
	if not partner_id in _last_trade_time_s:
		return INF
	return _elapsed_s - _last_trade_time_s[partner_id]


func register_trade(partner, traded_resources_total):
	_last_trade_time_s[partner.get_instance_id()] = _elapsed_s
	trade_growth_boost = min(
		Constants.Match.Trade.GROWTH_BOOST_MAX,
		(
			trade_growth_boost
			+ traded_resources_total * Constants.Match.Trade.GROWTH_BOOST_PER_TRADED_RESOURCE
		)
	)
	changed.emit()


func _get_growth_per_s():
	if not has_core():
		return 0.0
	var max_population = (
		Constants.Match.City.MAX_BUILDINGS * Constants.Match.City.POPULATION_PER_BUILDING
		+ Constants.Match.City.STARTING_POPULATION
	)
	var room_left = max(0.0, 1.0 - population / max_population)
	return (Constants.Match.City.BASE_GROWTH_PER_S + trade_growth_boost) * room_left


func _tick(delta):
	_elapsed_s += delta
	population += growth_per_s * delta
	trade_growth_boost = max(
		0.0, trade_growth_boost - Constants.Match.Trade.GROWTH_BOOST_DECAY_PER_S * delta
	)
	science += science_per_s * delta
	_try_unlocking_techs()
	_try_placing_buildings()
	_update_buildings_visibility()
	changed.emit()


func _try_unlocking_techs():
	var tech = get_next_tech()
	while tech != null and science >= Constants.Match.Tech.SCIENCE_COSTS[tech]:
		unlocked_techs.append(tech)
		tech_unlocked.emit(tech)
		MatchSignals.tech_unlocked.emit(player, tech)
		tech = get_next_tech()


func _try_placing_buildings():
	var core = _find_core()
	if core == null:
		return
	var expected_buildings = min(
		Constants.Match.City.MAX_BUILDINGS,
		int(population / Constants.Match.City.POPULATION_PER_BUILDING)
	)
	while _buildings.size() < expected_buildings:
		var position = _find_building_position(core)
		if position == null:
			return
		_add_building(_next_building_kind(), position)


func _next_building_kind():
	if (_buildings.size() + 1) % Constants.Match.City.WORKSHOP_EVERY_NTH_BUILDING == 0:
		return "workshop"
	return "house"


func _add_building(kind, position):
	var building = CityBuilding.new()
	building.kind = kind
	add_child(building)
	building.global_position = position
	building.rotation.y = randf_range(0.0, TAU)
	building.visible = false
	_buildings.append(building)
	_update_building_visibility(building)
	building_added.emit(building)


func _find_building_position(core):
	var obstacles = (
		get_tree().get_nodes_in_group("units")
		+ get_tree().get_nodes_in_group("resource_units")
		+ get_tree().get_nodes_in_group("city_buildings")
	)
	var navigation_map_rid = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	var map_polygon = _match.map.get_topdown_polygon_2d()
	var radius = Constants.Match.City.BUILDING_RADIUS_M
	for ring in range(Constants.Match.City.BUILDING_RINGS):
		var ring_radius = (
			Constants.Match.City.FIRST_BUILDING_RING_RADIUS_M
			+ ring * Constants.Match.City.BUILDING_RING_SPACING_M
		)
		var slots = int(TAU * ring_radius / (radius * 2.0 + 1.0))
		for slot in range(slots):
			var angle = TAU * slot / slots + ring * 0.5
			var position = (
				core.global_position_yless + Vector3(cos(angle), 0, sin(angle)) * ring_radius
			)
			if not Geometry2D.is_point_in_polygon(Vector2(position.x, position.z), map_polygon):
				continue
			if (
				Utils.Match.Unit.Placement.validate_agent_placement_position(
					position, radius, obstacles, navigation_map_rid
				)
				== Utils.Match.Unit.Placement.VALID
			):
				return position
	return null


func _find_core():
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == player and unit is CommandCenter and unit.is_constructed():
			return unit
	return null


func _update_buildings_visibility():
	for building in _buildings:
		_update_building_visibility(building)


func _update_building_visibility(building):
	if building.revealed_once:
		return
	if player in _match.visible_players:
		building.revealed_once = true
	else:
		for unit in get_tree().get_nodes_in_group("revealed_units"):
			if (
				unit.is_revealing()
				and unit.sight_range != null
				and (
					unit.global_position_yless.distance_to(building.global_position)
					<= unit.sight_range
				)
			):
				building.revealed_once = true
				break
	building.visible = building.revealed_once
