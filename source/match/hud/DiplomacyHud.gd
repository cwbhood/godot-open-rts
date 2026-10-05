extends PanelContainer

# The human player's relations with every other faction, at the top of the screen: one
# chip per faction with its status and countdown. Clicking a chip opens the deal box to
# offer a non-aggression pact or an alliance, for free or for goods, with the AI's asking
# price and Good/Fair/Bad advice. Incoming treaty offers and status changes show here too.

const FactionRules = preload("res://source/data-model/Factions.gd")
const Human = preload("res://source/match/players/human/Human.gd")
const Trade = preload("res://source/match/city/Trade.gd")
const Diplomacy = preload("res://source/match/diplomacy/Diplomacy.gd")

const MAX_AMOUNT = 60
const TOAST_S = 9.0
const PRICE_REFRESH_S = 1.0
const STATE_KEYS = {
	Diplomacy.State.WAR: "DIPLOMACY_STATE_WAR",
	Diplomacy.State.NEUTRAL: "DIPLOMACY_STATE_NEUTRAL",
	Diplomacy.State.PACT: "DIPLOMACY_STATE_PACT",
	Diplomacy.State.ALLIANCE: "DIPLOMACY_STATE_ALLIANCE",
}
const STATE_HELP_KEYS = {
	Diplomacy.State.WAR: "DIPLOMACY_HELP_WAR",
	Diplomacy.State.NEUTRAL: "DIPLOMACY_HELP_NEUTRAL",
	Diplomacy.State.PACT: "DIPLOMACY_HELP_PACT",
	Diplomacy.State.ALLIANCE: "DIPLOMACY_HELP_ALLIANCE",
}
const STATE_COLORS = {
	Diplomacy.State.WAR: Color(1.0, 0.42, 0.38),
	Diplomacy.State.NEUTRAL: Color(0.85, 0.85, 0.85),
	Diplomacy.State.PACT: Color(0.5, 0.78, 1.0),
	Diplomacy.State.ALLIANCE: Color(0.45, 0.92, 0.45),
}
const RESULT_KEYS = {
	Diplomacy.Result.ACCEPTED: "DIPLOMACY_RESULT_ACCEPTED",
	Diplomacy.Result.INVALID: "TRADE_RESULT_INVALID",
	Diplomacy.Result.AT_WAR_NEEDS_PACT: "DIPLOMACY_RESULT_NEEDS_PACT",
	Diplomacy.Result.ALREADY_ALLIED: "DIPLOMACY_RESULT_ALREADY_ALLIED",
	Diplomacy.Result.PARTNER_ALLIED: "DIPLOMACY_RESULT_PARTNER_ALLIED",
	Diplomacy.Result.ALREADY_IN_EFFECT: "DIPLOMACY_RESULT_IN_EFFECT",
	Diplomacy.Result.PROPOSER_CANNOT_AFFORD: "TRADE_RESULT_PROPOSER_CANNOT_AFFORD",
	Diplomacy.Result.PARTNER_CANNOT_AFFORD: "TRADE_RESULT_PARTNER_CANNOT_AFFORD",
	Diplomacy.Result.PARTNER_REFUSED: "DIPLOMACY_RESULT_REFUSED",
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

var _player = null
var _factions = []
var _selected = null
var _incoming = null  # {"proposer", "kind", "offered", "requested", "left_s"}
var _toast_left_s = 0.0
var _since_price_refresh_s = 0.0
var _last_states = {}  # faction -> state, to tell an alliance ending from a new pact

var _chips_row = HBoxContainer.new()
var _chips = []
var _help_button = Button.new()
var _toast_label = Label.new()
var _help_label = Label.new()
var _deal_box = VBoxContainer.new()
var _deal_title = Label.new()
var _deal_status = Label.new()
var _price_label = Label.new()
var _kind_option = OptionButton.new()
var _give_amount = SpinBox.new()
var _give_resource = OptionButton.new()
var _ask_amount = SpinBox.new()
var _ask_resource = OptionButton.new()
var _their_price_button = Button.new()
var _offer_button = Button.new()
var _verdict_label = Label.new()
var _result_label = Label.new()
var _offer_box = VBoxContainer.new()
var _offer_label = Label.new()
var _offer_verdict_label = Label.new()

@onready var _match = find_parent("Match")


func _ready():
	hide()
	_build_layout()
	if not _match.is_node_ready():
		await _match.ready
	await get_tree().process_frame  # the match adds us before it sets up the players
	var humans = get_tree().get_nodes_in_group("players").filter(
		func(player): return player is Human
	)
	if humans.is_empty():
		return
	_player = humans[0]
	_factions = get_tree().get_nodes_in_group("players").filter(
		func(player): return player != _player
	)
	if _factions.is_empty():
		return
	for faction in _factions:
		var chip = Button.new()
		chip.focus_mode = Control.FOCUS_NONE
		chip.icon = _make_color_icon(faction.color)
		chip.toggle_mode = true
		chip.add_theme_font_size_override("font_size", 13)
		chip.tooltip_text = tr("DIPLOMACY_CHIP_TOOLTIP")
		chip.pressed.connect(_on_chip_pressed.bind(faction))
		_chips_row.add_child(chip)
		_chips.append(chip)
	_chips_row.move_child(_help_button, -1)
	MatchSignals.diplomacy_changed.connect(_on_diplomacy_changed)
	MatchSignals.diplomacy_offered.connect(_on_diplomacy_offered)
	MatchSignals.unit_targeted.connect(_on_unit_targeted)
	_player.changed.connect(_refresh_deal)
	_refresh_chips()
	show()


func _process(delta):
	if _player == null:
		return
	# centred at the top; anchors do not work reliably for a panel added at run time
	if size.y > get_combined_minimum_size().y + 1.0:
		reset_size()  # shrink back after the deal box or an offer closes
	position = _place()
	_refresh_chips()
	if _toast_left_s > 0.0:
		_toast_left_s -= delta
		if _toast_left_s <= 0.0:
			_toast_label.hide()
	if _incoming != null:
		_incoming["left_s"] -= delta
		if _incoming["left_s"] <= 0.0 or not is_instance_valid(_incoming["proposer"]):
			_dismiss_offer()
	_since_price_refresh_s += delta
	if _since_price_refresh_s >= PRICE_REFRESH_S:
		_since_price_refresh_s = 0.0
		_refresh_deal()  # strength changes move the prices


# Centred under the top strip, between the helper column on the left and the city panel;
# when it does not fit there it is centred on the screen.
func _place():
	var screen = get_viewport_rect().size
	var top = 40.0
	var resources = _match.get_node_or_null("HUD/MarginContainer2")
	if resources != null and resources.visible:
		top = round(resources.get_global_rect().end.y + 6.0)
	var left = 4.0
	for name in ["HelperPanel", "AutoExpandPanel"]:
		var panel = _match.get_node("HUD").find_child(name, true, false)
		if panel != null and panel.is_visible_in_tree() and panel.position.y < top + size.y:
			left = max(left, panel.get_global_rect().end.x + 6.0)
	var right = screen.x - 4.0
	var city = _match.get_node_or_null("HUD/CityHud")
	if city != null and city.visible:
		right = city.get_global_rect().position.x - 6.0
	var x = (screen.x - size.x) / 2.0
	if size.x <= right - left:
		x = clamp(x, left, right - size.x)
	return Vector2(round(max(4.0, x)), top)


func _build_layout():
	custom_minimum_size = Vector2(320, 0)
	var margin = MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 4)
	add_child(margin)
	var rows = VBoxContainer.new()
	margin.add_child(rows)

	var title = Label.new()
	title.text = tr("DIPLOMACY")
	title.theme_type_variation = "HeaderLabel"
	title.add_theme_font_size_override("font_size", 16)
	_chips_row.add_child(title)
	_chips_row.add_theme_constant_override("separation", 6)
	_chips_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_help_button.text = "?"
	_help_button.tooltip_text = tr("DIPLOMACY_HELP_TOOLTIP")
	_help_button.focus_mode = Control.FOCUS_NONE
	_help_button.toggle_mode = true
	_help_button.toggled.connect(func(on): _help_label.visible = on)
	_chips_row.add_child(_help_button)
	rows.add_child(_chips_row)

	_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.custom_minimum_size = Vector2(380, 0)
	_toast_label.add_theme_font_size_override("font_size", 14)
	_toast_label.add_theme_constant_override("outline_size", 4)
	_toast_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_toast_label.hide()
	rows.add_child(_toast_label)

	_help_label.text = tr("DIPLOMACY_RULES")
	_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_help_label.custom_minimum_size = Vector2(420, 0)
	_help_label.add_theme_font_size_override("font_size", 12)
	_help_label.hide()
	rows.add_child(_help_label)

	_build_deal_box()
	rows.add_child(_deal_box)
	_build_offer_box()
	rows.add_child(_offer_box)


