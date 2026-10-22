extends SceneTree
## Regression coverage for the Jib world-space arm fix. Runs the production
## SailboatLab body at translated world positions, then sails the Main vessel
## for ten simulated minutes with its formal wind and dynamic waves.

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const MAIN_SCENE := preload("res://scenes/main.tscn")
const BOAT_SCRIPT := preload("res://scripts/sailboat_lab_body.gd")
const SIMULATION_HZ := 60
const MAIN_TIME_SCALE := 8.0
const MAIN_PHYSICS_HZ := int(float(SIMULATION_HZ) * MAIN_TIME_SCALE)
const MAIN_DURATION_SECONDS := 600
const OFFSETS := [Vector3.ZERO, Vector3(10000.0, 0.0, -10000.0), Vector3(20000.0, 0.0, -20000.0)]
var _csv_path := "user://s1_c8_jib_world_space_fix.csv"

var _failures: Array[String] = []
var _rows: Array[Dictionary] = []
var _phase := "all"
var _original_physics_hz := 60
var _original_time_scale := 1.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_original_physics_hz = Engine.physics_ticks_per_second
	_original_time_scale = Engine.time_scale
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--phase="):
			_phase = argument.trim_prefix("--phase=")
	_csv_path = "user://s1_c8_jib_world_space_fix_%s.csv" % _phase
	if _phase not in ["all", "translation", "main"]:
		_failures.append("Unknown phase '%s'; use all, translation, or main." % _phase)
	else:
		if _phase in ["all", "translation"]:
			await _run_translation_trials()
		if _phase in ["all", "main"]:
			await _run_main_long_run()
	_write_csv()
	Engine.physics_ticks_per_second = _original_physics_hz
	Engine.time_scale = _original_time_scale
	if _failures.is_empty():
		print("[S1-C8-JIB] phase=%s passed; data=%s" % [_phase, ProjectSettings.globalize_path(_csv_path)])
		quit(0)
	else:
		for failure in _failures:
			push_error("[S1-C8-JIB] " + failure)
		print("[S1-C8-JIB] phase=%s failed=%d; data=%s" % [_phase, _failures.size(), ProjectSettings.globalize_path(_csv_path)])
		quit(1)


