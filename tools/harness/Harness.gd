extends Node

# The play harness: one tool to play and test Ironbound from a script.
#
#   godot --path . res://tools/harness/Harness.tscn -- --scenario=smoke
#   godot --path . res://tools/harness/Harness.tscn -- --batch=nightly
#   godot --path . res://tools/harness/Harness.tscn -- --stress=40
#   godot --path . res://tools/harness/Harness.tscn -- --serve=7777 [--scenario=sandbox]
#
# Or with ./play.sh / play.bat, which find Godot and pass these on. Everything is explained
# in docs/testing/play-harness.md. Options (after the "--"):
#
#   --scenario=NAME|PATH  a scenario JSON (names are looked up in tools/harness/scenarios/)
#   --batch=NAME|PATH     a batch JSON (tools/harness/batches/): many matches, one table
#   --stress=N            N against N units fighting, with frame-time budgets
#   --serve[=PORT]        keep the match running and take orders over TCP (default 7777)
#   --view=fast|window    fast: 3D off between screenshots (default in the cloud);
#                         window: draw every frame, for real GPU numbers on a PC
#   --speed=X             game speed (time scale), --seed=N, --minutes=M, --map=ID,
#   --ai=raider,turtle    AI opponents, --difficulty=hard, --helper=on
#   --shots-every=S       a screenshot every S game seconds
#   --out=DIR             where reports go (default harness-out/ in the project)
#   --baseline=FILE       batch: an earlier batch.json to find regressions against
#   --budget-frame-ms=X   fail when the 95th percentile frame time is above X ms
#   --budget-process-ms=X  the same for process time
#   --real-mouse=on       let the real mouse into the game too (the harness never moves it)
#   --window=1600x900     window size for --view=window
#
# Exit code 0 when everything passed, 1 when a check, budget or match failed.

const ScenarioRunner = preload("res://tools/harness/ScenarioRunner.gd")
const BatchRunner = preload("res://tools/harness/BatchRunner.gd")
const ApiServer = preload("res://tools/harness/ApiServer.gd")

const STRESS_MIX = ["tank", "raider", "militia", "artillery", "heavy_tank"]

var args = {}


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--"):
			var parts = argument.substr(2).split("=", true, 1)
			args[parts[0]] = parts[1] if parts.size() > 1 else "on"
	# a frozen match writes a crash report into --out and ends the run instead of hanging
	CrashReporter.set_hang_exit(float(args.get("hang-exit-s", "180")))
	# and a run that stops making progress without freezing ends too (real time, any speed)
	var limit_s = float(args.get("max-real-minutes", "90")) * 60.0
	get_tree().create_timer(limit_s, true, false, true).timeout.connect(
		func():
			print("HARNESS FAIL: still running after %.0f real minutes" % (limit_s / 60.0))
			get_tree().quit(3)
	)
	if args.has("batch"):
		await _run_batch()
	elif args.has("stress"):
		await _run_scenario(_stress_scenario(int(args["stress"])))
	elif args.has("scenario") or args.has("serve"):
		var scenario = ScenarioRunner.load_file(args.get("scenario", "sandbox"))
		if scenario == null:
			_quit(1)
			return
		await _run_scenario(scenario)
	else:
		print(
			(
				"play harness: give --scenario=NAME, --batch=NAME, --stress=N or --serve. "
				+ "See docs/testing/play-harness.md"
			)
		)
		_quit(2)


func _apply_overrides(scenario):
	scenario = scenario.duplicate(true)
	for key in ["map", "view"]:
		if args.has(key):
			scenario[key] = args[key]
	for key in ["speed", "minutes", "seed"]:
		if args.has(key):
			scenario[key] = float(args[key]) if key != "seed" else int(args[key])
	if args.has("shots-every"):
		scenario["shots_every"] = float(args["shots-every"])
	if args.has("ai") or args.has("difficulty") or args.has("helper"):
		var players = scenario.get("players", ScenarioRunner.DEFAULTS["players"]).duplicate(true)
		if args.has("ai"):
			players = players.filter(func(entry): return entry.get("type") == "human")
			for personality in args["ai"].split(","):
				players.append({"type": "ai", "personality": personality})
		for entry in players:
			if entry.get("type", "ai") == "human" and args.has("helper"):
				entry["helper"] = args["helper"] == "on"
			elif entry.get("type", "ai") != "human" and args.has("difficulty"):
				entry["difficulty"] = args["difficulty"]
		scenario["players"] = players
	var budgets = scenario.get("budgets", {}).duplicate()
	if args.has("budget-frame-ms"):
		budgets["frame_ms_p95"] = float(args["budget-frame-ms"])
	if args.has("budget-process-ms"):
		budgets["process_ms_p95"] = float(args["budget-process-ms"])
	scenario["budgets"] = budgets
	return scenario


