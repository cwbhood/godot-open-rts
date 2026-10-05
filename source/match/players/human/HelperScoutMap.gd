extends RefCounted

# The helper's memory of where its scout has been: the map in square cells, each holding the
# clock when it was last seen, or a negative "avoid until" where enemies were met.

var cell_m = 20.0
var _cells = {}  # Vector2i -> clock when seen, or a negative "avoid until"


func _init(a_cell_m):
	cell_m = a_cell_m


func avoid(position, until_s):
	_cells[cell_of(position)] = -until_s


func mark_cell(position, clock_s):
	_cells[cell_of(position)] = clock_s


func next_target(map_size, from, clock_s, is_dangerous):
	"""the stalest cell centre nearby that is_dangerous(center) does not rule out, or null"""
	var best = null
	var columns = int(ceil(map_size.x / cell_m))
	var rows = int(ceil(map_size.y / cell_m))
	for x in range(columns):
		for z in range(rows):
			var cell = Vector2i(x, z)
			var seen = _cells.get(cell, -1.0)
			if seen < 0.0 and -seen > clock_s:
				continue  # enemies were there not long ago
			var center = Vector3(
				min((x + 0.5) * cell_m, map_size.x - 2.0),
				0,
				min((z + 0.5) * cell_m, map_size.y - 2.0)
			)
			if is_dangerous.call(center):
				continue
			var staleness = clock_s - max(seen, 0.0) if seen >= 0.0 else 100000.0
			var score = staleness - 2.0 * center.distance_to(from)
			if best == null or score > best[0]:
				best = [score, center]
	return best[1] if best != null else null


func mark_seen(position, radius, map_size, clock_s):
	var reach = int(ceil(radius / cell_m))
	var center = cell_of(position)
	for dx in range(-reach, reach + 1):
		for dz in range(-reach, reach + 1):
			var cell = center + Vector2i(dx, dz)
			if cell.x < 0 or cell.y < 0 or cell.x * cell_m >= map_size.x:
				continue
			if cell.y * cell_m >= map_size.y:
				continue
			var cell_center = Vector3((cell.x + 0.5) * cell_m, 0, (cell.y + 0.5) * cell_m)
			if cell_center.distance_to(position * Vector3(1, 0, 1)) > radius:
				continue
			var previous = _cells.get(cell, 0.0)
			if previous < 0.0 and -previous > clock_s:
				continue  # keep avoiding it
			_cells[cell] = clock_s


func seen_share(map_size):
	var total = int(ceil(map_size.x / cell_m)) * int(ceil(map_size.y / cell_m))
	return min(1.0, float(_cells.size()) / max(total, 1))


func cell_of(position):
	return Vector2i(int(position.x / cell_m), int(position.z / cell_m))
