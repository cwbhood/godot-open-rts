extends Node

# Match-wide trade services:
# - ships traded goods with caravans between the factions' depots,
# - runs trade agreements: the same exchange repeated on a schedule, so factions can
#   come to depend on each other's supply,
# - keeps embargoes: a faction under embargo cannot trade with the imposing faction and
#   all agreements between them are cancelled. AIs impose one on whoever raids their
#   caravans or attacks their city; players can impose one from the trade panel.

const Trade = preload("res://source/match/city/Trade.gd")
const CaravanScene = preload("res://source/match/units/Caravan.tscn")
const Caravan = preload("res://source/match/units/Caravan.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const Hauling = preload("res://source/match/units/actions/Hauling.gd")
const Human = preload("res://source/match/players/human/Human.gd")

const AGREEMENT_INTERVAL_S = 30.0
const AGREEMENT_DELIVERIES = 5
const EMBARGO_S = 120.0

var agreements = []  # {"a", "b", "offered", "requested", "remaining", "next_s"}
var shipped_total = 0  # statistics
var raided_total = 0  # statistics

var _embargoes = {}  # "imposer_id:target_id" -> expiry time
var _elapsed_s = 0.0


func _ready():
	MatchSignals.cargo_destroyed.connect(_on_cargo_destroyed)
	MatchSignals.city_threat_changed.connect(_on_city_threat_changed)
	var timer = Timer.new()
	timer.timeout.connect(_tick.bind(1.0))
	add_child(timer)
	timer.start(1.0)


func is_embargoed(a, b):
	return _embargo_active(a, b) or _embargo_active(b, a)


func impose_embargo(imposer, target, duration_s = EMBARGO_S):
	_embargoes[_key(imposer, target)] = _elapsed_s + duration_s
	cancel_agreements_between(imposer, target)
	MatchSignals.embargo_changed.emit(imposer, target, true)


func lift_embargo(imposer, target):
	_embargoes.erase(_key(imposer, target))
	MatchSignals.embargo_changed.emit(imposer, target, false)


func propose_agreement(proposer, partner, offered, requested):
	"""a repeated trade; the AI partner judges it like a single trade"""
	var result = Trade.validate(proposer, partner, offered, requested)
	if result != Trade.Result.ACCEPTED:
		return result
	if not partner is Human and not Trade.ai_accepts(partner, requested, offered, proposer):
		return Trade.Result.PARTNER_REFUSED
	(
		agreements
		. append(
			{
				"a": proposer,
				"b": partner,
				"offered": offered,
				"requested": requested,
				"remaining": AGREEMENT_DELIVERIES,
				"next_s": _elapsed_s,
			}
		)
	)
	MatchSignals.agreement_changed.emit(proposer, partner)
	return Trade.Result.ACCEPTED


func cancel_agreements_between(a, b):
	var before = agreements.size()
	agreements = agreements.filter(
		func(agreement):
			return not (
				(agreement["a"] == a and agreement["b"] == b)
				or (agreement["a"] == b and agreement["b"] == a)
			)
	)
	if agreements.size() != before:
		MatchSignals.agreement_changed.emit(a, b)


func agreements_of(player):
	return agreements.filter(
		func(agreement): return agreement["a"] == player or agreement["b"] == player
	)


func ship(sender, receiver, goods):
	if Utils.Dict.sum(goods) == 0:
		return
	var receiver_depot = _closest_depot(receiver, _any_depot_position(sender))
	var sender_depot = (
		_closest_depot(sender, receiver_depot.global_position) if receiver_depot != null else null
	)
	if sender_depot == null or receiver_depot == null:
		receiver.add_resources(goods)
		return
	shipped_total += Utils.Dict.sum(goods)
	var caravan = CaravanScene.instantiate()
	caravan.trade_partner = receiver
	caravan.automated = false
	var position = Utils.Match.Unit.Placement.find_valid_position_radially_yet_skip_starting_radius(
		sender_depot.global_position,
		sender_depot.radius,
		caravan.radius,
		0.1,
		(receiver_depot.global_position - sender_depot.global_position).normalized(),
		false,
		find_parent("Match").navigation.get_navigation_map_rid_by_domain(
			Constants.Match.Navigation.Domain.TERRAIN
		),
		get_tree()
	)
	if position == Vector3.INF:  # no room for a caravan by the depot: deliver right away
		caravan.free()
		receiver.add_resources(goods)
		return
	MatchSignals.setup_and_spawn_unit.emit(caravan, Transform3D(Basis(), position), sender)
	caravan.remove_from_group("controlled_units")
	caravan.add_to_group("caravans")
	caravan.cargo = goods.duplicate()
	var deliver = func():
		if not is_instance_valid(receiver) or receiver.logistics == null:
			return false
		receiver.logistics.deliver(caravan.unload_cargo())
		caravan.queue_free()
		return true
	var return_home = func():
		# receiver depot gone: bring the goods back
		if is_instance_valid(caravan) and caravan.is_inside_tree() and not caravan.cargo.is_empty():
			if is_instance_valid(sender):
				sender.add_resources(caravan.unload_cargo())
			caravan.queue_free()
	caravan.action = Hauling.new([[receiver_depot, deliver]], return_home, "TRADING")


func _tick(delta):
	_elapsed_s += delta
	for agreement in agreements.duplicate():
		if _elapsed_s < agreement["next_s"]:
			continue
		var a = agreement["a"]
		var b = agreement["b"]
		if not is_instance_valid(a) or not is_instance_valid(b):
			agreements.erase(agreement)
			continue
		agreement["next_s"] = _elapsed_s + AGREEMENT_INTERVAL_S
		if (
			not Trade.Diplomacy.at_war(a, b)
			and Trade._can_afford(a, agreement["offered"])
			and Trade._can_afford(b, agreement["requested"])
		):
			Trade.execute(a, b, agreement["offered"], agreement["requested"])
			agreement["remaining"] -= 1
		if agreement["remaining"] <= 0:
			agreements.erase(agreement)
			MatchSignals.agreement_changed.emit(a, b)


func _embargo_active(imposer, target):
	var key = _key(imposer, target)
	if not key in _embargoes:
		return false
	if _elapsed_s >= _embargoes[key]:
		_embargoes.erase(key)
		MatchSignals.embargo_changed.emit(imposer, target, false)
		return false
	return true


func _on_cargo_destroyed(unit, owner, cargo, looter, _loot):
	if not unit is Caravan:
		return
	raided_total += Utils.Dict.sum(cargo)
	# the faction that lost a caravan stops trading with the raider for a while
	if looter != null and is_instance_valid(owner) and not owner is Human:
		impose_embargo(owner, looter)


func _on_city_threat_changed(player, threat_level, position):
	if threat_level == 0 or player is Human:
		return
	# an AI under attack embargoes the attackers
	for unit in get_tree().get_nodes_in_group("units"):
		if (
			unit.player != player
			and Trade.Diplomacy.at_war(player, unit.player)
			and unit.attack_damage != null
			and (
				unit.global_position_yless.distance_to(position * Vector3(1, 0, 1))
				<= Constants.Match.CivilDefense.THREAT_RADIUS_M
			)
			and not is_embargoed(player, unit.player)
		):
			impose_embargo(player, unit.player)


func _closest_depot(player, position):
	var closest = null
	for unit in get_tree().get_nodes_in_group("units"):
		if unit is CommandCenter and unit.player == player and unit.is_constructed():
			if (
				closest == null
				or (
					unit.global_position.distance_to(position)
					< closest.global_position.distance_to(position)
				)
			):
				closest = unit
	return closest


func _any_depot_position(player):
	var depot = _closest_depot(player, Vector3.ZERO)
	return depot.global_position if depot != null else Vector3.ZERO


static func _key(imposer, target):
	return "{0}:{1}".format([imposer.get_instance_id(), target.get_instance_id()])
