extends SceneTree
## Two isolated P2.12 hull-lateral application-point cases. The P2.5 BASE is
## reused from its protected result file; no third physics run is performed.

const LAB_SCENE := preload("res://scenes/SailboatLabP23c.tscn")
const BOAT_SCENE := "res://scenes/boats/SailingBoat8mP23c.tscn"
const PHYSICS_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_physics_profile.tres"
const VISUAL_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_visual_rig_profile.tres"
const POLAR_PROFILE_PATH := "res://resources/sailing/polar_test_profile.tres"
const P25_BASELINE_PATH := "res://docs/sailing/polar_p25/polar_2026-10-28_19-27-37_907713/polar_results.json"
const OUTPUT_ROOT := "res://docs/sailing/polar_p212"
const ENGINE_PHYSICS_HZ := 480
const TIME_SCALE := 8.0
const CASE_TIMEOUT_S := 180.0
const KNOTS_PER_MPS := 1.9438444924406
const VARIANTS := [
	{"id": "H1", "offset_z_m": -0.30, "label": "bowward_0.30m"},
	{"id": "H2", "offset_z_m": 0.30, "label": "sternward_0.30m"},
]
const CSV_FIELDS := [
	"variant", "application_offset_from_com_z_m", "run_id", "polar_config_hash", "boat_config_hash",
	"status", "failure_reason", "target_tws_kn", "target_twa_deg", "measured_twa_deg", "twa_error_deg",
	"mean_sog_kn", "mean_upwind_vmg_kn", "mean_target_course_vmg_kn", "mean_longitudinal_velocity_mps",
	"mean_lateral_velocity_mps", "mean_leeway_deg", "mean_heel_deg", "mean_rudder_deg", "rudder_saturation_fraction",
	"hull_lateral_force_starboard_n", "hull_longitudinal_resistance_forward_n", "hull_lateral_yaw_torque_nm",
	"hull_force_conservation_error_n", "hull_lateral_application_point_local_x_m", "hull_lateral_application_point_local_y_m", "hull_lateral_application_point_local_z_m",
	"keel_lateral_force_starboard_n", "keel_yaw_torque_nm", "rudder_lateral_force_starboard_n", "rudder_yaw_torque_nm",
	"main_yaw_torque_nm", "jib_yaw_torque_nm", "buoyancy_yaw_torque_nm", "known_measured_yaw_torque_sum_nm",
	"wave_queries_per_tick", "wind_queries_per_tick", "sample_count", "elapsed_simulation_seconds"
]

var _lab: Node3D
var _boat: RigidBody3D
var _runner: PolarTestRunner
var _old_physics_hz := 60
var _old_time_scale := 1.0
var _experiment_run_id := ""
var _output_directory := ""
var _rows: Array[Dictionary] = []
var _raw_results: Array[Dictionary] = []
var _variant_runs: Array[Dictionary] = []
var _error := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var base_profile := load(PHYSICS_PROFILE_PATH) as Resource
	var visual_profile := load(VISUAL_PROFILE_PATH) as Resource
	var baseline := _load_p25_baseline()
	if base_profile == null or visual_profile == null or baseline.is_empty():
		_finish(2, "P2.3c Profile or protected P2.5 BASE result could not be loaded")
		return
	var validation := _validate_inputs(base_profile, visual_profile, baseline)
	if not bool(validation.get("valid", false)):
		_finish(2, str(validation.get("reason", "P2.12 validation failed")))
		return
	if OS.get_cmdline_user_args().has("--validate-only"):
		print("P2.12 validation · %s" % str(validation))
		_finish(0)
		return

	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = ENGINE_PHYSICS_HZ
	Engine.time_scale = TIME_SCALE
	_experiment_run_id = "p212_%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec() % 1000000]
	_output_directory = OUTPUT_ROOT.path_join(_experiment_run_id)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_output_directory)):
		_finish(2, "Refusing to overwrite P2.12 output directory %s" % _output_directory)
		return
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_output_directory)) != OK:
		_finish(2, "Could not create P2.12 output directory")
		return

	var test_profile := (load(POLAR_PROFILE_PATH) as Resource).duplicate(true) as Resource
	test_profile.set("boat_scene_paths", PackedStringArray([BOAT_SCENE]))
	test_profile.set("case_timeout_seconds", CASE_TIMEOUT_S)
	var test_profile_path := _output_directory.path_join("p212_polar_test_profile.tres")
	if ResourceSaver.save(test_profile, test_profile_path) != OK:
		_finish(2, "Could not save the isolated P2.12 Polar profile")
		return
	var experiment_hash := _make_experiment_hash(test_profile, base_profile)

	var base_row := _make_base_row(baseline)
	_rows.append(base_row)
	for variant_value in VARIANTS:
		var variant: Dictionary = variant_value
		var result_row := await _run_variant(variant, test_profile)
		if result_row.is_empty():
			break
		_rows.append(result_row)
		if not bool(result_row.get("telemetry_finite", false)) or float(result_row.get("hull_force_conservation_error_n", INF)) > 0.00001:
			_error = "%s produced invalid telemetry or changed the summed hull resistance vector" % str(variant["id"])
			break

	_write_outputs(validation, base_profile, visual_profile, test_profile, experiment_hash, baseline)
	_finish(1 if not _error.is_empty() else 0)


