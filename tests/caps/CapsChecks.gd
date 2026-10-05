extends Node

# Hits every match cap in a running match and saves screenshots (see MatchLimits.gd):
# the unit cap for the player, the AI and the helper, the city population cap per tier,
# the depletion countdown and the end of the match by score.
# Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . \
#     res://tests/caps/CapsChecks.tscn -- --out=/tmp/caps
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const Human = preload("res://source/match/players/human/Human.gd")
const Helper = preload("res://source/match/players/human/Helper.gd")
const MatchLimits = preload("res://source/match/MatchLimits.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const WorkerScene = preload("res://source/match/units/Worker.tscn")
const VehicleFactoryScene = preload("res://source/match/units/VehicleFactory.tscn")
const GameData = preload("res://source/data-model/GameData.gd")

var _failures = 0
var _out = "user://caps"
var _match = null
var _limits = null
var _human = null
var _rival = null
var _cap_signals = []
var _limit_signals = []
var _depleted_signals = 0


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS  # keeps checking after the match end pauses
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	MatchSignals.unit_cap_reached.connect(func(player): _cap_signals.append(player))
	MatchSignals.match_limit_reached.connect(
		func(reason, ranking): _limit_signals.append([reason, ranking])
	)
	MatchSignals.resources_depleted.connect(func(): _depleted_signals += 1)
	_check_data()
	await _start_match()
	await _check_unit_cap()
	await _check_ai_unit_cap()
	await _check_helper_unit_cap()
	await _check_match_share()
	await _check_city_cap()
	await _check_manual()
	await _check_depletion_end()
	await _restart_match()
	await _check_time_end()
	print("caps checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_data():
	var caps = GameData.caps()
	_expect(int(caps.get("unit_slots_per_player", 0)) == 150, "unit cap per player is 150")
	_expect(int(caps.get("unit_slots_per_match", 0)) == 400, "match-wide unit cap is 400")
	_expect(float(caps.get("time_limit_min", 0)) > 0, "matches have a time limit")
	var tiers = GameData.tiers()
	_expect(
		tiers.all(func(tier): return "max_population" in tier),
		"every tier has a max_population ({0})".format(
			[str(tiers.map(func(tier): return tier.get("max_population")))]
		)
	)
	var slots = GameData.unit_field("unit_slots", "unit")
	var battle_tank = GameData.unit_by_id("battle_tank")
	_expect(int(slots[battle_tank["scene"]]) == 5, "a battle tank takes 5 slots")
	_expect(
		int(slots[GameData.unit_by_id("militia")["scene"]]) == 0,
		"militia take no slots (the city's own defense)"
	)


func _start_match():
	_match = load("res://tests/caps/CapsMatch.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_match)
	await _frames(40)
	_limits = MatchLimits.of(get_tree())
	_expect(_limits != null, "the match has limits")
	var players = get_tree().get_nodes_in_group("players")
	_human = players.filter(func(p): return p is Human)[0]
	_rival = players.filter(func(p): return not p is Human)[0]
	_human.add_resources({"timber": 400, "iron": 400, "copper": 400, "oil": 400})


func _restart_match():
	get_tree().paused = false
	_match.queue_free()
	await _frames(10)
	_cap_signals.clear()
	_limit_signals.clear()
	await _start_match()


func _check_unit_cap():
	_expect(_limits.slots_cap() == 150, "2 players: cap is 150 (400 / 2 is more)")
	var cc = _own(func(unit): return unit is CommandCenter)
	var used = _limits.slots_used(_human)
	_limits.config["unit_slots_per_player"] = used + 3
	var queued = 0
	for _i in range(6):
		if cc.production_queue.produce(WorkerScene, true) != null:
			queued += 1
	_expect(queued == 3, "3 free slots let 3 constructors be queued (queued %d)" % queued)
	_expect(_limits.slots_used(_human) == used + 3, "queued units take their slots at once")
	_expect(_human in _cap_signals, "the 4th order is refused with a unit-cap signal")
	await _frames(20)
	var guide = _match.find_child("Guide", true, false)
	var hints = [guide.get("_hint_label").text] + guide.get("_hint_queue") if guide else []
	_expect(
		hints.any(func(hint): return "Unit cap reached" in hint),
		"the player is told why ({0})".format([str(hints)])
	)
	var bar = _bar_label("UnitsLabel")
	_expect(
		bar != null and bar.text == "Units {0}/{0}".format([used + 3]),
		"top bar shows Units used/cap ('%s')" % (bar.text if bar else "none")
	)
	await _shot("1-unit-cap-reached")
	cc.production_queue.cancel_all()
	_expect(cc.production_queue.produce(WorkerScene, true) != null, "losing slots frees them")
	cc.production_queue.cancel_all()
	_limits.config["unit_slots_per_player"] = 150


func _check_ai_unit_cap():
	var ai_cc = null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _rival and unit is CommandCenter:
			ai_cc = unit
	_rival.add_resources({"iron": 100, "oil": 100})
	_limits.config["unit_slots_per_player"] = _limits.slots_used(_rival, true)
	_cap_signals.clear()
	_expect(
		ai_cc.production_queue.produce(WorkerScene, true) == null,
		"an AI factory at the cap refuses units too"
	)
	_expect(_rival in _cap_signals, "the AI's refusal is the same unit-cap signal")
	_limits.config["unit_slots_per_player"] = 150


func _check_helper_unit_cap():
	var cc = _own(func(unit): return unit is CommandCenter)
	var factory = VehicleFactoryScene.instantiate()
	factory.set_meta("spawn_constructed", true)
	MatchSignals.setup_and_spawn_unit.emit(
		factory, Transform3D(Basis(), cc.global_position + Vector3(8, 0, 8)), _human
	)
	await _frames(10)
	var cap = _limits.slots_used(_human) + 5
	_limits.config["unit_slots_per_player"] = cap
	var helper = Helper.of(_human)
	helper.army_target = 30
	helper.scouting = false
	helper.set_enabled(true)
	var hit_cap = await _wait_for(func(): return _limits.slots_used(_human) >= cap - 1, 1500)
	await _frames(240)
	var used = _limits.slots_used(_human)
	_expect(hit_cap and used <= cap, "the helper fills the army up to the cap, not past it (%d/%d)" % [used, cap])
	var status = helper.status_lines()
	_expect(
		status.any(func(line): return "unit cap" in line),
		"the helper panel says the cap stops it ({0})".format([str(status)])
	)
	await _shot("2-helper-at-unit-cap")
	helper.set_enabled(false)
	_limits.config["unit_slots_per_player"] = 150


func _check_match_share():
	_limits.config["unit_slots_per_match"] = 100
	_expect(_limits.slots_cap() == 50, "a match cap of 100 gives each of 2 players 50")
	_limits.config["unit_slots_per_match"] = 400


func _check_city_cap():
	var city = _human.city
	_expect(city.tier == 1 and city.max_population == 60, "a Frontier city holds 60 citizens")
	city.science = 0.0
	var core = _own(func(unit): return unit is CommandCenter)
	var angle = 0.0
	while city.housing < 60:  # build the city up to the Frontier cap at once
		angle += 0.6
		city._add_building("house", core.global_position + Vector3(cos(angle), 0, sin(angle)) * 7.0)
	var buildings = city.get_buildings_count("house") + city.get_buildings_count("workshop")
	city.population = 95.0  # e.g. a trade boom pushed it over
	await _wait_seconds(2.0)
	_expect(city.population <= 60.0, "population is held at the cap (%.1f)" % city.population)
	_expect(city.is_at_population_cap(), "the city reports it is full")
	_expect(city.growth_per_s <= 0.0, "a full city does not grow (%.2f/s)" % city.growth_per_s)
	_expect(
		city.get_buildings_count("house") + city.get_buildings_count("workshop") == buildings,
		"a full city builds no more houses"
	)
	var label = _match.find_child("CityHud", true, false)
	camera_on(core.global_position, 14.0)
	await _frames(30)
	var city_text = ""
	if label != null:
		for node in label.find_children("*", "Label", true, false):
			city_text += node.text + "\n"
	_expect("[max 60]" in city_text and "city full" in city_text, "the city panel shows the cap")
	await _shot("3-city-full-at-frontier")
	city.science = 151.0
	await _wait_seconds(1.5)
	_expect(
		city.tier == 2 and city.max_population == 100,
		"Industrial raises the cap to 100 (tier %d, max %d)" % [city.tier, city.max_population]
	)
	city.satisfaction = {}
	for resource in Constants.Match.Resources.ALL:
		city.warehouse[resource] = 40.0
	await _wait_seconds(3.0)
	_expect(city.population > 60.0, "after the tier-up it grows again (%.2f)" % city.population)


func _check_manual():
	var guide = _match.find_child("Guide", true, false)
	guide.toggle_help("LIMITS", true)
	await _frames(20)
	await _shot("4-manual-limits")
	guide.help_window.hide()


func _check_depletion_end():
	for deposit in get_tree().get_nodes_in_group("deposits"):
		deposit.queue_free()
	await _wait_seconds(1.5)
	_expect(_limits.depleted_at_s >= 0.0 and _depleted_signals == 1, "the last empty deposit is noticed")
	_expect(_limits.ends_by_depletion(), "a dry map ends sooner than the time limit")
	var left = _limits.time_left_s()
	_expect(abs(left - 300.0) < 5.0, "the dry-map countdown is 5 minutes (%.0f s left)" % left)
	await _frames(10)
	var clock = _bar_label("ClockLabel")
	_expect(
		clock != null and clock.visible and "Map dry" in clock.text,
		"the top bar shows the countdown ('%s')" % (clock.text if clock else "none")
	)
	await _shot("5-resources-gone-countdown")
	_limits.config["depletion_countdown_min"] = (_limits.elapsed_s - _limits.depleted_at_s + 2.0) / 60.0
	var ended = await _wait_for(func(): return not _limit_signals.is_empty(), 600)
	_expect(
		ended and _limit_signals[0][0] == MatchLimits.EndReason.DEPLETION,
		"the countdown ends the match"
	)
	await _frames(20)
	var summary = _match.find_child("ScoreSummary", true, false)
	_expect(summary != null and summary.is_visible_in_tree(), "the end screen lists the scores")
	_expect(get_tree().paused, "the match is over (paused behind the end screen)")
	await _shot("6-match-end-dry-map")


func _check_time_end():
	_expect(_limits.slots_cap() == 150 and not _limits.ended, "a new match starts with fresh limits")
	_limits.config["time_limit_min"] = (_limits.elapsed_s + 2.0) / 60.0
	await _frames(5)
	var clock = _bar_label("ClockLabel")
	_expect(clock != null and "Ends in" in clock.text, "the clock counts down ('%s')" % (clock.text if clock else "none"))
	var ended = await _wait_for(func(): return not _limit_signals.is_empty(), 600)
	_expect(ended and _limit_signals[0][0] == MatchLimits.EndReason.TIME, "time runs out")
	var ranking = _limit_signals[0][1] if ended else []
	_expect(ranking.size() == 2, "both players are ranked")
	if ranking.size() == 2:
		_expect(
			ranking[0]["score"]["total"] >= ranking[1]["score"]["total"],
			"best score first ({0} vs {1})".format(
				[ranking[0]["score"]["total"], ranking[1]["score"]["total"]]
			)
		)
		var handler = _match.find_child("MatchEndHandler", true, false)
		var won = ranking[0]["player"] == _human and ranking[0]["score"]["total"] > ranking[1]["score"]["total"]
		var tile = handler.find_child("Victory" if won else "Defeat", true, false)
		if ranking[0]["score"]["total"] == ranking[1]["score"]["total"]:
			tile = handler.find_child("Finish", true, false)
		await _frames(10)
		_expect(tile.visible, "the end screen shows {0}".format([tile.name]))
	await _shot("7-match-end-time-up")


func _bar_label(label_name):
	var bars = _match.get_node("HUD/MarginContainer2/Resources")
	for bar in bars.get_children():
		if bar.visible and bar.player == _human:
			return bar.find_child(label_name, true, false)
	return null


func camera_on(position, size):
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(size)
	camera.set_position_safely(position)


func _own(predicate):
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _human and predicate.call(unit):
			return unit
	return null


func _expect(condition, description):
	print(("PASS " if condition else "FAIL ") + description)
	if not condition:
		_failures += 1


func _wait_for(predicate, max_frames):
	for _i in range(max_frames):
		if predicate.call():
			return true
		await get_tree().process_frame
	return predicate.call()


func _wait_seconds(seconds):
	var start = _limits.elapsed_s if _limits != null else 0.0
	await _wait_for(func(): return _limits.elapsed_s - start >= seconds, 3000)


func _shot(name):
	await _frames(5)
	var path = "{0}/{1}.png".format([_out, name])
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
