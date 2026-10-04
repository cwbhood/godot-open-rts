extends Control

# Pre-match screen, as in Beyond All Reason: the whole map is shown from above with its
# start zones and resource deposits, and the human player clicks inside a start zone to
# place their starter city before a countdown runs out. AI players pick their zones in
# secret when the match starts, never a zone someone else holds, so the player only finds
# out where the rivals are by scouting. When time runs out without a pick, the player gets
# the free zone that matches their slot.

const LoadingScene = preload("res://source/main-menu/Loading.tscn")
const BackgroundScene = preload("res://source/main-menu/Background.tscn")

const PREVIEW_PIXELS = 1024
const DEPOSIT_CLEARANCE = 6.0  # metres between the city and a deposit's center
const EDGE_MARGIN = 4.0
const PANEL_WIDTH = 340

var match_settings = null
var map_path = null

var _map_info = {}
var _map = null  # preview copy of the map, rendered once from above
var _zones = []  # [{center: Vector2, radius: float}]
var _deposits = []  # [{kind, center: Vector2, amount}]
var _human = -1  # index into match_settings.players
var _choice = null  # {zone: int, position: Vector2}
var _hover_zone = -1
var _time_left = 30.0
var _started = false
var _rng = RandomNumberGenerator.new()
var _ui = {}


func _ready():
	_rng.randomize()
	name = "StartPicker"
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(BackgroundScene.instantiate())
	_map_info = Constants.Match.MAPS.get(map_path, {})
	for index in range(match_settings.players.size()):
		if match_settings.players[index].controller == Constants.PlayerType.HUMAN:
			_human = index
	_load_map()
	_time_left = _pick_seconds()
	_build_ui()
	_refresh()


func _process(delta):
	if _started:
		return
	_time_left -= delta
	_ui.timer.text = tr("START_PICK_TIME_LEFT").format([int(ceil(max(_time_left, 0.0)))])
	if _time_left <= 5.0:
		_ui.timer.add_theme_color_override("font_color", Color(1.0, 0.45, 0.35))
	if _time_left <= 0.0:
		start_match()


# public, also used by tests


func choose_spot(map_position: Vector2) -> bool:
	"""places the starter city at a point on the map, if that point is allowed"""
	var zone = _zone_at(map_position)
	if zone == -1:
		_set_message(tr("START_PICK_OUTSIDE_ZONE"))
		return false
	var problem = _spot_problem(map_position)
	if problem != "":
		_set_message(problem)
		return false
	_choose(zone, map_position)
	return true


func choose_random_spot():
	var zone = _rng.randi() % _zones.size()
	_choose(zone, _zones[zone].center)


func start_match():
	if _started:
		return
	_started = true
	if _human != -1 and _choice == null and not _zones.is_empty():
		_choose(_default_zone(), _zones[_default_zone()].center)
	_assign_start_zones()
	var loading = LoadingScene.instantiate()
	loading.match_settings = match_settings
	loading.map_path = map_path
	get_parent().add_child(loading)
	get_tree().current_scene = loading
	queue_free()


func get_start_zones():
	return _zones


# map preview


func _pick_seconds() -> float:
	var seconds = float(match_settings.get("start_pick_seconds"))
	if seconds <= 0.0:
		seconds = float(_map_info.get("start_pick_seconds", _map.start_pick_seconds))
	return max(seconds, 3.0)


func _load_map():
	_map = load(map_path).instantiate()
	var radius = _map_info.get("start_zone_radius")
	for zone in _map.get_start_zones():
		if radius != null:
			zone.radius = float(radius)
		_zones.append(zone)
	_deposits = _map.get_deposit_list()
	# deposit units and their scripts need a running match; the overlay draws them instead
	var resources = _map.find_child("Resources")
	if resources != null:
		for child in resources.get_children():
			resources.remove_child(child)
			child.free()


func _build_preview() -> SubViewportContainer:
	var map_size = Vector2(_map.size)
	var viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(
		(Vector2(PREVIEW_PIXELS, PREVIEW_PIXELS) * map_size / max(map_size.x, map_size.y)).round()
	)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.msaa_3d = Viewport.MSAA_4X
	var environment = WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.1, 0.09, 0.08)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.85, 0.8, 0.75)
	environment.environment.ambient_light_energy = 0.3
	environment.environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment.tonemap_exposure = 0.75
	viewport.add_child(environment)
	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	sun.light_energy = 0.85
	sun.shadow_enabled = true
	viewport.add_child(sun)
	var camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.size = map_size.x
	camera.near = 1.0
	camera.far = 600.0
	camera.position = Vector3(map_size.x / 2.0, 300.0, map_size.y / 2.0)
	camera.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	viewport.add_child(camera)
	viewport.add_child(_map)
	var water = _map.get_node_or_null("Water")
	if water != null:
		# the water shader reflects the sky, which reads as white from straight above
		var flat_water = StandardMaterial3D.new()
		flat_water.albedo_color = Color(0.16, 0.42, 0.55)
		flat_water.roughness = 0.6
		water.material_override = flat_water
	var container = SubViewportContainer.new()
	container.stretch = true
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	container.add_child(viewport)
	return container


