extends Node

# Every player has a Logistics node that runs their supply lines:
# - construction sites inside the yard of a depot (a constructed command center) get their
#   materials straight from the depot,
# - every other site waits for haulers bringing the materials from the closest depot,
# - extractors are emptied by haulers that drive the goods to the closest depot,
# - goods delivered to a depot are split between the player's stock and the city
#   warehouse (see City.receive_delivery).
# Haulers away from depots are exposed: destroying them loses the cargo (see Unit loot).
# The route between an extractor and its depot starts as a dirt track and can be upgraded
# (data/roads.json) so that haulers on it drive faster.

const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Hauling = preload("res://source/match/units/actions/Hauling.gd")

const ROAD_WIDTH_M = 1.1

var delivered_total = {}  # statistics: goods that reached a depot
var lost_total = {}  # statistics: goods destroyed on the way or in extractors
var looted_total = {}  # statistics: goods taken from other players
var fuel_burnt_total = {}  # statistics

var out_of_fuel = false
var road_levels = {}  # extractor -> index into Constants.Match.Roads.LEVELS

var _road_visuals = {}  # extractor -> MeshInstance3D

var _site_loaders = {}
var _fuel_accumulated = 0.0  # site -> number of haulers on their way to load materials for it

@onready var _player = get_parent()


func _ready():
	MatchSignals.cargo_destroyed.connect(_on_cargo_destroyed)
	var timer = Timer.new()
	timer.timeout.connect(_tick)
	add_child(timer)
	timer.start(Constants.Match.Logistics.TICK_S)


func get_depots():
	return get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return unit is CommandCenter and unit.player == _player and unit.is_constructed()
	)


func get_haulers():
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Hauler and unit.player == _player
	)


func get_extractors():
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Extractor and unit.player == _player
	)


func get_sites():
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Structure and unit.player == _player and unit.needs_materials()
	)


func closest_depot(position):
	var closest = null
	for depot in get_depots():
		if (
			closest == null
			or (
				_distance(depot.global_position, position)
				< _distance(closest.global_position, position)
			)
		):
			closest = depot
	return closest


func is_in_yard(position):
	var depot = closest_depot(position)
	return (
		depot != null
		and _distance(depot.global_position, position) <= Constants.Match.Logistics.YARD_RADIUS_M
	)


func deliver(goods):
	"""goods arriving at a depot"""
	for resource in goods:
		Utils.Dict.add_amount(delivered_total, resource, goods[resource])
	var remainder = goods
	if _player.city != null:
		remainder = _player.city.receive_delivery(goods)
	_player.add_resources(remainder)
	MatchSignals.goods_delivered.emit(_player, goods)


func assign_job(hauler):
	"""gives an idle hauler something to do; returns true if it got a job"""
	if not hauler.cargo.is_empty():
		return _assign_unloading(hauler)
	if hauler.dedicated_extractor != null:
		if not is_instance_valid(hauler.dedicated_extractor):
			hauler.dedicated_extractor = null
		elif hauler.dedicated_extractor.get_available_for_pickup() >= 1:
			return _assign_pickup(hauler, hauler.dedicated_extractor)
		else:
			return false
	var best_job = null
	var best_score = INF
	for site in get_sites():
		if is_in_yard(site.global_position):
			continue
		var pending = Utils.Dict.sum(site.materials_pending)
		if pending <= _site_loaders.get(site.get_instance_id(), 0) * hauler.cargo_capacity:
			continue
		var depot = closest_depot(site.global_position)
		if depot == null:
			continue
		# sites go first: their materials are already paid for
		var score = (
			(
				_distance(hauler.global_position, depot.global_position)
				+ _distance(depot.global_position, site.global_position)
			)
			* 0.5
		)
		if score < best_score:
			best_score = score
			best_job = [assign_supply, site]
	for extractor in get_extractors():
		var available = extractor.get_available_for_pickup()
		if (
			available < Constants.Match.Logistics.MIN_PICKUP
			and available < Constants.Match.Extraction.STORAGE_MAX
		):
			continue
		if _haulers_dedicated_to(extractor) > 0:
			continue
		var score = (
			_distance(hauler.global_position, extractor.global_position)
			/ (1.0 + float(available) / hauler.cargo_capacity)
		)
		if score < best_score:
			best_score = score
			best_job = [_assign_pickup, extractor]
	if best_job == null:
		return false
	return best_job[0].call(hauler, best_job[1])


func get_road_level(extractor):
	return road_levels.get(extractor, 0)


