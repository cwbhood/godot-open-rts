extends "res://source/match/units/Unit.gd"

# Supply truck. Carries construction materials from a depot (command center) to remote
# construction sites and extracted goods from extractors back to a depot. Automated
# haulers get their jobs from the player's Logistics node. When a hauler is destroyed
# its cargo is lost and part of it is looted by the attacker.

var cargo = {}
var cargo_capacity = null
var cargo_site = null  # construction site the cargo is meant for, if any
var automated = true
var dedicated_extractor = null  # set when the player pins the hauler to one extractor
var road_speed_multiplier = 1.0  # set by Logistics from the road of the current route


func get_cargo_total():
	return Utils.Dict.sum(cargo)


func get_free_capacity():
	return cargo_capacity - get_cargo_total()


func get_lootable_cargo():
	return cargo


func load_cargo(goods, site = null):
	for resource in goods:
		Utils.Dict.add_amount(cargo, resource, goods[resource])
	if site != null:
		cargo_site = site
	action_updated.emit()


func unload_cargo():
	var unloaded = cargo
	cargo = {}
	cargo_site = null
	action_updated.emit()
	return unloaded


func _handle_unit_death():
	if cargo_site != null and is_instance_valid(cargo_site) and not cargo.is_empty():
		cargo_site.lose_materials_in_transit(cargo)
	super()
