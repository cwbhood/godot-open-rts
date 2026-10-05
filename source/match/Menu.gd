extends CanvasLayer

# The pause menu (Esc): Resume, Options, Save game, Load game, Restart match, Surrender,
# Exit to main menu.
#
# Saving (see source/match/SaveGame.gd): F5 quicksaves and F9 loads the quicksave at any
# time; the match also saves itself to the "autosave" slot every AUTOSAVE_EVERY_S of match
# time. A short note in the corner says when a save was written.
#
# The match is paused while it is open. It only opens when nothing else paused the game
# (the starter city build-up, the match end screen, the frame incrementer), as before.
# Options opens the options screen over the match (source/main-menu/Options.tscn with
# `overlay`); Esc there goes back to this menu.

const OptionsScene = preload("res://source/main-menu/Options.tscn")
const LoadingScene = preload("res://source/main-menu/Loading.tscn")
const MenuStyle = preload("res://source/options/MenuStyle.gd")
const SaveGame = preload("res://source/match/SaveGame.gd")
const SaveLoadPanel = preload("res://source/main-menu/SaveLoadPanel.gd")
const MATCH_SCENE_PATH = "res://source/match/Match.tscn"
const AUTOSAVE_EVERY_S = 300.0
const NOTE_SHOWN_S = 2.5

var _options = null
var _save_load_panel = null
var _confirmed_action = null
var _next_autosave_s = AUTOSAVE_EVERY_S
var _note = null
var _note_left_s = 0.0

@onready var _root = $Root
@onready var _panel = find_child("CenterContainer")
@onready var _confirm_dialog = find_child("ConfirmDialog")


func _ready():
	hide()
	MenuStyle.style_panel(find_child("PanelContainer"))
	MenuStyle.style_heading(find_child("Title"), 48)
	MenuStyle.style_dialog(_confirm_dialog)
	MenuStyle.accent_button(find_child("ResumeButton"))
	_confirm_dialog.confirmed.connect(func(): _confirmed_action.call())
	_confirm_dialog.get_ok_button().focus_mode = Control.FOCUS_NONE
	_confirm_dialog.get_cancel_button().focus_mode = Control.FOCUS_NONE
	_add_save_buttons()
	_note = Label.new()
	_note.name = "SaveNote"
	_note.add_theme_color_override("font_color", MenuStyle.ACCENT)
	_note.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_note.add_theme_constant_override("outline_size", 6)
	_note.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_note.position.y -= 96
	_note.hide()
	add_sibling.call_deferred(_make_note_layer())


func _make_note_layer():
	"""the save note stays visible while this menu is hidden"""
	var note_layer = CanvasLayer.new()
	note_layer.name = "SaveNoteLayer"
	note_layer.layer = layer + 1
	note_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	note_layer.add_child(_note)
	return note_layer


func _add_save_buttons():
	var options_button = find_child("OptionsButton")
	var load_button = Button.new()
	load_button.name = "LoadButton"
	load_button.text = "Load game"
	load_button.focus_mode = Control.FOCUS_NONE
	load_button.pressed.connect(open_save_load.bind(SaveLoadPanel.Mode.LOAD))
	options_button.add_sibling(load_button)
	var save_button = Button.new()
	save_button.name = "SaveButton"
	save_button.text = "Save game"
	save_button.focus_mode = Control.FOCUS_NONE
	save_button.pressed.connect(open_save_load.bind(SaveLoadPanel.Mode.SAVE))
	options_button.add_sibling(save_button)


func _process(delta):
	if _note_left_s > 0.0:
		_note_left_s -= delta / max(Engine.time_scale, 0.01)
		_note.visible = _note_left_s > 0.0
	if get_tree().paused:
		return
	var limits = _match_limits()
	if limits == null or limits.ended or limits.elapsed_s < _next_autosave_s:
		return
	_next_autosave_s = limits.elapsed_s + AUTOSAVE_EVERY_S
	if _can_save():
		SaveGame.save_match(find_parent("Match"), SaveGame.AUTOSAVE_NAME)
		_show_note("Autosaved")


func _match_limits():
	var a_match = find_parent("Match")
	return a_match.get_node_or_null("MatchLimits") if a_match != null else null


func _can_save():
	var a_match = find_parent("Match")
	return (
		a_match != null
		and a_match.map != null
		and a_match.map.scene_file_path != ""
		and a_match.scene_file_path == MATCH_SCENE_PATH
		and a_match.get_node_or_null("CityBuildUp") == null
	)


func _show_note(text):
	_note.text = text
	_note.show()
	_note_left_s = NOTE_SHOWN_S


