extends Node

# Smoke test and screenshots for the map editor: opens it, places a few features through
# the same functions mouse clicks use, saves the map and checks that GameData lists it.
# xvfb-run -a godot --path . res://tests/screenshots/MapEditorShots.tscn -- --out=/tmp/shots

const MapEditorScene = preload("res://source/map-editor/MapEditor.tscn")


func _ready():
	var out_dir = "/tmp"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			out_dir = argument.trim_prefix("--out=")
	var editor = MapEditorScene.instantiate()
	add_child(editor)
	await _frames(10)
	editor._camera.set_size_safely(110.0)
	editor._camera.set_position_safely(Vector3(50.0, 0.0, 50.0))
	await _frames(10)
	await _shot(out_dir + "/editor_random.png")
	editor._clear_layout()
	await _frames(3)
	editor._ui.name.text = "Editor Smoke Test"
	editor._select_tool(editor.Tool.LAKE)
	editor._place_at(Vector2(50, 50))
	editor._select_tool(editor.Tool.FOREST)
	editor._place_at(Vector2(30, 60))
	editor._place_at(Vector2(33, 62))
	editor._select_tool(editor.Tool.OUTCROP)
	editor._place_at(Vector2(70, 30))
	editor._select_tool(editor.Tool.DEPOSIT)
	editor._place_at(Vector2(25, 35))
	editor._select_tool(editor.Tool.SPAWN)
	editor._place_at(Vector2(20, 80))
	editor._erase_at(Vector2(70, 30))
	await _frames(10)
	await _shot(out_dir + "/editor_painted.png")
	editor._save()
	var saved = Constants.Match.MAPS.get("user://mods/custom_maps/maps/editor_smoke_test.tscn")
	print("editor status: ", editor._ui.status.text)
	print("editor saved map listed: ", saved)
	var map = load("user://mods/custom_maps/maps/editor_smoke_test.tscn").instantiate()
	print("saved map spawns: ", map.find_child("SpawnPoints").get_child_count())
	print("saved map deposits: ", map.get_node("Deposits").get_child_count())
	map.free()
	# water: turn the sea on (each start point gets an island), add an island and a ford
	editor._on_sea_toggled(true)
	editor._select_tool(editor.Tool.ISLAND)
	editor._place_at(Vector2(25, 35))
	editor._select_tool(editor.Tool.SHALLOWS)
	editor._place_at(Vector2(50, 70))
	await _frames(20)
	await _shot(out_dir + "/editor_water.png")
	editor._ui.name.text = "Editor Island Test"
	editor._save()
	print("editor water status: ", editor._ui.status.text)
	var island_map = "user://mods/custom_maps/maps/editor_island_test.tscn"
	print("editor island map listed: ", Constants.Match.MAPS.get(island_map) != null)
	print("editor island layout sea: ", editor._layout.sea, " islands: ", editor._layout.islands.size())
	editor._place_at(Vector2(50, 50))  # an island in the middle of the old lake is fine
	editor._select_tool(editor.Tool.DEPOSIT)
	editor._place_at(Vector2(50, 92))  # out at sea: saving must refuse
	await _frames(20)
	print("spawns: ", editor._layout.spawns, " depth there: ", editor._map.water.depth_fast(Vector2(50, 92)))
	editor._save()
	print("editor deposit at sea status: ", editor._ui.status.text)
	get_tree().quit()


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame


func _shot(path):
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)
