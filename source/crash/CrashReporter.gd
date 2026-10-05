extends Node

# Writes a crash report to user://crash_reports/ when the game crashes, freezes or floods the
# log with errors. Nothing leaves the computer unless the player agrees on the next launch
# (see CrashPrompt.gd).
#
# How each case is caught:
# - crash: every run keeps sessions/<id>.json up to date (match, fps, last log lines, errors)
#   and deletes it on a clean exit. A file left behind by a process that is gone means that
#   run died; the next launch turns it into a report and adds the engine backtrace from the
#   previous godot.log.
# - hang: a watchdog thread notices when the main thread has not finished a frame for HANG_S
#   seconds and writes a report straight away, so it exists even if the player kills the game.
#   A freeze that ends on its own is kept as a "freeze" report.
# - error storm: STORM_ERRORS engine or script errors within STORM_WINDOW_MS.
#
# Command line (after --):
#   --hang-exit=SECONDS   after a freeze this long, write the report and kill the process
#                         (QA runs use it so a stuck match doesn't stall the batch)
#   --crash-test=KIND:S   crash, hang or storm S seconds into a match (or after start without
#                         a match), to test this reporter
#   --crash-log=PATH      the path given to Godot's --log-file; runs in parallel share
#                         godot.log, so they need their own log for the crash backtrace
#   --no-crash-reports    turn the reporter off for this run

const ReportText = preload("res://source/crash/ReportText.gd")

const FORMAT = 1
const DIR = "user://crash_reports"
const SESSIONS_DIR = DIR + "/sessions"
const SENT_DIR = DIR + "/sent"
const DISMISSED_DIR = DIR + "/dismissed"
const HEARTBEAT_S = 2.0
const CONTEXT_S = 1.0
const STALE_S = 15.0
const HANG_S = 20.0
const STORM_ERRORS = 100
const STORM_WINDOW_MS = 10000
const LOG_LINES = 120
const MAX_ERROR_KINDS = 20
const LOG_MARKER = "crash reporter session "
const SIGNALS = {
	"4": "illegal instruction",
	"6": "abort",
	"7": "bus error",
	"8": "floating point error",
	"11": "segmentation fault",
}
const SEVERITY = {"error_storm": 1, "freeze": 2, "hang": 3, "crash": 4}


class ReportLogger:
	extends Logger
	var mutex = Mutex.new()
	var lines = []
	var errors = {}  # message + place -> {message, where, kind, count, stack, first_ms}
	var recent_errors_ms = []
	var storm = false

	func _log_message(message, error):
		mutex.lock()
		for line in message.strip_edges(false, true).split("\n"):
			_push(("[stderr] " if error else "") + line)
		mutex.unlock()

	func _log_error(
		function, file, line, code, rationale, _editor_notify, error_type, script_backtraces
	):
		var message = rationale if rationale != "" else code
		var where = "%s:%d in %s()" % [file, line, function]
		var kind = ["ERROR", "WARNING", "SCRIPT ERROR", "SHADER ERROR"][error_type]
		var stack = ""
		for backtrace in script_backtraces:
			if backtrace != null and not backtrace.is_empty():
				stack += backtrace.format(0, 2)
		var now = Time.get_ticks_msec()
		mutex.lock()
		_push("%s: %s (%s)" % [kind, message, where])
		if error_type != ERROR_TYPE_WARNING:
			var key = message + where
			if key in errors:
				errors[key]["count"] += 1
			elif errors.size() < MAX_ERROR_KINDS:
				errors[key] = {
					"kind": kind,
					"message": message,
					"where": where,
					"stack": stack.strip_edges(false, true),
					"count": 1,
					"first_ms": now,
				}
			recent_errors_ms.append(now)
			while recent_errors_ms[0] < now - STORM_WINDOW_MS:
				recent_errors_ms.pop_front()
			if recent_errors_ms.size() >= STORM_ERRORS:
				storm = true
		mutex.unlock()

	func _push(line):
		lines.append(line)
		if lines.size() > LOG_LINES:
			lines.pop_front()

	func snapshot():
		mutex.lock()
		var copy = {"log_tail": lines.duplicate(), "errors": errors.values().duplicate(true)}
		mutex.unlock()
		copy["errors"].sort_custom(func(a, b): return a["count"] > b["count"])
		return copy


var enabled = true
var session_id = ""

