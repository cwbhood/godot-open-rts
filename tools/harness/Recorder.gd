extends Node

# Writes down what happens in a harness match: a timeline of key events (units built and
# lost, tiers, wars, trades, refused placements, script errors, commands given), a metrics
# sample every few game seconds (frame time, process time, units, stock per player),
# screenshots, and at the end a short report:
#
#   <out>/report.md      what a person reads first: verdict, checks, numbers, screenshots
#   <out>/report.json    the same for scripts and the batch runner
#   <out>/timeline.jsonl one event per line
#   <out>/metrics.csv    one sample per line
#   <out>/shots/*.png

const Human = preload("res://source/match/players/human/Human.gd")
const Structure = preload("res://source/match/units/Structure.gd")


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


var out_dir = "user://harness"
var api = null
var sample_every_s = 5.0
var shots_every_s = 0.0  # 0: only the screenshots a scenario asks for
var three_d_off = false  # 3D is only switched on for screenshots
var shot_size = Vector2i(0, 0)  # 0: the window size

var timeline = []  # [{t, kind, text, ...}]
var samples = []  # [{t, real_s, frame_ms, ...}]
var shots = []  # [{t, name, path}]
var frame_times_ms = []  # every rendered frame since the match started
var process_times_ms = []
var last_frame_ms = 0.0
var logger = ErrorLogger.new()

var _deaths = {}  # player index -> {kind: count}, folded into the timeline every sample
var _next_sample_s = 0.0
var _next_shot_s = 0.0
var _last_frame_us = 0
var _real_start_us = 0
var _shooting = false
var _timeline_file = null


func _ready():
	name = "Recorder"
	process_mode = Node.PROCESS_MODE_ALWAYS
	OS.add_logger(logger)


func start():
	DirAccess.make_dir_recursive_absolute(out_dir.path_join("shots"))
	_timeline_file = FileAccess.open(out_dir.path_join("timeline.jsonl"), FileAccess.WRITE)
	_real_start_us = Time.get_ticks_usec()
	_last_frame_us = _real_start_us
	_next_shot_s = shots_every_s if shots_every_s > 0.0 else INF
	# a unit is already out of the tree (no player) when it reports its death, so remember
	# every unit's owner while it lives
	for unit in get_tree().get_nodes_in_group("units"):
		_tag_owner(unit)
	MatchSignals.unit_spawned.connect(_tag_owner)
	MatchSignals.unit_died.connect(_on_unit_died)
	MatchSignals.unit_construction_finished.connect(
		func(unit): _event("built", "%s built %s" % [_who(unit.player), api.kind_of(unit)])
	)
	MatchSignals.unit_production_finished.connect(
		func(unit, _producer):
			_event("produced", "%s produced %s" % [_who(unit.player), api.kind_of(unit)], true)
	)
	MatchSignals.tier_reached.connect(
		func(player, tier): _event("tier", "%s reached tier %d" % [_who(player), tier])
	)
	MatchSignals.diplomacy_changed.connect(
		func(a, b, state):
			_event("diplomacy", "%s and %s: %s" % [_who(a), _who(b), _diplomacy_name(state)])
	)
	MatchSignals.trade_completed.connect(
		func(proposer, partner, offered, requested):
			_event(
				"trade",
				"%s traded %s for %s with %s" % [_who(proposer), offered, requested, _who(partner)]
			)
	)
	MatchSignals.structure_placement_refused.connect(
		func(player): _event("placement_refused", "%s: placement refused" % _who(player))
	)
	MatchSignals.unit_cap_reached.connect(
		func(player): _event("unit_cap", "%s hit the unit cap" % _who(player), true)
	)
	MatchSignals.resources_depleted.connect(func(): _event("depleted", "the map ran dry"))
	MatchSignals.match_limit_reached.connect(
		func(reason, _ranking): _event("match_limit", "match limit: %s" % reason)
	)
	MatchSignals.match_finished_with_victory.connect(
		func(): _event("match_end", "the human player won")
	)
	MatchSignals.match_finished_with_defeat.connect(
		func(): _event("match_end", "the human player lost")
	)


