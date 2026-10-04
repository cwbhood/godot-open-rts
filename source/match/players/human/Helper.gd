extends Node

# The helper: an assistant the player can switch on (HUD panel on the left, off by default).
# It plays the economy and the home guard so the player can focus on war and trade:
# - economy: puts idle constructors on auto-expand (see AutoExpand), keeps enough
#   constructors, and asks auto-expand for a vehicle factory when the army needs one;
#   it orders a freight train when far extractors call for one and recycles trucks
#   that have had nothing to do for a while (auto-expand builds the storage yards),
# - army: queues combat units at the player's factories up to the army size the player
#   set; they wait at the factory's rally point and only fight back like any idle unit,
# - scouting: keeps one scout buggy driving to the least recently seen parts of the map,
#   holding fire and turning back from enemies,
# - constructor guard: remembers enemies any of the player's units has seen, and keeps
#   constructors away from them: it pulls them back when enemies come close, reroutes
#   them around enemies on their way, holds them back when the destination itself is
#   threatened (resuming the order once it is clear), and tells the player.
# It never spends below what the player keeps in the bank per commodity, and it never
# orders an attack: it does not start wars and leaves pacts and alliances alone.
# A match whose rules turn AI assist off (MatchRules, "Raw") never lets it switch on.

signal alerted(text)
signal alert_raised(kind)  # the same alert by kind ("on", "retreat", ...), for the advisor voice

const Worker = preload("res://source/match/units/Worker.gd")
const HelperScoutMap = preload("res://source/match/players/human/HelperScoutMap.gd")
const MatchLimits = preload("res://source/match/MatchLimits.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const CommandCenter = preload("res://source/match/units/CommandCenter.gd")
const AutoExpand = preload("res://source/match/units/traits/AutoExpand.gd")
const Constructing = preload("res://source/match/units/actions/Constructing.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")
const GameData = preload("res://source/data-model/GameData.gd")
const MatchRules = preload("res://source/data-model/MatchRules.gd")

const NODE_NAME = "Helper"
const WORKER_SCENE = "res://source/match/units/Worker.tscn"
const SCOUT_UNIT_ID = "scout_buggy"
const ARMY_FACTORY_ID = "vehicle_factory"
const DEFAULT_KEEP = 10
const DEFAULT_ARMY_TARGET = 8
const DEFAULT_CONSTRUCTORS = 3
const THINK_INTERVAL_S = 1.0
const GUARD_INTERVAL_S = 0.5
const THREAT_MEMORY_S = 45.0  # moving enemies are forgotten when nobody sees them for this long
# an enemy is dangerous within its sight or weapon range (whichever is longer) plus this
# margin; the checks below add their own extra distance on top
const DANGER_MARGIN_M = 4.0
const DESTINATION_EXTRA_M = 4.0  # constructors are not sent this close to a known enemy
const FLEE_EXTRA_M = 0.0  # enemies this close make a constructor run
# a route passing this close gets a detour; above FLEE_EXTRA_M so a route judged clear
# never leads into a retreat
const PATH_EXTRA_M = 2.5
const SCOUT_EXTRA_M = 3.0
const BLOCKED_SITE_S = 20.0  # a destination nobody can reach safely is left alone this long
const PATH_SAMPLE_M = 2.0
const PATH_CHECK_INTERVAL_S = 2.0
const RESUME_AFTER_CLEAR_S = 6.0
const DETOUR_MAX_S = 40.0  # a waypoint not reached by then is given up on
const WAYPOINT_REACHED_M = 3.0
const SCOUT_CELL_M = 20.0
const SCOUT_AVOID_S = 90.0
const ALERT_COOLDOWN_S = 12.0
const MAX_ALERTS = 4

var enabled = false:
	set = set_enabled
var keep = {}  # commodity -> amount the helper never spends below
var army_target = DEFAULT_ARMY_TARGET
var constructors_target = DEFAULT_CONSTRUCTORS
var scouting = true
var alerts = []  # newest first: {"text", "t"}
var events = []  # last guard decisions, oldest first, for tests and bug reports
var stats = {
	"retreats": 0,
	"detours": 0,
	"holds": 0,
	"resumed": 0,
	"units_ordered": 0,
	"constructors_ordered": 0,
	"trains_ordered": 0,
	"trucks_recycled": 0,
	"attack_orders": 0,  # stays 0: nothing in here orders an attack
	"think_usec_total": 0,
	"thinks": 0,
}

var _clock_s = 0.0
var _since_think_s = THINK_INTERVAL_S
var _since_guard_s = GUARD_INTERVAL_S
var _threats = {}  # enemy unit -> {"position", "seen_s", "static"}
var _guards = {}  # constructor -> {"kind", "action", "resume", "since_s", ...}
var _path_checked_s = {}  # constructor -> clock of its last path check
var _scout = null
var _scout_pending = false
var _scout_map = HelperScoutMap.new(SCOUT_CELL_M)  # where the scout has been
var _scout_target = null
var _alert_times = {}  # alert key -> clock
var _blocked = []  # [position, until clock] of destinations held back for a blocked route
var _status = {"economy": "", "army": "", "scout": "", "guard": ""}
var _mine = []  # own units, gathered once per tick
var _others = []  # everybody else's units, same tick

@onready var _player = get_parent()


class _Eyes:
	# the player's units and buildings that can see, bucketed on a grid so that "does
	# anyone see this spot" checks a few cells instead of every unit
	const CELL_M = 16.0
	var _cells = {}  # Vector2i -> [[position, sight range], ...]

	func _init(units):
		for unit in units:
			var sight = unit.sight_range
			if sight == null or sight <= 0.0:
				continue
			var position = unit.global_position_yless
			var low = _cell(position - Vector3(sight, 0, sight))
			var high = _cell(position + Vector3(sight, 0, sight))
			for x in range(low.x, high.x + 1):
				for z in range(low.y, high.y + 1):
					var key = Vector2i(x, z)
					if not key in _cells:
						_cells[key] = []
					_cells[key].append([position, sight])

	func sees(position):
		for eye in _cells.get(_cell(position), []):
			if eye[0].distance_to(position) <= eye[1]:
				return true
		return false

	static func _cell(position):
		return Vector2i(floori(position.x / CELL_M), floori(position.z / CELL_M))


static func of(player):
	if player == null or not is_instance_valid(player):
		return null
	return player.get_node_or_null(NODE_NAME)


static func active_for(player):
	"""the player's helper when it is switched on, else null"""
	var helper = of(player)
	return helper if helper != null and helper.enabled else null


func _ready():
	for resource in Constants.Match.Resources.ALL:
		keep[resource] = DEFAULT_KEEP
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)


