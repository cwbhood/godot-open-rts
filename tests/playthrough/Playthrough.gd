extends Node

# Plays a whole match as the human player against AI personalities, through the same
# input paths a person uses: mouse clicks on units, the unit menus and the HUD, hovering
# deposits, box selection and right-click orders. It watches for script errors, failed
# placements, stuck units, unbuilt sites and broken HUD, and saves screenshots.
#
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . \
#     res://tests/playthrough/Playthrough.tscn -- --map=plain_and_simple \
#     --ai=balanced,raider --minutes=25 --out=/tmp/play
#
# The match is started from the real Play menu. Writes report.json and report.txt to
# --out and exits with code 1 when it found problems. A crash, freeze or error storm also
# leaves crash_report.txt/json in --out (see source/crash/CrashReporter.gd); after a hard
# crash it appears there on the next Godot launch, or run tools/crash/Collect.tscn.
#
# --helper=on switches the player's helper on through its HUD switch after the opening
# and stops the bot from attacking, so the match shows what the helper does alone: it
# reports a bug when the player's side starts a war or loses a constructor to an enemy
# the helper knew about.
#
# --rules=raw|guided picks the match rules preset in the Play menu (default: whatever the
# menu remembers). With auto-build or AI assist off the bot builds everything by hand.
#
# --faction=foundry|syndicate picks the player's faction in the Play menu (default: the
# menu's, the Foundry League). The bot builds from that faction's roster, tries every
# combat unit of it at least once and reports in stats.roster which ones it got.

