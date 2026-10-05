extends Node

# Checks the faction, colour and AI difficulty choices of the Play menu end to end and saves
# screenshots of the menu and of the match it starts:
#
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . \
#     res://tests/setup/MatchSetupCheck.tscn -- --out=/tmp/setup
#
# - picking a colour another slot has swaps the two, so no colour is used twice,
# - the colours and difficulties reach MatchSettings and the players of the match,
# - every unit wears its owner's colour, also on models whose team-coloured material is
#   only marked by its "TeamColor" name (the Blender models in tools/blender/),
# - the difficulty's numbers are applied on top of the personality,
# - the faction dropdown starts on Foundry for the human and Random for AIs; the picked
#   faction, or the one Random drew for the AI's play style, reaches the players, their
#   starter units and the diplomacy panel's names.
# Exits with code 1 when a check fails.

const PlayScene = preload("res://source/main-menu/Play.tscn")
const GameData = preload("res://source/data-model/GameData.gd")
const Unit = preload("res://source/match/units/Unit.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Factions = preload("res://source/data-model/Factions.gd")

# slot -> [controller personality or "human", difficulty, colour id, faction choice,
# faction expected in the match]
const SLOTS = [
	["human", "", "orange", "foundry", "foundry"],
	["balanced", "easy", "red", "syndicate", "syndicate"],
	["raider", "hard", "teal", "random", "syndicate"],  # only the Syndicate suits raiders
	["turtle", "brutal", "white", "random", "foundry"],
]

var _args = {"out": "user://setup-check", "map": "plain_and_simple"}
var _failures = []


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	DirAccess.make_dir_recursive_absolute(_args["out"])
	_check_team_color_by_material_name()
	var play = PlayScene.instantiate()
	get_tree().root.add_child.call_deferred(play)
	await _frames(10)
	var settings = await _fill_in_menu(play)
	await _start(play, settings)
	_report()


func _fill_in_menu(play):
	var map_paths = play.get("_map_paths")
	for index in range(map_paths.size()):
		if map_paths[index].get_file().get_basename().to_snake_case() == _args["map"]:
			play.find_child("MapList").select(index)
			play.find_child("MapList").item_selected.emit(index)
	var personalities = play.get("_ai_personalities")
	var options = play.find_child("GridContainer").find_children("OptionButton*")
	var slot_options = play.get("_slot_options")
	var palette = GameData.player_colors().map(func(entry): return entry["id"])
	for slot in range(SLOTS.size()):
		var choice = Constants.PlayerType.HUMAN
		if SLOTS[slot][0] != "human":
			choice = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI + personalities.find(SLOTS[slot][0])
			slot_options.set_difficulty(slot, SLOTS[slot][1])
		options[slot].select(choice)
		options[slot].item_selected.emit(choice)
	for slot in range(SLOTS.size()):
		var default = "foundry" if SLOTS[slot][0] == "human" else "random"
		_expect(
			slot_options.faction_of(slot) == default,
			"slot %d faction starts on %s (got %s)" % [slot, default, slot_options.faction_of(slot)]
		)
	_pick_faction(play, 1, SLOTS[1][3])
	# pick through the dropdowns like a player: slot 1 first takes the human's colour...
	_pick_color(play, 0, palette.find("orange"))
	_pick_color(play, 1, palette.find("orange"))
	_expect(
		slot_options.color_of(0) != slot_options.color_of(1),
		"picking a taken colour swaps it, slot 0 and 1 both have %s" % slot_options.color_of(0)
	)
	# ...then everybody settles on their own one
	for slot in range(SLOTS.size()):
		_pick_color(play, slot, palette.find(SLOTS[slot][2]))
	var colors = []
	for slot in range(4):
		colors.append(slot_options.color_of(slot))
	for slot in range(colors.size()):
		_expect(colors.count(colors[slot]) == 1, "colour of slot %d is used twice" % slot)
	await _frames(5)
	_screenshot("1-play-menu.png")
	var difficulty_button = play.find_child("DifficultyButton2", true, false)
	difficulty_button.show_popup()
	await _frames(5)
	_screenshot("2-difficulty-dropdown.png")
	difficulty_button.get_popup().hide()
	var faction_button = play.find_child("FactionButton1", true, false)
	faction_button.show_popup()
	await _frames(5)
	_screenshot("2b-faction-dropdown.png")
	faction_button.get_popup().hide()
	var color_button = play.find_child("ColorButton0", true, false)
	color_button.show_popup()
	await _frames(5)
	_screenshot("3-colour-dropdown.png")
	color_button.get_popup().hide()
	_expect(
		play.find_child("DifficultyButton0", true, false).modulate.a == 0.0,
		"the human slot shows no difficulty"
	)
	var settings = play.call("_create_match_settings")
	for slot in range(SLOTS.size()):
		var player_settings = settings.players[slot]
		var wanted_color = GameData.player_colors()[palette.find(SLOTS[slot][2])]["color"]
		_expect(
			player_settings.color == wanted_color,
			"slot %d colour %s reached MatchSettings" % [slot, SLOTS[slot][2]]
		)
		if SLOTS[slot][0] != "human":
			_expect(
				player_settings.ai_difficulty == SLOTS[slot][1],
				(
					"slot %d difficulty %s reached MatchSettings (got %s)"
					% [slot, SLOTS[slot][1], player_settings.ai_difficulty]
				)
			)
			_expect(player_settings.ai_personality == SLOTS[slot][0], "slot %d play style" % slot)
		_expect(
			player_settings.faction == SLOTS[slot][4],
			(
				"slot %d faction %s reached MatchSettings as %s (got %s)"
				% [slot, SLOTS[slot][3], SLOTS[slot][4], player_settings.faction]
			)
		)
	return settings


func _pick_faction(play, slot, faction_id):
	var button = play.find_child("FactionButton%d" % slot, true, false)
	var index = Factions.ids().find(faction_id)
	if index < 0:
		index = button.item_count - 1  # Random
	button.select(index)
	button.item_selected.emit(index)


func _pick_color(play, slot, index):
	var button = play.find_child("ColorButton%d" % slot, true, false)
	button.select(index)
	button.item_selected.emit(index)


func _start(play, settings):
	play.find_child("StartButton").pressed.emit()
	var match_node = null
	for _i in range(900):
		await _frames(1)
		match_node = get_tree().root.find_child("Match", true, false)
		if match_node != null and match_node.is_node_ready():
			break
	if match_node == null:
		_expect(false, "the match did not start")
		return
	await _frames(120)
	var players = get_tree().get_nodes_in_group("players")
	_expect(players.size() == SLOTS.size(), "%d players in the match" % players.size())
	for index in range(min(players.size(), SLOTS.size())):
		var player = players[index]
		_expect(player.color == settings.players[index].color, "player %d has its colour" % index)
		if SLOTS[index][0] != "human":
			_check_difficulty(player, SLOTS[index][0], SLOTS[index][1])
		_check_faction(match_node, player, SLOTS[index][4])
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == null or not unit is Unit:
			continue
		var colored = _team_colored_surfaces(unit)
		_expect(
			colored.all(func(color): return color == unit.player.color),
			"%s of player %d wears another player's colour" % [unit.name, unit.player.get_index()]
		)
	var atmosphere = match_node.find_child("Atmosphere", true, false)
	if atmosphere != null:
		atmosphere.set_weather_immediately("clear")
	# show every faction: the AI colours are what the shots are about
	match_node.settings.visibility = match_node.settings.Visibility.FULL
	match_node.fog_of_war.reveal()
	for layer in match_node.find_children("*", "CanvasLayer", true, false):
		layer.visible = false
	await _frames(60)
	var camera = get_viewport().get_camera_3d()
	var map_size = match_node.map.size
	camera.set_size_safely(max(map_size.x, map_size.y) * 0.7)
	camera.set_position_safely(Vector3(map_size.x / 2.0, 0.0, map_size.y / 2.0))
	await _frames(30)
	_screenshot("4-all-bases.png")
	var shot = 5
	for player in get_tree().get_nodes_in_group("players"):
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.player == player and unit is CommandCenter:
				camera.set_size_safely(14.0)
				camera.set_position_safely(unit.global_position)
				await _frames(20)
				_screenshot("%d-base-of-player-%d.png" % [shot, player.get_index() + 1])
				shot += 1
				break


func _check_faction(match_node, player, faction_id):
	var where = "player %d" % player.get_index()
	_expect(
		player.faction == faction_id, "%s plays %s (got %s)" % [where, faction_id, player.faction]
	)
	var wanted = Factions.start_units(faction_id).map(
		func(id): return GameData.unit_by_id(id)["scene"]
	)
	var own = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player and not unit is CommandCenter
	)
	for scene_path in wanted:
		_expect(
			own.any(func(unit): return unit._scene_path() == scene_path),
			"%s got its starter %s" % [where, scene_path.get_file()]
		)
	var hud = match_node.find_child("DiplomacyHud", true, false)
	if hud != null and hud.has_method("faction_name"):
		var label = hud.faction_name(player)
		_expect(
			label.begins_with(Factions.display_name(faction_id)),
			"%s is called '%s' in the diplomacy panel" % [where, label]
		)


