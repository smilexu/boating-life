extends SceneTree
## Four single-sail trim sensitivity cases for Nordic 28 P2.6.
## Each condition uses the real P2.3c rigid body and the existing Polar PD helm.

const LAB_SCENE := preload("res://scenes/SailboatLabP23c.tscn")
const BOAT_SCENE := "res://scenes/boats/SailingBoat8mP23c.tscn"
const PHYSICS_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_physics_profile.tres"
const VISUAL_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_visual_rig_profile.tres"
const POLAR_PROFILE := preload("res://resources/sailing/polar_test_profile.tres")
const OUTPUT_ROOT := "res://docs/sailing/polar_p26"
const ENGINE_PHYSICS_HZ := 480
const TIME_SCALE := 8.0
const CASE_TIMEOUT_S := 180.0
const CSV_FIELDS := [
	"case_id", "phase", "trim_name", "status", "failure_reason", "target_tws_kn", "target_twa_deg", "measured_twa_deg",
	"heading_error_deg", "mean_sog_kn", "mean_longitudinal_velocity_mps", "mean_leeway_deg", "mean_heel_deg",
	"main_target_deg", "main_actual_deg", "jib_target_deg", "jib_actual_deg", "rudder_target_deg", "rudder_actual_deg",
	"rudder_saturation_fraction", "main_forward_force_n", "jib_forward_force_n", "main_local_y_torque_nm", "jib_local_y_torque_nm",
	"keel_local_y_torque_nm", "rudder_local_y_torque_nm", "buoyancy_local_y_torque_nm", "explicit_damping_local_y_torque_nm",
	"known_local_y_torque_sum_nm", "main_aoa_deg", "jib_aoa_deg", "main_cl", "jib_cl", "rudder_water_speed_mps", "rudder_aoa_deg"
]

