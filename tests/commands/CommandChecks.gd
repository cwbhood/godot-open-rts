extends "res://tests/playtest/PlaytestChecks.gd"

# Bot checks for the unit orders (source/match/players/human/UnitCommands.gd and
# source/match/handlers/UnitCommandHandler.gd). Every order goes in
# through simulated mouse and keyboard events or a click on the unit-menu button, like a
# player would give it:
# - right-drag draws a line: a preview shows the spots, the units spread out along it,
# - a plain right-click still moves the group, Shift queues moves,
# - F + click fights its way (engages an enemy on the way, then arrives), F + left-drag
#   makes a fighting line,
# - P + clicks (Shift for more points) patrols, the button patrols the base loop,
# - V + click guards, X stops, Z retreats,
# - L cycles the fire stance (hold fire ignores an enemy in range, return fire answers
#   only a shooter), K holds position (no chase).
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --resolution 1280x720 \
#     res://tests/commands/CommandChecks.tscn -- --out=/tmp/commands
# Prints PASS/FAIL lines, saves screenshots to --out and exits with code 1 on failures.

const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const TankScene = preload("res://source/match/units/Tank.tscn")
const HaulerScene = preload("res://source/match/units/Hauler.tscn")
const Hauler = preload("res://source/match/units/Hauler.gd")
const AttackMoving = preload("res://source/match/units/actions/AttackMoving.gd")
const Patrolling = preload("res://source/match/units/actions/Patrolling.gd")
const Guarding = preload("res://source/match/units/actions/Guarding.gd")
const QueuedOrders = preload("res://source/match/units/actions/QueuedOrders.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
const Stances = preload("res://source/match/units/actions/Stances.gd")
const UnitCommandHandler = preload("res://source/match/handlers/UnitCommandHandler.gd")

var _rival = null
var _handler = null
var _cc = null
var _mouse_at = Vector2.ZERO


func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	_match = load("res://tests/playthrough/HelperMatch.tscn").instantiate()
	add_child(_match)
	await _frames(30)
	_human = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)[0]
	_rival = get_tree().get_nodes_in_group("players").filter(func(p): return p != _human)[0]
	_handler = UnitCommandHandler.of(get_tree())
	_cc = _own(func(unit): return unit is CommandCenter)
	_make_rival_inert()
	_match.fog_of_war.reveal()  # the screenshots show the whole field
	var atmosphere = _match.find_child("Atmosphere", true, false)
	if atmosphere != null:  # clear skies for readable screenshots
		atmosphere.set_weather_immediately(&"clear")
		atmosphere.set("_time_to_next_weather", 1.0e9)
	var only = ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	for scenario in [
		["line", _check_line_drag],
		["queue", _check_click_and_queue],
		["fight", _check_fight],
		["patrol", _check_patrol],
		["base", _check_patrol_base_button],
		["guard", _check_guard_stop_retreat],
		["stances", _check_stances],
		["manual", _check_manual],
	]:
		if only == "" or scenario[0] in only.split(","):
			await scenario[1].call()
	print("command checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


# --- scenarios ----------------------------------------------------------------------------


func _check_line_drag():
	var tanks = _spawn_squad(_human, _cc.global_position + Vector3(10, 0, 10), 6)
	await _frames(30)
	await _select(tanks)
	var center = _cc.global_position + Vector3(16, 0, 20)
	camera_on(center, 22.0)
	await _frames(10)
	var start = center + Vector3(-9, 0, 0)
	var end = center + Vector3(9, 0, 0)
	await _drag(MOUSE_BUTTON_RIGHT, start, end, false)
	_expect(
		_handler.last_preview_slots.size() == 6,
		"the drag preview shows a spot per unit (%d)" % _handler.last_preview_slots.size()
	)
	await _shot("line-1-drag-preview")
	await _release(MOUSE_BUTTON_RIGHT, end)
	var targets = tanks.map(
		func(tank):
			return (
				tank.action.get_plan()["points"][0]
				if tank.action != null and tank.action.has_method("get_plan")
				else null
			)
	)
	_expect(not targets.has(null), "every unit got a move order from the drag")
	await _wait_for(func(): return _all_arrived(tanks), 1500)
	var off_line = tanks.filter(func(tank): return abs(tank.global_position.z - center.z) > 2.0)
	_expect(off_line.is_empty(), "the units stand on the drawn line (%d off it)" % off_line.size())
	_expect(
		_line_width(tanks, Vector3(0, 0, 1)) > 12.0 and _spread(tanks) > 2.0,
		(
			"they spread along it (%.1f m wide, closest pair %.1f m)"
			% [_line_width(tanks, Vector3(0, 0, 1)), _spread(tanks)]
		)
	)
	await _shot("line-2-units-in-line")
	# a short line makes two rows
	await _drag(MOUSE_BUTTON_RIGHT, center + Vector3(-3, 0, 6), center + Vector3(3, 0, 6))
	await _wait_for(func(): return _all_arrived(tanks), 1500)
	var rows = {}
	for tank in tanks:
		rows[snappedf(tank.global_position.z, 1.5)] = true
	_expect(rows.size() >= 2, "a short line forms rows (%d rows)" % rows.size())
	await _shot("line-3-short-line-two-rows")
	_cleanup(tanks)


func _check_click_and_queue():
	var tanks = _spawn_squad(_human, _cc.global_position + Vector3(10, 0, 10), 3)
	await _frames(30)
	await _select(tanks)
	var center = _cc.global_position + Vector3(12, 0, 16)
	camera_on(center, 26.0)
	await _frames(10)
	await _click(MOUSE_BUTTON_RIGHT, center + Vector3(-6, 0, 4))
	_expect(
		tanks.all(func(tank): return tank.action is Moving),
		"a plain right-click still moves the group"
	)
	await _key(KEY_SHIFT, true)
	await _click(MOUSE_BUTTON_RIGHT, center + Vector3(6, 0, 6))
	await _click(MOUSE_BUTTON_RIGHT, center + Vector3(6, 0, -6))
	await _key(KEY_SHIFT, false)
	var plans = tanks.map(
		func(tank): return tank.action.get_plan() if tank.action is QueuedOrders else {}
	)
	_expect(
		plans.all(func(plan): return not plan.is_empty() and plan["points"].size() == 3),
		"Shift queues the moves after the first one"
	)
	await _shot("queue-1-order-lines")
	await _wait_for(func(): return _all_arrived(tanks), 2500)
	_expect(
		tanks.all(
			func(tank): return tank.global_position.distance_to(center + Vector3(6, 0, -6)) < 4.0
		),
		"they drove the queued route to its end"
	)
	_cleanup(tanks)


func _check_fight():
	if not Diplomacy.at_war(_human, _rival):
		Diplomacy.instance.declare_war(_rival, _human)
	var tanks = _spawn_squad(_human, _cc.global_position + Vector3(8, 0, 14), 3)
	var center = _cc.global_position + Vector3(10, 0, 28)
	var enemy = _spawn_squad(_rival, center + Vector3(0, 0, 0), 1)[0]
	Stances.set_fire_stance(enemy, Stances.Fire.HOLD)  # a target, not a threat
	await _frames(30)
	await _select(tanks)
	camera_on(center, 28.0)
	await _frames(10)
	await _key(KEY_F)
	_expect(_handler.mode == "fight", "F starts a fight order")
	var goal = center + Vector3(0, 0, 10)
	await _click(MOUSE_BUTTON_LEFT, goal)
	_expect(_handler.mode == null, "the click gives the order and ends the mode")
	_expect(
		tanks.all(func(tank): return tank.action is AttackMoving), "the units are on a fight order"
	)
	var engaged = await _wait_for(func(): return tanks.any(_is_engaging), 1500)
	_expect(engaged, "they engage the enemy they meet on the way")
	await _shot("fight-1-engaging-on-the-way")
	await _wait_for(func(): return not is_instance_valid(enemy), 2500)
	_expect(not is_instance_valid(enemy), "the enemy was destroyed")
	await _wait_for(func(): return _all_arrived(tanks), 2000)
	var report = []
	for tank in tanks:
		report.append("%.1f m %s" % [tank.global_position.distance_to(goal), tank.action])
	_expect(
		tanks.all(func(tank): return tank.global_position.distance_to(goal) < 5.0),
		"then they carry on to the fight point (%s)" % ", ".join(report)
	)
	# fight line: F, then a left-drag
	await _key(KEY_F)
	await _drag(MOUSE_BUTTON_LEFT, goal + Vector3(-6, 0, 4), goal + Vector3(6, 0, 4))
	_expect(
		tanks.all(func(tank): return tank.action is AttackMoving),
		"F + left-drag gives each unit a fight order to its spot on the line"
	)
	await _wait_for(func(): return _all_arrived(tanks), 1500)
	_expect(_line_width(tanks, Vector3(0, 0, 1)) > 6.0, "they form the fighting line")
	_cleanup(tanks)


func _check_patrol():
	var tanks = _spawn_squad(_human, _cc.global_position + Vector3(10, 0, 10), 2)
	await _frames(30)
	await _select(tanks)
	var center = _cc.global_position + Vector3(14, 0, 14)
	camera_on(center, 28.0)
	await _frames(10)
	await _key(KEY_P)
	await _key(KEY_SHIFT, true)
	await _click(MOUSE_BUTTON_LEFT, center + Vector3(10, 0, -4))
	await _click(MOUSE_BUTTON_LEFT, center + Vector3(10, 0, 10))
	await _key(KEY_SHIFT, false)
	await _key(KEY_ESCAPE)
	_expect(
		tanks.all(
			func(tank): return tank.action is Patrolling and tank.action.get_waypoints().size() == 3
		),
		"P + Shift-clicks make a patrol through both points and back"
	)
	await _shot("patrol-1-patrol-route")
	var tank = tanks[0]
	var visited = {}
	for _i in range(60):
		await _frames(20)
		if not tank.action is Patrolling:
			break
		visited[tank.action.get_plan()["points"][0]] = true
	_expect(
		visited.size() >= 3, "the patrol loops through its points (%d legs seen)" % visited.size()
	)
	_cleanup(tanks)


func _check_patrol_base_button():
	var tanks = _spawn_squad(_human, _cc.global_position + Vector3(8, 0, 8), 3)
	await _frames(30)
	await _select(tanks)
	camera_on(_cc.global_position, 30.0)
	await _frames(10)
	var button = _match.find_child("Command_patrol_base", true, false)
	_expect(
		button != null and button.is_visible_in_tree(), "the Patrol base button is in the unit menu"
	)
	if button == null:
		return
	await _shot("base-0-unit-menu-buttons")
	await _click_screen(MOUSE_BUTTON_LEFT, button.get_global_rect().get_center())
	_expect(
		tanks.all(func(tank): return tank.action is Patrolling),
		"clicking it sends the units on the base loop"
	)
	if tanks[0].action is Patrolling:
		var loop = tanks[0].action.get_waypoints()
		var starts = tanks.map(func(tank): return tank.action.get_plan()["points"][0])
		_expect(loop.size() >= 5, "the loop has %d points around the base" % loop.size())
		_expect(
			starts[0] != starts[1] and starts[1] != starts[2],
			"the units start at different points of the loop"
		)
	await _frames(120)
	await _shot("base-1-base-patrol-loop")
	_cleanup(tanks)


func _check_guard_stop_retreat():
	var tanks = _spawn_squad(_human, _cc.global_position + Vector3(10, 0, 10), 2)
	var hauler = HaulerScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		hauler, Transform3D(Basis(), _ground(_cc.global_position + Vector3(14, 0, 4))), _human
	)
	await _frames(30)
	hauler.automated = false
	await _select(tanks)
	camera_on(_cc.global_position + Vector3(10, 0, 8), 24.0)
	await _frames(10)
	await _key(KEY_V)
	await _click(MOUSE_BUTTON_LEFT, hauler.global_position)
	_expect(
		tanks.all(func(tank): return tank.action is Guarding),
		"V + click on a hauler makes the units guard it"
	)
	hauler.action = Moving.new(_ground(_cc.global_position + Vector3(24, 0, 2)))
	await _frames(300)
	_expect(
		tanks.all(
			func(tank): return tank.global_position.distance_to(hauler.global_position) < 7.0
		),
		"the guards follow the hauler"
	)
	await _key(KEY_X)
	_expect(
		tanks.all(func(tank): return tank.action == null or tank.action.has_method("is_idle")),
		"X stops them"
	)
	await _select(tanks)
	await _key(KEY_Z)
	_expect(tanks.all(func(tank): return tank.action is Moving), "Z sends them back to base")
	await _wait_for(func(): return _all_arrived(tanks), 2000)
	_expect(
		tanks.all(func(tank): return tank.global_position.distance_to(_cc.global_position) < 10.0),
		"they arrive next to the command center"
	)
	hauler.queue_free()
	_cleanup(tanks)


