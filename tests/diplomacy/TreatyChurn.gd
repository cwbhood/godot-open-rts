extends Node

# Freeze hunt: a full AI match with treaties signed, expired and broken by war over and over,
# in rain, printing each step before it happens so the last line names what hung.
#
#   godot --headless --path . res://tests/diplomacy/TreatyChurn.tscn -- --map=plain_and_simple \
#     --ai=turtle,balanced,raider,trader --minutes=12 --churn-from=120 --every=3

const MatchSettings = preload("res://source/data-model/MatchSettings.gd")
const PlayerSettings = preload("res://source/data-model/PlayerSettings.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")

var _args = {
	"map": "plain_and_simple",
	"ai": "turtle,balanced,raider,trader",
	"minutes": "12",
	"churn-from": "120",
	"every": "3",
	"weather": "rain",
	"speed": "1",
	"seed": "1",
}
var _match = null
var _elapsed_s = 0.0
var _next_churn_s = 0.0
var _next_beat_s = 0.0
var _rng = RandomNumberGenerator.new()
var _steps = 0


func _ready():
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--") and "=" in argument:
			var parts = argument.substr(2).split("=", true, 1)
			_args[parts[0]] = parts[1]
	_rng.seed = int(_args["seed"])
	seed(int(_args["seed"]))
	var map_path = null
	for path in Constants.Match.MAPS:
		if path.get_file().get_basename().to_snake_case() == _args["map"]:
			map_path = path
	assert(map_path != null, "unknown map " + _args["map"])
	preload("res://source/data-model/GameData.gd").register_generated_scenes()
	for scene_path in (
		Constants.Match.Units.PROJECTILES.values() + Constants.Match.Units.CONSTRUCTION_COSTS.keys()
	):
		Globals.cache[scene_path] = load(scene_path)
	var settings = MatchSettings.new()
	var personalities = _args["ai"].split(",")
	for index in range(min(personalities.size(), Constants.Match.MAPS[map_path]["players"])):
		var player_settings = PlayerSettings.new()
		player_settings.controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		player_settings.ai_personality = personalities[index]
		player_settings.color = Constants.Player.COLORS[index]
		settings.players.append(player_settings)
	settings.visibility = settings.Visibility.PER_PLAYER
	settings.visible_player = 0
	FeatureFlags.handle_match_end = false
	_match = load("res://source/match/Match.tscn").instantiate()
	_match.settings = settings
	_match.map = load(map_path).instantiate()
	get_tree().root.add_child.call_deferred(_match)
	MatchSignals.diplomacy_changed.connect(
		func(a, b, state): _say("event %s-%s -> %s" % [_n(a), _n(b), Diplomacy.State.keys()[state]])
	)
	Engine.time_scale = float(_args["speed"])
	_next_churn_s = float(_args["churn-from"])
	_say("start " + str(_args))


func _physics_process(delta):
	if _match == null or not _match.is_node_ready():
		return
	_elapsed_s += delta
	if _elapsed_s >= _next_beat_s:
		_next_beat_s += 10.0
		_say("beat units=%d" % get_tree().get_nodes_in_group("units").size())
	if _elapsed_s >= _next_churn_s:
		_next_churn_s += float(_args["every"])
		_churn()
	if _elapsed_s >= float(_args["minutes"]) * 60.0:
		_say("done steps=%d" % _steps)
		get_tree().quit()


func _churn():
	var atmosphere = get_tree().get_first_node_in_group("atmosphere")
	if atmosphere != null and atmosphere.get_weather() != StringName(_args["weather"]):
		_say("weather -> " + _args["weather"])
		atmosphere.set_weather_immediately(StringName(_args["weather"]))
	var diplomacy = Diplomacy.instance
	var players = get_tree().get_nodes_in_group("players")
	if diplomacy == null or players.size() < 2:
		return
	var a = players[_rng.randi() % players.size()]
	var b = players[_rng.randi() % players.size()]
	if a == b:
		return
	_steps += 1
	var roll = _rng.randi() % 4
	var state = Diplomacy.State.keys()[diplomacy.get_state(a, b)]
	if roll == 0:
		_say("DO pact %s-%s (was %s)" % [_n(a), _n(b), state])
		diplomacy.sign_treaty(a, b, Diplomacy.PACT)
	elif roll == 1 and diplomacy.can_sign(a, b, Diplomacy.ALLIANCE) == Diplomacy.Result.ACCEPTED:
		_say("DO alliance %s-%s (was %s)" % [_n(a), _n(b), state])
		diplomacy.sign_treaty(a, b, Diplomacy.ALLIANCE)
	elif roll == 2:
		_say("DO expire %s-%s (was %s)" % [_n(a), _n(b), state])
		var relation = diplomacy._relations.get(Diplomacy._key(a, b))
		if relation != null and relation["left_s"] > 0.0:
			relation["left_s"] = 0.001
	else:
		_say("DO war %s-%s (was %s)" % [_n(a), _n(b), state])
		diplomacy.declare_war(a, b)


func _n(player):
	return "P%d" % player.get_index() if is_instance_valid(player) else "P?"


func _say(text):
	print("CHURN t=%6.1f %s" % [_elapsed_s, text])
