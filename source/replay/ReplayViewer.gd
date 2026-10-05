extends Control

# Plays back matches recorded by the ReplayRecorder as a top-down map: units move as they
# did, haulers carrying goods are ringed, raids flash red, and the side panel shows each
# faction's economy and the event log at the current moment.

const ReplayRecorder = preload("res://source/match/ReplayRecorder.gd")
const GameData = preload("res://source/data-model/GameData.gd")

const SPEEDS = [1.0, 4.0, 16.0, 64.0]
const RAID_MARKER_S = 6.0

var _replay = null
var _time_s = 0.0
var _playing = false
var _speed = 4.0
var _snapshot_index = 0
var _unit_categories = {}  # unit data id -> category
var _replay_paths = []

var _list = null
var _canvas = null
var _slider = null
var _time_label = null
var _play_button = null
var _stats_label = null
var _events_label = null


func _ready():
	for unit in GameData.units():
		_unit_categories[unit["id"]] = unit.get("category", "unit")
	_build_ui()
	_fill_list()


func _process(delta):
	if _replay == null or not _playing:
		return
	_time_s = min(_time_s + delta * _speed, float(_replay["duration_s"]))
	if _time_s >= float(_replay["duration_s"]):
		_set_playing(false)
	_slider.set_value_no_signal(_time_s)
	_refresh()


func _build_ui():
	var background = ColorRect.new()
	background.color = Color(0.08, 0.09, 0.1)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var root = HBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var left = VBoxContainer.new()
	left.custom_minimum_size = Vector2(260, 0)
	root.add_child(left)
	var title = Label.new()
	title.text = tr("REPLAYS")
	left.add_child(title)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_replay_selected)
	left.add_child(_list)
	var back = Button.new()
	back.text = tr("BACK")
	back.pressed.connect(
		func(): get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
	)
	left.add_child(back)

	var center = VBoxContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(center)
	_canvas = Control.new()
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.clip_contents = true
	_canvas.draw.connect(_draw_canvas)
	center.add_child(_canvas)
	var controls = HBoxContainer.new()
	center.add_child(controls)
	_play_button = Button.new()
	_play_button.custom_minimum_size = Vector2(80, 0)
	_play_button.pressed.connect(func(): _set_playing(not _playing))
	controls.add_child(_play_button)
	var speed = OptionButton.new()
	for value in SPEEDS:
		speed.add_item("x%d" % int(value))
	speed.selected = SPEEDS.find(_speed)
	speed.item_selected.connect(func(index): _speed = SPEEDS[index])
	controls.add_child(speed)
	_slider = HSlider.new()
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.step = 0.1
	_slider.value_changed.connect(
		func(value):
			_time_s = value
			_refresh()
	)
	controls.add_child(_slider)
	_time_label = Label.new()
	_time_label.custom_minimum_size = Vector2(90, 0)
	controls.add_child(_time_label)

	var right = VBoxContainer.new()
	right.custom_minimum_size = Vector2(320, 0)
	root.add_child(right)
	_stats_label = Label.new()
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_stats_label)
	_events_label = RichTextLabel.new()
	_events_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_events_label.scroll_following = true
	right.add_child(_events_label)
	_set_playing(false)


func _fill_list():
	_list.clear()
	_replay_paths = ReplayRecorder.list_replays()
	for path in _replay_paths:
		_list.add_item(path.get_file().get_basename())
	if _replay_paths.is_empty():
		_list.add_item(tr("REPLAYS_NONE"))
		_list.set_item_disabled(0, true)


func _on_replay_selected(index):
	if index >= _replay_paths.size():
		return
	_replay = ReplayRecorder.load_replay(_replay_paths[index])
	if _replay == null:
		return
	_time_s = 0.0
	_snapshot_index = 0
	_slider.max_value = float(_replay["duration_s"])
	_slider.set_value_no_signal(0.0)
	_set_playing(true)
	_refresh()


func _set_playing(playing):
	_playing = playing and _replay != null
	_play_button.text = tr("REPLAY_PAUSE") if _playing else tr("REPLAY_PLAY")


func _refresh():
	if _replay == null:
		return
	_time_label.text = (
		"%d:%02d / %d:%02d"
		% [
			int(_time_s) / 60,
			int(_time_s) % 60,
			int(_replay["duration_s"]) / 60,
			int(_replay["duration_s"]) % 60
		]
	)
	_snapshot_index = _find_snapshot_index(_time_s)
	_refresh_stats()
	_refresh_events()
	_canvas.queue_redraw()


func _find_snapshot_index(time_s):
	var snapshots = _replay["snapshots"]
	var low = 0
	var high = snapshots.size() - 1
	while low < high:
		var middle = (low + high + 1) / 2
		if float(snapshots[middle]["t"]) <= time_s:
			low = middle
		else:
			high = middle - 1
	return low


