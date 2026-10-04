extends CanvasLayer

# Decides when a match is won, lost or over, then pauses it behind the end screen: a banner,
# a table of each player's numbers (MatchStats), a score-over-time chart and buttons to play
# the same match again or go back to the main menu.

const Human = preload("res://source/match/players/human/Human.gd")
const MatchLimits = preload("res://source/match/MatchLimits.gd")
const MatchStats = preload("res://source/match/handlers/MatchStats.gd")
const ScoreChart = preload("res://source/match/handlers/ScoreChart.gd")
const LoadingScene = preload("res://source/main-menu/Loading.tscn")
const TITLE_FONT = preload("res://assets/ui/fonts/ironbound_title.tres")
const BODY_FONT = preload("res://assets/ui/fonts/barlow-600.woff2")
const NUMBER_FONT = preload("res://assets/ui/fonts/ibm-plex-mono-500.woff2")

const SAND = Color("efe4cf")
const MUTED = Color("b5a68c")
const ACCENT = Color("f2a93b")
const RUST = Color("d0643a")
const SURFACE = Color("1f1a14")
const LINE = Color("3d3326")

var stats = null

var _human = null
var _limit_reason = null
var _panel_column = null
var _victory_tile = null
var _defeat_tile = null
var _finish_tile = null
var _subtitle = null
var _table = null
var _chart = null


func _ready():
	if not FeatureFlags.handle_match_end:
		queue_free()
		return
	hide()
	stats = MatchStats.new()
	stats.name = "MatchStats"
	add_child(stats)
	_build()
	await find_parent("Match").ready
	MatchSignals.setup_and_spawn_unit.connect(_on_new_unit)
	MatchSignals.match_limit_reached.connect(_on_match_limit_reached)
	for unit in get_tree().get_nodes_in_group("units"):
		unit.tree_exited.connect(_on_unit_tree_exited)


func surrender():
	"""ends the match as a loss for the human player (pause menu)"""
	if visible:
		return
	_handle_defeat()


func _handle_defeat():
	_defeat_tile.show()
	_show()
	MatchSignals.match_finished_with_defeat.emit()


func _handle_victory():
	_victory_tile.show()
	_show()
	MatchSignals.match_finished_with_victory.emit()


func _handle_finish():
	_finish_tile.show()
	_show()


func _show():
	stats.finish()
	_fill()
	show()
	get_tree().paused = true


func _on_new_unit(unit, _transform, _player):
	unit.tree_exited.connect(_on_unit_tree_exited)


func _on_unit_tree_exited():
	if visible or not is_inside_tree():
		return
	var players = Utils.Set.new()
	for unit in get_tree().get_nodes_in_group("units"):
		players.add(unit.player)
	var human = _find_human()
	if human != null and not players.has(human):
		_handle_defeat()
	elif human != null and players.has(human) and players.size() == 1:
		_handle_victory()
	elif players.size() == 1:
		_handle_finish()


func _on_match_limit_reached(reason, ranking):
	"""time ran out (or the map ran dry): the best score wins, see MatchLimits"""
	if visible or ranking.is_empty():
		return
	_limit_reason = reason
	var human = _find_human()
	var best = ranking[0]["score"]["total"]
	var leaders = ranking.filter(func(row): return row["score"]["total"] == best)
	if leaders.size() > 1:
		_finish_tile.text = tr("MATCH_END_DRAW").to_upper()
		_handle_finish()
	elif human == null:
		_handle_finish()
	elif leaders[0]["player"] == human:
		_handle_victory()
	else:
		_handle_defeat()


func _find_human():
	if _human != null and is_instance_valid(_human):
		return _human
	for player in get_tree().get_nodes_in_group("players"):
		if player is Human:
			_human = player
			return player
	return null


func _player_name(player):
	if player == _find_human():
		return tr("MATCH_END_YOU")
	var a_match = find_parent("Match")
	var diplomacy_hud = a_match.find_child("DiplomacyHud", true, false) if a_match else null
	if diplomacy_hud != null:
		return diplomacy_hud.faction_name(player)
	return "#{0}".format([player.get_index() + 1])