func get_road_speed_multiplier(extractor):
	var levels = Constants.Match.Roads.LEVELS
	if levels.is_empty():
		return 1.0
	return float(levels[min(get_road_level(extractor), levels.size() - 1)]["speed_multiplier"])


func get_road_length_m(extractor):
	var depot = closest_depot(extractor.global_position)
	if depot == null:
		return 0.0
	return _distance(depot.global_position, extractor.global_position)


func get_road_upgrade_for(extractor):
	"""{"level", "entry", "cost"} of the next upgrade of the extractor's route, or null"""
	var levels = Constants.Match.Roads.LEVELS
	var next_level = get_road_level(extractor) + 1
	if next_level >= levels.size() or closest_depot(extractor.global_position) == null:
		return null
	var segments = max(1, int(ceil(get_road_length_m(extractor) / 10.0)))
	var cost = {}
	for resource in levels[next_level].get("cost_per_10_m", {}):
		cost[resource] = int(levels[next_level]["cost_per_10_m"][resource]) * segments
	return {"level": next_level, "entry": levels[next_level], "cost": cost}


func can_upgrade_road(extractor):
	var upgrade = get_road_upgrade_for(extractor)
	return (
		upgrade != null
		and extractor.is_constructed()
		and _player.has_tier(int(upgrade["entry"].get("tier", 1)))
		and _player.has_resources(upgrade["cost"])
	)


func upgrade_road(extractor):
	if not can_upgrade_road(extractor):
		return false
	var upgrade = get_road_upgrade_for(extractor)
	_player.subtract_resources(upgrade["cost"])
	road_levels[extractor] = upgrade["level"]
	_update_road_visual(extractor)
	if not extractor.tree_exiting.is_connected(_on_extractor_removed):
		extractor.tree_exiting.connect(_on_extractor_removed.bind(extractor))
	MatchSignals.road_upgraded.emit(_player, extractor, upgrade["level"])
	return true


func _on_extractor_removed(extractor):
	road_levels.erase(extractor)
	var visual = _road_visuals.get(extractor)
	if visual != null and is_instance_valid(visual):
		visual.queue_free()
	_road_visuals.erase(extractor)
	MatchSignals.road_upgraded.emit(_player, extractor, 0)


func _update_road_visual(extractor):
	"""a simple strip between the depot and the extractor so upgraded routes are visible"""
	var depot = closest_depot(extractor.global_position)
	if depot == null:
		return
	var visual = _road_visuals.get(extractor)
	if visual == null or not is_instance_valid(visual):
		visual = MeshInstance3D.new()
		visual.name = "Road"
		visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(visual)
		_road_visuals[extractor] = visual
	var start = depot.global_position * Vector3(1, 0, 1)
	var end = extractor.global_position * Vector3(1, 0, 1)
	var length = start.distance_to(end)
	var mesh = BoxMesh.new()
	mesh.size = Vector3(ROAD_WIDTH_M, 0.04, max(0.1, length))
	var material = StandardMaterial3D.new()
	material.albedo_color = Color(
		Constants.Match.Roads.LEVELS[get_road_level(extractor)].get("color", "#555555")
	)
	material.roughness = 0.95
	mesh.material = material
	visual.mesh = mesh
	visual.global_transform = Transform3D(Basis(), (start + end) * 0.5 + Vector3(0, 0.03, 0))
	if length > 0.01:
		visual.look_at(end + Vector3(0, 0.03, 0), Vector3.UP)


func is_unit_out_of_fuel(unit):
	return out_of_fuel and Constants.Match.Units.FUEL_PER_S.get(unit._scene_path(), 0.0) > 0.0


func _tick():
	_burn_fuel(Constants.Match.Logistics.TICK_S)
	_supply_sites_in_yards()
	for hauler in get_haulers():
		if hauler.automated and hauler.action == null:
			assign_job(hauler)


func _burn_fuel(delta):
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player != _player:
			continue
		var movement = unit.find_child("Movement")
		if movement == null or movement.velocity.length_squared() < 0.0001:
			continue
		_fuel_accumulated += Constants.Match.Units.FUEL_PER_S.get(unit._scene_path(), 0.0) * delta
	var whole = int(floor(_fuel_accumulated))
	if whole > 0:
		var burnt = min(whole, _player.oil)
		if burnt > 0:
			_player.subtract_resources({"oil": burnt})
		_fuel_accumulated -= whole
		Utils.Dict.add_amount(fuel_burnt_total, "oil", burnt)
	out_of_fuel = _player.oil <= 0 and not FeatureFlags.allow_resources_deficit_spending