func _validate_inputs(base_profile: Resource, visual_profile: Resource, baseline: Dictionary) -> Dictionary:
	if str(base_profile.resource_path) != PHYSICS_PROFILE_PATH or str(visual_profile.resource_path) != VISUAL_PROFILE_PATH:
		return {"valid": false, "reason": "P2.3c scene resources are not the expected isolated Profiles"}
	if absf(float(base_profile.get("mass_kg")) - 3200.0) > 0.001 or not Vector3(base_profile.get("center_of_mass_m")).is_equal_approx(Vector3(0.0, -0.65, 0.0)):
		return {"valid": false, "reason": "P2.3c mass or COM differs from the protected experiment baseline"}
	if absf(float(base_profile.get("hull_lateral_drag_linear_n_s_m")) - 500.0) > 0.001 or absf(float(base_profile.get("hull_lateral_drag_quadratic_n_s2_m2")) - 250.0) > 0.001:
		return {"valid": false, "reason": "P2.3c lateral hull resistance coefficients differ from the requested baseline"}
	if str(baseline.get("status", "")) != "HEADING_FAILED" or str(baseline.get("case_id", "")) != "p25_12kn_050twa_port":
		return {"valid": false, "reason": "Protected P2.5 BASE is not the requested PORT / 12 kn / -50 degree result"}
	return {
		"valid": true,
		"boat_scene_path": BOAT_SCENE,
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"mass_kg": base_profile.get("mass_kg"),
		"center_of_mass_local_m": base_profile.get("center_of_mass_m"),
		"hull_lateral_drag_linear_n_s_m": base_profile.get("hull_lateral_drag_linear_n_s_m"),
		"hull_lateral_drag_quadratic_n_s2_m2": base_profile.get("hull_lateral_drag_quadratic_n_s2_m2"),
		"variants": VARIANTS.duplicate(true),
		"base_source": P25_BASELINE_PATH,
		"profile_mutation": "none; application offsets are set through a test-only runtime method",
	}


