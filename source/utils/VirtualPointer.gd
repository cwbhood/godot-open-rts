extends RefCounted

# The mouse position the game reads. Normally that is the real cursor. The play harness
# (tools/harness/) can switch to its own virtual mouse, so a scripted match on someone's
# PC clicks and drags without taking over their cursor.

const DEVICE = 7077  # InputEvent.device of the events the virtual mouse sends

static var active = false
static var position = Vector2.ZERO


static func get_position(viewport):
	return position if active else viewport.get_mouse_position()
