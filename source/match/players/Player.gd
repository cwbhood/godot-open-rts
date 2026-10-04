extends Node3D

signal changed

@export var timber = 0:
	set(value):
		timber = value
		emit_changed()
@export var iron = 0:
	set(value):
		iron = value
		emit_changed()
@export var copper = 0:
	set(value):
		copper = value
		emit_changed()
@export var oil = 0:
	set(value):
		oil = value
		emit_changed()
@export var color = Color.WHITE
# AI difficulty handicaps and bonuses (data/difficulties/); 1.0 for everybody else
var gather_rate = 1.0  # share of hauled goods that reaches the stock
var production_speed = 1.0  # speed of the factories' production queues

var city:
	get:
		return get_node_or_null("City")
var power_grid:
	get:
		return get_node_or_null("PowerGrid")
var logistics:
	get:
		return get_node_or_null("Logistics")

var _color_material = null
var _extra_stock = {}  # commodities added in data/ beyond the four exported above


func _get(property):
	if property in _extra_stock:
		return _extra_stock[property]
	if property in Constants.Match.Resources.ALL:
		return 0
	return null


func _set(property, value):
	if property in Constants.Match.Resources.ALL:  # only reached for undeclared ones
		_extra_stock[property] = value
		emit_changed()
		return true
	return false


func add_resources(resources):
	for resource in resources:
		set(resource, get(resource) + resources[resource])


func has_resources(resources):
	if FeatureFlags.allow_resources_deficit_spending:
		return true
	for resource in resources:
		if get(resource) < resources[resource]:
			return false
	return true


func subtract_resources(resources):
	for resource in resources:
		set(resource, get(resource) - resources[resource])


func get_stock():
	var stock = {}
	for resource in Constants.Match.Resources.ALL:
		stock[resource] = get(resource)
	return stock


func get_tier():
	return city.tier if city != null else 1


func has_tier(tier):
	return get_tier() >= tier


func meets_tier_requirement(scene_path):
	return has_tier(int(Constants.Match.Units.TIER_REQUIREMENTS.get(scene_path, 1)))


func needs_airport_for(scene_path):
	"""fixed-wing aircraft can only be produced once there is an airport to land at"""
	return scene_path in Constants.Match.Air.FLIGHT_ENDURANCE_S and not has_airport()


func has_airport():
	return get_tree().get_nodes_in_group("airports").any(
		func(airport): return airport.player == self and airport.is_constructed()
	)


func can_produce(scene_path):
	return meets_tier_requirement(scene_path) and not needs_airport_for(scene_path)


func get_production_multiplier():
	return (city.production_multiplier if city != null else 1.0) * production_speed


func get_color_material():
	if _color_material == null:
		_color_material = StandardMaterial3D.new()
		_color_material.vertex_color_use_as_albedo = true
		_color_material.albedo_color = color
		_color_material.roughness = 0.55
	return _color_material


func emit_changed():
	changed.emit()
