extends Control

const CrashPrompt = preload("res://source/crash/CrashPrompt.gd")
const SaveGame = preload("res://source/match/SaveGame.gd")
const SaveLoadPanel = preload("res://source/main-menu/SaveLoadPanel.gd")
const EMBLEM = preload("res://assets/logos/ironbound_emblem.svg")
const TITLE_FONT = preload("res://assets/ui/fonts/ironbound_title.tres")
const BODY_FONT = preload("res://assets/ui/fonts/barlow-600.woff2")
const MENU_LEFT = 72
const ACCENT = Color("f2a93b")


func _ready():
	_add_title()
	if CrashPrompt.should_show():
		add_child(CrashPrompt.new())
	var play_button = find_child("Button")
	var replays_button = Button.new()
	replays_button.name = "ReplaysButton"
	replays_button.text = tr("REPLAYS")
	replays_button.pressed.connect(
		func(): get_tree().change_scene_to_file("res://source/replay/ReplayViewer.tscn")
	)
	play_button.add_sibling(replays_button)
	var load_button = Button.new()
	load_button.name = "LoadButton"
	load_button.text = tr("LOAD_GAME")
	load_button.pressed.connect(_open_load)
	play_button.add_sibling(load_button)
	var saves = SaveGame.list_saves()
	if not saves.is_empty():
		var continue_button = Button.new()
		continue_button.name = "ContinueButton"
		continue_button.text = tr("CONTINUE")
		continue_button.tooltip_text = saves[0]["name"] + "  " + saves[0]["summary"]
		continue_button.pressed.connect(_continue.bind(saves[0]["path"]))
		play_button.add_sibling(continue_button)
	_lay_out_menu()


func _continue(path):
	var data = SaveGame.read(path)
	if data == null or not ResourceLoader.exists(data.get("map", "")):
		_open_load()
		return
	SaveLoadPanel.load_save(get_tree(), data)


func _open_load():
	var panel = SaveLoadPanel.new()
	panel.mode = SaveLoadPanel.Mode.LOAD
	add_child(panel)


func _on_play_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Play.tscn")


func _on_options_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Options.tscn")


func _on_credits_button_pressed():
	get_tree().change_scene_to_file("res://source/main-menu/Credits.tscn")


func _on_quit_button_pressed():
	get_tree().quit()


func _add_title():
	var shade = TextureRect.new()
	var gradient = Gradient.new()
	# dark behind the menu column on the left, the battlefield clear on the right
	gradient.offsets = PackedFloat32Array([0.0, 0.38, 0.75])
	gradient.colors = PackedColorArray(
		[
			Color(0.08, 0.067, 0.05, 0.92),
			Color(0.08, 0.067, 0.05, 0.6),
			Color(0.08, 0.067, 0.05, 0.0),
		]
	)
	var texture = GradientTexture2D.new()
	texture.gradient = gradient
	texture.fill_from = Vector2(0, 0)
	texture.fill_to = Vector2(1, 0)
	shade.texture = texture
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	move_child(shade, 1)

	var title = HBoxContainer.new()
	title.name = "Title"
	title.alignment = BoxContainer.ALIGNMENT_BEGIN
	title.add_theme_constant_override("separation", 18)
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	title.offset_left = MENU_LEFT
	title.offset_right = MENU_LEFT + 720
	title.offset_top = 56
	title.offset_bottom = 190
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title)
	var emblem = TextureRect.new()
	emblem.texture = EMBLEM
	emblem.custom_minimum_size = Vector2(88, 88)
	emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	emblem.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title.add_child(emblem)
	var words = VBoxContainer.new()
	words.add_theme_constant_override("separation", -12)
	words.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	title.add_child(words)
	words.add_child(_label("IRONBOUND", TITLE_FONT, 96, Color("efe4cf")))
	words.add_child(_label(tr("IRONBOUND_TAGLINE"), BODY_FONT, 24, Color("f2a93b")))

	var version = _label(
		tr("VERSION_LABEL").format([ProjectSettings.get_setting("application/config/version")]),
		BODY_FONT,
		18,
		Color("b5a68c")
	)
	version.name = "Version"
	version.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	version.offset_left = 24
	version.offset_top = -44
	version.offset_bottom = -16
	version.offset_right = 400
	version.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_child(version)


func _lay_out_menu():
	"""a column of large, flat buttons on the left over the backdrop; Play stands out"""
	var background = find_child("Background", false)
	background.self_modulate = Color.WHITE
	background.flip_h = true  # the shot's base and oases end up right of the menu
	var panel = find_child("PanelContainer", false)
	panel.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	panel.offset_left = MENU_LEFT - 20
	panel.offset_top = -150
	panel.grow_vertical = Control.GROW_DIRECTION_END
	var column = panel.find_child("VBoxContainer")
	column.custom_minimum_size = Vector2(340, 0)
	column.alignment = BoxContainer.ALIGNMENT_BEGIN
	column.add_theme_constant_override("separation", 4)
	for button in column.get_children():
		if button is Button:
			_style_menu_button(button, button.name == "Button")


func _style_menu_button(button, primary):
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size = Vector2(0, 50 if primary else 44)
	button.add_theme_font_size_override("font_size", 26 if primary else 22)
	var normal = StyleBoxFlat.new()
	normal.bg_color = ACCENT if primary else Color(0, 0, 0, 0)
	normal.set_corner_radius_all(8)
	normal.content_margin_left = 20
	normal.content_margin_right = 20
	var hover = normal.duplicate()
	hover.bg_color = ACCENT.lightened(0.15) if primary else Color(1, 1, 1, 0.08)
	hover.border_color = ACCENT
	hover.border_width_left = 0 if primary else 4
	for state in ["normal", "focus"]:
		button.add_theme_stylebox_override(state, normal)
	for state in ["hover", "pressed", "hover_pressed"]:
		button.add_theme_stylebox_override(state, hover)
	var ink = Color("1a1206") if primary else Color("efe4cf")
	for color_name in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(color_name, ink)
	if not primary:
		button.add_theme_color_override("font_hover_color", ACCENT)


func _label(text, font, font_size, color):
	var label = Label.new()
	label.text = text
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 3)
	return label