func _process(_delta):
	if _real_start_us == 0:
		return
	var now = Time.get_ticks_usec()
	last_frame_ms = (now - _last_frame_us) / 1000.0
	_last_frame_us = now
	if not _shooting:
		frame_times_ms.append(last_frame_ms)
		process_times_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)


func _physics_process(_delta):
	if _real_start_us == 0 or api == null:
		return
	if api.elapsed_s >= _next_sample_s:
		_next_sample_s += sample_every_s
		_sample()
	if api.elapsed_s >= _next_shot_s and not _shooting:
		_next_shot_s += shots_every_s
		screenshot("t%04d" % int(api.elapsed_s))


func real_seconds():
	return (Time.get_ticks_usec() - _real_start_us) / 1000000.0


func _sample():
	var recent = frame_times_ms.slice(-30)
	var sample = {
		"t": snapped(api.elapsed_s, 0.1),
		"real_s": snapped(real_seconds(), 0.1),
		"frame_ms": snapped(_mean(recent), 0.01),
		"frame_ms_max": snapped(recent.max() if not recent.is_empty() else 0.0, 0.01),
		"process_ms": snapped(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.01),
		"physics_ms":
		snapped(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.01),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"units": get_tree().get_nodes_in_group("units").size(),
	}
	for player in api.players():
		var prefix = "p%d_" % player.get_index()
		var mine = get_tree().get_nodes_in_group("units").filter(
			func(unit): return unit.player == player
		)
		sample[prefix + "units"] = mine.filter(func(unit): return not unit is Structure).size()
		sample[prefix + "structures"] = mine.filter(func(unit): return unit is Structure).size()
		var stock = player.get_stock()
		for resource in stock:
			sample[prefix + resource] = int(stock[resource])
	samples.append(sample)
	for index in _deaths:
		var lost = _deaths[index]
		var parts = []
		for kind in lost:
			parts.append("%d %s" % [lost[kind], kind])
		_event("losses", "p%d lost %s" % [index, ", ".join(parts)], true, {"player": index})
	_deaths.clear()


func _tag_owner(unit):
	if unit.player != null:
		unit.set_meta("harness_owner", unit.player)


func _on_unit_died(unit):
	var owner = unit.get_meta("harness_owner", null)
	if owner == null or not is_instance_valid(owner) or not owner.is_inside_tree():
		return  # the match is closing
	var index = owner.get_index()
	var lost = _deaths.get(index, {})
	lost[api.kind_of(unit)] = lost.get(api.kind_of(unit), 0) + 1
	_deaths[index] = lost
	if unit is Structure:
		_event("structure_lost", "%s lost a %s" % [_who(owner), api.kind_of(unit)])


func _who(player):
	if player == null or not is_instance_valid(player):
		return "nobody"
	var label = "p%d" % player.get_index()
	if player is Human:
		return label + " (you)"
	if "personality_id" in player:
		return "%s (%s)" % [label, player.personality_id]
	return label


static func _diplomacy_name(state):
	return (
		["war", "neutral", "pact", "alliance"][state] if state is int and state < 4 else str(state)
	)


func _event(kind, text, minor = false, extra = {}):
	var entry = {
		"t": snapped(api.elapsed_s if api != null else 0.0, 0.1), "kind": kind, "text": text
	}
	entry.merge(extra)
	if minor:
		entry["minor"] = true
	timeline.append(entry)
	if _timeline_file != null:
		_timeline_file.store_line(JSON.stringify(entry))
		_timeline_file.flush()


func note(text, kind = "note"):
	_event(kind, text)
	print("[%7.1f] %s" % [api.elapsed_s if api != null else 0.0, text])


func note_command(order, result):
	var short = order.duplicate()
	short.erase("do")
	var text = (
		"%s %s -> %s"
		% [
			order["do"],
			JSON.stringify(short),
			"ok" if result.get("ok") else result.get("error", "failed")
		]
	)
	_event("command", text, result.get("ok", false))


