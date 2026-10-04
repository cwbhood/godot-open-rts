extends Control

# Teaches the game while it is played:
# - a tutorial at the top of the screen walking through the first goals, one at a time,
#   each ticked off by what the player actually does (it can be folded away; the choice
#   is remembered between matches),
# - one-off hints that pop up below it the first time something worth explaining happens
#   (a blackout, a site outside the yard, a crashed drone...),
# - the auto-expand overview on the left,
# - the manual (F1, or the Help button).

const Human = preload("res://source/match/players/human/Human.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const AutoExpand = preload("res://source/match/units/traits/AutoExpand.gd")
const AutoExpandPanel = preload("res://source/match/hud/AutoExpandPanel.gd")
const AutoExpandBar = preload("res://source/match/hud/AutoExpandBar.gd")
const HelpWindow = preload("res://source/match/hud/HelpWindow.gd")

const SETTINGS_PATH = "user://guide.cfg"
const REFRESH_INTERVAL_S = 0.5
const HINT_DURATION_S = 12.0
const PANEL_WIDTH = 520
const DONE_COLOR = Color(0.55, 1.0, 0.55)
# tutorial steps in order: translation key suffix and the help topic that explains it
const STEPS = [
	["SELECT_CONSTRUCTOR", "CONSTRUCTORS"],
	["BUILD_EXTRACTOR", "CONSTRUCTORS"],
	["FINISH_EXTRACTOR", "CONSTRUCTORS"],
	["DELIVERY", "SUPPLY_LINES"],
	["POWER", "POWER"],
	["AUTO_EXPAND", "AUTO_EXPAND"],
	["TIER", "CITY_TIERS"],
	["TRADE", "TRADE"],
	["ARMY", "COMBAT"],
]

var player = null
var help_window = null
var auto_expand_panel = null
var auto_expand_bar = null

var _step = 0
var _delivered = false
var _traded = false
var _army = false
var _hints_shown = {}
var _hint_queue = []
var _hint_time_left_s = 0.0
var _since_refresh_s = REFRESH_INTERVAL_S

var _tutorial = PanelContainer.new()
var _tutorial_title = Label.new()
var _tutorial_body = Label.new()
var _tutorial_details = VBoxContainer.new()
var _skip_button = Button.new()
var _more_button = Button.new()
var _fold_button = Button.new()
var _hint_panel = PanelContainer.new()
var _hint_label = Label.new()


func _ready():
	name = "Guide"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_tutorial()
	_build_hint()
	auto_expand_panel = AutoExpandPanel.new()
	add_child(auto_expand_panel)
	auto_expand_bar = AutoExpandBar.new()  # placed left of the unit menu, see _layout
	add_child(auto_expand_bar)
	help_window = HelpWindow.new()
	add_child(help_window)
	MatchSignals.match_started.connect(_on_match_started)
	MatchSignals.goods_delivered.connect(_on_goods_delivered)
	MatchSignals.trade_completed.connect(_on_trade_completed)
	MatchSignals.unit_production_finished.connect(_on_unit_production_finished)
	MatchSignals.unit_spawned.connect(_on_unit_spawned)
	MatchSignals.power_changed.connect(_on_power_changed)
	MatchSignals.tier_reached.connect(_on_tier_reached)
	MatchSignals.not_enough_resources_for_construction.connect(
		func(a_player): _on_short_of_resources(a_player, "HINT_NOT_ENOUGH_FOR_CONSTRUCTION")
	)
	MatchSignals.not_enough_resources_for_production.connect(
		func(a_player): _on_short_of_resources(a_player, "HINT_NOT_ENOUGH_FOR_PRODUCTION")
	)
	MatchSignals.aircraft_crashed.connect(_on_aircraft_crashed)
	MatchSignals.cargo_destroyed.connect(_on_cargo_destroyed)
	_on_match_started()


func _build_tutorial():
	_tutorial.name = "Tutorial"
	_tutorial.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	add_child(_tutorial)
	var margin = MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	_tutorial.add_child(margin)
	var box = VBoxContainer.new()
	margin.add_child(box)
	var header = HBoxContainer.new()
	box.add_child(header)
	_tutorial_title.add_theme_font_size_override("font_size", 17)
	_tutorial_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_tutorial_title)
	var help_button = Button.new()
	help_button.text = tr("GUIDE_HELP_BUTTON")
	help_button.tooltip_text = tr("GUIDE_HELP_TOOLTIP")
	help_button.focus_mode = Control.FOCUS_NONE
	help_button.pressed.connect(func(): toggle_help())
	header.add_child(help_button)
	_fold_button.focus_mode = Control.FOCUS_NONE
	_fold_button.pressed.connect(func(): _set_folded(_tutorial_details.visible))
	header.add_child(_fold_button)
	box.add_child(_tutorial_details)
	_tutorial_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_body.custom_minimum_size = Vector2(PANEL_WIDTH - 20, 0)
	_tutorial_body.add_theme_font_size_override("font_size", 14)
	_tutorial_details.add_child(_tutorial_body)
	var buttons = HBoxContainer.new()
	_tutorial_details.add_child(buttons)
	_more_button.text = tr("GUIDE_MORE")
	_more_button.focus_mode = Control.FOCUS_NONE
	_more_button.pressed.connect(func(): toggle_help(STEPS[min(_step, STEPS.size() - 1)][1], true))
	buttons.add_child(_more_button)
	var skip = _skip_button
	skip.text = tr("GUIDE_SKIP")
	skip.tooltip_text = tr("GUIDE_SKIP_TOOLTIP")
	skip.focus_mode = Control.FOCUS_NONE
	skip.pressed.connect(_skip_step)
	buttons.add_child(skip)
	_set_folded(_load_setting("tutorial_folded", false))


