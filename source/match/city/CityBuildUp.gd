extends Node

# The starter city's build-up: when a match starts, each visible player's first command
# centre is shown being built for a few seconds (cranes, scaffold, workers, the building
# rising in stages, dust and construction sounds) before the normal model takes over.
#
# - The game is paused while it plays, so the match clock, the economy and the AI all start
#   when it ends; nobody loses those seconds. This node, the animation and the fog of war
#   keep running through the pause.
# - Space, Enter, Escape or a click skips it.
# - It plays wherever the command centre stands: it listens to
#   MatchSignals.starter_city_spawned, so a start picked later (a start-zone pick screen)
#   gets the animation when its city appears.
# - The whole site is one skinned mesh (assets/models/ironbound/construction/, built by
#   tools/blender/build_construction.py) that is freed at the end.

signal finished

const Unit = preload("res://source/match/units/Unit.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const RIG_SCENE_PATH = "res://assets/models/ironbound/construction/city_build_up.glb"
const SOUND_PATH = "res://assets/audio/construction/city_build_up.ogg"
const ANIMATION = "build"
const HIDE_UNITS_RADIUS_M = 7.0

var playing = false

var _started = false
var _pending = []  # command centres that spawned before start()
var _sites = []  # {"unit", "rig", "model_nodes"}
var _hidden_units = []
var _paused_by_us = false
var _process_modes = {}  # node -> process mode before the build-up
var _hud_was_visible = true
var _sound = null
var _hint = null

@onready var _match = find_parent("Match")


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	MatchSignals.starter_city_spawned.connect(_on_starter_city_spawned)


func start():
	"""plays the build-up for the starter cities spawned so far; later ones play on spawn"""
	_started = true
	var command_centers = _pending
	_pending = []
	_play(command_centers)


func skip():
	if not playing:
		return
	for site in _sites:
		var animation_player = site["rig"].find_child("AnimationPlayer", true, false)
		if animation_player != null:
			animation_player.seek(animation_player.current_animation_length, true)
	_finish()


func _on_starter_city_spawned(_player, command_center):
	if _started:
		_play([command_center])
	else:
		_pending.append(command_center)


func _play(command_centers):
	var visible_players = _match.visible_players
	var sites = command_centers.filter(
		func(unit): return is_instance_valid(unit) and unit.player in visible_players
	)
	if sites.is_empty() or not ResourceLoader.exists(RIG_SCENE_PATH):
		return
	var rig_scene = load(RIG_SCENE_PATH)
	for command_center in sites:
		_start_site(command_center, rig_scene)
	if playing:
		return  # a second city joined a running build-up
	playing = true
	_pause_match()
	_sound = AudioStreamPlayer.new()
	_sound.stream = load(SOUND_PATH)
	_sound.volume_db = -4.0
	add_child(_sound)
	_sound.play()
	_show_hint()


func _start_site(command_center, rig_scene):
	var geometry = command_center.find_child("Geometry", true, false)
	if geometry == null:
		return
	var model = geometry.get_node_or_null("Model")
	var rig = rig_scene.instantiate()
	rig.name = "CityBuildUp"
	rig.process_mode = Node.PROCESS_MODE_ALWAYS
	rig.visible = false  # until the first frame is posed, the rest pose shows everything
	rig.transform = model.transform if model != null else Transform3D.IDENTITY
	geometry.add_child(rig)
	var model_nodes = geometry.get_children().filter(
		func(child): return child is Node3D and child != rig and child.visible
	)
	for node in model_nodes:
		node.visible = false
	Utils.Match.traverse_node_tree_and_replace_materials_matching_albedo(
		rig,
		Unit.MATERIAL_ALBEDO_TO_REPLACE,
		Unit.MATERIAL_ALBEDO_TO_REPLACE_EPSILON,
		command_center.player.get_color_material()
	)
	var animation_player = rig.find_child("AnimationPlayer", true, false)
	if animation_player != null:
		animation_player.play(ANIMATION)
		animation_player.advance(0.0)
	rig.visible = true
	_hide_starting_units(command_center)
	_sites.append({"unit": command_center, "rig": rig, "model_nodes": model_nodes})


func _hide_starting_units(command_center):
	"""the first units roll out when the city is done"""
	for unit in get_tree().get_nodes_in_group("units"):
		if (
			unit.player == command_center.player
			and not unit is Structure
			and unit.visible
			and (
				unit.global_position.distance_to(command_center.global_position)
				< HIDE_UNITS_RADIUS_M
			)
		):
			unit.visible = false
			_hidden_units.append(unit)


func _pause_match():
	if not get_tree().paused:
		get_tree().paused = true
		_paused_by_us = true
	# the fog of war must keep drawing what the command centre reveals
	for node in [_match.get_node_or_null("FogOfWar")]:
		if node != null:
			_process_modes[node] = node.process_mode
			node.process_mode = Node.PROCESS_MODE_ALWAYS
	var hud = _match.get_node_or_null("HUD")
	if hud != null:
		_hud_was_visible = hud.visible
		hud.visible = false


func _process(_delta):
	if playing and _sites.all(func(site): return _site_done(site)):
		_finish()


func _site_done(site):
	if not is_instance_valid(site["rig"]):
		return true
	var animation_player = site["rig"].find_child("AnimationPlayer", true, false)
	return (
		animation_player == null
		or not animation_player.is_playing()
		or (
			animation_player.current_animation_position
			>= animation_player.current_animation_length - 0.001
		)
	)


func _finish():
	if not playing:
		return
	playing = false
	for site in _sites:
		for node in site["model_nodes"]:
			if is_instance_valid(node):
				node.visible = true
		if is_instance_valid(site["rig"]):
			site["rig"].queue_free()
	_sites = []
	for unit in _hidden_units:
		if is_instance_valid(unit):
			unit.visible = true
	_hidden_units = []
	for node in _process_modes:
		if is_instance_valid(node):
			node.process_mode = _process_modes[node]
	_process_modes = {}
	var hud = _match.get_node_or_null("HUD")
	if hud != null:
		hud.visible = _hud_was_visible
	if _paused_by_us:
		get_tree().paused = false
		_paused_by_us = false
	if _sound != null:
		var tween = create_tween()
		tween.tween_property(_sound, "volume_db", -40.0, 0.4)
		tween.tween_callback(_sound.queue_free)
		_sound = null
	if _hint != null:
		_hint.queue_free()
		_hint = null
	finished.emit()


func _input(event):
	if not playing:
		return
	var skip_pressed = (
		(event is InputEventKey and event.pressed and not event.echo)
		and event.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE]
	)
	var clicked = event is InputEventMouseButton and event.pressed
	if skip_pressed or clicked:
		get_viewport().set_input_as_handled()
		skip()


func _show_hint():
	_hint = CanvasLayer.new()
	_hint.layer = 10
	var label = Label.new()
	label.text = tr("CITY_BUILD_UP_SKIP")
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("outline_size", 6)
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	label.offset_top = -56
	label.offset_bottom = -24
	label.offset_left = -300
	label.offset_right = 300
	_hint.add_child(label)
	add_child(_hint)
