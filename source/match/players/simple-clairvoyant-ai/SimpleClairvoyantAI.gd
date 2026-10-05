extends "res://source/match/players/Player.gd"

enum ResourceRequestPriority { LOW, MEDIUM, HIGH }
enum OffensiveStructure { VEHICLE_FACTORY, AIRCRAFT_FACTORY }

const TradeController = preload(
	"res://source/match/players/simple-clairvoyant-ai/TradeController.gd"
)
const RaidingController = preload(
	"res://source/match/players/simple-clairvoyant-ai/RaidingController.gd"
)
const DiplomacyController = preload(
	"res://source/match/players/simple-clairvoyant-ai/DiplomacyController.gd"
)
const ArmyPositioningController = preload(
	"res://source/match/players/simple-clairvoyant-ai/ArmyPositioningController.gd"
)
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const GameData = preload("res://source/data-model/GameData.gd")

# personalities (data/ai/*.json) override the numbers below
@export var personality_id = "balanced"
@export var expected_number_of_workers = 3
@export var expected_number_of_haulers = 4
@export var extractor_targets = {"timber": 1, "iron": 2, "copper": 1, "oil": 2}
@export var expected_number_of_power_plants = 1
@export var expected_number_of_ccs = 1
@export var expected_number_of_ag_turrets = 1
@export var expected_number_of_aa_turrets = 1
@export var primary_offensive_structure = OffensiveStructure.VEHICLE_FACTORY
@export var secondary_offensive_structure = OffensiveStructure.AIRCRAFT_FACTORY
@export var expected_number_of_battlegroups = 2
@export var expected_number_of_units_in_battlegroup = 4
@export var raid_party_size = 2
@export var raid_interval_s = 240.0
@export var trade_offer_interval_s = 30.0
@export var proposes_agreements = false
@export var upgrades_roads = true
@export var peacefulness = 1.0
@export var accepts_alliances = true
@export var attacks_neutrals = true
# the difficulty (data/difficulties/) is applied on top of the personality
@export var difficulty_id = "normal"
@export var defence = {}  # where the army stands while home, see ArmyPositioningController
var think_interval_multiplier = 1.0
var reaction_delay_s = 0.5
var first_attack_after_s = 0.0
var scouting = true
var tech_upgrades = true
var retreat_below_hp = 0.0
var focus_fire = true
var match_time_s = 0.0

var _provisioning_ongoing = false
var _resource_requests = {
	ResourceRequestPriority.LOW: [],
	ResourceRequestPriority.MEDIUM: [],
	ResourceRequestPriority.HIGH: [],
}
var _call_to_perform_during_process = null

@onready var _match = find_parent("Match")

@onready var _economy_controller = find_child("EconomyController")
@onready var _defense_controller = find_child("DefenseController")
@onready var _offense_controller = find_child("OffenseController")
@onready var _intelligence_controller = find_child("IntelligenceController")
@onready var _construction_works_controller = find_child("ConstructionWorksController")


func _ready():
	# wait for match to be ready
	if not _match.is_node_ready():
		await _match.ready
	# wait additional frame to make sure other players are in place
	await get_tree().physics_frame

	_apply_personality()
	_apply_difficulty()
	changed.connect(_on_player_data_changed)
	_economy_controller.resources_required.connect(
		_on_resource_request.bind(_economy_controller, ResourceRequestPriority.HIGH)
	)
	_economy_controller.setup(self)
	_defense_controller.resources_required.connect(
		_on_resource_request.bind(_defense_controller, ResourceRequestPriority.MEDIUM)
	)
	_defense_controller.setup(self)
	_offense_controller.resources_required.connect(
		_on_resource_request.bind(_offense_controller, ResourceRequestPriority.LOW)
	)
	_offense_controller.setup(self)
	_intelligence_controller.setup(self)
	_construction_works_controller.setup(self)
	var trade_controller = TradeController.new()
	trade_controller.name = "TradeController"
	add_child(trade_controller)
	trade_controller.setup(self)
	var raiding_controller = RaidingController.new()
	raiding_controller.name = "RaidingController"
	add_child(raiding_controller)
	raiding_controller.resources_required.connect(
		_on_resource_request.bind(raiding_controller, ResourceRequestPriority.LOW)
	)
	raiding_controller.setup(self)
	var diplomacy_controller = DiplomacyController.new()
	diplomacy_controller.name = "DiplomacyController"
	add_child(diplomacy_controller)
	diplomacy_controller.setup(self)
	var army_positioning_controller = ArmyPositioningController.new()
	army_positioning_controller.name = "ArmyPositioningController"
	add_child(army_positioning_controller)
	army_positioning_controller.setup(self)


func wants_to_attack(player):
	"""whether this AI sends troops or raiders against 'player': never through a treaty,
	always at war or against its ally's enemies, and against neutrals by personality"""
	if player == self or not Diplomacy.can_attack(self, player):
		return false
	if Diplomacy.at_war(self, player):
		return true
	var ally = Diplomacy.ally_of(self)
	if ally != null and Diplomacy.at_war(ally, player):
		return true
	return attacks_neutrals