func _build_deal_box():
	_deal_box.add_child(HSeparator.new())
	_deal_title.add_theme_font_size_override("font_size", 15)
	_deal_box.add_child(_deal_title)
	for label in [_deal_status, _price_label]:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.custom_minimum_size = Vector2(420, 0)
		label.add_theme_font_size_override("font_size", 12)
		_deal_box.add_child(label)

	var kind_row = HBoxContainer.new()
	kind_row.add_child(_make_label("DIPLOMACY_OFFER_KIND"))
	_kind_option.add_item(tr("DIPLOMACY_KIND_PACT"))
	_kind_option.add_item(tr("DIPLOMACY_KIND_ALLIANCE"))
	_kind_option.focus_mode = Control.FOCUS_NONE
	_kind_option.item_selected.connect(func(_index): _refresh_deal())
	kind_row.add_child(_kind_option)
	_their_price_button.text = tr("DIPLOMACY_USE_THEIR_PRICE")
	_their_price_button.tooltip_text = tr("DIPLOMACY_USE_THEIR_PRICE_TOOLTIP")
	_their_price_button.focus_mode = Control.FOCUS_NONE
	_their_price_button.pressed.connect(_on_their_price_pressed)
	kind_row.add_child(_their_price_button)
	_deal_box.add_child(kind_row)

	var give_row = HBoxContainer.new()
	give_row.add_child(_make_label("DIPLOMACY_YOU_GIVE"))
	_setup_amount(_give_amount)
	give_row.add_child(_give_amount)
	_setup_resource_option(_give_resource)
	give_row.add_child(_give_resource)
	_deal_box.add_child(give_row)
	var ask_row = HBoxContainer.new()
	ask_row.add_child(_make_label("DIPLOMACY_YOU_ASK"))
	_setup_amount(_ask_amount)
	ask_row.add_child(_ask_amount)
	_setup_resource_option(_ask_resource)
	ask_row.add_child(_ask_resource)
	_deal_box.add_child(ask_row)

	_setup_verdict_label(_verdict_label)
	_deal_box.add_child(_verdict_label)
	_offer_button.text = tr("DIPLOMACY_OFFER")
	_offer_button.focus_mode = Control.FOCUS_NONE
	_offer_button.pressed.connect(_on_offer_pressed)
	_deal_box.add_child(_offer_button)
	_result_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_result_label.custom_minimum_size = Vector2(420, 0)
	_result_label.add_theme_font_size_override("font_size", 13)
	_deal_box.add_child(_result_label)
	_deal_box.hide()


