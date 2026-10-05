class Unit:
	const Movement = preload("res://source/match/utils/UnitMovementUtils.gd")
	const Placement = preload("res://source/match/utils/UnitPlacementUtils.gd")


const Resources = preload("res://source/match/utils/ResourceUtils.gd")

const TEAM_COLOR_MATERIAL_NAME = "TeamColor"


static func traverse_node_tree_and_replace_materials_matching_albedo(
	starting_node, albedo_to_match, epsilon, material_to_set
):
	if starting_node == null:
		return
	# owned = false: meshes inside a model instantiated at runtime (GameData.apply_model)
	# belong to that model's root, not to the unit scene
	for child in starting_node.find_children("*", "", true, false):
		if not "mesh" in child or child.mesh == null:
			continue
		for surface_id in range(child.mesh.get_surface_count()):
			var surface_material = child.mesh.surface_get_material(surface_id)
			if surface_material == null:
				continue
			# Blender models (tools/blender/) name their team-coloured material "TeamColor";
			# older ones mark it with a key albedo instead
			if (
				surface_material.resource_name == TEAM_COLOR_MATERIAL_NAME
				or (
					"albedo_color" in surface_material
					and Utils.Colour.is_equal_approx_with_epsilon(
						surface_material.albedo_color, albedo_to_match, epsilon
					)
				)
			):
				child.set("surface_material_override/{0}".format([surface_id]), material_to_set)


static func select_units(units_to_select):
	if not units_to_select.empty() and not Input.is_action_pressed("shift_selecting"):
		MatchSignals.deselect_all_units.emit()
	for unit in units_to_select.iterate():
		var selection = unit.find_child("Selection")
		if selection != null:
			selection.select()
