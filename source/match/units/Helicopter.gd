extends "res://source/match/units/Unit.gd"

const RotorSpin = preload("res://source/match/units/RotorSpin.gd")
const WaitingForTargets = preload("res://source/match/units/actions/WaitingForTargets.gd")

var _rotors = []


func _ready():
	await super()
	_rotors = RotorSpin.collect(self)
	action_changed.connect(_on_action_changed)
	action = WaitingForTargets.new()


func _physics_process(delta):
	RotorSpin.spin(_rotors, delta)


func _on_action_changed(new_action):
	if new_action == null:
		action = WaitingForTargets.new()
