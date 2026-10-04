extends RefCounted

# The water of a map: an optional sea covering everything but its islands, lakes, extra
# water bodies and shallow fords. A map definition lists them in its "layout":
#
#   "sea": true,                      // the whole map is deep water except the islands
#   "islands": [{"center": [30, 100], "radius": 20}, {"points": [[x, z], ...]}],
#   "water": [
#     {"center": [64, 64], "radius": 6, "depth": "deep"},
#     {"from": [40, 88], "to": [56, 72], "radius": 3.5, "depth": "shallow"},
#     {"points": [[x, z], ...], "depth": "deep"}
#   ]
#
# Shapes are circles (center, radius), capsules (from, to, radius: a strip such as a ford
# or a channel) and polygons (points). Shallow water wins over deep water, islands cut
# land out of the sea only. Legacy "lakes" (wobbly circles) count as deep water.
#
# Deep water is navigable by boats and amphibious units only. Shallow water is waded by
# land units (slowly) and sailed by boats. Everything a unit asks per tick goes through
# depth_fast(), a lookup in a grid rasterized once when the map is generated.

enum Depth { LAND, SHALLOW, DEEP }

const GRID_STEP = 0.5
const GRID_BLOCK = 8  # cells per side of a block tested as a whole
const DEEP_BED = 1.6
const SHALLOW_BED = 0.6
const SHORE_OUT = 1.5  # the bed starts dipping this far out on land
const SHORE_IN = 3.0  # and reaches full depth this far into the water
const DEPTH_NAMES = {"deep": Depth.DEEP, "shallow": Depth.SHALLOW}

var sea = false
var bodies = []  # [{shape: Dictionary, depth: Depth}]
var islands = []  # [shape]
var lakes = []  # legacy lakes [{center, radius, phase}], read through lake_line_at
var lake_line_at = Callable()  # (lake, pos) -> water line radius of a legacy lake

var _grid = PackedByteArray()
var _grid_origin = Vector2.ZERO
var _grid_columns = 0
var _grid_rows = 0


static func from_layout(layout) -> RefCounted:
	var water = load("res://source/match/maps/WaterLayout.gd").new()
	if not layout is Dictionary:
		return water
	water.sea = bool(layout.get("sea", false))
	for item in layout.get("islands", []):
		var shape = _parse_shape(item)
		if shape != null:
			water.islands.append(shape)
	for item in layout.get("water", []):
		var shape = _parse_shape(item)
		if shape != null:
			var depth = DEPTH_NAMES.get(String(item.get("depth", "deep")), Depth.DEEP)
			water.bodies.append({"shape": shape, "depth": depth})
	return water


static func export_shape(shape) -> Dictionary:
	var to_list = func(v): return [snappedf(v.x, 0.01), snappedf(v.y, 0.01)]
	match shape.kind:
		"circle":
			return {"center": to_list.call(shape.center), "radius": snappedf(shape.radius, 0.01)}
		"capsule":
			return {
				"from": to_list.call(shape.from),
				"to": to_list.call(shape.to),
				"radius": snappedf(shape.radius, 0.01),
			}
	return {"points": Array(shape.points).map(to_list)}


func export_layout(target: Dictionary):
	"""writes sea, islands and water into a layout dictionary (only what is used)"""
	if sea:
		target["sea"] = true
	if not islands.is_empty():
		target["islands"] = islands.map(export_shape)
	if not bodies.is_empty():
		var list = []
		for body in bodies:
			var item = export_shape(body.shape)
			item["depth"] = "shallow" if body.depth == Depth.SHALLOW else "deep"
			list.append(item)
		target["water"] = list


func has_water() -> bool:
	return sea or not bodies.is_empty() or not lakes.is_empty()


func has_more_than_lakes() -> bool:
	return sea or not bodies.is_empty()


# signed distances, negative inside


func deep_distance(pos: Vector2, with_lakes = true) -> float:
	var distance = INF
	if sea:
		var island = INF
		for shape in islands:
			if shape.kind != "circle" or _circle_may_beat(shape, pos, island):
				island = min(island, _shape_distance(shape, pos))
		distance = -island
	for body in bodies:
		if body.depth == Depth.DEEP:
			distance = min(distance, _shape_distance(body.shape, pos))
	if with_lakes:
		for lake in lakes:
			distance = min(distance, pos.distance_to(lake.center) - lake_line_at.call(lake, pos))
	return distance


