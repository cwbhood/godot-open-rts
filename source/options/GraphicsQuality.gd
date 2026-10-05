extends RefCounted

# The graphics quality preset (Options.graphics_quality): shadow resolution and filtering,
# anti-aliasing, ambient occlusion and glow.
#
# The match's look (source/match/Match.tscn: WorldEnvironment, DirectionalLight3D) belongs
# to the art: the preset only ever turns effects down from what the scene sets, never on.
# The scene's own values are remembered on the nodes (meta "quality_base") the first time,
# so switching back to a higher preset restores them exactly.
#
# Match.gd calls attach(self) once; the preset is then applied again whenever the options
# change.

enum { LOW = 0, MEDIUM = 1, HIGH = 2, ULTRA = 3 }

const NAMES = ["Low", "Medium", "High", "Ultra"]
const PRESETS = {
	LOW:
	{
		"shadow_atlas": 1024,
		"soft_shadows": RenderingServer.SHADOW_QUALITY_HARD,
		"split_shadows": false,
		"msaa": Viewport.MSAA_DISABLED,
		"fxaa": false,
		"ssao": false,
		"ssao_quality": RenderingServer.ENV_SSAO_QUALITY_VERY_LOW,
		"glow": false,
	},
	MEDIUM:
	{
		"shadow_atlas": 2048,
		"soft_shadows": RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		"split_shadows": true,
		"msaa": Viewport.MSAA_DISABLED,
		"fxaa": true,
		"ssao": false,
		"ssao_quality": RenderingServer.ENV_SSAO_QUALITY_LOW,
		"glow": true,
	},
	HIGH:
	{
		"shadow_atlas": 4096,
		"soft_shadows": RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
		"split_shadows": true,
		"msaa": Viewport.MSAA_2X,
		"fxaa": false,
		"ssao": true,
		"ssao_quality": RenderingServer.ENV_SSAO_QUALITY_MEDIUM,
		"glow": true,
	},
	ULTRA:
	{
		"shadow_atlas": 8192,
		"soft_shadows": RenderingServer.SHADOW_QUALITY_SOFT_HIGH,
		"split_shadows": true,
		"msaa": Viewport.MSAA_4X,
		"fxaa": false,
		"ssao": true,
		"ssao_quality": RenderingServer.ENV_SSAO_QUALITY_HIGH,
		"glow": true,
	},
}


static func describe(quality):
	"""one line for the options screen: what the preset does"""
	var preset = PRESETS[quality]
	var anti_aliasing = "off"
	if preset["msaa"] != Viewport.MSAA_DISABLED:
		anti_aliasing = "MSAA {0}x".format([2 if preset["msaa"] == Viewport.MSAA_2X else 4])
	elif preset["fxaa"]:
		anti_aliasing = "FXAA"
	return (
		"Shadows {0}px, anti-aliasing {1}, ambient occlusion {2}, glow {3}"
		. format(
			[
				preset["shadow_atlas"],
				anti_aliasing,
				"on" if preset["ssao"] else "off",
				"on" if preset["glow"] else "off",
			]
		)
	)


static func apply_global(quality, viewport):
	"""what is not tied to a scene: the root viewport and the renderer's shadow settings"""
	var preset = PRESETS.get(quality, PRESETS[HIGH])
	RenderingServer.directional_shadow_atlas_set_size(preset["shadow_atlas"], true)
	RenderingServer.directional_soft_shadow_filter_set_quality(preset["soft_shadows"])
	RenderingServer.positional_soft_shadow_filter_set_quality(preset["soft_shadows"])
	RenderingServer.environment_set_ssao_quality(preset["ssao_quality"], true, 0.5, 2, 50.0, 300.0)
	viewport.msaa_3d = preset["msaa"]
	viewport.screen_space_aa = (
		Viewport.SCREEN_SPACE_AA_FXAA if preset["fxaa"] else Viewport.SCREEN_SPACE_AA_DISABLED
	)


static func apply_to_scene(quality, scene_root):
	"""turns the scene's own environment and sun down to the preset"""
	var preset = PRESETS.get(quality, PRESETS[HIGH])
	for world_environment in scene_root.find_children("*", "WorldEnvironment", true, false):
		var environment = world_environment.environment
		if environment == null:
			continue
		var base = _base(
			world_environment, {"ssao": environment.ssao_enabled, "glow": environment.glow_enabled}
		)
		environment.ssao_enabled = base["ssao"] and preset["ssao"]
		environment.glow_enabled = base["glow"] and preset["glow"]
	for light in scene_root.find_children("*", "DirectionalLight3D", true, false):
		var base = _base(light, {"mode": light.directional_shadow_mode})
		light.directional_shadow_mode = (
			base["mode"] if preset["split_shadows"] else DirectionalLight3D.SHADOW_ORTHOGONAL
		)


static func attach(scene_root):
	"""applies the current preset to scene_root now and whenever the options change"""
	var apply = func():
		if is_instance_valid(scene_root) and scene_root.is_inside_tree():
			apply_to_scene(Globals.options.graphics_quality, scene_root)
	apply.call()
	Globals.options.changed.connect(apply)
	scene_root.tree_exiting.connect(
		func():
			if Globals.options.changed.is_connected(apply):
				Globals.options.changed.disconnect(apply)
	)


static func _base(node, current):
	if not node.has_meta("quality_base"):
		node.set_meta("quality_base", current)
	return node.get_meta("quality_base")