func _build_offer_box():
	_offer_box.add_child(HSeparator.new())
	_offer_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_offer_label.custom_minimum_size = Vector2(420, 0)
	_offer_box.add_child(_offer_label)
	_setup_verdict_label(_offer_verdict_label)
	_offer_box.add_child(_offer_verdict_label)
	var buttons = HBoxContainer.new()
	var accept = Button.new()
	accept.text = tr("TRADE_ACCEPT")
	accept.focus_mode = Control.FOCUS_NONE
	accept.pressed.connect(_on_accept_offer_pressed)
	buttons.add_child(accept)
	var decline = Button.new()
	decline.text = tr("TRADE_DECLINE")
	decline.focus_mode = Control.FOCUS_NONE
	decline.pressed.connect(_dismiss_offer)
	buttons.add_child(decline)
	_offer_box.add_child(buttons)
	_offer_box.hide()


func _make_label(key):
	var label = Label.new()
	label.text = tr(key)
	label.custom_minimum_size = Vector2(70, 0)
	return label


func _setup_amount(spin_box):
	spin_box.min_value = 0
	spin_box.max_value = MAX_AMOUNT
	spin_box.value = 0
	spin_box.focus_mode = Control.FOCUS_NONE
	spin_box.get_line_edit().focus_mode = Control.FOCUS_CLICK
	spin_box.value_changed.connect(func(_value): _refresh_deal())


