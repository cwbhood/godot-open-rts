extends Node

# Plays one scenario file: starts the match it describes, runs its timed orders, checks
# its expectations and writes the report. The file format is in docs/testing/play-harness.md;
# tools/harness/scenarios/ has working examples.

signal finished(report)

const GameData = preload("res://source/data-model/GameData.gd")
const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const HarnessApi = preload("res://tools/harness/HarnessApi.gd")
const Recorder = preload("res://tools/harness/Recorder.gd")
const VirtualMouse = preload("res://tools/harness/VirtualMouse.gd")

const DEFAULTS = {
	"name": "",
	"description": "",
	"map": "plain_and_simple",
	"seed": 1,
	"minutes": 5.0,
	"speed": 1.0,
	"view": "fast",
	"players": [{"type": "human"}, {"type": "ai", "personality": "balanced"}],
	"fog": true,
	"weather": "clear",
	"city_build_up": false,
	"tutorial": false,
	"match_end": false,
	"sample_every": 5.0,
	"shots_every": 0.0,
	"setup": [],
	"events": [],
	"checks": [],
	"budgets": {},
	"end_when": null,
}

var scenario = {}
var out_dir = "user://harness"
var api = HarnessApi.new()
var recorder = Recorder.new()
var mouse = VirtualMouse.new()
var real_mouse = false
var keep_running = false  # --serve: stay up after the time limit until an "end" order

var _match = null
var _results = []  # [{name, ok, detail, t}]
var _pending_events = []
var _pending_checks = []
var _always_checks = []
var _failed_always = {}
var _ended = ""
var _busy = false


static func load_file(path):
	"""reads a scenario JSON; relative names are looked up in tools/harness/scenarios/"""
	var candidates = [path, "res://tools/harness/scenarios/" + path]
	if not path.ends_with(".json"):
		candidates.append("res://tools/harness/scenarios/" + path + ".json")
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(candidate))
			if parsed is Dictionary:
				parsed["file"] = candidate
				return parsed
			push_error("harness: %s is not a JSON object" % candidate)
			return null
	push_error("harness: no scenario at %s" % path)
	return null


static func normalized(raw):
	var result = DEFAULTS.duplicate(true)
	result.merge(raw, true)
	if raw.has("seconds"):
		result["minutes"] = float(raw["seconds"]) / 60.0
	result["seed"] = int(result["seed"])
	if result["name"] == "":
		result["name"] = str(raw.get("file", "scenario")).get_file().get_basename()
	return result


func _ready():
	name = "ScenarioRunner"
	process_mode = Node.PROCESS_MODE_ALWAYS


func run():
	scenario = normalized(scenario)
	seed(int(scenario["seed"]))
	var map_path = _map_path(scenario["map"])
	if map_path == null:
		_finish_early("unknown map '%s'" % scenario["map"])
		return
	GameData.register_generated_scenes()
	FeatureFlags.handle_match_end = scenario["match_end"]
	recorder.out_dir = out_dir
	recorder.api = api
	recorder.sample_every_s = float(scenario["sample_every"])
	recorder.shots_every_s = float(scenario["shots_every"])
	recorder.three_d_off = scenario["view"] == "fast"
	api.recorder = recorder
	api.mouse = mouse
	mouse.block_real_mouse = not real_mouse
	add_child(recorder)
	add_child(api)
	get_tree().root.add_child.call_deferred(mouse)
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = _match_settings(map_path)
	_match.map = load(map_path).instantiate()
	_match.play_city_build_up = scenario["city_build_up"]
	get_tree().root.add_child.call_deferred(_match)
	await _match.ready
	await get_tree().process_frame
	api.match_node = _match
	if scenario["view"] == "fast":
		get_viewport().disable_3d = true
	_set_speed(float(scenario["speed"]))
	recorder.start()
	recorder.note(
		(
			"started %s on %s, seed %s, %s"
			% [scenario["name"], scenario["map"], scenario["seed"], _players_text()]
		),
		"start"
	)
	if not scenario["fog"]:
		await api.command({"do": "reveal"})
	var atmosphere = _match.find_child("Atmosphere", true, false)
	if scenario["weather"] != "random" and atmosphere != null:
		atmosphere.random_weather = false
		await api.command({"do": "weather", "set": scenario["weather"]})
	var guide = _match.find_child("Guide", true, false)
	if guide != null and not scenario["tutorial"]:
		guide.set("_step", guide.STEPS.size())  # as if every step was skipped
		guide.call("_refresh_tutorial")
	for index in range(scenario["players"].size()):
		var player_entry = scenario["players"][index]
		if player_entry.get("type") == "human" and player_entry.get("helper", false):
			await api.command({"do": "helper", "on": true})
	for order in scenario["setup"]:
		await _run_order(order)
	_queue_timed()
	await _loop()
	await _finish()


