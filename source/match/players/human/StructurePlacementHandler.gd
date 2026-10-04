extends Node3D

enum BlueprintPositionValidity {
	VALID,
	COLLIDES_WITH_OBJECT,
	NOT_NAVIGABLE,
	NOT_ENOUGH_RESOURCES,
	OUT_OF_MAP,
	NO_DEPOSIT_NEARBY,
	TIER_TOO_LOW,
	IN_WATER,
	NEEDS_SHORE,
}

const Extractor = preload("res://source/match/units/Extractor.gd")
const Worker = preload("res://source/match/units/Worker.gd")
const GameData = preload("res://source/data-model/GameData.gd")
const WaterRules = preload("res://source/match/WaterRules.gd")

const ROTATION_BY_KEY_STEP = 45.0
const ROTATION_DEAD_ZONE_DISTANCE = 0.1
# with a constructor selected, hovering a deposit picks its extractor automatically
const AUTO_PICK_HOVER_MARGIN_M = 0.6  # mouse this close to the deposit edge picks it
const AUTO_PICK_KEEP_MARGIN_M = 2.5  # the blueprint follows the deposit within this ring
const AUTO_PICK_GAP_M = 0.6  # gap between the snapped blueprint and the deposit
const AUTO_PICK_SNAP_STEPS = 12  # tries on each side when the spot facing the mouse is taken

const MATERIALS_ROOT = "res://source/match/resources/materials/"
const BLUEPRINT_VALID_PATH = MATERIALS_ROOT + "blueprint_valid.material.tres"
const BLUEPRINT_INVALID_PATH = MATERIALS_ROOT + "blueprint_invalid.material.tres"

var _active_blueprint_node = null
var _pending_structure_radius = null
var _pending_structure_navmap_rid = null
var _pending_structure_prototype = null
var _blueprint_rotating = false
var _auto_deposit = null  # deposit the blueprint was picked for by hovering it
var _suppressed_deposit = null  # just built at or cancelled, ignored until the mouse leaves

@onready var _player = get_parent()
@onready var _match = find_parent("Match")
@onready var _feedback_label = find_child("FeedbackLabel3D")


func _ready():
	_feedback_label.hide()
	MatchSignals.place_structure.connect(_on_structure_placement_request)


func _unhandled_input(event):
	if event is InputEventMouseMotion and not _blueprint_rotation_started():
		_update_auto_picked_extractor()
	if not _structure_placement_started():
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_handle_lmb_down_event(event)
	if event.is_action_pressed("rotate_structure"):
		_try_rotating_blueprint_by(ROTATION_BY_KEY_STEP)
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		_handle_lmb_up_event(event)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_handle_rmb_event(event)
	if event is InputEventMouseMotion:
		_handle_mouse_motion_event(event)


func _handle_lmb_down_event(_event):
	get_viewport().set_input_as_handled()
	_start_blueprint_rotation()


func _handle_lmb_up_event(_event):
	get_viewport().set_input_as_handled()
	var blueprint_position_validity = _calculate_blueprint_position_validity()
	if blueprint_position_validity == BlueprintPositionValidity.VALID:
		_finish_structure_placement()
	elif blueprint_position_validity == BlueprintPositionValidity.NOT_ENOUGH_RESOURCES:
		MatchSignals.not_enough_resources_for_construction.emit(_player)
	else:
		MatchSignals.structure_placement_refused.emit(_player)
	_finish_blueprint_rotation()


func _handle_rmb_event(event):
	get_viewport().set_input_as_handled()
	if event.pressed:
		_finish_blueprint_rotation()
		_cancel_structure_placement()


func _handle_mouse_motion_event(_event):
	get_viewport().set_input_as_handled()
	if _blueprint_rotation_started():
		_rotate_blueprint_towards_mouse_pos()
	elif _auto_deposit != null:
		_snap_blueprint_next_to_deposit()
	else:
		_set_blueprint_position_based_on_mouse_pos()
	var blueprint_position_validity = _calculate_blueprint_position_validity()
	_update_feedback_label(blueprint_position_validity)
	_update_blueprint_color(blueprint_position_validity == BlueprintPositionValidity.VALID)


func _structure_placement_started():
	return _active_blueprint_node != null


func _blueprint_rotation_started():
	return _blueprint_rotating == true


