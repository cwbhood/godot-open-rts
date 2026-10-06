extends Node

# Screenshots of the menus and the in-match HUD in their usual states, and a check that
# nothing on screen is cut off by the window edge. Run at each window size to check:
#   xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --resolution 1280x720 \
#     res://tests/screenshots/UiShots.tscn -- --out=/tmp/ui
# --only=main,play,replay,hud picks the parts. Exits with 1 when a control sticks out.

const Worker = preload("res://source/match/units/Worker.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Human = preload("res://source/match/players/human/Human.gd")

var _args = {}
var _out = ""
var _problems = []


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var size = get_viewport().get_visible_rect().size
	_out = _args.get("out", "user://ui-shots")
	DirAccess.make_dir_recursive_absolute(_out)
	var only = _args.get("only", "main,play,replay,hud").split(",")
	if "main" in only:
		await _menu("res://source/main-menu/Main.tscn", "main")
	if "play" in only:
		await _menu("res://source/main-menu/Play.tscn", "play")
	if "replay" in only:
		await _replay_viewer()
	if "hud" in only:
		await _hud()
	print("UI SHOTS %dx%d: %d problem(s)" % [size.x, size.y, _problems.size()])
	for problem in _problems:
		print("  PROBLEM ", problem)
	get_tree().quit(1 if not _problems.is_empty() else 0)


func _menu(path, label):
	var scene = load(path).instantiate()
	add_child(scene)
	await _frames(20)
	_check_on_screen(scene, label)
	await _shot(label)
	scene.queue_free()
	await _frames(2)


func _replay_viewer():
	var viewer = load("res://source/replay/ReplayViewer.tscn").instantiate()
	add_child(viewer)
	await _frames(10)
	var paths = viewer.get("_replay_paths")
	await _shot("replay-list")
	if not paths.is_empty():
		viewer.call("_on_replay_selected", 0)
		viewer.call("_set_playing", false)
		viewer.get("_slider").value = viewer.get("_slider").max_value * 0.6
		await _frames(10)
		_check_on_screen(viewer, "replay-playing")
		await _shot("replay-playing")
	viewer.set("_replay", null)
	viewer.call("_fill_list", [])
	await _frames(10)
	_check_on_screen(viewer, "replay-empty")
	await _shot("replay-empty")
	viewer.queue_free()
	await _frames(2)


func _hud():
	var match_node = load(_args.get("scene", "res://tests/manual/TestDesert.tscn")).instantiate()
	add_child(match_node)
	await _frames(90)
	var human = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)[0]
	var own = get_tree().get_nodes_in_group("units").filter(func(u): return u.player == human)
	await _shot("hud-start")
	var worker = own.filter(func(u): return u is Worker)
	if not worker.is_empty():
		MatchSignals.deselect_all_units.emit()
		worker[0].find_child("Selection").select()
		await _frames(20)
		_check_on_screen(match_node.get_node("HUD"), "hud-worker")
		await _shot("hud-worker-selected")
	var cc = own.filter(func(u): return u is CommandCenter)
	if not cc.is_empty():
		MatchSignals.deselect_all_units.emit()
		cc[0].find_child("Selection").select()
		for _i in range(2):
			cc[0].production_queue.produce(load("res://source/match/units/Worker.tscn"))
		await _frames(40)
		await _shot("hud-command-center-selected")
	MatchSignals.deselect_all_units.emit()
	var hud = match_node.get_node("HUD")
	var city = hud.find_child("CityHud", true, false)
	if city != null and city.has_method("open_details"):
		city.open_details()
		await _frames(10)
		await _shot("hud-city-details")
		city.open_trade()
		await _frames(10)
		_check_on_screen(hud, "hud-trade")
		await _shot("hud-city-trade")
	for name in ["HelperPanel", "AutoExpandPanel"]:
		var panel = hud.find_child(name, true, false)
		if panel != null and panel.has_method("set_collapsed"):
			panel.set_collapsed(false)
	await _frames(10)
	_check_on_screen(hud, "hud-all-open")
	await _shot("hud-panels-open")
	match_node.queue_free()
	await _frames(2)


func _check_on_screen(root, label):
	var screen = get_viewport().get_visible_rect().grow(1)
	for control in root.find_children("*", "Control", true, false):
		if not control.is_visible_in_tree() or control is ScrollContainer:
			continue
		if control.get_parent() is ScrollContainer or _in_scroll(control):
			continue
		var rect = control.get_global_rect()
		if rect.size.x < 2 or rect.size.y < 2:
			continue
		if control.get_parent() is SubViewport or control.get_viewport() != get_viewport():
			continue
		if not screen.encloses(rect):
			_problems.append("%s: %s off screen %s" % [label, control.get_path(), rect])


func _in_scroll(control):
	var node = control.get_parent()
	while node != null and node is Control:
		if node is ScrollContainer:
			return true
		node = node.get_parent()
	return false


func _shot(name):
	await RenderingServer.frame_post_draw
	var size = get_viewport().get_visible_rect().size
	var path = "%s/%s-%dx%d.png" % [_out, name, size.x, size.y]
	get_viewport().get_texture().get_image().save_png(path)
	print("shot ", path)


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
