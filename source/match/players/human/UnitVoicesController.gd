extends Node

# Replies of the player's own units. Every unit type answers with its voice set from
# data/sounds/voices.json: infantry, tank crews, officers, pilots, builders and traders
# speak, unmanned units (drones, automated buggies) and buildings answer with machine
# sounds. Lines are picked by VoiceBank so the same line is not repeated back to back.
#
# Selection and orders cut off the line that is playing (the player wants to hear the
# reply to the click they just made); reports (under attack, unit ready) wait their turn.

enum Priority { REPORT, REPLY }

const Structure = preload("res://source/match/units/Structure.gd")
const ResourceUnit = preload("res://source/match/units/non-player/ResourceUnit.gd")
const VoiceBank = preload("res://source/match/audio/VoiceBank.gd")

const REPEAT_CLICKS = 3  # selecting the same unit this often in a row gets a cheeky line
const REPEAT_WINDOW_MS = 2500
const RETREAT_HP_RATIO = 0.4  # a move order to hurt or just-hit units is a retreat
const RECENT_DAMAGE_MS = 4000
const UNDER_ATTACK_COOLDOWN_MS = 7000  # between any two "taking fire" lines
const UNDER_ATTACK_PER_UNIT_MS = 20000

var bank = VoiceBank.new()
var last_line = {}  # {"set", "action"} of the line played last, for tests

var _pending_selection = []
var _repeat_unit_id = 0
var _repeat_clicks = 0
var _repeat_last_ms = 0
var _damage_ms = {}  # unit instance id -> time it was last hit
var _under_attack_ms = -UNDER_ATTACK_COOLDOWN_MS
var _under_attack_unit_ms = {}
var _playing_priority = Priority.REPORT

@onready var _audio_player = find_child("AudioStreamPlayer")
@onready var _player = get_parent()


func _ready() -> void:
	MatchSignals.unit_selected.connect(_on_unit_selected)
	MatchSignals.units_ordered.connect(_on_units_ordered)
	MatchSignals.unit_damaged.connect(_on_unit_damaged)
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)


func say(set_id, action, priority = Priority.REPLY):
	"""plays the next line of a set's action; false when it has none or must wait"""
	if _audio_player.playing and priority < _playing_priority:
		return false
	var stream = bank.pick(set_id, action)
	if stream == null:
		return false
	_audio_player.stream = stream
	_audio_player.play()
	_playing_priority = priority
	last_line = {"set": set_id, "action": action}
	return true


func _is_own(unit):
	return (
		is_instance_valid(unit)
		and not unit is ResourceUnit
		and "player" in unit
		and unit.player == _player
	)


func _lead_set(units):
	"""the voice set most of the units share; the first unit's set on a tie"""
	var counts = {}
	var first = null
	for unit in units:
		var set_id = VoiceBank.set_id_for_unit(unit)
		if set_id == null:
			continue
		if first == null:
			first = set_id
		counts[set_id] = counts.get(set_id, 0) + 1
	var best = first
	for set_id in counts:
		if counts[set_id] > counts.get(best, 0):
			best = set_id
	return best


func _on_unit_selected(unit):
	if not _is_own(unit):
		return
	if _pending_selection.is_empty():
		_flush_selection.call_deferred()  # a box selection selects many units in one frame
	_pending_selection.append(unit)


func _flush_selection():
	var units = _pending_selection.filter(func(unit): return is_instance_valid(unit))
	_pending_selection = []
	var mobile = units.filter(func(unit): return not unit is Structure)
	var voiced = mobile if not mobile.is_empty() else units
	if voiced.is_empty():
		return
	var set_id = _lead_set(voiced)
	if set_id == null:
		return
	var action = "select"
	if voiced.size() == 1 and _counts_as_repeat_click(voiced[0]):
		if bank.has_lines(set_id, "select_repeat"):
			action = "select_repeat"
	say(set_id, action)


func _counts_as_repeat_click(unit):
	var now = Time.get_ticks_msec()
	if unit.get_instance_id() == _repeat_unit_id and now - _repeat_last_ms < REPEAT_WINDOW_MS:
		_repeat_clicks += 1
	else:
		_repeat_unit_id = unit.get_instance_id()
		_repeat_clicks = 1
	_repeat_last_ms = now
	if _repeat_clicks >= REPEAT_CLICKS:
		_repeat_clicks = 0
		return true
	return false


func _on_units_ordered(units, order):
	var own = units.filter(_is_own)
	if own.is_empty():
		return
	var set_id = _lead_set(own)
	if set_id == null:
		return
	if order == "move" and own.any(_is_hurt):
		order = "retreat"
	say(set_id, order)


func _is_hurt(unit):
	if unit is Structure:
		return false
	if Time.get_ticks_msec() - _damage_ms.get(unit.get_instance_id(), -INF) < RECENT_DAMAGE_MS:
		return true
	if "hp" in unit and "hp_max" in unit and unit.hp != null and unit.hp_max:
		return float(unit.hp) / unit.hp_max < RETREAT_HP_RATIO
	return false


func _on_unit_damaged(unit):
	if not _is_own(unit) or unit is Structure:
		return  # the advisor reports attacks on the base
	var now = Time.get_ticks_msec()
	var id = unit.get_instance_id()
	_damage_ms[id] = now
	if (
		now - _under_attack_ms < UNDER_ATTACK_COOLDOWN_MS
		or now - _under_attack_unit_ms.get(id, -INF) < UNDER_ATTACK_PER_UNIT_MS
	):
		return
	var set_id = VoiceBank.set_id_for_unit(unit)
	if set_id != null and say(set_id, "under_attack", Priority.REPORT):
		_under_attack_ms = now
		_under_attack_unit_ms[id] = now


func _on_unit_production_finished(unit, producer_unit):
	if not _is_own(producer_unit) or not is_instance_valid(unit):
		return
	var set_id = VoiceBank.set_id_for_unit(unit)
	if set_id != null:
		say(set_id, "ready", Priority.REPORT)
