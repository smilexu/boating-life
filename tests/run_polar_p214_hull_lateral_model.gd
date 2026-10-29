extends SceneTree
## P2.14 focused validation: exact zero-offset regression plus one tiny
## nonzero geometry-offset path smoke. The estimated Z offset is below the
## GLB keel-exclusion uncertainty, so no H-GEO calibration sweep is run.

const LAB_SCENE := preload("res://scenes/SailboatLabP23c.tscn")
const BOAT_SCENE := "res://scenes/boats/SailingBoat8mP23c.tscn"
const SOURCE_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_physics_profile.tres"
const VISUAL_PROFILE_PATH := "res://resources/sailing/nordic28_p23c_visual_rig_profile.tres"
const BASE_PROFILE_PATH := "res://resources/sailing/nordic28_p214_base_physics_profile.tres"
const HGEO_PROFILE_PATH := "res://resources/sailing/nordic28_p214_hgeo_physics_profile.tres"
const POLAR_PROFILE_PATH := "res://resources/sailing/polar_test_profile.tres"
const P25_RESULTS_PATH := "res://docs/sailing/polar_p25/polar_2026-10-28_19-27-37_907713/polar_results.json"
const OUTPUT_ROOT := "res://docs/sailing/polar_p214"
const PHYSICS_HZ := 480
const TIME_SCALE := 8.0
const CASE_TIMEOUT_S := 180.0
const KNOTS_PER_MPS := 1.9438444924406
const ESTIMATED_HULL_CENTER_BODY_LOCAL_M := Vector3(0.006664, -0.282765, -0.004380)
const ESTIMATED_COM_LOCAL_M := Vector3(0.0, -0.65, 0.0)
const H_GEO_Z_OFFSET_M := -0.004380
const CSV_FIELDS := [
	"variant", "case_id", "run_id", "polar_config_hash", "boat_config_hash", "profile_path", "profile_sha256",
	"status", "failure_reason", "target_tws_kn", "target_twa_deg", "measured_twa_deg", "twa_error_deg",
	"mean_sog_kn", "mean_upwind_vmg_kn", "mean_target_course_vmg_kn", "mean_longitudinal_velocity_mps",
	"mean_lateral_velocity_mps", "mean_leeway_deg", "mean_heel_deg", "mean_rudder_deg", "rudder_saturation_fraction",
	"hull_lateral_center_from_com_z_m", "hull_lateral_velocity_x_mps", "hull_lateral_force_x_n", "hull_lateral_yaw_torque_nm",
	"hull_force_conservation_error_n", "wind_queries_per_tick", "wave_queries_per_tick", "sample_count", "elapsed_simulation_seconds",
	"source_case_id"
]

