extends Node3D

# In-game editor for desert maps. It edits the explicit layout that DesertMapGenerator.gd
# reads from a map definition (start points, lakes, forests, rock outcrops, resource
# deposits, and water: a sea with islands and shallow fords, see WaterLayout.gd), rebuilds
# the map after every change and saves it as a mod under user://mods/custom_maps/, where
# GameData picks it up so it shows in the Play menu.
# Anything not placed by hand (dunes, sand patterns, small props) comes from the seed.

enum Tool { LAKE, FOREST, OUTCROP, DEPOSIT, SPAWN, ERASE, ISLAND, SHALLOWS }

const Generator = preload("res://source/match/maps/DesertMapGenerator.gd")
const MapScene = preload("res://source/match/Map.tscn")
const IsometricCamera = preload("res://source/match/IsometricCamera3D.gd")
const GameData = preload("res://source/data-model/GameData.gd")
const FairStart = preload("res://source/match/maps/FairStart.gd")

const MOD_DIR = "user://mods/custom_maps"
const GENERATOR_SCRIPT = "res://source/match/maps/DesertMapGenerator.gd"
const MAX_SPAWNS = 8
const FOREST_KINDS = ["acacia", "pine", "mixed"]
const BRUSH_LIMITS = {
	"lake": Vector2(3.0, 14.0),
	"forest": Vector2(1.5, 5.0),
	"outcrop": Vector2(1.0, 5.0),
	"island": Vector2(4.0, 30.0),
	"shallows": Vector2(2.0, 10.0),
}
const ERASE_REACH = 4.0
const START_ZONE_RADIUS = 7.0

var _layout = _empty_layout()
var _size = Vector2(100, 100)
var _seed = 1
var _map = null
var _camera = null
var _markers = null
var _brush_preview = null
var _rebuild_queued = false
var _tool = Tool.LAKE
var _ui = {}


func _ready():
	_setup_environment()
	_setup_camera()
	_markers = Node3D.new()
	_markers.name = "Markers"
	add_child(_markers)
	_setup_brush_preview()
	_build_ui()
	_map = MapScene.instantiate()
	_map.set_script(Generator)
	_map.spawn_deposits = false
	_map.start_zone_radius = START_ZONE_RADIUS
	_map._generated = true  # the first layout is generated below
	add_child(_map)
	_new_random_layout()


func _process(_delta):
	_update_brush_preview()
	if _rebuild_queued:
		_rebuild_queued = false
		_rebuild()


func _unhandled_input(event):
	if not event is InputEventMouseButton or not event.pressed:
		return
	if event.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return
	var hit = _camera.get_ray_intersection(event.position)
	if hit == null:
		return
	var pos = Vector2(hit.x, hit.z)
	if pos.x < 0.0 or pos.y < 0.0 or pos.x > _size.x or pos.y > _size.y:
		_set_status(tr("MAP_EDITOR_OUTSIDE"))
		return
	if event.button_index == MOUSE_BUTTON_RIGHT or _tool == Tool.ERASE:
		_erase_at(pos)
	else:
		_place_at(pos)
	get_viewport().set_input_as_handled()


# editing


func _empty_layout():
	return {
		"spawns": [],
		"lakes": [],
		"forests": [],
		"outcrops": [],
		"deposits": [],
		"sea": false,
		"islands": [],
		"water": [],
	}


func _with_water_keys(layout):
	"""older layouts have no water keys"""
	for key in ["islands", "water"]:
		if not key in layout:
			layout[key] = []
	if not "sea" in layout:
		layout["sea"] = false
	return layout


func _mirror(pos: Vector2) -> Vector2:
	return _size - pos


func _mirroring() -> bool:
	return _ui.mirror.button_pressed


