extends Node3D

# Sky, sun, clouds, cloud shadows and weather for a match.
#
# Gameplay hooks (for economy/combat code; nothing here changes gameplay by itself):
#   var atmosphere = get_tree().get_first_node_in_group("atmosphere")
#   atmosphere.weather_changed                       # signal(weather: StringName)
#   atmosphere.get_weather() -> StringName           # &"clear", &"hazy", &"overcast", ...
#   atmosphere.get_vision_multiplier() -> float      # scale unit sight ranges
#   atmosphere.get_hauler_speed_multiplier() -> float
#   atmosphere.get_wood_growth_multiplier() -> float
#   atmosphere.get_air_scouting_multiplier_at(pos) -> float   # < 1 under thick cloud
#   atmosphere.get_cloud_density_at(pos) -> float    # 0..1 cloud above a world position
#   atmosphere.get_wind() -> Vector2                 # m/s on the XZ plane
#   atmosphere.set_weather(weather, transition_s)    # force a weather (scripts, missions)
# Multipliers blend smoothly during weather transitions.

signal weather_changed(weather)

const CloudShader = preload("res://source/shaders/3d/clouds.gdshader")
const CloudTexture = preload("res://assets/textures/clouds_tile.png")
const CloudShadowTexture = preload("res://assets/textures/cloud_shadows_2x2.png")

const CLOUD_HEIGHT = 32.0
const CLOUD_PERIOD = 400.0
const CLOUDS_FADE_IN_CAMERA_SIZES = Vector2(32.0, 55.0)
const WEATHERS = {
	&"clear":
	{
		"weight": 45.0,
		"coverage": 0.38,
		"shadow_opacity": 0.55,
		"sun_energy": 1.35,
		"sun_color": Color(1.0, 0.93, 0.82),
		"ambient_energy": 1.0,
		"haze": 0.0,
		"haze_color": Color(0.93, 0.8, 0.65),
		"rain": 0.0,
		"dust": 0.0,
		"wind_speed": 3.0,
		"vision": 1.0,
		"hauler_speed": 1.0,
		"wood_growth": 1.0,
	},
	&"hazy":
	{
		"weight": 20.0,
		"coverage": 0.22,
		"shadow_opacity": 0.35,
		"sun_energy": 1.2,
		"sun_color": Color(1.0, 0.88, 0.72),
		"ambient_energy": 1.1,
		"haze": 0.25,
		"haze_color": Color(0.95, 0.82, 0.66),
		"rain": 0.0,
		"dust": 0.15,
		"wind_speed": 4.0,
		"vision": 0.9,
		"hauler_speed": 1.0,
		"wood_growth": 0.9,
	},
	&"overcast":
	{
		"weight": 15.0,
		"coverage": 0.72,
		"shadow_opacity": 0.3,
		"sun_energy": 0.75,
		"sun_color": Color(0.9, 0.9, 0.92),
		"ambient_energy": 1.05,
		"haze": 0.1,
		"haze_color": Color(0.75, 0.75, 0.78),
		"rain": 0.0,
		"dust": 0.0,
		"wind_speed": 5.0,
		"vision": 0.95,
		"hauler_speed": 1.0,
		"wood_growth": 1.15,
	},
	&"rain":
	{
		"weight": 8.0,
		"coverage": 0.88,
		"shadow_opacity": 0.2,
		"sun_energy": 0.5,
		"sun_color": Color(0.8, 0.84, 0.9),
		"ambient_energy": 0.9,
		"haze": 0.3,
		"haze_color": Color(0.58, 0.62, 0.68),
		"rain": 1.0,
		"dust": 0.0,
		"wind_speed": 6.0,
		"vision": 0.8,
		"hauler_speed": 0.85,
		"wood_growth": 1.6,
	},
	&"sandstorm":
	{
		"weight": 12.0,
		"coverage": 0.3,
		"shadow_opacity": 0.15,
		"sun_energy": 0.7,
		"sun_color": Color(1.0, 0.75, 0.5),
		"ambient_energy": 0.95,
		"haze": 0.75,
		"haze_color": Color(0.86, 0.6, 0.38),
		"rain": 0.0,
		"dust": 1.0,
		"wind_speed": 14.0,
		"vision": 0.55,
		"hauler_speed": 0.7,
		"wood_growth": 0.8,
	},
}
const BLENDED_KEYS = [
	"coverage",
	"shadow_opacity",
	"sun_energy",
	"sun_color",
	"ambient_energy",
	"haze",
	"haze_color",
	"rain",
	"dust",
	"wind_speed",
	"vision",
	"hauler_speed",
	"wood_growth",
]

@export var initial_weather = &"clear"
@export var random_weather = true
@export var weather_duration_range_s = Vector2(150.0, 320.0)
@export var transition_duration_s = 18.0

