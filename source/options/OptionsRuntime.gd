extends CanvasLayer

# The options that need a node running all the time (Globals.gd adds this one):
# - the FPS counter in the top right corner (Options.show_fps)
# - muting the game while its window is in the background (Options.mute_when_unfocused)

const FPS_REFRESH_S = 0.25

var _fps_label = Label.new()
var _since_refresh = 0.0
var _muted_for_focus = false


func _ready():
	layer = 128  # above every menu and HUD
	process_mode = Node.PROCESS_MODE_ALWAYS
	_fps_label.name = "FpsCounter"
	_fps_label.anchor_left = 1.0
	_fps_label.anchor_right = 1.0
	_fps_label.offset_left = -96.0
	_fps_label.offset_right = -8.0
	_fps_label.offset_top = 4.0
	_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fps_label.add_theme_color_override("font_color", Color("efe4cf"))
	_fps_label.add_theme_color_override("font_outline_color", Color("14110d"))
	_fps_label.add_theme_constant_override("outline_size", 4)
	_fps_label.add_theme_font_size_override("font_size", 14)
	add_child(_fps_label)
	Globals.options.changed.connect(_on_options_changed)
	_on_options_changed()
	# the engine sets the root window's scale from the project settings after the autoloads
	# load (and with them the options file), so the interface scale is applied once more
	_reapply_window_options.call_deferred()


func _reapply_window_options():
	Globals.options.ui_scale = Globals.options.ui_scale
	Globals.options.render_scale = Globals.options.render_scale


func _process(delta):
	if not _fps_label.visible:
		return
	_since_refresh += delta
	if _since_refresh >= FPS_REFRESH_S:
		_since_refresh = 0.0
		_fps_label.text = "{0} FPS".format([Engine.get_frames_per_second()])


func _notification(what):
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		if Globals.options.mute_when_unfocused:
			AudioServer.set_bus_mute(0, true)
			_muted_for_focus = true
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if _muted_for_focus:
			_muted_for_focus = false
			Globals.options.apply_audio()


func _on_options_changed():
	_fps_label.visible = Globals.options.show_fps
	_fps_label.text = "{0} FPS".format([Engine.get_frames_per_second()])
	if _muted_for_focus and not Globals.options.mute_when_unfocused:
		_muted_for_focus = false
		Globals.options.apply_audio()
