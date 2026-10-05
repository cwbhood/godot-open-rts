extends Control

# Tells the player what they are looking at:
# - hovering any unit or building shows a small tip by the cursor with its name and one
#   line of state (for your resource buildings: yard and how many trucks are coming; for
#   your trucks: their current job),
# - selecting one unit or building opens a card next to the minimap with its name, role,
#   what it does, what it costs and needs, what it makes, its live status and, for your
#   extractors, storages, depots and construction sites, the trucks working for it.
#   Truck names on the card select that truck and centre the camera on it,
# - the routes of those trucks are drawn on the ground (HaulerRouteLines.gd), for the
#   building under the cursor and the selected one, and the route of a selected truck.
# Texts come from data/units (role, info, cost, power...) via BuildingInfoText.gd.

const HudStyle = preload("res://source/match/hud/HudStyle.gd")
const Text = preload("res://source/match/hud/BuildingInfoText.gd")
const HaulerLinks = preload("res://source/match/economy/HaulerLinks.gd")
const HaulerRouteLines = preload("res://source/match/hud/HaulerRouteLines.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Structure = preload("res://source/match/units/Structure.gd")

const REFRESH_INTERVAL_S = 0.25
const CARD_WIDTH = 380
const TIP_WIDTH = 300
const TIP_OFFSET = Vector2(18, 20)

var hovered = null  # unit under the cursor
var shown = null  # unit the card shows

var _details_folded = false
var _since_refresh_s = 0.0
var _tip = null
var _tip_title = null
var _tip_body = null
var _card = null
var _card_icon = null
var _card_title = null
var _card_role = null
var _card_fold = null
var _card_details = null
var _card_body = null
var _routes = null

@onready var _match = find_parent("Match")


func _ready():
	name = "BuildingInfo"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_tip()
	_build_card()
	_routes = HaulerRouteLines.new()
	_routes.name = "HaulerRouteLines"
	_match.add_child.call_deferred(_routes)
	var units = get_tree().get_nodes_in_group("units")
	units.sort_custom(func(a, b): return a.get_instance_id() < b.get_instance_id())
	for unit in units:
		_track(unit)
	MatchSignals.unit_spawned.connect(_track)
	MatchSignals.unit_selected.connect(func(_unit): _on_selection_changed.call_deferred())
	MatchSignals.unit_deselected.connect(func(_unit): _on_selection_changed.call_deferred())
	MatchSignals.unit_died.connect(_on_unit_died)


func _process(delta):
	if _tip.visible:
		_place_tip()
	_since_refresh_s += delta
	if _since_refresh_s < REFRESH_INTERVAL_S:
		return
	_since_refresh_s = 0.0
	_refresh()


func _track(unit):
	"""numbers the unit among its owner's units of that type and follows the cursor on it"""
	if unit.player != null and (unit is Structure or unit is Hauler):
		HaulerLinks.number_of(unit)
	if not unit.mouse_entered.is_connected(_on_mouse_entered):
		unit.mouse_entered.connect(_on_mouse_entered.bind(unit))
		unit.mouse_exited.connect(_on_mouse_exited.bind(unit))


func _on_mouse_entered(unit):
	if not _valid(unit) or not unit.visible:
		return
	hovered = unit
	_refresh()


func _on_mouse_exited(unit):
	if hovered == unit:
		hovered = null
		_refresh()


func _on_unit_died(unit):
	if hovered == unit:
		hovered = null
	if shown == unit:
		shown = null
	_refresh()


func _on_selection_changed():
	var selected = get_tree().get_nodes_in_group("selected_units")
	shown = selected[0] if selected.size() == 1 else null
	_refresh()


func _valid(unit):
	return unit != null and is_instance_valid(unit) and unit.is_inside_tree()


func _is_own(unit):
	return unit.is_in_group("controlled_units")


func _refresh():
	if not _valid(hovered) or not hovered.visible:
		hovered = null
	if not _valid(shown):
		shown = null
	_refresh_tip()
	_refresh_card()
	_refresh_routes()


func _refresh_tip():
	# no tip for the unit the card already shows
	_tip.visible = hovered != null and hovered != shown and hovered.player != null
	if not _tip.visible:
		return
	var own = _is_own(hovered)
	var title = (
		HaulerLinks.display_name(hovered)
		if own
		else Text.entry_of(hovered)["name"] if Text.entry_of(hovered) != null else ""
	)
	_tip_title.text = tr(title)
	var lines = []
	if not own:
		lines.append(_owner_text(hovered))
	var summary = Text.hover_summary(hovered, own)
	if summary != "":
		lines.append(summary)
	_tip_body.text = Text.plain("\n".join(lines))
	_tip_body.visible = not lines.is_empty()
	_tip.reset_size()
	_place_tip()


func _place_tip():
	var viewport = get_viewport().get_visible_rect().size
	var spot = get_viewport().get_mouse_position() + TIP_OFFSET
	spot.x = min(spot.x, viewport.x - _tip.size.x - 4)
	spot.y = min(spot.y, viewport.y - _tip.size.y - 4)
	_tip.position = spot


func _refresh_card():
	_card.visible = shown != null and shown.player != null and Text.entry_of(shown) != null
	if not _card.visible:
		return
	var own = _is_own(shown)
	var entry = Text.entry_of(shown)
	_card_icon.texture = (
		load(entry["icon"]) if ResourceLoader.exists(entry.get("icon", "")) else null
	)
	_card_icon.modulate = Color(entry.get("icon_tint", "#ffffff"))
	_card_title.text = HaulerLinks.display_name(shown) if own else tr(entry["name"])
	_card_role.text = Text.role_text(shown) + ("" if own else "  ·  " + _owner_text(shown))
	var details = [Text.info_text(shown)]
	var needs = Text.needs_line(shown)
	if needs != "":
		details.append(_section("INFO_NEEDS") + needs)
	var makes = Text.makes_line(shown)
	if shown is Structure or makes != tr("INFO_NOTHING"):
		details.append(_section("INFO_MAKES") + makes)
	_card_details.text = "\n".join(details)
	_card_details.visible = not _details_folded
	var body = []
	var status = Text.status_lines(shown, own)
	if shown is Hauler and own:
		status.append(Text.cargo_line(shown))
	if not status.is_empty():
		body.append(_section("INFO_STATUS") + "\n" + "\n".join(status))
	if own and HaulerLinks.is_served_building(shown):
		body.append(_section("INFO_HAULERS") + "\n" + "\n".join(Text.truck_lines(shown)))
	_card_body.text = "\n".join(body)
	_card_body.visible = not body.is_empty()
	_card.reset_size()
	_place_card()


func _place_card():
	var viewport = get_viewport().get_visible_rect().size
	var left = 8.0
	var minimap = _match.find_child("Minimap", true, false) if _match != null else null
	if minimap != null and minimap.is_visible_in_tree():
		left = minimap.get_global_rect().end.x + 8.0
	_card.position = Vector2(left, viewport.y - _card.size.y - 8.0)


func _refresh_routes():
	if _routes == null or not _routes.is_inside_tree():
		return
	var buildings = []
	var trucks = []
	for unit in [hovered, shown]:
		if unit == null or not _is_own(unit):
			continue
		if unit is Hauler:
			trucks.append(unit)
		elif HaulerLinks.is_served_building(unit) and not unit in buildings:
			buildings.append(unit)
	_routes.show_routes(buildings, trucks)


func _owner_text(unit):
	var diplomacy_hud = _match.find_child("DiplomacyHud", true, false) if _match else null
	var owner = (
		diplomacy_hud.faction_name(unit.player)
		if diplomacy_hud != null
		else "#{0}".format([unit.player.get_index() + 1])
	)
	return tr("INFO_ENEMY").format([owner])


func _section(key):
	return "[color={0}][b]{1}[/b][/color]  ".format([HudStyle.MUTED.to_html(false), tr(key)])


func _on_link_clicked(meta):
	var id = int(str(meta))
	if not is_instance_id_valid(id):
		return
	var unit = instance_from_id(id)
	if not unit is Node or not unit.is_inside_tree():
		return
	MatchSignals.deselect_all_units.emit()
	var selection = unit.find_child("Selection")
	if selection != null:
		selection.select()
	var camera = get_viewport().get_camera_3d()
	if camera != null and camera.has_method("set_position_safely"):
		camera.set_position_safely(unit.global_position)


func _on_fold_pressed():
	_details_folded = not _details_folded
	HudStyle.set_folded_icon(_card_fold, _details_folded)
	_refresh()


func _build_tip():
	_tip = PanelContainer.new()
	_tip.name = "HoverTip"
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip.custom_minimum_size = Vector2(0, 0)
	add_child(_tip)
	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	HudStyle.margin(_tip, 8, 5).add_child(box)
	_tip_title = Label.new()
	_tip_title.theme_type_variation = "HeaderLabel"
	_tip_title.add_theme_font_size_override("font_size", 15)
	box.add_child(_tip_title)
	_tip_body = Label.new()
	HudStyle.small(_tip_body, 13, true)
	_tip_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_body.custom_minimum_size = Vector2(TIP_WIDTH - 16, 0)
	box.add_child(_tip_body)
	_tip.hide()


func _build_card():
	_card = PanelContainer.new()
	_card.name = "BuildingCard"
	_card.custom_minimum_size = Vector2(CARD_WIDTH, 0)
	add_child(_card)
	var box = VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	HudStyle.margin(_card, 12, 10).add_child(box)
	var header = HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)
	_card_icon = HudStyle.icon_rect(null, 32)
	header.add_child(_card_icon)
	var titles = VBoxContainer.new()
	titles.add_theme_constant_override("separation", -2)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	_card_title = Label.new()
	_card_title.theme_type_variation = "HeaderLabel"
	_card_title.add_theme_font_size_override("font_size", 18)
	_card_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	titles.add_child(_card_title)
	_card_role = Label.new()
	HudStyle.small(_card_role, 12, true)
	_card_role.uppercase = true
	titles.add_child(_card_role)
	_card_fold = Button.new()
	HudStyle.style_fold_button(_card_fold)
	HudStyle.set_folded_icon(_card_fold, false)
	_card_fold.pressed.connect(_on_fold_pressed)
	header.add_child(_card_fold)
	_card_details = _rich_text()
	box.add_child(_card_details)
	_card_body = _rich_text()
	_card_body.meta_clicked.connect(_on_link_clicked)
	box.add_child(_card_body)
	_card.hide()


func _rich_text():
	var label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(CARD_WIDTH - 24, 0)
	label.add_theme_font_size_override("normal_font_size", 13)
	label.add_theme_font_size_override("bold_font_size", 12)
	label.add_theme_color_override("default_color", HudStyle.FG)
	label.meta_underlined = true
	return label
