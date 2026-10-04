extends CanvasLayer

const Human = preload("res://source/match/players/human/Human.gd")
const MatchLimits = preload("res://source/match/MatchLimits.gd")

@onready var _victory_tile = find_child("Victory")
@onready var _defeat_tile = find_child("Defeat")
@onready var _finish_tile = find_child("Finish")


func _ready():
	if not FeatureFlags.handle_match_end:
		queue_free()
		return
	hide()
	_victory_tile.hide()
	_defeat_tile.hide()
	_finish_tile.hide()
	await find_parent("Match").ready
	MatchSignals.setup_and_spawn_unit.connect(_on_new_unit)
	MatchSignals.match_limit_reached.connect(_on_match_limit_reached)
	for unit in get_tree().get_nodes_in_group("units"):
		unit.tree_exited.connect(_on_unit_tree_exited)


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
	var human_players = get_tree().get_nodes_in_group("players").filter(
		func(player): return player is Human
	)
	if not human_players.is_empty() and not players.has(human_players[0]):
		_handle_defeat()
	elif not human_players.is_empty() and players.has(human_players[0]) and players.size() == 1:
		_handle_victory()
	elif players.size() == 1:
		_handle_finish()


func _on_match_limit_reached(reason, ranking):
	"""time ran out (or the map ran dry): the best score wins, see MatchLimits"""
	if visible or ranking.is_empty():
		return
	var human = null
	for player in get_tree().get_nodes_in_group("players"):
		if player is Human:
			human = player
			break
	var best = ranking[0]["score"]["total"]
	var leaders = ranking.filter(func(row): return row["score"]["total"] == best)
	var summary = RichTextLabel.new()
	summary.name = "ScoreSummary"
	summary.bbcode_enabled = true
	summary.fit_content = true
	summary.custom_minimum_size = Vector2(520, 0)
	summary.text = _score_text(reason, ranking, human)
	_victory_tile.get_parent().add_child(summary)
	_victory_tile.get_parent().move_child(summary, _finish_tile.get_index() + 1)
	if leaders.size() > 1:
		_finish_tile.get_child(0).text = tr("MATCH_END_DRAW")
		_handle_finish()
	elif human == null:
		_handle_finish()
	elif leaders[0]["player"] == human:
		_handle_victory()
	else:
		_handle_defeat()


func _score_text(reason, ranking, human):
	var lines = [
		(
			"[b]"
			+ tr(
				(
					"MATCH_END_DEPLETION"
					if reason == MatchLimits.EndReason.DEPLETION
					else "MATCH_END_TIME"
				)
			)
			+ "[/b]"
		)
	]
	var diplomacy_hud = find_parent("Match").find_child("DiplomacyHud", true, false)
	for index in range(ranking.size()):
		var player = ranking[index]["player"]
		var score = ranking[index]["score"]
		var name = tr("MATCH_END_YOU")
		if player != human:
			name = (
				diplomacy_hud.faction_name(player)
				if diplomacy_hud != null
				else "#{0}".format([player.get_index() + 1])
			)
		lines.append(
			(
				"[color=#{0}]■[/color] ".format([player.color.to_html(false)])
				+ tr("MATCH_END_SCORE_ROW").format(
					[
						index + 1,
						name,
						score["total"],
						score["citizens"],
						score["army"],
						score["structures"],
						score["science"]
					]
				)
			)
		)
	return "\n".join(lines)


func _on_exit_button_pressed():
	get_tree().paused = false
	get_tree().change_scene_to_file("res://source/main-menu/Main.tscn")