var _lab: Node3D
var _boat: RigidBody3D
var _runner: PolarTestRunner
var _old_physics_hz := 60
var _old_time_scale := 1.0
var _run_id := ""
var _run_dir := ""
var _rows: Array[Dictionary] = []
var _runs: Array[Dictionary] = []
var _raw_results: Array[Dictionary] = []
var _validation: Dictionary = {}
var _error := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	var source_profile := load(SOURCE_PROFILE_PATH) as Resource
	var base_profile := load(BASE_PROFILE_PATH) as Resource
	var hgeo_profile := load(HGEO_PROFILE_PATH) as Resource
	var polar_profile := load(POLAR_PROFILE_PATH) as Resource
	var p25 := _load_p25_results()
	if source_profile == null or base_profile == null or hgeo_profile == null or polar_profile == null or p25.is_empty():
		_finish(2, "Required P2.14 Profiles, Polar profile, or protected P2.5 data failed to load")
		return
	_validation = _validate_profiles(source_profile, base_profile, hgeo_profile, p25)
	if not bool(_validation.get("valid", false)):
		_finish(2, str(_validation.get("reason", "P2.14 validation failed")))
		return
	if OS.get_cmdline_user_args().has("--validate-only"):
		print("P2.14 config validation · %s" % JSON.stringify(_validation, "\t"))
		_finish(0)
		return

	_run_id = "p214_%d_%d" % [int(Time.get_unix_time_from_system()), Time.get_ticks_usec() % 1000000]
	_run_dir = OUTPUT_ROOT.path_join(_run_id)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_run_dir)):
		_finish(2, "Refusing to overwrite existing P2.14 directory %s" % _run_dir)
		return
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_run_dir)) != OK:
		_finish(2, "Could not create P2.14 result directory")
		return

	var saved_polar_profile := polar_profile.duplicate(true) as Resource
	saved_polar_profile.set("boat_scene_paths", PackedStringArray([BOAT_SCENE]))
	saved_polar_profile.set("case_timeout_seconds", CASE_TIMEOUT_S)
	var saved_polar_path := _run_dir.path_join("p214_polar_test_profile.tres")
	if ResourceSaver.save(saved_polar_profile, saved_polar_path) != OK:
		_finish(2, "Could not save isolated P2.14 Polar settings")
		return

	Engine.physics_ticks_per_second = PHYSICS_HZ
	Engine.time_scale = TIME_SCALE
	var p25_m50: Dictionary = p25["m50"]
	var p25_m90: Dictionary = p25["m90"]
	_rows.append(_make_row_from_existing("P25_BASE_M50", p25_m50, "P2.5 protected result"))
	_rows.append(_make_row_from_existing("P25_BASE_M90", p25_m90, "P2.5 protected result"))

	var base_row := await _run_case("P214_BASE_ZERO_M50_SMOKE", BASE_PROFILE_PATH, 0.0, saved_polar_profile, -50.0, "zero-offset regression smoke")
	if base_row.is_empty():
		_write_outputs(p25, saved_polar_path)
		_finish(1)
		return
	_rows.append(base_row)
	if not _matches_p25_smoke(base_row, p25_m50):
		_error = "Zero-offset smoke did not remain within the P2.5 regression tolerances; H-GEO path was not run"
		_write_outputs(p25, saved_polar_path)
		_finish(1)
		return

	# The estimated Z lever arm is only 4.38 mm and varies by roughly 20–30 mm
	# with the merged-mesh keel exclusion. Run one path smoke, not a misleading
	# three-angle calibration sweep.
	var hgeo_row := await _run_case("P214_HGEO_PATH_M50_SMOKE", HGEO_PROFILE_PATH, H_GEO_Z_OFFSET_M, saved_polar_profile, -50.0, "nonzero force-path smoke only; geometry offset below uncertainty")
	if hgeo_row.is_empty():
		_write_outputs(p25, saved_polar_path)
		_finish(1)
		return
	_rows.append(hgeo_row)
	if not _hgeo_torque_is_consistent(hgeo_row):
		_error = "H-GEO telemetry yaw moment did not match r cross F"

	_write_outputs(p25, saved_polar_path)
	_finish(1 if not _error.is_empty() else 0)


func _validate_profiles(source: Resource, base: Resource, hgeo: Resource, p25: Dictionary) -> Dictionary:
	if absf(float(source.get("main_sail_area_m2")) - 15.90006) > 0.0001 or absf(float(source.get("headsail_area_m2")) - 6.59991) > 0.0001:
		return {"valid": false, "reason": "P2.3c source sail areas do not match protected profile"}
	if not _same_profile_except(source, base, ["vessel_name"]) or not _same_profile_except(source, hgeo, ["vessel_name", "hull_lateral_center_from_com_local_m"]):
		return {"valid": false, "reason": "P2.14 Profiles contain changes beyond name/COM-relative lateral center"}
	var base_center: Vector3 = base.get("hull_lateral_center_from_com_local_m")
	var hgeo_center: Vector3 = hgeo.get("hull_lateral_center_from_com_local_m")
	if not base_center.is_zero_approx() or not hgeo_center.is_equal_approx(Vector3(0.0, 0.0, H_GEO_Z_OFFSET_M)):
		return {"valid": false, "reason": "BASE/H-GEO center values are incorrect"}
	if str(p25["m50"].get("status", "")) != "HEADING_FAILED" or str(p25["m90"].get("status", "")) != "STABLE":
		return {"valid": false, "reason": "Protected P2.5 reference statuses are unexpected"}
	return {
		"valid": true,
		"boat_scene_path": BOAT_SCENE,
		"source_profile_path": SOURCE_PROFILE_PATH,
		"base_profile_path": BASE_PROFILE_PATH,
		"hgeo_profile_path": HGEO_PROFILE_PATH,
		"base_zero_offset": base_center,
		"hgeo_com_relative_offset_m": hgeo_center,
		"profile_single_variable_check": "pass; H-GEO changes only the new center vector, BASE only changes vessel_name",
		"geometry_estimate_z_only_m": H_GEO_Z_OFFSET_M,
		"geometry_center_body_local_m": ESTIMATED_HULL_CENTER_BODY_LOCAL_M,
		"com_body_local_m": ESTIMATED_COM_LOCAL_M,
		"geometry_uncertainty_note": "Merged hull/keel mesh exclusion sensitivity moves the Z centroid by about 20–30 mm, larger than the 4.38 mm candidate arm.",
		"p25_reference_path": P25_RESULTS_PATH,
	}