func open_save_load(mode):
	"""the save or load window over the paused match (also used by tests)"""
	if _save_load_panel != null:
		return _save_load_panel
	if mode == SaveLoadPanel.Mode.SAVE and not _can_save():
		_show_note("This match cannot be saved")
		return null
	_save_load_panel = SaveLoadPanel.new()
	_save_load_panel.mode = mode
	_save_load_panel.match_node = find_parent("Match")
	_save_load_panel.closed.connect(_on_save_load_closed)
	_save_load_panel.saved.connect(func(_path): _show_note("Game saved"))
	_root.add_child(_save_load_panel)
	_panel.hide()
	return _save_load_panel


func _on_save_load_closed():
	_save_load_panel = null
	_panel.show()


func quicksave():
	if not _can_save():
		_show_note("This match cannot be saved")
		return ""
	var path = SaveGame.save_match(find_parent("Match"), SaveGame.QUICKSAVE_NAME)
	_show_note("Quicksaved (F9 to load)" if path != "" else "Saving failed")
	return path


func quickload():
	var data = SaveGame.read(SaveGame.path_of(SaveGame.QUICKSAVE_NAME))
	if data == null:
		_show_note("No quicksave yet (F5 saves)")
		return
	MatchSignals.match_aborted.emit()
	SaveLoadPanel.load_save(get_tree(), data)


func _unhandled_input(event):
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F5 and not visible:
			get_viewport().set_input_as_handled()
			quicksave()
			return
		if event.keycode == KEY_F9:
			get_viewport().set_input_as_handled()
			quickload()
			return
	if _save_load_panel != null:
		return  # the save window closes itself on Esc
	if not event.is_action_pressed("toggle_match_menu"):
		return
	if visible and _confirm_dialog.visible:
		_confirm_dialog.hide()
		get_viewport().set_input_as_handled()
	elif (not visible and not get_tree().paused) or (visible and get_tree().paused):
		get_viewport().set_input_as_handled()
		_toggle()


func is_open():
	return visible


func open_options():
	"""the options screen over the paused match (also used by the screenshot test)"""
	if _options != null:
		return _options
	_options = OptionsScene.instantiate()
	_options.overlay = true
	_options.closed.connect(_on_options_closed)
	_root.add_child(_options)
	_panel.hide()
	return _options


func _toggle():
	visible = not visible
	get_tree().paused = visible
	if not visible:
		_close_options()
		if _save_load_panel != null:
			_save_load_panel.queue_free()
			_save_load_panel = null
			_panel.show()


func _close_options():
	if _options != null:
		_options.queue_free()
		_options = null
	_panel.show()


func _on_options_closed():
	_options = null
	_panel.show()


func _confirm(text, ok_text, action):
	_confirmed_action = action
	_confirm_dialog.title = ok_text
	_confirm_dialog.dialog_text = text
	_confirm_dialog.ok_button_text = ok_text
	_confirm_dialog.popup_centered()


func _on_resume_button_pressed():
	_toggle()


func _on_options_button_pressed():
	open_options()


func _on_restart_button_pressed():
	_confirm("Restart this match with the same settings?", "Restart", _restart)


func _on_surrender_button_pressed():
	_confirm("Give up this match? It counts as a defeat.", "Surrender", _surrender)


func _on_exit_button_pressed():
	_confirm("Leave the match and return to the main menu? Progress will be lost.", "Exit", _exit)


func _restart():
	var a_match = find_parent("Match")
	get_tree().paused = false
	if a_match == null or a_match.map == null or a_match.map.scene_file_path == "":
		get_tree().reload_current_scene()
		return
	if a_match.scene_file_path != MATCH_SCENE_PATH:
		get_tree().reload_current_scene()  # a test scene with its own players and map
		return
	var loading = LoadingScene.instantiate()
	loading.match_settings = a_match.settings
	loading.map_path = a_match.map.scene_file_path
	var tree = get_tree()
	tree.root.add_child(loading)
	tree.current_scene = loading
	a_match.queue_free()


func _surrender():
	var match_end_handler = (
		find_parent("Match").find_child("MatchEndHandler", true, false)
		if find_parent("Match") != null
		else null
	)
	visible = false
	_close_options()
	if match_end_handler == null or not match_end_handler.has_method("surrender"):
		_exit()  # match end handling is off (sandbox): just leave
		return
	match_end_handler.surrender()


func _exit():
	MatchSignals.match_aborted.emit()
	await get_tree().create_timer(1.74).timeout  # Give voice narrator some time to finish.
	get_tree().paused = false
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
