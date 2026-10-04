extends Node

# Plays many matches, each in its own Godot process (so a crash or freeze only loses that
# one match), and tabulates them in <out>/batch.md, batch.csv and batch.json. Given a
# baseline (an earlier batch.json), it also lists regressions: a run that passed before and
# fails now, new script errors, a crash or freeze, or a frame time more than 25% worse.
#
# A batch file either lists scenarios ("runs") or crosses one scenario with a "matrix" of
# maps, AI personalities, difficulties and seeds. See docs/testing/play-harness.md.

signal finished(ok)

const ScenarioRunner = preload("res://tools/harness/ScenarioRunner.gd")

var batch = {}
var out_dir = "user://harness-batch"
var forward_args = []  # engine arguments for the children (renderer, resolution)
var extra_user_args = []  # --view, --speed... passed on to every run
var baseline_path = ""

var _runs = []  # [{key, scenario, dir, pid, started_ms, status, report}]


func _ready():
	name = "BatchRunner"
	process_mode = Node.PROCESS_MODE_ALWAYS


func run():
	DirAccess.make_dir_recursive_absolute(out_dir)
	_runs = _expand()
	if _runs.is_empty():
		print("HARNESS BATCH: nothing to run")
		finished.emit(false)
		return
	print("HARNESS BATCH %s: %d matches" % [batch.get("name", "batch"), _runs.size()])
	var parallel = max(1, int(batch.get("parallel", 1)))
	var timeout_ms = float(batch.get("timeout_minutes", 30.0)) * 60000.0
	while _runs.any(func(run_entry): return run_entry["status"] in ["waiting", "running"]):
		var running = _runs.filter(func(run_entry): return run_entry["status"] == "running")
		for entry in running:
			if not OS.is_process_running(entry["pid"]):
				_collect(entry, OS.get_process_exit_code(entry["pid"]))
			elif Time.get_ticks_msec() - entry["started_ms"] > timeout_ms:
				OS.kill(entry["pid"])
				_collect(entry, -1, "freeze: killed after %.0f minutes" % (timeout_ms / 60000.0))
		running = _runs.filter(func(run_entry): return run_entry["status"] == "running")
		for entry in _runs:
			if running.size() >= parallel:
				break
			if entry["status"] == "waiting":
				_launch(entry)
				running.append(entry)
		await get_tree().create_timer(0.5).timeout
	var ok = _write_tables()
	finished.emit(ok)


func _expand():
	var runs = []
	var base = batch.get("override", {})
	if batch.has("runs"):
		for name_or_object in batch["runs"]:
			var scenario = (
				name_or_object
				if name_or_object is Dictionary
				else ScenarioRunner.load_file(str(name_or_object))
			)
			if scenario == null:
				continue
			scenario = scenario.duplicate(true)
			scenario.merge(base, true)
			runs.append(_entry(scenario.get("name", "run"), scenario, runs.size()))
	if batch.has("scenario"):
		var template = ScenarioRunner.load_file(str(batch["scenario"]))
		if template == null:
			return runs
		var matrix = batch.get("matrix", {})
		var combos = [{}]
		for axis in ["map", "ai", "difficulty", "seed"]:
			if not matrix.has(axis):
				continue
			var grown = []
			for combo in combos:
				for value in matrix[axis]:
					var next = combo.duplicate()
					next[axis] = value
					grown.append(next)
			combos = grown
		for combo in combos:
			var scenario = template.duplicate(true)
			scenario.merge(base, true)
			_apply_combo(scenario, combo)
			var key_parts = [template.get("name", str(batch["scenario"]).get_basename())]
			for axis in combo:
				key_parts.append(str(combo[axis]))
			runs.append(_entry("-".join(key_parts), scenario, runs.size()))
	return runs


