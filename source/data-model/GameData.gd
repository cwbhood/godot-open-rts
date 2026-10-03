# Loads the game's content definitions from JSON files so that units, structures,
# commodities, tiers, maps and AI personalities can be added or changed without code.
# Base content lives in res://data/, mods are merged on top from res://mods/<mod>/data/
# and user://mods/<mod>/data/ (entries with the same "id" are patched field by field).
# See data/README.md for the schema.

const BASE_DATA_DIR = "res://data"
const MOD_ROOTS = ["res://mods", "user://mods"]
const UNITS_ROOT = "res://source/match/units/"
const PROJECTILES = {
	"cannon_shell": "res://source/match/units/projectiles/CannonShell.tscn",
	"rocket": "res://source/match/units/projectiles/Rocket.tscn",
}
const DOMAINS = {"terrain": 1, "air": 0}  # mirrors Constants.Match.Navigation.Domain

static var _cache = null


static func get_data():
	if _cache == null:
		_cache = _load_all()
	return _cache


static func reload():
	_cache = null
	return get_data()


static func units():
	return get_data()["units"]


static func unit_by_id(id):
	for unit in units():
		if unit["id"] == id:
			return unit
	return null


static func unit_by_scene(scene_path):
	for unit in units():
		if unit["scene"] == scene_path:
			return unit
	return null


static func resource_ids():
	return get_data()["resources"].map(func(resource): return resource["id"])


static func resource_field(field):
	var values = {}
	for resource in get_data()["resources"]:
		if field in resource:
			values[resource["id"]] = _convert(field, resource[field])
	return values


static func unit_field(field, category = null, default = null):
	"""maps unit scene path -> field value"""
	var values = {}
	for unit in units():
		if category != null and unit.get("category") != category:
			continue
		if field in unit:
			values[unit["scene"]] = _convert(field, unit[field])
		elif default != null:
			values[unit["scene"]] = default
	return values


static func unit_power_field(field):
	var values = {}
	for unit in units():
		if field in unit.get("power", {}):
			values[unit["scene"]] = unit["power"][field]
	return values


static func producible_by(producer_id):
	return units().filter(
		func(unit):
			return (
				producer_id in unit.get("produced_by", [])
				or producer_id in unit.get("built_by", [])
			)
	)


static func tiers():
	return get_data()["tiers"]


static func maps():
	var maps_by_scene = {}
	for a_map in get_data()["maps"]:
		maps_by_scene[a_map["scene"]] = {
			"name": a_map["name"],
			"players": int(a_map["players"]),
			"size": Vector2i(int(a_map["size"][0]), int(a_map["size"][1])),
		}
	return maps_by_scene


static func ai_personalities():
	return get_data()["ai_personalities"]


static func _convert(field, value):
	match field:
		"color", "icon_tint":
			return Color(value)
		"projectile":
			return PROJECTILES.get(value, value)
		"properties":
			var properties = value.duplicate(true)
			if "attack_domains" in properties:
				properties["attack_domains"] = properties["attack_domains"].map(
					func(domain): return DOMAINS[domain]
				)
			for key in ["hp", "hp_max", "attack_damage", "cargo_capacity"]:
				if key in properties:
					properties[key] = int(properties[key])
			return properties
		"cost", "starting_stock":
			if value is Dictionary:
				var cost = {}
				for key in value:
					cost[key] = int(value[key])
				return cost
			return int(value)
	return value


static func _load_all():
	var data = {
		"resources": _load_list_file(BASE_DATA_DIR + "/resources.json", "resources"),
		"tiers": _load_list_file(BASE_DATA_DIR + "/tiers.json", "tiers"),
		"units": _load_dir(BASE_DATA_DIR + "/units"),
		"maps": _load_dir(BASE_DATA_DIR + "/maps"),
		"ai_personalities": _load_dir(BASE_DATA_DIR + "/ai"),
	}
	for mod_dir in _find_mod_data_dirs():
		_merge(data["resources"], _load_list_file(mod_dir + "/resources.json", "resources"))
		var mod_tiers = _load_list_file(mod_dir + "/tiers.json", "tiers")
		if not mod_tiers.is_empty():
			data["tiers"] = mod_tiers
		_merge(data["units"], _load_dir(mod_dir + "/units"))
		_merge(data["maps"], _load_dir(mod_dir + "/maps"))
		_merge(data["ai_personalities"], _load_dir(mod_dir + "/ai"))
	data["tiers"].sort_custom(func(a, b): return a["science"] < b["science"])
	data["units"].sort_custom(func(a, b): return a["id"] < b["id"])
	return data


static func _find_mod_data_dirs():
	var dirs = []
	for root in MOD_ROOTS:
		var dir = DirAccess.open(root)
		if dir == null:
			continue
		var mod_names = Array(dir.get_directories())
		mod_names.sort()
		for mod_name in mod_names:
			if DirAccess.dir_exists_absolute(root + "/" + mod_name + "/data"):
				dirs.append(root + "/" + mod_name + "/data")
	return dirs


static func _merge(base_entries, mod_entries):
	for mod_entry in mod_entries:
		var existing = base_entries.filter(func(entry): return entry["id"] == mod_entry["id"])
		if existing.is_empty():
			base_entries.append(mod_entry)
		else:
			existing[0].merge(mod_entry, true)


static func _load_list_file(path, key):
	var parsed = _parse_json_file(path)
	if parsed == null:
		return []
	return parsed.get(key, [])


static func _load_dir(path):
	var entries = []
	var dir = DirAccess.open(path)
	if dir == null:
		return entries
	var file_names = Array(dir.get_files()).filter(func(file): return file.ends_with(".json"))
	file_names.sort()
	for file_name in file_names:
		var entry = _parse_json_file(path + "/" + file_name)
		if entry is Dictionary:
			if not "id" in entry:
				entry["id"] = file_name.get_basename()
			entries.append(entry)
	return entries


static func _parse_json_file(path):
	if not FileAccess.file_exists(path):
		return null
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null:
		push_error("GameData: cannot parse '{0}'".format([path]))
	return parsed
