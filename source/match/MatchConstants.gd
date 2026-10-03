const OWNED_PLAYER_CIRCLE_COLOR = Color.GREEN
const ADVERSARY_PLAYER_CIRCLE_COLOR = Color.RED
const RESOURCE_CIRCLE_COLOR = Color.YELLOW
const DEFAULT_CIRCLE_COLOR = Color.WHITE
const GameData = preload("res://source/data-model/GameData.gd")

# content definitions (units, structures, commodities, tiers, maps) live in res://data/,
# see data/README.md; the static vars below expose them in the shape the code expects
# gdlint: ignore=class-variable-name
static var MAPS = GameData.maps()


class Navigation:
	enum Domain { AIR, TERRAIN }

	const DOMAIN_TO_GROUP_MAPPING = {
		Domain.AIR: "air_navigation_input",
		Domain.TERRAIN: "terrain_navigation_input",
	}


class Air:
	const Y = 1.5
	const PLANE = Plane(Vector3.UP, Y)

	class Navmesh:
		const CELL_SIZE = 0.4
		const CELL_HEIGHT = 0.4
		const MAX_AGENT_RADIUS = 0.8


class Terrain:
	const PLANE = Plane(Vector3.UP, 0)

	class Navmesh:
		const CELL_SIZE = 0.3
		const CELL_HEIGHT = 0.3
		const MAX_AGENT_RADIUS = 0.9  # max radius of movable units


class Resources:
	# commodities stored by every player; all of them come from deposits on the map
	const TIMBER = "timber"
	const IRON = "iron"
	const COPPER = "copper"
	const OIL = "oil"
	# gdlint: ignore=class-variable-name
	static var ALL = GameData.resource_ids()
	# gdlint: ignore=class-variable-name
	static var COLORS = GameData.resource_field("color")
	# gdlint: ignore=class-variable-name
	static var STARTING_STOCK = GameData.resource_field("starting_stock")
	# gdlint: ignore=class-variable-name
	static var DEFAULT_DEPOSIT_AMOUNT = GameData.resource_field("deposit_amount")
	# gdlint: ignore=class-variable-name
	static var DEPOSIT_SCENES = GameData.resource_field("deposit_scene")


class Units:
	const PRODUCTION_QUEUE_LIMIT = 5
	const ADHERENCE_MARGIN_M = 0.3  # TODO: try lowering while fixing a 'push' problem
	const NEW_RESOURCE_SEARCH_RADIUS_M = 30
	const MOVING_UNIT_RADIUS_MAX_M = 1.0
	const EMPTY_SPACE_RADIUS_SURROUNDING_STRUCTURE_M = MOVING_UNIT_RADIUS_MAX_M * 2.5
	const STRUCTURE_CONSTRUCTING_SPEED = 0.3  # progress [0.0..1.0] per second
	# gdlint: ignore=class-variable-name
	static var PRODUCTION_COSTS = GameData.unit_field("cost", "unit")
	# gdlint: ignore=class-variable-name
	static var PRODUCTION_TIMES = GameData.unit_field("build_time_s", "unit")
	# minimal city tier (see Tech.TIERS) required to produce a unit or construct a structure
	# gdlint: ignore=class-variable-name
	static var TIER_REQUIREMENTS = GameData.unit_field("tier")
	# gdlint: ignore=class-variable-name
	static var STRUCTURE_BLUEPRINTS = GameData.unit_field("blueprint", "structure")
	# construction materials are paid when a structure is placed; outside of the city yard
	# they have to be brought to the construction site by haulers, see Logistics
	# gdlint: ignore=class-variable-name
	static var CONSTRUCTION_COSTS = GameData.unit_field("cost", "structure")
	# gdlint: ignore=class-variable-name
	static var DEFAULT_PROPERTIES = GameData.unit_field("properties")
	# gdlint: ignore=class-variable-name
	static var PROJECTILES = GameData.unit_field("projectile")
	# oil burnt per second while a unit is moving
	# gdlint: ignore=class-variable-name
	static var FUEL_PER_S = GameData.unit_field("fuel_per_s")
	# movement speed in m/s, overrides the Movement node of the scene
	# gdlint: ignore=class-variable-name
	static var SPEEDS = GameData.unit_field("speed")


