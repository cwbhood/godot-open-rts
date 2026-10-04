extends Node

# Relations between factions. Every pair of factions is in one of four states:
# - NEUTRAL (the start): units hold fire unless ordered to attack. Any hit on the other
#   side, a shot, a raid, a caravan ambush, means war.
# - WAR: units fight on sight and the two cannot trade. Only a non-aggression pact ends
#   a war, and only after a pact can the two become allies.
# - PACT (non-aggression): for PACT_S neither side can harm the other, other factions
#   still can. Then back to neutral.
# - ALLIANCE: like a pact, for ALLIANCE_S, and allies trade at fair prices and AI allies
#   go after their ally's enemies. A faction has at most one ally, and can only ally
#   with a faction that has none. When it runs out it becomes a pact, then neutral.
# Pacts and alliances are offered for free or in exchange for goods, paid on signing.
# AIs judge offers by their personality and by how strong the other side is.

enum State { WAR, NEUTRAL, PACT, ALLIANCE }
enum Result {
	ACCEPTED,
	INVALID,
	AT_WAR_NEEDS_PACT,
	ALREADY_ALLIED,
	PARTNER_ALLIED,
	ALREADY_IN_EFFECT,
	PROPOSER_CANNOT_AFFORD,
	PARTNER_CANNOT_AFFORD,
	PARTNER_REFUSED,
}

const PACT = "pact"
const ALLIANCE = "alliance"
const KINDS = [PACT, ALLIANCE]
const Trade = preload("res://source/match/city/Trade.gd")

# the one Diplomacy of the running match; without one everybody fights everybody
static var instance = null

var _relations = {}  # pair key -> {"state", "left_s", "aggressor", "since_s"}
var _elapsed_s = 0.0


func _enter_tree():
	instance = self


func _exit_tree():
	if instance == self:
		instance = null


func _process(delta):
	_elapsed_s += delta
	for key in _relations.keys():
		var relation = _relations[key]
		if relation["left_s"] <= 0.0:
			continue
		relation["left_s"] -= delta
		if relation["left_s"] > 0.0:
			continue
		if relation["state"] == State.ALLIANCE:
			_set_state(relation["a"], relation["b"], State.PACT, Constants.Match.Diplomacy.PACT_S)
		elif relation["state"] == State.PACT:
			_set_state(relation["a"], relation["b"], State.NEUTRAL, 0.0)


# queries usable from anywhere; they fall back to "everybody is an enemy" without a match


static func state_between(a, b):
	if instance == null or a == null or b == null or a == b:
		return State.WAR
	return instance.get_state(a, b)


static func can_attack(attacker_player, target_player):
	"""whether units of one faction may hit the other at all (an order or a pact allows it)"""
	if attacker_player == null or target_player == null or attacker_player == target_player:
		return attacker_player != target_player
	return state_between(attacker_player, target_player) in [State.WAR, State.NEUTRAL]


static func engages_on_sight(player, other_player):
	"""whether idle units and turrets open fire on their own: only at war"""
	if player == null or other_player == null or player == other_player:
		return player != other_player
	return state_between(player, other_player) == State.WAR


static func at_war(a, b):
	return instance != null and a != b and state_between(a, b) == State.WAR


static func allied(a, b):
	return instance != null and a != b and state_between(a, b) == State.ALLIANCE


static func ally_of(player):
	return instance.get_ally(player) if instance != null else null


static func register_hit(attacker_player, target_player):
	"""called for every hit; returns false when a treaty protects the target (the hit
	does nothing), and turns neutral factions into enemies"""
	if instance == null or attacker_player == null or target_player == null:
		return true
	if attacker_player == target_player:
		return true
	var state = instance.get_state(attacker_player, target_player)
	if state == State.PACT or state == State.ALLIANCE:
		return false
	if state == State.NEUTRAL:
		instance.declare_war(attacker_player, target_player)
	return true


# instance API


func get_state(a, b):
	var relation = _relations.get(_key(a, b))
	return relation["state"] if relation != null else State.NEUTRAL