func _run_variant(variant: Dictionary, test_profile: Resource) -> Dictionary:
	_lab = LAB_SCENE.instantiate() as Node3D
	_boat = _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	if _boat == null or _runner == null or _boat.scene_file_path != BOAT_SCENE:
		_error = "%s: P2.3c SailboatLab boat or runner is missing" % str(variant["id"])
		return {}
	var runtime_profile: Resource = _boat.get("profile") as Resource
	var anchors := _boat.get_node_or_null("VisualRoot/VisualRigAnchors") as Node3D
	var runtime_visual: Resource = anchors.get("visual_profile") as Resource if anchors != null else null
	if runtime_profile == null or runtime_profile.resource_path != PHYSICS_PROFILE_PATH or runtime_visual == null or runtime_visual.resource_path != VISUAL_PROFILE_PATH:
		_error = "%s: runtime boat is not using the protected P2.3c Profiles" % str(variant["id"])
		_lab.queue_free()
		return {}
	_runner.profile = test_profile.duplicate(true) as Resource
	_boat.set("p22_extended_telemetry_enabled", true)
	root.add_child(_lab)
	await process_frame
	var before_snapshot: Dictionary = _boat.call("get_debug_snapshot")
	if not _boat.has_method("set_test_hull_lateral_resistance_application_offset_z_m") or absf(float(before_snapshot.get("hull_lateral_application_offset_z_m", INF))) > 0.000001:
		_error = "%s: test-only lateral application override is missing or not default-off" % str(variant["id"])
		await _free_lab()
		return {}
	var offset_z := float(variant["offset_z_m"])
	if not bool(_boat.call("set_test_hull_lateral_resistance_application_offset_z_m", offset_z)):
		_error = "%s: could not set the requested COM-relative offset" % str(variant["id"])
		await _free_lab()
		return {}
	var set_snapshot: Dictionary = _boat.call("get_debug_snapshot")
	if absf(float(set_snapshot.get("hull_lateral_application_offset_z_m", INF)) - offset_z) > 0.000001:
		_error = "%s: requested offset did not reach the real boat instance" % str(variant["id"])
		await _free_lab()
		return {}

	var test_case := {
		"case_id": "p212_12kn_twa_m50_%s" % str(variant["id"]).to_lower(),
		"target_tws_kn": 12.0,
		"target_twa_deg": -50.0,
		"tack": "PORT",
		"experiment_group": "P212_NORDIC28_HULL_LATERAL_BALANCE",
		"experiment_variable": "hull_lateral_application_offset_z_m",
		"experiment_label": "%s · COM-relative local Z %+.2f m" % [str(variant["id"]), offset_z],
		"hull_lateral_application_offset_z_m": offset_z,
		"auto_sail_trim_enabled": true,
	}
	var started := _runner.start_new_batch({"include_extended_telemetry": true, "explicit_cases": [test_case]})
	if not started:
		_error = "%s: Polar runner did not start (%s)" % [str(variant["id"]), str(_runner.get_status_snapshot().get("status", "unknown"))]
		await _free_lab()
		return {}
	var initial: Dictionary = _runner.get_status_snapshot()
	print("P2.12 started · %s · run=%s · COM-relative Z=%+.2f m · dt=%.9f s" % [str(variant["id"]), str(initial.get("test_run_id", "")), offset_z, 1.0 / 60.0])
	await _wait_for_batch(str(variant["id"]))
	var final_state: Dictionary = _runner.get_status_snapshot()
	var checkpoint_path := str(final_state.get("output_path", ""))
	if checkpoint_path.is_empty() or not FileAccess.file_exists(checkpoint_path):
		_error = "%s: Polar runner did not write a checkpoint" % str(variant["id"])
		await _free_lab()
		return {}
	var checkpoint_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
	if not checkpoint_value is Dictionary:
		_error = "%s: checkpoint JSON could not be parsed" % str(variant["id"])
		await _free_lab()
		return {}
	var checkpoint: Dictionary = checkpoint_value
	var results: Array = checkpoint.get("results", [])
	if results.size() != 1:
		_error = "%s: expected one result, received %d" % [str(variant["id"]), results.size()]
		await _free_lab()
		return {}
	var raw_result: Dictionary = results[0]
	var run_id := str(checkpoint.get("test_run_id", ""))
	var runner_output := _output_directory.path_join("runner_runs").path_join(str(variant["id"]).to_lower())
	if not _copy_runner_artifacts(checkpoint, runner_output):
		await _free_lab()
		return {}
	var row := _make_result_row(variant, checkpoint, raw_result)
	row["runner_artifact_directory"] = runner_output
	if not bool(row.get("telemetry_finite", false)):
		_error = "%s: one or more force/torque telemetry fields were non-finite" % str(variant["id"])
	_variant_runs.append({
		"variant": variant,
		"run_id": run_id,
		"polar_config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"application_offset_from_com_z_m": offset_z,
		"status": raw_result.get("status", "UNKNOWN"),
		"runner_artifact_directory": runner_output,
	})
	_raw_results.append({"variant": variant, "checkpoint_metadata": checkpoint.get("run_metadata", {}), "raw_result": raw_result})
	_boat.call("set_test_hull_lateral_resistance_application_offset_z_m", 0.0)
	await _free_lab()
	return row