var _weather = &"clear"
var _current = {}
var _from = {}
var _transition_progress = 1.0
var _transition_duration = 1.0
var _time_to_next_weather = 0.0
var _wind_angle = 0.6
var _cloud_offset = Vector2.ZERO
var _cloud_image = null
var _rng = RandomNumberGenerator.new()
var _lightning_cooldown = 6.0
var _flash = 0.0
var _cloud_shadows = Decal.new()

@onready var _match = find_parent("Match")
@onready var _clouds = $Clouds
@onready var _rain = $Rain
@onready var _dust = $Dust
@onready var _dust_haze = $DustHaze


func _ready():
	add_to_group("atmosphere")
	_rng.randomize()
	_cloud_image = CloudTexture.get_image()
	if _cloud_image.is_compressed():
		_cloud_image.decompress()
	_setup_clouds()
	_cloud_shadows.name = "CloudShadows"
	_cloud_shadows.texture_albedo = CloudShadowTexture
	_cloud_shadows.upper_fade = 0.0
	_cloud_shadows.lower_fade = 0.0
	add_child(_cloud_shadows)
	# keep the box below the camera: decals whose box contains an orthogonal camera are dropped
	_cloud_shadows.size = Vector3(CLOUD_PERIOD * 2.0, 24.0, CLOUD_PERIOD * 2.0)
	_weather = initial_weather
	_current = WEATHERS[_weather].duplicate()
	_time_to_next_weather = _rng.randf_range(
		weather_duration_range_s.x, weather_duration_range_s.y
	)
	_apply()


func _process(delta):
	_advance_weather(delta)
	_advance_wind(delta)
	_apply()
	_follow_camera()
	_update_lightning(delta)


func get_weather():
	return _weather


func get_vision_multiplier():
	return _current.vision


func get_hauler_speed_multiplier():
	return _current.hauler_speed


func get_wood_growth_multiplier():
	return _current.wood_growth


func get_wind():
	return Vector2.from_angle(_wind_angle) * _current.wind_speed


func get_cloud_density_at(world_position: Vector3) -> float:
	var uv = (Vector2(world_position.x, world_position.z) - _cloud_offset) / CLOUD_PERIOD
	var pixel = Vector2i(
		posmod(int(uv.x * _cloud_image.get_width()), _cloud_image.get_width()),
		posmod(int(uv.y * _cloud_image.get_height()), _cloud_image.get_height())
	)
	var value = _cloud_image.get_pixelv(pixel).r
	var threshold = 1.0 - _current.coverage
	return smoothstep(threshold, threshold + 0.18, value)


func get_air_scouting_multiplier_at(world_position: Vector3) -> float:
	"""air units see less of what lies under thick cloud; sandstorms blind them further"""
	var cloud = get_cloud_density_at(world_position)
	return clamp(1.0 - cloud * 0.6, 0.3, 1.0) * lerp(1.0, 0.6, _current.dust)


func set_weather(weather, transition_s = -1.0):
	assert(weather in WEATHERS, "unknown weather: {0}".format([weather]))
	_from = _current.duplicate()
	_weather = weather
	_transition_duration = transition_duration_s if transition_s < 0.0 else transition_s
	_transition_progress = 0.0 if _transition_duration > 0.0 else 1.0
	if _transition_progress >= 1.0:
		_current = WEATHERS[weather].duplicate()
	weather_changed.emit(weather)


func set_weather_immediately(weather):
	"""used by screenshot tooling and debug menus"""
	set_weather(StringName(weather), 0.0)
	_apply()


func _setup_clouds():
	var plane = PlaneMesh.new()
	plane.size = Vector2(900.0, 900.0)
	_clouds.mesh = plane
	var material = ShaderMaterial.new()
	material.shader = CloudShader
	material.set_shader_parameter("cloud_texture", CloudTexture)
	material.set_shader_parameter("period", CLOUD_PERIOD)
	_clouds.material_override = material
	_clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _advance_weather(delta):
	if _transition_progress < 1.0:
		_transition_progress = min(_transition_progress + delta / _transition_duration, 1.0)
		var target = WEATHERS[_weather]
		var weight = smoothstep(0.0, 1.0, _transition_progress)
		for key in BLENDED_KEYS:
			_current[key] = lerp(_from[key], target[key], weight)
	if not random_weather:
		return
	_time_to_next_weather -= delta
	if _time_to_next_weather <= 0.0:
		_time_to_next_weather = _rng.randf_range(
			weather_duration_range_s.x, weather_duration_range_s.y
		)
		set_weather(_pick_next_weather())


func _pick_next_weather():
	var total = 0.0
	for weather in WEATHERS:
		if weather != _weather:
			total += WEATHERS[weather].weight
	var roll = _rng.randf() * total
	for weather in WEATHERS:
		if weather == _weather:
			continue
		roll -= WEATHERS[weather].weight
		if roll <= 0.0:
			return weather
	return &"clear"