func _same_profile_except(base: Resource, candidate: Resource, ignored: Array) -> bool:
	for property_value in base.get_property_list():
		var property: Dictionary = property_value
		if (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var property_name := str(property.get("name", ""))
		if property_name in ignored or property_name in ["resource_path", "resource_name"]:
			continue
		if var_to_str(base.get(property_name)) != var_to_str(candidate.get(property_name)):
			return false
	return true


func _run_case(variant: String, profile_path: String, expected_z: float, polar_profile: Resource, target_twa: float, label: String) -> Dictionary:
	var boat_profile := load(profile_path) as Resource
	_lab = LAB_SCENE.instantiate() as Node3D
	_boat = _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_runner = _lab.get_node_or_null("PolarTestRunner") as PolarTestRunner
	if boat_profile == null or _boat == null or _runner == null or _boat.scene_file_path != BOAT_SCENE:
		_error = "%s: P2.3c lab boat, Profile, or Polar runner is missing" % variant
		await _free_lab()
		return {}
	_boat.set("profile", boat_profile)
	_boat.set("p22_extended_telemetry_enabled", true)
	_runner.profile = polar_profile.duplicate(true) as Resource
	root.add_child(_lab)
	await process_frame
	var snapshot: Dictionary = _boat.call("get_debug_snapshot")
	var runtime_center: Vector3 = snapshot.get("hull_lateral_center_from_com_local_m", Vector3(NAN, NAN, NAN))
	if absf(runtime_center.z - expected_z) > 0.000001 or absf(runtime_center.x) > 0.000001 or absf(runtime_center.y) > 0.000001:
		_error = "%s Profile did not reach the body runtime: %s" % [variant, str(runtime_center)]
		await _free_lab()
		return {}
	var explicit_case := {
		"case_id": variant.to_lower(),
		"target_tws_kn": 12.0,
		"target_twa_deg": target_twa,
		"tack": "PORT",
		"experiment_group": "P214_NORDIC28_HULL_LATERAL_CENTER",
		"experiment_variable": "hull_lateral_center_from_com_local_m",
		"experiment_label": label,
		"auto_sail_trim_enabled": true,
	}
	if not _runner.start_new_batch({"include_extended_telemetry": true, "capture_yaw_timeseries": true, "explicit_cases": [explicit_case]}):
		_error = "%s: Polar runner did not start (%s)" % [variant, str(_runner.get_status_snapshot().get("status", "unknown"))]
		await _free_lab()
		return {}
	var start_state: Dictionary = _runner.get_status_snapshot()
	var run_id := str(start_state.get("test_run_id", ""))
	print("P2.14 started · %s · run=%s · COM-relative Z=%+.6f m · dt=%.9f s" % [variant, run_id, expected_z, 1.0 / 60.0])
	await _wait_for_batch(variant)
	var finish_state: Dictionary = _runner.get_status_snapshot()
	var checkpoint_path := str(finish_state.get("output_path", ""))
	if checkpoint_path.is_empty() or not FileAccess.file_exists(checkpoint_path):
		_error = "%s: Polar runner did not write a checkpoint" % variant
		await _free_lab()
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(checkpoint_path))
	if not parsed is Dictionary:
		_error = "%s: Polar checkpoint JSON could not be parsed" % variant
		await _free_lab()
		return {}
	var checkpoint: Dictionary = parsed
	var results: Array = checkpoint.get("results", [])
	if results.size() != 1:
		_error = "%s: expected one case result, received %d" % [variant, results.size()]
		await _free_lab()
		return {}
	var raw_result: Dictionary = results[0]
	var artifact_dir := _run_dir.path_join("runner_runs").path_join(variant.to_lower())
	if not _copy_runner_artifacts(checkpoint, artifact_dir):
		await _free_lab()
		return {}
	var row := _make_row(variant, profile_path, expected_z, checkpoint, raw_result)
	row["runner_artifact_directory"] = artifact_dir
	if not bool(row.get("telemetry_finite", false)):
		_error = "%s: extended telemetry contains invalid values" % variant
	_runs.append({
		"variant": variant,
		"run_id": checkpoint.get("test_run_id", run_id),
		"polar_config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"status": raw_result.get("status", "UNKNOWN"),
		"profile_path": profile_path,
		"profile_sha256": _sha256_file(profile_path),
		"hull_lateral_center_from_com_local_m": runtime_center,
		"artifact_directory": artifact_dir,
	})
	_raw_results.append({"variant": variant, "run_metadata": checkpoint.get("run_metadata", {}), "result": raw_result})
	print("P2.14 complete · %s · %s · TWA %+.3f° · SOG %.3f kn · rudder %+.2f° · hull Mz %+.4f N·m" % [
		variant, str(row.get("status", "UNKNOWN")), float(row.get("measured_twa_deg", NAN)), float(row.get("mean_sog_kn", NAN)),
		float(row.get("mean_rudder_deg", NAN)), float(row.get("hull_lateral_yaw_torque_nm", NAN)),
	])
	await _free_lab()
	return row


