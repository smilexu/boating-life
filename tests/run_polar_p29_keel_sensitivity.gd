extends SceneTree
## Three isolated P2.9 keel sensitivity runs using the P2.3c rigid body.
## Each run uses a private duplicated SailboatLabProfile and the existing
## P2.5 Polar controller/telemetry. No production profile is mutated.

const LAB_SCENE := preload("res://scenes/SailboatLabP23c.tscn")
const BOAT_SCENE := "res://scenes/boats/SailingBoat8mP23c.tscn"
const BASE_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_physics_profile.tres"
const VISUAL_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_visual_rig_profile.tres"
const POLAR_PROFILE_PATH := "res://resources/sailing/polar_test_profile.tres"
const P25_BASELINE_PATH := "res://docs/sailing/polar_p25/polar_2026-10-28_19-27-37_907713/polar_results.json"
const OUTPUT_ROOT := "res://docs/sailing/polar_p29"
const ENGINE_PHYSICS_HZ := 480
const TIME_SCALE := 8.0
const CASE_TIMEOUT_S := 180.0
const KNOTS_PER_MPS := 1.9438444924406
const VARIANTS := [
	{"id": "K1", "property": "keel_area_m2", "value": 2.64, "label": "area_plus_20_percent"},
	{"id": "K2", "property": "keel_area_m2", "value": 3.08, "label": "area_plus_40_percent"},
	{"id": "K3", "property": "keel_max_lift_coefficient", "value": 1.38, "label": "cl_max_plus_20_percent"},
]
const CSV_FIELDS := [
	"variant", "changed_parameter", "changed_value", "profile_path", "profile_sha256", "run_id", "config_hash",
	"status", "failure_reason", "target_tws_kn", "target_twa_deg", "measured_twa_deg", "twa_error_deg",
	"mean_sog_kn", "mean_upwind_vmg_kn", "runner_target_course_vmg_kn", "mean_longitudinal_velocity_mps",
	"mean_lateral_velocity_mps", "mean_leeway_deg", "mean_heel_deg", "mean_rudder_deg", "rudder_saturation_fraction",
	"keel_area_m2", "keel_aoa_deg", "keel_cl", "keel_cd", "keel_lateral_force_starboard_n", "keel_forward_force_n",
	"keel_drag_forward_force_n", "hull_resistance_forward_n", "keel_yaw_torque_nm",
	"rudder_aoa_deg", "rudder_cl", "rudder_cd", "rudder_lateral_force_starboard_n", "rudder_yaw_torque_nm",
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
var _raw_results: Array[Dictionary] = []
var _run_manifests: Array[Dictionary] = []
var _error := ""
var _stop_after_current := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	var base_profile := load(BASE_PROFILE_PATH) as Resource
	var base_visual := load(VISUAL_PROFILE_PATH) as Resource
	if base_profile == null or base_visual == null:
		_finish(2, "P2.3c physics or visual Profile failed to load")
		return
	var validation := _validate_variants(base_profile)
	if not bool(validation.get("valid", false)):
		_finish(2, str(validation.get("reason", "Profile validation failed")))
		return
	if OS.get_cmdline_user_args().has("--validate-only"):
		print("P2.9 config validation · %s" % str(validation))
		_finish(0)
		return

	_run_id = "p29_%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec() % 1000000]
	_run_root = OUTPUT_ROOT.path_join(_run_id)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_run_root)):
		_finish(2, "Refusing to overwrite existing P2.9 run directory: %s" % _run_root)
		return
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_run_root)) != OK:
		_finish(2, "Could not create P2.9 output directory")
		return
	Engine.physics_ticks_per_second = ENGINE_PHYSICS_HZ
	Engine.time_scale = TIME_SCALE
	print("P2.9 · run=%s · dt=%.9f s · engine=%d Hz × %.1f · cases=3 · timeout=%.0f sim s" % [
		_run_id, 1.0 / 60.0, ENGINE_PHYSICS_HZ, TIME_SCALE, CASE_TIMEOUT_S,
	])

	for variant_value in VARIANTS:
		var variant: Dictionary = variant_value
		var row := await _run_variant(base_profile, variant)
		if row.is_empty():
			_stop_after_current = true
			break
		_rows.append(row)
		if not bool(row.get("telemetry_valid", false)) or str(row.get("status", "")) == "INVALID":
			_error = "Invalid/non-finite telemetry for %s; stopped before the next keel variant" % str(variant["id"])
			_stop_after_current = true
			break

	var baseline := _load_p25_baseline()
	if baseline.is_empty():
		_error = "Could not load the protected P2.5 BASE result"
		_stop_after_current = true
	else:
		_rows.push_front(baseline)
	_write_outputs(validation, base_profile)
	_finish(1 if not _error.is_empty() else 0)


