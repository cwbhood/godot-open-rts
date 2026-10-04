# Loads the game's content definitions from JSON files so that units, structures,
# commodities, tiers, maps and AI personalities can be added or changed without code.
# Base content lives in res://data/, mods are merged on top from res://mods/<mod>/data/
# and user://mods/<mod>/data/ (entries with the same "id" are patched field by field).
# See data/README.md for the schema.
#
# A unit entry may name a "base" unit instead of a "scene": it then inherits every field
# of the base (properties are merged key by key) and gets a scene generated at runtime
# from the base scene, with its own "model" swapped in. This is how new units are added
# without touching code or the Godot editor (see docs/modding/add-a-unit.md).

const BASE_DATA_DIR = "res://data"
const MOD_ROOTS = ["res://mods", "user://mods"]
const UNITS_ROOT = "res://source/match/units/"
const PROJECTILES = {
	"cannon_shell": "res://source/match/units/projectiles/CannonShell.tscn",
	"rocket": "res://source/match/units/projectiles/Rocket.tscn",
}
const DOMAINS = {"terrain": 1, "air": 0}  # mirrors Constants.Match.Navigation.Domain
const GENERATED_SCENES_ROOT = "res://data-units/"

static var _cache = null
static var _generated_scenes = {}  # scene path -> PackedScene, kept alive for load()


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


static func roads():
	return get_data()["roads"]


static func voices():
	"""data/sounds/voices.json: which voice set each unit uses and what actions need lines"""
	return get_data()["voices"]


static func voice_sets():
	return get_data()["voice_sets"]


static func voice_set_by_id(id):
	for voice_set in voice_sets():
		if voice_set["id"] == id:
			return voice_set
	return null


static func voice_set_id_for(unit_entry):
	"""a unit's own "voice" field wins, then data/sounds/voices.json, then a default"""
	if unit_entry == null:
		return null
	if "voice" in unit_entry:
		return unit_entry["voice"]
	var config = voices()
	var mapped = config.get("unit_voices", {}).get(unit_entry["id"])
	if mapped != null:
		return mapped
	var defaults = config.get("default_voices", {})
	if unit_entry.get("category") == "structure":
		return defaults.get("structure")
	var scene_path = unit_entry.get("base_scene", unit_entry.get("scene", ""))
	if (
		scene_path
		in ["res://source/match/units/Helicopter.tscn", "res://source/match/units/Drone.tscn"]
	):
		return defaults.get("air_unit", defaults.get("unit"))
	return defaults.get("unit")


static func is_generated_scene(scene_path):
	return scene_path.begins_with(GENERATED_SCENES_ROOT)


static func register_generated_scenes():
	"""builds the scenes of data-only units; call before any of them is loaded"""
	for unit in units():
		if is_generated_scene(unit["scene"]) and not unit["scene"] in _generated_scenes:
			var scene = _build_generated_scene(unit)
			if scene != null:
				_generated_scenes[unit["scene"]] = scene


static func apply_model(root, unit):
	"""swaps the visible model under the unit's Geometry node for the entry's "model";
	returns the added model node or null"""
	var model_scene = load(unit["model"]) if ResourceLoader.exists(unit["model"]) else null
	# turrets keep their Geometry under a DetachTransform node, hence the deep search
	var geometry = root.find_child("Geometry", true, false)
	if model_scene == null or geometry == null:
		push_error("GameData: cannot use model '{0}'".format([unit.get("model")]))
		return null
	for child in geometry.get_children():
		if child is Node3D:
			child.visible = false  # kept so that scripts referring to them keep working
	var model = model_scene.instantiate()
	model.name = "Model"
	model.scale = Vector3.ONE * float(unit.get("model_scale", 1.0))
	var offset = unit.get("model_offset", [0, 0, 0])
	model.position = Vector3(offset[0], offset[1], offset[2])
	model.rotation.y = deg_to_rad(float(unit.get("model_rotation_y_deg", 0.0)))
	geometry.add_child(model)
	return model


static func _build_generated_scene(unit):
	var base_scene = load(unit["base_scene"])
	if base_scene == null:
		push_error("GameData: unit '{0}' has an unknown base".format([unit["id"]]))
		return null
	var root = base_scene.instantiate()
	if "model" in unit:
		var model = apply_model(root, unit)
		if model != null:
			model.owner = root
	var scene = PackedScene.new()
	var error = scene.pack(root)
	root.free()
	if error != OK:
		push_error("GameData: cannot build scene of unit '{0}'".format([unit["id"]]))
		return null
	scene.take_over_path(unit["scene"])
	return scene


static func maps():
	var maps_by_scene = {}
	for a_map in get_data()["maps"]:
		maps_by_scene[a_map["scene"]] = {
			"name": a_map["name"],
			"players": int(a_map["players"]),
			"size": Vector2i(int(a_map["size"][0]), int(a_map["size"][1])),
		}
		for optional in ["id", "start_zone_radius", "start_pick_seconds"]:
			if optional in a_map:
				maps_by_scene[a_map["scene"]][optional] = a_map[optional]
	return maps_by_scene


static func ai_personalities():
	return get_data()["ai_personalities"]


static func ai_difficulties():
	"""difficulty levels from data/difficulties/, easiest first"""
	return get_data()["ai_difficulties"]