func set_enabled(value):
	if enabled == value:
		return
	if value and not allowed():
		return  # the match's rules have AI assist off
	enabled = value
	if not is_inside_tree():
		return
	if enabled:
		_since_think_s = THINK_INTERVAL_S
		_since_guard_s = GUARD_INTERVAL_S
		_say("HELPER_ALERT_ON", "on")
	else:
		_hand_back()


func allowed():
	"""whether this match's rules let the helper run at all"""
	return MatchRules.ai_assist_on(self)


func keep_of(resource):
	return int(keep.get(resource, DEFAULT_KEEP))


func status_lines():
	if not enabled:
		return [tr("HELPER_STATUS_OFF")]
	var lines = []
	for key in ["guard", "economy", "army", "scout"]:
		if _status[key] != "":
			lines.append(_status[key])
	return lines


func known_threats():
	return _threats.size()


func is_dangerous(position, extra = DESTINATION_EXTRA_M):
	return _threat_near(position, extra) != null


func is_unsafe(position):
	"""for auto-expand: dangerous, or a spot the helper just found no safe route to"""
	if is_dangerous(position):
		return true
	var spot = position * Vector3(1, 0, 1)
	for entry in _blocked:
		if entry[1] > _clock_s and entry[0].distance_to(spot) < 3.0:
			return true
	return false


func wanted_structure():
	"""scene path auto-expand should build for the army, or null"""
	if not enabled or army_target <= 0:
		return null
	var entry = GameData.unit_by_id(ARMY_FACTORY_ID)
	if entry == null or not _player.meets_tier_requirement(entry["scene"]):
		return null
	var have = _own(func(unit): return unit is Structure and unit._scene_path() == entry["scene"])
	return entry["scene"] if have.is_empty() else null


