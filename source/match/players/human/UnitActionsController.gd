extends Node

const Structure = preload("res://source/match/units/Structure.gd")
const ResourceUnit = preload("res://source/match/units/non-player/ResourceUnit.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const UnitCommands = preload("res://source/match/players/human/UnitCommands.gd")
const Storage = preload("res://source/match/units/Storage.gd")


class Actions:
	const Moving = preload("res://source/match/units/actions/Moving.gd")
	const MovingToUnit = preload("res://source/match/units/actions/MovingToUnit.gd")
	const Following = preload("res://source/match/units/actions/Following.gd")
	const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
	const Constructing = preload("res://source/match/units/actions/Constructing.gd")
	const Escorting = preload("res://source/match/units/actions/Escorting.gd")
	const Landing = preload("res://source/match/units/actions/Landing.gd")


func _ready():
	MatchSignals.terrain_targeted.connect(_on_terrain_targeted)
	MatchSignals.unit_targeted.connect(_on_unit_targeted)
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	MatchSignals.navigate_unit_to_rally_point.connect(_on_navigate_unit_to_rally_point)


func _try_navigating_selected_units_towards_position(target_point):
	var terrain_units_to_move = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit):
			return (
				unit.is_in_group("controlled_units")
				and unit.movement_domain == Constants.Match.Navigation.Domain.TERRAIN
				and Actions.Moving.is_applicable(unit)
			)
	)
	var air_units_to_move = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit):
			return (
				unit.is_in_group("controlled_units")
				and unit.movement_domain == Constants.Match.Navigation.Domain.AIR
				and Actions.Moving.is_applicable(unit)
			)
	)
	if Input.is_action_pressed("shift_selecting"):
		# Shift: the move is carried out after the orders the units already have
		UnitCommands.point_order(
			terrain_units_to_move + air_units_to_move, target_point, "move", true
		)
		return
	var new_unit_targets = Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(
		terrain_units_to_move, target_point
	)
	new_unit_targets += Utils.Match.Unit.Movement.crowd_moved_to_new_pivot(
		air_units_to_move, target_point
	)
	for tuple in new_unit_targets:
		var unit = tuple[0]
		var new_target = tuple[1]
		if unit is Hauler:
			unit.automated = false  # manually driven haulers wait for orders
			unit.recycling = false
			unit.dedicated_extractor = null
			unit.road_speed_multiplier = 1.0
		unit.action = Actions.Moving.new(new_target)


func _try_setting_rally_points(target_point: Vector3):
	var controlled_structures = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit):
			return unit.is_in_group("controlled_units") and unit.find_child("RallyPoint") != null
	)
	for structure in controlled_structures:
		var rally_point = structure.find_child("RallyPoint")
		if rally_point != null:
			rally_point.target_unit = null
			rally_point.global_position = target_point


func _try_ordering_selected_workers_to_construct_structure(potential_structure):
	if not potential_structure is Structure or potential_structure.is_constructed():
		return
	var structure = potential_structure
	var selected_constructors = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit):
			return (
				unit.is_in_group("controlled_units")
				and Actions.Constructing.is_applicable(unit, structure)
			)
	)
	for unit in selected_constructors:
		unit.action = Actions.Constructing.new(structure)


func _navigate_selected_units_towards_unit(target_unit):
	var at_least_one_unit_navigated = false
	for unit in get_tree().get_nodes_in_group("selected_units"):
		if not unit.is_in_group("controlled_units"):
			continue
		if _navigate_unit_towards_unit(unit, target_unit):
			at_least_one_unit_navigated = true
	return at_least_one_unit_navigated


func _navigate_unit_towards_unit(unit, target_unit):
	if unit is Hauler and _order_hauler(unit, target_unit):
		return true
	if unit.get("is_train") == true:
		return _order_train(unit, target_unit)
	if Actions.AutoAttacking.is_applicable(unit, target_unit):
		unit.action = Actions.AutoAttacking.new(target_unit)
		return true
	if Actions.Constructing.is_applicable(unit, target_unit):
		unit.action = Actions.Constructing.new(target_unit)
		return true
	if Actions.Landing.is_applicable(unit, target_unit):
		unit.action = Actions.Landing.new(target_unit)  # land and refuel
		return true
	if target_unit is Hauler and Actions.Escorting.is_applicable(unit, target_unit):
		unit.action = Actions.Escorting.new(target_unit)  # convoy escort
		return true
	if (
		(target_unit.is_in_group("adversary_units") or target_unit.is_in_group("controlled_units"))
		and Actions.Following.is_applicable(unit)
	):
		unit.action = Actions.Following.new(target_unit)
		return true
	if Actions.MovingToUnit.is_applicable(unit):
		unit.action = Actions.MovingToUnit.new(target_unit)
		return true
	if _try_setting_rally_point_to_unit(unit, target_unit):
		return true
	return false  # gdlint: ignore = max-returns


func _order_hauler(hauler, target_unit):
	"""own extractor: serve only that extractor, own depot: back to automatic logistics,
	own construction site: bring materials there"""
	if not "player" in target_unit or target_unit.player != hauler.player:
		return false
	var logistics = hauler.player.logistics
	hauler.recycling = false
	if (target_unit is Extractor or target_unit is Storage) and target_unit.is_constructed():
		hauler.automated = true
		hauler.dedicated_extractor = target_unit
		hauler.action = null
		return true
	if target_unit is CommandCenter and target_unit.is_constructed():
		hauler.automated = true
		hauler.dedicated_extractor = null
		hauler.action = null
		return true
	if target_unit is Structure and target_unit.needs_materials() and logistics != null:
		hauler.automated = true
		hauler.dedicated_extractor = null
		hauler.action = null
		return logistics.assign_supply(hauler, target_unit)
	return false


func _order_train(train, target_unit):
	"""own extractor or storage: add or remove that stop, own depot: the train's new home"""
	if not "player" in target_unit or target_unit.player != train.player:
		return false
	if (target_unit is Extractor or target_unit is Storage) and target_unit.is_constructed():
		train.toggle_stop(target_unit)
		return true
	if target_unit is CommandCenter and target_unit.is_constructed():
		train.depot = target_unit
		train.set_line(train.stops, train.manual_line)
		return true
	return false


func _try_setting_rally_point_to_unit(unit, target_unit):
	if not unit is Structure:
		return false
	if not target_unit is ResourceUnit and unit.player != target_unit.player:
		# it's not allowed to set rally point to enemy at the moment as with current implementation
		# the position of enemy unit hidden in the fog of war could be hinted
		return false
	var rally_point = unit.find_child("RallyPoint")
	if rally_point == null:
		return false
	rally_point.target_unit = target_unit
	return true


func _on_terrain_targeted(position):
	_try_navigating_selected_units_towards_position(position)
	_try_setting_rally_points(position)


func _on_unit_targeted(unit):
	if _navigate_selected_units_towards_unit(unit):
		var targetability = unit.find_child("Targetability")
		if targetability != null:
			targetability.animate()


func _on_unit_spawned(unit):
	if unit.get_meta("placed_by_hand", false):
		# sites laid out by auto-expanding constructors must not pull the selected ones away
		_try_ordering_selected_workers_to_construct_structure(unit)


func _on_navigate_unit_to_rally_point(unit, rally_point):
	if rally_point.target_unit != null:
		_navigate_unit_towards_unit(unit, rally_point.target_unit)
	elif (
		rally_point.global_position != rally_point.get_parent().global_position
		and Actions.Moving.is_applicable(unit)
	):  # trains run on their rails
		unit.action = Actions.Moving.new(rally_point.global_position)
