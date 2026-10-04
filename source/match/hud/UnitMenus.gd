extends PanelContainer

const VehicleFactory = preload("res://source/match/units/VehicleFactory.gd")
const AircraftFactory = preload("res://source/match/units/AircraftFactory.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const ExtractorMenu = preload("res://source/match/hud/unit-menus/ExtractorMenu.gd")

var _shown = []

@onready var _generic_menu = find_child("GenericMenu")
@onready var _command_center_menu = find_child("CommandCenterMenu")
@onready var _vehicle_factory_menu = find_child("VehicleFactoryMenu")
@onready var _aircraft_factory_menu = find_child("AircraftFactoryMenu")
@onready var _worker_menu = find_child("WorkerMenu")
@onready var _extractor_menu = _create_extractor_menu()


func _ready():
	_reset_menus()
	MatchSignals.unit_selected.connect(func(_unit): _reset_menus())
	MatchSignals.unit_deselected.connect(func(_unit): _reset_menus())
	MatchSignals.unit_died.connect(func(_unit): _reset_menus())


# Only menus whose visibility really changes are touched: hiding a button, even for one
# frame, cancels a click in progress, and unit_died fires for every unit on the map.
func _reset_menus():
	_shown.clear()
	visible = _try_showing_any_menu()
	for menu in _all_menus():
		menu.visible = menu in _shown


func _all_menus():
	return [
		_generic_menu,
		_command_center_menu,
		_vehicle_factory_menu,
		_aircraft_factory_menu,
		_worker_menu,
		_extractor_menu
	]


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
		_shown.append(_command_center_menu)
		return true
	if (
		selected_controlled_units.size() == 1
		and selected_controlled_units[0] is VehicleFactory
		and selected_controlled_units[0].is_constructed()
	):
		_vehicle_factory_menu.unit = selected_controlled_units[0]
		_shown.append(_vehicle_factory_menu)
		return true
	if (
		selected_controlled_units.size() == 1
		and selected_controlled_units[0] is AircraftFactory
		and selected_controlled_units[0].is_constructed()
	):
		_aircraft_factory_menu.unit = selected_controlled_units[0]
		_shown.append(_aircraft_factory_menu)
		return true
	if (
		selected_controlled_units.size() == 1
		and selected_controlled_units[0] is Extractor
		and selected_controlled_units[0].is_constructed()
	):
		_extractor_menu.unit = selected_controlled_units[0]
		_shown.append(_extractor_menu)
		return true
	if selected_controlled_units.size() == 1 and selected_controlled_units[0] is Worker:
		_shown.append(_worker_menu)
	if selected_controlled_units.size() > 0:
		_generic_menu.units = selected_controlled_units
		_shown.append(_generic_menu)
		return true
	return false


func _create_extractor_menu():
	var menu = ExtractorMenu.new()
	menu.name = "ExtractorMenu"
	_generic_menu.add_sibling(menu)
	return menu