func spare(cost):
	"""whether the bank covers 'cost' and still keeps what the player wants kept"""
	for resource in cost:
		if int(_player.get(resource)) - int(cost[resource]) < keep_of(resource):
			return false
	return true


func _process(delta):
	if not enabled or not _player.is_inside_tree() or _match() == null:
		return
	if not allowed():
		enabled = false  # switched on behind the rules' back (e.g. before the match began)
		return
	_clock_s += delta
	_since_think_s += delta
	_since_guard_s += delta
	if _since_guard_s >= GUARD_INTERVAL_S:
		_since_guard_s = 0.0
		var started = Time.get_ticks_usec()
		_gather_units()
		_scan_threats()
		_guard_constructors()
		_steer_scout()
		stats["think_usec_total"] += Time.get_ticks_usec() - started
		stats["thinks"] += 1
	if _since_think_s >= THINK_INTERVAL_S:
		_since_think_s = 0.0
		var started = Time.get_ticks_usec()
		_gather_units()
		_manage_economy()
		_manage_army()
		_manage_scout()
		stats["think_usec_total"] += Time.get_ticks_usec() - started


# --- threats


func _is_hostile(other):
	"""factions that may hit us: at war, or neutral and willing to start one; never pacts
	or allies"""
	if other == null or other == _player or not Diplomacy.can_attack(other, _player):
		return false
	if Diplomacy.at_war(other, _player):
		return true
	return not other.has_method("wants_to_attack") or other.wants_to_attack(_player)


func _gather_units():
	_mine = []
	_others = []
	for unit in get_tree().get_nodes_in_group("units"):
		if unit.player == _player:
			_mine.append(unit)
		else:
			_others.append(unit)


func _scan_threats():
	"""an enemy is known once any of our units or buildings sees it; it is remembered
	where it was last seen until someone sees that spot empty or memory runs out"""
	var eyes = _Eyes.new(_mine)
	var hostiles = []
	var hostility = {}
	for unit in _others:
		if unit.attack_damage == null:
			continue
		if not unit.player in hostility:
			hostility[unit.player] = _is_hostile(unit.player)
		if not hostility[unit.player]:
			continue
		if unit is Structure and not unit.is_constructed():
			continue
		hostiles.append(unit)
	var seen = {}
	for enemy in hostiles:
		var position = enemy.global_position_yless
		if eyes.sees(position):
			seen[enemy] = true
			_threats[enemy] = {
				"position": position,
				"seen_s": _clock_s,
				"static": enemy.movement_speed <= 0.0,
				"danger": _danger_radius_of(enemy),
			}
	for enemy in _threats.keys():
		if enemy in seen:
			continue
		var record = _threats[enemy]
		if not is_instance_valid(enemy) or not enemy.is_inside_tree():
			_threats.erase(enemy)
			continue
		if not hostility.get(enemy.player, _is_hostile(enemy.player)):
			_threats.erase(enemy)  # a treaty was signed
			continue
		if not record["static"] and _clock_s - record["seen_s"] > THREAT_MEMORY_S:
			_threats.erase(enemy)
			continue
		if eyes.sees(record["position"]):
			_threats.erase(enemy)  # we look at the spot and it is gone


static func _danger_radius_of(enemy):
	var sight = float(enemy.sight_range if enemy.sight_range != null else 0.0)
	var weapon = float(enemy.attack_range if enemy.attack_range != null else 0.0)
	return max(sight, weapon) + DANGER_MARGIN_M


func _threat_near(position, extra):
	"""[distance, position, enemy, danger radius] of the closest threat whose danger
	radius plus 'extra' covers 'position', or null"""
	var spot = position * Vector3(1, 0, 1)
	var best = null
	for enemy in _threats:
		var record = _threats[enemy]
		var distance = record["position"].distance_to(spot)
		if distance <= record["danger"] + extra and (best == null or distance < best[0]):
			best = [distance, record["position"], enemy, record["danger"]]
	return best


func _threats_around(position, extra):
	var spot = position * Vector3(1, 0, 1)
	var count = 0
	for enemy in _threats:
		var record = _threats[enemy]
		if record["position"].distance_to(spot) <= record["danger"] + extra:
			count += 1
	return count


# --- constructor guard


