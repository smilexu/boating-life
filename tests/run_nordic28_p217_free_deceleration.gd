extends SceneTree
## P2.17 isolated windless free-deceleration diagnostic for the P2.16 rig.
## Each speed is initialized once through the body's existing offline-test hook;
## thereafter only the solver and existing hydro forces change velocity.

const LAB_SCENE := preload("res://scenes/SailboatLabP216.tscn")
const EXPECTED_BOAT_SCENE := "res://scenes/boats/SailingBoat8mP216.tscn"
const PHYSICS_PROFILE_PATH := "res://resources/sailing/nordic28_p216_physics_profile.tres"
const OUTPUT_ROOT := "res://docs/sailing/polar_p217"
const PHYSICS_HZ := 480
const TIME_SCALE := 8.0
const EXPECTED_STEP_S := 1.0 / 60.0
const KNOTS_TO_MPS := 0.5144444444444445
const MPS_TO_KNOTS := 1.0 / KNOTS_TO_MPS
const SAMPLE_INTERVAL_S := 0.25
const DECEL_DURATION_S := 8.0
const CALM_MAX_S := 30.0
const CALM_REQUIRED_S := 3.0
const START_SPEEDS_KN := [2.0, 3.0, 4.0, 5.0, 6.0]
const SIGNATURE_FILES := [
	"res://scripts/sailboat_lab_body.gd",
	"res://scripts/sailboat_hydrodynamics.gd",
	"res://scripts/sailboat_aero_math.gd",
	"res://scripts/sailboat_buoyancy_math.gd",
	"res://scripts/wind_field.gd",
	"res://scripts/wave_sampler.gd",
	"res://scenes/SailboatLabP216.tscn",
	"res://scenes/boats/SailingBoat8mP216.tscn",
	PHYSICS_PROFILE_PATH,
	"res://resources/sea_waves.tres",
	"res://project.godot",
	"res://tests/run_nordic28_p217_free_deceleration.gd",
]
const CSV_FIELDS := [
	"test_run_id", "case_id", "boat_scene_path", "profile_path", "profile_sha256",
	"configuration_fingerprint", "initial_target_speed_kn", "sample_time_s", "physics_step_s",
	"longitudinal_speed_kn", "lateral_speed_mps", "hull_longitudinal_force_forward_n",
	"keel_forward_force_n", "rudder_forward_force_n", "sum_explicit_hydro_forward_force_n",
	"measured_longitudinal_acceleration_mps2", "measured_deceleration_mps2",
	"force_over_mass_acceleration_estimate_mps2", "wind_speed_mps", "sail_force_enabled",
	"engine_state", "wave_strength", "water_current_mps", "roll_deg", "pitch_deg",
	"yaw_rate_rad_s", "wave_queries_per_tick", "wind_queries_per_tick"
]

