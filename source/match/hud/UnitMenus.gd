extends PanelContainer

const VehicleFactory = preload("res://source/match/units/VehicleFactory.gd")
const AircraftFactory = preload("res://source/match/units/AircraftFactory.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const ExtractorMenu = preload("res://source/match/hud/unit-menus/ExtractorMenu.gd")
const FleetMenu = preload("res://source/match/hud/unit-menus/FleetMenu.gd")
const Storage = preload("res://source/match/units/Storage.gd")

@onready var _generic_menu = find_child("GenericMenu")
@onready var _command_center_menu = find_child("CommandCenterMenu")
@onready var _vehicle_factory_menu = find_child("VehicleFactoryMenu")
@onready var _aircraft_factory_menu = find_child("AircraftFactoryMenu")
@onready var _worker_menu = find_child("WorkerMenu")
@onready var _extractor_menu = _create_extractor_menu()
@onready var _fleet_menu = _create_fleet_menu()


func _ready():
	_reset_menus()
	MatchSignals.unit_selected.connect(func(_unit): _reset_menus())
	MatchSignals.unit_deselected.connect(func(_unit): _reset_menus())
	MatchSignals.unit_died.connect(func(_unit): _reset_menus())


func _reset_menus():
	_hide_all_menus()
	if _try_showing_any_menu():
		show()
	else:
		hide()


func _hide_all_menus():
	_generic_menu.hide()
	_command_center_menu.hide()
	_vehicle_factory_menu.hide()
	_aircraft_factory_menu.hide()
	_worker_menu.hide()
	_extractor_menu.hide()
	_fleet_menu.hide()


func _try_showing_any_menu():
	var selected_controlled_units = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return unit.is_in_group("controlled_units")
	)
	if (
		selected_controlled_units.size() == 1
		and selected_controlled_units[0] is CommandCenter
		and selected_controlled_units[0].is_constructed()
	):
		_command_center_menu.unit = selected_controlled_units[0]
		_command_center_menu.show()
		return true
	if (
		selected_controlled_units.size() == 1
		and selected_controlled_units[0] is VehicleFactory
		and selected_controlled_units[0].is_constructed()
	):
		_vehicle_factory_menu.unit = selected_controlled_units[0]
		_vehicle_factory_menu.show()
		return true
	if (
		selected_controlled_units.size() == 1
		and selected_controlled_units[0] is AircraftFactory
		and selected_controlled_units[0].is_constructed()
	):
		_aircraft_factory_menu.unit = selected_controlled_units[0]
		_aircraft_factory_menu.show()
		return true
	if (
		selected_controlled_units.size() == 1
		and (selected_controlled_units[0] is Extractor or selected_controlled_units[0] is Storage)
		and selected_controlled_units[0].is_constructed()
	):
		_extractor_menu.unit = selected_controlled_units[0]
		_extractor_menu.show()
		return true
	if selected_controlled_units.size() == 1 and selected_controlled_units[0] is Worker:
		_worker_menu.show()
	if FleetMenu.applies_to(selected_controlled_units):
		_fleet_menu.units = selected_controlled_units
		_fleet_menu.show()
	if selected_controlled_units.size() > 0:
		_generic_menu.units = selected_controlled_units
		_generic_menu.show()
		return true
	return false


func _create_fleet_menu():
	var menu = FleetMenu.new()
	menu.name = "FleetMenu"
	_generic_menu.add_sibling(menu)
	return menu


func _create_extractor_menu():
	var menu = ExtractorMenu.new()
	menu.name = "ExtractorMenu"
	_generic_menu.add_sibling(menu)
	return menu
