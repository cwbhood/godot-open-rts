extends RefCounted

# Turns a crash report into the text that gets sent: a GitHub issue title and a Markdown
# body. The body is what the prompt shows word for word, so the player sees exactly what
# leaves the computer. Paths are shortened and the account name is removed.

const ISSUE_REPO = "cwbhood/godot-open-rts"
const ISSUE_LABEL = "crash-report"
const ENDPOINT_SETTING = "ironbound/crash_reports/endpoint"
const MAX_URL_LENGTH = 7800  # GitHub rejects new-issue links much past 8 KB
const MAX_POST_BODY = 60000  # GitHub issue bodies stop at 65536 characters
const HEADING = "### Ironbound crash report"

const WHAT_HAPPENED = {
	"crash": "The game crashed",
	"hang": "The game froze and did not recover",
	"freeze": "The game froze for a while, then went on",
	"error_storm": "The game logged a flood of errors",
}


static func endpoint():
	"""a crash inbox (tools/crash-inbox/) that files issues for players without GitHub"""
	return str(ProjectSettings.get_setting(ENDPOINT_SETTING, "")).strip_edges()


static func title(report):
	var match_info = report.get("match", {})
	var where = (
		"on %s at %s" % [match_info.get("map", "?"), _clock(match_info.get("match_time_s", 0))]
		if match_info.get("in_match", false)
		else "outside a match"
	)
	var game = report.get("game", {})
	return (
		"Crash report: %s %s (%s %s)"
		% [
			WHAT_HAPPENED.get(report.get("kind", ""), "problem").to_lower().trim_prefix(
				"the game "
			),
			where,
			game.get("version", ""),
			game.get("commit", "").substr(0, 7),
		]
	)


static func body(report, max_chars = MAX_POST_BODY):
	"""max_chars 0 means no limit; otherwise log lines are dropped first, then stacks"""
	var log_tail = report.get("log_tail", [])
	var keep = log_tail.size()
	var with_stacks = true
	while true:
		var text = _scrub(_compose(report, log_tail.slice(log_tail.size() - keep), with_stacks))
		if max_chars <= 0 or text.length() <= max_chars:
			return text
		if keep > 10:
			keep = max(10, keep - max(5, keep / 4))
		elif with_stacks:
			with_stacks = false
		elif keep > 0:
			keep = 0
		else:
			return text.substr(0, max_chars)
	return ""


static func issue_url(report):
	"""a prefilled new-issue page; returns [url, body actually in the url]"""
	var base = (
		"https://github.com/%s/issues/new?labels=%s&title=%s&body="
		% [ISSUE_REPO, ISSUE_LABEL, title(report).uri_encode()]
	)
	var limit = 6000
	while true:
		var text = body(report, limit)
		var url = base + text.uri_encode()
		if url.length() <= MAX_URL_LENGTH or limit < 500:
			return [url, text]
		limit = int(limit * 0.85)
	return ["", ""]