func _calculate_blueprint_position_validity():
	if _active_bluprint_out_of_map():
		return BlueprintPositionValidity.OUT_OF_MAP
	var scene_path = _pending_structure_prototype.resource_path
	if not _player.meets_tier_requirement(scene_path):
		return BlueprintPositionValidity.TIER_TOO_LOW
	if not _player_has_enough_resources():
		return BlueprintPositionValidity.NOT_ENOUGH_RESOURCES
	if (
		scene_path in Constants.Match.Extraction.EXTRACTOR_KINDS
		and (
			Extractor.find_deposit_near(
				scene_path,
				_active_blueprint_node.global_position,
				_pending_structure_radius,
				get_tree()
			)
			== null
		)
	):
		return BlueprintPositionValidity.NO_DEPOSIT_NEARBY
	var water_validity = (
		{
			WaterRules.IN_WATER: BlueprintPositionValidity.IN_WATER,
			WaterRules.NEEDS_SHORE: BlueprintPositionValidity.NEEDS_SHORE,
		}
		. get(
			WaterRules.structure_problem(
				_match.map,
				scene_path,
				_active_blueprint_node.global_position,
				_pending_structure_radius
			),
			BlueprintPositionValidity.VALID
		)
	)
	var placement_validity = Utils.Match.Unit.Placement.validate_agent_placement_position(
		_active_blueprint_node.global_position,
		_pending_structure_radius,
		(
			get_tree().get_nodes_in_group("units")
			+ get_tree().get_nodes_in_group("resource_units")
			+ get_tree().get_nodes_in_group("city_buildings")
		),
		_pending_structure_navmap_rid
	)
	var validity = (
		{
			Utils.Match.Unit.Placement.COLLIDES_WITH_AGENT:
			BlueprintPositionValidity.COLLIDES_WITH_OBJECT,
			Utils.Match.Unit.Placement.NOT_NAVIGABLE: BlueprintPositionValidity.NOT_NAVIGABLE,
		}
		. get(placement_validity, BlueprintPositionValidity.VALID)
	)
	return water_validity if water_validity != BlueprintPositionValidity.VALID else validity


func _player_has_enough_resources():
	var construction_cost = Constants.Match.Units.CONSTRUCTION_COSTS[
		_pending_structure_prototype.resource_path
	]
	return _player.has_resources(construction_cost)


func _active_bluprint_out_of_map():
	return not Geometry2D.is_point_in_polygon(
		Vector2(
			_active_blueprint_node.global_transform.origin.x,
			_active_blueprint_node.global_transform.origin.z
		),
		_match.map.get_topdown_polygon_2d()
	)


func _logistics_hint():
	"""tells the player whether the site needs haulers and whether it will have power"""
	var position = _active_blueprint_node.global_position
	var hints = []
	if _player.logistics != null and not _player.logistics.is_in_yard(position):
		hints.append(tr("BLUEPRINT_NEEDS_HAULERS"))
	var scene_path = _pending_structure_prototype.resource_path
	if (
		Constants.Match.Power.DEMAND_MW.get(scene_path, 0.0) > 0.0
		and _player.power_grid != null
		and not _player.power_grid.is_position_on_grid(position)
	):
		hints.append(tr("BLUEPRINT_OFF_GRID"))
	return "\n".join(hints)


func _update_feedback_label(blueprint_position_validity):
	_feedback_label.visible = (
		blueprint_position_validity != BlueprintPositionValidity.VALID or _logistics_hint() != ""
	)
	match blueprint_position_validity:
		BlueprintPositionValidity.COLLIDES_WITH_OBJECT:
			_feedback_label.text = tr("BLUEPRINT_COLLIDES_WITH_OBJECT")
		BlueprintPositionValidity.NOT_NAVIGABLE:
			_feedback_label.text = tr("BLUEPRINT_NOT_NAVIGABLE")
		BlueprintPositionValidity.NOT_ENOUGH_RESOURCES:
			_feedback_label.text = tr("BLUEPRINT_NOT_ENOUGH_RESOURCES")
		BlueprintPositionValidity.OUT_OF_MAP:
			_feedback_label.text = tr("BLUEPRINT_OUT_OF_MAP")
		BlueprintPositionValidity.NO_DEPOSIT_NEARBY:
			_feedback_label.text = tr("BLUEPRINT_NO_DEPOSIT_NEARBY")
		BlueprintPositionValidity.TIER_TOO_LOW:
			_feedback_label.text = tr("BLUEPRINT_TIER_TOO_LOW")
		BlueprintPositionValidity.IN_WATER:
			_feedback_label.text = tr("BLUEPRINT_IN_WATER")
		BlueprintPositionValidity.NEEDS_SHORE:
			_feedback_label.text = tr("BLUEPRINT_NEEDS_SHORE")
		BlueprintPositionValidity.VALID:
			_feedback_label.text = _logistics_hint()


