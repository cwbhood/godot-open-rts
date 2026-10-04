extends Resource

enum Visibility { PER_PLAYER, ALL_PLAYERS, FULL }

@export var players: Array[Resource] = []
@export var visibility = Visibility.PER_PLAYER
@export var visible_player = 0
@export var sandbox = false  # no match end, deficit spending, full visibility
## seconds to pick a start zone; 0 uses the map's "start_pick_seconds" (30 by default)
@export var start_pick_seconds = 0.0
