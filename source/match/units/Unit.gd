extends Area3D

signal selected
signal deselected
signal hp_changed
signal action_changed(new_action)
signal action_updated

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
var movement_domain:
	get = _get_movement_domain
var movement_speed:
	get = _get_movement_speed
var sight_range = null:
	get:
		if sight_range == null or _match == null:
			return sight_range
		var weather = _match.get_node_or_null("WeatherEffects")
		if weather == null:
			return sight_range
		return sight_range * weather.get_vision_multiplier(global_position, movement_domain)
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

@onready var _match = find_parent("Match")


func _ready():
	if not _match.is_node_ready():
		await _match.ready
	_setup_color()
	_setup_default_properties_from_constants()
	assert(_safety_checks())


func take_damage(damage, attacker):
	if attacker != null and is_instance_valid(attacker) and "player" in attacker:
		last_attacker_player = attacker.player
	hp -= damage


func is_revealing():
	return is_in_group("revealed_units") and visible


func _set_hp(value):
	var old_hp = hp
	hp = max(0, value)
	if old_hp != null and hp < old_hp:
		MatchSignals.unit_damaged.emit(self)
	hp_changed.emit()
	if hp == 0:
		_handle_unit_death()


func _set_hp_max(value):
	hp_max = value
	hp_changed.emit()


func _get_radius():
	if find_child("Movement") != null:
		return find_child("Movement").radius
	if find_child("MovementObstacle") != null:
		return find_child("MovementObstacle").radius
	return null


func _get_movement_domain():
	if find_child("Movement") != null:
		return find_child("Movement").domain
	if find_child("MovementObstacle") != null:
		return find_child("MovementObstacle").domain
	return null


func _get_movement_speed():
	if find_child("Movement") != null:
		return find_child("Movement").speed
	return 0.0


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
	var default_properties = Constants.Match.Units.DEFAULT_PROPERTIES[
		get_script().resource_path.replace(".gd", ".tscn")
	]
	for property in default_properties:
		set(property, default_properties[property])


func _on_action_node_tree_exited(action_node):
	assert(action_node == action, "unexpected action released")
	action = null
