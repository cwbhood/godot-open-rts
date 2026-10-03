extends Node

# Every now and then, when one crystal runs short while the other piles up,
# the AI offers a trade to another faction. Other AIs decide on the spot,
# a human player gets the offer in the city panel.

const Trade = preload("res://source/match/city/Trade.gd")
const Human = preload("res://source/match/players/human/Human.gd")

const MIN_IMBALANCE = 2
const OFFERED_AMOUNT = 3
const REQUESTED_AMOUNT = 2

var _player = null


func setup(player):
	_player = player
	var timer = Timer.new()
	timer.timeout.connect(_try_offering_trade)
	add_child(timer)
	timer.start(Constants.Match.Trade.AI_OFFER_INTERVAL_S * randf_range(0.8, 1.2))


func _try_offering_trade():
	var scarce_resource = Trade.scarce_resource_of(_player)
	if scarce_resource == null:
		return
	var abundant_resource = "resource_b" if scarce_resource == "resource_a" else "resource_a"
	if (
		_player.get(abundant_resource) - _player.get(scarce_resource) < MIN_IMBALANCE
		or _player.get(abundant_resource) < OFFERED_AMOUNT
	):
		return
	var offered = {abundant_resource: OFFERED_AMOUNT}
	var requested = {scarce_resource: REQUESTED_AMOUNT}
	var partners = get_tree().get_nodes_in_group("players").filter(
		func(player): return player != _player
	)
	partners.shuffle()
	for partner in partners:
		if Trade.validate(_player, partner, offered, requested) != Trade.Result.ACCEPTED:
			continue
		if partner is Human:
			MatchSignals.trade_offered.emit(_player, partner, offered, requested)
			return
		if Trade.ai_accepts(partner, requested, offered):
			Trade.execute(_player, partner, offered, requested)
			return
