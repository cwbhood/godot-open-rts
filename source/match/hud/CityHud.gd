extends PanelContainer

# Shows the human player's self-building city and lets them trade with other factions.

const Human = preload("res://source/match/players/human/Human.gd")
const Trade = preload("res://source/match/city/Trade.gd")

const RESOURCES = ["resource_a", "resource_b"]
const MAX_TRADE_AMOUNT = 20
const RESULT_MESSAGES = {
	Trade.Result.ACCEPTED: "TRADE_RESULT_ACCEPTED",
	Trade.Result.INVALID: "TRADE_RESULT_INVALID",
	Trade.Result.PROPOSER_CANNOT_AFFORD: "TRADE_RESULT_PROPOSER_CANNOT_AFFORD",
	Trade.Result.PARTNER_CANNOT_AFFORD: "TRADE_RESULT_PARTNER_CANNOT_AFFORD",
	Trade.Result.PARTNER_BUSY: "TRADE_RESULT_PARTNER_BUSY",
	Trade.Result.PARTNER_REFUSED: "TRADE_RESULT_PARTNER_REFUSED",
}

var _player = null
var _partners = []
var _incoming_offer = null
var _incoming_offer_time_left_s = 0.0

var _population_label = Label.new()
var _buildings_label = Label.new()
var _production_label = Label.new()
var _science_label = Label.new()
var _partner_option = OptionButton.new()
var _give_amount = SpinBox.new()
var _give_resource_option = OptionButton.new()
var _get_amount = SpinBox.new()
var _get_resource_label = Label.new()
var _propose_button = Button.new()
var _result_label = Label.new()
var _offer_box = VBoxContainer.new()
var _offer_label = Label.new()

@onready var _match = find_parent("Match")


func _ready():
	hide()
	_build_layout()
	if not _match.is_node_ready():
		await _match.ready
	var human_players = get_tree().get_nodes_in_group("players").filter(
		func(player): return player is Human
	)
	if human_players.is_empty() or human_players[0].city == null:
		return
	_player = human_players[0]
	_player.city.changed.connect(_refresh_city)
	MatchSignals.trade_offered.connect(_on_trade_offered)
	MatchSignals.trade_completed.connect(_on_trade_completed)
	_refresh_partners()
	_refresh_city()
	show()


func _process(delta):
	if _incoming_offer == null:
		return
	_incoming_offer_time_left_s -= delta
	if _incoming_offer_time_left_s <= 0.0 or not is_instance_valid(_incoming_offer["proposer"]):
		_dismiss_offer()


func _build_layout():
	custom_minimum_size = Vector2(320, 0)
	var margin = MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)
	var rows = VBoxContainer.new()
	margin.add_child(rows)

	rows.add_child(_make_title("CITY"))
	for label in [_population_label, _buildings_label, _production_label, _science_label]:
		rows.add_child(label)

	rows.add_child(HSeparator.new())
	rows.add_child(_make_title("TRADE"))
	var partner_row = HBoxContainer.new()
	partner_row.add_child(_make_label("TRADE_PARTNER"))
	_partner_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_partner_option.focus_mode = Control.FOCUS_NONE
	partner_row.add_child(_partner_option)
	rows.add_child(partner_row)

	var give_row = HBoxContainer.new()
	give_row.add_child(_make_label("TRADE_GIVE"))
	_setup_amount(_give_amount, 3)
	give_row.add_child(_give_amount)
	for resource in RESOURCES:
		_give_resource_option.add_item(tr(resource.to_upper()))
	_give_resource_option.focus_mode = Control.FOCUS_NONE
	_give_resource_option.item_selected.connect(func(_index): _refresh_get_resource_label())
	give_row.add_child(_give_resource_option)
	rows.add_child(give_row)

	var get_row = HBoxContainer.new()
	get_row.add_child(_make_label("TRADE_GET"))
	_setup_amount(_get_amount, 3)
	get_row.add_child(_get_amount)
	get_row.add_child(_get_resource_label)
	rows.add_child(get_row)
	_refresh_get_resource_label()

	_propose_button.text = tr("TRADE_PROPOSE")
	_propose_button.focus_mode = Control.FOCUS_NONE
	_propose_button.pressed.connect(_on_propose_pressed)
	rows.add_child(_propose_button)
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(_result_label)

	_offer_box.add_child(HSeparator.new())
	_offer_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_offer_box.add_child(_offer_label)
	var offer_buttons = HBoxContainer.new()
	var accept_button = Button.new()
	accept_button.text = tr("TRADE_ACCEPT")
	accept_button.focus_mode = Control.FOCUS_NONE
	accept_button.pressed.connect(_on_accept_offer_pressed)
	offer_buttons.add_child(accept_button)
	var decline_button = Button.new()
	decline_button.text = tr("TRADE_DECLINE")
	decline_button.focus_mode = Control.FOCUS_NONE
	decline_button.pressed.connect(_dismiss_offer)
	offer_buttons.add_child(decline_button)
	_offer_box.add_child(offer_buttons)
	_offer_box.hide()
	rows.add_child(_offer_box)