func _make_result_row(variant: Dictionary, checkpoint: Dictionary, result: Dictionary) -> Dictionary:
	var ext: Dictionary = result.get("extended_telemetry", {})
	var v_x := float(result.get("mean_velocity_world_x_mps", NAN))
	var v_z := float(result.get("mean_velocity_world_z_mps", NAN))
	var upwind_vmg := (v_x * sin(deg_to_rad(180.0)) - v_z * cos(deg_to_rad(180.0))) * KNOTS_PER_MPS
	var force_error := Vector3(
		float(ext.get("mean_hull_drag_calculated_force_local_n_x", NAN)) - float(ext.get("mean_hull_drag_applied_force_local_n_x", NAN)),
		float(ext.get("mean_hull_drag_calculated_force_local_n_y", NAN)) - float(ext.get("mean_hull_drag_applied_force_local_n_y", NAN)),
		float(ext.get("mean_hull_drag_calculated_force_local_n_z", NAN)) - float(ext.get("mean_hull_drag_applied_force_local_n_z", NAN))
	).length()
	return {
		"variant": str(variant["id"]),
		"application_offset_from_com_z_m": float(variant["offset_z_m"]),
		"run_id": checkpoint.get("test_run_id", ""),
		"polar_config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"status": result.get("status", "UNKNOWN"),
		"failure_reason": result.get("failure_reason", ""),
		"target_tws_kn": result.get("target_tws_kn", 12.0),
		"target_twa_deg": result.get("target_twa_deg", -50.0),
		"measured_twa_deg": result.get("measured_twa_deg", null),
		"twa_error_deg": float(result.get("measured_twa_deg", NAN)) - float(result.get("target_twa_deg", -50.0)),
		"mean_sog_kn": result.get("mean_sog_kn", null),
		"mean_upwind_vmg_kn": upwind_vmg,
		"mean_target_course_vmg_kn": result.get("mean_vmg_kn", null),
		"mean_longitudinal_velocity_mps": result.get("mean_longitudinal_velocity_mps", null),
		"mean_lateral_velocity_mps": ext.get("mean_body_lateral_speed_mps", null),
		"mean_leeway_deg": result.get("mean_leeway_deg", null),
		"mean_heel_deg": result.get("mean_heel_deg", null),
		"mean_rudder_deg": result.get("mean_rudder_deg", null),
		"rudder_saturation_fraction": result.get("rudder_saturation_fraction", null),
		"hull_lateral_force_starboard_n": ext.get("mean_hull_lateral_resistance_starboard_n", null),
		"hull_longitudinal_resistance_forward_n": ext.get("mean_hull_longitudinal_resistance_forward_n", null),
		"hull_lateral_yaw_torque_nm": ext.get("mean_hull_lateral_yaw_torque_nm", null),
		"hull_force_conservation_error_n": force_error,
		"hull_lateral_application_point_local_x_m": ext.get("mean_hull_lateral_application_point_local_m_x", null),
		"hull_lateral_application_point_local_y_m": ext.get("mean_hull_lateral_application_point_local_m_y", null),
		"hull_lateral_application_point_local_z_m": ext.get("mean_hull_lateral_application_point_local_m_z", null),
		"keel_lateral_force_starboard_n": ext.get("mean_keel_net_lateral_force_starboard_n", null),
		"keel_yaw_torque_nm": ext.get("mean_keel_net_torque_local_nm_y", null),
		"rudder_lateral_force_starboard_n": ext.get("mean_rudder_net_lateral_force_starboard_n", null),
		"rudder_yaw_torque_nm": ext.get("mean_rudder_net_torque_local_nm_y", null),
		"main_yaw_torque_nm": ext.get("mean_main_net_torque_local_nm_y", null),
		"jib_yaw_torque_nm": ext.get("mean_jib_net_torque_local_nm_y", null),
		"buoyancy_yaw_torque_nm": ext.get("mean_buoyancy_yaw_torque_nm", null),
		"known_measured_yaw_torque_sum_nm": ext.get("mean_measured_yaw_torque_sum_nm", null),
		"wave_queries_per_tick": ext.get("mean_wave_query_count_per_tick", null),
		"wind_queries_per_tick": ext.get("mean_wind_query_count_per_tick", null),
		"sample_count": result.get("sample_count", 0),
		"elapsed_simulation_seconds": result.get("elapsed_simulation_seconds", null),
		"telemetry_finite": bool(ext.get("telemetry_finite", false)),
		"extended_telemetry": ext,
		"raw_result": result,
	}


