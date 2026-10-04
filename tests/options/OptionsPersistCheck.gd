extends Node

# Checks that options survive a restart and are applied at startup. Run it twice:
#   godot --path . res://tests/options/OptionsPersistCheck.tscn -- --phase=write
#   godot --path . res://tests/options/OptionsPersistCheck.tscn -- --phase=read
# "write" changes settings away from their defaults and saves them; "read" (a new
# process) checks that Globals.options loaded them and that they took effect, then puts
# the defaults back. Exits with code 1 if anything failed.

const VALUES = {
	"master_volume": 0.5,
	"music_volume": 0.25,
	"effects_volume": 0.4,
	"voices_volume": 0.0,
	"ambience_volume": 0.3,
	"mute_when_unfocused": false,
	"screen": 1,
	"window_resolution": Vector2i(1280, 720),
	"vsync": false,
	"max_fps": 90,
	"render_scale": 0.75,
	"graphics_quality": 0,
	"ui_scale": 1.25,
	"show_fps": true,
	"camera_scroll_speed": 1.5,
	"edge_scrolling": false,
	"invert_zoom": true,
}

var _failures = 0


func _ready():
	var phase = "read"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--phase="):
			phase = arg.trim_prefix("--phase=")
	await get_tree().process_frame
	if phase == "write":
		for property in VALUES:
			Globals.options.set(property, VALUES[property])
		_check("saved", Globals.options.save() == OK)
	else:
		for property in VALUES:
			_check(
				"{0} persisted ({1})".format([property, Globals.options.get(property)]),
				Globals.options.get(property) == VALUES[property]
			)
		var music = AudioServer.get_bus_index("Music")
		_check("Music bus exists", music > 0)
		_check(
			"Music bus volume applied",
			is_equal_approx(AudioServer.get_bus_volume_db(music), linear_to_db(0.25))
		)
		_check(
			"Voices bus muted at 0%", AudioServer.is_bus_mute(AudioServer.get_bus_index("Voices"))
		)
		_check("frame rate limit applied", Engine.max_fps == 90)
		_check("UI scale applied", is_equal_approx(get_tree().root.content_scale_factor, 1.25))
		_check("render scale applied", is_equal_approx(get_tree().root.scaling_3d_scale, 0.75))
		_check("low quality: no MSAA", get_tree().root.msaa_3d == Viewport.MSAA_DISABLED)
		_check(
			"windowed mode applied",
			DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED
		)
		_check("FPS counter shown", Globals.find_child("FpsCounter", true, false).visible)
		Globals.options.reset_to_defaults()
		Globals.options.save()
	print("DONE failures=", _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _check(text, ok):
	print(("PASS " if ok else "FAIL ") + text)
	if not ok:
		_failures += 1