func _map_path(map_id):
	var maps = GameData.maps()
	for scene_path in maps:
		if maps[scene_path].get("id") == map_id or scene_path == map_id:
			return scene_path
		if scene_path.get_file().get_basename().to_snake_case() == map_id:
			return scene_path
	return null


func _match_settings(map_path):
	var settings = MatchSettings.new()
	var colors = GameData.player_colors()
	var slots = int(Constants.Match.MAPS.get(map_path, {}).get("players", 8))
	var entries = scenario["players"].slice(0, slots)
	for index in range(entries.size()):
		var entry = entries[index]
		var player_settings = PlayerSettings.new()
		if entry.get("type", "ai") == "human":
			player_settings.controller = Constants.PlayerType.HUMAN
		else:
			player_settings.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
			player_settings.ai_personality = entry.get("personality", "balanced")
			player_settings.ai_difficulty = entry.get("difficulty", "normal")
		player_settings.color = Constants.Player.COLORS[index % Constants.Player.COLORS.size()]
		for color in colors:
			if color["id"] == entry.get("color", ""):
				player_settings.color = color["color"]
		if entry.has("start_zone"):
			player_settings.start_zone = int(entry["start_zone"])
		if entry.has("start_position"):
			player_settings.start_position = Vector2(
				entry["start_position"][0], entry["start_position"][1]
			)
		settings.players.append(player_settings)
	var human_index = entries.find_custom(func(entry): return entry.get("type") == "human")
	settings.visible_player = max(human_index, 0)
	settings.visibility = (
		settings.Visibility.PER_PLAYER if human_index >= 0 else settings.Visibility.ALL_PLAYERS
	)
	return settings


func _players_text():
	return ", ".join(scenario["players"].map(player_label))


static func player_label(entry):
	if entry.get("type") == "human":
		return "you" + (" + helper" if entry.get("helper", false) else "")
	return "%s/%s" % [entry.get("personality", "balanced"), entry.get("difficulty", "normal")]


func _set_speed(speed):
	Engine.time_scale = speed
	Engine.max_physics_steps_per_frame = max(8, int(ceil(speed * 4)))


func _queue_timed():
	for event in scenario["events"]:
		if event.has("every"):
			var start = float(event.get("from", event["every"]))
			var stop = float(event.get("until", scenario["minutes"] * 60.0))
			var t = start
			while t <= stop:
				var copy = event.duplicate()
				copy["at"] = t
				_pending_events.append(copy)
				t += float(event["every"])
		else:
			_pending_events.append(event)
	_pending_events.sort_custom(func(a, b): return float(a.get("at", 0)) < float(b.get("at", 0)))
	for check in scenario["checks"]:
		if check.get("always", false):
			_always_checks.append(check)
		elif check.has("at"):
			_pending_checks.append(check)
	_pending_checks.sort_custom(func(a, b): return float(a["at"]) < float(b["at"]))


func _loop():
	var limit = float(scenario["minutes"]) * 60.0
	var next_always = 0.0
	while _ended == "":
		await get_tree().physics_frame
		var t = api.elapsed_s
		while not _pending_events.is_empty() and float(_pending_events[0].get("at", 0)) <= t:
			await _run_order(_pending_events.pop_front())
		while not _pending_checks.is_empty() and float(_pending_checks[0]["at"]) <= t:
			_record(_pending_checks.pop_front())
		if t >= next_always and not _always_checks.is_empty():
			next_always = t + float(scenario["sample_every"])
			for check in _always_checks:
				_record(check, true)
		if scenario["end_when"] != null and evaluate(scenario["end_when"])["ok"]:
			_ended = "end_when met at %.0f s" % t
		elif api.ended:
			_ended = "ended by an order"
		elif t >= limit and not keep_running:
			_ended = "time limit"
		elif _match_over() != "":
			_ended = _match_over()


func _match_over():
	var ends = recorder.timeline.filter(func(entry): return entry["kind"] == "match_end")
	return ends[-1]["text"] if not ends.is_empty() else ""


