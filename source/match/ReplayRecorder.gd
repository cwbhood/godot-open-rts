extends Node

# Records a match for the replay viewer (main menu > Replays): a snapshot of every unit
# and every faction's economy each SNAPSHOT_INTERVAL_S, plus economy and combat events
# as they happen. Saved compressed to user://replays/ when the match ends or is left.

const GameData = preload("res://source/data-model/GameData.gd")

const REPLAYS_DIR = "user://replays"
const FORMAT_VERSION = 1
const SNAPSHOT_INTERVAL_S = 1.0
const MAX_REPLAYS_KEPT = 20

var _elapsed_s = 0.0
var _since_snapshot_s = 0.0
var _snapshots = []
var _events = []
var _unit_ids = {}  # unit -> short id
var _next_unit_id = 1
var _saved = false

@onready var _match = get_parent()


func _ready():
	MatchSignals.goods_delivered.connect(
		func(player, goods): _event("delivered", {"player": _index(player), "goods": goods})
	)
	MatchSignals.cargo_destroyed.connect(_on_cargo_destroyed)
	MatchSignals.tier_reached.connect(
		func(player, tier): _event("tier", {"player": _index(player), "tier": tier})
	)
	MatchSignals.trade_completed.connect(_on_trade_completed)
	MatchSignals.embargo_changed.connect(
		func(imposer, target, active):
			_event(
				"embargo", {"player": _index(imposer), "target": _index(target), "active": active}
			)
	)
	MatchSignals.city_threat_changed.connect(
		func(player, level, _position): _event("threat", {"player": _index(player), "level": level})
	)
	MatchSignals.road_upgraded.connect(
		func(player, _extractor, level): _event("road", {"player": _index(player), "level": level})
	)
	MatchSignals.unit_died.connect(
		func(unit): _event("died", {"unit": _unit_ids.get(unit, 0), "player": _index(unit.player)})
	)
	MatchSignals.match_finished_with_victory.connect(save)
	MatchSignals.match_finished_with_defeat.connect(save)


func _physics_process(delta):
	if not _match.is_node_ready():
		return
	_elapsed_s += delta
	_since_snapshot_s += delta
	if _since_snapshot_s >= SNAPSHOT_INTERVAL_S:
		_since_snapshot_s = 0.0
		_snapshot()


func _exit_tree():
	save()


func save():
	if _saved or _snapshots.is_empty():
		return
	_saved = true
	DirAccess.make_dir_recursive_absolute(REPLAYS_DIR)
	var map_path = _match.map.scene_file_path
	var replay = {
		"version": FORMAT_VERSION,
		"date": Time.get_datetime_string_from_system(),
		"map": map_path,
		"map_name": GameData.maps().get(map_path, {}).get("name", map_path.get_file()),
		"map_size": [_match.map.size.x, _match.map.size.y],
		"duration_s": _elapsed_s,
		"players": _players_info(),
		"deposits": _deposits(),
		"snapshots": _snapshots,
		"events": _events,
	}
	var file_name = (
		"%s_%s.replay"
		% [
			Time.get_datetime_string_from_system().replace(":", "-"),
			map_path.get_file().get_basename()
		]
	)
	var file = FileAccess.open_compressed(
		REPLAYS_DIR + "/" + file_name, FileAccess.WRITE, FileAccess.COMPRESSION_GZIP
	)
	if file == null:
		push_warning("ReplayRecorder: cannot write the replay")
		return
	file.store_string(JSON.stringify(replay))
	file.close()
	_prune_old_replays()


static func list_replays():
	"""file paths of saved replays, newest first"""
	var dir = DirAccess.open(REPLAYS_DIR)
	if dir == null:
		return []
	var files = Array(dir.get_files()).filter(func(file): return file.ends_with(".replay"))
	files.sort()
	files.reverse()
	return files.map(func(file): return REPLAYS_DIR + "/" + file)


static func load_replay(path):
	var file = FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_GZIP)
	if file == null:
		return null
	var replay = JSON.parse_string(file.get_as_text())
	file.close()
	return replay if replay is Dictionary else null


func _snapshot():
	var units = []
	for unit in get_tree().get_nodes_in_group("units"):
		if not unit in _unit_ids:
			_unit_ids[unit] = _next_unit_id
			_next_unit_id += 1
		var entry = GameData.unit_by_scene(unit._scene_path())
		(
			units
			. append(
				[
					_unit_ids[unit],
					_index(unit.player),
					entry["id"] if entry != null else "",
					snapped(unit.global_position.x, 0.1),
					snapped(unit.global_position.z, 0.1),
					snapped(float(unit.hp) / float(unit.hp_max), 0.01) if unit.hp_max else 1.0,
					int(not unit.cargo.is_empty()) if "cargo" in unit else 0,
				]
			)
		)
	var economy = []
	for player in _players():
		var city = player.city
		var logistics = player.logistics
		(
			economy
			. append(
				{
					"stock": player.get_stock(),
					"population": snapped(city.population, 0.1) if city != null else 0,
					"science": snapped(city.science, 0.1) if city != null else 0,
					"tier": city.tier if city != null else 1,
					"delivered":
					Utils.Dict.sum(logistics.delivered_total) if logistics != null else 0,
					"lost": Utils.Dict.sum(logistics.lost_total) if logistics != null else 0,
					"power":
					(
						[
							snapped(player.power_grid.total_supply_mw, 0.1),
							snapped(player.power_grid.total_demand_mw, 0.1)
						]
						if player.power_grid != null
						else [0, 0]
					),
				}
			)
		)
	_snapshots.append({"t": snapped(_elapsed_s, 0.1), "units": units, "economy": economy})


func _event(kind, data):
	if _saved:
		return
	data["t"] = snapped(_elapsed_s, 0.1)
	data["kind"] = kind
	_events.append(data)


func _on_cargo_destroyed(unit, owner, cargo, looter, loot):
	_event(
		"raid",
		{
			"player": _index(owner),
			"looter": _index(looter),
			"cargo": cargo,
			"loot": loot,
			"x": snapped(unit.global_position.x, 0.1) if is_instance_valid(unit) else 0,
			"z": snapped(unit.global_position.z, 0.1) if is_instance_valid(unit) else 0,
		}
	)


func _on_trade_completed(proposer, partner, offered, requested):
	_event(
		"trade",
		{
			"player": _index(proposer),
			"partner": _index(partner),
			"offered": offered,
			"requested": requested,
		}
	)


func _players():
	if not is_inside_tree():
		return []  # signals may still arrive while the match is being torn down
	return get_tree().get_nodes_in_group("players")


func _index(player):
	if player == null or not is_instance_valid(player):
		return -1
	return _players().find(player)


func _players_info():
	return _players().map(
		func(player):
			return {
				"color": player.color.to_html(false),
				"personality": player.get("personality_id"),
				"human": player.get_script().resource_path.contains("human"),
			}
	)


func _deposits():
	return get_tree().get_nodes_in_group("deposits").map(
		func(deposit):
			return [
				deposit.kind,
				snapped(deposit.global_position.x, 0.1),
				snapped(deposit.global_position.z, 0.1),
			]
	)


func _prune_old_replays():
	var replays = list_replays()
	for index in range(MAX_REPLAYS_KEPT, replays.size()):
		DirAccess.remove_absolute(replays[index])
