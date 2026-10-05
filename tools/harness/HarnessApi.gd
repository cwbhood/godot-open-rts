extends Node

# What a test script, a scenario file or a remote client can see and do in a running match.
#
# state() returns the match as plain JSON-ready data: players with their stock, tier and
# wars, every unit with its position, health and current order, what threatens the human
# player, and how fast the game runs (fps, frame time, process time).
#
# command({"do": ..., ...}) gives orders through the same code the HUD uses: selecting goes
# through the units' Selection trait, a move or attack through the same signals a
# right-click sends, fight/patrol/guard/line/stop/retreat/stances through the
# UnitCommandHandler that the buttons and hotkeys call, building through the structure
# placement handler with a (virtual) mouse click, production through the factory's queue
# as the build menu does. Commands return {"ok": bool, ...} and never throw, so a script
# can check what happened. See docs/testing/play-harness.md for the full list.
#
# Units are picked with selectors: a unit id (from state()), a list of ids, or a string
# "<who>:<what>" where who is own, enemy, all or p<N> (player index) and what is a unit id
# from data/units (tank, worker, ...), * (everything), combat, structures or workers.
# Add "near": [x, z] and "radius" to narrow it down, "limit" to cap the count.

const GameData = preload("res://source/data-model/GameData.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const Helper = preload("res://source/match/players/human/Helper.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const AutoExpand = preload("res://source/match/units/traits/AutoExpand.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const UnitCommandHandler = preload("res://source/match/handlers/UnitCommandHandler.gd")
const UnitCommands = preload("res://source/match/players/human/UnitCommands.gd")
const SaveGame = preload("res://source/match/SaveGame.gd")

signal match_replaced(new_match)  # "reload" swapped the match for one loaded from a save

const COMMANDS = [
	"select",
	"move",
	"attack",
	"fight",
	"patrol",
	"patrol_base",
	"guard",
	"line",
	"stop",
	"retreat",
	"stance",
	"hold_position",
	"build",
	"extract",
	"produce",
	"helper",
	"auto_expand",
	"speed",
	"camera",
	"click",
	"drag",
	"key",
	"give",
	"spawn",
	"declare_war",
	"weather",
	"reveal",
	"screenshot",
	"wait",
	"state",
	"save",
	"reload",
	"end"
]
const VALIDITY_NAMES = [
	"valid",
	"collides",
	"not_navigable",
	"not_enough_resources",
	"out_of_map",
	"no_deposit_nearby",
	"tier_too_low"
]

var match_node = null
var mouse = null  # VirtualMouse
var recorder = null  # Recorder, for screenshots and the event log
var elapsed_s = 0.0  # game seconds since the match started
var ended = false  # set by the "end" command

var _kinds = {}  # scene path -> unit id from data/units


func _ready():
	name = "HarnessApi"
	process_mode = Node.PROCESS_MODE_ALWAYS
	for entry in GameData.units():
		_kinds[entry["scene"]] = entry["id"]


func _physics_process(delta):
	if match_node != null and is_instance_valid(match_node) and not get_tree().paused:
		elapsed_s += delta


# --- reading the match ------------------------------------------------------------------


func players():
	return get_tree().get_nodes_in_group("players")


func human():
	for player in players():
		if player is Human:
			return player
	return null


func kind_of(unit):
	return _kinds.get(unit.scene_file_path, unit.scene_file_path.get_file().get_basename())


func is_combat(unit):
	return (
		not unit is Structure
		and not unit is Worker
		and unit.attack_range != null
		and unit.movement_speed != null
		and unit.movement_speed > 0.0
	)


func perf():
	return {
		"fps": Engine.get_frames_per_second(),
		"frame_ms": recorder.last_frame_ms if recorder != null else 0.0,
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"speed": Engine.time_scale,
	}


func state(with_units = true):
	var data = perf()
	data["t"] = snapped(elapsed_s, 0.01)
	data["players"] = players().map(_player_state)
	var units = get_tree().get_nodes_in_group("units")
	data["unit_count"] = units.size()
	if with_units:
		data["units"] = units.map(_unit_state)
	data["selected"] = get_tree().get_nodes_in_group("selected_units").map(
		func(unit): return unit.get_instance_id()
	)
	data["threats"] = threats()
	if recorder != null:
		data["recent_events"] = recorder.timeline.slice(-10)
	return data


func _player_state(player):
	var units = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player
	)
	var entry = {
		"index": player.get_index(),
		"name": player.name,
		"type": "human" if player is Human else "ai",
		"color": player.color.to_html(false),
		"stock": player.get_stock(),
		"tier": player.get_tier(),
		"units": units.filter(func(unit): return not unit is Structure).size(),
		"structures": units.filter(func(unit): return unit is Structure).size(),
		"combat": units.filter(is_combat).size(),
		"workers": units.filter(func(unit): return unit is Worker).size(),
		"at_war_with":
		(
			players()
			. filter(func(other): return other != player and Diplomacy.at_war(player, other))
			. map(func(other): return other.get_index())
		),
	}
	if "personality_id" in player:
		entry["personality"] = player.personality_id
	if "difficulty_id" in player:
		entry["difficulty"] = player.difficulty_id
	if player.city != null:
		entry["population"] = player.city.population
		entry["science"] = snapped(player.city.science, 0.1)
	var helper = Helper.of(player) if player is Human else null
	if helper != null:
		entry["helper"] = {
			"enabled": helper.enabled,
			"army_target": helper.army_target,
			"stats": helper.stats.duplicate(),
		}
	return entry


