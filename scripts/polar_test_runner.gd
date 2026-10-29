extends Node
class_name PolarTestRunner
## Offline test runner for the real SailboatLab rigid body. It actuates only the
## vessel's normal rudder and AUTO Trim interfaces; it never writes pose/speed
## after case initialization.

signal boat_scene_change_requested(scene_path: String)
signal progress_changed(snapshot: Dictionary)
signal test_run_finished(snapshot: Dictionary)

const TEST_MATH := preload("res://scripts/polar_test_math.gd")
const STABILITY := preload("res://scripts/polar_stability_detector.gd")
const EXPORTER := preload("res://scripts/polar_data_exporter.gd")
const DEFAULT_PROFILE := preload("res://resources/sailing/polar_test_profile.tres")
const KNOTS_TO_MPS := 0.5144444444444445
const SAMPLES_PER_SIM_SECOND := 1.0
const ENGINE_NEUTRAL := 0
const SIGNATURE_SCRIPT_PATHS := [
	"res://scripts/sailboat_lab_body.gd",
	"res://scripts/sailboat_aero_math.gd",
	"res://scripts/sailboat_hydrodynamics.gd",
	"res://scripts/sailboat_buoyancy_math.gd",
	"res://scripts/sailboat_auto_sail_trim.gd",
	"res://scripts/auxiliary_marine_engine.gd",
	"res://scripts/sailboat_navigation_math.gd",
	"res://scripts/wind_field.gd",
	"res://scripts/wave_sampler.gd",
	"res://scripts/polar_test_math.gd",
	"res://scripts/polar_test_profile.gd",
	"res://scripts/polar_stability_detector.gd",
	"res://scripts/polar_data_exporter.gd",
	"res://scripts/polar_test_runner.gd",
	"res://scripts/polar_p22_experiment_profile.gd",
]

@export var profile: Resource = DEFAULT_PROFILE
@export_node_path("Node3D") var boat_path: NodePath = ^"../SailboatBody"
@export_node_path("Node") var wind_field_path: NodePath = ^"../WindField"
@export_node_path("Node") var wave_sampler_path: NodePath = ^"../WaveSampler"

var _boat: Node3D
var _wind: WindField
var _wave_sampler: WaveSampler
var _selected_boat_scene_path := ""
var _running := false
var _stop_requested := false
var _run_id := ""
var _run_directory := ""
var _run_metadata: Dictionary = {}
var _active_config: Dictionary = {}
var _config_hash := ""
var _cases: Array[Dictionary] = []
var _results: Array[Dictionary] = []
var _results_by_case_id: Dictionary = {}
var _case_index := 0
var _current_case: Dictionary = {}
var _current_sim_time_s := 0.0
var _case_wall_started_usec := 0
var _stability_first_qualified_sim_s := -1.0
var _last_observed_physics_step_s := 0.0
var _maximum_physics_step_error_s := 0.0
var _current_samples: Array[Dictionary] = []
var _previous_telemetry_rudder_deg := NAN
var _previous_telemetry_sample_time_s := NAN
var _last_controller_error_deg := 0.0
var _last_controller_compass_yaw_rate_deg_s := 0.0
var _last_controller_pid_unclamped_deg := 0.0
var _last_controller_command_deg := 0.0
var _last_ui_snapshot: Dictionary = {}
var _saved_wind: Dictionary = {}
var _saved_wave_strength := 1.0
var _saved_dynamic_waves := true
var _saved_keyboard_controls := true
var _saved_auto_trim := false
var _environment_captured := false
var _last_checkpoint_path := ""


func _ready() -> void:
	_boat = get_node_or_null(boat_path) as Node3D
	_wind = get_node_or_null(wind_field_path) as WindField
	_wave_sampler = get_node_or_null(wave_sampler_path) as WaveSampler
	if profile == null:
		profile = DEFAULT_PROFILE
	var paths: PackedStringArray = profile.get("boat_scene_paths")
	if not paths.is_empty():
		_selected_boat_scene_path = paths[0]
	if _boat != null and _boat.has_method("get_scene_file_path"):
		var current_scene_path := _boat.scene_file_path
		if not current_scene_path.is_empty():
			_selected_boat_scene_path = current_scene_path
	_refresh_status("就绪 · 仅运行用户选择的工况")


func get_available_boat_scene_paths() -> PackedStringArray:
	return profile.get("boat_scene_paths") if profile != null else PackedStringArray()


func get_selected_boat_scene_path() -> String:
	return _selected_boat_scene_path


func get_last_output_path() -> String:
	return _last_checkpoint_path


func get_status_snapshot() -> Dictionary:
	var result := _last_ui_snapshot.duplicate(true)
	result["running"] = _running
	result["stop_requested"] = _stop_requested
	result["test_run_id"] = _run_id
	result["boat_scene_path"] = _selected_boat_scene_path
	var completed := 0
	for row in _results_by_case_id.values():
		if str(row.get("status", "")) != "INTERRUPTED":
			completed += 1
	result["completed_count"] = completed
	result["case_count"] = _cases.size()
	result["case_index"] = _case_index
	result["simulation_seconds"] = _current_sim_time_s
	result["output_path"] = _last_checkpoint_path
	return result


func set_boat_instance(boat: Node3D) -> void:
	_boat = boat
	if _boat != null and not _boat.scene_file_path.is_empty():
		_selected_boat_scene_path = _boat.scene_file_path
	_refresh_status("船型已切换：%s" % _boat_name())


func select_boat_scene(path: String) -> bool:
	if _running:
		_refresh_status("测试运行中，不能切换船型")
		return false
	if not get_available_boat_scene_paths().has(path) or not ResourceLoader.exists(path):
		_refresh_status("船型路径无效或未登记：%s" % path)
		return false
	if path == _selected_boat_scene_path:
		return true
	boat_scene_change_requested.emit(path)
	return _selected_boat_scene_path == path


func start_new_batch(ui_config: Dictionary = {}) -> bool:
	if _running:
		return false
	var validation := _validate_setup()
	if not bool(validation["ok"]):
		_refresh_status(str(validation["reason"]))
		return false
	_active_config = _make_config(ui_config)
	_cases = _build_cases(_active_config)
	if _cases.is_empty():
		_refresh_status("没有可运行工况，请检查风速、TWA 和舷侧选择")
		return false
	_config_hash = _calculate_config_hash(_active_config)
	_run_id = _new_run_id()
	_run_directory = EXPORTER.create_run_directory(_run_id)
	_run_metadata = _make_run_metadata()
	_results.clear()
	_results_by_case_id.clear()
	_case_index = 0
	_last_checkpoint_path = _run_directory.path_join("polar_checkpoint.json")
	if not _capture_environment():
		return false
	_running = true
	_stop_requested = false
	_refresh_status("批次开始 · %d 个工况" % _cases.size())
	call_deferred("_execute_batch")
	return true


func resume_latest(ui_config: Dictionary = {}) -> bool:
	if _running:
		return false
	var loaded := EXPORTER.load_latest_checkpoint()
	if not bool(loaded.get("ok", false)):
		_refresh_status(str(loaded.get("reason", "找不到 checkpoint")))
		return false
	var checkpoint: Dictionary = loaded["data"]
	var requested_config := _make_config(ui_config)
	var requested_hash := _calculate_config_hash(requested_config)
	if str(checkpoint.get("config_hash", "")) != requested_hash:
		_refresh_status("恢复被拒绝：船型、物理配置或测试条件与 checkpoint 不一致")
		return false
	if str(checkpoint.get("boat_scene_path", "")) != _selected_boat_scene_path:
		_refresh_status("恢复被拒绝：checkpoint 船型与当前选择不同")
		return false
	_active_config = requested_config
	_cases = _decode_dictionary_array(checkpoint.get("cases", []))
	_results = _decode_dictionary_array(checkpoint.get("results", []))
	_results_by_case_id.clear()
	for row in _results:
		_results_by_case_id[str(row.get("case_id", ""))] = row
	_run_id = str(checkpoint.get("test_run_id", ""))
	_run_directory = str(checkpoint.get("run_directory", ""))
	_last_checkpoint_path = str(loaded.get("checkpoint_path", ""))
	_run_metadata = checkpoint.get("run_metadata", _make_run_metadata())
	_config_hash = requested_hash
	_case_index = clampi(int(checkpoint.get("next_case_index", 0)), 0, _cases.size())
	_skip_completed_cases()
	if _case_index >= _cases.size():
		_refresh_status("checkpoint 中没有待继续的工况")
		return false
	if not _capture_environment():
		return false
	_running = true
	_stop_requested = false
	_refresh_status("从 checkpoint 恢复 · 工况 %d/%d" % [_case_index + 1, _cases.size()])
	call_deferred("_execute_batch")
	return true


