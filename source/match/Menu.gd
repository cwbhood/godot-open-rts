extends CanvasLayer

# The pause menu (Esc): Resume, Options, Restart match, Surrender, Exit to main menu.
#
# The match is paused while it is open. It only opens when nothing else paused the game
# (the starter city build-up, the match end screen, the frame incrementer), as before.
# Options opens the options screen over the match (source/main-menu/Options.tscn with
# `overlay`); Esc there goes back to this menu.

const OptionsScene = preload("res://source/main-menu/Options.tscn")
const LoadingScene = preload("res://source/main-menu/Loading.tscn")
const MenuStyle = preload("res://source/options/MenuStyle.gd")
const MATCH_SCENE_PATH = "res://source/match/Match.tscn"

var _options = null
var _confirmed_action = null

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


func _unhandled_input(event):
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
