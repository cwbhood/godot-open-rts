extends "res://source/match/units/Structure.gd"

# Base for oil derricks, mines and lumber mills. Once constructed next to a matching
# deposit it extracts goods into a small local storage. Haulers pick them up and drive
# them to a depot (see Logistics). Extraction slows down without power and stops when the
# storage is full or the deposit runs dry.

signal stored_changed

const ResourceDeposit = preload("res://source/match/units/non-player/ResourceDeposit.gd")

var deposit = null
var resource_kind = null
var stored = 0
var reserved_for_pickup = 0  # goods promised to haulers already on their way

var _accumulated = 0.0


static func find_deposit_near(scene_path, position, structure_radius, scene_tree):
	var kinds = Constants.Match.Extraction.EXTRACTOR_KINDS.get(scene_path, [])
	var closest = null
	var closest_gap = INF
	for candidate in scene_tree.get_nodes_in_group("deposits"):
		if not candidate.kind in kinds or not candidate.is_inside_tree():
			continue
		var gap = (
			(candidate.global_position * Vector3(1, 0, 1)).distance_to(position * Vector3(1, 0, 1))
			- candidate.radius
			- structure_radius
		)
		if gap <= Constants.Match.Extraction.MAX_DISTANCE_TO_DEPOSIT_M and gap < closest_gap:
			closest = candidate
			closest_gap = gap
	return closest


func _ready():
	await super()
	_bind_deposit()
	var timer = Timer.new()
	timer.timeout.connect(_extract.bind(0.5))
	add_child(timer)
	timer.start(0.5)


func is_depleted():
	return deposit == null or not is_instance_valid(deposit)


func get_available_for_pickup():
	return max(0, stored - reserved_for_pickup)


func reserve_pickup(amount):
	reserved_for_pickup += amount


func cancel_pickup_reservation(amount):
	reserved_for_pickup = max(0, reserved_for_pickup - amount)


func take_goods(amount):
	var taken = min(amount, stored)
	stored -= taken
	reserved_for_pickup = max(0, reserved_for_pickup - amount)
	stored_changed.emit()
	return {resource_kind: taken} if taken > 0 else {}


func get_rate_per_s():
	if is_under_construction() or is_depleted():
		return 0.0
	var unpowered = Constants.Match.Extraction.UNPOWERED_RATE_FACTOR
	return (
		Constants.Match.Extraction.RATE_PER_S[resource_kind]
		* (unpowered + (1.0 - unpowered) * power_ratio)
	)


func get_lootable_cargo():
	return {resource_kind: stored} if resource_kind != null and stored > 0 else {}


func _bind_deposit():
	deposit = find_deposit_near(_scene_path(), global_position, radius, get_tree())
	if deposit == null:
		return
	resource_kind = deposit.kind
	deposit.tree_exiting.connect(func(): deposit = null)


func _extract(delta):
	var rate = get_rate_per_s()
	if rate <= 0.0:
		return
	_accumulated += rate * delta
	while _accumulated >= 1.0 and stored < Constants.Match.Extraction.STORAGE_MAX:
		if is_depleted() or deposit.extract(1) == 0:
			break
		stored += 1
		_accumulated -= 1.0
		stored_changed.emit()
	_accumulated = min(_accumulated, 1.0)
