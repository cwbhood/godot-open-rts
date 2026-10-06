extends Control

# The options screen: Audio, Video, Interface, Camera and Controls tabs.
#
# Opened from the main menu (its own scene) or over a paused match by the match menu
# (source/match/Menu.gd), which sets `overlay` before adding it: Back then closes it and
# emits `closed` instead of returning to the main menu.
#
# Settings live in Globals.options (source/data-model/Options.gd): its setters apply them
# at once, and this screen saves the file shortly after every change and when it closes.

signal closed

const GameData = preload("res://source/data-model/GameData.gd")
const Options = preload("res://source/data-model/Options.gd")
const Look = preload("res://source/match/environment/Look.gd")
const GraphicsQuality = preload("res://source/options/GraphicsQuality.gd")
const Keybinds = preload("res://source/match/Keybinds.gd")
const MenuStyle = preload("res://source/options/MenuStyle.gd")

const ACCENT = MenuStyle.ACCENT
const TEXT = MenuStyle.TEXT
const MUTED = MenuStyle.MUTED
const LINE = MenuStyle.LINE
const SURFACE = MenuStyle.BACKGROUND
const PANEL_MAX_SIZE = Vector2(1100, 760)
const LABEL_WIDTH = 300
const SAVE_DELAY_S = 0.6

const SCREEN_MODES = [
	[Options.Screen.FULL, "Fullscreen (borderless)"],
	[Options.Screen.WINDOW, "Windowed"],
	[Options.Screen.EXCLUSIVE, "Exclusive fullscreen"],
]
const KEY_SECTIONS = [
	[
		"Camera",
		[
			["move_map_up", "Scroll up"],
			["move_map_down", "Scroll down"],
			["move_map_left", "Scroll left"],
			["move_map_right", "Scroll right"],
			["rotate_map_counterclockwise", "Rotate left"],
			["rotate_map_clockwise", "Rotate right"],
		],
	],
	[
		"Unit commands",
		[
			["command_fight", "Attack-move"],
			["command_patrol", "Patrol"],
			["command_guard", "Guard"],
			["command_patrol_base", "Patrol base"],
			["command_stop", "Stop"],
			["command_retreat", "Retreat"],
			["command_fire_stance", "Fire stance"],
			["command_hold_position", "Hold position"],
		],
	],
	[
		"Selection and building",
		[
			["shift_selecting", "Add to selection (hold)"],
			["unit_groups_set_1", "Set group 1 to 9"],
			["unit_groups_access_1", "Select group 1 to 9"],
			["rotate_structure", "Rotate building"],
		],
	],
	[
		"Game",
		[
			["toggle_match_menu", "Menu / pause"],
		],
	],
]
const MOUSE_BINDINGS = [
	["Select", "Left click / drag"],
	["Move, attack, gather", "Right click"],
	["Line formation", "Right drag"],
	["Rotate camera", "Middle drag"],
	["Reset camera rotation", "Middle double click"],
	["Zoom", "Mouse wheel"],
]

@export var overlay = false

var _heading_font = null
var _controls = {}  # option property -> its control
var _value_labels = {}  # option property -> [label showing its value, unit]
var _quality_hint = null
var _resolution_button = null
var _resolution_choices = []  # Vector2i per item of _resolution_button
var _tabs = null
var _panel = null
var _save_timer = Timer.new()
var _dirty = false
var _reset_dialog = null

@onready var _background = find_child("Background")


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	_heading_font = MenuStyle.heading_font()
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DELAY_S
	_save_timer.timeout.connect(_save)
	add_child(_save_timer)
	if overlay:
		_background.hide()
		var dim = ColorRect.new()
		dim.name = "Dim"
		dim.color = Color(0.05, 0.04, 0.03, 0.6)
		dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		add_child(dim)
		move_child(dim, 0)
	_build()
	_load_values()
	get_viewport().size_changed.connect(_fit_panel)
	_fit_panel()


func _exit_tree():
	if _dirty:
		_save()


func _unhandled_input(event):
	if event.is_action_pressed("toggle_match_menu") or event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _reset_dialog != null and _reset_dialog.visible:
			_reset_dialog.hide()
			return
		_on_back_button_pressed()


func select_tab(index):
	"""shows tab `index` (0 Audio .. 4 Controls); used by the screenshot test too"""
	_tabs.current_tab = clampi(index, 0, _tabs.get_tab_count() - 1)


func _on_back_button_pressed():
	if _dirty:
		_save()
	if overlay:
		closed.emit()
		queue_free()
	else:
		get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")


# ---------------------------------------------------------------------------------------
# layout


