extends Button

# Main menu entry for the map editor (source/map-editor/MapEditor.tscn).


func _ready():
	text = tr("MAP_EDITOR")
	pressed.connect(
		func(): get_tree().change_scene_to_file("res://source/map-editor/MapEditor.tscn")
	)
