extends Button

# One unit waiting in a factory's queue: its icon, how far along it is, and a click
# cancels it (the cost is refunded).

const GameData = preload("res://source/data-model/GameData.gd")

var queue = null
var queue_element = null

var _progress = ProgressBar.new()


func _ready():
	theme_type_variation = "SlotButton"
	if queue == null or queue_element == null:
		return
	queue_element.changed.connect(_on_queue_element_changed)
	pressed.connect(func(): queue.cancel(queue_element))
	var scene_path = queue_element.unit_prototype.resource_path
	var entry = GameData.unit_by_scene(scene_path)
	text = ""
	if entry != null and "icon" in entry and ResourceLoader.exists(entry["icon"]):
		var icon_rect = TextureRect.new()
		icon_rect.texture = load(entry["icon"])
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon_rect.offset_left = 8
		icon_rect.offset_top = 4
		icon_rect.offset_right = -8
		icon_rect.offset_bottom = -14
		icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if "icon_tint" in entry:
			icon_rect.modulate = Color(entry["icon_tint"])
		add_child(icon_rect)
		move_child(icon_rect, 0)
	else:
		text = scene_path.get_file().left(1)
	tooltip_text = (
		"{0}\n{1}"
		. format(
			[
				tr(entry["name"]) if entry != null else scene_path.get_file().get_basename(),
				tr("QUEUE_CANCEL_TOOLTIP"),
			]
		)
	)
	_progress.show_percentage = false
	_progress.max_value = 1.0
	_progress.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_progress.offset_left = 5
	_progress.offset_right = -5
	_progress.offset_top = -9
	_progress.offset_bottom = -4
	_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_progress)
	var label = find_child("Label")
	label.add_theme_constant_override("outline_size", 3)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.offset_right = -4
	label.offset_bottom = -10
	_on_queue_element_changed()


func _on_queue_element_changed():
	var progress = queue_element.progress()
	find_child("Label").text = "{0}%".format([int(progress * 100.0)])
	_progress.value = progress