func _build():
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	MenuStyle.style_panel(_panel)
	add_child(_panel)
	var margin = _margin(24, 18)
	_panel.add_child(margin)
	var column = VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title = Label.new()
	title.name = "Title"
	title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	title.text = tr("OPTIONS").to_upper()
	_style_heading(title, 40)
	column.add_child(title)

	_tabs = TabContainer.new()
	_tabs.name = "Tabs"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_alignment = TabBar.ALIGNMENT_LEFT
	_tabs.add_theme_font_size_override("font_size", 20)
	_tabs.add_theme_color_override("font_selected_color", ACCENT)
	_tabs.add_theme_color_override("font_hovered_color", TEXT)
	_tabs.add_theme_color_override("font_unselected_color", MUTED)
	column.add_child(_tabs)
	_build_audio_tab(_add_tab("Audio"))
	_build_video_tab(_add_tab("Video"))
	_build_interface_tab(_add_tab("Interface"))
	_build_camera_tab(_add_tab("Camera"))
	_build_controls_tab(_add_tab("Controls"))

	var buttons = HBoxContainer.new()
	buttons.name = "Buttons"
	buttons.add_theme_constant_override("separation", 12)
	column.add_child(buttons)
	var reset = Button.new()
	reset.name = "ResetButton"
	reset.text = "Reset to defaults"
	reset.custom_minimum_size = Vector2(220, 0)
	reset.pressed.connect(_on_reset_button_pressed)
	buttons.add_child(reset)
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)
	var back = Button.new()
	back.name = "BackButton"
	back.text = tr("BACK").to_upper()
	back.custom_minimum_size = Vector2(220, 0)
	back.pressed.connect(_on_back_button_pressed)
	MenuStyle.accent_button(back)
	buttons.add_child(back)

	_reset_dialog = ConfirmationDialog.new()
	_reset_dialog.name = "ResetDialog"
	_reset_dialog.title = "Reset to defaults"
	_reset_dialog.dialog_text = "Put every setting back to its default value?"
	_reset_dialog.ok_button_text = "Reset"
	_reset_dialog.confirmed.connect(_reset_to_defaults)
	MenuStyle.style_dialog(_reset_dialog)
	add_child(_reset_dialog)


func _fit_panel():
	if _panel == null:
		return
	var available = get_viewport_rect().size
	var size = Vector2(
		minf(PANEL_MAX_SIZE.x, available.x - 32.0), minf(PANEL_MAX_SIZE.y, available.y - 32.0)
	)
	_panel.size = size
	_panel.position = ((available - size) / 2.0).floor()


func _add_tab(tab_name):
	var scroll = ScrollContainer.new()
	scroll.name = tab_name
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var margin = _margin(20, 14)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(margin)
	var rows = VBoxContainer.new()
	rows.name = "Rows"
	rows.add_theme_constant_override("separation", 10)
	margin.add_child(rows)
	_tabs.add_child(scroll)
	return rows


func _build_audio_tab(rows):
	_section(rows, "Volume")
	_slider_row(rows, "master_volume", "Master", 0, 100, 1, "%")
	_slider_row(rows, "music_volume", "Music", 0, 100, 1, "%")
	_slider_row(rows, "effects_volume", "Effects", 0, 100, 1, "%")
	_slider_row(rows, "voices_volume", "Voices", 0, 100, 1, "%")
	_slider_row(rows, "ambience_volume", "Ambience", 0, 100, 1, "%")
	_section(rows, "Behaviour")
	_check_row(rows, "mute_when_unfocused", "Mute when the game is in the background")


func _build_video_tab(rows):
	_section(rows, "Display")
	var screen = _option_row(
		rows, "screen", "Window mode", SCREEN_MODES.map(func(mode): return mode[1])
	)
	screen.item_selected.connect(
		func(index):
			Globals.options.screen = SCREEN_MODES[index][0]
			_refresh_resolution_state()
			_changed()
	)
	_resolution_button = _option_row(rows, "window_resolution", "Window size", [])
	_resolution_button.item_selected.connect(
		func(index):
			Globals.options.window_resolution = _resolution_choices[index]
			_changed()
	)
	var vsync = _check_row(rows, "vsync", "Vertical sync")
	vsync.tooltip_text = "Waits for the monitor's refresh: no tearing, a little more input lag"
	var fps_names = Options.MAX_FPS_CHOICES.map(
		func(fps): return "Unlimited" if fps == 0 else str(fps)
	)
	var max_fps = _option_row(rows, "max_fps", "Frame rate limit", fps_names)
	max_fps.item_selected.connect(
		func(index):
			Globals.options.max_fps = Options.MAX_FPS_CHOICES[index]
			_changed()
	)
	_section(rows, "Quality")
	var quality = _option_row(rows, "graphics_quality", "Graphics quality", GraphicsQuality.NAMES)
	quality.item_selected.connect(
		func(index):
			Globals.options.graphics_quality = index
			_quality_hint.text = GraphicsQuality.describe(index)
			_changed()
	)
	_quality_hint = _hint(rows, "")
	_slider_row(rows, "render_scale", "Render scale", 50, 100, 5, "%")
	_hint(rows, "Below 100% the 3D world is drawn at a lower resolution: faster, less sharp.")
	var models = _option_row(
		rows, "classic_unit_models", "Unit models", ["New (Blender, play-ready)", "Classic"]
	)
	models.item_selected.connect(
		func(index):
			Globals.options.classic_unit_models = index == 1
			GameData.switch_unit_models()
			_changed()
	)
	var looks = Look.available_looks()
	var art = _option_row(
		rows, "art_style", "Art style", looks.map(func(id): return Look.display_name(id))
	)
	art.item_selected.connect(
		func(index):
			Globals.options.art_style = looks[index]
			_changed()
	)
	_hint(rows, "How matches are lit and coloured. Takes effect in the next match.")