func _unit_state(unit):
	var entry = {
		"id": unit.get_instance_id(),
		"player": unit.player.get_index() if unit.player != null else -1,
		"kind": kind_of(unit),
		"x": snapped(unit.global_position.x, 0.01),
		"z": snapped(unit.global_position.z, 0.01),
		"hp": unit.hp,
		"hp_max": unit.hp_max,
		"action": _action_name(unit.action),
		"selected": unit.is_in_group("selected_units"),
	}
	if unit is Structure:
		entry["built"] = unit.is_constructed()
	return entry


func _action_name(action):
	if action == null:
		return null
	var script = action.get_script()
	return script.resource_path.get_file().get_basename() if script != null else action.name


func threats(player = null):
	"""enemy units within sight of the player's units (the human player by default)"""
	player = player if player != null else human()
	if player == null:
		return []
	var own = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player and unit.sight_range != null
	)
	var seen = []
	for enemy in get_tree().get_nodes_in_group("units"):
		if enemy.player == player or enemy.player == null:
			continue
		if not Diplomacy.at_war(player, enemy.player) or enemy.attack_range == null:
			continue
		for unit in own:
			var distance = unit.global_position_yless.distance_to(enemy.global_position_yless)
			if distance <= unit.sight_range:
				(
					seen
					. append(
						{
							"id": enemy.get_instance_id(),
							"player": enemy.player.get_index(),
							"kind": kind_of(enemy),
							"x": snapped(enemy.global_position.x, 0.01),
							"z": snapped(enemy.global_position.z, 0.01),
							"near": unit.get_instance_id(),
						}
					)
				)
				break
	return seen


func find_units(selector, near = null, radius = INF, limit = 0):
	var found = []
	if selector is float or selector is int:
		selector = [selector]
	if selector is Array:
		for id in selector:
			var unit = instance_from_id(int(id))
			if unit != null and is_instance_valid(unit) and unit.is_in_group("units"):
				found.append(unit)
	elif selector is String:
		var parts = selector.split(":", true, 1)
		var who = parts[0]
		var what = parts[1] if parts.size() > 1 else "*"
		var owner = _player_for(who)
		for unit in get_tree().get_nodes_in_group("units"):
			if not _owned_by(unit, who, owner) or not _is_kind(unit, what):
				continue
			found.append(unit)
	if near != null:
		var point = _vec2(near)
		found = found.filter(func(unit): return flat(unit).distance_to(point) <= radius)
		found.sort_custom(
			func(a, b): return flat(a).distance_to(point) < flat(b).distance_to(point)
		)
	if limit > 0:
		found = found.slice(0, limit)
	return found