func _copies(pos: Vector2) -> Array:
	"""pos plus its mirrored copies: the opposite point, or with 4-way mirroring on a square
	map, the same point turned a quarter, half and three quarters around the center"""
	var copies = [pos]
	if _ui.mirror_4.button_pressed and is_equal_approx(_size.x, _size.y):
		var center = _size / 2.0
		var offset = pos - center
		copies.append_array(
			[
				center - offset,
				center + Vector2(-offset.y, offset.x),
				center + Vector2(offset.y, -offset.x)
			]
		)
	elif _mirroring():
		copies.append(_mirror(pos))
	var unique = []
	for copy in copies:
		if unique.all(func(other): return other.distance_to(copy) > 2.0):
			unique.append(copy)
	return unique


func _to_list(pos: Vector2):
	return [snappedf(pos.x, 0.01), snappedf(pos.y, 0.01)]


func _to_vector(list) -> Vector2:
	return Vector2(float(list[0]), float(list[1]))


func _place_at(pos: Vector2):
	var positions = _copies(pos)
	var radius = _ui.brush.value
	match _tool:
		Tool.LAKE:
			for p in positions:
				_layout.lakes.append({"center": _to_list(p), "radius": radius})
		Tool.FOREST:
			var kind = FOREST_KINDS[_ui.forest_kind.selected]
			for p in positions:
				_add_forest_circle(p, radius, kind)
		Tool.OUTCROP:
			for p in positions:
				_layout.outcrops.append({"center": _to_list(p), "radius": radius})
		Tool.DEPOSIT:
			var kind = _resource_ids()[_ui.deposit_kind.selected]
			for p in positions:
				_layout.deposits.append({"kind": kind, "center": _to_list(p)})
		Tool.ISLAND:
			for p in positions:
				_layout.islands.append({"center": _to_list(p), "radius": radius})
		Tool.SHALLOWS:
			for p in positions:
				_layout.water.append({"center": _to_list(p), "radius": radius, "depth": "shallow"})
		Tool.SPAWN:
			if _layout.spawns.size() + positions.size() > MAX_SPAWNS:
				_set_status(tr("MAP_EDITOR_TOO_MANY_SPAWNS").format([MAX_SPAWNS]))
				return
			for p in positions:
				_layout.spawns.append(_to_list(p))
	_queue_rebuild()


func _add_forest_circle(pos: Vector2, radius: float, kind: String):
	"""grows a touching forest of the same kind, otherwise starts a new forest"""
	var circle = {"center": _to_list(pos), "radius": radius}
	for forest in _layout.forests:
		if forest.get("kind", "mixed") != kind:
			continue
		for other in forest.circles:
			if _to_vector(other.center).distance_to(pos) < float(other.radius) + radius + 1.0:
				forest.circles.append(circle)
				return
	_layout.forests.append({"kind": kind, "circles": [circle]})


func _erase_at(pos: Vector2):
	var erased = _erase_nearest(pos)
	if erased:
		for copy in _copies(pos).slice(1):
			_erase_nearest(copy)
	if erased:
		_queue_rebuild()
	else:
		_set_status(tr("MAP_EDITOR_NOTHING_TO_ERASE"))


func _erase_nearest(pos: Vector2) -> bool:
	"""removes the closest feature whose area (or marker) is under 'pos'"""
	var candidates = []  # [distance, container array, item]
	for spawn in _layout.spawns:
		candidates.append([_to_vector(spawn).distance_to(pos) - ERASE_REACH, _layout.spawns, spawn])
	for deposit in _layout.deposits:
		var center = _to_vector(deposit.center)
		candidates.append([center.distance_to(pos) - ERASE_REACH, _layout.deposits, deposit])
	var circle_lists = [_layout.lakes, _layout.outcrops, _layout.islands, _layout.water]
	for forest in _layout.forests:
		circle_lists.append(forest.circles)
	for circles in circle_lists:
		for circle in circles:
			if not "center" in circle:
				continue  # polygons and fords from JSON are edited there
			var distance = _to_vector(circle.center).distance_to(pos)
			candidates.append([distance - float(circle.radius) - 1.0, circles, circle])
	candidates = candidates.filter(func(candidate): return candidate[0] <= 0.0)
	if candidates.is_empty():
		return false
	candidates.sort_custom(func(a, b): return a[0] < b[0])
	candidates[0][1].erase(candidates[0][2])
	_layout.forests = _layout.forests.filter(func(forest): return not forest.circles.is_empty())
	return true