static func _apply_combo(scenario, combo):
	if combo.has("map"):
		scenario["map"] = combo["map"]
	if combo.has("seed"):
		scenario["seed"] = combo["seed"]
	var players = scenario.get("players", ScenarioRunner.DEFAULTS["players"]).duplicate(true)
	if combo.has("ai"):
		var personalities = str(combo["ai"]).split(",")
		var kept = players.filter(func(entry): return entry.get("type") == "human")
		for personality in personalities:
			kept.append({"type": "ai", "personality": personality})
		players = kept
	if combo.has("difficulty"):
		for entry in players:
			if entry.get("type", "ai") != "human":
				entry["difficulty"] = combo["difficulty"]
	scenario["players"] = players
	scenario["name"] = "%s %s" % [scenario.get("name", "run"), combo]


func _entry(key, scenario, index):
	var safe = key.validate_filename().replace(" ", "_")
	return {
		"key": key,
		"scenario": scenario,
		"dir": out_dir.path_join("runs").path_join("%02d-%s" % [index, safe]),
		"status": "waiting",
		"pid": -1,
	}


func _launch(entry):
	var directory = ProjectSettings.globalize_path(entry["dir"])
	DirAccess.make_dir_recursive_absolute(directory)
	var scenario_path = directory.path_join("scenario.json")
	var file = FileAccess.open(scenario_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(entry["scenario"], "  "))
	file.close()
	var arguments = ["--path", ProjectSettings.globalize_path("res://")]
	arguments.append_array(forward_args)
	arguments.append_array(
		[
			"res://tools/harness/Harness.tscn",
			"--",
			"--scenario=" + scenario_path,
			"--out=" + directory
		]
	)
	arguments.append_array(extra_user_args)
	entry["pid"] = OS.create_process(OS.get_executable_path(), arguments)
	entry["started_ms"] = Time.get_ticks_msec()
	entry["status"] = "running" if entry["pid"] > 0 else "failed_to_start"
	print("  start %s (pid %d)" % [entry["key"], entry["pid"]])


func _collect(entry, exit_code, problem = ""):
	var report_path = ProjectSettings.globalize_path(entry["dir"]).path_join("report.json")
	var report = null
	if FileAccess.file_exists(report_path):
		report = JSON.parse_string(FileAccess.get_file_as_string(report_path))
	if report == null:
		report = {"verdict": "crash", "metrics": {}, "checks": []}
		if problem == "":
			problem = "no report: the match crashed (exit code %d)" % exit_code
	if problem != "":
		report["verdict"] = "crash"
		report["problem"] = problem
	entry["report"] = report
	entry["status"] = "done"
	entry["exit_code"] = exit_code
	print(
		(
			"  %s %s %s"
			% [report["verdict"].to_upper(), entry["key"], problem if problem != "" else ""]
		)
	)


func _row(entry):
	var report = entry.get("report", {})
	var metrics = report.get("metrics", {})
	var checks = report.get("checks", [])
	var scenario = entry["scenario"]
	var final_players = report.get("final", {}).get("players", [])
	return {
		"key": entry["key"],
		"map": scenario.get("map", ""),
		"players": ", ".join(scenario.get("players", []).map(ScenarioRunner.player_label)),
		"seed": scenario.get("seed", 1),
		"verdict": report.get("verdict", "crash"),
		"checks_ok": checks.filter(func(check): return check["ok"]).size(),
		"checks": checks.size(),
		"failed_checks":
		checks.filter(func(check): return not check["ok"]).map(func(check): return check["name"]),
		"game_min": snapped(float(metrics.get("game_s", 0)) / 60.0, 0.1),
		"frame_ms_p95": metrics.get("frame_ms_p95", null),
		"process_ms_p95": metrics.get("process_ms_p95", null),
		"script_errors": metrics.get("script_errors", null),
		"units_end": final_players.map(func(player): return player["units"] + player["structures"]),
		"problem": report.get("problem", ""),
		"report": entry["dir"].path_join("report.md"),
	}


