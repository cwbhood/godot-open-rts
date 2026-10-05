extends Node

# Checks diplomacy (war, pacts, alliances) in a running three-faction match and saves
# screenshots of the diplomacy bar. Usage (needs a real renderer):
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . \
#     res://tests/diplomacy/DiplomacyChecks.tscn -- --out=/tmp/diplomacy
# Prints PASS/FAIL lines and exits with code 1 if anything failed.

const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const Trade = preload("res://source/match/city/Trade.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
const TankScene = preload("res://source/match/units/Tank.tscn")

var _failures = 0
var _out = "user://diplomacy"
var _match = null
var _human = null
var _balanced = null
var _raider = null
var _diplomacy = null
var _human_tank = null
var _ai_tank = null


func _ready():
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	_match = load("res://tests/diplomacy/TestThreeFactions.tscn").instantiate()
	add_child(_match)
	await _frames(30)
	for player in get_tree().get_nodes_in_group("players"):
		if player is Human:
			_human = player
		elif player.personality_id == "raider":
			_raider = player
		else:
			_balanced = player
	_diplomacy = Diplomacy.instance
	_expect(_diplomacy != null, "the match has diplomacy")
	_check_neutral_start()
	_check_ai_prices()
	await _check_hit_means_war()
	await _check_pact()
	_check_alliance_rules()
	_check_timers()
	await _check_hud()
	await _check_ultimatum()
	print("diplomacy checks: {0} failure(s)".format([_failures]))
	get_tree().quit(1 if _failures > 0 else 0)


func _check_neutral_start():
	_expect(
		_diplomacy.get_state(_human, _balanced) == Diplomacy.State.NEUTRAL, "factions start neutral"
	)
	_expect(Diplomacy.can_attack(_human, _balanced), "neutrals can be ordered to attack")
	_expect(not Diplomacy.engages_on_sight(_human, _balanced), "neutrals do not fire on sight")


func _check_ai_prices():
	var raider_pact = Diplomacy.ai_demand(_raider, _human, Diplomacy.PACT)
	var balanced_pact = Diplomacy.ai_demand(_balanced, _human, Diplomacy.PACT)
	_expect(
		raider_pact > balanced_pact,
		"the raider asks more for a pact than the balanced AI ({0} > {1})".format(
			[int(raider_pact), int(balanced_pact)]
		)
	)
	_expect(
		Diplomacy.ai_demand(_raider, _human, Diplomacy.ALLIANCE) == null, "the raider never allies"
	)
	print("  balanced asks for a pact: ", Diplomacy.ai_asking_price(_balanced, _human, "pact"))
	print("  raider asks for a pact: ", Diplomacy.ai_asking_price(_raider, _human, "pact"))


func _check_hit_means_war():
	var cc = _first_unit(_human, func(unit): return unit.find_child("ProductionQueue") != null)
	var spot = cc.global_position + Vector3(9, 0, 9)
	_human_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(_human_tank, Transform3D(Basis(), spot), _human)
	_ai_tank = TankScene.instantiate()
	MatchSignals.setup_and_spawn_unit.emit(
		_ai_tank, Transform3D(Basis(), spot + Vector3(3, 0, 0)), _balanced
	)
	var market = _match.get_node("Market")
	(
		market
		. agreements
		. append(
			{
				"a": _human,
				"b": _balanced,
				"offered": {"timber": 1},
				"requested": {"iron": 1},
				"remaining": 5,
				"next_s": INF,
			}
		)
	)
	await _frames(90)
	_expect(
		_human_tank.hp == _human_tank.hp_max and _ai_tank.hp == _ai_tank.hp_max,
		"neutral tanks side by side hold fire"
	)
	_ai_tank.action = AutoAttacking.new(_human_tank)
	await _wait_for(func(): return Diplomacy.at_war(_human, _balanced), 600)
	_expect(Diplomacy.at_war(_human, _balanced), "the first hit means war")
	_expect(_diplomacy.aggressor(_human, _balanced) == _balanced, "the AI is the aggressor")
	_expect(
		Trade.validate(_human, _balanced, {"timber": 1}, {"iron": 1}) == Trade.Result.AT_WAR,
		"no trading at war"
	)
	_expect(market.agreements_of(_human).is_empty(), "war cancels trade agreements")
	_expect(
		(
			_diplomacy.can_sign(_human, _balanced, Diplomacy.ALLIANCE)
			== Diplomacy.Result.AT_WAR_NEEDS_PACT
		),
		"no alliance straight out of a war"
	)
	await _wait_for(func(): return _ai_tank.hp < _ai_tank.hp_max, 600)
	_expect(_ai_tank.hp < _ai_tank.hp_max, "at war the attacked tank fires back on its own")
	await _shot("1-war")


func _check_pact():
	var price = Diplomacy.ai_asking_price(_balanced, _human, Diplomacy.PACT)
	print("  balanced asks for a pact at war: ", price)
	if not price["requested"].is_empty():
		_expect(
			(
				_diplomacy.propose(_human, _balanced, Diplomacy.PACT)
				== Diplomacy.Result.PARTNER_REFUSED
			),
			"the AI refuses a free pact when it wants goods"
		)
		_human.add_resources(price["requested"])
	var result = _diplomacy.propose(
		_human, _balanced, Diplomacy.PACT, price["requested"], price["offered"]
	)
	_expect(result == Diplomacy.Result.ACCEPTED, "the AI signs a pact at its price")
	_expect(
		_diplomacy.get_state(_human, _balanced) == Diplomacy.State.PACT,
		"pact in effect, {0} s left".format([int(_diplomacy.seconds_left(_human, _balanced))])
	)
	await _frames(20)
	var hp_before = [_human_tank.hp, _ai_tank.hp]
	await _frames(120)
	_expect(
		[_human_tank.hp, _ai_tank.hp] == hp_before, "the pact stops the fight already under way"
	)
	_human_tank.take_damage(5, _ai_tank)
	_expect(_human_tank.hp == hp_before[0], "hits between pact partners do nothing")
	_expect(not AutoAttacking.is_applicable(_ai_tank, _human_tank), "no attack orders under a pact")
	_expect(not _balanced.wants_to_attack(_human), "the AI will not send troops through a pact")
	_expect(Diplomacy.can_attack(_raider, _human), "other factions can still attack pact partners")


func _check_alliance_rules():
	_expect(
		_diplomacy.can_sign(_human, _balanced, Diplomacy.ALLIANCE) == Diplomacy.Result.ACCEPTED,
		"after a pact, alliance is possible"
	)
	_diplomacy.sign_treaty(_human, _balanced, Diplomacy.ALLIANCE)
	_expect(Diplomacy.allied(_human, _balanced), "allied")
	_expect(
		_diplomacy.can_sign(_human, _raider, Diplomacy.ALLIANCE) == Diplomacy.Result.ALREADY_ALLIED,
		"one ally at a time"
	)
	_expect(
		(
			_diplomacy.can_sign(_raider, _balanced, Diplomacy.ALLIANCE)
			== Diplomacy.Result.PARTNER_ALLIED
		),
		"cannot ally with a faction that has an ally"
	)
	_expect(
		Trade._margin(_balanced, _human) == Constants.Match.Diplomacy.ALLY_TRADE_MARGIN,
		"allies trade at fair prices"
	)
	_diplomacy.declare_war(_raider, _human)
	var attacks_neutrals = _balanced.attacks_neutrals
	_balanced.attacks_neutrals = false
	_expect(_balanced.wants_to_attack(_raider), "an AI ally goes after its ally's enemies")
	_balanced.attacks_neutrals = attacks_neutrals


func _check_timers():
	_diplomacy._process(Constants.Match.Diplomacy.ALLIANCE_S + 0.5)
	_expect(
		_diplomacy.get_state(_human, _balanced) == Diplomacy.State.PACT,
		"an alliance turns into a pact when it runs out"
	)
	_expect(
		absf(_diplomacy.seconds_left(_human, _balanced) - Constants.Match.Diplomacy.PACT_S) < 1.0,
		"the follow-up pact lasts 5 minutes"
	)
	_diplomacy._process(Constants.Match.Diplomacy.PACT_S + 0.5)
	_expect(
		_diplomacy.get_state(_human, _balanced) == Diplomacy.State.NEUTRAL, "then neutral again"
	)


func _check_hud():
	var hud = _match.find_child("DiplomacyHud", true, false)
	_expect(hud != null and hud.visible, "the diplomacy bar shows")
	if hud == null:
		return
	_diplomacy.sign_treaty(_human, _balanced, Diplomacy.PACT)
	await _frames(5)
	var chip_text = hud.get("_chips")[0].text
	_expect("4:5" in chip_text or "5:00" in chip_text, "the chip counts down (" + chip_text + ")")
	hud.call("_on_chip_pressed", _balanced)
	await _frames(5)
	_expect(hud.get("_deal_box").visible, "clicking a faction opens the deal box")
	await _shot("2-pact-deal-box")
	hud.call("_on_chip_pressed", _balanced)
	var controller = _raider.get_node("DiplomacyController")
	_human.add_resources({"oil": 20, "iron": 20, "copper": 20, "timber": 20})
	var offered = controller.call("_offer", _diplomacy, _human, Diplomacy.PACT)
	await _frames(5)
	_expect(offered and hud.get("_offer_box").visible, "an AI pact offer shows in the bar")
	await _shot("3-incoming-pact-offer")


func _check_ultimatum():
	"""a non-peaceful AI demands tribute for a pact once its difficulty's time is up, and
	declares war when the demand is ignored; a signed pact buys quiet minutes"""
	var controller = _raider.get_node("DiplomacyController")
	_raider.ultimatum_after_s = 30.0
	var attacks_neutrals = _raider.attacks_neutrals
	_raider.attacks_neutrals = false  # no stray shot may start the war for it
	for timer in controller.get_children():
		if timer is Timer:
			timer.paused = true  # its own decision rounds stay out of this check
	_diplomacy.call("_set_state", _human, _raider, Diplomacy.State.NEUTRAL, 0.0)
	_diplomacy.call("_stop_hostilities", _human, _raider)  # left over from the war check
	_human.add_resources({"oil": 40, "iron": 40, "copper": 40, "timber": 40})
	# make sure the raider is not much weaker, or it makes no demands
	var home = _first_unit(_raider, func(_unit): return true).global_position_yless
	for i in range(4):
		var tank = TankScene.instantiate()
		MatchSignals.setup_and_spawn_unit.emit(
			tank, Transform3D(Basis(), home + Vector3(4 + i * 2, 0, 4)), _raider
		)
	await _frames(5)
	controller.set("_ultimatums", {})
	_raider.match_time_s = 10.0
	_expect(not controller.call("_press_human", _diplomacy, _human), "no demand before its time")
	_raider.match_time_s = 31.0
	_keep_neutral(_raider)
	var hud = _match.find_child("DiplomacyHud", true, false)
	if hud != null:
		hud.call("_dismiss_offer")
	var demanded = controller.call("_press_human", _diplomacy, _human)
	_expect(demanded, "then it demands tribute")
	await _frames(5)
	_expect(hud == null or hud.get("_offer_box").visible, "the demand shows as a pact offer")
	await _shot("4-ultimatum")
	_raider.match_time_s = 50.0
	_keep_neutral(_raider)
	controller.call("_press_human", _diplomacy, _human)
	_expect(
		_diplomacy.get_state(_human, _raider) == Diplomacy.State.NEUTRAL, "there is time to answer"
	)
	_raider.match_time_s = 120.0
	_keep_neutral(_raider)
	controller.call("_press_human", _diplomacy, _human)
	_expect(
		_diplomacy.get_state(_human, _raider) == Diplomacy.State.WAR,
		"an ignored demand ends in war"
	)
	_diplomacy.call("_set_state", _human, _raider, Diplomacy.State.NEUTRAL, 0.0)
	controller.set("_ultimatums", {})
	controller.call("_press_human", _diplomacy, _human)
	_diplomacy.sign_treaty(_raider, _human, Diplomacy.PACT)
	controller.call("_press_human", _diplomacy, _human)
	var entry = controller.get("_ultimatums").values()[0]
	_expect(
		(
			_diplomacy.get_state(_human, _raider) == Diplomacy.State.PACT
			and entry["next_s"] >= _raider.match_time_s + 200.0
		),
		"signing the pact keeps the peace and the next demand waits"
	)
	_raider.attacks_neutrals = attacks_neutrals
	for timer in controller.get_children():
		if timer is Timer:
			timer.paused = false


func _keep_neutral(ai):
	"""stray shots of the busy test match do not start this war; the controller must"""
	if _diplomacy.get_state(_human, ai) == Diplomacy.State.WAR:
		_diplomacy.call("_set_state", _human, ai, Diplomacy.State.NEUTRAL, 0.0)
	_diplomacy.call("_stop_hostilities", _human, ai)


func _first_unit(player, predicate):
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == player and predicate.call(unit):
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
		await get_tree().physics_frame
	return predicate.call()


func _shot(name):
	await _frames(5)
	var path = "{0}/{1}.png".format([_out, name])
	get_viewport().get_texture().get_image().save_png(path)
	print("saved ", path)


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
