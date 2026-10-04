extends Node

# The harness's own mouse. It sends clicks, drags and hovers into the game as input events
# (the same events a real mouse makes), draws a small cursor so screenshots and anyone
# watching can see where it points, and leaves the real cursor alone: no warping, no
# confining. While it is on, real mouse input is kept out of the game so a person moving
# their mouse over the window does not disturb a scripted match (--real-mouse=on lets it
# through, to play along).

const VirtualPointer = preload("res://source/utils/VirtualPointer.gd")

var block_real_mouse = true

var _layer = CanvasLayer.new()
var _cursor = Polygon2D.new()
var _buttons = 0


func _ready():
	name = "VirtualMouse"
	process_mode = Node.PROCESS_MODE_ALWAYS
	VirtualPointer.active = true
	VirtualPointer.position = get_viewport().get_visible_rect().size / 2.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_layer.layer = 128
	add_child(_layer)
	_cursor.polygon = PackedVector2Array(
		[
			Vector2(0, 0),
			Vector2(0, 17),
			Vector2(4.5, 13),
			Vector2(8, 20),
			Vector2(10.5, 19),
			Vector2(7, 12),
			Vector2(12.5, 12)
		]
	)
	_cursor.color = Color(1.0, 0.85, 0.2)
	var outline = Line2D.new()
	outline.points = _cursor.polygon + PackedVector2Array([Vector2(0, 0)])
	outline.width = 1.5
	outline.default_color = Color.BLACK
	_cursor.add_child(outline)
	_layer.add_child(_cursor)
	_cursor.position = VirtualPointer.position
	# stay the last child of the root, so this node sees input before the match does
	get_tree().root.child_entered_tree.connect(func(_node): _stay_last.call_deferred())


func _exit_tree():
	VirtualPointer.active = false


func _stay_last():
	if is_inside_tree() and get_parent() == get_tree().root:
		get_parent().move_child(self, -1)


func _input(event):
	if not block_real_mouse:
		return
	if (
		(
			event is InputEventMouse
			or event is InputEventScreenTouch
			or event is InputEventScreenDrag
		)
		and event.device != VirtualPointer.DEVICE
	):
		get_viewport().set_input_as_handled()


func position():
	return VirtualPointer.position


func move(to, steps = 1):
	"""moves in a few steps, like a hand would, so hovers and drags register"""
	var from = VirtualPointer.position
	for step in range(1, steps + 1):
		var point = from.lerp(to, float(step) / steps)
		var event = InputEventMouseMotion.new()
		event.device = VirtualPointer.DEVICE
		event.position = point
		event.global_position = point
		event.relative = point - VirtualPointer.position
		event.button_mask = _buttons
		VirtualPointer.position = point
		_cursor.position = point
		Input.parse_input_event(event)
		await get_tree().process_frame


func button(button_index, pressed, at = null, shift = false):
	if at != null:
		await move(at)
	var event = InputEventMouseButton.new()
	event.device = VirtualPointer.DEVICE
	event.position = VirtualPointer.position
	event.global_position = VirtualPointer.position
	event.button_index = button_index
	event.pressed = pressed
	event.shift_pressed = shift
	var mask = 1 << (button_index - 1)
	_buttons = (_buttons | mask) if pressed else (_buttons & ~mask)
	event.button_mask = _buttons
	Input.parse_input_event(event)
	await get_tree().process_frame


func click(at, button_index = MOUSE_BUTTON_LEFT, shift = false):
	await move(at, 2)
	await button(button_index, true, null, shift)
	await get_tree().process_frame
	await button(button_index, false, null, shift)
	await get_tree().process_frame


func drag(from, to, button_index = MOUSE_BUTTON_LEFT, steps = 6, shift = false):
	await move(from, 2)
	await button(button_index, true, null, shift)
	await move(to, steps)
	await button(button_index, false, null, shift)
	await get_tree().process_frame


func key(keycode, shift = false):
	for pressed in [true, false]:
		var event = InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = pressed
		event.shift_pressed = shift
		Input.parse_input_event(event)
		await get_tree().process_frame


func action(action_name):
	for pressed in [true, false]:
		var event = InputEventAction.new()
		event.action = action_name
		event.pressed = pressed
		Input.parse_input_event(event)
		await get_tree().process_frame
