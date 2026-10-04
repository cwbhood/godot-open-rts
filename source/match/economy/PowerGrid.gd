extends Node

# The player's electric grid. Grid nodes (command centers, power plants, solar plants and
# pylons) cover a radius; nodes whose radii overlap are connected and every structure
# inside a covered area is wired to that network. Each network balances its own supply
# and demand. A network short on supply browns out: all its consumers (factories,
# extractors, the city) get power_ratio < 1. Unconnected consumers get no power at all.
# Oil-fired power plants burn oil from the player's stock in proportion to their load
# and stop when the stock runs dry.

const Structure = preload("res://source/match/units/Structure.gd")

var networks = []  # [{"nodes": [...], "consumers": [...], "supply": MW, "demand": MW}]
var total_supply_mw = 0.0
var total_demand_mw = 0.0
var city_power_ratio = 1.0

var _burn_accumulated = {}

@onready var _player = get_parent()


func _ready():
	var timer = Timer.new()
	timer.timeout.connect(_tick.bind(Constants.Match.Power.TICK_S))
	add_child(timer)
	timer.start(Constants.Match.Power.TICK_S)


func get_power_ratio_at(position):
	"""power ratio a consumer placed at 'position' would get, 0.0 when off-grid"""
	for network in networks:
		for node in network["nodes"]:
			if is_instance_valid(node) and _distance(node, position) <= _grid_radius(node) + 0.001:
				return network["ratio"]
	return 0.0


func is_position_on_grid(position):
	for network in networks:
		for node in network["nodes"]:
			if is_instance_valid(node) and _distance(node, position) <= _grid_radius(node):
				return true
	return false


func get_grid_links():
	"""pairs of connected grid nodes, used to draw power lines"""
	var links = []
	for network in networks:
		# a node destroyed since the last tick stays listed until the next one
		var nodes = network["nodes"].filter(func(node): return is_instance_valid(node))
		for i in range(nodes.size()):
			for j in range(i + 1, nodes.size()):
				if _nodes_connect(nodes[i], nodes[j]):
					links.append([nodes[i], nodes[j]])
	return links


func _tick(delta):
	var structures = get_tree().get_nodes_in_group("units").filter(
		func(unit): return unit is Structure and unit.player == _player and unit.is_constructed()
	)
	var grid_nodes = structures.filter(func(unit): return _grid_radius(unit) > 0.0)
	networks = _build_networks(grid_nodes)
	var city = _player.city
	var city_core = city.get_core() if city != null else null
	total_supply_mw = 0.0
	total_demand_mw = 0.0
	var connected_consumers = {}
	for network in networks:
		network["consumers"] = []
		network["demand"] = 0.0
		for structure in structures:
			var demand = Constants.Match.Power.DEMAND_MW.get(structure._scene_path(), 0.0)
			if demand <= 0.0 or structure in connected_consumers:
				continue
			if network["nodes"].any(
				func(node): return _distance(node, structure.global_position) <= _grid_radius(node)
			):
				network["consumers"].append(structure)
				network["demand"] += demand
				connected_consumers[structure] = true
		network["has_city"] = city_core != null and city_core in network["nodes"]
		if network["has_city"]:
			network["demand"] += city.power_demand_mw
		network["supply"] = _network_supply(network, delta)
		network["ratio"] = (
			1.0
			if network["demand"] <= 0.0
			else clamp(network["supply"] / network["demand"], 0.0, 1.0)
		)
		total_supply_mw += network["supply"]
		total_demand_mw += network["demand"]
	city_power_ratio = 0.0
	for network in networks:
		for consumer in network["consumers"]:
			consumer.power_ratio = network["ratio"]
		if network["has_city"]:
			city_power_ratio = network["ratio"]
	for structure in structures:
		if (
			not structure in connected_consumers
			and Constants.Match.Power.DEMAND_MW.get(structure._scene_path(), 0.0) > 0.0
		):
			structure.power_ratio = 0.0
	if city != null:
		city.power_ratio = city_power_ratio if city_core != null else 0.0
	MatchSignals.power_changed.emit(_player)


func _network_supply(network, delta):
	"""capacity the network can actually deliver; fuelled plants burn for their share"""
	var capacity = 0.0
	var plants = []
	for node in network["nodes"]:
		var output = Constants.Match.Power.OUTPUT_MW.get(node._scene_path(), 0.0)
		if output <= 0.0:
			continue
		output *= float(node.hp) / float(node.hp_max)  # damaged plants deliver less
		var burns = Constants.Match.Power.BURNS.get(node._scene_path(), {})
		if not burns.is_empty() and not _can_burn(burns):
			continue  # out of fuel
		capacity += output
		plants.append([node, output, burns])
	var load_factor = clamp(network["demand"] / capacity, 0.0, 1.0) if capacity > 0.0 else 0.0
	for plant in plants:
		for resource in plant[2]:
			_burn(resource, plant[2][resource] * plant[1] * load_factor * delta)
	return capacity


func _can_burn(burns):
	for resource in burns:
		if _player.get(resource) <= 0 and _burn_accumulated.get(resource, 0.0) < 1.0:
			return false
	return true


func _burn(resource, amount):
	_burn_accumulated[resource] = _burn_accumulated.get(resource, 0.0) + amount
	var whole = int(floor(_burn_accumulated[resource]))
	if whole > 0 and _player.get(resource) >= whole:
		_player.subtract_resources({resource: whole})
		_burn_accumulated[resource] -= whole


func _build_networks(grid_nodes):
	var result = []
	var visited = {}
	for start in grid_nodes:
		if start in visited:
			continue
		var network_nodes = []
		var queue = [start]
		visited[start] = true
		while not queue.is_empty():
			var node = queue.pop_back()
			network_nodes.append(node)
			for other in grid_nodes:
				if not other in visited and _nodes_connect(node, other):
					visited[other] = true
					queue.append(other)
		result.append({"nodes": network_nodes})
	return result


static func _nodes_connect(a, b):
	return _distance(a, b.global_position) <= _grid_radius(a) + _grid_radius(b)


static func _grid_radius(structure):
	return Constants.Match.Power.GRID_RADIUS_M.get(structure._scene_path(), 0.0)


static func _distance(node, position):
	return (node.global_position * Vector3(1, 0, 1)).distance_to(position * Vector3(1, 0, 1))
