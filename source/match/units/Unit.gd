extends Area3D

signal selected
signal deselected
signal hp_changed
signal action_changed(new_action)
signal action_updated

const GameData = preload("res://source/data-model/GameData.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const MATERIAL_ALBEDO_TO_REPLACE = Color(0.99, 0.81, 0.48)
const MATERIAL_ALBEDO_TO_REPLACE_EPSILON = 0.05

var hp = null:
	set = _set_hp
var hp_max = null:
	set = _set_hp_max
var attack_damage = null
var attack_interval = null
var attack_range = null
var attack_domains = []
var radius:
	get = _get_radius
var movement_domain:  # AIR or TERRAIN: boats and amphibious units count as TERRAIN
	get = _get_movement_domain
var navigation_domain:  # also WATER or AMPHIBIOUS: picks the navigation map
	get = _get_navigation_domain
var movement_speed:
	get = _get_movement_speed
var sight_range = null:
	get:
		if sight_range == null or _match == null:
			return sight_range
		if _weather == null or not is_instance_valid(_weather):
			_weather = _match.get_node_or_null("WeatherEffects")
			if _weather == null:
				return sight_range
		return sight_range * _weather.get_vision_multiplier(global_position, movement_domain)
var player:
	get:
		return get_parent()
var color:
	get:
		return player.color
var action = null:
	set = _set_action
var global_position_yless:
	get:
		return global_position * Vector3(1, 0, 1)
var type:
	get = _get_type
var last_attacker_player = null  # used to hand out loot when cargo gets destroyed

var _action_locked = false
var _weather = null
var _child_cache = {}  # trait name -> node or null; sight range and radius reads are hot

@onready var _match = find_parent("Match")


func _ready():
	if not _match.is_node_ready():
		await _match.ready
	_setup_default_properties_from_constants()  # may swap in the model from data
	_setup_color()
	assert(_safety_checks())


func take_damage(damage, attacker):
	if has_meta("surrendering"):
		return  # a city centre under the white flag (see CityCentres.gd)
	if attacker != null and is_instance_valid(attacker) and "player" in attacker:
		if not Diplomacy.register_hit(attacker.player, player):
			return  # a pact or an alliance protects us from them
		last_attacker_player = attacker.player
		if attacker.is_in_group("units"):  # units on return fire shoot back at it
			set_meta("last_hit_by", attacker)
			set_meta("last_hit_at_ms", Time.get_ticks_msec())
	var hp_before = hp
	hp -= damage
	if hp < hp_before:
		# only real hits count; construction sites also lower hp when they are laid out
		MatchSignals.unit_damaged.emit(self)


func is_revealing():
	return is_in_group("revealed_units") and visible


func _set_hp(value):
	hp = max(0, value)
	hp_changed.emit()
	if hp == 0:
		_handle_unit_death()


func _set_hp_max(value):
	hp_max = value
	hp_changed.emit()


func _get_radius():
	var movement = _cached_child("Movement")
	if movement != null:
		return movement.radius
	var obstacle = _cached_child("MovementObstacle")
	if obstacle != null:
		return obstacle.radius
	return null


func _get_movement_domain():
	return Constants.Match.Navigation.surface(_get_navigation_domain())


func _get_navigation_domain():
	var movement = _cached_child("Movement")
	if movement != null:
		return movement.domain
	var obstacle = _cached_child("MovementObstacle")
	if obstacle != null:
		return obstacle.domain
	return null


func _get_movement_speed():
	var movement = _cached_child("Movement")
	if movement != null:
		return movement.speed
	return 0.0


func get_movement_trait():
	return _cached_child("Movement")


func _cached_child(child_name):
	"""find_child walks the whole model, which is too slow for the per-tick reads above"""
	if child_name in _child_cache:
		var cached = _child_cache[child_name]
		if cached == null or (is_instance_valid(cached) and cached.get_parent() != null):
			return cached
	var node = find_child(child_name)
	if is_inside_tree():
		_child_cache[child_name] = node  # before entering the tree traits may still be added
	return node


func _is_movable():
	return _get_movement_speed() > 0.0


func _setup_color():
	var material = player.get_color_material()
	Utils.Match.traverse_node_tree_and_replace_materials_matching_albedo(
		find_child("Geometry"),
		MATERIAL_ALBEDO_TO_REPLACE,
		MATERIAL_ALBEDO_TO_REPLACE_EPSILON,
		material
	)


func _set_action(action_node):
	if not is_inside_tree() or _action_locked:
		if action_node != null:
			action_node.queue_free()
		return
	_action_locked = true
	_teardown_current_action()
	action = action_node
	if action != null:
		var action_copy = action  # bind() performs copy itself, but lets force copy just in case
		action.tree_exited.connect(_on_action_node_tree_exited.bind(action_copy))
		add_child(action_node)
	_action_locked = false
	action_changed.emit(action)


func _scene_path():
	if scene_file_path != "":
		return scene_file_path  # also covers data-only units built from a base scene
	return get_script().resource_path.replace(".gd", ".tscn")


func _get_type():
	var unit_script_path = get_script().resource_path
	var unit_file_name = unit_script_path.substr(unit_script_path.rfind("/") + 1)
	var unit_name = unit_file_name.split(".")[0]
	return unit_name


func _teardown_current_action():
	if action != null and action.is_inside_tree():
		action.queue_free()
		remove_child(action)  # triggers _on_action_node_tree_exited immediately


func _safety_checks():
	if movement_domain == Constants.Match.Navigation.Domain.AIR:
		assert(
			(
				radius < Constants.Match.Air.Navmesh.MAX_AGENT_RADIUS
				or is_equal_approx(radius, Constants.Match.Air.Navmesh.MAX_AGENT_RADIUS)
			),
			"Unit radius exceeds the established limit"
		)
	elif movement_domain == Constants.Match.Navigation.Domain.TERRAIN:
		assert(
			(
				not _is_movable()
				or (
					radius < Constants.Match.Terrain.Navmesh.MAX_AGENT_RADIUS
					or is_equal_approx(radius, Constants.Match.Terrain.Navmesh.MAX_AGENT_RADIUS)
				)
			),
			"Unit radius exceeds the established limit"
		)
	return true


func get_lootable_cargo():
	"""goods carried or stored by the unit; part of them goes to whoever destroys it"""
	return {}


func _handle_unit_death():
	_hand_out_loot()
	tree_exited.connect(func(): MatchSignals.unit_died.emit(self))
	queue_free()


func _hand_out_loot():
	var cargo = get_lootable_cargo()
	if cargo.is_empty():
		return
	var looter = last_attacker_player
	var loot = {}
	if looter != null and is_instance_valid(looter) and looter != player:
		for resource in cargo:
			var amount = int(floor(cargo[resource] * Constants.Match.Logistics.LOOT_SHARE))
			if amount > 0:
				loot[resource] = amount
		looter.add_resources(loot)
	else:
		looter = null
	MatchSignals.cargo_destroyed.emit(self, player, cargo, looter, loot)


func _setup_default_properties_from_constants():
	var scene_path = _scene_path()
	var default_properties = Constants.Match.Units.DEFAULT_PROPERTIES[scene_path]
	for property in default_properties:
		set(property, default_properties[property])
	var entry = GameData.unit_by_scene(scene_path)
	if entry != null and "model" in entry and not GameData.is_generated_scene(scene_path):
		GameData.apply_model(self, entry)  # art swapped in from data/units/*.json
	var movement = find_child("Movement")
	if movement != null and scene_path in Constants.Match.Units.SPEEDS:
		movement.speed = Constants.Match.Units.SPEEDS[scene_path]
	if (
		scene_path in Constants.Match.Air.FLIGHT_ENDURANCE_S
		and get_node_or_null("FixedWingFlight") == null
	):
		var flight = load("res://source/match/units/traits/FixedWingFlight.gd").new()
		flight.name = "FixedWingFlight"
		flight.endurance_s = float(Constants.Match.Air.FLIGHT_ENDURANCE_S[scene_path])
		add_child(flight)


func _on_action_node_tree_exited(action_node):
	assert(action_node == action, "unexpected action released")
	action = null