func _validate_variants(base_profile: Resource) -> Dictionary:
	var expected_base_area := float(base_profile.get("keel_area_m2"))
	var expected_base_cl := float(base_profile.get("keel_max_lift_coefficient"))
	if absf(expected_base_area - 2.2) > 0.00001 or absf(expected_base_cl - 1.15) > 0.00001:
		return {"valid": false, "reason": "P2.3c baseline keel parameters differ from the requested BASE: area=%s CLmax=%s" % [expected_base_area, expected_base_cl]}
	for variant_value in VARIANTS:
		var variant: Dictionary = variant_value
		var copy := base_profile.duplicate(true) as Resource
		copy.set(str(variant["property"]), float(variant["value"]))
		if not _same_profile_except(base_profile, copy, str(variant["property"])):
			return {"valid": false, "reason": "%s changes more than its named keel property" % str(variant["id"])}
	return {
		"valid": true,
		"boat_scene_path": BOAT_SCENE,
		"base_profile_path": BASE_PROFILE_PATH,
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"base_keel_area_m2": expected_base_area,
		"base_keel_cl_max": expected_base_cl,
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
	profile_copy.set(str(variant["property"]), float(variant["value"]))
	if not _same_profile_except(base_profile, profile_copy, str(variant["property"])):
		_error = "%s independent profile failed single-variable verification" % str(variant["id"])
		return {}
	var profile_directory := _run_root.path_join("profiles")
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(profile_directory)) != OK:
		_error = "Could not create experiment Profile directory"
		return {}
	var profile_path := profile_directory.path_join("%s_physics_profile.tres" % str(variant["id"]).to_lower())
	if FileAccess.file_exists(profile_path):
		_error = "Refusing to overwrite experiment Profile %s" % profile_path
		return {}
	var save_error := ResourceSaver.save(profile_copy, profile_path)
	if save_error != OK:
		_error = "Could not save independent experiment Profile: %s" % error_string(save_error)
		return {}
	var experiment_profile := load(profile_path) as Resource
	if experiment_profile == null or not _same_profile_except(base_profile, experiment_profile, str(variant["property"])):
		_error = "%s saved Profile did not round-trip with only the requested change" % str(variant["id"])
		return {}

	_lab = LAB_SCENE.instantiate() as Node3D
	_boat = _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	if _boat == null or _runner == null:
		_error = "P2.3c lab scene is missing SailboatBody or PolarTestRunner"
		return {}
	if _boat.scene_file_path != BOAT_SCENE:
		_error = "Unexpected test boat scene: %s" % _boat.scene_file_path
		return {}
	_boat.set("profile", experiment_profile)
	_boat.set("p22_extended_telemetry_enabled", true)
	var test_profile := (load(POLAR_PROFILE_PATH) as Resource).duplicate(true)
	test_profile.set("boat_scene_paths", PackedStringArray([BOAT_SCENE]))
	test_profile.set("case_timeout_seconds", CASE_TIMEOUT_S)
	_runner.profile = test_profile
	root.add_child(_lab)
	await process_frame
	var runtime_snapshot: Dictionary = _boat.call("get_debug_snapshot")
	var runtime_area := float(runtime_snapshot.get("keel_area_m2", NAN))
	if absf(float(runtime_snapshot.get("keel_area_m2", NAN)) - float(experiment_profile.get("keel_area_m2"))) > 0.0001:
		_error = "%s Profile did not reach runtime SailboatLabBody" % str(variant["id"])
		_lab.queue_free()
		await process_frame
		return {}
	var case_id := "%s_12kn_twa_m50" % str(variant["id"]).to_lower()
	var explicit_case := {
		"case_id": case_id,
		"target_tws_kn": 12.0,
		"target_twa_deg": -50.0,
		"tack": "PORT",
		"experiment_group": "P29_NORDIC28_KEEL_SENSITIVITY",
		"experiment_variable": str(variant["property"]),
		"experiment_label": "%s · keel %s=%s" % [str(variant["id"]), str(variant["property"]), str(variant["value"])],
		"auto_sail_trim_enabled": true,
	}
	var started := _runner.start_new_batch({
		"include_extended_telemetry": true,
		"explicit_cases": [explicit_case],
	})
	if not started:
		_error = "%s runner failed to start: %s" % [str(variant["id"]), str(_runner.get_status_snapshot().get("status", "unknown"))]
		_lab.queue_free()
		await process_frame
		return {}
	var start_state := _runner.get_status_snapshot()
	var current_run_id := str(start_state.get("test_run_id", ""))
	print("P2.9 started · %s · run=%s · keel area %.3f m² · CLmax %.3f · config=%s" % [
		str(variant["id"]), current_run_id, float(experiment_profile.get("keel_area_m2")),
		float(experiment_profile.get("keel_max_lift_coefficient")), str(start_state.get("output_path", "")),
	])
	await _wait_for_batch(str(variant["id"]))
	var final_state: Dictionary = _runner.get_status_snapshot()
	var checkpoint_path := str(final_state.get("output_path", ""))
	if checkpoint_path.is_empty() or not FileAccess.file_exists(checkpoint_path):
		_error = "%s completed without a Polar checkpoint" % str(variant["id"])
		_lab.queue_free()
		await process_frame
		return {}
	var checkpoint_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
	if not checkpoint_value is Dictionary:
		_error = "%s Polar checkpoint could not be parsed" % str(variant["id"])
		_lab.queue_free()
		await process_frame
		return {}
	var checkpoint: Dictionary = checkpoint_value
	var results: Array = checkpoint.get("results", [])
	if results.size() != 1:
		_error = "%s expected one result, got %d" % [str(variant["id"]), results.size()]
		_lab.queue_free()
		await process_frame
		return {}
	var raw_result: Dictionary = results[0]
	var artifact_directory := _run_root.path_join("runner_runs").path_join(str(variant["id"]).to_lower())
	if not _copy_runner_artifacts(checkpoint, artifact_directory):
		_lab.queue_free()
		await process_frame
		return {}
	var profile_sha := _sha256_file(profile_path)
	var row := _make_result_row(str(variant["id"]), str(variant["property"]), float(variant["value"]), profile_path, profile_sha, checkpoint, raw_result)
	row["runtime_keel_area_m2"] = runtime_area
	row["telemetry_valid"] = bool(raw_result.get("extended_telemetry", {}).get("telemetry_finite", false))
	row["runner_artifact_directory"] = artifact_directory
	_raw_results.append({"variant": variant, "checkpoint_metadata": checkpoint.get("run_metadata", {}), "raw_result": raw_result})
	_run_manifests.append({
		"variant": variant,
		"run_id": checkpoint.get("test_run_id", current_run_id),
		"config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"profile_path": profile_path,
		"profile_sha256": profile_sha,
		"result_status": raw_result.get("status", "UNKNOWN"),
		"runner_artifact_directory": artifact_directory,
		"runtime_keel_area_m2": runtime_area,
	})
	print("P2.9 complete · %s · %s · TWA %+.3f° · SOG %.3f kn · leeway %+.3f° · rudder %.2f°/%.1f%%" % [
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


func _make_result_row(variant: String, changed_parameter: String, changed_value: float, profile_path: String, profile_sha: String, checkpoint: Dictionary, result: Dictionary) -> Dictionary:
	var ext: Dictionary = result.get("extended_telemetry", {})
	var wind_from := float(result.get("wind_from_deg", 180.0))
	var velocity := Vector3(float(result.get("mean_velocity_world_x_mps", NAN)), 0.0, float(result.get("mean_velocity_world_z_mps", NAN)))
	var upwind_forward := Vector3(sin(deg_to_rad(wind_from)), 0.0, -cos(deg_to_rad(wind_from)))
	var upwind_vmg := velocity.dot(upwind_forward) * KNOTS_PER_MPS if velocity.is_finite() else NAN
	return {
		"variant": variant,
		"changed_parameter": changed_parameter,
		"changed_value": changed_value,
		"profile_path": profile_path,
		"profile_sha256": profile_sha,
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
		"mean_lateral_velocity_mps": _telemetry(ext, "mean_body_lateral_speed_mps"),
		"mean_leeway_deg": result.get("mean_leeway_deg", null),
		"mean_heel_deg": result.get("mean_heel_deg", null),
		"mean_rudder_deg": result.get("mean_rudder_deg", null),
		"rudder_saturation_fraction": result.get("rudder_saturation_fraction", null),
		"keel_area_m2": _telemetry(ext, "mean_keel_area_m2"),
		"keel_aoa_deg": _telemetry(ext, "mean_keel_aoa_deg"),
		"keel_cl": _telemetry(ext, "mean_keel_cl"),
		"keel_cd": _telemetry(ext, "mean_keel_cd"),
		"keel_lateral_force_starboard_n": _telemetry(ext, "mean_keel_net_lateral_force_starboard_n"),
		"keel_forward_force_n": _telemetry(ext, "mean_keel_net_forward_force_n"),
		"keel_drag_forward_force_n": _telemetry(ext, "mean_keel_drag_forward_force_n"),
		"hull_resistance_forward_n": result.get("mean_hull_resistance_forward_n", null),
		"keel_yaw_torque_nm": _telemetry(ext, "mean_keel_net_torque_local_nm_y"),
		"rudder_aoa_deg": _telemetry(ext, "mean_rudder_aoa_deg"),
		"rudder_cl": _telemetry(ext, "mean_rudder_cl"),
		"rudder_cd": _telemetry(ext, "mean_rudder_cd"),
		"rudder_lateral_force_starboard_n": _telemetry(ext, "mean_rudder_net_lateral_force_starboard_n"),
		"rudder_yaw_torque_nm": _telemetry(ext, "mean_rudder_net_torque_local_nm_y"),
		"main_yaw_torque_nm": _telemetry(ext, "mean_main_net_torque_local_nm_y"),
		"jib_yaw_torque_nm": _telemetry(ext, "mean_jib_net_torque_local_nm_y"),
		"buoyancy_yaw_torque_nm": _telemetry(ext, "mean_buoyancy_yaw_torque_nm"),
		"measured_yaw_torque_sum_nm": _telemetry(ext, "mean_measured_yaw_torque_sum_nm"),
		"elapsed_simulation_seconds": result.get("elapsed_simulation_seconds", null),
		"sample_count": result.get("sample_count", 0),
		"telemetry_valid": bool(ext.get("telemetry_finite", false)),
		"extended_telemetry": ext,
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
			return _make_result_row(
				"BASE", "none", 0.0, BASE_PROFILE_PATH, _sha256_file(BASE_PROFILE_PATH),
				{"test_run_id": result.get("test_run_id", ""), "config_hash": document.get("metadata", {}).get("config_hash", result.get("boat_config_hash", "")), "boat_config_hash": result.get("boat_config_hash", "")}, compact_result
			)
	return {}


func _telemetry(telemetry: Dictionary, key: String) -> Variant:
	return telemetry.get(key, null)


func _copy_runner_artifacts(checkpoint: Dictionary, destination: String) -> bool:
	var absolute_directory := ProjectSettings.globalize_path(destination)
	if DirAccess.dir_exists_absolute(absolute_directory):
		_error = "Refusing to overwrite runner artifacts: %s" % destination
		return false
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		_error = "Could not create runner artifact directory: %s" % destination
		return false
	var source_directory := str(checkpoint.get("run_directory", ""))
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		var source := source_directory.path_join(filename)
		if not FileAccess.file_exists(source):
			_error = "Missing Polar runner artifact: %s" % source
			return false
		var output := FileAccess.open(destination.path_join(filename), FileAccess.WRITE)
		if output == null:
			_error = "Could not copy Polar artifact: %s" % filename
			return false
		output.store_string(FileAccess.get_file_as_string(source))
	return true


func _write_outputs(validation: Dictionary, base_profile: Resource) -> void:
	var cases: Array[Dictionary] = []
	for row in _rows:
		var csv_row: Array = []
		for field in CSV_FIELDS:
			csv_row.append(row.get(field, null))
		cases.append({"case_id": row.get("variant", ""), "result": row})
	var csv_lines := PackedStringArray([",".join(PackedStringArray(CSV_FIELDS))])
	for case_value in cases:
		var row: Dictionary = case_value["result"]
		var cells := PackedStringArray()
		for field in CSV_FIELDS:
			cells.append(_csv_value(row.get(field, null)))
		csv_lines.append(",".join(cells))
	_write_text(_run_root.path_join("keel_sensitivity.csv"), "\n".join(csv_lines) + "\n")
	var p25_doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(P25_BASELINE_PATH)) if FileAccess.file_exists(P25_BASELINE_PATH) else {}
	_write_json(_run_root.path_join("keel_sensitivity.json"), {
		"experiment": "Nordic 28 P2.9 keel side-force sensitivity",
		"experiment_run_id": _run_id,
		"base_reference": {"phase": "P2.5 existing data; not rerun", "source": P25_BASELINE_PATH, "case_id": "p25_12kn_050twa_port"},
		"conditions": {"tws_kn": 12.0, "target_twa_deg": -50.0, "tack": "PORT", "engine": "OFF", "wave_mode": "zero_amplitude", "water_current_mps": [0.0, 0.0, 0.0]},
		"execution": {"physics_step_seconds": 1.0 / 60.0, "engine_physics_ticks_per_second": ENGINE_PHYSICS_HZ, "time_scale": TIME_SCALE, "effective_simulated_steps_per_second": 60.0, "case_timeout_sim_seconds": CASE_TIMEOUT_S},
		"protected_base_profile": {"path": BASE_PROFILE_PATH, "sha256": _sha256_file(BASE_PROFILE_PATH), "keel_area_m2": base_profile.get("keel_area_m2"), "keel_max_lift_coefficient": base_profile.get("keel_max_lift_coefficient")},
		"variant_runs": _run_manifests,
		"results": cases,
		"p25_reference_metadata": p25_doc.get("metadata", {}) if p25_doc is Dictionary else {},
		"analysis_notes": ["mean_upwind_vmg_kn is computed from mean horizontal world velocity projected onto the true wind-from bearing; positive means progress into the wind.", "runner_target_course_vmg_kn is retained separately because the P2 runner projects onto the commanded target heading, not the actual wind axis.", "Failure statuses are preserved; a failed TWA result is not a valid -50 degree polar point."],
	})
	_write_json(_run_root.path_join("p29_manifest.json"), {
		"experiment_run_id": _run_id,
		"phase": "Nordic 28 P2.9 keel side-force sensitivity",
		"timestamp": Time.get_datetime_string_from_system(true),
		"boat_scene_path": BOAT_SCENE,
		"base_physics_profile_path": BASE_PROFILE_PATH,
		"base_physics_profile_sha256": _sha256_file(BASE_PROFILE_PATH),
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"visual_profile_sha256": _sha256_file(VISUAL_PROFILE_PATH),
		"runner_sha256": _sha256_file("res://scripts/polar_test_runner.gd"),
		"test_script_sha256": _sha256_file("res://tests/run_polar_p29_keel_sensitivity.gd"),
		"profile_validation": validation,
		"runs": _run_manifests,
		"baseline_run_id": "polar_2026-10-28_19-27-37_907713",
		"baseline_configuration_hash": "fff7841f8afdb2ee2a742b05e606c51d9b530c052f815f59931bd47b7e7da18f",
		"stop_after_current": _stop_after_current,
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


func _write_text(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_error = "Could not write %s" % path
		return
	file.store_string(contents)


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
		var snapshot := _runner.get_status_snapshot()
		var now := Time.get_ticks_usec()
		if now - last_log_usec >= 10000000:
			last_log_usec = now
			print("P2.9 progress · %s · sim %.0f s · SOG %.2f kn · TWA %+.1f° · rudder %+.1f°" % [
				variant, float(snapshot.get("simulation_seconds", 0.0)), float(snapshot.get("sog_kn", 0.0)),
				float(snapshot.get("measured_twa_deg", 0.0)), float(snapshot.get("rudder_deg", 0.0)),
			])


func _finish(exit_code: int, message: String = "") -> void:
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	if not message.is_empty():
		push_error("[polar p2.9] " + message)
		quit(exit_code)
		return
	if not _error.is_empty():
		push_error("[polar p2.9] " + _error)
		quit(exit_code)
		return
	quit(exit_code)
