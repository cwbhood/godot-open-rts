extends Node

# The match's art direction: lighting, sky, colour grade, terrain palette and finishing
# effects, read from data/looks/<id>.json so a look can be tuned without touching scenes.
#
# Match.gd adds one Look node; it applies the look picked in Options (Options.art_style),
# or --look=<id> on the command line, or DEFAULT_LOOK. "classic" is the look from before
# looks existed and changes nothing.
#
# What a look file holds (every section optional):
#   environment: Environment properties by name (colours as [r, g, b] or [r, g, b, a])
#   sky:         ProceduralSkyMaterial properties by name
#   sun:         elevation and azimuth in degrees, energy (a multiplier on the weather's
#                sun), tint (multiplies the weather's sun colour), shadow_blur
#   ambient:     energy (multiplier on the weather's ambient light)
#   haze:        multiplier on the weather's haze; base_haze: haze added in every weather
#   terrain:     desert_terrain.gdshader uniforms
#   grade:       look_grade.gdshader uniforms (colour grade, tilt-shift, vignette, grain)
#   outline:     look_outline.gdshader uniforms; lines are drawn only when this is present
#
# Atmosphere.gd asks this node for the sun, ambient and haze multipliers every frame, so the
# weather keeps working on top of any look.

const LOOKS_DIR = "res://data/looks"
const DEFAULT_LOOK = "stylised"
const CLASSIC_LOOK = "classic"
const GraphicsQuality = preload("res://source/options/GraphicsQuality.gd")
const GradeShader = preload("res://source/shaders/2d/look_grade.gdshader")
const OutlineShader = preload("res://source/shaders/3d/look_outline.gdshader")
const TerrainMaterial = preload(
	"res://source/match/resources/materials/desert_terrain.material.tres"
)
# outlines fade out between these camera sizes: far away they would only add noise
const OUTLINE_FADE_SIZES = Vector2(28.0, 60.0)

# the terrain material is shared by every match: its scene values, kept to restore them
static var _terrain_base = {}

var look_id = ""
var definition = {}

var _grade_layer = null
var _outline = null


static func available_looks():
	"""ids of the looks in data/looks, sorted"""
	var ids = []
	for file_name in DirAccess.get_files_at(LOOKS_DIR):
		if file_name.ends_with(".json"):
			ids.append(file_name.get_basename())
	ids.sort()
	return ids


static func load_definition(id):
	var path = "{0}/{1}.json".format([LOOKS_DIR, id])
	if not FileAccess.file_exists(path):
		return null
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else null


static func picked_look():
	"""--look=<id> beats the Options choice, which beats DEFAULT_LOOK"""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--look="):
			return arg.trim_prefix("--look=")
	var chosen = Globals.options.get("art_style") if Globals.options != null else ""
	if chosen != null and chosen != "" and load_definition(chosen) != null:
		return chosen
	return DEFAULT_LOOK


func _ready():
	add_to_group("look")
	apply(picked_look())


func _process(_delta):
	if _outline == null:
		return
	var camera = get_viewport().get_camera_3d()
	if camera != null:
		var fade = 1.0 - smoothstep(OUTLINE_FADE_SIZES.x, OUTLINE_FADE_SIZES.y, camera.size)
		_outline.material_override.set_shader_parameter("fade", fade)
		_outline.visible = fade > 0.01


func apply(id):
	"""switches the running match to look `id`; unknown ids fall back to classic"""
	var loaded = load_definition(id)
	if loaded == null:
		push_warning("unknown look '{0}', using classic".format([id]))
		id = CLASSIC_LOOK
		loaded = {}
	look_id = id
	definition = loaded
	var match_node = get_parent()
	_apply_environment(match_node)
	_apply_sun(match_node)
	_apply_terrain()
	_apply_grade()
	_apply_outline()


func get_sun_energy_multiplier():
	return float(definition.get("sun", {}).get("energy", 1.0))


func get_sun_tint():
	return _color(definition.get("sun", {}).get("tint", [1, 1, 1]))


func get_ambient_multiplier():
	return float(definition.get("ambient", {}).get("energy", 1.0))


func get_haze_multiplier():
	return float(definition.get("haze", 1.0))


func get_base_haze():
	"""haze present in every weather: distance softens into the air (aerial perspective)"""
	return float(definition.get("base_haze", 0.0))


