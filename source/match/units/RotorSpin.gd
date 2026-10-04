# Spins the rotors of an aircraft model: nodes named "Rotor*" under the model that
# GameData swapped in from data (or under Geometry for the stock scenes).
# Tail rotors ("RotorTail*") turn around their local X axis, all others around up.

const SPEED_DEG = 800.0


static func collect(unit):
	var root = unit.find_child("Model", true, false)
	if root == null:
		root = unit.find_child("Geometry", false)
	if root == null:
		return []
	var rotors = root.find_children("Rotor*", "Node3D", true, false)
	if root.name.begins_with("Rotor"):
		rotors.append(root)
	return rotors.filter(func(rotor): return rotor.get_parent().name != "Rotor")


static func spin(rotors, delta):
	for rotor in rotors:
		if rotor.name.begins_with("RotorTail"):
			rotor.rotate_object_local(Vector3.RIGHT, deg_to_rad(SPEED_DEG * 1.5 * delta))
		else:
			rotor.rotate_object_local(Vector3.UP, deg_to_rad(SPEED_DEG * delta))