func _new_random_layout():
	_seed = int(_ui.seed.value)
	_size = Vector2(_ui.width.value, _ui.height.value)
	_map.layout = null
	_map.map_seed = _seed
	_map.size = _size
	_map.generate()
	_layout = _with_water_keys(_map.export_layout())
	_layout.sea = _ui.sea.button_pressed
	for deposit in _layout.deposits:
		deposit.erase("amount")  # keep the commodity's default amount unless set by hand
	_map.layout = _layout.duplicate(true)
	_after_rebuild()


func _clear_layout():
	_layout = _empty_layout()
	var corner = _size * 0.16
	_layout.spawns = [_to_list(corner), _to_list(_mirror(corner))]
	_queue_rebuild()


func _on_size_changed(_value):
	var old_size = _size
	_size = Vector2(_ui.width.value, _ui.height.value)
	if old_size == _size:
		return
	var scale = _size / old_size
	var rescale = func(list): return _to_list(_to_vector(list) * scale)
	_layout.spawns = _layout.spawns.map(rescale)
	for key in ["lakes", "outcrops", "deposits", "islands", "water"]:
		for item in _layout[key]:
			for point_key in ["center", "from", "to"]:
				if point_key in item:
					item[point_key] = rescale.call(item[point_key])
			if "points" in item:
				item.points = item.points.map(rescale)
	for forest in _layout.forests:
		for circle in forest.circles:
			circle.center = rescale.call(circle.center)
	_queue_rebuild()


# rebuilding


func _queue_rebuild():
	_set_status(tr("MAP_EDITOR_REBUILDING"))
	# wait one frame so the status shows before the (slow) rebuild starts
	await get_tree().process_frame
	_rebuild_queued = true


func _rebuild():
	_map.map_seed = _seed
	_map.size = _size
	_map.layout = _layout.duplicate(true)
	_map.generate()
	_after_rebuild()


func _after_rebuild():
	_rebuild_markers()
	var planes: Array[Plane] = [
		Plane(1, 0, 0, -10),
		Plane(-1, 0, 0, -_size.x - 10),
		Plane(0, 0, 1, -10),
		Plane(0, 0, -1, -_size.y - 10),
	]
	_camera.bounding_planes = planes
	_update_info()
	_set_status("")


func _rebuild_markers():
	for child in _markers.get_children():
		child.queue_free()
	var colors = GameData.resource_field("color")
	for i in range(_layout.spawns.size()):
		var pos = _to_vector(_layout.spawns[i])
		_add_marker(pos, Color(0.95, 0.95, 0.95), 3.0, tr("MAP_EDITOR_START_N").format([i + 1]))
		_add_zone_ring(pos)
	for deposit in _layout.deposits:
		var color = Color(colors.get(deposit.kind, "#ffffff"))
		_add_marker(_to_vector(deposit.center), color, 1.2, tr(deposit.kind.to_upper()))


func _add_zone_ring(pos: Vector2):
	"""the start zone: players may place their city anywhere inside this ring"""
	var ring = MeshInstance3D.new()
	var mesh = TorusMesh.new()
	mesh.inner_radius = START_ZONE_RADIUS - 0.25
	mesh.outer_radius = START_ZONE_RADIUS
	mesh.rings = 64
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.85)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = material
	ring.mesh = mesh
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.position = Vector3(pos.x, 0.15, pos.y)
	_markers.add_child(ring)


