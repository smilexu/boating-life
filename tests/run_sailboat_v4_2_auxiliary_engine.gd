extends SceneTree

## Headless integration check for the Nordic 28 auxiliary diesel. Uses the
## production SailboatLab RigidBody3D and only test-scoped environmental/setup
## overrides.

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const SIM_HZ := 60
const OFFLINE_TIME_SCALE := 8.0
const OUTPUT_DIR := "res://docs/sailing/v4_2_data"
const OUTPUT_CSV := OUTPUT_DIR + "/engine_test_results.csv"

var _lab: Node3D
var _boat: RigidBody3D
var _wind: Node
var _engine: Node
var _rows: Array[String] = ["case,time_s,tws_mps,throttle,gear,hdg_deg,sog_kn,longitudinal_mps,lateral_mps,engine_state,thrust_forward_n,fuel_remaining_l,consumption_lph,sail_force_long_n,sail_forces_enabled"]
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var old_tick_rate := Engine.physics_ticks_per_second
	var old_time_scale := Engine.time_scale
	Engine.physics_ticks_per_second = int(SIM_HZ * OFFLINE_TIME_SCALE)
	Engine.time_scale = OFFLINE_TIME_SCALE
	var world_time_manager := root.get_node_or_null("WorldTimeManager")
	if world_time_manager != null:
		world_time_manager.set("autosave_enabled", false)
	_lab = LAB_SCENE.instantiate() as Node3D
	var test_wave_sampler := _lab.get_node_or_null("WaveSampler")
	if test_wave_sampler != null:
		test_wave_sampler.set("wave_time_seconds", 0.0)
		test_wave_sampler.set_process(false)
		test_wave_sampler.set_physics_process(false)
	root.add_child(_lab)
	await process_frame
	_boat = _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_wind = _lab.get_node_or_null("WindField")
	_engine = _lab.get_node_or_null("SailboatBody/AuxiliaryMarineEngine")
	if _boat == null or _wind == null or _engine == null:
		_failures.append("SailboatLab did not load the production boat, WindField, and auxiliary engine components.")
		_finish(old_tick_rate, old_time_scale)
		return
	_boat.call("set_keyboard_controls_enabled", false)
	_wind.call("set_random_seed", 481516)
	_wind.set("gust_strength_mps", 0.0)
	_wind.set("gust_direction_variation_degrees", 0.0)
	_wind.call("set_test_simulation_time", 0.0)
	await _wait_physics_seconds(1.0)
	await _test_fuel_and_interlocks()
	await _test_no_wind_motor_cases()
	await _test_sail_and_mixed_cases()
	await _test_reverse()
	await _test_sampling_and_performance()
	_write_csv()
	var snapshot: Dictionary = _boat.call("get_debug_snapshot")
	print("[Nordic28 V4.2] engine=%s fuel=%.2fL wind_queries=%d wave_queries=%d total_physics_avg/p95=%d/%d us engine_step=%d us output=%s" % [
		str(_engine.call("get_state_name")),
		float(_engine.call("get_snapshot").get("tank", {}).get("remaining_l", 0.0)),
		int(snapshot.get("wind_query_count_per_tick", 0)), int(snapshot.get("wave_query_count_per_tick", 0)),
		int(snapshot.get("total_physics_calculation_average_usec", 0)), int(snapshot.get("total_physics_calculation_p95_usec", 0)),
		int(snapshot.get("engine_calculation_usec", 0)), OUTPUT_CSV,
	])
	_finish(old_tick_rate, old_time_scale)


