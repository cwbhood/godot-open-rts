extends RefCounted

# Saving and loading a match. A save is one JSON file in user://saves/ holding the match
# settings and a snapshot of the match: every unit and structure (where it stands, its
# health, construction, cargo, stored goods and production queue), the resource deposits
# still left, each player's stock and city, the treaties and trade agreements, the match
# clock and the camera.
#
# Loading builds the match from the saved settings (Loading.gd with `saved_game`), spawns the
# saved units instead of the starter city (Match._setup_player_units calls spawn_units) and
# then puts the rest back once the match runs (restore_after_start).
#
# Orders kept: move, fight (attack-move), construct, patrol and guard. Not kept: other orders
# (such units stand where they were; the AIs and the trucks' job board hand out new ones),
# goods on their way to a construction site (they go back to the depot's pile and are
# fetched again), laid rail track (the train lays it again), fog of war explored outside
# current sight, and the end screen's statistics before the save.

const Structure = preload("res://source/match/units/Structure.gd")
const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const ProductionQueue = preload("res://source/match/units/traits/ProductionQueue.gd")
const CityBuilding = preload("res://source/match/city/CityBuilding.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const AttackMoving = preload("res://source/match/units/actions/AttackMoving.gd")
const Constructing = preload("res://source/match/units/actions/Constructing.gd")
const Patrolling = preload("res://source/match/units/actions/Patrolling.gd")
const Guarding = preload("res://source/match/units/actions/Guarding.gd")
const Helper = preload("res://source/match/players/human/Helper.gd")

const VERSION = 1
const SAVE_DIR = "user://saves"
const AUTOSAVE_NAME = "autosave"
const QUICKSAVE_NAME = "quicksave"
# plain unit fields copied when the unit has them (haulers, trains, extractors, storages)
const UNIT_FIELDS = [
	"cargo",
	"stored",
	"kind",
	"wanted_kind",
	"logistics_priority",
	"automated",
	"resource_kind",
]

# ---------------------------------------------------------------- files


static func path_of(save_name):
	return SAVE_DIR.path_join(_safe_name(save_name) + ".json")


static func list_saves():
	"""[{name, path, modified, summary}] newest first"""
	var saves = []
	var dir = DirAccess.open(SAVE_DIR)
	if dir == null:
		return saves
	for file in dir.get_files():
		if not file.ends_with(".json"):
			continue
		var path = SAVE_DIR.path_join(file)
		var data = read(path)
		if data == null:
			continue
		(
			saves
			. append(
				{
					"name": file.get_basename(),
					"path": path,
					"modified": FileAccess.get_modified_time(path),
					"summary": data.get("summary", ""),
				}
			)
		)
	saves.sort_custom(func(a, b): return a["modified"] > b["modified"])
	return saves


static func read(path):
	"""the save as a Dictionary, null when it is missing, broken or from a newer game"""
	if not FileAccess.file_exists(path):
		return null
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary or int(data.get("version", 0)) < 1:
		return null
	if int(data["version"]) > VERSION:
		return null
	return data


static func write(save_name, data):
	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var path = path_of(save_name)
	var temp_path = path + ".tmp"
	var file = FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return ""
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	DirAccess.rename_absolute(temp_path, path)  # a crash mid-write never breaks the old save
	return path


static func delete(path):
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


static func save_match(a_match, save_name):
	"""writes the match to user://saves/<save_name>.json; returns the path, "" on failure"""
	return write(save_name, capture(a_match))


static func _safe_name(save_name):
	var safe = ""
	for character in str(save_name).strip_edges():
		safe += character if character.is_valid_identifier() or character in "-0123456789 " else "_"
	return safe if safe != "" else "save"


# ---------------------------------------------------------------- capture


static func capture(a_match):
	var tree = a_match.get_tree()
	var players = tree.get_nodes_in_group("players")
	var data = {
		"version": VERSION,
		"saved_at": Time.get_datetime_string_from_system(false, true),
		"map": a_match.map.scene_file_path,
		"settings": _capture_settings(a_match.settings),
		"elapsed_s": 0.0,
		"players": [],
		"units": [],
		"deposits": _capture_deposits(a_match),
		"diplomacy": [],
		"market": {},
		"camera": _vec3(a_match.get_node("IsometricCamera3D").global_position),
	}
	var limits = a_match.get_node_or_null("MatchLimits")
	if limits != null:
		data["elapsed_s"] = limits.elapsed_s
		data["depleted_at_s"] = limits.depleted_at_s
	var unit_ids = {}  # unit -> index in data["units"]
	for unit in tree.get_nodes_in_group("units"):
		if not unit.is_inside_tree() or unit.player == null or unit.is_queued_for_deletion():
			continue
		unit_ids[unit] = unit_ids.size()
	var civil_roles = {}  # unit -> "post" or "militia" of its city's own defense
	for player in players:
		var civil_defense = player.city.civil_defense if player.city != null else null
		if civil_defense != null:
			for post in civil_defense.get_posts():
				civil_roles[post] = "post"
			for militia in civil_defense.get_militia():
				civil_roles[militia] = "militia"
	for unit in unit_ids:
		var saved = _capture_unit(unit, players)
		if unit in civil_roles:
			saved["civil"] = civil_roles[unit]
			if unit.get("home_position") != null:
				saved["home"] = _vec3(unit.home_position)
		var order = _capture_order(unit.action, unit_ids)
		if order != null:
			saved["order"] = order
		data["units"].append(saved)
	for player in players:
		data["players"].append(_capture_player(player, unit_ids))
	var diplomacy = a_match.get_node_or_null("Diplomacy")
	if diplomacy != null:
		for relation in diplomacy._relations.values():
			(
				data["diplomacy"]
				. append(
					{
						"a": players.find(relation["a"]),
						"b": players.find(relation["b"]),
						"state": relation["state"],
						"left_s": relation["left_s"],
						"aggressor": players.find(relation["aggressor"]),
						"since_s": relation["since_s"] - diplomacy._elapsed_s,
					}
				)
			)
	var market = a_match.get_node_or_null("Market")
	if market != null:
		data["market"] = _capture_market(market, players)
	var guide = a_match.find_child("Guide", true, false)
	if guide != null:
		data["guide"] = {
			"step": guide._step,
			"hints_shown": guide._hints_shown.keys(),
			"delivered": guide._delivered,
			"traded": guide._traded,
			"army": guide._army,
			"commanded": guide._commanded,
		}
	for player in players:
		var helper = Helper.of(player)
		if helper != null and helper.enabled:
			data["helper"] = {
				"player": players.find(player),
				"army": helper.army_target,
				"scouting": helper.scouting
			}
	var minutes = int(data["elapsed_s"] / 60.0)
	data["summary"] = (
		"{0} · {1} min · {2}"
		. format(
			[
				Constants.Match.MAPS.get(data["map"], {}).get(
					"name", data["map"].get_file().get_basename()
				),
				minutes,
				data["saved_at"].replace("T", " ").substr(0, 16),
			]
		)
	)
	return data


static func _capture_settings(settings):
	var out = {
		"visibility": settings.visibility,
		"visible_player": settings.visible_player,
		"sandbox": settings.sandbox,
		"tutorial": settings.tutorial,
		"ai_assist": settings.ai_assist,
		"auto_build": settings.auto_build,
		"players": [],
	}
	for player_settings in settings.players:
		(
			out["players"]
			. append(
				{
					"color": player_settings.color.to_html(),
					"controller": player_settings.controller,
					"spawn_index_offset": player_settings.spawn_index_offset,
					"ai_personality": player_settings.ai_personality,
					"ai_difficulty": player_settings.ai_difficulty,
					"start_zone": player_settings.start_zone,
					"faction": player_settings.faction,
				}
			)
		)
	return out


static func _capture_player(player, unit_ids):
	var out = {"stock": player.get_stock(), "faction": player.faction}
	var city = player.city
	if city != null and city.civil_defense != null:
		out["civil_defense_started"] = city.civil_defense._initial_posts_placed
	if city != null:
		var buildings = []
		for building in city._buildings:
			if is_instance_valid(building):
				(
					buildings
					. append(
						{
							"kind": building.kind,
							"variant": building.variant,
							"at": _vec3(building.global_position),
							"rotation": building.rotation.y,
							"revealed": building.revealed_once,
						}
					)
				)
		out["city"] = {
			"population": city.population,
			"science": city.science,
			"tier": city.tier,
			"trade_growth_boost": city.trade_growth_boost,
			"warehouse": city.warehouse,
			"satisfaction": city.satisfaction,
			"elapsed_s": city._elapsed_s,
			"buildings": buildings,
		}
	var logistics = player.logistics
	if logistics != null:
		var roads = {}
		for extractor in logistics.road_levels:
			if extractor in unit_ids:
				roads[str(unit_ids[extractor])] = logistics.road_levels[extractor]
		out["roads"] = roads
	return out


static func _capture_unit(unit, players):
	var out = {
		"scene": unit._scene_path(),
		"player": players.find(unit.player),
		"transform": _transform(unit.global_transform),
		"hp": unit.hp,
	}
	if unit is Structure:
		out["progress"] = unit.get_construction_progress()
		if unit.is_under_construction():
			# goods on a truck are lost with the truck's order: back to the depot's pile
			var pending = unit.materials_pending.duplicate()
			for resource in unit.materials_in_transit:
				pending[resource] = pending.get(resource, 0) + unit.materials_in_transit[resource]
			out["materials_pending"] = pending
			out["materials_unpaid"] = unit.materials_unpaid
			out["materials_delivered"] = unit.materials_delivered
			out["materials_total"] = unit.materials_total
		var queue = unit.production_queue
		if queue != null and queue.size() > 0:
			out["queue"] = queue.get_elements().map(
				func(element): return [element.unit_prototype.resource_path, element.time_left]
			)
	for field in UNIT_FIELDS:
		var value = unit.get(field)
		if value != null:
			out[field] = value
	if unit.get("cargo_site") != null:
		out.erase("cargo")  # materials for a site went back to its pile, see above
	return out


static func _capture_order(action, unit_ids):
	"""the unit's current order as [kind, target], null when it is not one a save keeps"""
	if action == null or not is_instance_valid(action):
		return null
	if action is Constructing and action._target_unit in unit_ids:
		return ["construct", unit_ids[action._target_unit]]
	if action is Guarding and action._escorted in unit_ids:
		return ["guard", unit_ids[action._escorted]]
	if action is AttackMoving and action._target_position != null:
		return ["fight", _vec3(action._target_position)]
	if action is Patrolling:
		var kind = "patrol_base" if action.is_base_patrol() else "patrol"
		return [kind, action._waypoints.map(_vec3), action._index]
	if action is Moving and action._target_position != null:
		return ["move", _vec3(action._target_position)]
	return null


static func _restore_orders(spawned, data):
	for index in range(min(spawned.size(), data["units"].size())):
		var unit = spawned[index]
		var order = data["units"][index].get("order")
		if (
			order == null
			or unit == null
			or not is_instance_valid(unit)
			or not unit.is_inside_tree()
		):
			continue
		var target = null
		if order[0] in ["construct", "guard"]:
			var target_index = int(order[1])
			target = spawned[target_index] if target_index < spawned.size() else null
			if target == null or not is_instance_valid(target):
				continue
		match order[0]:
			"construct":
				if Constructing.is_applicable(unit, target):
					unit.action = Constructing.new(target)
			"guard":
				unit.action = Guarding.new(target)
			"fight":
				unit.action = AttackMoving.new(_to_vec3(order[1]))
			"patrol":
				unit.action = Patrolling.new(order[1].map(_to_vec3), int(order[2]))
			"patrol_base":
				unit.action = Patrolling.new(order[1].map(_to_vec3), int(order[2]), unit.player)
			"move":
				if Moving.is_applicable(unit):
					unit.action = Moving.new(_to_vec3(order[1]))


static func _capture_deposits(a_match):
	var out = {}
	for deposit in a_match.get_tree().get_nodes_in_group("deposits"):
		if a_match.map.is_ancestor_of(deposit) and not deposit.is_queued_for_deletion():
			out[str(a_match.map.get_path_to(deposit))] = deposit.amount
	return out


static func _capture_market(market, players):
	var agreements = []
	for agreement in market.agreements:
		(
			agreements
			. append(
				{
					"a": players.find(agreement["a"]),
					"b": players.find(agreement["b"]),
					"offered": agreement["offered"],
					"requested": agreement["requested"],
					"remaining": agreement["remaining"],
					"next_in_s": agreement["next_s"] - market._elapsed_s,
				}
			)
		)
	var embargoes = []
	for imposer in players:
		for target in players:
			if imposer != target and market._embargo_active(imposer, target):
				embargoes.append(
					[
						players.find(imposer),
						players.find(target),
						market._embargoes[market._key(imposer, target)] - market._elapsed_s
					]
				)
	return {
		"agreements": agreements,
		"embargoes": embargoes,
		"shipped_total": market.shipped_total,
		"raided_total": market.raided_total,
	}


# ---------------------------------------------------------------- restore


static func settings_from(data):
	var saved = data["settings"]
	var settings = MatchSettings.new()
	settings.visibility = int(saved["visibility"])
	settings.visible_player = int(saved["visible_player"])
	settings.sandbox = saved.get("sandbox", false)
	settings.tutorial = saved.get("tutorial", true)
	settings.ai_assist = saved.get("ai_assist", true)
	settings.auto_build = saved.get("auto_build", true)
	for saved_player in saved["players"]:
		var player_settings = PlayerSettings.new()
		player_settings.color = Color.html(saved_player["color"])
		player_settings.controller = int(saved_player["controller"])
		player_settings.spawn_index_offset = int(saved_player["spawn_index_offset"])
		player_settings.ai_personality = saved_player["ai_personality"]
		player_settings.ai_difficulty = saved_player["ai_difficulty"]
		player_settings.start_zone = int(saved_player.get("start_zone", -1))
		player_settings.faction = saved_player["faction"]
		settings.players.append(player_settings)
	return settings


static func spawn_units(a_match, data):
	"""puts the saved units into the match in place of the starter cities"""
	_restore_deposits(a_match, data.get("deposits", {}))
	var players = a_match.get_tree().get_nodes_in_group("players")
	var spawned = []
	for saved in data["units"]:
		var player_index = int(saved["player"])
		if (
			player_index < 0
			or player_index >= players.size()
			or not ResourceLoader.exists(saved["scene"])
		):
			spawned.append(null)
			continue
		var unit = load(saved["scene"]).instantiate()
		var under_construction = unit is Structure and float(saved.get("progress", 1.0)) < 1.0
		a_match._setup_and_spawn_unit(
			unit, _to_transform(saved["transform"]), players[player_index], under_construction
		)
		_restore_unit(unit, saved)
		spawned.append(unit)
	a_match.set_meta("loaded_units", spawned)


static func _restore_unit(unit, saved):
	if unit is Structure and unit.is_under_construction():
		unit._construction_progress = float(saved.get("progress", 0.0))
		unit.materials_pending = _ints(saved.get("materials_pending", {}))
		unit.materials_unpaid = _ints(saved.get("materials_unpaid", {}))
		unit.materials_delivered = _ints(saved.get("materials_delivered", {}))
		unit.materials_in_transit = {}
		unit.materials_total = int(saved.get("materials_total", unit.materials_total))
	if saved.get("hp") != null and unit.hp_max != null:
		unit.hp = clampi(int(saved["hp"]), 1, unit.hp_max)
	for field in UNIT_FIELDS:
		if field in saved and field in unit:
			var value = saved[field]
			if value is Dictionary:
				value = _ints(value)
			elif value is float and field in ["stored", "logistics_priority"]:
				value = int(value)
			unit.set(field, value)
	if "queue" in saved and unit is Structure and unit.production_queue != null:
		for entry in saved["queue"]:
			if not ResourceLoader.exists(entry[0]):
				continue
			var element = ProductionQueue.ProductionQueueElement.new()
			element.unit_prototype = load(entry[0])
			element.time_total = Constants.Match.Units.PRODUCTION_TIMES.get(
				entry[0], float(entry[1])
			)
			element.time_left = min(float(entry[1]), element.time_total)
			unit.production_queue._enqueue_element(element)


static func _restore_deposits(a_match, deposits):
	if deposits.is_empty():
		return
	for deposit in a_match.get_tree().get_nodes_in_group("deposits"):
		if not a_match.map.is_ancestor_of(deposit):
			continue
		var key = str(a_match.map.get_path_to(deposit))
		if key in deposits:
			deposit.amount = int(deposits[key])
		else:
			# ran dry before the save
			deposit.remove_from_group("deposits")
			deposit.remove_from_group("resource_units")
			deposit.queue_free()


static func restore_after_start(a_match, data):
	"""the parts that live outside units, once every subsystem of the match is ready"""
	var tree = a_match.get_tree()
	var players = tree.get_nodes_in_group("players")
	var spawned = a_match.get_meta("loaded_units", [])
	for index in range(min(players.size(), data["players"].size())):
		_restore_player(players[index], data["players"][index], spawned)
	var limits = a_match.get_node_or_null("MatchLimits")
	if limits != null:
		limits.elapsed_s = float(data.get("elapsed_s", 0.0))
		limits.depleted_at_s = float(data.get("depleted_at_s", -1.0))
	var diplomacy = a_match.get_node_or_null("Diplomacy")
	if diplomacy != null:
		for relation in data.get("diplomacy", []):
			var a = _player_at(players, relation["a"])
			var b = _player_at(players, relation["b"])
			if a == null or b == null:
				continue
			diplomacy._set_state(
				a,
				b,
				int(relation["state"]),
				float(relation["left_s"]),
				_player_at(players, relation.get("aggressor", -1))
			)
			diplomacy._relations[diplomacy._key(a, b)]["since_s"] = (
				diplomacy._elapsed_s + float(relation.get("since_s", 0.0))
			)
	_restore_orders(spawned, data)
	_restore_civil_defense(players, spawned, data)
	var market = a_match.get_node_or_null("Market")
	if market != null and not data.get("market", {}).is_empty():
		_restore_market(market, data["market"], players)
	var guide = a_match.find_child("Guide", true, false)
	if guide != null and "guide" in data:
		var saved_guide = data["guide"]
		guide._step = int(saved_guide.get("step", 0))
		for hint in saved_guide.get("hints_shown", []):
			guide._hints_shown[hint] = true
		for flag in ["delivered", "traded", "army", "commanded"]:
			guide.set("_" + flag, saved_guide.get(flag, false))
		guide._refresh_tutorial()
	if "helper" in data:
		var helper = Helper.of(_player_at(players, data["helper"]["player"]))
		var panel = a_match.find_child("HelperPanel", true, false)
		if helper != null:
			if panel != null and panel.get("_switch") != null:
				panel.get("_switch").button_pressed = true  # the panel and the helper agree
			else:
				helper.enabled = true
			helper.army_target = int(data["helper"].get("army", helper.army_target))
			helper.scouting = data["helper"].get("scouting", helper.scouting)
	if "camera" in data:
		var camera = a_match.get_node("IsometricCamera3D")
		camera.global_position = _to_vec3(data["camera"])
	MatchSignals.match_loaded.emit()


static func _restore_player(player, saved, spawned):
	for resource in saved.get("stock", {}):
		player.set(resource, int(saved["stock"][resource]))
	var city = player.city
	if city != null and "city" in saved:
		var saved_city = saved["city"]
		city.population = float(saved_city["population"])
		city.science = float(saved_city["science"])
		city.tier = int(saved_city["tier"])
		city.trade_growth_boost = float(saved_city.get("trade_growth_boost", 0.0))
		for resource in saved_city.get("warehouse", {}):
			city.warehouse[resource] = float(saved_city["warehouse"][resource])
		for resource in saved_city.get("satisfaction", {}):
			city.satisfaction[resource] = float(saved_city["satisfaction"][resource])
		city._elapsed_s = float(saved_city.get("elapsed_s", 0.0))
		for building in city._buildings:
			building.queue_free()
		city._buildings.clear()
		for saved_building in saved_city.get("buildings", []):
			var building = CityBuilding.new()
			building.kind = saved_building["kind"]
			building.variant = int(saved_building["variant"])
			city.add_child(building)
			building.global_position = _to_vec3(saved_building["at"])
			building.rotation.y = float(saved_building["rotation"])
			building.revealed_once = saved_building.get("revealed", false)
			city._buildings.append(building)
			city._update_building_visibility(building)
		city.changed.emit()
	var logistics = player.logistics
	if logistics != null:
		for unit_index in saved.get("roads", {}):
			var index = int(unit_index)
			var extractor = spawned[index] if index < spawned.size() else null
			if extractor == null or not is_instance_valid(extractor):
				continue
			logistics.road_levels[extractor] = int(saved["roads"][unit_index])
			logistics._update_road_visual(extractor)
			if not extractor.tree_exiting.is_connected(logistics._on_extractor_removed):
				extractor.tree_exiting.connect(logistics._on_extractor_removed.bind(extractor))


static func _restore_civil_defense(players, spawned, data):
	"""the city's posts and militia count as its own again, so it does not raise new ones"""
	for index in range(min(players.size(), data["players"].size())):
		var city = players[index].city
		if city != null and city.civil_defense != null:
			city.civil_defense._initial_posts_placed = data["players"][index].get(
				"civil_defense_started", true
			)
	for index in range(min(spawned.size(), data["units"].size())):
		var unit = spawned[index]
		var role = data["units"][index].get("civil")
		if role == null or unit == null or not is_instance_valid(unit) or unit.player.city == null:
			continue
		var civil_defense = unit.player.city.civil_defense
		if civil_defense == null:
			continue
		unit.add_to_group("city_defense")
		if role == "post":
			civil_defense._posts.append(unit)
		else:
			if "home" in data["units"][index]:
				unit.home_position = _to_vec3(data["units"][index]["home"])
			unit.remove_from_group("controlled_units")  # the city commands it, not the player
			civil_defense._militia.append(unit)


static func _restore_market(market, saved, players):
	market.shipped_total = int(saved.get("shipped_total", 0))
	market.raided_total = int(saved.get("raided_total", 0))
	for agreement in saved.get("agreements", []):
		var a = _player_at(players, agreement["a"])
		var b = _player_at(players, agreement["b"])
		if a == null or b == null:
			continue
		(
			market
			. agreements
			. append(
				{
					"a": a,
					"b": b,
					"offered": _ints(agreement["offered"]),
					"requested": _ints(agreement["requested"]),
					"remaining": int(agreement["remaining"]),
					"next_s": market._elapsed_s + float(agreement["next_in_s"]),
				}
			)
		)
	for embargo in saved.get("embargoes", []):
		var imposer = _player_at(players, embargo[0])
		var target = _player_at(players, embargo[1])
		if imposer != null and target != null:
			market._embargoes[market._key(imposer, target)] = market._elapsed_s + float(embargo[2])


# ---------------------------------------------------------------- helpers


static func _player_at(players, index):
	index = int(index) if index != null else -1
	return players[index] if index >= 0 and index < players.size() else null


static func _ints(dictionary):
	"""JSON reads every number as a float; goods are counted in whole units"""
	var out = {}
	for key in dictionary:
		var value = dictionary[key]
		out[key] = int(value) if value is float and value == floor(value) else value
	return out


static func _vec3(vector):
	return [vector.x, vector.y, vector.z]


static func _to_vec3(values):
	return Vector3(float(values[0]), float(values[1]), float(values[2]))


static func _transform(a_transform):
	var basis = a_transform.basis
	return _vec3(basis.x) + _vec3(basis.y) + _vec3(basis.z) + _vec3(a_transform.origin)


static func _to_transform(values):
	var floats = values.map(func(value): return float(value))
	return Transform3D(
		Vector3(floats[0], floats[1], floats[2]),
		Vector3(floats[3], floats[4], floats[5]),
		Vector3(floats[6], floats[7], floats[8]),
		Vector3(floats[9], floats[10], floats[11])
	)
