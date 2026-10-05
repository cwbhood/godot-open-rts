extends Node3D

# City centres (the command centers) and what happens when they fall. The numbers are in
# data/city_centres.json:
# - Every finished city centre rules a circle on the ground ("radius_m"); the buildings and
#   houses inside it belong to that city. Your own circles are drawn on the ground, and the
#   blueprint of a new city centre shows the circle it will get.
# - A player may have "max_per_player" city centres (sites count), each at least
#   "min_spacing_m" from the others. Capturing one may take a player past the limit.
# - When a player's last city centre is lost, a countdown ("rebuild_countdown_s") starts.
#   A new city centre finished in time ends it: what still stands inside its circle (or
#   inside the circle of another city centre) is kept, the player's other buildings and
#   houses are abandoned. Rebuild where the old city stood to keep it; rebuild elsewhere
#   to start over there. When the countdown runs out the player is defeated and loses
#   everything left. Sandbox matches have no countdown.
# - Surrender: a finished city centre that was hit lately ("attack_memory_s", the hit may
#   be on any building in its circle) with enemy fighting units in its circle and no
#   friendly turret or fighting unit (own or allied) there raises a white flag. While the
#   flag flies the city takes no damage. Defenders reaching the circle, or the attackers
#   leaving it, lower the flag. After "surrender_countdown_s" the city centre, the
#   buildings and the houses in its circle go to the attacker with the most firepower
#   there, together with the share of citizens living in those houses.
# The AIs play by the same rules: EconomyController rebuilds where most of its old city
# still stands and adds a second city centre later on, ArmyPositioningController defends
# every circle, and attacking armies take cities that cannot defend themselves.
# The state is saved with the match (capture / restore, see SaveGame.gd).

