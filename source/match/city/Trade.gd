# Commodity trade between factions. Every faction values commodities by its own local
# prices: whatever it is short of is expensive, whatever piles up is cheap. That makes
# trades worthwhile for both sides when their maps differ (one rich in oil and poor in
# metal, the other the reverse). Accepted trades are shipped by caravans (see Market), so
# goods only arrive if the caravans make it, and both cities get a growth boost.

enum Result {
	ACCEPTED,
	INVALID,
	PROPOSER_CANNOT_AFFORD,
	PARTNER_CANNOT_AFFORD,
	PARTNER_BUSY,
	PARTNER_REFUSED,
	EMBARGO,
}


static func local_price(player, resource):
	var trade = Constants.Match.Trade
	var comfortable = trade.COMFORTABLE_STOCK * _hoarding_factor(player)
	var stock = max(1.0, float(player.get(resource)))
	return (
		trade.BASE_PRICES[resource]
		* clamp(sqrt(comfortable / stock), trade.PRICE_FACTOR_MIN, trade.PRICE_FACTOR_MAX)
	)


static func value_for(player, resources):
	var value = 0.0
	for resource in resources:
		value += resources[resource] * local_price(player, resource)
	return value


static func fair_amount(player, give_resource, give_amount, get_resource):
	"""how much of 'get_resource' 'player' would hand over for the offered goods"""
	var offered_value = give_amount * local_price(player, give_resource)
	return int(floor(offered_value / (local_price(player, get_resource) * _margin(player))))


static func propose(proposer, partner, offered, requested):
	"""'offered' and 'requested' are resource dicts, e.g. {"oil": 3}.
	The partner is expected to be an AI which decides on its own."""
	var validity = validate(proposer, partner, offered, requested)
	if validity != Result.ACCEPTED:
		return validity
	if not ai_accepts(partner, requested, offered):
		return Result.PARTNER_REFUSED
	execute(proposer, partner, offered, requested)
	return Result.ACCEPTED


static func validate(proposer, partner, offered, requested):
	if proposer == partner or _total(offered) + _total(requested) == 0:
		return Result.INVALID
	for resources in [offered, requested]:
		for resource in resources:
			if not resource in Constants.Match.Resources.ALL or resources[resource] < 0:
				return Result.INVALID
	var market = _market(proposer)
	if market != null and market.is_embargoed(proposer, partner):
		return Result.EMBARGO
	if not _can_afford(proposer, offered):
		return Result.PROPOSER_CANNOT_AFFORD
	if not _can_afford(partner, requested):
		return Result.PARTNER_CANNOT_AFFORD
	if (
		partner.city != null
		and (
			partner.city.seconds_since_last_trade_with(proposer)
			< Constants.Match.Trade.PARTNER_COOLDOWN_S
		)
	):
		return Result.PARTNER_BUSY
	return Result.ACCEPTED


static func ai_accepts(ai_player, given, received):
	"""AI accepts when what it receives is worth more than what it gives, in its prices"""
	return value_for(ai_player, received) >= value_for(ai_player, given) * _margin(ai_player)


static func scarce_resource_of(player):
	var scarcest = null
	for resource in Constants.Match.Resources.ALL:
		if (
			scarcest == null
			or (
				local_price(player, resource) / Constants.Match.Trade.BASE_PRICES[resource]
				> (local_price(player, scarcest) / Constants.Match.Trade.BASE_PRICES[scarcest])
			)
		):
			scarcest = resource
	return scarcest


static func abundant_resource_of(player):
	var abundant = null
	for resource in Constants.Match.Resources.ALL:
		if (
			abundant == null
			or (
				local_price(player, resource) / Constants.Match.Trade.BASE_PRICES[resource]
				< (local_price(player, abundant) / Constants.Match.Trade.BASE_PRICES[abundant])
			)
		):
			abundant = resource
	return abundant


static func execute(proposer, partner, offered, requested):
	proposer.subtract_resources(offered)
	partner.subtract_resources(requested)
	var traded_value = value_for(proposer, requested) + value_for(partner, offered)
	if proposer.city != null:
		proposer.city.register_trade(partner, traded_value)
	if partner.city != null:
		partner.city.register_trade(proposer, traded_value)
	var market = _market(proposer)
	if market != null:
		market.ship(proposer, partner, offered)
		market.ship(partner, proposer, requested)
	else:
		partner.add_resources(offered)
		proposer.add_resources(requested)
	MatchSignals.trade_completed.emit(proposer, partner, offered, requested)


static func _market(player):
	var a_match = player.find_parent("Match")
	return a_match.get_node_or_null("Market") if a_match != null else null


static func _hoarding_factor(player):
	return player.get_meta("trade_hoarding_factor", 1.0)


static func _margin(player):
	return player.get_meta("trade_profit_margin", Constants.Match.Trade.AI_PROFIT_MARGIN)


static func _can_afford(player, resources):
	for resource in resources:
		if player.get(resource) < resources[resource]:
			return false
	return true


static func _total(resources):
	var total = 0
	for resource in resources:
		total += resources[resource]
	return total
