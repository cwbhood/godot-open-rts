extends RefCounted

# Playable factions, defined in data/factions/*.json (see data/README.md):
#
# - which units a player may build: a unit with a "factions" list belongs to those
#   factions only, a unit without one is shared, and a faction can hide shared units it
#   replaces with its own ("hidden_units", e.g. its own turrets in place of the generic
#   ones). The rules themselves live in GameData.faction_allows.
# - "roles": which of its units the AI and the city use for each job (main battle unit
#   per tier, raider, turrets, ...). A role the faction leaves out falls back to
#   DEFAULT_ROLES when that unit is in its roster.
# - "start_units", "city" multipliers (trade growth, production speed) and perks such as
#   "armed_caravans".
#
# A player without a faction ("", as in tests and scenes with predefined players) may
# build everything and uses DEFAULT_ROLES, the units the game had before factions.

const GameData = preload("res://source/data-model/GameData.gd")

const NONE = ""
const RANDOM = "random"
const DEFAULT_ROLES = {
	"main_t1": "tank",
	"main_t2": "heavy_tank",
	"main_t3": "battle_tank",
	"air_t2": "helicopter",
	"air_t3": "gunship",
	"raider": "raider",
	"scout": "scout_buggy",
	"ag_turret": "ag_turret",
	"aa_turret": "aa_turret",
	"militia": "militia",
}
const DEFAULT_START_UNITS = ["drone", "worker", "worker", "hauler", "hauler"]


static func ids():
	return GameData.factions().map(func(faction): return faction["id"])


static func of(player):
	"""the faction id of a player node, "" when it has none"""
	if player == null or not is_instance_valid(player):
		return NONE
	var id = player.get("faction")
	return id if id is String else NONE


static func role_id(faction_id, role):
	"""unit id the faction uses for a role, or null when it has none"""
	var faction = GameData.faction_by_id(faction_id) if faction_id != NONE else null
	if faction != null:
		var id = faction.get("roles", {}).get(role)
		if id != null and GameData.unit_by_id(id) != null:
			return id
	var fallback = DEFAULT_ROLES.get(role)
	if fallback == null:
		return null
	var entry = GameData.unit_by_id(fallback)
	if entry == null or not GameData.faction_allows(faction_id, entry):
		return null
	return fallback


static func role_scene(faction_id, role):
	"""scene path of the unit the faction uses for a role, or null"""
	var id = role_id(faction_id, role)
	var entry = GameData.unit_by_id(id) if id != null else null
	return entry["scene"] if entry != null else null


static func role_scene_of(player, role):
	return role_scene(of(player), role)


static func start_units(faction_id):
	var faction = GameData.faction_by_id(faction_id) if faction_id != NONE else null
	var listed = faction.get("start_units", []) if faction != null else []
	var known = listed.filter(func(id): return GameData.unit_by_id(id) != null)
	return known if not known.is_empty() else DEFAULT_START_UNITS


static func city_multiplier(player, key, default = 1.0):
	"""a number from the faction's "city" object, e.g. "trade_growth" or
	"production_speed"; 1.0 for players without a faction"""
	var faction = GameData.faction_by_id(of(player))
	if faction == null:
		return default
	return float(faction.get("city", {}).get(key, default))


static func perk(player, key):
	"""a perk object of the player's faction (e.g. "armed_caravans") or null"""
	var faction = GameData.faction_by_id(of(player))
	if faction == null:
		return null
	return faction.get(key)


static func display_name(faction_id):
	var faction = GameData.faction_by_id(faction_id)
	if faction == null:
		return ""
	return TranslationServer.translate(faction.get("name", faction_id))


static func label_for(player):
	"""e.g. "Sandline Syndicate (Red)", or "" for a player without a faction"""
	var faction_id = of(player)
	if faction_id == NONE or GameData.faction_by_id(faction_id) == null:
		return ""
	var color_name = _color_name(player.color)
	if color_name == "":
		return display_name(faction_id)
	return "{0} ({1})".format([display_name(faction_id), color_name])


static func resolve(choice, personality_id = "", rng = null):
	"""turns a Play menu choice into a faction id: "random" picks one of the factions
	suited to the AI personality (any faction when none lists it)"""
	var all_ids = ids()
	if choice != RANDOM:
		return choice if choice in all_ids or choice == NONE else NONE
	if all_ids.is_empty():
		return NONE
	var suited = GameData.factions().filter(
		func(faction): return personality_id in faction.get("ai_personalities", [])
	)
	var pool = suited.map(func(faction): return faction["id"]) if not suited.is_empty() else all_ids
	var index = rng.randi_range(0, pool.size() - 1) if rng != null else randi() % pool.size()
	return pool[index]


static func _color_name(color):
	var best = null
	var best_distance = INF
	for entry in GameData.player_colors():
		var distance = (
			Vector3(
				entry["color"].r - color.r, entry["color"].g - color.g, entry["color"].b - color.b
			)
			. length()
		)
		if distance < best_distance:
			best_distance = distance
			best = entry
	if best == null or best_distance > 0.05:
		return ""
	return TranslationServer.translate(best["name"])
