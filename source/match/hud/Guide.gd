extends Control

# Teaches the game while it is played:
# - a tutorial at the top of the screen walking through the first goals, one at a time,
#   each ticked off by what the player actually does (it can be folded away; the choice
#   is remembered between matches),
# - one-off hints that pop up below it the first time something worth explaining happens
#   (a blackout, a site outside the yard, a crashed drone...),
# - the helper's panel and the auto-expand overview on the left,
# - the manual (F1, or the Help button).
# The match's rules (MatchRules, picked in the Play menu) can leave out the tutorial and
# hints, the helper's panel or the auto-expand panel and bar; the manual always stays.

const Human = preload("res://source/match/players/human/Human.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Extractor = preload("res://source/match/units/Extractor.gd")
const AutoExpand = preload("res://source/match/units/traits/AutoExpand.gd")
const AutoExpandPanel = preload("res://source/match/hud/AutoExpandPanel.gd")
const AutoExpandBar = preload("res://source/match/hud/AutoExpandBar.gd")
const HelpWindow = preload("res://source/match/hud/HelpWindow.gd")
const HelperPanel = preload("res://source/match/hud/HelperPanel.gd")
const Helper = preload("res://source/match/players/human/Helper.gd")
const MatchRules = preload("res://source/data-model/MatchRules.gd")
const MatchLimits = preload("res://source/match/MatchLimits.gd")
const HudStyle = preload("res://source/match/hud/HudStyle.gd")

const SETTINGS_PATH = "user://guide.cfg"
const REFRESH_INTERVAL_S = 0.5
const HINT_DURATION_S = 12.0
const CAP_ALERT_INTERVAL_S = 20.0
const PANEL_WIDTH = 300  # the width of the left column (HelperPanel, AutoExpandPanel)
const DONE_COLOR = Color("#8fbf5a")
const GAP = 6.0
# the panel a tutorial step is about opens when the step starts (all start folded)
const STEP_PANELS = {"AUTO_EXPAND": "AutoExpandPanel", "TRADE": "CityHud"}
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
	["COMMANDS", "COMMANDS"],
]

var player = null
var help_window = null
var auto_expand_panel = null
var auto_expand_bar = null
var helper_panel = null
var tutorial_on = true  # the match's rules, read once in _ready
var ai_assist_on = true
var auto_build_on = true

var _step = 0
var _delivered = false
var _traded = false
var _army = false
var _commanded = false  # the player used a line, patrol or another army order
var _hints_shown = {}
var _hint_queue = []
var _hint_time_left_s = 0.0
var _since_refresh_s = REFRESH_INTERVAL_S
var _last_cap_alert_ms = -100000
var _city_full_alerted_tiers = {}

var _tutorial = PanelContainer.new()
var _tutorial_title = Label.new()
var _tutorial_body = Label.new()
var _tutorial_details = VBoxContainer.new()
var _skip_button = Button.new()
var _folded_when_done = false
var _more_button = Button.new()
var _fold_button = Button.new()
var _hint_panel = PanelContainer.new()
var _hint_label = Label.new()
var _surplus_shown = 0
var _full_extractors_hinted = false
var _opened_for_step = -1


func _ready():
	name = "Guide"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	tutorial_on = MatchRules.tutorial_on(self)
	ai_assist_on = MatchRules.ai_assist_on(self)
	auto_build_on = MatchRules.auto_build_on(self)
	_build_tutorial()
	_tutorial.visible = tutorial_on
	_build_hint()
	if ai_assist_on:  # no panel, no H key
		helper_panel = HelperPanel.new()
		add_child(helper_panel)
	if auto_build_on:  # no panel, no bar, no G key
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
	MatchSignals.unit_command_issued.connect(func(_command): _commanded = true)
	MatchSignals.unit_selected.connect(_on_unit_selected)
	MatchSignals.cargo_destroyed.connect(_on_cargo_destroyed)
	MatchSignals.unit_cap_reached.connect(_on_unit_cap_reached)
	MatchSignals.resources_depleted.connect(_on_resources_depleted)
	MatchSignals.route_raided.connect(_on_route_raided)
	_on_match_started()


