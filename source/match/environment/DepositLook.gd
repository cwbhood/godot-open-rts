extends Node3D

# Gives a resource deposit its Ironbound model and shows how much is left in it: ore and
# oil switch to a worked-out model and sink as they run low, and a timber stand loses its
# trees one by one. A child of each deposit scene (ResourceDeposit.gd); the deposit's own
# placeholder meshes are hidden, its collision, selection and highlight are kept.

const MODELS_DIR = "res://assets/models/ironbound/"
const MODELS = {
	"oil": ["deposits/oil_seep.glb", "deposits/oil_seep_depleted.glb"],
	"iron": ["deposits/ore_iron.glb", "deposits/ore_iron_depleted.glb"],
	"copper": ["deposits/ore_copper.glb", "deposits/ore_copper_depleted.glb"],
	# timber stands are trees (planted below) on ground with stumps and cut logs
	"timber": ["deposits/timber_stack_depleted.glb", "deposits/timber_stack_depleted.glb"],
}
const TREES = ["env/pine_a.glb", "env/pine_b.glb", "env/tree_acacia_a.glb"]
const TREE_COUNT = 7
const WORKED_OUT_BELOW = 0.4  # fraction of the starting amount
const REFRESH_S = 0.5

var _deposit = null
var _initial_amount = 1
var _full = null
var _worked_out = null
var _trees = []
var _since_refresh = 0.0


func _ready():
	_deposit = get_parent()
	# the deposit fills in its default amount in its own _ready, which runs after ours
	_setup.call_deferred()


func _setup():
	var kind = String(_deposit.kind)
	if not kind in MODELS:
		queue_free()
		return
	var geometry = _deposit.find_child("Geometry")
	for child in geometry.get_children():
		child.visible = false
	reparent(geometry, false)
	_initial_amount = max(1, _deposit.amount)
	_full = _add_model(MODELS[kind][0])
	_worked_out = _add_model(MODELS[kind][1])
	if kind == "timber":
		_plant_trees()
	_refresh()


func _process(delta):
	_since_refresh += delta
	if _since_refresh >= REFRESH_S and _full != null:
		_since_refresh = 0.0
		_refresh()


func _refresh():
	var left = clamp(float(_deposit.amount) / _initial_amount, 0.0, 1.0)
	if not _trees.is_empty():
		var standing = int(ceil(left * _trees.size()))
		for i in range(_trees.size()):
			_trees[i].visible = i < standing
		_full.visible = false
		_worked_out.visible = true
		return
	_full.visible = left >= WORKED_OUT_BELOW
	_worked_out.visible = not _full.visible
	# ore heaps shrink into the ground as they are mined
	var shrink = lerp(0.55, 1.0, left) if _full.visible else 1.0
	_full.scale = Vector3(1.0, shrink, 1.0)


func _add_model(path):
	var model = load(MODELS_DIR + path).instantiate()
	add_child(model)
	return model


func _plant_trees():
	var rng = RandomNumberGenerator.new()
	rng.seed = hash(_deposit.global_position.snapped(Vector3.ONE * 0.1))
	for i in range(TREE_COUNT):
		var angle = TAU * i / TREE_COUNT + rng.randf_range(-0.3, 0.3)
		var distance = rng.randf_range(0.4, 1.3) if i > 0 else 0.0
		var tree = load(MODELS_DIR + TREES[rng.randi() % TREES.size()]).instantiate()
		tree.position = Vector3(cos(angle), 0.0, sin(angle)) * distance
		tree.rotation.y = rng.randf() * TAU
		tree.scale = Vector3.ONE * rng.randf_range(0.55, 0.8)
		add_child(tree)
		_trees.append(tree)
