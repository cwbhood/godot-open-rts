extends Node

# Decides when the AI offers treaties. It sues for peace when a war goes badly (paying
# tribute if it is much weaker, asking for goods if it is the stronger side), peaceful
# personalities offer pacts to stronger neighbours, and those that accept alliances look
# for an ally when they share an enemy. Offers to other AIs are answered on the spot, a
# human gets them in the diplomacy panel.
#
# Tension: an AI that is not peaceful does not leave a human neighbour in peace for ever.
# Once the difficulty's "ultimatum_after_s" has passed it demands tribute for a
# non-aggression pact; a human who does not sign in time is at war with it. A pact buys
# a few quiet minutes, then the next demand comes. Much weaker AIs make no demands.

const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const Trade = preload("res://source/match/city/Trade.gd")
const FactionRules = preload("res://source/data-model/Factions.gd")

const LOSING_THREAT = 1.3  # sue for peace once the enemy is this much stronger
const PEACEFUL = 1.2  # personalities at least this peaceful look for treaties on their own
const MIN_WAR_S = 60.0  # wars last at least this long before peaceful AIs give up
const ULTIMATUM_GRACE_S = 20.0  # on top of the offer's own expiry, before war is declared
const ULTIMATUM_AGAIN_S = 240.0  # after a pact ends, the next demand waits this long
const TOO_WEAK_TO_THREATEN = 1.3  # no demands while the human is this much stronger

var offers_made = 0  # statistics

var _player = null
var _last_offer_s = {}  # partner instance id -> time of last offer
var _elapsed_s = 0.0
var _ultimatums = {}  # human instance id -> {"deadline_s", "next_s"}

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
		if not Diplomacy.is_ai(other) and _press_human(diplomacy, other):
			return
		var since_offer = _elapsed_s - _last_offer_s.get(other.get_instance_id(), -INF)
		if since_offer < Constants.Match.Diplomacy.AI_OFFER_COOLDOWN_S:
			continue
		var kind = _treaty_wanted_with(diplomacy, other)
		if kind != null and _offer(diplomacy, other, kind):
			return  # one offer per round


func _press_human(diplomacy, human):
	"""the ultimatum: demands tribute for a pact, declares war when it runs out; true when
	it spoke this round"""
	var after_s = float(_ai.ultimatum_after_s)
	if after_s <= 0.0 or _ai.peacefulness >= PEACEFUL:
		return false
	var now_s = float(_ai.match_time_s)  # game time; the decision timer runs a bit off
	var id = human.get_instance_id()
	var entry = _ultimatums.get(id, {"deadline_s": -1.0, "next_s": after_s})
	_ultimatums[id] = entry
	var state = diplomacy.get_state(_player, human)
	if state != Diplomacy.State.NEUTRAL:
		entry["deadline_s"] = -1.0
		if state != Diplomacy.State.WAR:
			entry["next_s"] = max(entry["next_s"], now_s + ULTIMATUM_AGAIN_S)
		return false
	if entry["deadline_s"] >= 0.0:
		if now_s < entry["deadline_s"]:
			return false
		entry["deadline_s"] = -1.0
		diplomacy.declare_war(_player, human)
		_alert(human, tr("ULTIMATUM_WAR").format([_my_name(human)]))
		return true
	if now_s < entry["next_s"]:
		return false
	return _demand_tribute(diplomacy, human, entry, now_s)


func _demand_tribute(diplomacy, human, entry, now_s):
	if Diplomacy.threat_ratio(_player, human) >= TOO_WEAK_TO_THREATEN:
		return false
	var wanted = Trade.scarce_resource_of(_player)
	var tier = int(_player.get_tier())
	var amount = min(10 + 6 * tier, int(human.get(wanted)))
	var requested = {wanted: amount} if amount > 0 else {}
	if (
		diplomacy.validate(_player, human, Diplomacy.PACT, {}, requested)
		!= Diplomacy.Result.ACCEPTED
	):
		return false
	entry["deadline_s"] = (now_s + Constants.Match.Diplomacy.OFFER_EXPIRY_S + ULTIMATUM_GRACE_S)
	offers_made += 1
	_last_offer_s[human.get_instance_id()] = _elapsed_s
	MatchSignals.diplomacy_offered.emit(_player, human, Diplomacy.PACT, {}, requested)
	_alert(human, tr("ULTIMATUM_DEMAND").format([_my_name(human)]))
	return true


func _my_name(human):
	"""as the human's diplomacy bar names us: faction and colour, or "Faction N" """
	var label = FactionRules.label_for(_player)
	if label != "":
		return label
	var others = get_tree().get_nodes_in_group("players").filter(
		func(player): return player != human
	)
	return tr("TRADE_FACTION").format([others.find(_player) + 1])


func _alert(human, text):
	"""a warning line for the human, through the guide's alerts"""
	if not human.is_in_group("players") or Diplomacy.is_ai(human):
		return
	var guide = get_tree().root.find_child("Guide", true, false)
	if guide != null and guide.has_method("show_alert"):
		guide.show_alert(text)


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
	var price = (
		_price_to_meet(other, kind)
		if Diplomacy.is_ai(other)
		else Diplomacy.ai_asking_price(_player, other, kind)
	)
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


func _price_to_meet(other_ai, kind):
	"""another AI answers by its own price, so offer that, as long as the treaty is
	worth it to us; otherwise two AIs that both want something never make peace"""
	var theirs = Diplomacy.ai_asking_price(other_ai, _player, kind)
	if theirs == null:
		return null
	var cost = (
		Trade.value_for(_player, theirs["requested"]) - Trade.value_for(_player, theirs["offered"])
	)
	if cost > Diplomacy.treaty_worth(_player, other_ai, kind):
		return null
	return {"offered": theirs["requested"], "requested": theirs["offered"]}