static func ai_difficulty(id):
	for difficulty in ai_difficulties():
		if difficulty["id"] == id:
			return difficulty
	return null


static func player_colors():
	"""the colours players can pick in the Play menu: [{id, name, color: Color}]"""
	return get_data()["player_colors"].map(
		func(entry):
			var converted = entry.duplicate()
			converted["color"] = Color(entry["color"])
			return converted
	)


static func _convert(field, value):
	match field:
		"color", "icon_tint":
			return Color(value)
		"projectile":
			return PROJECTILES.get(value, value)
		"properties":
			var properties = value.duplicate(true)
			if "attack_domains" in properties:
				var domains = properties["attack_domains"].filter(
					func(domain): return domain in DOMAINS
				)
				properties["attack_domains"] = domains.map(func(domain): return DOMAINS[domain])
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
		"ai_difficulties": _load_dir(BASE_DATA_DIR + "/difficulties"),
		"player_colors": _load_list_file(BASE_DATA_DIR + "/player_colors.json", "player_colors"),
		"roads": _load_list_file(BASE_DATA_DIR + "/roads.json", "roads"),
		"voices": _parse_dict_file(BASE_DATA_DIR + "/sounds/voices.json"),
		"voice_sets": _load_dir(BASE_DATA_DIR + "/sounds/voice_sets"),
	}
	for mod_dir in _find_mod_data_dirs():
		_merge(data["resources"], _load_list_file(mod_dir + "/resources.json", "resources"))
		var mod_tiers = _load_list_file(mod_dir + "/tiers.json", "tiers")
		if not mod_tiers.is_empty():
			data["tiers"] = mod_tiers
		_merge(data["units"], _load_dir(mod_dir + "/units"))
		_merge(data["maps"], _load_dir(mod_dir + "/maps"))
		_merge(data["ai_personalities"], _load_dir(mod_dir + "/ai"))
		_merge(data["ai_difficulties"], _load_dir(mod_dir + "/difficulties"))
		_merge(
			data["player_colors"], _load_list_file(mod_dir + "/player_colors.json", "player_colors")
		)
		var mod_roads = _load_list_file(mod_dir + "/roads.json", "roads")
		if not mod_roads.is_empty():
			data["roads"] = mod_roads
		_merge_voices(data["voices"], _parse_dict_file(mod_dir + "/sounds/voices.json"))
		_merge_voice_sets(data["voice_sets"], _load_dir(mod_dir + "/sounds/voice_sets"))
	_resolve_bases(data["units"])
	data["tiers"].sort_custom(func(a, b): return a["science"] < b["science"])
	data["units"].sort_custom(func(a, b): return a["id"] < b["id"])
	data["ai_difficulties"].sort_custom(func(a, b): return a.get("order", 0) < b.get("order", 0))
	return data


static func _resolve_bases(entries):
	"""units with a "base" inherit the base unit's fields and get a generated scene"""
	var by_id = {}
	for entry in entries:
		by_id[entry["id"]] = entry
	for entry in entries:
		if not "base" in entry:
			continue
		var chain = [entry]
		var base = by_id.get(entry["base"])
		while base != null and "base" in base and not base in chain:
			chain.append(base)
			base = by_id.get(base["base"])
		if base == null or base in chain:
			push_error("GameData: unit '{0}' has a missing or circular base".format([entry["id"]]))
			entry["invalid"] = true
			continue
		var resolved = base.duplicate(true)
		chain.reverse()
		for link in chain:
			for key in link:
				if key == "properties" or key == "power" or key == "cost":
					var merged = resolved.get(key, {}).duplicate(true)
					merged.merge(link[key], true)
					resolved[key] = merged
				else:
					resolved[key] = link[key]
		resolved["base_scene"] = base["scene"]
		resolved["scene"] = GENERATED_SCENES_ROOT + entry["id"] + ".tscn"
		entry.clear()
		entry.merge(resolved)
	for index in range(entries.size() - 1, -1, -1):
		if entries[index].get("invalid", false):
			entries.remove_at(index)


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


static func _merge_voices(base, mod):
	"""unit_voices and default_voices are patched key by key, other fields replaced"""
	for key in mod:
		if key in ["unit_voices", "default_voices"] and key in base:
			base[key].merge(mod[key], true)
		else:
			base[key] = mod[key]


static func _merge_voice_sets(base_sets, mod_sets):
	"""a mod set with a known id replaces lines action by action; a lines entry with a
	"folder" of its own keeps it, so mods can add their files to a base set"""
	for mod_set in mod_sets:
		var existing = base_sets.filter(func(entry): return entry["id"] == mod_set["id"])
		if existing.is_empty():
			base_sets.append(mod_set)
			continue
		var target = existing[0]
		var lines = target.get("lines", {}).duplicate()
		for action in mod_set.get("lines", {}):
			var entries = mod_set["lines"][action].duplicate(true)
			for line in entries:
				if line is Dictionary and not "folder" in line and "folder" in mod_set:
					line["folder"] = mod_set["folder"]
			lines[action] = entries
		for key in mod_set:
			if key != "lines" and key != "folder":
				target[key] = mod_set[key]
		target["lines"] = lines


static func _parse_dict_file(path):
	var parsed = _parse_json_file(path)
	return parsed if parsed is Dictionary else {}


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