func _refresh_stats():
	var snapshot = _replay["snapshots"][_snapshot_index]
	var lines = ["%s, %s" % [_replay.get("map_name", ""), _replay.get("date", "")]]
	for index in range(snapshot["economy"].size()):
		var economy = snapshot["economy"][index]
		var info = _replay["players"][index]
		var stock = []
		for resource in economy["stock"]:
			stock.append("%s %d" % [tr(resource.to_upper()), int(economy["stock"][resource])])
		(
			lines
			. append(
				(
					tr("REPLAY_PLAYER_LINE")
					. format(
						[
							index + 1,
							_personality_label(info),
							int(economy["tier"]),
							int(economy["population"]),
							int(economy["science"]),
							int(economy["delivered"]),
							int(economy["lost"]),
							"%.0f/%.0f" % [float(economy["power"][0]), float(economy["power"][1])],
							", ".join(stock),
						]
					)
				)
			)
		)
	_stats_label.text = "\n\n".join(lines)


func _refresh_events():
	var lines = []
	for event in _replay["events"]:
		if float(event["t"]) > _time_s:
			break
		var text = _describe_event(event)
		if text != "":
			lines.append("[%d:%02d] %s" % [int(event["t"]) / 60, int(event["t"]) % 60, text])
	_events_label.text = "\n".join(lines.slice(max(0, lines.size() - 60)))


func _describe_event(event):
	var player = "P%d" % (int(event.get("player", -1)) + 1)
	var text = ""
	match event["kind"]:
		"raid":
			text = tr("REPLAY_EVENT_RAID").format(
				[player, int(Utils.Dict.sum(event["cargo"])), "P%d" % (int(event["looter"]) + 1)]
			)
		"tier":
			text = tr("REPLAY_EVENT_TIER").format([player, int(event["tier"])])
		"trade":
			text = tr("REPLAY_EVENT_TRADE").format([player, "P%d" % (int(event["partner"]) + 1)])
		"embargo":
			if event["active"]:
				text = tr("REPLAY_EVENT_EMBARGO").format(
					[player, "P%d" % (int(event["target"]) + 1)]
				)
		"threat":
			if int(event["level"]) == 2:
				text = tr("REPLAY_EVENT_CALL_FOR_HELP").format([player])
		"road":
			if int(event["level"]) > 0:
				text = tr("REPLAY_EVENT_ROAD").format([player, int(event["level"])])
	return text


func _draw_canvas():
	if _replay == null:
		return
	var map_size = Vector2(float(_replay["map_size"][0]), float(_replay["map_size"][1]))
	var scale = min(_canvas.size.x / map_size.x, _canvas.size.y / map_size.y)
	var offset = (_canvas.size - map_size * scale) / 2.0
	_canvas.draw_rect(Rect2(offset, map_size * scale), Color(0.36, 0.31, 0.22))
	var to_canvas = func(x, z): return offset + Vector2(float(x), float(z)) * scale
	for deposit in _replay["deposits"]:
		var color = Constants.Match.Resources.COLORS.get(deposit[0], Color.WHITE)
		var center = to_canvas.call(deposit[1], deposit[2])
		_canvas.draw_colored_polygon(
			PackedVector2Array(
				[
					center + Vector2(0, -4),
					center + Vector2(4, 0),
					center + Vector2(0, 4),
					center + Vector2(-4, 0)
				]
			),
			color
		)
	var snapshot = _replay["snapshots"][_snapshot_index]
	var next = _replay["snapshots"][min(_snapshot_index + 1, _replay["snapshots"].size() - 1)]
	var span = float(next["t"]) - float(snapshot["t"])
	var weight = clamp((_time_s - float(snapshot["t"])) / span, 0.0, 1.0) if span > 0.0 else 0.0
	var next_positions = {}
	for unit in next["units"]:
		next_positions[unit[0]] = Vector2(unit[3], unit[4])
	for unit in snapshot["units"]:
		var position = Vector2(unit[3], unit[4])
		if unit[0] in next_positions:
			position = position.lerp(next_positions[unit[0]], weight)
		var center = to_canvas.call(position.x, position.y)
		var owner = int(unit[1])
		var color = Color(_replay["players"][owner]["color"]) if owner >= 0 else Color.GRAY
		if _unit_categories.get(unit[2], "unit") == "structure":
			_canvas.draw_rect(Rect2(center - Vector2(4, 4), Vector2(8, 8)), color)
		else:
			_canvas.draw_circle(center, 2.5, color)
			if int(unit[6]) == 1:
				_canvas.draw_arc(center, 4.0, 0.0, TAU, 12, Color.WHITE, 1.0)
	for event in _replay["events"]:
		if event["kind"] != "raid":
			continue
		var age = _time_s - float(event["t"])
		if age < 0.0:
			break
		if age <= RAID_MARKER_S:
			var center = to_canvas.call(event["x"], event["z"])
			var color = Color(1, 0.15, 0.1, 1.0 - age / RAID_MARKER_S)
			_canvas.draw_line(center - Vector2(5, 5), center + Vector2(5, 5), color, 2.0)
			_canvas.draw_line(center - Vector2(5, -5), center + Vector2(5, -5), color, 2.0)


func _personality_label(info):
	var faction = GameData.faction_by_id(str(info.get("faction", "")))
	var faction_name = tr(faction["name"]) if faction != null else ""
	if info["human"]:
		return faction_name
	var label = tr("AI_PLAYER").format([str(info["personality"])])
	for personality in GameData.ai_personalities():
		if personality["id"] == info["personality"]:
			label = tr("AI_PLAYER").format([tr(personality["name"])])
	return label if faction_name == "" else "{0}, {1}".format([faction_name, label])