func _start_structure_placement(structure_prototype):
	if _structure_placement_started():
		return
	_pending_structure_prototype = structure_prototype
	_active_blueprint_node = (
		load(Constants.Match.Units.STRUCTURE_BLUEPRINTS[structure_prototype.resource_path])
		. instantiate()
	)
	var blueprint_origin = Vector3(-999, 0, -999)
	var camera_direction_yless = (
		(get_viewport().get_camera_3d().project_ray_normal(Vector2(0, 0)) * Vector3(1, 0, 1))
		. normalized()
	)
	var rotate_towards = blueprint_origin + camera_direction_yless.rotated(Vector3.UP, PI * 0.75)
	_active_blueprint_node.global_transform = Transform3D(Basis(), blueprint_origin).looking_at(
		rotate_towards, Vector3.UP
	)
	add_child(_active_blueprint_node)
	var temporary_structure_instance = _pending_structure_prototype.instantiate()
	_pending_structure_radius = temporary_structure_instance.radius
	_pending_structure_navmap_rid = (
		find_parent("Match")
		. navigation
		. get_navigation_map_rid_by_domain(temporary_structure_instance.movement_domain)
	)
	temporary_structure_instance.free()


func _set_blueprint_position_based_on_mouse_pos():
	var mouse_pos_2d = get_viewport().get_mouse_position()
	var mouse_pos_3d = get_viewport().get_camera_3d().get_ray_intersection(mouse_pos_2d)
	if mouse_pos_3d == null:
		return
	_active_blueprint_node.global_transform.origin = mouse_pos_3d
	_feedback_label.global_transform.origin = mouse_pos_3d


func _update_blueprint_color(blueprint_position_is_valid):
	var material_to_set = (
		preload(BLUEPRINT_VALID_PATH)
		if blueprint_position_is_valid
		else preload(BLUEPRINT_INVALID_PATH)
	)
	for child in _active_blueprint_node.find_children("*"):
		if "material_override" in child:
			child.material_override = material_to_set


func _cancel_structure_placement():
	if _auto_deposit != null and is_instance_valid(_auto_deposit):
		_suppressed_deposit = _auto_deposit
	_auto_deposit = null
	if _structure_placement_started():
		_feedback_label.hide()
		_active_blueprint_node.queue_free()
		_active_blueprint_node = null


func _finish_structure_placement():
	if _player_has_enough_resources():
		var construction_cost = Constants.Match.Units.CONSTRUCTION_COSTS[
			_pending_structure_prototype.resource_path
		]
		_player.subtract_resources(construction_cost)
		var structure = _pending_structure_prototype.instantiate()
		# only sites laid out by hand pull the selected constructors (see UnitActionsController)
		structure.set_meta("placed_by_hand", true)
		MatchSignals.setup_and_spawn_unit.emit(
			structure, _active_blueprint_node.global_transform, _player
		)
	_cancel_structure_placement()


func _start_blueprint_rotation():
	_blueprint_rotating = true


func _try_rotating_blueprint_by(degrees):
	if not _structure_placement_started():
		return
	_active_blueprint_node.global_transform.basis = (
		_active_blueprint_node.global_transform.basis.rotated(Vector3.UP, deg_to_rad(degrees))
	)


func _rotate_blueprint_towards_mouse_pos():
	var mouse_pos_2d = get_viewport().get_mouse_position()
	var mouse_pos_3d = get_viewport().get_camera_3d().get_ray_intersection(mouse_pos_2d)
	if mouse_pos_3d == null:
		return
	var mouse_pos_yless = mouse_pos_3d * Vector3(1, 0, 1)
	var blueprint_pos_3d = _active_blueprint_node.global_transform.origin
	var blueprint_pos_yless = blueprint_pos_3d * Vector3(-999, 0, -999)
	if mouse_pos_yless.distance_to(blueprint_pos_yless) < ROTATION_DEAD_ZONE_DISTANCE:
		return
	var rotation_target = Vector3(mouse_pos_yless.x, blueprint_pos_3d.y, mouse_pos_yless.z)
	if rotation_target.is_equal_approx(_active_blueprint_node.global_transform.origin):
		return
	_active_blueprint_node.global_transform = _active_blueprint_node.global_transform.looking_at(
		rotation_target, Vector3.UP
	)


func _finish_blueprint_rotation():
	_blueprint_rotating = false


