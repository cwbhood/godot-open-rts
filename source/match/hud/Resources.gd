extends VBoxContainer

# The top strip (ResourcesBar) of the human player. Only a match without a human player
# (AI against AI, watched) shows every faction's strip, each marked with its colour: the
# rivals' stock is not the player's business, even with the whole map revealed (sandbox).

const Human = preload("res://source/match/players/human/Human.gd")

# TODO: handle human player removal/addition


func _ready():
	add_theme_constant_override("separation", 0)
	await find_parent("Match").ready
	_hide_all_bars()
	_setup_all_bars()
	var human_players = get_tree().get_nodes_in_group("players").filter(
		func(player): return player is Human
	)
	if not human_players.is_empty():
		_show_player_bars([human_players[0]])
	else:
		var players = get_tree().get_nodes_in_group("players")
		for bar in get_children():
			bar.set_show_owner(players.size() > 1)
		_show_player_bars(players)


func _hide_all_bars():
	for bar in get_children():
		bar.hide()


func _setup_all_bars():
	var bar_nodes = get_children()
	var players = get_tree().get_nodes_in_group("players")
	for i in range(min(players.size(), bar_nodes.size())):
		bar_nodes[i].setup(players[i])


func _show_player_bars(players):
	for player in players:
		for bar_node in get_children():
			if bar_node.player == player:
				bar_node.show()
