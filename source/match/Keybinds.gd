extends RefCounted

# Unit command hotkeys are input map actions (project.godot). Players can rebind them in
# user://controls.cfg, read at the start of every match:
#
#   [keys]
#   command_patrol="O"
#   command_fight="Shift+A"
#
# Key names are the ones Godot prints (OS.find_keycode_from_string).

const PATH = "user://controls.cfg"
const ACTIONS = [
	"command_fight",
	"command_patrol",
	"command_guard",
	"command_patrol_base",
	"command_stop",
	"command_retreat",
	"command_fire_stance",
	"command_hold_position",
]


static func apply_overrides(path = PATH):
	var config = ConfigFile.new()
	if config.load(path) != OK:
		return 0
	var applied = 0
	for action in ACTIONS:
		var text = str(config.get_value("keys", action, ""))
		if text == "" or not InputMap.has_action(action):
			continue
		var event = _parse(text)
		if event == null:
			push_warning("controls.cfg: unknown key '{0}' for {1}".format([text, action]))
			continue
		InputMap.action_erase_events(action)
		InputMap.action_add_event(action, event)
		applied += 1
	return applied


static func key_label(action):
	"""the key shown on buttons and in the manual, e.g. "P" """
	if not InputMap.has_action(action):
		return ""
	for event in InputMap.action_get_events(action):
		if event is InputEventKey:
			if event.physical_keycode != 0:
				return event.as_text_physical_keycode()
			return event.as_text_keycode()
	return ""


static func _parse(text):
	var code = OS.find_keycode_from_string(text)
	if code == KEY_NONE:
		return null
	var event = InputEventKey.new()
	event.physical_keycode = code & KEY_CODE_MASK
	event.shift_pressed = (code & KEY_MASK_SHIFT) != 0
	event.ctrl_pressed = (code & KEY_MASK_CTRL) != 0
	event.alt_pressed = (code & KEY_MASK_ALT) != 0
	return event
