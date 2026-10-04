extends RefCounted

# Adds a difficulty and a colour dropdown next to every player slot of the Play menu.
#
# - Colours come from data/player_colors.json. No two slots share one: picking a colour
#   that another slot has swaps the two.
# - Difficulties come from data/difficulties/ and only apply to AI slots; the play style
#   (personality) stays in the slot's controller dropdown, so the two are picked separately.
#
# Play.gd reads the choices with color_of() and difficulty_of() when it builds the
# MatchSettings, so they reach the match through PlayerSettings.color / .ai_difficulty.

const GameData = preload("res://source/data-model/GameData.gd")

const SWATCH_SIZE = 18
const DEFAULT_DIFFICULTY = "normal"

var _grid = null
var _controllers = []  # OptionButton per slot (None / Human / AI: <play style>)
var _difficulty_buttons = []
var _color_buttons = []
var _colors = []  # palette index per slot
var _palette = []
var _difficulties = []


func setup(grid):
	_grid = grid
	_palette = GameData.player_colors()
	_difficulties = GameData.ai_difficulties()
	_controllers = grid.find_children("OptionButton*", "", false)
	grid.columns = 4
	for slot in range(_controllers.size()):
		var difficulty_button = _create_difficulty_button(slot)
		var color_button = _create_color_button(slot)
		grid.add_child(difficulty_button)
		grid.move_child(difficulty_button, _controllers[slot].get_index() + 1)
		grid.add_child(color_button)
		grid.move_child(color_button, difficulty_button.get_index() + 1)
		_difficulty_buttons.append(difficulty_button)
		_color_buttons.append(color_button)
		_colors.append(slot % max(_palette.size(), 1))
		_controllers[slot].item_selected.connect(func(_index): refresh())
	for slot in range(_controllers.size()):
		_show_color(slot)
	refresh()


func refresh():
	"""difficulty only means something for AI slots; hidden slots hide their extras too"""
	for slot in range(_controllers.size()):
		var controller = _controllers[slot]
		var is_ai = controller.selected >= Constants.PlayerType.SIMPLE_CLAIRVOYANT_AI
		_difficulty_buttons[slot].visible = controller.visible
		_color_buttons[slot].visible = controller.visible
		_difficulty_buttons[slot].disabled = not is_ai
		# keeps its grid cell so the columns stay aligned
		_difficulty_buttons[slot].modulate.a = 1.0 if is_ai else 0.0
		_color_buttons[slot].disabled = controller.selected == Constants.PlayerType.NONE
		_color_buttons[slot].modulate.a = (
			0.35 if controller.selected == Constants.PlayerType.NONE else 1.0
		)


func color_of(slot):
	if _palette.is_empty():
		return Constants.Player.COLORS[slot % Constants.Player.COLORS.size()]
	return _palette[_colors[slot]]["color"]


func difficulty_of(slot):
	var index = _difficulty_buttons[slot].selected
	if index < 0 or index >= _difficulties.size():
		return DEFAULT_DIFFICULTY
	return _difficulties[index]["id"]


func set_color(slot, palette_index):
	"""gives the slot a colour; a slot that had it gets this slot's old colour"""
	var previous = _colors[slot]
	for other in range(_colors.size()):
		if other != slot and _colors[other] == palette_index:
			_colors[other] = previous
			_show_color(other)
	_colors[slot] = palette_index
	_show_color(slot)


func set_difficulty(slot, difficulty_id):
	for index in range(_difficulties.size()):
		if _difficulties[index]["id"] == difficulty_id:
			_difficulty_buttons[slot].select(index)


func _create_difficulty_button(slot):
	var button = OptionButton.new()
	button.name = "DifficultyButton{0}".format([slot])
	button.focus_mode = Control.FOCUS_NONE
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.tooltip_text = tr("AI_DIFFICULTY")
	for difficulty in _difficulties:
		button.add_item(tr(difficulty["name"]))
		button.set_item_tooltip(button.item_count - 1, tr(difficulty.get("description", "")))
		if difficulty["id"] == DEFAULT_DIFFICULTY:
			button.select(button.item_count - 1)
	return button


func _create_color_button(slot):
	var button = OptionButton.new()
	button.name = "ColorButton{0}".format([slot])
	button.focus_mode = Control.FOCUS_NONE
	button.tooltip_text = tr("PLAYER_COLOR")
	for entry in _palette:
		button.add_icon_item(_swatch(entry["color"]), tr(entry["name"]))
	button.item_selected.connect(func(index): set_color(slot, index))
	return button


func _show_color(slot):
	if _palette.is_empty():
		return
	_color_buttons[slot].select(_colors[slot])


static func _swatch(color):
	var image = Image.create(SWATCH_SIZE, SWATCH_SIZE, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.1, 0.1, 0.1))
	image.fill_rect(Rect2i(2, 2, SWATCH_SIZE - 4, SWATCH_SIZE - 4), color)
	return ImageTexture.create_from_image(image)
