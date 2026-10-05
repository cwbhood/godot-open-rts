extends Node3D

const Unit = preload("res://source/match/units/Unit.gd")

# a house or workshop the city places on its own; not a unit, but it takes up
# space so that structures and freshly produced units are not placed on top of it

var kind = null
var variant = -1  # index into the kind's models; random when left at -1
var player = null  # whose colour the team-coloured surfaces take; defaults to the city's
var radius = Constants.Match.City.BUILDING_RADIUS_M
var revealed_once = false


func _ready():
	add_to_group("city_buildings")
	var models = Constants.Match.City.BUILDING_MODELS[kind]
	if variant < 0:
		variant = randi()
	var model = load(models[variant % models.size()]).instantiate()
	add_child(model)
	if player == null and "player" in get_parent():
		player = get_parent().player
	if player != null:
		Utils.Match.traverse_node_tree_and_replace_materials_matching_albedo(
			model,
			Unit.MATERIAL_ALBEDO_TO_REPLACE,
			Unit.MATERIAL_ALBEDO_TO_REPLACE_EPSILON,
			player.get_color_material()
		)
