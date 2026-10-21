extends SceneTree

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const PROFILE := preload("res://resources/sailing/sailboat_lab_profile.tres")

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var project_default := float(ProjectSettings.get_setting("physics/3d/default_linear_damp", 0.1))
	_expect(int(PROFILE.get("linear_damp_mode")) == RigidBody3D.DAMP_MODE_REPLACE, "SailboatLab profile selects REPLACE mode")
	_expect(is_zero_approx(float(PROFILE.get("linear_damping"))), "SailboatLab profile disables generic linear damping")
	_test_historical_diagnostic_baselines()
	for instance_index in range(2):
		var lab := LAB_SCENE.instantiate()
		root.add_child(lab)
		await process_frame
		var boat := lab.get_node_or_null("SailboatBody") as RigidBody3D
		_expect(boat != null, "SailboatLab instance %d resolves its rigid body" % (instance_index + 1))
		if boat != null:
			_expect(boat.linear_damp_mode == RigidBody3D.DAMP_MODE_REPLACE, "SailboatLab instance %d keeps REPLACE mode after initialization" % (instance_index + 1))
			_expect(is_zero_approx(boat.linear_damp), "SailboatLab instance %d has zero body linear damping" % (instance_index + 1))
			var effective := boat.linear_damp if boat.linear_damp_mode == RigidBody3D.DAMP_MODE_REPLACE else boat.linear_damp + project_default
			_expect(is_zero_approx(effective), "project default damping is not re-added to SailboatLab instance %d" % (instance_index + 1))
		lab.queue_free()
		await process_frame
	_expect(is_equal_approx(float(ProjectSettings.get_setting("physics/3d/default_linear_damp", 0.1)), project_default), "SailboatLab does not alter project-wide default damping")
	if _failures.is_empty():
		print("Sailboat damping policy tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_historical_diagnostic_baselines() -> void:
	var c5b := _find_csv_row("res://docs/sailing/c5b_data/s1_c5b_full_time_history.csv", "cross_270_trim_50", "sim_time_s", "120.000000")
	_expect(not c5b.is_empty(), "historical C5b 120 s crosswind snapshot remains available")
	if not c5b.is_empty():
		_expect(_csv_near(c5b, "sog_knots", 0.908195, 0.00001), "historical C5b SOG snapshot is retained")
		_expect(_csv_near(c5b, "longitudinal_speed_mps", 0.447995, 0.00001), "historical C5b longitudinal speed snapshot is retained")
	var c5c := _find_csv_row("res://docs/sailing/c5c_data/s1_c5c_steady_force_decomposition.csv", "baseline_8ms_50deg", "sim_time_s", "120.000000")
	_expect(not c5c.is_empty(), "historical C5c 120 s force snapshot remains available")
	if not c5c.is_empty():
		_expect(_csv_near(c5c, "effective_linear_damp_coefficient", 0.22, 0.00001), "historical C5c combined damping snapshot remains 0.22/s")
		_expect(_csv_near(c5c, "sog_knots", 0.908195, 0.00001), "historical C5c SOG snapshot is retained")


func _find_csv_row(path: String, case_name: String, time_field: String, time_value: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var header := file.get_csv_line()
	var case_index := header.find("case")
	var time_index := header.find(time_field)
	if case_index < 0 or time_index < 0:
		file.close()
		return {}
	while not file.eof_reached():
		var cells := file.get_csv_line()
		if cells.size() != header.size():
			continue
		if cells[case_index] == case_name and cells[time_index] == time_value:
			file.close()
			return {"header": header, "cells": cells}
	file.close()
	return {}


func _csv_near(row: Dictionary, field: String, expected: float, tolerance: float) -> bool:
	var header: Array = row.get("header", [])
	var cells: Array = row.get("cells", [])
	var index := header.find(field)
	return index >= 0 and index < cells.size() and absf(float(cells[index]) - expected) <= tolerance


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
		push_error("FAIL: " + message)
