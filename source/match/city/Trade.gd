# Resource exchange between two factions. A completed trade moves the resources and
# gives both cities a temporary growth boost, so trading pays off for both sides.

enum Result {
	ACCEPTED,
	INVALID,
	PROPOSER_CANNOT_AFFORD,
	PARTNER_CANNOT_AFFORD,
	PARTNER_BUSY,
	PARTNER_REFUSED,
}


static func propose(proposer, partner, offered, requested):
	"""'offered' and 'requested' are resource dicts, e.g. {"resource_a": 3}.
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
			if not resource in Constants.Match.Trade.RESOURCES or resources[resource] < 0:
				return Result.INVALID
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
	"""AI accepts when what it receives is worth at least what it gives away.
	The crystal it has less of is worth more to it."""
	return value_for(ai_player, received) >= value_for(ai_player, given)


static func value_for(player, resources):
	var scarce_resource = scarce_resource_of(player)
	var value = 0.0
	for resource in resources:
		value += (
			resources[resource]
			* (Constants.Match.Trade.SCARCE_RESOURCE_VALUE if resource == scarce_resource else 1.0)
		)
	return value


static func scarce_resource_of(player):
	if player.resource_a < player.resource_b:
		return "resource_a"
	if player.resource_b < player.resource_a:
		return "resource_b"
	return null


static func execute(proposer, partner, offered, requested):
	proposer.subtract_resources(offered)
	partner.add_resources(offered)
	partner.subtract_resources(requested)
	proposer.add_resources(requested)
	var traded_total = _total(offered) + _total(requested)
	if proposer.city != null:
		proposer.city.register_trade(partner, traded_total)
	if partner.city != null:
		partner.city.register_trade(proposer, traded_total)
	MatchSignals.trade_completed.emit(proposer, partner, offered, requested)


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
