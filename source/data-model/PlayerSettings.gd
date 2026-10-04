extends Resource

@export var color = Color.BLUE
@export var controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
@export var spawn_index_offset = 0
@export var ai_personality = "balanced"  # id of a personality from data/ai/
@export var start_zone = -1  # picked on the start screen; -1 uses the slot's spawn point
@export var start_position = Vector2.INF  # where in the start zone the city stands (x, z)
