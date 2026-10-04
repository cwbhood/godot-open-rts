extends PanelContainer

# Shows the human player's city, supply lines and the commodity market, and lets them
# trade with other factions.

const Human = preload("res://source/match/players/human/Human.gd")
const Trade = preload("res://source/match/city/Trade.gd")
const CivilDefense = preload("res://source/match/city/CivilDefense.gd")

const MAX_TRADE_AMOUNT = 40
const RESULT_MESSAGES = {
	Trade.Result.ACCEPTED: "TRADE_RESULT_ACCEPTED",
	Trade.Result.INVALID: "TRADE_RESULT_INVALID",
	Trade.Result.PROPOSER_CANNOT_AFFORD: "TRADE_RESULT_PROPOSER_CANNOT_AFFORD",
	Trade.Result.PARTNER_CANNOT_AFFORD: "TRADE_RESULT_PARTNER_CANNOT_AFFORD",
	Trade.Result.PARTNER_BUSY: "TRADE_RESULT_PARTNER_BUSY",
	Trade.Result.PARTNER_REFUSED: "TRADE_RESULT_PARTNER_REFUSED",
	Trade.Result.EMBARGO: "TRADE_RESULT_EMBARGO",
	Trade.Result.AT_WAR: "TRADE_RESULT_AT_WAR",
}
const VERDICT_KEYS = {
	Trade.Verdict.GOOD: "TRADE_VERDICT_GOOD_TITLE",
	Trade.Verdict.FAIR: "TRADE_VERDICT_FAIR_TITLE",
	Trade.Verdict.BAD: "TRADE_VERDICT_BAD_TITLE",
}
const VERDICT_COLORS = {
	Trade.Verdict.GOOD: Color(0.45, 0.9, 0.45),
	Trade.Verdict.FAIR: Color(0.95, 0.85, 0.35),
	Trade.Verdict.BAD: Color(1.0, 0.45, 0.4),
}
const THREAT_KEYS = {
	CivilDefense.ThreatLevel.NONE: "THREAT_NONE",
	CivilDefense.ThreatLevel.CONTAINED: "THREAT_CONTAINED",
	CivilDefense.ThreatLevel.OVERWHELMING: "THREAT_OVERWHELMING",
}

var _player = null
var _partners = []
var _incoming_offer = null
var _incoming_offer_time_left_s = 0.0

var _tier_label = Label.new()
var _science_bar = ProgressBar.new()
var _population_label = Label.new()
var _satisfaction_label = Label.new()
var _warehouse_label = Label.new()
var _defense_label = Label.new()
var _logistics_label = Label.new()
var _surplus_row = HBoxContainer.new()
var _surplus_label = Label.new()
var _recycle_button = Button.new()
var _partner_option = OptionButton.new()
var _prices_label = Label.new()
var _give_amount = SpinBox.new()
var _give_resource_option = OptionButton.new()
var _get_amount = SpinBox.new()
var _get_resource_option = OptionButton.new()
var _fair_label = Label.new()
var _verdict_label = Label.new()
var _propose_button = Button.new()
var _agreement_button = Button.new()
var _embargo_button = Button.new()
var _result_label = Label.new()
var _agreements_label = Label.new()
var _offer_box = VBoxContainer.new()
var _offer_label = Label.new()
var _offer_verdict_label = Label.new()
var _scroll = ScrollContainer.new()  # the body scrolls when the screen is too short for it
var _rows = VBoxContainer.new()
var _collapse_button = Button.new()
var _unit_menus = null
var _production_queue = null

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
	_player.changed.connect(_refresh_trade)
	MatchSignals.trade_offered.connect(_on_trade_offered)
	MatchSignals.trade_completed.connect(_on_trade_completed)
	MatchSignals.agreement_changed.connect(func(_a, _b): _refresh_trade())
	MatchSignals.embargo_changed.connect(func(_a, _b, _active): _refresh_trade())
	_refresh_partners()
	_refresh_city()
	_refresh_trade()
	show()