var _old_physics_hz := 60
var _old_time_scale := 1.0
var _run_id := ""
var _run_directory := ""
var _run_fingerprint := ""
var _profile_sha256 := ""
var _rows: Array[Dictionary] = []
var _summaries: Array[Dictionary] = []
var _errors: Array[String] = []
var _profile_values: Dictionary = {}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_old_physics_hz = Engine.physics_ticks_per_second
	_old_time_scale = Engine.time_scale
	var profile := load(PHYSICS_PROFILE_PATH) as Resource
	if profile == null:
		_finish(2, "P2.16 physics profile failed to load")
		return
	_profile_values = _profile_summary(profile)
	_profile_sha256 = FileAccess.get_sha256(PHYSICS_PROFILE_PATH)
	_run_id = "p217_%s_%d" % [Time.get_datetime_string_from_system(true).replace(":", "").replace("-", ""), Time.get_ticks_usec() % 1000000]
	_run_fingerprint = _make_fingerprint()
	_run_directory = OUTPUT_ROOT.path_join(_run_id)
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(_run_directory)):
		_finish(2, "Refusing to overwrite existing run directory %s" % _run_directory)
		return
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_run_directory)) != OK:
		_finish(2, "Could not create P2.17 output directory")
		return

	Engine.physics_ticks_per_second = PHYSICS_HZ
	Engine.time_scale = TIME_SCALE
	var manifest := _make_manifest(profile)
	if not _write_json(_run_directory.path_join("p217_run_manifest.json"), manifest):
		_finish(2, "Could not write P2.17 run manifest")
		return

	for target_speed_kn in START_SPEEDS_KN:
		var summary := await _run_speed_case(float(target_speed_kn))
		if summary.is_empty():
			break
		_summaries.append(summary)

	var ok := _errors.is_empty() and _summaries.size() == START_SPEEDS_KN.size()
	_write_csv(_run_directory.path_join("p217_free_deceleration.csv"), CSV_FIELDS, _rows)
	_write_json(_run_directory.path_join("p217_free_deceleration.json"), {
		"test_run_id": _run_id,
		"configuration_fingerprint": _run_fingerprint,
		"boat_scene_path": EXPECTED_BOAT_SCENE,
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"profile_sha256": _profile_sha256,
		"test_method": "Per condition, calm at zero velocity with static zero-amplitude WaveSampler and zero wind/current; set one initial forward local velocity through set_test_initial_linear_velocity_local, then allow free solver deceleration with sails disabled and engine off.",
		"simulated_physics_step_seconds": EXPECTED_STEP_S,
		"engine_physics_ticks_per_second": Engine.physics_ticks_per_second,
		"engine_time_scale": Engine.time_scale,
		"initial_speed_targets_kn": START_SPEEDS_KN,
		"summary_rows": _summaries,
		"timeseries_rows": _rows,
		"errors": _errors,
	})
	_write_json(_run_directory.path_join("p217_run_manifest.json"), _make_manifest(profile, ok, not ok))
	_finish(0 if ok else 1, "P2.17 free-deceleration completed %d/%d cases · run=%s · fingerprint=%s" % [_summaries.size(), START_SPEEDS_KN.size(), _run_id, _run_fingerprint])