func seconds_left(a, b):
	var relation = _relations.get(_key(a, b))
	return max(0.0, relation["left_s"]) if relation != null else 0.0


func aggressor(a, b):
	"""who struck first in the current war, or null"""
	var relation = _relations.get(_key(a, b))
	return relation["aggressor"] if relation != null else null


func seconds_in_state(a, b):
	var relation = _relations.get(_key(a, b))
	return _elapsed_s - relation["since_s"] if relation != null else _elapsed_s


func get_ally(player):
	for relation in _relations.values():
		if relation["state"] != State.ALLIANCE:
			continue
		if relation["a"] == player and is_instance_valid(relation["b"]):
			return relation["b"]
		if relation["b"] == player and is_instance_valid(relation["a"]):
			return relation["a"]
	return null


func declare_war(attacker_player, target_player):
	if get_state(attacker_player, target_player) == State.WAR:
		return
	_set_state(attacker_player, target_player, State.WAR, 0.0, attacker_player)
	var market = get_parent().get_node_or_null("Market") if get_parent() != null else null
	if market != null:
		market.cancel_agreements_between(attacker_player, target_player)


func can_sign(proposer, partner, kind):
	if proposer == null or partner == null or proposer == partner or not kind in KINDS:
		return Result.INVALID
	var state = get_state(proposer, partner)
	var result = Result.ACCEPTED
	if state == State.ALLIANCE:
		result = Result.ALREADY_IN_EFFECT
	elif kind == PACT:
		result = Result.ACCEPTED
	elif state == State.WAR:
		result = Result.AT_WAR_NEEDS_PACT
	elif get_ally(proposer) != null:
		result = Result.ALREADY_ALLIED
	elif get_ally(partner) != null:
		result = Result.PARTNER_ALLIED
	return result


func validate(proposer, partner, kind, offered, requested):
	var result = can_sign(proposer, partner, kind)
	if result != Result.ACCEPTED:
		return result
	for resources in [offered, requested]:
		for resource in resources:
			if not resource in Constants.Match.Resources.ALL or resources[resource] < 0:
				return Result.INVALID
	if not Trade._can_afford(proposer, offered):
		return Result.PROPOSER_CANNOT_AFFORD
	if not Trade._can_afford(partner, requested):
		return Result.PARTNER_CANNOT_AFFORD
	return Result.ACCEPTED


func propose(proposer, partner, kind, offered = {}, requested = {}):
	"""an offer to an AI, which answers on the spot; offers to a human go through
	MatchSignals.diplomacy_offered and the HUD calls sign_treaty() when they accept"""
	var result = validate(proposer, partner, kind, offered, requested)
	if result != Result.ACCEPTED:
		return result
	if is_ai(partner) and not ai_accepts(partner, proposer, kind, requested, offered):
		return Result.PARTNER_REFUSED
	sign_treaty(proposer, partner, kind, offered, requested)
	return Result.ACCEPTED


func sign_treaty(proposer, partner, kind, offered = {}, requested = {}):
	proposer.subtract_resources(offered)
	partner.add_resources(offered)
	partner.subtract_resources(requested)
	proposer.add_resources(requested)
	var c = Constants.Match.Diplomacy
	if kind == ALLIANCE:
		_set_state(proposer, partner, State.ALLIANCE, c.ALLIANCE_S)
	else:
		_set_state(proposer, partner, State.PACT, c.PACT_S)
	MatchSignals.treaty_signed.emit(proposer, partner, kind, offered, requested)


# how factions value treaties


static func is_ai(player):
	return player != null and "personality_id" in player


static func strength_of(player):
	"""rough fighting strength: hit points of everything that can shoot"""
	var strength = 0.0
	for unit in player.get_tree().get_nodes_in_group("units"):
		if unit.player == player and unit.attack_damage != null:
			strength += unit.hp
	return strength


static func threat_ratio(player, other):
	"""above 1 when 'other' is stronger than 'player'"""
	var c = Constants.Match.Diplomacy
	return clamp(
		(strength_of(other) + c.STRENGTH_FLOOR) / (strength_of(player) + c.STRENGTH_FLOOR),
		c.THREAT_MIN,
		c.THREAT_MAX
	)


