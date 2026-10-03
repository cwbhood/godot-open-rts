extends Node3D

# a house or workshop the city places on its own; not a unit, but it takes up
# space so that structures and freshly produced units are not placed on top of it

var kind = null
var radius = Constants.Match.City.BUILDING_RADIUS_M
var revealed_once = false


func _ready():
	add_to_group("city_buildings")
	var model = load(Constants.Match.City.BUILDING_MODELS[kind]).instantiate()
	model.scale = Vector3.ONE * (0.6 if kind == "house" else 0.8)
	add_child(model)
