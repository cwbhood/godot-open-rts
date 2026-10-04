extends Node

# The advisor: spoken announcements about the base and the match (under attack,
# construction complete, research complete, low oil, storage full, trade, war, helper
# alerts). Lines come from the "advisor" voice set in data/sounds/ and are picked by
# VoiceBank, so repeated events vary their wording. An announcement that arrives while
# another one plays waits in a short queue instead of cutting it off.

const GameData = preload("res://source/data-model/GameData.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const Helper = preload("res://source/match/players/human/Helper.gd")
const VoiceBank = preload("res://source/match/audio/VoiceBank.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")

const FINAL_EVENTS = ["victory", "defeat"]  # nothing cuts these off
const QUEUE_SIZE = 3
const QUEUE_MAX_AGE_MS = 5000  # stale news is dropped
const BASE_UNDER_ATTACK_QUIET_MS = 10 * 1000  # repeat only after the base was quiet this long
const COOLDOWN_MS = {
	"unit_lost": 4000,
	"training": 3000,
	"not_enough_resources": 2500,
	"cannot_place": 2000,
	"construction_complete": 1500,
	"low_oil": 60000,
	"storage_full": 90000,
	"convoy_lost": 15000,
	"helper_alert": 8000,
}
const LOW_OIL = 5  # announce when the oil stock drops below this...
const OIL_RECOVERED = 12  # ...and again only after it climbed back above this
const POLL_S = 2.0
const HELPER_ALERTS = {
	"on": "helper_on",
	"off": "helper_off",
	"retreat": "constructor_pulled_back",
	"detour": "constructor_rerouted",
	"hold": "constructor_held",
	"blocked": "constructor_held",
}

var bank = VoiceBank.new()
var last_event = null  # the event announced last, for tests

var _set_id = "advisor"
var _queue = []  # [[event, time ms]]
var _last_ms = {}  # event -> time it was last announced
var _last_base_damage_ms = -BASE_UNDER_ATTACK_QUIET_MS
var _oil_low = false

@onready var _audio_player = find_child("AudioStreamPlayer")
@onready var _player = get_parent()


func _ready():
	_set_id = GameData.voices().get("advisor", "advisor")
	_audio_player.finished.connect(_play_next)
	MatchSignals.match_started.connect(announce.bind("match_started"))
	MatchSignals.match_aborted.connect(announce.bind("match_aborted"))
	MatchSignals.match_finished_with_victory.connect(announce.bind("victory"))
	MatchSignals.match_finished_with_defeat.connect(announce.bind("defeat"))
	MatchSignals.unit_damaged.connect(_on_unit_damaged)
	MatchSignals.unit_died.connect(_on_unit_died)
	MatchSignals.unit_production_started.connect(_on_production_started)
	MatchSignals.not_enough_resources_for_production.connect(_on_not_enough_resources)
	MatchSignals.not_enough_resources_for_construction.connect(_on_not_enough_resources)
	MatchSignals.structure_placement_refused.connect(_if_mine.bind("cannot_place"))
	MatchSignals.unit_construction_finished.connect(_on_construction_finished)
	MatchSignals.tier_reached.connect(_on_tier_reached)
	MatchSignals.trade_completed.connect(_on_trade_completed)
	MatchSignals.cargo_destroyed.connect(_on_cargo_destroyed)
	MatchSignals.diplomacy_changed.connect(_on_diplomacy_changed)
	MatchSignals.treaty_signed.connect(_on_treaty_signed)
	_connect_helper.call_deferred()  # Human adds its helper after its children are ready
	var timer = Timer.new()
	timer.timeout.connect(_poll)
	add_child(timer)
	timer.start(POLL_S)


func announce(event):
	"""says an advisor line for the event now, or after the one that is playing"""
	var now = Time.get_ticks_msec()
	if now - _last_ms.get(event, -INF) < COOLDOWN_MS.get(event, 0):
		return
	_last_ms[event] = now
	if not bank.has_lines(_set_id, event):
		return
	if event in FINAL_EVENTS:
		_queue.clear()
		_play(event)
		return
	if _audio_player.playing:
		if last_event in FINAL_EVENTS:
			return
		_queue = _queue.filter(func(entry): return entry[0] != event)
		_queue.append([event, now])
		if _queue.size() > QUEUE_SIZE:
			_queue.pop_front()
		return
	_play(event)


func _play(event):
	var stream = bank.pick(_set_id, event)
	if stream == null:
		return
	last_event = event
	_audio_player.stream = stream
	_audio_player.play()


func _play_next():
	var now = Time.get_ticks_msec()
	while not _queue.is_empty():
		var entry = _queue.pop_front()
		if now - entry[1] <= QUEUE_MAX_AGE_MS:
			_play(entry[0])
			return


func _if_mine(player, event):
	if player == _player:
		announce(event)


func _involves_me(a, b):
	return a == _player or b == _player


func _on_unit_damaged(unit):
	if unit.player != _player or not unit is Structure:
		return  # units under attack speak for themselves (UnitVoicesController)
	var now = Time.get_ticks_msec()
	if now - _last_base_damage_ms > BASE_UNDER_ATTACK_QUIET_MS:
		announce("base_under_attack")
	_last_base_damage_ms = now


func _on_unit_died(unit):
	if unit.is_in_group("controlled_units") and not unit is Structure:
		announce("unit_lost")


func _on_production_started(_unit_prototype, producer_unit):
	if producer_unit.player == _player:
		announce("training")


func _on_construction_finished(unit):
	if unit.player == _player:
		announce("construction_complete")


func _on_not_enough_resources(player):
	_if_mine(player, "not_enough_resources")


func _on_tier_reached(player, tier):
	if player != _player:
		return
	var tiers = GameData.tiers()
	var event = "research_complete"
	if tier >= 1 and tier <= tiers.size():
		var named = "tier_" + tiers[tier - 1]["name"].to_lower().trim_prefix("tier_")
		if bank.has_lines(_set_id, named):
			event = named
	announce(event)


func _on_trade_completed(proposer, partner, _offered, _requested):
	if _involves_me(proposer, partner):
		announce("trade_complete")


func _on_cargo_destroyed(_unit, owner, _cargo, _looter, _loot):
	if owner == _player:
		announce("convoy_lost")


func _on_diplomacy_changed(a, b, state):
	if _involves_me(a, b) and state == Diplomacy.State.WAR:
		announce("war_declared")


func _on_treaty_signed(proposer, partner, _kind, _offered, _requested):
	if _involves_me(proposer, partner):
		announce("treaty_signed")


func _connect_helper():
	var helper = Helper.of(_player) if is_instance_valid(_player) else null
	if helper != null and helper.has_signal("alert_raised"):
		helper.alert_raised.connect(_on_helper_alert)


func _on_helper_alert(kind):
	announce(HELPER_ALERTS.get(kind, "helper_alert"))


func _poll():
	if not is_instance_valid(_player) or not "oil" in GameData.resource_ids():
		return
	var oil = _player.get("oil")
	if oil != null:
		if not _oil_low and oil < LOW_OIL:
			_oil_low = true
			announce("low_oil")
		elif _oil_low and oil > OIL_RECOVERED:
			_oil_low = false
	for extractor in get_tree().get_nodes_in_group("controlled_units"):
		if (
			extractor is Extractor
			and extractor.player == _player
			and not extractor.is_depleted()
			and extractor.stored >= Constants.Match.Extraction.STORAGE_MAX
		):
			announce("storage_full")
			return