func _run_speed_case(target_speed_kn: float) -> Dictionary:
	var lab := LAB_SCENE.instantiate() as Node3D
	var boat := lab.get_node_or_null("SailboatBody") as RigidBody3D
	var wind := lab.get_node_or_null("WindField")
	var waves := lab.get_node_or_null("WaveSampler")
	if boat == null or wind == null or waves == null or boat.scene_file_path != EXPECTED_BOAT_SCENE:
		_errors.append("%.1f kn: P2.16 SailboatLab fixture does not contain expected boat/wind/wave nodes" % target_speed_kn)
		lab.free()
		return {}
	root.add_child(lab)
	await process_frame
	await process_frame
	if boat.get("profile") == null or boat.get("profile").resource_path != PHYSICS_PROFILE_PATH:
		_errors.append("%.1f kn: runtime boat did not load the protected P2.16 physics profile" % target_speed_kn)
		lab.queue_free()
		await process_frame
		return {}

	waves.set("wave_strength", 0.0)
	boat.call("set_dynamic_waves_enabled", true)
	boat.call("set_water_current_world_velocity", Vector3.ZERO)
	boat.call("set_keyboard_controls_enabled", false)
	boat.call("set_sail_forces_enabled_for_lab_test", false)
	boat.call("set_auto_sail_trim_enabled", false)
	if boat.has_method("set_lab_test_wind"):
		boat.call("set_lab_test_wind", 0.0, 0.0)
	else:
		_errors.append("%.1f kn: test wind override is unavailable" % target_speed_kn)
		lab.queue_free()
		await process_frame
		return {}
	wind.call("set_random_seed", 217)
	wind.call("set_gust_parameters", 0.0, 24.0, 450.0)
	wind.set("gust_direction_variation_degrees", 0.0)
	wind.call("set_test_simulation_time", 0.0)
	boat.call("set_auxiliary_engine_target_throttle", 0.0)
	boat.call("set_auxiliary_engine_gear", 0)
	boat.call("stop_auxiliary_engine")
	boat.call("reset_to_neutral", 0.0)
	boat.sleeping = false
	var calm := await _wait_until_calm(boat)
	if not bool(calm.get("ok", false)):
		_errors.append("%.1f kn: boat did not settle before initial-speed injection (%s)" % [target_speed_kn, str(calm.get("reason", "unknown"))])
		lab.queue_free()
		await process_frame
		return {}

	var target_speed_mps := target_speed_kn * KNOTS_TO_MPS
	boat.call("set_test_initial_linear_velocity_local", Vector3(0.0, 0.0, -target_speed_mps))
	boat.sleeping = false
	var sim_time_s := 0.0
	var sample_accumulator_s := 0.0
	var previous_sample_speed_mps := NAN
	var previous_sample_time_s := NAN
	var observed_initial_speed_kn := NAN
	var sample_count := 0
	var first_step_verified := false
	while sim_time_s < DECEL_DURATION_S:
		await physics_frame
		var debug: Dictionary = boat.call("get_debug_snapshot")
		var step_s := float(debug.get("physics_delta_s", NAN))
		if not is_finite(step_s) or absf(step_s - EXPECTED_STEP_S) > 0.0005:
			_errors.append("%.1f kn: observed physics step %s differs from 1/60 s" % [target_speed_kn, str(step_s)])
			break
		var is_first_physics_sample := not first_step_verified
		sim_time_s += step_s
		sample_accumulator_s += step_s
		if not first_step_verified:
			var applied_initial: Vector3 = debug.get("test_initial_velocity_applied_local_mps", Vector3.ZERO)
			if not applied_initial.is_equal_approx(Vector3(0.0, 0.0, -target_speed_mps)):
				_errors.append("%.1f kn: test initial velocity hook applied %s, expected local -Z %s" % [target_speed_kn, str(applied_initial), str(Vector3(0.0, 0.0, -target_speed_mps))])
				break
			first_step_verified = true
		if not is_first_physics_sample and sample_accumulator_s + 0.00001 < SAMPLE_INTERVAL_S:
			continue
		sample_accumulator_s = 0.0
		var local_velocity := boat.global_basis.inverse() * boat.linear_velocity
		var forward_speed_mps := -local_velocity.z
		if not is_finite(forward_speed_mps) or not _snapshot_is_finite(debug):
			_errors.append("%.1f kn: non-finite velocity or resistance telemetry" % target_speed_kn)
			break
		if is_nan(observed_initial_speed_kn):
			observed_initial_speed_kn = forward_speed_mps * MPS_TO_KNOTS
		var longitudinal_acceleration := 0.0
		if is_finite(previous_sample_speed_mps) and is_finite(previous_sample_time_s):
			var sample_delta := sim_time_s - previous_sample_time_s
			if sample_delta > 0.0:
				longitudinal_acceleration = (forward_speed_mps - previous_sample_speed_mps) / sample_delta
		var hull_force: Vector3 = debug.get("hull_drag_force_local_n", Vector3.ZERO)
		var keel_force: Vector3 = debug.get("keel_force_local_n", Vector3.ZERO)
		var rudder_force: Vector3 = debug.get("rudder_force_local_n", Vector3.ZERO)
		var hull_forward_n := -hull_force.z
		var keel_forward_n := -keel_force.z
		var rudder_forward_n := -rudder_force.z
		var sum_forward_n := hull_forward_n + keel_forward_n + rudder_forward_n
		var mass_kg := float(debug.get("mass_kg", NAN))
		var engine_snapshot: Dictionary = debug.get("auxiliary_engine", {})
		var engine_running := bool(engine_snapshot.get("running", true))
		var engine_state := "RUNNING" if engine_running else "OFF"
		if engine_running or Vector3(debug.get("engine_force_local_n", Vector3.ZERO)).length() > 0.001:
			_errors.append("%.1f kn: engine was not OFF or its force was nonzero during deceleration" % target_speed_kn)
			break
		if bool(debug.get("effective_sail_forces_enabled", true)) or float(debug.get("true_wind_speed_mps", NAN)) > 0.0001:
			_errors.append("%.1f kn: sail forces or wind remained enabled" % target_speed_kn)
			break
		var row := {
			"test_run_id": _run_id,
			"case_id": "p217_free_%.1fkn" % target_speed_kn,
			"boat_scene_path": EXPECTED_BOAT_SCENE,
			"profile_path": PHYSICS_PROFILE_PATH,
			"profile_sha256": _profile_sha256,
			"configuration_fingerprint": _run_fingerprint,
			"initial_target_speed_kn": target_speed_kn,
			"sample_time_s": sim_time_s,
			"physics_step_s": step_s,
			"longitudinal_speed_kn": forward_speed_mps * MPS_TO_KNOTS,
			"lateral_speed_mps": local_velocity.x,
			"hull_longitudinal_force_forward_n": hull_forward_n,
			"keel_forward_force_n": keel_forward_n,
			"rudder_forward_force_n": rudder_forward_n,
			"sum_explicit_hydro_forward_force_n": sum_forward_n,
			"measured_longitudinal_acceleration_mps2": longitudinal_acceleration,
			"measured_deceleration_mps2": -longitudinal_acceleration,
			"force_over_mass_acceleration_estimate_mps2": sum_forward_n / mass_kg if mass_kg > 0.0 else NAN,
			"wind_speed_mps": float(debug.get("true_wind_speed_mps", NAN)),
			"sail_force_enabled": bool(debug.get("effective_sail_forces_enabled", true)),
			"engine_state": engine_state,
			"wave_strength": float(waves.get("wave_strength")),
			"water_current_mps": Vector3(debug.get("water_current_world_mps", Vector3(NAN, NAN, NAN))).length(),
			"roll_deg": float(debug.get("roll_degrees", NAN)),
			"pitch_deg": float(debug.get("pitch_degrees", NAN)),
			"yaw_rate_rad_s": float(debug.get("yaw_rate_rad_s", NAN)),
			"wave_queries_per_tick": int(debug.get("wave_query_count_per_tick", -1)),
			"wind_queries_per_tick": int(debug.get("wind_query_count_per_tick", -1)),
		}
		_rows.append(row)
		sample_count += 1
		previous_sample_speed_mps = forward_speed_mps
		previous_sample_time_s = sim_time_s
		if forward_speed_mps <= 0.05:
			break

	var case_rows: Array[Dictionary] = []
	for row in _rows:
		if str(row.get("case_id", "")) == "p217_free_%.1fkn" % target_speed_kn:
			case_rows.append(row)
	if not first_step_verified or case_rows.is_empty():
		if _errors.is_empty():
			_errors.append("%.1f kn: no deceleration samples were captured" % target_speed_kn)
		lab.queue_free()
		await process_frame
		return {}
	var first_second_rows: Array[Dictionary] = []
	for row in case_rows:
		if float(row["sample_time_s"]) <= 1.25:
			first_second_rows.append(row)
	var regression := _speed_slope(first_second_rows)
	var initial_hull_force := _mean_field(first_second_rows, "hull_longitudinal_force_forward_n")
	var initial_keel_force := _mean_field(first_second_rows, "keel_forward_force_n")
	var initial_rudder_force := _mean_field(first_second_rows, "rudder_forward_force_n")
	var summary := {
		"case_id": "p217_free_%.1fkn" % target_speed_kn,
		"status": "COMPLETE",
		"initial_target_speed_kn": target_speed_kn,
		"first_physics_step_longitudinal_speed_kn": observed_initial_speed_kn,
		"sample_count": sample_count,
		"last_sample_time_s": float(case_rows.back()["sample_time_s"]),
		"first_1_25s_linear_speed_slope_mps2": regression,
		"first_1_25s_deceleration_mps2": -regression,
		"first_1_25s_mean_hull_resistance_forward_n": initial_hull_force,
		"first_1_25s_mean_keel_forward_force_n": initial_keel_force,
		"first_1_25s_mean_rudder_forward_force_n": initial_rudder_force,
		"first_1_25s_mean_sum_explicit_hydro_forward_force_n": initial_hull_force + initial_keel_force + initial_rudder_force,
		"last_longitudinal_speed_kn": float(case_rows.back()["longitudinal_speed_kn"]),
		"last_roll_deg": float(case_rows.back()["roll_deg"]),
		"last_pitch_deg": float(case_rows.back()["pitch_deg"]),
		"wind_speed_mps": 0.0,
		"sails_enabled": false,
		"engine_state": "OFF",
		"wave_strength": 0.0,
		"water_current_mps": 0.0,
	}
	lab.queue_free()
	await process_frame
	return summary


