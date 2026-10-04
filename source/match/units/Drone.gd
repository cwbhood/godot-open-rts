extends "res://source/match/units/Unit.gd"

const RotorSpin = preload("res://source/match/units/RotorSpin.gd")

var _rotors = []


func _ready():
	await super()
	_rotors = RotorSpin.collect(self)


func _physics_process(delta):
	RotorSpin.spin(_rotors, delta)
