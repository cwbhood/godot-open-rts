extends SceneTree

# Prints how fair the start zones of every map are (see source/match/maps/FairStart.gd).
#
#   godot --headless --path . -s res://tools/check_fair_starts.gd [-- --map=<id>]
#
# For each map: one row per start zone with the distance to the nearest deposit of each
# commodity and the amount within 30 m and 60 m, then FAIR or the metrics that differ.
# Exits with code 1 when any map is unfair.


func _init():
	process_frame.connect(_run, CONNECT_ONE_SHOT)  # autoloads are ready by then


func _run():
	var GameData = load("res://source/data-model/GameData.gd")
	var FairStart = load("res://source/match/maps/FairStart.gd")
	var only = ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			only = arg.trim_prefix("--map=")
	var unfair = 0
	for entry in GameData.reload()["maps"]:
		if only != "" and entry["id"] != only:
			continue
		var map = load(entry["scene"]).instantiate()
		var kind_agnostic = entry.get("generator", {}).get("resource_layout") == "asymmetric"
		var zones = FairStart.measure(map, kind_agnostic)
		print(
			"\n== {0} ({1} players, {2}x{3} m, {4} start zones){5}".format(
				[
					entry["name"],
					entry["players"],
					map.size.x,
					map.size.y,
					zones.size(),
					" kinds ignored: asymmetric by design" if kind_agnostic else ""
				]
			)
		)
		if not zones.is_empty():
			var metrics = zones[0].keys()
			for metric in metrics:
				var row = "  %-34s" % metric
				for zone in zones:
					row += "%9.1f" % zone[metric]
				print(row)
		var problems = FairStart.problems(map, kind_agnostic)
		if problems.is_empty():
			print("  FAIR")
		else:
			unfair += 1
			for problem in problems:
				print("  UNFAIR: " + problem)
		map.free()
	quit(1 if unfair > 0 else 0)
