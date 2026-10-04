extends Node3D

# Player-side controls for the unit orders in UnitCommands:
# - right-drag with units selected: they spread out along the drawn line (a preview of the
#   spots shows while dragging); a plain right-click still moves/attacks as before,
# - Shift + right-click / order: queued after the current orders,
# - command keys and the matching unit-menu buttons: fight (F), patrol (P), guard (V) wait
#   for a click on the map (a left-drag in fight mode draws a fighting line); patrol my
#   base (B), stop (X), retreat (Z), fire stance (L) and hold position (K) act at once,
# - lines on the ground under selected units show where their orders take them.
# Key bindings are input map actions (see Keybinds.gd), so they can be changed.

signal mode_changed(mode)

const UnitCommands = preload("res://source/match/players/human/UnitCommands.gd")
const Stances = preload("res://source/match/units/actions/Stances.gd")

const DRAG_START_PX = 12.0
const PATH_SAMPLE_M = 0.6
const GUARD_PICK_M = 2.5
const LINE_Y = 0.12
const SLOT_RADIUS_M = 0.55
const COLORS = {
	"move": Color(0.45, 1.0, 0.45, 0.9),
	"fight": Color(1.0, 0.42, 0.3, 0.9),
	"patrol": Color(0.4, 0.75, 1.0, 0.9),
	"guard": Color(1.0, 0.85, 0.3, 0.9),
}
# action name -> what it does; the instant ones need no click on the map
const MODES = ["fight", "patrol", "guard"]
const INSTANT = ["patrol_base", "stop", "retreat", "fire_stance", "hold_position"]

var mode = null  # "fight", "patrol" or "guard" while waiting for a click
var last_preview_slots = []  # for tests: spots shown by the last drag preview

var _drag = null  # {"button", "kind", "start_px", "points", "active"}
var _mesh = ImmediateMesh.new()
var _mesh_instance = MeshInstance3D.new()
var _prompt_layer = CanvasLayer.new()
var _prompt = Label.new()

@onready var _match = find_parent("Match")


func _ready():
	name = "UnitCommandHandler"
	add_to_group("unit_command_handler")
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.render_priority = 10
	_mesh_instance.mesh = _mesh
	_mesh_instance.material_override = material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
	_prompt_layer.layer = 5
	add_child(_prompt_layer)
	_prompt.add_theme_font_size_override("font_size", 18)
	_prompt.add_theme_color_override("font_outline_color", Color.BLACK)
	_prompt.add_theme_constant_override("outline_size", 6)
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt.hide()
	_prompt_layer.add_child(_prompt)


static func of(tree):
	return tree.get_first_node_in_group("unit_command_handler")


# --- public: used by the unit-menu buttons, hotkeys and tests ---------------------------


func selected_units():
	return get_tree().get_nodes_in_group("selected_units").filter(
		func(unit): return unit.is_in_group("controlled_units")
	)


func begin(command):
	"""a button or hotkey: instant commands run, the others wait for a map click"""
	if command in INSTANT:
		run_instant(command)
	elif command in MODES:
		_set_mode(null if mode == command else command)


func run_instant(command):
	var units = selected_units()
	if units.is_empty():
		return
	match command:
		"patrol_base":
			if UnitCommands.patrol_base(units).is_empty():
				return
		"stop":
			UnitCommands.stop(units)
		"retreat":
			UnitCommands.retreat(units)
		"fire_stance":
			var stance = UnitCommands.cycle_fire_stance(units)
			if stance == null:
				return
			_flash(tr("COMMAND_FIRE_STANCE_" + ["AT_WILL", "RETURN", "HOLD"][stance]))
		"hold_position":
			var hold = UnitCommands.toggle_hold_position(units)
			if hold == null:
				return
			_flash(tr("COMMAND_HOLD_ON" if hold else "COMMAND_HOLD_OFF"))
	_issued(command)


func issue_at(command, point, queue = false):
	"""a click on the map in a command mode, or the same from a test"""
	var units = selected_units()
	match command:
		"fight":
			UnitCommands.fight(units, point, queue)
		"patrol":
			UnitCommands.patrol(units, [point], queue)
		"guard":
			var target = _own_unit_near(point, units)
			if target == null or UnitCommands.guard(units, target).is_empty():
				return false
		_:
			UnitCommands.point_order(units, point, "move", queue)
	_issued(command)
	return true


func issue_line(kind, path, queue = false):
	var pairs = UnitCommands.line(selected_units(), path, kind, queue)
	if not pairs.is_empty():
		_issued("line" if kind == "move" else kind + "_line")
	return pairs


# --- input ------------------------------------------------------------------------------


func _unhandled_input(event):
	if event is InputEventKey:
		_handle_key(event)
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion and _drag != null:
		_handle_drag_motion(event.position)


func _handle_key(event):
	if not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE and mode != null:
		_set_mode(null)
		get_viewport().set_input_as_handled()
		return
	if selected_units().is_empty() or _placing_structure():
		return
	for command in MODES + INSTANT:
		if event.is_action_pressed("command_" + command):
			begin(command)
			get_viewport().set_input_as_handled()
			return


