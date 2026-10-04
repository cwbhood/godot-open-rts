extends Node

# Decides when the AI offers treaties. It sues for peace when a war goes badly (paying
# tribute if it is much weaker, asking for goods if it is the stronger side), peaceful
# personalities offer pacts to stronger neighbours, and those that accept alliances look
# for an ally when they share an enemy. Offers to other AIs are answered on the spot, a
# human gets them in the diplomacy panel.

const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const Trade = preload("res://source/match/city/Trade.gd")

const LOSING_THREAT = 1.3  # sue for peace once the enemy is this much stronger
const PEACEFUL = 1.2  # personalities at least this peaceful look for treaties on their own
const MIN_WAR_S = 60.0  # wars last at least this long before peaceful AIs give up

var offers_made = 0  # statistics

var _player = null
var _last_offer_s = {}  # partner instance id -> time of last offer
var _elapsed_s = 0.0

@onready var _ai = get_parent()


func setup(player):
	_player = player
	var timer = Timer.new()
	var interval = Constants.Match.Diplomacy.AI_DECISION_INTERVAL_S
	timer.timeout.connect(_tick.bind(interval))
	add_child(timer)
	timer.start(interval * randf_range(0.8, 1.2))


func _tick(delta):
	_elapsed_s += delta
	var diplomacy = Diplomacy.instance
	if diplomacy == null:
		return
	var others = get_tree().get_nodes_in_group("players").filter(
		func(player): return player != _player
	)
	others.shuffle()
	for other in others:
		var since_offer = _elapsed_s - _last_offer_s.get(other.get_instance_id(), -INF)
		if since_offer < Constants.Match.Diplomacy.AI_OFFER_COOLDOWN_S:
			continue
		var kind = _treaty_wanted_with(diplomacy, other)
		if kind != null and _offer(diplomacy, other, kind):
			return  # one offer per round


func _treaty_wanted_with(diplomacy, other):
	var state = diplomacy.get_state(_player, other)
	var threat = Diplomacy.threat_ratio(_player, other)
	if state == Diplomacy.State.WAR:
		var tired = (
			_ai.peacefulness >= PEACEFUL and diplomacy.seconds_in_state(_player, other) > MIN_WAR_S
		)
		return Diplomacy.PACT if threat >= LOSING_THREAT or tired else null
	var can_ally = (
		diplomacy.can_sign(_player, other, Diplomacy.ALLIANCE) == Diplomacy.Result.ACCEPTED
	)
	if not _ai.accepts_alliances or not can_ally:
		if state == Diplomacy.State.NEUTRAL and _ai.peacefulness >= PEACEFUL and threat > 1.0:
			return Diplomacy.PACT
		return null
	if _shares_enemy_with(other) or (_ai.peacefulness >= PEACEFUL and randf() < 0.3):
		return Diplomacy.ALLIANCE
	return null


func _shares_enemy_with(other):
	for third in get_tree().get_nodes_in_group("players"):
		if third != _player and third != other:
			if Diplomacy.at_war(_player, third) and Diplomacy.at_war(other, third):
				return true
	return false


func _offer(diplomacy, other, kind):
	var price = Diplomacy.ai_asking_price(_player, other, kind)
	if price == null:
		return false
	var offered = price["offered"]
	var requested = price["requested"]
	for resource in requested:
		# never ask for more than they have
		requested[resource] = min(requested[resource], int(other.get(resource)))
	if diplomacy.validate(_player, other, kind, offered, requested) != Diplomacy.Result.ACCEPTED:
		return false
	_last_offer_s[other.get_instance_id()] = _elapsed_s
	offers_made += 1
	if Diplomacy.is_ai(other):
		diplomacy.propose(_player, other, kind, offered, requested)
	else:
		MatchSignals.diplomacy_offered.emit(_player, other, kind, offered, requested)
	return true