func _build_tutorial():
	_tutorial.name = "Tutorial"
	_tutorial.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	add_child(_tutorial)
	var margin = HudStyle.margin(_tutorial, 12, 8)
	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)
	var header = HudStyle.header("tutorial", _tutorial_title, null)
	_tutorial_title.add_theme_font_size_override("font_size", 17)
	# the column is narrow: long step titles wrap instead of being cut off
	_tutorial_title.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	_tutorial_title.clip_text = false
	_tutorial_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_title.custom_minimum_size = Vector2(PANEL_WIDTH - 90, 0)
	box.add_child(header)
	var help_button = Button.new()
	help_button.text = tr("GUIDE_HELP_BUTTON")
	help_button.tooltip_text = tr("GUIDE_HELP_TOOLTIP")
	help_button.focus_mode = Control.FOCUS_NONE
	help_button.add_theme_font_size_override("font_size", 13)
	help_button.pressed.connect(func(): toggle_help())
	HudStyle.style_fold_button(_fold_button)
	_fold_button.pressed.connect(func(): _set_folded(_tutorial_details.visible))
	header.add_child(_fold_button)
	box.add_child(_tutorial_details)
	_tutorial_details.add_theme_constant_override("separation", 8)
	_tutorial_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tutorial_body.custom_minimum_size = Vector2(PANEL_WIDTH - 26, 0)
	_tutorial_body.add_theme_font_size_override("font_size", 15)
	_tutorial_details.add_child(_tutorial_body)
	var buttons = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	_tutorial_details.add_child(buttons)
	_more_button.text = tr("GUIDE_MORE")
	_more_button.focus_mode = Control.FOCUS_NONE
	_more_button.add_theme_font_size_override("font_size", 13)
	_more_button.pressed.connect(func(): toggle_help(STEPS[min(_step, STEPS.size() - 1)][1], true))
	buttons.add_child(_more_button)
	var skip = _skip_button
	skip.text = tr("GUIDE_SKIP")
	skip.tooltip_text = tr("GUIDE_SKIP_TOOLTIP")
	skip.focus_mode = Control.FOCUS_NONE
	skip.add_theme_font_size_override("font_size", 13)
	skip.pressed.connect(_skip_step)
	buttons.add_child(skip)
	buttons.add_child(help_button)
	_set_folded(_load_setting("tutorial_folded", false))


func _build_hint():
	_hint_panel.name = "Hint"
	_hint_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(HudStyle.SURFACE, 0.94)
	style.border_color = HudStyle.ACCENT
	style.border_width_left = 4
	style.set_corner_radius_all(4)
	style.shadow_color = Color(0, 0, 0, 0.35)
	style.shadow_size = 6
	_hint_panel.add_theme_stylebox_override("panel", style)
	add_child(_hint_panel)
	var margin = HudStyle.margin(_hint_panel, 12, 8)
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint_label.custom_minimum_size = Vector2(PANEL_WIDTH - 90, 0)
	_hint_label.add_theme_font_size_override("font_size", 14)
	row.add_child(_hint_label)
	var close = Button.new()
	close.text = "OK"
	close.focus_mode = Control.FOCUS_NONE
	close.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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
		if tutorial_on:
			_refresh_tutorial()
		_check_city_cap()  # a limit alert, shown under Raw rules too
		_check_logistics()
	_update_hint(delta)
	_layout()


func _layout():
	"""positions are set by hand: the HUD layer gives this control no size to anchor to.
	The top strip runs along the top; under it the helper, auto-expand, tutorial and hint
	panels make a column on the left, the city panel one on the right, and the diplomacy
	bar sits alone at the top centre."""
	var screen = get_viewport_rect().size
	for panel in [_tutorial, _hint_panel]:
		if panel.size.y > panel.get_combined_minimum_size().y + 1.0:
			panel.reset_size()  # shrink back after shorter text
	var top_left = 40.0
	var resources = get_parent().get_node_or_null("MarginContainer2")
	if resources != null and resources.is_visible_in_tree():
		top_left = resources.global_position.y + resources.size.y + GAP
	var below_helper = top_left
	if helper_panel != null:
		if helper_panel.size.y > helper_panel.get_combined_minimum_size().y + 1.0:
			helper_panel.reset_size()
		helper_panel.position = Vector2(GAP, top_left)
		if helper_panel.visible:
			below_helper = helper_panel.position.y + helper_panel.size.y + GAP
	var minimap_top = screen.y - 225
	if auto_expand_panel != null:
		if auto_expand_panel.size.y > auto_expand_panel.get_combined_minimum_size().y + 1.0:
			auto_expand_panel.reset_size()
		auto_expand_panel.position = Vector2(
			GAP,
			clamp(below_helper, top_left, max(top_left, minimap_top - auto_expand_panel.size.y))
		)
	# the tutorial and hints continue the left column, so the middle of the screen stays on
	# the battlefield; the diplomacy bar keeps the top centre for itself
	var top = below_helper
	if auto_expand_panel != null and auto_expand_panel.visible:
		top = auto_expand_panel.position.y + auto_expand_panel.size.y + GAP
	_tutorial.position = Vector2(GAP, top)
	var hint_top = _tutorial.position.y + _tutorial.size.y + GAP if _tutorial.visible else top
	_hint_panel.position = Vector2(GAP, hint_top)
	if auto_expand_bar == null:
		return
	var unit_menus = get_parent().find_child("UnitMenus", true, false)
	var right = screen.x - 5
	if unit_menus != null and unit_menus.is_visible_in_tree():
		right = unit_menus.global_position.x - GAP
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
	"""shows a hint once per match, unless the match's rules have tips off"""
	if key in _hints_shown or not tutorial_on:
		return
	_hints_shown[key] = true
	_hint_queue.append(tr(key).format(args))


