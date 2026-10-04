extends GridContainer

# Production or construction buttons generated from the unit definitions in res://data/
# (see GameData.producible_by). Structures are placed with the blueprint, units are queued
# in the selected producer. Buttons stay disabled until the city reaches the required tier.

const GameData = preload("res://source/data-model/GameData.gd")
const SLOTS = 16
const SLOT_SIZE = Vector2(80, 80)
const ICON_MARGIN = 10

@export var producer_id = ""

var unit = null

var _buttons = {}  # scene path -> button


func _ready():
	columns = 4
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var entries = GameData.producible_by(producer_id)
	entries.sort_custom(
		func(a, b): return [int(a.get("tier", 1)), a["id"]] < [int(b.get("tier", 1)), b["id"]]
	)
	entries = entries.slice(0, SLOTS)
	for _i in range(SLOTS - entries.size()):
		var padding = Control.new()
		padding.custom_minimum_size = SLOT_SIZE
		padding.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(padding)
	for entry in entries:
		add_child(_make_button(entry))


func _process(_delta):
	var player = _player()
	for scene_path in _buttons:
		_buttons[scene_path].disabled = player == null or not player.can_produce(scene_path)


func _player():
	if unit != null and is_instance_valid(unit):
		return unit.player
	var selected = get_tree().get_nodes_in_group("selected_units").filter(
		func(a_unit): return a_unit.is_in_group("controlled_units")
	)
	return selected[0].player if not selected.is_empty() else null


func _make_button(entry):
	var button = Button.new()
	button.custom_minimum_size = SLOT_SIZE
	button.focus_mode = Control.FOCUS_NONE
	button.tooltip_text = describe(entry)
	if "icon" in entry and ResourceLoader.exists(entry["icon"]):
		var icon = TextureRect.new()
		icon.texture = load(entry["icon"])
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.set_anchors_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = ICON_MARGIN
		icon.offset_top = ICON_MARGIN / 2.0
		icon.offset_right = -ICON_MARGIN
		icon.offset_bottom = -ICON_MARGIN * 1.6
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if "icon_tint" in entry:
			icon.modulate = Color(entry["icon_tint"])
		button.add_child(icon)
	# the name under the icon, so buttons can be told apart without hovering
	var name_label = Label.new()
	name_label.text = tr(entry["name"])
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_constant_override("outline_size", 4)
	name_label.add_theme_color_override("font_outline_color", Color.BLACK)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.clip_text = true
	name_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	name_label.offset_left = 2
	name_label.offset_right = -2
	name_label.offset_bottom = -2
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(name_label)
	var tier_label = Label.new()
	tier_label.text = "T{0}".format([int(entry.get("tier", 1))]) if entry.get("tier", 1) > 1 else ""
	tier_label.add_theme_font_size_override("font_size", 12)
	tier_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tier_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	tier_label.offset_right = -4
	tier_label.offset_top = 1
	tier_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(tier_label)
	button.pressed.connect(_on_button_pressed.bind(entry))
	_buttons[entry["scene"]] = button
	return button


static func describe(entry):
	var lines = [
		"{0} - {1}".format(
			[
				TranslationServer.translate(entry["name"]),
				TranslationServer.translate(entry["description"])
			]
		)
	]
	var properties = entry.get("properties", {})
	var stats = []
	if "hp_max" in properties:
		stats.append("{0} HP".format([int(properties["hp_max"])]))
	if "attack_damage" in properties:
		(
			stats
			. append(
				(
					"{0} DPS, {1} m"
					. format(
						[
							"%.1f" % (properties["attack_damage"] / properties["attack_interval"]),
							properties["attack_range"],
						]
					)
				)
			)
		)
	if "cargo_capacity" in properties:
		stats.append(
			TranslationServer.translate("CARGO_CAPACITY").format(
				[int(properties["cargo_capacity"])]
			)
		)
	var power = entry.get("power", {})
	if power.get("output_mw", 0) > 0:
		stats.append("+{0} MW".format([power["output_mw"]]))
	if power.get("demand_mw", 0) > 0:
		stats.append("-{0} MW".format([power["demand_mw"]]))
	if power.get("grid_radius_m", 0) > 0:
		stats.append(TranslationServer.translate("GRID_RADIUS").format([power["grid_radius_m"]]))
	if not stats.is_empty():
		lines.append(", ".join(stats))
	if "extracts" in entry:
		lines.append(
			TranslationServer.translate("EXTRACTS").format(
				[
					", ".join(
						entry["extracts"].map(
							func(kind): return TranslationServer.translate(kind.to_upper())
						)
					)
				]
			)
		)
	var cost_parts = []
	for resource in Constants.Match.Resources.ALL:
		if entry.get("cost", {}).get(resource, 0) > 0:
			cost_parts.append(
				"{0} {1}".format(
					[int(entry["cost"][resource]), TranslationServer.translate(resource.to_upper())]
				)
			)
	lines.append(TranslationServer.translate("COST").format([", ".join(cost_parts)]))
	if "flight_endurance_s" in entry:
		lines.append(
			TranslationServer.translate("NEEDS_AIRPORT").format([int(entry["flight_endurance_s"])])
		)
	if int(entry.get("tier", 1)) > 1:
		lines.append(
			TranslationServer.translate("REQUIRES_TIER").format(
				[
					TranslationServer.translate(
						Constants.Match.Tech.TIERS[int(entry["tier"]) - 1]["name"]
					)
				]
			)
		)
	return "\n".join(lines)


func _on_button_pressed(entry):
	var scene = load(entry["scene"])
	if entry.get("category") == "structure":
		MatchSignals.place_structure.emit(scene)
	elif unit != null and is_instance_valid(unit):
		unit.production_queue.produce(scene)