func _make_base_row(result: Dictionary) -> Dictionary:
	var ext: Dictionary = result.get("extended_telemetry", {})
	var v_x := float(result.get("mean_velocity_world_x_mps", NAN))
	var v_z := float(result.get("mean_velocity_world_z_mps", NAN))
	var com: Vector3 = (load(PHYSICS_PROFILE_PATH) as Resource).get("center_of_mass_m")
	var upwind_vmg := (v_x * sin(deg_to_rad(180.0)) - v_z * cos(deg_to_rad(180.0))) * KNOTS_PER_MPS
	return {
		"variant": "BASE",
		"application_offset_from_com_z_m": 0.0,
		"run_id": result.get("test_run_id", "polar_2026-10-28_19-27-37_907713"),
		"polar_config_hash": "P2.5 base run; see source result metadata",
		"boat_config_hash": result.get("boat_config_hash", ""),
		"status": result.get("status", "UNKNOWN"),
		"failure_reason": result.get("failure_reason", ""),
		"target_tws_kn": result.get("target_tws_kn", 12.0),
		"target_twa_deg": result.get("target_twa_deg", -50.0),
		"measured_twa_deg": result.get("measured_twa_deg", null),
		"twa_error_deg": float(result.get("measured_twa_deg", NAN)) - float(result.get("target_twa_deg", -50.0)),
		"mean_sog_kn": result.get("mean_sog_kn", null),
		"mean_upwind_vmg_kn": upwind_vmg,
		"mean_target_course_vmg_kn": result.get("mean_vmg_kn", null),
		"mean_longitudinal_velocity_mps": result.get("mean_longitudinal_velocity_mps", null),
		"mean_lateral_velocity_mps": ext.get("mean_body_lateral_speed_mps", null),
		"mean_leeway_deg": result.get("mean_leeway_deg", null),
		"mean_heel_deg": result.get("mean_heel_deg", null),
		"mean_rudder_deg": result.get("mean_rudder_deg", null),
		"rudder_saturation_fraction": result.get("rudder_saturation_fraction", null),
		"hull_lateral_force_starboard_n": ext.get("mean_hull_lateral_resistance_starboard_n", null),
		"hull_longitudinal_resistance_forward_n": ext.get("mean_hull_longitudinal_resistance_forward_n", null),
		"hull_lateral_yaw_torque_nm": 0.0,
		"hull_force_conservation_error_n": 0.0,
		"hull_lateral_application_point_local_x_m": com.x,
		"hull_lateral_application_point_local_y_m": com.y,
		"hull_lateral_application_point_local_z_m": com.z,
		"keel_lateral_force_starboard_n": ext.get("mean_keel_net_lateral_force_starboard_n", null),
		"keel_yaw_torque_nm": ext.get("mean_keel_net_torque_local_nm_y", null),
		"rudder_lateral_force_starboard_n": ext.get("mean_rudder_net_lateral_force_starboard_n", null),
		"rudder_yaw_torque_nm": ext.get("mean_rudder_net_torque_local_nm_y", null),
		"main_yaw_torque_nm": ext.get("mean_main_net_torque_local_nm_y", null),
		"jib_yaw_torque_nm": ext.get("mean_jib_net_torque_local_nm_y", null),
		"buoyancy_yaw_torque_nm": ext.get("mean_buoyancy_yaw_torque_nm", null),
		"known_measured_yaw_torque_sum_nm": ext.get("mean_measured_yaw_torque_sum_nm", null),
		"wave_queries_per_tick": ext.get("mean_wave_query_count_per_tick", null),
		"wind_queries_per_tick": ext.get("mean_wind_query_count_per_tick", null),
		"sample_count": result.get("sample_count", 0),
		"elapsed_simulation_seconds": result.get("elapsed_simulation_seconds", null),
		"telemetry_finite": true,
		"extended_telemetry": ext,
		"raw_result": result,
	}


func _load_p25_baseline() -> Dictionary:
	if not FileAccess.file_exists(P25_BASELINE_PATH):
		return {}
	var document: Variant = JSON.parse_string(FileAccess.get_file_as_string(P25_BASELINE_PATH))
	if not document is Dictionary:
		return {}
	for result_value in document.get("results", []):
		var result: Dictionary = result_value
		if str(result.get("case_id", "")) == "p25_12kn_050twa_port":
			var row := result.duplicate(true)
			row["test_run_id"] = str(document.get("metadata", {}).get("test_run_id", "polar_2026-10-28_19-27-37_907713"))
			row["boat_config_hash"] = str(result.get("boat_config_hash", document.get("metadata", {}).get("boat_config_hash", "")))
			row["source_metadata"] = document.get("metadata", {})
			return row
	return {}