func retry_failed_latest(ui_config: Dictionary = {}) -> bool:
	if _running:
		return false
	var loaded := EXPORTER.load_latest_checkpoint()
	if not bool(loaded.get("ok", false)):
		_refresh_status(str(loaded.get("reason", "找不到 checkpoint")))
		return false
	var checkpoint: Dictionary = loaded["data"]
	var requested_config := _make_config(ui_config)
	var requested_hash := _calculate_config_hash(requested_config)
	if str(checkpoint.get("config_hash", "")) != requested_hash or str(checkpoint.get("boat_scene_path", "")) != _selected_boat_scene_path:
		_refresh_status("重跑被拒绝：当前配置与 checkpoint 不一致")
		return false
	_active_config = requested_config
	_cases = _decode_dictionary_array(checkpoint.get("cases", []))
	_results = _decode_dictionary_array(checkpoint.get("results", []))
	_results_by_case_id.clear()
	for row in _results:
		_results_by_case_id[str(row.get("case_id", ""))] = row
	var has_failures := false
	for test_case in _cases:
		var row: Dictionary = _results_by_case_id.get(str(test_case["case_id"]), {})
		if str(row.get("status", "")) in ["UNSTABLE", "HEADING_FAILED", "TIMEOUT", "INVALID"]:
			_results_by_case_id.erase(str(test_case["case_id"]))
			has_failures = true
	if not has_failures:
		_refresh_status("没有可重跑的失败工况")
		return false
	_rebuild_results_array()
	_case_index = 0
	_run_id = str(checkpoint.get("test_run_id", ""))
	_run_directory = str(checkpoint.get("run_directory", ""))
	_last_checkpoint_path = str(loaded.get("checkpoint_path", ""))
	_run_metadata = checkpoint.get("run_metadata", _make_run_metadata())
	_config_hash = requested_hash
	if not _capture_environment():
		return false
	_running = true
	_stop_requested = false
	_refresh_status("重跑失败工况 · %d 个" % _cases.size())
	call_deferred("_execute_batch")
	return true


func request_stop() -> void:
	if _running:
		_stop_requested = true
		_refresh_status("正在安全中断当前工况…")


func _execute_batch() -> void:
	while _case_index < _cases.size():
		var test_case: Dictionary = _cases[_case_index]
		var previous_result: Dictionary = _results_by_case_id.get(str(test_case["case_id"]), {})
		if not previous_result.is_empty() and str(previous_result.get("status", "")) != "INTERRUPTED":
			_case_index += 1
			continue
		_current_case = test_case
		var result: Dictionary = await _execute_case(test_case)
		_results_by_case_id[str(test_case["case_id"])] = result
		_rebuild_results_array()
		if str(result.get("status", "")) == "INTERRUPTED":
			_persist_checkpoint(_case_index)
			break
		_case_index += 1
		_persist_checkpoint(_case_index)
		progress_changed.emit(get_status_snapshot())
	_restore_environment()
	_running = false
	_stop_requested = false
	var end_text := "已安全中断，可从 checkpoint 恢复" if _case_index < _cases.size() else "批次完成"
	_refresh_status(end_text)
	test_run_finished.emit(get_status_snapshot())


func _execute_case(test_case: Dictionary) -> Dictionary:
	_current_sim_time_s = 0.0
	_case_wall_started_usec = Time.get_ticks_usec()
	_stability_first_qualified_sim_s = -1.0
	_last_observed_physics_step_s = 0.0
	_maximum_physics_step_error_s = 0.0
	_current_samples.clear()
	_previous_telemetry_rudder_deg = NAN
	_previous_telemetry_sample_time_s = NAN
	_last_controller_error_deg = 0.0
	_last_controller_compass_yaw_rate_deg_s = 0.0
	_last_controller_pid_unclamped_deg = 0.0
	_last_controller_command_deg = 0.0
	var target_twa := float(test_case["target_twa_deg"])
	var target_heading := TEST_MATH.target_heading_degrees(float(_active_config["wind_from_degrees"]), target_twa)
	if not await _prepare_case(test_case, target_heading):
		return _make_result(test_case, "INVALID", "test fixture could not configure its local wind/wave/body state", {})
	var sample_accumulator := 0.0
	var stable_collection_start := -1.0
	var timeout_s := float(_active_config["case_timeout_seconds"])
	var window_size := maxi(2, int(ceil(float(_active_config["stability_window_seconds"]) / SAMPLES_PER_SIM_SECOND)))
	var sample_window_s := float(_active_config["sample_window_seconds"])
	var status := "TIMEOUT"
	var reason := "case reached configured simulation timeout"
	var final_metrics: Dictionary = {}
	var heading_failure_started_sim_s := -1.0
	while _current_sim_time_s < timeout_s:
		await get_tree().physics_frame
		if _boat == null or not is_instance_valid(_boat):
			status = "INVALID"
			reason = "selected boat instance disappeared during test"
			break
		var debug: Dictionary = _boat.call("get_debug_snapshot")
		var step_s := float(debug.get("physics_delta_s", 0.0))
		if not is_finite(step_s) or step_s <= 0.0 or absf(step_s - float(profile.get("fixed_physics_step_seconds"))) > 0.0005:
			status = "INVALID"
			reason = "observed physics step is invalid or differs from configured fixed step"
			break
		_last_observed_physics_step_s = step_s
		_maximum_physics_step_error_s = maxf(_maximum_physics_step_error_s, absf(step_s - float(profile.get("fixed_physics_step_seconds"))))
		_current_sim_time_s += step_s
		_apply_heading_controller(target_heading)
		sample_accumulator += step_s
		if sample_accumulator >= SAMPLES_PER_SIM_SECOND:
			sample_accumulator -= SAMPLES_PER_SIM_SECOND
			var sample := _sample_state(target_heading, target_twa)
			_current_samples.append(sample)
			if not _sample_is_finite(sample):
				status = "INVALID"
				reason = "non-finite navigation or force value captured"
				break
			var elapsed_samples := float(_current_samples.size())
			if elapsed_samples >= float(_active_config["minimum_warmup_seconds"]) and _current_samples.size() >= window_size:
				var recent := _tail_samples(_current_samples, window_size)
				var evaluation := STABILITY.evaluate(recent, _active_config, target_twa)
				if bool(evaluation.get("stable", false)):
					heading_failure_started_sim_s = -1.0
					if stable_collection_start < 0.0:
						stable_collection_start = _current_sim_time_s
						_stability_first_qualified_sim_s = _current_sim_time_s
					elif _current_sim_time_s - stable_collection_start >= sample_window_s:
						status = "STABLE"
						reason = "stability window and post-stability sample window completed"
						final_metrics = STABILITY.evaluate(_tail_samples(_current_samples, int(sample_window_s)), _active_config, target_twa).get("metrics", {})
						break
				elif bool(evaluation.get("no_forward_progress", false)) and _heading_metrics_acceptable(evaluation.get("metrics", {})):
					heading_failure_started_sim_s = -1.0
					if stable_collection_start < 0.0:
						stable_collection_start = _current_sim_time_s
						_stability_first_qualified_sim_s = _current_sim_time_s
					elif _current_sim_time_s - stable_collection_start >= sample_window_s:
						status = "NO_FORWARD_PROGRESS"
						reason = str(evaluation.get("reason", "heading held but no forward progress"))
						final_metrics = evaluation.get("metrics", {})
						break
				elif bool(evaluation.get("heading_failed", false)):
					stable_collection_start = -1.0
					if heading_failure_started_sim_s < 0.0:
						heading_failure_started_sim_s = _current_sim_time_s
					elif STABILITY.heading_failure_persisted(
						heading_failure_started_sim_s,
						_current_sim_time_s,
						float(_active_config["stability_window_seconds"])
					):
						status = "HEADING_FAILED"
						reason = "%s; persisted for the full heading-failure confirmation window" % str(evaluation.get("reason", "target TWA not held"))
						final_metrics = evaluation.get("metrics", {})
						break
				elif bool(evaluation.get("no_forward_progress", false)):
					stable_collection_start = -1.0
					heading_failure_started_sim_s = -1.0
				else:
					stable_collection_start = -1.0
					heading_failure_started_sim_s = -1.0
			_update_live_status(test_case)
			if _stop_requested:
				status = "INTERRUPTED"
				reason = "user requested safe interruption; this case will be rerun on resume"
				break
	if status == "TIMEOUT" and not _current_samples.is_empty():
		var ending_samples := _tail_samples(_current_samples, window_size)
		var ending_evaluation := STABILITY.evaluate(ending_samples, _active_config, target_twa)
		final_metrics = ending_evaluation.get("metrics", {})
		if bool(ending_evaluation.get("heading_failed", false)):
			status = "HEADING_FAILED"
			reason = str(ending_evaluation.get("reason", reason))
		elif bool(ending_evaluation.get("no_forward_progress", false)):
			status = "NO_FORWARD_PROGRESS"
			reason = str(ending_evaluation.get("reason", reason))
		elif _current_samples.size() >= window_size:
			status = "UNSTABLE"
			reason = str(ending_evaluation.get("reason", reason))
	if final_metrics.is_empty() and not _current_samples.is_empty():
		final_metrics = STABILITY.evaluate(_tail_samples(_current_samples, mini(window_size, _current_samples.size())), _active_config, target_twa).get("metrics", {})
	return _make_result(test_case, status, reason, final_metrics)


