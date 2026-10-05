extends "res://source/match/players/Player.gd"

const Helper = preload("res://source/match/players/human/Helper.gd")


func _ready():
	var helper = Helper.new()
	helper.name = Helper.NODE_NAME
	add_child(helper)