func _run_translation_trials() -> void:
	var lab := LAB_SCENE.instantiate() as Node3D
	root.add_child(lab)
	for _tick in range(4):
		await physics_frame
	var boat := lab.get_node_or_null("SailboatBody") as RigidBody3D
	var wind := lab.get_node_or_null("WindField")
	var wave_sampler := lab.get_node_or_null("WaveSampler")
	if boat == null or wind == null:
		_failures.append("SailboatLab did not provide SailboatBody and WindField.")
		lab.queue_free()
		return
	if wave_sampler != null:
		wave_sampler.set("wave_time_seconds", 0.0)
		wave_sampler.set_process(false)
		wave_sampler.set_physics_process(false)
	boat.call("set_dynamic_waves_enabled", false)
	boat.call("set_water_current_world_velocity", Vector3.ZERO)
	wind.call("set_random_seed", 481516)
	wind.call("set_gust_parameters", 0.0, 24.0, 450.0)
	wind.call("set_test_simulation_time", 0.0)
	if not bool(boat.call("set_lab_test_wind", 8.0, 270.0)):
		_failures.append("Could not configure the deterministic 8 m/s translation-test wind.")
		lab.queue_free()
		return
	boat.call("set_auto_sail_trim_enabled", false)
	boat.call("set_headsail_enabled", true)
	boat.set("actual_sail_angle_rad", deg_to_rad(50.0))
	boat.call("set_target_sail_angle", deg_to_rad(50.0))
	boat.set("actual_headsail_angle_rad", deg_to_rad(-45.0))
	boat.call("set_target_headsail_angle", deg_to_rad(-45.0))
	boat.call("set_target_rudder_angle", 0.0)
	var profile: Resource = boat.get("profile")
	var com_local: Vector3 = profile.get("center_of_mass_m")
	var neutral_origin_y := float(boat.get("water_height_m")) - float(profile.get("rest_submergence_m")) + 0.5
	var diagnostic_basis := Basis.from_euler(Vector3(deg_to_rad(2.0), 0.0, deg_to_rad(3.0)))
	var instantaneous: Array[Dictionary] = []
	for offset_index in range(OFFSETS.size()):
		var offset: Vector3 = OFFSETS[offset_index]
		await _set_initial_body_state(
			boat,
			Vector3(offset.x, neutral_origin_y, offset.z),
			diagnostic_basis,
			Vector3(0.8, 0.0, 0.2),
			Vector3(0.15, 0.02, -0.12)
		)
		var debug: Dictionary = boat.call("get_debug_snapshot")
		var expected_arm := BOAT_SCRIPT.world_arm_from_local_point(
			debug.get("headsail_pressure_center_local_m", Vector3.ZERO), com_local, boat.global_basis
		)
		var actual_arm: Vector3 = debug.get("headsail_arm_from_com_world_m", Vector3.ZERO)
		var main_pressure_center_local: Vector3 = debug.get("sail_pressure_center_local_m", Vector3.ZERO)
		var main_force_local: Vector3 = debug.get("sail_net_force_local_n", Vector3.ZERO)
		var main_torque_local := (main_pressure_center_local - com_local).cross(main_force_local)
		var row := {
			"phase": "translated_instant",
			"offset_x_m": offset.x,
			"offset_z_m": offset.z,
			"headsail_arm_length_m": actual_arm.length(),
			"headsail_arm_error_m": actual_arm.distance_to(expected_arm),
			"headsail_aws_mps": float(debug.get("headsail_apparent_wind_speed_mps", 0.0)),
			"headsail_apparent_x_mps": (debug.get("headsail_apparent_wind_local_mps", Vector3.ZERO) as Vector3).x,
			"headsail_apparent_z_mps": (debug.get("headsail_apparent_wind_local_mps", Vector3.ZERO) as Vector3).z,
			"headsail_force_x_n": (debug.get("headsail_net_force_local_n", Vector3.ZERO) as Vector3).x,
			"headsail_force_y_n": (debug.get("headsail_net_force_local_n", Vector3.ZERO) as Vector3).y,
			"headsail_force_z_n": (debug.get("headsail_net_force_local_n", Vector3.ZERO) as Vector3).z,
			"headsail_force_n": (debug.get("headsail_net_force_local_n", Vector3.ZERO) as Vector3).length(),
			"headsail_yaw_torque_nm": float(debug.get("headsail_yaw_torque_nm", 0.0)),
			"headsail_roll_torque_nm": float(debug.get("headsail_roll_torque_local_nm", 0.0)),
			"main_aws_mps": float(debug.get("apparent_wind_speed_mps", 0.0)),
			"main_apparent_x_mps": (debug.get("apparent_wind_local_mps", Vector3.ZERO) as Vector3).x,
			"main_apparent_z_mps": (debug.get("apparent_wind_local_mps", Vector3.ZERO) as Vector3).z,
			"main_force_n": main_force_local.length(),
			"main_yaw_torque_nm": main_torque_local.y,
			"main_roll_torque_local_nm": main_torque_local.z,
			"true_wind_x_mps": (debug.get("true_wind_world_mps", Vector3.ZERO) as Vector3).x,
			"true_wind_z_mps": (debug.get("true_wind_world_mps", Vector3.ZERO) as Vector3).z,
			"linear_velocity_x_mps": boat.linear_velocity.x,
			"linear_velocity_z_mps": boat.linear_velocity.z,
			"angular_velocity_x_rad_s": boat.angular_velocity.x,
			"angular_velocity_y_rad_s": boat.angular_velocity.y,
			"angular_velocity_z_rad_s": boat.angular_velocity.z,
		}
		instantaneous.append(row)
		_rows.append(row)
		print("[S1-C8-JIB][instant] offset=(%.0f,%.0f) jib arm=%.4fm AWS=%.4fm/s force=%.2fN yaw=%.2fNm wind=(%.4f,%.4f) velocity=(%.4f,%.4f) omega=(%.4f,%.4f,%.4f)" % [
			offset.x, offset.z, float(row["headsail_arm_length_m"]), float(row["headsail_aws_mps"]),
			float(row["headsail_force_n"]), float(row["headsail_yaw_torque_nm"]), float(row["true_wind_x_mps"]),
			float(row["true_wind_z_mps"]), float(row["linear_velocity_x_mps"]), float(row["linear_velocity_z_mps"]),
			float(row["angular_velocity_x_rad_s"]), float(row["angular_velocity_y_rad_s"]), float(row["angular_velocity_z_rad_s"]),
		])
		if actual_arm.distance_to(expected_arm) > 0.001:
			_failures.append("Jib world arm does not match the rotated local point-to-COM offset at translation index %d." % offset_index)
		if actual_arm.length() < 3.3 or actual_arm.length() > 3.7:
			_failures.append("Jib COM arm is outside the expected hull-scale range at translation index %d (%.3f m)." % [offset_index, actual_arm.length()])
	if instantaneous.size() == OFFSETS.size():
		var baseline: Dictionary = instantaneous[0]
		for index in range(1, instantaneous.size()):
			var candidate: Dictionary = instantaneous[index]
			for metric in ["headsail_arm_length_m", "headsail_aws_mps", "headsail_force_n", "headsail_yaw_torque_nm", "headsail_roll_torque_nm", "main_aws_mps", "main_force_n", "main_yaw_torque_nm", "main_roll_torque_local_nm"]:
				if absf(float(candidate[metric]) - float(baseline[metric])) > _metric_tolerance(metric, float(baseline[metric])):
					_failures.append("Instantaneous %s changes with world translation at index %d (base %.6f, shifted %.6f)." % [metric, index, float(baseline[metric]), float(candidate[metric])])
			for metric in ["true_wind_x_mps", "true_wind_z_mps"]:
				if absf(float(candidate[metric]) - float(baseline[metric])) > 0.001:
					_failures.append("The configured uniform test wind changed with world translation (%s, index %d)." % [metric, index])
	for offset_index in range(OFFSETS.size()):
		var offset: Vector3 = OFFSETS[offset_index]
		await _set_initial_body_state(
			boat,
			Vector3(offset.x, neutral_origin_y, offset.z),
			Basis.IDENTITY,
			Vector3.ZERO,
			Vector3.ZERO
		)
		boat.set("actual_sail_angle_rad", deg_to_rad(50.0))
		boat.call("set_target_sail_angle", deg_to_rad(50.0))
		boat.set("actual_headsail_angle_rad", deg_to_rad(-45.0))
		boat.call("set_target_headsail_angle", deg_to_rad(-45.0))
		boat.call("reset_performance_history")
		var max_aws := 0.0
		var max_headsail_force := 0.0
		var max_angular_speed := 0.0
		for _tick in range(5 * SIMULATION_HZ):
			await physics_frame
			var state: Dictionary = boat.call("get_debug_snapshot")
			max_aws = maxf(max_aws, float(state.get("headsail_apparent_wind_speed_mps", 0.0)))
			max_headsail_force = maxf(max_headsail_force, (state.get("headsail_net_force_local_n", Vector3.ZERO) as Vector3).length())
			max_angular_speed = maxf(max_angular_speed, (state.get("angular_velocity_rad_s", Vector3.ZERO) as Vector3).length())
			if not _snapshot_is_finite(state) or float(state.get("headsail_apparent_wind_speed_mps", 0.0)) > 100.0 or (state.get("headsail_net_force_local_n", Vector3.ZERO) as Vector3).length() > 250000.0:
				_failures.append("Short translated sailing trial became non-finite or exceeded the anomaly thresholds at offset index %d." % offset_index)
				break
		var final_debug: Dictionary = boat.call("get_debug_snapshot")
		var final_row := {
			"phase": "translated_sail_5s",
			"offset_x_m": offset.x,
			"offset_z_m": offset.z,
			"sog_mps": float(final_debug.get("linear_speed_mps", 0.0)),
			"local_longitudinal_mps": float(final_debug.get("longitudinal_velocity_mps", 0.0)),
			"heel_deg": absf(float(final_debug.get("roll_degrees", 0.0))),
			"tilt_deg": rad_to_deg(boat.global_basis.y.angle_to(Vector3.UP)),
			"max_headsail_aws_mps": max_aws,
			"max_headsail_force_n": max_headsail_force,
			"max_angular_speed_rad_s": max_angular_speed,
		}
		_rows.append(final_row)
		print("[S1-C8-JIB][sail5] offset=(%.0f,%.0f) SOG=%.3fm/s tilt=%.2f° max jib AWS=%.2fm/s force=%.1fN" % [
			offset.x, offset.z, float(final_row["sog_mps"]), float(final_row["tilt_deg"]),
			max_aws, max_headsail_force,
		])
	if lab != null and is_instance_valid(lab):
		lab.queue_free()
		await process_frame