const Human = preload("res://source/match/players/human/Human.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Drone = preload("res://source/match/units/Drone.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const AutoExpand = preload("res://source/match/units/traits/AutoExpand.gd")
const Helper = preload("res://source/match/players/human/Helper.gd")
const Trade = preload("res://source/match/city/Trade.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const GameData = preload("res://source/data-model/GameData.gd")
const PlayScene = preload("res://source/main-menu/Play.tscn")
const Factions = preload("res://source/data-model/Factions.gd")

const UNITS = "res://source/match/units/"
const MINE = UNITS + "Mine.tscn"
const LUMBER_MILL = UNITS + "LumberMill.tscn"
const OIL_DERRICK = UNITS + "OilDerrick.tscn"
const POWER_PLANT = UNITS + "PowerPlant.tscn"
const PYLON = UNITS + "Pylon.tscn"
const VEHICLE_FACTORY = UNITS + "VehicleFactory.tscn"
const AIRCRAFT_FACTORY = UNITS + "AircraftFactory.tscn"
const AIRPORT = UNITS + "Airport.tscn"
const AG_TURRET = UNITS + "AntiGroundTurret.tscn"  # without a faction, see _role_scene
const WEATHERS = [&"clear", &"overcast", &"rain", &"sandstorm"]
const STUCK_WINDOW_S = 45.0
const SITE_STALL_S = 240.0


class ErrorLogger:
	extends Logger
	var mutex = Mutex.new()
	var errors = {}  # message -> count
	var warnings = {}

	func _log_error(
		function, file, line, code, rationale, _editor_notify, error_type, _script_backtraces
	):
		var text = "{0} ({1}:{2} {3})".format(
			[rationale if rationale != "" else code, file.get_file(), line, function]
		)
		if "shader_cache" in text or "status < 0" in text:
			return
		mutex.lock()
		var bucket = warnings if error_type == ERROR_TYPE_WARNING else errors
		bucket[text] = bucket.get(text, 0) + 1
		mutex.unlock()

	func _log_message(_message, _error):
		pass


var _args = {
	"map": "plain_and_simple",
	"ai": "balanced",
	"minutes": "25",
	"out": "user://playthrough",
	"shots-every": "180",
	"seed": "1",
	"steps": "24",  # physics steps per rendered frame, so game time keeps up on slow GPUs
	"helper": "off",
	"rules": "",  # "raw" or "guided", see source/data-model/MatchRules.gd
	"faction": "",  # "foundry" or "syndicate"; empty keeps the Play menu's default
}
var _logger = ErrorLogger.new()
var _match = null
var _human = null
var _camera = null
var _handler = null
var _elapsed_s = 0.0
var _findings = []  # {kind, text, t, shot}
var _finding_keys = {}
var _stats = {"placements_ok": {}, "placements_failed": {}, "clicks_missed": 0, "trades": {}}
var _timeline = []
var _positions = {}  # unit -> [[t, pos], ...]
var _reported_stuck = {}
var _site_seen = {}  # site -> first seen time
var _reported_sites = {}
var _result = "time limit"
var _shot_index = 0
var _next_shot_s = 0.0
var _weather_index = 0
var _rng = RandomNumberGenerator.new()
var _finished = false
var _doing = "starting"  # last bot step, for the hang watchdog
var _watchdog = Thread.new()
var _frames_seen = 0


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	_rng.seed = int(_args["seed"])
	Engine.max_physics_steps_per_frame = int(_args["steps"])
	DirAccess.make_dir_recursive_absolute(_args["out"])
	OS.add_logger(_logger)
	# a frozen match writes a crash report (copied to --out) and ends the run after 3 minutes
	CrashReporter.set_hang_exit(180.0)
	_watchdog.start(_watch_main_thread)
	MatchSignals.match_finished_with_victory.connect(func(): _result = "victory")
	MatchSignals.match_finished_with_defeat.connect(func(): _result = "defeat")
	_say("start map=%s ai=%s minutes=%s" % [_args["map"], _args["ai"], _args["minutes"]])
	await _start_from_menu()
	if _match == null:
		_finding("menu", "the match did not start from the Play menu")
		_finish()
		return
	await _play()
	_finish()


# --- starting the match through the menu


func _start_from_menu():
	var play = PlayScene.instantiate()
	get_tree().root.add_child.call_deferred(play)
	await _frames(10)
	var map_list = play.find_child("MapList")
	var map_paths = play.get("_map_paths")
	var wanted = -1
	for index in range(map_paths.size()):
		if Constants.Match.MAPS[map_paths[index]].get("id", "") == _args["map"]:
			wanted = index
		elif map_paths[index].get_file().get_basename().to_snake_case() == _args["map"]:
			wanted = index
	if wanted == -1:
		_say("unknown map " + _args["map"])
		return
	map_list.select(wanted)
	map_list.item_selected.emit(wanted)
	var personalities = play.get("_ai_personalities")
	var options = play.find_child("GridContainer").find_children("OptionButton*")
	var ais = _args["ai"].split(",")
	for index in range(options.size()):
		var option = options[index]
		if not option.visible:
			continue
		var choice = Constants.PlayerType.NONE
		if index == 0:
			choice = Constants.PlayerType.HUMAN
		elif index - 1 < ais.size():
			choice = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI + personalities.find(ais[index - 1])
		option.select(choice)
		option.item_selected.emit(choice)
	if _args["rules"] != "":
		play.get("_rules_options").select_preset(_args["rules"])
	if _args["faction"] != "":
		var faction_button = play.find_child("FactionButton0", true, false)
		var faction_index = Factions.ids().find(_args["faction"])
		if faction_button == null or faction_index < 0:
			_finding("menu", "cannot pick faction %s in the Play menu" % _args["faction"])
		else:
			faction_button.select(faction_index)
			faction_button.item_selected.emit(faction_index)
	await _frames(5)
	var start = play.find_child("StartButton")
	if not await _click_control(start, "Play menu start button"):
		start.pressed.emit()
	for _i in range(600):
		await _frames(1)
		var picker = get_tree().root.get_node_or_null("StartPicker")
		if picker != null and not picker.get("_started"):
			# the start-zone screen: take the slot's own zone, as the countdown would
			await _frames(5)
			picker.start_match()
		for child in get_tree().root.get_children():
			if child.name == "Match" or child.get_script() == load("res://source/match/Match.gd"):
				_match = child
		if _match != null and _match.is_node_ready():
			break
	if _match == null:
		return
	await _frames(30)
	var humans = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)
	_human = humans[0]
	_camera = get_viewport().get_camera_3d()
	_handler = _human.find_child("StructurePlacementHandler")
	_stats["faction"] = _human.faction
	_stats["roster"] = {}
	for entry in _roster():
		_stats["roster"][entry["id"]] = 0
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	var weather = _atmosphere()
	_say(
		(
			"match started: %d players, weather node %s"
			% [get_tree().get_nodes_in_group("players").size(), weather != null]
		)
	)


# --- the human's game plan


func _play():
	var limit_s = float(_args["minutes"]) * 60.0
	var start_ms = Time.get_ticks_msec()
	await _shot("00-start")
	await _opening()
	var next_think = 0.0
	while _elapsed_s < limit_s and _result == "time limit":
		await _wait_s(1.0)
		if _elapsed_s >= next_think:
			next_think = _elapsed_s + 8.0
			await _think()
		if _elapsed_s >= _next_shot_s:
			_next_shot_s += float(_args["shots-every"])
			await _shot("t%04d" % int(_elapsed_s))
	_say(
		(
			"played %.0f s of game time in %.0f s"
			% [_elapsed_s, (Time.get_ticks_msec() - start_ms) / 1000.0]
		)
	)
	await _shot("99-end")


func _opening():
	var workers = _own_units(func(unit): return unit is Worker)
	if workers.is_empty():
		_finding("start", "no constructors at the start")
		return
	var builder = workers[0]
	# iron mine by hovering the deposit, as the tooltip tells players
	await _place_extractor_by_hover(builder, "iron")
	await _place_extractor_by_hover(builder, "timber")
	# copper with the menu button instead
	await _place_from_menu(builder, MINE, _deposit_spot("copper", builder.global_position))
	await _place_from_menu(builder, POWER_PLANT, _free_spot_near(_base(), 9.0))
	await _place_extractor_by_hover(builder, "oil")
	if workers.size() > 1 and _match.settings.auto_build:
		await _toggle_auto_expand(workers[1], true)
	if _args["helper"] == "on" and _match.settings.ai_assist:
		await _switch_helper_on()
	await _shot("01-opening")


func _think():
	_sample_stuck_units()
	_check_sites()
	_check_hud()
	_log_economy()
	var stock = _human.get_stock()
	var workers = _own_units(func(unit): return unit is Worker)
	var builder = null
	for worker in workers:
		if not AutoExpand.is_enabled_on(worker):
			builder = worker
			break
	_doing = "build"
	if workers.is_empty() and _has(stock, {"iron": 4, "oil": 2}):
		await _produce_at(_base(), UNITS + "Worker.tscn")
	if builder != null and _idle(builder):
		await _next_building(builder, stock)
	_doing = "produce"
	await _produce_army(stock)
	_doing = "trade"
	if int(_elapsed_s) % 64 < 8:
		await _trade_round()
	_doing = "diplomacy"
	if int(_elapsed_s) % 150 < 8:
		await _diplomacy_round()
	if int(_elapsed_s) % 120 < 8:
		await _cycle_weather()
	if _args["helper"] == "on" and _match.settings.ai_assist:
		_doing = "helper"
		_check_helper()
	else:
		_doing = "attack"
		await _maybe_attack()
	_doing = "answer offers"
	await _answer_offers()
	_doing = "waiting"


func _next_building(builder, stock):
	var have = func(scene): return _count_own(scene)
	var plan = []
	if have.call(MINE) < 2:
		plan.append([MINE, _deposit_spot("iron", builder.global_position)])
	if have.call(POWER_PLANT) < 1:
		plan.append([POWER_PLANT, _free_spot_near(_base(), 9.0)])
	if have.call(VEHICLE_FACTORY) < 1:
		plan.append([VEHICLE_FACTORY, _free_spot_near(_base(), 12.0)])
	if have.call(AIRPORT) < 1:
		plan.append([AIRPORT, _free_spot_near(_base(), 14.0)])
	if have.call(OIL_DERRICK) < 2:
		plan.append([OIL_DERRICK, _deposit_spot("oil", builder.global_position)])
	if have.call(LUMBER_MILL) < 2:
		plan.append([LUMBER_MILL, _deposit_spot("timber", builder.global_position)])
	if have.call(MINE) < 4:
		plan.append([MINE, _deposit_spot("iron", builder.global_position)])
	if _human.has_tier(2) and have.call(AIRCRAFT_FACTORY) < 1:
		plan.append([AIRCRAFT_FACTORY, _free_spot_near(_base(), 16.0)])
	var turret = _role_scene("ag_turret", AG_TURRET)
	if have.call(turret) < 2 and _elapsed_s > 300:
		plan.append([turret, _free_spot_near(_base(), 11.0)])
	var aa_turret = _role_scene("aa_turret", null)
	if aa_turret != null and _human.has_tier(2) and have.call(aa_turret) < 1:
		plan.append([aa_turret, _free_spot_near(_base(), 12.0)])
	var foundry = _role_scene("production_boost", null)
	var factory = _own_constructed(VEHICLE_FACTORY)
	if foundry != null and factory != null and have.call(foundry) < 1:
		plan.append([foundry, _free_spot_near(factory, 4.0)])
	var trading_post = _role_scene("trade_depot", null)
	if trading_post != null and have.call(trading_post) < 1 and _elapsed_s > 200:
		plan.append([trading_post, _free_spot_near(_base(), 15.0)])
	if have.call(POWER_PLANT) < 2 and _elapsed_s > 400:
		plan.append([POWER_PLANT, _free_spot_near(_base(), 15.0)])
	for step in plan:
		if step[1] == null:
			continue
		var cost = Constants.Match.Units.CONSTRUCTION_COSTS[step[0]]
		if not _has(stock, cost) or not _human.can_produce(step[0]):
			continue
		await _place_from_menu(builder, step[0], step[1])
		return


func _produce_army(stock):
	var factory = _own_constructed(VEHICLE_FACTORY)
	if factory != null and _queue_size(factory) < 2:
		for scene in _army_choices("vehicle_factory"):
			if _human.can_produce(scene) and _has(stock, _cost(scene)):
				await _produce_at(factory, scene)
				break
	var air = _own_constructed(AIRCRAFT_FACTORY)
	if air != null and _queue_size(air) < 1:
		for scene in _army_choices("aircraft_factory"):
			if _human.can_produce(scene) and _has(stock, _cost(scene)):
				await _produce_at(air, scene)
				break
	var base = _base()
	if base != null and _queue_size(base) < 1:
		var drones = _own_units(func(unit): return unit is Drone).size()
		var haulers = _own_units(func(unit): return unit is Hauler).size()
		var extractors = _own_units(func(unit): return unit is Extractor).size()
		if haulers < 2 + extractors / 2 and _has(stock, _cost(UNITS + "Hauler.tscn")):
			await _produce_at(base, UNITS + "Hauler.tscn")
		elif _own_units(func(unit): return unit is Worker).size() < 3 and _elapsed_s > 240:
			await _produce_at(base, UNITS + "Worker.tscn")
		elif drones < 2 and _human.can_produce(UNITS + "Drone.tscn"):
			await _produce_at(base, UNITS + "Drone.tscn")


func _roster():
	"""what the player's faction can make in its factories and with constructors"""
	var entries = []
	for producer in ["worker", "vehicle_factory", "aircraft_factory", "command_center"]:
		for entry in GameData.producible_by(producer, _human.faction):
			if not entry in entries:
				entries.append(entry)
	return entries


func _role_scene(role, fallback):
	var path = Factions.role_scene(_human.faction, role)
	return path if path != null else fallback


func _army_choices(producer_id):
	"""combat units of the roster: ones never built yet first, then the strongest"""
	var entries = GameData.producible_by(producer_id, _human.faction).filter(
		func(entry):
			return (
				entry.get("category") == "unit"
				and entry.get("properties", {}).get("attack_damage") != null
				and entry.get("movement", "land") != "water"
			)
	)
	entries.sort_custom(
		func(a, b): return Utils.Dict.sum(a.get("cost", {})) > Utils.Dict.sum(b.get("cost", {}))
	)
	var untried = entries.filter(func(entry): return _stats["roster"].get(entry["id"], 0) == 0)
	if _rng.randf() < 0.3:
		entries.shuffle()
	return (untried + entries).map(func(entry): return entry["scene"])


func _is_army(unit):
	var entry = GameData.unit_by_scene(unit._scene_path())
	return (
		entry != null
		and entry.get("category") == "unit"
		and unit.get("attack_damage") != null
		and not unit.is_in_group("city_defense")
		and not unit.is_in_group("caravans")
	)


func _on_unit_spawned(unit):
	if _human == null or not is_instance_valid(unit) or unit.player != _human:
		return
	var entry = GameData.unit_by_scene(unit._scene_path())
	if entry != null and entry["id"] in _stats["roster"]:
		_stats["roster"][entry["id"]] += 1


func _switch_helper_on():
	var panel = _match.find_child("HelperPanel", true, false)
	if panel == null:
		_finding("helper", "there is no helper panel")
		return
	await _click_control(panel.get("_switch"), "helper switch")
	await _frames(4)
	var helper = Helper.of(_human)
	if helper == null or not helper.enabled:
		_finding("helper", "clicking the helper switch did not turn it on")
		return
	MatchSignals.unit_died.connect(_on_unit_died_with_helper)
	_say("helper on")


func _check_helper():
	var helper = Helper.of(_human)
	if helper == null or not helper.enabled:
		return
	for player in get_tree().get_nodes_in_group("players"):
		if player == _human or not Diplomacy.at_war(_human, player):
			continue
		if Diplomacy.instance.aggressor(_human, player) == _human:
			_finding("helper", "the player's side started a war with the helper on")
	if helper.stats["attack_orders"] > 0:
		_finding("helper", "the helper gave an attack order")
	_stats["helper"] = helper.stats.duplicate()
	_stats["helper"]["known_threats"] = helper.known_threats()


func _on_unit_died_with_helper(unit):
	if not is_instance_valid(unit) or unit.player != _human or not unit is Worker:
		return
	var helper = Helper.of(_human)
	var known = helper != null and helper.is_dangerous(unit.global_position, 6.0)
	_finding(
		"helper",
		(
			"a constructor died %s"
			% ("next to enemies the helper knew about" if known else "to enemies nobody had seen")
		),
		known
	)


func _maybe_attack():
	var army = _own_units(func(unit): return _is_army(unit) and _idle(unit))
	if army.size() < 6:
		return
	var target = _closest_enemy_target(army[0].global_position)
	if target == null:
		return
	_say(
		"attack with %d units on %s of P%d" % [army.size(), target.name, target.player.get_index()]
	)
	await _select(army)
	await _right_click_world(target.global_position, "attack order")
	_timeline.append({"t": int(_elapsed_s), "attack": army.size()})


# --- placing structures as a player does


func _place_extractor_by_hover(builder, kind):
	var deposit = _closest_free_deposit(kind, builder.global_position)
	if deposit == null:
		_finding("placement", "no free %s deposit on the map to build on" % kind, false)
		return false
	await _select([builder])
	await _look_at(deposit.global_position)
	var screen = _camera.unproject_position(deposit.global_position)
	var towards_builder = _camera.unproject_position(builder.global_position) - screen
	var offset = (
		towards_builder.normalized() * 6.0 if towards_builder.length() > 1 else Vector2(6, 4)
	)
	await _mouse_move(screen + offset)
	await _frames(6)
	await _mouse_move(screen + offset * 1.2)
	await _frames(6)
	var prototype = _handler.get("_pending_structure_prototype")
	if _handler.get("_auto_deposit") != deposit or prototype == null:
		_finding(
			"placement",
			"hovering a %s deposit with a constructor selected did not pick an extractor" % kind
		)
		await _shot("hover-%s-failed" % kind)
		return false
	return await _confirm_placement(prototype.resource_path, "hover " + kind)


func _place_from_menu(builder, scene_path, spot):
	if spot == null:
		_finding("placement", "found no spot to try %s" % scene_path.get_file(), false)
		return false
	await _select([builder])
	await _cancel_placement()
	var menu = _visible_menu_with(scene_path)
	if menu == null:
		_finding("hud", "no visible menu has a %s button" % scene_path.get_file())
		return false
	var button = menu.get("_buttons")[scene_path]
	if button.disabled:
		_say("%s button disabled (stock %s)" % [scene_path.get_file(), _human.get_stock()])
		return false
	await _look_at(spot)
	if not await _click_control(button, scene_path.get_file() + " button"):
		return false
	await _frames(4)
	if (
		_handler.get("_pending_structure_prototype") == null
		or not _handler.call("_structure_placement_started")
	):
		_finding("placement", "pressing %s did not start a blueprint" % scene_path.get_file())
		return false
	await _mouse_move(_camera.unproject_position(spot))
	await _frames(4)
	return await _confirm_placement(scene_path, "menu " + scene_path.get_file())


func _confirm_placement(scene_path, how):
	var name = scene_path.get_file().get_basename()
	var validity = _handler.call("_calculate_blueprint_position_validity")
	var reason = _handler.BlueprintPositionValidity.keys()[validity]
	if validity != _handler.BlueprintPositionValidity.VALID:
		# a player would wiggle the mouse a bit before giving up
		var base_pos = get_viewport().get_mouse_position()
		for attempt in range(8):
			var angle = attempt * TAU / 8.0
			await _mouse_move(base_pos + Vector2(cos(angle), sin(angle)) * (18 + attempt * 6))
			await _frames(3)
			validity = _handler.call("_calculate_blueprint_position_validity")
			if validity == _handler.BlueprintPositionValidity.VALID:
				break
		reason = _handler.BlueprintPositionValidity.keys()[validity]
	if validity != _handler.BlueprintPositionValidity.VALID:
		_bump(_stats["placements_failed"], name + ":" + reason)
		if reason in ["NOT_ENOUGH_RESOURCES", "TIER_TOO_LOW"]:
			await _cancel_placement()
			return false
		var label = _handler.find_child("FeedbackLabel3D")
		_finding(
			"placement",
			(
				"%s (%s) could not be placed: %s, label says '%s'"
				% [name, how, reason, label.text if label.visible else "<hidden>"]
			),
			true,
			"placement-" + name + "-" + reason
		)
		await _shot("placement-%s-%s" % [name, reason])
		await _cancel_placement()
		return false
	var before = _count_own(scene_path)
	var mouse = get_viewport().get_mouse_position()
	var over = get_viewport().gui_get_hovered_control()
	if over != null:  # a player cannot click through a panel either
		_say("%s (%s): the spot is under %s, giving up" % [name, how, over.name])
		_bump(_stats["placements_failed"], name + ":UNDER_HUD")
		await _cancel_placement()
		return false
	await _mouse_button(mouse, MOUSE_BUTTON_LEFT, true)
	await _frames(2)
	await _mouse_button(mouse, MOUSE_BUTTON_LEFT, false)
	await _frames(6)
	if _count_own(scene_path) <= before:
		_finding("placement", "%s (%s) was valid but clicking did not lay out a site" % [name, how])
		await _cancel_placement()
		return false
	_bump(_stats["placements_ok"], name)
	_say("placed %s (%s)" % [name, how])
	return true


func _cancel_placement():
	if _handler.call("_structure_placement_started"):
		await _mouse_button(get_viewport().get_mouse_position(), MOUSE_BUTTON_RIGHT, true)
		await _mouse_button(get_viewport().get_mouse_position(), MOUSE_BUTTON_RIGHT, false)
		await _frames(2)


func _toggle_auto_expand(worker, on):
	await _select([worker])
	await _frames(6)
	var bar = _match.find_child("AutoExpandBar", true, false)
	if bar == null or not bar.visible:
		_finding("hud", "the auto-expand switch is not shown for a constructor")
		return
	var toggle = bar.get("_toggle")
	if toggle.button_pressed != on:
		await _click_control(toggle, "auto-expand switch")
	await _frames(4)
	if AutoExpand.is_enabled_on(worker) != on:
		_finding("hud", "clicking the auto-expand switch did not change it")


func _produce_at(producer, scene_path):
	if producer == null:
		return false
	await _select([producer])
	await _frames(4)
	var menu = _visible_menu_with(scene_path)
	if menu == null:
		return false
	var button = menu.get("_buttons")[scene_path]
	if button.disabled:
		_say("%s button disabled (stock %s)" % [scene_path.get_file(), _human.get_stock()])
		return false
	var before = _queue_size(producer)
	if not await _click_control(button, scene_path.get_file() + " button"):
		return false
	await _frames(3)
	if _queue_size(producer) <= before:
		var stock = _human.get_stock()
		var full = _queue_size(producer) >= Constants.Match.Units.PRODUCTION_QUEUE_LIMIT
		if _has(stock, _cost(scene_path)) and not full:
			_finding("production", "clicking %s did not queue it" % scene_path.get_file())
		return false
	_say("queued " + scene_path.get_file().get_basename())
	return true


# --- trade and diplomacy through the HUD


func _trade_round():
	var hud = _match.find_child("CityHud", true, false)
	if hud == null:
		_finding("hud", "no city/trade panel")
		return
	var partners = hud.get("_partners")
	if partners.is_empty():
		return
	var stock = _human.get_stock()
	var give = Utils.Dict.items(stock)
	give.sort_custom(func(a, b): return a[1] > b[1])
	var need = Utils.Dict.items(stock)
	need.sort_custom(func(a, b): return a[1] < b[1])
	if give[0][1] < 25:
		return
	var partner_index = _rng.randi_range(0, partners.size() - 1)
	hud.get("_partner_option").select(partner_index)
	hud.get("_give_resource_option").select(Constants.Match.Resources.ALL.find(give[0][0]))
	hud.get("_get_resource_option").select(Constants.Match.Resources.ALL.find(need[0][0]))
	hud.get("_give_amount").value = 10
	hud.get("_get_amount").value = 6
	var button = hud.get("_propose_button")
	if not button.is_visible_in_tree():
		_finding("hud", "the trade propose button is not visible", false)
		button.pressed.emit()
	else:
		await _click_control(button, "trade propose button")
	await _frames(3)
	var result = hud.get("_result_label").text
	_bump(_stats["trades"], result)
	_say("trade offer %s -> %s: %s" % [give[0][0], need[0][0], result])


func _answer_offers():
	var hud = _match.find_child("CityHud", true, false)
	if hud != null and hud.get("_incoming_offer") != null:
		var box = hud.get("_offer_box")
		var accept = _find_button(box, "TRADE_ACCEPT")
		_say("incoming trade offer: " + hud.get("_offer_label").text)
		if accept != null:
			await _click_control(accept, "accept trade button")
	var dip = _match.find_child("DiplomacyHud", true, false)
	if dip != null and dip.get("_incoming") != null:
		var box = dip.get("_offer_box")
		_say("incoming diplomacy offer")
		var accept = _find_button(box, "TRADE_ACCEPT")
		if accept != null:
			await _click_control(accept, "accept treaty button")


func _diplomacy_round():
	var hud = _match.find_child("DiplomacyHud", true, false)
	var diplomacy = Diplomacy.instance
	if hud == null or diplomacy == null:
		_finding("hud", "no diplomacy bar")
		return
	var factions = hud.get("_factions")
	var chips = hud.get("_chips") if "_chips" in hud else null
	for faction in factions:
		if faction == _human:
			continue
		var state = diplomacy.get_state(_human, faction)
		if state in [Diplomacy.State.WAR, Diplomacy.State.NEUTRAL]:
			var chip = null
			if chips is Dictionary:
				chip = chips.get(faction)
			elif chips is Array:
				chip = chips[factions.find(faction)]
			if chip != null:
				await _click_control(chip, "diplomacy chip")
			else:
				hud.call("_on_chip_pressed", faction)
			await _frames(3)
			var kind = Diplomacy.KINDS[hud.get("_kind_option").selected]
			await _click_control(hud.get("_offer_button"), "treaty offer button")
			await _frames(3)
			_say(
				(
					"offered %s to P%d (%s): %s"
					% [
						kind,
						faction.get_index(),
						Diplomacy.State.keys()[state],
						hud.get("_result_label").text
					]
				)
			)
			if hud.get("_deal_box").visible:
				hud.call("_on_chip_pressed", faction)  # close
			return


func _cycle_weather():
	var atmosphere = _atmosphere()
	if atmosphere == null:
		return
	_weather_index = (_weather_index + 1) % WEATHERS.size()
	atmosphere.set_weather(WEATHERS[_weather_index], 5.0)
	_say("weather -> " + str(WEATHERS[_weather_index]))


# --- watching for problems


func _sample_stuck_units():
	for unit in _own_units(func(unit): return not unit is Structure):
		var history = _positions.get(unit, [])
		history.append([_elapsed_s, unit.global_position, unit.action])
		history = history.filter(func(entry): return _elapsed_s - entry[0] <= STUCK_WINDOW_S + 10)
		_positions[unit] = history
		if history.size() < 4 or unit in _reported_stuck:
			continue
		var oldest = history[0]
		if _elapsed_s - oldest[0] < STUCK_WINDOW_S:
			continue
		var action = unit.action
		if action == null or not history.all(func(entry): return entry[2] == action):
			continue
		var moved = (
			history.map(func(entry): return entry[1].distance_to(unit.global_position)).max()
		)
		var action_name = action.get_script().resource_path.get_file().get_basename()
		if (
			moved < 0.4
			and (
				action_name
				in [
					"Moving",
					"MovingToUnit",
					"Constructing",
					"CollectingGoods",
					"Hauling",
					"Landing",
					"Following"
				]
			)
		):
			if action_name == "Constructing" and _near_site(unit):
				continue
			_reported_stuck[unit] = true
			_finding(
				"stuck",
				(
					"%s of P%d sits still for %ds while %s at %s"
					% [
						unit.name,
						unit.player.get_index(),
						STUCK_WINDOW_S,
						action_name,
						unit.global_position.snapped(Vector3.ONE * 0.1)
					]
				),
				true,
				"stuck-" + unit.scene_file_path.get_file() + action_name
			)
			await _look_at(unit.global_position)
			await _shot("stuck-%s" % unit.name)
	for unit in _positions.keys():
		if not is_instance_valid(unit):
			_positions.erase(unit)


func _near_site(unit):
	var target = unit.action.get("_target_unit") if unit.action != null else null
	return (
		target != null
		and is_instance_valid(target)
		and (
			unit.global_position.distance_to(target.global_position)
			< target.radius + unit.radius + 1.5
		)
	)


func _check_sites():
	for unit in get_tree().get_nodes_in_group("units"):
		if not unit is Structure or not unit.is_under_construction():
			continue
		if not unit in _site_seen:
			_site_seen[unit] = [_elapsed_s, unit.get_construction_progress()]
			continue
		var seen = _site_seen[unit]
		if unit in _reported_sites or _elapsed_s - seen[0] < SITE_STALL_S:
			continue
		if unit.get_construction_progress() - seen[1] < 0.01:
			_reported_sites[unit] = true
			var label = unit.get_node_or_null("SiteStatusLabel")
			_finding(
				"site",
				(
					"%s site of P%d made no progress in %ds (%s)"
					% [
						unit.name,
						unit.player.get_index(),
						SITE_STALL_S,
						label.text.replace("\n", " ") if label != null else "no label"
					]
				),
				unit.player == _human,
				"site-" + str(unit.player.get_index()) + unit.scene_file_path.get_file()
			)
		else:
			_site_seen[unit] = [_elapsed_s, unit.get_construction_progress()]


func _check_hud():
	var viewport_rect = get_viewport().get_visible_rect()
	var panels = []
	for name in [
		"CityHud", "DiplomacyHud", "ResourcesBar", "Minimap", "UnitMenus", "AutoExpandPanel"
	]:
		var node = _match.find_child(name, true, false)
		if node == null:
			continue
		var control = node if node is Control else null
		if control == null:
			for child in node.get_children():
				if child is Control and child.visible:
					control = child
					break
		if control == null or not control.is_visible_in_tree():
			continue
		var rect = control.get_global_rect()
		if rect.size.x > 2 and not viewport_rect.grow(2).encloses(rect):
			_finding(
				"hud", "%s sticks out of the screen: %s" % [name, rect], false, "hud-out-" + name
			)
		panels.append([name, rect])
	for i in range(panels.size()):
		for j in range(i + 1, panels.size()):
			var overlap = panels[i][1].intersection(panels[j][1])
			if overlap.get_area() > 400:
				_finding(
					"hud",
					(
						"%s overlaps %s (%dx%d px)"
						% [panels[i][0], panels[j][0], overlap.size.x, overlap.size.y]
					),
					false,
					"hud-overlap-" + panels[i][0] + panels[j][0]
				)


func _log_economy():
	if int(_elapsed_s) % 60 >= 8:
		return
	var line = {"t": int(_elapsed_s), "fps": Engine.get_frames_per_second(), "players": []}
	for player in get_tree().get_nodes_in_group("players"):
		var units = get_tree().get_nodes_in_group("units").filter(
			func(unit): return unit.player == player
		)
		line["players"].append(
			{
				"p": player.get_index(),
				"ai": player.get("personality_id"),
				"stock": player.get_stock(),
				"tier": player.get_tier(),
				"science": snapped(player.city.science, 0.1) if player.city != null else 0,
				"pop": snapped(player.city.population, 0.1) if player.city != null else 0,
				"units": units.filter(func(unit): return not unit is Structure).size(),
				"structures": units.filter(func(unit): return unit is Structure).size(),
				"extractors":
				units.filter(func(unit): return unit is Extractor and unit.is_constructed()).size(),
			}
		)
	_timeline.append(line)
	var summaries = line["players"].map(_player_summary)
	_say("t=%d fps=%.1f %s" % [line["t"], line["fps"], " | ".join(summaries)])


func _player_summary(p):
	return (
		"P%d %s T%d sci=%s pop=%s u=%d s=%d x=%d %s"
		% [
			p["p"],
			p["ai"],
			p["tier"],
			p["science"],
			p["pop"],
			p["units"],
			p["structures"],
			p["extractors"],
			p["stock"]
		]
	)


# --- input helpers: everything goes through the viewport like a real mouse


func _mouse_move(position):
	var event = InputEventMouseMotion.new()
	var previous = get_viewport().get_mouse_position()
	event.position = position
	event.global_position = position
	event.relative = position - previous
	get_viewport().warp_mouse(position)
	Input.parse_input_event(event)
	await _frames(1)


func _mouse_button(position, button, pressed):
	var event = InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = button
	event.pressed = pressed
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT and pressed else 0
	Input.parse_input_event(event)
	await _frames(1)


func _click_control(control, what):
	if control == null or not control.is_visible_in_tree():
		_finding("hud", "%s is not visible when needed" % what, false, "hidden-" + what)
		return false
	if control is BaseButton and control.disabled:
		_say(what + " is disabled")
		return false
	var scroll = control.get_parent()
	while scroll != null and not scroll is ScrollContainer:
		scroll = scroll.get_parent()
	var reachable = get_viewport().get_visible_rect()
	if scroll != null:  # scroll to it first, as a player would
		scroll.ensure_control_visible(control)
		await _frames(2)
		reachable = reachable.intersection(scroll.get_global_rect())
	if not reachable.grow(1).encloses(control.get_global_rect()):
		_finding(
			"hud",
			"%s is (partly) off screen at %s" % [what, control.get_global_rect()],
			true,
			"offscreen-" + what
		)
	var fired = [false]
	var on_press = func(): fired[0] = true
	var signal_name = "pressed" if control.has_signal("pressed") else ""
	if signal_name != "":
		control.connect(signal_name, on_press, CONNECT_ONE_SHOT)
	await _frames(3)  # let freshly shown panels finish their layout
	var center = control.get_global_rect().get_center()
	await _mouse_move(center)
	await _frames(2)
	if not control.get_global_rect().has_point(center):
		center = control.get_global_rect().get_center()
		await _mouse_move(center)
		await _frames(2)
	await _mouse_button(center, MOUSE_BUTTON_LEFT, true)
	await _mouse_button(center, MOUSE_BUTTON_LEFT, false)
	await _frames(2)
	if signal_name != "" and not fired[0]:
		control.disconnect(signal_name, on_press)
		var hovered = get_viewport().gui_get_hovered_control()
		if (
			hovered is BaseButton
			and hovered != control
			and hovered.tooltip_text != ""
			and hovered.tooltip_text == control.tooltip_text
		):
			# an identical button of another menu instance sits on top and got the click
			_finding(
				"hud", "two copies of the %s menu button are stacked" % what, false, "dup-" + what
			)
			return true
		if not control.is_visible_in_tree():
			_say(what + " went away before the click landed (offer expired?)")
			return false
		if hovered == control and control is BaseButton and control.disabled:
			_say(what + " became disabled before the click landed")
			return false
		_stats["clicks_missed"] += 1
		_finding(
			"hud",
			(
				"clicking %s did nothing (mouse over %s)"
				% [what, _describe_control(hovered, control, center)]
			),
			true,
			"click-" + what
		)
		await _shot("click-missed-" + what.replace(" ", "-"))
		return false
	return true


func _describe_control(hovered, target, point):
	if hovered == null:
		return "nothing"
	if hovered == target:
		return (
			"the button itself, enabled, rect %s has point: %s"
			% [target.get_global_rect(), target.get_global_rect().has_point(point)]
		)
	var tip = str(hovered.get("tooltip_text")).get_slice("\n", 0).left(40)
	return (
		"%s '%s' under %s, target in tree: %s"
		% [hovered.get_class(), tip, hovered.get_parent().name, target.is_inside_tree()]
	)


func _select(units):
	units = units.filter(func(unit): return is_instance_valid(unit) and unit.is_inside_tree())
	if units.is_empty():
		return
	await _cancel_placement()
	MatchSignals.deselect_all_units.emit()
	await _frames(1)
	if units.size() == 1:
		var unit = units[0]
		await _look_at(unit.global_position)
		var screen = _camera.unproject_position(unit.global_position + Vector3(0, 0.3, 0))
		await _mouse_move(screen)
		if get_viewport().gui_get_hovered_control() != null:
			# a panel covers it: a player would scroll the camera so it shows elsewhere
			for offset in [
				Vector3(0, 0, -7), Vector3(7, 0, 0), Vector3(-7, 0, 0), Vector3(0, 0, 7)
			]:
				await _look_at(unit.global_position + offset)
				screen = _camera.unproject_position(unit.global_position + Vector3(0, 0.3, 0))
				await _mouse_move(screen)
				if get_viewport().gui_get_hovered_control() == null:
					break
		await _mouse_button(screen, MOUSE_BUTTON_LEFT, true)
		await _frames(2)
		await _mouse_button(screen, MOUSE_BUTTON_LEFT, false)
		await _frames(3)
		if not unit.is_in_group("selected_units"):
			_stats["clicks_missed"] += 1
			_bump(_stats, "select_fallbacks")
			var got = get_tree().get_nodes_in_group("selected_units").map(func(u): return u.name)
			_finding(
				"select",
				(
					"clicking %s did not select it (selected instead: %s)"
					% [unit.scene_file_path.get_file(), got]
				),
				false,
				"select-" + unit.scene_file_path.get_file()
			)
			await _shot("select-missed-" + unit.name)
			MatchSignals.deselect_all_units.emit()
			unit.find_child("Selection").select()
			await _frames(2)
	else:
		var center = Vector3.ZERO
		for unit in units:
			center += unit.global_position
		center /= units.size()
		await _look_at(center)
		var points = units.map(func(unit): return _camera.unproject_position(unit.global_position))
		var top_left = points[0]
		var bottom_right = points[0]
		for point in points:
			top_left = Vector2(min(top_left.x, point.x), min(top_left.y, point.y))
			bottom_right = Vector2(max(bottom_right.x, point.x), max(bottom_right.y, point.y))
		top_left -= Vector2(25, 25)
		bottom_right += Vector2(25, 25)
		await _mouse_move(top_left)
		await _mouse_button(top_left, MOUSE_BUTTON_LEFT, true)
		for step in range(1, 5):
			await _mouse_move(top_left.lerp(bottom_right, step / 4.0))
		await _mouse_button(bottom_right, MOUSE_BUTTON_LEFT, false)
		await _frames(3)
		var missing = units.filter(func(unit): return not unit.is_in_group("selected_units"))
		if not missing.is_empty():
			_bump(_stats, "box_select_misses")
			for unit in missing:
				unit.find_child("Selection").select()


func _right_click_world(position, what):
	await _look_at(position)
	var screen = _camera.unproject_position(position)
	await _mouse_move(screen)
	await _mouse_button(screen, MOUSE_BUTTON_RIGHT, true)
	await _mouse_button(screen, MOUSE_BUTTON_RIGHT, false)
	await _frames(3)


func _look_at(position):
	_camera.set_position_safely(position)
	await _frames(3)


# --- queries


func _atmosphere():
	if _match == null:
		return null
	return _match.find_child("Atmosphere", true, false)


func _own_units(predicate = null):
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == _human and (predicate == null or predicate.call(unit))
	)


