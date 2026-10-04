extends "res://tests/playtest/PlaytestChecks.gd"

# Checks constructor building, auto-expand and the guide in a running match, and saves
# screenshots. Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . \
#     res://tests/playtest/ConstructorChecks.tscn -- --out=/tmp/constructors
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const Structure = preload("res://source/match/units/Structure.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const Constructing = preload("res://source/match/units/actions/Constructing.gd")
const AutoExpand = preload("res://source/match/units/traits/AutoExpand.gd")
const OilDerrickScene = preload("res://source/match/units/OilDerrick.tscn")
const UNDER_CONSTRUCTION_MATERIAL = preload(
	"res://source/match/resources/materials/structure_under_construction.material.tres"
)


func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	_match = load("res://tests/manual/TestOneCityOneRival.tscn").instantiate()
	add_child(_match)
	await _frames(30)
	_human = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)[0]
	await _check_far_site_waits_for_constructor()
	await _check_auto_expand()
	await _check_guide()
	print("constructor checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_far_site_waits_for_constructor():
	MatchSignals.deselect_all_units.emit()
	var worker = _own(func(unit): return unit is Worker)
	var deposit = _deposit_about("oil", worker.global_position, 25.0)
	_human.add_resources({"timber": 10, "iron": 20, "copper": 5})
	var site = OilDerrickScene.instantiate()
	site.set_meta("placed_by_hand", true)
	var position = deposit.global_position_yless + Vector3(deposit.radius + 1.4, 0, 0)
	MatchSignals.setup_and_spawn_unit.emit(site, Transform3D(Basis(), position), _human)
	await _frames(240)
	_expect(
		site.get_construction_progress() == 0.0,
		"a derrick {0} m from the constructor is not built without it (progress {1})".format(
			[int(worker.global_position.distance_to(position)), site.get_construction_progress()]
		)
	)
	var meshes = site.find_child("Geometry").find_children("*", "MeshInstance3D", true, false)
	var model_meshes = meshes.filter(func(mesh): return mesh.is_visible_in_tree())
	_expect(
		(
			not model_meshes.is_empty()
			and model_meshes.all(
				func(mesh): return mesh.material_override == UNDER_CONSTRUCTION_MATERIAL
			)
		),
		"the site's model looks unfinished ({0} meshes)".format([model_meshes.size()])
	)
	var label = site.get_node_or_null("SiteStatusLabel")
	_expect(
		label != null and label.visible and label.text.length() > 0,
		"the site says what it waits for: " + (label.text if label != null else "no label")
	)
	camera_on(site.global_position, 15.0)
	await _frames(20)
	await _shot("1-far-site-waits-for-constructor")
	# a constructor ordered there builds it only once it got there
	worker.action = Constructing.new(site)
	await _frames(10)
	var progress_before_arrival = [0.0]
	var arrived = await _wait_for(
		func():
			if Utils.Match.Unit.Movement.units_adhere(worker, site):
				return true
			progress_before_arrival[0] = site.get_construction_progress()
			return false,
		4000
	)
	_expect(arrived, "the constructor drives to the site")
	_expect(progress_before_arrival[0] == 0.0, "no progress before the constructor arrives")
	var progressed = await _wait_for(func(): return site.get_construction_progress() > 0.0, 1500)
	_expect(progressed, "progress starts once it is there (materials permitting)")
	site.cancel_construction()
	worker.action = null
	await _frames(5)


func _check_auto_expand():
	var worker = _own(func(unit): return unit is Worker)
	MatchSignals.deselect_all_units.emit()
	worker.find_child("Selection").select()
	await _frames(10)
	var bar = _match.find_child("AutoExpandBar", true, false)
	_expect(bar != null and bar.visible, "the auto-expand switch shows for a constructor")
	_human.set_meta(AutoExpand.RESERVE_META, 1000)
	bar.get("_toggle").button_pressed = true
	await _frames(5)
	_expect(AutoExpand.is_enabled_on(worker), "the switch turns auto-expand on")
	await _frames(200)
	var auto = worker.get_node(AutoExpand.NODE_NAME)
	print("  status with a huge reserve: ", auto.status_text)
	_expect(
		auto.job == AutoExpand.Job.WAITING and not worker.action is Constructing,
		"it keeps the reserve: nothing built while the bank is at the reserve"
	)
	_human.set_meta(AutoExpand.RESERVE_META, 10)
	_human.add_resources({"timber": 60, "iron": 60, "copper": 30, "oil": 20})
	var extractors_before = _own_extractors()
	var started = await _wait_for(
		func(): return worker.action is Constructing and auto.target != null, 600
	)
	print("  status: ", auto.status_text)
	_expect(started, "with money it lays out a site and drives there")
	var spent = AutoExpand.get_spent(_human)
	_expect(not spent.is_empty(), "its spending is counted: " + str(spent))
	if started:
		var site = auto.target
		print("  it picked: ", site.name)
		camera_on(worker.global_position.lerp(site.global_position, 0.5), 18.0)
		await _frames(60)
		await _shot("2-auto-expand-bar-and-panel")
		var built = await _wait_for(
			func(): return not is_instance_valid(site) or site.is_constructed(), 6000
		)
		_expect(built, "it builds the site and moves on")
		await _frames(200)
		print("  next status: ", auto.status_text)
		print("  extractors before %d, now %d" % [extractors_before, _own_extractors()])
	var panel = _match.find_child("AutoExpandPanel", true, false)
	_expect(panel != null and panel.visible, "the auto-expand overview is on screen")
	worker.action = Moving.new(worker.global_position + Vector3(25, 0, 25))
	var paused = await _wait_for(func(): return auto.job == AutoExpand.Job.PAUSED, 300)
	print("  after an order: ", auto.status_text)
	_expect(paused, "a manual order pauses it")
	bar.get("_toggle").button_pressed = false
	await _frames(5)
	_expect(not AutoExpand.is_enabled_on(worker), "the switch turns it off again")


func _check_guide():
	var guide = _match.find_child("Guide", true, false)
	_expect(guide != null, "the guide is in the HUD")
	if guide == null:
		return
	var title = guide.get("_tutorial_title").text
	_expect(title.length() > 0 and not title.begins_with("GUIDE_"), "tutorial shows: " + title)
	guide.show_hint("HINT_BLACKOUT")
	await _frames(10)
	await _shot("3-tutorial-and-hint")
	var key = InputEventKey.new()
	key.keycode = KEY_F1
	key.pressed = true
	Input.parse_input_event(key)
	await _frames(10)
	_expect(guide.help_window.visible, "F1 opens the manual")
	guide.help_window.show_topic("AUTO_EXPAND")
	await _frames(10)
	await _shot("4-manual")
	guide.help_window.hide()
	var resources_bar = _match.find_child("ResourcesBar", true, false)
	var tooltip = resources_bar.get_child(0).get_child(0).get_child(0).get_child(0).tooltip_text  # margin > column > row > item
	_expect(tooltip.contains("\n"), "resource tooltips explain the commodity: " + tooltip)


func _own_extractors():
	return (
		get_tree()
		. get_nodes_in_group("units")
		. filter(func(unit): return unit is Extractor and unit.player == _human)
		. size()
	)


func _deposit_about(kind, position, distance):
	"""the deposit of 'kind' whose distance from 'position' is closest to 'distance'"""
	var best = null
	for deposit in get_tree().get_nodes_in_group("deposits"):
		if deposit.kind != kind:
			continue
		var error = abs(deposit.global_position.distance_to(position) - distance)
		if best == null or error < best[0]:
			best = [error, deposit]
	return best[1]
