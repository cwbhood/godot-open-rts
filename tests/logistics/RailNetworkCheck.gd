extends SceneTree

# Checks the rail network's track planning without a match: a second stop near an
# existing line branches off it at a new junction instead of getting a parallel line of its
# own, a train on a leg that gets split carries on along the halves, and the trip through
# the junction is found.
#
#   godot --headless --path . -s res://tests/logistics/RailNetworkCheck.gd

var _failed = 0


class FakeStop:
	extends RefCounted
	var global_position = Vector3.ZERO
	var global_position_yless = Vector3.ZERO
	var radius = 1.0

	func _init(at):
		global_position = at
		global_position_yless = at


class FakeLogistics:
	extends Node
	var depots = []

	func get_depots():
		return depots


func _initialize():
	var RailNetwork = load("res://source/match/economy/RailNetwork.gd")
	var logistics = FakeLogistics.new()
	var depot = FakeStop.new(Vector3(0, 0, 0))
	logistics.depots = [depot]
	var stop_a = FakeStop.new(Vector3(40, 0, 0))
	var stop_b = FakeStop.new(Vector3(40, 0, 14))
	var rails = RailNetwork.new(logistics)

	var depot_node = rails.node_for_stop(depot, stop_a.global_position)
	var a_node = rails.node_for_stop(stop_a, depot.global_position)
	var to_a = rails.route(depot_node, a_node)
	_expect(to_a.size() == 1, "the first stop gets one leg of track (%d)" % to_a.size())
	var trunk = to_a[0][0]
	trunk["built_a"] = trunk["length"] * 0.5  # a train laid half of it so far
	_expect(rails.get_length_m(false) > 30.0, "the trunk is planned")

	var b_node = rails.node_for_stop(stop_b, depot.global_position)
	var planned_before = rails.get_length_m(false)
	var to_b = rails.route(depot_node, b_node)
	var junctions = rails.nodes.keys().filter(func(id): return not rails.nodes[id]["stop"])
	_expect(junctions.size() == 1, "the second stop branches off the trunk at a junction")
	var added = rails.get_length_m(false) - planned_before
	_expect(added < 20.0, "only the branch is new track (%.1f m)" % added)
	_expect(to_b.size() == 2, "the trip runs trunk then branch (%d legs)" % to_b.size())
	_expect("dead" in trunk, "the trunk was split at the junction")
	_expect(
		is_equal_approx(rails.get_length_m(), trunk["length"] * 0.5),
		"the built half of the trunk stays built (%.1f m)" % rails.get_length_m()
	)
	# a train that was 32 m down the old trunk is now on its second half
	var at = rails.resolve_position(trunk, false, 32.0)
	_expect(at[0] != trunk and not "dead" in at[0], "a train on the split leg moves to a half")
	_expect(
		absf(at[2] + trunk["dead"]["at"] - 32.0) < 0.01,
		"and keeps its place on the track (%.1f m into the half)" % at[2]
	)
	var back = rails.route(b_node, a_node)
	_expect(back.size() == 2, "from the branch to the first stop goes through the junction")
	print("RailNetworkCheck: %s" % ("PASS" if _failed == 0 else "%d FAILED" % _failed))
	logistics.free()
	quit(1 if _failed > 0 else 0)


func _expect(condition, text):
	print(("PASS " if condition else "FAIL ") + text)
	if not condition:
		_failed += 1