func _player_for(who):
	if who == "own":
		return human()
	if who.begins_with("p") and who.substr(1).is_valid_int():
		var index = int(who.substr(1))
		var all = players()
		return all[index] if index < all.size() else null
	return null


func _owned_by(unit, who, owner):
	match who:
		"all", "*":
			return true
		"enemy":
			var me = human()
			return unit.player != me and unit.player != null and Diplomacy.at_war(me, unit.player)
		_:
			return owner != null and unit.player == owner


func _is_kind(unit, what):
	match what:
		"*":
			return true
		"combat":
			return is_combat(unit)
		"structures":
			return unit is Structure
		"workers":
			return unit is Worker
		_:
			return kind_of(unit) == what


static func flat(unit):
	return Vector2(unit.global_position.x, unit.global_position.z)


static func _vec2(value):
	if value is Vector2:
		return value
	if value is Vector3:
		return Vector2(value.x, value.z)
	return Vector2(float(value[0]), float(value[1]))


static func _vec3(value):
	var flat = _vec2(value)
	return Vector3(flat.x, 0.0, flat.y)


# --- giving orders ----------------------------------------------------------------------


func command(order):
	"""runs one order ({"do": name, ...}); always returns {"ok": bool, ...}"""
	if not order is Dictionary or not order.has("do"):
		return {"ok": false, "error": 'an order needs a "do" field'}
	var what = str(order["do"])
	if not what in COMMANDS:
		return {"ok": false, "error": "unknown order '%s'; known: %s" % [what, COMMANDS]}
	if match_node == null or not is_instance_valid(match_node):
		return {"ok": false, "error": "no match is running"}
	var result = await call("_do_" + what, order)
	if result == null:
		result = {"ok": true}
	if recorder != null and what not in ["state", "wait", "screenshot"]:
		recorder.note_command(order, result)
	return result


func _units_of(order, key = "units"):
	return find_units(
		order.get(key, "own:combat"),
		order.get("near"),
		float(order.get("radius", INF)),
		int(order.get("limit", 0))
	)


func _handler():
	return UnitCommandHandler.of(get_tree())


func _select_units(units):
	MatchSignals.deselect_all_units.emit()
	for unit in units:
		var selection = unit.find_child("Selection")
		if selection != null:
			selection.select()
	return units.filter(func(unit): return unit.is_in_group("selected_units"))


func _do_select(order):
	var units = _units_of(order)
	if order.get("via", "") == "mouse":
		return await _select_with_mouse(units)
	var selected = _select_units(units)
	return {"ok": not selected.is_empty(), "selected": selected.size()}


func _select_with_mouse(units):
	"""a click on one unit or a box drag around several, as a player would"""
	if units.is_empty() or mouse == null:
		return {"ok": false, "error": "nothing to select"}
	MatchSignals.deselect_all_units.emit()
	var camera = get_viewport().get_camera_3d()
	var center = Vector3.ZERO
	for unit in units:
		center += unit.global_position
	center /= units.size()
	camera.set_position_safely(center)
	await _frames(2)
	if units.size() == 1:
		await mouse.click(camera.unproject_position(units[0].global_position + Vector3.UP * 0.3))
	else:
		var points = units.map(func(unit): return camera.unproject_position(unit.global_position))
		var top_left = points[0]
		var bottom_right = points[0]
		for point in points:
			top_left = Vector2(min(top_left.x, point.x), min(top_left.y, point.y))
			bottom_right = Vector2(max(bottom_right.x, point.x), max(bottom_right.y, point.y))
		await mouse.drag(top_left - Vector2(25, 25), bottom_right + Vector2(25, 25))
	await _frames(2)
	var selected = units.filter(func(unit): return unit.is_in_group("selected_units"))
	return {"ok": selected.size() == units.size(), "selected": selected.size()}


func _select_for(order):
	var units = _units_of(order)
	if units.is_empty():
		return []
	return _select_units(units)


