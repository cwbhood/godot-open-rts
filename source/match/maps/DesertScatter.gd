extends RefCounted

# Scatters trees, palms, reeds, rocks, bushes and grass over a generated desert map using one
# MultiMeshInstance3D per model. Props are purely visual: movement is blocked by the map's
# obstacle colliders, so blocking props are only placed inside obstacle circles.

const MODELS_DIR = "res://assets/models/ironbound/env/"
const FOREST_TREES = {
	&"acacia": ["tree_acacia_a", "tree_acacia_b"],
	&"pine": ["pine_a", "pine_b"],
	&"mixed": ["tree_acacia_a", "pine_a", "pine_b", "bush_a"],
}

var _map = null
var _rng = RandomNumberGenerator.new()
var _transforms = {}  # model name -> [Transform3D]
var _mesh_cache = {}


func populate(map):
	_map = map
	_rng.seed = map.map_seed * 7919 + 13
	_scatter_forests()
	_scatter_lake_shores()
	_scatter_outcrops()
	_scatter_open_ground()
	_scatter_outer_area()
	_scatter_pebbles()
	_build_multimeshes()


func _add(model_name, pos: Vector2, scale_range = Vector2(0.85, 1.2), sink = 0.0):
	if _is_drowned(model_name, pos):
		return
	var height = _map.get_height(pos) - sink
	var basis = Basis(Vector3.UP, _rng.randf() * TAU).scaled(
		Vector3.ONE * _rng.randf_range(scale_range.x, scale_range.y)
	)
	if not model_name in _transforms:
		_transforms[model_name] = []
	_transforms[model_name].append(Transform3D(basis, Vector3(pos.x, height, pos.y)))


func _is_drowned(model_name, pos: Vector2) -> bool:
	"""props stay on land; reeds may stand in lakes and shallows but not out at sea"""
	var water = _map.water
	if water == null or not water.has_more_than_lakes():
		return false
	if model_name == "reeds":
		return water.depth_fast(pos) == water.Depth.DEEP and water.deep_distance(pos, false) < 0.0
	return water.depth_fast(pos) != water.Depth.LAND


func _pick(names):
	return names[_rng.randi() % names.size()]


func _scatter_forests():
	for forest in _map.forests:
		var placed = []
		var tree_names = FOREST_TREES[forest.kind]
		for circle in forest.circles:
			var attempts = int(PI * pow(circle.radius + 0.5, 2.0) / 1.2)
			for _i in range(attempts):
				var pos = (
					circle.center
					+ (
						Vector2.from_angle(_rng.randf() * TAU)
						* sqrt(_rng.randf())
						* (circle.radius + 0.4)
					)
				)
				if placed.any(func(other): return other.distance_to(pos) < 1.25):
					continue
				placed.append(pos)
				_add(_pick(tree_names), pos, Vector2(0.65, 1.0))
			for _i in range(int(circle.radius * 4.0)):
				var angle = _rng.randf() * TAU
				var pos = (
					circle.center
					+ Vector2.from_angle(angle) * (circle.radius + _rng.randf_range(0.5, 3.5))
				)
				if _map.is_obstructed(pos) or _map.is_reserved(pos):
					continue
				var roll = _rng.randf()
				if roll < 0.45:
					_add("grass_tuft", pos, Vector2(0.8, 1.4))
				elif roll < 0.8:
					_add(_pick(["bush_a", "bush_b"]), pos, Vector2(0.7, 1.2))
				elif roll < 0.9:
					_add(_pick(tree_names), pos, Vector2(0.45, 0.65))


func _scatter_lake_shores():
	for lake in _map.lakes:
		var circumference = TAU * lake.radius * 1.2
		for i in range(int(circumference * 1.6)):
			var angle = _rng.randf() * TAU
			var direction = Vector2.from_angle(angle)
			var radius = _map._lake_radius_at(lake, lake.center + direction * lake.radius)
			var shore = _rng.randf()
			if shore < 0.45:
				var pos = lake.center + direction * radius * _rng.randf_range(0.97, 1.08)
				_add("reeds", pos, Vector2(0.7, 1.2), 0.05)
			elif shore < 0.75:
				var pos = lake.center + direction * radius * _rng.randf_range(1.15, 1.32)
				_add(_pick(["palm_a", "palm_b"]), pos, Vector2(0.6, 0.85))
			elif shore < 0.9:
				var pos = lake.center + direction * radius * _rng.randf_range(1.1, 1.6)
				if not _map.is_reserved(pos):
					_add(_pick(["bush_a", "grass_tuft"]), pos, Vector2(0.8, 1.3))