func _make_row(variant: String, profile_path: String, expected_z: float, checkpoint: Dictionary, result: Dictionary) -> Dictionary:
	var ext: Dictionary = result.get("extended_telemetry", {})
	var velocity := Vector3(float(result.get("mean_velocity_world_x_mps", NAN)), 0.0, float(result.get("mean_velocity_world_z_mps", NAN)))
	var wind_from := float(result.get("wind_from_deg", 180.0))
	var upwind_direction := Vector3(sin(deg_to_rad(wind_from)), 0.0, -cos(deg_to_rad(wind_from)))
	var calculated_force := Vector3(
		float(ext.get("mean_hull_drag_calculated_force_local_n_x", NAN)),
		float(ext.get("mean_hull_drag_calculated_force_local_n_y", NAN)),
		float(ext.get("mean_hull_drag_calculated_force_local_n_z", NAN))
	)
	var applied_force := Vector3(
		float(ext.get("mean_hull_drag_applied_force_local_n_x", NAN)),
		float(ext.get("mean_hull_drag_applied_force_local_n_y", NAN)),
		float(ext.get("mean_hull_drag_applied_force_local_n_z", NAN))
	)
	return {
		"variant": variant,
		"case_id": result.get("case_id", ""),
		"run_id": checkpoint.get("test_run_id", result.get("test_run_id", "")),
		"polar_config_hash": checkpoint.get("config_hash", ""),
		"boat_config_hash": checkpoint.get("boat_config_hash", ""),
		"profile_path": profile_path,
		"profile_sha256": _sha256_file(profile_path),
		"status": result.get("status", "UNKNOWN"),
		"failure_reason": result.get("failure_reason", ""),
		"target_tws_kn": result.get("target_tws_kn", 12.0),
		"target_twa_deg": result.get("target_twa_deg", -50.0),
		"measured_twa_deg": result.get("measured_twa_deg", null),
		"twa_error_deg": float(result.get("measured_twa_deg", NAN)) - float(result.get("target_twa_deg", target_twa_from_result(result))),
		"mean_sog_kn": result.get("mean_sog_kn", null),
		"mean_upwind_vmg_kn": velocity.dot(upwind_direction) * KNOTS_PER_MPS if velocity.is_finite() else NAN,
		"mean_target_course_vmg_kn": result.get("mean_vmg_kn", null),
		"mean_longitudinal_velocity_mps": result.get("mean_longitudinal_velocity_mps", null),
		"mean_lateral_velocity_mps": ext.get("mean_body_lateral_speed_mps", null),
		"mean_leeway_deg": result.get("mean_leeway_deg", null),
		"mean_heel_deg": result.get("mean_heel_deg", null),
		"mean_rudder_deg": result.get("mean_rudder_deg", null),
		"rudder_saturation_fraction": result.get("rudder_saturation_fraction", null),
		"hull_lateral_center_from_com_z_m": expected_z,
		"hull_lateral_velocity_x_mps": ext.get("mean_hull_lateral_velocity_local_mps_x", null),
		"hull_lateral_force_x_n": ext.get("mean_hull_lateral_resistance_starboard_n", null),
		"hull_lateral_yaw_torque_nm": ext.get("mean_hull_lateral_yaw_torque_nm", null),
		"hull_force_conservation_error_n": (calculated_force - applied_force).length(),
		"wind_queries_per_tick": ext.get("mean_wind_query_count_per_tick", null),
		"wave_queries_per_tick": ext.get("mean_wave_query_count_per_tick", null),
		"sample_count": result.get("sample_count", 0),
		"elapsed_simulation_seconds": result.get("elapsed_simulation_seconds", null),
		"source_case_id": "",
		"telemetry_finite": bool(ext.get("telemetry_finite", false)),
		"extended_telemetry": ext,
		"raw_result": result,
	}


