extends Node

# Opens the real main menu with pending crash reports and saves screenshots of the prompt
# in both delivery modes. With --endpoint=URL it also presses Send and checks the crash
# inbox answered (tests/crash/fake_inbox.py stands in for the Cloudflare Worker).
#
#   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --resolution 1600x900 \
#     res://tests/crash/CrashPromptCheck.tscn -- --out=/tmp/prompt --endpoint=http://127.0.0.1:8787

const ReportText = preload("res://source/crash/ReportText.gd")

var _args = {"out": "user://crash_prompt"}


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	DirAccess.make_dir_recursive_absolute(_args["out"])
	var pending = CrashReporter.pending_reports()
	print("pending reports: %d" % pending.size())
	if pending.is_empty():
		get_tree().quit(1)
		return
	var menu = load("res://source/main-menu/Main.tscn").instantiate()
	add_child(menu)
	await _frames(20)
	await _shot("1-prompt-github")
	var prompt = menu.get_child(menu.get_child_count() - 1)
	var url = prompt.get("_url")
	print("github url length: %d" % url.length())
	if "endpoint" in _args:
		ProjectSettings.set_setting(ReportText.ENDPOINT_SETTING, _args["endpoint"])
		prompt.call("_show_report")
		await _frames(5)
		await _shot("2-prompt-inbox")
		prompt.call("_on_send")
		var waited = 0
		while is_instance_valid(prompt) and waited < 600:
			await _frames(1)
			waited += 1
			if waited == 30:
				await _shot("3-sent")
		var sent = DirAccess.get_files_at(CrashReporter.SENT_DIR).size()
		print("sent reports: %d" % sent)
		get_tree().quit(0 if sent > 0 else 1)
		return
	get_tree().quit(0)


func _shot(name):
	await _frames(3)
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_args["out"], name])


func _frames(count):
	for _i in range(count):
		await get_tree().process_frame
