extends GridContainer

# Menu of a selected extractor: upgrades the road of its supply route (data/roads.json).

const REFRESH_INTERVAL_S = 0.5

var unit = null:
	set = _set_unit

var _road_button = null


func _ready():
	columns = 4
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_road_button = Button.new()
	_road_button.custom_minimum_size = Vector2(80, 80)
	_road_button.text = tr("ROAD_BUTTON")
	_road_button.add_theme_font_size_override("font_size", 14)
	_road_button.pressed.connect(_on_road_button_pressed)
	add_child(_road_button)
	var timer = Timer.new()
	timer.timeout.connect(_refresh)
	add_child(timer)
	timer.start(REFRESH_INTERVAL_S)
	MatchSignals.road_upgraded.connect(func(_player, _extractor, _level): _refresh())


func _set_unit(a_unit):
	unit = a_unit
	if is_node_ready():
		_refresh()


func _refresh():
	if not visible or unit == null or not is_instance_valid(unit):
		return
	var logistics = unit.player.logistics
	var levels = Constants.Match.Roads.LEVELS
	if logistics == null or levels.is_empty():
		_road_button.disabled = true
		return
	var current = levels[min(logistics.get_road_level(unit), levels.size() - 1)]
	var lines = [
		tr("ROAD_CURRENT").format(
			[tr(current["name"]), "%.1f" % float(current["speed_multiplier"])]
		),
		tr("ROAD_LENGTH").format([int(logistics.get_road_length_m(unit))]),
	]
	var upgrade = logistics.get_road_upgrade_for(unit)
	if upgrade == null:
		lines.append(tr("ROAD_MAXED"))
	else:
		var cost_parts = []
		for resource in upgrade["cost"]:
			cost_parts.append(
				"{0} {1}".format([upgrade["cost"][resource], tr(resource.to_upper())])
			)
		(
			lines
			. append(
				(
					tr("ROAD_UPGRADE")
					. format(
						[
							tr(upgrade["entry"]["name"]),
							"%.1f" % float(upgrade["entry"]["speed_multiplier"]),
							", ".join(cost_parts),
						]
					)
				)
			)
		)
		if not unit.player.has_tier(int(upgrade["entry"].get("tier", 1))):
			lines.append(
				tr("REQUIRES_TIER").format(
					[tr(Constants.Match.Tech.TIERS[int(upgrade["entry"]["tier"]) - 1]["name"])]
				)
			)
	_road_button.tooltip_text = "\n".join(lines)
	_road_button.disabled = not logistics.can_upgrade_road(unit)


func _on_road_button_pressed():
	if unit != null and is_instance_valid(unit) and unit.player.logistics != null:
		unit.player.logistics.upgrade_road(unit)
	_refresh()