func _guard_constructors():
	var held = 0
	_blocked = _blocked.filter(func(entry): return entry[1] > _clock_s)
	for constructor in _guards.keys():
		if not is_instance_valid(constructor) or not constructor.is_inside_tree():
			_guards.erase(constructor)
			_path_checked_s.erase(constructor)
	for constructor in _own(func(unit): return unit is Worker):
		var guard = _guards.get(constructor)
		if (
			guard != null
			and guard["kind"] == "detour"
			and constructor.action == guard["action"]
			and (
				(
					constructor.global_position_yless.distance_to(guard["waypoint"])
					< WAYPOINT_REACHED_M
				)
				or _clock_s - guard["since_s"] > DETOUR_MAX_S
			)
		):
			_resume(constructor, guard)  # close enough: movement may not report arrival
			continue
		if guard != null and constructor.action != guard["action"]:
			var ours_running = guard["action"] != null and is_instance_valid(guard["action"])
			if ours_running or constructor.action != null:
				# a new order from the player (or auto-expand) wins over ours
				_guards.erase(constructor)
				guard = null
			elif guard["kind"] == "detour":
				_resume(constructor, guard)  # reached the waypoint
				continue
		var close = _threat_near(constructor.global_position, FLEE_EXTRA_M)
		if close != null:
			_retreat(constructor, close)
			held += 1
			continue
		if guard != null:
			held += 1
			if guard["kind"] != "detour":
				_maybe_resume(constructor, guard)
			continue
		_check_order(constructor)
	_status["guard"] = (
		tr("HELPER_STATUS_GUARD").format([held, _threats.size()])
		if held > 0 or not _threats.is_empty()
		else tr("HELPER_STATUS_GUARD_CLEAR")
	)


func _check_order(constructor):
	var destination = _destination_of(constructor.action)
	if destination == null:
		return
	if is_dangerous(destination):
		_hold(constructor, destination)
		return
	if _clock_s - _path_checked_s.get(constructor, -INF) < PATH_CHECK_INTERVAL_S:
		return
	_path_checked_s[constructor] = _clock_s
	var blocker = _first_threat_on_path(constructor.global_position, destination)
	if blocker == null:
		return
	var waypoint = _detour(constructor.global_position, destination, blocker)
	if waypoint == null:
		_blocked.append([destination * Vector3(1, 0, 1), _clock_s + BLOCKED_SITE_S])
		_hold(constructor, destination, blocker[1])
		return
	var resume = _resume_order_of(constructor.action)
	var action = Moving.new(waypoint)
	constructor.action = action
	_guards[constructor] = {
		"kind": "detour",
		"action": action,
		"resume": resume,
		"since_s": _clock_s,
		"waypoint": waypoint * Vector3(1, 0, 1),
	}
	stats["detours"] += 1
	_log("detour", constructor, waypoint)
	_say(
		"HELPER_ALERT_DETOUR",
		"detour",
		[_threats_around(blocker[1], DESTINATION_EXTRA_M)],
		blocker[1]
	)


func _retreat(constructor, threat):
	var guard = _guards.get(constructor)
	if guard != null and guard["kind"] == "retreat":
		if constructor.action == guard["action"] and constructor.action != null:
			return  # already running
	var resume = guard["resume"] if guard != null else _resume_order_of(constructor.action)
	var away = _safe_spot_for(constructor.global_position, threat[1])
	var action = Moving.new(away)
	constructor.action = action
	_guards[constructor] = {
		"kind": "retreat",
		"action": action,
		"resume": resume,
		"since_s": _clock_s,
		"destination": _destination_from_resume(resume),
	}
	stats["retreats"] += 1
	_log("retreat", constructor, threat[1])
	_say(
		"HELPER_ALERT_RETREAT",
		"retreat",
		[_threats_around(threat[1], DESTINATION_EXTRA_M)],
		threat[1]
	)