func _check_stances():
	if not Diplomacy.at_war(_human, _rival):
		Diplomacy.instance.declare_war(_rival, _human)
	var spot = _cc.global_position + Vector3(14, 0, 22)
	var tank = _spawn_squad(_human, spot, 1)[0]
	await _frames(30)
	await _select([tank])
	camera_on(spot, 24.0)
	await _frames(5)
	await _key(KEY_L)
	_expect(Stances.fire_stance(tank) == Stances.Fire.RETURN, "L switches to return fire")
	var enemy = _spawn_squad(_rival, spot + Vector3(3.5, 0, 0), 1)[0]
	Stances.set_fire_stance(enemy, Stances.Fire.HOLD)
	await _frames(150)
	_expect(
		is_instance_valid(enemy) and enemy.hp == enemy.hp_max,
		"on return fire it does not shoot first"
	)
	Stances.set_fire_stance(enemy, Stances.Fire.AT_WILL)  # the enemy opens fire
	var answered = await _wait_for(
		func(): return not is_instance_valid(enemy) or enemy.hp < enemy.hp_max, 900
	)
	_expect(answered, "once shot at, it shoots back")
	if is_instance_valid(enemy):
		enemy.queue_free()
	await _frames(10)
	tank.hp = tank.hp_max
	await _key(KEY_L)
	_expect(Stances.fire_stance(tank) == Stances.Fire.HOLD, "L again: hold fire")
	var calm_enemy = _spawn_squad(_rival, spot + Vector3(3.5, 0, 0), 1)[0]
	Stances.set_fire_stance(calm_enemy, Stances.Fire.HOLD)
	await _frames(200)
	_expect(
		is_instance_valid(calm_enemy) and calm_enemy.hp == calm_enemy.hp_max,
		"on hold fire it leaves an enemy in range alone"
	)
	if is_instance_valid(calm_enemy):
		calm_enemy.queue_free()
	await _key(KEY_L)
	_expect(Stances.fire_stance(tank) == Stances.Fire.AT_WILL, "L again: back to fire at will")
	# hold position: an enemy within sight but out of range is not chased
	await _key(KEY_K)
	_expect(Stances.holds_position(tank), "K holds position")
	var start = tank.global_position
	var far_enemy = _spawn_squad(_rival, start + Vector3(0, 0, tank.attack_range + 2.5), 1)[0]
	Stances.set_fire_stance(far_enemy, Stances.Fire.HOLD)
	await _frames(300)
	_expect(
		tank.global_position.distance_to(start) < 1.5,
		(
			"holding, it does not chase an enemy out of range (moved %.1f m)"
			% tank.global_position.distance_to(start)
		)
	)
	await _shot("stances-1-holding-position")
	await _key(KEY_K)
	var chased = await _wait_for(
		func():
			return tank.global_position.distance_to(start) > 1.5 or not is_instance_valid(far_enemy),
		900
	)
	_expect(chased, "released, it goes after the enemy")
	if is_instance_valid(far_enemy):
		far_enemy.queue_free()
	_cleanup([tank])


