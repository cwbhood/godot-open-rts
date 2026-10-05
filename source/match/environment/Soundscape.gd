extends Node

# Ambient sound of a match, mixed from where the camera looks:
# - wind, louder with the weather's wind and when zoomed out, howling in sandstorms,
# - rain while it rains,
# - engines of vehicles moving near the middle of the screen: tank diesels and tracks, wheeled
#   trucks, helicopter rotors and drone propellers, each from how many of them move nearby,
# - the noise of the nearest city, fading out with distance and as the camera zooms out,
# - a trade horn when a trade deal goes through or goods reach a depot near the camera.
# The sounds are synthesized by tools/audio/make_soundscape.py and make_war_sounds.py.
# Weapon fire and explosions are WarSounds, a child of this node.

const WarSounds = preload("res://source/match/environment/WarSounds.gd")

const AUDIO_DIR = "res://assets/audio/ambience/"
const WAR_AUDIO_DIR = "res://assets/audio/war/"
const REFRESH_S = 0.25
const FADE_PER_S = 1.5  # how fast volumes follow their targets (linear gain per second)
const CITY_HEARING_RANGE_M = 45.0
const ENGINE_HEARING_RANGE_M = 16.0  # when zoomed in; grows with the camera size
# engine loop -> unit scenes it is heard from; other vehicles (trucks, buggies) hum
const ENGINE_LOOPS = {
	"tank_engine_loop": ["Tank", "HeavyTank", "BattleTank", "Artillery"],
	"rotor_loop": ["Helicopter", "Gunship"],
	"drone_loop": ["Drone"],
}
const SILENT_UNITS = ["Militia"]  # on foot
const CLOSE_CAMERA_SIZE = 12.0
const FAR_CAMERA_SIZE = 70.0
const HORN_COOLDOWN_S = 9.0
const SILENT_DB = -60.0

var _players = {}  # name -> AudioStreamPlayer
var _targets = {}  # name -> linear gain the player fades towards
var _since_refresh = 0.0
var _horn_cooldown = 0.0
var _pivot = Vector3.ZERO
var _zoom_out = 0.0  # 0 close to the ground, 1 fully zoomed out
var _camera_size = CLOSE_CAMERA_SIZE


func _ready():
	for sound_name in ["wind_loop", "rain_loop", "engine_hum_loop", "city_loop"]:
		var stream = load(AUDIO_DIR + sound_name + ".ogg")
		stream.loop = true
		_add_player(sound_name, stream, true)
	for sound_name in ENGINE_LOOPS:
		var stream = load(WAR_AUDIO_DIR + sound_name + ".ogg")
		stream.loop = true
		_add_player(sound_name, stream, true)
	var war_sounds = WarSounds.new()
	war_sounds.name = "WarSounds"
	add_child(war_sounds)
	_add_player("trade_horn", load(AUDIO_DIR + "trade_horn.ogg"), false)
	MatchSignals.trade_completed.connect(_on_trade_completed)
	MatchSignals.goods_delivered.connect(_on_goods_delivered)


func _add_player(sound_name, stream, looping):
	var player = AudioStreamPlayer.new()
	player.name = sound_name.to_pascal_case()
	player.stream = stream
	player.volume_db = SILENT_DB
	add_child(player)
	if looping:
		player.play(randf() * stream.get_length())
	_players[sound_name] = player
	_targets[sound_name] = 0.0


func _process(delta):
	_horn_cooldown = max(_horn_cooldown - delta, 0.0)
	_since_refresh += delta
	if _since_refresh >= REFRESH_S:
		_since_refresh = 0.0
		_update_listener()
		_update_targets()
	for sound_name in _targets:
		if sound_name == "trade_horn":
			continue
		var player = _players[sound_name]
		var gain = db_to_linear(player.volume_db)
		gain = move_toward(gain, _targets[sound_name], FADE_PER_S * delta)
		player.volume_db = max(linear_to_db(gain), SILENT_DB)


func _update_listener():
	var camera = get_viewport().get_camera_3d()
	if camera == null or not camera.has_method("get_ray_intersection"):
		return
	var pivot = camera.get_ray_intersection(get_viewport().get_visible_rect().size / 2.0)
	if pivot != null:
		_pivot = pivot
	_zoom_out = clamp(inverse_lerp(CLOSE_CAMERA_SIZE, FAR_CAMERA_SIZE, camera.size), 0.0, 1.0)
	_camera_size = camera.size


