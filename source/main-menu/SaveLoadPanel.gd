extends Control

# The Save game / Load game window of the pause menu and the main menu. Lists the saves in
# user://saves/ (newest first, with map, match time and date), and saves the running match
# or loads the picked save (see source/match/SaveGame.gd). Works while the match is paused.

signal closed
signal saved(path)

enum Mode { SAVE, LOAD }

const SaveGame = preload("res://source/match/SaveGame.gd")
const MenuStyle = preload("res://source/options/MenuStyle.gd")
const LoadingScene = preload("res://source/main-menu/Loading.tscn")

var mode = Mode.LOAD
var match_node = null  # the match to save (Mode.SAVE)

var _saves = []
var _list = null
var _name_edit = null
var _action_button = null
var _delete_button = null
var _status = null


static func load_save(tree, data):
	"""leaves whatever runs now and starts the saved match"""
	tree.paused = false
	var old_scene = tree.current_scene
	var loading = LoadingScene.instantiate()
	loading.saved_game = data
	tree.root.add_child(loading)
	tree.current_scene = loading
	if old_scene != null:
		old_scene.queue_free()


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var shade = ColorRect.new()
	shade.color = Color(0, 0, 0, 0.55)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel = PanelContainer.new()
	MenuStyle.style_panel(panel)
	center.add_child(panel)
	var margin = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)
	var box = VBoxContainer.new()
	box.custom_minimum_size = Vector2(560, 0)
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	var title = Label.new()
	title.name = "Title"
	title.text = tr("SAVE_GAME") if mode == Mode.SAVE else tr("LOAD_GAME")
	MenuStyle.style_heading(title, 36)
	box.add_child(title)

	if mode == Mode.SAVE:
		_name_edit = LineEdit.new()
		_name_edit.name = "SaveName"
		_name_edit.placeholder_text = tr("SAVE_NAME")
		_name_edit.text = _default_name()
		_name_edit.text_submitted.connect(func(_text): _on_action())
		box.add_child(_name_edit)

	_list = ItemList.new()
	_list.name = "SaveList"
	_list.custom_minimum_size = Vector2(0, 280)
	_list.item_selected.connect(_on_selected)
	_list.item_activated.connect(func(_index): _on_action())
	box.add_child(_list)

	_status = Label.new()
	_status.name = "Status"
	_status.add_theme_color_override("font_color", MenuStyle.MUTED)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)

	var buttons = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	box.add_child(buttons)
	_action_button = Button.new()
	_action_button.name = "ActionButton"
	_action_button.text = tr("SAVE") if mode == Mode.SAVE else tr("LOAD")
	_action_button.custom_minimum_size = Vector2(140, 0)
	_action_button.pressed.connect(_on_action)
	MenuStyle.accent_button(_action_button)
	buttons.add_child(_action_button)
	_delete_button = Button.new()
	_delete_button.name = "DeleteButton"
	_delete_button.text = tr("DELETE")
	_delete_button.pressed.connect(_on_delete)
	buttons.add_child(_delete_button)
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)
	var back = Button.new()
	back.name = "BackButton"
	back.text = tr("BACK")
	back.custom_minimum_size = Vector2(120, 0)
	back.pressed.connect(close)
	buttons.add_child(back)

	_refresh()
	if _name_edit != null:
		_name_edit.grab_focus()
		_name_edit.select_all()


func _unhandled_input(event):
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("toggle_match_menu"):
		get_viewport().set_input_as_handled()
		close()


func close():
	closed.emit()
	queue_free()


func _refresh():
	_saves = SaveGame.list_saves()
	_list.clear()
	for save in _saves:
		_list.add_item("{0}    {1}".format([save["name"], save["summary"]]))
	if _saves.is_empty():
		_status.text = tr("NO_SAVES")
	elif mode == Mode.LOAD:
		_list.select(0)
		_status.text = ""
	_update_buttons()


func _update_buttons():
	var picked = _list.get_selected_items()
	_delete_button.disabled = picked.is_empty()
	if mode == Mode.LOAD:
		_action_button.disabled = picked.is_empty()
	else:
		_action_button.disabled = _name_edit.text.strip_edges() == ""


func _on_selected(index):
	if mode == Mode.SAVE:
		_name_edit.text = _saves[index]["name"]
	_update_buttons()


func _on_action():
	if mode == Mode.SAVE:
		_save()
	else:
		_load()


func _save():
	var save_name = _name_edit.text.strip_edges()
	if save_name == "" or match_node == null:
		return
	var path = SaveGame.save_match(match_node, save_name)
	if path == "":
		_status.text = tr("SAVE_FAILED")
		return
	saved.emit(path)
	close()


func _load():
	var picked = _list.get_selected_items()
	if picked.is_empty():
		return
	var data = SaveGame.read(_saves[picked[0]]["path"])
	if data == null or not ResourceLoader.exists(data.get("map", "")):
		_status.text = tr("LOAD_FAILED")
		return
	if match_node != null:
		MatchSignals.match_aborted.emit()  # the replay of the match left behind is kept
	load_save(get_tree(), data)


func _on_delete():
	var picked = _list.get_selected_items()
	if picked.is_empty():
		return
	SaveGame.delete(_saves[picked[0]]["path"])
	_refresh()


func _default_name():
	var limits = match_node.get_node_or_null("MatchLimits") if match_node != null else null
	var minutes = int(limits.elapsed_s / 60.0) if limits != null else 0
	var map_name = Constants.Match.MAPS.get(match_node.map.scene_file_path, {}).get("name", "match")
	return "{0} {1}m".format([tr(map_name), minutes])