func _make_experiment_hash(test_profile: Resource, base_profile: Resource) -> String:
	var signature := {
		"phase": "P2.12 hull lateral application-point comparison",
		"boat_scene_path": BOAT_SCENE,
		"boat_scene_sha256": _sha256_file(BOAT_SCENE),
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"physics_profile_sha256": _sha256_file(PHYSICS_PROFILE_PATH),
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"visual_profile_sha256": _sha256_file(VISUAL_PROFILE_PATH),
		"polar_profile_values": _resource_values(test_profile),
		"body_script_sha256": _sha256_file("res://scripts/sailboat_lab_body.gd"),
		"polar_runner_sha256": _sha256_file("res://scripts/polar_test_runner.gd"),
		"test_script_sha256": _sha256_file("res://tests/run_polar_p212_hull_lateral_balance.gd"),
		"godot_version": Engine.get_version_info(),
		"physics_ticks_per_second": ENGINE_PHYSICS_HZ,
		"time_scale": TIME_SCALE,
		"conditions": {"tws_kn": 12.0, "target_twa_deg": -50.0, "tack": "PORT", "engine": "OFF", "waves": "zero amplitude", "water_current_mps": [0.0, 0.0, 0.0]},
		"variants": VARIANTS,
		"protected_base_boat_profile_values": _resource_values(base_profile),
	}
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSON.stringify(signature, "", true).to_utf8_buffer())
	return context.finish().hex_encode()


func _resource_values(resource: Resource) -> Dictionary:
	var result := {}
	for property_value in resource.get_property_list():
		var property: Dictionary = property_value
		if (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var name := str(property.get("name", ""))
		if name == "script" or name.begins_with("resource_"):
			continue
		var value: Variant = resource.get(name)
		result[name] = str(value) if value is Resource else value
	return result


func _write_outputs(validation: Dictionary, base_profile: Resource, visual_profile: Resource, test_profile: Resource, experiment_hash: String, baseline: Dictionary) -> void:
	var csv_lines := PackedStringArray([",".join(PackedStringArray(CSV_FIELDS))])
	for row in _rows:
		var cells := PackedStringArray()
		for field in CSV_FIELDS:
			cells.append(_csv_value(row.get(field, null)))
		csv_lines.append(",".join(cells))
	_write_text(_output_directory.path_join("hull_lateral_balance.csv"), "\n".join(csv_lines) + "\n")
	_write_json(_output_directory.path_join("hull_lateral_balance.json"), {
		"experiment": "Nordic 28 P2.12 hull lateral resistance application-point experiment",
		"experiment_run_id": _experiment_run_id,
		"experiment_config_fingerprint": experiment_hash,
		"conditions": {"tws_kn": 12.0, "target_twa_deg": -50.0, "tack": "PORT", "engine": "OFF", "wave_mode": "WaveSampler enabled with zero amplitude", "water_current_mps": [0.0, 0.0, 0.0]},
		"application_point_definition": "COM local point + (0, 0, offset_z); lateral X resistance only is applied there; longitudinal Z and any Y component stay central.",
		"physics_step_seconds": 1.0 / 60.0,
		"execution_acceleration": {"engine_physics_ticks_per_second": ENGINE_PHYSICS_HZ, "time_scale": TIME_SCALE, "effective_simulated_steps_per_second": 60.0, "timeout_simulation_seconds": CASE_TIMEOUT_S},
		"protected_baseline": {"source": P25_BASELINE_PATH, "run_id": baseline.get("test_run_id", ""), "boat_config_hash": baseline.get("boat_config_hash", ""), "result": _make_base_row(baseline)},
		"experiment_runs": _variant_runs,
		"results": _rows,
		"raw_runner_results": _raw_results,
		"profile_validation": validation,
		"known_force_and_torque_limits": ["Hull resistance is calculated once and its components are applied once; the local resultant is checked against the calculated vector.", "Yaw torque is about rigid-body local +Y; known measured moment sum includes explicit cached moments only and is not the complete engine solver net moment."],
	})
	_write_json(_output_directory.path_join("p212_manifest.json"), {
		"experiment_run_id": _experiment_run_id,
		"experiment_config_fingerprint": experiment_hash,
		"created_at": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info(),
		"boat_scene_path": BOAT_SCENE,
		"boat_scene_sha256": _sha256_file(BOAT_SCENE),
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"physics_profile_sha256": _sha256_file(PHYSICS_PROFILE_PATH),
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"visual_profile_sha256": _sha256_file(VISUAL_PROFILE_PATH),
		"saved_test_polar_profile_path": _output_directory.path_join("p212_polar_test_profile.tres"),
		"saved_test_polar_profile_sha256": _sha256_file(_output_directory.path_join("p212_polar_test_profile.tres")),
		"runner_sha256": _sha256_file("res://scripts/polar_test_runner.gd"),
		"body_sha256": _sha256_file("res://scripts/sailboat_lab_body.gd"),
		"test_script_sha256": _sha256_file("res://tests/run_polar_p212_hull_lateral_balance.gd"),
		"conditions": {"tws_kn": 12.0, "target_twa_deg": -50.0, "tack": "PORT", "engine": "OFF", "auto_trim": true, "rudder_controller": "existing Polar PD", "rudder_limit_degrees": 35.0, "wave_sampler_enabled_amplitude_zero": true, "current_mps": [0.0, 0.0, 0.0]},
		"unchanged_physics_parameters": _resource_values(base_profile),
		"visual_profile_values": _resource_values(visual_profile),
		"stability_settings": _resource_values(test_profile),
		"execution": {"physics_step_seconds": 1.0 / 60.0, "physics_ticks_per_second": ENGINE_PHYSICS_HZ, "time_scale": TIME_SCALE, "case_timeout_seconds": CASE_TIMEOUT_S},
		"p25_baseline": {"source": P25_BASELINE_PATH, "run_id": baseline.get("test_run_id", ""), "boat_config_hash": baseline.get("boat_config_hash", ""), "status": baseline.get("status", "")},
		"runs": _variant_runs,
		"validation": validation,
		"error": _error,
	})


func _copy_runner_artifacts(checkpoint: Dictionary, destination: String) -> bool:
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(destination)):
		_error = "Refusing to overwrite P2.12 runner artifacts at %s" % destination
		return false
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination)) != OK:
		_error = "Could not create P2.12 runner artifact directory"
		return false
	var source_directory := str(checkpoint.get("run_directory", ""))
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		var source := source_directory.path_join(filename)
		if not FileAccess.file_exists(source):
			_error = "Missing Polar artifact %s" % source
			return false
		if not _write_text(destination.path_join(filename), FileAccess.get_file_as_string(source)):
			return false
	return true


