extends Node

# Checks the soundtrack's state machine (source/audio/MusicPlayer.gd) on a simulated clock:
# a stray hit brings the tension loop, a sustained fight the battle loop, and quiet brings the
# calm tracks back; the match end plays a sting. Also checks that every track loads and that
# the "Music" bus exists. Usage:
#   godot --headless --path . res://tests/audio/MusicCheck.tscn
# Exits with 1 on a failure.

var _failures = []


func _ready():
	var music = MusicPlayer
	var states = music.State
	_expect(AudioServer.get_bus_index(music.BUS) != -1, "the Music bus exists")
	for track_name in music.TRACKS:
		_expect(music._stream(track_name) is AudioStreamOggVorbis, track_name + " loads")
	_expect(music._stream("battle").loop, "the battle track loops")
	_expect(not music._stream("calm_1").loop, "calm tracks play once and take turns")

	var t = 1000.0
	music._start_match(self, t)
	_expect(music.state == states.CALM, "a match starts calm")
	var first_calm = music.track
	music.register_combat(music.HEAT_HIT, t + 1.0)
	_expect(music.state == states.TENSION, "a hit on our side brings tension")
	for i in range(20):  # a hit every half second for ten seconds
		music.register_combat(music.HEAT_HIT, t + 2.0 + i * 0.5)
	_expect(music.state == states.BATTLE, "a sustained fight brings the battle music")
	music._update_state(t + 17.0)
	_expect(music.state == states.BATTLE, "battle holds for a few seconds after the last hit")
	music._update_state(t + 30.0)
	_expect(music.state == states.TENSION, "battle cools down to tension")
	music._update_state(t + 37.0)
	_expect(music.state == states.CALM, "about 20 s of quiet brings the calm music back")
	_expect(music.track != first_calm, "the other calm track plays next")
	music._city_threat = 1
	music._update_state(t + 50.0)
	_expect(music.state == states.TENSION, "a threatened city brings tension")
	music._city_threat = 0
	music._on_match_finished("victory")
	_expect(music.state == states.ENDED and music.track == "victory", "victory plays a sting")
	music._leave_match()

	for failure in _failures:
		print("FAIL: ", failure)
	print("MusicCheck: {0}".format(["ok" if _failures.is_empty() else "FAILED"]))
	get_tree().quit(0 if _failures.is_empty() else 1)


func _expect(condition, what):
	if not condition:
		_failures.append(what)
