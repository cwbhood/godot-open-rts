extends PanelContainer

const VehicleFactory = preload("res://source/match/units/VehicleFactory.gd")
const AircraftFactory = preload("res://source/match/units/AircraftFactory.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const ExtractorMenu = preload("res://source/match/hud/unit-menus/ExtractorMenu.gd")
const Shipyard = preload("res://source/match/units/Shipyard.gd")
const BuildMenu = preload("res://source/match/hud/unit-menus/BuildMenu.gd")

@onready var _generic_menu = find_child("GenericMenu")
@onready var _command_center_menu = find_child("CommandCenterMenu")
@onready var _vehicle_factory_menu = find_child("VehicleFactoryMenu")
@onready var _aircraft_factory_menu = find_child("AircraftFactoryMenu")
@onready var _worker_menu = find_child("WorkerMenu")
@onready var _extractor_menu = _create_extractor_menu()
@onready var _shipyard_menu = _create_shipyard_menu()


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
	_shipyard_menu.hide()


func _try_showing_any_menu():
	var selected_controlled_units = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return unit.is_in_group("controlled_units")
	)
	if (
		selected_controlled_units.size() == 1
		and _try_showing_structure_menu(selected_controlled_units[0])
	):
		return true
	if selected_controlled_units.size() == 1 and selected_controlled_units[0] is Worker:
		_worker_menu.show()
	if selected_controlled_units.size() > 0:
		_generic_menu.units = selected_controlled_units
		_generic_menu.show()
		return true
	return false


func _try_showing_structure_menu(unit):
	"""the production or extractor menu of a single selected, finished structure"""
	if not unit.has_method("is_constructed") or not unit.is_constructed():
		return false
	for entry in [
		[CommandCenter, _command_center_menu],
		[VehicleFactory, _vehicle_factory_menu],
		[Shipyard, _shipyard_menu],
		[AircraftFactory, _aircraft_factory_menu],
		[Extractor, _extractor_menu],
	]:
		if is_instance_of(unit, entry[0]):
			entry[1].unit = unit
			entry[1].show()
			return true
	return false


func _create_extractor_menu():
	var menu = ExtractorMenu.new()
	menu.name = "ExtractorMenu"
	_generic_menu.add_sibling(menu)
	return menu


func _create_shipyard_menu():
	var menu = BuildMenu.new()
	menu.name = "ShipyardMenu"
	menu.producer_id = "shipyard"
	menu.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_generic_menu.add_sibling(menu)
	return menu
