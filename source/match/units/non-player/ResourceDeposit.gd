extends "res://source/match/units/non-player/ResourceUnit.gd"

# A natural deposit of a commodity (oil field, iron or copper ore, woods). It cannot be
# harvested by hand: a constructor builds an extractor next to it and haulers carry the
# extracted goods home. The deposit disappears once it runs dry.

signal depleted

@export var kind = "iron"  # id of a commodity from data/resources.json
@export var amount = -1  # -1 means the default amount for the kind
@export var tint_material: Material = null  # optional override for imported models

var color:
	get:
		return Constants.Match.Resources.COLORS[kind]


func _ready():
	add_to_group("deposits")
	if amount < 0:
		amount = Constants.Match.Resources.DEFAULT_DEPOSIT_AMOUNT[kind]
	if tint_material != null:
		for child in find_child("Geometry").find_children("*", "MeshInstance3D"):
			child.material_override = tint_material


func extract(requested):
	var taken = min(requested, amount)
	amount -= taken
	if amount <= 0:
		depleted.emit()
		queue_free()
	return taken
