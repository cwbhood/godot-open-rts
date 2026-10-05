extends Node3D

# Draws on the ground where the trucks working for a building are going (BuildingInfo.gd
# picks the buildings: the one under the cursor and the selected one), and the remaining
# route of a selected truck. Each truck gets a ring and a small tag with its name and
# how long until it arrives; the line runs from the truck through its stops to the
# building, in the colour of what it is doing (see BuildingInfoText.KIND_COLORS).

const HaulerLinks = preload("res://source/match/economy/HaulerLinks.gd")
const Text = preload("res://source/match/hud/BuildingInfoText.gd")
const HudStyle = preload("res://source/match/hud/HudStyle.gd")

const REFRESH_INTERVAL_S = 0.1
const LINE_WIDTH_M = 0.4
const LIFT_M = 0.3
const RING_RADIUS_M = 1.3
const RING_SEGMENTS = 20
const DASH_M = 1.2
const GAP_M = 0.7

var _buildings = []
var _trucks = []
var _mesh = ImmediateMesh.new()
var _tags = []  # Label3D pool
var _vertices = []
var _colors = []
var _since_s = 0.0
var _offset_m = 0.0  # moves the dashes towards where the trucks drive


func _ready():
	var instance = MeshInstance3D.new()
	instance.mesh = _mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.render_priority = 10
	instance.material_override = material
	add_child(instance)


func show_routes(buildings, trucks):
	_buildings = buildings
	_trucks = trucks
	_redraw()


func get_drawn_count():
	"""trucks drawn right now (tests)"""
	var count = 0
	for tag in _tags:
		if tag.visible:
			count += 1
	return count


func _process(delta):
	if _buildings.is_empty() and _trucks.is_empty():
		return
	_offset_m = fmod(_offset_m + delta * 2.0, DASH_M + GAP_M)
	_since_s += delta
	if _since_s >= REFRESH_INTERVAL_S:
		_since_s = 0.0
		_redraw()


func _redraw():
	_mesh.clear_surfaces()
	_vertices.clear()
	_colors.clear()
	var drawn = []  # [truck, colour, tag text]
	for building in _buildings:
		if not is_instance_valid(building):
			continue
		for link in HaulerLinks.links_for(building):
			if link["kind"] == "TRAIN" or link["unit"] in drawn.map(func(d): return d[0]):
				continue
			var color = Text.KIND_COLORS.get(link["kind"], HudStyle.FG)
			if link["path"].size() >= 2:
				_path(link["path"], color)
			elif link["kind"] == "LEAVING" and link["other"] != null:
				_path([link["unit"].global_position, link["other"].global_position], color)
			else:  # waiting or parked next to it
				_path([link["unit"].global_position, building.global_position], color)
			var tag = HaulerLinks.display_name(link["unit"])
			if link["eta_s"] >= 0.0 and link["kind"] in HaulerLinks.INBOUND:
				tag += "  " + tr("LINK_ETA").format([int(ceil(link["eta_s"]))])
			drawn.append([link["unit"], color, tag])
	for truck in _trucks:
		if not is_instance_valid(truck) or truck in drawn.map(func(d): return d[0]):
			continue
		var job = HaulerLinks.job_of(truck)
		if job["path"].size() >= 2:
			_path(job["path"], HudStyle.ACCENT)
		drawn.append([truck, HudStyle.ACCENT, HaulerLinks.display_name(truck)])
	for entry in drawn:
		_ring(entry[0].global_position, entry[1])
	if not _vertices.is_empty():
		_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in range(_vertices.size()):
			_mesh.surface_set_color(_colors[i])
			_mesh.surface_add_vertex(_vertices[i])
		_mesh.surface_end()
	_update_tags(drawn)


func _add(corners, color):
	for index in [0, 1, 2, 0, 2, 3]:
		_vertices.append(corners[index])
		_colors.append(color)


func _path(points, color):
	"""a dashed ribbon along the points, dashes marching towards the end"""
	var faded = Color(color, 0.95)
	var phase = _offset_m
	for i in range(points.size() - 1):
		var a = points[i]
		var b = points[i + 1]
		var length = Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
		if length < 0.01:
			continue
		var t = -phase
		while t < length:
			var start = max(t, 0.0)
			var end = min(t + DASH_M, length)
			if end > start:
				_quad(a.lerp(b, start / length), a.lerp(b, end / length), faded)
			t += DASH_M + GAP_M
		phase = fmod(phase + length, DASH_M + GAP_M)


func _quad(a, b, color):
	var along = Vector3(b.x - a.x, 0, b.z - a.z).normalized()
	var side = along.cross(Vector3.UP) * LINE_WIDTH_M * 0.5
	var lift = Vector3(0, LIFT_M, 0)
	_add([a + side + lift, a - side + lift, b - side + lift, b + side + lift], color)


func _ring(center, color):
	var lift = Vector3(0, LIFT_M, 0)
	var inner = RING_RADIUS_M - LINE_WIDTH_M
	for i in range(RING_SEGMENTS):
		var a0 = TAU * i / RING_SEGMENTS
		var a1 = TAU * (i + 1) / RING_SEGMENTS
		var o0 = Vector3(cos(a0), 0, sin(a0))
		var o1 = Vector3(cos(a1), 0, sin(a1))
		_add(
			[
				center + o0 * RING_RADIUS_M + lift,
				center + o0 * inner + lift,
				center + o1 * inner + lift,
				center + o1 * RING_RADIUS_M + lift,
			],
			color
		)


func _update_tags(drawn):
	while _tags.size() < drawn.size():
		var tag = Label3D.new()
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.no_depth_test = true
		tag.fixed_size = true
		tag.pixel_size = 0.001
		tag.font_size = 30
		tag.outline_size = 10
		tag.outline_modulate = Color(HudStyle.BG, 0.9)
		tag.render_priority = 11
		tag.outline_render_priority = 10
		add_child(tag)
		_tags.append(tag)
	for i in range(_tags.size()):
		var tag = _tags[i]
		tag.visible = i < drawn.size()
		if not tag.visible:
			continue
		tag.text = drawn[i][2]
		tag.modulate = drawn[i][1].lightened(0.25)
		tag.global_position = drawn[i][0].global_position + Vector3(0, 2.2, 0)
