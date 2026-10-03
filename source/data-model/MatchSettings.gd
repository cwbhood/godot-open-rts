extends Resource

enum Visibility { PER_PLAYER, ALL_PLAYERS, FULL }

@export var players: Array[Resource] = []
@export var visibility = Visibility.PER_PLAYER
@export var visible_player = 0
@export var sandbox = false  # no match end, deficit spending, full visibility
