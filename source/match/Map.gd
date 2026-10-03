@tool
extends Node3D

# TODO: add editor-only 2nd pass shader to 'Terrain' mesh highlighting map boundries

const EXTRA_MARGIN = 2

@export var size = Vector2(50, 50):
	set(a_size):
		size = a_size
		var terrain_mesh = find_child("Terrain").mesh
		if terrain_mesh is PlaneMesh:
			terrain_mesh.size = size + Vector2(EXTRA_MARGIN, EXTRA_MARGIN) * 2
			terrain_mesh.center_offset = Vector3(size.x, 0.0, size.y) / 2.0


func get_topdown_polygon_2d():
	return [Vector2(0, 0), Vector2(size.x, 0), size, Vector2(0, size.y)]


func get_resource_deposits():
	"""returns [{kind: StringName, position: Vector3, amount: int, node: Marker3D}] for every
	deposit marker under 'Deposits'; maps without deposit markers return an empty array"""
	var deposits_node = get_node_or_null("Deposits")
	if deposits_node == null:
		return []
	var deposits = []
	for marker in deposits_node.get_children():
		(
			deposits
			. append(
				{
					"kind": marker.get_meta("kind", &""),
					"position": marker.global_position,
					"amount": marker.get_meta("amount", 0),
					"node": marker,
				}
			)
		)
	return deposits
