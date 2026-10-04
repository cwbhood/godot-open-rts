extends Resource

@export var color = Color.BLUE  # picked in the Play menu from data/player_colors.json
@export var controller = Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
@export var spawn_index_offset = 0
@export var ai_personality = "balanced"  # id of a personality from data/ai/
@export var ai_difficulty = "normal"  # id of a difficulty from data/difficulties/