func _check_manual():
	var guide = _match.find_child("Guide", true, false)
	guide.toggle_help("COMMANDS", true)
	await _frames(10)
	await _shot("manual-unit-orders")
	guide.help_window.hide()


# --- helpers ------------------------------------------------------------------------------


static func _is_engaging(tank):
	return tank.action is AttackMoving and str(tank.action).contains("AutoAttacking")


func _make_rival_inert():
	_rival.set_process(false)
	for child in _rival.get_children():
		if child.name.ends_with("Controller"):
			child.queue_free()


func _units_of(player):
	return get_tree().get_nodes_in_group("units").filter(func(unit): return unit.player == player)


func _ground(position):
	var rid = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	return NavigationServer3D.map_get_closest_point(rid, position)


func _spawn_squad(player, center, count):
	var squad = []
	for index in range(count):
		var tank = TankScene.instantiate()
		var offset = Vector3(index % 3, 0, index / 3) * 1.9
		MatchSignals.setup_and_spawn_unit.emit(
			tank, Transform3D(Basis(), _ground(center + offset)), player
		)
		squad.append(tank)
	return squad


func _cleanup(units):
	MatchSignals.deselect_all_units.emit()
	for unit in units:
		if is_instance_valid(unit):
			unit.queue_free()
	await _frames(5)