var _logger = ReportLogger.new()
var _args = {}
var _static_info = {}
var _context = {}
var _context_mutex = Mutex.new()
var _report_mutex = Mutex.new()
var _session_mutex = Mutex.new()
var _events = []
var _beat_ms = 0
var _watchdog = null
var _stop_watchdog = false
var _hang_exit_s = 0.0
var _crash_test = []
var _match = null
var _atmosphere = null
var _match_time_s = 0.0
var _run_time_s = 0.0
var _next_context_s = 0.0
var _next_heartbeat_s = 0.0
var _storm_reported = false
var _started_utc = ""
var _log_file = ""  # --crash-log, see the header


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--"):
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	if "no-crash-reports" in _args:
		enabled = false
		return
	_hang_exit_s = float(_args.get("hang-exit", "0"))
	if _args.get("crash-test", "") != "":
		var parts = _args["crash-test"].split(":")
		_crash_test = [parts[0], float(parts[1]) if parts.size() > 1 else 5.0]
	for directory in [SESSIONS_DIR, SENT_DIR, DISMISSED_DIR]:
		DirAccess.make_dir_recursive_absolute(directory)
	_started_utc = Time.get_datetime_string_from_system(true)
	session_id = "%s-%d" % [_started_utc.replace(":", "").replace("-", ""), OS.get_process_id()]
	_static_info = _collect_static_info()
	if _args.get("crash-log", "") != "":
		_log_file = ProjectSettings.globalize_path(_args["crash-log"])
	OS.add_logger(_logger)
	print(LOG_MARKER + session_id)
	collect_dead_sessions()
	_beat_ms = Time.get_ticks_msec()
	_update_context()
	_write_session()
	# a debugger stopped on a breakpoint looks exactly like a freeze, so runs launched from
	# the editor only report crashes and error storms
	if not EngineDebugger.is_active() or "hang-watch" in _args:
		_watchdog = Thread.new()
		_watchdog.start(_watch)


func _exit_tree():
	if not enabled:
		return
	_stop_watchdog = true
	if _watchdog != null:
		_watchdog.wait_to_finish()
	OS.remove_logger(_logger)
	DirAccess.remove_absolute(_session_path())


func _process(delta):
	if not enabled:
		return
	_beat_ms = Time.get_ticks_msec()
	_run_time_s += delta
	if _run_time_s >= _next_context_s:
		_next_context_s = _run_time_s + CONTEXT_S
		_update_context()
	if _watchdog == null and _run_time_s >= _next_heartbeat_s:
		_next_heartbeat_s = _run_time_s + HEARTBEAT_S
		_write_session()
	if _logger.storm and not _storm_reported:
		_storm_reported = true
		_update_context()
		_record_event(
			"error_storm", "%d errors within %d s" % [STORM_ERRORS, STORM_WINDOW_MS / 1000]
		)
	if not _crash_test.is_empty():
		_run_crash_test()


func _physics_process(delta):
	if _match != null and is_instance_valid(_match) and not get_tree().paused:
		_match_time_s += delta


func set_hang_exit(seconds):
	"""QA runners: kill the process after a freeze this long so the batch goes on"""
	if not "hang-exit" in _args:
		_hang_exit_s = seconds


func own_report():
	"""this run's report so far (hang, freeze or error storm), or null"""
	return _read_json(_report_path(session_id)) if enabled else null


# --- reports on disk


func pending_reports():
	"""newest first; each entry is the report dictionary with its "path" added"""
	var reports = []
	for file_name in DirAccess.get_files_at(DIR):
		if file_name.ends_with(".json"):
			var report = _read_json(DIR + "/" + file_name)
			if report is Dictionary and report.get("format", 0) == FORMAT:
				report["path"] = DIR + "/" + file_name
				reports.append(report)
	reports.sort_custom(func(a, b): return a.get("time_utc", "") > b.get("time_utc", ""))
	return reports.filter(func(report): return report.get("session_id") != session_id)


func mark_report(report, sent):
	"""moves a pending report (json and txt) to sent/ or dismissed/"""
	var target = SENT_DIR if sent else DISMISSED_DIR
	var path = report["path"]
	for extension in [".json", ".txt"]:
		var from = path.get_basename() + extension
		if FileAccess.file_exists(from):
			DirAccess.rename_absolute(from, target + "/" + from.get_file())


func reports_for_session(id):
	for directory in [DIR, SENT_DIR, DISMISSED_DIR]:
		var path = directory + "/report_%s.json" % id
		if FileAccess.file_exists(path):
			return _read_json(path)
	return null