func _hold(constructor, destination, danger = null):
	"""'danger': where the enemies are, when that is not at the destination itself"""
	var resume = _resume_order_of(constructor.action)
	var spot = _safe_spot_for(constructor.global_position, destination)
	var action = (
		Moving.new(spot)
		if (
			constructor.global_position_yless.distance_to(spot) > 4.0
			and is_dangerous(constructor.global_position, DESTINATION_EXTRA_M + 8.0)
		)
		else null
	)
	constructor.action = action
	_guards[constructor] = {
		"kind": "hold",
		"action": action,
		"resume": resume,
		"since_s": _clock_s,
		"destination": destination,
	}
	stats["holds"] += 1
	_log("hold", constructor, destination)
	if danger == null:
		_say(
			"HELPER_ALERT_HOLD",
			"hold",
			[_threats_around(destination, DESTINATION_EXTRA_M)],
			destination
		)
	else:
		_say("HELPER_ALERT_BLOCKED", "hold", [_threats_around(danger, DESTINATION_EXTRA_M)], danger)


func _maybe_resume(constructor, guard):
	"""picks the order up again once its destination has been clear for a while"""
	var destination = guard.get("destination")
	if destination != null and is_dangerous(destination):
		guard["since_s"] = _clock_s
		return
	if _clock_s - guard["since_s"] < RESUME_AFTER_CLEAR_S:
		return
	if guard["action"] != null and is_instance_valid(guard["action"]):
		return  # still pulling back
	_resume(constructor, guard)


func _resume(constructor, guard):
	_guards.erase(constructor)
	_path_checked_s.erase(constructor)
	var resume = guard["resume"]
	if resume == null:
		return
	if resume["kind"] == "construct":
		var site = resume["site"]
		if is_instance_valid(site) and site.is_inside_tree() and site.is_under_construction():
			constructor.action = Constructing.new(site)
			stats["resumed"] += 1
	elif resume["kind"] == "move":
		constructor.action = Moving.new(resume["position"])
		stats["resumed"] += 1


func _destination_of(action):
	if action == null or not is_instance_valid(action):
		return null
	if action is Constructing:
		var site = action.get("_target_unit")
		return site.global_position_yless if is_instance_valid(site) else null
	if action is Moving:
		return action.get("_target_position")
	return null


func _resume_order_of(action):
	if action == null or not is_instance_valid(action):
		return null
	if action is Constructing:
		return {"kind": "construct", "site": action.get("_target_unit")}
	if action is Moving and action.get("_target_position") != null:
		return {"kind": "move", "position": action.get("_target_position")}
	return null


func _destination_from_resume(resume):
	if resume == null:
		return null
	if resume["kind"] == "construct":
		return resume["site"].global_position_yless if is_instance_valid(resume["site"]) else null
	return resume["position"]


func _first_threat_on_path(from, to):
	var path = NavigationServer3D.map_get_path(_terrain_map(), from, to, true)
	if path.is_empty():
		path = PackedVector3Array([from, to])
	for index in range(path.size() - 1):
		var a = path[index]
		var b = path[index + 1]
		var steps = max(1, int(a.distance_to(b) / PATH_SAMPLE_M))
		for step in range(steps + 1):
			var threat = _threat_near(a.lerp(b, float(step) / steps), PATH_EXTRA_M)
			if threat != null:
				return threat
	return null


func _detour(from, to, blocker):
	"""a waypoint around the group of enemies from which both legs are clear, shortest
	first, or null"""
	var center = Vector3.ZERO
	var group = []
	for enemy in _threats:
		if _threats[enemy]["position"].distance_to(blocker[1]) <= blocker[3]:
			group.append(_threats[enemy])
			center += _threats[enemy]["position"]
	center /= max(group.size(), 1)
	var spread = 0.0
	for record in group:
		spread = max(spread, record["position"].distance_to(center) + record["danger"])
	var candidates = []
	for distance in [spread + PATH_EXTRA_M + 3.0, spread + 9.0, spread + 16.0]:
		for step in range(12):
			var angle = TAU * step / 12.0
			var point = NavigationServer3D.map_get_closest_point(
				_terrain_map(), center + Vector3(cos(angle), 0, sin(angle)) * distance
			)
			candidates.append(point * Vector3(1, 0, 1))
	candidates.sort_custom(
		func(a, b):
			return from.distance_to(a) + a.distance_to(to) < from.distance_to(b) + b.distance_to(to)
	)
	var rejected = {"off map": 0, "in danger": 0, "first leg": 0, "second leg": 0}
	for point in candidates:
		if not _on_map(point):
			rejected["off map"] += 1
		elif is_dangerous(point, PATH_EXTRA_M + 1.0):
			rejected["in danger"] += 1
		elif _first_threat_on_path(from, point) != null:
			rejected["first leg"] += 1
		elif _first_threat_on_path(point, to) != null:
			rejected["second leg"] += 1
		else:
			return point
	events.append("%.1f no detour around %s: %s" % [_clock_s, center.round(), rejected])
	return null