func _set_initial_body_state(
	boat: RigidBody3D,
	position_world: Vector3,
	basis_world: Basis,
	linear_velocity_world: Vector3,
	angular_velocity_world: Vector3
) -> void:
	boat.freeze = true
	boat.sleeping = false
	boat.global_transform = Transform3D(basis_world, position_world)
	await physics_frame
	boat.linear_velocity = linear_velocity_world
	boat.angular_velocity = angular_velocity_world
	boat.freeze = false
	boat.sleeping = false
	await physics_frame


func _run_main_long_run() -> void:
	var main := MAIN_SCENE.instantiate() as Node3D
	if main == null:
		_failures.append("Main PackedScene could not be instantiated.")
		return
	root.add_child(main)
	for _tick in range(12):
		await physics_frame
	var controller := main.get_node_or_null("PlayerBoat/MotionRoot")
	var boat := main.get_node_or_null("PlayerBoat/SailingBoat8m") as RigidBody3D
	if controller == null or boat == null:
		_failures.append("Main did not expose its sailing controller and reusable 8 m sailboat.")
		main.queue_free()
		return
	controller.call("set_sailing_enabled", true)
	for _tick in range(60):
		await physics_frame
	boat.call("set_auto_sail_trim_enabled", true)
	var initial_wind := boat.call("get_debug_snapshot") as Dictionary
	if not bool(boat.call("get_auto_sail_trim_enabled")):
		_failures.append("Main sailboat did not enter AUTO trim for the long-run regression.")
	var wind_field := main.get_node_or_null("WindField")
	var initial_wind_speed := float(initial_wind.get("true_wind_speed_mps", 0.0))
	var initial_wind_from := float(initial_wind.get("true_wind_from_degrees", 0.0))
	if wind_field == null or str(wind_field.call("get_debug_override_state")) != "formal":
		_failures.append("Main's long-run test did not begin with the formal WindField configuration.")
	var previous_scale := Engine.time_scale
	var previous_hz := Engine.physics_ticks_per_second
	Engine.physics_ticks_per_second = MAIN_PHYSICS_HZ
	Engine.time_scale = MAIN_TIME_SCALE
	var sim_steps := MAIN_DURATION_SECONDS * SIMULATION_HZ
	var sample_interval := 60 * SIMULATION_HZ
	var max_sog := 0.0
	var max_tilt := 0.0
	var max_jib_aws := 0.0
	var max_jib_force := 0.0
	var max_main_force := 0.0
	var max_speed := 0.0
	var max_angular_speed := 0.0
	var max_position_component := 0.0
	var sample_count := 0
	var run_failed := false
	for tick in range(1, sim_steps + 1):
		await physics_frame
		var snapshot: Dictionary = boat.call("get_debug_snapshot")
		if int(snapshot.get("wave_query_count_per_tick", 0)) != 4 or int(snapshot.get("wind_query_count_per_tick", 0)) != 1:
			_failures.append("Main query budget changed at simulated t=%.1fs (waves=%d, wind=%d)." % [
				float(tick) / SIMULATION_HZ,
				int(snapshot.get("wave_query_count_per_tick", 0)),
				int(snapshot.get("wind_query_count_per_tick", 0)),
			])
			run_failed = true
			break
		var position := boat.global_position
		var tilt := rad_to_deg(boat.global_basis.y.angle_to(Vector3.UP))
		var velocity: Vector3 = snapshot.get("linear_velocity_mps", Vector3.ZERO)
		var angular: Vector3 = snapshot.get("angular_velocity_rad_s", Vector3.ZERO)
		var jib_force: Vector3 = snapshot.get("headsail_net_force_local_n", Vector3.ZERO)
		var main_force: Vector3 = snapshot.get("sail_net_force_local_n", Vector3.ZERO)
		var jib_aws := float(snapshot.get("headsail_apparent_wind_speed_mps", 0.0))
		max_sog = maxf(max_sog, velocity.length())
		max_speed = maxf(max_speed, velocity.length())
		max_tilt = maxf(max_tilt, tilt)
		max_jib_aws = maxf(max_jib_aws, jib_aws)
		max_jib_force = maxf(max_jib_force, jib_force.length())
		max_main_force = maxf(max_main_force, main_force.length())
		max_angular_speed = maxf(max_angular_speed, angular.length())
		max_position_component = maxf(max_position_component, maxf(absf(position.x), maxf(absf(position.y), absf(position.z))))
		if not _snapshot_is_finite(snapshot) or not _vector_is_finite(position) or not _vector_is_finite(angular):
			_failures.append("Main long-run developed a non-finite vessel state at simulated tick %d." % tick)
			run_failed = true
			break
		if jib_aws >= 100.0 or jib_force.length() >= 250000.0 or velocity.length() >= 25.0 or angular.length() >= 4.0 or tilt >= 65.0:
			_failures.append("Main long-run crossed a sailboat anomaly threshold at simulated t=%.1fs (AWS %.1f m/s, Jib %.0f N, tilt %.1f°)." % [float(tick) / SIMULATION_HZ, jib_aws, jib_force.length(), tilt])
			run_failed = true
			break
		if tick % sample_interval == 0 or tick == sim_steps:
			sample_count += 1
			var row := {
				"phase": "main_long_run",
				"sim_time_s": float(tick) / SIMULATION_HZ,
				"heading_deg": float(boat.call("get_navigation_snapshot").get("heading_degrees", 0.0)),
				"sog_mps": velocity.length(),
				"tilt_deg": tilt,
				"angular_speed_rad_s": angular.length(),
				"true_wind_mps": float(snapshot.get("true_wind_speed_mps", 0.0)),
				"true_wind_from_deg": float(snapshot.get("true_wind_from_degrees", 0.0)),
				"headsail_aws_mps": jib_aws,
				"headsail_force_n": jib_force.length(),
				"main_force_n": main_force.length(),
				"headsail_arm_m": (snapshot.get("headsail_arm_from_com_world_m", Vector3.ZERO) as Vector3).length(),
				"headsail_angle_deg": rad_to_deg(float(snapshot.get("actual_headsail_angle_rad", 0.0))),
				"main_sail_angle_deg": rad_to_deg(float(snapshot.get("actual_sail_angle_rad", 0.0))),
				"wave_queries": int(snapshot.get("wave_query_count_per_tick", 0)),
				"wind_queries": int(snapshot.get("wind_query_count_per_tick", 0)),
			}
			_rows.append(row)
			print("[S1-C8-JIB][main %ds] wind=%.2fm/s from %.1f° jib AWS=%.2fm/s jib force=%.1fN SOG=%.3fm/s tilt=%.2f°" % [
				int(row["sim_time_s"]), float(row["true_wind_mps"]), float(row["true_wind_from_deg"]),
				float(row["headsail_aws_mps"]), float(row["headsail_force_n"]), float(row["sog_mps"]), float(row["tilt_deg"]),
			])
	Engine.physics_ticks_per_second = previous_hz
	Engine.time_scale = previous_scale
	var final_snapshot: Dictionary = boat.call("get_debug_snapshot")
	var final_row := {
		"phase": "main_summary",
		"requested_sim_time_s": MAIN_DURATION_SECONDS,
		"samples": sample_count,
		"initial_wind_mps": initial_wind_speed,
		"initial_wind_from_deg": initial_wind_from,
		"max_sog_mps": max_sog,
		"max_speed_mps": max_speed,
		"max_tilt_deg": max_tilt,
		"max_headsail_aws_mps": max_jib_aws,
		"max_headsail_force_n": max_jib_force,
		"max_main_force_n": max_main_force,
		"max_angular_speed_rad_s": max_angular_speed,
		"max_position_component_m": max_position_component,
		"final_wave_queries": int(final_snapshot.get("wave_query_count_per_tick", 0)),
		"final_wind_queries": int(final_snapshot.get("wind_query_count_per_tick", 0)),
		"completed": not run_failed,
	}
	_rows.append(final_row)
	print("[S1-C8-JIB][main summary] completed=%s max SOG=%.3fm/s max Jib AWS=%.2fm/s force=%.1fN tilt=%.2f° pos_max=%.1fm queries=%d/%d" % [
		str(not run_failed), max_sog, max_jib_aws, max_jib_force, max_tilt, max_position_component,
		int(final_row["final_wave_queries"]), int(final_row["final_wind_queries"]),
	])
	main.queue_free()
	await process_frame