func collect_dead_sessions():
	"""turns session files of processes that are gone into crash reports"""
	var converted = []
	for file_name in DirAccess.get_files_at(SESSIONS_DIR):
		var path = SESSIONS_DIR + "/" + file_name
		var session = _read_json(path)
		if not session is Dictionary:
			if Time.get_unix_time_from_system() - FileAccess.get_modified_time(path) > STALE_S:
				DirAccess.remove_absolute(path)  # cut off mid-write by the crash
			continue
		if session.get("session_id", "") == session_id:
			continue
		# OS.is_process_running only knows child processes, so a session counts as alive while
		# its heartbeat is fresh; the watchdog thread keeps beating even when the game freezes
		var backtrace = _engine_backtrace_from_previous_log(session)
		var fresh = Time.get_unix_time_from_system() - FileAccess.get_modified_time(path) < STALE_S
		if fresh and backtrace.is_empty():
			continue
		DirAccess.remove_absolute(path)
		var report = _crash_report_from_session(session, backtrace)
		if report != null:
			_save_report(report)
			converted.append(report)
	return converted


func _crash_report_from_session(session, backtrace):
	var existing = _read_json(_report_path(session["session_id"]))
	var hang = existing is Dictionary and existing.get("kind") in ["hang", "freeze"]
	var detail = ""
	if not backtrace.is_empty():
		detail = backtrace[0] if backtrace.size() > 0 else "engine crash"
	elif hang:
		detail = "the game was closed while frozen"
	elif session.get("game", {}).get("editor_run", false):
		return null  # stopped from the editor; Godot gives no signal for that
	else:
		detail = "the game stopped without a clean exit (killed, out of memory or power loss)"
	var report = existing if existing is Dictionary else session.duplicate(true)
	report["kind"] = "crash" if not hang or not backtrace.is_empty() else "hang"
	report["engine_backtrace"] = backtrace
	var at = session.get("match", {}).get("match_time_s", 0)
	report["events"] = (
		report.get("events", []) + [{"kind": "crash", "detail": detail, "match_time_s": at}]
	)
	report["time_utc"] = session.get("heartbeat_utc", report.get("time_utc", ""))
	if not hang:
		for key in ["match", "perf", "log_tail", "errors"]:
			report[key] = session.get(key, report.get(key))
	return report


func _engine_backtrace_from_previous_log(session):
	"""Godot renames the previous godot.log at start-up; its crash handler output ends it"""
	var logs_dir = "user://logs"
	var candidates = []
	if session.get("log_file", "") != "":
		candidates.append(session["log_file"])
	for file_name in DirAccess.get_files_at(logs_dir):
		if file_name.begins_with("godot") and file_name.ends_with(".log"):
			candidates.append(logs_dir + "/" + file_name)
	var started = int(session.get("started_unix", 0))
	for path in candidates:
		if not FileAccess.file_exists(path) or FileAccess.get_modified_time(path) < started:
			continue
		var text = FileAccess.get_file_as_string(path)
		if text.find(LOG_MARKER + session["session_id"]) == -1:
			continue  # several runs share user://logs, only trust this session's log
		var at = text.find("Program crashed with signal")
		if at == -1:
			at = text.find("CrashHandlerException")
		if at == -1:
			continue
		return _summarize_crash_log(text.substr(0, at).split("\n"), text.substr(at).split("\n"))
	return []


func _summarize_crash_log(before, after):
	"""the crash line, the last log lines before it and the GDScript backtrace; the C++
	frames of official builds have no symbols, so only their count is kept"""
	var lines = [after[0].strip_edges()]
	var signal_number = after[0].get_slice("signal", 1).strip_edges()
	if signal_number in SIGNALS:
		lines[0] += " (%s)" % SIGNALS[signal_number]
	var cpp_frames = 0
	var in_gdscript = false
	for line in after.slice(1):
		line = line.strip_edges()
		if line.begins_with("Engine version"):
			lines.append(line)
		elif line.begins_with("GDScript backtrace"):
			in_gdscript = true
			lines.append(line)
		elif line.begins_with("-- END OF GDSCRIPT"):
			in_gdscript = false
		elif in_gdscript and line != "":
			lines.append("  " + line)
		elif line.begins_with("[") and not in_gdscript:
			cpp_frames += 1
	lines.append("(%d C++ frames without symbols left out)" % cpp_frames)
	var tail = Array(before).filter(func(line): return line.strip_edges() != "")
	tail = tail.slice(max(0, tail.size() - 25))
	tail = tail.filter(func(line): return not line.strip_edges().begins_with("====="))
	return lines + ["", "Log before the crash:"] + tail


# --- watchdog thread