func _count_own(scene_path):
	return _own_units(func(unit): return unit.scene_file_path == scene_path).size()


func _own_constructed(scene_path):
	for unit in _own_units(func(unit): return unit.scene_file_path == scene_path):
		if unit.is_constructed():
			return unit
	return null


func _base():
	for unit in _own_units(func(unit): return unit is CommandCenter):
		return unit
	return null


func _idle(unit):
	return unit.action == null


func _queue_size(producer):
	var queue = producer.get("production_queue")
	return queue.size() if queue != null else 0


func _cost(scene_path):
	return Constants.Match.Units.PRODUCTION_COSTS.get(
		scene_path, Constants.Match.Units.CONSTRUCTION_COSTS.get(scene_path, {})
	)


func _has(stock, cost):
	for resource in cost:
		if stock.get(resource, 0) < cost[resource]:
			return false
	return true


func _visible_menu_with(scene_path):
	for menu in _match.find_children("*", "GridContainer", true, false):
		if menu.has_method("_make_button") and menu.is_visible_in_tree():
			if scene_path in menu.get("_buttons"):
				return menu
	return null


func _find_button(root, text_key):
	for button in root.find_children("*", "Button", true, false):
		if button.text == tr(text_key) or text_key in button.text.to_upper():
			return button
	return null


