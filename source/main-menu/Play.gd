extends Control

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const LoadingScene = preload("res://source/main-menu/Loading.tscn")
const StartPicker = preload("res://source/main-menu/StartPicker.gd")
const GameData = preload("res://source/data-model/GameData.gd")

var _map_paths = []
var _ai_personalities = []  # option index - SIMPLE_CLAIRVOYANT_AI -> personality id
var _sandbox_check_box = null

@onready var _start_button = find_child("StartButton")
@onready var _map_list = find_child("MapList")
@onready var _map_details = find_child("MapDetailsLabel")


func _ready():
	_setup_map_list()
	_on_map_list_item_selected(0)
	_setup_ai_personalities()
	_setup_sandbox_check_box()
	var option_nodes = find_child("GridContainer").find_children("OptionButton*")
	for option_node_id in range(option_nodes.size()):
		option_nodes[option_node_id].item_selected.connect(_on_player_selected.bind(option_node_id))


func _setup_ai_personalities():
	"""every AI personality from data/ai/ becomes its own entry in the player dropdowns"""
	var personalities = GameData.ai_personalities()
	personalities.sort_custom(
		func(a, b): return a["id"] == "balanced" or (b["id"] != "balanced" and a["id"] < b["id"])
	)
	_ai_personalities = personalities.map(func(personality): return personality["id"])
	for option_node in find_child("GridContainer").find_children("OptionButton*"):
		var selected = option_node.selected
		while option_node.item_count > Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI:
			option_node.remove_item(option_node.item_count - 1)
		for personality in personalities:
			option_node.add_item(tr("AI_PLAYER").format([tr(personality["name"])]))
			option_node.set_item_tooltip(
				option_node.item_count - 1, tr(personality.get("description", ""))
			)
		option_node.selected = min(selected, option_node.item_count - 1)


func _setup_sandbox_check_box():
	_sandbox_check_box = CheckBox.new()
	_sandbox_check_box.name = "SandboxCheckBox"
	_sandbox_check_box.text = tr("SANDBOX_MODE")
	_sandbox_check_box.tooltip_text = tr("SANDBOX_MODE_DESCRIPTION")
	_map_details.get_parent().add_child(_sandbox_check_box)


func _setup_map_list():
	var maps = Utils.Dict.items(Constants.Match.MAPS)
	maps.sort_custom(func(map_a, map_b): return map_a[1]["players"] < map_b[1]["players"])
	_map_paths = maps.map(func(map): return map[0])
	_map_list.clear()
	for map_path in _map_paths:
		_map_list.add_item(Constants.Match.MAPS[map_path]["name"])
	_map_list.select(0)


func _create_match_settings():
	var match_settings = MatchSettings.new()

	var option_nodes = find_child("GridContainer").find_children("OptionButton*")
	var spawn_index_offset = 0
	for option_node_id in range(option_nodes.size()):
		var player_controller = option_nodes[option_node_id].selected
		if not option_nodes[option_node_id].visible:
			break  # slots past the map's player count are hidden, they must not play
		if player_controller != Constants.PlayerType.NONE:
			var player_settings = PlayerSettings.new()
			if player_controller >= Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI:
				var personality_index = (
					player_controller - Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
				)
				if personality_index < _ai_personalities.size():
					player_settings.ai_personality = _ai_personalities[personality_index]
				player_controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
			player_settings.controller = player_controller
			player_settings.color = Constants.Player.COLORS[option_node_id]
			player_settings.spawn_index_offset = spawn_index_offset
			match_settings.players.append(player_settings)
			spawn_index_offset = 0
		else:
			spawn_index_offset += 1

	match_settings.visible_player = -1
	for player_id in range(match_settings.players.size()):
		var player = match_settings.players[player_id]
		if player.controller == Constants.PlayerType.HUMAN:
			match_settings.visible_player = player_id
	if match_settings.visible_player == -1:
		match_settings.visibility = match_settings.Visibility.ALL_PLAYERS
	match_settings.sandbox = _sandbox_check_box.button_pressed

	return match_settings


func _get_selected_map_path():
	return _map_paths[_map_list.get_selected_items()[0]]


func _on_start_button_pressed():
	hide()
	var match_settings = _create_match_settings()
	var new_scene = null
	if match_settings.players.any(
		func(player): return player.controller == Constants.PlayerType.HUMAN
	):
		new_scene = StartPicker.new()  # pick a start zone first, see StartPicker.gd
	else:
		new_scene = LoadingScene.instantiate()
	new_scene.match_settings = match_settings
	new_scene.map_path = _get_selected_map_path()
	get_parent().add_child(new_scene)
	get_tree().current_scene = new_scene
	queue_free()


func _on_back_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")


func _align_player_controls_visibility_to_map(map):
	var option_nodes = find_child("GridContainer").find_children("OptionButton*")
	var label_nodes = find_child("GridContainer").find_children("Label*")
	assert(option_nodes.size() == label_nodes.size())
	for node_id in range(option_nodes.size()):
		option_nodes[node_id].visible = node_id < map["players"]
		label_nodes[node_id].visible = node_id < map["players"]
	_refresh_start_button()


func _refresh_start_button():
	"""a match needs at least two players in the slots the map shows"""
	var players = find_child("GridContainer").find_children("OptionButton*").filter(
		func(option_node):
			return option_node.visible and option_node.selected != Constants.PlayerType.NONE
	)
	_start_button.disabled = players.size() < 2


func _on_player_selected(selected_option_id, selected_player_id):
	_start_button.disabled = false
	if selected_option_id == Constants.PlayerType.HUMAN:
		var option_nodes = find_child("GridContainer").find_children("OptionButton*")
		for option_node_id in range(option_nodes.size()):
			if (
				option_node_id != selected_player_id
				and option_nodes[option_node_id].selected == Constants.PlayerType.HUMAN
			):
				option_nodes[option_node_id].selected = (Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI)
	_refresh_start_button()


func _on_map_list_item_selected(index):
	var map = Constants.Match.MAPS[_map_paths[index]]
	_map_details.text = "[u]Players:[/u] {0}\n[u]Size:[/u] {1}x{2}".format(
		[map["players"], map["size"].x, map["size"].y]
	)
	_align_player_controls_visibility_to_map(map)
