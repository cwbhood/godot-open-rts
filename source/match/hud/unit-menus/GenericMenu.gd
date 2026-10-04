extends GridContainer

const Structure = preload("res://source/match/units/Structure.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Keybinds = preload("res://source/match/Keybinds.gd")
const Stances = preload("res://source/match/units/actions/Stances.gd")
const UnitCommandHandler = preload("res://source/match/handlers/UnitCommandHandler.gd")

# unit orders on the second and third rows (see UnitCommandHandler); the first row and
# the last slot stay free for the cancel button and the worker's build menu underneath
const COMMANDS = [
	["fight", "Padding5"],
	["patrol", "Padding6"],
	["patrol_base", "Padding7"],
	["guard", "Padding8"],
	["retreat", "Padding9"],
	["fire_stance", "Padding10"],
	["hold_position", "Padding11"],
]

var units = []

var _command_buttons = {}  # command -> button
var _cancel_button = null


func _ready():
	for entry in COMMANDS:
		_command_buttons[entry[0]] = _replace_padding(entry[1], entry[0])
	var cancel = find_child("CancelActionButton")
	_cancel_button = cancel
	cancel.tooltip_text = "{0} ({1})".format(
		[tr("CANCEL_CURRENT_ACTION"), Keybinds.key_label("command_stop")]
	)


func _replace_padding(padding_name, command):
	var padding = get_node(padding_name)
	var button = Button.new()
	button.name = "Command_" + command
	button.theme_type_variation = "SlotButton"
	button.custom_minimum_size = padding.custom_minimum_size
	button.focus_mode = Control.FOCUS_NONE
	button.toggle_mode = command in UnitCommandHandler.MODES
	button.add_theme_font_size_override("font_size", 13)
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.tooltip_text = "{0} ({1})".format(
		[
			tr("COMMAND_{0}_TOOLTIP".format([command.to_upper()])),
			Keybinds.key_label("command_" + command)
		]
	)
	button.pressed.connect(_on_command_pressed.bind(command))
	add_child(button)
	move_child(button, padding.get_index())
	padding.queue_free()
	remove_child(padding)
	return button


func _process(_delta):
	if not is_visible_in_tree():
		return
	var handler = UnitCommandHandler.of(get_tree())
	var movable = units.filter(
		func(unit):
			return is_instance_valid(unit) and not unit is Structure and unit.movement_speed > 0.0
	)
	var armed = movable.filter(func(unit): return unit.attack_range != null)
	# a single constructor shows its build menu in the same slots
	var show = not movable.is_empty() and not (units.size() == 1 and units[0] is Worker)
	# under a single constructor's build menu the cancel button would peek between the
	# build buttons without being clickable; X (stop) still cancels
	_cancel_button.visible = not (units.size() == 1 and units[0] is Worker)
	for command in _command_buttons:
		var button = _command_buttons[command]
		button.visible = show
		button.disabled = command in ["fire_stance", "hold_position"] and armed.is_empty()
		var key = Keybinds.key_label("command_" + command)
		var label = tr("COMMAND_{0}".format([command.to_upper()]))
		if command == "fire_stance" and not armed.is_empty():
			label = tr(
				(
					"COMMAND_FIRE_STANCE_SHORT_"
					+ ["AT_WILL", "RETURN", "HOLD"][Stances.fire_stance(armed[0])]
				)
			)
		elif command == "hold_position" and not armed.is_empty():
			label = tr(
				(
					"COMMAND_HOLD_SHORT_ON"
					if Stances.holds_position(armed[0])
					else "COMMAND_HOLD_SHORT_OFF"
				)
			)
		button.text = "{0}\n[{1}]".format([label, key])
		if button.toggle_mode:
			button.set_pressed_no_signal(handler != null and handler.mode == command)


func _on_command_pressed(command):
	var handler = UnitCommandHandler.of(get_tree())
	if handler != null:
		handler.begin(command)


func _on_cancel_action_button_pressed():
	if len(units) == 1 and units[0] is Structure and units[0].is_under_construction():
		units[0].cancel_construction()
		return
	for unit in units:
		unit.action = null