func _check_difficulty(player, personality_id, difficulty_id):
	var personality = GameData.ai_personalities().filter(func(entry): return entry["id"] == personality_id)[0]
	var difficulty = GameData.ai_difficulty(difficulty_id)
	var where = "%s/%s" % [personality_id, difficulty_id]
	_expect(player.difficulty_id == difficulty_id, where + ": difficulty id")
	_expect(
		is_equal_approx(player.gather_rate, float(difficulty["gather_rate"])),
		where + ": gather rate"
	)
	_expect(
		is_equal_approx(player.production_speed, float(difficulty["production_speed"])),
		where + ": production speed"
	)
	var units = int(personality.get("expected_number_of_units_in_battlegroup", 4))
	_expect(
		(
			player.expected_number_of_units_in_battlegroup
			== max(1, int(round(units * float(difficulty["army_size_scale"]))))
		),
		where + ": attack group size"
	)
	_expect(player.tech_upgrades == difficulty["tech_upgrades"], where + ": tech upgrades")
	_expect(player.focus_fire == difficulty["focus_fire"], where + ": focus fire")
	if not difficulty["cheats"]:
		_expect(player.gather_rate <= 1.0, where + ": a non-cheating AI earns no bonus")


func _check_team_color_by_material_name():
	"""a model with a blue material named TeamColor (no key albedo) takes the player colour"""
	var root = Node3D.new()
	var mesh_instance = MeshInstance3D.new()
	var mesh = BoxMesh.new()
	var material = StandardMaterial3D.new()
	material.resource_name = "TeamColor"
	material.albedo_color = Color(0.1, 0.3, 0.9)
	mesh.material = material
	mesh_instance.mesh = mesh
	root.add_child(mesh_instance)
	var team_material = StandardMaterial3D.new()
	team_material.albedo_color = Color.ORANGE
	Utils.Match.traverse_node_tree_and_replace_materials_matching_albedo(
		root,
		Unit.MATERIAL_ALBEDO_TO_REPLACE,
		Unit.MATERIAL_ALBEDO_TO_REPLACE_EPSILON,
		team_material
	)
	_expect(
		mesh_instance.get_surface_override_material(0) == team_material,
		"a material named TeamColor takes the player colour"
	)
	root.free()


func _team_colored_surfaces(unit):
	"""colours of the override materials put on the unit's team-coloured surfaces"""
	var colors = []
	var geometry = unit.find_child("Geometry")
	if geometry == null:
		return colors
	for child in geometry.find_children("*", "MeshInstance3D", true, false):
		if child.mesh == null:
			continue
		for surface in range(child.mesh.get_surface_count()):
			var override = child.get_surface_override_material(surface)
			if override != null and override.vertex_color_use_as_albedo:
				colors.append(override.albedo_color)
	return colors


func _expect(condition, what):
	print(("PASS " if condition else "FAIL ") + what)
	if not condition:
		_failures.append(what)


func _screenshot(file_name):
	var path = _args["out"].path_join(file_name)
	get_viewport().get_texture().get_image().save_png(path)
	print("screenshot ", ProjectSettings.globalize_path(path))


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame


func _report():
	print("MatchSetupCheck: %d failure(s)" % _failures.size())
	get_tree().quit(1 if not _failures.is_empty() else 0)
