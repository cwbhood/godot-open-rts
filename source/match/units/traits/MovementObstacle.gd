extends NavigationObstacle3D

const Movement = preload("res://source/match/units/traits/Movement.gd")

@export var domain = Constants.Match.Navigation.Domain.TERRAIN
@export var path_height_offset = 0.0

@onready var _match = find_parent("Match")
@onready var _unit = get_parent()


func _ready():
	await get_tree().process_frame  # wait for navigation to be operational
	set_navigation_map(_match.navigation.get_navigation_map_rid_by_domain(domain))
	_align_unit_position_to_navigation()
	_affect_navigation_if_needed()
	_fit_avoidance_to_navmesh()


func _exit_tree():
	if affect_navigation_mesh:
		remove_from_group(Constants.Match.Navigation.DOMAIN_TO_GROUP_MAPPING[domain])
		MatchSignals.schedule_navigation_rebake.emit(domain)


func _align_unit_position_to_navigation():
	_unit.global_transform.origin = (
		NavigationServer3D.map_get_closest_point(
			get_navigation_map(), get_parent().global_transform.origin
		)
		- Vector3(0, path_height_offset, 0)
	)


func _affect_navigation_if_needed():
	if affect_navigation_mesh:
		add_to_group(Constants.Match.Navigation.DOMAIN_TO_GROUP_MAPPING[domain])
		MatchSignals.schedule_navigation_rebake.emit(domain)


func _fit_avoidance_to_navmesh():
	"""a structure carved out of the navmesh is already kept clear by paths, and its avoidance
	circle (radius) reaches past the carved edge: units following a path round its corner
	pushed into that circle and stuck there. Keep only the outline for avoidance then; the
	radius itself stays, placement and adherence are measured with it"""
	if affect_navigation_mesh and Movement.settings()["crowd_steering"]:
		NavigationServer3D.obstacle_set_radius(get_rid(), 0.0)