func _add_marker(pos: Vector2, color: Color, height: float, text: String):
	var pole = MeshInstance3D.new()
	var mesh = CylinderMesh.new()
	mesh.top_radius = 0.18
	mesh.bottom_radius = 0.6
	mesh.height = height
	var material = StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color * 0.35
	mesh.material = material
	pole.mesh = mesh
	pole.position = Vector3(pos.x, height / 2.0, pos.y)
	_markers.add_child(pole)
	var label = Label3D.new()
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true
	label.pixel_size = 0.0015
	label.font_size = 22
	label.outline_size = 8
	label.no_depth_test = true
	label.position = Vector3(pos.x, height + 0.8, pos.y)
	_markers.add_child(label)


# saving


func _map_id() -> String:
	var id = ""
	for character in _ui.name.text.strip_edges().to_lower():
		if character in "abcdefghijklmnopqrstuvwxyz0123456789":
			id += character
		elif not id.ends_with("_") and id != "":
			id += "_"
	return id.trim_suffix("_")


func _save():
	var id = _map_id()
	if id == "":
		_set_status(tr("MAP_EDITOR_NEEDS_NAME"))
		return
	if _layout.spawns.size() < 2:
		_set_status(tr("MAP_EDITOR_NEEDS_SPAWNS"))
		return
	if _something_in_water():
		_set_status(tr("MAP_EDITOR_IN_WATER"))
		return
	DirAccess.make_dir_recursive_absolute(MOD_DIR + "/data/maps")
	DirAccess.make_dir_recursive_absolute(MOD_DIR + "/maps")
	var json_path = "{0}/data/maps/{1}.json".format([MOD_DIR, id])
	var scene_path = "{0}/maps/{1}.tscn".format([MOD_DIR, id])
	var definition = {
		"id": id,
		"name": _ui.name.text.strip_edges(),
		"scene": scene_path,
		"players": _layout.spawns.size(),
		"size": [int(_size.x), int(_size.y)],
		"start_zone_radius": START_ZONE_RADIUS,
		"generator": {"seed": _seed},
		"layout": _layout,
	}
	var json_file = FileAccess.open(json_path, FileAccess.WRITE)
	json_file.store_string(JSON.stringify(definition, "  "))
	json_file.close()
	var scene_file = FileAccess.open(scene_path, FileAccess.WRITE)
	scene_file.store_string(_scene_text(json_path))
	scene_file.close()
	GameData.reload()
	Constants.Match.MAPS = GameData.maps()
	_set_status(tr("MAP_EDITOR_SAVED").format([ProjectSettings.globalize_path(json_path)]))


func _scene_text(json_path):
	"""a desert map scene that reads the saved definition"""
	return (
		"\n"
		. join(
			[
				"[gd_scene load_steps=3 format=3]",
				"",
				'[ext_resource type="PackedScene" path="res://source/match/Map.tscn" id="1_map"]',
				'[ext_resource type="Script" path="{0}" id="2_gen"]'.format([GENERATOR_SCRIPT]),
				"",
				'[node name="Map" instance=ExtResource("1_map")]',
				'script = ExtResource("2_gen")',
				"size = Vector2({0}, {1})".format([int(_size.x), int(_size.y)]),
				'map_definition = "{0}"'.format([json_path]),
				"",
			]
		)
	)


func _load_definition(path):
	var definition = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not definition is Dictionary:
		_set_status(tr("MAP_EDITOR_CANNOT_LOAD"))
		return
	_ui.name.text = definition.get("name", "")
	var size_list = definition.get("size", [100, 100])
	_ui.width.set_value_no_signal(size_list[0])
	_ui.height.set_value_no_signal(size_list[1])
	_ui.seed.set_value_no_signal(definition.get("generator", {}).get("seed", 1))
	if "layout" in definition:
		_size = Vector2(size_list[0], size_list[1])
		_seed = int(_ui.seed.value)
		_layout = _with_water_keys(definition.layout)
		_ui.sea.set_pressed_no_signal(bool(_layout.sea))
		_queue_rebuild()
	else:
		_new_random_layout()


