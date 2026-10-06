extends Resource

# The player's settings, saved to Constants.OPTIONS_FILE_PATH (see save()). Every setter
# applies its setting at once, so loading the file at startup (Globals.gd) applies them all.
# What depends on a running match (shadows, ambient occlusion, glow) is applied by
# source/options/GraphicsQuality.gd, which listens to `changed`.

enum Screen { FULL = 0, WINDOW = 1, EXCLUSIVE = 2 }
enum Quality { LOW = 0, MEDIUM = 1, HIGH = 2, ULTRA = 3 }

const VirtualPointer = preload("res://source/utils/VirtualPointer.gd")
const GraphicsQuality = preload("res://source/options/GraphicsQuality.gd")

const VOLUME_BUSES = {
	"master_volume": "Master",
	"music_volume": "Music",
	"effects_volume": "Effects",
	"voices_volume": "Voices",
	"ambience_volume": "Ambience",
}
const RESOLUTIONS = [
	Vector2i(1280, 720),
	Vector2i(1366, 768),
	Vector2i(1600, 900),
	Vector2i(1920, 1080),
	Vector2i(2560, 1440),
	Vector2i(3840, 2160),
]
const MAX_FPS_CHOICES = [0, 30, 60, 90, 120, 144, 165, 240]  # 0: unlimited
const UI_SCALE_MIN = 0.75
const UI_SCALE_MAX = 1.5
# what "Reset to defaults" resets (the unit models are a choice of art, not a setting)
const RESETTABLE = [
	"screen",
	"window_resolution",
	"vsync",
	"max_fps",
	"render_scale",
	"graphics_quality",
	"master_volume",
	"music_volume",
	"effects_volume",
	"voices_volume",
	"ambience_volume",
	"mute_when_unfocused",
	"ui_scale",
	"show_fps",
	"camera_scroll_speed",
	"edge_scrolling",
	"invert_zoom",
	"mouse_restricted",
]

# --- video
@export var screen: Screen = Screen.FULL:
	set = _set_screen
# the window size in windowed mode; Vector2i.ZERO keeps whatever size the window has
@export var window_resolution = Vector2i.ZERO:
	set = _set_window_resolution
@export var vsync = true:
	set = _set_vsync
@export var max_fps = 0:
	set = _set_max_fps
@export_range(0.5, 1.0) var render_scale = 1.0:
	set = _set_render_scale
@export var graphics_quality: Quality = Quality.HIGH:
	set = _set_graphics_quality
# the unit art from before the play-ready Blender models (see GameData.use_classic_models)
@export var classic_unit_models = false
# the match's art direction, a file in data/looks (see source/match/environment/Look.gd);
# empty: the game's default look
@export var art_style = ""

# --- audio (linear, 0..1)
@export_range(0.0, 1.0) var master_volume = 1.0:
	set(value):
		master_volume = clampf(value, 0.0, 1.0)
		_apply_volume("master_volume")
@export_range(0.0, 1.0) var music_volume = 0.7:
	set(value):
		music_volume = clampf(value, 0.0, 1.0)
		_apply_volume("music_volume")
@export_range(0.0, 1.0) var effects_volume = 1.0:
	set(value):
		effects_volume = clampf(value, 0.0, 1.0)
		_apply_volume("effects_volume")
@export_range(0.0, 1.0) var voices_volume = 1.0:
	set(value):
		voices_volume = clampf(value, 0.0, 1.0)
		_apply_volume("voices_volume")
@export_range(0.0, 1.0) var ambience_volume = 0.8:
	set(value):
		ambience_volume = clampf(value, 0.0, 1.0)
		_apply_volume("ambience_volume")
# read by source/options/OptionsRuntime.gd
@export var mute_when_unfocused = true

# --- interface
@export_range(0.75, 1.5) var ui_scale = 1.0:
	set = _set_ui_scale
@export var show_fps = false:
	set(value):
		show_fps = value
		emit_changed()

# --- camera and mouse (read by IsometricCamera3D.gd)
@export_range(0.25, 3.0) var camera_scroll_speed = 1.0
@export var edge_scrolling = true
@export var invert_zoom = false
@export var mouse_restricted = false:
	set = _set_mouse_restricted


func _init():
	_apply_stored_options()


func save():
	return ResourceSaver.save(self, Constants.OPTIONS_FILE_PATH)


func apply_audio():
	for property in VOLUME_BUSES:
		_apply_volume(property)


func reset_to_defaults():
	var defaults = get_script().new()
	for property in RESETTABLE:
		set(property, defaults.get(property))
	emit_changed()


func _set_screen(value):
	screen = value
	_apply_screen()


func _set_window_resolution(value):
	window_resolution = value
	_apply_window_resolution()


func _set_vsync(value):
	vsync = value
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED
	)


func _set_max_fps(value):
	max_fps = max(int(value), 0)
	Engine.max_fps = max_fps


func _set_render_scale(value):
	render_scale = clampf(value, 0.5, 1.0)
	var root = _root()
	if root != null:
		root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		root.scaling_3d_scale = render_scale


func _set_graphics_quality(value):
	graphics_quality = value
	var root = _root()
	if root != null:
		GraphicsQuality.apply_global(graphics_quality, root)
	emit_changed()


func _set_ui_scale(value):
	ui_scale = clampf(value, UI_SCALE_MIN, UI_SCALE_MAX)
	var root = _root()
	if root != null:
		root.content_scale_factor = ui_scale


func _set_mouse_restricted(value):
	mouse_restricted = value
	_apply_mouse_restricted()


func _apply_stored_options():
	_apply_screen()
	_apply_mouse_restricted()
	apply_audio()
	_set_vsync(vsync)
	_set_max_fps(max_fps)
	_set_render_scale(render_scale)
	_set_graphics_quality(graphics_quality)
	_set_ui_scale(ui_scale)


func _apply_screen():
	var mode = (
		{
			Screen.FULL: DisplayServer.WINDOW_MODE_FULLSCREEN,
			Screen.WINDOW: DisplayServer.WINDOW_MODE_WINDOWED,
			Screen.EXCLUSIVE: DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN,
		}
		. get(screen, DisplayServer.WINDOW_MODE_FULLSCREEN)
	)
	if DisplayServer.window_get_mode() != mode:
		DisplayServer.window_set_mode(mode)
	_apply_window_resolution()


func _apply_window_resolution():
	if screen != Screen.WINDOW or window_resolution == Vector2i.ZERO:
		return
	if DisplayServer.get_name() == "headless":
		return
	var screen_index = DisplayServer.window_get_current_screen()
	var usable = DisplayServer.screen_get_usable_rect(screen_index)
	var size = Vector2i(
		mini(window_resolution.x, usable.size.x), mini(window_resolution.y, usable.size.y)
	)
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_position(usable.position + (usable.size - size) / 2)


func _apply_volume(property):
	var bus = AudioServer.get_bus_index(VOLUME_BUSES[property])
	if bus < 0:
		return
	var volume = get(property)
	AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(volume, 0.0001)))
	AudioServer.set_bus_mute(bus, volume <= 0.0)


func _apply_mouse_restricted():
	# never trap the cursor of someone whose PC runs a scripted match (tools/harness/)
	if mouse_restricted and not VirtualPointer.active:
		Input.set_mouse_mode(Input.MOUSE_MODE_CONFINED)
	else:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


static func _root():
	var tree = Engine.get_main_loop() as SceneTree
	return tree.root if tree != null else null