func _apply_environment(match_node):
	var world_environment = match_node.find_child("WorldEnvironment", false)
	if world_environment == null or world_environment.environment == null:
		return
	# the scene's environment is shared by every match; work on this match's own copy
	if not world_environment.has_meta("look_base_environment"):
		world_environment.set_meta("look_base_environment", world_environment.environment)
	var environment = world_environment.get_meta("look_base_environment").duplicate(true)
	world_environment.environment = environment
	_set_properties(environment, definition.get("environment", {}))
	if environment.sky != null and environment.sky.sky_material != null:
		_set_properties(environment.sky.sky_material, definition.get("sky", {}))
	# the graphics preset turns effects down from what the look asks for
	if world_environment.has_meta("quality_base"):
		world_environment.remove_meta("quality_base")
	if Globals.options != null:
		GraphicsQuality.apply_to_scene(Globals.options.graphics_quality, match_node)


func _apply_sun(match_node):
	var sun = match_node.find_child("DirectionalLight3D", false)
	if sun == null:
		return
	if not sun.has_meta("look_base"):
		sun.set_meta("look_base", {"rotation": sun.rotation, "shadow_blur": sun.shadow_blur})
	var base = sun.get_meta("look_base")
	var settings = definition.get("sun", {})
	sun.rotation = base["rotation"]
	if settings.has("elevation") or settings.has("azimuth"):
		sun.rotation = Vector3(
			-deg_to_rad(float(settings.get("elevation", rad_to_deg(-base["rotation"].x)))),
			deg_to_rad(float(settings.get("azimuth", rad_to_deg(base["rotation"].y)))),
			0.0
		)
	sun.shadow_blur = float(settings.get("shadow_blur", base["shadow_blur"]))


func _apply_terrain():
	var settings = definition.get("terrain", {})
	for key in _terrain_base:
		TerrainMaterial.set_shader_parameter(key, _terrain_base[key])
	for key in settings:
		if not _terrain_base.has(key):
			_terrain_base[key] = TerrainMaterial.get_shader_parameter(key)
		TerrainMaterial.set_shader_parameter(key, _value(settings[key]))


func _apply_grade():
	var settings = definition.get("grade", {})
	if settings.is_empty():
		if _grade_layer != null:
			_grade_layer.queue_free()
			_grade_layer = null
		return
	if _grade_layer == null:
		_grade_layer = CanvasLayer.new()
		_grade_layer.name = "LookGrade"
		_grade_layer.layer = -1  # over the 3D world, under every HUD layer
		var rect = ColorRect.new()
		rect.name = "Grade"
		rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.material = ShaderMaterial.new()
		rect.material.shader = GradeShader
		_grade_layer.add_child(rect)
		add_child(_grade_layer)
	var material = _grade_layer.get_node("Grade").material
	for uniform in GradeShader.get_shader_uniform_list():
		if uniform["name"] != "screen_texture":
			material.set_shader_parameter(uniform["name"], null)  # back to the shader default
	for key in settings:
		material.set_shader_parameter(key, _value(settings[key]))


func _apply_outline():
	var settings = definition.get("outline", {})
	if settings.is_empty():
		if _outline != null:
			_outline.queue_free()
			_outline = null
		return
	if _outline == null:
		_outline = MeshInstance3D.new()
		_outline.name = "LookOutline"
		var quad = QuadMesh.new()
		quad.size = Vector2(2, 2)
		_outline.mesh = quad
		_outline.extra_cull_margin = 16384.0
		_outline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_outline.material_override = ShaderMaterial.new()
		_outline.material_override.shader = OutlineShader
		# first of the see-through passes: under fog of war, cloud shadows and clouds
		_outline.material_override.render_priority = -20
		add_child(_outline)
	for key in settings:
		_outline.material_override.set_shader_parameter(key, _value(settings[key]))


func _set_properties(object, properties):
	for key in properties:
		if not key in object:
			push_warning("look {0}: no property '{1}'".format([look_id, key]))
			continue
		object.set(key, _value(properties[key]))


static func _value(value):
	if value is Array and (value.size() == 3 or value.size() == 4):
		return _color(value)
	return value


static func _color(values):
	return Color(values[0], values[1], values[2], values[3] if values.size() > 3 else 1.0)
