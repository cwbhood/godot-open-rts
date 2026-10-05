extends Node3D

const SurfaceNavigation = preload("res://source/match/SurfaceNavigation.gd")

var water = null  # boats
var amphibious = null  # amphibious units; used only on maps with water

var _static_obstacles = []
var _map_has_water = false

@onready var air = find_child("Air")
@onready var terrain = find_child("Terrain")

@onready var _match = find_parent("Match")


func _ready():
	var template = terrain.find_child("NavigationRegion3D").navigation_mesh
	water = SurfaceNavigation.new(Constants.Match.Navigation.Domain.WATER, template)
	amphibious = SurfaceNavigation.new(Constants.Match.Navigation.Domain.AMPHIBIOUS, template)
	add_child(water)
	add_child(amphibious)
	await _match.ready
	_setup_static_obstacles()


func get_navigation_map_rid_by_domain(domain):
	match domain:
		Constants.Match.Navigation.Domain.AIR:
			return air.navigation_map_rid
		Constants.Match.Navigation.Domain.WATER:
			return water.navigation_map_rid
		Constants.Match.Navigation.Domain.AMPHIBIOUS:
			# without water an amphibious unit is a land unit
			return amphibious.navigation_map_rid if _map_has_water else terrain.navigation_map_rid
	return terrain.navigation_map_rid


func setup(map):
	assert(_static_obstacles.is_empty())
	air.bake(map)
	terrain.bake(map)
	_map_has_water = map.has_method("has_water") and map.has_water()
	if _map_has_water:
		water.bake(map, null)
		amphibious.bake(map, terrain.static_geometry)
		terrain.obstacles_parsed.connect(amphibious.rebake_with)
	_setup_static_obstacles()


func _setup_static_obstacles():
	if not _static_obstacles.is_empty():
		return
	for domain in Constants.Match.Navigation.Domain.values():
		var obstacle = NavigationServer3D.obstacle_create()
		NavigationServer3D.obstacle_set_map(obstacle, get_navigation_map_rid_by_domain(domain))
		var obstacle_y = (
			Constants.Match.Air.Y if domain == Constants.Match.Navigation.Domain.AIR else 0
		)
		NavigationServer3D.obstacle_set_position(obstacle, Vector3(0, obstacle_y, 0))
		var obstacle_vertices = [
			Vector3(0, 0, 0),
			Vector3(0, 0, _match.map.size.y),
			Vector3(_match.map.size.x, 0, _match.map.size.y),
			Vector3(_match.map.size.x, 0, 0),
		]
		NavigationServer3D.obstacle_set_vertices(obstacle, obstacle_vertices)
		NavigationServer3D.obstacle_set_avoidance_enabled(obstacle, true)
		_static_obstacles.append(obstacle)
