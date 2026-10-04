extends "res://source/match/units/Unit.gd"

signal constructed

const UNDER_CONSTRUCTION_MATERIAL = preload(
	"res://source/match/resources/materials/structure_under_construction.material.tres"
)
const SiteStatusLabel = preload("res://source/match/units/traits/SiteStatusLabel.gd")

# Construction materials are paid up front (see StructurePlacementHandler and the AI) and
# then wait at a depot until they reach the site, either straight from the yard of a
# nearby command center or on haulers (see Logistics). A site cannot be built further
# than the share of materials that has already arrived.
var materials_pending = {}  # paid for, waiting at the depot to be picked up
var materials_in_transit = {}  # loaded on haulers
var materials_unpaid = {}  # lost on the way (raided haulers), has to be paid again
var materials_delivered = {}
var materials_total = 0
var power_ratio = 1.0  # set by the power grid for structures that consume power

var _construction_progress = 1.0

@onready var production_queue = find_child("ProductionQueue"):
	set(_value):
		pass


func _ready():
	await super()
	if is_under_construction():
		_change_geometry_material(UNDER_CONSTRUCTION_MATERIAL)  # again, for the swapped-in model


func is_revealing():
	return super() and is_constructed()


func mark_as_under_construction():
	assert(not is_under_construction(), "structure already under construction")
	_construction_progress = 0.0
	_change_geometry_material(UNDER_CONSTRUCTION_MATERIAL)
	var cost = Constants.Match.Units.CONSTRUCTION_COSTS.get(_scene_path(), {})
	materials_pending = cost.duplicate()
	materials_total = Utils.Dict.sum(cost)
	var label = SiteStatusLabel.new()
	label.name = "SiteStatusLabel"
	add_child(label)
	if hp == null:
		await ready
	hp = 1


func construct(progress):
	assert(is_under_construction(), "structure must be under construction")
	progress = min(progress, get_materials_ratio() - _construction_progress)
	if progress <= 0.0:
		return

	var expected_hp_before_progressing = int(_construction_progress * float(hp_max - 1))
	_construction_progress += progress
	var expected_hp_after_progressing = int(_construction_progress * float(hp_max - 1))
	if expected_hp_after_progressing > expected_hp_before_progressing:
		hp += 1
	if _construction_progress >= 1.0:
		_finish_construction()


func cancel_construction():
	# materials still at the depot or already on site are salvaged, the ones on the road
	# are brought back by their haulers
	player.add_resources(materials_pending)
	player.add_resources(materials_delivered)
	materials_pending = {}
	materials_delivered = {}
	queue_free()


func get_construction_progress():
	return _construction_progress


func get_materials_ratio():
	if materials_total == 0:
		return 1.0
	return float(Utils.Dict.sum(materials_delivered)) / float(materials_total)


func needs_materials():
	return (
		is_under_construction()
		and (not materials_pending.is_empty() or not materials_unpaid.is_empty())
	)


func take_pending_materials(capacity):
	"""a hauler loads up to 'capacity' of the materials waiting for this site"""
	var cargo = {}
	for resource in materials_pending.keys():
		var amount = min(materials_pending[resource], capacity - Utils.Dict.sum(cargo))
		if amount <= 0:
			continue
		cargo[resource] = amount
		Utils.Dict.add_amount(materials_pending, resource, -amount)
		Utils.Dict.add_amount(materials_in_transit, resource, amount)
	return cargo


func receive_materials(materials, from_transit = true):
	for resource in materials:
		if from_transit:
			Utils.Dict.add_amount(materials_in_transit, resource, -materials[resource])
		Utils.Dict.add_amount(materials_delivered, resource, materials[resource])


func lose_materials_in_transit(materials):
	for resource in materials:
		Utils.Dict.add_amount(materials_in_transit, resource, -materials[resource])
		Utils.Dict.add_amount(materials_unpaid, resource, materials[resource])


func repay_lost_materials():
	"""tries to pay again for materials lost on the road"""
	for resource in materials_unpaid.keys():
		var amount = min(materials_unpaid[resource], player.get(resource))
		if FeatureFlags.allow_resources_deficit_spending:
			amount = materials_unpaid[resource]
		if amount <= 0:
			continue
		player.subtract_resources({resource: amount})
		Utils.Dict.add_amount(materials_unpaid, resource, -amount)
		Utils.Dict.add_amount(materials_pending, resource, amount)


func is_constructed():
	return _construction_progress >= 1.0


func is_under_construction():
	return not is_constructed()


func _finish_construction():
	_change_geometry_material(null)
	if is_inside_tree():
		constructed.emit()
		MatchSignals.unit_construction_finished.emit(self)


func _change_geometry_material(material):
	# owned = false: the model swapped in from data/units (GameData.apply_model) is added at
	# runtime and has no owner, so the default lookup skipped it and sites looked finished
	for child in find_child("Geometry").find_children("*", "", true, false):
		if "material_override" in child:
			child.material_override = material