func _update_targets():
	var atmosphere = get_tree().get_first_node_in_group("atmosphere")
	var wind_speed = 1.0
	var rain = 0.0
	var dust = 0.0
	if atmosphere != null:
		wind_speed = atmosphere.get_wind().length()
		rain = atmosphere.get_rain_intensity()
		dust = atmosphere.get_dust_intensity()
	_targets["wind_loop"] = clamp(
		0.12 + wind_speed * 0.05 + _zoom_out * 0.18 + dust * 0.45, 0.0, 0.85
	)
	_targets["rain_loop"] = rain * lerp(0.7, 0.4, _zoom_out)
	var close = 1.0 - _zoom_out
	_targets["city_loop"] = _city_closeness() * close * 0.6
	var engines = _engine_loudness()
	_targets["engine_hum_loop"] = engines.get("engine_hum_loop", 0.0) * close * 0.45
	_targets["tank_engine_loop"] = engines.get("tank_engine_loop", 0.0) * close * 0.6
	_targets["rotor_loop"] = engines.get("rotor_loop", 0.0) * lerp(1.0, 0.5, _zoom_out) * 0.55
	_targets["drone_loop"] = engines.get("drone_loop", 0.0) * close * 0.35


func _city_closeness():
	var closest = INF
	for depot in _depots():
		closest = min(closest, _flat_distance(depot.global_position, _pivot))
	return clamp(1.0 - closest / CITY_HEARING_RANGE_M, 0.0, 1.0)


func _engine_loudness():
	"""loop name -> 0..1 from the moving vehicles that use it, nearer ones counting more"""
	var hearing_range = ENGINE_HEARING_RANGE_M + _camera_size * 0.5
	var weights = {}
	for unit in get_tree().get_nodes_in_group("units"):
		var distance = _flat_distance(unit.global_position, _pivot)
		if distance > hearing_range:
			continue
		var movement = unit.find_child("Movement", false, false)
		if movement == null or movement.velocity.length_squared() <= 0.01:
			continue
		var unit_name = unit.scene_file_path.get_file().get_basename()
		if unit_name in SILENT_UNITS:
			continue
		var loop = "engine_hum_loop"
		for engine_loop in ENGINE_LOOPS:
			if unit_name in ENGINE_LOOPS[engine_loop]:
				loop = engine_loop
		weights[loop] = weights.get(loop, 0.0) + 1.0 - distance / hearing_range
	var loudness = {}
	for loop in weights:
		loudness[loop] = clamp(log(1.0 + weights[loop] * 1.5) / log(10.0), 0.0, 1.0)
	return loudness


func _depots():
	var depots = []
	for player in get_tree().get_nodes_in_group("players"):
		var logistics = player.get_node_or_null("Logistics")
		if logistics != null:
			depots.append_array(logistics.get_depots())
	return depots


func _flat_distance(a: Vector3, b: Vector3):
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


func _sound_horn(at_position, loudness):
	if _horn_cooldown > 0.0:
		return
	var distance = _flat_distance(at_position, _pivot)
	var gain = loudness * clamp(1.0 - distance / CITY_HEARING_RANGE_M, 0.0, 1.0)
	gain *= lerp(1.0, 0.35, _zoom_out)
	if gain < 0.05:
		return
	_horn_cooldown = HORN_COOLDOWN_S
	var horn = _players["trade_horn"]
	horn.volume_db = linear_to_db(gain)
	horn.pitch_scale = randf_range(0.94, 1.06)
	horn.play()


func _on_trade_completed(proposer, partner, _offered, _requested):
	# heard at whichever of the two trading cities is closer to the camera
	var closest = null
	for player in [proposer, partner]:
		var logistics = player.get_node_or_null("Logistics") if player != null else null
		if logistics == null:
			continue
		for depot in logistics.get_depots():
			var distance = _flat_distance(depot.global_position, _pivot)
			if closest == null or distance < _flat_distance(closest, _pivot):
				closest = depot.global_position
	if closest != null:
		_sound_horn(closest, 0.8)


func _on_goods_delivered(player, _goods):
	var logistics = player.get_node_or_null("Logistics") if player != null else null
	if logistics == null or randf() > 0.3:
		return
	var depots = logistics.get_depots()
	if not depots.is_empty():
		_sound_horn(depots[0].global_position, 0.35)
