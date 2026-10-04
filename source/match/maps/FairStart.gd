extends RefCounted

# Measures how fair a map's start zones are. For every zone it collects the distance to the
# nearest deposit of each commodity and how much of each commodity lies within NEAR and MID
# metres, plus the distance to the map center and to the nearest other zone. Zones are fair
# when every number is within tolerance of the same number for every other zone.
# Used by tools/validate_data.gd and tools/check_fair_starts.gd.

const NEAR = 30.0
const MID = 60.0
const DISTANCE_TOLERANCE = 2.0  # metres, or DISTANCE_TOLERANCE_RATIO of the distance
const DISTANCE_TOLERANCE_RATIO = 0.05
const AMOUNT_TOLERANCE_RATIO = 0.1  # of the largest amount among the zones
const ANY_KIND = &"any"


static func measure(map, kind_agnostic = false) -> Array:
	"""returns one {metric name: value} dictionary per start zone"""
	var zones = map.get_start_zones()
	var deposits = map.get_deposit_list()
	var kinds = [ANY_KIND]
	if not kind_agnostic:
		for deposit in deposits:
			if not deposit.kind in kinds:
				kinds.append(deposit.kind)
	var center = Vector2(map.size) / 2.0
	var results = []
	for zone in zones:
		var metrics = {"distance to map center": zone.center.distance_to(center)}
		var nearest_zone = INF
		for other in zones:
			if other != zone:
				nearest_zone = min(nearest_zone, zone.center.distance_to(other.center))
		if nearest_zone < INF:
			metrics["distance to nearest other zone"] = nearest_zone
		for kind in kinds:
			var nearest = INF
			var near_amount = 0.0
			var mid_amount = 0.0
			for deposit in deposits:
				if kind != ANY_KIND and deposit.kind != kind:
					continue
				var distance = zone.center.distance_to(deposit.center)
				nearest = min(nearest, distance)
				# asymmetric maps give sides different commodities on purpose, so there the
				# number of deposits is compared instead of the amount of each commodity
				var value = 1.0 if kind_agnostic else float(deposit.amount)
				if distance <= NEAR:
					near_amount += value
				if distance <= MID:
					mid_amount += value
			metrics["nearest {0}".format([kind])] = nearest
			var unit = " deposits" if kind_agnostic else ""
			metrics["{0}{1} within {2} m".format([kind, unit, NEAR])] = near_amount
			metrics["{0}{1} within {2} m".format([kind, unit, MID])] = mid_amount
		results.append(metrics)
	return results


static func problems(map, kind_agnostic = false) -> Array:
	"""returns human-readable descriptions of every metric that differs too much between
	start zones; an empty array means the starts are fair"""
	var found = []
	var zones = measure(map, kind_agnostic)
	if zones.size() < 2:
		return found
	for metric in zones[0]:
		var values = zones.map(func(zone): return zone.get(metric, INF))
		var low = values.min()
		var high = values.max()
		if is_inf(low) and is_inf(high):
			continue
		var tolerance = 0.0
		if metric.contains(" within "):
			tolerance = high * AMOUNT_TOLERANCE_RATIO
		else:
			tolerance = max(DISTANCE_TOLERANCE, low * DISTANCE_TOLERANCE_RATIO)
		if high - low > tolerance + 0.001:
			found.append(
				"{0} differs between start zones: {1}".format(
					[metric, ", ".join(values.map(func(v): return "%.1f" % v))]
				)
			)
	return found
