extends SceneTree
## Two isolated P2.10 keel-center position runs on the P2.3c rigid body.
## Uses the existing Polar Runner and telemetry; only keel_center_local_m.z
## differs from the P2.3c profile in each saved experiment copy.

const LAB_SCENE := preload("res://scenes/SailboatLabP23c.tscn")
const BOAT_SCENE := "res://scenes/boats/SailingBoat8mP23c.tscn"
const BASE_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_physics_profile.tres"
const VISUAL_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_visual_rig_profile.tres"
const POLAR_PROFILE_PATH := "res://resources/sailing/polar_test_profile.tres"
const P25_BASELINE_PATH := "res://docs/sailing/polar_p25/polar_2026-10-28_19-27-37_907713/polar_results.json"
const OUTPUT_ROOT := "res://docs/sailing/polar_p210"
const ENGINE_PHYSICS_HZ := 480
const TIME_SCALE := 8.0
const CASE_TIMEOUT_S := 180.0
const KNOTS_PER_MPS := 1.9438444924406
const BASE_KEEL_CENTER := Vector3(0.0, -1.05, 0.15)
const VARIANTS := [
	{"id": "F30", "z_m": -0.15, "label": "keel_center_forward_0p30m"},
	{"id": "A30", "z_m": 0.45, "label": "keel_center_aft_0p30m"},
]
const CSV_FIELDS := [
	"variant", "keel_center_x_m", "keel_center_y_m", "keel_center_z_m", "profile_path", "profile_sha256",
	"run_id", "config_hash", "status", "failure_reason", "target_tws_kn", "target_twa_deg", "measured_twa_deg",
	"twa_error_deg", "mean_sog_kn", "mean_upwind_vmg_kn", "runner_target_course_vmg_kn",
	"mean_longitudinal_velocity_mps", "mean_lateral_velocity_mps", "mean_leeway_deg", "mean_heel_deg",
	"mean_rudder_deg", "rudder_saturation_fraction", "keel_area_m2", "keel_water_speed_mps",
	"keel_flow_x_mps", "keel_flow_y_mps", "keel_flow_z_mps", "keel_aoa_deg", "keel_cl", "keel_cd",
	"keel_lateral_force_starboard_n", "keel_forward_force_n", "keel_yaw_torque_nm", "rudder_yaw_torque_nm",
	"main_yaw_torque_nm", "jib_yaw_torque_nm", "buoyancy_yaw_torque_nm", "measured_yaw_torque_sum_nm",
	"elapsed_simulation_seconds", "sample_count"
]

var _lab: Node3D
var _boat: RigidBody3D
var _runner: PolarTestRunner
var _old_physics_hz := 60
var _old_time_scale := 1.0
var _run_root := ""
var _run_id := ""
var _rows: Array[Dictionary] = []
var _run_manifest: Array[Dictionary] = []
var _error := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	var base_profile := load(BASE_PROFILE_PATH) as Resource
	var visual_profile := load(VISUAL_PROFILE_PATH) as Resource
	if base_profile == null or visual_profile == null:
		_finish(2, "P2.3c physics or visual Profile failed to load")
		return
	var validation := _validate_setup(base_profile)
	if not bool(validation.get("valid", false)):
		_finish(2, str(validation.get("reason", "P2.10 Profile validation failed")))
		return
	if OS.get_cmdline_user_args().has("--validate-only"):
		print("P2.10 config validation · %s" % str(validation))
		_finish(0)
		return

	_run_id = "p210_%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec() % 1000000]
	_run_root = OUTPUT_ROOT.path_join(_run_id)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_run_root)):
		_finish(2, "Refusing to overwrite existing P2.10 run directory: %s" % _run_root)
		return
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_run_root)) != OK:
		_finish(2, "Could not create P2.10 output directory")
		return
	Engine.physics_ticks_per_second = ENGINE_PHYSICS_HZ
	Engine.time_scale = TIME_SCALE
	print("P2.10 · run=%s · dt=%.9f s · engine=%d Hz × %.1f · cases=2 · timeout=%.0f sim s" % [
		_run_id, 1.0 / 60.0, ENGINE_PHYSICS_HZ, TIME_SCALE, CASE_TIMEOUT_S,
	])

	for variant_value in VARIANTS:
		var variant: Dictionary = variant_value
		var row := await _run_variant(base_profile, variant)
		if row.is_empty():
			break
		_rows.append(row)
		if not bool(row.get("telemetry_valid", false)) or str(row.get("status", "")) == "INVALID":
			_error = "%s contained INVALID or non-finite telemetry; stopped before the next case" % str(variant["id"])
			break

	var baseline := _load_p25_baseline()
	if baseline.is_empty():
		_error = "Could not load the protected P2.5 BASE result"
	else:
		_rows.push_front(baseline)
	_write_outputs(validation, base_profile, visual_profile)
	_finish(1 if not _error.is_empty() else 0)


