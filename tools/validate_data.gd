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
var FairStart = null

const UNIT_FIELDS = ["id", "category", "name", "cost"]
const KNOWN_UNIT_FIELDS = [
	"id", "category", "scene", "base", "base_scene", "blueprint", "name", "description",
	"icon", "icon_tint", "tier", "cost", "build_time_s", "produced_by", "built_by",
	"properties", "projectile", "fuel_per_s", "flight_endurance_s", "extracts", "power", "speed", "model",
	"model_scale", "model_offset", "model_rotation_y_deg", "unit_slots", "movement", "water_speed",
	"placement", "voice", "classic_model", "classic_model_scale", "classic_model_offset",
	"classic_model_rotation_y_deg", "factions", "production_bonus", "trade_depot"
]
const KNOWN_FACTION_FIELDS = [
	"id", "order", "name", "description", "color_hint", "start_units", "hidden_units", "roles",
	"city", "armed_caravans", "ai_personalities"
]
# roles the code asks for (see Factions.DEFAULT_ROLES and the AI controllers)
const FACTION_ROLES = [
	"main_t1", "main_t2", "main_t3", "support_t2", "air_t2", "air_t3", "raider", "scout",
	"ag_turret", "aa_turret", "militia", "production_boost", "trade_depot"
]
const FACTION_ROLE_CATEGORY = {
	"ag_turret": "structure", "aa_turret": "structure", "production_boost": "structure",
	"trade_depot": "structure"
}
# field -> [min, max]
const FACTION_CITY_FIELDS = {"production_speed": [0.5, 2.0], "trade_growth": [0.5, 3.0]}
const ARMED_CARAVAN_FIELDS = {
	"attack_damage": [0, 20], "attack_interval": [0.1, 10.0], "attack_range": [1.0, 15.0]
}
const CAPS_NUMBERS = [
	"unit_slots_per_player", "unit_slots_per_match", "default_unit_slots", "time_limit_min",
	"depletion_countdown_min"
]
const CAPS_SCORE_WEIGHTS = ["per_citizen", "per_unit_slot", "per_structure", "per_science"]
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
	"proposes_agreements", "upgrades_roads", "peacefulness", "accepts_alliances",
	"attacks_neutrals", "defence"
]
const KNOWN_DEFENCE_FIELDS = [
	"shape", "front_m", "choke_search_m", "staging_share", "front", "flanks", "reserve",
	"guards", "guard_routes", "max_guard_posts", "spacing_m", "ring_m", "react_m", "leash_m"
]

# field -> [min, max] for numbers, or "bool"
const DIFFICULTY_FIELDS = {
	"order": [0, 100],
	"cheats": "bool",
	"gather_rate": [0.1, 3.0],
	"production_speed": [0.1, 3.0],
	"think_interval_multiplier": [0.1, 10.0],
	"reaction_delay_s": [0.0, 60.0],
	"economy_scale": [0.1, 4.0],
	"defense_scale": [0.0, 4.0],
	"army_size_scale": [0.1, 4.0],
	"max_attack_groups": [0, 20],
	"first_attack_after_s": [0, 7200],
	"raid_interval_scale": [0.0, 10.0],
	"scouting": "bool",
	"tech_upgrades": "bool",
	"retreat_below_hp": [0.0, 0.9],
	"focus_fire": "bool",
}
# bonuses that only a difficulty marked "cheats": true may give
const CHEAT_FIELDS = ["gather_rate", "production_speed"]
const MIN_PLAYER_COLOR_DISTANCE = 0.12  # in RGB, so two players never look alike

var _errors = 0
var _warnings = 0


func _init():
	process_frame.connect(_run, CONNECT_ONE_SHOT)  # autoloads are ready by then


