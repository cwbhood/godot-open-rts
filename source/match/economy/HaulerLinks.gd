extends RefCounted

# Read-only view of the truck job board for the HUD: which trucks (and trains) are
# working for a building right now and what a truck is doing. Nothing here changes a
# job; it reads the Hauling and Standby actions Logistics.gd gives the trucks.
#
# A link is a Dictionary:
#   unit      the truck or train
#   kind      COLLECT, LEAVING, WAITING, BRINGING_GOODS, COMING_TO_LOAD,
#             COMING_FOR_MATERIALS, BRINGING_MATERIALS, RETURNING, PARKED or TRAIN
#   cargo     what the truck carries now
#   other     the building at the other end of the trip, or null
#   distance  metres the truck still drives to reach the building (along its stops)
#   eta_s     seconds until it gets there, or -1 when it is not on its way
#   path      world points from the truck through its stops up to the building

const Hauler = preload("res://source/match/units/Hauler.gd")
const Hauling = preload("res://source/match/units/actions/Hauling.gd")
const Standby = preload("res://source/match/units/actions/Standby.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const GameData = preload("res://source/data-model/GameData.gd")

const PARKED = "PARKED"
# a truck on its way to a building first, then the ones already there
const KIND_ORDER = [
	"BRINGING_MATERIALS",
	"BRINGING_GOODS",
	"COLLECT",
	"COMING_TO_LOAD",
	"COMING_FOR_MATERIALS",
	"RETURNING",
	"WAITING",
	"LEAVING",
	"PARKED",
	"TRAIN",
]
# kinds where the truck is driving towards the building
const INBOUND = [
	"BRINGING_MATERIALS",
	"BRINGING_GOODS",
	"COLLECT",
	"COMING_TO_LOAD",
	"COMING_FOR_MATERIALS",
	"RETURNING",
]


static func links_for(building):
	"""the trucks and trains of the building's owner working for it, sorted by kind and
	distance"""
	var links = []
	if building == null or not is_instance_valid(building) or building.player == null:
		return links
	var logistics = building.player.get("logistics")
	if logistics == null:
		return links
	for hauler in logistics.get_haulers():
		var link = _link(hauler, building)
		if link != null:
			links.append(link)
	for train in logistics.fleet.get_trains():
		if not is_instance_valid(train) or train.recycling:
			continue
		if building in train.stops or train.depot == building:
			(
				links
				. append(
					{
						"unit": train,
						"kind": "TRAIN",
						"cargo": train.cargo,
						"other": null,
						"distance": _flat(train.global_position, building.global_position),
						"eta_s": -1.0,
						"path": [],
					}
				)
			)
	links.sort_custom(_before)
	return links


static func is_served_building(building):
	"""buildings whose card lists trucks: extractors, storages, depots and sites"""
	if building == null or not is_instance_valid(building) or not building is Structure:
		return false
	if building.is_under_construction():
		return true
	return building.has_method("get_available_for_pickup") or _is_depot(building)


static func job_of(hauler):
	"""what a truck is doing: {kind, cargo, targets, distance, eta_s, path}; kind is
	COLLECTING, DELIVERING_GOODS, LOADING_FOR_SITE, SUPPLYING_SITE, RETURNING, STANDBY,
	PARKED, MANUAL, RECYCLING or IDLE"""
	var job = {
		"kind": "IDLE",
		"cargo": hauler.cargo,
		"targets": [],
		"distance": 0.0,
		"eta_s": -1.0,
		"path": [],
	}
	if hauler.recycling:
		job["kind"] = "RECYCLING"
	elif hauler.action is Standby:
		job["kind"] = PARKED if hauler.action.description == PARKED else "STANDBY"
		job["targets"] = [hauler.action.target]
	elif hauler.action is Hauling:
		var targets = _valid(hauler.action.get_stop_targets())
		job["targets"] = targets
		match hauler.action.description:
			"COLLECTING":
				job["kind"] = "COLLECTING" if targets.size() >= 2 else "DELIVERING_GOODS"
			"SUPPLYING":
				job["kind"] = "LOADING_FOR_SITE" if targets.size() >= 2 else "SUPPLYING_SITE"
			"RETURNING":
				job["kind"] = "RETURNING"
	elif not hauler.automated:
		job["kind"] = "MANUAL"
	if not job["targets"].is_empty() and job["kind"] != "PARKED" and job["kind"] != "STANDBY":
		var route = _route(hauler, job["targets"], job["targets"].back())
		job["distance"] = route[0]
		job["path"] = route[1]
		job["eta_s"] = route[0] / _speed(hauler)
	elif not job["targets"].is_empty():
		job["distance"] = _flat(hauler.global_position, job["targets"][0].global_position)
		job["path"] = [hauler.global_position, job["targets"][0].global_position]
	return job


static func source_of(hauler):
	"""the extractor or storage the truck's cargo came from, if it still stands"""
	if hauler.cargo_source_id == null or not is_instance_id_valid(hauler.cargo_source_id):
		return null
	var source = instance_from_id(hauler.cargo_source_id)
	return source if source is Node and source.is_inside_tree() else null


static func cargo_text(cargo):
	if cargo == null or cargo.is_empty():
		return ""
	var parts = []
	for kind in cargo:
		if int(round(cargo[kind])) > 0:
			parts.append("{0} {1}".format([int(round(cargo[kind])), _tr(kind.to_upper())]))
	return ", ".join(parts)


static func display_name(unit):
	"""the unit's name from data plus its number among the owner's units of that type,
	so that "Mine 2" in a truck's job is the mine you can find on the map"""
	if unit == null or not is_instance_valid(unit):
		return ""
	if unit is Hauler:
		return _tr("TRUCK_NAME").format([number_of(unit)])
	var entry = GameData.unit_by_scene(unit._scene_path())
	var name = _tr(entry["name"]) if entry != null else str(unit.name)
	return _tr("BUILDING_NUMBERED").format([name, number_of(unit)])


static func number_of(unit):
	"""1, 2, 3... per player and unit type, in the order the units are numbered (the
	HUD numbers units as they spawn, see BuildingInfo.gd)"""
	if unit.has_meta("info_number"):
		return unit.get_meta("info_number")
	var player = unit.player
	if player == null:
		return 0
	var counters = player.get_meta("info_numbers", {})
	var key = unit._scene_path()
	counters[key] = counters.get(key, 0) + 1
	player.set_meta("info_numbers", counters)
	unit.set_meta("info_number", counters[key])
	return counters[key]


static func _link(hauler, building):
	var link = {
		"unit": hauler,
		"kind": "",
		"cargo": hauler.cargo,
		"other": null,
		"distance": 0.0,
		"eta_s": -1.0,
		"path": [],
	}
	if hauler.action is Standby:
		if hauler.action.target != building:
			return null
		link["kind"] = PARKED if hauler.action.description == PARKED else "WAITING"
		link["distance"] = _flat(hauler.global_position, building.global_position)
		return link
	if not hauler.action is Hauling:
		return null
	var targets = _valid(hauler.action.get_stop_targets())
	var description = hauler.action.description
	if not building in targets:
		var source = source_of(hauler)
		if description == "COLLECTING" and targets.size() == 1 and source == building:
			link["kind"] = "LEAVING"
			link["other"] = targets[0]
			link["distance"] = _flat(hauler.global_position, building.global_position)
			return link
		return null
	match description:
		"COLLECTING":
			if targets.size() >= 2 and targets[0] == building:
				link["kind"] = "COLLECT"
				link["other"] = targets[1]
				var kind = building.get_goods_kind()
				link["goods"] = _tr(kind.to_upper()).to_lower() if kind != null else ""
			elif targets.size() == 1:
				link["kind"] = "BRINGING_GOODS"
				link["other"] = source_of(hauler)
			else:
				return null  # the depot: the truck is still on its way to collect
		"SUPPLYING":
			if targets.size() >= 2 and targets[0] == building:
				link["kind"] = "COMING_TO_LOAD"
				link["other"] = targets[1]
			elif targets.size() >= 2:
				link["kind"] = "COMING_FOR_MATERIALS"
				link["other"] = targets[0]
			else:
				link["kind"] = "BRINGING_MATERIALS"
		"RETURNING":
			link["kind"] = "RETURNING"
		_:
			return null
	var route = _route(hauler, targets, building)
	link["distance"] = route[0]
	link["path"] = route[1]
	link["eta_s"] = route[0] / _speed(hauler)
	return link


static func _route(hauler, targets, last):
	"""[metres, points] from the truck through its stops up to and including last"""
	var points = [hauler.global_position]
	var metres = 0.0
	for target in targets:
		metres += _flat(points.back(), target.global_position)
		points.append(target.global_position)
		if target == last:
			break
	return [metres, points]


static func _valid(targets):
	var valid = []
	for target in targets:
		if is_instance_valid(target) and target.is_inside_tree():
			valid.append(target)
	return valid


static func _speed(hauler):
	return max(hauler.movement_speed * max(hauler.road_speed_multiplier, 0.1), 0.1)


static func _is_depot(building):
	return building is CommandCenter


static func _before(a, b):
	var rank_a = KIND_ORDER.find(a["kind"])
	var rank_b = KIND_ORDER.find(b["kind"])
	if rank_a != rank_b:
		return rank_a < rank_b
	return a["distance"] < b["distance"]


static func _flat(a, b):
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


static func _tr(key):
	return TranslationServer.translate(key)