func _scatter_outcrops():
	for outcrop in _map.outcrops:
		_add(
			_pick(["rock_spire_a", "rock_spire_b"]),
			outcrop.center,
			Vector2(outcrop.radius * 0.55, outcrop.radius * 0.75)
		)
		for _i in range(int(outcrop.radius * 3.0)):
			var pos = (
				outcrop.center
				+ (
					Vector2.from_angle(_rng.randf() * TAU)
					* outcrop.radius
					* _rng.randf_range(0.5, 1.0)
				)
			)
			_add(_pick(["boulder_a", "boulder_b", "boulder_c"]), pos, Vector2(0.6, 1.3), 0.1)
		for _i in range(4):
			var pos = (
				outcrop.center
				+ (
					Vector2.from_angle(_rng.randf() * TAU)
					* (outcrop.radius + _rng.randf_range(0.5, 2.5))
				)
			)
			if not _map.is_obstructed(pos) and not _map.is_reserved(pos):
				_add("rock_slabs", pos, Vector2(0.3, 0.6), 0.05)


func _scatter_open_ground():
	var cell = 3.0
	var x = 0.0
	while x < _map.size.x:
		var z = 0.0
		while z < _map.size.y:
			var pos = Vector2(x + _rng.randf() * cell, z + _rng.randf() * cell)
			z += cell
			if _map.is_obstructed(pos, 0.6) or _map.is_reserved(pos, 0.5):
				continue
			var vegetation = _map.forest_density(pos)
			var roll = _rng.randf()
			if roll < 0.22 + vegetation * 0.3:
				_add("grass_tuft", pos, Vector2(0.6, 1.2))
			elif roll < 0.27 + vegetation * 0.4:
				_add(_pick(["bush_a", "bush_b"]), pos, Vector2(0.5, 1.0))
			elif roll < 0.295:
				_add(_pick(["boulder_a", "boulder_b", "boulder_c"]), pos, Vector2(0.15, 0.35), 0.05)
			elif roll < 0.31:
				_add("cactus_a", pos, Vector2(0.5, 0.8))
			elif roll < 0.318:
				_add("dead_tree", pos, Vector2(0.6, 0.9))
			elif roll < 0.326:
				_add("rock_slabs", pos, Vector2(0.25, 0.45), 0.05)
		x += cell


func _scatter_pebbles():
	"""small stones in loose clusters: open ground reads as real ground, not a flat colour"""
	var cell = 1.8
	var x = 0.0
	while x < _map.size.x:
		var z = 0.0
		while z < _map.size.y:
			var pos = Vector2(x + _rng.randf() * cell, z + _rng.randf() * cell)
			z += cell
			if _rng.randf() > 0.2 or _map.is_obstructed(pos, 0.3) or _map.is_reserved(pos, 0.3):
				continue
			for i in range(_rng.randi_range(1, 4)):
				var offset = Vector2.from_angle(_rng.randf() * TAU) * _rng.randf() * 0.5
				_add(
					_pick(["boulder_a", "boulder_b", "boulder_c"]),
					pos + offset,
					Vector2(0.03, 0.09),
					0.01
				)
		x += cell


