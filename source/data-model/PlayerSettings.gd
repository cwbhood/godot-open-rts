extends Resource

@export var color = Color.BLUE  # picked in the Play menu from data/player_colors.json
@export var controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
@export var spawn_index_offset = 0
@export var ai_personality = "balanced"  # id of a personality from data/ai/
@export var ai_difficulty = "normal"  # id of a difficulty from data/difficulties/
@export var start_zone = -1  # picked on the start screen; -1 uses the slot's spawn point
@export var start_position = Vector2.INF  # where in the start zone the city stands (x, z)
## id of a faction from data/factions/; "random" is resolved when the match settings are
## made (see Factions.resolve), so Restart keeps the same faction; "" builds everything
@export var faction = ""
