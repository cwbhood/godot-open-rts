extends GridContainer

const TankUnit = preload("res://source/match/units/Tank.tscn")
const HeavyTankUnit = preload("res://source/match/units/HeavyTank.tscn")

var unit = null

@onready var _tank_button = find_child("ProduceTankButton")
@onready var _heavy_tank_button = find_child("ProduceHeavyTankButton")


func _ready():
	_tank_button.tooltip_text = _unit_tooltip(TankUnit, "TANK")
	_heavy_tank_button.tooltip_text = _unit_tooltip(HeavyTankUnit, "HEAVY_TANK")


func _process(_delta):
	var required_tech = Constants.Match.Units.TECH_REQUIREMENTS[HeavyTankUnit.resource_path]
	_heavy_tank_button.disabled = (
		unit == null or not is_instance_valid(unit) or not unit.player.has_tech(required_tech)
	)


func _unit_tooltip(unit_scene, name_key):
	var properties = Constants.Match.Units.DEFAULT_PROPERTIES[unit_scene.resource_path]
	return "{0} - {1}\n{2} HP, {3} DPS\n{4}: {5}, {6}: {7}".format(
		[
			tr(name_key),
			tr(name_key + "_DESCRIPTION"),
			properties["hp_max"],
			properties["attack_damage"] * properties["attack_interval"],
			tr("RESOURCE_A"),
			Constants.Match.Units.PRODUCTION_COSTS[unit_scene.resource_path]["resource_a"],
			tr("RESOURCE_B"),
			Constants.Match.Units.PRODUCTION_COSTS[unit_scene.resource_path]["resource_b"]
		]
	)


func _on_produce_tank_button_pressed():
	unit.production_queue.produce(TankUnit)


func _on_produce_heavy_tank_button_pressed():
	unit.production_queue.produce(HeavyTankUnit)
