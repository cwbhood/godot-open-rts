extends SceneTree

# Checks the game data (data/ plus every mod in res://mods and user://mods) for mistakes.
#
#   godot --headless --path . -s res://tools/validate_data.gd
#
# Prints one line per problem and exits with code 1 when there is at least one error.
# Warnings (like a missing translation) do not fail the check.

var GameData = null  # loaded once autoloads exist, unit scripts depend on them
var Unit = null
var Structure = null

const UNIT_FIELDS = ["id", "category", "name", "cost"]
const KNOWN_UNIT_FIELDS = [
	"id", "category", "scene", "base", "base_scene", "blueprint", "name", "description",
	"icon", "icon_tint", "tier", "cost", "build_time_s", "produced_by", "built_by",
	"properties", "projectile", "fuel_per_s", "extracts", "power", "speed", "model",
	"model_scale", "model_offset", "model_rotation_y_deg"
]
const KNOWN_PROPERTIES = [
	"sight_range", "hp", "hp_max", "attack_damage", "attack_interval", "attack_range",
	"attack_domains", "cargo_capacity", "radius"
]
const KNOWN_AI_FIELDS = [
	"id", "name", "description", "expected_number_of_workers", "expected_number_of_haulers",
	"extractor_targets", "expected_number_of_power_plants", "expected_number_of_ag_turrets",
	"expected_number_of_aa_turrets", "expected_number_of_battlegroups",
	"expected_number_of_units_in_battlegroup", "raid_party_size", "raid_interval_s",
	"trade_hoarding_factor", "trade_profit_margin", "trade_offer_interval_s",
	"proposes_agreements", "upgrades_roads"
]

var _errors = 0
var _warnings = 0


func _init():
	process_frame.connect(_run, CONNECT_ONE_SHOT)  # autoloads are ready by then


func _run():
	GameData = load("res://source/data-model/GameData.gd")
	Unit = load("res://source/match/units/Unit.gd")
	Structure = load("res://source/match/units/Structure.gd")
	var data = GameData.reload()
	var resources = GameData.resource_ids()
	_check_resources(data["resources"])
	_check_tiers(data["tiers"])
	_check_units(data["units"], resources, data["tiers"].size())
	_check_maps(data["maps"])
	_check_ai(data["ai_personalities"], resources)
	_check_roads(data["roads"], resources, data["tiers"].size())
	print(
		"validate_data: {0} units, {1} commodities, {2} maps, {3} AI personalities".format(
			[data["units"].size(), resources.size(), data["maps"].size(),
			data["ai_personalities"].size()]
		)
	)
	print("validate_data: {0} error(s), {1} warning(s)".format([_errors, _warnings]))
	quit(1 if _errors > 0 else 0)


func _error(where, message):
	_errors += 1
	printerr("ERROR   {0}: {1}".format([where, message]))


func _warn(where, message):
	_warnings += 1
	print("WARNING {0}: {1}".format([where, message]))


func _check_translation(where, key):
	if key is String and key != "" and TranslationServer.translate(key) == key:
		_warn(where, "no translation for '{0}' in assets/translations/".format([key]))


func _check_cost(where, cost, resources):
	if not cost is Dictionary:
		_error(where, "cost must be an object like {\"iron\": 3}")
		return
	for resource in cost:
		if not resource in resources:
			_error(where, "unknown commodity '{0}' (known: {1})".format([resource, ", ".join(resources)]))
		elif not (cost[resource] is float or cost[resource] is int) or cost[resource] < 0:
			_error(where, "amount of '{0}' must be a number >= 0".format([resource]))


func _check_resources(entries):
	var ids = {}
	for entry in entries:
		var where = "resources.json '{0}'".format([entry.get("id", "?")])
		if not "id" in entry:
			_error(where, "missing id")
			continue
		if entry["id"] in ids:
			_error(where, "duplicate id")
		ids[entry["id"]] = true
		for field in ["name", "color", "deposit_scene", "extraction_rate_per_s", "base_price"]:
			if not field in entry:
				_error(where, "missing '{0}'".format([field]))
		if "color" in entry and not Color.html_is_valid(str(entry["color"])):
			_error(where, "color must look like \"#aabbcc\"")
		if "deposit_scene" in entry and not ResourceLoader.exists(entry["deposit_scene"]):
			_error(where, "deposit_scene '{0}' does not exist".format([entry["deposit_scene"]]))
		_check_translation(where, entry.get("name"))


func _check_tiers(entries):
	if entries.is_empty():
		_error("tiers.json", "at least one tier is needed")
		return
	if float(entries[0].get("science", -1)) != 0.0:
		_error("tiers.json", "the first tier must start at science 0")
	for entry in entries:
		_check_translation("tiers.json '{0}'".format([entry.get("name", "?")]), entry.get("name"))


