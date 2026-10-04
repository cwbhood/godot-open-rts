extends Control

# Shown over the main menu when the last run left a crash report behind. It shows the exact
# text that would be sent and sends nothing unless the player presses Send.

const ReportText = preload("res://source/crash/ReportText.gd")

const TITLES = {
	"crash": "Ironbound closed unexpectedly last time",
	"hang": "Ironbound froze last time",
	"freeze": "Ironbound froze for a while last time",
	"error_storm": "Ironbound ran into a flood of errors last time",
}

var _reports = []
var _index = 0
var _body = ""
var _url = ""

var _title = Label.new()
var _counter = Label.new()
var _text = TextEdit.new()
var _route = Label.new()
var _status = Label.new()
var _send = Button.new()
var _skip = Button.new()
var _folder = Button.new()
var _request = HTTPRequest.new()


static func should_show():
	return (
		CrashReporter.enabled
		and DisplayServer.get_name() != "headless"
		and not CrashReporter.pending_reports().is_empty()
	)


func _ready():
	_reports = CrashReporter.pending_reports()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.7)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(dim)
	var center = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color("1d1f24")
	style.border_color = Color("c8873a")
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var margin = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	panel.add_child(margin)
	var column = VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var header = HBoxContainer.new()
	_title.add_theme_font_size_override("font_size", 28)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)
	header.add_child(_counter)
	column.add_child(header)

	var explanation = Label.new()
	explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	explanation.custom_minimum_size.x = 980
	explanation.text = (
		"Send last crash report? It helps find and fix the problem. Nothing is sent unless"
		+ " you press Send. The report holds no personal data: no name, account or address,"
		+ " and folder paths are shortened. Below is exactly what would be sent."
	)
	column.add_child(explanation)

	_text.editable = false
	_text.custom_minimum_size = Vector2(980, 440)
	_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_text.add_theme_font_override("font", _monospace())
	_text.add_theme_font_size_override("font_size", 13)
	var text_style = StyleBoxFlat.new()
	text_style.bg_color = Color("101114")
	text_style.set_content_margin_all(8)
	_text.add_theme_stylebox_override("read_only", text_style)
	_text.add_theme_color_override("font_readonly_color", Color(0.85, 0.87, 0.9))
	column.add_child(_text)

	_route.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_route.custom_minimum_size.x = 980
	_route.modulate = Color(1, 1, 1, 0.75)
	column.add_child(_route)
	_status.visible = false
	column.add_child(_status)

	var buttons = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	_send.text = "Send report"
	_skip.text = "Don't send"
	_folder.text = "Open reports folder"
	for button in [_send, _skip, _folder]:
		button.custom_minimum_size = Vector2(200, 44)
		buttons.add_child(button)
	column.add_child(buttons)
	_send.pressed.connect(_on_send)
	_skip.pressed.connect(_on_skip)
	_folder.pressed.connect(
		func(): OS.shell_open(ProjectSettings.globalize_path(CrashReporter.DIR))
	)
	add_child(_request)
	_request.request_completed.connect(_on_request_completed)
	_show_report()
	_send.grab_focus()


func _show_report():
	var report = _reports[_index]
	_title.text = TITLES.get(report.get("kind", ""), TITLES["crash"])
	_counter.text = "report %d of %d" % [_index + 1, _reports.size()] if _reports.size() > 1 else ""
	if ReportText.endpoint() != "":
		_body = ReportText.body(report)
		_url = ""
		_route.text = (
			"Send uploads this text to the Ironbound crash inbox, which files it as an issue on"
			+ " github.com/%s where the developers read it." % ReportText.ISSUE_REPO
		)
	else:
		var issue = ReportText.issue_url(report)
		_url = issue[0]
		_body = issue[1]
		_route.text = (
			(
				"Send opens a new issue on github.com/%s in your browser with this text filled in."
				% ReportText.ISSUE_REPO
			)
			+ " Nothing is posted until you press Submit there (needs a free GitHub account)."
			+ " The full report stays in the reports folder."
		)
	_text.text = "Title: %s\n\n%s" % [ReportText.title(report), _body]
	_status.visible = false
	_send.disabled = false


func _on_send():
	var report = _reports[_index]
	if _url != "":
		OS.shell_open(_url)
		CrashReporter.mark_report(report, true)
		_next()
		return
	_send.disabled = true
	_status.visible = true
	_status.text = "Sending..."
	var payload = {
		"title": ReportText.title(report),
		"body": _body,
		"report_id": report.get("session_id", ""),
		"format": report.get("format", 0),
	}
	_request.request(
		ReportText.endpoint(),
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		JSON.stringify(payload)
	)


func _on_request_completed(result, code, _headers, _body_bytes):
	if result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300:
		CrashReporter.mark_report(_reports[_index], true)
		_status.text = "Sent. Thank you!"
		await get_tree().create_timer(1.2).timeout
		_next()
	else:
		_status.text = (
			(
				"Could not send it (%s). The report stays in the reports folder"
				+ " and will be offered again next time."
			)
			% ("HTTP %d" % code if result == HTTPRequest.RESULT_SUCCESS else "no connection")
		)
		_send.disabled = false


func _on_skip():
	CrashReporter.mark_report(_reports[_index], false)
	_next()


func _next():
	_index += 1
	if _index < _reports.size():
		_show_report()
	else:
		queue_free()


func _monospace():
	var font = SystemFont.new()
	font.font_names = PackedStringArray(["Consolas", "DejaVu Sans Mono", "Menlo", "monospace"])
	return font
