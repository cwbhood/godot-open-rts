extends Node

const Options = preload("res://source/data-model/Options.gd")
const OptionsRuntime = preload("res://source/options/OptionsRuntime.gd")

var options = (
	load(Constants.OPTIONS_FILE_PATH)
	if ResourceLoader.exists(Constants.OPTIONS_FILE_PATH)
	else Options.new()
)
var god_mode = false
var cache = {}


func _ready():
	var options_runtime = OptionsRuntime.new()
	options_runtime.name = "OptionsRuntime"
	add_child(options_runtime)


func _unhandled_input(event):
	if event.is_action_pressed("toggle_god_mode"):
		_toggle_god_mode()


func _toggle_god_mode():
	if not FeatureFlags.god_mode:
		return
	god_mode = not god_mode
	if god_mode:
		Signals.god_mode_enabled.emit()
	else:
		Signals.god_mode_disabled.emit()