func _build_hint():
	_hint_panel.name = "Hint"
	_hint_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	_hint_panel.self_modulate = Color(1.0, 0.92, 0.6)
	add_child(_hint_panel)
	var margin = MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	_hint_panel.add_child(margin)
	var row = HBoxContainer.new()
	margin.add_child(row)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint_label.custom_minimum_size = Vector2(PANEL_WIDTH - 60, 0)
	_hint_label.add_theme_font_size_override("font_size", 14)
	row.add_child(_hint_label)
	var close = Button.new()
	close.text = "OK"
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func(): _hint_time_left_s = 0.0)
	row.add_child(close)
	_hint_panel.hide()


func _unhandled_key_input(event):
	if event.pressed and not event.echo and event.keycode == KEY_F1:
		toggle_help()
		get_viewport().set_input_as_handled()


func _process(delta):
	_since_refresh_s += delta
	if _since_refresh_s >= REFRESH_INTERVAL_S:
		_since_refresh_s = 0.0
		_refresh_tutorial()
	_update_hint(delta)
	_layout()


func _layout():
	"""positions are set by hand: the HUD layer gives this control no size to anchor to"""
	var screen = get_viewport_rect().size
	for panel in [_tutorial, _hint_panel]:
		if panel.size.y > panel.get_combined_minimum_size().y + 1.0:
			panel.reset_size()  # shrink back after shorter text
	# the diplomacy bar sits at the top centre too, so the tutorial goes right under it
	var top = 6.0
	var diplomacy_hud = get_parent().get_node_or_null("DiplomacyHud")
	if diplomacy_hud != null and diplomacy_hud.is_visible_in_tree():
		top = diplomacy_hud.position.y + diplomacy_hud.size.y + 6.0
	_tutorial.position = Vector2(round((screen.x - _tutorial.size.x) / 2.0), top)
	_hint_panel.position = Vector2(
		round((screen.x - _hint_panel.size.x) / 2.0), _tutorial.position.y + _tutorial.size.y + 6
	)
	var minimap_top = screen.y - 225
	auto_expand_panel.position = Vector2(
		5,
		clamp(
			round((screen.y - auto_expand_panel.size.y) / 2.0),
			60,
			minimap_top - auto_expand_panel.size.y
		)
	)
	var unit_menus = get_parent().find_child("UnitMenus", true, false)
	var right = screen.x - 5
	if unit_menus != null and unit_menus.is_visible_in_tree():
		right = unit_menus.global_position.x - 6
	auto_expand_bar.position = Vector2(
		right - auto_expand_bar.size.x, screen.y - 5 - auto_expand_bar.size.y
	)


func toggle_help(topic = null, force_show = false):
	if help_window.visible and not force_show:
		help_window.hide()
		return
	if topic != null:
		help_window.show_topic(topic)
	help_window.show()


func show_hint(key, args = []):
	"""shows a hint once per match"""
	if key in _hints_shown:
		return
	_hints_shown[key] = true
	_hint_queue.append(tr(key).format(args))


func _update_hint(delta):
	if _hint_time_left_s > 0.0:
		_hint_time_left_s -= delta
		if _hint_time_left_s > 0.0:
			return
	if _hint_queue.is_empty():
		_hint_panel.hide()
		return
	_hint_label.text = _hint_queue.pop_front()
	_hint_time_left_s = HINT_DURATION_S
	_hint_panel.show()