func target_twa_from_result(result: Dictionary) -> float:
	return float(result.get("target_twa_deg", -50.0))


func _make_row_from_existing(variant: String, result: Dictionary, source: String) -> Dictionary:
	var ext: Dictionary = result.get("extended_telemetry", {})
	var velocity := Vector3(float(result.get("mean_velocity_world_x_mps", NAN)), 0.0, float(result.get("mean_velocity_world_z_mps", NAN)))
	var wind_from := float(result.get("wind_from_deg", 180.0))
	var upwind_direction := Vector3(sin(deg_to_rad(wind_from)), 0.0, -cos(deg_to_rad(wind_from)))
	return {
		"variant": variant,
		"case_id": result.get("case_id", ""),
		"run_id": result.get("test_run_id", ""),
		"polar_config_hash": "protected P2.5; see referenced checkpoint",
		"boat_config_hash": result.get("boat_config_hash", ""),
		"profile_path": SOURCE_PROFILE_PATH,
		"profile_sha256": _sha256_file(SOURCE_PROFILE_PATH),
		"status": result.get("status", "UNKNOWN"),
		"failure_reason": result.get("failure_reason", ""),
		"target_tws_kn": result.get("target_tws_kn", 12.0),
		"target_twa_deg": result.get("target_twa_deg", -50.0),
		"measured_twa_deg": result.get("measured_twa_deg", null),
		"twa_error_deg": float(result.get("measured_twa_deg", NAN)) - float(result.get("target_twa_deg", -50.0)),
		"mean_sog_kn": result.get("mean_sog_kn", null),
		"mean_upwind_vmg_kn": velocity.dot(upwind_direction) * KNOTS_PER_MPS if velocity.is_finite() else NAN,
		"mean_target_course_vmg_kn": result.get("mean_vmg_kn", null),
		"mean_longitudinal_velocity_mps": result.get("mean_longitudinal_velocity_mps", null),
		"mean_lateral_velocity_mps": ext.get("mean_body_lateral_speed_mps", null),
		"mean_leeway_deg": result.get("mean_leeway_deg", null),
		"mean_heel_deg": result.get("mean_heel_deg", null),
		"mean_rudder_deg": result.get("mean_rudder_deg", null),
		"rudder_saturation_fraction": result.get("rudder_saturation_fraction", null),
		"hull_lateral_center_from_com_z_m": 0.0,
		"hull_lateral_velocity_x_mps": null,
		"hull_lateral_force_x_n": ext.get("mean_hull_lateral_resistance_starboard_n", null),
		"hull_lateral_yaw_torque_nm": 0.0,
		"hull_force_conservation_error_n": 0.0,
		"wind_queries_per_tick": ext.get("mean_wind_query_count_per_tick", null),
		"wave_queries_per_tick": ext.get("mean_wave_query_count_per_tick", null),
		"sample_count": result.get("sample_count", 0),
		"elapsed_simulation_seconds": result.get("elapsed_simulation_seconds", null),
		"source_case_id": result.get("case_id", ""),
		"profile_source": source,
		"telemetry_finite": bool(ext.get("telemetry_finite", false)),
		"extended_telemetry": ext,
	}


