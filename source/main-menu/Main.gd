extends Control


func _ready():
	var play_button = find_child("Button")
	var replays_button = Button.new()
	replays_button.name = "ReplaysButton"
	replays_button.text = tr("REPLAYS")
	replays_button.pressed.connect(
		func(): get_tree().change_scene_to_file("res://source/replay/ReplayViewer.tscn")
	)
	play_button.add_sibling(replays_button)


func _on_play_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Play.tscn")


func _on_options_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Options.tscn")


func _on_credits_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Credits.tscn")


func _on_quit_button_pressed():
	get_tree().quit()