func _prepare_case(test_case: Dictionary, target_heading_degrees: float) -> bool:
	if _boat == null or _wind == null or _wave_sampler == null:
		return false
	if not _boat.has_method("set_lab_test_wind") or not bool(_boat.call("set_lab_test_wind", float(test_case["target_tws_kn"]) * KNOTS_TO_MPS, float(_active_config["wind_from_degrees"]))):
		return false
	_wind.set_random_seed(int(_active_config["fixed_wind_seed"]))
	_wind.set_gust_parameters(0.0, 24.0, 450.0)
	_wind.set("gust_direction_variation_degrees", 0.0)
	_wind.set_test_simulation_time(0.0)
	_wave_sampler.wave_strength = 0.0 if str(_active_config.get("wave_mode", "zero_amplitude")) == "zero_amplitude" else _saved_wave_strength
	if _boat.has_method("set_dynamic_waves_enabled"):
		_boat.call("set_dynamic_waves_enabled", true)
	if _boat.has_method("set_water_current_world_velocity"):
		_boat.call("set_water_current_world_velocity", Vector3.ZERO)
	if _boat.has_method("set_keyboard_controls_enabled"):
		_boat.call("set_keyboard_controls_enabled", false)
	_stop_engine()
	_boat.call("reset_to_neutral", -target_heading_degrees)
	_boat.call("set_target_rudder_angle", 0.0)
	_boat.call("set_target_sail_angle", 0.0)
	_boat.call("set_target_headsail_angle", 0.0)
	_boat.set("p22_extended_telemetry_enabled", bool(_active_config.get("include_extended_telemetry", false)))
	_boat.set("actual_rudder_angle_rad", 0.0)
	_boat.set("actual_sail_angle_rad", 0.0)
	_boat.set("actual_headsail_angle_rad", 0.0)
	var use_auto_trim := bool(test_case.get("auto_sail_trim_enabled", true))
	_boat.call("set_auto_sail_trim_enabled", use_auto_trim)
	if use_auto_trim and not bool(_boat.call("get_auto_sail_trim_enabled")):
		return false
	if not use_auto_trim:
		# Project convention: port wind (negative TWA) sheets both sails to +X/starboard.
		var trim_sign := 1.0 if float(test_case["target_twa_deg"]) < 0.0 else -1.0
		_boat.call("set_target_sail_angle", deg_to_rad(trim_sign * float(test_case.get("main_trim_magnitude_deg", 0.0))))
		_boat.call("set_target_headsail_angle", deg_to_rad(trim_sign * float(test_case.get("headsail_trim_magnitude_deg", 0.0))))
	_boat.sleeping = false
	var frames := 0
	while frames < 12:
		var diagnostics: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		if not bool(diagnostics.get("pose_command_pending", false)):
			break
		await get_tree().physics_frame
		frames += 1
	if frames >= 12:
		return false
	var nav: Dictionary = _boat.call("get_navigation_snapshot")
	var heading := float(nav.get("heading_degrees", NAN))
	return is_finite(heading) and absf(wrapf(heading - target_heading_degrees, -180.0, 180.0)) <= 2.0


func _apply_heading_controller(target_heading_degrees: float) -> void:
	var diagnostic: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var heading := float(diagnostic.get("heading_degrees", 0.0))
	var heading_error := wrapf(target_heading_degrees - heading, -180.0, 180.0)
	# The body uses local +Y yaw as a port-turn rate, which decreases compass HDG.
	var compass_yaw_rate := -rad_to_deg(float(diagnostic.get("yaw_rate_rad_s", 0.0)))
	var nav: Dictionary = _boat.call("get_navigation_snapshot")
	var max_rudder := rad_to_deg(float(nav.get("max_rudder_angle_rad", deg_to_rad(float(profile.get("rudder_limit_degrees"))))))
	var command_degrees := TEST_MATH.rudder_command_degrees(
		heading_error,
		compass_yaw_rate,
		float(profile.get("rudder_p_gain")),
		float(profile.get("rudder_d_gain")),
		minf(max_rudder, float(profile.get("rudder_limit_degrees")))
	)
	# Preserve the exact existing PD output while exposing its unclamped request
	# and clamped command for optional diagnostic time-series capture.
	_last_controller_error_deg = heading_error
	_last_controller_compass_yaw_rate_deg_s = compass_yaw_rate
	_last_controller_pid_unclamped_deg = float(profile.get("rudder_p_gain")) * heading_error - float(profile.get("rudder_d_gain")) * compass_yaw_rate
	_last_controller_command_deg = command_degrees
	_boat.call("set_target_rudder_angle", deg_to_rad(command_degrees))


func _sample_state(target_heading_degrees: float, target_twa_degrees: float) -> Dictionary:
	var nav: Dictionary = _boat.call("get_navigation_snapshot")
	var diagnostic: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var debug: Dictionary = _boat.call("get_debug_snapshot")
	var heading := float(nav.get("heading_degrees", NAN))
	var true_wind_from := float(nav.get("true_wind_from_degrees", float(_active_config["wind_from_degrees"])))
	var measured_twa := TEST_MATH.relative_twa_degrees(true_wind_from, heading)
	var body_velocity: Vector3 = _boat.linear_velocity
	var horizontal_velocity := Vector3(body_velocity.x, 0.0, body_velocity.z)
	var target_forward := TEST_MATH.target_course_forward(target_heading_degrees)
	var rudder_max := maxf(rad_to_deg(float(nav.get("max_rudder_angle_rad", 0.611))), 0.001)
	var vlong := float(diagnostic.get("longitudinal_velocity_mps", NAN))
	var vlat := float(diagnostic.get("lateral_velocity_mps", NAN))
	var hull_drag: Vector3 = diagnostic.get("hull_drag_force_local_n", Vector3.ZERO)
	var keel_force: Vector3 = diagnostic.get("keel_force_local_n", Vector3.ZERO)
	var rudder_force: Vector3 = diagnostic.get("rudder_force_local_n", Vector3.ZERO)
	var main_force: Vector3 = debug.get("sail_net_force_local_n", Vector3.ZERO)
	var headsail_force: Vector3 = debug.get("headsail_net_force_local_n", Vector3.ZERO)
	var cog_degrees := float(nav.get("cog_degrees", NAN)) if bool(nav.get("cog_valid", false)) else NAN
	var sample := {
		"sim_time_s": _current_sim_time_s,
		"heading_deg": heading,
		"heading_error_deg": wrapf(target_heading_degrees - heading, -180.0, 180.0),
		"measured_twa_deg": measured_twa,
		"twa_error_deg": wrapf(measured_twa - target_twa_degrees, -180.0, 180.0),
		"sog_mps": float(nav.get("sog_mps", NAN)),
		"velocity_world_x_mps": horizontal_velocity.x,
		"velocity_world_z_mps": horizontal_velocity.z,
		"cog_deg": cog_degrees,
		"vmg_kn": horizontal_velocity.dot(target_forward) * TEST_MATH.KNOTS_PER_MPS,
		"vlong_mps": vlong,
		"vlat_mps": vlat,
		"heel_deg": float(nav.get("heel_degrees", NAN)),
		"leeway_deg": TEST_MATH.relative_leeway_degrees(vlong, vlat),
		"rudder_deg": rad_to_deg(float(nav.get("actual_rudder_angle_rad", NAN))),
		"target_rudder_deg": rad_to_deg(float(nav.get("target_rudder_angle_rad", NAN))),
		"rudder_limit_deg": rudder_max,
		"yaw_rate_deg_s": -rad_to_deg(float(diagnostic.get("yaw_rate_rad_s", NAN))),
		"main_sail_deg": rad_to_deg(float(nav.get("actual_sail_angle_rad", NAN))),
		"headsail_deg": rad_to_deg(float(nav.get("actual_headsail_angle_rad", NAN))),
		"main_force_forward_n": -main_force.z,
		"headsail_force_forward_n": -headsail_force.z,
		"hull_resistance_forward_n": -hull_drag.z,
		"keel_force_forward_n": -keel_force.z,
		"rudder_force_forward_n": -rudder_force.z,
		"total_water_force_forward_n": -(hull_drag.z + keel_force.z + rudder_force.z),
		"body_calculation_average_usec": float(debug.get("total_physics_calculation_average_usec", NAN)),
		"body_calculation_p95_usec": float(debug.get("total_physics_calculation_p95_usec", NAN)),
		"wind_speed_mps": float(nav.get("true_wind_speed_mps", NAN)),
		"target_wind_from_deg": float(_active_config["wind_from_degrees"]),
		"tws_kn": float(nav.get("true_wind_speed_mps", NAN)) * TEST_MATH.KNOTS_PER_MPS,
		"aws_kn": float(nav.get("apparent_wind_speed_mps", NAN)) * TEST_MATH.KNOTS_PER_MPS,
		"awa_deg": float(nav.get("apparent_wind_from_relative_degrees", NAN)),
	}
	if bool(_active_config.get("include_extended_telemetry", false)):
		var extended := _make_extended_sample(nav, debug, diagnostic)
		var rudder_deg := float(extended.get("p22_rudder_actual_angle_deg", NAN))
		var sample_time := float(extended.get("p22_sim_time_s", _current_sim_time_s))
		var elapsed := sample_time - _previous_telemetry_sample_time_s
		extended["p22_rudder_angle_rate_deg_s"] = (rudder_deg - _previous_telemetry_rudder_deg) / elapsed if is_finite(rudder_deg) and is_finite(_previous_telemetry_rudder_deg) and elapsed > 0.0 else 0.0
		extended["p22_telemetry_finite_flag"] = _extended_sample_is_finite(extended)
		_previous_telemetry_rudder_deg = rudder_deg
		_previous_telemetry_sample_time_s = sample_time
		sample.merge(extended, true)
	if bool(_active_config.get("capture_yaw_timeseries", false)):
		sample["target_heading_deg"] = target_heading_degrees
		sample["controller_error_deg"] = _last_controller_error_deg
		sample["controller_compass_yaw_rate_deg_s"] = _last_controller_compass_yaw_rate_deg_s
		sample["pid_output_unclamped_deg"] = _last_controller_pid_unclamped_deg
		sample["pid_command_deg"] = _last_controller_command_deg
		sample["local_yaw_rate_rad_s"] = float(diagnostic.get("yaw_rate_rad_s", NAN))
		sample["angular_damp"] = float(_boat.get("angular_damp"))
		var damp_mode := int(_boat.get("angular_damp_mode"))
		sample["angular_damp_mode"] = "COMBINE" if damp_mode == 0 else ("REPLACE" if damp_mode == 1 else "UNKNOWN")
	return sample


