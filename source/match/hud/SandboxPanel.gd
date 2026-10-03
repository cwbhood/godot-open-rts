extends PanelContainer

# Sandbox tools (sandbox matches only): spawn any unit or structure defined in data/, for
# any faction, where you click; top up every commodity. Handy for trying out new units.

const GameData = preload("res://source/data-model/GameData.gd")
const Structure = preload("res://source/match/units/Structure.gd")

const TOP_UP_AMOUNT = 100

var _unit_option = null
var _player_option = null
var _spawn_button = null
var _placing = false
var _unit_ids = []

@onready var _match = find_parent("Match")


func _ready():
	var box = VBoxContainer.new()
	add_child(box)
	var title = Label.new()
	title.text = tr("SANDBOX_MODE")
	box.add_child(title)
	_unit_option = OptionButton.new()
	for unit in GameData.units():
		_unit_ids.append(unit["id"])
		_unit_option.add_item(tr(unit.get("name", unit["id"])))
	box.add_child(_unit_option)
	_player_option = OptionButton.new()
	box.add_child(_player_option)
	_spawn_button = Button.new()
	_spawn_button.toggle_mode = true
	_spawn_button.text = tr("SANDBOX_SPAWN")
	_spawn_button.tooltip_text = tr("SANDBOX_SPAWN_TOOLTIP")
	_spawn_button.toggled.connect(func(pressed): _placing = pressed)
	box.add_child(_spawn_button)
	var top_up = Button.new()
	top_up.text = tr("SANDBOX_TOP_UP").format([TOP_UP_AMOUNT])
	top_up.pressed.connect(_on_top_up_pressed)
	box.add_child(top_up)
	if not _match.is_node_ready():
		await _match.ready
	for player in get_tree().get_nodes_in_group("players"):
		_player_option.add_item(tr("TRADE_FACTION").format([player.get_index() + 1]))
		_player_option.set_item_icon(_player_option.item_count - 1, _color_icon(player.color))


func _unhandled_input(event):
	if not _placing:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			var camera = get_viewport().get_camera_3d()
			var position = camera.get_ray_intersection(event.position)
			if position != null:
				_spawn(position)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_spawn_button.button_pressed = false
			get_viewport().set_input_as_handled()


func _spawn(position):
	var players = get_tree().get_nodes_in_group("players")
	if players.is_empty() or _unit_option.selected < 0:
		return
	var player = players[max(0, _player_option.selected)]
	var entry = GameData.unit_by_id(_unit_ids[_unit_option.selected])
	var unit = load(entry["scene"]).instantiate()
	if unit is Structure:
		unit.set_meta("spawn_constructed", true)
	MatchSignals.setup_and_spawn_unit.emit(
		unit, Transform3D(Basis(), position * Vector3(1, 0, 1)), player
	)


func _on_top_up_pressed():
	var resources = {}
	for resource in Constants.Match.Resources.ALL:
		resources[resource] = TOP_UP_AMOUNT
	for player in get_tree().get_nodes_in_group("players"):
		player.add_resources(resources)


static func _color_icon(color):
	var image = Image.create(12, 12, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)
