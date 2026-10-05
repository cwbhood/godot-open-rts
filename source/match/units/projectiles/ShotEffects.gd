extends RefCounted

# Short, cheap visuals for weapon fire: muzzle flashes, tracers, smoke puffs, impact sparks and
# dust, rocket explosions, barrel recoil and a brief flash on the unit that gets hit.
#
# Every effect is one or two unshaded billboard quads or boxes sharing a handful of meshes and
# materials, animated by a tween and freed when it ends; nothing casts shadows. Fading uses the
# per-instance `transparency` so the materials stay shared. Effects outside the camera view or
# in the fog of war are skipped, and when many are alive at once the smoke and dust are dropped
# first and then everything, so a huge battle costs a bounded amount.

const MAX_LIVE_EFFECTS = 160
const MAX_LIVE_EFFECTS_FOR_SMOKE = 90
const TRACER_SPEED_M_PER_S = 45.0
const TRACER_MIN_S = 0.08
const TRACER_MAX_S = 0.2
const HIT_FLASH_S = 0.08
const RECOIL_S = 0.16
const FIRE_COLOR = Color(1.0, 0.45, 0.08)
const CORE_COLOR = Color(1.0, 0.97, 0.8)
const TRACER_COLOR = Color(1.0, 0.6, 0.12)

static var _live_effects = 0
static var _resources = null


static func cannon_shot(shooter, origin_transform, target):
	"""muzzle flash, smoke, recoil and a tracer that ends in sparks and dust on the target;
	sized by the shooter's damage so rifles look smaller than tank guns"""
	var target_position = _aim_point(target)
	var size = clampf(0.45 + 0.22 * float(shooter.attack_damage), 0.55, 1.4)
	var shooter_seen = _is_seen(shooter, origin_transform.origin)
	var target_seen = _is_seen(target, target_position)
	if shooter_seen:
		_muzzle_flash(shooter, origin_transform.origin, 0.8 * size, 0.09)
		_smoke(shooter, origin_transform.origin, 0.35 * size, Color(0.42, 0.4, 0.38), 0.5)
		if shooter.attack_damage >= 2:  # guns, not rifles
			recoil(shooter, 0.06 * size)
	if not shooter_seen and not target_seen:
		return
	var distance = origin_transform.origin.distance_to(target_position)
	var flight_s = clampf(distance / TRACER_SPEED_M_PER_S, TRACER_MIN_S, TRACER_MAX_S)
	_tracer(shooter, origin_transform.origin, target_position, 0.05 * size + 0.02, flight_s)
	if target_seen:
		var timer = shooter.get_tree().create_timer(flight_s, false)
		timer.timeout.connect(_cannon_impact.bind(target, target_position, size))


static func rocket_launch(shooter, origin_position):
	if not _is_seen(shooter, origin_position):
		return
	_muzzle_flash(shooter, origin_position, 0.8, 0.1)
	_smoke(shooter, origin_position, 0.5, Color(0.45, 0.43, 0.4), 0.8)


static func rocket_impact(target, position):
	if not _is_seen(target, position):
		return
	_flash(target, position, 1.4, FIRE_COLOR, 0.16)
	_flash(target, position, 0.7, CORE_COLOR, 0.09)
	_smoke(target, position + Vector3(0, 0.15, 0), 0.8, Color(0.3, 0.28, 0.26), 1.0)
	hit_flash(target)


static func hit_flash(target):
	"""tints the target's meshes bright for a moment"""
	if not is_instance_valid(target) or not target.is_inside_tree() or not target.visible:
		return
	var meshes = (
		target.get_meta("_hit_flash_meshes") if target.has_meta("_hit_flash_meshes") else null
	)
	if meshes == null:
		meshes = target.find_children("*", "GeometryInstance3D", true, false).filter(
			func(mesh): return mesh is MeshInstance3D and mesh.is_visible_in_tree()
		)
		target.set_meta("_hit_flash_meshes", meshes)
	var overlay = _get_resources()["hit_overlay"]
	for mesh in meshes:
		if is_instance_valid(mesh):
			mesh.material_overlay = overlay
	var timer = target.get_tree().create_timer(HIT_FLASH_S, false)
	timer.timeout.connect(_clear_hit_flash.bind(meshes, overlay))


static func recoil(shooter, distance):
	"""kicks the shooter's model back along its barrel and eases it home"""
	var model = shooter.get_meta("_recoil_model") if shooter.has_meta("_recoil_model") else null
	if model == null:
		var geometry = shooter.find_child("Geometry", true, false)
		if geometry == null:
			return
		model = geometry.get_node_or_null("Model")
		if model == null:
			model = geometry
		shooter.set_meta("_recoil_model", model)
		shooter.set_meta("_recoil_rest", model.position)
	if not is_instance_valid(model) or not model.is_inside_tree():
		return
	var rest = shooter.get_meta("_recoil_rest")
	# the model's parent may be scaled or rotated, so push along the shooter's back in its space
	var back = (
		(model.get_parent() as Node3D).global_transform.basis.inverse()
		* (shooter.global_transform.basis.z.normalized() * distance)
	)
	var tween = model.create_tween()
	model.position = rest + back
	tween.tween_property(model, "position", rest, RECOIL_S).set_ease(Tween.EASE_OUT).set_trans(
		Tween.TRANS_QUAD
	)


static func _cannon_impact(target, fallback_position, size):
	var position = _aim_point(target) if is_instance_valid(target) else fallback_position
	if not _is_seen(target, position):
		return
	var anchor = target if is_instance_valid(target) and target.is_inside_tree() else null
	if anchor == null:
		return
	_flash(anchor, position, 0.45 * size, FIRE_COLOR, 0.08)
	_flash(anchor, position, 0.2 * size, CORE_COLOR, 0.05)
	_smoke(anchor, position, 0.35 * size, Color(0.5, 0.42, 0.32), 0.45)
	hit_flash(target)