func _validate_setup(base_profile: Resource) -> Dictionary:
	var base_center: Vector3 = base_profile.get("keel_center_local_m")
	if base_center.distance_to(BASE_KEEL_CENTER) > 0.00001:
		return {"valid": false, "reason": "P2.3c keel center differs from expected BASE center: %s" % str(base_center)}
	for variant_value in VARIANTS:
		var variant: Dictionary = variant_value
		var copy := base_profile.duplicate(true) as Resource
		copy.set("keel_center_local_m", Vector3(base_center.x, base_center.y, float(variant["z_m"])))
		if not _same_profile_except(base_profile, copy, "keel_center_local_m"):
			return {"valid": false, "reason": "%s changes profile fields beyond keel_center_local_m" % str(variant["id"])}
	return {
		"valid": true,
		"boat_scene_path": BOAT_SCENE,
		"base_profile_path": BASE_PROFILE_PATH,
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"base_keel_center_local_m": base_center,
		"base_keel_area_m2": base_profile.get("keel_area_m2"),
		"base_keel_max_lift_coefficient": base_profile.get("keel_max_lift_coefficient"),
		"variants": VARIANTS.duplicate(true),
		"single_variable_profile_check": "pass",
	}


func _same_profile_except(base: Resource, candidate: Resource, changed_property: String) -> bool:
	for property_value in base.get_property_list():
		var property: Dictionary = property_value
		if (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var property_name := str(property.get("name", ""))
		if property_name == changed_property or property_name in ["resource_path", "resource_name"]:
			continue
		if var_to_str(base.get(property_name)) != var_to_str(candidate.get(property_name)):
			return false
	return true


func _run_variant(base_profile: Resource, variant: Dictionary) -> Dictionary:
	var profile_copy := base_profile.duplicate(true) as Resource
	var base_center: Vector3 = base_profile.get("keel_center_local_m")
	var new_center := Vector3(base_center.x, base_center.y, float(variant["z_m"]))
	profile_copy.set("keel_center_local_m", new_center)
	if not _same_profile_except(base_profile, profile_copy, "keel_center_local_m"):
		_error = "%s independent Profile failed single-variable verification" % str(variant["id"])
		return {}
	var profile_directory := _run_root.path_join("profiles")
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(profile_directory)) != OK:
		_error = "Could not create independent Profile directory"
		return {}
	var profile_path := profile_directory.path_join("%s_physics_profile.tres" % str(variant["id"]).to_lower())
	if FileAccess.file_exists(profile_path) or ResourceSaver.save(profile_copy, profile_path) != OK:
		_error = "Could not save independent Profile for %s" % str(variant["id"])
		return {}
	var test_profile_resource := load(profile_path) as Resource
	if test_profile_resource == null or not _same_profile_except(base_profile, test_profile_resource, "keel_center_local_m"):
		_error = "%s saved Profile did not round-trip with only keel center changed" % str(variant["id"])
		return {}

	_lab = LAB_SCENE.instantiate() as Node3D
	_boat = _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	if _boat == null or _runner == null or _boat.scene_file_path != BOAT_SCENE:
		_error = "Unexpected P2.3c lab/body scene structure"
		return {}
	_boat.set("profile", test_profile_resource)
	_boat.set("p22_extended_telemetry_enabled", true)
	var polar_profile := (load(POLAR_PROFILE_PATH) as Resource).duplicate(true)
	polar_profile.set("boat_scene_paths", PackedStringArray([BOAT_SCENE]))
	polar_profile.set("case_timeout_seconds", CASE_TIMEOUT_S)
	_runner.profile = polar_profile
	root.add_child(_lab)
	await process_frame
	var debug: Dictionary = _boat.call("get_debug_snapshot")
	var runtime_center: Vector3 = debug.get("keel_center_local_m", Vector3(NAN, NAN, NAN))
	if runtime_center.distance_to(new_center) > 0.0001:
		_error = "%s keel center was not applied at runtime: %s" % [str(variant["id"]), str(runtime_center)]
		_lab.queue_free()
		await process_frame
		return {}

	var case_id := "p210_%s_12kn_twa_m50" % str(variant["id"]).to_lower()
	var case := {
		"case_id": case_id,
		"target_tws_kn": 12.0,
		"target_twa_deg": -50.0,
		"tack": "PORT",
		"experiment_group": "P210_NORDIC28_KEEL_POSITION",
		"experiment_variable": "keel_center_local_m.z",
		"experiment_label": "%s · keel center Z %.2f m" % [str(variant["id"]), float(variant["z_m"])],
		"auto_sail_trim_enabled": true,
	}
	if not _runner.start_new_batch({"include_extended_telemetry": true, "explicit_cases": [case]}):
		_error = "%s Polar batch did not start" % str(variant["id"])
		_lab.queue_free()
		await process_frame
		return {}
	var run_id := str(_runner.get_status_snapshot().get("test_run_id", ""))
	print("P2.10 started · %s · run=%s · keel center=%s" % [str(variant["id"]), run_id, str(new_center)])
	await _wait_for_batch(str(variant["id"]))
	var state: Dictionary = _runner.get_status_snapshot()
	var checkpoint_path := str(state.get("output_path", ""))
	if checkpoint_path.is_empty() or not FileAccess.file_exists(checkpoint_path):
		_error = "%s run completed without checkpoint" % str(variant["id"])
		_lab.queue_free()
		await process_frame
		return {}
	var checkpoint_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
	if not checkpoint_value is Dictionary:
		_error = "%s checkpoint could not be parsed" % str(variant["id"])
		_lab.queue_free()
		await process_frame
		return {}
	var checkpoint: Dictionary = checkpoint_value
	var raw_results: Array = checkpoint.get("results", [])
	if raw_results.size() != 1:
		_error = "%s returned %d rows; expected one" % [str(variant["id"]), raw_results.size()]
		_lab.queue_free()
		await process_frame
		return {}
	var raw_result: Dictionary = raw_results[0]
	var artifact_dir := _run_root.path_join("runner_runs").path_join(str(variant["id"]).to_lower())
	if not _copy_runner_artifacts(checkpoint, artifact_dir):
		_lab.queue_free()
		await process_frame
		return {}
	var profile_hash := _sha256_file(profile_path)
	var row := _make_row(str(variant["id"]), new_center, profile_path, profile_hash, checkpoint, raw_result)
	row["runtime_keel_center_local_m"] = runtime_center
	row["telemetry_valid"] = bool(raw_result.get("extended_telemetry", {}).get("telemetry_finite", false))
	row["runner_artifact_directory"] = artifact_dir
	_run_manifest.append({
		"variant": variant,
		"run_id": checkpoint.get("test_run_id", run_id),
		"config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"profile_path": profile_path,
		"profile_sha256": profile_hash,
		"runtime_keel_center_local_m": runtime_center,
		"result_status": raw_result.get("status", "UNKNOWN"),
		"runner_artifact_directory": artifact_dir,
	})
	print("P2.10 complete · %s · %s · TWA %+.3f° · SOG %.3f kn · leeway %+.3f° · rudder %.2f°/%.1f%%" % [
		str(variant["id"]), str(raw_result.get("status", "UNKNOWN")), float(raw_result.get("measured_twa_deg", NAN)),
		float(raw_result.get("mean_sog_kn", NAN)), float(raw_result.get("mean_leeway_deg", NAN)),
		float(raw_result.get("mean_rudder_deg", NAN)), float(raw_result.get("rudder_saturation_fraction", NAN)) * 100.0,
	])
	_lab.queue_free()
	await process_frame
	_lab = null
	_boat = null
	_runner = null
	return row