var _lab: Node3D
var _boat: RigidBody3D
var _runner: PolarTestRunner
var _old_physics_hz := 60
var _old_time_scale := 1.0
var _error := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	Engine.physics_ticks_per_second = ENGINE_PHYSICS_HZ
	Engine.time_scale = TIME_SCALE
	_lab = LAB_SCENE.instantiate() as Node3D
	_boat = _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	if _boat == null or _runner == null:
		_finish(2, "P2.3c SailboatLab is missing the boat or PolarTestRunner")
		return
	var validation := _validate_rig()
	if not bool(validation.get("valid", false)):
		_finish(2, str(validation.get("reason", "P2.3c resource validation failed")))
		return
	var test_profile := (POLAR_PROFILE as Resource).duplicate(true)
	test_profile.set("boat_scene_paths", PackedStringArray([BOAT_SCENE]))
	test_profile.set("case_timeout_seconds", CASE_TIMEOUT_S)
	_runner.profile = test_profile
	_boat.set("p22_extended_telemetry_enabled", true)
	root.add_child(_lab)
	await process_frame
	if OS.get_cmdline_user_args().has("--validate-only"):
		print("P2.6 configuration validation · %s" % str(validation))
		_finish(0)
		return
	var phase_two := OS.get_cmdline_user_args().has("--phase2")
	var cases := _build_cases(phase_two)
	if cases.size() != 4:
		_finish(2, "P2.6 phase 1 expected exactly four cases")
		return
	var started := _runner.start_new_batch({"include_extended_telemetry": true, "explicit_cases": cases})
	if not started:
		_finish(2, "P2.6 phase 1 batch did not start")
		return
	var initial := _runner.get_status_snapshot()
	print("P2.6 phase 1 started · run=%s · dt=%.9f s · cases=%d" % [str(initial.get("test_run_id", "pending")), 1.0 / 60.0, cases.size()])
	await _wait_for_batch()
	var state := _runner.get_status_snapshot()
	var checkpoint_path := str(state.get("output_path", ""))
	if checkpoint_path.is_empty() or not FileAccess.file_exists(checkpoint_path):
		_finish(1, "P2.6 phase 1 did not produce a Polar checkpoint")
		return
	var checkpoint_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
	if not checkpoint_value is Dictionary:
		_finish(1, "P2.6 phase 1 checkpoint could not be parsed")
		return
	var checkpoint: Dictionary = checkpoint_value
	var run_id := str(checkpoint.get("test_run_id", "p26_unknown"))
	var destination := OUTPUT_ROOT.path_join(run_id)
	if FileAccess.file_exists(destination.path_join("polar_results.json")):
		_finish(1, "Refusing to overwrite P2.6 output %s" % destination)
		return
	if not _copy_artifacts(checkpoint, destination):
		_finish(1, _error)
		return
	var results: Array = checkpoint.get("results", [])
	if results.size() != cases.size():
		_finish(1, "P2.6 returned %d rows; expected %d" % [results.size(), cases.size()])
		return
	if not _write_results_csv(destination.path_join("trim_candidates.csv"), results):
		_finish(1, _error)
		return
	var result_summaries := _make_result_summaries(results)
	var baseline := {
		"source": "P2.5 run polar_2026-10-28_19-27-37_907713, 12 kn / TWA -50, final analysis window",
		"status": "HEADING_FAILED", "measured_twa_deg": -58.9676725539986, "mean_sog_kn": 1.51279703587229,
		"mean_longitudinal_velocity_mps": 0.713584657510122, "mean_leeway_deg": 23.3047830962883,
		"mean_heel_deg": -8.01293990216639, "main_actual_deg": 24.460, "jib_actual_deg": 19.460,
		"rudder_actual_deg": -35.0, "rudder_target_deg": -35.0, "rudder_saturation_fraction": 1.0,
		"known_local_y_torque_sum_nm": 0.0382781982421875,
	}
	var manifest := {
		"experiment": "Nordic 28 P2.6 near-upwind sail trim/yaw balance sensitivity",
		"phase": "combined trim probes" if phase_two else "single-sail sensitivity probes",
		"test_run_id": run_id,
		"polar_config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"boat_scene_path": BOAT_SCENE,
		"boat_scene_sha256": _sha256_file(BOAT_SCENE),
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"physics_profile_sha256": _sha256_file(PHYSICS_PROFILE_PATH),
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"visual_profile_sha256": _sha256_file(VISUAL_PROFILE_PATH),
		"test_script_sha256": _sha256_file("res://tests/run_polar_p26_trim_balance.gd"),
		"fixed_condition": {"tws_kn": 12.0, "target_twa_deg": -50.0, "tack": "PORT", "engine": "OFF", "current_mps": Vector3.ZERO, "wave_mode": "WaveSampler enabled; amplitude zero"},
		"physics_step_seconds": 1.0 / 60.0,
		"execution_acceleration": {"physics_ticks_per_second": ENGINE_PHYSICS_HZ, "time_scale": TIME_SCALE},
		"stability_config": checkpoint.get("run_metadata", {}).get("config", {}),
		"trim_cases": cases,
		"p25_reference_baseline": baseline,
		"p25_reference_run_id": "polar_2026-10-28_19-27-37_907713",
		"resource_validation": validation,
		"summary_results": result_summaries,
	}
	if not _write_json(destination.path_join("p26_manifest.json"), manifest):
		_finish(1, _error)
		return
	if not _write_json(destination.path_join("p26_summary.json"), {"test_run_id": run_id, "status_counts": _status_counts(results), "results": result_summaries, "p25_baseline": baseline}):
		_finish(1, _error)
		return
	print("P2.6 phase 1 complete · %d/%d · run=%s · statuses=%s · output=%s" % [
		int(state.get("completed_count", 0)), int(state.get("case_count", 0)), run_id, str(_status_counts(results)), destination,
	])
	_finish(0)


func _validate_rig() -> Dictionary:
	if _boat.scene_file_path != BOAT_SCENE:
		return {"valid": false, "reason": "Unexpected test scene %s" % _boat.scene_file_path}
	var physics: Resource = _boat.get("profile") as Resource
	var anchors := _boat.get_node_or_null("VisualRoot/VisualRigAnchors") as Node3D
	var visual: Resource = anchors.get("visual_profile") as Resource if anchors != null else null
	if physics == null or visual == null or physics.resource_path != PHYSICS_PROFILE_PATH or visual.resource_path != VISUAL_PROFILE_PATH:
		return {"valid": false, "reason": "P2.3c isolated profiles are not bound to the boat"}
	return {
		"valid": true, "boat_scene_path": _boat.scene_file_path,
		"physics_profile_path": physics.resource_path, "visual_profile_path": visual.resource_path,
		"mass_kg": float(physics.get("mass_kg")),
		"main_sail_area_m2": float(physics.get("main_sail_area_m2")),
		"jib_area_m2": float(physics.get("headsail_area_m2")),
		"center_of_mass_local_m": physics.get("center_of_mass_m"),
		"rudder_limit_deg": rad_to_deg(float(physics.get("max_rudder_angle_rad"))),
	}


