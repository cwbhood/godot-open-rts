extends Node3D

const Unit = preload("res://source/match/units/Unit.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Player = preload("res://source/match/players/Player.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const City = preload("res://source/match/city/City.gd")
const Logistics = preload("res://source/match/economy/Logistics.gd")
const PowerGrid = preload("res://source/match/economy/PowerGrid.gd")
const WeatherEffects = preload("res://source/match/WeatherEffects.gd")
const Market = preload("res://source/match/economy/Market.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const DiplomacyHud = preload("res://source/match/hud/DiplomacyHud.gd")
const GameData = preload("res://source/data-model/GameData.gd")
const ReplayRecorder = preload("res://source/match/ReplayRecorder.gd")
const SandboxPanel = preload("res://source/match/hud/SandboxPanel.gd")
const Guide = preload("res://source/match/hud/Guide.gd")
const UnitCommandHandler = preload("res://source/match/handlers/UnitCommandHandler.gd")
const Keybinds = preload("res://source/match/Keybinds.gd")
const MatchLimits = preload("res://source/match/MatchLimits.gd")

const CommandCenter = preload("res://source/match/units/CommandCenter.tscn")
const Drone = preload("res://source/match/units/Drone.tscn")
const Worker = preload("res://source/match/units/Worker.tscn")
const Hauler = preload("res://source/match/units/Hauler.tscn")

@export var settings: Resource = null

var map:
	set = _set_map,
	get = _get_map
var visible_player = null:
	set = _set_visible_player
var visible_players = null:
	set = _ignore,
	get = _get_visible_players

var _feature_flags_before_sandbox = null

@onready var navigation = $Navigation
@onready var fog_of_war = $FogOfWar

@onready var _camera = $IsometricCamera3D
@onready var _players = $Players
@onready var _terrain = $Terrain


func _enter_tree():
	assert(settings != null, "match cannot start without settings, see examples in tests/manual/")
	assert(map != null, "match cannot start without map, see examples in tests/manual/")
	GameData.register_generated_scenes()
	if settings.get("sandbox"):
		_feature_flags_before_sandbox = {
			"allow_resources_deficit_spending": FeatureFlags.allow_resources_deficit_spending,
			"handle_match_end": FeatureFlags.handle_match_end,
		}
		FeatureFlags.allow_resources_deficit_spending = true
		FeatureFlags.handle_match_end = false
		settings.visibility = settings.Visibility.FULL


func _exit_tree():
	if _feature_flags_before_sandbox != null:
		for flag in _feature_flags_before_sandbox:
			FeatureFlags.set(flag, _feature_flags_before_sandbox[flag])


func _ready():
	add_to_group("match")  # the crash reporter reads map, players and match time from here
	if get_node_or_null("WeatherEffects") == null:
		var weather_effects = WeatherEffects.new()
		weather_effects.name = "WeatherEffects"
		add_child(weather_effects)
	if get_node_or_null("ReplayRecorder") == null:
		var replay_recorder = ReplayRecorder.new()
		replay_recorder.name = "ReplayRecorder"
		add_child(replay_recorder)
	if settings.get("sandbox"):
		var sandbox_panel = SandboxPanel.new()
		sandbox_panel.name = "SandboxPanel"
		sandbox_panel.position = Vector2(8, 48)
		$HUD.add_child(sandbox_panel)
	if $HUD.get_node_or_null("Guide") == null:
		$HUD.add_child(Guide.new())  # tutorial, hints, auto-expand overview and manual
	if get_node_or_null("MatchLimits") == null:  # unit, population and match-length caps
		var limits = MatchLimits.new()
		limits.name = "MatchLimits"
		add_child(limits)
	if get_node_or_null("Market") == null:
		var market = Market.new()
		market.name = "Market"
		add_child(market)
	if get_node_or_null("Diplomacy") == null:
		var diplomacy = Diplomacy.new()
		diplomacy.name = "Diplomacy"
		add_child(diplomacy)
	if $HUD.get_node_or_null("DiplomacyHud") == null:
		var diplomacy_hud = DiplomacyHud.new()
		diplomacy_hud.name = "DiplomacyHud"
		$HUD.add_child(diplomacy_hud)
	if get_node_or_null("UnitCommandHandler") == null:
		Keybinds.apply_overrides()
		# added last: its input runs before the selection box and the terrain's clicks
		add_child.call_deferred(UnitCommandHandler.new())
	MatchSignals.setup_and_spawn_unit.connect(_setup_and_spawn_unit)
	_setup_subsystems_dependent_on_map()
	_setup_players()
	_setup_player_units()
	visible_player = get_tree().get_nodes_in_group("players")[settings.visible_player]
	_move_camera_to_initial_position()
	if settings.visibility == settings.Visibility.FULL:
		fog_of_war.reveal()
	MatchSignals.match_started.emit()


func _unhandled_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if Input.is_action_pressed("shift_selecting"):
			return
		MatchSignals.deselect_all_units.emit()


func _set_map(a_map):
	assert(get_node_or_null("Map") == null, "map already set")
	a_map.name = "Map"
	add_child(a_map)
	a_map.owner = self


func _ignore(_value):
	pass


func _get_map():
	return get_node_or_null("Map")


func _set_visible_player(player):
	_conceal_player_units(visible_player)
	_reveal_player_units(player)
	visible_player = player


func _get_visible_players():
	if settings.visibility == settings.Visibility.PER_PLAYER:
		return [visible_player]
	return get_tree().get_nodes_in_group("players")


func _setup_subsystems_dependent_on_map():
	_terrain.update_shape(map.find_child("Terrain").mesh)
	fog_of_war.resize(map.size)
	_recalculate_camera_bounding_planes(map.size)
	navigation.setup(map)


func _recalculate_camera_bounding_planes(map_size: Vector2):
	_camera.bounding_planes[1] = Plane(-1, 0, 0, -map_size.x)
	_camera.bounding_planes[3] = Plane(0, 0, -1, -map_size.y)


func _setup_players():
	assert(
		_players.get_children().is_empty() or settings.players.is_empty(),
		"players can be defined either in settings or in scene tree, not in both"
	)
	if _players.get_children().is_empty():
		_create_players_from_settings()
	for node in _players.get_children():
		if node is Player:
			node.add_to_group("players")
			_setup_starting_stock(node)
			_setup_economy(node)


func _setup_starting_stock(player):
	if not player.get_stock().values().all(func(amount): return amount == 0):
		return  # predefined in the scene
	player.add_resources(Constants.Match.Resources.STARTING_STOCK)


func _setup_economy(player):
	for node_script in [City, Logistics, PowerGrid]:
		var node_name = node_script.resource_path.get_file().get_basename()
		if player.get_node_or_null(node_name) != null:
			continue
		var node = node_script.new()
		node.name = node_name
		player.add_child(node)


func _create_players_from_settings():
	for player_settings in settings.players:
		var player_scene = Constants.Match.Player.CONTROLLER_SCENES[player_settings.controller]
		var player = player_scene.instantiate()
		player.color = player_settings.color
		if "personality_id" in player and player_settings.get("ai_personality") != null:
			player.personality_id = player_settings.ai_personality
		if "difficulty_id" in player and player_settings.get("ai_difficulty") != null:
			player.difficulty_id = player_settings.ai_difficulty
		if player_settings.get("start_zone") != null and player_settings.start_zone >= 0:
			player.set_meta("start_zone", player_settings.start_zone)
			player.set_meta("start_position", player_settings.start_position)
		if player_settings.spawn_index_offset > 0:
			for _i in range(player_settings.spawn_index_offset):
				_players.add_child(Node.new())
		_players.add_child(player)


func _setup_player_units():
	for player in _players.get_children():
		if not player is Player:
			continue
		var player_index = player.get_index()
		var predefined_units = player.get_children().filter(func(child): return child is Unit)
		if not predefined_units.is_empty():
			predefined_units.map(func(unit): _setup_unit_groups(unit, unit.player))
		else:
			_spawn_player_units(player, _start_transform(player, player_index))


func _start_transform(player, player_index):
	"""where a player's starter city stands: the spot picked on the start screen, facing the
	same way as its zone's spawn point, or the spawn point of the player's slot"""
	var spawn_points = map.find_child("SpawnPoints")
	var zone = player.get_meta("start_zone", -1)
	if zone < 0 or zone >= spawn_points.get_child_count():
		return spawn_points.get_child(player_index).global_transform
	var start_transform = spawn_points.get_child(zone).global_transform
	var spot = player.get_meta("start_position", Vector2.INF)
	if spot.is_finite():
		start_transform.origin = Vector3(spot.x, start_transform.origin.y, spot.y)
	return start_transform


func _spawn_player_units(player, spawn_transform):
	_setup_and_spawn_unit(CommandCenter.instantiate(), spawn_transform, player, false)
	_setup_and_spawn_unit(
		Drone.instantiate(), spawn_transform.translated(Vector3(-2, 0, -2)), player
	)
	_setup_and_spawn_unit(
		Worker.instantiate(), spawn_transform.translated(Vector3(-3, 0, 3)), player
	)
	_setup_and_spawn_unit(
		Worker.instantiate(), spawn_transform.translated(Vector3(3, 0, 3)), player
	)
	_setup_and_spawn_unit(
		Hauler.instantiate(), spawn_transform.translated(Vector3(-3, 0, -3)), player
	)
	_setup_and_spawn_unit(
		Hauler.instantiate(), spawn_transform.translated(Vector3(3, 0, -3)), player
	)


func _setup_and_spawn_unit(unit, a_transform, player, mark_structure_under_construction = true):
	unit.global_transform = a_transform
	if unit.get_meta("spawn_constructed", false):
		mark_structure_under_construction = false  # e.g. defense posts the city starts with
	if unit is Structure and mark_structure_under_construction:
		unit.mark_as_under_construction()
	_setup_unit_groups(unit, player)
	player.add_child(unit)
	MatchSignals.unit_spawned.emit(unit)


func _setup_unit_groups(unit, player):
	unit.add_to_group("units")
	if player == _get_human_player():
		unit.add_to_group("controlled_units")
	else:
		unit.add_to_group("adversary_units")
	if player in visible_players:
		unit.add_to_group("revealed_units")


func _get_human_player():
	var human_players = get_tree().get_nodes_in_group("players").filter(
		func(player): return player is Human
	)
	assert(human_players.size() <= 1, "more than one human player is not allowed")
	if not human_players.is_empty():
		return human_players[0]
	return null


func _move_camera_to_initial_position():
	var human_player = _get_human_player()
	if human_player != null:
		_move_camera_to_player_units_crowd_pivot(human_player)
	else:
		_move_camera_to_player_units_crowd_pivot(get_tree().get_nodes_in_group("players")[0])


func _move_camera_to_player_units_crowd_pivot(player):
	var player_units = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player
	)
	assert(not player_units.is_empty(), "player must have at least one initial unit")
	var crowd_pivot = Utils.Match.Unit.Movement.calculate_aabb_crowd_pivot_yless(player_units)
	_camera.set_position_safely(crowd_pivot)


func _reveal_player_units(player):
	if player == null:
		return
	for unit in get_tree().get_nodes_in_group("units").filter(
		func(a_unit): return a_unit.player == player
	):
		unit.add_to_group("revealed_units")


func _conceal_player_units(player):
	if player == null:
		return
	for unit in get_tree().get_nodes_in_group("units").filter(
		func(a_unit): return a_unit.player == player
	):
		unit.remove_from_group("revealed_units")
