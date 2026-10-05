extends Node3D

# The white flag a city centre raises while it surrenders (see CityCentres.gd): a pole with
# a waving white cloth over the building and the seconds left before the city changes hands.

const POLE_HEIGHT_M = 2.6
const CLOTH_SIZE = Vector2(1.8, 1.1)
const BORDER_M = 0.07

var seconds_left = 0.0

var _cloth = MeshInstance3D.new()
var _label = Label3D.new()
var _time_s = 0.0


func _ready():
	var top = _top_of_parent()
	position = Vector3(0, top, 0)
	var pole = MeshInstance3D.new()
	var pole_mesh = CylinderMesh.new()
	pole_mesh.top_radius = 0.045
	pole_mesh.bottom_radius = 0.055
	pole_mesh.height = POLE_HEIGHT_M
	pole.mesh = pole_mesh
	var pole_material = StandardMaterial3D.new()
	pole_material.albedo_color = Color("3b332b")
	pole.material_override = pole_material
	pole.position = Vector3(0, POLE_HEIGHT_M * 0.5, 0)
	add_child(pole)
	var cloth_mesh = QuadMesh.new()
	cloth_mesh.size = CLOTH_SIZE
	cloth_mesh.subdivide_width = 6
	_cloth.mesh = cloth_mesh
	var cloth_material = StandardMaterial3D.new()
	cloth_material.albedo_color = Color(0.97, 0.97, 0.94)
	cloth_material.emission_enabled = true
	cloth_material.emission = Color(1, 1, 1)
	cloth_material.emission_energy_multiplier = 0.9
	cloth_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_cloth.material_override = cloth_material
	# a dark hem around the cloth keeps it readable against the sand
	var hem_material = StandardMaterial3D.new()
	hem_material.albedo_color = Color("2a2520")
	for edge in [
		[Vector3(0, CLOTH_SIZE.y * 0.5, 0), Vector3(CLOTH_SIZE.x + BORDER_M * 2.0, BORDER_M, 0.03)],
		[
			Vector3(0, -CLOTH_SIZE.y * 0.5, 0),
			Vector3(CLOTH_SIZE.x + BORDER_M * 2.0, BORDER_M, 0.03)
		],
		[Vector3(CLOTH_SIZE.x * 0.5, 0, 0), Vector3(BORDER_M, CLOTH_SIZE.y, 0.03)],
		[Vector3(-CLOTH_SIZE.x * 0.5, 0, 0), Vector3(BORDER_M, CLOTH_SIZE.y, 0.03)],
	]:
		var strip = MeshInstance3D.new()
		var strip_mesh = BoxMesh.new()
		strip_mesh.size = edge[1]
		strip.mesh = strip_mesh
		strip.material_override = hem_material
		strip.position = edge[0]
		_cloth.add_child(strip)
	_cloth.position = Vector3(CLOTH_SIZE.x * 0.5, POLE_HEIGHT_M - CLOTH_SIZE.y * 0.5, 0)
	add_child(_cloth)
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.0013
	_label.font_size = 30
	_label.modulate = Color("ffd27a")
	_label.outline_size = 8
	_label.outline_modulate = Color(0, 0, 0, 0.9)
	_label.render_priority = 11
	_label.position = Vector3(0, POLE_HEIGHT_M + 0.6, 0)
	add_child(_label)
	_refresh_label()


func _process(delta):
	_time_s += delta
	# the cloth swings around the pole and ripples a little
	_cloth.rotation.y = sin(_time_s * 2.3) * 0.35
	_cloth.position.x = cos(_cloth.rotation.y) * CLOTH_SIZE.x * 0.5
	_cloth.position.z = -sin(_cloth.rotation.y) * CLOTH_SIZE.x * 0.5
	_cloth.scale.y = 1.0 + sin(_time_s * 7.0) * 0.05
	_refresh_label()


func _refresh_label():
	_label.text = tr("CITY_SURRENDER_FLAG").format([int(ceil(max(0.0, seconds_left)))])


func _top_of_parent():
	var health_bar = get_parent().get_node_or_null("HealthBar")
	return (health_bar.position.y + 0.3) if health_bar != null else 2.3