func _do_move(order):
	var units = _select_for(order)
	if units.is_empty():
		return {"ok": false, "error": "no units match %s" % [order.get("units")]}
	var point = ground(order["to"], order.get("offset"))
	if not _all_controlled(units):
		UnitCommands.point_order(units, point, "move", order.get("queue", false))
	elif order.get("queue", false):
		_handler().issue_at("move", point, true)
	else:
		MatchSignals.terrain_targeted.emit(point)  # what a right-click on the ground sends
	return {"ok": true, "units": units.size()}


func _do_attack(order):
	var units = _select_for(order)
	var targets = find_units(order.get("target"))
	if units.is_empty() or targets.is_empty():
		return {"ok": false, "error": "need units and a target"}
	MatchSignals.unit_targeted.emit(targets[0])  # what a right-click on an enemy sends
	return {"ok": true, "units": units.size(), "target": targets[0].get_instance_id()}


func _do_fight(order):
	return _point_command("fight", order)


func _do_guard(order):
	var targets = find_units(order.get("target"))
	if targets.is_empty():
		return {"ok": false, "error": "guard needs a target"}
	order = order.duplicate()
	order["to"] = [targets[0].global_position.x, targets[0].global_position.z]
	return _point_command("guard", order)


func _point_command(kind, order):
	var units = _select_for(order)
	if units.is_empty():
		return {"ok": false, "error": "no units match %s" % [order.get("units")]}
	var point = ground(order["to"], order.get("offset"))
	var queue = order.get("queue", false)
	if not _all_controlled(units):
		# AI units: the handler only orders the player's own, so call the same orders directly
		match kind:
			"fight":
				UnitCommands.fight(units, point, queue)
			"patrol":
				UnitCommands.patrol(units, [point], queue)
			_:
				UnitCommands.point_order(units, point, "move", queue)
		return {"ok": true, "units": units.size()}
	var ok = _handler().issue_at(kind, point, queue)
	return {"ok": ok, "units": units.size()}


func _all_controlled(units):
	return units.all(func(unit): return unit.is_in_group("controlled_units"))


func _do_patrol(order):
	var units = _select_for(order)
	if units.is_empty():
		return {"ok": false, "error": "no units match %s" % [order.get("units")]}
	var points = order.get("points", [order.get("to")])
	var queue = order.get("queue", false)
	if not _all_controlled(units):
		UnitCommands.patrol(units, points.map(ground), queue)
		return {"ok": true, "units": units.size()}
	for index in range(points.size()):
		_handler().issue_at("patrol", ground(points[index]), queue or index > 0)
	return {"ok": true, "units": units.size()}


func _do_line(order):
	var units = _select_for(order)
	if units.is_empty():
		return {"ok": false, "error": "no units match %s" % [order.get("units")]}
	if order.get("via", "") == "mouse":
		return await _line_with_mouse(order)
	var path = [ground(order["from"]), ground(order["to"])]
	var pairs = _handler().issue_line(order.get("kind", "move"), path, order.get("queue", false))
	return {
		"ok": not pairs.is_empty(),
		"units": units.size(),
		"slots": pairs.map(func(pair): return [snapped(pair[1].x, 0.01), snapped(pair[1].z, 0.01)])
	}


func _line_with_mouse(order):
	"""holds the right button and drags, as a player draws a line"""
	var camera = get_viewport().get_camera_3d()
	var from = ground(order["from"])
	var to = ground(order["to"])
	# zoomed out, so both ends land on the map and not on the side panels (the city panel
	# covers the right of the screen); the player's zoom comes back afterwards
	var old_size = camera.size
	camera.set_size_safely(camera.size_max)
	camera.set_position_safely((from + to) / 2.0)
	await _frames(2)
	await mouse.drag(
		camera.unproject_position(from), camera.unproject_position(to), MOUSE_BUTTON_RIGHT, 8
	)
	camera.set_size_safely(old_size)
	return {"ok": true}


func _do_patrol_base(order):
	return _instant("patrol_base", order)


func _do_stop(order):
	return _instant("stop", order)


func _do_retreat(order):
	return _instant("retreat", order)


func _do_hold_position(order):
	var units = _select_for(order)
	if units.is_empty():
		return {"ok": false, "error": "no units"}
	var hold = UnitCommands.toggle_hold_position(units)
	if order.has("on") and hold != order["on"]:
		hold = UnitCommands.toggle_hold_position(units)
	return {"ok": true, "hold": hold}