func _select(units):
	MatchSignals.deselect_all_units.emit()
	await _frames(1)
	for unit in units:
		unit.find_child("Selection").select()


func _all_arrived(units):
	return units.all(
		func(unit):
			return (
				not is_instance_valid(unit)
				or unit.action == null
				or unit.action.has_method("is_idle")
			)
	)


func _spread(units):
	"""distance of the closest pair"""
	var best = INF
	for i in range(units.size()):
		for j in range(i + 1, units.size()):
			best = min(
				best, units[i].global_position_yless.distance_to(units[j].global_position_yless)
			)
	return best


func _line_width(units, facing):
	var across = Vector3(-facing.z, 0, facing.x)
	var values = units.map(func(unit): return unit.global_position.dot(across))
	return values.max() - values.min() if not values.is_empty() else 0.0


func _screen(world):
	return get_viewport().get_camera_3d().unproject_position(world)


func _key(keycode, pressed = null):
	"""a key tap, or only press / release when 'pressed' is given"""
	for state in [true, false] if pressed == null else [pressed]:
		var event = InputEventKey.new()
		event.keycode = keycode
		event.physical_keycode = keycode
		event.pressed = state
		event.shift_pressed = Input.is_key_pressed(KEY_SHIFT) and keycode != KEY_SHIFT
		Input.parse_input_event(event)
		await _frames(2)


func _mouse_button(button, pressed, screen_position):
	var event = InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = screen_position
	event.global_position = screen_position
	event.shift_pressed = Input.is_key_pressed(KEY_SHIFT)
	Input.parse_input_event(event)
	await _frames(2)


func _mouse_motion(screen_position):
	var event = InputEventMouseMotion.new()
	event.position = screen_position
	event.global_position = screen_position
	event.relative = screen_position - _mouse_at
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		event.button_mask = MOUSE_BUTTON_MASK_RIGHT
	_mouse_at = screen_position
	Input.parse_input_event(event)
	await _frames(1)


func _click_screen(button, screen_position):
	await _mouse_motion(screen_position)
	await _mouse_button(button, true, screen_position)
	await _mouse_button(button, false, screen_position)


func _click(button, world):
	await _click_screen(button, _screen(world))


func _drag(button, from_world, to_world, release = true):
	var from = _screen(from_world)
	var to = _screen(to_world)
	await _mouse_motion(from)
	await _mouse_button(button, true, from)
	for step in range(1, 13):
		await _mouse_motion(from.lerp(to, step / 12.0))
	if release:
		await _release(button, to_world)


func _release(button, world):
	await _mouse_button(button, false, _screen(world))