func _setup_resource_option(option):
	for resource in Constants.Match.Resources.ALL:
		option.add_item(tr(resource.to_upper()))
	option.focus_mode = Control.FOCUS_NONE
	option.item_selected.connect(func(_index): _refresh_deal())


func _setup_verdict_label(label):
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(420, 0)
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_constant_override("outline_size", 3)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))


func _make_color_icon(color):
	var image = Image.create(14, 14, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


# state


func _diplomacy():
	return Diplomacy.instance


func faction_name(player):
	"""the player's faction and colour (e.g. "Sandline Syndicate (Red)"), or the same
	numbering as the trade panel for players without a faction"""
	var label = FactionRules.label_for(player)
	if label != "":
		return label
	var index = _factions.find(player)
	return tr("TRADE_FACTION").format([index + 1]) if index >= 0 else "?"


func status_text(faction):
	var diplomacy = _diplomacy()
	if diplomacy == null:
		return ""
	var state = diplomacy.get_state(_player, faction)
	var text = tr(STATE_KEYS[state])
	var left = diplomacy.seconds_left(_player, faction)
	if left > 0.0:
		text += " " + _clock(left)
	return text


static func _clock(seconds):
	var whole = int(ceil(seconds))
	return "%d:%02d" % [whole / 60, whole % 60]


func _kind():
	return Diplomacy.KINDS[_kind_option.selected]


func _goods(amount_box, resource_option):
	var amount = int(amount_box.value)
	if amount <= 0:
		return {}
	return {Constants.Match.Resources.ALL[resource_option.selected]: amount}


func _describe(resources):
	var parts = []
	for resource in resources:
		parts.append("{0} {1}".format([resources[resource], tr(resource.to_upper())]))
	return ", ".join(parts) if not parts.is_empty() else tr("DIPLOMACY_NOTHING")


func _refresh_chips():
	var diplomacy = _diplomacy()
	if diplomacy == null:
		return
	for i in range(_factions.size()):
		var faction = _factions[i]
		if not is_instance_valid(faction):
			continue
		var chip = _chips[i]
		chip.text = "{0}: {1}".format([faction_name(faction), status_text(faction)])
		var color = STATE_COLORS[diplomacy.get_state(_player, faction)]
		chip.add_theme_color_override("font_color", color)
		chip.add_theme_color_override("font_pressed_color", color)
		chip.add_theme_color_override("font_hover_color", color.lightened(0.2))
		chip.button_pressed = faction == _selected
	if _selected != null:
		_deal_title.text = "{0}: {1}".format([faction_name(_selected), status_text(_selected)])


func _refresh_deal():
	var diplomacy = _diplomacy()
	if _selected == null or diplomacy == null or not is_instance_valid(_selected):
		return
	var state = diplomacy.get_state(_player, _selected)
	_deal_status.text = tr(STATE_HELP_KEYS[state])
	var ally = diplomacy.get_ally(_selected)
	if ally != null and ally != _player:
		_deal_status.text += " " + tr("DIPLOMACY_THEY_HAVE_ALLY").format([faction_name(ally)])
	var lines = []
	for kind in Diplomacy.KINDS:
		lines.append(_price_line(diplomacy, kind))
	_price_label.text = "\n".join(lines)
	var can_sign = diplomacy.can_sign(_player, _selected, _kind())
	_offer_button.disabled = can_sign != Diplomacy.Result.ACCEPTED
	_their_price_button.disabled = _offer_button.disabled
	if can_sign != Diplomacy.Result.ACCEPTED:
		_verdict_label.text = tr(RESULT_KEYS[can_sign])
		_verdict_label.add_theme_color_override("font_color", Color(0.85, 0.85, 0.85))
		return
	_show_verdict(
		_verdict_label,
		_selected,
		_kind(),
		_goods(_give_amount, _give_resource),
		_goods(_ask_amount, _ask_resource)
	)


func _price_line(diplomacy, kind):
	var name = tr("DIPLOMACY_KIND_PACT" if kind == Diplomacy.PACT else "DIPLOMACY_KIND_ALLIANCE")
	var can_sign = diplomacy.can_sign(_player, _selected, kind)
	if can_sign != Diplomacy.Result.ACCEPTED:
		return "{0}: {1}".format([name, tr(RESULT_KEYS[can_sign])])
	if not Diplomacy.is_ai(_selected):
		return name
	var price = Diplomacy.ai_asking_price(_selected, _player, kind)
	if price == null:
		return "{0}: {1}".format([name, tr("DIPLOMACY_PRICE_NEVER")])
	if not price["requested"].is_empty():
		return "{0}: {1}".format(
			[name, tr("DIPLOMACY_PRICE_ASKS").format([_describe(price["requested"])])]
		)
	if not price["offered"].is_empty():
		return "{0}: {1}".format(
			[name, tr("DIPLOMACY_PRICE_PAYS").format([_describe(price["offered"])])]
		)
	return "{0}: {1}".format([name, tr("DIPLOMACY_PRICE_FREE")])


func _show_verdict(label, other, kind, given, received):
	var assessment = Diplomacy.assess(_player, other, kind, given, received)
	label.text = "{0}: {1}".format([tr(VERDICT_KEYS[assessment["verdict"]]), assessment["reason"]])
	label.add_theme_color_override("font_color", VERDICT_COLORS[assessment["verdict"]])


func _toast(text, color = Color.WHITE):
	_toast_label.text = text
	_toast_label.add_theme_color_override("font_color", color)
	_toast_label.show()
	_toast_left_s = TOAST_S


# events


func _on_chip_pressed(faction):
	_selected = null if _selected == faction else faction
	_deal_box.visible = _selected != null
	_result_label.text = ""
	if _selected != null:
		var diplomacy = _diplomacy()
		var state = diplomacy.get_state(_player, faction) if diplomacy != null else null
		# preselect what makes sense next: a pact after a war, otherwise an alliance
		_kind_option.select(1 if state in [Diplomacy.State.NEUTRAL, Diplomacy.State.PACT] else 0)
		if diplomacy != null:  # ...unless that one is off the table (e.g. they have an ally)
			for index in range(Diplomacy.KINDS.size()):
				if (
					diplomacy.can_sign(_player, faction, _kind()) != Diplomacy.Result.ACCEPTED
					and (
						diplomacy.can_sign(_player, faction, Diplomacy.KINDS[index])
						== Diplomacy.Result.ACCEPTED
					)
				):
					_kind_option.select(index)
		_on_their_price_pressed()
	_refresh_chips()
	_refresh_deal()


func _on_their_price_pressed():
	if _selected == null or not Diplomacy.is_ai(_selected):
		return
	var price = Diplomacy.ai_asking_price(_selected, _player, _kind())
	_give_amount.set_value_no_signal(0)
	_ask_amount.set_value_no_signal(0)
	if price != null:
		for resource in price["requested"]:  # what they ask is what we give
			_give_amount.set_value_no_signal(min(MAX_AMOUNT, price["requested"][resource]))
			_give_resource.select(Constants.Match.Resources.ALL.find(resource))
		for resource in price["offered"]:
			_ask_amount.set_value_no_signal(min(MAX_AMOUNT, price["offered"][resource]))
			_ask_resource.select(Constants.Match.Resources.ALL.find(resource))
	_refresh_deal()


func _on_offer_pressed():
	var diplomacy = _diplomacy()
	if _selected == null or diplomacy == null:
		return
	var result = diplomacy.propose(
		_player,
		_selected,
		_kind(),
		_goods(_give_amount, _give_resource),
		_goods(_ask_amount, _ask_resource)
	)
	_result_label.text = tr(RESULT_KEYS[result])
	_refresh_deal()


func _on_diplomacy_changed(a, b, state):
	_refresh_chips()
	_refresh_deal()
	if a != _player and b != _player:
		if state in [Diplomacy.State.WAR, Diplomacy.State.ALLIANCE]:
			_toast(
				(
					tr(
						(
							"DIPLOMACY_TOAST_OTHERS_WAR"
							if state == Diplomacy.State.WAR
							else "DIPLOMACY_TOAST_OTHERS_ALLIANCE"
						)
					)
					. format([faction_name(a), faction_name(b)])
				),
				STATE_COLORS[state]
			)
		return
	var other = b if a == _player else a
	var key = (
		{
			Diplomacy.State.PACT: "DIPLOMACY_TOAST_PACT",
			Diplomacy.State.ALLIANCE: "DIPLOMACY_TOAST_ALLIANCE",
			Diplomacy.State.NEUTRAL: "DIPLOMACY_TOAST_NEUTRAL",
		}
		. get(state, "DIPLOMACY_TOAST_ATTACKED")
	)
	var diplomacy = _diplomacy()
	if state == Diplomacy.State.WAR and diplomacy.aggressor(a, b) == _player:
		key = "DIPLOMACY_TOAST_YOU_ATTACKED"
	if state == Diplomacy.State.PACT and _last_states.get(other) == Diplomacy.State.ALLIANCE:
		key = "DIPLOMACY_TOAST_ALLIANCE_ENDED"
	_last_states[other] = state
	_toast(tr(key).format([faction_name(other)]), STATE_COLORS[state])


func _on_diplomacy_offered(proposer, partner, kind, offered, requested):
	if partner != _player or _incoming != null:
		return
	_incoming = {
		"proposer": proposer,
		"kind": kind,
		"offered": offered,
		"requested": requested,
		"left_s": Constants.Match.Diplomacy.OFFER_EXPIRY_S,
	}
	var kind_name = tr(
		"DIPLOMACY_KIND_PACT" if kind == Diplomacy.PACT else "DIPLOMACY_KIND_ALLIANCE"
	)
	var key = "DIPLOMACY_INCOMING_FREE"
	if not offered.is_empty():
		key = "DIPLOMACY_INCOMING_PAYS"
	elif not requested.is_empty():
		key = "DIPLOMACY_INCOMING_ASKS"
	_offer_label.text = tr(key).format(
		[faction_name(proposer), kind_name, _describe(offered), _describe(requested)]
	)
	# their offer is what we receive, their request is what we give
	_show_verdict(_offer_verdict_label, proposer, kind, requested, offered)
	_offer_box.show()


func _on_accept_offer_pressed():
	var diplomacy = _diplomacy()
	if _incoming == null or diplomacy == null:
		return
	var proposer = _incoming["proposer"]
	var result = diplomacy.validate(
		proposer, _player, _incoming["kind"], _incoming["offered"], _incoming["requested"]
	)
	if result == Diplomacy.Result.ACCEPTED:
		diplomacy.sign_treaty(
			proposer, _player, _incoming["kind"], _incoming["offered"], _incoming["requested"]
		)
	else:
		_toast(tr("TRADE_RESULT_OFFER_EXPIRED"))
	_dismiss_offer()


func _dismiss_offer():
	_incoming = null
	_offer_box.hide()


func _on_unit_targeted(unit):
	"""right-clicking a faction you have a treaty with explains why nothing happens"""
	if not "player" in unit or unit.player == _player or unit.player == null:
		return
	if Diplomacy.can_attack(_player, unit.player):
		return
	_toast(
		tr("DIPLOMACY_TOAST_PROTECTED").format(
			[faction_name(unit.player), status_text(unit.player)]
		),
		STATE_COLORS[_diplomacy().get_state(_player, unit.player)]
	)