func _safe_spot_for(position, danger):
	var depot = _closest_safe_depot(position)
	if depot != null:
		return depot.global_position_yless + Vector3(2, 0, 2)
	var away = ((position - danger) * Vector3(1, 0, 1)).normalized()
	if away == Vector3.ZERO:
		away = Vector3(1, 0, 0)
	return NavigationServer3D.map_get_closest_point(_terrain_map(), position + away * 20.0)


func _closest_safe_depot(position):
	var best = null
	for depot in _own(func(unit): return unit is CommandCenter and unit.is_constructed()):
		if is_dangerous(depot.global_position):
			continue
		var distance = depot.global_position_yless.distance_to(position * Vector3(1, 0, 1))
		if best == null or distance < best[0]:
			best = [distance, depot]
	return best[1] if best != null else null


# --- economy


func _manage_economy():
	var constructors = _own(func(unit): return unit is Worker)
	var on_auto = 0
	for constructor in constructors:
		if AutoExpand.is_enabled_on(constructor):
			on_auto += 1
			continue
		if constructor.get_meta("auto_expand_opt_out", false) or constructor in _guards:
			continue
		if constructor.action == null:
			AutoExpand.set_enabled_on(constructor, true)
			if AutoExpand.is_enabled_on(constructor):  # not when the rules have auto-build off
				constructor.set_meta("helper_auto", true)
				on_auto += 1
	if constructors.size() < constructors_target and _queued(WORKER_SCENE) == 0:
		if _produce_somewhere(WORKER_SCENE, func(unit): return unit is CommandCenter):
			stats["constructors_ordered"] += 1
	_status["economy"] = tr("HELPER_STATUS_ECONOMY").format([on_auto, constructors.size()])
	_manage_fleet()


func _manage_fleet():
	"""a freight train when far extractors call for one, and idle trucks recycled"""
	var logistics = _player.logistics
	var train = GameData.unit_by_id("train")
	if logistics == null or train == null:
		return
	var trains = _own(func(unit): return unit.get("is_train") == true).size()
	if logistics.rails.wants_train() and _queued(train["scene"]) == 0 and trains < 2:
		if _produce_somewhere(train["scene"], func(unit): return unit is CommandCenter):
			stats["trains_ordered"] += 1
	if logistics.fleet.surplus_trucks > 0:
		stats["trucks_recycled"] += logistics.fleet.recycle_surplus(1)


# --- army


func _is_soldier(unit):
	return (
		unit.player == _player
		and unit.attack_damage != null
		and unit.movement_speed > 0.0
		and not unit is Worker
		and not unit is Hauler
		and unit != _scout
		and not unit.get_meta("helper_scout", false)
	)


func _manage_army():
	var soldiers = _own(_is_soldier).size()
	var queued = 0
	for factory in _factories():
		for element in factory.production_queue.get_elements():
			var path = element.unit_prototype.resource_path
			if _is_combat_entry(GameData.unit_by_scene(path)) and not _is_scout_scene(path):
				queued += 1
	var total = soldiers + queued
	if army_target <= 0:
		_status["army"] = tr("HELPER_STATUS_ARMY_OFF").format([soldiers])
		return
	if total >= army_target:
		_status["army"] = tr("HELPER_STATUS_ARMY_FULL").format([soldiers, army_target])
		return
	var factories = _factories()
	if factories.is_empty():
		_status["army"] = tr("HELPER_STATUS_ARMY_NO_FACTORY").format([soldiers, army_target])
		return
	var limits = MatchLimits.of(get_tree())
	if limits != null and limits.slots_used(_player) >= limits.slots_cap():
		_status["army"] = tr("HELPER_STATUS_ARMY_CAP").format(
			[soldiers, limits.slots_used(_player), limits.slots_cap()]
		)
		return
	for factory in factories:
		if total >= army_target:
			break
		if factory.production_queue.size() >= 2:
			continue
		var choice = _best_unit_for(factory)
		if choice == null:
			continue
		if factory.production_queue.produce(load(choice)) != null:
			total += 1
			stats["units_ordered"] += 1
	_status["army"] = tr("HELPER_STATUS_ARMY").format([soldiers, total - soldiers, army_target])


