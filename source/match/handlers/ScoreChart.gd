extends Control

# A small line chart of each player's score over match time, for the end screen.

const GRID = Color("3d3326")
const LABEL = Color("b5a68c")
const FONT = preload("res://assets/ui/fonts/ibm-plex-mono-500.woff2")

var _series = []  # [{color, points: [Vector2(seconds, score)], label}]


func set_series(series):
	_series = series
	queue_redraw()


func _draw():
	var left = 54.0
	var bottom = size.y - 26.0
	var plot = Rect2(left, 8.0, size.x - left - 10.0, bottom - 8.0)
	var max_t = 1.0
	var max_score = 1.0
	for series in _series:
		for point in series["points"]:
			max_t = max(max_t, point.x)
			max_score = max(max_score, point.y)
	max_score = _nice_ceiling(max_score)
	for step in range(5):
		var y = plot.end.y - plot.size.y * step / 4.0
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), GRID, 1.0)
		var value = int(max_score * step / 4.0)
		draw_string(
			FONT, Vector2(0, y + 5), str(value), HORIZONTAL_ALIGNMENT_RIGHT, left - 8, 14, LABEL
		)
	var minutes = int(ceil(max_t / 60.0))
	var tick_every = max(1, int(ceil(minutes / 8.0)))
	for minute in range(0, minutes + 1, tick_every):
		var x = plot.position.x + plot.size.x * (minute * 60.0) / max(max_t, 1.0)
		if x > plot.end.x + 1:
			break
		draw_string(
			FONT,
			Vector2(x - 20, size.y - 4),
			"%dm" % minute,
			HORIZONTAL_ALIGNMENT_CENTER,
			40,
			14,
			LABEL
		)
	for series in _series:
		var points = PackedVector2Array()
		for point in series["points"]:
			points.append(
				Vector2(
					plot.position.x + plot.size.x * point.x / max_t,
					plot.end.y - plot.size.y * point.y / max_score
				)
			)
		if points.size() >= 2:
			draw_polyline(points, series["color"].lightened(0.15), 3.0, true)
		if points.size() >= 1:
			var last = points[points.size() - 1]
			draw_circle(last, 5.0, series["color"].lightened(0.15))
			draw_string(
				FONT,
				last + Vector2(-90, -10),
				series["label"],
				HORIZONTAL_ALIGNMENT_RIGHT,
				84,
				14,
				series["color"].lightened(0.3)
			)


func _nice_ceiling(value):
	var magnitude = pow(10.0, floor(log(value) / log(10.0)))
	for factor in [1.0, 2.0, 2.5, 5.0, 10.0]:
		if value <= factor * magnitude:
			return factor * magnitude
	return value