func _make_extended_sample(nav: Dictionary, debug: Dictionary, diagnostic: Dictionary) -> Dictionary:
	var com_local: Vector3 = debug.get("center_of_mass_local_m", _boat.center_of_mass)
	var main_pc: Vector3 = debug.get("sail_pressure_center_local_m", Vector3.ZERO)
	var jib_pc: Vector3 = debug.get("headsail_pressure_center_local_m", Vector3.ZERO)
	var keel_pc: Vector3 = debug.get("keel_center_local_m", Vector3.ZERO)
	var rudder_pc: Vector3 = debug.get("rudder_center_local_m", Vector3.ZERO)
	var main_lift: Vector3 = debug.get("sail_lift_force_local_n", Vector3.ZERO)
	var main_drag: Vector3 = debug.get("sail_drag_force_local_n", Vector3.ZERO)
	var main_net: Vector3 = debug.get("sail_net_force_local_n", Vector3.ZERO)
	var jib_lift: Vector3 = debug.get("headsail_lift_force_local_n", Vector3.ZERO)
	var jib_drag: Vector3 = debug.get("headsail_drag_force_local_n", Vector3.ZERO)
	var jib_net: Vector3 = debug.get("headsail_net_force_local_n", Vector3.ZERO)
	var keel_result: Dictionary = debug.get("keel_result", {})
	var rudder_result: Dictionary = debug.get("rudder_result", {})
	var keel_lift: Vector3 = keel_result.get("lift_force_local_n", Vector3.ZERO)
	var keel_drag: Vector3 = keel_result.get("drag_force_local_n", Vector3.ZERO)
	var keel_net: Vector3 = keel_result.get("net_force_local_n", Vector3.ZERO)
	var rudder_lift: Vector3 = rudder_result.get("lift_force_local_n", Vector3.ZERO)
	var rudder_drag: Vector3 = rudder_result.get("drag_force_local_n", Vector3.ZERO)
	var rudder_net: Vector3 = rudder_result.get("net_force_local_n", Vector3.ZERO)
	var main_arm := main_pc - com_local
	var jib_arm := jib_pc - com_local
	var keel_arm := keel_pc - com_local
	var rudder_arm := rudder_pc - com_local
	var main_lift_torque := main_arm.cross(main_lift)
	var main_drag_torque := main_arm.cross(main_drag)
	var main_net_torque := main_arm.cross(main_net)
	var jib_lift_torque := jib_arm.cross(jib_lift)
	var jib_drag_torque := jib_arm.cross(jib_drag)
	var jib_net_torque := jib_arm.cross(jib_net)
	var keel_lift_torque := keel_arm.cross(keel_lift)
	var keel_drag_torque := keel_arm.cross(keel_drag)
	var keel_net_torque := keel_arm.cross(keel_net)
	var rudder_lift_torque := rudder_arm.cross(rudder_lift)
	var rudder_drag_torque := rudder_arm.cross(rudder_drag)
	var rudder_net_torque := rudder_arm.cross(rudder_net)
	var local_velocity: Vector3 = debug.get("local_velocity_mps", Vector3.ZERO)
	var hull_force: Vector3 = debug.get("hull_drag_force_local_n", Vector3.ZERO)
	var hull_lateral_force: Vector3 = debug.get("hull_lateral_force_local_n", Vector3(hull_force.x, 0.0, 0.0))
	var hull_lateral_application_point: Vector3 = debug.get("hull_lateral_application_point_local_m", com_local)
	var hull_lateral_arm: Vector3 = debug.get("hull_lateral_center_from_com_local_m", hull_lateral_application_point - com_local)
	var hull_lateral_application_offset_z := hull_lateral_arm.z
	var hull_lateral_torque: Vector3 = debug.get("hull_lateral_torque_local_nm", hull_lateral_arm.cross(hull_lateral_force))
	var hull_lateral_yaw_torque := hull_lateral_torque.y
	var hull_lateral_flow: Vector3 = debug.get("hull_lateral_velocity_local_mps", local_velocity)
	var keel_flow: Vector3 = debug.get("keel_relative_water_velocity_local_mps", Vector3.ZERO)
	var rudder_flow: Vector3 = debug.get("rudder_relative_water_velocity_local_mps", Vector3.ZERO)
	var jib_air: Vector3 = debug.get("headsail_apparent_wind_local_mps", Vector3.ZERO)
	var jib_awa := rad_to_deg(atan2(-jib_air.x, jib_air.z)) if jib_air.length_squared() > 0.0001 else 0.0
	var damping_torque: Vector3 = debug.get("p22_axis_damping_torque_local_nm", Vector3.ZERO)
	var buoyancy_torque: Vector3 = debug.get("p22_buoyancy_torque_local_nm", Vector3.ZERO)
	var total_torque := main_net_torque + jib_net_torque + keel_net_torque + rudder_net_torque + hull_lateral_torque + damping_torque + buoyancy_torque
	var measured_total_horizontal_force: Vector3 = debug.get("total_horizontal_force_local_n", Vector3(NAN, NAN, NAN))
	var measured_total_external_yaw_torque := float(debug.get("total_external_yaw_torque_nm", NAN))
	var engine_force: Vector3 = debug.get("engine_force_local_n", Vector3(NAN, NAN, NAN))
	var engine_yaw_torque := float(debug.get("engine_yaw_torque_nm", NAN))
	var rudder_limit_deg := rad_to_deg(float(debug.get("max_rudder_angle_rad", 0.0)))
	var actual_rudder_deg := rad_to_deg(float(debug.get("actual_rudder_angle_rad", 0.0)))
	var rudder_sat := 1.0 if rudder_limit_deg > 0.0 and absf(actual_rudder_deg) >= rudder_limit_deg - 0.05 else 0.0
	var profile_resource: Resource = _boat.get("profile") as Resource
	var keel_stall := float(profile_resource.get("keel_stall_angle_rad")) if profile_resource != null else NAN
	var rudder_stall := float(profile_resource.get("rudder_stall_angle_rad")) if profile_resource != null else NAN
	var keel_aoa := float(keel_result.get("angle_of_attack_rad", NAN))
	var rudder_aoa := float(rudder_result.get("angle_of_attack_rad", NAN))
	var actual_twa := TEST_MATH.relative_twa_degrees(float(nav.get("true_wind_from_degrees", _active_config.get("wind_from_degrees", 180.0))), float(nav.get("heading_degrees", NAN)))
	var output := {
		"p22_sim_time_s": _current_sim_time_s,
		"p22_mass_kg": float(debug.get("mass_kg", NAN)),
		"p22_com_local_x_m": com_local.x, "p22_com_local_y_m": com_local.y, "p22_com_local_z_m": com_local.z,
		"p22_measured_twa_deg": actual_twa,
		"p22_twa_control_error_deg": wrapf(actual_twa - float(_current_case.get("target_twa_deg", 0.0)), -180.0, 180.0),
		"p22_main_area_m2": float(debug.get("sail_area_m2", NAN)),
		"p22_main_actual_angle_deg": rad_to_deg(float(debug.get("actual_sail_angle_rad", NAN))),
		"p22_main_target_angle_deg": rad_to_deg(float(debug.get("target_sail_angle_rad", NAN))),
		"p22_main_awa_deg": float(debug.get("sail_apparent_wind_from_angle_degrees", NAN)),
		"p22_main_aws_mps": float(debug.get("sail_apparent_wind_speed_mps", NAN)),
		"p22_main_aoa_deg": rad_to_deg(float(debug.get("sail_angle_of_attack_rad", NAN))),
		"p22_main_cl": float(debug.get("sail_cl", NAN)), "p22_main_cd": float(debug.get("sail_cd", NAN)),
		"p22_main_luffing_scale": float(debug.get("sail_luffing_scale", NAN)),
		"p22_main_wrong_side_lift_scale": float(debug.get("sail_wrong_side_lift_scale", NAN)),
		"p22_jib_area_m2": float(debug.get("headsail_effective_area_m2", NAN)),
		"p22_jib_actual_angle_deg": rad_to_deg(float(debug.get("actual_headsail_angle_rad", NAN))),
		"p22_jib_target_angle_deg": rad_to_deg(float(debug.get("target_headsail_angle_rad", NAN))),
		"p22_jib_awa_deg": jib_awa, "p22_jib_aws_mps": float(debug.get("headsail_apparent_wind_speed_mps", NAN)),
		"p22_jib_aoa_deg": rad_to_deg(float(debug.get("headsail_angle_of_attack_rad", NAN))),
		"p22_jib_cl": float(debug.get("headsail_cl", NAN)), "p22_jib_cd": float(debug.get("headsail_cd", NAN)),
		"p22_jib_luffing_scale": float(debug.get("headsail_luffing_scale", NAN)),
		"p22_jib_wrong_side_lift_scale": float(debug.get("headsail_wrong_side_lift_scale", NAN)),
		"p22_keel_area_m2": float(debug.get("keel_area_m2", NAN)),
		"p22_keel_local_flow_x_mps": keel_flow.x, "p22_keel_local_flow_y_mps": keel_flow.y, "p22_keel_local_flow_z_mps": keel_flow.z,
		"p22_keel_water_speed_mps": float(keel_result.get("water_speed_mps", NAN)),
		"p22_keel_aoa_deg": rad_to_deg(keel_aoa), "p22_keel_cl": float(keel_result.get("cl", NAN)), "p22_keel_cd": float(keel_result.get("cd", NAN)),
		"p22_keel_stall_zone_flag": 1.0 if is_finite(keel_stall) and is_finite(keel_aoa) and absf(keel_aoa) >= keel_stall else 0.0,
		"p22_rudder_area_m2": float(debug.get("rudder_area_m2", NAN)),
		"p22_rudder_actual_angle_deg": actual_rudder_deg,
		"p22_rudder_target_angle_deg": rad_to_deg(float(debug.get("target_rudder_angle_rad", NAN))),
		"p22_rudder_saturation_flag": rudder_sat,
		"p22_rudder_local_flow_x_mps": rudder_flow.x, "p22_rudder_local_flow_y_mps": rudder_flow.y, "p22_rudder_local_flow_z_mps": rudder_flow.z,
		"p22_rudder_water_speed_mps": float(rudder_result.get("water_speed_mps", NAN)),
		"p22_rudder_aoa_deg": rad_to_deg(rudder_aoa), "p22_rudder_cl": float(rudder_result.get("cl", NAN)), "p22_rudder_cd": float(rudder_result.get("cd", NAN)),
		"p22_rudder_stall_zone_flag": 1.0 if is_finite(rudder_stall) and is_finite(rudder_aoa) and absf(rudder_aoa) >= rudder_stall else 0.0,
		"p22_hull_longitudinal_resistance_forward_n": -hull_force.z,
		"p22_hull_lateral_resistance_starboard_n": hull_force.x,
		"p22_hull_lateral_application_offset_z_m": hull_lateral_application_offset_z,
		"p22_hull_lateral_center_from_com_local_m_x": hull_lateral_arm.x,
		"p22_hull_lateral_center_from_com_local_m_y": hull_lateral_arm.y,
		"p22_hull_lateral_center_from_com_local_m_z": hull_lateral_arm.z,
		"p22_hull_lateral_velocity_local_mps_x": hull_lateral_flow.x,
		"p22_hull_lateral_velocity_local_mps_y": hull_lateral_flow.y,
		"p22_hull_lateral_velocity_local_mps_z": hull_lateral_flow.z,
		"p22_hull_lateral_application_point_local_m_x": hull_lateral_application_point.x,
		"p22_hull_lateral_application_point_local_m_y": hull_lateral_application_point.y,
		"p22_hull_lateral_application_point_local_m_z": hull_lateral_application_point.z,
		"p22_hull_lateral_yaw_torque_nm": hull_lateral_yaw_torque,
		"p22_body_longitudinal_speed_mps": -local_velocity.z,
		"p22_body_lateral_speed_mps": local_velocity.x,
		"p22_axis_damping_pitch_torque_nm": damping_torque.x,
		"p22_axis_damping_yaw_torque_nm": damping_torque.y,
		"p22_axis_damping_roll_torque_nm": damping_torque.z,
		"p22_buoyancy_pitch_torque_nm": buoyancy_torque.x,
		"p22_buoyancy_yaw_torque_nm": buoyancy_torque.y,
		"p22_buoyancy_roll_torque_nm": buoyancy_torque.z,
		"p22_measured_pitch_torque_sum_nm": total_torque.x,
		"p22_measured_yaw_torque_sum_nm": total_torque.y,
		"p22_measured_roll_torque_sum_nm": total_torque.z,
		# Direct cached sums from the production physics step. These are kept
		# separate from the reconstructed component sum above so the report can
		# identify their exact coverage and avoid treating absent terms as zero.
		"p22_total_horizontal_force_local_n_x": measured_total_horizontal_force.x,
		"p22_total_horizontal_force_local_n_y": measured_total_horizontal_force.y,
		"p22_total_horizontal_force_local_n_z": measured_total_horizontal_force.z,
		"p22_total_external_yaw_torque_nm": measured_total_external_yaw_torque,
		"p22_engine_force_local_n_x": engine_force.x,
		"p22_engine_force_local_n_y": engine_force.y,
		"p22_engine_force_local_n_z": engine_force.z,
		"p22_engine_yaw_torque_nm": engine_yaw_torque,
		"p22_engine_running_flag": 1.0 if str(debug.get("auxiliary_engine", {}).get("state_name", "OFF")) == "RUNNING" else 0.0,
		"p22_sail_force_enabled_flag": 1.0 if bool(debug.get("effective_sail_forces_enabled", false)) else 0.0,
		"p22_headsail_enabled_flag": 1.0 if bool(debug.get("headsail_enabled", false)) else 0.0,
		"p22_required_force_torque_cache_available_flag": 1.0 if debug.has("total_horizontal_force_local_n") and debug.has("total_external_yaw_torque_nm") else 0.0,
		"p22_wind_query_count_per_tick": float(debug.get("wind_query_count_per_tick", NAN)),
		"p22_wave_query_count_per_tick": float(debug.get("wave_query_count_per_tick", NAN)),
	}
	_add_force_and_torque(output, "p22_main_lift", main_lift, main_arm)
	_add_force_and_torque(output, "p22_main_drag", main_drag, main_arm)
	_add_force_and_torque(output, "p22_main_net", main_net, main_arm)
	_add_force_and_torque(output, "p22_jib_lift", jib_lift, jib_arm)
	_add_force_and_torque(output, "p22_jib_drag", jib_drag, jib_arm)
	_add_force_and_torque(output, "p22_jib_net", jib_net, jib_arm)
	_add_force_and_torque(output, "p22_keel_lift", keel_lift, keel_arm)
	_add_force_and_torque(output, "p22_keel_drag", keel_drag, keel_arm)
	_add_force_and_torque(output, "p22_keel_net", keel_net, keel_arm)
	_add_force_and_torque(output, "p22_rudder_lift", rudder_lift, rudder_arm)
	_add_force_and_torque(output, "p22_rudder_drag", rudder_drag, rudder_arm)
	_add_force_and_torque(output, "p22_rudder_net", rudder_net, rudder_arm)
	_add_force_and_torque(output, "p22_hull_lateral", hull_lateral_force, hull_lateral_arm)
	_add_vector_fields(output, "p22_hull_lateral_torque_local_nm", hull_lateral_torque)
	_add_vector_fields(output, "p22_hull_drag_calculated_force_local_n", hull_force)
	_add_vector_fields(output, "p22_hull_drag_applied_force_local_n", debug.get("hull_drag_applied_force_local_n", hull_force))
	_add_vector_fields(output, "p22_main_pressure_center_local_m", main_pc)
	_add_vector_fields(output, "p22_jib_pressure_center_local_m", jib_pc)
	_add_vector_fields(output, "p22_keel_application_local_m", keel_pc)
	_add_vector_fields(output, "p22_rudder_application_local_m", rudder_pc)
	return output