func _make_row(variant: String, center: Vector3, profile_path: String, profile_hash: String, checkpoint: Dictionary, result: Dictionary) -> Dictionary:
	var telemetry: Dictionary = result.get("extended_telemetry", {})
	var wind_from := float(result.get("wind_from_deg", 180.0))
	var mean_velocity := Vector3(float(result.get("mean_velocity_world_x_mps", NAN)), 0.0, float(result.get("mean_velocity_world_z_mps", NAN)))
	var upwind_direction := Vector3(sin(deg_to_rad(wind_from)), 0.0, -cos(deg_to_rad(wind_from)))
	var upwind_vmg := mean_velocity.dot(upwind_direction) * KNOTS_PER_MPS if mean_velocity.is_finite() else NAN
	return {
		"variant": variant,
		"keel_center_local_m": center,
		"keel_center_x_m": center.x,
		"keel_center_y_m": center.y,
		"keel_center_z_m": center.z,
		"profile_path": profile_path,
		"profile_sha256": profile_hash,
		"run_id": checkpoint.get("test_run_id", result.get("test_run_id", "")),
		"config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"status": result.get("status", "UNKNOWN"),
		"failure_reason": result.get("failure_reason", ""),
		"target_tws_kn": result.get("target_tws_kn", 12.0),
		"target_twa_deg": result.get("target_twa_deg", -50.0),
		"measured_twa_deg": result.get("measured_twa_deg", null),
		"twa_error_deg": float(result.get("measured_twa_deg", NAN)) - float(result.get("target_twa_deg", -50.0)),
		"mean_sog_kn": result.get("mean_sog_kn", null),
		"mean_upwind_vmg_kn": upwind_vmg,
		"runner_target_course_vmg_kn": result.get("mean_vmg_kn", null),
		"mean_longitudinal_velocity_mps": result.get("mean_longitudinal_velocity_mps", null),
		"mean_lateral_velocity_mps": _t(telemetry, "mean_body_lateral_speed_mps"),
		"mean_leeway_deg": result.get("mean_leeway_deg", null),
		"mean_heel_deg": result.get("mean_heel_deg", null),
		"mean_rudder_deg": result.get("mean_rudder_deg", null),
		"rudder_saturation_fraction": result.get("rudder_saturation_fraction", null),
		"keel_area_m2": _t(telemetry, "mean_keel_area_m2"),
		"keel_application_z_m": _t(telemetry, "mean_keel_application_local_m_z"),
		"keel_water_speed_mps": _t(telemetry, "mean_keel_water_speed_mps"),
		"keel_flow_x_mps": _t(telemetry, "mean_keel_local_flow_x_mps"),
		"keel_flow_y_mps": _t(telemetry, "mean_keel_local_flow_y_mps"),
		"keel_flow_z_mps": _t(telemetry, "mean_keel_local_flow_z_mps"),
		"keel_aoa_deg": _t(telemetry, "mean_keel_aoa_deg"),
		"keel_cl": _t(telemetry, "mean_keel_cl"),
		"keel_cd": _t(telemetry, "mean_keel_cd"),
		"keel_lateral_force_starboard_n": _t(telemetry, "mean_keel_net_lateral_force_starboard_n"),
		"keel_forward_force_n": _t(telemetry, "mean_keel_net_forward_force_n"),
		"keel_yaw_torque_nm": _t(telemetry, "mean_keel_net_torque_local_nm_y"),
		"rudder_yaw_torque_nm": _t(telemetry, "mean_rudder_net_torque_local_nm_y"),
		"main_yaw_torque_nm": _t(telemetry, "mean_main_net_torque_local_nm_y"),
		"jib_yaw_torque_nm": _t(telemetry, "mean_jib_net_torque_local_nm_y"),
		"buoyancy_yaw_torque_nm": _t(telemetry, "mean_buoyancy_yaw_torque_nm"),
		"measured_yaw_torque_sum_nm": _t(telemetry, "mean_measured_yaw_torque_sum_nm"),
		"elapsed_simulation_seconds": result.get("elapsed_simulation_seconds", null),
		"sample_count": result.get("sample_count", 0),
		"telemetry_valid": bool(telemetry.get("telemetry_finite", false)),
		"extended_telemetry": telemetry,
		"raw_result": result,
	}