func _factories():
	return _own(
		func(unit):
			return (
				unit is Structure
				and unit.is_constructed()
				and not unit is CommandCenter
				and unit.get("production_queue") != null
			)
	)


func _best_unit_for(factory):
	"""the strongest unlocked combat unit the bank can spare, by cost"""
	var producer = GameData.unit_by_scene(factory._scene_path())
	if producer == null:
		return null
	var best = null
	for entry in GameData.producible_by(producer["id"]):
		if not _is_combat_entry(entry) or entry["id"] == SCOUT_UNIT_ID:
			continue
		if not _player.can_produce(entry["scene"]):
			continue
		var limits = MatchLimits.of(get_tree())
		if limits != null and not limits.has_room_for(_player, entry["scene"]):
			continue  # a smaller unit may still fit under the unit cap
		var cost = Constants.Match.Units.PRODUCTION_COSTS.get(entry["scene"], {})
		if not spare(cost):
			continue
		var worth = Utils.Dict.sum(cost)
		if best == null or worth > best[0]:
			best = [worth, entry["scene"]]
	return best[1] if best != null else null


static func _is_combat_entry(entry):
	return (
		entry != null
		and entry.get("category", "unit") == "unit"
		and entry.get("properties", {}).get("attack_damage") != null
		and entry["id"] != "hauler"
		and entry["id"] != "caravan"
	)


# --- scouting


func _manage_scout():
	if not scouting:
		_release_scout()
		_status["scout"] = tr("HELPER_STATUS_SCOUT_OFF")
		return
	if _scout != null and not is_instance_valid(_scout):
		_scout = null
	if _scout == null:
		var spare_scouts = _own(func(unit): return unit.get_meta("helper_scout", false))
		if not spare_scouts.is_empty():
			_take_scout(spare_scouts[0])
	if _scout == null:
		var scene = _scout_scene()
		if scene != null and not _scout_pending and _queued(scene) == 0:
			var cost = Constants.Match.Units.PRODUCTION_COSTS.get(scene, {})
			if spare(cost) and _produce_somewhere(scene, func(unit): return unit in _factories()):
				_scout_pending = true
		_status["scout"] = tr("HELPER_STATUS_SCOUT_WAITING")
		return
	_status["scout"] = tr("HELPER_STATUS_SCOUT").format(
		[int(round(_scout_map.seen_share(_match().map.size) * 100.0))]
	)


func _steer_scout():
	if _scout == null or not is_instance_valid(_scout) or not scouting:
		return
	_scout_map.mark_seen(
		_scout.global_position,
		max(_scout.sight_range, SCOUT_CELL_M * 0.6),
		_match().map.size,
		_clock_s
	)
	var danger = _threat_near(_scout.global_position, SCOUT_EXTRA_M)
	if danger != null:
		_scout_map.avoid(danger[1], _clock_s + SCOUT_AVOID_S)
		if _scout_target == null or _scout_target.distance_to(danger[1]) < danger[3] * 2.0:
			_scout_target = _safe_spot_for(_scout.global_position, danger[1])
			_scout.action = Moving.new(_scout_target)
		return
	var moving = _scout.action is Moving and is_instance_valid(_scout.action)
	if moving and _scout_target != null and not is_dangerous(_scout_target, SCOUT_EXTRA_M):
		return
	if (
		_scout_target != null
		and (not moving or _scout_target.distance_to(_scout.global_position_yless) < 6.0)
	):
		# as close as it gets to that cell (a cell out at sea ends the move on the shore)
		_scout_map.mark_cell(_scout_target, _clock_s)
	_scout_target = _next_scout_target()
	if _scout_target != null:
		_scout.action = Moving.new(_scout_target)


func _next_scout_target():
	var best = _scout_map.next_target(
		_match().map.size,
		_scout.global_position_yless,
		_clock_s,
		func(center): return is_dangerous(center, SCOUT_EXTRA_M + 4.0)
	)
	if best == null:
		return null
	return NavigationServer3D.map_get_closest_point(_terrain_map(), best)