func _add_force_and_torque(output: Dictionary, prefix: String, force: Vector3, arm_from_com: Vector3) -> void:
	_add_vector_fields(output, prefix + "_force_local_n", force)
	_add_vector_fields(output, prefix + "_arm_from_com_local_m", arm_from_com)
	_add_vector_fields(output, prefix + "_torque_local_nm", arm_from_com.cross(force))
	output[prefix + "_forward_force_n"] = -force.z
	output[prefix + "_lateral_force_starboard_n"] = force.x


func _add_vector_fields(output: Dictionary, prefix: String, value: Vector3) -> void:
	output[prefix + "_x"] = value.x
	output[prefix + "_y"] = value.y
	output[prefix + "_z"] = value.z


func _make_result(test_case: Dictionary, status: String, reason: String, metrics: Dictionary) -> Dictionary:
	var leeway_value: Variant = metrics.get("mean_leeway_deg", _mean_sample("leeway_deg"))
	if typeof(leeway_value) == TYPE_FLOAT and not is_finite(float(leeway_value)):
		leeway_value = null
	var result := {
		"case_id": str(test_case.get("case_id", "")),
		"boat_id": _boat_name(),
		"boat_scene_path": _selected_boat_scene_path,
		"boat_config_hash": _config_hash,
		"physics_version": str(Engine.get_version_info().get("string", "Godot")),
		"test_run_id": _run_id,
		"timestamp": Time.get_datetime_string_from_system(true),
		"engine_state": str(_boat.call("get_auxiliary_engine_snapshot").get("state_name", "OFF")) if _boat.has_method("get_auxiliary_engine_snapshot") else "OFF",
		"auto_trim_state": "AUTO" if _boat != null and _boat.has_method("get_auto_sail_trim_enabled") and bool(_boat.call("get_auto_sail_trim_enabled")) else "MANUAL",
		"target_tws_kn": float(test_case.get("target_tws_kn", 0.0)),
		"target_twa_deg": float(test_case.get("target_twa_deg", 0.0)),
		"tack": str(test_case.get("tack", "")),
		"wind_from_deg": float(_active_config.get("wind_from_degrees", 180.0)),
		"wave_mode": "static_zero_amplitude_sampler_enabled" if str(_active_config.get("wave_mode", "zero_amplitude")) == "zero_amplitude" else "project_wave_amplitude",
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"physics_time_scale": Engine.time_scale,
		"effective_simulated_ticks_per_second": 1.0 / float(profile.get("fixed_physics_step_seconds")),
		"measured_twa_deg": float(metrics.get("mean_twa_deg", _circular_mean_sample("measured_twa_deg"))),
		"mean_tws_kn": float(metrics.get("mean_tws_kn", _mean_sample("tws_kn"))),
		"mean_aws_kn": float(metrics.get("mean_aws_kn", _mean_sample("aws_kn"))),
		"mean_awa_deg": float(metrics.get("mean_awa_deg", _circular_mean_sample("awa_deg"))),
		"mean_velocity_world_x_mps": float(metrics.get("velocity_world_x_mps", _mean_sample("velocity_world_x_mps"))),
		"mean_velocity_world_z_mps": float(metrics.get("velocity_world_z_mps", _mean_sample("velocity_world_z_mps"))),
		"mean_heading_deg": float(metrics.get("mean_heading_deg", _circular_mean_sample("heading_deg"))),
		"mean_cog_deg": _bearing_from_mean_velocity(float(metrics.get("velocity_world_x_mps", _mean_sample("velocity_world_x_mps"))), float(metrics.get("velocity_world_z_mps", _mean_sample("velocity_world_z_mps")))),
		"mean_sog_kn": float(metrics.get("sog_mps", _mean_sample("sog_mps"))) * TEST_MATH.KNOTS_PER_MPS,
		"mean_stw_kn": float(metrics.get("sog_mps", _mean_sample("sog_mps"))) * TEST_MATH.KNOTS_PER_MPS,
		"mean_vmg_kn": float(metrics.get("vmg_kn", _mean_sample("vmg_kn"))),
		"mean_heel_deg": float(metrics.get("heel_deg", _mean_sample("heel_deg"))),
		"mean_leeway_deg": leeway_value,
		"speed_stddev_mps": float(metrics.get("sog_stddev_mps", NAN)),
		"heading_error_deg": float(metrics.get("mean_abs_heading_error_deg", _mean_sample_abs("heading_error_deg"))),
		"mean_rudder_deg": float(metrics.get("rudder_deg", _mean_sample("rudder_deg"))),
		"rudder_saturation_fraction": float(metrics.get("rudder_saturation_fraction", 0.0)),
		"main_sail_deg": float(metrics.get("main_sail_deg", _mean_sample("main_sail_deg"))),
		"headsail_deg": float(metrics.get("headsail_deg", _mean_sample("headsail_deg"))),
		"mean_main_forward_force_n": float(metrics.get("main_force_forward_n", _mean_sample("main_force_forward_n"))),
		"mean_headsail_forward_force_n": float(metrics.get("headsail_force_forward_n", _mean_sample("headsail_force_forward_n"))),
		"mean_hull_resistance_forward_n": float(metrics.get("hull_resistance_forward_n", _mean_sample("hull_resistance_forward_n"))),
		"mean_keel_force_forward_n": float(metrics.get("keel_force_forward_n", _mean_sample("keel_force_forward_n"))),
		"mean_rudder_force_forward_n": float(metrics.get("rudder_force_forward_n", _mean_sample("rudder_force_forward_n"))),
		"mean_total_water_force_forward_n": float(metrics.get("total_water_force_forward_n", _mean_sample("total_water_force_forward_n"))),
		"mean_body_calculation_usec": float(metrics.get("body_calculation_average_usec", _mean_sample("body_calculation_average_usec"))),
		"p95_body_calculation_usec": float(metrics.get("maximum_body_calculation_p95_usec", _max_sample("body_calculation_p95_usec"))),
		"mean_longitudinal_velocity_mps": float(metrics.get("vlong_mps", _mean_sample("vlong_mps"))),
		"elapsed_simulation_seconds": _current_sim_time_s,
		"stability_first_qualified_simulation_seconds": _stability_first_qualified_sim_s if _stability_first_qualified_sim_s >= 0.0 else null,
		"wall_clock_elapsed_seconds": float(Time.get_ticks_usec() - _case_wall_started_usec) / 1000000.0 if _case_wall_started_usec > 0 else 0.0,
		"observed_physics_step_seconds": _last_observed_physics_step_s,
		"maximum_physics_step_error_seconds": _maximum_physics_step_error_s,
		"sample_count": _current_samples.size(),
		"status": status,
		"failure_reason": reason,
		"experiment_group": str(test_case.get("experiment_group", "")),
		"experiment_variable": str(test_case.get("experiment_variable", "")),
		"experiment_label": str(test_case.get("experiment_label", "")),
		"auto_sail_trim_enabled": bool(test_case.get("auto_sail_trim_enabled", true)),
		"requested_main_trim_magnitude_deg": float(test_case.get("main_trim_magnitude_deg", NAN)),
		"requested_headsail_trim_magnitude_deg": float(test_case.get("headsail_trim_magnitude_deg", NAN)),
	}
	if bool(_active_config.get("include_extended_telemetry", false)):
		result["extended_telemetry"] = _summarize_extended_samples()
	if bool(_active_config.get("capture_yaw_timeseries", false)):
		# P2.5-only additive output. Existing stability evaluation continues to
		# use the same one-second samples and thresholds.
		result["yaw_timeseries_samples"] = _current_samples.duplicate(true)
	for key in result:
		if typeof(result[key]) == TYPE_FLOAT and not is_finite(float(result[key])):
			result[key] = null
	return result