func _closest_free_deposit(kind, from):
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


func _deposit_spot(kind, from):
	var deposit = _closest_free_deposit(kind, from)
	if deposit == null:
		return null
	var direction = (from - deposit.global_position) * Vector3(1, 0, 1)
	direction = direction.normalized() if direction.length() > 0.1 else Vector3(1, 0, 0)
	return deposit.global_position + direction * (deposit.radius + 1.7)  # extractor radius 0.9, gap 0.8


func _free_spot_near(structure, distance):
	if structure == null:
		return null
	var center = structure.global_position
	var navmap = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	var obstacles = (
		get_tree().get_nodes_in_group("units")
		+ get_tree().get_nodes_in_group("resource_units")
		+ get_tree().get_nodes_in_group("city_buildings")
	)
	for ring in range(4):
		for step in range(12):
			var angle = step * TAU / 12.0 + ring * 0.3
			var spot = center + Vector3(cos(angle), 0, sin(angle)) * (distance + ring * 4.0)
			if (
				Utils.Match.Unit.Placement.validate_agent_placement_position(
					spot, 2.0, obstacles, navmap
				)
				== Utils.Match.Unit.Placement.VALID
			):
				return spot
	return null


func _closest_enemy_target(from):
	var best = null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _human or not unit is Structure:
			continue
		var distance = unit.global_position.distance_to(from)
		if best == null or distance < best[0]:
			best = [distance, unit]
	return best[1] if best != null else null