func _load_p25_baseline() -> Dictionary:
	if not FileAccess.file_exists(P25_BASELINE_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(P25_BASELINE_PATH))
	if not parsed is Dictionary:
		return {}
	var document: Dictionary = parsed
	for result_value in document.get("results", []):
		var result: Dictionary = result_value
		if str(result.get("case_id", "")) == "p25_12kn_050twa_port":
			var compact_result := result.duplicate(true)
			compact_result.erase("yaw_timeseries_samples")
			return _make_baseline_row(compact_result, document)
	return {}


func _make_baseline_row(result: Dictionary, document: Dictionary) -> Dictionary:
	var row := _make_row("BASE", BASE_KEEL_CENTER, BASE_PROFILE_PATH, _sha256_file(BASE_PROFILE_PATH), {
		"test_run_id": result.get("test_run_id", ""),
		"config_hash": result.get("boat_config_hash", ""),
		"boat_config_hash": result.get("boat_config_hash", ""),
	}, result)
	row["profile_metadata_source"] = "P2.5 BASE, existing immutable run"
	row["p25_metadata"] = document.get("metadata", {})
	return row


func _t(values: Dictionary, key: String) -> Variant:
	return values.get(key, null)


func _copy_runner_artifacts(checkpoint: Dictionary, destination: String) -> bool:
	var absolute_directory := ProjectSettings.globalize_path(destination)
	if DirAccess.dir_exists_absolute(absolute_directory):
		_error = "Refusing to overwrite runner artifact directory: %s" % destination
		return false
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		_error = "Could not create runner artifact directory: %s" % destination
		return false
	var source_directory := str(checkpoint.get("run_directory", ""))
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		var source := source_directory.path_join(filename)
		if not FileAccess.file_exists(source):
			_error = "Missing Polar Runner artifact: %s" % source
			return false
		var file := FileAccess.open(destination.path_join(filename), FileAccess.WRITE)
		if file == null:
			_error = "Could not copy Polar artifact %s" % filename
			return false
		file.store_string(FileAccess.get_file_as_string(source))
	return true