class Extraction:
	# extractors have to be placed next to a deposit of the matching kind
	const MAX_DISTANCE_TO_DEPOSIT_M = 1.5  # gap between the extractor and the deposit edges
	const UNPOWERED_RATE_FACTOR = 0.5
	const STORAGE_MAX = 16  # goods wait at the extractor until a hauler picks them up
	# gdlint: ignore=class-variable-name
	static var EXTRACTOR_KINDS = GameData.unit_field("extracts", "structure")
	# with a fully powered grid
	# gdlint: ignore=class-variable-name
	static var RATE_PER_S = GameData.resource_field("extraction_rate_per_s")


class Logistics:
	const TICK_S = 0.5
	const YARD_RADIUS_M = 9.0  # sites this close to a depot get materials without haulers
	const YARD_DELIVERY_PER_S = 4.0
	const MIN_PICKUP = 4  # haulers do not drive out for less than this
	const LOOT_SHARE = 0.5  # share of destroyed cargo that goes to the attacker
	const HAULER_IDLE_RECHECK_S = 1.0


class Roads:
	# road levels a supply route can be upgraded to, from data/roads.json
	# gdlint: ignore=class-variable-name
	static var LEVELS = GameData.roads()


class Fuel:
	# units burn oil from the player stock while moving (rates in data/units/*.json);
	# with no oil left they crawl
	const OUT_OF_FUEL_SPEED_FACTOR = 0.4


class Power:
	const TICK_S = 1.0
	# MW produced by a structure when it runs
	const CITY_DEMAND_MW_PER_POPULATION = 0.08
	const UNPOWERED_PRODUCTION_FACTOR = 0.25
	# gdlint: ignore=class-variable-name
	static var OUTPUT_MW = GameData.unit_power_field("output_mw")
	# gdlint: ignore=class-variable-name
	static var DEMAND_MW = GameData.unit_power_field("demand_mw")
	# structures within this radius are wired to the grid node; two nodes connect when
	# their radii overlap
	# gdlint: ignore=class-variable-name
	static var GRID_RADIUS_M = GameData.unit_power_field("grid_radius_m")
	# commodities burnt per MW per second while a plant is loaded
	# gdlint: ignore=class-variable-name
	static var BURNS = GameData.unit_power_field("burns")


class City:
	const TICK_S = 0.5
	const STARTING_POPULATION = 10.0
	const POPULATION_PER_BUILDING = 5.0
	const MAX_BUILDINGS = 24
	const BASE_GROWTH_PER_S = 0.12  # slows down as housing fills up
	const WORKSHOP_EVERY_NTH_BUILDING = 3  # the rest are houses
	const PRODUCTION_SPEED_BONUS_PER_WORKSHOP = 0.06
	const SCIENCE_PER_POPULATION_PER_S = 0.02
	const BUILDING_RADIUS_M = 1.0
	const FIRST_BUILDING_RING_RADIUS_M = 5.5
	const BUILDING_RING_SPACING_M = 2.5
	const BUILDING_RINGS = 4
	const BUILDING_MODELS = {
		"house": "res://assets/models/kenney-spacekit/hangar_roundA.glb",
		"workshop": "res://assets/models/kenney-spacekit/machine_generator.glb",
	}
	# share of every delivery that goes into the city warehouse instead of the player stock
	const DELIVERY_SHARE = 0.25
	const WAREHOUSE_CAPACITY = 40.0  # per commodity; overflow spills into the player stock
	const BUILDING_COSTS = {
		"house": {"timber": 4.0, "iron": 1.0},
		"workshop": {"timber": 2.0, "iron": 3.0, "copper": 1.0},
	}
	const SATISFACTION_SMOOTHING = 0.05  # per tick, exponential moving average
	const STARVING_SATISFACTION = 0.35  # below this the population slowly shrinks
	const SHRINK_PER_S = 0.03
	const UNPOWERED_SCIENCE_FACTOR = 0.4
	# gdlint: ignore=class-variable-name
	static var STARTING_WAREHOUSE = GameData.resource_field("city_starting_warehouse")
	# commodities consumed per citizen per minute
	# gdlint: ignore=class-variable-name
	static var UPKEEP_PER_POPULATION_PER_MIN = GameData.resource_field(
		"city_upkeep_per_population_per_min"
	)