func _matches_p25_smoke(smoke: Dictionary, baseline: Dictionary) -> bool:
	var base_ext: Dictionary = baseline.get("extended_telemetry", {})
	var smoke_ext: Dictionary = smoke.get("extended_telemetry", {})
	var twa_delta := absf(float(smoke.get("measured_twa_deg", NAN)) - float(baseline.get("measured_twa_deg", NAN)))
	var sog_delta := absf(float(smoke.get("mean_sog_kn", NAN)) - float(baseline.get("mean_sog_kn", NAN)))
	var rudder_delta := absf(float(smoke.get("mean_rudder_deg", NAN)) - float(baseline.get("mean_rudder_deg", NAN)))
	var force_delta := absf(float(smoke_ext.get("mean_hull_lateral_resistance_starboard_n", NAN)) - float(base_ext.get("mean_hull_lateral_resistance_starboard_n", NAN)))
	var moment := absf(float(smoke.get("hull_lateral_yaw_torque_nm", NAN)))
	var force_error := float(smoke.get("hull_force_conservation_error_n", INF))
	var result := twa_delta <= 0.50 and sog_delta <= 0.03 and rudder_delta <= 1.0 and force_delta <= 3.0 and moment <= 0.00001 and force_error <= 0.00001
	print("P2.14 BASE regression · ΔTWA=%.4f° ΔSOG=%.5f kn Δrudder=%.4f° ΔhullFx=%.5f N Mz=%.8f N·m force-sum=%.8f N · %s" % [twa_delta, sog_delta, rudder_delta, force_delta, moment, force_error, "PASS" if result else "FAIL"])
	return result


func _hgeo_torque_is_consistent(row: Dictionary) -> bool:
	var ext: Dictionary = row.get("extended_telemetry", {})
	var z := float(row.get("hull_lateral_center_from_com_z_m", NAN))
	var fx := float(row.get("hull_lateral_force_x_n", NAN))
	var mz := float(row.get("hull_lateral_yaw_torque_nm", NAN))
	var expected := z * fx
	return is_finite(expected) and is_finite(mz) and absf(expected - mz) <= 0.002 and float(row.get("hull_force_conservation_error_n", INF)) <= 0.00001 and bool(ext.get("telemetry_finite", false))




func _copy_runner_artifacts(checkpoint: Dictionary, destination: String) -> bool:
	var absolute := ProjectSettings.globalize_path(destination)
	if DirAccess.dir_exists_absolute(absolute) or DirAccess.make_dir_recursive_absolute(absolute) != OK:
		_error = "Could not create unique Polar artifact directory %s" % destination
		return false
	var source_directory := str(checkpoint.get("run_directory", ""))
	for filename in ["polar_results.csv", "polar_results.json", "polar_summary.json", "polar_checkpoint.json"]:
		var source_path := source_directory.path_join(filename)
		if not FileAccess.file_exists(source_path):
			_error = "Runner artifact is missing: %s" % source_path
			return false
		var file := FileAccess.open(destination.path_join(filename), FileAccess.WRITE)
		if file == null:
			_error = "Could not write copied runner artifact: %s" % filename
			return false
		file.store_string(FileAccess.get_file_as_string(source_path))
	return true