# --- reporting


func _finding(kind, text, is_bug = true, key = ""):
	key = key if key != "" else kind + text
	if key in _finding_keys:
		_finding_keys[key]["count"] += 1
		return
	var entry = {"kind": kind, "text": text, "t": int(_elapsed_s), "bug": is_bug, "count": 1}
	_finding_keys[key] = entry
	_findings.append(entry)
	_say(("BUG " if is_bug else "NOTE ") + kind + ": " + text)


func _bump(dictionary, key):
	dictionary[key] = dictionary.get(key, 0) + 1


func _say(text):
	print("PLAY %5ds %s" % [int(_elapsed_s), text])


func _shot(name):
	await _frames(3)
	_shot_index += 1
	var path = "%s/%02d-%s.png" % [_args["out"], _shot_index, name]
	get_viewport().get_texture().get_image().save_png(path)


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame


func _wait_s(seconds):
	var until = _elapsed_s + seconds
	var paused_frames = 0
	while _elapsed_s < until and _result == "time limit":
		await get_tree().physics_frame
		paused_frames = paused_frames + 1 if get_tree().paused else 0
		if paused_frames > 600:
			_finding("pause", "the game paused itself and stayed paused (%s)" % _paused_by())
			await _shot("paused")
			_result = "paused"


func _paused_by():
	var visible = []
	for layer_name in ["Menu", "MatchEndHandler", "FrameIncrementer"]:
		var node = _match.find_child(layer_name, true, false)
		if node is CanvasLayer and node.visible:
			visible.append(layer_name)
	return "visible: %s, last step: %s" % [visible, _doing]


