extends "res://source/match/units/Structure.gd"

# Storage yard, like the storages of Captain of Industry: place it next to your
# extractors and their conveyors fill it (see Extractor.linked_storage), so they never
# stop for want of a truck. It holds one commodity at a time: the one the player picked,
# or on Auto whatever arrives first, until it is empty again. Trucks and trains collect
# from it in full loads (Logistics). Destroying it spills the goods, part goes to the
# attacker.

const BufferGauge = preload("res://source/match/units/traits/BufferGauge.gd")

var stored = 0
var kind = null  # commodity held now
var wanted_kind = null  # null: auto, otherwise the only commodity it accepts
var reserved_for_pickup = 0
var logistics_priority = 1  # 0 low, 1 normal, 2 high


func _ready():
	await super()
	var gauge = BufferGauge.new()
	gauge.name = "BufferGauge"
	add_child(gauge)


func get_buffer_capacity():
	return int(Constants.Match.Logistics.STORAGE.get("capacity", 120))


func get_goods_kind():
	return kind


func is_full():
	return stored >= get_buffer_capacity()


func accepts(a_kind):
	if not is_constructed() or is_full():
		return false
	if wanted_kind != null and a_kind != wanted_kind:
		return false
	return kind == null or kind == a_kind or stored == 0


func set_wanted_kind(a_kind):
	wanted_kind = a_kind
	if stored == 0:
		kind = null


func receive(a_kind, amount):
	"""goods coming off a conveyor; returns how many fitted"""
	if not accepts(a_kind):
		return 0
	kind = a_kind
	var accepted = min(amount, get_buffer_capacity() - stored)
	stored += accepted
	return accepted


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
	var goods = {kind: taken} if taken > 0 and kind != null else {}
	if stored == 0 and wanted_kind == null:
		kind = null
	return goods


func get_rate_per_s():
	"""what its conveyors bring in, for the truck and train planning"""
	var rate = 0.0
	if player == null or player.logistics == null:
		return rate
	for extractor in player.logistics.get_extractors():
		if extractor.linked_storage == self:
			rate += extractor.get_rate_per_s()
	return rate


func get_lootable_cargo():
	return {kind: stored} if kind != null and stored > 0 else {}