func _build_interface_tab(rows):
	_section(rows, "Interface")
	var ui_scale = _slider_row(rows, "ui_scale", "Interface scale", 75, 150, 5, "%")
	ui_scale.tooltip_text = "Applied when you let go of the slider"
	_check_row(rows, "show_fps", "Show frame rate (FPS) counter")


func _build_camera_tab(rows):
	_section(rows, "Camera")
	_slider_row(rows, "camera_scroll_speed", "Scroll speed", 25, 300, 5, "%")
	_check_row(rows, "edge_scrolling", "Scroll when the mouse touches the screen edge")
	_check_row(rows, "invert_zoom", "Invert mouse wheel zoom")
	_section(rows, "Mouse")
	_check_row(rows, "mouse_restricted", "Keep the mouse inside the game window")


func _build_controls_tab(rows):
	Keybinds.apply_overrides()  # show the keys of user://controls.cfg, as matches use them
	for section in KEY_SECTIONS:
		_section(rows, section[0])
		for binding in section[1]:
			var key = _key_text(binding[0])
			if binding[0] == "unit_groups_set_1":
				key = key.replace("1", "1-9")
			elif binding[0] == "unit_groups_access_1":
				key = "1-9"
			_binding_row(rows, binding[1], key)
	_section(rows, "Mouse")
	for binding in MOUSE_BINDINGS:
		_binding_row(rows, binding[0], binding[1])
	_hint(
		rows,
		(
			"Unit command keys can be changed in user://controls.cfg"
			+ ' (one line per command under [keys], e.g. command_patrol="O").'
		)
	)


# ---------------------------------------------------------------------------------------
# rows


func _section(rows, text):
	var label = Label.new()
	label.text = text.to_upper()
	_style_heading(label, 22)
	if rows.get_child_count() > 0:
		var gap = Control.new()
		gap.custom_minimum_size = Vector2(0, 4)
		rows.add_child(gap)
	rows.add_child(label)
	var line = ColorRect.new()
	line.color = LINE
	line.custom_minimum_size = Vector2(0, 2)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(line)


func _row(rows, text):
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var label = Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(label)
	rows.add_child(row)
	return row


