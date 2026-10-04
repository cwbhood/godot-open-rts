extends Node3D

const ShotEffects = preload("res://source/match/units/projectiles/ShotEffects.gd")

var target_unit = null

@onready var _unit = get_parent()
@onready var _unit_particles = find_child("OriginParticles")
@onready var _timer = find_child("Timer")


func _ready():
	assert(target_unit != null, "target unit was not provided")
	_unit_particles.visible = _unit.visible
	_setup_unit_particles()
	_setup_timer()
	if not is_instance_valid(target_unit) or not is_instance_valid(_unit):
		return
	target_unit.take_damage(_unit.attack_damage, _unit)


func _setup_timer():
	_timer.timeout.connect(queue_free)
	_timer.start(_unit_particles.lifetime)


func _setup_unit_particles():
	await get_tree().physics_frame  # wait for rotation to kick in if remote transform is used
	var a_global_transform = (
		_unit.global_transform
		if _unit.find_child("ProjectileOrigin") == null
		else _unit.find_child("ProjectileOrigin").global_transform
	)
	_unit_particles.global_transform = a_global_transform
	_unit_particles.emitting = true
	if is_instance_valid(target_unit) and is_instance_valid(_unit):
		ShotEffects.cannon_shot(_unit, a_global_transform, target_unit)
