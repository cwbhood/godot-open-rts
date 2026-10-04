extends RefCounted

# Finds the voice set of a unit and picks its lines. Sets come from data/sounds/ (see
# data/README.md#sounds). Lines of one action are drawn like cards from a shuffled deck, so
# every variant plays once before any repeats and the same line never plays twice in a row.

const GameData = preload("res://source/data-model/GameData.gd")

var _decks = {}  # "set/action" -> [line index] still to play
var _last_played = {}  # "set/action" -> line index
var _streams = {}  # path -> AudioStream (null when it failed to load)


static func set_id_for_unit(unit):
	var scene_path = unit._scene_path() if unit.has_method("_scene_path") else unit.scene_file_path
	return GameData.voice_set_id_for(GameData.unit_by_scene(scene_path))


static func line_path(voice_set, line):
	var file = line["file"] if line is Dictionary else str(line)
	if file.begins_with("res://") or file.begins_with("user://"):
		return file
	var folder = voice_set.get("folder", "")
	if line is Dictionary:
		folder = line.get("folder", folder)
	return folder + file if folder == "" or folder.ends_with("/") else folder.path_join(file)


static func lines_of(set_id, action):
	var voice_set = GameData.voice_set_by_id(set_id)
	if voice_set == null:
		return []
	return voice_set.get("lines", {}).get(action, [])


static func load_stream(path):
	if path.begins_with("user://"):
		return AudioStreamOggVorbis.load_from_file(path) if FileAccess.file_exists(path) else null
	return load(path) if ResourceLoader.exists(path) else null


func has_lines(set_id, action):
	return not lines_of(set_id, action).is_empty()


func pick(set_id, action):
	"""the next line of a set's action as an AudioStream, null when it has none"""
	var lines = lines_of(set_id, action)
	if lines.is_empty():
		return null
	var index = _draw("{0}/{1}".format([set_id, action]), lines.size())
	return _stream(line_path(GameData.voice_set_by_id(set_id), lines[index]))


func _draw(key, count):
	var deck = _decks.get(key, [])
	if deck.is_empty():
		deck = range(count)
		deck.shuffle()
		if count > 1 and deck[0] == _last_played.get(key, -1):
			deck.push_back(deck.pop_front())  # a fresh deck never starts with the last line
		_decks[key] = deck
	var index = deck.pop_front()
	_last_played[key] = index
	return index


func _stream(path):
	if not path in _streams:
		_streams[path] = load_stream(path)
		if _streams[path] == null:
			push_warning("VoiceBank: cannot load '{0}'".format([path]))
	return _streams[path]