func shallow_distance(pos: Vector2) -> float:
	var distance = INF
	for body in bodies:
		if body.depth == Depth.SHALLOW:
			distance = min(distance, _shape_distance(body.shape, pos))
	return distance


func depth_at(pos: Vector2) -> int:
	"""exact depth class; per-tick code should call depth_fast()"""
	if shallow_distance(pos) < 0.0:
		return Depth.SHALLOW
	if deep_distance(pos) < 0.0:
		return Depth.DEEP
	return Depth.LAND


func bed_height(pos: Vector2) -> float:
	"""height of the ground under the water (0 on land); legacy lakes are left to the map"""
	if not has_more_than_lakes():
		return 0.0
	var shallow = shallow_distance(pos)
	var deep = max(deep_distance(pos, false), -shallow)  # fords cut through deep water
	var any_water = min(deep, shallow)
	return -max(DEEP_BED * _shore(deep), SHALLOW_BED * _shore(any_water))


func wetness(pos: Vector2) -> float:
	"""1 in and right next to water, fading to 0 a few metres inland (ground colouring)"""
	if not has_more_than_lakes():
		return 0.0
	return smoothstep(3.5, 0.0, min(deep_distance(pos, false), shallow_distance(pos)))


func _shore(distance: float) -> float:
	return smoothstep(SHORE_OUT, -SHORE_IN, distance)


# the grid


func build_grid(area: Rect2):
	_grid_origin = area.position
	_grid_columns = int(ceil(area.size.x / GRID_STEP))
	_grid_rows = int(ceil(area.size.y / GRID_STEP))
	_grid.resize(_grid_columns * _grid_rows)
	if not has_water():
		_grid.fill(Depth.LAND)
		return
	# blocks far from every shore get one depth for all their cells: a few hundred
	# evaluations instead of one per cell (which took half a second on big maps)
	var half = Vector2.ONE * GRID_STEP * 0.5
	var block_reach = GRID_BLOCK * GRID_STEP * 1.1  # half the diagonal plus room for wobble
	for block_row in range(0, _grid_rows, GRID_BLOCK):
		for block_column in range(0, _grid_columns, GRID_BLOCK):
			var center = (
				_grid_origin
				+ (Vector2(block_column, block_row) + Vector2.ONE * GRID_BLOCK * 0.5) * GRID_STEP
			)
			var shallow = shallow_distance(center)
			var deep = deep_distance(center)
			var uniform = min(abs(shallow), abs(deep)) > block_reach
			var block_depth = (
				Depth.SHALLOW if shallow < 0.0 else (Depth.DEEP if deep < 0.0 else Depth.LAND)
			)
			for row in range(block_row, min(block_row + GRID_BLOCK, _grid_rows)):
				for column in range(block_column, min(block_column + GRID_BLOCK, _grid_columns)):
					var depth = block_depth
					if not uniform:
						depth = depth_at(_grid_origin + Vector2(column, row) * GRID_STEP + half)
					_grid[row * _grid_columns + column] = depth


func depth_fast(pos: Vector2) -> int:
	if _grid_columns == 0:
		return Depth.LAND
	var column = int(floor((pos.x - _grid_origin.x) / GRID_STEP))
	var row = int(floor((pos.y - _grid_origin.y) / GRID_STEP))
	if column < 0 or row < 0 or column >= _grid_columns or row >= _grid_rows:
		return Depth.DEEP if sea else Depth.LAND
	return _grid[row * _grid_columns + column]


func is_wet_near(pos: Vector2, radius: float) -> bool:
	"""true when any water (shallow included) lies within radius of pos"""
	for offset in _ring(radius):
		if depth_fast(pos + offset) != Depth.LAND:
			return true
	return false


func has_deep_water_near(pos: Vector2, radius: float) -> bool:
	for reach in [radius * 0.5, radius]:
		for offset in _ring(reach):
			if depth_fast(pos + offset) == Depth.DEEP:
				return true
	return false