func _do_stance(order):
	var units = _select_for(order)
	if units.is_empty():
		return {"ok": false, "error": "no units"}
	var names = ["at_will", "return", "hold"]
	var wanted = names.find(order.get("stance", "at_will"))
	if wanted == -1:
		return {"ok": false, "error": "stance is at_will, return or hold"}
	UnitCommands.set_fire_stance(units, wanted)
	return {"ok": true}


func _instant(kind, order):
	var units = _select_for(order)
	if units.is_empty():
		return {"ok": false, "error": "no units match %s" % [order.get("units")]}
	_handler().run_instant(kind)
	return {"ok": true, "units": units.size()}


func _do_build(order):
	"""picks the structure in the build menu, points at the spot and clicks, like a player"""
	var builders = _units_of(order, "builder") if order.has("builder") else []
	if builders.is_empty():
		builders = find_units("own:worker", null, INF, 1)
	if builders.is_empty():
		return {"ok": false, "error": "no constructor to build with"}
	var entry = GameData.unit_by_id(order.get("structure", ""))
	if entry == null or entry.get("category") != "structure":
		return {"ok": false, "error": "unknown structure '%s'" % order.get("structure")}
	var player = builders[0].player
	var handler = player.find_child("StructurePlacementHandler")
	_select_units([builders[0]])
	await _frames(1)
	MatchSignals.place_structure.emit(load(entry["scene"]))
	await _frames(1)
	var camera = get_viewport().get_camera_3d()
	var spot = ground(order.get("spot", "base"), order.get("offset"))
	camera.set_position_safely(spot)
	await _frames(2)
	var screen = camera.unproject_position(spot)
	await mouse.move(screen + Vector2(12, 6))
	await mouse.move(screen)
	await _frames(1)
	var validity = handler._calculate_blueprint_position_validity()
	var tries = 1
	if order.get("search", false):
		# like a player nudging the blueprint around until it turns green
		for ring in [2.5, 5.0, 7.5, 10.0]:
			for step in range(8):
				if validity == 0:
					break
				var nearby = spot + Vector3(ring, 0, 0).rotated(Vector3.UP, step * PI / 4.0)
				screen = camera.unproject_position(ground(nearby))
				await mouse.move(screen)
				await _frames(1)
				validity = handler._calculate_blueprint_position_validity()
				tries += 1
	var before = _structures_of(player)
	await mouse.button(MOUSE_BUTTON_LEFT, true)
	await mouse.button(MOUSE_BUTTON_LEFT, false)
	await _frames(2)
	var built = _structures_of(player).filter(func(unit): return not unit in before)
	if handler._structure_placement_started():
		await mouse.click(screen, MOUSE_BUTTON_RIGHT)  # a player cancels with a right-click
	if built.is_empty():
		return {
			"ok": false,
			"error": "placement refused: " + VALIDITY_NAMES[validity],
			"reason": VALIDITY_NAMES[validity],
			"tries": tries,
		}
	var site = built[0]
	return {
		"ok": true,
		"tries": tries,
		"id": site.get_instance_id(),
		"x": snapped(site.global_position.x, 0.01),
		"z": snapped(site.global_position.z, 0.01)
	}