func _watch():
	var stalled_ms = 0
	var reported = false
	var next_heartbeat_ms = 0
	while not _stop_watchdog:
		OS.delay_msec(250)
		if Time.get_ticks_msec() >= next_heartbeat_ms:
			next_heartbeat_ms = Time.get_ticks_msec() + int(HEARTBEAT_S * 1000.0)
			_write_session()
		var stalled_now = Time.get_ticks_msec() - _beat_ms
		if stalled_now >= HANG_S * 1000.0:
			stalled_ms = stalled_now
			if not reported or stalled_now % 5000 < 250:
				reported = true
				_record_event("hang", "no frame for %d s" % int(stalled_ms / 1000.0), false)
			if _hang_exit_s > 0.0 and stalled_now >= _hang_exit_s * 1000.0:
				_record_event(
					"hang",
					"frozen for %d s, killed by --hang-exit" % int(stalled_ms / 1000.0),
					false
				)
				OS.kill(OS.get_process_id())
		elif reported:
			reported = false
			_record_event(
				"freeze", "the game froze for %d s, then went on" % int(stalled_ms / 1000.0)
			)


# --- building reports


func _record_event(kind, detail, append = true):
	"""Writes (or updates) this session's report. Called from the main or watchdog thread."""
	_report_mutex.lock()
	var report = _read_json(_report_path(session_id))
	if not report is Dictionary:
		report = {}
	var event = {"kind": kind, "detail": detail, "match_time_s": _context.get("match_time_s", 0)}
	var events = report.get("events", [])
	if append or events.is_empty() or events[-1]["kind"] != kind:
		events.append(event)
	else:
		events[-1] = event
	var previous_kind = report.get("kind", "")
	report.merge(_snapshot(), true)
	report["events"] = events
	if kind == "freeze" and previous_kind == "hang":
		report["kind"] = "freeze"
	elif SEVERITY.get(kind, 0) >= SEVERITY.get(previous_kind, 0):
		report["kind"] = kind
	else:
		report["kind"] = previous_kind
	report["time_utc"] = Time.get_datetime_string_from_system(true)
	_save_report(report)
	_report_mutex.unlock()


func _snapshot():
	_context_mutex.lock()
	var context = _context.duplicate(true)
	_context_mutex.unlock()
	var logged = _logger.snapshot()
	return {
		"format": FORMAT,
		"session_id": session_id,
		"pid": OS.get_process_id(),
		"started_utc": _started_utc,
		"started_unix": int(Time.get_unix_time_from_system() - _run_time_s),
		"heartbeat_utc": Time.get_datetime_string_from_system(true),
		"game": _static_info["game"],
		"system": _static_info["system"],
		"args": OS.get_cmdline_user_args(),
		"log_file": _log_file,
		"match": context.get("match", {}),
		"perf": context.get("perf", {}),
		"errors": logged["errors"],
		"log_tail": logged["log_tail"],
	}


func _write_session():
	_session_mutex.lock()
	var file = FileAccess.open(_session_path(), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_snapshot(), " "))
		file.close()
	_session_mutex.unlock()


func _save_report(report):
	var path = _report_path(report["session_id"])
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(report, " "))
	file.close()
	file = FileAccess.open(path.get_basename() + ".txt", FileAccess.WRITE)
	file.store_string(ReportText.body(report, 0))
	file.close()
	_copy_to_qa_output(report, path)


func _copy_to_qa_output(report, path):
	"""QA runs pass --out=DIR; their reports also land there next to report.txt. Runs that
	pass --out=FILE (Simulate, MatchPerf: a .json summary) get them next to that file."""
	for argument in report.get("args", []):
		if argument.begins_with("--out="):
			var out = argument.substr(6)
			# a directory named like the summary file would stop the run writing it at the end
			if out.get_extension() != "":
				out = out.get_base_dir()
			DirAccess.make_dir_recursive_absolute(out)
			for extension in [".json", ".txt"]:
				DirAccess.copy_absolute(
					path.get_basename() + extension, out + "/crash_report" + extension
				)


func _session_path():
	return SESSIONS_DIR + "/" + session_id + ".json"


func _report_path(id):
	return DIR + "/report_%s.json" % id


func _read_json(path):
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


# --- context


func _update_context():
	if _match == null or not is_instance_valid(_match):
		var found = get_tree().get_first_node_in_group("match")
		if found != _match:
			_match_time_s = 0.0
		_match = found
	var info = {"in_match": false, "scene": ""}
	var scene = get_tree().current_scene
	if scene != null:
		info["scene"] = scene.scene_file_path
	if _match != null and is_instance_valid(_match) and _match.is_inside_tree():
		info = _match_info(info)
	var perf = {
		"fps": Engine.get_frames_per_second(),
		"frame_ms": snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.1),
		"physics_ms":
		snappedf(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, 0.1),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"memory_mb": int(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0),
		"video_memory_mb":
		int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0),
		"time_scale": Engine.time_scale,
		"run_time_s": int(_run_time_s),
	}
	_context_mutex.lock()
	_context = {"match": info, "perf": perf, "match_time_s": int(_match_time_s)}
	_context_mutex.unlock()