func _process(delta):
	_fit_to_screen()
	if _incoming_offer == null:
		return
	_incoming_offer_time_left_s -= delta
	if _incoming_offer_time_left_s <= 0.0 or not is_instance_valid(_incoming_offer["proposer"]):
		_dismiss_offer()


func _build_layout():
	custom_minimum_size = Vector2(340, 0)
	var margin = MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	add_child(margin)
	var column = VBoxContainer.new()
	margin.add_child(column)
	var header = HBoxContainer.new()
	var title = _make_title("CITY")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_collapse_button.text = "-"
	_collapse_button.focus_mode = Control.FOCUS_NONE
	_collapse_button.custom_minimum_size = Vector2(28, 0)
	_collapse_button.tooltip_text = tr("CITY_PANEL_COLLAPSE_TOOLTIP")
	_collapse_button.pressed.connect(_on_collapse_pressed)
	header.add_child(_collapse_button)
	column.add_child(header)
	column.add_child(_offer_box)  # incoming offers stay on top, they expire quickly
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.add_child(_rows)
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_child(_scroll)
	var rows = _rows

	rows.add_child(_tier_label)
	_science_bar.custom_minimum_size = Vector2(0, 10)
	_science_bar.show_percentage = false
	rows.add_child(_science_bar)
	for label in [
		_population_label, _satisfaction_label, _warehouse_label, _defense_label, _logistics_label
	]:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_font_size_override("font_size", 13)
		rows.add_child(label)
	# too many trucks for the work there is: offer to recycle the idle ones
	_surplus_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_surplus_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_surplus_label.add_theme_font_size_override("font_size", 13)
	_surplus_label.modulate = Color(1.0, 0.85, 0.4)
	_surplus_row.add_child(_surplus_label)
	_recycle_button.focus_mode = Control.FOCUS_NONE
	_recycle_button.pressed.connect(_on_recycle_pressed)
	_surplus_row.add_child(_recycle_button)
	_surplus_row.hide()
	rows.add_child(_surplus_row)

	rows.add_child(HSeparator.new())
	rows.add_child(_make_title("TRADE"))
	var partner_row = HBoxContainer.new()
	partner_row.add_child(_make_label("TRADE_PARTNER"))
	_partner_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_partner_option.focus_mode = Control.FOCUS_NONE
	_partner_option.item_selected.connect(func(_index): _refresh_trade())
	partner_row.add_child(_partner_option)
	_embargo_button.focus_mode = Control.FOCUS_NONE
	_embargo_button.pressed.connect(_on_embargo_pressed)
	partner_row.add_child(_embargo_button)
	rows.add_child(partner_row)
	_prices_label.add_theme_font_size_override("font_size", 12)
	rows.add_child(_prices_label)

	var give_row = HBoxContainer.new()
	give_row.add_child(_make_label("TRADE_GIVE"))
	_setup_amount(_give_amount, 6)
	give_row.add_child(_give_amount)
	_setup_resource_option(_give_resource_option, 1)
	give_row.add_child(_give_resource_option)
	rows.add_child(give_row)

	var get_row = HBoxContainer.new()
	get_row.add_child(_make_label("TRADE_GET"))
	_setup_amount(_get_amount, 3)
	get_row.add_child(_get_amount)
	_setup_resource_option(_get_resource_option, 3)
	get_row.add_child(_get_resource_option)
	rows.add_child(get_row)
	_fair_label.add_theme_font_size_override("font_size", 12)
	rows.add_child(_fair_label)
	_setup_verdict_label(_verdict_label)
	rows.add_child(_verdict_label)

	var buttons_row = HBoxContainer.new()
	_propose_button.text = tr("TRADE_PROPOSE")
	_propose_button.focus_mode = Control.FOCUS_NONE
	_propose_button.pressed.connect(_on_propose_pressed.bind(false))
	buttons_row.add_child(_propose_button)
	_agreement_button.text = tr("TRADE_PROPOSE_AGREEMENT")
	_agreement_button.tooltip_text = tr("TRADE_AGREEMENT_TOOLTIP")
	_agreement_button.focus_mode = Control.FOCUS_NONE
	_agreement_button.pressed.connect(_on_propose_pressed.bind(true))
	buttons_row.add_child(_agreement_button)
	rows.add_child(buttons_row)
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rows.add_child(_result_label)
	_agreements_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_agreements_label.add_theme_font_size_override("font_size", 12)
	rows.add_child(_agreements_label)

	_offer_box.add_child(HSeparator.new())
	_offer_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_offer_box.add_child(_offer_label)
	_setup_verdict_label(_offer_verdict_label)
	_offer_box.add_child(_offer_verdict_label)
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
	_offer_box.add_child(HSeparator.new())
	_offer_box.hide()