func _sample_is_finite(sample: Dictionary) -> bool:
	for key in ["heading_deg", "heading_error_deg", "measured_twa_deg", "twa_error_deg", "sog_mps", "velocity_world_x_mps", "velocity_world_z_mps", "vmg_kn", "vlong_mps", "vlat_mps", "heel_deg", "rudder_deg", "rudder_limit_deg", "yaw_rate_deg_s", "tws_kn", "aws_kn", "awa_deg", "main_force_forward_n", "headsail_force_forward_n", "hull_resistance_forward_n", "keel_force_forward_n", "rudder_force_forward_n"]:
		if not is_finite(float(sample.get(key, NAN))):
			return false
	return true


func _extended_sample_is_finite(sample: Dictionary) -> bool:
	for key in sample:
		if str(key).begins_with("p22_") and typeof(sample[key]) in [TYPE_FLOAT, TYPE_INT] and not is_finite(float(sample[key])):
			return false
	return true


func _summarize_extended_samples() -> Dictionary:
	var totals: Dictionary = {}
	var counts: Dictionary = {}
	var summary_window := maxi(1, int(ceil(float(_active_config.get("sample_window_seconds", 30.0)))))
	var samples_to_summarize := _tail_samples(_current_samples, summary_window)
	var all_finite := true
	for sample in samples_to_summarize:
		all_finite = all_finite and bool(sample.get("p22_telemetry_finite_flag", false))
		for key in sample:
			if not str(key).begins_with("p22_") or typeof(sample[key]) not in [TYPE_FLOAT, TYPE_INT]:
				continue
			var value := float(sample[key])
			if not is_finite(value):
				continue
			totals[key] = float(totals.get(key, 0.0)) + value
			counts[key] = int(counts.get(key, 0)) + 1
	var output := {}
	for key in totals:
		var count := int(counts[key])
		if count > 0:
			output["mean_" + str(key).trim_prefix("p22_")] = float(totals[key]) / float(count)
	output["telemetry_finite"] = all_finite
	output["telemetry_sample_count"] = samples_to_summarize.size()
	return output