# UI


func _build_ui():
	var margin = MarginContainer.new()
	margin.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	add_child(margin)
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	margin.add_child(row)

	var frame = AspectRatioContainer.new()
	frame.ratio = float(_map.size.x) / float(_map.size.y)
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(frame)
	var holder = Control.new()
	holder.name = "MapHolder"
	frame.add_child(holder)
	holder.add_child(_build_preview())
	var overlay = Control.new()
	overlay.name = "MapOverlay"
	overlay.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.draw.connect(_draw_overlay.bind(overlay))
	overlay.gui_input.connect(_on_overlay_input.bind(overlay))
	holder.add_child(overlay)
	_ui.overlay = overlay

	var panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.0, 0.0, 0.0, 0.6)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	row.add_child(panel)
	var column = VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)

	var title = Label.new()
	title.text = tr("START_PICK_TITLE")
	title.add_theme_font_size_override("font_size", 28)
	column.add_child(title)
	var map_name = Label.new()
	map_name.text = "{0}  ·  {1}x{2} m".format(
		[_map_info.get("name", ""), int(_map.size.x), int(_map.size.y)]
	)
	map_name.modulate = Color(1, 1, 1, 0.75)
	column.add_child(map_name)
	_ui.timer = Label.new()
	_ui.timer.name = "TimerLabel"
	_ui.timer.add_theme_font_size_override("font_size", 40)
	_ui.timer.text = " "
	column.add_child(_ui.timer)
	var hint = Label.new()
	hint.text = tr("START_PICK_HINT")
	hint.custom_minimum_size = Vector2(PANEL_WIDTH - 40, 0)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(hint)
	_ui.message = Label.new()
	_ui.message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ui.message.add_theme_color_override("font_color", Color(1.0, 0.8, 0.45))
	column.add_child(_ui.message)

	column.add_child(HSeparator.new())
	_ui.players = VBoxContainer.new()
	column.add_child(_ui.players)
	column.add_child(HSeparator.new())
	column.add_child(_legend())

	var spacer = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)
	_ui.random = _button(tr("START_PICK_RANDOM"), "RandomSpotButton", choose_random_spot)
	column.add_child(_ui.random)
	_ui.start = _button(tr("START_PICK_START"), "StartMatchButton", start_match)
	_ui.start.add_theme_font_size_override("font_size", 22)
	column.add_child(_ui.start)
	column.add_child(_button(tr("BACK"), "BackButton", _on_back))


func _button(text, node_name, callback):
	var button = Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = Vector2(0, 44)
	button.pressed.connect(callback)
	return button


func _legend():
	var box = HFlowContainer.new()
	var colors = Constants.Match.Resources.COLORS
	for kind in colors:
		var swatch = Panel.new()
		var swatch_style = StyleBoxFlat.new()
		swatch_style.bg_color = colors[kind]
		swatch_style.set_border_width_all(1)
		swatch_style.border_color = Color(1, 1, 1, 0.6)
		swatch.add_theme_stylebox_override("panel", swatch_style)
		swatch.custom_minimum_size = Vector2(14, 14)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		box.add_child(swatch)
		var label = Label.new()
		label.text = tr(String(kind).to_upper()) + "   "
		box.add_child(label)
	var note = Label.new()
	note.text = tr("START_PICK_LEGEND")
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(PANEL_WIDTH - 40, 0)
	note.modulate = Color(1, 1, 1, 0.75)
	box.add_child(note)
	return box


func _refresh():
	for child in _ui.players.get_children():
		child.queue_free()
	for index in range(match_settings.players.size()):
		var settings = match_settings.players[index]
		var line = HBoxContainer.new()
		var swatch = ColorRect.new()
		swatch.color = settings.color
		swatch.custom_minimum_size = Vector2(18, 18)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		line.add_child(swatch)
		var label = Label.new()
		if index == _human:
			var status = tr("START_PICK_YOU_WAITING")
			if _choice != null:
				status = tr("START_PICK_YOU_READY").format([_choice.zone + 1])
			label.text = "  " + status
		else:
			label.text = "  " + tr("START_PICK_AI_SECRET")
		line.add_child(label)
		_ui.players.add_child(line)
	_ui.start.disabled = _human != -1 and _choice == null
	_ui.random.disabled = _human == -1
	_ui.overlay.queue_redraw()


func _set_message(text):
	_ui.message.text = text


func _on_back():
	get_tree().change_scene_to_file("res://source/main-menu/Play.tscn")


# picking


func _choose(zone, map_position):
	_choice = {"zone": zone, "position": map_position}
	_set_message("")
	_refresh()


func _zone_at(map_position: Vector2) -> int:
	for index in range(_zones.size()):
		if map_position.distance_to(_zones[index].center) <= _zones[index].radius:
			return index
	return -1


