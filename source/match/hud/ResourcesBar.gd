extends PanelContainer

# The strip along the top of the screen: the player's stock of every commodity with what
# arrives per minute, the power grid (supply / demand), unit slots in use against the cap
# (see MatchLimits) and the match clock. In a match without a human player every faction
# gets a strip, marked with its colour.

const MatchLimits = preload("res://source/match/MatchLimits.gd")
const HudStyle = preload("res://source/match/hud/HudStyle.gd")
const REFRESH_S = 0.5
const INCOME_WINDOW_S = 60.0
const INCOME_SAMPLE_S = 2.0
const HEIGHT = 34

var player = null
var show_owner = false  # a colour chip in front: several strips are on screen

var _labels = {}
var _rate_labels = {}
var _items = {}
var _owner_chip = ColorRect.new()
var _power_label = Label.new()
var _power_item = null
var _units_label = Label.new()
var _clock_label = Label.new()
var _time_label = Label.new()
var _since_refresh_s = REFRESH_S
var _since_sample_s = INCOME_SAMPLE_S
var _delivered_samples = []  # [time_s, {resource: delivered so far}]
var _clock_s = 0.0


func _ready():
	theme_type_variation = "TopBar"
	custom_minimum_size = Vector2(0, HEIGHT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var row = HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 18)
	add_child(row)
	_owner_chip.custom_minimum_size = Vector2(6, 22)
	_owner_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_owner_chip.visible = show_owner
	row.add_child(_owner_chip)
	for resource in Constants.Match.Resources.ALL:
		var item = _item(HudStyle.resource_icon(resource), _resource_tooltip(resource))
		item.name = "Resource_" + resource
		var label = Label.new()
		label.theme_type_variation = "NumberLabel"
		label.add_theme_font_size_override("font_size", 16)
		label.custom_minimum_size = Vector2(36, 0)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		item.add_child(label)
		var rate = Label.new()
		rate.theme_type_variation = "MutedLabel"
		rate.add_theme_font_size_override("font_size", 12)
		rate.add_theme_color_override("font_color", HudStyle.GOOD)
		rate.custom_minimum_size = Vector2(40, 0)
		rate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		item.add_child(rate)
		row.add_child(item)
		_labels[resource] = label
		_rate_labels[resource] = rate
		_items[resource] = item
	row.add_child(_separator())
	_power_item = _item(HudStyle.icon("power"), tr("POWER_TOOLTIP"))
	_power_item.name = "Power"
	_power_label.theme_type_variation = "NumberLabel"
	_power_label.add_theme_font_size_override("font_size", 15)
	_power_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_power_item.add_child(_power_label)
	row.add_child(_power_item)
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)
	var units_item = _item(HudStyle.icon("units"), "")
	units_item.name = "Units"
	_units_label.name = "UnitsLabel"
	units_item.add_child(_units_label)
	row.add_child(units_item)
	var clock_item = _item(HudStyle.icon("clock"), tr("HUD_MATCH_TIME_TOOLTIP"))
	clock_item.name = "Clock"
	_time_label.name = "MatchTime"
	_time_label.theme_type_variation = "NumberLabel"
	clock_item.add_child(_time_label)
	_clock_label.name = "ClockLabel"
	_clock_label.add_theme_color_override("font_color", HudStyle.ACCENT)
	_clock_label.hide()
	clock_item.add_child(_clock_label)
	row.add_child(clock_item)
	for label in [_units_label, _clock_label, _time_label]:
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		label.add_theme_font_size_override("font_size", 15)


func _item(texture, tooltip):
	var item = HBoxContainer.new()
	item.add_theme_constant_override("separation", 6)
	item.tooltip_text = tooltip
	item.mouse_filter = Control.MOUSE_FILTER_PASS
	if texture != null:
		item.add_child(HudStyle.icon_rect(texture, 22))
	return item


func _separator():
	var line = VSeparator.new()
	line.custom_minimum_size = Vector2(1, 22)
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return line


func _process(delta):
	_clock_s += delta
	_since_refresh_s += delta
	_since_sample_s += delta
	if player == null or not visible:
		return
	if _since_sample_s >= INCOME_SAMPLE_S:
		_since_sample_s = 0.0
		_sample_income()
	if _since_refresh_s < REFRESH_S:
		return
	_since_refresh_s = 0.0
	_refresh_limits()