func _build_cases(phase_two: bool) -> Array[Dictionary]:
	var specs := [
		{"name": "M_MINUS", "main": 19.46, "jib": 19.46},
		{"name": "M_PLUS", "main": 29.46, "jib": 19.46},
		{"name": "J_MINUS", "main": 24.46, "jib": 14.46},
		{"name": "J_PLUS", "main": 24.46, "jib": 24.46},
	]
	if phase_two:
		specs = [
			{"name": "M_PLUS5_J_PLUS2P5", "main": 29.46, "jib": 21.96},
			{"name": "M_PLUS10_J_PLUS2P5", "main": 34.46, "jib": 21.96},
			{"name": "M_PLUS5_J_PLUS5", "main": 29.46, "jib": 24.46},
			{"name": "M_PLUS10_J_PLUS5", "main": 34.46, "jib": 24.46},
		]
	var output: Array[Dictionary] = []
	for spec in specs:
		output.append({
			"case_id": "p26_12kn_050twa_%s" % str(spec["name"]).to_lower(),
			"target_tws_kn": 12.0, "target_twa_deg": -50.0, "tack": "PORT",
			"experiment_group": "P26_NORDIC28_TRIM_BALANCE",
			"experiment_variable": str(spec["name"]),
			"experiment_label": "P2.6 · 12 kn / TWA -50° / %s" % str(spec["name"]),
			"auto_sail_trim_enabled": false,
			"main_trim_magnitude_deg": float(spec["main"]),
			"headsail_trim_magnitude_deg": float(spec["jib"]),
		})
	return output


func _wait_for_batch() -> void:
	var last_case := ""
	var last_log_usec := 0
	while bool(_runner.get_status_snapshot().get("running", false)):
		await process_frame
		var snapshot := _runner.get_status_snapshot()
		var case_id := str(snapshot.get("current_case_id", ""))
		var now := Time.get_ticks_usec()
		if case_id != last_case or now - last_log_usec >= 15000000:
			last_case = case_id
			last_log_usec = now
			print("P2.6 progress · %d/%d · %s · sim %.0f s · %.2f kn · TWA %+.1f° · rudder %+.1f°" % [
				int(snapshot.get("completed_count", 0)), int(snapshot.get("case_count", 0)), case_id,
				float(snapshot.get("simulation_seconds", 0.0)), float(snapshot.get("sog_kn", 0.0)),
				float(snapshot.get("measured_twa_deg", 0.0)), float(snapshot.get("rudder_deg", 0.0)),
			])


func _write_results_csv(path: String, results: Array) -> bool:
	var lines := PackedStringArray([",".join(PackedStringArray(CSV_FIELDS))])
	for result in results:
		var ext: Dictionary = result.get("extended_telemetry", {})
		var values := [
			result.get("case_id", ""), "combined_trim_probe" if OS.get_cmdline_user_args().has("--phase2") else "single_sail_probe", result.get("experiment_variable", ""), result.get("status", ""), result.get("failure_reason", ""),
			result.get("target_tws_kn", null), result.get("target_twa_deg", null), result.get("measured_twa_deg", null), result.get("heading_error_deg", null),
			result.get("mean_sog_kn", null), result.get("mean_longitudinal_velocity_mps", null), result.get("mean_leeway_deg", null), result.get("mean_heel_deg", null),
			result.get("main_sail_deg", null), ext.get("mean_main_target_angle_deg", null), result.get("headsail_deg", null), ext.get("mean_jib_target_angle_deg", null),
			ext.get("mean_rudder_target_angle_deg", null), result.get("mean_rudder_deg", null), result.get("rudder_saturation_fraction", null),
			result.get("mean_main_forward_force_n", null), result.get("mean_headsail_forward_force_n", null),
			ext.get("mean_main_net_torque_local_nm_y", null), ext.get("mean_jib_net_torque_local_nm_y", null),
			ext.get("mean_keel_net_torque_local_nm_y", null), ext.get("mean_rudder_net_torque_local_nm_y", null),
			ext.get("mean_buoyancy_yaw_torque_nm", null), ext.get("mean_axis_damping_yaw_torque_nm", null), ext.get("mean_measured_yaw_torque_sum_nm", null),
			ext.get("mean_main_aoa_deg", null), ext.get("mean_jib_aoa_deg", null), ext.get("mean_main_cl", null), ext.get("mean_jib_cl", null),
			ext.get("mean_rudder_water_speed_mps", null), ext.get("mean_rudder_aoa_deg", null),
		]
		var row := PackedStringArray()
		for value in values:
			row.append(_csv_value(value))
		lines.append(",".join(row))
	if not _write_text(path, "\n".join(lines) + "\n"):
		return false
	return true


