extends Control

const SaveGame = preload("res://source/match/SaveGame.gd")

var match_settings = null
var map_path = null
var saved_game = null  # a save from SaveGame.gd: settings and map come from it

@onready var _label = find_child("Label")
@onready var _progress_bar = find_child("ProgressBar")


func _ready():
	_progress_bar.value = 0.0
	if saved_game != null:
		match_settings = SaveGame.settings_from(saved_game)
		map_path = saved_game["map"]

	_label.text = tr("LOADING_STEP_PRELOADING")
	await get_tree().physics_frame
	_preload_scenes()
	_progress_bar.value = 0.2

	_label.text = tr("LOADING_STEP_LOADING_MAP")
	await get_tree().physics_frame
	var map = load(map_path).instantiate()
	_progress_bar.value = 0.4

	_label.text = tr("LOADING_STEP_LOADING_MATCH")
	await get_tree().physics_frame
	var match_prototype = load("res://source/match/Match.tscn")
	_progress_bar.value = 0.7

	_label.text = tr("LOADING_STEP_INSTANTIATING_MATCH")
	await get_tree().physics_frame
	var a_match = match_prototype.instantiate()
	a_match.settings = match_settings
	a_match.map = map
	# --no-build-up skips the starter city animation (automated runs)
	a_match.play_city_build_up = (
		saved_game == null and not "--no-build-up" in OS.get_cmdline_user_args()
	)
	a_match.saved_state = saved_game
	_progress_bar.value = 0.9

	_label.text = tr("LOADING_STEP_STARTING_MATCH")
	await get_tree().physics_frame
	get_parent().add_child(a_match)
	get_tree().current_scene = a_match
	queue_free()


func _preload_scenes():
	preload("res://source/data-model/GameData.gd").register_generated_scenes()
	var scene_paths = []
	scene_paths += Constants.Match.Units.PROJECTILES.values()
	scene_paths += Constants.Match.Units.CONSTRUCTION_COSTS.keys()
	for scene_path in scene_paths:
		Globals.cache[scene_path] = load(scene_path)