func _fit_to_screen():
	"""keeps the panel clear of the unit menu and on screen, scrolling its body if needed"""
	if _unit_menus == null and _match != null:
		_unit_menus = _match.find_child("UnitMenus", true, false)
		_production_queue = _match.get_node_or_null(
			"HUD/MarginContainer3/VBoxContainer/ProductionQueue"
		)
	var bottom = get_viewport_rect().size.y - 5.0
	if _unit_menus != null and _unit_menus.is_visible_in_tree():
		bottom = min(bottom, _unit_menus.global_position.y - 6.0)
	if (
		_production_queue != null
		and _production_queue.is_visible_in_tree()
		and _production_queue.find_child("QueueElements").get_child_count() > 0
	):
		bottom = min(bottom, _production_queue.global_position.y - 6.0)
	var wanted = _rows.get_combined_minimum_size().y if _scroll.visible else 0.0
	var chrome = get_combined_minimum_size().y - _scroll.custom_minimum_size.y
	var room = max(80.0, bottom - global_position.y - chrome)
	var height = min(wanted, room)
	if not is_equal_approx(_scroll.custom_minimum_size.y, height):
		_scroll.custom_minimum_size.y = height
		reset_size()


func _on_collapse_pressed():
	_scroll.visible = not _scroll.visible
	_collapse_button.text = "-" if _scroll.visible else "+"
	reset_size()


func _setup_verdict_label(label):
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_constant_override("outline_size", 3)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))


func _show_verdict(label, given, received):
	"""tells the player whether giving 'given' for 'received' makes sense for them now"""
	var assessment = Trade.assess(_player, given, received)
	label.text = "{0}: {1}".format([tr(VERDICT_KEYS[assessment["verdict"]]), assessment["reason"]])
	label.add_theme_color_override("font_color", VERDICT_COLORS[assessment["verdict"]])


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
	spin_box.value_changed.connect(func(_value): _refresh_trade())


func _setup_resource_option(option, selected):
	for resource in Constants.Match.Resources.ALL:
		option.add_item(tr(resource.to_upper()))
	option.select(min(selected, Constants.Match.Resources.ALL.size() - 1))
	option.focus_mode = Control.FOCUS_NONE
	option.item_selected.connect(func(_index): _refresh_trade())


func _give_resource():
	return Constants.Match.Resources.ALL[_give_resource_option.selected]


