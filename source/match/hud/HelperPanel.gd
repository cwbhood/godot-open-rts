extends PanelContainer

# The helper's panel (top left): the on/off switch (or H), what the helper is doing, its
# latest warnings, how much of each commodity it must leave in the bank, the army size it
# keeps and whether it scouts. Clicking a warning moves the camera there.

const Helper = preload("res://source/match/players/human/Helper.gd")
const HudStyle = preload("res://source/match/hud/HudStyle.gd")

const REFRESH_INTERVAL_S = 0.5
const KEEP_CHOICES = [0, 10, 25, 50, 100]
const ARMY_CHOICES = [0, 4, 8, 12, 20]
const ALERT_COLOR = Color(1.0, 0.75, 0.4)
const ALERT_SHOWN_S = 30.0
const WIDTH = 280

var _helper = null
var _title = Label.new()
var _switch = CheckButton.new()
var _collapse = Button.new()
var _details = VBoxContainer.new()
var _status = Label.new()
var _alert = Button.new()
var _keep_options = {}  # commodity -> OptionButton
var _army_option = OptionButton.new()
var _scout_box = CheckBox.new()
var _since_refresh_s = REFRESH_INTERVAL_S


func _ready():
	name = "HelperPanel"
	custom_minimum_size = Vector2(WIDTH, 0)
	var margin = HudStyle.margin(self, 8, 5)
	var box = VBoxContainer.new()
	margin.add_child(box)
	_title.text = tr("HELPER_TITLE")
	_title.tooltip_text = tr("HELPER_TOOLTIP")
	_title.mouse_filter = Control.MOUSE_FILTER_PASS
	_collapse.pressed.connect(func(): _set_collapsed(_details.visible))
	var header = HudStyle.header("helper", _title, null)
	box.add_child(header)
	_switch.focus_mode = Control.FOCUS_NONE
	_switch.tooltip_text = tr("HELPER_TOOLTIP")
	_switch.add_theme_font_size_override("font_size", 13)
	_switch.toggled.connect(_on_switch_toggled)
	header.add_child(_switch)
	HudStyle.style_fold_button(_collapse)
	header.add_child(_collapse)
	box.add_child(_details)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(WIDTH - 16, 0)
	_status.add_theme_font_size_override("font_size", 13)
	_status.theme_type_variation = "MutedLabel"
	_details.add_child(_status)
	_alert.flat = true
	_alert.focus_mode = Control.FOCUS_NONE
	_alert.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_alert.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_alert.clip_text = true
	_alert.custom_minimum_size = Vector2(WIDTH - 16, 0)
	_alert.add_theme_font_size_override("font_size", 12)
	_alert.add_theme_color_override("font_color", ALERT_COLOR)
	_alert.add_theme_color_override("font_hover_color", ALERT_COLOR.lightened(0.3))
	_alert.pressed.connect(_look_at_alert)
	_details.add_child(_alert)
	_details.add_child(_settings_label("HELPER_KEEP", "HELPER_KEEP_TOOLTIP"))
	var grid = GridContainer.new()
	grid.columns = 4
	_details.add_child(grid)
	for resource in Constants.Match.Resources.ALL:
		var label = Label.new()
		label.text = tr(resource.to_upper())
		label.add_theme_font_size_override("font_size", 12)
		grid.add_child(label)
		var option = _option(KEEP_CHOICES, "HELPER_KEEP_TOOLTIP")
		option.item_selected.connect(_on_keep_selected.bind(resource))
		grid.add_child(option)
		_keep_options[resource] = option
	var army_row = HBoxContainer.new()
	army_row.add_child(_settings_label("HELPER_ARMY", "HELPER_ARMY_TOOLTIP"))
	_army_option = _option(ARMY_CHOICES, "HELPER_ARMY_TOOLTIP")
	_army_option.item_selected.connect(_on_army_selected)
	army_row.add_child(_army_option)
	_details.add_child(army_row)
	_scout_box.text = tr("HELPER_SCOUT")
	_scout_box.tooltip_text = tr("HELPER_SCOUT_TOOLTIP")
	_scout_box.focus_mode = Control.FOCUS_NONE
	_scout_box.add_theme_font_size_override("font_size", 13)
	_scout_box.toggled.connect(_on_scout_toggled)
	_details.add_child(_scout_box)
	_set_collapsed(true)


func setup(player):
	_helper = Helper.of(player)
	if _helper == null:
		hide()
		return
	for resource in _keep_options:
		_keep_options[resource].select(max(0, KEEP_CHOICES.find(_helper.keep_of(resource))))
	_army_option.select(max(0, ARMY_CHOICES.find(_helper.army_target)))
	_scout_box.set_pressed_no_signal(_helper.scouting)
	_refresh()


func toggle():
	if _helper != null:
		_switch.button_pressed = not _switch.button_pressed


func _unhandled_key_input(event):
	if event.pressed and not event.echo and event.keycode == KEY_H and _helper != null:
		toggle()
		get_viewport().set_input_as_handled()


func _process(delta):
	_since_refresh_s += delta
	if _since_refresh_s >= REFRESH_INTERVAL_S:
		_since_refresh_s = 0.0
		_refresh()


func _refresh():
	if _helper == null or not is_instance_valid(_helper):
		return
	_switch.set_pressed_no_signal(_helper.enabled)
	_switch.text = tr("HELPER_ON") if _helper.enabled else tr("HELPER_OFF")
	_status.text = "\n".join(_helper.status_lines())
	var latest = _helper.alerts[0] if not _helper.alerts.is_empty() else null
	_alert.visible = (
		_helper.enabled and latest != null and _helper.get("_clock_s") - latest["t"] < ALERT_SHOWN_S
	)
	if _alert.visible:
		_alert.text = "⚠ " + latest["text"]
		_alert.tooltip_text = latest["text"]
		_alert.set_meta("position", latest.get("position"))


func _settings_label(key, tooltip):
	var label = Label.new()
	label.text = tr(key)
	label.tooltip_text = tr(tooltip)
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.add_theme_font_size_override("font_size", 13)
	return label


func _option(choices, tooltip):
	var option = OptionButton.new()
	for choice in choices:
		option.add_item(str(choice))
	option.tooltip_text = tr(tooltip)
	option.focus_mode = Control.FOCUS_NONE
	option.add_theme_font_size_override("font_size", 12)
	return option


func _set_collapsed(collapsed):
	_details.visible = not collapsed
	HudStyle.set_folded_icon(_collapse, collapsed)
	reset_size()


func set_collapsed(collapsed):
	_set_collapsed(collapsed)


func _on_switch_toggled(pressed):
	if _helper == null:
		return
	_helper.enabled = pressed
	if pressed:
		_set_collapsed(false)
	_refresh()


func _on_keep_selected(index, resource):
	if _helper != null:
		_helper.keep[resource] = KEEP_CHOICES[index]


func _on_army_selected(index):
	if _helper != null:
		_helper.army_target = ARMY_CHOICES[index]


func _on_scout_toggled(pressed):
	if _helper != null:
		_helper.scouting = pressed


func _look_at_alert():
	var position = _alert.get_meta("position", null)
	var camera = get_viewport().get_camera_3d()
	if position != null and camera != null and camera.has_method("set_position_safely"):
		camera.set_position_safely(position)