static func _aim_point(unit):
	if not is_instance_valid(unit):
		return Vector3.ZERO
	var shape = unit.find_child("CollisionShape3D", false, false)
	if shape != null:
		return shape.global_position
	return unit.global_position + Vector3(0, 0.3, 0)


static func _is_seen(unit, position):
	if not is_instance_valid(unit) or not unit.is_inside_tree() or not unit.visible:
		return false
	var camera = unit.get_viewport().get_camera_3d()
	return camera == null or camera.is_position_in_frustum(position)


static func _muzzle_flash(anchor, position, size, duration_s):
	"""an orange burst with a white-hot core; plain yellow vanishes against desert sand"""
	_flash(anchor, position, size, FIRE_COLOR, duration_s)
	_flash(anchor, position, 0.45 * size, CORE_COLOR, duration_s * 0.7)


static func _flash(anchor, position, size, color, duration_s):
	if _live_effects >= MAX_LIVE_EFFECTS:
		return
	var resources = _get_resources()
	var quad = _spawn(anchor, resources["quad"], _blob_material(true, color), position)
	quad.scale = Vector3.ONE * size
	var tween = quad.create_tween()
	tween.tween_property(quad, "scale", Vector3.ONE * size * 0.25, duration_s)
	tween.parallel().tween_property(quad, "transparency", 1.0, duration_s)
	tween.tween_callback(_free_effect.bind(quad))


static func _smoke(anchor, position, size, color, duration_s):
	if _live_effects >= MAX_LIVE_EFFECTS_FOR_SMOKE:
		return
	var resources = _get_resources()
	var quad = _spawn(anchor, resources["quad"], _blob_material(false, color), position)
	quad.scale = Vector3.ONE * size * 0.5
	quad.transparency = 0.25
	var tween = quad.create_tween()
	tween.tween_property(quad, "scale", Vector3.ONE * size * 1.6, duration_s).set_ease(
		Tween.EASE_OUT
	)
	tween.parallel().tween_property(quad, "transparency", 1.0, duration_s)
	tween.parallel().tween_property(
		quad, "global_position", position + Vector3(0, 0.35 * size, 0), duration_s
	)
	tween.tween_callback(_free_effect.bind(quad))


static func _tracer(anchor, from, to, thickness, flight_s):
	if _live_effects >= MAX_LIVE_EFFECTS or from.is_equal_approx(to):
		return
	var resources = _get_resources()
	var streak = _spawn(anchor, resources["box"], resources["tracer"], from)
	var length = minf(1.2, from.distance_to(to) * 0.5)
	streak.look_at_from_position(from, to, _up_for(to - from))
	streak.scale = Vector3(thickness, thickness, length)
	var tween = streak.create_tween()
	tween.tween_property(streak, "global_position", to, flight_s)
	tween.tween_callback(_free_effect.bind(streak))


static func _up_for(direction):
	return Vector3.RIGHT if absf(direction.normalized().y) > 0.99 else Vector3.UP


static func _spawn(anchor, mesh, material, position):
	var instance = MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.top_level = true
	# parented to the shooter's or target's player so that it lives in the match, not the unit
	var parent = anchor.get_parent() if anchor.get_parent() != null else anchor
	parent.add_child(instance)
	instance.global_position = position
	_live_effects += 1
	return instance


static func _free_effect(instance):
	_live_effects = maxi(0, _live_effects - 1)
	if is_instance_valid(instance):
		instance.queue_free()


static func _clear_hit_flash(meshes, overlay):
	for mesh in meshes:
		if is_instance_valid(mesh) and mesh.material_overlay == overlay:
			mesh.material_overlay = null


static func _get_resources():
	if _resources != null:
		return _resources
	var quad = QuadMesh.new()
	var box = BoxMesh.new()
	box.size = Vector3.ONE
	var flash = _billboard_shader(true)
	var smoke = _billboard_shader(false)
	var tracer = StandardMaterial3D.new()
	tracer.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	tracer.albedo_color = TRACER_COLOR
	var hit_overlay = StandardMaterial3D.new()
	hit_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	hit_overlay.albedo_color = Color(1.0, 0.55, 0.2, 0.3)
	hit_overlay.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	hit_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_resources = {
		"quad": quad,
		"box": box,
		"flash_shader": flash,
		"smoke_shader": smoke,
		"blob_materials": {},
		"tracer": tracer,
		"hit_overlay": hit_overlay,
	}
	return _resources


static func _blob_material(solid, color):
	"""one material per colour in use (a handful), shared by every blob of that colour"""
	var resources = _get_resources()
	var key = [solid, color]
	var material = resources["blob_materials"].get(key)
	if material == null:
		material = ShaderMaterial.new()
		material.shader = resources["flash_shader" if solid else "smoke_shader"]
		material.set_shader_parameter("tint", color)
		resources["blob_materials"][key] = material
	return material


static func _billboard_shader(solid):
	"""a soft round billboard blob: a solid-cored one for flashes (additive blending vanishes
	on bright desert sand) and a softer one for smoke and dust"""
	var shader = Shader.new()
	shader.code = (
		"""
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, %s;
uniform vec4 tint : source_color = vec4(1.0);
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz),
		MODEL_MATRIX[3]);
}
void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;
	float a = clamp(1.0 - d, 0.0, 1.0);
	a = %s;
	ALBEDO = tint.rgb;
	ALPHA = a * tint.a;
}
"""
		% [
			"blend_mix",
			"smoothstep(0.0, 0.5, a)" if solid else "smoothstep(0.0, 0.8, a) * 0.85",
		]
	)
	return shader
