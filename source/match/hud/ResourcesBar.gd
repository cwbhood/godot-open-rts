extends PanelContainer

# Player stock of every commodity, plus the state of the power grid and fuel, the unit
# slots in use against the cap and the match clock (see MatchLimits).

const MatchLimits = preload("res://source/match/MatchLimits.gd")
const REFRESH_S = 0.5

var player = null

var _labels = {}
var _power_label = Label.new()
var _units_label = Label.new()
var _clock_label = Label.new()
var _since_refresh_s = REFRESH_S


func _ready():
	var margin = MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 5)
	add_child(margin)
	var column = VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	margin.add_child(column)
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	column.add_child(row)
	# second line, so the bar stays clear of the diplomacy bar at the top centre on 1280 px
	var limits_row = HBoxContainer.new()
	limits_row.add_theme_constant_override("separation", 14)
	column.add_child(limits_row)
	for resource in Constants.Match.Resources.ALL:
		var item = HBoxContainer.new()
		item.tooltip_text = _resource_tooltip(resource)
		item.add_theme_constant_override("separation", 6)
		var swatch = ColorRect.new()
		swatch.custom_minimum_size = Vector2(14, 14)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		swatch.color = Constants.Match.Resources.COLORS[resource]
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		item.add_child(swatch)
		var label = Label.new()
		label.custom_minimum_size = Vector2(34, 0)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		item.add_child(label)
		row.add_child(item)
		_labels[resource] = label
	_power_label.tooltip_text = tr("POWER_TOOLTIP")
	_power_label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(_power_label)
	for label in [_units_label, _clock_label]:
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		limits_row.add_child(label)
	_units_label.name = "UnitsLabel"
	_clock_label.name = "ClockLabel"


func _process(delta):
	_since_refresh_s += delta
	if _since_refresh_s < REFRESH_S or player == null or not visible:
		return
	_since_refresh_s = 0.0
	_refresh_limits()


func _refresh_limits():
	var limits = MatchLimits.of(get_tree())
	if limits == null or not is_instance_valid(player):
		_units_label.hide()
		_clock_label.hide()
		return
	var used = limits.slots_used(player, false)
	var cap = limits.slots_cap()
	_units_label.show()
	_units_label.text = tr("UNITS_BAR").format([used, cap])
	_units_label.tooltip_text = tr("UNITS_BAR_TOOLTIP").format(
		[int(limits.config.get("unit_slots_per_match", 0)), limits._starting_players, cap]
	)
	_units_label.modulate = (
		Color.ORANGE_RED if used >= cap else (Color.YELLOW if used >= cap * 0.9 else Color.WHITE)
	)
	_clock_label.visible = limits.has_time_limit()
	if not _clock_label.visible:
		return
	var left = max(0.0, limits.time_left_s())
	var whole = int(ceil(left))
	var clock = "%d:%02d" % [whole / 60, whole % 60]
	_clock_label.text = (
		tr("MATCH_CLOCK_DEPLETED" if limits.ends_by_depletion() else "MATCH_CLOCK").format([clock])
	)
	_clock_label.modulate = Color.ORANGE if left <= 300.0 else Color.WHITE
	var ranking = limits.ranking()
	var place = ranking.map(func(row): return row["player"]).find(player)
	var score = ranking[place]["score"]["total"] if place >= 0 else 0
	_clock_label.tooltip_text = tr("MATCH_CLOCK_TOOLTIP").format(
		[score, place + 1, ranking.size(), int(limits.config.get("depletion_countdown_min", 0))]
	)


func setup(a_player):
	assert(player == null, "player cannot be null")
	player = a_player
	_on_player_resource_changed()
	player.changed.connect(_on_player_resource_changed)
	MatchSignals.power_changed.connect(_on_power_changed)


func _on_power_changed(changed_player):
	if changed_player == player:
		_refresh_power()


func _on_player_resource_changed():
	for resource in _labels:
		_labels[resource].text = str(player.get(resource))
	var oil_label = _labels.get("oil")
	if oil_label != null:
		oil_label.modulate = Color.ORANGE_RED if player.oil <= 0 else Color.WHITE


func _refresh_power():
	var grid = player.power_grid
	if grid == null:
		return
	_power_label.text = tr("POWER_BAR").format(
		["%.0f" % grid.total_supply_mw, "%.0f" % grid.total_demand_mw]
	)
	_power_label.modulate = (
		Color.ORANGE_RED if grid.total_demand_mw > grid.total_supply_mw + 0.01 else Color.WHITE
	)


static func _resource_tooltip(resource):
	"""what the commodity is, where it comes from and what it is for (guide.csv)"""
	var name = TranslationServer.translate(resource.to_upper())
	var key = "{0}_TOOLTIP".format([resource.to_upper()])
	var details = TranslationServer.translate(key)
	if details == key:
		details = TranslationServer.translate("RESOURCE_TOOLTIP_GENERIC")
	return "{0}\n{1}".format([name, details])
