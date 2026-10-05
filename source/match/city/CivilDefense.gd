extends Node

# The city's own defense. It keeps a few defense posts (turrets) around the city core and a
# militia that drives out to fight anything hostile entering the city, then returns home.
# Both scale with population and are rebuilt from the city warehouse when lost. Posts and
# militia slow down during blackouts. When attackers outmatch the defense, the city calls
# for help (MatchSignals.city_threat_changed). Posts and militia are the faction's
# "ag_turret", "aa_turret" and "militia" roles (see Factions.gd), e.g. Foundry bunkers.

enum ThreatLevel { NONE, CONTAINED, OVERWHELMING }

const DefaultAntiGroundTurretScene = preload("res://source/match/units/AntiGroundTurret.tscn")
const DefaultAntiAirTurretScene = preload("res://source/match/units/AntiAirTurret.tscn")
const DefaultMilitiaScene = preload("res://source/match/units/Militia.tscn")
const Factions = preload("res://source/data-model/Factions.gd")
const Moving = preload("res://source/match/units/actions/Moving.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")

var threat_level = ThreatLevel.NONE
var threats = []

var _posts = []
var _militia = []
var _since_last_militia_s = 0.0
var _since_last_post_s = 0.0
var _initial_posts_placed = false
var _ag_post_scene = null
var _aa_post_scene = null
var _militia_scene = null

@onready var _city = get_parent()
@onready var _match = find_parent("Match")


func _ready():
	if not _match.is_node_ready():
		await _match.ready
	_ag_post_scene = _role_scene("ag_turret", DefaultAntiGroundTurretScene)
	_aa_post_scene = _role_scene("aa_turret", DefaultAntiAirTurretScene)
	_militia_scene = _role_scene("militia", DefaultMilitiaScene)
	var timer = Timer.new()
	timer.timeout.connect(_tick.bind(Constants.Match.CivilDefense.TICK_S))
	add_child(timer)
	timer.start(Constants.Match.CivilDefense.TICK_S)


func _role_scene(role, default_scene):
	var path = Factions.role_scene_of(_city.player, role)
	return load(path) if path != null else default_scene


func get_posts():
	_posts = _posts.filter(func(post): return is_instance_valid(post) and post.is_inside_tree())
	return _posts


func get_militia():
	_militia = _militia.filter(func(unit): return is_instance_valid(unit) and unit.is_inside_tree())
	return _militia


func expected_posts():
	var c = Constants.Match.CivilDefense
	var posts = c.POSTS_BASE + int(_city.population * c.POSTS_PER_POPULATION)
	return min(c.POSTS_MAX, posts)


func expected_militia():
	var c = Constants.Match.CivilDefense
	return min(c.MILITIA_MAX, c.MILITIA_BASE + int(_city.population * c.MILITIA_PER_POPULATION))


func get_defense_strength():
	return (
		Utils.Arr.sum(get_posts().map(_strength_of))
		+ Utils.Arr.sum(get_militia().map(_strength_of))
	)


func _tick(delta):
	var core = _city.get_core()
	if core == null:
		return
	if not _initial_posts_placed:
		_initial_posts_placed = true
		for _i in range(expected_posts()):
			_spawn_post(core, _ag_post_scene)
		for _i in range(expected_militia()):
			_spawn_militia(core)
	var power_factor = 0.5 + 0.5 * _city.power_ratio
	_since_last_militia_s += delta * power_factor
	_since_last_post_s += delta * power_factor
	_reinforce(core)
	_apply_blackout_to_posts(power_factor)
	_respond_to_threats(core)


func _reinforce(core):
	var c = Constants.Match.CivilDefense
	if (
		get_militia().size() < expected_militia()
		and _since_last_militia_s >= c.MILITIA_REINFORCEMENT_S
		and _city.take_from_warehouse(
			Constants.Match.Units.PRODUCTION_COSTS[_militia_scene.resource_path]
		)
	):
		_since_last_militia_s = 0.0
		_spawn_militia(core)
	if (
		get_posts().size() < expected_posts() + (1 if _city.tier >= 3 else 0)
		and _since_last_post_s >= c.POST_REBUILD_S
		and _city.take_from_warehouse(c.POST_COST)
	):
		_since_last_post_s = 0.0
		var has_aa_post = get_posts().any(func(post): return post.attack_domains.has(0))
		var scene = _aa_post_scene if _city.tier >= 3 and not has_aa_post else _ag_post_scene
		_spawn_post(core, scene)