func _slider_row(rows, property, text, min_value, max_value, step, unit):
	var row = _row(rows, text)
	var slider = HSlider.new()
	slider.name = property.to_pascal_case()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size = Vector2(200, 24)
	MenuStyle.style_slider(slider)
	row.add_child(slider)
	var value_label = Label.new()
	value_label.custom_minimum_size = Vector2(64, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.add_theme_color_override("font_color", ACCENT)
	row.add_child(value_label)
	_controls[property] = slider
	_value_labels[property] = [value_label, unit]
	slider.value_changed.connect(
		func(value):
			value_label.text = "{0}{1}".format([int(value), unit])
			if property == "ui_scale" and slider.has_meta("dragging"):
				return  # rescaling under the mouse while dragging would move the slider
			_set_option(property, value / 100.0)
	)
	slider.drag_started.connect(func(): slider.set_meta("dragging", true))
	slider.drag_ended.connect(
		func(_value_changed):
			slider.remove_meta("dragging")
			_set_option(property, slider.value / 100.0)
	)
	return slider


func _check_row(rows, property, text):
	var row = _row(rows, text)
	row.get_child(0).custom_minimum_size.x = 0
	row.get_child(0).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var check = CheckButton.new()
	check.name = property.to_pascal_case()
	check.flat = true
	check.focus_mode = Control.FOCUS_NONE
	row.add_child(check)
	_controls[property] = check
	check.toggled.connect(func(pressed): _set_option(property, pressed))
	return check


func _option_row(rows, property, text, items):
	var row = _row(rows, text)
	var button = OptionButton.new()
	button.name = property.to_pascal_case()
	button.focus_mode = Control.FOCUS_NONE
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for item in items:
		button.add_item(item)
	row.add_child(button)
	_controls[property] = button
	return button


func _binding_row(rows, text, key):
	var row = _row(rows, text)
	var key_panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = SURFACE
	style.border_color = LINE
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	key_panel.add_theme_stylebox_override("panel", style)
	var key_label = Label.new()
	key_label.text = key
	key_label.add_theme_color_override("font_color", TEXT)
	key_panel.add_child(key_label)
	row.add_child(key_panel)


func _hint(rows, text):
	var label = Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", MUTED)
	label.add_theme_font_size_override("font_size", 15)
	rows.add_child(label)
	return label


func _margin(horizontal, vertical):
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", horizontal)
	margin.add_theme_constant_override("margin_right", horizontal)
	margin.add_theme_constant_override("margin_top", vertical)
	margin.add_theme_constant_override("margin_bottom", vertical)
	return margin


func _style_heading(label, size):
	MenuStyle.style_heading(label, size, _heading_font)


func _key_text(action):
	if not InputMap.has_action(action):
		return "-"
	var names = []
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			names.append(
				(
					event.as_text_physical_keycode()
					if event.physical_keycode != 0
					else event.as_text_keycode()
				)
			)
	if names.is_empty():
		return "-"
	return ", ".join(names).replace("Escape", "Esc")


# ---------------------------------------------------------------------------------------
# values


func _load_values():
	var options = Globals.options
	for property in Options.VOLUME_BUSES:
		_set_slider(property, options.get(property) * 100.0)
	_set_slider("render_scale", options.render_scale * 100.0)
	_set_slider("ui_scale", options.ui_scale * 100.0)
	_set_slider("camera_scroll_speed", options.camera_scroll_speed * 100.0)
	for property in [
		"mute_when_unfocused",
		"vsync",
		"show_fps",
		"edge_scrolling",
		"invert_zoom",
		"mouse_restricted"
	]:
		_controls[property].set_pressed_no_signal(options.get(property))
	var screen_index = SCREEN_MODES.map(func(mode): return mode[0]).find(options.screen)
	_controls["screen"].select(max(screen_index, 0))
	var fps_index = Options.MAX_FPS_CHOICES.find(options.max_fps)
	_controls["max_fps"].select(max(fps_index, 0))
	_controls["graphics_quality"].select(options.graphics_quality)
	_quality_hint.text = GraphicsQuality.describe(options.graphics_quality)
	_controls["classic_unit_models"].select(1 if options.classic_unit_models else 0)
	var art_style = options.art_style if options.art_style != "" else Look.DEFAULT_LOOK
	_controls["art_style"].select(max(Look.available_looks().find(art_style), 0))
	_fill_resolutions()
	_refresh_resolution_state()


func _set_slider(property, value):
	var slider = _controls[property]
	slider.set_value_no_signal(value)
	var label_and_unit = _value_labels[property]
	label_and_unit[0].text = "{0}{1}".format([int(round(slider.value)), label_and_unit[1]])


func _fill_resolutions():
	var screen_size = DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	_resolution_choices = [Vector2i.ZERO]
	for resolution in Options.RESOLUTIONS:
		if resolution.x <= screen_size.x and resolution.y <= screen_size.y:
			_resolution_choices.append(resolution)
	var current = Globals.options.window_resolution
	if not current in _resolution_choices:
		_resolution_choices.append(current)
	_resolution_button.clear()
	for resolution in _resolution_choices:
		_resolution_button.add_item(
			(
				"Automatic"
				if resolution == Vector2i.ZERO
				else "{0} x {1}".format([resolution.x, resolution.y])
			)
		)
	_resolution_button.select(_resolution_choices.find(current))


func _refresh_resolution_state():
	_resolution_button.disabled = Globals.options.screen != Options.Screen.WINDOW
	_resolution_button.tooltip_text = (
		"Only used in windowed mode" if _resolution_button.disabled else ""
	)


func _set_option(property, value):
	if Globals.options.get(property) == value:
		return
	Globals.options.set(property, value)
	_changed()


func _changed():
	_dirty = true
	_save_timer.start()


func _save():
	_dirty = false
	_save_timer.stop()
	Globals.options.save()


func _on_reset_button_pressed():
	_reset_dialog.popup_centered()


func _reset_to_defaults():
	Globals.options.reset_to_defaults()
	_load_values()
	_save()
