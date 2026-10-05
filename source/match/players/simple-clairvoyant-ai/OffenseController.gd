extends Node

signal resources_required(resources, metadata)

const Worker = preload("res://source/match/units/Worker.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const VehicleFactory = preload("res://source/match/units/VehicleFactory.gd")
const VehicleFactoryScene = preload("res://source/match/units/VehicleFactory.tscn")
const AircraftFactory = preload("res://source/match/units/AircraftFactory.gd")
const AircraftFactoryScene = preload("res://source/match/units/AircraftFactory.tscn")
const GameData = preload("res://source/data-model/GameData.gd")
const Factions = preload("res://source/data-model/Factions.gd")
const WaterRules = preload("res://source/match/WaterRules.gd")
const AutoAttackingBattlegroup = preload(
	"res://source/match/players/simple-clairvoyant-ai/AutoAttackingBattlegroup.gd"
)

const REFRESH_INTERVAL_S = 1.0 / 60.0 * 30.0
const NO_ROOM_RETRY_S = 30.0  # after finding no free spot, wait before searching again
const CROSSING_CHECK_INTERVAL_S = 20.0
# the units come from the faction's roles (see Factions.gd): the main battle unit of each
# tier from the vehicle factory, the aircraft of tier 2 and 3, and now and then a support
# unit; better units replace the basic ones as the city reaches higher tiers
const MAIN_ROLES = ["main_t1", "main_t2", "main_t3"]
const AIR_ROLES = ["air_t2", "air_t3"]
const SUPPORT_ROLE = "support_t2"
const SUPPORT_EVERY = 4  # every this many vehicles one is the support unit, when there is one
# on maps where the enemy is only reachable over water, the amphibious vehicle is built
# instead of the main battle unit (see _crossing_needed)
const AMPHIBIOUS_VEHICLE_ID = "amphibious_apc"
static var amphibious_vehicle_scene_path = (
	GameData.unit_by_id(AMPHIBIOUS_VEHICLE_ID).get("scene", "")
	if GameData.unit_by_id(AMPHIBIOUS_VEHICLE_ID) != null
	else ""
)

var _player = null
var _primary_structure_scene = null
var _secondary_structure_scene = null
var _number_of_pending_structure_resource_requests = {}
var _primary_unit_scene = null
var _secondary_unit_scene = null
var _number_of_pending_unit_resource_requests = {}
var _battlegroup_under_forming = null
var _battlegroups = []
var _no_room = false  # no free spot was found lately
var _retreated = []  # damaged units that pulled back, they join the next battlegroup
var _crossing_needed = false
var _crossing_checked_at_s = -INF
var _upgrades = {}  # scene path -> scene path of the unit replacing it at a higher tier
var _land_vehicle_scenes = []  # main battle units that cannot cross deep water
var _battle_unit_scenes = []
var _support_scene = null
var _vehicles_ordered = 0

@onready var _ai = get_parent()


func setup(player):
	_player = player
	_primary_structure_scene = (
		VehicleFactoryScene
		if _ai.primary_offensive_structure == _ai.OffensiveStructure.VEHICLE_FACTORY
		else AircraftFactoryScene
	)
	_secondary_structure_scene = (
		VehicleFactoryScene
		if _ai.secondary_offensive_structure == _ai.OffensiveStructure.VEHICLE_FACTORY
		else AircraftFactoryScene
	)
	_setup_roles()
	_primary_unit_scene = _first_unit_scene(_ai.primary_offensive_structure)
	_secondary_unit_scene = _first_unit_scene(_ai.secondary_offensive_structure)
	MatchSignals.tier_reached.connect(_on_tier_reached)
	_setup_refresh_timer()
	_try_creating_new_battlegroup()
	_attach_current_battle_units()
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	_enforce_primary_structure_existence()


func _setup_roles():
	var faction = Factions.of(_player)
	var main = MAIN_ROLES.map(func(role): return Factions.role_scene(faction, role))
	var air = AIR_ROLES.map(func(role): return Factions.role_scene(faction, role))
	main = main.filter(func(path): return path != null)
	air = air.filter(func(path): return path != null)
	for chain in [main, air]:
		for index in range(chain.size() - 1):
			if chain[index] != chain[index + 1]:
				_upgrades[chain[index]] = chain[index + 1]
	_land_vehicle_scenes = main.duplicate()
	_support_scene = Factions.role_scene(faction, SUPPORT_ROLE)
	for path in main + air + ([_support_scene] if _support_scene != null else []):
		if not path in _battle_unit_scenes:
			_battle_unit_scenes.append(path)


func _first_unit_scene(structure):
	"""the faction's tier 1 battle unit for the vehicle factory, its first aircraft for the
	aircraft factory (the vehicle when it has none)"""
	var faction = Factions.of(_player)
	var roles = AIR_ROLES if structure == _ai.OffensiveStructure.AIRCRAFT_FACTORY else []
	for role in roles + MAIN_ROLES:
		var path = Factions.role_scene(faction, role)
		if path != null:
			return load(path)
	return load(GameData.unit_by_id(Factions.DEFAULT_ROLES["main_t1"])["scene"])


func provision(resources, metadata):
	if metadata == "primary_structure":
		_provision_structure(_primary_structure_scene, resources, metadata)
	elif metadata == "secondary_structure":
		_provision_structure(_secondary_structure_scene, resources, metadata)
	elif metadata == "primary_unit":
		_provision_unit(_primary_unit_scene, _primary_structure(), resources, metadata)
	elif metadata == "secondary_unit":
		_provision_unit(_secondary_unit_scene, _secondary_structure(), resources, metadata)
	else:
		assert(false, "unexpected flow")


func _setup_refresh_timer():
	var timer = Timer.new()
	add_child(timer)
	timer.timeout.connect(_on_refresh_timer_timeout)
	timer.start(_ai.think_interval(REFRESH_INTERVAL_S))


func _provision_structure(structure_scene, resources, metadata):
	assert(
		resources == Constants.Match.Units.CONSTRUCTION_COSTS[structure_scene.resource_path],
		"unexpected amount of resources"
	)
	var workers = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Worker and unit.player == _player
	)
	_number_of_pending_structure_resource_requests[metadata] -= 1
	if workers.is_empty():
		return
	_construct_structure(structure_scene)


