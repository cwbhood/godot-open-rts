extends PanelContainer

# Shown above the unit menu while only constructors are selected: one big button turns
# auto-expand on or off for all of them, and a line says what they are doing.

const Worker = preload("res://source/match/units/Worker.gd")
const AutoExpand = preload("res://source/match/units/traits/AutoExpand.gd")

const REFRESH_INTERVAL_S = 0.3
const ON_COLOR = Color(0.55, 1.0, 0.55)

var _toggle = Button.new()
var _status = Label.new()
var _since_refresh_s = 0.0


func _ready():
	name = "AutoExpandBar"
	var margin = MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 5)
	add_child(margin)
	var box = VBoxContainer.new()
	margin.add_child(box)
	_toggle.toggle_mode = true
	_toggle.focus_mode = Control.FOCUS_NONE
	_toggle.custom_minimum_size = Vector2(0, 44)
	_toggle.add_theme_font_size_override("font_size", 18)
	_toggle.tooltip_text = tr("AUTO_EXPAND_TOOLTIP")
	_toggle.toggled.connect(_on_toggled)
	box.add_child(_toggle)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(320, 0)
	_status.add_theme_font_size_override("font_size", 13)
	box.add_child(_status)
	MatchSignals.unit_selected.connect(func(_unit): _refresh())
	MatchSignals.unit_deselected.connect(func(_unit): _refresh())
	MatchSignals.unit_died.connect(func(_unit): _refresh.call_deferred())
	_refresh()


func _process(delta):
	_since_refresh_s += delta
	if _since_refresh_s >= REFRESH_INTERVAL_S:
		_since_refresh_s = 0.0
		_refresh()


func _unhandled_key_input(event):
	# G, like the button (WASD move the camera, so no letter of those)
	if visible and event.pressed and not event.echo and event.keycode == KEY_G:
		_toggle.button_pressed = not _toggle.button_pressed
		get_viewport().set_input_as_handled()


func _selected_constructors():
	var selected = get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return unit.is_in_group("controlled_units")
	)
	if selected.is_empty() or not selected.all(func(unit): return unit is Worker):
		return []
	return selected


func _refresh():
	var constructors = _selected_constructors()
	visible = not constructors.is_empty()
	if not visible:
		return
	var enabled = constructors.filter(func(unit): return AutoExpand.is_enabled_on(unit))
	_toggle.set_pressed_no_signal(enabled.size() == constructors.size())
	_toggle.text = tr("AUTO_EXPAND_ON" if _toggle.button_pressed else "AUTO_EXPAND_OFF")
	_toggle.add_theme_color_override(
		"font_color", ON_COLOR if _toggle.button_pressed else Color.WHITE
	)
	_toggle.add_theme_color_override(
		"font_pressed_color", ON_COLOR if _toggle.button_pressed else Color.WHITE
	)
	if enabled.is_empty():
		_status.text = tr("AUTO_EXPAND_OFF_HINT")
	else:
		var auto_expand = enabled[0].get_node(AutoExpand.NODE_NAME)
		_status.text = auto_expand.status_text
		if enabled.size() > 1:
			_status.text += "\n" + tr("AUTO_EXPAND_MORE").format([enabled.size() - 1])


func _on_toggled(pressed):
	for unit in _selected_constructors():
		AutoExpand.set_enabled_on(unit, pressed)
	_refresh.call_deferred()
