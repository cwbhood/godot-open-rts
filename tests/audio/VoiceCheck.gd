extends Node

# Checks unit voices and advisor announcements. Usage (headless is fine):
#   godot --headless --path . res://tests/audio/VoiceCheck.tscn [-- --report=res://docs/audio-voices.md]
#
# Fails (exit 1) when:
# - a unit or structure in data/units has no voice set, or its set is missing
# - a voice set has no sound for one of the unit actions in data/sounds/voices.json, or a
#   speaking set has fewer than MIN_SPEECH_VARIANTS lines for one
# - the advisor has no line for one of its events
# - a sound file does not load
# - a faction voice override is missing, a unit unique to one faction talks with the voice
#   of a unit unique to the other, or both factions' militia sound the same
# - a line plays twice in a row when the same action repeats
# - in a staged match, selecting, ordering, hitting or producing a unit does not play a
#   line from that unit's own set for its owner's faction (the drone must buzz, not talk), or the advisor stays
#   silent on low oil, a full storage, a new tier or a helper alert
# --report writes a markdown list of every unit with its voice set and lines.

const GameData = preload("res://source/data-model/GameData.gd")
const VoiceBank = preload("res://source/match/audio/VoiceBank.gd")

const MIN_SPEECH_VARIANTS = 3
const DRAWS = 60

var _failures = []


func _ready():
	var report_path = ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--report="):
			report_path = arg.trim_prefix("--report=")
	_check_data()
	_check_no_repeats()
	await _check_in_match()
	if report_path != "":
		_write_report(report_path)
	for failure in _failures:
		print("FAIL: ", failure)
	print("voice check: {0} failure(s)".format([_failures.size()]))
	get_tree().quit(1 if not _failures.is_empty() else 0)


func _fail(text):
	_failures.append(text)


func _check_data():
	var config = GameData.voices()
	var actions = config.get("unit_actions", [])
	if actions.is_empty():
		_fail("data/sounds/voices.json lists no unit_actions")
	var used_sets = {}
	for unit in GameData.units():
		var set_id = GameData.voice_set_id_for(unit)
		if set_id == null:
			_fail("unit '{0}' has no voice set".format([unit["id"]]))
			continue
		if GameData.voice_set_by_id(set_id) == null:
			_fail("unit '{0}' uses missing voice set '{1}'".format([unit["id"], set_id]))
			continue
		used_sets[set_id] = true
	for set_id in used_sets:
		var voice_set = GameData.voice_set_by_id(set_id)
		for action in actions:
			var lines = voice_set.get("lines", {}).get(action, [])
			if lines.is_empty():
				_fail("voice set '{0}' has no sound for '{1}'".format([set_id, action]))
			elif voice_set.get("kind") == "speech" and lines.size() < MIN_SPEECH_VARIANTS:
				_fail(
					"voice set '{0}' has only {1} line(s) for '{2}'".format(
						[set_id, lines.size(), action]
					)
				)
	_check_faction_voices()
	var advisor = GameData.voice_set_by_id(config.get("advisor", "advisor"))
	if advisor == null:
		_fail("advisor voice set is missing")
	else:
		for event in config.get("advisor_events", []):
			if advisor.get("lines", {}).get(event, []).is_empty():
				_fail("advisor has no line for '{0}'".format([event]))
	for voice_set in GameData.voice_sets():
		for action in voice_set.get("lines", {}):
			for line in voice_set["lines"][action]:
				var path = VoiceBank.line_path(voice_set, line)
				if not VoiceBank.load_stream(path) is AudioStream:
					_fail("cannot load '{0}'".format([path]))


