extends GridContainer

# Menu of a selected extractor or storage yard: how eager trucks are to collect from it
# (priority), the road of an extractor's supply route (data/roads.json) and the commodity
# a storage keeps. Tooltips show the route's statistics.

const Storage = preload("res://source/match/units/Storage.gd")

const REFRESH_INTERVAL_S = 0.5
const PRIORITY_KEYS = ["PRIORITY_LOW", "PRIORITY_NORMAL", "PRIORITY_HIGH"]

var unit = null:
	set = _set_unit

var _road_button = null
var _priority_button = null
var _kind_button = null


func _ready():
	columns = 4
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_road_button = _make_button(tr("ROAD_BUTTON"), _on_road_button_pressed)
	_priority_button = _make_button("", _on_priority_button_pressed)
	_kind_button = _make_button("", _on_kind_button_pressed)
	var timer = Timer.new()
	timer.timeout.connect(_refresh)
	add_child(timer)
	timer.start(REFRESH_INTERVAL_S)
	MatchSignals.road_upgraded.connect(func(_player, _extractor, _level): _refresh())


func _make_button(text, on_pressed):
	var button = Button.new()
	button.custom_minimum_size = Vector2(80, 80)
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	button.add_theme_font_size_override("font_size", 13)
	button.pressed.connect(on_pressed)
	add_child(button)
	return button


func _set_unit(a_unit):
	unit = a_unit
	if is_node_ready():
		_refresh()


func _refresh():
	if not visible or unit == null or not is_instance_valid(unit):
		return
	var logistics = unit.player.logistics
	_road_button.visible = not unit is Storage
	_kind_button.visible = unit is Storage
	_priority_button.text = tr("PRIORITY_BUTTON").format(
		[tr(PRIORITY_KEYS[clamp(unit.logistics_priority, 0, 2)])]
	)
	_priority_button.tooltip_text = tr("PRIORITY_TOOLTIP") + "\n\n" + _stats_text(logistics)
	if unit is Storage:
		_kind_button.text = tr("STORAGE_KIND_BUTTON").format(
			[tr(unit.wanted_kind.to_upper()) if unit.wanted_kind != null else tr("STORAGE_AUTO")]
		)
		_kind_button.tooltip_text = tr("STORAGE_KIND_TOOLTIP")
		return
	_refresh_road(logistics)


func _stats_text(logistics):
	if logistics == null:
		return ""
	var stats = logistics.get_route_stats(unit)
	var lines = [
		(
			tr("ROUTE_STATS")
			. format(
				[
					stats["delivered"],
					stats["trips"],
					stats["lost"],
					int(stats["trip_s"] / max(stats["trips"], 1)),
				]
			)
		)
	]
	for train in logistics.fleet.get_trains():
		if unit in train.stops:
			lines.append(tr("ROUTE_ON_TRAIN_LINE"))
			break
	if unit.get("linked_storage") != null and unit.is_linked():
		lines.append(tr("ROUTE_FEEDS_STORAGE"))
	if logistics.is_route_in_danger(unit):
		lines.append(tr("ROUTE_IN_DANGER"))
	return "\n".join(lines)


func _refresh_road(logistics):
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


func _on_priority_button_pressed():
	if unit != null and is_instance_valid(unit):
		unit.logistics_priority = (unit.logistics_priority + 1) % PRIORITY_KEYS.size()
	_refresh()


func _on_kind_button_pressed():
	if unit == null or not is_instance_valid(unit) or not unit is Storage:
		return
	var kinds = [null] + Constants.Match.Resources.ALL
	unit.set_wanted_kind(kinds[(kinds.find(unit.wanted_kind) + 1) % kinds.size()])
	_refresh()