func _apply_personality():
	var personalities = GameData.ai_personalities().filter(
		func(personality): return personality["id"] == personality_id
	)
	if personalities.is_empty():
		return
	var personality = personalities[0]
	for key in personality:
		if key in ["id", "name", "description"]:
			continue
		if key == "trade_hoarding_factor" or key == "trade_profit_margin":
			set_meta(key, float(personality[key]))
		elif key == "extractor_targets":
			extractor_targets = personality[key]
		elif key in self:
			var value = personality[key]
			set(key, int(value) if value is float and key.begins_with("expected") else value)


func think_interval(seconds):
	"""how often a controller re-plans: easier AIs look at the game less often"""
	return seconds * think_interval_multiplier


func may_launch_attacks():
	"""easier AIs leave the other factions alone for the first minutes"""
	return match_time_s >= first_attack_after_s


func _apply_difficulty():
	var difficulty = GameData.ai_difficulty(difficulty_id)
	if difficulty == null:
		return
	gather_rate = float(difficulty.get("gather_rate", 1.0))
	production_speed = float(difficulty.get("production_speed", 1.0))
	think_interval_multiplier = float(difficulty.get("think_interval_multiplier", 1.0))
	reaction_delay_s = float(difficulty.get("reaction_delay_s", reaction_delay_s))
	first_attack_after_s = float(difficulty.get("first_attack_after_s", 0.0))
	scouting = difficulty.get("scouting", true)
	tech_upgrades = difficulty.get("tech_upgrades", true)
	retreat_below_hp = float(difficulty.get("retreat_below_hp", 0.0))
	focus_fire = difficulty.get("focus_fire", true)
	var economy = float(difficulty.get("economy_scale", 1.0))
	expected_number_of_workers = _scaled_at_least_one(expected_number_of_workers, economy)
	expected_number_of_haulers = _scaled_at_least_one(expected_number_of_haulers, economy)
	var targets = {}
	for kind in extractor_targets:
		targets[kind] = _scaled_at_least_one(int(extractor_targets[kind]), economy)
	extractor_targets = targets
	var defense = float(difficulty.get("defense_scale", 1.0))
	expected_number_of_ag_turrets = int(floor(expected_number_of_ag_turrets * defense))
	expected_number_of_aa_turrets = int(floor(expected_number_of_aa_turrets * defense))
	var army = float(difficulty.get("army_size_scale", 1.0))
	expected_number_of_units_in_battlegroup = _scaled_at_least_one(
		expected_number_of_units_in_battlegroup, army
	)
	var max_groups = int(difficulty.get("max_attack_groups", 0))
	if max_groups > 0:
		expected_number_of_battlegroups = min(expected_number_of_battlegroups, max_groups)
	var raid_scale = float(difficulty.get("raid_interval_scale", 1.0))
	if raid_scale <= 0.0:
		raid_party_size = 0  # never raids
	else:
		raid_interval_s *= raid_scale


static func _scaled_at_least_one(count, scale):
	"""a count the difficulty scales, but never down to nothing when it was not nothing"""
	if count <= 0:
		return count
	return max(1, int(round(count * scale)))


func _process(delta):
	match_time_s += delta
	if _call_to_perform_during_process != null:
		var call_to_perform = _call_to_perform_during_process
		_call_to_perform_during_process = null
		call_to_perform.call()


func _provision(controller, resources, metadata):
	_provisioning_ongoing = true
	controller.provision(resources, metadata)
	_provisioning_ongoing = false


func _try_fulfilling_resource_requests_according_to_priorities_next_frame():
	"""This function defers call so that:
	1. 'add_child() from tree_exited signal handler' bug is avoided
	2. high level loop of signals triggering each other is avoided"""
	_call_to_perform_during_process = _try_fulfilling_resource_requests_according_to_priorities


func _try_fulfilling_resource_requests_according_to_priorities():
	if _provisioning_ongoing:
		return
	for priority in [
		ResourceRequestPriority.HIGH, ResourceRequestPriority.MEDIUM, ResourceRequestPriority.LOW
	]:
		while (
			not _resource_requests[priority].is_empty()
			and _can_afford(_resource_requests[priority].front()["resources"], priority)
		):
			var resource_request = _resource_requests[priority].pop_front()
			_provision(
				resource_request["controller"],
				resource_request["resources"],
				resource_request["metadata"]
			)
		if (
			not _resource_requests[priority].is_empty()
			and not _can_afford(_resource_requests[priority].front()["resources"], priority)
		):
			break


func _can_afford(resources, priority):
	"""the economy may dig into the trade reserve, everything else may not"""
	if priority == ResourceRequestPriority.HIGH:
		return has_resources(resources)
	return _has_resources_beyond_trade_reserve(resources)


func _has_resources_beyond_trade_reserve(resources):
	"""AI keeps a few goods of each kind aside so that it has something to trade with"""
	var resources_with_reserve = {}
	for resource in Constants.Match.Resources.ALL:
		resources_with_reserve[resource] = (
			resources.get(resource, 0) + Constants.Match.Trade.AI_TRADE_RESERVE.get(resource, 0)
		)
	return has_resources(resources_with_reserve)


func _on_player_data_changed():
	_try_fulfilling_resource_requests_according_to_priorities_next_frame()


func _on_resource_request(resources, metadata, controller, priority):
	assert(not _provisioning_ongoing, "resource request received during provisioning")
	_resource_requests[priority].append(
		{"controller": controller, "resources": resources, "metadata": metadata}
	)
	_try_fulfilling_resource_requests_according_to_priorities_next_frame()