func _ring(radius: float) -> Array:
	var offsets = [Vector2.ZERO]
	var steps = max(8, int(ceil(TAU * radius / GRID_STEP / 2.0)))
	for i in range(steps):
		offsets.append(Vector2.from_angle(TAU * i / steps) * radius)
	return offsets


func navigation_faces(depths: Array) -> PackedVector3Array:
	"""upward-facing triangles at y=0 covering every grid cell of the given depth classes:
	runs of cells per row, merged with identical runs of the rows below into rectangles"""
	var faces = PackedVector3Array()
	var open = {}  # Vector2i(first column, end column) -> first row
	for row in range(_grid_rows + 1):
		var runs = {}
		if row < _grid_rows:
			var start = -1
			for column in range(_grid_columns + 1):
				var inside = (
					column < _grid_columns and _grid[row * _grid_columns + column] in depths
				)
				if inside and start < 0:
					start = column
				elif not inside and start >= 0:
					runs[Vector2i(start, column)] = true
					start = -1
		for run in open.keys():
			if not run in runs:
				_add_rectangle(faces, run, open[run], row)
				open.erase(run)
		for run in runs:
			if not run in open:
				open[run] = row
	return faces


func _add_rectangle(faces, run: Vector2i, first_row: int, end_row: int):
	var x0 = _grid_origin.x + run.x * GRID_STEP
	var x1 = _grid_origin.x + run.y * GRID_STEP
	var z0 = _grid_origin.y + first_row * GRID_STEP
	var z1 = _grid_origin.y + end_row * GRID_STEP
	var a = Vector3(x0, 0.0, z0)
	var b = Vector3(x1, 0.0, z0)
	var c = Vector3(x1, 0.0, z1)
	var d = Vector3(x0, 0.0, z1)
	faces.append_array([a, b, c, a, c, d])


# shapes


static func _parse_shape(item):
	if not item is Dictionary:
		return null
	var to_vector = func(list): return Vector2(float(list[0]), float(list[1]))
	if "points" in item:
		var points = PackedVector2Array()
		for point in item.points:
			points.append(to_vector.call(point))
		if points.size() < 3:
			return null
		return {"kind": "polygon", "points": points}
	if "from" in item and "to" in item:
		return {
			"kind": "capsule",
			"from": to_vector.call(item.from),
			"to": to_vector.call(item.to),
			"radius": float(item.get("radius", 2.0)),
		}
	if "center" in item:
		return {
			"kind": "circle",
			"center": to_vector.call(item.center),
			"radius": float(item.get("radius", 4.0)),
		}
	return null


static func _circle_may_beat(shape, pos: Vector2, best: float) -> bool:
	"""false when the circle, wobble included, cannot come closer than 'best'"""
	return pos.distance_to(shape.center) - shape.radius * 1.1 < best


static func _shape_distance(shape, pos: Vector2) -> float:
	# circles and capsules get a gentle deterministic wobble so coasts do not look drawn
	# with a compass; the shape's own numbers stay the average radius
	match shape.kind:
		"circle":
			var phase = shape.center.x * 0.37 + shape.center.y
			var angle = (pos - shape.center).angle()
			var wobble = (
				sin(angle * 3.0 + phase) * 0.05
				+ sin(angle * 5.0 + phase * 1.7) * 0.035
				+ sin(angle * 9.0 + phase * 0.6) * 0.015
			)
			return pos.distance_to(shape.center) - shape.radius * (1.0 + wobble)
		"capsule":
			var closest = Geometry2D.get_closest_point_to_segment(pos, shape.from, shape.to)
			var along = closest.distance_to(shape.from)
			var wobble = sin(along * 0.9 + shape.from.x) * 0.12 + sin(along * 2.3) * 0.06
			return pos.distance_to(closest) - shape.radius * (1.0 + wobble)
	var points = shape.points
	var nearest = INF
	for i in range(points.size()):
		var closest = Geometry2D.get_closest_point_to_segment(
			pos, points[i], points[(i + 1) % points.size()]
		)
		nearest = min(nearest, pos.distance_to(closest))
	return -nearest if Geometry2D.is_point_in_polygon(pos, points) else nearest
