extends Node

# Collects per-player numbers during a match for the end screen: a score sample every
# SAMPLE_EVERY_S seconds of match time, plus counters for units built and lost, buildings
# finished, goods delivered, trades and the highest city tier.

const MatchLimits = preload("res://source/match/MatchLimits.gd")
const Structure = preload("res://source/match/units/Structure.gd")

const SAMPLE_EVERY_S = 15.0

var elapsed_s = 0.0
var samples = []  # [{t: seconds, scores: {player instance id: total}}]
var counters = {}  # player instance id -> {built, lost, structures, delivered, trades, tier}

var _owners = {}  # unit instance id -> player, units have left the tree when unit_died fires
var _since_sample_s = 0.0


func _ready():
	process_mode = Node.PROCESS_MODE_PAUSABLE
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	MatchSignals.setup_and_spawn_unit.connect(
		func(unit, _t, player): _owners[unit.get_instance_id()] = player
	)
	MatchSignals.unit_died.connect(_on_unit_died)
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)
	MatchSignals.unit_construction_finished.connect(_on_unit_construction_finished)
	MatchSignals.goods_delivered.connect(_on_goods_delivered)
	MatchSignals.trade_completed.connect(_on_trade_completed)
	MatchSignals.tier_reached.connect(_on_tier_reached)
	MatchSignals.match_started.connect(_sample, CONNECT_ONE_SHOT)


func _process(delta):
	elapsed_s += delta
	_since_sample_s += delta
	if _since_sample_s >= SAMPLE_EVERY_S:
		_since_sample_s = 0.0
		_sample()


func finish():
	"""takes a last sample, call when the match ends"""
	_sample()


func counters_of(player):
	var key = player.get_instance_id()
	if not key in counters:
		counters[key] = {
			"built": 0, "lost": 0, "structures": 0, "delivered": 0, "trades": 0, "tier": 1
		}
	return counters[key]


func score_of(player):
	var limits = MatchLimits.of(get_tree())
	if limits == null:
		return 0
	return limits.score_of(player)["total"]


func _sample():
	var scores = {}
	for player in get_tree().get_nodes_in_group("players"):
		scores[player.get_instance_id()] = score_of(player)
	samples.append({"t": elapsed_s, "scores": scores})


func _on_unit_spawned(unit):
	if "player" in unit and unit.player != null:
		_owners[unit.get_instance_id()] = unit.player


func _on_unit_died(unit):
	var owner = _owners.get(unit.get_instance_id())
	if owner == null and "player" in unit:
		owner = unit.player
	if owner != null and is_instance_valid(owner):
		counters_of(owner)["lost"] += 1


func _on_unit_production_finished(unit, _producer):
	if unit.player != null:
		_owners[unit.get_instance_id()] = unit.player
		counters_of(unit.player)["built"] += 1


func _on_unit_construction_finished(unit):
	if unit.player != null and unit is Structure:
		counters_of(unit.player)["structures"] += 1


func _on_goods_delivered(player, goods):
	var total = 0.0
	if goods is Dictionary:
		for kind in goods:
			total += float(goods[kind])
	counters_of(player)["delivered"] += total


func _on_trade_completed(proposer, partner, _offered, _requested):
	counters_of(proposer)["trades"] += 1
	counters_of(partner)["trades"] += 1


func _on_tier_reached(player, tier):
	var row = counters_of(player)
	row["tier"] = max(row["tier"], int(tier))