func _advance_wind(delta):
	_wind_angle += sin(Time.get_ticks_msec() / 40000.0) * delta * 0.01
	_cloud_offset += get_wind() * delta * 0.6


func _apply():
	var cloud_material = _clouds.material_override
	cloud_material.set_shader_parameter("coverage", _current.coverage)
	cloud_material.set_shader_parameter("offset", _cloud_offset)
	var camera = get_viewport().get_camera_3d()
	var zoom_visibility = 0.0
	if camera != null:
		zoom_visibility = smoothstep(
			CLOUDS_FADE_IN_CAMERA_SIZES.x, CLOUDS_FADE_IN_CAMERA_SIZES.y, camera.size
		)
	cloud_material.set_shader_parameter("visibility", zoom_visibility)
	_cloud_shadows.modulate.a = _current.shadow_opacity
	var sun = _get_sun()
	if sun != null:
		sun.light_energy = _current.sun_energy + _flash * 3.0
		sun.light_color = _current.sun_color
	var environment = _get_environment()
	if environment != null:
		environment.ambient_light_energy = _current.ambient_energy
		environment.fog_enabled = _current.haze > 0.01
		environment.fog_light_color = _current.haze_color
		# the camera looks down at 30 degrees, so the ground is about twice its height away
		var camera_distance = 80.0 if camera == null else max(camera.global_position.y, 1.0) * 2.0
		environment.fog_density = _current.haze * 0.55 / camera_distance
		environment.fog_sky_affect = 0.0
	_rain.amount_ratio = _current.rain
	_rain.emitting = _current.rain > 0.02
	_dust.amount_ratio = _current.dust
	_dust.emitting = _current.dust > 0.02
	_dust_haze.amount_ratio = _current.dust
	_dust_haze.emitting = _current.dust > 0.02
	var wind = get_wind()
	for particles in [_dust, _dust_haze]:
		var process_material = particles.process_material
		process_material.direction = Vector3(wind.x, 0.0, wind.y).normalized()
		process_material.initial_velocity_min = _current.wind_speed * 1.2
		process_material.initial_velocity_max = _current.wind_speed * 2.0


func _follow_camera():
	var camera = get_viewport().get_camera_3d()
	if camera == null or not camera.has_method("get_ray_intersection"):
		return
	var pivot = camera.get_ray_intersection(get_viewport().get_visible_rect().size / 2.0)
	if pivot == null:
		return
	_clouds.global_position = Vector3(pivot.x, CLOUD_HEIGHT, pivot.z)
	var area = clamp(camera.size * 1.4, 12.0, 90.0)
	for particles in [_rain, _dust, _dust_haze]:
		particles.global_position = Vector3(pivot.x, 0.0, pivot.z)
		particles.process_material.emission_box_extents.x = area
		particles.process_material.emission_box_extents.z = area
		particles.visibility_aabb = AABB(
			Vector3(-area - 30.0, -5.0, -area - 30.0), Vector3(area * 2.0 + 60.0, 45.0, area * 2.0 + 60.0)
		)
	_position_cloud_shadows()


func _position_cloud_shadows():
	"""places the 2x2-tiled shadow decal so that it lines up with the cloud layer as seen along
	the sun direction, wrapping by one period so it always covers the playable area"""
	var sun = _get_sun()
	var shadow_shift = Vector2.ZERO
	if sun != null:
		var light_direction = -sun.global_transform.basis.z
		if light_direction.y < -0.1:
			shadow_shift = (
				Vector2(light_direction.x, light_direction.z) * CLOUD_HEIGHT / -light_direction.y
			)
	var map_center = Vector2(60.0, 60.0)
	if _match != null and _match.map != null:
		map_center = _match.map.size / 2.0
	var anchor = _cloud_offset + shadow_shift
	var low = map_center - Vector2(CLOUD_PERIOD, CLOUD_PERIOD) / 2.0
	var center = Vector2(
		low.x + fposmod(anchor.x - low.x, CLOUD_PERIOD),
		low.y + fposmod(anchor.y - low.y, CLOUD_PERIOD)
	)
	_cloud_shadows.global_position = Vector3(center.x, 9.0, center.y)


func _update_lightning(delta):
	_flash = max(_flash - delta * 6.0, 0.0)
	if _current.rain < 0.8:
		return
	_lightning_cooldown -= delta
	if _lightning_cooldown <= 0.0:
		_lightning_cooldown = _rng.randf_range(5.0, 18.0)
		_flash = 1.0


func _get_sun():
	return _match.find_child("DirectionalLight3D", false) if _match != null else null


func _get_environment():
	if _match == null:
		return null
	var world_environment = _match.find_child("WorldEnvironment", false)
	return world_environment.environment if world_environment != null else null