func _scout_scene():
	var entry = GameData.unit_by_id(SCOUT_UNIT_ID)
	if entry != null and _player.can_produce(entry["scene"]):
		return entry["scene"]
	return null


func _is_scout_scene(path):
	var entry = GameData.unit_by_id(SCOUT_UNIT_ID)
	return entry != null and entry["scene"] == path


func _take_scout(unit):
	_scout = unit
	_scout_pending = false
	unit.set_meta("helper_scout", true)
	unit.set_meta("hold_fire", true)  # see WaitingForTargets: a scout looks, it does not fight
	_scout_target = null


func _release_scout():
	if _scout != null and is_instance_valid(_scout):
		_scout.remove_meta("hold_fire")
		_scout.remove_meta("helper_scout")
		if _scout.action is Moving:
			_scout.action = null
	_scout = null
	_scout_pending = false


# --- handing control back


func _hand_back():
	_gather_units()
	for constructor in _own(func(unit): return unit is Worker):
		if constructor.get_meta("helper_auto", false):
			constructor.remove_meta("helper_auto")
			if AutoExpand.is_enabled_on(constructor):
				AutoExpand.set_enabled_on(constructor, false)
	for constructor in _guards:
		if is_instance_valid(constructor) and constructor.action == _guards[constructor]["action"]:
			_resume(constructor, _guards[constructor].duplicate())
	_guards.clear()
	_release_scout()
	_say("HELPER_ALERT_OFF", "off")


# --- helpers


func _produce_somewhere(scene_path, producer_filter):
	var cost = Constants.Match.Units.PRODUCTION_COSTS.get(scene_path, {})
	if not spare(cost) or not _player.can_produce(scene_path):
		return false
	for producer in _own(
		func(unit):
			return (
				producer_filter.call(unit)
				and unit is Structure
				and unit.is_constructed()
				and unit.get("production_queue") != null
			)
	):
		if not _can_make(producer, scene_path):
			continue
		if producer.production_queue.size() >= 2:
			continue
		if producer.production_queue.produce(load(scene_path)) != null:
			return true
	return false


static func _can_make(producer, scene_path):
	var producer_entry = GameData.unit_by_scene(producer._scene_path())
	var entry = GameData.unit_by_scene(scene_path)
	return (
		producer_entry != null
		and entry != null
		and producer_entry["id"] in entry.get("produced_by", [])
	)


func _queued(scene_path):
	var count = 0
	for producer in _own(func(unit): return unit.get("production_queue") != null):
		for element in producer.production_queue.get_elements():
			if element.unit_prototype.resource_path == scene_path:
				count += 1
	return count


func _on_unit_production_finished(unit, _producer):
	if not enabled or not is_instance_valid(unit) or unit.player != _player:
		return
	if _scout_pending and _scout == null and _is_scout_scene(unit._scene_path()):
		_take_scout(unit)


func _say(key, kind, args = [], position = null):
	"""an alert in the helper panel and the hint bar, at most one per kind every few s"""
	if kind in _alert_times and _clock_s - _alert_times[kind] < ALERT_COOLDOWN_S:
		return
	_alert_times[kind] = _clock_s
	var text = tr(key).format(args)
	alerts.push_front({"text": text, "t": _clock_s, "position": position})
	if alerts.size() > MAX_ALERTS:
		alerts.resize(MAX_ALERTS)
	alerted.emit(text)
	alert_raised.emit(kind)


func _log(kind, unit, position):
	events.append(
		(
			"%.1f %s %s at %s -> %s"
			% [_clock_s, kind, unit.name, unit.global_position_yless.round(), position.round()]
		)
	)
	if events.size() > 60:
		events.pop_front()


func _own(filter):
	"""own units passing 'filter', from the latest tick's list"""
	if _mine.is_empty():
		_gather_units()
	return _mine.filter(
		func(unit): return is_instance_valid(unit) and unit.is_inside_tree() and filter.call(unit)
	)


func _on_map(position):
	var size = _match().map.size
	return position.x >= 0.0 and position.z >= 0.0 and position.x <= size.x and position.z <= size.y


func _match():
	return _player.find_parent("Match")


func _terrain_map():
	return _match().navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