static func treaty_worth(player, other, kind):
	"""what a treaty with 'other' is worth to 'player', in trade value"""
	var c = Constants.Match.Diplomacy
	var worth = c.TREATY_WORTH[kind] * threat_ratio(player, other)
	if state_between(player, other) == State.WAR:
		worth *= c.WAR_WORTH_FACTOR
	return worth


static func ai_demand(ai_player, other, kind):
	"""trade value the AI wants on top of the treaty; negative means it would pay that
	much itself, null means it will not sign at all"""
	if kind == ALLIANCE and not ai_player.get("accepts_alliances"):
		return null
	var c = Constants.Match.Diplomacy
	var peacefulness = max(0.1, float(ai_player.get("peacefulness")))
	var demand = c.AI_BASE_DEMAND[kind] / peacefulness - treaty_worth(ai_player, other, kind)
	if instance != null and instance.aggressor(ai_player, other) == other:
		demand += c.AGGRESSOR_GRUDGE
	return demand


static func ai_accepts(ai_player, other, kind, given, received):
	var demand = ai_demand(ai_player, other, kind)
	if demand == null:
		return false
	return Trade.value_for(ai_player, received) - Trade.value_for(ai_player, given) >= demand


static func ai_asking_price(ai_player, other, kind):
	"""goods the AI asks 'other' for, or offers if it would pay: {"requested", "offered"},
	or null if it refuses outright"""
	var demand = ai_demand(ai_player, other, kind)
	if demand == null:
		return null
	if demand > 0.0:
		var wanted = Trade.scarce_resource_of(ai_player)
		var amount = int(ceil(demand / Trade.local_price(ai_player, wanted)))
		return {"requested": {wanted: amount}, "offered": {}}
	var spare = Trade.abundant_resource_of(ai_player)
	var reserve = Constants.Match.Trade.AI_TRADE_RESERVE.get(spare, 0)
	var tribute = int(floor(-demand * 0.5 / Trade.local_price(ai_player, spare)))
	tribute = clamp(tribute, 0, max(0, int(ai_player.get(spare)) - reserve))
	return {"requested": {}, "offered": {spare: tribute} if tribute > 0 else {}}


static func assess(player, other, kind, given, received):
	"""Good/Fair/Bad advice for a treaty deal, counting the treaty itself as goods"""
	var worth = treaty_worth(player, other, kind)
	var assessment = Trade.assess(player, given, received, worth)
	var key = "DIPLOMACY_WORTH_STRONGER"
	if threat_ratio(player, other) < 0.8:
		key = "DIPLOMACY_WORTH_WEAKER"
	elif threat_ratio(player, other) <= 1.25:
		key = "DIPLOMACY_WORTH_EVEN"
	assessment["reason"] = (
		TranslationServer.translate(key).format([int(round(worth))]) + "; " + assessment["reason"]
	)
	return assessment


func _set_state(a, b, state, duration_s, war_aggressor = null):
	var key = _key(a, b)
	_relations[key] = {
		"a": a,
		"b": b,
		"state": state,
		"left_s": duration_s,
		"aggressor": war_aggressor,
		"since_s": _elapsed_s,
	}
	if state == State.PACT or state == State.ALLIANCE:
		_stop_hostilities(a, b)
	MatchSignals.diplomacy_changed.emit(a, b, state)


func _stop_hostilities(a, b):
	"""cancels attacks already under way between the two"""
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player != a and unit.player != b:
			continue
		var other = b if unit.player == a else a
		var node = unit.action
		while node != null and is_instance_valid(node):
			var target = node.get("_target_unit")
			if (
				target != null
				and is_instance_valid(target)
				and "player" in target
				and target.player == other
			):
				if node == unit.action:
					unit.action = null
				else:
					node.queue_free()
				break
			node = node.get("_sub_action")


static func _key(a, b):
	var ids = [a.get_instance_id(), b.get_instance_id()]
	ids.sort()
	return "{0}:{1}".format(ids)