func _run():
	GameData = load("res://source/data-model/GameData.gd")
	Unit = load("res://source/match/units/Unit.gd")
	Structure = load("res://source/match/units/Structure.gd")
	FairStart = load("res://source/match/maps/FairStart.gd")
	var data = GameData.reload()
	var resources = GameData.resource_ids()
	_check_resources(data["resources"])
	_check_tiers(data["tiers"])
	_check_units(data["units"], resources, data["tiers"].size())
	_check_factions(data["factions"], data["units"], data["ai_personalities"])
	_check_maps(data["maps"])
	_check_ai(data["ai_personalities"], resources)
	_check_difficulties(data["ai_difficulties"])
	_check_player_colors(data["player_colors"], data["maps"])
	_check_roads(data["roads"], resources, data["tiers"].size())
	_check_caps("caps.json", data["caps"], true)
	for entry in data["maps"]:
		if "caps" in entry:
			_check_caps("maps/{0}.json caps".format([entry.get("id", "?")]), entry["caps"], false)
	_check_logistics(data["logistics"], data["units"], resources)
	_check_voices(data["units"])
	print(
		(
			"validate_data: {0} units, {1} commodities, {2} maps, {3} AI personalities, "
			+ "{4} difficulties, {5} player colours, {6} factions"
		).format(
			[data["units"].size(), resources.size(), data["maps"].size(),
			data["ai_personalities"].size(), data["ai_difficulties"].size(),
			data["player_colors"].size(), data["factions"].size()]
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
	var previous_max = 0.0
	for entry in entries:
		var where = "tiers.json '{0}'".format([entry.get("name", "?")])
		_check_translation(where, entry.get("name"))
		if not "max_population" in entry:
			_warn(where, "no max_population: the city grows to the built-in 130")
			continue
		var max_population = entry["max_population"]
		if not (max_population is float or max_population is int) or max_population < 10:
			_error(where, "max_population must be a number >= 10 (the starting population)")
		elif max_population < previous_max:
			_error(where, "max_population must not shrink from one tier to the next")
		else:
			previous_max = max_population


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
		if "unit_slots" in entry:
			var slots = entry["unit_slots"]
			if not (slots is float or slots is int) or slots < 0 or int(slots) != slots:
				_error(where, "unit_slots must be a whole number >= 0")
			elif entry.get("category") != "unit":
				_warn(where, "unit_slots only counts for units, structures take none")
		elif entry.get("category") == "unit":
			_warn(where, "no unit_slots: it takes default_unit_slots from caps.json")
		if "speed" in entry and float(entry["speed"]) <= 0.0:
			_error(where, "speed must be > 0")
		if "movement" in entry and not entry["movement"] in GameData.MOVEMENT_DOMAINS:
			_error(
				where,
				"movement must be one of {0}".format([GameData.MOVEMENT_DOMAINS.keys()])
			)
		if "movement" in entry and not "base" in entry:
			_warn(where, "movement applies to units with a base only; the scene sets it otherwise")
		if "water_speed" in entry and float(entry["water_speed"]) <= 0.0:
			_error(where, "water_speed must be > 0")
		if "placement" in entry and entry["placement"] != "shore":
			_error(where, "placement must be \"shore\"")
		for kind in entry.get("extracts", []):
			if not kind in resources:
				_error(where, "extracts unknown commodity '{0}'".format([kind]))
		_check_properties(where, entry.get("properties", {}))
		if "production_bonus" in entry and (
			entry.get("category") != "structure"
			or not float(entry.get("power", {}).get("demand_mw", 0.0)) > 0.0
		):
			_error(where, "production_bonus works for structures with a power demand_mw only")
		if "production_bonus" in entry and not (
			float(entry["production_bonus"]) > 0.0 and float(entry["production_bonus"]) <= 2.0
		):
			_error(where, "production_bonus must be above 0 and at most 2 (+200%)")
		if "trade_depot" in entry and entry.get("category") != "structure":
			_error(where, "trade_depot works for structures only")
		if "projectile" in entry and not entry["projectile"] in GameData.PROJECTILES:
			_error(
				where,
				"projectile must be one of {0}".format([GameData.PROJECTILES.keys()])
			)
		for field in ["icon", "model", "classic_model", "blueprint"]:
			if field in entry and not ResourceLoader.exists(entry[field]):
				_error(where, "{0} '{1}' does not exist".format([field, entry[field]]))
		_check_translation(where, entry.get("name"))
		_check_translation(where, entry.get("description"))
		_check_scene(where, entry)


func _check_factions(factions, units, personalities):
	var faction_ids = factions.map(func(faction): return faction["id"])
	var unit_ids = {}
	for unit in units:
		unit_ids[unit["id"]] = unit
	var personality_ids = personalities.map(func(personality): return personality["id"])
	for unit in units:
		if not "factions" in unit:
			continue
		var where = "units/{0}.json".format([unit["id"]])
		if not unit["factions"] is Array or unit["factions"].is_empty():
			_error(where, "factions must be a list of faction ids, or left out for a shared unit")
			continue
		for faction_id in unit["factions"]:
			if not faction_id in faction_ids:
				_error(where, "factions names unknown faction '{0}' (known: {1})".format(
					[faction_id, ", ".join(faction_ids)]
				))
	for faction in factions:
		var where = "factions/{0}.json".format([faction["id"]])
		for field in faction:
			if not field in KNOWN_FACTION_FIELDS:
				_warn(where, "unknown field '{0}' is ignored".format([field]))
		if faction["id"] in ["", "random"]:
			_error(where, "'{0}' is reserved, pick another id".format([faction["id"]]))
		for field in ["name", "description"]:
			if not field in faction:
				_error(where, "missing '{0}'".format([field]))
			_check_translation(where, faction.get(field))
		if "color_hint" in faction and not Color.html_is_valid(str(faction["color_hint"])):
			_error(where, "color_hint must look like \"#aabbcc\"")
		for field in ["start_units", "hidden_units"]:
			for unit_id in faction.get(field, []):
				if not unit_id in unit_ids:
					_error(where, "{0} names unknown unit '{1}'".format([field, unit_id]))
		for unit_id in faction.get("start_units", []):
			if unit_id in unit_ids and unit_ids[unit_id].get("category") != "unit":
				_error(where, "start_units must be units, '{0}' is a structure".format([unit_id]))
		var roles = faction.get("roles", {})
		for role in roles:
			var unit_id = roles[role]
			if not role in FACTION_ROLES:
				_warn(where, "role '{0}' is not used by the game".format([role]))
			if not unit_id in unit_ids:
				_error(where, "role '{0}' names unknown unit '{1}'".format([role, unit_id]))
				continue
			if not GameData.faction_allows(faction["id"], unit_ids[unit_id]):
				_error(where, "role '{0}' names '{1}', which is not in its roster".format(
					[role, unit_id]
				))
			var category = FACTION_ROLE_CATEGORY.get(role, "unit")
			if role != "militia" and unit_ids[unit_id].get("category") != category:
				_error(where, "role '{0}' needs a {1}, '{2}' is not one".format(
					[role, category, unit_id]
				))
		for role in ["main_t1", "ag_turret"]:
			if not role in roles:
				_warn(where, "no '{0}' role: the AI falls back to the default unit".format([role]))
		_check_number_fields(where + " city", faction.get("city", {}), FACTION_CITY_FIELDS)
		if "armed_caravans" in faction:
			_check_number_fields(
				where + " armed_caravans", faction["armed_caravans"], ARMED_CARAVAN_FIELDS
			)
		for personality_id in faction.get("ai_personalities", []):
			if not personality_id in personality_ids:
				_error(where, "ai_personalities names unknown personality '{0}'".format(
					[personality_id]
				))
		var roster = units.filter(func(unit): return GameData.faction_allows(faction["id"], unit))
		for producer in ["worker", "vehicle_factory"]:
			if not roster.any(func(unit): return producer in unit.get("built_by", []) + unit.get("produced_by", [])):
				_error(where, "its roster has nothing a {0} can make".format([producer]))
	for unit in units:
		if not "factions" in unit:
			continue
		var builders = unit.get("built_by", []) + unit.get("produced_by", [])
		for builder in builders:
			if builder in unit_ids and not unit["factions"].any(
				func(faction_id): return GameData.faction_allows(faction_id, unit_ids[builder])
			):
				_error("units/{0}.json".format([unit["id"]]), "no faction of it has a '{0}' to make it".format([builder]))


func _check_number_fields(where, values, ranges):
	if not values is Dictionary:
		_error(where, "must be an object")
		return
	for key in values:
		if not key in ranges:
			_warn(where, "unknown field '{0}' is ignored".format([key]))
			continue
		var value = values[key]
		if not (value is float or value is int) or value < ranges[key][0] or value > ranges[key][1]:
			_error(where, "'{0}' must be a number from {1} to {2}".format(
				[key, ranges[key][0], ranges[key][1]]
			))


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
		var kind_agnostic = entry.get("generator", {}).get("resource_layout") == "asymmetric"
		for problem in FairStart.problems(map, kind_agnostic):
			_error(where, "unfair start: " + problem)
		_check_map_water(where, map)
		map.free()


func _check_map_water(where, map):
	"""start points and deposits must be on dry land"""
	if not map.has_method("has_water") or not map.has_water():
		return
	var points = []
	for marker in map.find_child("SpawnPoints").get_children():
		points.append([marker.position, "start point " + marker.name])
	var deposits_node = map.get_node_or_null("Deposits")
	for marker in deposits_node.get_children() if deposits_node != null else []:
		points.append([marker.position, "{0} deposit".format([marker.get_meta("kind", "")])])
	for point in points:
		if map.water.is_wet_near(Vector2(point[0].x, point[0].z), 1.5):
			_error(where, "{0} at {1} is in or right next to water".format([point[1], point[0]]))


func _check_ai(entries, resources):
	for entry in entries:
		var where = "ai/{0}.json".format([entry.get("id", "?")])
		for field in entry:
			if not field in KNOWN_AI_FIELDS:
				_warn(where, "unknown field '{0}' is ignored".format([field]))
		var defence = entry.get("defence", {})
		if not defence is Dictionary:
			_error(where, "defence must be an object like {\"front_m\": 16}")
			defence = {}
		for field in defence:
			if not field in KNOWN_DEFENCE_FIELDS:
				_warn(where, "unknown defence field '{0}' is ignored".format([field]))
		if defence.get("shape", "groups") not in ["groups", "ring"]:
			_error(where, "defence shape must be \"groups\" or \"ring\"")
		for kind in entry.get("extractor_targets", {}):
			if not kind in resources:
				_error(where, "extractor_targets names unknown commodity '{0}'".format([kind]))
		_check_translation(where, entry.get("name"))


func _check_difficulties(entries):
	if not entries.any(func(entry): return entry.get("id") == "normal"):
		_error("difficulties/", "there must be a 'normal' difficulty, it is the default")
	var orders = {}
	for entry in entries:
		var where = "difficulties/{0}.json".format([entry.get("id", "?")])
		for field in entry:
			if not field in DIFFICULTY_FIELDS and not field in ["id", "name", "description"]:
				_warn(where, "unknown field '{0}' is ignored".format([field]))
		for field in DIFFICULTY_FIELDS:
			if not field in entry:
				continue
			var value = entry[field]
			var rule = DIFFICULTY_FIELDS[field]
			if rule is String:
				if not value is bool:
					_error(where, "'{0}' must be true or false".format([field]))
			elif not (value is float or value is int):
				_error(where, "'{0}' must be a number".format([field]))
			elif value < rule[0] or value > rule[1]:
				_error(where, "'{0}' must be between {1} and {2}".format([field, rule[0], rule[1]]))
		if not entry.get("cheats", false):
			for field in CHEAT_FIELDS:
				var value = entry.get(field, 1.0)
				if (value is float or value is int) and value > 1.0:
					_error(
						where,
						"'{0}' above 1 is a cheat: set \"cheats\": true or lower it".format([field])
					)
		var order = entry.get("order", 0)
		if order in orders:
			_warn(where, "same 'order' as {0}, the menu order is undefined".format([orders[order]]))
		orders[order] = entry.get("id")
		_check_translation(where, entry.get("name"))
		_check_translation(where, entry.get("description"))


func _check_player_colors(entries, maps):
	var where = "player_colors.json"
	var most_players = 0
	for a_map in maps:
		most_players = max(most_players, int(a_map.get("players", 0)))
	if entries.size() < most_players:
		_error(
			where,
			"{0} colours for maps with up to {1} players".format([entries.size(), most_players])
		)
	var colors = []
	for entry in entries:
		var text = entry.get("color", "")
		if not text is String or not Color.html_is_valid(text):
			_error(where, "'{0}' has no valid \"color\" (like \"#66b1ff\")".format([entry.get("id")]))
			colors.append(null)
			continue
		colors.append(Color(text))
		_check_translation(where, entry.get("name"))
	for i in range(colors.size()):
		for j in range(i + 1, colors.size()):
			if colors[i] == null or colors[j] == null:
				continue
			var distance = Vector3(colors[i].r, colors[i].g, colors[i].b).distance_to(
				Vector3(colors[j].r, colors[j].g, colors[j].b)
			)
			if distance < MIN_PLAYER_COLOR_DISTANCE:
				_error(
					where,
					"'{0}' and '{1}' are too alike to tell players apart".format(
						[entries[i].get("id"), entries[j].get("id")]
					)
				)


func _check_caps(where, caps, complete):
	if not caps is Dictionary:
		_error(where, "must be an object like {\"unit_slots_per_player\": 150}")
		return
	for key in caps:
		if key == "score":
			continue
		if not key in CAPS_NUMBERS:
			_warn(where, "unknown field '{0}' is ignored".format([key]))
		elif not (caps[key] is float or caps[key] is int) or caps[key] < 0:
			_error(where, "'{0}' must be a number >= 0 (0 turns the limit off)".format([key]))
	if complete:
		for key in CAPS_NUMBERS:
			if not key in caps:
				_warn(where, "missing '{0}': that limit is off".format([key]))
	var per_player = float(caps.get("unit_slots_per_player", 0))
	var per_match = float(caps.get("unit_slots_per_match", 0))
	if per_player > 0 and per_match > 0 and per_match < per_player:
		_warn(where, "unit_slots_per_match is below unit_slots_per_player: even 1v1 gets less")
	var score = caps.get("score", {})
	if not score is Dictionary:
		_error(where, "score must be an object of weights")
		return
	for key in score:
		if not key in CAPS_SCORE_WEIGHTS:
			_warn(where, "unknown score weight '{0}' is ignored".format([key]))
		elif not (score[key] is float or score[key] is int):
			_error(where, "score weight '{0}' must be a number".format([key]))


func _check_roads(entries, resources, tiers_count):
	for entry in entries:
		var where = "roads.json '{0}'".format([entry.get("id", "?")])
		if float(entry.get("speed_multiplier", 0.0)) <= 0.0:
			_error(where, "speed_multiplier must be > 0")
		if int(entry.get("tier", 1)) < 1 or int(entry.get("tier", 1)) > tiers_count:
			_error(where, "tier must be between 1 and {0}".format([tiers_count]))
		_check_cost(where, entry.get("cost_per_10_m", {}), resources)
		_check_translation(where, entry.get("name"))


# section -> key -> [min, max] for every number in logistics.json
const LOGISTICS_RANGES = {
	"jobs":
	{
		"tick_s": [0.1, 5.0],
		"min_pickup": [1, 1000],
		"site_value": [0.0, 100.0],
		"city_need_share": [0.0, 1.0],
		"city_need_factor": [0.0, 10.0],
		"load_overhead_s": [0.0, 60.0],
	},
	"standby": {"radius_m": [0.5, 20.0], "max_per_source": [1, 10]},
	"raids": {"avoid_s": [0.0, 600.0], "radius_m": [0.0, 50.0], "penalty": [1.0, 100.0]},
	"storage":
	{
		"capacity": [1, 10000],
		"link_radius_m": [1.0, 50.0],
		"conveyor_per_s": [0.01, 100.0],
		"min_pickup": [1, 1000],
	},
	"train":
	{
		"capacity": [1, 10000],
		"laying_speed": [0.1, 50.0],
		"stop_s": [0.0, 60.0],
		"auto_stops": [1, 10],
		"auto_min_route_m": [0.0, 500.0],
		"max_leg_m": [1.0, 1000.0],
	},
	"fleet":
	{
		"surplus_window_s": [5.0, 1200.0],
		"surplus_spare": [0, 50],
		"surplus_min": [1, 50],
		"recycle_refund": [0.0, 1.0],
	},
}


func _check_logistics(logistics, units, resources):
	var where = "logistics.json"
	if logistics.is_empty():
		_error(where, "missing or not a JSON object")
		return
	if int(logistics.get("extractor_buffer", 0)) < 1:
		_error(where, "extractor_buffer must be at least 1")
	for section in LOGISTICS_RANGES:
		var values = logistics.get(section)
		if not values is Dictionary:
			_error(where, "section '{0}' is missing".format([section]))
			continue
		for key in LOGISTICS_RANGES[section]:
			var bounds = LOGISTICS_RANGES[section][key]
			if not key in values:
				_error(where, "'{0}.{1}' is missing".format([section, key]))
			elif float(values[key]) < bounds[0] or float(values[key]) > bounds[1]:
				_error(
					where,
					"'{0}.{1}' = {2} is outside {3}..{4}".format(
						[section, key, values[key], bounds[0], bounds[1]]
					)
				)
	var factors = logistics.get("jobs", {}).get("priority_factors", [])
	if factors.size() != 3 or factors.any(func(factor): return float(factor) <= 0.0):
		_error(where, "jobs.priority_factors must be three numbers > 0 (low, normal, high)")
	_check_cost(where + " train.track_cost_per_10_m", logistics.get("train", {}).get("track_cost_per_10_m", {}), resources)
	var upkeep = logistics.get("fleet", {}).get("upkeep_oil_per_min", {})
	for kind in upkeep:
		if float(upkeep[kind]) < 0.0:
			_error(where, "fleet.upkeep_oil_per_min.{0} must be >= 0".format([kind]))
	for id in ["storage", "train", "hauler"]:
		if units.filter(func(unit): return unit["id"] == id).is_empty():
			_error(where, "the logistics system needs a unit with id '{0}' in data/units".format([id]))
	if not "oil" in resources and not upkeep.is_empty():
		_warn(where, "fleet upkeep is paid in oil, but there is no 'oil' commodity")


func _check_voices(units):
	"""every unit needs a voice set with a sound for each action; files must exist"""
	var actions = GameData.voices().get("unit_actions", [])
	for entry in units:
		var where = "units/{0}.json".format([entry["id"]])
		var set_id = GameData.voice_set_id_for(entry)
		var voice_set = GameData.voice_set_by_id(set_id) if set_id != null else null
		if voice_set == null:
			_error(where, "voice set '{0}' not found in data/sounds/voice_sets/".format([set_id]))
			continue
		for action in actions:
			if voice_set.get("lines", {}).get(action, []).is_empty():
				_error(where, "voice set '{0}' has no sound for '{1}'".format([set_id, action]))
	var VoiceBank = load("res://source/match/audio/VoiceBank.gd")
	for voice_set in GameData.voice_sets():
		for action in voice_set.get("lines", {}):
			for line in voice_set["lines"][action]:
				var path = VoiceBank.line_path(voice_set, line)
				if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
					_error("sounds/voice_sets/" + voice_set["id"] + ".json", "missing " + path)