func _wait_until_calm(boat: RigidBody3D) -> Dictionary:
	var elapsed := 0.0
	var calm_for := 0.0
	while elapsed < CALM_MAX_S:
		await physics_frame
		var debug: Dictionary = boat.call("get_debug_snapshot")
		var step_s := float(debug.get("physics_delta_s", NAN))
		if not is_finite(step_s) or absf(step_s - EXPECTED_STEP_S) > 0.0005:
			return {"ok": false, "reason": "physics step mismatch %s" % str(step_s)}
		elapsed += step_s
		var linear_speed := Vector3(debug.get("linear_velocity_mps", Vector3.ZERO)).length()
		var angular_speed := Vector3(debug.get("angular_velocity_rad_s", Vector3.ZERO)).length()
		if linear_speed < 0.06 and angular_speed < 0.02 and not bool(debug.get("pose_command_pending", false)):
			calm_for += step_s
		else:
			calm_for = 0.0
		if calm_for >= CALM_REQUIRED_S:
			return {"ok": true, "elapsed_simulation_s": elapsed, "calm_duration_s": calm_for}
	return {"ok": false, "reason": "exceeded %.1f simulation seconds without %.1f seconds below velocity thresholds" % [CALM_MAX_S, CALM_REQUIRED_S]}


func _snapshot_is_finite(debug: Dictionary) -> bool:
	for key in ["true_wind_speed_mps", "mass_kg", "physics_delta_s", "yaw_rate_rad_s", "roll_degrees", "pitch_degrees"]:
		if not is_finite(float(debug.get(key, NAN))):
			return false
	for key in ["hull_drag_force_local_n", "keel_force_local_n", "rudder_force_local_n", "linear_velocity_mps", "water_current_world_mps"]:
		var value: Variant = debug.get(key, Vector3(NAN, NAN, NAN))
		if not value is Vector3 or not _finite_vector(value):
			return false
	return true