func _editable_maps():
	"""[[label, json path]] for every saved custom map and the built-in desert maps"""
	var entries = []
	for root in [MOD_DIR + "/data/maps", "res://data/maps"]:
		var dir = DirAccess.open(root)
		if dir == null:
			continue
		for file_name in dir.get_files():
			if not file_name.ends_with(".json"):
				continue
			var path = root + "/" + file_name
			var definition = JSON.parse_string(FileAccess.get_file_as_string(path))
			if definition is Dictionary and ("generator" in definition or "layout" in definition):
				entries.append([definition.get("name", file_name), path])
	return entries


# scene setup


func _setup_environment():
	var sky_material = ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.38, 0.55, 0.78)
	sky_material.sky_horizon_color = Color(0.86, 0.8, 0.7)
	sky_material.ground_horizon_color = Color(0.86, 0.8, 0.7)
	sky_material.ground_bottom_color = Color(0.55, 0.45, 0.35)
	var sky = Sky.new()
	sky.sky_material = sky_material
	var environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.ssao_enabled = true
	var world_environment = WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)
	var sun = DirectionalLight3D.new()
	sun.rotation = Vector3(-0.9, 0.62, 0.0)
	sun.light_color = Color(1.0, 0.94, 0.84)
	sun.light_energy = 1.35
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 250.0
	add_child(sun)


func _setup_camera():
	_camera = Camera3D.new()
	_camera.set_script(IsometricCamera)
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.rotation_degrees = Vector3(-30.0, 0.0, 0.0)
	_camera.size = 60.0
	_camera.size_min = 10
	_camera.size_max = 140
	_camera.visible_height_max = 20
	_camera.position = Vector3(50.0, 40.0, 110.0)
	_camera.current = true
	add_child(_camera)


func _setup_brush_preview():
	_brush_preview = MeshInstance3D.new()
	var ring = TorusMesh.new()
	ring.inner_radius = 0.94
	ring.outer_radius = 1.0
	ring.rings = 48
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 1.0, 1.0, 0.8)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	ring.material = material
	_brush_preview.mesh = ring
	_brush_preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_brush_preview)


func _update_brush_preview():
	var hit = _camera.get_ray_intersection(get_viewport().get_mouse_position())
	_brush_preview.visible = (
		hit != null and _tool in [Tool.LAKE, Tool.FOREST, Tool.OUTCROP, Tool.ISLAND, Tool.SHALLOWS]
	)
	if _brush_preview.visible:
		var radius = _ui.brush.value
		_brush_preview.position = hit + Vector3(0.0, 0.15, 0.0)
		_brush_preview.scale = Vector3(radius, 1.0, radius)


# user interface


