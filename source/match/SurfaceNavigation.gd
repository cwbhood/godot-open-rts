extends Node3D

# Navigation map of boats (WATER) or of amphibious units (AMPHIBIOUS), created by
# Navigation.gd on maps with water. Each lives on its own navigation map so that boats and
# amphibious units get paths over water while land units keep theirs.
#
# The ground comes from the map (Map.get_navigation_faces). The water map never changes:
# structures cannot stand in water. The amphibious map also holds forests, rocks and
# structures; it rebakes off the main thread whenever the land map does, reusing the
# obstacle geometry TerrainNavigation already parsed, so a rebake costs no extra parsing.

var domain = null
var navigation_map_rid = RID()

var _navigation_mesh = null
var _region_rid = RID()
var _base_geometry = null
var _is_baking = false
var _pending_geometry = null


func _init(a_domain, template_navigation_mesh):
	domain = a_domain
	name = (
		{
			Constants.Match.Navigation.Domain.WATER: "Water",
			Constants.Match.Navigation.Domain.AMPHIBIOUS: "Amphibious",
		}
		. get(domain, "Surface")
	)
	_navigation_mesh = template_navigation_mesh.duplicate()
	navigation_map_rid = NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(navigation_map_rid, _navigation_mesh.cell_size)
	NavigationServer3D.map_set_cell_height(navigation_map_rid, _navigation_mesh.cell_height)
	# synchronous map updates make freshly baked navmeshes usable right away
	NavigationServer3D.map_set_use_async_iterations(navigation_map_rid, false)
	_region_rid = NavigationServer3D.region_create()
	NavigationServer3D.region_set_use_async_iterations(_region_rid, false)
	NavigationServer3D.region_set_map(_region_rid, navigation_map_rid)
	NavigationServer3D.map_set_active(navigation_map_rid, true)


func _exit_tree():
	if _region_rid.is_valid():
		NavigationServer3D.free_rid(_region_rid)
		_region_rid = RID()
	if navigation_map_rid.is_valid():
		NavigationServer3D.free_rid(navigation_map_rid)
		navigation_map_rid = RID()


func bake(map, static_geometry):
	"""static_geometry: obstacles parsed once by TerrainNavigation (forests, rocks); the
	water map leaves them out"""
	_navigation_mesh.filter_baking_aabb = AABB(Vector3.ZERO, Vector3(map.size.x, 5.0, map.size.y))
	_base_geometry = NavigationMeshSourceGeometryData3D.new()
	if domain == Constants.Match.Navigation.Domain.AMPHIBIOUS and static_geometry != null:
		_base_geometry.merge(static_geometry)
	_base_geometry.add_faces(map.get_navigation_faces(domain), Transform3D.IDENTITY)
	NavigationServer3D.bake_from_source_geometry_data(_navigation_mesh, _base_geometry)
	NavigationServer3D.region_set_navigation_mesh(_region_rid, _navigation_mesh)
	NavigationServer3D.map_force_update(navigation_map_rid)


func rebake_with(dynamic_geometry):
	"""structures changed: bake base ground + forests + the given structures, in the
	background; a request arriving mid-bake waits for the running one to finish"""
	if domain != Constants.Match.Navigation.Domain.AMPHIBIOUS or _base_geometry == null:
		return
	var full_geometry = NavigationMeshSourceGeometryData3D.new()
	full_geometry.merge(dynamic_geometry)
	full_geometry.merge(_base_geometry)
	if _is_baking:
		_pending_geometry = full_geometry
		return
	_start_bake(full_geometry)


func _start_bake(full_geometry):
	_is_baking = true
	NavigationServer3D.bake_from_source_geometry_data_async(
		_navigation_mesh, full_geometry, _on_bake_finished
	)


func _on_bake_finished():
	if not is_inside_tree():
		return
	NavigationServer3D.region_set_navigation_mesh(_region_rid, _navigation_mesh)
	_is_baking = false
	if _pending_geometry != null:
		var next_geometry = _pending_geometry
		_pending_geometry = null
		_start_bake(next_geometry)