func show_alert(text):
	"""a warning that may come back (unlike hints), but not twice in a row"""
	if text in _hint_queue or (_hint_panel.visible and _hint_label.text == text):
		return
	_hint_queue.append(text)


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
		if not _folded_when_done:
			# fold it once so it stops covering the middle of the screen; Show brings it back
			_folded_when_done = true
			_tutorial_details.visible = false
			HudStyle.set_folded_icon(_fold_button, true)
			_tutorial.reset_size()
		return
	var key = STEPS[_step][0]
	if _opened_for_step != _step:
		_opened_for_step = _step
		_open_panel_for(key)
	_tutorial_title.text = tr("GUIDE_TITLE").format(
		[_step + 1, STEPS.size(), tr("GUIDE_STEP_{0}_TITLE".format([key]))]
	)
	_tutorial_body.text = tr("GUIDE_STEP_{0}".format([key]))


func _open_panel_for(key):
	"""unfolds the panel the step talks about, once, when the step starts"""
	var panel = get_parent().find_child(STEP_PANELS.get(key, "-"), true, false)
	if panel == null:
		return
	if panel.has_method("open_trade"):
		panel.open_trade()
	elif panel.has_method("set_collapsed"):
		panel.set_collapsed(false)


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
			if not auto_build_on:
				return true  # nothing to teach: this match's rules have auto-build off
			return not _own(func(unit): return AutoExpand.is_enabled_on(unit)).is_empty()
		"TIER":
			return player.get_tier() >= 2
		"TRADE":
			return _traded
		"COMMANDS":
			return _commanded
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
	HudStyle.set_folded_icon(_fold_button, folded)
	_fold_button.tooltip_text = tr("GUIDE_SHOW") if folded else tr("GUIDE_HIDE")
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
	if auto_expand_panel != null:
		auto_expand_panel.setup(player)
	if helper_panel != null:
		helper_panel.setup(player)
	var helper = Helper.of(player)
	if helper != null:
		helper.alerted.connect(show_alert)
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


func _on_unit_selected(unit):
	if player == null or unit.player != player or unit.attack_range == null:
		return
	if unit is Structure or unit.movement_speed <= 0.0:
		return
	var army = get_tree().get_nodes_in_group("selected_units").filter(
		func(other): return other.player == player and other.attack_range != null
	)
	if army.size() >= 3:
		show_hint("HINT_ARMY_ORDERS")


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


func _on_unit_cap_reached(a_player):
	"""said again at most every CAP_ALERT_INTERVAL_S: the helper and auto-expand may keep
	asking factories for units while the player is at the cap"""
	if (
		a_player != player
		or Time.get_ticks_msec() - _last_cap_alert_ms < CAP_ALERT_INTERVAL_S * 1000
	):
		return
	_last_cap_alert_ms = Time.get_ticks_msec()
	var limits = MatchLimits.of(get_tree())
	if limits != null:
		show_alert(tr("ALERT_UNIT_CAP").format([limits.slots_used(player), limits.slots_cap()]))


func _on_resources_depleted():
	var limits = MatchLimits.of(get_tree())
	if player != null and limits != null and limits.has_time_limit():
		show_alert(
			tr("ALERT_RESOURCES_DEPLETED").format(
				[int(limits.config.get("depletion_countdown_min", 0))]
			)
		)


func _check_city_cap():
	var city = player.city if player != null and is_instance_valid(player) else null
	if city == null or not city.is_at_population_cap() or city.tier in _city_full_alerted_tiers:
		return
	_city_full_alerted_tiers[city.tier] = true
	var next_tier = city.tier + 1
	if next_tier > Constants.Match.Tech.TIERS.size():
		show_alert(tr("ALERT_CITY_FULL_LAST").format([int(city.max_population)]))
	else:
		show_alert(
			tr("ALERT_CITY_FULL").format(
				[
					int(city.max_population),
					tr(city.get_tier_name(next_tier)),
					int(city.get_max_population(next_tier))
				]
			)
		)


func _on_short_of_resources(a_player, key):
	if a_player == player:
		show_hint(key)


func _on_aircraft_crashed(unit):
	if is_instance_valid(unit) and unit.player == player:
		show_hint("HINT_AIRCRAFT_CRASHED")


func _check_logistics():
	"""alerts for a fleet that is too big, and a hint the first time extractors stall"""
	if player == null or not is_instance_valid(player) or player.logistics == null:
		return
	var surplus = player.logistics.fleet.surplus_trucks
	if surplus > 0 and _surplus_shown == 0:
		show_alert(tr("ALERT_SURPLUS_TRUCKS").format([surplus]))
	_surplus_shown = surplus
	if not _full_extractors_hinted:
		var full = player.logistics.get_extractors().filter(
			func(extractor): return extractor.is_constructed() and extractor.is_full()
		)
		if full.size() >= 2:
			_full_extractors_hinted = true
			show_hint("HINT_EXTRACTORS_FULL")


func _on_route_raided(a_player, _position):
	if a_player == player:
		show_alert(
			tr("ALERT_ROUTE_RAIDED").format(
				[int(Constants.Match.Logistics.RAIDS.get("avoid_s", 45.0))]
			)
		)


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