func _match_info(info):
	info["in_match"] = true
	info["match_time_s"] = int(_match_time_s)
	info["paused"] = get_tree().paused
	var map_path = _match.map.scene_file_path if _match.map != null else ""
	info["map"] = Constants.Match.MAPS.get(map_path, {}).get("name", map_path.get_file())
	var players = []
	var controller_names = {
		Constants.PlayerType.HUMAN: "human",
		Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI: "AI",
	}
	for player_settings in _match.settings.players:
		var controller = controller_names.get(player_settings.controller, "none")
		if controller == "AI":
			controller += " " + str(player_settings.ai_personality)
		players.append(controller)
	info["players"] = players
	info["sandbox"] = bool(_match.settings.get("sandbox"))
	info["units"] = get_tree().get_nodes_in_group("units").size()
	if _atmosphere == null or not is_instance_valid(_atmosphere):
		_atmosphere = _match.find_child("Atmosphere", true, false)
	if _atmosphere != null:
		info["weather"] = str(_atmosphere.get("_weather"))
	return info


func _collect_static_info():
	var version = ProjectSettings.get_setting("application/config/version", "")
	var git = _git_info()
	return {
		"game":
		{
			"name": ProjectSettings.get_setting("application/config/name", ""),
			"version": version,
			"commit": git["commit"],
			"branch": git["branch"],
			"build": "debug" if OS.is_debug_build() else "release",
			"godot": Engine.get_version_info()["string"],
			"editor_run": EngineDebugger.is_active(),
		},
		"system":
		{
			"os": OS.get_name(),
			"os_version": OS.get_version(),
			"cpu": OS.get_processor_name(),
			"cpu_threads": OS.get_processor_count(),
			"gpu": RenderingServer.get_video_adapter_name(),
			"gpu_vendor": RenderingServer.get_video_adapter_vendor(),
			"gpu_driver": " ".join(OS.get_video_adapter_driver_info()),
			"renderer": RenderingServer.get_current_rendering_method(),
			"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
			"screen": str(DisplayServer.screen_get_size()),
			"window": str(DisplayServer.window_get_size()),
			"locale": OS.get_locale(),
		},
	}


func _git_info():
	"""exported builds read build_info.json (make build-info), source runs read .git"""
	if FileAccess.file_exists("res://build_info.json"):
		var info = _read_json("res://build_info.json")
		if info is Dictionary:
			return {"commit": info.get("commit", ""), "branch": info.get("branch", "")}
	var result = {"commit": "", "branch": ""}
	var git_dir = ProjectSettings.globalize_path("res://.git")
	if not FileAccess.file_exists(git_dir + "/HEAD"):
		return result
	var head = FileAccess.get_file_as_string(git_dir + "/HEAD").strip_edges()
	if not head.begins_with("ref: "):
		result["commit"] = head.substr(0, 10)
		return result
	var ref = head.substr(5)
	result["branch"] = ref.trim_prefix("refs/heads/")
	if FileAccess.file_exists(git_dir + "/" + ref):
		result["commit"] = FileAccess.get_file_as_string(git_dir + "/" + ref).strip_edges()
	elif FileAccess.file_exists(git_dir + "/packed-refs"):
		for line in FileAccess.get_file_as_string(git_dir + "/packed-refs").split("\n"):
			if line.ends_with(" " + ref):
				result["commit"] = line.split(" ")[0]
	result["commit"] = result["commit"].substr(0, 10)
	return result


# --- self test


func _run_crash_test():
	var in_match = _match != null and is_instance_valid(_match)
	var clock = _match_time_s if in_match else _run_time_s
	if clock < _crash_test[1]:
		return
	var kind = _crash_test[0]
	_crash_test = []
	print("crash test: %s at %.0f s" % [kind, clock])
	_update_context()
	_write_session()
	match kind:
		"crash":
			OS.crash("crash test requested with --crash-test")
		"hang":
			var until = Time.get_ticks_msec() + 3600 * 1000
			while Time.get_ticks_msec() < until:
				OS.delay_msec(100)
		"freeze":
			OS.delay_msec(int((HANG_S + 5.0) * 1000.0))
		"storm":
			for i in range(STORM_ERRORS + 5):
				push_error("crash test error %d" % i)
		"script":
			var missing = null
			missing.call("crash_test")
