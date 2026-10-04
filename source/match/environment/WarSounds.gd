extends Node3D

# Sounds of battle: weapon fire, shell impacts, rocket hits and units blowing up.
#
# Nothing in the combat code has to call this. It watches the scene tree: a projectile node
# being added to a unit means that unit just fired, a rocket leaving the tree means it hit,
# and a unit leaving the tree with no hp left means it was destroyed.
#
# Sounds are heard from where the camera looks, like the ambient Soundscape: loudness falls
# with the distance from the middle of the screen, the hearing range grows as the camera zooms
# out, and everything gets quieter the further out the camera is. A listener placed above the
# middle of the screen pans each sound to the side of the screen it comes from. Fights in the
# fog of war are heard, muffled. The sounds come from tools/audio/make_war_sounds.py.

const Unit = preload("res://source/match/units/Unit.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const CannonShell = preload("res://source/match/units/projectiles/CannonShell.gd")
const Rocket = preload("res://source/match/units/projectiles/Rocket.gd")

const AUDIO_DIR = "res://assets/audio/war/"
const SOUNDS = {
	"cannon": 3,
	"heavy_cannon": 2,
	"rifle": 3,
	"rocket": 2,
	"impact": 3,
	"explosion_small": 2,
	"explosion_large": 2,
}
const VOICES = 24
const CLOSE_CAMERA_SIZE = 12.0
const FAR_CAMERA_SIZE = 70.0
const SHELL_SPEED_M_PER_S = 160.0
const HIDDEN_GAIN = 0.4  # neither side of the fight is visible
const MIN_GAIN = 0.03
# how loud each kind of sound is, how many of a kind may overlap, and the shortest gap between
# two of a kind, so that a big battle stays a roar instead of clipping into noise
const KINDS = {
	"cannon": {"gain": 0.75, "max": 5, "gap_s": 0.05},
	"heavy_cannon": {"gain": 0.9, "max": 4, "gap_s": 0.06},
	"rifle": {"gain": 0.5, "max": 4, "gap_s": 0.06},
	"rocket": {"gain": 0.6, "max": 4, "gap_s": 0.07},
	"impact": {"gain": 0.45, "max": 5, "gap_s": 0.05},
	"explosion_small": {"gain": 0.8, "max": 3, "gap_s": 0.12},
	"explosion_large": {"gain": 1.0, "max": 3, "gap_s": 0.2},
}
const RIFLE_UNITS = ["Militia", "Raider"]
const HEAVY_CANNON_UNITS = ["HeavyTank", "BattleTank", "AntiGroundTurret"]
const LIGHT_UNITS = ["Militia", "Raider", "Worker", "Drone", "Pylon"]

var played_counts = {}  # kind -> sounds played so far (read by tests)

var _streams = {}  # kind -> [AudioStream]
var _voices = []
var _voice_kinds = {}  # player -> kind it is playing
var _last_played_ms = {}  # kind -> ticks
var _listener = AudioListener3D.new()
var _pivot = Vector3.ZERO
var _zoom_out = 0.0
var _camera_size = 20.0


func _ready():
	for kind in SOUNDS:
		_streams[kind] = []
		for i in range(1, SOUNDS[kind] + 1):
			_streams[kind].append(load("{0}{1}_{2}.ogg".format([AUDIO_DIR, kind, i])))
	for i in range(VOICES):
		var voice = AudioStreamPlayer3D.new()
		voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		voice.max_distance = 0.0
		voice.panning_strength = 0.7
		voice.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		voice.bus = &"Effects"
		add_child(voice)
		_voices.append(voice)
	add_child(_listener)
	_listener.make_current()
	get_tree().node_added.connect(_on_node_added)


func _process(_delta):
	var camera = get_viewport().get_camera_3d()
	if camera == null or not camera.has_method("get_ray_intersection"):
		return
	var pivot = camera.get_ray_intersection(get_viewport().get_visible_rect().size / 2.0)
	if pivot != null:
		_pivot = pivot
	_camera_size = camera.size
	_zoom_out = clamp(inverse_lerp(CLOSE_CAMERA_SIZE, FAR_CAMERA_SIZE, camera.size), 0.0, 1.0)
	# the listener hovers over the middle of the screen, facing the way the camera faces,
	# so a shot on the left of the screen is heard on the left
	var forward = -camera.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() > 0.0001:
		_listener.global_transform = Transform3D(
			Basis.looking_at(forward.normalized(), Vector3.UP), _pivot + Vector3(0.0, 6.0, 0.0)
		)


func play(kind, at_position, loudness = 1.0, audible = true):
	"""plays one sound of a kind at a world position; returns false if it was not heard"""
	var now = Time.get_ticks_msec()
	var settings = KINDS[kind]
	if now - _last_played_ms.get(kind, -100000) < settings.gap_s * 1000.0:
		return false
	var gain = settings.gain * loudness * _gain_at(at_position)
	if not audible:
		gain *= HIDDEN_GAIN
	if gain < MIN_GAIN:
		return false
	var voice = _pick_voice(kind, settings.max, gain)
	if voice == null:
		return false
	_last_played_ms[kind] = now
	_voice_kinds[voice] = kind
	var streams = _streams[kind]
	voice.stream = streams[randi() % streams.size()]
	voice.global_position = at_position
	voice.volume_db = linear_to_db(gain)
	voice.pitch_scale = randf_range(0.9, 1.08)
	voice.play()
	played_counts[kind] = played_counts.get(kind, 0) + 1
	return true


func _gain_at(at_position):
	var hearing_range = 18.0 + _camera_size * 1.1
	var distance = Vector2(at_position.x, at_position.z).distance_to(Vector2(_pivot.x, _pivot.z))
	var closeness = clamp(1.0 - distance / hearing_range, 0.0, 1.0)
	return closeness * closeness * lerp(1.0, 0.3, _zoom_out)


func _pick_voice(kind, max_of_kind, gain):
	"""a free voice; else the quietest one if the new sound is louder (oldest of a full kind)"""
	var same_kind = []
	var free = null
	var quietest = null
	for voice in _voices:
		if not voice.playing:
			free = voice if free == null else free
			continue
		if _voice_kinds.get(voice) == kind:
			same_kind.append(voice)
		if quietest == null or voice.volume_db < quietest.volume_db:
			quietest = voice
	if same_kind.size() >= max_of_kind:
		var oldest = same_kind[0]
		for voice in same_kind:
			if voice.get_playback_position() > oldest.get_playback_position():
				oldest = voice
		return oldest
	if free != null:
		return free
	if quietest != null and quietest.volume_db < linear_to_db(gain):
		return quietest
	return null


func _on_node_added(node):
	# a projectile is added to its shooter before its _ready deals the damage
	if node is CannonShell:
		_on_cannon_fired(node)
	elif node is Rocket:
		_on_rocket_fired(node)
	elif node is Unit and not node.has_meta("_war_sounds"):
		node.set_meta("_war_sounds", true)
		node.tree_exiting.connect(_on_unit_leaving.bind(node))


func _on_cannon_fired(shell):
	if not is_instance_valid(shell) or not is_instance_valid(shell.target_unit):
		return
	var shooter = shell.get_parent()
	var target = shell.target_unit
	var audible = shooter.visible or target.visible
	var shooter_name = _unit_name(shooter)
	if shooter_name in RIFLE_UNITS:
		play("rifle", shooter.global_position, 1.0, audible)
		return
	var kind = "heavy_cannon" if shooter_name in HEAVY_CANNON_UNITS else "cannon"
	play(kind, shooter.global_position, 1.0, audible)
	# the shell lands a moment later where the target is
	var flight_s = shooter.global_position.distance_to(target.global_position) / SHELL_SPEED_M_PER_S
	var hit_position = target.global_position
	get_tree().create_timer(flight_s + 0.04).timeout.connect(
		play.bind("impact", hit_position, 1.0, audible)
	)


func _on_rocket_fired(rocket):
	if not is_instance_valid(rocket) or not is_instance_valid(rocket.target_unit):
		return
	var shooter = rocket.get_parent()
	var target = rocket.target_unit
	play("rocket", shooter.global_position, 1.0, shooter.visible or target.visible)
	rocket.tree_exiting.connect(_on_rocket_gone.bind(target))


func _on_rocket_gone(target):
	# a rocket leaves when it hits or when its target is already gone (then the target's own
	# explosion is heard instead)
	if is_instance_valid(target) and target.is_inside_tree() and target.hp > 0:
		play("explosion_small", target.global_position, 0.55, target.visible)


func _on_unit_leaving(unit):
	if unit.hp == null or unit.hp > 0 or not unit.is_inside_tree():
		return
	var big = unit is Structure or not _unit_name(unit) in LIGHT_UNITS
	if big:
		play("explosion_large", unit.global_position, 1.0, unit.visible)
	else:
		play("explosion_small", unit.global_position, 0.9, unit.visible)


func _unit_name(unit):
	return unit.scene_file_path.get_file().get_basename()
