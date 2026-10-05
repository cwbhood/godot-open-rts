extends Node

# The soundtrack (autoload). The menu theme plays on the menu screens; in a match the two calm
# tracks take turns, with a pause between them, until fighting breaks out around the
# player's units or buildings. Then the music crossfades to the tension loop, and to the battle
# loop once the fight keeps going. After about 20 s without a shot at or from the player it
# falls back to the calm tracks. Victory and defeat end the music with a short sting.
#
# Fighting is read from MatchSignals: unit_damaged (our unit hit, or a unit our side hit:
# Unit.last_attacker_player), unit_died with no hp left, and city_threat_changed for the
# player's city. Each hit adds to a "heat" that cools down over a few seconds.
#
# Music plays on the "Music" bus, which is added at runtime when the bus layout has none.
# With the Dummy audio driver (tests, CI, headless) the states still change and are logged,
# but no stream is decoded; pass --music to play anyway. The tracks come from
# tools/audio/make_music.py.

enum State { SILENT, MENU, CALM, TENSION, BATTLE, ENDED }

const MUSIC_DIR = "res://assets/audio/music/"
const TRACKS = {
	"menu": "menu_theme.ogg",
	"calm_1": "calm_dust_and_steel.ogg",
	"calm_2": "calm_caravan_road.ogg",
	"tension": "tension_heat_haze.ogg",
	"battle": "battle_iron_storm.ogg",
	"victory": "sting_victory.ogg",
	"defeat": "sting_defeat.ogg",
}
const CALM_TRACKS = ["calm_1", "calm_2"]
const BUS = "Music"
const LEVEL_DB = -4.0  # the tracks are mastered to about -16 LUFS; this sits them under the war
const SILENT_DB = -60.0
const POLL_S = 0.5
const CALM_GAP_S = 12.0  # silence between two calm tracks
const FADE_S = {
	State.MENU: 2.0,
	State.CALM: 5.0,
	State.TENSION: 2.5,
	State.BATTLE: 1.5,
	State.ENDED: 1.0,
	State.SILENT: 1.5,
}
# heat: each hit on or by the player's side adds to it, and it halves every HEAT_HALF_LIFE_S
const HEAT_HALF_LIFE_S = 5.0
const HEAT_HIT = 1.0
const HEAT_STRUCTURE_HIT = 1.5
const HEAT_LOSS = 2.0
const HEAT_KILL = 1.0
const TENSION_HEAT = 1.0
const BATTLE_HEAT = 8.0
const BATTLE_COOLDOWN_S = 10.0  # battle drops to tension after this long without a hit
const QUIET_S = 20.0  # and tension to calm after this long
const MIN_STATE_S = 6.0  # no stepping down sooner than this after a change

var state = State.SILENT
var track = ""  # the track playing now ("" when none)
var heat = 0.0
var transitions = []  # [[ticks ms, state name, track]] (read by tests)
var audible = true  # false with the Dummy driver: states change, nothing is decoded

var _players = []  # two AudioStreamPlayers, crossfaded
var _active = 0
var _streams = {}
var _fades = {}  # player -> Tween
var _calm_index = 0
var _calm_resume_at_s = -1.0
var _last_combat_s = -1000.0
var _heat_at_s = 0.0
var _state_since_s = 0.0
var _city_threat = 0
var _human_player = null
var _in_match = false
var _match = null  # the Match scene the music follows


func _ready():
	process_mode = Node.PROCESS_MODE_ALWAYS  # the match menu pauses the tree
	audible = (AudioServer.get_driver_name() != "Dummy" or "--music" in OS.get_cmdline_user_args())
	_ensure_bus()
	for i in range(2):
		var player = AudioStreamPlayer.new()
		player.bus = BUS
		player.volume_db = SILENT_DB
		player.finished.connect(_on_finished.bind(player))
		add_child(player)
		_players.append(player)
	_calm_index = randi() % CALM_TRACKS.size()
	MatchSignals.match_finished_with_victory.connect(_on_match_finished.bind("victory"))
	MatchSignals.match_finished_with_defeat.connect(_on_match_finished.bind("defeat"))
	MatchSignals.match_aborted.connect(_on_match_aborted)
	MatchSignals.unit_damaged.connect(_on_unit_damaged)
	MatchSignals.unit_died.connect(_on_unit_died)
	MatchSignals.city_threat_changed.connect(_on_city_threat_changed)
	var timer = Timer.new()
	timer.process_mode = Node.PROCESS_MODE_ALWAYS
	timer.timeout.connect(_poll)
	add_child(timer)
	timer.start(POLL_S)