func _check_faction_voices():
	"""every faction's voice override exists, and a faction's own units never talk with the
	voice of the other faction's own units (a Syndicate raider is no Foundry tank crew)"""
	var own_sets = {}  # faction -> {set id: unit id}
	for faction in GameData.voices().get("faction_voices", {}):
		if GameData.faction_by_id(faction) == null:
			_fail("faction_voices names unknown faction '{0}'".format([faction]))
		for unit_id in GameData.voices()["faction_voices"][faction]:
			var set_id = GameData.voices()["faction_voices"][faction][unit_id]
			if GameData.unit_by_id(unit_id) == null:
				_fail("faction_voices.{0} names unknown unit '{1}'".format([faction, unit_id]))
			if GameData.voice_set_by_id(set_id) == null:
				_fail("faction_voices.{0}.{1} uses missing set '{2}'".format([faction, unit_id, set_id]))
	for unit in GameData.units():
		if unit.get("category") == "structure":
			continue
		for faction in unit.get("factions", []):
			var set_id = GameData.voice_set_id_for(unit, faction)
			if GameData.voice_set_by_id(set_id) == null:
				_fail("{0} unit '{1}' has no voice set".format([faction, unit["id"]]))
				continue
			if GameData.voice_set_by_id(set_id).get("kind") == "speech":
				own_sets[faction] = own_sets.get(faction, {})
				own_sets[faction][set_id] = unit["id"]
	for faction in own_sets:
		for other in own_sets:
			if other == faction:
				continue
			for set_id in own_sets[faction]:
				if set_id in own_sets[other]:
					_fail(
						"{0} '{1}' and {2} '{3}' share the voice '{4}'".format(
							[faction, own_sets[faction][set_id], other, own_sets[other][set_id], set_id]
						)
					)
	var foundry_militia = GameData.voice_set_id_for(GameData.unit_by_id("militia"), "foundry")
	if foundry_militia == GameData.voice_set_id_for(GameData.unit_by_id("militia"), "syndicate"):
		_fail("Foundry and Syndicate militia share a voice")


func _check_no_repeats():
	var bank = VoiceBank.new()
	for voice_set in GameData.voice_sets():
		for action in voice_set.get("lines", {}):
			if voice_set["lines"][action].size() < 2:
				continue
			var last = null
			var heard = {}
			for i in range(DRAWS):
				var stream = bank.pick(voice_set["id"], action)
				if stream == last:
					_fail("'{0}/{1}' repeated a line back to back".format([voice_set["id"], action]))
					break
				last = stream
				heard[stream] = true
			if heard.size() != voice_set["lines"][action].size():
				_fail("'{0}/{1}' never played some lines".format([voice_set["id"], action]))


func _check_in_match():
	var match_node = load("res://tests/manual/TestDesert.tscn").instantiate()
	add_child(match_node)
	await _frames(20)
	var human = get_tree().get_nodes_in_group("players")[0]
	var voices = human.find_child("UnitVoicesController")
	var advisor = human.find_child("VoiceNarratorController")
	var mute = func(controller): controller.find_child("AudioStreamPlayer").volume_db = -80.0
	mute.call(voices)
	mute.call(advisor)
	var expected = []  # [faction, unit id, voice set]
	for faction_units in [
		["", ["drone", "scout_buggy", "militia", "tank", "helicopter", "worker"]],
		["foundry", ["militia", "tank", "heavy_tank", "artillery", "battle_tank", "helicopter"]],
		["syndicate", ["militia", "raider", "rocket_technical", "missile_truck", "helicopter", "gunship"]],
	]:
		for unit_id in faction_units[1]:
			var set_id = GameData.voice_set_id_for(GameData.unit_by_id(unit_id), faction_units[0])
			expected.append([faction_units[0], unit_id, set_id])
	var drone_set = GameData.voice_set_id_for(GameData.unit_by_id("drone"))
	if drone_set == GameData.voice_set_id_for(GameData.unit_by_id("militia")):
		_fail("the drone shares the infantry voice")
	if GameData.voice_set_by_id(drone_set).get("kind") != "machine":
		_fail("the drone does not use machine sounds")
	var original_faction = human.faction
	var spot = 0
	for case in expected:
		var unit_id = case[1]
		human.faction = case[0]
		spot += 1
		var entry = GameData.unit_by_id(unit_id)
		var unit = load(entry["scene"]).instantiate()
		MatchSignals.setup_and_spawn_unit.emit(
			unit, Transform3D(Basis(), Vector3(16 + spot, 0, 20)), human
		)
		await _frames(2)
		for action in ["select", "move", "attack", "retreat", "build", "cannot"]:
			voices.find_child("AudioStreamPlayer").stop()
			if action == "select":
				MatchSignals.unit_selected.emit(unit)
				await _frames(1)
			elif action == "retreat":
				voices._damage_ms[unit.get_instance_id()] = Time.get_ticks_msec()
				MatchSignals.units_ordered.emit([unit], "move")
				voices._damage_ms.erase(unit.get_instance_id())
			else:
				MatchSignals.units_ordered.emit([unit], action)
			_expect(voices.last_line, case[2], action, case[0] + " " + unit_id)
		voices.find_child("AudioStreamPlayer").stop()
		voices._under_attack_ms = -INF
		MatchSignals.unit_damaged.emit(unit)
		_expect(voices.last_line, case[2], "under_attack", case[0] + " " + unit_id)
		voices.find_child("AudioStreamPlayer").stop()
		MatchSignals.unit_production_finished.emit(unit, unit)  # any own producer will do
		_expect(voices.last_line, case[2], "ready", case[0] + " " + unit_id)
		voices.last_line = {}
		unit.queue_free()
		await _frames(1)
	human.faction = original_faction
	await _check_advisor(human, advisor)
	match_node.queue_free()
	await _frames(2)