func _make_result_summaries(results: Array) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for result in results:
		var ext: Dictionary = result.get("extended_telemetry", {})
		output.append({
			"case_id": result.get("case_id", ""), "trim_name": result.get("experiment_variable", ""), "status": result.get("status", ""),
			"failure_reason": result.get("failure_reason", ""), "requested_main_deg": result.get("requested_main_trim_magnitude_deg", null),
			"requested_jib_deg": result.get("requested_headsail_trim_magnitude_deg", null), "actual_twa_deg": result.get("measured_twa_deg", null),
			"mean_sog_kn": result.get("mean_sog_kn", null), "mean_vlong_mps": result.get("mean_longitudinal_velocity_mps", null),
			"mean_leeway_deg": result.get("mean_leeway_deg", null), "mean_heel_deg": result.get("mean_heel_deg", null),
			"mean_rudder_deg": result.get("mean_rudder_deg", null), "rudder_saturation_fraction": result.get("rudder_saturation_fraction", null),
			"actual_main_deg": result.get("main_sail_deg", null), "actual_jib_deg": result.get("headsail_deg", null),
			"mean_main_forward_force_n": result.get("mean_main_forward_force_n", null), "mean_jib_forward_force_n": result.get("mean_headsail_forward_force_n", null),
			"mean_main_local_y_torque_nm": ext.get("mean_main_net_torque_local_nm_y", null),
			"mean_jib_local_y_torque_nm": ext.get("mean_jib_net_torque_local_nm_y", null),
			"mean_keel_local_y_torque_nm": ext.get("mean_keel_net_torque_local_nm_y", null),
			"mean_rudder_local_y_torque_nm": ext.get("mean_rudder_net_torque_local_nm_y", null),
			"mean_buoyancy_local_y_torque_nm": ext.get("mean_buoyancy_yaw_torque_nm", null),
			"mean_known_local_y_torque_sum_nm": ext.get("mean_measured_yaw_torque_sum_nm", null),
			"mean_rudder_water_speed_mps": ext.get("mean_rudder_water_speed_mps", null), "mean_rudder_aoa_deg": ext.get("mean_rudder_aoa_deg", null),
		})
	return output


func _status_counts(results: Array) -> Dictionary:
	var counts := {}
	for result in results:
		var status := str(result.get("status", "UNKNOWN"))
		counts[status] = int(counts.get(status, 0)) + 1
	return counts


func _copy_artifacts(checkpoint: Dictionary, destination: String) -> bool:
	var absolute_dir := ProjectSettings.globalize_path(destination)
	if DirAccess.make_dir_recursive_absolute(absolute_dir) != OK:
		_error = "Could not create P2.6 output directory %s" % absolute_dir
		return false
	var source_dir := str(checkpoint.get("run_directory", ""))
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		var source := source_dir.path_join(filename)
		if not FileAccess.file_exists(source):
			_error = "Missing Polar artifact %s" % source
			return false
		if not _write_text(absolute_dir.path_join(filename), FileAccess.get_file_as_string(source)):
			return false
	return true


func _csv_value(value: Variant) -> String:
	if value == null:
		return ""
	var text := str(value)
	if typeof(value) in [TYPE_FLOAT, TYPE_INT] and not is_finite(float(value)):
		return ""
	if typeof(value) == TYPE_FLOAT:
		text = "%.8f" % float(value)
	if text.contains(",") or text.contains("\"") or text.contains("\n"):
		text = "\"" + text.replace("\"", "\"\"") + "\""
	return text


func _write_json(path: String, value: Variant) -> bool:
	return _write_text(path, JSON.stringify(value, "\t") + "\n")


func _write_text(path: String, value: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_error = "Could not write %s" % path
		return false
	file.store_string(value)
	return true


func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "UNAVAILABLE"
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()


func _finish(exit_code: int, message: String = "") -> void:
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	if not message.is_empty():
		push_error("[polar p2.6] " + message)
		quit(exit_code)
		return
	if not _error.is_empty():
		push_error("[polar p2.6] " + _error)
		quit(1)
		return
	quit(exit_code)