func _spot_problem(map_position: Vector2) -> String:
	var map_size = Vector2(_map.size)
	if (
		map_position.x < EDGE_MARGIN
		or map_position.y < EDGE_MARGIN
		or map_position.x > map_size.x - EDGE_MARGIN
		or map_position.y > map_size.y - EDGE_MARGIN
	):
		return tr("START_PICK_TOO_CLOSE_TO_EDGE")
	for deposit in _deposits:
		if map_position.distance_to(deposit.center) < DEPOSIT_CLEARANCE:
			return tr("START_PICK_TOO_CLOSE_TO_DEPOSIT")
	if _map.has_method("is_obstructed") and _map.is_obstructed(map_position, 2.5):
		return tr("START_PICK_BLOCKED")
	return ""


func _default_zone() -> int:
	"""the zone matching the player's slot, as before start zones existed"""
	return clamp(_human, 0, _zones.size() - 1)


func _assign_start_zones():
	"""AIs pick in secret: each takes the free zone furthest from the zones already taken,
	so two rivals never share a zone and a 2-player game on a 4-zone map starts across the
	map. Ties are broken at random so the human cannot predict the pick."""
	var taken = []
	if _human != -1 and _choice != null:
		taken.append(_choice.zone)
		_apply_zone(match_settings.players[_human], _choice.zone, _choice.position)
	for index in range(match_settings.players.size()):
		if index == _human:
			continue
		var best = []
		var best_score = -INF
		for zone in range(_zones.size()):
			if zone in taken:
				continue
			var score = INF if taken.is_empty() else 0.0
			if not taken.is_empty():
				score = (
					taken
					. map(func(other): return _zones[zone].center.distance_to(_zones[other].center))
					. min()
				)
			if score > best_score + 0.5:
				best = [zone]
				best_score = score
			elif abs(score - best_score) <= 0.5:
				best.append(zone)
		if best.is_empty():
			break  # more players than zones; the match falls back to slot order
		var zone = best[_rng.randi() % best.size()]
		if taken.is_empty() and index < _zones.size():
			zone = index
		taken.append(zone)
		_apply_zone(match_settings.players[index], zone, _zones[zone].center)


func _apply_zone(player_settings, zone, map_position):
	player_settings.start_zone = zone
	player_settings.start_position = map_position


func _to_map(overlay, local: Vector2) -> Vector2:
	return local / overlay.size * Vector2(_map.size)


func _to_overlay(overlay, map_position: Vector2) -> Vector2:
	return map_position / Vector2(_map.size) * overlay.size


func _on_overlay_input(event, overlay):
	if event is InputEventMouseMotion:
		var hover = _zone_at(_to_map(overlay, event.position))
		if hover != _hover_zone:
			_hover_zone = hover
			overlay.queue_redraw()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT and _human != -1:
			choose_spot(_to_map(overlay, event.position))


func _draw_overlay(overlay):
	var scale = overlay.size.x / float(_map.size.x)
	var font = get_theme_default_font()
	var colors = Constants.Match.Resources.COLORS
	for deposit in _deposits:
		var default_amount = Constants.Match.Resources.DEFAULT_DEPOSIT_AMOUNT.get(
			String(deposit.kind), 500
		)
		var radius = 1.3 * sqrt(float(deposit.amount) / max(default_amount, 1)) * scale
		var center = _to_overlay(overlay, deposit.center)
		overlay.draw_circle(center, radius + 2.0, Color(0, 0, 0, 0.7))
		overlay.draw_circle(center, radius, colors.get(deposit.kind, Color.WHITE))
	for index in range(_zones.size()):
		var zone = _zones[index]
		var center = _to_overlay(overlay, zone.center)
		var radius = zone.radius * scale
		var mine = _choice != null and _choice.zone == index
		var color = Color(1, 1, 1)
		if mine:
			color = match_settings.players[_human].color
		var fill = Color(color, 0.35 if index == _hover_zone or mine else 0.18)
		overlay.draw_circle(center, radius, fill)
		overlay.draw_arc(center, radius, 0.0, TAU, 48, Color(0, 0, 0, 0.8), 6.0, true)
		overlay.draw_arc(center, radius, 0.0, TAU, 48, Color(color, 0.95), 3.0, true)
		var label = tr("START_PICK_ZONE_N").format([index + 1])
		overlay.draw_string_outline(
			font,
			center + Vector2(-radius, -radius - 8.0),
			label,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			18,
			6,
			Color(0, 0, 0, 0.8)
		)
		overlay.draw_string(
			font,
			center + Vector2(-radius, -radius - 8.0),
			label,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			18,
			Color(1, 1, 1)
		)
	if _choice != null:
		var color = match_settings.players[_human].color
		var spot = _to_overlay(overlay, _choice.position)
		var half = 2.2 * scale
		overlay.draw_rect(Rect2(spot - Vector2(half, half), Vector2(half, half) * 2.0), color)
		overlay.draw_rect(
			Rect2(spot - Vector2(half, half), Vector2(half, half) * 2.0), Color.BLACK, false, 2.0
		)
		var label = tr("START_PICK_YOUR_CITY")
		overlay.draw_string_outline(
			font,
			spot + Vector2(half + 6.0, 6.0),
			label,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			18,
			6,
			Color(0, 0, 0, 0.8)
		)
		overlay.draw_string(
			font, spot + Vector2(half + 6.0, 6.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, color
		)