func _get_resource():
	return Constants.Match.Resources.ALL[_get_resource_option.selected]


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
	var next_science = city.get_next_tier_science()
	_tier_label.text = tr("CITY_TIER").format([city.tier, tr(city.get_tier_name())])
	if next_science == null:
		_science_bar.max_value = 1.0
		_science_bar.value = 1.0
		_science_bar.tooltip_text = tr("CITY_SCIENCE_DONE").format([int(city.science)])
	else:
		_science_bar.max_value = next_science
		_science_bar.value = city.science
		_science_bar.tooltip_text = tr("CITY_SCIENCE").format(
			[
				int(city.science),
				int(next_science),
				tr(city.get_tier_name(city.tier + 1)),
				"%.2f" % city.science_per_s
			]
		)
	_population_label.text = tr("CITY_POPULATION").format(
		[int(city.population), int(city.housing), "%+.2f" % city.growth_per_s]
	)
	if city.trade_growth_boost > 0.0:
		_population_label.text += " " + tr("CITY_TRADE_BOOST")
	if not city.has_core():
		_population_label.text += " " + tr("CITY_NO_CORE")
	_population_label.text += (
		"\n"
		+ tr("CITY_BUILDINGS").format(
			[
				city.get_buildings_count("house"),
				city.get_buildings_count("workshop"),
				int(round((city.production_multiplier - 1.0) * 100.0))
			]
		)
	)
	var needs = []
	for resource in Constants.Match.Resources.ALL:
		needs.append(
			"{0} {1}%".format(
				[tr(resource.to_upper()), int(round(city.satisfaction.get(resource, 1.0) * 100))]
			)
		)
	_satisfaction_label.text = (
		tr("CITY_SATISFACTION")
		. format(
			[
				int(round(city.get_satisfaction() * 100)),
				", ".join(needs),
				int(round(city.power_ratio * 100)),
			]
		)
	)
	var stores = []
	for resource in Constants.Match.Resources.ALL:
		stores.append(
			"{0} {1}".format([tr(resource.to_upper()), int(city.warehouse.get(resource, 0.0))])
		)
	_warehouse_label.text = tr("CITY_WAREHOUSE").format(
		[", ".join(stores), int(Constants.Match.City.DELIVERY_SHARE * 100)]
	)
	var defense = city.civil_defense
	if defense != null:
		_defense_label.text = (
			tr("CITY_DEFENSE")
			. format(
				[
					defense.get_posts().size(),
					defense.get_militia().size(),
					tr(THREAT_KEYS[defense.threat_level]),
				]
			)
		)
		_defense_label.modulate = (
			Color.ORANGE_RED
			if defense.threat_level == CivilDefense.ThreatLevel.OVERWHELMING
			else Color.WHITE
		)
	_refresh_logistics()


func _refresh_logistics():
	var logistics = _player.logistics
	if logistics == null:
		return
	var fleet = logistics.fleet.get_fleet_counts()
	_logistics_label.text = (
		tr("LOGISTICS_FLEET")
		. format(
			[
				fleet["total"],
				fleet["working"],
				fleet["standby"],
				fleet["parked"],
				int(ceil(logistics.fleet.truck_demand)),
				fleet["trains"],
				"%.1f" % logistics.fleet.get_upkeep_per_min(),
			]
		)
	)
	_logistics_label.text += (
		"\n"
		+ (
			tr("LOGISTICS_SUMMARY")
			. format(
				[
					Utils.Dict.sum(logistics.delivered_total),
					Utils.Dict.sum(logistics.lost_total),
					Utils.Dict.sum(logistics.looted_total),
				]
			)
		)
	)
	if fleet["recycling"] > 0:
		_logistics_label.text += " " + tr("LOGISTICS_RECYCLING").format([fleet["recycling"]])
	if logistics.out_of_fuel:
		_logistics_label.text += "\n" + tr("OUT_OF_FUEL")
	var surplus = logistics.fleet.surplus_trucks
	_surplus_row.visible = surplus > 0
	if surplus > 0:
		var refund = logistics.fleet.get_recycle_refund_text(surplus)
		_surplus_label.text = tr("LOGISTICS_SURPLUS").format([surplus])
		_recycle_button.text = tr("LOGISTICS_RECYCLE_BUTTON").format([surplus])
		_recycle_button.tooltip_text = tr("LOGISTICS_RECYCLE_TOOLTIP").format(
			[
				int(
					round(float(Constants.Match.Logistics.FLEET.get("recycle_refund", 0.75)) * 100)
				),
				refund
			]
		)