func _test_fuel_and_interlocks() -> void:
	var tank := _boat.get_node_or_null("FuelTank") as FuelTankComponent
	if tank == null:
		_failures.append("FuelTankComponent missing.")
		return
	var engine_profile: AuxiliaryMarineEngineProfile = _engine.get("profile") as AuxiliaryMarineEngineProfile
	if engine_profile == null \
		or not is_equal_approx(engine_profile.consumption_for_throttle_lph(0.0), 0.3) \
		or not is_equal_approx(engine_profile.consumption_for_throttle_lph(0.25), 0.6) \
		or not is_equal_approx(engine_profile.consumption_for_throttle_lph(0.5), 1.1) \
		or not is_equal_approx(engine_profile.consumption_for_throttle_lph(1.0), 2.0):
		_failures.append("Configured fuel-consumption curve differs from the requested idle/low/medium/high rates.")
	if not is_equal_approx(tank.fuel_remaining_l, 40.0):
		_failures.append("Tank should start at 40 L, got %.3f L." % tank.fuel_remaining_l)
	if tank.refuel(100.0) > 0.001 or not is_equal_approx(tank.fuel_remaining_l, 40.0):
		_failures.append("Refuelling above tank capacity was not clamped.")
	tank.set_fuel_remaining_l(20.0)
	if not is_equal_approx(tank.refuel(100.0), 20.0) or not is_equal_approx(tank.fuel_remaining_l, 40.0):
		_failures.append("Tank did not report the actual accepted refuel amount.")
	var total_consumed_before := tank.total_fuel_consumed_l
	tank.consume_fuel(0.25)
	if not is_equal_approx(tank.total_fuel_consumed_l - total_consumed_before, 0.25):
		_failures.append("Fuel tank did not track cumulative fuel consumption.")
	tank.set_fuel_remaining_l(0.0)
	tank.set_fuel_remaining_l(7.9)
	if not bool(tank.get_snapshot().get("low_fuel_warning", false)):
		_failures.append("Tank snapshot did not raise the configured low-fuel warning.")
	tank.set_fuel_remaining_l(0.0)
	if bool(_engine.call("start_engine")):
		_failures.append("Engine started with an empty tank.")
	_engine.call("reset_for_lab_test", 40.0)
	_engine.call("set_target_throttle", 1.0)
	if bool(_engine.call("set_gear", AuxiliaryMarineEngine.Gear.FORWARD)):
		_failures.append("Gear interlock accepted a shift above 10% throttle.")
	_engine.call("set_target_throttle", 0.0)
	_engine.call("set_gear", AuxiliaryMarineEngine.Gear.FORWARD)
	_engine.call("start_engine")
	await _wait_physics_seconds(3.0)
	if float(_engine.call("get_snapshot").get("tank", {}).get("remaining_l", 0.0)) >= 40.0:
		_failures.append("Engine fuel simulation did not consume idle fuel.")
	_engine.call("reset_for_lab_test", 12.34)
	_boat.call("set_vessel_active", false)
	if not is_equal_approx(_fuel_remaining(), 12.34):
		_failures.append("Switching the persistent Sailboat8m instance changed its stored tank fuel.")
	_boat.call("set_vessel_active", true)
	if not is_equal_approx(_fuel_remaining(), 12.34):
		_failures.append("Reactivating the persistent Sailboat8m instance refilled or lost tank fuel.")
	_engine.call("set_gear", AuxiliaryMarineEngine.Gear.FORWARD)
	_engine.call("set_target_throttle", 1.0)
	_engine.call("start_engine")
	_engine.call("set_fuel_for_lab_test", 0.000001)
	await _wait_physics_seconds(2.0)
	var empty_snapshot: Dictionary = _engine.call("get_snapshot")
	if float(empty_snapshot.get("tank", {}).get("remaining_l", 1.0)) != 0.0:
		_failures.append("Fuel amount went below or failed to clamp at empty.")
	if int(empty_snapshot.get("state", AuxiliaryMarineEngine.State.RUNNING)) != AuxiliaryMarineEngine.State.OFF:
		_failures.append("Engine did not stop when its remaining fuel was exhausted.")
	if float(empty_snapshot.get("thrust_forward_axis_n", 0.0)) != 0.0:
		_failures.append("Engine continued producing thrust after fuel exhaustion.")
	if bool(_engine.call("start_engine")):
		_failures.append("Engine restarted after fuel exhaustion.")
	_engine.call("reset_for_lab_test", 40.0)


func _test_no_wind_motor_cases() -> void:
	for throttle in [0.25, 0.5, 0.75, 1.0]:
		await _prepare_case(0.0, false, false)
		_boat.call("set_auxiliary_engine_gear", AuxiliaryMarineEngine.Gear.FORWARD)
		_boat.call("set_auxiliary_engine_target_throttle", throttle)
		_boat.call("start_auxiliary_engine")
		var fuel_before := _fuel_remaining()
		var speed_window: Array[float] = []
		for second in range(1, 61):
			await _wait_physics_seconds(1.0)
			var snapshot: Dictionary = _boat.call("get_debug_snapshot")
			var nav: Dictionary = _boat.call("get_navigation_snapshot")
			var engine: Dictionary = _boat.call("get_auxiliary_engine_snapshot")
			var main_force: Vector3 = snapshot.get("sail_net_force_local_n", Vector3.ZERO)
			var jib_force: Vector3 = snapshot.get("headsail_net_force_local_n", Vector3.ZERO)
			var sog_kn := float(nav.get("sog_knots", 0.0))
			if second > 50:
				speed_window.append(sog_kn)
			_rows.append(_csv_row("pure_motor", second, 0.0, throttle, int(engine.get("gear", 0)), float(nav.get("heading_degrees", 0.0)), sog_kn,
				float(snapshot.get("longitudinal_velocity_mps", 0.0)), float(snapshot.get("lateral_velocity_mps", 0.0)),
				str(engine.get("state_name", "")), float(engine.get("thrust_forward_axis_n", 0.0)), _fuel_remaining(),
				float(engine.get("consumption_lph", 0.0)), -main_force.z - jib_force.z,
				bool(snapshot.get("effective_sail_forces_enabled", true))))
		var mean_speed := _mean(speed_window)
		var fuel_used := fuel_before - _fuel_remaining()
		print("[Nordic28 V4.2][pure motor] throttle=%.0f%% final-window SOG=%.2f kn fuel=%.3f L" % [throttle * 100.0, mean_speed, fuel_used])
		var profile: AuxiliaryMarineEngineProfile = _engine.get("profile") as AuxiliaryMarineEngineProfile
		var reference_speed := profile.reference_cruise_speed_knots if profile != null else 5.0
		if is_equal_approx(throttle, 1.0) and absf(mean_speed - reference_speed) > 0.5:
			_failures.append("Full/high throttle final-window speed %.2f kn is more than 0.5 kn from the %.1f kn calibration target." % [mean_speed, reference_speed])
		if fuel_used <= 0.0:
			_failures.append("Running engine did not consume fuel at %.0f%% throttle." % (throttle * 100.0))


