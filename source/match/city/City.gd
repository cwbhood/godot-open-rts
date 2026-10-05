extends Node3D

# Every player owns a city that runs by itself around its first command center.
# - A share of every delivery (see Logistics) goes into the city warehouse.
# - Citizens consume commodities from the warehouse. How well that upkeep is met over time
#   is the city's satisfaction.
# - Satisfied cities grow; new houses and workshops are built from warehouse materials.
#   Workshops speed up unit production.
# - Population produces science on its own, scaled by satisfaction and power. Science is
#   never spent: the city reaches the next tier when it crosses a threshold.
# - The city draws power from the grid of its core and keeps a civil defense.
# - Trading with other factions temporarily speeds up growth for both sides (more for a
#   faction with a "trade_growth" multiplier, the Sandline Syndicate).

signal changed
signal building_added(building)
signal tier_reached(tier)

const CityBuilding = preload("res://source/match/city/CityBuilding.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const CivilDefense = preload("res://source/match/city/CivilDefense.gd")
const Factions = preload("res://source/data-model/Factions.gd")

var population = Constants.Match.City.STARTING_POPULATION
var science = 0.0
var tier = 1
var trade_growth_boost = 0.0
var warehouse = {}
var satisfaction = {}  # commodity -> [0..1], how well upkeep has been met lately
var power_ratio = 1.0  # set by the power grid
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
	get = _get_science_per_s
var power_demand_mw:
	get:
		return (
			population * Constants.Match.Power.CITY_DEMAND_MW_PER_POPULATION if has_core() else 0.0
		)
var housing:
	get:
		return (
			Constants.Match.City.STARTING_POPULATION
			+ _buildings.size() * Constants.Match.City.POPULATION_PER_BUILDING
		)
# the most citizens the city can hold at its tier ("max_population" in data/tiers.json);
# growth stops there until the next tier, see MatchLimits
var max_population:
	get:
		return get_max_population()
var player:
	get:
		return get_parent()
var civil_defense:
	get:
		return get_node_or_null("CivilDefense")

var _buildings = []
var _elapsed_s = 0.0
var _last_trade_time_s = {}  # partner instance id -> _elapsed_s at the time of the trade
var _upkeep_accumulated = {}
var _core = null

@onready var _match = find_parent("Match")


func _ready():
	for resource in Constants.Match.Resources.ALL:
		warehouse[resource] = float(Constants.Match.City.STARTING_WAREHOUSE.get(resource, 0.0))
		satisfaction[resource] = 1.0
		_upkeep_accumulated[resource] = 0.0
	var civil_defense_node = CivilDefense.new()
	civil_defense_node.name = "CivilDefense"
	add_child(civil_defense_node)
	if not _match.is_node_ready():
		await _match.ready
	var timer = Timer.new()
	timer.timeout.connect(_tick.bind(Constants.Match.City.TICK_S))
	add_child(timer)
	timer.start(Constants.Match.City.TICK_S)


func get_core():
	return _find_core()


func has_core():
	return _find_core() != null


func get_satisfaction():
	"""overall satisfaction, the average over all commodities"""
	if satisfaction.is_empty():
		return 1.0
	return Utils.Arr.sum(satisfaction.values()) / float(satisfaction.size())


func get_upkeep_per_min():
	var upkeep = {}
	for resource in Constants.Match.City.UPKEEP_PER_POPULATION_PER_MIN:
		upkeep[resource] = (
			population * Constants.Match.City.UPKEEP_PER_POPULATION_PER_MIN[resource]
		)
	return upkeep


func get_buildings_count(kind = null):
	if kind == null:
		return _buildings.size()
	return _buildings.filter(func(building): return building.kind == kind).size()


func get_next_tier_science():
	var tiers = Constants.Match.Tech.TIERS
	return tiers[tier]["science"] if tier < tiers.size() else null


func get_max_population(a_tier = null):
	var tiers = Constants.Match.Tech.TIERS
	var entry = tiers[clamp((a_tier if a_tier != null else tier) - 1, 0, tiers.size() - 1)]
	if "max_population" in entry:
		return float(entry["max_population"])
	return (
		Constants.Match.City.MAX_BUILDINGS * Constants.Match.City.POPULATION_PER_BUILDING
		+ Constants.Match.City.STARTING_POPULATION
	)


func is_at_population_cap():
	return population >= max_population - 0.01


func get_tier_name(a_tier = null):
	return Constants.Match.Tech.TIERS[(a_tier if a_tier != null else tier) - 1]["name"]


func receive_delivery(goods):
	"""takes the city's share of delivered goods, returns what is left for the player"""
	var remainder = {}
	for resource in goods:
		var share = min(
			round(goods[resource] * Constants.Match.City.DELIVERY_SHARE),
			max(0.0, Constants.Match.City.WAREHOUSE_CAPACITY - warehouse.get(resource, 0.0))
		)
		warehouse[resource] = warehouse.get(resource, 0.0) + share
		if goods[resource] - share > 0:
			remainder[resource] = int(goods[resource] - share)
	return remainder


func take_from_warehouse(resources):
	"""used by the civil defense; returns false if the warehouse cannot afford it"""
	for resource in resources:
		if warehouse.get(resource, 0.0) < resources[resource]:
			return false
	for resource in resources:
		warehouse[resource] -= resources[resource]
	return true


func seconds_since_last_trade_with(partner):
	var partner_id = partner.get_instance_id()
	if not partner_id in _last_trade_time_s:
		return INF
	return _elapsed_s - _last_trade_time_s[partner_id]


func register_trade(partner, traded_value):
	_last_trade_time_s[partner.get_instance_id()] = _elapsed_s
	var multiplier = Factions.city_multiplier(player, "trade_growth")
	trade_growth_boost = min(
		Constants.Match.Trade.GROWTH_BOOST_MAX * multiplier,
		(
			trade_growth_boost
			+ traded_value * Constants.Match.Trade.GROWTH_BOOST_PER_TRADED_VALUE * multiplier
		)
	)
	changed.emit()


func _get_growth_per_s():
	if not has_core():
		return 0.0
	var city_satisfaction = get_satisfaction()
	if city_satisfaction < Constants.Match.City.STARVING_SATISFACTION:
		return -Constants.Match.City.SHRINK_PER_S
	if is_at_population_cap():
		return 0.0
	# growth slows as the city fills up towards the last tier's cap; the current tier's cap
	# is a hard ceiling on top of that (see _tick)
	var room_left = max(
		0.0, 1.0 - population / get_max_population(Constants.Match.Tech.TIERS.size())
	)
	var power_factor = 0.5 + 0.5 * power_ratio
	return (
		(Constants.Match.City.BASE_GROWTH_PER_S * city_satisfaction + trade_growth_boost)
		* room_left
		* power_factor
	)


func _get_science_per_s():
	if not has_core():
		return 0.0
	var unpowered = Constants.Match.City.UNPOWERED_SCIENCE_FACTOR
	return (
		population
		* Constants.Match.City.SCIENCE_PER_POPULATION_PER_S
		* get_satisfaction()
		* (unpowered + (1.0 - unpowered) * power_ratio)
	)


func _tick(delta):
	_elapsed_s += delta
	if has_core():
		_consume_upkeep(delta)
	# population cannot outgrow the housing the city managed to build
	population = clamp(
		population + growth_per_s * delta,
		Constants.Match.City.STARTING_POPULATION * 0.5,
		min(housing + Constants.Match.City.POPULATION_PER_BUILDING, max_population)
	)
	trade_growth_boost = max(
		0.0, trade_growth_boost - Constants.Match.Trade.GROWTH_BOOST_DECAY_PER_S * delta
	)
	science += science_per_s * delta
	_try_reaching_next_tier()
	_try_placing_buildings()
	_spill_warehouse_overflow()
	_update_buildings_visibility()
	changed.emit()


func _consume_upkeep(delta):
	var smoothing = Constants.Match.City.SATISFACTION_SMOOTHING
	for resource in Constants.Match.City.UPKEEP_PER_POPULATION_PER_MIN:
		var needed = (
			population * Constants.Match.City.UPKEEP_PER_POPULATION_PER_MIN[resource] / 60.0 * delta
		)
		var taken = min(needed, warehouse.get(resource, 0.0))
		warehouse[resource] = warehouse.get(resource, 0.0) - taken
		var met = taken / needed if needed > 0.0 else 1.0
		satisfaction[resource] = lerp(satisfaction.get(resource, 1.0), met, smoothing)


func _try_reaching_next_tier():
	var next_science = get_next_tier_science()
	while next_science != null and science >= next_science:
		tier += 1
		tier_reached.emit(tier)
		MatchSignals.tier_reached.emit(player, tier)
		next_science = get_next_tier_science()


func _try_placing_buildings():
	var core = _find_core()
	if core == null or _buildings.size() >= Constants.Match.City.MAX_BUILDINGS:
		return
	if housing >= max_population:
		return  # the tier's population cap: more houses would stand empty
	if population < housing - Constants.Match.City.POPULATION_PER_BUILDING * 0.5:
		return  # houses are built when the city gets crowded
	var kind = _next_building_kind()
	var cost = Constants.Match.City.BUILDING_COSTS[kind]
	if not take_from_warehouse(cost):
		if kind == "house":
			return
		kind = "house"  # a workshop the city cannot afford yet does not block housing
		cost = Constants.Match.City.BUILDING_COSTS[kind]
		if not take_from_warehouse(cost):
			return
	var position = _find_building_position(core)
	if position == null:
		for resource in cost:
			warehouse[resource] += cost[resource]
		return
	_add_building(kind, position)


func _spill_warehouse_overflow():
	var overflow = {}
	for resource in warehouse:
		var extra = int(floor(warehouse[resource] - Constants.Match.City.WAREHOUSE_CAPACITY))
		if extra > 0:
			warehouse[resource] -= extra
			overflow[resource] = extra
	if not overflow.is_empty():
		player.add_resources(overflow)


func _next_building_kind():
	var due_workshops = int(
		(_buildings.size() + 1) / Constants.Match.City.WORKSHOP_EVERY_NTH_BUILDING
	)
	if get_buildings_count("workshop") < due_workshops:
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
	if _core != null and is_instance_valid(_core) and _core.is_inside_tree():
		return _core
	_core = null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == player and unit is CommandCenter and unit.is_constructed():
			_core = unit
			break
	return _core


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
