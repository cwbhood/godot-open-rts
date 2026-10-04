extends Node

# The caps that keep a match from running forever (settings in data/caps.json; a map entry
# in data/maps/ may override single keys with a "caps" object):
# - unit slots: every unit takes slots ("unit_slots" in data/units/, light units 1, heavy
#   ones up to 5). A player can field at most "unit_slots_per_player", and all players
#   together at most "unit_slots_per_match", split evenly between the players the match
#   started with, so a 4-player match lowers everyone's cap a bit. Units in production
#   count as soon as they are queued. Production of anyone (player, AI, helper) stops at
#   the cap until units are lost.
# - city population: each city tier has a "max_population" in data/tiers.json, see City.
# - match length: the match ends after "time_limit_min", or "depletion_countdown_min"
#   after the last resource deposit on the map ran dry, whichever comes first. The player
#   with the best score wins; equal best scores are a draw. Score: citizens, unit slots
#   in use, structures and science, weighted by "score" in data/caps.json.
# Sandbox matches (no match end) have no time limit.

enum EndReason { NONE, TIME, DEPLETION }

const GameData = preload("res://source/data-model/GameData.gd")
const Structure = preload("res://source/match/units/Structure.gd")

const TICK_S = 1.0
const CACHE_S = 0.25  # HUD and menu reads; production checks always count afresh

var config = {}
var elapsed_s = 0.0
var ended = false
var end_reason = EndReason.NONE
var depleted_at_s = -1.0  # match time when the last deposit ran dry

var _slots = {}  # unit scene path -> unit slots
var _starting_players = 1
var _had_deposits = false
var _since_tick_s = 0.0
var _cache = {}  # player instance id -> [time, slots used]


static func of(tree):
	"""the limits of the running match or null (e.g. in a test scene without a Match)"""
	var matches = tree.get_nodes_in_group("match")
	if matches.is_empty():
		return null
	return matches[0].get_node_or_null("MatchLimits")


func _ready():
	var a_match = get_parent()
	var map = a_match.get("map")
	config = GameData.caps(map.scene_file_path if map != null else null)
	_slots = GameData.unit_field("unit_slots", "unit", int(config.get("default_unit_slots", 1)))
	MatchSignals.match_started.connect(_on_match_started, CONNECT_ONE_SHOT)


func _on_match_started():
	_starting_players = max(1, get_tree().get_nodes_in_group("players").size())
	_had_deposits = not get_tree().get_nodes_in_group("deposits").is_empty()


func _process(delta):
	if ended:
		return
	elapsed_s += delta
	_since_tick_s += delta
	if _since_tick_s < TICK_S:
		return
	_since_tick_s = 0.0
	if _had_deposits and depleted_at_s < 0.0:
		if get_tree().get_nodes_in_group("deposits").is_empty():
			depleted_at_s = elapsed_s
			MatchSignals.resources_depleted.emit()
	if not FeatureFlags.handle_match_end:
		return
	if time_left_s() <= 0.0:
		end_match(
			EndReason.DEPLETION if _depletion_deadline_s() <= _time_deadline_s() else EndReason.TIME
		)


# unit slots


func slots_of(scene_path):
	return int(_slots.get(scene_path, 0))


func slots_cap():
	var per_player = int(config.get("unit_slots_per_player", 0))
	var per_match = int(config.get("unit_slots_per_match", 0))
	var cap = per_player if per_player > 0 else 1 << 30
	if per_match > 0:
		cap = min(cap, per_match / _starting_players)
	return cap


func slots_used(player, fresh = true):
	"""slots of the player's live units plus units waiting in its production queues"""
	var key = player.get_instance_id()
	var now = Time.get_ticks_msec() / 1000.0
	if not fresh and key in _cache and now - _cache[key][0] < CACHE_S:
		return _cache[key][1]
	var used = 0
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player != player:
			continue
		if unit is Structure:
			var queue = unit.production_queue
			if queue != null:
				for element in queue.get_elements():
					used += slots_of(element.unit_prototype.resource_path)
		else:
			used += slots_of(unit._scene_path())
	_cache[key] = [now, used]
	return used


func has_room_for(player, scene_path):
	var needed = slots_of(scene_path)
	return needed <= 0 or slots_used(player) + needed <= slots_cap()


# match length


func time_left_s():
	return min(_time_deadline_s(), _depletion_deadline_s()) - elapsed_s


func ends_by_depletion():
	return _depletion_deadline_s() < _time_deadline_s()


func has_time_limit():
	return FeatureFlags.handle_match_end and time_left_s() < INF


func _time_deadline_s():
	var minutes = float(config.get("time_limit_min", 0))
	return minutes * 60.0 if minutes > 0.0 else INF


func _depletion_deadline_s():
	if depleted_at_s < 0.0:
		return INF
	return depleted_at_s + float(config.get("depletion_countdown_min", 0)) * 60.0


func score_of(player):
	var weights = config.get("score", {})
	var city = player.city
	var structures = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player and unit is Structure and unit.is_constructed()
	)
	var parts = {
		"citizens": city.population * float(weights.get("per_citizen", 1)) if city else 0.0,
		"army": slots_used(player, false) * float(weights.get("per_unit_slot", 1)),
		"structures": structures.size() * float(weights.get("per_structure", 5)),
		"science": city.science * float(weights.get("per_science", 0.1)) if city else 0.0,
	}
	var total = 0
	for part in parts:
		parts[part] = int(round(parts[part]))
		total += parts[part]
	parts["total"] = total
	return parts


func ranking():
	"""[{player, score}] of every player still in the match, best first"""
	var alive = {}
	for unit in get_tree().get_nodes_in_group("units"):
		alive[unit.player] = true
	var rows = []
	for player in get_tree().get_nodes_in_group("players"):
		if player in alive:
			rows.append({"player": player, "score": score_of(player)})
	rows.sort_custom(func(a, b): return a["score"]["total"] > b["score"]["total"])
	return rows


func end_match(reason):
	if ended:
		return
	ended = true
	end_reason = reason
	MatchSignals.match_limit_reached.emit(reason, ranking())
