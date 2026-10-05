extends RefCounted

# Paints the minimap's background from a generated desert map: sand, hardpan, vegetation,
# rock and water in the terrain material's own colours (so it follows the art direction),
# with hill shading from the height field. Maps that are not generated keep the plain
# background.

const TerrainMaterial = preload(
	"res://source/match/resources/materials/desert_terrain.material.tres"
)
const WATER_SHALLOW = Color("#4f9fa8")
const WATER_DEEP = Color("#2b5f7a")
const LIGHT_DIRECTION = Vector2(-0.6, -0.8)  # from the top left, like the in-match sun


static func build(map, pixels_per_meter = 1):
	"""an ImageTexture covering the map's playable area, or null for a map without terrain"""
	if map == null or not map.has_method("_terrain_color") or not map.has_method("get_height"):
		return null
	var width = int(map.size.x * pixels_per_meter)
	var height = int(map.size.y * pixels_per_meter)
	if width <= 0 or height <= 0:
		return null
	var sand = _param("sand_light", Color(0.85, 0.66, 0.44))
	var hardpan = _param("hardpan_color", Color(0.80, 0.72, 0.60))
	var grass = _param("grass_dark", Color(0.29, 0.37, 0.18))
	var rock = _param("rock_light", Color(0.76, 0.50, 0.35))
	var wet = _param("wet_color", Color(0.50, 0.40, 0.30))
	var image = Image.create(width, height, false, Image.FORMAT_RGB8)
	var step = 1.0 / pixels_per_meter
	for y in range(height):
		for x in range(width):
			var pos = Vector2((x + 0.5) * step, (y + 0.5) * step)
			var ground = map.get_height(pos)
			var slope_x = map.get_height(pos + Vector2(step, 0)) - ground
			var slope_y = map.get_height(pos + Vector2(0, step)) - ground
			var weights = map._terrain_color(
				pos, ground, clamp(Vector2(slope_x, slope_y).length(), 0, 1)
			)
			var color = sand.lerp(hardpan, weights.a * 0.8)
			color = color.lerp(wet, weights.b * 0.7)
			color = color.lerp(grass, weights.r)
			color = color.lerp(rock, weights.g)
			if ground < -0.25:
				color = WATER_SHALLOW.lerp(WATER_DEEP, clamp((-ground - 0.25) / 1.5, 0.0, 1.0))
			else:
				# hill shading: slopes facing the light brighter, the others darker
				var shade = Vector2(slope_x, slope_y).dot(LIGHT_DIRECTION) / step
				color = color * clamp(1.0 + shade * 0.35, 0.7, 1.25)
			image.set_pixel(x, y, color)
	return ImageTexture.create_from_image(image)


static func _param(name, fallback):
	var value = TerrainMaterial.get_shader_parameter(name)
	if value is Color:
		return value
	if value is Vector3:
		return Color(value.x, value.y, value.z)
	return fallback
