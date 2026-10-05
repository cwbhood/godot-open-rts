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
	AT_WAR,
}

enum Verdict { GOOD, FAIR, BAD }

const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")


static func local_price(player, resource):
	return _price_at_stock(player, resource, float(player.get(resource)))


static func assess(player, given, received, extra_received_value = 0.0):
	"""whether a trade pays off for 'player' right now, as
	{"verdict": Verdict, "reason": translated line}. Goods are valued at the prices the
	player would have halfway through the trade, so giving away the last of something
	counts for a lot and receiving more of what is piling up counts for little.
	'extra_received_value' counts something besides goods, like a treaty."""
	var trade = Constants.Match.Trade
	for resource in given:
		var left = int(player.get(resource)) - int(given[resource])
		if left < 0:
			return _verdict(Verdict.BAD, "TRADE_VERDICT_CANNOT_AFFORD", [_name(resource)])
		if left < trade.ASSESSMENT_SAFETY_STOCK and given[resource] > 0:
			return _verdict(Verdict.BAD, "TRADE_VERDICT_DRAINS", [left, _name(resource)])
	var given_value = 0.0
	for resource in given:
		var stock = float(player.get(resource)) - given[resource] / 2.0
		given_value += given[resource] * _price_at_stock(player, resource, stock)
	var received_value = extra_received_value
	for resource in received:
		var stock = float(player.get(resource)) + received[resource] / 2.0
		received_value += received[resource] * _price_at_stock(player, resource, stock)
	if given_value <= 0.0:
		return _verdict(Verdict.GOOD, "TRADE_VERDICT_FREE", [])
	var ratio = received_value / given_value
	var percent = int(round(abs(ratio - 1.0) * 100.0))
	if ratio >= trade.ASSESSMENT_GOOD_RATIO:
		return _verdict(Verdict.GOOD, "TRADE_VERDICT_GOOD", [percent])
	if ratio >= trade.ASSESSMENT_FAIR_RATIO:
		return _verdict(Verdict.FAIR, "TRADE_VERDICT_FAIR", [percent])
	return _verdict(Verdict.BAD, "TRADE_VERDICT_BAD", [percent])


static func value_for(player, resources):
	var value = 0.0
	for resource in resources:
		value += resources[resource] * local_price(player, resource)
	return value


static func fair_amount(player, give_resource, give_amount, get_resource, partner = null):
	"""how much of 'get_resource' 'player' would hand over for the offered goods"""
	var offered_value = give_amount * local_price(player, give_resource)
	return int(
		floor(offered_value / (local_price(player, get_resource) * _margin(player, partner)))
	)


static func propose(proposer, partner, offered, requested):
	"""'offered' and 'requested' are resource dicts, e.g. {"oil": 3}.
	The partner is expected to be an AI which decides on its own."""
	var validity = validate(proposer, partner, offered, requested)
	if validity != Result.ACCEPTED:
		return validity
	if not ai_accepts(partner, requested, offered, proposer):
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
	if Diplomacy.at_war(proposer, partner):
		return Result.AT_WAR
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


static func ai_accepts(ai_player, given, received, partner = null):
	"""AI accepts when what it receives is worth more than what it gives, in its prices"""
	return (
		value_for(ai_player, received) >= value_for(ai_player, given) * _margin(ai_player, partner)
	)


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


static func _price_at_stock(player, resource, stock):
	var trade = Constants.Match.Trade
	var comfortable = trade.COMFORTABLE_STOCK * _hoarding_factor(player)
	return (
		trade.BASE_PRICES[resource]
		* clamp(sqrt(comfortable / max(1.0, stock)), trade.PRICE_FACTOR_MIN, trade.PRICE_FACTOR_MAX)
	)


static func _verdict(verdict, reason_key, arguments):
	return {
		"verdict": verdict,
		"reason": TranslationServer.translate(reason_key).format(arguments),
	}


static func _name(resource):
	return TranslationServer.translate(resource.to_upper())


static func _market(player):
	var a_match = player.find_parent("Match")
	return a_match.get_node_or_null("Market") if a_match != null else null


static func _hoarding_factor(player):
	return player.get_meta("trade_hoarding_factor", 1.0)


static func _margin(player, partner = null):
	var margin = player.get_meta("trade_profit_margin", Constants.Match.Trade.AI_PROFIT_MARGIN)
	if partner != null and Diplomacy.allied(player, partner):
		margin = min(margin, Constants.Match.Diplomacy.ALLY_TRADE_MARGIN)  # allies pay fair
	return margin


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
