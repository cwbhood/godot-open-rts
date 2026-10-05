@tool
extends Node3D

# TODO: add editor-only 2nd pass shader to 'Terrain' mesh highlighting map boundries

const EXTRA_MARGIN = 2
const DEFAULT_START_PICK_SECONDS = 30.0

@export var size = Vector2(50, 50):
	set(a_size):
		size = a_size
		var terrain_mesh = find_child("Terrain").mesh
		if terrain_mesh is PlaneMesh:
			terrain_mesh.size = size + Vector2(EXTRA_MARGIN, EXTRA_MARGIN) * 2
			terrain_mesh.center_offset = Vector3(size.x, 0.0, size.y) / 2.0

## how far from its spawn point a player may place the starter city
@export var start_zone_radius = 6.0
## how long players get to pick a start zone before one is picked for them
@export var start_pick_seconds = DEFAULT_START_PICK_SECONDS

# WaterLayout.gd of maps with seas, lakes or fords; null on maps without any water
var water = null


func get_start_zones():
	"""returns [{center: Vector2, radius: float, transform: Transform3D}], one per spawn point,
	in spawn point order"""
	var zones = []
	var spawn_points = find_child("SpawnPoints")
	if spawn_points == null:
		return zones
	for marker in spawn_points.get_children():
		var spawn_transform = _transform_in_map(marker)
		var origin = spawn_transform.origin
		(
			zones
			. append(
				{
					"center": Vector2(origin.x, origin.z),
					"radius": float(marker.get_meta("zone_radius", start_zone_radius)),
					"transform": spawn_transform,
				}
			)
		)
	return zones


func get_deposit_list():
	"""returns [{kind: StringName, center: Vector2, amount: int}] for every resource deposit,
	read from the deposit markers of generated maps or the deposit units of hand-made ones.
	Works before the map enters the scene tree."""
	var nodes = []
	var deposits_node = get_node_or_null("Deposits")
	if deposits_node != null:
		nodes = deposits_node.get_children()
	if nodes.is_empty() and find_child("Resources") != null:
		nodes = find_child("Resources").find_children("*", "Node3D", true, false).filter(
			func(node): return node.get_script() != null and "kind" in node and "amount" in node
		)
	var result = []
	for node in nodes:
		var kind = StringName(node.get_meta("kind", node.get("kind")))
		var amount = int(node.get_meta("amount", node.get("amount")))
		if amount < 0:
			amount = Constants.Match.Resources.DEFAULT_DEPOSIT_AMOUNT.get(String(kind), 500)
		var origin = _transform_in_map(node).origin
		result.append({"kind": kind, "center": Vector2(origin.x, origin.z), "amount": amount})
	return result


func _transform_in_map(node):
	var result = node.transform
	var parent = node.get_parent()
	while parent != null and parent != self:
		result = parent.transform * result
		parent = parent.get_parent()
	return result


func has_water() -> bool:
	return water != null and water.has_water()


func water_depth_at(pos: Vector3) -> int:
	"""WaterLayout.Depth (0 = land) under a point; cheap enough for per-tick use"""
	return water.depth_fast(Vector2(pos.x, pos.z)) if has_water() else 0


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