func _run_order(order):
	var result = await api.command(order)
	if order.get("expect_ok", false):
		(
			_results
			. append(
				{
					"name": "order %s at %.0f s" % [order["do"], api.elapsed_s],
					"ok": result.get("ok", false),
					"detail": result.get("error", ""),
					"t": snapped(api.elapsed_s, 0.1),
				}
			)
		)
	return result


func _record(check, always = false):
	var outcome = evaluate(check)
	var label = check.get("name", _describe(check))
	if always:
		if outcome["ok"] or label in _failed_always:
			return
		_failed_always[label] = true
	outcome["name"] = label
	outcome["t"] = snapped(api.elapsed_s, 0.1)
	_results.append(outcome)
	recorder.note(
		"%s %s %s" % ["check ok:" if outcome["ok"] else "CHECK FAILED:", label, outcome["detail"]],
		"check"
	)


# --- checks ----------------------------------------------------------------------------


func evaluate(check):
	"""returns {ok, detail}; unknown kinds fail with an explanation"""
	var kind = check.get("expect", "")
	var method = "_check_" + kind
	if not has_method(method):
		return {"ok": false, "detail": "unknown check '%s'" % kind}
	return call(method, check)


func _check_units(check):
	var count = (
		api
		. find_units(
			check.get("units", "own:*"), check.get("near"), float(check.get("radius", INF))
		)
		. size()
	)
	return _in_range(count, check, "units")


func _check_built(check):
	var count = (
		api
		. find_units(check.get("units", "own:structures"))
		. filter(func(unit): return not unit.has_method("is_constructed") or unit.is_constructed())
		. size()
	)
	return _in_range(count, check, "built")


func _check_stock(check):
	var player = api._player_for(str(check.get("player", "own")))
	if player == null:
		return {"ok": false, "detail": "no such player"}
	return _in_range(player.get_stock().get(check.get("resource", "iron"), 0), check, "")


func _check_no_errors(_check):
	var errors = recorder.logger.errors
	var count = Recorder._total(errors)
	var first = errors.keys().slice(0, 3)
	return {"ok": count == 0, "detail": "%d script errors %s" % [count, first if count else ""]}


func _check_no_war_started_by(check):
	return _no_war_started_by(str(check.get("player", "own")))


func _check_near(check):
	return _near(check)


func _check_spread(check):
	return _spread(check)


func _check_metric(check):
	var value = recorder.metrics().get(check.get("metric", ""), null)
	if value == null:
		return {"ok": false, "detail": "unknown metric %s" % check.get("metric")}
	return _in_range(value, check, check["metric"])


func _check_helper(check):
	var helper_state = api.state(false)["players"].filter(func(p): return p.has("helper"))
	if helper_state.is_empty():
		return {"ok": false, "detail": "no helper"}
	var value = helper_state[0]["helper"]["stats"].get(check.get("stat", ""), 0)
	return _in_range(value, check, check.get("stat", ""))


func _check_on_line(check):
	"""every unit stands within "within" m of the line from-to, spread at least min_spacing"""
	var units = api.find_units(check.get("units", "own:combat"))
	if units.is_empty():
		return {"ok": false, "detail": "no units"}
	var a = HarnessApi._vec2(api.ground(check["from"]))
	var b = HarnessApi._vec2(api.ground(check["to"]))
	var within = float(check.get("within", 2.0))
	var off = units.filter(
		func(unit):
			var p = HarnessApi.flat(unit)
			return p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)) > within
	)
	var spread = _spread({"units": check.get("units"), "min_m": check.get("min_spacing", 1.5)})
	return {
		"ok": off.is_empty() and spread["ok"],
		"detail": "%d of %d off the line, %s" % [off.size(), units.size(), spread["detail"]]
	}


func _check_expr(check):
	return _expression(check)


func _check_timeline(check):
	var kind = check.get("kind", "")
	var text = str(check.get("contains", ""))
	# careful: in Godot, "" in "abc" is false
	var matching = recorder.timeline.filter(
		func(entry): return entry["kind"] == kind and (text == "" or text in entry["text"])
	)
	return _in_range(matching.size(), check, "events")


func _in_range(value, check, unit_name):
	var ok = true
	if check.has("min") and value < float(check["min"]):
		ok = false
	if check.has("max") and value > float(check["max"]):
		ok = false
	if check.has("equals") and value != check["equals"]:
		ok = false
	var bounds = []
	if check.has("min"):
		bounds.append(">= %s" % check["min"])
	if check.has("max"):
		bounds.append("<= %s" % check["max"])
	if check.has("equals"):
		bounds.append("== %s" % check["equals"])
	return {"ok": ok, "detail": "%s %s (want %s)" % [value, unit_name, " and ".join(bounds)]}