func _test_sail_and_mixed_cases() -> void:
	await _prepare_case(8.0, true, true)
	_boat.call("set_auto_sail_trim_enabled", true)
	var pure_sail_fuel := _fuel_remaining()
	var pure_sail_speed := await _run_sailing_case("pure_sail", 0.0, 0, 60)
	if not is_equal_approx(pure_sail_fuel, _fuel_remaining()):
		_failures.append("Fuel changed while the auxiliary engine was off during sail-only operation.")
	await _prepare_case(8.0, false, true)
	_boat.call("set_auxiliary_engine_gear", AuxiliaryMarineEngine.Gear.FORWARD)
	_boat.call("set_auxiliary_engine_target_throttle", 0.5)
	_boat.call("start_auxiliary_engine")
	var motor_in_wind_speed := await _run_sailing_case("motor_in_wind_no_sails", 0.5, AuxiliaryMarineEngine.Gear.FORWARD, 60)
	await _prepare_case(8.0, true, true)
	_boat.call("set_auto_sail_trim_enabled", true)
	_boat.call("set_auxiliary_engine_gear", AuxiliaryMarineEngine.Gear.FORWARD)
	_boat.call("set_auxiliary_engine_target_throttle", 0.5)
	_boat.call("start_auxiliary_engine")
	var mixed_speed := await _run_sailing_case("mixed_sail_engine", 0.5, AuxiliaryMarineEngine.Gear.FORWARD, 60)
	print("[Nordic28 V4.2][8 m/s compare] pure sail=%.2f kn · pure engine 50%% (sails off)=%.2f kn · mixed 50%%=%.2f kn" % [pure_sail_speed, motor_in_wind_speed, mixed_speed])


func _test_reverse() -> void:
	await _prepare_case(0.0, false, false)
	_boat.call("set_test_initial_linear_velocity_local", Vector3(0.0, 0.0, -0.5))
	_boat.call("set_auxiliary_engine_gear", AuxiliaryMarineEngine.Gear.REVERSE)
	_boat.call("set_auxiliary_engine_target_throttle", 0.4)
	_boat.call("start_auxiliary_engine")
	await _wait_physics_seconds(1.0)
	var first: Dictionary = _boat.call("get_debug_snapshot")
	await _wait_physics_seconds(20.0)
	var last: Dictionary = _boat.call("get_debug_snapshot")
	print("[Nordic28 V4.2][reverse] initial longitudinal=%.2f m/s final=%.2f m/s" % [float(first.get("longitudinal_velocity_mps", 0.0)), float(last.get("longitudinal_velocity_mps", 0.0))])
	if float(last.get("longitudinal_velocity_mps", 0.0)) >= float(first.get("longitudinal_velocity_mps", 0.0)):
		_failures.append("Reverse gear did not reduce/drive the hull's forward longitudinal speed.")


func _test_sampling_and_performance() -> void:
	await _prepare_case(0.0, false, true)
	await _wait_physics_seconds(10.0)
	var engine_node := _engine
	_boat.set("_auxiliary_engine", null)
	await _wait_physics_seconds(10.0)
	var without_engine: Dictionary = _boat.call("get_debug_snapshot")
	_boat.set("_auxiliary_engine", engine_node)
	await _wait_physics_seconds(10.0)
	var with_engine: Dictionary = _boat.call("get_debug_snapshot")
	print("[Nordic28 V4.2][perf] body avg/p95 with/without engine component=%d/%d vs %d/%d us; component=%d us" % [
		int(with_engine.get("total_physics_calculation_average_usec", 0)), int(with_engine.get("total_physics_calculation_p95_usec", 0)),
		int(without_engine.get("total_physics_calculation_average_usec", 0)), int(without_engine.get("total_physics_calculation_p95_usec", 0)),
		int(with_engine.get("engine_calculation_usec", 0)),
	])
	if int(with_engine.get("wind_query_count_per_tick", 0)) != 1:
		_failures.append("Engine integration changed the SailboatLab wind query count from one per physics step.")
	if int(with_engine.get("wave_query_count_per_tick", 0)) != 4:
		_failures.append("Engine integration changed the dynamic WaveSampler count from four per physics step.")