func _heading_metrics_acceptable(metrics: Dictionary) -> bool:
	return (
		float(metrics.get("mean_abs_twa_error_deg", INF)) <= float(_active_config["maximum_mean_twa_error_degrees"])
		and float(metrics.get("mean_abs_heading_error_deg", INF)) <= float(_active_config["maximum_heading_error_degrees"])
		and float(metrics.get("rudder_saturation_fraction", INF)) <= float(_active_config["maximum_rudder_saturation_fraction"])
	)


func _mean_sample(key: String) -> float:
	if _current_samples.is_empty():
		return NAN
	var total := 0.0
	var count := 0
	for sample in _current_samples:
		var value := float(sample.get(key, NAN))
		if is_finite(value):
			total += value
			count += 1
	return total / float(count) if count > 0 else NAN


func _mean_sample_abs(key: String) -> float:
	if _current_samples.is_empty():
		return NAN
	var total := 0.0
	for sample in _current_samples:
		total += absf(float(sample.get(key, 0.0)))
	return total / float(_current_samples.size())


func _max_sample(key: String) -> float:
	if _current_samples.is_empty():
		return NAN
	var maximum := -INF
	for sample in _current_samples:
		var value := float(sample.get(key, NAN))
		if is_finite(value):
			maximum = maxf(maximum, value)
	return maximum if is_finite(maximum) else NAN


func _bearing_from_mean_velocity(east_mps: float, south_mps: float) -> float:
	if not is_finite(east_mps) or not is_finite(south_mps) or Vector2(east_mps, south_mps).length() < 0.1:
		return NAN
	return fposmod(rad_to_deg(atan2(east_mps, -south_mps)), 360.0)


func _circular_mean_sample(key: String) -> float:
	var sine_total := 0.0
	var cosine_total := 0.0
	var count := 0
	for sample in _current_samples:
		var value := float(sample.get(key, NAN))
		if not is_finite(value):
			continue
		var angle := deg_to_rad(value)
		sine_total += sin(angle)
		cosine_total += cos(angle)
		count += 1
	if count == 0:
		return NAN
	return rad_to_deg(atan2(sine_total, cosine_total))


func _tail_samples(samples: Array[Dictionary], count: int) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	var first := maxi(0, samples.size() - count)
	for index in range(first, samples.size()):
		output.append(samples[index])
	return output


func _make_config(ui_config: Dictionary) -> Dictionary:
	var tws_knots: Array[float] = []
	if ui_config.has("tws_knots"):
		for value in ui_config["tws_knots"]:
			if is_finite(float(value)) and float(value) > 0.0:
				tws_knots.append(float(value))
	else:
		for value in profile.get("target_tws_knots"):
			tws_knots.append(float(value))
	var output := {
		"tws_knots": tws_knots,
		"twa_start_degrees": clampf(float(ui_config.get("twa_start_degrees", profile.get("twa_start_degrees"))), 0.0, 180.0),
		"twa_end_degrees": clampf(float(ui_config.get("twa_end_degrees", profile.get("twa_end_degrees"))), 0.0, 180.0),
		"twa_step_degrees": maxf(float(ui_config.get("twa_step_degrees", profile.get("twa_step_degrees"))), 1.0),
		"include_port_tack": bool(ui_config.get("include_port_tack", profile.get("include_port_tack"))),
		"include_starboard_tack": bool(ui_config.get("include_starboard_tack", profile.get("include_starboard_tack"))),
		"minimum_warmup_seconds": float(profile.get("minimum_warmup_seconds")),
		"stability_window_seconds": float(profile.get("stability_window_seconds")),
		"sample_window_seconds": float(profile.get("sample_window_seconds")),
		"case_timeout_seconds": float(profile.get("case_timeout_seconds")),
		"maximum_mean_twa_error_degrees": float(profile.get("maximum_mean_twa_error_degrees")),
		"maximum_heading_error_degrees": float(profile.get("maximum_heading_error_degrees")),
		"maximum_speed_standard_deviation_mps": float(profile.get("maximum_speed_standard_deviation_mps")),
		"maximum_speed_half_window_delta_mps": float(profile.get("maximum_speed_half_window_delta_mps")),
		"maximum_rudder_saturation_fraction": float(profile.get("maximum_rudder_saturation_fraction")),
		"no_forward_progress_threshold_mps": float(profile.get("no_forward_progress_threshold_mps")),
		"rudder_p_gain": float(profile.get("rudder_p_gain")),
		"rudder_d_gain": float(profile.get("rudder_d_gain")),
		"rudder_limit_degrees": float(profile.get("rudder_limit_degrees")),
		"wind_from_degrees": float(profile.get("fixed_wind_from_degrees")),
		"fixed_wind_seed": int(profile.get("fixed_wind_seed")),
		"physics_step_seconds": float(profile.get("fixed_physics_step_seconds")),
		"engine_physics_ticks_per_second": Engine.physics_ticks_per_second,
		"time_scale": Engine.time_scale,
		"wave_mode": "zero_amplitude" if bool(profile.get("zero_wave_sampler_strength")) else "project_settings",
		"include_extended_telemetry": bool(ui_config.get("include_extended_telemetry", false)),
		"capture_yaw_timeseries": bool(ui_config.get("capture_yaw_timeseries", false)),
	}
	if ui_config.has("explicit_cases") and ui_config["explicit_cases"] is Array:
		output["explicit_cases"] = ui_config["explicit_cases"].duplicate(true)
	return output


func _build_cases(config: Dictionary) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	if config.has("explicit_cases"):
		for raw_case in config["explicit_cases"]:
			if not raw_case is Dictionary:
				continue
			var custom: Dictionary = raw_case.duplicate(true)
			var tws := float(custom.get("target_tws_kn", 0.0))
			var twa := float(custom.get("target_twa_deg", 999.0))
			if not is_finite(tws) or tws <= 0.0 or not is_finite(twa) or absf(twa) > 180.0:
				continue
			var tack := str(custom.get("tack", ""))
			if tack.is_empty():
				tack = "SYMMETRIC" if is_zero_approx(twa) or is_equal_approx(absf(twa), 180.0) else ("PORT" if twa < 0.0 else "STARBOARD")
			if str(custom.get("case_id", "")).is_empty():
				custom["case_id"] = str(_case_dictionary(tws, twa, tack)["case_id"])
			custom["tack"] = tack
			custom["target_tws_kn"] = snappedf(tws, 0.001)
			custom["target_twa_deg"] = snappedf(twa, 0.001)
			output.append(custom)
		return output
	if float(config["twa_end_degrees"]) < float(config["twa_start_degrees"]):
		return output
	if not bool(config["include_port_tack"]) and not bool(config["include_starboard_tack"]):
		return output
	var twa_values: Array[float] = []
	var angle := float(config["twa_start_degrees"])
	while angle <= float(config["twa_end_degrees"]) + 0.001:
		twa_values.append(clampf(angle, 0.0, 180.0))
		angle += float(config["twa_step_degrees"])
	for tws in config["tws_knots"]:
		for magnitude in twa_values:
			if is_zero_approx(magnitude) or is_equal_approx(magnitude, 180.0):
				output.append(_case_dictionary(float(tws), magnitude, "SYMMETRIC"))
			elif bool(config["include_port_tack"]):
				output.append(_case_dictionary(float(tws), -magnitude, "PORT"))
			if not is_zero_approx(magnitude) and not is_equal_approx(magnitude, 180.0) and bool(config["include_starboard_tack"]):
				output.append(_case_dictionary(float(tws), magnitude, "STARBOARD"))
	return output


func _case_dictionary(tws_knots: float, signed_twa: float, tack: String) -> Dictionary:
	var safe_tws := snappedf(tws_knots, 0.001)
	var safe_twa := snappedf(signed_twa, 0.001)
	return {
		"case_id": "tws_%05.2f_twa_%+06.2f_%s" % [safe_tws, safe_twa, tack.to_lower()],
		"target_tws_kn": safe_tws,
		"target_twa_deg": safe_twa,
		"tack": tack,
	}


func _validate_setup() -> Dictionary:
	if profile == null or _boat == null or _wind == null or _wave_sampler == null:
		return {"ok": false, "reason": "Polar runner requires a boat, local WindField, WaveSampler, and PolarTestProfile"}
	for method_name in ["get_navigation_snapshot", "get_s1_c4_diagnostic_snapshot", "get_debug_snapshot", "reset_to_neutral", "set_target_rudder_angle", "set_auto_sail_trim_enabled", "get_auto_sail_trim_enabled", "set_lab_test_wind"]:
		if not _boat.has_method(method_name):
			return {"ok": false, "reason": "selected vessel lacks required real-physics API: %s" % method_name}
	if not _boat.call("can_set_lab_test_wind"):
		return {"ok": false, "reason": "WindField is owned by formal weather; Polar tests require the isolated SailboatLab fixture"}
	return {"ok": true, "reason": "ready"}


