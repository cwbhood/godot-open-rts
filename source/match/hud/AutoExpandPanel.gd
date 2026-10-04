extends PanelContainer

# Overview of auto-expand for the human player: which constructors run it and what each is
# doing, what it has spent so far, how much it must leave in the bank, and buttons to turn
# it on or off for every constructor at once. Clicking a line selects that constructor.

const Worker = preload("res://source/match/units/Worker.gd")
const AutoExpand = preload("res://source/match/units/traits/AutoExpand.gd")
const HudStyle = preload("res://source/match/hud/HudStyle.gd")

const REFRESH_INTERVAL_S = 0.5
const RESERVE_CHOICES = [0, 10, 25, 50]
const WIDTH = 280

var _player = null
var _title = Label.new()
var _lines = VBoxContainer.new()
var _spent_label = Label.new()
var _reserve_option = OptionButton.new()
var _all_on = Button.new()
var _all_off = Button.new()
var _details = VBoxContainer.new()
var _collapse = Button.new()
var _since_refresh_s = REFRESH_INTERVAL_S


func _ready():
	name = "AutoExpandPanel"
	custom_minimum_size = Vector2(WIDTH, 0)
	var margin = HudStyle.margin(self, 8, 5)
	var box = VBoxContainer.new()
	margin.add_child(box)
	_title.tooltip_text = tr("AUTO_EXPAND_TOOLTIP")
	_title.mouse_filter = Control.MOUSE_FILTER_PASS
	_collapse.pressed.connect(func(): _set_collapsed(_details.visible))
	box.add_child(HudStyle.header("expand", _title, _collapse))
	box.add_child(_details)
	_details.add_child(_lines)
	_spent_label.add_theme_font_size_override("font_size", 12)
	_spent_label.theme_type_variation = "MutedLabel"
	_spent_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_details.add_child(_spent_label)
	var reserve_row = HBoxContainer.new()
	var reserve_label = Label.new()
	reserve_label.text = tr("AUTO_EXPAND_RESERVE")
	reserve_label.tooltip_text = tr("AUTO_EXPAND_RESERVE_TOOLTIP")
	reserve_label.mouse_filter = Control.MOUSE_FILTER_PASS
	reserve_label.add_theme_font_size_override("font_size", 13)
	reserve_row.add_child(reserve_label)
	for choice in RESERVE_CHOICES:
		_reserve_option.add_item(str(choice))
	_reserve_option.tooltip_text = tr("AUTO_EXPAND_RESERVE_TOOLTIP")
	_reserve_option.focus_mode = Control.FOCUS_NONE
	_reserve_option.item_selected.connect(_on_reserve_selected)
	reserve_row.add_child(_reserve_option)
	_details.add_child(reserve_row)
	var buttons = HBoxContainer.new()
	_all_on.text = tr("AUTO_EXPAND_ALL_ON")
	_all_on.focus_mode = Control.FOCUS_NONE
	_all_on.pressed.connect(_set_all.bind(true))
	buttons.add_child(_all_on)
	_all_off.text = tr("AUTO_EXPAND_ALL_OFF")
	_all_off.focus_mode = Control.FOCUS_NONE
	_all_off.pressed.connect(_set_all.bind(false))
	buttons.add_child(_all_off)
	_details.add_child(buttons)
	_set_collapsed(true)  # the tutorial opens it at its step (see Guide)


func setup(player):
	_player = player
	var reserve = AutoExpand.get_reserve(player)
	_reserve_option.select(max(0, RESERVE_CHOICES.find(reserve)))
	_refresh()


func _process(delta):
	_since_refresh_s += delta
	if _since_refresh_s >= REFRESH_INTERVAL_S:
		_since_refresh_s = 0.0
		_refresh()


func _constructors():
	if _player == null:
		return []
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Worker and unit.player == _player
	)


func _refresh():
	if _player == null or not is_instance_valid(_player):
		return
	var constructors = _constructors()
	var enabled = constructors.filter(func(unit): return AutoExpand.is_enabled_on(unit))
	_title.text = tr("HUD_AUTO_EXPAND_SHORT").format([enabled.size(), constructors.size()])
	_title.tooltip_text = (
		tr("AUTO_EXPAND_TITLE").format([enabled.size(), constructors.size()])
		+ "\n"
		+ tr("AUTO_EXPAND_TOOLTIP")
	)
	# rows are reused rather than rebuilt, so that a click is not lost to a refresh
	var rows = _lines.get_children()
	for index in range(max(enabled.size(), 1), rows.size()):
		rows[index].hide()
	for index in range(max(enabled.size(), 1)):
		var line = rows[index] if index < rows.size() else _make_line()
		line.show()
		if enabled.is_empty():
			line.set_meta("unit", null)
			line.text = tr("AUTO_EXPAND_NONE")
			line.tooltip_text = tr("AUTO_EXPAND_TOOLTIP")
			continue
		var status = enabled[index].get_node(AutoExpand.NODE_NAME).status_text
		line.set_meta("unit", enabled[index])
		line.text = "• " + status
		line.tooltip_text = status
	var spent = AutoExpand.get_spent(_player)
	var parts = []
	for resource in Constants.Match.Resources.ALL:
		if spent.get(resource, 0) > 0:
			parts.append("{0} {1}".format([spent[resource], tr(resource.to_upper())]))
	_spent_label.text = tr("AUTO_EXPAND_SPENT").format(
		[", ".join(parts) if not parts.is_empty() else "0"]
	)
	_all_on.disabled = enabled.size() == constructors.size()
	_all_off.disabled = enabled.is_empty()


func _make_line():
	var line = Button.new()
	line.flat = true
	line.focus_mode = Control.FOCUS_NONE
	line.alignment = HORIZONTAL_ALIGNMENT_LEFT
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.clip_text = true
	line.custom_minimum_size = Vector2(WIDTH - 16, 0)
	line.add_theme_font_size_override("font_size", 12)
	line.pressed.connect(func(): _select(line.get_meta("unit", null)))
	_lines.add_child(line)
	return line


func _set_collapsed(collapsed):
	_details.visible = not collapsed
	HudStyle.set_folded_icon(_collapse, collapsed)
	reset_size()


func set_collapsed(collapsed):
	_set_collapsed(collapsed)


func _set_all(enabled):
	for unit in _constructors():
		AutoExpand.set_enabled_on(unit, enabled)
		unit.set_meta("auto_expand_opt_out", not enabled)  # the helper leaves it alone
	_refresh()


func _on_reserve_selected(index):
	if _player != null:
		_player.set_meta(AutoExpand.RESERVE_META, RESERVE_CHOICES[index])


func _select(unit):
	if unit == null or not is_instance_valid(unit):
		return
	MatchSignals.deselect_all_units.emit()
	unit.find_child("Selection").select()
	var camera = get_viewport().get_camera_3d()
	if camera != null and camera.has_method("set_position_safely"):
		camera.set_position_safely(unit.global_position)
