extends "res://source/match/units/Hauler.gd"

# Trade caravan. Carries traded goods from the sender's depot to the receiver's depot.
# The two trading factions let it pass (safe conduct), anybody else can raid it and loot
# part of the cargo.

var trade_partner = null


func is_protected_from(attacker_player):
	return attacker_player == trade_partner