func _sample_income():
	"""goods delivered to the player's depots over the last minute, per commodity"""
	if not is_instance_valid(player) or player.get("logistics") == null:
		return
	var delivered = player.logistics.delivered_total.duplicate()
	_delivered_samples.append([_clock_s, delivered])
	while _delivered_samples.size() > 2 and _clock_s - _delivered_samples[1][0] >= INCOME_WINDOW_S:
		_delivered_samples.pop_front()
	var first = _delivered_samples[0]
	var span = _clock_s - first[0]
	for resource in _rate_labels:
		var label = _rate_labels[resource]
		if span < INCOME_SAMPLE_S * 2.0:
			label.text = ""
			continue
		var per_min = (delivered.get(resource, 0) - first[1].get(resource, 0)) * 60.0 / span
		label.text = "+%d/m" % int(round(per_min)) if per_min >= 0.5 else ""
		_items[resource].tooltip_text = (
			_resource_tooltip(resource)
			+ "\n"
			+ tr("HUD_INCOME_TOOLTIP").format([int(round(per_min))])
		)


func _refresh_limits():
	var limits = MatchLimits.of(get_tree())
	if limits == null or not is_instance_valid(player):
		_units_label.get_parent().hide()
		_clock_label.hide()
		_time_label.text = _format_time(_clock_s)
		return
	_time_label.text = _format_time(limits.elapsed_s)
	var used = limits.slots_used(player, false)
	var cap = limits.slots_cap()
	var units_item = _units_label.get_parent()
	units_item.show()
	_units_label.text = tr("UNITS_BAR").format([used, cap])
	units_item.tooltip_text = tr("UNITS_BAR_TOOLTIP").format(
		[int(limits.config.get("unit_slots_per_match", 0)), limits._starting_players, cap]
	)
	_units_label.tooltip_text = units_item.tooltip_text
	var units_color = HudStyle.FG
	if used >= cap:
		units_color = HudStyle.BAD
	elif used >= cap * 0.9:
		units_color = HudStyle.WARN
	_units_label.add_theme_color_override("font_color", units_color)
	_clock_label.visible = limits.has_time_limit()
	if not _clock_label.visible:
		return
	var left = max(0.0, limits.time_left_s())
	_clock_label.text = (
		tr("MATCH_CLOCK_DEPLETED" if limits.ends_by_depletion() else "MATCH_CLOCK")
		. format([_format_time(left, true)])
	)
	_clock_label.add_theme_color_override(
		"font_color", HudStyle.BAD if left <= 300.0 else HudStyle.ACCENT
	)
	var ranking = limits.ranking()
	var place = ranking.map(func(row): return row["player"]).find(player)
	var score = ranking[place]["score"]["total"] if place >= 0 else 0
	_clock_label.tooltip_text = tr("MATCH_CLOCK_TOOLTIP").format(
		[score, place + 1, ranking.size(), int(limits.config.get("depletion_countdown_min", 0))]
	)


static func _format_time(seconds, round_up = false):
	var whole = int(ceil(seconds)) if round_up else int(seconds)
	if whole >= 3600:
		return "%d:%02d:%02d" % [whole / 3600, (whole / 60) % 60, whole % 60]
	return "%d:%02d" % [whole / 60, whole % 60]


func setup(a_player):
	assert(player == null, "player cannot be null")
	player = a_player
	_owner_chip.color = player.color
	_on_player_resource_changed()
	_refresh_power()
	player.changed.connect(_on_player_resource_changed)
	MatchSignals.power_changed.connect(_on_power_changed)


func set_show_owner(value):
	show_owner = value
	_owner_chip.visible = value


func _on_power_changed(changed_player):
	if changed_player == player:
		_refresh_power()


func _on_player_resource_changed():
	for resource in _labels:
		_labels[resource].text = str(player.get(resource))
	var oil_label = _labels.get("oil")
	if oil_label != null:
		oil_label.add_theme_color_override(
			"font_color", HudStyle.BAD if player.oil <= 0 else HudStyle.FG
		)


func _refresh_power():
	var grid = player.power_grid
	if grid == null:
		return
	_power_label.text = tr("POWER_BAR").format(
		["%.0f" % grid.total_supply_mw, "%.0f" % grid.total_demand_mw]
	)
	_power_label.add_theme_color_override(
		"font_color",
		HudStyle.BAD if grid.total_demand_mw > grid.total_supply_mw + 0.01 else HudStyle.FG
	)


static func _resource_tooltip(resource):
	"""what the commodity is, where it comes from and what it is for (guide.csv)"""
	var name = TranslationServer.translate(resource.to_upper())
	var key = "{0}_TOOLTIP".format([resource.to_upper()])
	var details = TranslationServer.translate(key)
	if details == key:
		details = TranslationServer.translate("RESOURCE_TOOLTIP_GENERIC")
	return "{0}\n{1}".format([name, details])