func _expect(last_line, set_id, action, unit_id):
	if last_line.get("set") != set_id or last_line.get("action") != action:
		_fail(
			"{0} '{1}' played {2}, expected {3}/{4}".format(
				[unit_id, action, last_line, set_id, action]
			)
		)


func _check_advisor(human, advisor):
	var player = advisor.find_child("AudioStreamPlayer")
	var cases = [
		["tier", func(): MatchSignals.tier_reached.emit(human, 2), "tier_industrial"],
		["low oil", func(): human.set("oil", 0), "low_oil"],
		["helper", func(): advisor._on_helper_alert("detour"), "constructor_rerouted"],
		["placement", func(): MatchSignals.structure_placement_refused.emit(human), "cannot_place"],
		["broke", func(): MatchSignals.not_enough_resources_for_construction.emit(human), "not_enough_resources"],
	]
	for case in cases:
		player.stop()
		advisor.last_event = null
		case[1].call()
		if case[0] == "low oil":
			advisor._poll()
		if advisor.last_event != case[2]:
			_fail("advisor said {0} on {1}, expected {2}".format([advisor.last_event, case[0], case[2]]))


func _write_report(path):
	var config = GameData.voices()
	var out = ["# Unit voices and sounds", ""]
	out.append("Generated by `tests/audio/VoiceCheck.tscn -- --report=" + path + "`.")
	out.append("Voice sets live in `data/sounds/`, the files in `assets/audio/voices/`.")
	out.append("")
	out.append("| Unit | Voice set | Syndicate voice | Kind | Lines (select / move / attack / retreat / build / cannot / under attack / ready) |")
	out.append("| --- | --- | --- | --- | --- |")
	for unit in GameData.units():
		var set_id = GameData.voice_set_id_for(unit)
		var syndicate_set = GameData.voice_set_id_for(unit, "syndicate")
		var voice_set = GameData.voice_set_by_id(set_id)
		var counts = []
		for action in config.get("unit_actions", []):
			counts.append(str(voice_set.get("lines", {}).get(action, []).size()))
		out.append(
			"| {0} | {1} | {2} | {3} | {4} |".format(
				[
					unit["id"],
					set_id,
					syndicate_set if syndicate_set != set_id else "same",
					voice_set.get("kind", ""),
					" / ".join(counts)
				]
			)
		)
	for voice_set in GameData.voice_sets():
		out.append("")
		out.append("## " + voice_set["id"] + " (" + voice_set.get("kind", "") + ")")
		out.append("")
		out.append(voice_set.get("description", ""))
		out.append("")
		for action in voice_set.get("lines", {}):
			var texts = voice_set["lines"][action].map(
				func(line): return line.get("text", line.get("file", "")) if line is Dictionary else str(line)
			)
			if voice_set.get("kind") == "machine":
				out.append("- **{0}**: {1} variants".format([action, texts.size()]))
			else:
				out.append("- **{0}**: {1}".format([action, " · ".join(texts)]))
	var file = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("\n".join(out) + "\n")
	file.close()
	print("report written to ", path)


func _frames(count):
	for i in range(count):
		await get_tree().process_frame