func _do_extract(order):
	"""hovers the closest free deposit of a kind with a constructor selected and clicks, the
	way the tooltip tells players to build extractors"""
	var builders = _units_of(order, "builder") if order.has("builder") else []
	if builders.is_empty():
		builders = find_units("own:worker", null, INF, 1)
	if builders.is_empty():
		return {"ok": false, "error": "no constructor to build with"}
	var builder = builders[0]
	var deposit = free_deposit(str(order.get("resource", "iron")), builder.global_position)
	if deposit == null:
		return {"ok": false, "error": "no free %s deposit" % order.get("resource", "iron")}
	var handler = builder.player.find_child("StructurePlacementHandler")
	_select_units([builder])
	var camera = get_viewport().get_camera_3d()
	camera.set_position_safely(deposit.global_position)
	await _frames(2)
	var screen = camera.unproject_position(deposit.global_position)
	var towards = camera.unproject_position(builder.global_position) - screen
	var offset = towards.normalized() * 6.0 if towards.length() > 1 else Vector2(6, 4)
	await mouse.move(screen + offset * 3.0)
	await mouse.move(screen + offset, 3)
	await _frames(3)
	if handler.get("_auto_deposit") != deposit:
		return {"ok": false, "error": "hovering the deposit did not pick an extractor"}
	var validity = handler._calculate_blueprint_position_validity()
	var before = _structures_of(builder.player)
	await mouse.button(MOUSE_BUTTON_LEFT, true)
	await mouse.button(MOUSE_BUTTON_LEFT, false)
	await _frames(2)
	var built = _structures_of(builder.player).filter(func(unit): return not unit in before)
	await mouse.move(screen + offset * 12.0, 2)  # move off, so the hover does not pick again
	if built.is_empty():
		return {
			"ok": false,
			"error": "placement refused: " + VALIDITY_NAMES[validity],
			"reason": VALIDITY_NAMES[validity]
		}
	return {"ok": true, "id": built[0].get_instance_id(), "kind": kind_of(built[0])}


func free_deposit(kind, from):
	var best = null
	for deposit in get_tree().get_nodes_in_group("deposits"):
		if deposit.kind != kind or not deposit.is_inside_tree():
			continue
		var taken = get_tree().get_nodes_in_group("units").any(
			func(unit):
				return (
					unit is Extractor
					and (
						unit.global_position.distance_to(deposit.global_position)
						< deposit.radius + unit.radius + 1.5
					)
				)
		)
		if taken:
			continue
		var distance = deposit.global_position.distance_to(from)
		if best == null or distance < best[0]:
			best = [distance, deposit]
	return best[1] if best != null else null


func _structures_of(player):
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player and unit is Structure
	)


func _do_produce(order):
	var entry = GameData.unit_by_id(order.get("unit", ""))
	if entry == null:
		return {"ok": false, "error": "unknown unit '%s'" % order.get("unit")}
	var producers = find_units(order.get("producer", "own:structures")).filter(
		func(unit):
			return (
				unit.get("production_queue") != null
				and (
					entry["id"]
					in GameData.producible_by(kind_of(unit)).map(func(e): return e["id"])
				)
			)
	)
	if producers.is_empty():
		return {"ok": false, "error": "nothing here can produce %s" % entry["id"]}
	var queued = 0
	for _i in range(int(order.get("count", 1))):
		var producer = producers[queued % producers.size()]
		if producer.production_queue.produce(load(entry["scene"])) == null:
			break
		queued += 1
	return {"ok": queued > 0, "queued": queued}


func _do_helper(order):
	var helper = Helper.of(human())
	if helper == null:
		return {"ok": false, "error": "this match has no helper"}
	var panel = match_node.find_child("HelperPanel", true, false)
	var on = order.get("on", true)
	if panel != null and panel.get("_switch") != null:
		panel.get("_switch").button_pressed = on  # the switch in the helper panel
	else:
		helper.enabled = on
	if order.has("army"):
		helper.army_target = int(order["army"])
	if order.has("scouting"):
		helper.scouting = order["scouting"]
	return {"ok": helper.enabled == on}


func _do_auto_expand(order):
	var units = find_units(order.get("units", "own:worker"))
	for unit in units:
		AutoExpand.set_enabled_on(unit, order.get("on", true))
	return {"ok": not units.is_empty(), "units": units.size()}


func _do_speed(order):
	Engine.time_scale = clamp(float(order.get("x", 1.0)), 0.1, 32.0)
	Engine.max_physics_steps_per_frame = max(8, int(ceil(Engine.time_scale * 4)))
	return {"ok": true, "speed": Engine.time_scale}


