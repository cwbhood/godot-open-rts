extends PanelContainer

# Player stock of every commodity, plus the state of the power grid and fuel.

var player = null

var _labels = {}
var _power_label = Label.new()


func _ready():
	var margin = MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 5)
	add_child(margin)
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)
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