func _run_sailing_case(case_name: String, throttle: float, gear_value: int, seconds: int) -> float:
	var final_speed_window: Array[float] = []
	for second in range(1, seconds + 1):
		await _wait_physics_seconds(1.0)
		var snapshot: Dictionary = _boat.call("get_debug_snapshot")
		var nav: Dictionary = _boat.call("get_navigation_snapshot")
		var engine: Dictionary = _boat.call("get_auxiliary_engine_snapshot")
		var main_force: Vector3 = snapshot.get("sail_net_force_local_n", Vector3.ZERO)
		var jib_force: Vector3 = snapshot.get("headsail_net_force_local_n", Vector3.ZERO)
		if second > seconds - 10:
			final_speed_window.append(float(nav.get("sog_knots", 0.0)))
		_rows.append(_csv_row(case_name, second, 8.0, throttle, gear_value, float(nav.get("heading_degrees", 0.0)), float(nav.get("sog_knots", 0.0)),
			float(snapshot.get("longitudinal_velocity_mps", 0.0)), float(snapshot.get("lateral_velocity_mps", 0.0)),
			str(engine.get("state_name", "")), float(engine.get("thrust_forward_axis_n", 0.0)), _fuel_remaining(),
			float(engine.get("consumption_lph", 0.0)), -main_force.z - jib_force.z,
			bool(snapshot.get("effective_sail_forces_enabled", true))))
	return _mean(final_speed_window)


func _prepare_case(wind_speed: float, sail_forces_enabled: bool, dynamic_waves: bool) -> void:
	_boat.call("set_dynamic_waves_enabled", dynamic_waves)
	_boat.call("set_sail_forces_enabled_for_lab_test", sail_forces_enabled)
	_boat.call("set_water_current_world_velocity", Vector3.ZERO)
	_wind.call("set_test_simulation_time", 0.0)
	_boat.call("set_lab_test_wind", wind_speed, 270.0)
	_boat.call("reset_auxiliary_engine_for_lab_test", 40.0)
	_boat.call("set_auto_sail_trim_enabled", false)
	_boat.call("set_target_sail_angle", deg_to_rad(50.0))
	_boat.call("set_target_headsail_angle", deg_to_rad(40.0))
	_boat.call("reset_to_neutral", 0.0)
	_boat.sleeping = false
	await _wait_physics_seconds(1.0)
	_wind.call("set_test_simulation_time", 0.0)


func _wait_physics_seconds(seconds: float) -> void:
	for _tick in range(roundi(maxf(seconds, 0.0) * SIM_HZ)):
		await physics_frame


func _fuel_remaining() -> float:
	var snapshot: Dictionary = _boat.call("get_auxiliary_engine_snapshot")
	var tank: Dictionary = snapshot.get("tank", {})
	return float(tank.get("remaining_l", 0.0))


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())


func _csv_row(case_name: String, time_s: int, tws: float, throttle: float, gear_value: int, heading: float, sog_kn: float, longitudinal: float, lateral: float, state_name: String, thrust: float, fuel: float, consumption: float, sail_forward: float, sail_forces_enabled: bool) -> String:
	return "%s,%d,%.2f,%.2f,%d,%.2f,%.4f,%.4f,%.4f,%s,%.3f,%.6f,%.4f,%.3f,%s" % [case_name, time_s, tws, throttle, gear_value, heading, sog_kn, longitudinal, lateral, state_name, thrust, fuel, consumption, sail_forward, str(sail_forces_enabled).to_lower()]


func _write_csv() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIR))
	var file := FileAccess.open(OUTPUT_CSV, FileAccess.WRITE)
	if file == null:
		_failures.append("Could not write diagnostic CSV: %s" % OUTPUT_CSV)
		return
	file.store_line("\n".join(_rows))
	file.close()


func _finish(old_tick_rate: int, old_time_scale: float) -> void:
	Engine.physics_ticks_per_second = old_tick_rate
	Engine.time_scale = old_time_scale
	if _failures.is_empty():
		print("[Nordic28 V4.2] PASS · rows=%d" % maxi(_rows.size() - 1, 0))
		quit(0)
	else:
		for failure in _failures:
			push_error("[Nordic28 V4.2] " + failure)
		quit(1)