func _supply_sites_in_yards():
	var budget_per_site = (
		Constants.Match.Logistics.YARD_DELIVERY_PER_S * Constants.Match.Logistics.TICK_S
	)
	for site in get_sites():
		site.repay_lost_materials()
		if not is_in_yard(site.global_position):
			continue
		var budget = int(ceil(budget_per_site))
		for resource in site.materials_pending.keys():
			var amount = min(site.materials_pending[resource], budget)
			if amount <= 0:
				continue
			budget -= amount
			Utils.Dict.add_amount(site.materials_pending, resource, -amount)
			site.receive_materials({resource: amount}, false)


func assign_supply(hauler, site):
	var depot = closest_depot(site.global_position)
	if depot == null:
		return false
	# keyed by id: the lambda below may outlive the site (freed objects can't be captured)
	var site_id = site.get_instance_id()
	_site_loaders[site_id] = _site_loaders.get(site_id, 0) + 1
	var state = {"loading": true}
	var release_loader = func():
		if state["loading"]:
			state["loading"] = false
			_site_loaders[site_id] = max(0, _site_loaders.get(site_id, 1) - 1)
			if _site_loaders[site_id] == 0:
				_site_loaders.erase(site_id)
	var site_ref = weakref(site)
	var load_materials = func():
		release_loader.call()
		var target = site_ref.get_ref()
		if target == null or not target.is_inside_tree():
			return false
		var materials = target.take_pending_materials(hauler.get_free_capacity())
		if materials.is_empty():
			return false
		hauler.load_cargo(materials, target)
		return true
	var unload_materials = func():
		var target = site_ref.get_ref()
		if target == null or not target.is_inside_tree():
			return false
		target.receive_materials(hauler.unload_cargo())
		return true
	hauler.road_speed_multiplier = 1.0
	hauler.action = Hauling.new(
		[[depot, load_materials], [site, unload_materials]], release_loader, "SUPPLYING"
	)
	return true


func _assign_pickup(hauler, extractor):
	var depot = closest_depot(extractor.global_position)
	if depot == null:
		return false
	var amount = min(extractor.get_available_for_pickup(), hauler.get_free_capacity())
	extractor.reserve_pickup(amount)
	var state = {"reserved": true}
	var extractor_ref = weakref(extractor)  # the lambdas may outlive the extractor
	var release_reservation = func():
		if state["reserved"]:
			state["reserved"] = false
			var source = extractor_ref.get_ref()
			if source != null:
				source.cancel_pickup_reservation(amount)
	var take_goods = func():
		var source = extractor_ref.get_ref()
		if source == null or not source.is_inside_tree():
			state["reserved"] = false
			return false
		state["reserved"] = false
		var goods = source.take_goods(amount)
		if goods.is_empty():
			return false
		hauler.load_cargo(goods)
		return true
	var unload_goods = func():
		deliver(hauler.unload_cargo())
		return true
	hauler.road_speed_multiplier = get_road_speed_multiplier(extractor)
	hauler.action = Hauling.new(
		[[extractor, take_goods], [depot, unload_goods]], release_reservation, "COLLECTING"
	)
	return true


func _assign_unloading(hauler):
	hauler.road_speed_multiplier = 1.0
	var site = hauler.cargo_site
	if (
		site != null
		and is_instance_valid(site)
		and site.is_inside_tree()
		and site.is_under_construction()
	):
		var site_ref = weakref(site)
		var unload_materials = func():
			var target = site_ref.get_ref()
			if target == null or not target.is_inside_tree():
				return false
			target.receive_materials(hauler.unload_cargo())
			return true
		hauler.action = Hauling.new([[site, unload_materials]], null, "SUPPLYING")
		return true
	var depot = closest_depot(hauler.global_position)
	if depot == null:
		return false
	var unload_goods = func():
		hauler.cargo_site = null
		deliver(hauler.unload_cargo())
		return true
	hauler.action = Hauling.new([[depot, unload_goods]], null, "RETURNING")
	return true


func _haulers_dedicated_to(extractor):
	return get_haulers().filter(func(hauler): return hauler.dedicated_extractor == extractor).size()


func _on_cargo_destroyed(_unit, owner, cargo, looter, loot):
	if owner == _player:
		for resource in cargo:
			Utils.Dict.add_amount(lost_total, resource, cargo[resource])
	if looter == _player:
		for resource in loot:
			Utils.Dict.add_amount(looted_total, resource, loot[resource])


static func _distance(a, b):
	return (a * Vector3(1, 0, 1)).distance_to(b * Vector3(1, 0, 1))