static func _compose(report, log_tail, with_stacks):
	var game = report.get("game", {})
	var system = report.get("system", {})
	var match_info = report.get("match", {})
	var perf = report.get("perf", {})
	var lines = [HEADING, ""]
	var events = report.get("events", [])
	var detail = events[-1].get("detail", "") if not events.is_empty() else ""
	lines.append(
		"**What happened:** %s%s." % [WHAT_HAPPENED.get(report.get("kind", ""), "?"), _then(detail)]
	)
	lines.append("")
	(
		lines
		. append(
			(
				"- **Game:** %s %s, commit %s%s, %s build%s, Godot %s"
				% [
					game.get("name", ""),
					game.get("version", ""),
					_or_unknown(game.get("commit", "")),
					" on " + game["branch"] if game.get("branch", "") != "" else "",
					game.get("build", ""),
					", run from the editor" if game.get("editor_run", false) else "",
					game.get("godot", ""),
				]
			)
		)
	)
	if match_info.get("in_match", false):
		(
			lines
			. append(
				(
					"- **Match:** %s, players %s, match time %s%s%s, %d units"
					% [
						match_info.get("map", "?"),
						", ".join(match_info.get("players", [])),
						_clock(match_info.get("match_time_s", 0)),
						", paused" if match_info.get("paused", false) else "",
						", weather " + match_info["weather"] if match_info.has("weather") else "",
						match_info.get("units", 0),
					]
				)
			)
		)
	else:
		lines.append("- **Screen:** %s (not in a match)" % match_info.get("scene", "?").get_file())
	var performance = [
		"%d fps" % perf.get("fps", 0),
		"frame %s ms" % perf.get("frame_ms", 0),
		"physics %s ms" % perf.get("physics_ms", 0),
		"%d nodes" % perf.get("nodes", 0),
		"%d MB RAM" % perf.get("memory_mb", 0),
		"%d MB VRAM" % perf.get("video_memory_mb", 0),
		"played %s" % _clock(perf.get("run_time_s", 0)),
	]
	lines.append("- **Performance:** " + ", ".join(performance))
	(
		lines
		. append(
			(
				"- **System:** %s %s, %s (%d threads), %s %s, driver %s, %s/%s, screen %s"
				% [
					system.get("os", ""),
					system.get("os_version", ""),
					system.get("cpu", ""),
					system.get("cpu_threads", 0),
					system.get("gpu_vendor", ""),
					system.get("gpu", ""),
					_or_unknown(system.get("gpu_driver", "")),
					system.get("renderer", ""),
					system.get("rendering_driver", ""),
					system.get("screen", ""),
				]
			)
		)
	)
	if events.size() > 1:
		lines.append("- **Timeline:** " + "; ".join(events.map(_event_text)))
	var backtrace = report.get("engine_backtrace", [])
	if not backtrace.is_empty():
		lines += ["", "**Engine backtrace**", "```text"] + backtrace + ["```"]
	var errors = report.get("errors", [])
	if not errors.is_empty():
		lines += ["", "**Errors** (%d different, most frequent first)" % errors.size(), "```text"]
		for error in errors:
			lines.append(
				(
					"x%d %s: %s (%s)"
					% [error["count"], error["kind"], error["message"], error["where"]]
				)
			)
			if with_stacks and error.get("stack", "") != "":
				lines.append(error["stack"])
		lines.append("```")
	if not log_tail.is_empty():
		lines += ["", "**Last %d log lines**" % log_tail.size(), "```text"] + log_tail + ["```"]
	lines += ["", "Report %s, format %d" % [report.get("session_id", ""), report.get("format", 0)]]
	return "\n".join(lines)


static func _event_text(event):
	return (
		"%s at %s (%s)"
		% [event.get("kind", ""), _clock(event.get("match_time_s", 0)), event.get("detail", "")]
	)


static func _then(detail):
	return ": " + detail if detail != "" else ""


static func _or_unknown(text):
	return text if str(text) != "" else "unknown"


static func _clock(seconds):
	seconds = int(seconds)
	return "%d:%02d" % [seconds / 60, seconds % 60]


static func _scrub(text):
	"""no account names or personal folders: paths become user://, res:// or ~"""
	var replacements = [
		[OS.get_user_data_dir(), "user:/"],
		[ProjectSettings.globalize_path("res://").trim_suffix("/"), "res:/"],
		[OS.get_executable_path().get_base_dir(), "<game folder>"],
	]
	for variable in ["HOME", "USERPROFILE"]:
		var home = OS.get_environment(variable)
		if home.length() > 3:
			replacements.append([home, "~"])
			replacements.append([home.replace("\\", "/"), "~"])
	for replacement in replacements:
		if replacement[0].length() > 3:
			text = text.replace(replacement[0], replacement[1])
			text = text.replace(replacement[0].replace("/", "\\"), replacement[1])
	for variable in ["USER", "USERNAME", "LOGNAME"]:
		var user = OS.get_environment(variable)
		if user.length() >= 2:  # only inside paths, a plain word may be the same as the name
			for separator in ["/", "\\"]:
				text = text.replace(separator + user + separator, separator + "<user>" + separator)
	return text