func _on_recycle_pressed():
	if _player != null and _player.logistics != null:
		_player.logistics.fleet.recycle_surplus()
	_refresh_logistics()


func _refresh_trade():
	if _player == null:
		return
	_refresh_offer_verdict()  # stock changes can turn a fine offer into a bad one
	var partner = _selected_partner()
	var price_lines = [tr("TRADE_PRICES_HEADER")]
	for resource in Constants.Match.Resources.ALL:
		(
			price_lines
			. append(
				(
					"{0}: {1} / {2}"
					. format(
						[
							tr(resource.to_upper()),
							"%.1f" % Trade.local_price(_player, resource),
							(
								"%.1f" % Trade.local_price(partner, resource)
								if partner != null
								else "-"
							),
						]
					)
				)
			)
		)
	_prices_label.text = "\n".join(price_lines)
	if partner != null:
		_fair_label.text = (
			tr("TRADE_FAIR_AMOUNT")
			. format(
				[
					Trade.fair_amount(
						partner, _give_resource(), int(_give_amount.value), _get_resource()
					),
					tr(_get_resource().to_upper()),
				]
			)
		)
		_show_verdict(
			_verdict_label,
			{_give_resource(): int(_give_amount.value)},
			{_get_resource(): int(_get_amount.value)}
		)
		var market = _match.get_node_or_null("Market")
		var embargoed = market != null and market.is_embargoed(_player, partner)
		_embargo_button.text = tr("TRADE_LIFT_EMBARGO" if embargoed else "TRADE_EMBARGO")
		var agreement_lines = []
		if market != null:
			for agreement in market.agreements_of(_player):
				var mine_is_a = agreement["a"] == _player
				(
					agreement_lines
					. append(
						(
							tr("TRADE_AGREEMENT_LINE")
							. format(
								[
									_faction_name(agreement["b"] if mine_is_a else agreement["a"]),
									_describe_resources(
										(
											agreement["offered"]
											if mine_is_a
											else agreement["requested"]
										)
									),
									_describe_resources(
										(
											agreement["requested"]
											if mine_is_a
											else agreement["offered"]
										)
									),
									agreement["remaining"],
								]
							)
						)
					)
				)
		_agreements_label.text = "\n".join(agreement_lines)


func _on_propose_pressed(as_agreement):
	var partner = _selected_partner()
	if partner == null:
		return
	var offered = {_give_resource(): int(_give_amount.value)}
	var requested = {_get_resource(): int(_get_amount.value)}
	var result = Trade.Result.PARTNER_REFUSED
	if not partner is Human:
		if as_agreement:
			result = _match.get_node("Market").propose_agreement(
				_player, partner, offered, requested
			)
		else:
			result = Trade.propose(_player, partner, offered, requested)
	_result_label.text = tr(RESULT_MESSAGES[result])
	_refresh_trade()


func _on_embargo_pressed():
	var partner = _selected_partner()
	var market = _match.get_node_or_null("Market")
	if partner == null or market == null:
		return
	if market.is_embargoed(_player, partner):
		market.lift_embargo(_player, partner)
	else:
		market.impose_embargo(_player, partner, INF)
	_refresh_trade()


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
	_refresh_offer_verdict()
	_offer_box.show()


func _refresh_offer_verdict():
	if _incoming_offer == null:
		return
	# the proposer's offer is what we receive, its request is what we give
	_show_verdict(_offer_verdict_label, _incoming_offer["requested"], _incoming_offer["offered"])


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
		_refresh_trade()


func _faction_name(player):
	var index = _partners.find(player)
	return _partner_option.get_item_text(index) if index >= 0 else "?"


func _describe_resources(resources):
	var parts = []
	for resource in resources:
		parts.append("{0} {1}".format([resources[resource], tr(resource.to_upper())]))
	return ", ".join(parts)