func _scatter_outer_area():
	var cell = 4.5
	var reach = _map.outer_margin * 0.9
	var x = -reach
	while x < _map.size.x + reach:
		var z = -reach
		while z < _map.size.y + reach:
			var pos = Vector2(x + _rng.randf() * cell, z + _rng.randf() * cell)
			z += cell
			var edge_distance = _map._distance_outside_playable_area(pos)
			if edge_distance < 1.5:
				continue
			var height = _map.get_height(pos)
			var mesa = height - _map._dune_height(pos) * smoothstep(3.0, 30.0, edge_distance)
			var roll = _rng.randf()
			if mesa > 1.5:
				if roll < 0.18:
					_add(
						_pick(["boulder_a", "boulder_b", "boulder_c"]), pos, Vector2(0.8, 2.2), 0.3
					)
				elif roll < 0.22:
					_add(_pick(["rock_spire_a", "rock_spire_b"]), pos, Vector2(0.8, 1.6), 0.3)
			elif roll < 0.12:
				_add("grass_tuft", pos, Vector2(0.8, 1.4), 0.1)
			elif roll < 0.15:
				_add("dead_tree", pos, Vector2(0.7, 1.0), 0.1)
			elif roll < 0.17:
				_add(_pick(["bush_a", "bush_b"]), pos, Vector2(0.6, 1.0), 0.1)
		x += cell


func _build_multimeshes():
	var root = Node3D.new()
	root.name = "Scatter"
	_map.add_child(root)
	for model_name in _transforms:
		var mesh = _load_mesh(model_name)
		var multimesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = mesh
		multimesh.instance_count = _transforms[model_name].size()
		for i in range(multimesh.instance_count):
			multimesh.set_instance_transform(i, _transforms[model_name][i])
		var instance = MultiMeshInstance3D.new()
		instance.name = model_name
		instance.multimesh = multimesh
		root.add_child(instance)


func _load_mesh(model_name):
	if model_name in _mesh_cache:
		return _mesh_cache[model_name]
	var path = MODELS_DIR + model_name + ".glb"
	var mesh = null
	if ResourceLoader.exists(path):
		var scene = load(path).instantiate()
		mesh = merge_meshes(scene)
		scene.free()
	if mesh == null:
		mesh = _placeholder_mesh(model_name)
	_mesh_cache[model_name] = mesh
	return mesh


static func merge_meshes(root: Node3D) -> ArrayMesh:
	"""bakes every MeshInstance3D under 'root' into one ArrayMesh (one surface per source
	surface) so that a multi-part model can be drawn by a single MultiMesh"""
	var merged = ArrayMesh.new()
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var relative = _transform_relative_to(node, root)
		for surface in range(node.mesh.get_surface_count()):
			var arrays = node.mesh.surface_get_arrays(surface)
			var vertices = arrays[Mesh.ARRAY_VERTEX]
			for i in range(vertices.size()):
				vertices[i] = relative * vertices[i]
			arrays[Mesh.ARRAY_VERTEX] = vertices
			if arrays[Mesh.ARRAY_NORMAL] != null:
				var normals = arrays[Mesh.ARRAY_NORMAL]
				var normal_basis = relative.basis.inverse().transposed()
				for i in range(normals.size()):
					normals[i] = (normal_basis * normals[i]).normalized()
				arrays[Mesh.ARRAY_NORMAL] = normals
			arrays[Mesh.ARRAY_TANGENT] = null
			merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var material = node.get_active_material(surface)
			merged.surface_set_material(merged.get_surface_count() - 1, material)
	return merged if merged.get_surface_count() > 0 else null


static func _transform_relative_to(node: Node3D, root: Node3D) -> Transform3D:
	var result = Transform3D.IDENTITY
	var current = node
	while current != null and current != root:
		if current is Node3D:
			result = current.transform * result
		current = current.get_parent()
	return result


func _placeholder_mesh(model_name):
	var material = StandardMaterial3D.new()
	var mesh = null
	if "tree" in model_name or "pine" in model_name or "palm" in model_name:
		mesh = CylinderMesh.new()
		mesh.top_radius = 0.0
		mesh.bottom_radius = 0.8
		mesh.height = 2.5
		material.albedo_color = Color(0.35, 0.42, 0.2)
	elif "bush" in model_name or "grass" in model_name or "reeds" in model_name:
		mesh = SphereMesh.new()
		mesh.radius = 0.3
		mesh.height = 0.4
		material.albedo_color = Color(0.55, 0.55, 0.3)
	else:
		mesh = SphereMesh.new()
		mesh.radius = 0.6
		mesh.height = 0.9
		material.albedo_color = Color(0.6, 0.42, 0.3)
	mesh.material = material
	return mesh