func _build():
	var center = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(center)
	var panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(SURFACE, 0.96)
	style.border_color = LINE
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(28)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	_panel_column = VBoxContainer.new()
	_panel_column.custom_minimum_size = Vector2(980, 0)
	_panel_column.add_theme_constant_override("separation", 14)
	panel.add_child(_panel_column)

	_victory_tile = _banner("Victory", tr("MATCH_END_VICTORY").to_upper(), ACCENT)
	_defeat_tile = _banner("Defeat", tr("MATCH_END_DEFEAT").to_upper(), RUST)
	_finish_tile = _banner("Finish", tr("MATCH_END_FINISHED").to_upper(), SAND)
	_subtitle = _label("", BODY_FONT, 20, MUTED)
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel_column.add_child(_subtitle)

	_table = GridContainer.new()
	_table.name = "StatsTable"
	_table.columns = 8
	_table.add_theme_constant_override("h_separation", 26)
	_table.add_theme_constant_override("v_separation", 6)
	_table.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_panel_column.add_child(_table)

	var chart_title = _label(tr("MATCH_END_SCORE_OVER_TIME"), BODY_FONT, 18, MUTED)
	_panel_column.add_child(chart_title)
	_chart = ScoreChart.new()
	_chart.name = "ScoreChart"
	_chart.custom_minimum_size = Vector2(980, 220)
	_panel_column.add_child(_chart)

	var buttons = HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 16)
	_panel_column.add_child(buttons)
	var rematch = _button(tr("MATCH_END_REMATCH"), _on_rematch_button_pressed)
	rematch.name = "RematchButton"
	buttons.add_child(rematch)
	var exit = _button(tr("MATCH_END_MAIN_MENU"), _on_exit_button_pressed)
	exit.name = "ExitButton"
	buttons.add_child(exit)


func _fill():
	var human = _find_human()
	var minutes = int(stats.elapsed_s) / 60
	var seconds = int(stats.elapsed_s) % 60
	var reason = ""
	if _limit_reason != null:
		reason = tr(
			(
				"MATCH_END_DEPLETION"
				if _limit_reason == MatchLimits.EndReason.DEPLETION
				else "MATCH_END_TIME"
			)
		)
	var time_text = tr("MATCH_END_DURATION").format(["%d:%02d" % [minutes, seconds]])
	_subtitle.text = time_text if reason == "" else "{0}  ·  {1}".format([reason, time_text])

	var players = get_tree().get_nodes_in_group("players")
	players.sort_custom(func(a, b): return stats.score_of(a) > stats.score_of(b))
	for child in _table.get_children():
		child.queue_free()
	for header in [
		"",
		"MATCH_END_COL_SCORE",
		"MATCH_END_COL_TIER",
		"MATCH_END_COL_BUILT",
		"MATCH_END_COL_LOST",
		"MATCH_END_COL_STRUCTURES",
		"MATCH_END_COL_DELIVERED",
		"MATCH_END_COL_TRADES",
	]:
		var cell = _label(tr(header) if header != "" else "", BODY_FONT, 17, MUTED)
		cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_table.add_child(cell)
	for player in players:
		var row = stats.counters_of(player)
		var name_cell = _label("■ " + _player_name(player), BODY_FONT, 20, SAND)
		name_cell.add_theme_color_override("font_color", player.color.lightened(0.2))
		if player == human:
			name_cell.add_theme_font_override("font", TITLE_FONT)
		_table.add_child(name_cell)
		for value in [
			stats.score_of(player),
			row["tier"],
			row["built"],
			row["lost"],
			row["structures"],
			int(round(row["delivered"])),
			row["trades"],
		]:
			var cell = _label(str(value), NUMBER_FONT, 20, SAND)
			cell.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			_table.add_child(cell)

	# kept for tests and for anyone reading the old summary text
	var summary = _panel_column.get_node_or_null("ScoreSummary")
	if summary == null:
		summary = Label.new()
		summary.name = "ScoreSummary"
		summary.visible = true
		summary.modulate.a = 0.0
		summary.custom_minimum_size = Vector2(0, 1)
		summary.clip_text = true
		_panel_column.add_child(summary)
	summary.text = _subtitle.text

	var series = []
	for player in players:
		var points = []
		for sample in stats.samples:
			points.append(Vector2(sample["t"], sample["scores"].get(player.get_instance_id(), 0)))
		series.append({"color": player.color, "points": points, "label": _player_name(player)})
	_chart.set_series(series)


func _banner(node_name, text, color):
	var label = _label(text, TITLE_FONT, 84, color)
	label.name = node_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.hide()
	_panel_column.add_child(label)
	return label


func _label(text, font, font_size, color):
	var label = Label.new()
	label.text = text
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(text, callback):
	var button = Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(260, 52)
	button.add_theme_font_override("font", BODY_FONT)
	button.add_theme_font_size_override("font_size", 22)
	button.pressed.connect(callback)
	return button


func _on_rematch_button_pressed():
	var a_match = find_parent("Match")
	var map_path = a_match.map.scene_file_path if a_match != null and a_match.map else ""
	if a_match == null or a_match.settings == null or map_path == "":
		_on_exit_button_pressed()
		return
	var loading = LoadingScene.instantiate()
	loading.match_settings = a_match.settings.duplicate(true)
	loading.map_path = map_path
	get_tree().paused = false
	get_tree().root.add_child(loading)
	get_tree().current_scene = loading
	a_match.queue_free()


func _on_exit_button_pressed():
	get_tree().paused = false
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