func _handle_mouse_button(event):
	if event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			if mode != null:
				_set_mode(null)  # right-click leaves a command mode, like Esc
				get_viewport().set_input_as_handled()
				return
			if _can_drag():
				# not consumed: a plain right-click keeps working; a drag overrides it
				_start_drag(MOUSE_BUTTON_RIGHT, "move", event.position)
		elif _drag != null and _drag["button"] == MOUSE_BUTTON_RIGHT:
			if _drag["active"]:
				issue_line("move", _drag["points"], Input.is_action_pressed("shift_selecting"))
				get_viewport().set_input_as_handled()
			_end_drag()
	elif event.button_index == MOUSE_BUTTON_LEFT and mode != null:
		get_viewport().set_input_as_handled()  # no selection box while giving an order
		if event.pressed:
			_start_drag(MOUSE_BUTTON_LEFT, mode, event.position)
			return
		if _drag == null:
			return
		var queue = Input.is_action_pressed("shift_selecting")
		var command = mode
		if _drag["active"] and command == "fight":
			issue_line("fight", _drag["points"], queue)
		else:
			var point = _ground_point(event.position)
			if point != null:
				issue_at(command, point, queue)
		_end_drag()
		if not queue:
			_set_mode(null)  # Shift keeps the mode for more points


func _can_drag():
	return not UnitCommands.movable(selected_units()).is_empty() and not _placing_structure()


func _start_drag(button, kind, screen_position):
	var point = _ground_point(screen_position)
	if point == null:
		return
	_drag = {
		"button": button,
		"kind": kind,
		"start_px": screen_position,
		"points": [point],
		"active": false,
	}


func _handle_drag_motion(screen_position):
	if not _drag["active"]:
		if screen_position.distance_to(_drag["start_px"]) < DRAG_START_PX:
			return
		_drag["active"] = _drag["kind"] in ["move", "fight"]
	var point = _ground_point(screen_position)
	if point != null and point.distance_to(_drag["points"].back()) >= PATH_SAMPLE_M:
		_drag["points"].append(point)


func _end_drag():
	_drag = null


func _ground_point(screen_position):
	var camera = get_viewport().get_camera_3d()
	if camera == null or not camera.has_method("get_ray_intersection"):
		return null
	var point = camera.get_ray_intersection(screen_position)
	return point * Vector3(1, 0, 1) if point != null else null


func _own_unit_near(point, exclude):
	var best = null
	var best_distance = GUARD_PICK_M
	for unit in get_tree().get_nodes_in_group("controlled_units"):
		if unit in exclude:
			continue
		var reach = GUARD_PICK_M + (unit.radius if unit.radius != null else 0.0)
		var distance = unit.global_position_yless.distance_to(point)
		if distance <= reach and (best == null or distance < best_distance):
			best = unit
			best_distance = distance
	return best


func _placing_structure():
	for player in get_tree().get_nodes_in_group("players"):
		var handler = player.get_node_or_null("StructurePlacementHandler")
		if handler != null and handler._structure_placement_started():
			return true
	return false


func _set_mode(new_mode):
	mode = new_mode
	_end_drag()
	if mode == null:
		_prompt.hide()
	else:
		_prompt.text = tr("COMMAND_PROMPT_" + mode.to_upper())
		_prompt.show()
	mode_changed.emit(mode)


func _flash(text):
	_prompt.text = text
	_prompt.show()
	get_tree().create_timer(1.5).timeout.connect(
		func():
			if mode == null:
				_prompt.hide()
	)


func _issued(command):
	MatchSignals.unit_command_issued.emit(command)


# --- drawing ----------------------------------------------------------------------------


func _process(_delta):
	if _prompt.visible:
		var mouse = get_viewport().get_mouse_position()
		_prompt.position = mouse + Vector2(18, 14)
	_mesh.clear_surfaces()
	var drew = false
	var dragging = _drag != null and _drag["active"]
	for unit in [] if dragging else selected_units():  # while dragging only the new line shows
		if unit.action != null and unit.action.has_method("get_plan"):
			drew = _draw_plan(unit, unit.action.get_plan(), drew)
	if dragging:
		drew = _draw_drag_preview(drew)
	if drew:
		_mesh.surface_end()


func _begin_lines(drew):
	if not drew:
		_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	return true


func _segment(a, b, color):
	_mesh.surface_set_color(color)
	_mesh.surface_add_vertex(Vector3(a.x, LINE_Y, a.z))
	_mesh.surface_set_color(color)
	_mesh.surface_add_vertex(Vector3(b.x, LINE_Y, b.z))


func _ring(center, radius, color):
	var steps = 12
	for i in range(steps):
		var a = TAU * i / steps
		var b = TAU * (i + 1) / steps
		_segment(
			center + Vector3(cos(a), 0, sin(a)) * radius,
			center + Vector3(cos(b), 0, sin(b)) * radius,
			color
		)


func _draw_plan(unit, plan, drew):
	if plan.is_empty() or plan["points"].is_empty():
		return drew
	drew = _begin_lines(drew)
	var kinds = plan.get("kinds", [])
	var previous = unit.global_position_yless
	for i in range(plan["points"].size()):
		var point = plan["points"][i]
		var kind = kinds[i] if i < kinds.size() else plan["kind"]
		var color = COLORS.get(kind, COLORS["move"])
		_segment(previous, point, color)
		_ring(point, SLOT_RADIUS_M * 0.6, color)
		previous = point
	if plan.get("loop", false) and plan["points"].size() > 1:
		_segment(plan["points"].back(), plan["points"].front(), COLORS["patrol"])
	return drew


func _draw_drag_preview(drew):
	drew = _begin_lines(drew)
	var color = COLORS.get(_drag["kind"], COLORS["move"])
	var points = _drag["points"]
	for i in range(1, points.size()):
		_segment(points[i - 1], points[i], color)
	var units = UnitCommands.movable(selected_units())
	var rear = (
		Utils.Match.Unit.Movement.calculate_aabb_crowd_pivot_yless(units)
		if not units.is_empty()
		else null
	)
	last_preview_slots = UnitCommands.formation_slots(
		points, units.size(), UnitCommands.spacing_for(units), rear
	)
	for slot in last_preview_slots:
		_ring(slot, SLOT_RADIUS_M, color)
	return drew
