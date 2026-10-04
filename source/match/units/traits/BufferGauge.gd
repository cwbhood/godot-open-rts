extends Label3D

# Floating gauge over the player's own extractors and storage buildings: what they hold
# against their capacity ("IRON 12/16"), and why goods are piling up. A full extractor
# stops working until a truck or train comes, so it turns red and says so.

const REFRESH_INTERVAL_S = 0.5
const COLOR_LOW = Color(0.75, 1.0, 0.7)
const COLOR_FILLING = Color(1.0, 0.9, 0.45)
const COLOR_FULL = Color(1.0, 0.45, 0.35)

var _since_refresh_s = REFRESH_INTERVAL_S

@onready var _building = get_parent()


func _ready():
	billboard = BaseMaterial3D.BILLBOARD_ENABLED
	no_depth_test = true
	fixed_size = true
	pixel_size = 0.0011
	font_size = 20
	outline_size = 7
	outline_modulate = Color(0, 0, 0, 0.85)
	render_priority = 9
	position = Vector3(0, 1.9 + _building.radius, 0)
	_refresh()


func _process(delta):
	_since_refresh_s += delta
	if _since_refresh_s >= REFRESH_INTERVAL_S:
		_since_refresh_s = 0.0
		_refresh()


func _refresh():
	var kind = _building.get_goods_kind()
	visible = (
		_building.is_in_group("controlled_units")
		and _building.is_constructed()
		and (kind != null or _building.has_method("receive"))
	)
	if not visible:
		return
	var capacity = max(1, _building.get_buffer_capacity())
	var share = float(_building.stored) / capacity
	var kind_name = tr(kind.to_upper()) if kind != null else tr("STORAGE_EMPTY")
	var lines = ["{0} {1}/{2}".format([kind_name, _building.stored, capacity])]
	if _building.has_method("is_linked") and _building.is_linked():
		lines.append(tr("GAUGE_TO_STORAGE"))
	elif share >= 1.0:
		lines.append(tr("GAUGE_FULL_STORAGE" if _building.has_method("receive") else "GAUGE_FULL"))
	text = "\n".join(lines)
	modulate = COLOR_FULL if share >= 1.0 else (COLOR_FILLING if share >= 0.5 else COLOR_LOW)
