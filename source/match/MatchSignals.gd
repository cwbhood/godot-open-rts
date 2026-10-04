extends Node

# requests
signal deselect_all_units
signal setup_and_spawn_unit(unit, transform, player)
signal place_structure(structure_prototype)
signal schedule_navigation_rebake(domain)
signal navigate_unit_to_rally_point(unit, rally_point)  # currently, only for human players
signal trade_offered(proposer, partner, offered, requested)  # AI offering a trade to a human
signal diplomacy_offered(proposer, partner, kind, offered, requested)  # AI offering a treaty

# notifications
signal match_started
signal match_aborted
signal match_finished_with_victory
signal match_finished_with_defeat
signal terrain_targeted(position)
signal unit_spawned(unit)
signal unit_targeted(unit)
signal unit_command_issued(command)  # a player order from UnitCommandHandler
signal unit_selected(unit)
signal unit_deselected(unit)
signal unit_damaged(unit)
signal unit_died(unit)
signal unit_production_started(unit_prototype, producer_unit)
signal unit_production_finished(unit, producer_unit)
signal unit_construction_finished(unit)
signal not_enough_resources_for_production(player)
signal not_enough_resources_for_construction(player)
signal unit_cap_reached(player)  # production refused: no unit slots left
signal resources_depleted  # the last deposit on the map ran dry
signal match_limit_reached(reason, ranking)  # see MatchLimits
signal trade_completed(proposer, partner, offered, requested)
signal tier_reached(player, tier)
signal goods_delivered(player, goods)
signal cargo_destroyed(unit, owner, cargo, looter, loot)
signal city_threat_changed(player, threat_level, position)
signal power_changed(player)
signal embargo_changed(imposer, target, active)
signal agreement_changed(a, b)
signal road_upgraded(player, extractor, level)
signal unit_recycled(unit, refund)  # a truck or train taken apart at a depot
signal route_raided(player, position)  # a truck or train of the player was destroyed
signal aircraft_crashed(unit)
signal diplomacy_changed(a, b, state)
signal treaty_signed(proposer, partner, kind, offered, requested)