func _write_tables():
	var rows = _runs.map(_row)
	var regressions = _regressions(rows)
	var data = {
		"name": batch.get("name", "batch"),
		"rows": rows,
		"regressions": regressions,
		"baseline": baseline_path,
	}
	var json = FileAccess.open(out_dir.path_join("batch.json"), FileAccess.WRITE)
	json.store_string(JSON.stringify(data, "  "))
	json.close()
	var columns = [
		"key",
		"map",
		"players",
		"seed",
		"verdict",
		"checks_ok",
		"checks",
		"game_min",
		"frame_ms_p95",
		"process_ms_p95",
		"script_errors",
		"problem"
	]
	var csv = FileAccess.open(out_dir.path_join("batch.csv"), FileAccess.WRITE)
	csv.store_line(",".join(columns))
	for row in rows:
		csv.store_line(",".join(columns.map(func(column): return '"%s"' % str(row[column]))))
	csv.close()
	var passed = rows.filter(func(row): return row["verdict"] == "pass").size()
	var lines = [
		"# Batch %s: %d of %d passed" % [data["name"], passed, rows.size()],
		"",
	]
	if baseline_path != "":
		lines.append(
			(
				"Compared with %s: %s"
				% [
					baseline_path,
					"%d regression(s)" % regressions.size() if regressions else "no regressions"
				]
			)
		)
		lines.append("")
		for regression in regressions:
			lines.append("- **%s**: %s" % [regression["key"], regression["what"]])
		lines.append("")
	lines.append(
		(
			"| Run | Map | Players | Seed | Result | Checks | Game min | Frame p95 ms "
			+ "| Process p95 ms | Errors | Units at end |"
		)
	)
	lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
	for row in rows:
		(
			lines
			. append(
				(
					"| [%s](%s) | %s | %s | %s | %s | %d/%d | %s | %s | %s | %s | %s |"
					% [
						row["key"],
						row["report"].replace(out_dir + "/", ""),
						row["map"],
						row["players"],
						row["seed"],
						(
							row["verdict"].to_upper()
							+ (" (%s)" % row["problem"] if row["problem"] else "")
						),
						row["checks_ok"],
						row["checks"],
						row["game_min"],
						row["frame_ms_p95"],
						row["process_ms_p95"],
						row["script_errors"],
						row["units_end"],
					]
				)
			)
		)
	var failed = rows.filter(func(row): return row["verdict"] != "pass")
	if not failed.is_empty():
		lines.append("")
		lines.append("## Failed")
		lines.append("")
		for row in failed:
			lines.append(
				(
					"- %s: %s"
					% [row["key"], row["problem"] if row["problem"] else row["failed_checks"]]
				)
			)
	lines.append("")
	var markdown = FileAccess.open(out_dir.path_join("batch.md"), FileAccess.WRITE)
	markdown.store_string("\n".join(lines))
	markdown.close()
	print("\n".join(lines))
	print("HARNESS BATCH report " + ProjectSettings.globalize_path(out_dir.path_join("batch.md")))
	return failed.is_empty() and regressions.is_empty()


func _regressions(rows):
	if baseline_path == "" or not FileAccess.file_exists(baseline_path):
		return []
	var baseline = JSON.parse_string(FileAccess.get_file_as_string(baseline_path))
	if not baseline is Dictionary:
		return []
	var before = {}
	for row in baseline.get("rows", []):
		before[row["key"]] = row
	var found = []
	for row in rows:
		var old = before.get(row["key"])
		if old == null:
			continue
		if old["verdict"] == "pass" and row["verdict"] != "pass":
			found.append({"key": row["key"], "what": "passed before, %s now" % row["verdict"]})
		if row["script_errors"] != null and old["script_errors"] != null:
			if row["script_errors"] > old["script_errors"]:
				found.append(
					{
						"key": row["key"],
						"what":
						"script errors %d -> %d" % [old["script_errors"], row["script_errors"]]
					}
				)
		if row["frame_ms_p95"] != null and old["frame_ms_p95"] != null:
			var was = float(old["frame_ms_p95"])
			var now = float(row["frame_ms_p95"])
			if now > was * 1.25 and now - was > 2.0:
				found.append(
					{"key": row["key"], "what": "frame time p95 %.1f -> %.1f ms" % [was, now]}
				)
	return found