func _do_camera(order):
	var camera = get_viewport().get_camera_3d()
	if camera == null or not camera.has_method("set_position_safely"):
		return {"ok": false, "error": "no match camera"}
	var target = order.get("spot")
	if order.has("follow"):
		var units = find_units(order["follow"])
		if not units.is_empty():
			target = units[0].global_position
	if target == null:
		return {"ok": false, "error": 'camera needs "spot" or "follow"'}
	camera.set_position_safely(ground(target) if not target is Vector3 else target)
	return {"ok": true}


func _do_click(order):
	var at = _screen_point(order)
	var button = {"left": MOUSE_BUTTON_LEFT, "right": MOUSE_BUTTON_RIGHT}.get(
		order.get("button", "left"), MOUSE_BUTTON_LEFT
	)
	await mouse.click(at, button, order.get("shift", false))
	var hovered = get_viewport().gui_get_hovered_control()
	return {"ok": true, "x": at.x, "y": at.y, "hovered": hovered.name if hovered != null else null}


func _do_drag(order):
	var camera = get_viewport().get_camera_3d()
	var from = _vec2(order["from"])
	var to = _vec2(order["to"])
	if order.get("world", false):
		from = camera.unproject_position(ground(from))
		to = camera.unproject_position(ground(to))
	var button = MOUSE_BUTTON_RIGHT if order.get("button", "left") == "right" else MOUSE_BUTTON_LEFT
	await mouse.drag(from, to, button, 8, order.get("shift", false))
	return {"ok": true}


func _screen_point(order):
	if order.has("world"):
		var camera = get_viewport().get_camera_3d()
		return camera.unproject_position(ground(order["world"]))
	return _vec2(order.get("screen", [0, 0]))


func _do_key(order):
	if order.has("action"):
		await mouse.action(order["action"])
	else:
		var keycode = OS.find_keycode_from_string(str(order.get("key", "")))
		if keycode == KEY_NONE:
			return {"ok": false, "error": "unknown key '%s'" % order.get("key")}
		await mouse.key(keycode, order.get("shift", false))
	return {"ok": true}


func _do_give(order):
	var player = _player_for(str(order.get("player", "own")))
	if player == null:
		return {"ok": false, "error": "no such player"}
	player.add_resources(order.get("resources", {}))
	return {"ok": true, "stock": player.get_stock()}


func _do_spawn(order):
	"""test setup only: puts units on the map like the sandbox panel does"""
	var player = _player_for(str(order.get("player", "own")))
	var entry = GameData.unit_by_id(order.get("unit", ""))
	if player == null or entry == null:
		return {"ok": false, "error": "spawn needs a player and a unit id"}
	var center = ground(order.get("spot", "base"), order.get("offset"))
	var count = int(order.get("count", 1))
	var spacing = float(order.get("spacing", 2.5))
	var columns = int(ceil(sqrt(count)))
	var ids = []
	for index in range(count):
		var offset = Vector3(
			(index % columns - (columns - 1) / 2.0) * spacing,
			0,
			(index / columns - (columns - 1) / 2.0) * spacing
		)
		var unit = load(entry["scene"]).instantiate()
		if unit is Structure:
			unit.set_meta("spawn_constructed", true)
		MatchSignals.setup_and_spawn_unit.emit(
			unit, Transform3D(Basis(), (center + offset) * Vector3(1, 0, 1)), player
		)
		ids.append(unit.get_instance_id())
	return {"ok": true, "ids": ids}


func _do_declare_war(order):
	var a = _player_for(str(order.get("player", "own")))
	var b = _player_for(str(order.get("on", "p1")))
	if Diplomacy.instance == null or a == null or b == null:
		return {"ok": false, "error": "need two players and diplomacy"}
	Diplomacy.instance.declare_war(a, b)
	return {"ok": Diplomacy.at_war(a, b)}


func _do_weather(order):
	var atmosphere = match_node.find_child("Atmosphere", true, false)
	if atmosphere == null:
		return {"ok": false, "error": "this map has no weather"}
	atmosphere.set_weather_immediately(StringName(order.get("set", "clear")))
	return {"ok": true}


func _do_reveal(_order):
	var fog = match_node.find_child("FogOfWar", true, false)
	if fog != null:
		fog.reveal()
	return {"ok": fog != null}