func _write_outputs(p25: Dictionary, saved_polar_path: String) -> void:
	if _run_dir.is_empty():
		return
	var csv := PackedStringArray([",".join(PackedStringArray(CSV_FIELDS))])
	for row in _rows:
		var cells := PackedStringArray()
		for field in CSV_FIELDS:
			cells.append(_csv_value(row.get(field, null)))
		csv.append(",".join(cells))
	_write_text(_run_dir.path_join("hull_lateral_model.csv"), "\n".join(csv) + "\n")
	var p25_meta: Dictionary = p25.get("metadata", {})
	_write_json(_run_dir.path_join("hull_lateral_model.json"), {
		"experiment": "Nordic 28 P2.14 single-point hull lateral resistance model",
		"experiment_run_id": _run_id,
		"phase_note": "Geometry sensitivity is below mesh-exclusion uncertainty; the H-GEO case is a force-path smoke only and is not a calibration result.",
		"boat_scene_path": BOAT_SCENE,
		"source_profile_path": SOURCE_PROFILE_PATH,
		"visual_profile_path": VISUAL_PROFILE_PATH,
		"geometry_estimate": {
			"mesh_path": "VisualRoot/HullModelAdapter/Nordic28Model/node_0",
			"merged_hull_and_fin_keel_mesh": true,
			"body_local_waterline_y_m": -0.05,
			"waterline_source": "rest_submergence 0.45 m plus four-point mean y -0.50 m; static reset/body relation",
			"keel_exclusion": {"method": "exclude central strip |X| <= 0.25 m below body-local y -0.60 m", "reason": "separate keel water-force model"},
			"projected_area_hull_only_m2": 6.29380835820549,
			"centroid_body_local_m": ESTIMATED_HULL_CENTER_BODY_LOCAL_M,
			"com_body_local_m": ESTIMATED_COM_LOCAL_M,
			"centroid_from_com_local_m": ESTIMATED_HULL_CENTER_BODY_LOCAL_M - ESTIMATED_COM_LOCAL_M,
			"applied_first_pass_center_z_only_from_com_local_m": Vector3(0.0, 0.0, H_GEO_Z_OFFSET_M),
			"keel_exclusion_z_sensitivity_m": [-0.005792, 0.022798],
			"uncertainty": "Single GLB surface merges keel and hull; geometric central-strip removal is approximate. Candidate Z lever magnitude 4.38 mm is smaller than exclusion sensitivity."
		},
		"execution": {"physics_step_seconds": 1.0 / 60.0, "engine_physics_ticks_per_second": PHYSICS_HZ, "time_scale": TIME_SCALE, "effective_steps_per_simulated_second": 60.0, "case_timeout_sim_seconds": CASE_TIMEOUT_S},
		"p25_protected_baseline": {"source": P25_RESULTS_PATH, "run_id": p25_meta.get("test_run_id", ""), "boat_config_hash": p25_meta.get("boat_config_hash", ""), "m50_case_id": "p25_12kn_050twa_port", "m90_case_id": "p25_12kn_090twa_port"},
		"polar_profile_path": saved_polar_path,
		"profile_validation": _validation,
		"runs": _runs,
		"results": _rows,
		"raw_runner_results": _raw_results,
		"skipped_formal_cases": [
			{"variant": "H-GEO", "target_tws_kn": 12, "target_twa_deg": -70, "reason": "P2.5 has no exact matching base; geometry-derived Z center is within GLB segmentation uncertainty, so no calibration case was forced."},
			{"variant": "H-GEO", "target_tws_kn": 12, "target_twa_deg": -90, "reason": "The candidate Z force arm is 4.38 mm, below the 20–30 mm keel-boundary estimate sensitivity; formal performance comparison would be non-informative."}
		],
		"notes": [
			"BASE profile offset is zero and retains the original central-force branch.",
			"The one H-GEO test checks the nonzero force path only; its result is not interpreted as a meaningful hydrodynamic change.",
			"All force and moment telemetry is local body axes; yaw moment is local +Y and r cross F about the actual COM.",
			"No extra explicit torque is applied; force is applied once at the COM-relative point converted to body-origin offset for apply_force().",
			"Failure statuses remain unchanged; HEADING_FAILED results are not valid target-TWA Polar points."
		],
		"error": _error
	})
	_write_json(_run_dir.path_join("p214_manifest.json"), {
		"experiment_run_id": _run_id,
		"timestamp": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info(),
		"boat_scene_path": BOAT_SCENE,
		"boat_scene_sha256": _sha256_file(BOAT_SCENE),
		"source_profile_sha256": _sha256_file(SOURCE_PROFILE_PATH),
		"base_profile_sha256": _sha256_file(BASE_PROFILE_PATH),
		"hgeo_profile_sha256": _sha256_file(HGEO_PROFILE_PATH),
		"visual_profile_sha256": _sha256_file(VISUAL_PROFILE_PATH),
		"body_script_sha256": _sha256_file("res://scripts/sailboat_lab_body.gd"),
		"polar_runner_sha256": _sha256_file("res://scripts/polar_test_runner.gd"),
		"test_script_sha256": _sha256_file("res://tests/run_polar_p214_hull_lateral_model.gd"),
		"hydrodynamics_script_sha256": _sha256_file("res://scripts/sailboat_hydrodynamics.gd"),
		"configuration_fingerprint": _configuration_fingerprint(),
		"p25_reference": {"path": P25_RESULTS_PATH, "run_id": p25_meta.get("test_run_id", ""), "profile_hash": p25_meta.get("boat_config_hash", "")},
		"runtime_execution": {"physics_step_seconds": 1.0 / 60.0, "ticks_per_second": PHYSICS_HZ, "time_scale": TIME_SCALE, "case_timeout_sim_seconds": CASE_TIMEOUT_S},
		"profile_validation": _validation,
		"runs": _runs,
		"error": _error
	})


