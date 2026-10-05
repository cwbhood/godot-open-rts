extends Node3D

const SIGHT_COMPENSATION = 2.0  # compensates for blurry edges of FoW
const REFRESH_EVERY_PHYSICS_TICKS = 3

const Structure = preload("res://source/match/units/Structure.gd")

var _units_processed_at_least_once = {}
var _structure_to_dummy_mapping = {}
var _orphaned_dummies = []
var _ticks_until_refresh = 0


func _ready():
	MatchSignals.unit_spawned.connect(_recalculate_unit_visibility)
	MatchSignals.unit_died.connect(_on_unit_died)


func _physics_process(_delta):
	# every unit against every revealing unit is the costliest check of a big match; a 20 Hz
	# refresh looks the same as a 60 Hz one
	_ticks_until_refresh -= 1
	if _ticks_until_refresh > 0:
		return
	_ticks_until_refresh = REFRESH_EVERY_PHYSICS_TICKS
	var revealers = _index_revealers()
	for unit in get_tree().get_nodes_in_group("units"):
		_recalculate_unit_visibility(unit, revealers)
	for orphaned_dummy in _orphaned_dummies.duplicate():
		_recalcuate_orphaned_dummy_existence(orphaned_dummy, revealers)


func _is_disabled():
	return not visible


func _index_revealers():
	"""buckets revealing units on a grid as wide as the longest sight, so a lookup only checks
	the revealers of the 3x3 cells around a point instead of all of them"""
	var entries = []
	var cell_size = 1.0
	for unit in get_tree().get_nodes_in_group("revealed_units"):
		if not unit.is_revealing():
			continue
		var sight_range = unit.sight_range  # weather-dependent getter, read it once
		if sight_range == null:
			continue
		var reach = sight_range + SIGHT_COMPENSATION
		var position = Vector2(unit.global_position.x, unit.global_position.z)
		entries.append([position, reach * reach])
		cell_size = max(cell_size, reach)
	var cells = {}
	for entry in entries:
		cells.get_or_add(_cell_of(entry[0], cell_size), []).append(entry)
	return {"cell_size": cell_size, "cells": cells}


func _cell_of(position, cell_size):
	return Vector2i(floori(position.x / cell_size), floori(position.y / cell_size))


func _is_revealed(global_position_3d, revealers):
	var position = Vector2(global_position_3d.x, global_position_3d.z)
	var center = _cell_of(position, revealers["cell_size"])
	var cells = revealers["cells"]
	for x in range(center.x - 1, center.x + 2):
		for y in range(center.y - 1, center.y + 2):
			var bucket = cells.get(Vector2i(x, y))
			if bucket == null:
				continue
			for entry in bucket:
				if entry[0].distance_squared_to(position) <= entry[1]:
					return true
	return false


func _recalculate_unit_visibility(unit, revealers = null):
	if unit.is_in_group("revealed_units") or _is_disabled():
		_update_unit_visibility(unit, true)
		return
	if revealers == null:
		revealers = _index_revealers()
	_update_unit_visibility(unit, _is_revealed(unit.global_position, revealers))


func _update_unit_visibility(unit, should_be_visible):
	if (
		unit in _units_processed_at_least_once
		and unit is Structure
		and unit.visible != should_be_visible
	):
		if unit.visible:
			_create_dummy_structure(unit)
		else:
			_try_removing_dummy_structure(unit)
	unit.visible = should_be_visible
	_units_processed_at_least_once[unit] = true


func _create_dummy_structure(unit):
	if unit in _structure_to_dummy_mapping:
		return
	var dummy = unit.find_child("Geometry").duplicate()
	dummy.global_transform = unit.find_child("Geometry").global_transform
	add_child(dummy)
	_structure_to_dummy_mapping[unit] = dummy


func _try_removing_dummy_structure(unit):
	if unit in _structure_to_dummy_mapping:
		_structure_to_dummy_mapping[unit].queue_free()
		_structure_to_dummy_mapping.erase(unit)


func _recalcuate_orphaned_dummy_existence(orphaned_dummy, revealers = null):
	if revealers == null:
		revealers = _index_revealers()
	if _is_revealed(orphaned_dummy.global_position, revealers):
		_orphaned_dummies.erase(orphaned_dummy)
		orphaned_dummy.queue_free()


func _on_unit_died(unit):
	_units_processed_at_least_once.erase(unit)
	if unit in _structure_to_dummy_mapping:
		var orphaned_dummy = _structure_to_dummy_mapping[unit]
		_structure_to_dummy_mapping.erase(unit)
		_orphaned_dummies.append(orphaned_dummy)
		_recalcuate_orphaned_dummy_existence(orphaned_dummy)
