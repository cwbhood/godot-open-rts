extends Node2D

# Draws the logistics of the match on the minimap:
# - supply routes from depots to extractors (in the colour of the commodity) and to
#   construction sites waiting for haulers (dashed); upgraded roads are drawn wider,
# - power lines between grid nodes,
# - trade caravan routes between cities,
# - haulers as larger dots in their owner's colour, with a ring showing their cargo,
# - a red cross for a few seconds wherever cargo was destroyed.
# Routes of other factions show only where their units are currently in sight, so supply
# lines keep their fog of war.

const Extractor = preload("res://source/match/units/Extractor.gd")
const Structure = preload("res://source/match/units/Structure.gd")
const Hauler = preload("res://source/match/units/Hauler.gd")
const Caravan = preload("res://source/match/units/Caravan.gd")

const REDRAW_INTERVAL_S = 0.25
const RAID_MARKER_S = 8.0
const ROUTE_WIDTH = 1.5
const POWER_LINE_COLOR = Color(1.0, 0.9, 0.3, 0.55)
const SITE_ROUTE_COLOR = Color(1.0, 1.0, 1.0, 0.6)
const TRADE_ROUTE_COLOR = Color(0.95, 0.75, 1.0, 0.8)
const RAID_COLOR = Color(1.0, 0.15, 0.1)

var pixels_per_meter = 2.0

var _since_redraw_s = 0.0
var _raid_markers = []  # [[position 2d, time left]]

@onready var _match = find_parent("Match")


func _ready():
	MatchSignals.cargo_destroyed.connect(_on_cargo_destroyed)


func _process(delta):
	for marker in _raid_markers:
		marker[1] -= delta
	_raid_markers = _raid_markers.filter(func(marker): return marker[1] > 0.0)
	_since_redraw_s += delta
	if _since_redraw_s >= REDRAW_INTERVAL_S:
		_since_redraw_s = 0.0
		queue_redraw()


func _draw():
	if _match == null or not _match.is_node_ready():
		return
	for player in get_tree().get_nodes_in_group("players"):
		var own = player in _match.visible_players
		_draw_power_lines(player, own)
		_draw_supply_routes(player, own)
	for unit in get_tree().get_nodes_in_group("units"):
		if unit is Hauler and _is_seen(unit, unit.player in _match.visible_players):
			_draw_hauler(unit)
	for marker in _raid_markers:
		var size = 3.0
		draw_line(marker[0] - Vector2(size, size), marker[0] + Vector2(size, size), RAID_COLOR, 1.5)
		draw_line(
			marker[0] - Vector2(size, -size), marker[0] + Vector2(size, -size), RAID_COLOR, 1.5
		)


func _draw_supply_routes(player, own):
	var logistics = player.logistics
	if logistics == null:
		return
	for extractor in logistics.get_extractors():
		if not _is_seen(extractor, own):
			continue
		var depot = logistics.closest_depot(extractor.global_position)
		if depot == null:
			continue
		var color = Constants.Match.Resources.COLORS.get(extractor.resource_kind, Color.WHITE)
		color.a = 0.8 if extractor.is_constructed() else 0.4
		var road_level = logistics.get_road_level(extractor)
		if road_level > 0:  # upgraded roads show as a darker band under the route
			draw_line(
				_to_map(depot),
				_to_map(extractor),
				Color(0.1, 0.1, 0.1, 0.8),
				ROUTE_WIDTH + 1.5 * road_level
			)
		draw_line(_to_map(depot), _to_map(extractor), color, ROUTE_WIDTH)
	for site in logistics.get_sites():
		if not _is_seen(site, own) or logistics.is_in_yard(site.global_position):
			continue
		var depot = logistics.closest_depot(site.global_position)
		if depot != null:
			draw_dashed_line(_to_map(depot), _to_map(site), SITE_ROUTE_COLOR, 1.0, 3.0)
	for unit in get_tree().get_nodes_in_group("units"):
		if (
			unit is Caravan
			and unit.player == player
			and _is_seen(unit, own)
			and unit.trade_partner != null
			and is_instance_valid(unit.trade_partner)
		):
			var depot = unit.trade_partner.logistics.closest_depot(unit.global_position)
			if depot != null:
				draw_dashed_line(_to_map(unit), _to_map(depot), TRADE_ROUTE_COLOR, 1.0, 4.0)


func _draw_power_lines(player, own):
	var grid = player.power_grid
	if grid == null:
		return
	for link in grid.get_grid_links():
		if is_instance_valid(link[0]) and is_instance_valid(link[1]):
			if _is_seen(link[0], own) and _is_seen(link[1], own):
				draw_line(_to_map(link[0]), _to_map(link[1]), POWER_LINE_COLOR, 0.75)


func _draw_hauler(hauler):
	var center = _to_map(hauler)
	draw_circle(center, 2.5, hauler.player.color)
	if hauler.cargo.is_empty():
		return
	var cargo_resource = hauler.cargo.keys()[0]
	draw_arc(
		center,
		3.5,
		0.0,
		TAU,
		12,
		Constants.Match.Resources.COLORS.get(cargo_resource, Color.WHITE),
		1.0
	)


func _is_seen(unit, own):
	return own or unit.visible


func _to_map(unit_or_position):
	var position = (
		unit_or_position if unit_or_position is Vector3 else unit_or_position.global_position
	)
	return Vector2(position.x, position.z) * pixels_per_meter


func _on_cargo_destroyed(unit, _owner, _cargo, _looter, _loot):
	if not is_instance_valid(unit):
		return
	var own = unit.player in _match.visible_players if unit.player != null else false
	if own or unit.visible:
		_raid_markers.append([_to_map(unit.global_position), RAID_MARKER_S])