func now_s():
	return Time.get_ticks_msec() / 1000.0


func register_combat(weight, at_s = -1.0):
	"""fighting involving the player's side; also called by tests"""
	if not state in [State.CALM, State.TENSION, State.BATTLE]:
		return
	var now = now_s() if at_s < 0.0 else at_s
	_cool_down(now)
	heat += weight
	_last_combat_s = now
	_update_state(now)


func _poll():
	var scene = get_tree().current_scene
	var scene_path = scene.scene_file_path if scene != null else ""
	if scene_path == "res://source/match/Match.tscn":
		if scene != _match:
			_start_match(scene)
		_update_state(now_s())
	elif (
		scene_path.begins_with("res://source/main-menu/") or scene_path == "res://source/Main.tscn"
	):
		_leave_match()
		if state != State.MENU:
			_go(State.MENU, "menu")
	elif scene_path.begins_with("res://source/map-editor/"):
		_leave_match()
		if state != State.CALM:
			_go(State.CALM, _next_calm_track())
	if state == State.CALM and _calm_resume_at_s >= 0.0 and now_s() >= _calm_resume_at_s:
		_calm_resume_at_s = -1.0
		_go(State.CALM, _next_calm_track())


func _update_state(now):
	if not _in_match or state == State.ENDED:
		return
	_cool_down(now)
	var quiet_s = now - _last_combat_s
	var wanted = State.CALM
	if heat >= BATTLE_HEAT or _city_threat >= 2:
		wanted = State.BATTLE
	elif heat >= TENSION_HEAT or _city_threat >= 1:
		wanted = State.TENSION
	# stepping down waits: battle holds while hits keep coming, tension until it is quiet
	if wanted < state:
		if now - _state_since_s < MIN_STATE_S:
			return
		if state == State.BATTLE and quiet_s < BATTLE_COOLDOWN_S and _city_threat < 1:
			wanted = State.BATTLE if heat >= TENSION_HEAT else State.TENSION
		if wanted == State.CALM and (quiet_s < QUIET_S or _city_threat >= 1):
			wanted = State.TENSION
	if wanted == state:
		return
	match wanted:
		State.CALM:
			_go(State.CALM, _next_calm_track(), now)
		State.TENSION:
			_go(State.TENSION, "tension", now)
		State.BATTLE:
			_go(State.BATTLE, "battle", now)


func _cool_down(now):
	if now > _heat_at_s:
		heat *= pow(0.5, (now - _heat_at_s) / HEAT_HALF_LIFE_S)
		_heat_at_s = now
	if heat < 0.05:
		heat = 0.0


func _go(new_state, track_name, now = -1.0):
	state = new_state
	_state_since_s = now_s() if now < 0.0 else now
	_calm_resume_at_s = -1.0
	transitions.append([Time.get_ticks_msec(), State.keys()[new_state], track_name])
	print(
		"[music] {0}: {1} (heat {2})".format(
			[State.keys()[new_state], track_name, snapped(heat, 0.1)]
		)
	)
	_crossfade_to(track_name, FADE_S.get(new_state, 2.0))


