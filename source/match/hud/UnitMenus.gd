extends PanelContainer

const VehicleFactory = preload("res://source/match/units/VehicleFactory.gd")
const AircraftFactory = preload("res://source/match/units/AircraftFactory.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const ExtractorMenu = preload("res://source/match/hud/unit-menus/ExtractorMenu.gd")
const FleetMenu = preload("res://source/match/hud/unit-menus/FleetMenu.gd")
const Storage = preload("res://source/match/units/Storage.gd")
const Shipyard = preload("res://source/match/units/Shipyard.gd")
const BuildMenu = preload("res://source/match/hud/unit-menus/BuildMenu.gd")

var _shown = []

@onready var _generic_menu = find_child("GenericMenu")
@onready var _command_center_menu = find_child("CommandCenterMenu")
@onready var _vehicle_factory_menu = find_child("VehicleFactoryMenu")
@onready var _aircraft_factory_menu = find_child("AircraftFactoryMenu")
@onready var _worker_menu = find_child("WorkerMenu")
@onready var _extractor_menu = _create_extractor_menu()
@onready var _fleet_menu = _create_fleet_menu()
@onready var _shipyard_menu = _create_shipyard_menu()


func _ready():
	# no grey placeholder squares: the menus size the panel to the rows they use
	find_child("BackgroundGrid").hide()
	for index in range(12, 17):
		var padding = _generic_menu.get_node_or_null("Padding%d" % index)
		if padding != null:
			padding.hide()
	_generic_menu.find_child("CancelActionButton").theme_type_variation = "SlotButton"
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
		_extractor_menu,
		_shipyard_menu,
		_fleet_menu
	]


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
		_shown.append(_worker_menu)
	if FleetMenu.applies_to(selected_controlled_units):
		_fleet_menu.units = selected_controlled_units
		_shown.append(_fleet_menu)
	if selected_controlled_units.size() > 0:
		_generic_menu.units = selected_controlled_units
		_shown.append(_generic_menu)
		return true
	return false


func _create_fleet_menu():
	var menu = FleetMenu.new()
	menu.name = "FleetMenu"
	_generic_menu.add_sibling(menu)
	return menu


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
		[Storage, _extractor_menu],
	]:
		if is_instance_of(unit, entry[0]):
			entry[1].unit = unit
			_shown.append(entry[1])
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