func _wait_for_batch(variant_id: String) -> void:
	var last_log_usec := 0
	while bool(_runner.get_status_snapshot().get("running", false)):
		await process_frame
		var snapshot: Dictionary = _runner.get_status_snapshot()
		var now := Time.get_ticks_usec()
		if now - last_log_usec >= 15000000:
			last_log_usec = now
			print("P2.12 progress · %s · sim %.0f s · SOG %.2f kn · TWA %+.1f° · rudder %+.1f°" % [
				variant_id, float(snapshot.get("simulation_seconds", 0.0)), float(snapshot.get("sog_kn", 0.0)),
				float(snapshot.get("measured_twa_deg", NAN)), float(snapshot.get("rudder_deg", NAN)),
			])


func _free_lab() -> void:
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
		await process_frame
	_lab = null
	_boat = null
	_runner = null


func _finish(code: int, message: String = "") -> void:
	if not message.is_empty():
		print("P2.12 · %s" % message)
	if _lab != null:
		await _free_lab()
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	quit(code)


func _write_text(path: String, contents: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_error = "Could not write %s: %s" % [path, error_string(FileAccess.get_open_error())]
		return false
	file.store_string(contents)
	return true


func _write_json(path: String, value: Variant) -> bool:
	return _write_text(path, JSON.stringify(value, "\t") + "\n")


func _csv_value(value: Variant) -> String:
	if value == null:
		return ""
	if typeof(value) in [TYPE_FLOAT, TYPE_INT] and not is_finite(float(value)):
		return ""
	var text := "%.8f" % float(value) if typeof(value) == TYPE_FLOAT else str(value)
	if text.contains(",") or text.contains("\"") or text.contains("\n"):
		text = "\"" + text.replace("\"", "\"\"") + "\""
	return text


func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "UNAVAILABLE"
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()
