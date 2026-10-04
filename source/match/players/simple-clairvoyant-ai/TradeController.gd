extends Node

# Every now and then the AI offers its most abundant commodity for the one it is most
# short of, at a price that is fair in its own local prices. Other AIs decide on the
# spot, a human player gets the offer in the city panel. Trading personalities also
# propose repeated agreements to other AIs.

const Trade = preload("res://source/match/city/Trade.gd")
const Human = preload("res://source/match/players/human/Human.gd")

const MAX_OFFERED_AMOUNT = 10

var trades_offered = 0  # statistics

var _player = null

@onready var _ai = get_parent()


func setup(player):
	_player = player
	var timer = Timer.new()
	timer.timeout.connect(_try_offering_trade)
	add_child(timer)
	timer.start(_ai.trade_offer_interval_s * randf_range(0.8, 1.2))


func _try_offering_trade():
	var scarce = Trade.scarce_resource_of(_player)
	var abundant = Trade.abundant_resource_of(_player)
	if scarce == null or abundant == null or scarce == abundant:
		return
	var reserve = Constants.Match.Trade.AI_TRADE_RESERVE.get(abundant, 0)
	var offered_amount = min(MAX_OFFERED_AMOUNT, _player.get(abundant) - reserve)
	if offered_amount < 2:
		return
	var offered = {abundant: offered_amount}
	var requested_amount = Trade.fair_amount(_player, abundant, offered_amount, scarce)
	if requested_amount < 1:
		return
	var requested = {scarce: requested_amount}
	var partners = get_tree().get_nodes_in_group("players").filter(
		func(player): return player != _player
	)
	partners.shuffle()
	var market = find_parent("Match").get_node_or_null("Market")
	for partner in partners:
		if Trade.validate(_player, partner, offered, requested) != Trade.Result.ACCEPTED:
			continue
		trades_offered += 1
		if partner is Human:
			MatchSignals.trade_offered.emit(_player, partner, offered, requested)
			return
		if not Trade.ai_accepts(partner, requested, offered, _player):
			continue
		if _ai.proposes_agreements and market != null and market.agreements_of(_player).is_empty():
			market.propose_agreement(_player, partner, offered, requested)
		else:
			Trade.execute(_player, partner, offered, requested)
		return