func _finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _speed_slope(rows: Array[Dictionary]) -> float:
	if rows.size() < 2:
		return NAN
	var mean_time := 0.0
	var mean_speed := 0.0
	for row in rows:
		mean_time += float(row["sample_time_s"])
		mean_speed += float(row["longitudinal_speed_kn"]) * KNOTS_TO_MPS
	mean_time /= float(rows.size())
	mean_speed /= float(rows.size())
	var numerator := 0.0
	var denominator := 0.0
	for row in rows:
		var time_delta := float(row["sample_time_s"]) - mean_time
		numerator += time_delta * (float(row["longitudinal_speed_kn"]) * KNOTS_TO_MPS - mean_speed)
		denominator += time_delta * time_delta
	return numerator / denominator if denominator > 0.0 else NAN


func _mean_field(rows: Array[Dictionary], field: String) -> float:
	if rows.is_empty():
		return NAN
	var total := 0.0
	for row in rows:
		total += float(row.get(field, NAN))
	return total / float(rows.size())


func _profile_summary(profile: Resource) -> Dictionary:
	var result := {}
	for property_value in profile.get_property_list():
		var property: Dictionary = property_value
		if (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var name := str(property.get("name", ""))
		if name in ["script", "resource_local_to_scene", "resource_path", "resource_name"]:
			continue
		result[name] = var_to_str(profile.get(name))
	return result


func _make_fingerprint() -> String:
	var hasher := HashingContext.new()
	hasher.start(HashingContext.HASH_SHA256)
	hasher.update(JSON.stringify(_profile_values, "", true).to_utf8_buffer())
	for path in SIGNATURE_FILES:
		hasher.update(path.to_utf8_buffer())
		hasher.update(FileAccess.get_file_as_bytes(path))
	hasher.update(JSON.stringify({
		"physics_ticks_per_second": PHYSICS_HZ,
		"time_scale": TIME_SCALE,
		"expected_step_seconds": EXPECTED_STEP_S,
		"sample_interval_seconds": SAMPLE_INTERVAL_S,
		"duration_seconds": DECEL_DURATION_S,
		"calm_max_seconds": CALM_MAX_S,
		"calm_required_seconds": CALM_REQUIRED_S,
		"initial_speeds_kn": START_SPEEDS_KN,
		"sails_enabled": false,
		"engine_state": "OFF",
		"wind_mps": 0.0,
		"wave_strength": 0.0,
		"water_current_mps": 0.0,
	}, "", true).to_utf8_buffer())
	return hasher.finish().hex_encode()


func _make_manifest(profile: Resource, complete := false, failed := false) -> Dictionary:
	var source_hashes := {}
	for path in SIGNATURE_FILES:
		source_hashes[path] = FileAccess.get_sha256(path)
	return {
		"test_run_id": _run_id,
		"status": "COMPLETE" if complete else ("FAILED" if failed else "RUNNING"),
		"failure_reasons": _errors,
		"created_at": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info(),
		"boat_scene_path": EXPECTED_BOAT_SCENE,
		"sailboat_lab_scene_path": "res://scenes/SailboatLabP216.tscn",
		"physics_profile_path": PHYSICS_PROFILE_PATH,
		"profile_sha256": _profile_sha256,
		"configuration_fingerprint": _run_fingerprint,
		"configuration_fingerprint_inputs": SIGNATURE_FILES,
		"source_sha256": source_hashes,
		"physical_profile_values": _profile_values,
		"simulation": {
			"physics_ticks_per_second": PHYSICS_HZ,
			"time_scale": TIME_SCALE,
			"observed_fixed_physics_step_seconds": EXPECTED_STEP_S,
			"initial_velocity_local_mps": "(0, 0, -target_speed_mps), applied once before the force solver step",
			"initial_speed_targets_kn": START_SPEEDS_KN,
			"free_run_duration_seconds": DECEL_DURATION_S,
			"sample_interval_seconds": SAMPLE_INTERVAL_S,
			"calm_gate": {"maximum_seconds": CALM_MAX_S, "required_duration_seconds": CALM_REQUIRED_S, "linear_speed_below_mps": 0.06, "angular_speed_below_rad_s": 0.02},
			"water_current_mps": 0.0,
			"wind_speed_mps": 0.0,
			"wave_sampler_strength": 0.0,
			"wave_sampler_and_buoyancy_enabled": true,
			"sail_forces_enabled": false,
			"engine_state": "OFF",
			"rudder_target": "neutral from reset_to_neutral",
		},
		"force_sign_convention": "Forward is local -Z. forward force component = -local_force.z; negative means resistance.",
		"measured_deceleration_method": "Ordinary least-squares slope of sampled body-local forward speed over first 1.25 simulation seconds; includes a sample on the first physics step after one-time initial velocity injection, then samples every 0.25 simulated seconds. Instantaneous sample acceleration is finite difference between samples.",
		"source_p2_16_results_reused_without_rerun": "res://docs/sailing/polar_p216/p216_results.json",
		"results_directory": _run_directory,
	}


func _write_csv(path: String, fields: Array, rows: Array[Dictionary]) -> bool:
	var lines := PackedStringArray([",".join(PackedStringArray(fields))])
	for row in rows:
		var cells := PackedStringArray()
		for field in fields:
			cells.append(_csv_value(row.get(field, "")))
		lines.append(",".join(cells))
	return _write_text(path, "\n".join(lines) + "\n")


func _csv_value(value: Variant) -> String:
	if value is bool:
		return "true" if value else "false"
	var text := str(value)
	if text.contains(",") or text.contains("\"") or text.contains("\n"):
		return "\"%s\"" % text.replace("\"", "\"\"")
	return text


func _write_json(path: String, value: Variant) -> bool:
	return _write_text(path, JSON.stringify(value, "\t") + "\n")


func _write_text(path: String, content: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(content)
	file.close()
	return true


func _finish(exit_code: int, message := "") -> void:
	Engine.physics_ticks_per_second = _old_physics_hz
	Engine.time_scale = _old_time_scale
	if not message.is_empty():
		print(message)
	if not _errors.is_empty():
		for error in _errors:
			push_error(error)
	quit(exit_code)
