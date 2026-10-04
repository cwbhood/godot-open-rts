extends Control

# Startup splash: the Ironbound emblem and wordmark, then a small Godot credit.
# Any key or click skips it.

const BACKGROUND_COLOR = Color("14110d")
const SAND = Color("efe4cf")
const MUTED = Color("b5a68c")
const EMBLEM = preload("res://assets/logos/ironbound_emblem.svg")
const GODOT_LOGO = preload("res://assets/logos/godot_logo_vertical_monochrome_dark_312x357.png")
const TITLE_FONT = preload("res://assets/ui/fonts/ironbound_title.tres")
const BODY_FONT = preload("res://assets/ui/fonts/barlow-600.woff2")

var _tween = null


func _ready():
	if not FeatureFlags.show_logos_on_startup:
		queue_free()
		return
	var background = ColorRect.new()
	background.color = BACKGROUND_COLOR
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)

	var center = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var column = VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 18)
	center.add_child(column)

	var emblem = TextureRect.new()
	emblem.texture = EMBLEM
	emblem.custom_minimum_size = Vector2(160, 160)
	emblem.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	emblem.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	emblem.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(emblem)

	var title = _label("IRONBOUND", TITLE_FONT, 120, SAND)
	title.add_theme_constant_override("outline_size", 0)
	column.add_child(title)

	var tagline = _label(tr("IRONBOUND_TAGLINE"), BODY_FONT, 26, MUTED)
	column.add_child(tagline)

	var godot_row = HBoxContainer.new()
	godot_row.alignment = BoxContainer.ALIGNMENT_CENTER
	godot_row.add_theme_constant_override("separation", 12)
	godot_row.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	godot_row.offset_top = -90
	godot_row.offset_bottom = -40
	godot_row.offset_left = -200
	godot_row.offset_right = 200
	add_child(godot_row)
	var godot_logo = TextureRect.new()
	godot_logo.texture = GODOT_LOGO
	godot_logo.custom_minimum_size = Vector2(38, 44)
	godot_logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	godot_logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	godot_row.add_child(godot_logo)
	godot_row.add_child(_label(tr("MADE_WITH_GODOT"), BODY_FONT, 22, MUTED))

	column.modulate.a = 0.0
	godot_row.modulate.a = 0.0
	_tween = create_tween()
	_tween.tween_property(column, "modulate:a", 1.0, 0.8)
	_tween.parallel().tween_property(emblem, "scale", Vector2.ONE, 0.8).from(Vector2(0.9, 0.9))
	_tween.tween_property(godot_row, "modulate:a", 1.0, 0.4)
	_tween.tween_interval(1.4)
	_tween.tween_property(self, "modulate:a", 0.0, 0.5)
	_tween.finished.connect(queue_free)
	emblem.pivot_offset = emblem.custom_minimum_size / 2.0


func _input(event):
	if (
		(
			event is InputEventKey
			or event is InputEventMouseButton
			or event is InputEventJoypadButton
		)
		and event.is_pressed()
	):
		get_viewport().set_input_as_handled()
		_skip()


func _skip():
	if _tween != null:
		_tween.kill()
		_tween = null
	queue_free()


func _label(text, font, font_size, color):
	var label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label