func _provision_unit(unit_scene, structure_producing_unit, resources, metadata):
	unit_scene = _adapted_to_water(unit_scene)
	if resources != Constants.Match.Units.PRODUCTION_COSTS[unit_scene.resource_path]:
		for scene_path in _battle_unit_scene_paths():  # requested before an upgrade or a swap
			if resources == Constants.Match.Units.PRODUCTION_COSTS[scene_path]:
				unit_scene = load(scene_path)
				break
	assert(
		resources == Constants.Match.Units.PRODUCTION_COSTS[unit_scene.resource_path],
		"unexpected amount of resources"
	)
	if structure_producing_unit == null:
		return
	_number_of_pending_unit_resource_requests[metadata] -= 1
	structure_producing_unit.production_queue.produce(unit_scene, true)


func committed_units():
	"""units of battlegroups that are on the attack right now"""
	var units = []
	for battlegroup in _battlegroups:
		if is_instance_valid(battlegroup) and battlegroup.is_attacking():
			units += battlegroup.units()
	return units


func _try_creating_new_battlegroup():
	if not _battlegroups.is_empty():
		_enforce_secondary_structure_existence()
	if _battlegroups.size() == _ai.expected_number_of_battlegroups:
		var primary_structure = _primary_structure()
		if primary_structure != null:
			primary_structure.production_queue.cancel_all()
		_battlegroup_under_forming = null
		return false
	var adversary_players = get_tree().get_nodes_in_group("players").filter(
		func(player): return player != _player
	)
	adversary_players.shuffle()
	# factions it is at war with come first
	adversary_players.sort_custom(
		func(a, b): return _ai.Diplomacy.at_war(_player, a) and not _ai.Diplomacy.at_war(_player, b)
	)
	var battlegroup = AutoAttackingBattlegroup.new(
		_ai.expected_number_of_units_in_battlegroup, adversary_players, _ai
	)
	_battlegroups.append(battlegroup)
	battlegroup.tree_exited.connect(_on_battlegroup_died.bind(battlegroup))
	battlegroup.unit_retreated.connect(_on_unit_retreated)
	add_child(battlegroup)
	_battlegroup_under_forming = battlegroup
	_attach_retreated_units.call_deferred()
	return true


func _attach_current_battle_units():
	var battle_units = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == _player and _is_battle_unit(unit)
	)
	for battle_unit in battle_units:
		_on_unit_spawned(battle_unit)


