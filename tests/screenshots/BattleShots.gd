extends Node

# Stages every armed unit firing at a sturdy enemy and screenshots the fight through the game
# camera, to judge muzzle flashes, tracers, rockets and impacts at play zoom.
# Usage (needs a real renderer, e.g. under xvfb-run):
#   godot --path . res://tests/screenshots/BattleShots.tscn -- --out=/tmp/battle --size=15 \
#     --shots=10 --every=1 --time_scale=0.1 --volley
# Options: --shots (screenshots taken), --every (frames between them), --time_scale (slows the
# fight so short effects land on a frame), --volley (everyone fires at once as capturing
# starts), --warmup, --settle, --prefix, --at=x,z.

const GameData = preload("res://source/data-model/GameData.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const AutoAttacking = preload("res://source/match/units/actions/AutoAttacking.gd")
const AttackingWhileInRange = preload("res://source/match/units/actions/AttackingWhileInRange.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")

# [attacker id, target id]; each group is one row of the shot
const GROUPS = [
	[
		["militia", "heavy_tank"],
		["raider", "heavy_tank"],
		["scout_buggy", "heavy_tank"],
		["tank", "heavy_tank"],
		["heavy_tank", "heavy_tank"],
		["battle_tank", "heavy_tank"],
	],
	[
		["artillery", "heavy_tank"],
		["helicopter", "heavy_tank"],
		["gunship", "heavy_tank"],
		["ag_turret", "heavy_tank"],
		["missile_truck", "helicopter"],
		["aa_turret", "helicopter"],
	],
]
const COLUMN_SPACING = 3.2
const PAIR_DISTANCE = 3.6
const GROUP_SPACING = -8.0  # second row north of the first, away from the map edge

var _args = {}


func _ready():
	for arg in OS.get_cmdline_user_args():
		var parts = arg.trim_prefix("--").split("=", true, 1)
		_args[parts[0]] = parts[1] if parts.size() > 1 else ""
	var out_dir = _args.get("out", "user://battle")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var match_node = load("res://tests/manual/TestDesert.tscn").instantiate()
	match_node.settings.visibility = match_node.settings.Visibility.FULL
	add_child(match_node)
	await _frames(int(_args.get("warmup", "30")))
	for layer in match_node.find_children("*", "CanvasLayer", true, false):
		layer.visible = false
	var atmosphere = match_node.find_child("Atmosphere", true, false)
	if atmosphere != null:
		atmosphere.set_weather_immediately("clear")
	var players = get_tree().get_nodes_in_group("players")
	if Diplomacy.instance != null:
		Diplomacy.instance.declare_war(players[0], players[1])
	var centre = _parse_xz(_args.get("at", "31,32"))
	var group_centres = []
	var pairs = []
	for g in range(GROUPS.size()):
		group_centres.append(centre + Vector3(0, 0, g * GROUP_SPACING))
		_clear_area(group_centres[g], 12.0, players[0].get_node("Logistics").get_depots())
	await _frames(2)
	for g in range(GROUPS.size()):
		var group_centre = group_centres[g]
		var group = GROUPS[g]
		for i in range(group.size()):
			var x = (i - (group.size() - 1) / 2.0) * COLUMN_SPACING
			var attacker_at = group_centre + Vector3(x, 0, PAIR_DISTANCE / 2.0)
			var target_at = group_centre + Vector3(x, 0, -PAIR_DISTANCE / 2.0)
			var attacker = _spawn(group[i][0], attacker_at, target_at, players[0])
			var target = _spawn(group[i][1], target_at, attacker_at, players[1])
			pairs.append([attacker, target])
	await _frames(1)
	pairs = pairs.filter(
		func(pair): return is_instance_valid(pair[0]) and is_instance_valid(pair[1])
	)
	for pair in pairs:
		for unit in pair:
			unit.hp_max = 100000
			unit.hp = 100000
		# targets stand still and hold fire so the attackers stay in shot
		pair[1].process_mode = Node.PROCESS_MODE_DISABLED
		pair[0].action = (
			AutoAttacking.new(pair[1])
			if pair[0].movement_speed > 0.0
			else AttackingWhileInRange.new(pair[1])
		)
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(float(_args.get("size", "15")))
	var prefix = _args.get("prefix", "battle")
	camera.set_position_safely((group_centres[0] + group_centres[-1]) / 2.0)
	await _frames(int(_args.get("settle", "20")))
	Engine.time_scale = float(_args.get("time_scale", "0.25"))
	if "volley" in _args:
		_fire_volley(pairs)
	for shot in range(int(_args.get("shots", "6"))):
		await _frames(int(_args.get("every", "2")))
		var path = "{0}/{1}_{2}.png".format([out_dir, prefix, shot])
		get_viewport().get_texture().get_image().save_png(path)
		print("saved ", path)
	get_tree().quit()


func _fire_volley(pairs):
	"""every attacker fires once at the same moment, as AttackingWhileInRange would"""
	for pair in pairs:
		var scene_path = pair[0].get_script().resource_path.replace(".gd", ".tscn")
		var projectile = load(Constants.Match.Units.PROJECTILES[scene_path]).instantiate()
		projectile.target_unit = pair[1]
		pair[0].add_child(projectile)


func _spawn(id, position, facing_point, player):
	var entry = GameData.unit_by_id(id)
	var unit = load(entry["scene"]).instantiate()
	if unit is Structure:
		unit.set_meta("spawn_constructed", true)
	var transform = Transform3D(Basis(), position).looking_at(
		Vector3(facing_point.x, position.y, facing_point.z), Vector3.UP
	)
	MatchSignals.setup_and_spawn_unit.emit(unit, transform, player)
	return unit


func _parse_xz(text):
	var xz = text.split(",")
	return Vector3(float(xz[0]), 0, float(xz[1]))


func _clear_area(centre, radius, keep):
	for node in get_tree().get_nodes_in_group("units"):
		if node in keep:
			continue
		if node.global_position.distance_to(centre) < radius:
			node.queue_free()
	for node in get_tree().get_nodes_in_group("city_buildings"):
		if node.global_position.distance_to(centre) < radius:
			node.visible = false


func _frames(count):
	for i in range(count):
		await get_tree().process_frame