func screenshot(label):
	"""saves the current view; switches 3D on for it when the run keeps 3D off"""
	_shooting = true
	if three_d_off:
		get_viewport().disable_3d = false
		for _i in range(3):
			await RenderingServer.frame_post_draw
	else:
		await RenderingServer.frame_post_draw
	var image = get_viewport().get_texture().get_image()
	if three_d_off:
		get_viewport().disable_3d = true
	_shooting = false
	if image == null or image.is_empty():
		return ""
	if shot_size.x > 0 and image.get_width() > shot_size.x:
		image.resize(shot_size.x, int(image.get_height() * float(shot_size.x) / image.get_width()))
	var file = "%02d-%s.png" % [shots.size(), label.validate_filename()]
	var path = out_dir.path_join("shots").path_join(file)
	image.save_png(path)
	shots.append({"t": snapped(api.elapsed_s, 0.1), "name": label, "path": "shots/" + file})
	return path


# --- numbers ---------------------------------------------------------------------------


static func _mean(values):
	if values.is_empty():
		return 0.0
	var total = 0.0
	for value in values:
		total += value
	return total / values.size()


static func percentile(values, share):
	if values.is_empty():
		return 0.0
	var sorted = values.duplicate()
	sorted.sort()
	return sorted[clamp(int(ceil(share * sorted.size())) - 1, 0, sorted.size() - 1)]


func metrics():
	# the first 3 s after the start are loading hitches, not gameplay
	var skip = 0
	var waited = 0.0
	while skip < frame_times_ms.size() and waited < 3000.0:
		waited += frame_times_ms[skip]
		skip += 1
	var frames = frame_times_ms.slice(skip)
	var scripts = process_times_ms.slice(skip)
	var real_s = real_seconds()
	return {
		"game_s": snapped(api.elapsed_s, 0.1),
		"real_s": snapped(real_s, 0.1),
		"game_speed": snapped(api.elapsed_s / max(real_s, 0.001), 0.01),
		"frames": frames.size(),
		"fps_mean": snapped(1000.0 / max(_mean(frames), 0.001), 0.1),
		"frame_ms_p50": snapped(percentile(frames, 0.5), 0.01),
		"frame_ms_p95": snapped(percentile(frames, 0.95), 0.01),
		"frame_ms_p99": snapped(percentile(frames, 0.99), 0.01),
		"frame_ms_max": snapped(frames.max() if not frames.is_empty() else 0.0, 0.01),
		"process_ms_p50": snapped(percentile(scripts, 0.5), 0.01),
		"process_ms_p95": snapped(percentile(scripts, 0.95), 0.01),
		"slow_frames_over_50ms": frames.filter(func(ms): return ms > 50.0).size(),
		"script_errors": _total(logger.errors),
		"warnings": _total(logger.warnings),
		"three_d": not three_d_off,
	}


static func _total(counts):
	var total = 0
	for key in counts:
		total += counts[key]
	return total


# --- the report ------------------------------------------------------------------------


func write_report(info, checks, final_state):
	"""info: name, verdict, seed, settings...; checks: [{name, ok, detail}]"""
	var numbers = metrics()
	var report = info.duplicate()
	report["metrics"] = numbers
	report["checks"] = checks
	report["errors"] = logger.errors
	report["warnings"] = logger.warnings
	report["timeline"] = timeline
	report["shots"] = shots
	report["final"] = {"t": final_state.get("t"), "players": final_state.get("players")}
	var json = FileAccess.open(out_dir.path_join("report.json"), FileAccess.WRITE)
	json.store_string(JSON.stringify(report, "  "))
	json.close()
	_write_metrics_csv()
	var markdown = FileAccess.open(out_dir.path_join("report.md"), FileAccess.WRITE)
	markdown.store_string(_markdown(report))
	markdown.close()
	return report


func _write_metrics_csv():
	var file = FileAccess.open(out_dir.path_join("metrics.csv"), FileAccess.WRITE)
	if samples.is_empty():
		file.close()
		return
	var columns = []
	for sample in samples:
		for key in sample:
			if not key in columns:
				columns.append(key)
	file.store_line(",".join(columns))
	for sample in samples:
		file.store_line(",".join(columns.map(func(key): return str(sample.get(key, "")))))
	file.close()