func _construct_structure(structure_scene):
	var construction_cost = Constants.Match.Units.CONSTRUCTION_COSTS[structure_scene.resource_path]
	assert(
		_player.has_resources(construction_cost),
		"player should have enough resources at this point"
	)
	# TODO: introduce actual algorithm which takes enemy positions into account
	var ccs = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is CommandCenter and unit.player == _player
	)
	var workers = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Worker and unit.player == _player
	)
	if _no_room:
		return
	var unit_to_spawn = structure_scene.instantiate()
	var reference_position_for_placement = (
		ccs[0].global_position if not ccs.is_empty() else workers[0].global_position
	)
	var placement_position = Utils.Match.Unit.Placement.find_valid_position_radially(
		reference_position_for_placement,
		unit_to_spawn.radius + Constants.Match.Units.EMPTY_SPACE_RADIUS_SURROUNDING_STRUCTURE_M,
		find_parent("Match").navigation.get_navigation_map_rid_by_domain(
			unit_to_spawn.navigation_domain
		),
		get_tree()
	)
	if placement_position == Vector3.INF:  # the base is full
		unit_to_spawn.free()
		_no_room = true
		get_tree().create_timer(NO_ROOM_RETRY_S).timeout.connect(func(): _no_room = false)
		return
	var target_transform = Transform3D(Basis(), placement_position).looking_at(
		placement_position + Vector3(-1, 0, 1), Vector3.UP
	)
	_player.subtract_resources(construction_cost)
	MatchSignals.setup_and_spawn_unit.emit(unit_to_spawn, target_transform, _player)
	_enforce_primary_units_production.call_deferred()


func _enforce_primary_structure_existence():
	_enforce_structure_existence(
		_primary_structure(), _primary_structure_scene, "primary_structure"
	)


func _enforce_secondary_structure_existence():
	_enforce_structure_existence(
		_secondary_structure(), _secondary_structure_scene, "secondary_structure"
	)


func _enforce_structure_existence(structure, structure_scene, type):
	if not _player.meets_tier_requirement(structure_scene.resource_path):
		return
	if structure == null and _number_of_pending_structure_resource_requests.get(type, 0) == 0:
		_number_of_pending_structure_resource_requests[type] = (
			_number_of_pending_structure_resource_requests.get(type, 0) + 1
		)
		resources_required.emit(
			Constants.Match.Units.CONSTRUCTION_COSTS[structure_scene.resource_path], type
		)


func _enforce_primary_units_production():
	_enforce_units_production(_primary_structure(), _primary_unit_scene, "primary_unit")


func _enforce_secondary_units_production():
	_enforce_units_production(_secondary_structure(), _secondary_unit_scene, "secondary_unit")


func _enforce_units_production(structure, unit_scene, type):
	if structure == null or not structure.is_constructed() or not _is_units_production_allowed():
		return
	unit_scene = _adapted_to_water(unit_scene)
	if not _player.can_produce(unit_scene.resource_path):
		return
	var number_of_pending_units = structure.production_queue.size()
	if number_of_pending_units + _number_of_pending_unit_resource_requests.get(type, 0) == 0:
		unit_scene = _with_support(unit_scene, type)
		_number_of_pending_unit_resource_requests[type] = (
			_number_of_pending_unit_resource_requests.get(type, 0) + 1
		)
		resources_required.emit(
			Constants.Match.Units.PRODUCTION_COSTS[unit_scene.resource_path], type
		)


func _is_battle_unit(unit):
	if not unit._scene_path() in _battle_unit_scene_paths():
		return false
	# the faction's raider may also be its main battle unit: raiding parties keep theirs
	var raiding = _ai.get_node_or_null("RaidingController")
	return raiding == null or not raiding.claims(unit)


func _battle_unit_scene_paths():
	if amphibious_vehicle_scene_path == "" or not _player.in_roster(amphibious_vehicle_scene_path):
		return _battle_unit_scenes
	return _battle_unit_scenes + [amphibious_vehicle_scene_path]


func _adapted_to_water(unit_scene):
	"""the amphibious vehicle in place of a land one when no enemy can be reached by land"""
	if (
		unit_scene.resource_path in _land_vehicle_scenes
		and _player.in_roster(amphibious_vehicle_scene_path)
		and _is_crossing_needed()
	):
		return load(amphibious_vehicle_scene_path)
	return unit_scene


func _with_support(unit_scene, type):
	"""every SUPPORT_EVERY-th vehicle of the primary line is the support unit (artillery)"""
	if (
		type != "primary_unit"
		or _support_scene == null
		or not unit_scene.resource_path in _land_vehicle_scenes
		or not _player.can_produce(_support_scene)
	):
		return unit_scene
	_vehicles_ordered += 1
	if _vehicles_ordered % SUPPORT_EVERY == 0:
		return load(_support_scene)
	return unit_scene