func _check_units(entries, resources, tiers_count):
	var ids = {}
	for entry in entries:
		ids[entry.get("id", "")] = entry
	var producers = ids.keys()
	for entry in entries:
		var where = "units/{0}.json".format([entry.get("id", "?")])
		for field in UNIT_FIELDS:
			if not field in entry:
				_error(where, "missing '{0}'".format([field]))
		for field in entry:
			if not field in KNOWN_UNIT_FIELDS:
				_warn(where, "unknown field '{0}' is ignored".format([field]))
		if not entry.get("category") in ["unit", "structure"]:
			_error(where, "category must be \"unit\" or \"structure\"")
		_check_cost(where, entry.get("cost", {}), resources)
		var tier = int(entry.get("tier", 1))
		if tier < 1 or tier > tiers_count:
			_error(where, "tier must be between 1 and {0}".format([tiers_count]))
		for producer in entry.get("produced_by", []) + entry.get("built_by", []):
			if not producer in producers:
				_error(where, "produced_by/built_by names unknown unit '{0}'".format([producer]))
		if entry.get("category") == "unit" and float(entry.get("build_time_s", 0.0)) < 0.0:
			_error(where, "build_time_s must be >= 0")
		if "speed" in entry and float(entry["speed"]) <= 0.0:
			_error(where, "speed must be > 0")
		for kind in entry.get("extracts", []):
			if not kind in resources:
				_error(where, "extracts unknown commodity '{0}'".format([kind]))
		_check_properties(where, entry.get("properties", {}))
		if "projectile" in entry and not entry["projectile"] in GameData.PROJECTILES:
			_error(
				where,
				"projectile must be one of {0}".format([GameData.PROJECTILES.keys()])
			)
		for field in ["icon", "model", "blueprint"]:
			if field in entry and not ResourceLoader.exists(entry[field]):
				_error(where, "{0} '{1}' does not exist".format([field, entry[field]]))
		_check_translation(where, entry.get("name"))
		_check_translation(where, entry.get("description"))
		_check_scene(where, entry)


func _check_properties(where, properties):
	for key in properties:
		if not key in KNOWN_PROPERTIES:
			_warn(where, "unknown property '{0}'".format([key]))
	if int(properties.get("hp", 1)) > int(properties.get("hp_max", properties.get("hp", 1))):
		_error(where, "hp cannot be greater than hp_max")
	var attack_keys = ["attack_damage", "attack_interval", "attack_range", "attack_domains"]
	var present = attack_keys.filter(func(key): return key in properties)
	if not present.is_empty() and present.size() != attack_keys.size():
		_error(where, "an attacking unit needs all of {0}".format([attack_keys]))
	for domain in properties.get("attack_domains", []):
		if not domain in GameData.DOMAINS:
			_error(where, "attack_domains must be \"terrain\" and/or \"air\"")


func _check_scene(where, entry):
	if not "scene" in entry:
		_error(where, "needs either a 'scene' or a 'base' unit")
		return
	if GameData.is_generated_scene(entry["scene"]):
		GameData.register_generated_scenes()
	var scene = load(entry["scene"]) if ResourceLoader.exists(entry["scene"]) or GameData.is_generated_scene(entry["scene"]) else null
	if scene == null:
		_error(where, "scene '{0}' cannot be loaded".format([entry["scene"]]))
		return
	var node = scene.instantiate()
	if not is_instance_of(node, Unit):
		_error(where, "scene root must use a script extending Unit.gd")
	elif (entry.get("category") == "structure") != is_instance_of(node, Structure):
		_error(where, "category does not match the scene (Structure.gd or not)")
	node.free()


func _check_maps(entries):
	for entry in entries:
		var where = "maps/{0}.json".format([entry.get("id", "?")])
		for field in ["name", "scene", "players", "size"]:
			if not field in entry:
				_error(where, "missing '{0}'".format([field]))
		if not ResourceLoader.exists(entry.get("scene", "")):
			_error(where, "scene '{0}' does not exist".format([entry.get("scene")]))
			continue
		var map = load(entry["scene"]).instantiate()
		var spawn_points = map.find_child("SpawnPoints")
		if spawn_points == null:
			_error(where, "map has no SpawnPoints node")
		elif spawn_points.get_child_count() < int(entry.get("players", 0)):
			_error(
				where,
				"players is {0} but the map has {1} spawn points".format(
					[entry.get("players"), spawn_points.get_child_count()]
				)
			)
		if "size" in entry and Vector2(entry["size"][0], entry["size"][1]) != map.size:
			_error(where, "size {0} does not match the map scene {1}".format([entry["size"], map.size]))
		var deposits = map.find_children("*", "", true, false).filter(
			func(node): return node.get_script() != null and "kind" in node and "amount" in node
		)
		if deposits.is_empty():
			_warn(where, "map has no resource deposits")
		map.free()


func _check_ai(entries, resources):
	for entry in entries:
		var where = "ai/{0}.json".format([entry.get("id", "?")])
		for field in entry:
			if not field in KNOWN_AI_FIELDS:
				_warn(where, "unknown field '{0}' is ignored".format([field]))
		for kind in entry.get("extractor_targets", {}):
			if not kind in resources:
				_error(where, "extractor_targets names unknown commodity '{0}'".format([kind]))
		_check_translation(where, entry.get("name"))


func _check_roads(entries, resources, tiers_count):
	for entry in entries:
		var where = "roads.json '{0}'".format([entry.get("id", "?")])
		if float(entry.get("speed_multiplier", 0.0)) <= 0.0:
			_error(where, "speed_multiplier must be > 0")
		if int(entry.get("tier", 1)) < 1 or int(entry.get("tier", 1)) > tiers_count:
			_error(where, "tier must be between 1 and {0}".format([tiers_count]))
		_check_cost(where, entry.get("cost_per_10_m", {}), resources)
		_check_translation(where, entry.get("name"))