func _configuration_fingerprint() -> String:
	var signature := {
		"phase": "P2.14 single point hull lateral resistance",
		"source_profile_sha256": _sha256_file(SOURCE_PROFILE_PATH),
		"base_profile_sha256": _sha256_file(BASE_PROFILE_PATH),
		"hgeo_profile_sha256": _sha256_file(HGEO_PROFILE_PATH),
		"boat_scene_sha256": _sha256_file(BOAT_SCENE),
		"body_sha256": _sha256_file("res://scripts/sailboat_lab_body.gd"),
		"runner_sha256": _sha256_file("res://scripts/polar_test_runner.gd"),
		"godot": Engine.get_version_info(),
		"physics_hz": PHYSICS_HZ,
		"time_scale": TIME_SCALE,
		"conditions": {"tws_kn": 12.0, "wind_from_degrees": 180.0, "engine": "OFF", "wave_mode": "zero amplitude", "current_mps": [0, 0, 0], "auto_trim": true, "rudder_controller": "existing Polar PD"},
		"geometry_offset_m": H_GEO_Z_OFFSET_M,
	}
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSON.stringify(signature, "", true).to_utf8_buffer())
	return context.finish().hex_encode()


func _wait_for_batch(variant: String) -> void:
	var last_log_usec := 0
	while bool(_runner.get_status_snapshot().get("running", false)):
		await process_frame
		var snapshot: Dictionary = _runner.get_status_snapshot()
		var now := Time.get_ticks_usec()
		if now - last_log_usec >= 10000000:
			last_log_usec = now
			print("P2.14 progress · %s · sim %.0f s · SOG %.2f kn · TWA %+.1f° · rudder %+.1f°" % [
				variant, float(snapshot.get("simulation_seconds", 0.0)), float(snapshot.get("sog_kn", 0.0)), float(snapshot.get("measured_twa_deg", NAN)), float(snapshot.get("rudder_deg", NAN)),
			])


func _free_lab() -> void:
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	await process_frame
	_lab = null
	_boat = null
	_runner = null


func _sha256_file(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return "UNAVAILABLE"
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(file.get_buffer(file.get_length()))
	return context.finish().hex_encode()


func _write_text(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_error = "Could not write %s" % path
		return
	file.store_string(contents)


func _write_json(path: String, value: Variant) -> void:
	_write_text(path, JSON.stringify(value, "\t") + "\n")


func _csv_value(value: Variant) -> String:
	if value == null:
		return ""
	if (typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT) and not is_finite(float(value)):
		return ""
	var text := "%.8f" % float(value) if typeof(value) == TYPE_FLOAT else str(value)
	if text.contains(",") or text.contains("\"") or text.contains("\n"):
		text = "\"" + text.replace("\"", "\"\"") + "\""
	return text


func _finish(code: int, message: String = "") -> void:
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if not message.is_empty():
		push_error("[polar p2.14] " + message)
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
	await process_frame
	quit(code if _error.is_empty() else maxi(code, 1))


func _load_p25_results() -> Dictionary:
	if not FileAccess.file_exists(P25_RESULTS_PATH):
		return {}
	var document_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(P25_RESULTS_PATH))
	if not document_value is Dictionary:
		return {}
	var found := {"metadata": document_value.get("metadata", {})}
	for result_value in document_value.get("results", []):
		var result: Dictionary = result_value
		match str(result.get("case_id", "")):
			"p25_12kn_050twa_port": found["m50"] = result
			"p25_12kn_090twa_port": found["m90"] = result
	return found if found.has("m50") and found.has("m90") else {}