const GameData = preload("res://source/data-model/GameData.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const CityBuilding = preload("res://source/match/city/CityBuilding.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const SaveGame = preload("res://source/match/SaveGame.gd")
const SurrenderFlag = preload("res://source/match/city/SurrenderFlag.gd")

const TICK_S = 0.25
const RING_Y = 0.1
const RING_WIDTH_M = 0.3
const RING_SEGMENTS = 72
const OWN_RING_ALPHA = 0.45
const LOST_SITE_COLOR = Color(1.0, 0.55, 0.2, 0.85)
const SURRENDER_COLOR = Color(1.0, 1.0, 1.0, 0.9)
const BLUEPRINT_OK_COLOR = Color(0.55, 1.0, 0.55, 0.75)
const BLUEPRINT_BAD_COLOR = Color(1.0, 0.4, 0.35, 0.75)

var config = {}
var countdowns = {}  # player -> {"left_s", "sites": [Vector3 where its city centres stood]}
var surrenders = {}  # command center -> {"left_s"}
var defeated = {}  # player -> true

var _had_centre = {}  # player -> true once it had a finished city centre
var _last_sites = {}  # player -> positions of its finished city centres at the last tick
var _last_hit_s = {}  # command center -> _elapsed_s of the last enemy hit in its circle
var _elapsed_s = 0.0
var _since_tick_s = 0.0
var _mesh = ImmediateMesh.new()
var _mesh_instance = MeshInstance3D.new()
var _site_labels = []
var _banner_layer = CanvasLayer.new()
var _banner = Label.new()

@onready var _match = get_parent()


static func of(tree):
	"""the city centre rules of the running match or null (e.g. a test without a Match)"""
	return tree.get_first_node_in_group("city_centres") if tree != null else null


func _ready():
	add_to_group("city_centres")
	config = GameData.city_centres()
	var material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.render_priority = 5
	_mesh_instance.name = "Rings"
	_mesh_instance.mesh = _mesh
	_mesh_instance.material_override = material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
	_banner_layer.name = "CityCentreBanner"
	_banner_layer.layer = 4
	add_child(_banner_layer)
	_banner.name = "Banner"
	_banner.add_theme_font_size_override("font_size", 22)
	_banner.add_theme_color_override("font_color", Color("ffd27a"))
	_banner.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_banner.add_theme_constant_override("outline_size", 8)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.hide()
	_banner_layer.add_child(_banner)
	MatchSignals.unit_damaged.connect(_on_unit_damaged)


# rules other code asks about


func radius():
	return float(config["radius_m"])


func max_per_player():
	return int(config["max_per_player"])


func centres_of(player, include_sites = false):
	var found = []
	for unit in get_tree().get_nodes_in_group("units"):
		if (
			unit is CommandCenter
			and unit.player == player
			and not unit.is_queued_for_deletion()
			and (include_sites or unit.is_constructed())
		):
			found.append(unit)
	return found


func can_place_more(player):
	return centres_of(player, true).size() < max_per_player()


func too_close_to_own_centre(player, position):
	var position_yless = position * Vector3(1, 0, 1)
	for centre in centres_of(player, true):
		if (
			centre.global_position_yless.distance_to(position_yless)
			< float(config["min_spacing_m"])
		):
			return true
	return false


func centre_covering(player, position):
	"""the player's finished city centre whose circle holds the position, or null"""
	var position_yless = position * Vector3(1, 0, 1)
	var best = null
	var best_distance = INF
	for centre in centres_of(player):
		var distance = centre.global_position_yless.distance_to(position_yless)
		if distance <= radius() and distance < best_distance:
			best = centre
			best_distance = distance
	return best


func rebuild_time_left(player):
	"""seconds left to rebuild a city centre, or -1 when no countdown runs"""
	return countdowns[player]["left_s"] if player in countdowns else -1.0


func lost_sites(player):
	return countdowns[player]["sites"] if player in countdowns else []


func is_surrendering(command_center):
	return command_center in surrenders


func surrender_time_left(command_center):
	return surrenders[command_center]["left_s"] if command_center in surrenders else -1.0


func rebuild_anchor(player):
	"""where an AI should rebuild: the lost city site with the most of its buildings still
	standing, or null"""
	var best = null
	var best_count = -1
	for site in lost_sites(player):
		var count = 0
		for unit in get_tree().get_nodes_in_group("units"):
			if (
				unit.player == player
				and unit is Structure
				and unit.global_position_yless.distance_to(site) <= radius()
			):
				count += 1
		if count > best_count:
			best = site
			best_count = count
	return best


func defenders_near(command_center):
	"""own or allied turrets and fighting units in the city centre's circle"""
	var owner_player = command_center.player
	var center = command_center.global_position_yless
	var found = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit == command_center or unit.attack_damage == null or unit.is_queued_for_deletion():
			continue
		if unit.player != owner_player and not Diplomacy.allied(unit.player, owner_player):
			continue
		if unit is Structure and not unit.is_constructed():
			continue
		if unit.global_position_yless.distance_to(center) <= radius():
			found.append(unit)
	return found


func attackers_near(command_center):
	"""player -> firepower of the enemy fighting units in the city centre's circle"""
	var owner_player = command_center.player
	var center = command_center.global_position_yless
	var firepower = {}
	for unit in get_tree().get_nodes_in_group("units"):
		if (
			unit is Structure
			or unit.attack_damage == null
			or unit.player == owner_player
			or unit.is_queued_for_deletion()
			or not Diplomacy.engages_on_sight(unit.player, owner_player)
		):
			continue
		if unit.global_position_yless.distance_to(center) <= radius():
			firepower[unit.player] = firepower.get(unit.player, 0.0) + _firepower_of(unit)
	return firepower


# the clock


func _process(delta):
	_elapsed_s += delta
	_since_tick_s += delta
	if _since_tick_s >= TICK_S:
		_tick(_since_tick_s)
		_since_tick_s = 0.0
	_draw_rings()
	_update_banner()


func _tick(delta):
	for player in get_tree().get_nodes_in_group("players"):
		if player in defeated:
			continue
		_tick_countdown(player, delta)
	for command_center in get_tree().get_nodes_in_group("units"):
		if (
			command_center is CommandCenter
			and command_center.is_constructed()
			and not command_center.is_queued_for_deletion()
		):
			_tick_surrender(command_center, delta)
	for command_center in surrenders.keys():
		if not is_instance_valid(command_center) or not command_center.is_inside_tree():
			surrenders.erase(command_center)
	for command_center in _last_hit_s.keys():
		if not is_instance_valid(command_center):
			_last_hit_s.erase(command_center)


func _tick_countdown(player, delta):
	var centres = centres_of(player)
	if not centres.is_empty():
		_had_centre[player] = true
		_last_sites[player] = centres.map(func(centre): return centre.global_position_yless)
		if player in countdowns:
			_end_countdown(player)
		return
	if not _had_centre.get(player, false) or not FeatureFlags.handle_match_end:
		return
	if not player in countdowns:
		_start_countdown(player)
	countdowns[player]["left_s"] -= delta
	if countdowns[player]["left_s"] <= 0.0:
		_defeat(player)


func _start_countdown(player):
	var seconds = float(config["rebuild_countdown_s"])
	countdowns[player] = {"left_s": seconds, "sites": _last_sites.get(player, []).duplicate()}
	_refresh_site_labels()
	MatchSignals.city_centre_countdown_started.emit(player, seconds)
	if _is_human(player):
		_alert(tr("CITY_CENTRE_LOST_ALERT").format([_clock(seconds)]))


func _end_countdown(player):
	"""a new city centre stands: keep what is inside a circle, abandon the rest"""
	countdowns.erase(player)
	_refresh_site_labels()
	var kept = 0
	var abandoned = 0
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player != player or not unit is Structure or unit is CommandCenter:
			continue
		if centre_covering(player, unit.global_position) != null:
			kept += 1
			continue
		abandoned += 1
		_remove_unit(unit)
	var city = player.city
	if city != null:
		for building in city._buildings.duplicate():
			if not is_instance_valid(building):
				continue
			if centre_covering(player, building.global_position) == null:
				city._buildings.erase(building)
				building.queue_free()
		city.changed.emit()
	MatchSignals.city_rebuilt.emit(player, kept, abandoned)
	if _is_human(player):
		_alert(tr("CITY_CENTRE_REBUILT_ALERT").format([kept, abandoned]))


func _defeat(player):
	defeated[player] = true
	countdowns.erase(player)
	_refresh_site_labels()
	MatchSignals.player_defeated.emit(player)
	if player.city != null:
		for building in player.city._buildings:
			if is_instance_valid(building):
				building.queue_free()
		player.city._buildings.clear()
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == player:
			_remove_unit(unit)
	if not _is_human(player):
		_alert(tr("CITY_CENTRE_PLAYER_DEFEATED_ALERT").format([_player_name(player)]))


# surrender


func _tick_surrender(command_center, delta):
	var attackers = attackers_near(command_center)
	var defended = not defenders_near(command_center).is_empty()
	if command_center in surrenders:
		if defended or attackers.is_empty():
			_end_surrender(command_center)
			return
		surrenders[command_center]["left_s"] -= delta
		var flag = command_center.get_node_or_null("SurrenderFlag")
		if flag != null:
			flag.seconds_left = surrenders[command_center]["left_s"]
		if surrenders[command_center]["left_s"] <= 0.0:
			_capture(command_center, _strongest(attackers))
		return
	var hit_s = _last_hit_s.get(command_center, -INF)
	if (
		_elapsed_s - hit_s <= float(config["attack_memory_s"])
		and not attackers.is_empty()
		and not defended
	):
		_start_surrender(command_center, attackers)


func _start_surrender(command_center, attackers, seconds = null):
	var left_s = float(config["surrender_countdown_s"]) if seconds == null else seconds
	surrenders[command_center] = {"left_s": left_s}
	command_center.set_meta("surrendering", true)
	if command_center.get_node_or_null("SurrenderFlag") == null:
		var flag = SurrenderFlag.new()
		flag.name = "SurrenderFlag"
		flag.seconds_left = left_s
		command_center.add_child(flag)
	MatchSignals.city_surrender_started.emit(command_center)
	if _is_human(command_center.player):
		_alert(tr("CITY_SURRENDER_OWN_ALERT").format([int(ceil(left_s))]))
	elif attackers.keys().any(_is_human):
		_alert(tr("CITY_SURRENDER_ENEMY_ALERT").format([int(ceil(left_s))]))


func _end_surrender(command_center):
	surrenders.erase(command_center)
	if not is_instance_valid(command_center):
		return
	command_center.remove_meta("surrendering")
	var flag = command_center.get_node_or_null("SurrenderFlag")
	if flag != null:
		flag.queue_free()
	MatchSignals.city_surrender_ended.emit(command_center)
	if _is_human(command_center.player) and command_center.is_inside_tree():
		_alert(tr("CITY_SURRENDER_LIFTED_ALERT"))


func _capture(command_center, new_owner):
	"""the city centre, the buildings and the houses in its circle change hands"""
	surrenders.erase(command_center)
	_last_hit_s.erase(command_center)
	var old_owner = command_center.player
	var center = command_center.global_position_yless
	var players = get_tree().get_nodes_in_group("players")
	var taken = []
	for unit in get_tree().get_nodes_in_group("units"):
		if (
			unit.player == old_owner
			and unit is Structure
			and not unit.is_queued_for_deletion()
			and unit.global_position_yless.distance_to(center) <= radius()
		):
			taken.append(unit)
	var new_centre = null
	for unit in taken:
		var saved = SaveGame._capture_unit(unit, players)
		saved.erase("queue")  # orders of the old owner are not carried over
		var unit_transform = unit.global_transform
		_remove_unit(unit)
		if not ResourceLoader.exists(saved["scene"]):
			continue
		var copy = load(saved["scene"]).instantiate()
		if float(saved.get("progress", 1.0)) >= 1.0:
			copy.set_meta("spawn_constructed", true)
		# through the signal, so everything that follows new units (the end screen too) sees it
		MatchSignals.setup_and_spawn_unit.emit(copy, unit_transform, new_owner)
		SaveGame._restore_unit(copy, saved)
		if unit == command_center:
			new_centre = copy
	_move_houses(old_owner, new_owner, center)
	if new_centre != null:
		MatchSignals.city_captured.emit(new_centre, old_owner, new_owner)
	if _is_human(new_owner):
		_alert(tr("CITY_CAPTURED_BY_YOU_ALERT").format([taken.size()]))
	elif _is_human(old_owner):
		_alert(tr("CITY_CAPTURED_FROM_YOU_ALERT"))


func _move_houses(old_owner, new_owner, center):
	var old_city = old_owner.city
	var new_city = new_owner.city
	if old_city == null or new_city == null:
		return
	var total = old_city._buildings.size()
	var moved = 0
	for building in old_city._buildings.duplicate():
		if not is_instance_valid(building):
			continue
		if (building.global_position * Vector3(1, 0, 1)).distance_to(center) > radius():
			continue
		var copy = CityBuilding.new()
		copy.kind = building.kind
		copy.variant = building.variant
		new_city.add_child(copy)
		copy.global_position = building.global_position
		copy.rotation.y = building.rotation.y
		copy.revealed_once = building.revealed_once
		new_city._buildings.append(copy)
		new_city._update_building_visibility(copy)
		old_city._buildings.erase(building)
		building.queue_free()
		moved += 1
	if moved > 0 and total > 0:
		var citizens = old_city.population * float(moved) / float(total)
		old_city.population -= citizens
		new_city.population += citizens
	old_city.changed.emit()
	new_city.changed.emit()


func _strongest(firepower):
	var best = null
	for player in firepower:
		if best == null or firepower[player] > firepower[best]:
			best = player
	return best


static func _firepower_of(unit):
	if unit.attack_damage == null:
		return 0.0
	var interval = unit.attack_interval if unit.attack_interval != null else 1.0
	return float(max(1, unit.hp)) * float(unit.attack_damage) / max(0.1, float(interval))


func _on_unit_damaged(unit):
	if not is_instance_valid(unit) or not unit is Structure:
		return
	var attacker = unit.last_attacker_player
	if attacker == null or not is_instance_valid(attacker) or attacker == unit.player:
		return
	var centre = centre_covering(unit.player, unit.global_position)
	if centre != null:
		_last_hit_s[centre] = _elapsed_s


func _remove_unit(unit):
	"""takes a unit out of the match without a fight: no loot, no death. It stays in the
	"units" group until it is gone (its own actions look it up there this frame), so counts
	here skip units queued for deletion"""
	unit.remove_from_group("selected_units")
	unit.queue_free()


# what the player sees


func _draw_rings():
	_mesh.clear_surfaces()
	var human = _human()
	var rings = []  # [center, radius, color, dashed]
	if human != null:
		for centre in centres_of(human):
			var color = Color(human.color, OWN_RING_ALPHA)
			if centre.is_in_group("selected_units"):
				color.a = 0.8
			rings.append([centre.global_position_yless, radius(), color, false])
		for site in lost_sites(human):
			rings.append([site, radius(), LOST_SITE_COLOR, true])
		var blueprint = _city_centre_blueprint(human)
		if blueprint != null:
			var position = blueprint[0].global_position * Vector3(1, 0, 1)
			var ok = can_place_more(human) and not too_close_to_own_centre(human, position)
			rings.append(
				[position, radius(), BLUEPRINT_OK_COLOR if ok else BLUEPRINT_BAD_COLOR, false]
			)
	for unit in get_tree().get_nodes_in_group("selected_units"):
		if unit is CommandCenter and unit.player != human and unit.is_constructed():
			rings.append(
				[unit.global_position_yless, radius(), Color(unit.player.color, 0.6), false]
			)
	var pulse = 0.55 + 0.45 * sin(_elapsed_s * 6.0)
	for centre in surrenders:
		if is_instance_valid(centre) and centre.visible:
			rings.append(
				[
					centre.global_position_yless,
					radius(),
					Color(SURRENDER_COLOR, SURRENDER_COLOR.a * pulse),
					false
				]
			)
	if rings.is_empty():
		return
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for ring in rings:
		_add_ring(ring[0], ring[1], ring[2], ring[3])
	_mesh.surface_end()


func _add_ring(center, ring_radius, color, dashed):
	var inner = ring_radius - RING_WIDTH_M * 0.5
	var outer = ring_radius + RING_WIDTH_M * 0.5
	for i in range(RING_SEGMENTS):
		if dashed and i % 2 == 1:
			continue
		var a = TAU * i / RING_SEGMENTS
		var b = TAU * (i + 1) / RING_SEGMENTS
		var da = Vector3(cos(a), 0, sin(a))
		var db = Vector3(cos(b), 0, sin(b))
		var y = Vector3(0, RING_Y, 0)
		var points = [
			center + da * inner + y,
			center + da * outer + y,
			center + db * outer + y,
			center + da * inner + y,
			center + db * outer + y,
			center + db * inner + y,
		]
		for point in points:
			_mesh.surface_set_color(color)
			_mesh.surface_add_vertex(point)


func _city_centre_blueprint(player):
	"""[blueprint node] while the human places a city centre, else null"""
	var handler = player.get_node_or_null("StructurePlacementHandler")
	if handler == null or handler.get("_active_blueprint_node") == null:
		return null
	var prototype = handler.get("_pending_structure_prototype")
	if prototype == null or not prototype.resource_path.ends_with("CommandCenter.tscn"):
		return null
	return [handler.get("_active_blueprint_node")]


func _refresh_site_labels():
	for label in _site_labels:
		if is_instance_valid(label):
			label.queue_free()
	_site_labels = []
	var human = _human()
	if human == null:
		return
	for site in lost_sites(human):
		var label = Label3D.new()
		label.text = tr("CITY_CENTRE_LOST_SITE")
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.fixed_size = true
		label.pixel_size = 0.0012
		label.font_size = 32
		label.outline_size = 8
		label.modulate = LOST_SITE_COLOR
		label.outline_modulate = Color(0, 0, 0, 0.85)
		label.render_priority = 10
		add_child(label)
		label.global_position = site + Vector3(0, 1.5, 0)
		_site_labels.append(label)


func _update_banner():
	var human = _human()
	var lines = []
	if human != null and human in countdowns:
		lines.append(tr("CITY_CENTRE_COUNTDOWN").format([_clock(countdowns[human]["left_s"])]))
	if human != null:
		for centre in surrenders:
			if is_instance_valid(centre) and centre.player == human:
				lines.append(
					tr("CITY_SURRENDER_COUNTDOWN").format([int(ceil(surrenders[centre]["left_s"]))])
				)
				break
	_banner.visible = not lines.is_empty()
	if not _banner.visible:
		return
	_banner.text = "\n".join(lines)
	_banner.reset_size()
	var screen = get_viewport().get_visible_rect().size
	_banner.position = Vector2(round((screen.x - _banner.size.x) / 2.0), 88)


func _alert(text):
	var guide = _match.find_child("Guide", true, false) if _match != null else null
	if guide != null:
		guide.show_alert(text)


func _human():
	for player in get_tree().get_nodes_in_group("players"):
		if player is Human:
			return player
	return null


func _is_human(player):
	return player != null and is_instance_valid(player) and player is Human


func _player_name(player):
	var hud = _match.find_child("DiplomacyHud", true, false) if _match != null else null
	if hud != null and hud.has_method("faction_name"):
		return hud.faction_name(player)
	return "#{0}".format([player.get_index() + 1])


static func _clock(seconds):
	var whole = int(ceil(max(0.0, seconds)))
	return "%d:%02d" % [whole / 60, whole % 60]


# saving


func capture(players, unit_ids):
	var out = {"countdowns": [], "surrenders": [], "defeated": [], "had_centre": []}
	for player in countdowns:
		(
			out["countdowns"]
			. append(
				{
					"player": players.find(player),
					"left_s": countdowns[player]["left_s"],
					"sites": countdowns[player]["sites"].map(SaveGame._vec3),
				}
			)
		)
	for centre in surrenders:
		if centre in unit_ids:
			out["surrenders"].append(
				{"unit": unit_ids[centre], "left_s": surrenders[centre]["left_s"]}
			)
	for player in defeated:
		out["defeated"].append(players.find(player))
	for player in _had_centre:
		out["had_centre"].append(players.find(player))
	return out


func restore(saved, players, spawned):
	for index in saved.get("had_centre", []):
		if int(index) >= 0 and int(index) < players.size():
			_had_centre[players[int(index)]] = true
	for index in saved.get("defeated", []):
		if int(index) >= 0 and int(index) < players.size():
			defeated[players[int(index)]] = true
	for entry in saved.get("countdowns", []):
		var index = int(entry["player"])
		if index < 0 or index >= players.size():
			continue
		var player = players[index]
		_had_centre[player] = true
		countdowns[player] = {
			"left_s": float(entry["left_s"]),
			"sites": entry.get("sites", []).map(SaveGame._to_vec3),
		}
	_refresh_site_labels()
	for entry in saved.get("surrenders", []):
		var index = int(entry["unit"])
		var centre = spawned[index] if index >= 0 and index < spawned.size() else null
		if centre != null and is_instance_valid(centre):
			_start_surrender(centre, {}, float(entry["left_s"]))