func _out_dir(label):
	if args.has("out"):
		return args["out"]
	var root = ProjectSettings.globalize_path("res://").path_join("harness-out")
	DirAccess.make_dir_recursive_absolute(root)
	if not FileAccess.file_exists(root.path_join(".gdignore")):
		FileAccess.open(root.path_join(".gdignore"), FileAccess.WRITE).close()
	var stamp = Time.get_datetime_string_from_system().replace(":", "").replace("T", "-")
	return root.path_join("%s-%s" % [stamp, label.validate_filename().replace(" ", "_")])


func _setup_window(view):
	if view != "window" or DisplayServer.get_name() == "headless":
		return
	var size = Vector2i(1600, 900)
	if args.has("window") and "x" in args["window"]:
		var parts = args["window"].split("x")
		size = Vector2i(int(parts[0]), int(parts[1]))
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	DisplayServer.window_set_title("Ironbound play harness")


func _run_scenario(scenario):
	scenario = _apply_overrides(scenario)
	if args.has("serve") and not scenario.has("minutes"):
		scenario["minutes"] = 600.0
	var runner = ScenarioRunner.new()
	runner.scenario = scenario
	runner.out_dir = _out_dir(scenario.get("name", "run"))
	runner.real_mouse = args.get("real-mouse", "off") == "on"
	runner.keep_running = args.has("serve")
	add_child(runner)
	_setup_window(ScenarioRunner.normalized(scenario)["view"])
	if args.has("serve"):
		var server = ApiServer.new()
		server.api = runner.api
		server.port = int(args["serve"]) if args["serve"].is_valid_int() else 7777
		add_child(server)
	print("HARNESS out " + ProjectSettings.globalize_path(runner.out_dir))
	runner.run()
	var report = await runner.finished
	_quit(0 if report.get("verdict") == "pass" else 1)


func _run_batch():
	var path = args["batch"]
	var candidates = [path, "res://tools/harness/batches/" + path]
	if not path.ends_with(".json"):
		candidates.append("res://tools/harness/batches/" + path + ".json")
	var batch = null
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			batch = JSON.parse_string(FileAccess.get_file_as_string(candidate))
			break
	if not batch is Dictionary:
		print("HARNESS BATCH: no batch file at " + path)
		_quit(1)
		return
	OS.low_processor_usage_mode = true  # this process only waits for the matches it starts
	get_viewport().disable_3d = true
	var runner = BatchRunner.new()
	runner.batch = batch
	runner.out_dir = _out_dir("batch-" + str(batch.get("name", "batch")))
	runner.baseline_path = args.get("baseline", "")
	if args.has("parallel"):
		batch["parallel"] = int(args["parallel"])
	runner.forward_args = _engine_args_for_children()
	for key in ["view", "speed", "minutes", "budget-frame-ms", "budget-process-ms", "window"]:
		if args.has(key):
			runner.extra_user_args.append("--%s=%s" % [key, args[key]])
	add_child(runner)
	runner.run()
	var ok = await runner.finished
	_quit(0 if ok else 1)


func _engine_args_for_children():
	var forwarded = []
	var engine_args = OS.get_cmdline_args()
	for index in range(engine_args.size()):
		var argument = engine_args[index]
		if (
			argument
			in ["--rendering-driver", "--rendering-method", "--resolution", "--display-driver"]
		):
			if index + 1 < engine_args.size():
				forwarded.append_array([argument, engine_args[index + 1]])
	return forwarded


func _stress_scenario(count):
	"""count against count mixed units meeting in the middle of Big Arena"""
	var spawn = []
	var per_kind = int(ceil(float(count) / STRESS_MIX.size()))
	var left = count
	for index in range(STRESS_MIX.size()):
		var amount = min(per_kind, left)
		left -= amount
		if amount <= 0:
			break
		for side in [0, 1]:
			(
				spawn
				. append(
					{
						"do": "spawn",
						"player": "p%d" % side,
						"unit": STRESS_MIX[index],
						"count": amount,
						"at": [30 + side * 40, 30 + index * 9],
						"spacing": 2.2,
					}
				)
			)
	spawn.append({"do": "declare_war", "player": "p0", "on": "p1"})
	return {
		"name": "stress-%dv%d" % [count, count],
		"description":
		(
			(
				"%d against %d units (tanks, raiders, militia, artillery, heavy tanks) fight in the "
				+ "middle of Big Arena. Fails when frame or process time goes over budget."
			)
			% [count, count]
		),
		"map": "big_arena",
		"minutes": float(args.get("minutes", "2")),
		"fog": false,
		"players": [{"type": "human"}, {"type": "ai", "personality": "turtle"}],
		"sample_every": 2.0,
		"shots_every": 30.0,
		"setup": spawn,
		"events":
		[
			{"at": 2, "do": "fight", "units": "p0:combat", "to": [70, 50]},
			{"at": 2, "do": "fight", "units": "p1:combat", "to": [30, 50]},
		],
		"checks":
		[
			{"end": true, "expect": "no_errors"},
			{
				"at": 100,
				"name": "the armies met and fought",
				"expect": "timeline",
				"kind": "losses",
				"min": 1
			},
		],
		"budgets": {"frame_ms_p95": 50.0},
	}


func _quit(code):
	await get_tree().process_frame
	get_tree().quit(code)
