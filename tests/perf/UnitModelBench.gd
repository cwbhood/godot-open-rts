extends Node3D

# Frame cost of the classic against the new unit models: 30 copies of one model in a bare
# lit scene with shadows, seen through an orthographic camera at the game's angle.
# For every unit with a "classic_model" in data/units, measures the empty scene, then 30
# classic and 30 new copies, and writes bench.json and bench.md to --out.
# Usage (needs a real renderer, e.g. under xvfb-run):
#   godot --path . res://tests/perf/UnitModelBench.tscn -- --out=/tmp/bench
# Options: --count (30), --frames measured per case (90), --only=tank,raider.

const GameData = preload("res://source/data-model/GameData.gd")
const Unit = preload("res://source/match/units/Unit.gd")

const SPACING = 2.4
const TEAM_COLOR = Color(0.4, 0.694118, 1)

var _args = {}
var _team_material = null


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_team_material = StandardMaterial3D.new()
	_team_material.vertex_color_use_as_albedo = true
	_team_material.albedo_color = TEAM_COLOR
	_build_stage()
	var out_dir = _args.get("out", "user://unit_bench")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var count = int(_args.get("count", "30"))
	var only = _args.get("only", "").split(",", false)
	var results = []
	var empty = await _measure(null)
	print("empty scene: ", empty)
	for entry in GameData.units():
		if not "classic_model" in entry or (not only.is_empty() and not entry["id"] in only):
			continue
		var row = {"id": entry["id"]}
		for variant in ["classic", "new"]:
			var prefix = "classic_" if variant == "classic" else ""
			var path = entry[prefix + "model"]
			var scale = float(entry.get(prefix + "model_scale", 1.0)) * _geometry_scale(entry)
			var group = _spawn_copies(path, scale, count)
			var measured = await _measure(group)
			measured["model_tris"] = _triangles(load(path).instantiate())
			measured["model_surfaces"] = _surfaces(load(path).instantiate())
			measured["cost_ms"] = measured["frame_ms"] - empty["frame_ms"]
			row[variant] = measured
			group.queue_free()
			await _frames(5)
		print(entry["id"], ": ", row)
		results.append(row)
	var file = FileAccess.open(out_dir + "/bench.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"empty": empty, "count": count, "units": results}, "  "))
	file = FileAccess.open(out_dir + "/bench.md", FileAccess.WRITE)
	file.store_string(_table(empty, count, results))
	print(_table(empty, count, results))
	get_tree().quit()


func _build_stage():
	var environment = WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color(0.85, 0.75, 0.55)
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	add_child(environment)
	var sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.rotation_degrees = Vector3(-55, 35, 0)
	add_child(sun)
	var ground = MeshInstance3D.new()
	var plane = PlaneMesh.new()
	plane.size = Vector2(60, 60)
	ground.mesh = plane
	add_child(ground)
	var camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 16.0
	camera.rotation_degrees = Vector3(-30, 0, 0)
	camera.position = Vector3(0, 12, 20.8)
	add_child(camera)
	camera.make_current()


func _geometry_scale(entry):
	"""the unit scene's own Geometry scale, which model_scale multiplies"""
	var scene_path = entry.get("base_scene", entry["scene"])
	var unit = load(scene_path).instantiate()
	var geometry = unit.find_child("Geometry", true, false)
	var scale = geometry.scale.x if geometry != null else 1.0
	unit.free()
	return scale


func _spawn_copies(path, scale, count):
	var group = Node3D.new()
	add_child(group)
	var columns = 6
	var scene = load(path)
	for i in range(count):
		var model = scene.instantiate()
		GameData.use_vertex_colours(model)
		model.scale = Vector3.ONE * scale
		var column = i % columns
		var row = i / columns
		model.position = Vector3((column - 2.5) * SPACING, 0, (row - 2.0) * SPACING)
		model.rotation.y = PI * 0.75
		group.add_child(model)
		Utils.Match.traverse_node_tree_and_replace_materials_matching_albedo(
			model, Unit.MATERIAL_ALBEDO_TO_REPLACE, 0.05, _team_material
		)
	return group


func _measure(_group):
	await _frames(30)
	var frames = int(_args.get("frames", "90"))
	var started = Time.get_ticks_usec()
	var draw_calls = 0
	var primitives = 0
	for i in range(frames):
		await get_tree().process_frame
		draw_calls += RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME
		)
		primitives += RenderingServer.get_rendering_info(
			RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME
		)
	return {
		"frame_ms": (Time.get_ticks_usec() - started) / 1000.0 / frames,
		"draw_calls": draw_calls / frames,
		"primitives": primitives / frames,
	}


func _triangles(node):
	var total = 0
	for child in [node] + node.find_children("*", "MeshInstance3D", true, false):
		if child is MeshInstance3D and child.mesh != null:
			for surface in range(child.mesh.get_surface_count()):
				var arrays = child.mesh.surface_get_arrays(surface)
				var indices = arrays[Mesh.ARRAY_INDEX]
				total += (
					indices.size() / 3 if indices != null else arrays[Mesh.ARRAY_VERTEX].size() / 3
				)
	node.free()
	return total


func _surfaces(node):
	var total = 0
	for child in [node] + node.find_children("*", "MeshInstance3D", true, false):
		if child is MeshInstance3D and child.mesh != null:
			total += child.mesh.get_surface_count()
	node.free()
	return total


func _table(empty, count, results):
	var lines = [
		"Empty scene: {0} ms per frame.".format([snappedf(empty["frame_ms"], 0.1)]),
		"",
		(
			(
				"| Unit | Tris per model classic → new | Surfaces | %d copies: cost ms classic → new"
				% count
			)
			+ " | Draw calls | Triangles drawn |"
		),
		"|---|---|---|---|---|---|",
	]
	for row in results:
		var c = row["classic"]
		var n = row["new"]
		(
			lines
			. append(
				(
					"| {0} | {1} → {2} | {3} → {4} | {5} → {6} | {7} → {8} | {9}k → {10}k |"
					. format(
						[
							row["id"],
							c["model_tris"],
							n["model_tris"],
							c["model_surfaces"],
							n["model_surfaces"],
							snappedf(c["cost_ms"], 0.1),
							snappedf(n["cost_ms"], 0.1),
							c["draw_calls"],
							n["draw_calls"],
							c["primitives"] / 1000,
							n["primitives"] / 1000,
						]
					)
				)
			)
		)
	return "\n".join(lines) + "\n"


func _frames(count):
	for i in range(count):
		await get_tree().process_frame