func _write_outputs(validation: Dictionary, base_profile: Resource, visual_profile: Resource) -> void:
	var csv_lines := PackedStringArray([",".join(PackedStringArray(CSV_FIELDS))])
	for row in _rows:
		var cells := PackedStringArray()
		for field in CSV_FIELDS:
			cells.append(_csv_value(row.get(field, null)))
		csv_lines.append(",".join(cells))
	_write_text(_run_root.path_join("keel_position.csv"), "\n".join(csv_lines) + "\n")
	var result_rows: Array[Dictionary] = []
	for row in _rows:
		result_rows.append({"variant": row.get("variant", ""), "result": row})
	_write_json(_run_root.path_join("keel_position.json"), {
		"experiment": "Nordic 28 P2.10 keel hydrodynamic center longitudinal position sensitivity",
		"experiment_run_id": _run_id,
		"base_reference": {"source": P25_BASELINE_PATH, "run_id": "polar_2026-10-28_19-27-37_907713", "case_id": "p25_12kn_050twa_port", "rerun": false},
		"conditions": {"tws_kn": 12.0, "target_twa_deg": -50.0, "tack": "PORT", "engine": "OFF", "wave_mode": "zero_amplitude", "water_current_mps": [0.0, 0.0, 0.0]},
		"execution": {"physics_step_seconds": 1.0 / 60.0, "engine_physics_ticks_per_second": ENGINE_PHYSICS_HZ, "time_scale": TIME_SCALE, "effective_simulated_steps_per_second": 60.0, "case_timeout_sim_seconds": CASE_TIMEOUT_S},
		"profile_baseline": {"path": BASE_PROFILE_PATH, "sha256": _sha256_file(BASE_PROFILE_PATH), "keel_center_local_m": BASE_KEEL_CENTER, "keel_area_m2": base_profile.get("keel_area_m2"), "keel_max_lift_coefficient": base_profile.get("keel_max_lift_coefficient")},
		"variant_runs": _run_manifest,
		"results": result_rows,
		"interpretation_notes": ["mean_upwind_vmg_kn is actual mean horizontal world velocity projected toward the true wind-from bearing; positive means progress upwind.", "runner_target_course_vmg_kn is reported separately because it projects on the commanded heading.", "The moved point is only the hydrodynamic force application center in an isolated profile; the visible keel is not moved."],
	})
	_write_json(_run_root.path_join("p210_manifest.json"), {
		"experiment_run_id": _run_id,
		"phase": "Nordic 28 P2.10 keel position sensitivity",
		"timestamp": Time.get_datetime_string_from_system(true),
		"boat_scene_path": BOAT_SCENE,
		"base_physics_profile_path": BASE_PROFILE_PATH,
		"base_physics_profile_sha256": _sha256_file(BASE_PROFILE_PATH),
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"visual_profile_sha256": _sha256_file(VISUAL_PROFILE_PATH),
		"runner_sha256": _sha256_file("res://scripts/polar_test_runner.gd"),
		"test_script_sha256": _sha256_file("res://tests/run_polar_p210_keel_position.gd"),
		"profile_validation": validation,
		"runs": _run_manifest,
		"base_run_id": "polar_2026-10-28_19-27-37_907713",
		"base_configuration_hash": "fff7841f8afdb2ee2a742b05e606c51d9b530c052f815f59931bd47b7e7da18f",
		"error": _error,
	})