func _capture_environment() -> bool:
	if _environment_captured:
		return true
	if _wind == null or _wave_sampler == null:
		return false
	_saved_wind = {
		"mean_wind_speed_mps": _wind.mean_wind_speed_mps,
		"mean_wind_from_degrees": _wind.mean_wind_from_degrees,
		"gust_strength_mps": _wind.gust_strength_mps,
		"gust_time_scale_seconds": _wind.gust_time_scale_seconds,
		"gust_space_scale_meters": _wind.gust_space_scale_meters,
		"gust_direction_variation_degrees": _wind.gust_direction_variation_degrees,
		"random_seed": _wind.random_seed,
		"test_time_enabled": _wind.has_test_time_override(),
		"test_time_seconds": _wind.get_simulation_time_seconds(),
	}
	_saved_wave_strength = _wave_sampler.wave_strength
	var boat_debug: Dictionary = _boat.call("get_debug_snapshot")
	_saved_dynamic_waves = bool(boat_debug.get("dynamic_waves_enabled", true))
	_saved_keyboard_controls = bool(_boat.get("keyboard_controls_enabled"))
	_saved_auto_trim = bool(_boat.call("get_auto_sail_trim_enabled"))
	_environment_captured = true
	return true


func _restore_environment() -> void:
	if not _environment_captured:
		return
	if is_instance_valid(_wave_sampler):
		_wave_sampler.wave_strength = _saved_wave_strength
	if is_instance_valid(_wind):
		_wind.set_gust_parameters(float(_saved_wind["gust_strength_mps"]), float(_saved_wind["gust_time_scale_seconds"]), float(_saved_wind["gust_space_scale_meters"]))
		_wind.set_mean_wind(float(_saved_wind["mean_wind_speed_mps"]), float(_saved_wind["mean_wind_from_degrees"]))
		_wind.set("gust_direction_variation_degrees", float(_saved_wind["gust_direction_variation_degrees"]))
		_wind.set_random_seed(int(_saved_wind["random_seed"]))
		if bool(_saved_wind["test_time_enabled"]):
			_wind.set_test_simulation_time(float(_saved_wind["test_time_seconds"]))
		else:
			_wind.clear_test_simulation_time()
	if is_instance_valid(_boat):
		_boat.call("set_dynamic_waves_enabled", _saved_dynamic_waves)
		_boat.call("reset_to_neutral", 0.0)
		_boat.call("set_auto_sail_trim_enabled", _saved_auto_trim)
		_boat.call("set_keyboard_controls_enabled", _saved_keyboard_controls)
		_boat.sleeping = false
	_environment_captured = false


func _stop_engine() -> void:
	if _boat == null or not _boat.has_method("has_auxiliary_engine") or not bool(_boat.call("has_auxiliary_engine")):
		return
	if _boat.has_method("reset_auxiliary_engine_for_lab_test"):
		_boat.call("reset_auxiliary_engine_for_lab_test")
	else:
		_boat.call("stop_auxiliary_engine")
	_boat.call("set_auxiliary_engine_target_throttle", 0.0)
	_boat.call("set_auxiliary_engine_gear", ENGINE_NEUTRAL)


func _update_live_status(test_case: Dictionary) -> void:
	var nav: Dictionary = _boat.call("get_navigation_snapshot")
	var diagnostics: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var auto_trim: Dictionary = nav.get("auto_sail_trim", {})
	_last_ui_snapshot = {
		"status": "运行中",
		"current_case_id": test_case.get("case_id", ""),
		"current_case_index": _case_index + 1,
		"case_count": _cases.size(),
		"target_tws_kn": test_case.get("target_tws_kn", 0.0),
		"target_twa_deg": test_case.get("target_twa_deg", 0.0),
		"sog_kn": float(nav.get("sog_knots", 0.0)),
		"measured_twa_deg": float(nav.get("true_wind_from_relative_degrees", NAN)),
		"stability_status": "采集中 · 尚未完成稳定窗口",
		"rudder_deg": rad_to_deg(float(nav.get("actual_rudder_angle_rad", 0.0))),
		"main_sail_deg": rad_to_deg(float(nav.get("actual_sail_angle_rad", 0.0))),
		"headsail_deg": rad_to_deg(float(nav.get("actual_headsail_angle_rad", 0.0))),
		"trim_no_go": bool(auto_trim.get("no_go", false)),
	}
	progress_changed.emit(get_status_snapshot())


func _refresh_status(message: String) -> void:
	_last_ui_snapshot["status"] = message
	_last_ui_snapshot["current_case_id"] = _current_case.get("case_id", "")
	progress_changed.emit(get_status_snapshot())


func _make_run_metadata() -> Dictionary:
	return {
		"test_run_id": _run_id,
		"boat_id": _boat_name(),
		"boat_scene_path": _selected_boat_scene_path,
		"boat_config_hash": _config_hash,
		"created_at": Time.get_datetime_string_from_system(true),
		"godot_version": Engine.get_version_info(),
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"physics_step_seconds": profile.get("fixed_physics_step_seconds"),
		"engine_physics_ticks_per_second": Engine.physics_ticks_per_second,
		"time_scale": Engine.time_scale,
		"effective_physics_steps_per_simulated_second": 1.0 / float(profile.get("fixed_physics_step_seconds")),
		"physics_step_note": "Engine ticks/time scale are execution acceleration; each observed RigidBody physics delta is checked against the fixed simulated step.",
		"config": _active_config,
		"config_hash_coverage": {
			"scripts": SIGNATURE_SCRIPT_PATHS,
			"selected_boat_scene_source": true,
			"profile_storage_values_and_resource_source": true,
			"engine_version_and_test_configuration": true,
		},
		"stw_definition": "SOG; no current system is configured and the runner sets water current to zero",
		"leeway_definition": "signed ground-track angle relative to bow from local vlat/vlong; NaN below 0.15 m/s",
		"vmg_definition": "horizontal world velocity projected onto the target course direction",
		"wave_definition": "WaveSampler remains enabled and is queried by the boat; local sampler amplitude is set to zero for static water",
	}


func _persist_checkpoint(next_index: int) -> void:
	var checkpoint := {
		"schema_version": 1,
		"test_run_id": _run_id,
		"run_directory": _run_directory,
		"boat_scene_path": _selected_boat_scene_path,
		"boat_config_hash": _config_hash,
		"config_hash": _config_hash,
		"config": _active_config,
		"run_metadata": _run_metadata,
		"cases": _cases,
		"results": _results,
		"next_case_index": next_index,
		"updated_at": Time.get_datetime_string_from_system(true),
	}
	EXPORTER.save_bundle(_run_directory, _run_metadata, _cases, _results, checkpoint)
	_last_checkpoint_path = _run_directory.path_join("polar_checkpoint.json")


func _skip_completed_cases() -> void:
	while _case_index < _cases.size():
		var row: Dictionary = _results_by_case_id.get(str(_cases[_case_index].get("case_id", "")), {})
		if row.is_empty() or str(row.get("status", "")) == "INTERRUPTED":
			return
		_case_index += 1


func _rebuild_results_array() -> void:
	_results.clear()
	for case in _cases:
		var row: Dictionary = _results_by_case_id.get(str(case.get("case_id", "")), {})
		if not row.is_empty():
			_results.append(row)


func _decode_dictionary_array(value: Variant) -> Array[Dictionary]:
	var output: Array[Dictionary] = []
	if value is Array:
		for row in value:
			if row is Dictionary:
				output.append(row)
	return output


func _calculate_config_hash(config: Dictionary) -> String:
	var signature := {
		"boat_scene_path": _selected_boat_scene_path,
		"config": config,
		"engine_version": Engine.get_version_info().get("string", ""),
		"profile": _resource_signature(_boat.get("profile") if _boat != null else null),
		"profile_file": _resource_contents((_boat.get("profile") as Resource).resource_path if _boat != null and _boat.get("profile") is Resource else ""),
		"boat_scene_file": _resource_contents(_selected_boat_scene_path),
		"scripts": {},
	}
	for path in SIGNATURE_SCRIPT_PATHS:
		signature["scripts"][path] = _resource_contents(path)
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(JSON.stringify(signature, "", true).to_utf8_buffer())
	return context.finish().hex_encode()


func _resource_signature(resource: Resource) -> Dictionary:
	var output := {}
	if resource == null:
		return output
	for property in resource.get_property_list():
		if (int(property.get("usage", 0)) & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var property_name := str(property.get("name", ""))
		if property_name == "script" or property_name.begins_with("resource_"):
			continue
		var value: Variant = resource.get(property_name)
		output[property_name] = str(value) if value is Resource else value
	output["resource_path"] = resource.resource_path
	return output


func _resource_contents(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return "missing:%s" % path
	return FileAccess.get_file_as_string(path)


func _boat_name() -> String:
	if not _selected_boat_scene_path.is_empty():
		return _selected_boat_scene_path.get_file().get_basename()
	return str(_boat.name) if _boat != null else "unknown_boat"


func _new_run_id() -> String:
	var stamp := Time.get_datetime_string_from_system(true).replace(":", "-").replace("T", "_")
	return "polar_%s_%06d" % [stamp, randi_range(0, 999999)]