func _markdown(report):
	var lines = []
	var verdict = report.get("verdict", "?")
	var icon = {"pass": "PASS", "fail": "FAIL", "crash": "CRASH"}.get(verdict, verdict.to_upper())
	lines.append("# %s: %s" % [icon, report.get("name", "harness run")])
	lines.append("")
	if report.get("description", "") != "":
		lines.append(report["description"])
		lines.append("")
	var m = report["metrics"]
	(
		lines
		. append(
			(
				"Map **%s**, seed %s, %s game seconds in %s real seconds (%sx), 3D %s. Ended: %s."
				% [
					report.get("map", "?"),
					report.get("seed", "?"),
					m["game_s"],
					m["real_s"],
					m["game_speed"],
					"on" if m["three_d"] else "off between screenshots",
					report.get("ended", "?"),
				]
			)
		)
	)
	lines.append("")
	lines.append("## Checks")
	lines.append("")
	if report["checks"].is_empty():
		lines.append("No checks in this scenario.")
	for check in report["checks"]:
		lines.append(
			(
				"- %s **%s** %s"
				% ["ok  " if check["ok"] else "FAIL", check["name"], check.get("detail", "")]
			)
		)
	lines.append("")
	lines.append("## Players at the end")
	lines.append("")
	lines.append("| Player | Type | Units | Structures | Tier | Stock | At war with |")
	lines.append("| --- | --- | --- | --- | --- | --- | --- |")
	for player in report["final"].get("players", []):
		var stock = player["stock"]
		var stock_text = ", ".join(stock.keys().map(func(key): return "%s %d" % [key, stock[key]]))
		(
			lines
			. append(
				(
					"| p%d %s | %s | %d | %d | %d | %s | %s |"
					% [
						player["index"],
						player.get("personality", ""),
						player["type"],
						player["units"],
						player["structures"],
						player["tier"],
						stock_text,
						player["at_war_with"],
					]
				)
			)
		)
	lines.append("")
	lines.append("## Speed")
	lines.append("")
	lines.append(
		(
			(
				"Frame time p50 %s ms, p95 %s ms, p99 %s ms, worst %s ms (%s fps on average). "
				+ "Process time p95 %s ms. %d frames over 50 ms. %d script errors, %d warnings."
			)
			% [
				m["frame_ms_p50"],
				m["frame_ms_p95"],
				m["frame_ms_p99"],
				m["frame_ms_max"],
				m["fps_mean"],
				m["process_ms_p95"],
				m["slow_frames_over_50ms"],
				m["script_errors"],
				m["warnings"]
			]
		)
	)
	if not m["three_d"]:
		lines.append("")
		lines.append(
			(
				"3D was off, so frame times show the CPU side only. Run with --view=window on a PC "
				+ "for real GPU numbers."
			)
		)
	if not report["errors"].is_empty():
		lines.append("")
		lines.append("## Script errors")
		lines.append("")
		for text in report["errors"]:
			lines.append("- %dx %s" % [report["errors"][text], text])
	lines.append("")
	lines.append("## What happened")
	lines.append("")
	var shown = report["timeline"].filter(func(entry): return not entry.get("minor", false))
	for entry in shown.slice(0, 80):
		lines.append("- %s %s" % [_clock(entry["t"]), entry["text"]])
	if shown.size() > 80:
		lines.append("- ... %d more in timeline.jsonl" % (shown.size() - 80))
	if not report["shots"].is_empty():
		lines.append("")
		lines.append("## Screenshots")
		lines.append("")
		for shot in report["shots"]:
			lines.append("![%s at %s](%s)" % [shot["name"], _clock(shot["t"]), shot["path"]])
	lines.append("")
	return "\n".join(lines)


static func _clock(seconds):
	return "%d:%02d" % [int(seconds) / 60, int(seconds) % 60]