func _do_screenshot(order):
	if recorder == null:
		return {"ok": false, "error": "no recorder"}
	var path = await recorder.screenshot(str(order.get("name", "shot")))
	return {"ok": path != "", "path": path}


func _do_wait(order):
	var until = elapsed_s + float(order.get("seconds", 1.0))
	while elapsed_s < until and not ended:
		await get_tree().physics_frame
	return {"ok": true, "t": elapsed_s}


func _do_state(order):
	return {"ok": true, "state": state(order.get("units", true))}


func _do_save(order):
	var path = SaveGame.save_match(match_node, order.get("name", "harness"))
	if path == "":
		return {"ok": false, "error": "could not write the save"}
	return {"ok": true, "path": path, "units": SaveGame.read(path)["units"].size()}


func _do_reload(order):
	"""saves the match, throws it away and loads the save into a fresh match, the way the
	pause menu's Save and Load do; ok when every unit, stock and city came back the same"""
	var save_name = order.get("name", "harness-reload")
	var before = save_summary()
	var path = SaveGame.save_match(match_node, save_name)
	var data = SaveGame.read(path)
	if not order.get("keep", false):
		SaveGame.delete(path)  # a test's save stays out of the player's Load game list
	if data == null:
		return {"ok": false, "error": "the save could not be read back"}
	var old_match = match_node
	var speed = Engine.time_scale
	old_match.get_parent().remove_child(old_match)
	old_match.free()
	await get_tree().process_frame
	var new_match = load("res://source/match/Match.tscn").instantiate()
	new_match.settings = SaveGame.settings_from(data)
	new_match.map = load(data["map"]).instantiate()
	new_match.saved_state = data
	get_tree().root.add_child(new_match)
	get_tree().current_scene = new_match
	await MatchSignals.match_loaded
	match_node = new_match
	var after = save_summary()
	Engine.time_scale = speed
	match_replaced.emit(new_match)
	var differences = []
	for key in before:
		if str(before[key]) != str(after.get(key)):
			differences.append("%s: %s before, %s after" % [key, before[key], after.get(key)])
	return {
		"ok": differences.is_empty(),
		"path": path,
		"units": data["units"].size(),
		"error": "; ".join(differences),
	}


func save_summary():
	"""what a save must bring back: units by kind, stock, city tier and population per player"""
	var out = {}
	var all_players = players()
	for index in range(all_players.size()):
		var player = all_players[index]
		var kinds = {}
		for unit in get_tree().get_nodes_in_group("units"):
			if unit.player == player and not unit.is_queued_for_deletion():
				var kind = kind_of(unit)
				kinds[kind] = kinds.get(kind, 0) + 1
		var sorted_kinds = kinds.keys()
		sorted_kinds.sort()
		out["p%d units" % index] = sorted_kinds.map(
			func(kind): return "%s=%d" % [kind, kinds[kind]]
		)
		var stock = player.get_stock()
		out["p%d stock" % index] = stock.keys().map(
			func(key): return "%s=%d" % [key, roundi(stock[key])]
		)
		if player.city != null:
			out["p%d city" % index] = (
				"tier %d, population %d, %d houses"
				% [player.city.tier, int(player.city.population), player.city._buildings.size()]
			)
	return out


func _do_end(order):
	ended = true
	return {"ok": true, "reason": order.get("reason", "ended by a command")}


func ground(value, offset = null):
	"""a map point from [x, z], or from a unit selector ("base" is the own command center)"""
	var point = Vector3.ZERO
	if value is Dictionary:  # {"of": "base" or a selector, "offset": [x, z]}
		return ground(value.get("of", "base"), value.get("offset", offset))
	if value is String:
		var units = find_units("own:command_center" if value == "base" else value)
		point = units[0].global_position * Vector3(1, 0, 1) if not units.is_empty() else point
	else:
		point = _vec3(value)
	if offset != null:
		point += _vec3(offset)
	if match_node != null and match_node.map != null:
		var size = match_node.map.size
		point.x = clamp(point.x, 0.5, size.x - 0.5)
		point.z = clamp(point.z, 0.5, size.y - 0.5)
	return point


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