func _metric_tolerance(metric: String, baseline: float) -> float:
	if metric in ["headsail_arm_length_m"]:
		return 0.002
	if metric in ["headsail_aws_mps", "main_aws_mps"]:
		return 0.10
	if metric in ["main_yaw_torque_nm", "main_roll_torque_local_nm"]:
		return maxf(5.0, absf(baseline) * 0.03)
	return maxf(1.5, absf(baseline) * 0.015)


func _snapshot_is_finite(snapshot: Dictionary) -> bool:
	for key in ["linear_velocity_mps", "angular_velocity_rad_s", "headsail_net_force_local_n", "sail_net_force_local_n", "headsail_apparent_wind_local_mps", "headsail_arm_from_com_world_m"]:
		var value: Variant = snapshot.get(key, Vector3.ZERO)
		if value is Vector3 and not _vector_is_finite(value):
			return false
	for key in ["headsail_apparent_wind_speed_mps", "headsail_yaw_torque_nm", "headsail_roll_torque_local_nm"]:
		if not is_finite(float(snapshot.get(key, 0.0))):
			return false
	return true


func _vector_is_finite(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _write_csv() -> void:
	var file := FileAccess.open(_csv_path, FileAccess.WRITE)
	if file == null:
		push_error("Could not write translation test CSV; error %d." % FileAccess.get_open_error())
		return
	var headers := PackedStringArray()
	for row in _rows:
		for key in row:
			if not headers.has(str(key)):
				headers.append(str(key))
	headers.sort()
	file.store_line(",".join(headers))
	for row in _rows:
		var values := PackedStringArray()
		for header in headers:
			var value: Variant = row.get(header, "")
			var string_value := str(value).replace("\"", "\"\"")
			values.append("\"%s\"" % string_value)
		file.store_line(",".join(values))
	file.close()