func _csv_value(value: Variant) -> String:
	if value == null:
		return ""
	if (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and not is_finite(float(value)):
		return ""
	var text := "%.8f" % float(value) if typeof(value) == TYPE_FLOAT else str(value)
	if text.contains(",") or text.contains("\"") or text.contains("\n"):
		text = "\"" + text.replace("\"", "\"\"") + "\""
	return text


func _write_text(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_error = "Could not write %s" % path
		return
	file.store_string(content)


func _write_json(path: String, value: Variant) -> void:
	_write_text(path, JSON.stringify(value, "\t") + "\n")


func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "UNAVAILABLE"
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()


func _wait_for_batch(variant: String) -> void:
	var last_log_usec := 0
	while bool(_runner.get_status_snapshot().get("running", false)):
		await process_frame
		var now := Time.get_ticks_usec()
		if now - last_log_usec >= 10000000:
			last_log_usec = now
			var snapshot: Dictionary = _runner.get_status_snapshot()
			print("P2.10 progress · %s · sim %.0f s · SOG %.2f kn · TWA %+.1f° · rudder %+.1f°" % [
				variant, float(snapshot.get("simulation_seconds", 0.0)), float(snapshot.get("sog_kn", 0.0)),
				float(snapshot.get("measured_twa_deg", 0.0)), float(snapshot.get("rudder_deg", 0.0)),
			])


func _finish(exit_code: int, message: String = "") -> void:
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	if not message.is_empty():
		push_error("[polar p2.10] " + message)
		quit(exit_code)
		return
	if not _error.is_empty():
		push_error("[polar p2.10] " + _error)
		quit(exit_code)
		return
	quit(exit_code)