func _build_ui():
	var layer = CanvasLayer.new()
	add_child(layer)
	var panel = PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -340.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	layer.add_child(panel)
	var margin = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	panel.add_child(margin)
	var scroll = ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var box = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)

	_add_heading(box, tr("MAP_EDITOR"))
	_ui.name = LineEdit.new()
	_ui.name.text = tr("MAP_EDITOR_DEFAULT_NAME")
	_add_row(box, tr("MAP_EDITOR_NAME"), _ui.name)

	var size_row = HBoxContainer.new()
	_ui.width = _spin_box(60, 200, 10, _size.x)
	_ui.height = _spin_box(60, 200, 10, _size.y)
	_ui.width.value_changed.connect(_on_size_changed)
	_ui.height.value_changed.connect(_on_size_changed)
	size_row.add_child(_ui.width)
	size_row.add_child(_ui.height)
	_add_row(box, tr("MAP_EDITOR_SIZE"), size_row)

	_ui.seed = _spin_box(1, 99999, 1, _seed)
	_add_row(box, tr("MAP_EDITOR_SEED"), _ui.seed)
	var start_row = HBoxContainer.new()
	start_row.add_child(_button(tr("MAP_EDITOR_RANDOM"), _new_random_layout))
	start_row.add_child(_button(tr("MAP_EDITOR_CLEAR"), _clear_layout))
	box.add_child(start_row)

	_ui.open = OptionButton.new()
	_ui.open.fit_to_longest_item = false
	_ui.open.item_selected.connect(_on_open_selected)
	_ui.open.pressed.connect(_refresh_open_list)
	_refresh_open_list()
	_add_row(box, tr("MAP_EDITOR_OPEN"), _ui.open)

	_ui.mirror = CheckBox.new()
	_ui.mirror.text = tr("MAP_EDITOR_MIRROR")
	_ui.mirror.button_pressed = true
	box.add_child(_ui.mirror)
	_ui.mirror_4 = CheckBox.new()
	_ui.mirror_4.text = tr("MAP_EDITOR_MIRROR_4")
	_ui.mirror_4.tooltip_text = tr("MAP_EDITOR_MIRROR_4_TOOLTIP")
	box.add_child(_ui.mirror_4)
	_ui.sea = CheckBox.new()
	_ui.sea.text = tr("MAP_EDITOR_SEA")
	_ui.sea.toggled.connect(_on_sea_toggled)
	box.add_child(_ui.sea)

	_add_heading(box, tr("MAP_EDITOR_TOOLS"))
	var group = ButtonGroup.new()
	var tools = GridContainer.new()
	tools.columns = 2
	var tool_names = {
		Tool.LAKE: "MAP_EDITOR_TOOL_LAKE",
		Tool.FOREST: "MAP_EDITOR_TOOL_FOREST",
		Tool.OUTCROP: "MAP_EDITOR_TOOL_OUTCROP",
		Tool.DEPOSIT: "MAP_EDITOR_TOOL_DEPOSIT",
		Tool.SPAWN: "MAP_EDITOR_TOOL_SPAWN",
		Tool.ISLAND: "MAP_EDITOR_TOOL_ISLAND",
		Tool.SHALLOWS: "MAP_EDITOR_TOOL_SHALLOWS",
		Tool.ERASE: "MAP_EDITOR_TOOL_ERASE",
	}
	for tool_id in tool_names:
		var button = Button.new()
		button.text = tr(tool_names[tool_id])
		button.toggle_mode = true
		button.button_group = group
		button.button_pressed = tool_id == _tool
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_select_tool.bind(tool_id))
		tools.add_child(button)
	box.add_child(tools)

	_ui.forest_kind = OptionButton.new()
	for kind in FOREST_KINDS:
		_ui.forest_kind.add_item(tr("MAP_EDITOR_FOREST_" + kind.to_upper()))
	_add_row(box, tr("MAP_EDITOR_FOREST_KIND"), _ui.forest_kind)
	_ui.deposit_kind = OptionButton.new()
	for kind in _resource_ids():
		_ui.deposit_kind.add_item(tr(kind.to_upper()))
	_add_row(box, tr("MAP_EDITOR_DEPOSIT_KIND"), _ui.deposit_kind)
	_ui.brush = HSlider.new()
	_ui.brush.step = 0.5
	_ui.brush.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_add_row(box, tr("MAP_EDITOR_BRUSH"), _ui.brush)

	_ui.info = Label.new()
	_ui.info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_ui.info)
	var help = Label.new()
	help.text = tr("MAP_EDITOR_HELP")
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.modulate = Color(1, 1, 1, 0.7)
	box.add_child(help)

	box.add_child(_button(tr("MAP_EDITOR_SAVE"), _save))
	_ui.status = Label.new()
	_ui.status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_ui.status)
	box.add_child(
		_button(
			tr("BACK"), func(): get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
		)
	)
	_select_tool(_tool)


func _add_heading(box, text):
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 20)
	box.add_child(label)