func _is_crossing_needed():
	if amphibious_vehicle_scene_path == "":
		return false
	var now_s = Time.get_ticks_msec() / 1000.0
	if now_s - _crossing_checked_at_s < CROSSING_CHECK_INTERVAL_S:
		return _crossing_needed
	_crossing_checked_at_s = now_s
	_crossing_needed = false
	var a_match = find_parent("Match")
	if a_match == null or not a_match.map.has_method("has_water") or not a_match.map.has_water():
		return false
	var own_ccs = _ccs_of(func(player): return player == _player)
	var enemy_ccs = _ccs_of(func(player): return player != _player and _ai.wants_to_attack(player))
	if own_ccs.is_empty() or enemy_ccs.is_empty():
		return false
	var land = a_match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	_crossing_needed = not enemy_ccs.any(
		func(cc):
			return WaterRules.path_reaches(
				land, own_ccs[0].global_position, cc.global_position, cc.radius + 6.0
			)
	)
	return _crossing_needed


func _ccs_of(player_filter):
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is CommandCenter and player_filter.call(unit.player)
	)


func _primary_structure():
	var primary_structures = get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return (
				(
					unit is VehicleFactory
					if _ai.primary_offensive_structure == _ai.OffensiveStructure.VEHICLE_FACTORY
					else unit is AircraftFactory
				)
				and unit.player == _player
			)
	)
	return primary_structures[0] if not primary_structures.is_empty() else null


func _secondary_structure():
	var secondary_structures = get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return (
				(
					unit is VehicleFactory
					if _ai.secondary_offensive_structure == _ai.OffensiveStructure.VEHICLE_FACTORY
					else unit is AircraftFactory
				)
				and unit.player == _player
			)
	)
	return secondary_structures[0] if not secondary_structures.is_empty() else null


func _is_units_production_allowed():
	var primary_structure = _primary_structure()
	var secondary_structure = _secondary_structure()
	return (
		_number_of_additional_units_required()
		> (
			Utils.Arr.sum(_number_of_pending_unit_resource_requests.values())
			+ (
				primary_structure.production_queue.size()
				if primary_structure != null and primary_structure.is_constructed()
				else 0
			)
			+ (
				secondary_structure.production_queue.size()
				if secondary_structure != null and secondary_structure.is_constructed()
				else 0
			)
		)
	)


func _number_of_additional_units_required():
	if _battlegroup_under_forming == null:
		return 0
	return (
		_ai.expected_number_of_battlegroups * _ai.expected_number_of_units_in_battlegroup
		- (_battlegroups.size() - 1) * _ai.expected_number_of_units_in_battlegroup
		- _battlegroup_under_forming.size()
	)


func _on_unit_spawned(unit):
	if unit.player != _player:
		return
	if _is_battle_unit(unit):
		# TODO: check if this still happens after ensuring only own players should match
		# assert(_battlegroup_under_forming != null) # TODO: investigate how do we get here
		if _battlegroup_under_forming == null:
			return
		_battlegroup_under_forming.attach_unit(unit)
		if _battlegroup_under_forming.size() == _ai.expected_number_of_units_in_battlegroup:
			_try_creating_new_battlegroup()
		_enforce_primary_units_production()
		_enforce_secondary_units_production()


func _on_unit_retreated(unit):
	_retreated.append(unit)
	_attach_retreated_units()


func _attach_retreated_units():
	_retreated = _retreated.filter(
		func(unit): return is_instance_valid(unit) and unit.is_inside_tree()
	)
	while not _retreated.is_empty() and _battlegroup_under_forming != null:
		var unit = _retreated.pop_front()
		_battlegroup_under_forming.attach_unit(unit)
		if _battlegroup_under_forming.size() == _ai.expected_number_of_units_in_battlegroup:
			_try_creating_new_battlegroup()


func _on_battlegroup_died(battlegroup):
	if not is_inside_tree():
		return
	_battlegroups.erase(battlegroup)


func _on_refresh_timer_timeout():
	_enforce_primary_structure_existence()
	# secondary structure existence is enforced only when a battlegroup is formed
	_enforce_primary_units_production()
	_enforce_secondary_units_production()


func _on_tier_reached(player, _tier):
	if player != _player or not _ai.tech_upgrades:
		return  # easier AIs keep building their first units
	for _i in range(2):
		var primary_upgrade = _upgrades.get(_primary_unit_scene.resource_path)
		if primary_upgrade != null and _player.meets_tier_requirement(primary_upgrade):
			_primary_unit_scene = load(primary_upgrade)
		var secondary_upgrade = _upgrades.get(_secondary_unit_scene.resource_path)
		if (
			secondary_upgrade != null
			and _player.meets_tier_requirement(secondary_upgrade)
			and _player.meets_tier_requirement(_secondary_unit_scene.resource_path)
		):
			_secondary_unit_scene = load(secondary_upgrade)
