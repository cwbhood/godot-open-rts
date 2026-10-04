extends SceneTree

# Times the generation of a map with water and the bakes of its navigation meshes.
#   godot --headless --path . -s res://tests/perf/WaterMapTiming.gd -- --map=res://source/match/maps/TwinIsles.tscn


func _initialize():
	var map_path = "res://source/match/maps/TwinIsles.tscn"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			map_path = arg.trim_prefix("--map=")
	var started = Time.get_ticks_msec()
	var map = load(map_path).instantiate()
	print("instantiate + generate: ", Time.get_ticks_msec() - started, " ms")
	var water = map.water
	started = Time.get_ticks_msec()
	water.build_grid(Rect2(-Vector2.ONE * 6.0, map.size + Vector2.ONE * 12.0))
	print("grid: ", Time.get_ticks_msec() - started, " ms")
	for domain in [1, 2, 3]:
		started = Time.get_ticks_msec()
		var faces = map.get_navigation_faces(domain)
		var faces_ms = Time.get_ticks_msec() - started
		var navigation_mesh = NavigationMesh.new()
		navigation_mesh.cell_size = 0.3
		navigation_mesh.cell_height = 0.3
		navigation_mesh.agent_radius = 0.9
		navigation_mesh.agent_height = 1.8
		navigation_mesh.agent_max_climb = 0.0
		navigation_mesh.edge_max_error = 1.0
		navigation_mesh.filter_baking_aabb = AABB(Vector3.ZERO, Vector3(map.size.x, 5, map.size.y))
		var geometry = NavigationMeshSourceGeometryData3D.new()
		geometry.add_faces(faces, Transform3D.IDENTITY)
		started = Time.get_ticks_msec()
		NavigationServer3D.bake_from_source_geometry_data(navigation_mesh, geometry)
		print(
			"domain ", domain, ": ", faces.size() / 3, " triangles in ", faces_ms, " ms, bake ",
			Time.get_ticks_msec() - started, " ms, ", navigation_mesh.get_polygon_count(), " polygons"
		)
	map.free()
	quit()