func _no_war_started_by(who):
	var me = api._player_for(who)
	if me == null or Diplomacy.instance == null:
		return {"ok": true, "detail": "no diplomacy in this match"}
	var started = []
	for other in api.players():
		if other != me and Diplomacy.at_war(me, other):
			if Diplomacy.instance.aggressor(me, other) == me:
				started.append("p%d" % other.get_index())
	return {
		"ok": started.is_empty(),
		"detail": "started wars with %s" % [started] if started else "started no war"
	}


func _near(check):
	var units = api.find_units(check.get("units", "own:combat"))
	if units.is_empty():
		return {"ok": false, "detail": "no units"}
	var point = HarnessApi._vec2(api.ground(check["to"]))
	var radius = float(check.get("radius", 5.0))
	var close = units.filter(func(unit): return HarnessApi.flat(unit).distance_to(point) <= radius)
	var share = float(close.size()) / units.size()
	return {
		"ok": share >= float(check.get("share", 1.0)),
		"detail": "%d of %d within %.0f m" % [close.size(), units.size(), radius]
	}


func _spread(check):
	"""nearest neighbour distance of every unit is at least min_m (no clumps)"""
	var units = api.find_units(check.get("units", "own:combat"))
	var closest = INF
	for a in units:
		for b in units:
			if a != b:
				closest = min(closest, HarnessApi.flat(a).distance_to(HarnessApi.flat(b)))
	var wanted = float(check.get("min_m", 1.5))
	return {
		"ok": units.size() >= 2 and closest >= wanted,
		"detail": "closest pair %.2f m apart (want >= %.2f m)" % [closest, wanted]
	}


func _expression(check):
	var expression = Expression.new()
	if expression.parse(check.get("code", "false"), ["state"]) != OK:
		return {"ok": false, "detail": "cannot parse: " + expression.get_error_text()}
	var value = expression.execute([api.state()], null, false)
	if expression.has_execute_failed():
		return {"ok": false, "detail": "failed: " + expression.get_error_text()}
	return {"ok": bool(value), "detail": "%s -> %s" % [check["code"], value]}


func _describe(check):
	var parts = [check.get("expect", "?")]
	for key in ["units", "player", "resource", "metric", "stat", "code", "to"]:
		if check.has(key):
			parts.append(str(check[key]))
	return " ".join(parts)


# --- ending ----------------------------------------------------------------------------


func _finish():
	_set_speed(1.0)
	for check in scenario["checks"]:
		if check.get("end", false):
			_record(check)
	for metric in scenario["budgets"]:
		var check = {"expect": "metric", "metric": metric, "max": scenario["budgets"][metric]}
		check["name"] = "budget %s <= %s" % [metric, scenario["budgets"][metric]]
		_record(check)
	if not _pending_checks.is_empty():
		for check in _pending_checks:
			_results.append(
				{
					"name": check.get("name", _describe(check)),
					"ok": false,
					"detail": "never ran: the match ended at %.0f s" % api.elapsed_s,
					"t": snapped(api.elapsed_s, 0.1)
				}
			)
	if api.human() != null:
		await api.command({"do": "camera", "follow": "own:command_center"})
	await recorder.screenshot("end")
	var verdict = "pass" if _results.all(func(result): return result["ok"]) else "fail"
	var report = (
		recorder
		. write_report(
			{
				"name": scenario["name"],
				"description": scenario["description"],
				"file": scenario.get("file", ""),
				"map": scenario["map"],
				"seed": scenario["seed"],
				"players": scenario["players"],
				"verdict": verdict,
				"ended": _ended,
			},
			_results,
			api.state(false)
		)
	)
	print(
		(
			"HARNESS %s %s: %d/%d checks ok, report %s"
			% [
				verdict.to_upper(),
				scenario["name"],
				_results.filter(func(result): return result["ok"]).size(),
				_results.size(),
				ProjectSettings.globalize_path(out_dir.path_join("report.md")),
			]
		)
	)
	finished.emit(report)


func _finish_early(reason):
	push_error("harness: " + reason)
	print("HARNESS FAIL %s: %s" % [scenario.get("name", "?"), reason])
	await get_tree().process_frame  # the caller awaits "finished" right after run()
	finished.emit({"verdict": "fail", "error": reason})