func _refresh_tutorial():
	if player == null or not is_instance_valid(player):
		return
	while _step < STEPS.size() and _step_done(STEPS[_step][0]):
		_step += 1
	if _step >= STEPS.size():
		_tutorial_title.text = tr("GUIDE_TITLE_DONE")
		_tutorial_body.text = tr("GUIDE_DONE")
		_tutorial_title.add_theme_color_override("font_color", DONE_COLOR)
		_more_button.hide()
		_skip_button.hide()  # nothing left to skip
		return
	var key = STEPS[_step][0]
	_tutorial_title.text = tr("GUIDE_TITLE").format(
		[_step + 1, STEPS.size(), tr("GUIDE_STEP_{0}_TITLE".format([key]))]
	)
	_tutorial_body.text = tr("GUIDE_STEP_{0}".format([key]))


func _step_done(key):
	match key:
		"SELECT_CONSTRUCTOR":
			return not _selected_constructors().is_empty()
		"BUILD_EXTRACTOR":
			return not _own(func(unit): return unit is Extractor).is_empty()
		"FINISH_EXTRACTOR":
			return not (
				_own(func(unit): return unit is Extractor and unit.is_constructed()).is_empty()
			)
		"DELIVERY":
			return _delivered
		"POWER":
			return not _own(_is_power_plant).is_empty()
		"AUTO_EXPAND":
			return not _own(func(unit): return AutoExpand.is_enabled_on(unit)).is_empty()
		"TIER":
			return player.get_tier() >= 2
		"TRADE":
			return _traded
	return _army  # gdlint: ignore = max-returns


func _selected_constructors():
	var selected = get_tree().get_nodes_in_group("selected_units")
	return selected.filter(func(unit): return unit is Worker and unit.player == player)


static func _is_power_plant(unit):
	if not unit is Structure or not unit.is_constructed():
		return false
	var scene_path = unit._scene_path()
	return (
		Constants.Match.Power.OUTPUT_MW.get(scene_path, 0.0) > 0.0
		and not scene_path.ends_with("CommandCenter.tscn")
	)


func _skip_step():
	_step = min(_step + 1, STEPS.size())
	_refresh_tutorial()


func _set_folded(folded):
	_tutorial_details.visible = not folded
	_fold_button.text = tr("GUIDE_SHOW") if folded else tr("GUIDE_HIDE")
	_save_setting("tutorial_folded", folded)
	_tutorial.reset_size()


func _own(filter):
	return get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit.player == player and filter.call(unit)
	)


func _on_match_started():
	if player != null:
		return
	var humans = get_tree().get_nodes_in_group("players").filter(func(p): return p is Human)
	if humans.is_empty():
		return
	player = humans[0]
	auto_expand_panel.setup(player)
	_refresh_tutorial()


func _on_goods_delivered(a_player, _goods):
	if a_player == player:
		_delivered = true


func _on_trade_completed(proposer, partner, _offered, _requested):
	if proposer == player or partner == player:
		_traded = true


func _on_unit_production_finished(unit, _producer):
	if is_instance_valid(unit) and unit.player == player and unit.attack_damage != null:
		_army = true


func _on_unit_spawned(unit):
	if player == null or unit.player != player or not unit is Structure:
		return
	if not unit.is_under_construction() or unit.get_meta("auto_expand", false):
		return
	var logistics = player.logistics
	if logistics != null and not logistics.is_in_yard(unit.global_position):
		show_hint("HINT_SITE_OUTSIDE_YARD")
	else:
		show_hint("HINT_SITE_NEEDS_CONSTRUCTOR")


func _on_power_changed(a_player):
	if a_player != player or player.power_grid == null:
		return
	var grid = player.power_grid
	if grid.total_demand_mw > grid.total_supply_mw + 0.01:
		show_hint("HINT_BLACKOUT")


func _on_tier_reached(a_player, tier):
	if a_player == player and tier > 1:
		show_hint(
			"HINT_TIER_REACHED",
			[
				tr(
					(
						Constants
						. Match
						. Tech
						. TIERS[min(tier, Constants.Match.Tech.TIERS.size()) - 1]["name"]
					)
				)
			]
		)


func _on_short_of_resources(a_player, key):
	if a_player == player:
		show_hint(key)


func _on_aircraft_crashed(unit):
	if is_instance_valid(unit) and unit.player == player:
		show_hint("HINT_AIRCRAFT_CRASHED")


func _on_cargo_destroyed(_unit, owner, _cargo, _looter, _loot):
	if owner == player:
		show_hint("HINT_CARGO_DESTROYED")


func _load_setting(key, default):
	var config = ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return default
	return config.get_value("guide", key, default)


func _save_setting(key, value):
	var config = ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value("guide", key, value)
	config.save(SETTINGS_PATH)
