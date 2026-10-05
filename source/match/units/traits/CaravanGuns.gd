extends Node3D

# Guns on a trade caravan of a faction with "armed_caravans" (the Sandline Syndicate, see
# data/factions/). The caravan keeps driving; the guns shoot at armed hostile ground units
# within range, whoever hit the caravan last first. Market.ship adds them.

const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const Stances = preload("res://source/match/units/actions/Stances.gd")
const ShotEffects = preload("res://source/match/units/projectiles/ShotEffects.gd")

const IDLE_CHECK_S = 0.5

var attack_damage = 1  # read by ShotEffects to size the shot
var attack_interval = 0.8
var attack_range = 5.0

var _cooldown_s = 0.0

@onready var _caravan = get_parent()


static func arm(caravan, perk):
	"""adds guns to the caravan with the faction's numbers, returns them"""
	var guns = new()
	guns.name = "CaravanGuns"
	guns.attack_damage = int(perk.get("attack_damage", guns.attack_damage))
	guns.attack_interval = float(perk.get("attack_interval", guns.attack_interval))
	guns.attack_range = float(perk.get("attack_range", guns.attack_range))
	guns.position = Vector3(0, 0.8, 0)
	caravan.add_child(guns)
	return guns


func _physics_process(delta):
	_cooldown_s -= delta
	if _cooldown_s > 0.0 or not _caravan.is_inside_tree():
		return
	var target = _pick_target()
	if target == null:
		_cooldown_s = IDLE_CHECK_S
		return
	_cooldown_s = attack_interval
	ShotEffects.cannon_shot(self, global_transform, target)
	target.take_damage(attack_damage, _caravan)


func _pick_target():
	var attacker = _caravan.get_meta("last_hit_by") if _caravan.has_meta("last_hit_by") else null
	if (
		attacker != null
		and is_instance_valid(attacker)
		and Stances.recently_hit_by(_caravan, attacker)
		and _can_shoot(attacker)
	):
		return attacker
	var best = null
	var best_distance = INF
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _caravan.player or unit.get("attack_damage") == null:
			continue
		if not _can_shoot(unit) or not Diplomacy.engages_on_sight(_caravan.player, unit.player):
			continue
		if unit.player == _caravan.get("trade_partner"):
			continue  # safe conduct both ways
		var distance = _distance_to(unit)
		if distance < best_distance:
			best_distance = distance
			best = unit
	return best


func _can_shoot(unit):
	return (
		unit.is_inside_tree()
		and unit.hp != null
		and unit.hp > 0
		and unit.movement_domain == Constants.Match.Navigation.Domain.TERRAIN
		and _distance_to(unit) <= attack_range
	)


func _distance_to(unit):
	return _caravan.global_position_yless.distance_to(unit.global_position_yless)
