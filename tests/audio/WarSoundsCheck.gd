extends Node

# Stages a small battle and checks that it is heard: weapon fire, impacts, explosions and
# tank engines. Usage (needs a real renderer, e.g. under xvfb-run):
#   godot --path . res://tests/audio/WarSoundsCheck.tscn
# Exits with 1 if a kind of sound never played.

const TankScene = preload("res://source/match/units/Tank.tscn")
const MilitiaScene = preload("res://source/match/units/Militia.tscn")
const ArtilleryScene = preload("res://source/match/units/Artillery.tscn")
const Moving = preload("res://source/match/units/actions/Moving.gd")


func _ready():
	var match_node = load("res://tests/manual/TestDesert.tscn").instantiate()
	add_child(match_node)
	await _frames(30)
	var players = get_tree().get_nodes_in_group("players")
	var front = Vector3(60.0, 0.0, 60.0)
	var armies = []
	for side in range(2):
		var army = []
		for i in range(8):
			var scene = [TankScene, TankScene, MilitiaScene, ArtilleryScene][i % 4]
			var unit = scene.instantiate()
			var offset = Vector3(
				(i % 4) * 2.5 - 4.0, 0.0, (side * 2 - 1) * (9.0 + int(i / 4.0) * 2.5)
			)
			MatchSignals.setup_and_spawn_unit.emit(
				unit, Transform3D(Basis(), front + offset), players[side]
			)
			army.append(unit)
		armies.append(army)
	await _frames(5)
	for army in armies:
		for unit in army:
			unit.action = Moving.new(front)  # drive in: engines, then auto-attack on arrival
	var camera = get_viewport().get_camera_3d()
	camera.set_size_safely(18.0)
	camera.set_position_safely(front)
	Engine.time_scale = 3.0
	Engine.max_physics_steps_per_frame = 32
	var war_sounds = match_node.find_child("WarSounds", true, false)
	var soundscape = match_node.find_child("Soundscape", true, false)
	var loudest_tank_engine = 0.0
	for i in range(400):
		await get_tree().process_frame
		loudest_tank_engine = max(loudest_tank_engine, soundscape._targets["tank_engine_loop"])
		if i % 50 == 49:
			print("frame ", i + 1, " ", war_sounds.played_counts)
	print("played: ", war_sounds.played_counts, " tank engine peak: ", loudest_tank_engine)
	var failures = 0
	for kind in ["cannon", "rifle", "rocket", "impact"]:
		if war_sounds.played_counts.get(kind, 0) == 0:
			print("FAIL: never heard ", kind)
			failures += 1
	if (
		not war_sounds.played_counts.has("explosion_small")
		and not war_sounds.played_counts.has("explosion_large")
	):
		print("FAIL: no explosion")
		failures += 1
	if loudest_tank_engine <= 0.0:
		print("FAIL: tank engines silent")
		failures += 1
	print("war sounds check: {0} failure(s)".format([failures]))
	get_tree().quit(1 if failures > 0 else 0)


func _frames(count):
	for i in range(count):
		await get_tree().process_frame