func _crossfade_to(track_name, fade_s):
	if track_name == track and _players[_active].playing:
		return
	track = track_name
	var old = _players[_active]
	_fade(old, SILENT_DB, fade_s, true)
	if track_name == "" or not audible:
		return
	var stream = _stream(track_name)
	if stream == null:
		return
	_active = 1 - _active
	var player = _players[_active]
	if _fades.has(player):
		_fades[player].kill()
	player.stream = stream
	player.volume_db = SILENT_DB if fade_s > 0.0 else LEVEL_DB
	player.play()
	_fade(player, LEVEL_DB, fade_s * 0.6, false)


func _fade(player, to_db, seconds, stop_after):
	if _fades.has(player):
		_fades[player].kill()
	if not player.playing:
		return
	var tween = create_tween()
	tween.set_process_mode(Tween.TWEEN_PROCESS_IDLE)
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(player, "volume_db", to_db, max(seconds, 0.05)).set_trans(Tween.TRANS_SINE)
	if stop_after:
		tween.tween_callback(player.stop)
	_fades[player] = tween


func _stream(track_name):
	if not _streams.has(track_name):
		var stream = load(MUSIC_DIR + TRACKS[track_name])
		if stream is AudioStreamOggVorbis:
			stream.loop = track_name in ["menu", "tension", "battle"]
		_streams[track_name] = stream
	return _streams[track_name]


func _next_calm_track():
	_calm_index = (_calm_index + 1) % CALM_TRACKS.size()
	return CALM_TRACKS[_calm_index]


func _ensure_bus():
	if AudioServer.get_bus_index(BUS) != -1:
		return
	AudioServer.add_bus()
	var index = AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, BUS)
	AudioServer.set_bus_send(index, "Master")


func _is_ours(unit):
	return is_instance_valid(unit) and unit.is_in_group("controlled_units")


func _hit_by_us(unit):
	if not "last_attacker_player" in unit or unit.last_attacker_player == null:
		return false
	if _human_player == null or not is_instance_valid(_human_player):
		var ours = get_tree().get_first_node_in_group("controlled_units")
		_human_player = ours.player if ours != null and "player" in ours else null
	return _human_player != null and unit.last_attacker_player == _human_player


func _start_match(a_match, now = -1.0):
	"""a match scene became current (the music follows the scene, not match_started, so
	replays and test matches get music too)"""
	_match = a_match
	_in_match = true
	heat = 0.0
	now = now_s() if now < 0.0 else now
	_heat_at_s = now
	_city_threat = 0
	_human_player = null
	_last_combat_s = -1000.0
	_go(State.CALM, _next_calm_track(), now)


func _leave_match():
	_match = null
	_in_match = false
	_human_player = null


func _on_match_aborted():
	_in_match = false


func _on_match_finished(result):
	if state == State.ENDED:
		return
	_in_match = false
	_go(State.ENDED, result)


func _on_unit_damaged(unit):
	if not _in_match or not is_instance_valid(unit):
		return
	if _is_ours(unit):
		register_combat(HEAT_STRUCTURE_HIT if unit.is_in_group("structures") else HEAT_HIT)
	elif _hit_by_us(unit):
		register_combat(HEAT_HIT)


func _on_unit_died(unit):
	# units also leave the tree when a match is torn down or a site is replaced by its
	# building; only a unit someone shot down to no hp died in a fight
	if not _in_match or not is_instance_valid(unit) or not "hp" in unit or unit.hp > 0:
		return
	if not "last_attacker_player" in unit or unit.last_attacker_player == null:
		return
	if _is_ours(unit):
		register_combat(HEAT_LOSS)
	elif _hit_by_us(unit):
		register_combat(HEAT_KILL)


func _on_city_threat_changed(player, threat_level, _position):
	if not _in_match:
		return
	var ours = get_tree().get_first_node_in_group("controlled_units")
	if ours == null or not "player" in ours or ours.player != player:
		return
	_city_threat = threat_level
	if threat_level > 0:
		_last_combat_s = now_s()
	_update_state(now_s())


func _on_finished(player):
	if player != _players[_active]:
		return
	if state == State.CALM:
		_calm_resume_at_s = now_s() + CALM_GAP_S  # a breather, then the other calm track
		track = ""
	elif state == State.ENDED:
		track = ""