func _make_title(text_key):
	var label = _make_label(text_key)
	label.add_theme_font_size_override("font_size", 18)
	return label


func _make_label(text_key):
	var label = Label.new()
	label.text = tr(text_key)
	return label


func _setup_amount(spin_box, value):
	spin_box.min_value = 0
	spin_box.max_value = MAX_TRADE_AMOUNT
	spin_box.value = value
	spin_box.focus_mode = Control.FOCUS_NONE
	spin_box.get_line_edit().focus_mode = Control.FOCUS_CLICK


func _refresh_get_resource_label():
	_get_resource_label.text = tr(_get_resource().to_upper())


func _give_resource():
	return RESOURCES[_give_resource_option.selected]


func _get_resource():
	return RESOURCES[1 - _give_resource_option.selected]


func _refresh_partners():
	_partners = get_tree().get_nodes_in_group("players").filter(
		func(player): return player != _player
	)
	_partner_option.clear()
	for i in range(_partners.size()):
		_partner_option.add_item(tr("TRADE_FACTION").format([i + 1]))
		_partner_option.set_item_icon(i, _make_color_icon(_partners[i].color))
	_propose_button.disabled = _partners.is_empty()


func _make_color_icon(color):
	var image = Image.create(14, 14, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _refresh_city():
	var city = _player.city
	_population_label.text = tr("CITY_POPULATION").format(
		[int(city.population), "%.2f" % city.growth_per_s]
	)
	if city.trade_growth_boost > 0.0:
		_population_label.text += " " + tr("CITY_TRADE_BOOST")
	if not city.has_core():
		_population_label.text += " " + tr("CITY_NO_CORE")
	_buildings_label.text = tr("CITY_BUILDINGS").format(
		[city.get_buildings_count("house"), city.get_buildings_count("workshop")]
	)
	_production_label.text = tr("CITY_PRODUCTION").format(
		[int(round((city.production_multiplier - 1.0) * 100.0))]
	)
	var next_tech = city.get_next_tech()
	if next_tech == null:
		_science_label.text = tr("CITY_SCIENCE_DONE").format([int(city.science)])
	else:
		_science_label.text = (
			tr("CITY_SCIENCE")
			. format(
				[
					int(city.science),
					int(Constants.Match.Tech.SCIENCE_COSTS[next_tech]),
					tr("TECH_" + next_tech.to_upper()),
				]
			)
		)


func _on_propose_pressed():
	var partner = _selected_partner()
	if partner == null:
		return
	var offered = {_give_resource(): int(_give_amount.value)}
	var requested = {_get_resource(): int(_get_amount.value)}
	var result = (
		Trade.propose(_player, partner, offered, requested)
		if not partner is Human
		else Trade.Result.PARTNER_REFUSED
	)
	_result_label.text = tr(RESULT_MESSAGES[result])


func _selected_partner():
	var index = _partner_option.selected
	if index < 0 or index >= _partners.size() or not is_instance_valid(_partners[index]):
		return null
	return _partners[index]


func _on_trade_offered(proposer, partner, offered, requested):
	if partner != _player or _incoming_offer != null:
		return
	_incoming_offer = {"proposer": proposer, "offered": offered, "requested": requested}
	_incoming_offer_time_left_s = Constants.Match.Trade.OFFER_EXPIRY_S
	_offer_label.text = (
		tr("TRADE_INCOMING_OFFER")
		. format(
			[
				_faction_name(proposer),
				_describe_resources(offered),
				_describe_resources(requested),
			]
		)
	)
	_offer_box.show()


func _on_accept_offer_pressed():
	if _incoming_offer == null:
		return
	var proposer = _incoming_offer["proposer"]
	var result = Trade.validate(
		proposer, _player, _incoming_offer["offered"], _incoming_offer["requested"]
	)
	if result == Trade.Result.ACCEPTED:
		Trade.execute(proposer, _player, _incoming_offer["offered"], _incoming_offer["requested"])
		_result_label.text = tr("TRADE_RESULT_ACCEPTED")
	elif result == Trade.Result.PARTNER_CANNOT_AFFORD:
		_result_label.text = tr("TRADE_RESULT_PROPOSER_CANNOT_AFFORD")  # we are the partner here
	else:
		_result_label.text = tr("TRADE_RESULT_OFFER_EXPIRED")
	_dismiss_offer()


func _dismiss_offer():
	_incoming_offer = null
	_offer_box.hide()


func _on_trade_completed(proposer, partner, _offered, _requested):
	if proposer == _player or partner == _player:
		_refresh_city()


func _faction_name(player):
	var index = _partners.find(player)
	return _partner_option.get_item_text(index) if index >= 0 else "?"


func _describe_resources(resources):
	var parts = []
	for resource in resources:
		parts.append("{0} {1}".format([resources[resource], tr(resource.to_upper())]))
	return ", ".join(parts)
