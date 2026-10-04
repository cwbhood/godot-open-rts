extends Resource

enum Visibility { PER_PLAYER, ALL_PLAYERS, FULL }

@export var players: Array[Resource] = []
@export var visibility = Visibility.PER_PLAYER
@export var visible_player = 0
@export var sandbox = false  # no match end, deficit spending, full visibility
## seconds to pick a start zone; 0 uses the map's "start_pick_seconds" (30 by default)
@export var start_pick_seconds = 0.0
## help the player gets this match, see MatchRules.gd ("Guided": all on, "Raw": all off)
@export var tutorial = true  # tutorial panel and hints
@export var ai_assist = true  # the player's helper AI may be switched on
@export var auto_build = true  # constructors may auto-expand