func _add_row(box, text, control):
	var row = HBoxContainer.new()
	var label = Label.new()
	label.text = text
	label.custom_minimum_size.x = 100
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	box.add_child(row)


func _spin_box(min_value, max_value, step, value):
	var spin_box = SpinBox.new()
	spin_box.min_value = min_value
	spin_box.max_value = max_value
	spin_box.step = step
	spin_box.value = value
	spin_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spin_box


func _button(text, callback):
	var button = Button.new()
	button.text = text
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	return button


func _select_tool(tool_id):
	_tool = tool_id
	var tool_key = {
		Tool.LAKE: "lake",
		Tool.FOREST: "forest",
		Tool.OUTCROP: "outcrop",
		Tool.ISLAND: "island",
		Tool.SHALLOWS: "shallows",
	}
	var limits = BRUSH_LIMITS.get(tool_key.get(tool_id), Vector2.ZERO)
	_ui.brush.editable = limits != Vector2.ZERO
	if limits != Vector2.ZERO:
		_ui.brush.min_value = limits.x
		_ui.brush.max_value = limits.y
		_ui.brush.value = (limits.x + limits.y) / 2.0
	_ui.forest_kind.disabled = tool_id != Tool.FOREST
	_ui.deposit_kind.disabled = tool_id != Tool.DEPOSIT


func _refresh_open_list():
	_ui.open.clear()
	_ui.open.add_item(tr("MAP_EDITOR_OPEN_PICK"))
	_ui.open.set_item_metadata(0, "")
	for entry in _editable_maps():
		_ui.open.add_item(entry[0])
		_ui.open.set_item_metadata(_ui.open.item_count - 1, entry[1])


func _on_open_selected(index):
	var path = _ui.open.get_item_metadata(index)
	if path != "":
		_load_definition(path)


func _update_info():
	var deposit_counts = {}
	for deposit in _layout.deposits:
		deposit_counts[deposit.kind] = deposit_counts.get(deposit.kind, 0) + 1
	var deposit_text = ", ".join(
		deposit_counts.keys().map(
			func(kind): return "{0} {1}".format([deposit_counts[kind], tr(kind.to_upper())])
		)
	)
	var water_text = ""
	if _layout.sea or not _layout.water.is_empty():
		water_text = (
			"\n"
			+ (
				tr("MAP_EDITOR_WATER_INFO")
				. format(
					[
						tr("MAP_EDITOR_SEA") if _layout.sea else "-",
						_layout.islands.size(),
						_layout.water.size(),
					]
				)
			)
		)
	_ui.info.text = (
		(
			tr("MAP_EDITOR_INFO")
			. format(
				[
					_layout.spawns.size(),
					_layout.lakes.size(),
					_layout.forests.size(),
					_layout.outcrops.size(),
					deposit_text if deposit_text != "" else "-",
				]
			)
		)
		+ water_text
	)
	var problems = FairStart.problems(_map)
	if problems.is_empty():
		_ui.info.text += "\n" + tr("MAP_EDITOR_FAIR")
	else:
		_ui.info.text += "\n" + tr("MAP_EDITOR_UNFAIR").format([problems[0]])


func _set_status(text):
	_ui.status.text = text


func _resource_ids():
	return Array(GameData.resource_ids()).map(func(id): return String(id))


func _on_sea_toggled(pressed):
	_layout.sea = pressed
	if pressed and _layout.islands.is_empty():
		# a sea with no land would drown every start point: give each one an island
		for spawn in _layout.spawns:
			_layout.islands.append({"center": spawn, "radius": min(_size.x, _size.y) * 0.16})
	_queue_rebuild()


func _something_in_water() -> bool:
	"""start points and deposits must stay on dry land"""
	if _map.water == null:
		return false
	var points = _layout.spawns.map(_to_vector)
	points.append_array(_layout.deposits.map(func(deposit): return _to_vector(deposit.center)))
	return points.any(func(point): return _map.water.is_wet_near(point, 1.5))