class CivilDefense:
	const TICK_S = 1.0
	const THREAT_RADIUS_M = 16.0
	const POSTS_BASE = 2
	const POSTS_PER_POPULATION = 1.0 / 20.0
	const POSTS_MAX = 5
	const MILITIA_BASE = 2
	const MILITIA_PER_POPULATION = 1.0 / 30.0
	const MILITIA_MAX = 4
	const MILITIA_REINFORCEMENT_S = 25.0
	const POST_REBUILD_S = 40.0
	const POST_RING_RADIUS_M = 4.0
	const POST_COST = {"iron": 4.0, "timber": 2.0}  # paid from the city warehouse


class Trade:
	const PARTNER_COOLDOWN_S = 20.0  # how often a single faction is willing to trade
	const GROWTH_BOOST_PER_TRADED_VALUE = 0.01  # population/s, for both sides
	const GROWTH_BOOST_MAX = 0.5
	const GROWTH_BOOST_DECAY_PER_S = 0.005
	const COMFORTABLE_STOCK = 40.0  # local price equals the base price at this stock level
	const PRICE_FACTOR_MIN = 0.5
	const PRICE_FACTOR_MAX = 2.5
	const AI_PROFIT_MARGIN = 1.05  # AI wants to receive at least this much more than it gives
	const AI_TRADE_RESERVE = {"timber": 4, "iron": 4, "copper": 2, "oil": 3}
	const AI_OFFER_INTERVAL_S = 30.0
	const OFFER_EXPIRY_S = 20.0
	# gdlint: ignore=class-variable-name
	static var BASE_PRICES = GameData.resource_field("base_price")


class Tech:
	# science is never spent; the city reaches the next tier once it accumulates enough
	# gdlint: ignore=class-variable-name
	static var TIERS = GameData.tiers()


class VoiceNarrator:
	enum Events {
		MATCH_STARTED,
		MATCH_ABORTED,
		MATCH_FINISHED_WITH_VICTORY,
		MATCH_FINISHED_WITH_DEFEAT,
		BASE_UNDER_ATTACK,
		UNIT_UNDER_ATTACK,
		UNIT_LOST,
		UNIT_PRODUCTION_STARTED,
		UNIT_PRODUCTION_FINISHED,
		UNIT_CONSTRUCTION_FINISHED,
		UNIT_HELLO,
		UNIT_ACK_1,
		UNIT_ACK_2,
		NOT_ENOUGH_RESOURCES,
	}

	const EVENT_TO_ASSET_MAPPING = {
		Events.MATCH_STARTED:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/battle_control_online.ogg"),
		Events.MATCH_ABORTED:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/battle_control_offline.ogg"),
		Events.MATCH_FINISHED_WITH_VICTORY:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/you_are_victorious.ogg"),
		Events.MATCH_FINISHED_WITH_DEFEAT:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/you_have_lost.ogg"),
		Events.BASE_UNDER_ATTACK:
		preload(
			"res://assets/voice/english/ttsmaker-com-148-alayna-us/your_base_is_under_attack.ogg"
		),
		Events.UNIT_UNDER_ATTACK:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/unit_under_attack.ogg"),
		Events.UNIT_LOST:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/unit_lost.ogg"),
		Events.UNIT_PRODUCTION_STARTED:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/training.ogg"),
		Events.UNIT_PRODUCTION_FINISHED:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/unit_ready.ogg"),
		Events.UNIT_CONSTRUCTION_FINISHED:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/construction_complete.ogg"),
		Events.UNIT_HELLO:
		preload("res://assets/voice/english/ttsmaker-com-2704-jackson-us/sir.ogg"),
		Events.UNIT_ACK_1:
		preload("res://assets/voice/english/ttsmaker-com-2704-jackson-us/yes_sir.ogg"),
		Events.UNIT_ACK_2:
		preload("res://assets/voice/english/ttsmaker-com-2704-jackson-us/acknowledged.ogg"),
		Events.NOT_ENOUGH_RESOURCES:
		preload("res://assets/voice/english/ttsmaker-com-148-alayna-us/not_enough_resources.ogg"),
	}