func _apply_blackout_to_posts(power_factor):
	for post in get_posts():
		if post.attack_interval == null:
			continue
		if not post.has_meta("base_attack_interval"):
			post.set_meta("base_attack_interval", post.attack_interval)
		post.attack_interval = post.get_meta("base_attack_interval") / power_factor


func _respond_to_threats(core):
	var c = Constants.Match.CivilDefense
	threats = get_tree().get_nodes_in_group("units").filter(
		func(unit):
			return (
				unit.player != _city.player
				and AutoAttacking.Diplomacy.engages_on_sight(_city.player, unit.player)
				and unit.attack_damage != null
				and (
					unit.global_position_yless.distance_to(core.global_position_yless)
					<= c.THREAT_RADIUS_M
				)
			)
	)
	var threat_strength = Utils.Arr.sum(threats.map(_strength_of))
	var new_level = ThreatLevel.NONE
	if not threats.is_empty():
		new_level = (
			ThreatLevel.OVERWHELMING
			if threat_strength > get_defense_strength()
			else ThreatLevel.CONTAINED
		)
	if new_level != threat_level:
		threat_level = new_level
		MatchSignals.city_threat_changed.emit(_city.player, threat_level, core.global_position)
	for militia in get_militia():
		var targets = threats.filter(
			func(threat): return threat.movement_domain in militia.attack_domains
		)
		if not targets.is_empty():
			if not militia.action is AutoAttacking:
				targets.sort_custom(
					func(a, b):
						return (
							a.global_position_yless.distance_to(militia.global_position_yless)
							< b.global_position_yless.distance_to(militia.global_position_yless)
						)
				)
				militia.action = AutoAttacking.new(targets[0])
		elif (
			militia.home_position != null
			and not militia.action is Moving
			and (
				militia.global_position_yless.distance_to(militia.home_position)
				> c.POST_RING_RADIUS_M
			)
		):
			militia.action = Moving.new(militia.home_position)


func _spawn_post(core, scene):
	var post = scene.instantiate()
	var position = _find_spot_around(core, post.radius if "radius" in post else 0.6, 4.5)
	if position == null:
		post.free()
		return
	post.set_meta("spawn_constructed", true)
	post.add_to_group("city_defense")
	MatchSignals.setup_and_spawn_unit.emit(post, Transform3D(Basis(), position), _city.player)
	_posts.append(post)


func _spawn_militia(core):
	var militia = _militia_scene.instantiate()
	var position = _find_spot_around(core, 0.9, 3.0)
	if position == null:
		militia.free()
		return
	militia.home_position = position
	militia.add_to_group("city_defense")
	MatchSignals.setup_and_spawn_unit.emit(militia, Transform3D(Basis(), position), _city.player)
	militia.remove_from_group("controlled_units")
	_militia.append(militia)


func _find_spot_around(core, radius, distance_from_core_edge):
	var obstacles = (
		get_tree().get_nodes_in_group("units")
		+ get_tree().get_nodes_in_group("resource_units")
		+ get_tree().get_nodes_in_group("city_buildings")
	)
	var navigation_map_rid = _match.navigation.get_navigation_map_rid_by_domain(
		Constants.Match.Navigation.Domain.TERRAIN
	)
	var map_polygon = _match.map.get_topdown_polygon_2d()
	var distance = core.radius + radius + distance_from_core_edge
	var start_angle = randf() * TAU
	for ring in range(3):
		for step in range(12):
			var angle = start_angle + TAU * step / 12.0
			var position = (
				core.global_position_yless
				+ Vector3(cos(angle), 0, sin(angle)) * (distance + ring * 1.5)
			)
			if not Geometry2D.is_point_in_polygon(Vector2(position.x, position.z), map_polygon):
				continue
			if (
				Utils.Match.Unit.Placement.validate_agent_placement_position(
					position, radius, obstacles, navigation_map_rid
				)
				== Utils.Match.Unit.Placement.VALID
			):
				return position
	return null


static func _strength_of(unit):
	if unit.attack_damage == null or unit.attack_interval == null:
		return 0.0
	return unit.hp * unit.attack_damage / unit.attack_interval
