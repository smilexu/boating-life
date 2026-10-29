extends SceneTree
## Two-case P2.5 yaw-dynamics capture on the isolated P2.3c experiment rig.
## The test uses the real rigid body, production rudder interface and existing
## P2.4 PD heading controller; time-series capture is observational only.

const LAB_SCENE := preload("res://scenes/SailboatLabP23c.tscn")
const BOAT_SCENE := "res://scenes/boats/SailingBoat8mP23c.tscn"
const PHYSICS_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_physics_profile.tres"
const VISUAL_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_visual_rig_profile.tres"
const POLAR_PROFILE := preload("res://resources/sailing/polar_test_profile.tres")
const OUTPUT_ROOT := "res://docs/sailing/polar_p25"
const ENGINE_PHYSICS_HZ := 480
const ACCELERATION_SCALE := 8.0
const CASE_TIMEOUT_S := 180.0
const CSV_FIELDS := [
	"case_id", "status", "sim_time_s", "target_heading_deg", "heading_deg", "heading_error_deg",
	"target_twa_deg", "measured_twa_deg", "twa_error_deg", "local_yaw_rate_rad_s", "local_yaw_rate_deg_s",
	"local_yaw_accel_rad_s2", "compass_yaw_rate_deg_s", "sog_mps", "vlong_mps", "vlat_mps", "leeway_deg",
	"controller_error_deg", "controller_compass_yaw_rate_deg_s", "pid_output_unclamped_deg", "pid_command_deg",
	"target_rudder_deg", "actual_rudder_deg", "rudder_saturation_flag", "rudder_water_speed_mps", "rudder_aoa_deg",
	"main_sail_yaw_torque_nm", "jib_yaw_torque_nm", "keel_yaw_torque_nm", "rudder_yaw_torque_nm",
	"explicit_damping_yaw_torque_nm", "buoyancy_yaw_torque_nm", "known_yaw_torque_sum_nm",
	"external_yaw_torque_cache_nm", "angular_damp", "angular_damp_mode"
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
	Engine.time_scale = ACCELERATION_SCALE
	_lab = LAB_SCENE.instantiate() as Node3D
	_boat = _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	if _boat == null or _runner == null:
		_finish(2, "P2.3c lab scene is missing SailboatBody or PolarTestRunner")
		return
	var test_profile := (POLAR_PROFILE as Resource).duplicate(true)
	test_profile.set("boat_scene_paths", PackedStringArray([BOAT_SCENE]))
	test_profile.set("case_timeout_seconds", CASE_TIMEOUT_S)
	_runner.profile = test_profile
	_boat.set("p22_extended_telemetry_enabled", true)
	root.add_child(_lab)
	await process_frame
	var validation := _validate_rig()
	if not bool(validation.get("valid", false)):
		_finish(2, str(validation.get("reason", "P2.3c validation failed")))
		return
	if OS.get_cmdline_user_args().has("--validate-only"):
		print("P2.5 rig validation · %s" % str(validation))
		_finish(0)
		return
	var cases := _build_cases()
	var started := _runner.start_new_batch({
		"include_extended_telemetry": true,
		"capture_yaw_timeseries": true,
		"explicit_cases": cases,
	})
	if not started:
		_finish(2, "P2.5 batch failed to start")
		return
	var initial := _runner.get_status_snapshot()
	print("P2.5 started · run=%s · config=%s · dt=%.9f s · engine=%d Hz × %.1f · cases=%d" % [
		str(initial.get("test_run_id", "pending")), str(initial.get("output_path", "pending")),
		1.0 / 60.0, ENGINE_PHYSICS_HZ, ACCELERATION_SCALE, cases.size(),
	])
	await _wait_for_batch()
	var state := _runner.get_status_snapshot()
	var checkpoint_path := str(state.get("output_path", ""))
	if checkpoint_path.is_empty() or not FileAccess.file_exists(checkpoint_path):
		_finish(1, "P2.5 completed without a readable checkpoint")
		return
	var checkpoint_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
	if not checkpoint_value is Dictionary:
		_finish(1, "P2.5 checkpoint JSON could not be parsed")
		return
	var checkpoint: Dictionary = checkpoint_value
	var run_id := str(checkpoint.get("test_run_id", "p25_unknown"))
	var destination := OUTPUT_ROOT.path_join(run_id)
	if FileAccess.file_exists(destination.path_join("polar_results.json")):
		_finish(1, "Refusing to overwrite existing P2.5 artifacts: %s" % destination)
		return
	if not _copy_run_artifacts(checkpoint, destination):
		_finish(1, _error)
		return
	var results: Array = checkpoint.get("results", [])
	if results.size() != cases.size():
		_finish(1, "P2.5 returned %d results for %d cases" % [results.size(), cases.size()])
		return
	if not _write_timeseries_csv(destination.path_join("yaw_timeseries.csv"), results):
		_finish(1, _error)
		return
	var counts := {}
	for result in results:
		var status := str(result.get("status", "UNKNOWN"))
		counts[status] = int(counts.get(status, 0)) + 1
	_write_json(destination.path_join("p25_summary.json"), {
		"experiment": "Nordic 28 P2.5 yaw dynamics and heading control diagnostics",
		"test_run_id": run_id,
		"polar_config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"result_count": results.size(),
		"status_counts": counts,
		"results": _case_summary(results),
	})
	_write_json(destination.path_join("p25_manifest.json"), {
		"phase": "Nordic 28 P2.5 yaw dynamics diagnostics",
		"test_run_id": run_id,
		"polar_config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"boat_scene_path": BOAT_SCENE,
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"physics_profile_sha256": _sha256_file(PHYSICS_PROFILE_PATH),
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"visual_profile_sha256": _sha256_file(VISUAL_PROFILE_PATH),
		"boat_scene_sha256": _sha256_file(BOAT_SCENE),
		"runner_sha256": _sha256_file("res://scripts/polar_test_runner.gd"),
		"test_script_sha256": _sha256_file("res://tests/run_polar_p25_yaw_diagnostics.gd"),
		"conditions": [{"tws_kn": 12.0, "target_twa_deg": -50.0, "tack": "PORT"}, {"tws_kn": 12.0, "target_twa_deg": -90.0, "tack": "PORT"}],
		"engine_state_expected": "OFF",
		"auto_trim": true,
		"wave_mode": "WaveSampler enabled, amplitude zero; current zero",
		"physics_step_seconds": 1.0 / 60.0,
		"execution_acceleration": {"engine_physics_ticks_per_second": ENGINE_PHYSICS_HZ, "time_scale": ACCELERATION_SCALE, "effective_simulated_steps_per_second": 60.0},
		"time_series_interval_seconds": "approximately 1.0 simulated second; existing runner sample cadence",
		"yaw_acceleration_method": "offline central difference of neighboring 1 Hz local yaw-rate samples; one-sided at endpoints",
		"angular_damping": validation.get("angular_damping", {}),
		"p24_reference_run_id": "polar_2026-10-28_19-06-59_469219",
		"stability_parameters": checkpoint.get("run_metadata", {}).get("config", {}),
	})
	print("P2.5 complete · %d/%d · run=%s · statuses=%s · artifacts=%s" % [
		int(state.get("completed_count", 0)), int(state.get("case_count", 0)), run_id, str(counts), destination,
	])
	_finish(0)


func _validate_rig() -> Dictionary:
	if _boat.scene_file_path != BOAT_SCENE:
		return {"valid": false, "reason": "Unexpected boat scene: %s" % _boat.scene_file_path}
	var physics: Resource = _boat.get("profile") as Resource
	var anchors := _boat.get_node_or_null("VisualRoot/VisualRigAnchors") as Node3D
	var visual: Resource = anchors.get("visual_profile") as Resource if anchors != null else null
	if physics == null or visual == null or physics.resource_path != PHYSICS_PROFILE_PATH or visual.resource_path != VISUAL_PROFILE_PATH:
		return {"valid": false, "reason": "P2.3c independent physics/visual profiles are not bound"}
	var default_angular_damp: Variant = ProjectSettings.get_setting("physics/3d/default_angular_damp", null)
	var mode_value := int(_boat.get("angular_damp_mode"))
	var mode_name := "COMBINE" if mode_value == 0 else ("REPLACE" if mode_value == 1 else "UNKNOWN")
	return {
		"valid": true,
		"boat_scene_path": _boat.scene_file_path,
		"physics_profile_path": physics.resource_path,
		"visual_profile_path": visual.resource_path,
		"angular_damping": {
			"runtime_body_angular_damp": float(_boat.get("angular_damp")),
			"runtime_angular_damp_mode_value": mode_value,
			"runtime_angular_damp_mode_name": mode_name,
			"project_default_angular_damp_setting": default_angular_damp,
			"profile_angular_damping": float(physics.get("angular_damping")),
		},
		"mass_kg": float(physics.get("mass_kg")),
		"center_of_mass_local_m": physics.get("center_of_mass_m"),
	}


func _build_cases() -> Array[Dictionary]:
	return [
		{"case_id": "p25_12kn_050twa_port", "target_tws_kn": 12.0, "target_twa_deg": -50.0, "tack": "PORT", "experiment_group": "P25_NORDIC28_YAW_DIAGNOSTICS", "experiment_variable": "target_twa", "experiment_label": "P2.5 · 12 kn / 50° / PORT", "auto_sail_trim_enabled": true},
		{"case_id": "p25_12kn_090twa_port", "target_tws_kn": 12.0, "target_twa_deg": -90.0, "tack": "PORT", "experiment_group": "P25_NORDIC28_YAW_DIAGNOSTICS", "experiment_variable": "target_twa", "experiment_label": "P2.5 · 12 kn / 90° / PORT", "auto_sail_trim_enabled": true},
	]


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
			print("P2.5 progress · %d/%d · %s · sim %.0f s · %.2f kn · TWA %+.1f°" % [
				int(snapshot.get("completed_count", 0)), int(snapshot.get("case_count", 0)), case_id,
				float(snapshot.get("simulation_seconds", 0.0)), float(snapshot.get("sog_kn", 0.0)), float(snapshot.get("measured_twa_deg", 0.0)),
			])


func _write_timeseries_csv(path: String, results: Array) -> bool:
	var lines := PackedStringArray([",".join(PackedStringArray(CSV_FIELDS))])
	for result in results:
		var case_id := str(result.get("case_id", ""))
		var status := str(result.get("status", "UNKNOWN"))
		var samples: Array = result.get("yaw_timeseries_samples", [])
		var accelerations := _yaw_accelerations(samples)
		for index in range(samples.size()):
			var sample: Dictionary = samples[index]
			var local_rate := float(sample.get("local_yaw_rate_rad_s", NAN))
			var values: Array = [
				case_id, status, sample.get("sim_time_s", null), sample.get("target_heading_deg", null), sample.get("heading_deg", null), sample.get("heading_error_deg", null),
				result.get("target_twa_deg", null), sample.get("measured_twa_deg", null), sample.get("twa_error_deg", null), local_rate,
				rad_to_deg(local_rate), accelerations[index], sample.get("yaw_rate_deg_s", null), sample.get("sog_mps", null), sample.get("vlong_mps", null), sample.get("vlat_mps", null), sample.get("leeway_deg", null),
				sample.get("controller_error_deg", null), sample.get("controller_compass_yaw_rate_deg_s", null), sample.get("pid_output_unclamped_deg", null), sample.get("pid_command_deg", null),
				sample.get("target_rudder_deg", null), sample.get("rudder_deg", null), sample.get("p22_rudder_saturation_flag", null), sample.get("p22_rudder_water_speed_mps", null), sample.get("p22_rudder_aoa_deg", null),
				sample.get("p22_main_net_torque_local_nm_y", null), sample.get("p22_jib_net_torque_local_nm_y", null), sample.get("p22_keel_net_torque_local_nm_y", null), sample.get("p22_rudder_net_torque_local_nm_y", null),
				sample.get("p22_axis_damping_yaw_torque_nm", null), sample.get("p22_buoyancy_yaw_torque_nm", null), sample.get("p22_measured_yaw_torque_sum_nm", null),
				sample.get("p22_total_external_yaw_torque_nm", null), sample.get("angular_damp", null), sample.get("angular_damp_mode", null),
			]
			var row := PackedStringArray()
			for value in values:
				row.append(_csv_value(value))
			lines.append(",".join(row))
	var absolute_path := ProjectSettings.globalize_path(path)
	if DirAccess.make_dir_recursive_absolute(absolute_path.get_base_dir()) != OK:
		_error = "Could not create time-series directory"
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_error = "Could not write yaw time-series CSV: %s" % path
		return false
	file.store_string("\n".join(lines) + "\n")
	return true


func _yaw_accelerations(samples: Array) -> Array[float]:
	var output: Array[float] = []
	for index in range(samples.size()):
		var left_index := maxi(0, index - 1)
		var right_index := mini(samples.size() - 1, index + 1)
		if left_index == right_index:
			output.append(0.0)
			continue
		var left: Dictionary = samples[left_index]
		var right: Dictionary = samples[right_index]
		var dt := float(right.get("sim_time_s", 0.0)) - float(left.get("sim_time_s", 0.0))
		var delta_rate := float(right.get("local_yaw_rate_rad_s", 0.0)) - float(left.get("local_yaw_rate_rad_s", 0.0))
		output.append(delta_rate / dt if dt > 0.0 else 0.0)
	return output


func _case_summary(results: Array) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	for result in results:
		var samples: Array = result.get("yaw_timeseries_samples", [])
		var local_rates: Array[float] = []
		var headings: Array[float] = []
		var rudders: Array[float] = []
		for sample_value in samples:
			var sample: Dictionary = sample_value
			local_rates.append(float(sample.get("local_yaw_rate_rad_s", NAN)))
			headings.append(float(sample.get("heading_error_deg", NAN)))
			rudders.append(float(sample.get("rudder_deg", NAN)))
		output.append({
			"case_id": result.get("case_id", ""), "status": result.get("status", ""), "failure_reason": result.get("failure_reason", ""),
			"target_twa_deg": result.get("target_twa_deg", null), "measured_twa_deg": result.get("measured_twa_deg", null),
			"mean_sog_kn": result.get("mean_sog_kn", null), "mean_heel_deg": result.get("mean_heel_deg", null),
			"mean_leeway_deg": result.get("mean_leeway_deg", null), "mean_rudder_deg": result.get("mean_rudder_deg", null),
			"rudder_saturation_fraction": result.get("rudder_saturation_fraction", null),
			"mean_local_yaw_rate_rad_s": _mean(local_rates), "max_abs_heading_error_deg": _max_abs(headings),
			"max_abs_actual_rudder_deg": _max_abs(rudders), "sample_count": samples.size(),
			"extended_telemetry": result.get("extended_telemetry", {}),
		})
	return output


func _mean(values: Array[float]) -> Variant:
	if values.is_empty():
		return null
	var total := 0.0
	var count := 0
	for value in values:
		if is_finite(value):
			total += value
			count += 1
	return total / count if count > 0 else null


func _max_abs(values: Array[float]) -> Variant:
	if values.is_empty():
		return null
	var maximum := 0.0
	var found := false
	for value in values:
		if is_finite(value):
			maximum = maxf(maximum, absf(value))
			found = true
	return maximum if found else null


func _copy_run_artifacts(checkpoint: Dictionary, destination: String) -> bool:
	var absolute_directory := ProjectSettings.globalize_path(destination)
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		_error = "Could not create P2.5 output directory %s" % absolute_directory
		return false
	var source_directory := str(checkpoint.get("run_directory", ""))
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		var source := source_directory.path_join(filename)
		if not FileAccess.file_exists(source):
			_error = "Missing Polar artifact %s" % source
			return false
		var file := FileAccess.open(absolute_directory.path_join(filename), FileAccess.WRITE)
		if file == null:
			_error = "Could not copy artifact %s" % filename
			return false
		file.store_string(FileAccess.get_file_as_string(source))
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


func _sha256_file(resource_path: String) -> String:
	var file := FileAccess.open(resource_path, FileAccess.READ)
	if file == null:
		return "UNAVAILABLE"
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()


func _write_json(resource_path: String, value: Variant) -> bool:
	var file := FileAccess.open(resource_path, FileAccess.WRITE)
	if file == null:
		_error = "Could not write JSON: %s" % resource_path
		return false
	file.store_string(JSON.stringify(value, "\t") + "\n")
	return true


func _finish(exit_code: int, message: String = "") -> void:
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	if not message.is_empty():
		push_error("[polar p2.5] " + message)
		quit(exit_code)
		return
	if not _error.is_empty():
		push_error("[polar p2.5] " + _error)
		quit(1)
		return
	quit(exit_code)
