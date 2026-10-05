extends Node3D

@onready var _particles = find_child("GPUParticles3D")


func _ready():
	# wait one frame for transform to propagate; a signal (not await) so a node
	# freed meanwhile, e.g. by loading a save, does not resume into nothing
	get_tree().physics_frame.connect(_start, CONNECT_ONE_SHOT)


func _start():
	_particles.emitting = true