# Runs on its own thread: if the main thread stops producing frames, the game is stuck
# in a script or engine loop. Print what the bot was doing and quit so the run ends.
func _watch_main_thread():
	var last = -1
	var still_s = 0
	while not _finished:
		OS.delay_msec(5000)
		if _frames_seen == last:
			still_s += 5
			if still_s >= 180:
				print("HANG main thread froze for %d s, last bot step: %s" % [still_s, _doing])
				OS.kill(OS.get_process_id())
				return
		else:
			still_s = 0
		last = _frames_seen


func _process(_delta):
	_frames_seen += 1


func _exit_tree():
	_finished = true
	if _watchdog.is_started():
		_watchdog.wait_to_finish()


func _physics_process(delta):
	if _match != null and not get_tree().paused:
		_elapsed_s += delta


func _finish():
	if _finished:
		return
	_finished = true
	var crash_report = CrashReporter.own_report()
	if crash_report != null:
		_finding("crash reporter", "%s, see crash_report.txt" % crash_report["kind"])
	if _stats.has("roster"):
		_stats["roster_never_built"] = _stats["roster"].keys().filter(
			func(id): return _stats["roster"][id] == 0
		)
	var report = {
		"args": _args,
		"result": _result,
		"game_seconds": int(_elapsed_s),
		"findings": _findings,
		"errors": _logger.errors,
		"warnings": _logger.warnings,
		"stats": _stats,
		"timeline": _timeline,
	}
	var file = FileAccess.open(_args["out"] + "/report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	var lines = ["result: %s after %d s" % [_result, int(_elapsed_s)]]
	for finding in _findings:
		lines.append(
			(
				"%s %s at %ds (x%d): %s"
				% [
					"BUG" if finding["bug"] else "note",
					finding["kind"],
					finding["t"],
					finding["count"],
					finding["text"]
				]
			)
		)
	for text in _logger.errors:
		lines.append("ERROR x%d: %s" % [_logger.errors[text], text])
	lines.append("stats: " + JSON.stringify(_stats))
	file = FileAccess.open(_args["out"] + "/report.txt", FileAccess.WRITE)
	file.store_string("\n".join(lines))
	file.close()
	print("\n".join(lines))
	var bugs = _findings.filter(func(finding): return finding["bug"]).size() + _logger.errors.size()
	get_tree().quit(1 if bugs > 0 else 0)