func _on_structure_placement_request(structure_prototype):
	if _auto_deposit != null:
		_cancel_structure_placement()  # a button press wins over the hovered deposit
		_suppressed_deposit = null
	_start_structure_placement(structure_prototype)


func _update_auto_picked_extractor():
	if _structure_placement_started() and _auto_deposit == null:
		return  # the player picked a structure in the menu
	var mouse_pos_3d = _mouse_pos_3d()
	if mouse_pos_3d == null:
		return
	var hovered = _deposit_under(mouse_pos_3d)
	if _suppressed_deposit != null and hovered != _suppressed_deposit:
		_suppressed_deposit = null
	if _auto_deposit != null:
		if not is_instance_valid(_auto_deposit) or not _auto_deposit.is_inside_tree():
			_cancel_structure_placement()
		elif hovered != null and hovered != _auto_deposit:
			_cancel_structure_placement()
		elif not _mouse_near_auto_deposit(mouse_pos_3d):
			_cancel_structure_placement()
			_suppressed_deposit = null
		else:
			return
	if hovered == null or hovered == _suppressed_deposit or not _constructor_selected():
		return
	var scene_path = _extractor_scene_for(hovered.kind)
	if scene_path == null:
		return
	_start_structure_placement(load(scene_path))
	_auto_deposit = hovered


func _constructor_selected():
	return get_tree().get_nodes_in_group("selected_units").any(
		func(unit): return unit is Worker and unit.is_in_group("controlled_units")
	)


func _deposit_under(mouse_pos_3d):
	var closest = null
	var closest_distance = INF
	for deposit in get_tree().get_nodes_in_group("deposits"):
		if not deposit.is_inside_tree() or not deposit.visible:
			continue
		var distance = (deposit.global_position * Vector3(1, 0, 1)).distance_to(
			mouse_pos_3d * Vector3(1, 0, 1)
		)
		if distance <= deposit.radius + AUTO_PICK_HOVER_MARGIN_M and distance < closest_distance:
			closest = deposit
			closest_distance = distance
	return closest


func _mouse_near_auto_deposit(mouse_pos_3d):
	return (
		(_auto_deposit.global_position * Vector3(1, 0, 1)).distance_to(
			mouse_pos_3d * Vector3(1, 0, 1)
		)
		<= _auto_deposit.radius + _pending_structure_radius + AUTO_PICK_KEEP_MARGIN_M
	)


func _extractor_scene_for(kind):
	"""scene of a structure constructors can build to extract 'kind', unlocked ones first"""
	var candidates = []
	for entry in GameData.producible_by("worker"):
		if kind in entry.get("extracts", []):
			candidates.append(entry["scene"])
	if candidates.is_empty():
		return null
	for scene_path in candidates:
		if _player.meets_tier_requirement(scene_path):
			return scene_path
	return candidates[0]


func _snap_blueprint_next_to_deposit():
	"""puts the blueprint right next to the deposit, on the side of the mouse if it is free"""
	var mouse_pos_3d = _mouse_pos_3d()
	if mouse_pos_3d == null:
		return
	var center = _auto_deposit.global_position * Vector3(1, 0, 1)
	var direction = (mouse_pos_3d * Vector3(1, 0, 1)) - center
	if direction.length() < 0.05:
		direction = Vector3(0, 0, 1)
	direction = direction.normalized()
	var distance = _auto_deposit.radius + _pending_structure_radius + AUTO_PICK_GAP_M
	var height = Vector3(0, mouse_pos_3d.y, 0)
	for step in range(AUTO_PICK_SNAP_STEPS + 1):
		for side in [1.0, -1.0]:
			var angle = side * step * PI / AUTO_PICK_SNAP_STEPS
			_active_blueprint_node.global_transform.origin = (
				center + direction.rotated(Vector3.UP, angle) * distance + height
			)
			if not (
				_calculate_blueprint_position_validity()
				in [
					BlueprintPositionValidity.COLLIDES_WITH_OBJECT,
					BlueprintPositionValidity.NOT_NAVIGABLE,
					BlueprintPositionValidity.OUT_OF_MAP,
					BlueprintPositionValidity.IN_WATER,
				]
			):
				_feedback_label.global_transform.origin = (
					_active_blueprint_node.global_transform.origin
				)
				return
	_active_blueprint_node.global_transform.origin = center + direction * distance + height
	_feedback_label.global_transform.origin = _active_blueprint_node.global_transform.origin


func _mouse_pos_3d():
	var camera = get_viewport().get_camera_3d()
	if camera == null:
		return null
	return camera.get_ray_intersection(get_viewport().get_mouse_position())
