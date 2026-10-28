extends SceneTree

const HYDRO := preload("res://scripts/sailboat_hydrodynamics.gd")
const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const PROFILE := preload("res://resources/sailing/sailboat_lab_profile.tres")
const GRAVITY_MPS2 := 9.8

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_foil_hydrodynamics()
	_test_hull_resistance()
	_test_rudder_angle_limits()
	await _test_lab_zero_wind_and_stationary_rudder()
	await _test_sailing_and_rudder_response()
	await _test_dynamic_wave_combination()
	if _failures.is_empty():
		print("Sailboat hydrodynamics tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_foil_hydrodynamics() -> void:
	var zero := HYDRO.calculate_foil_forces(Vector3.ZERO, 0.5, 1.0)
	_expect(not bool(zero["valid"]), "zero water speed disables keel and rudder force")
	_expect(_near(zero["net_force_local_n"], Vector3.ZERO), "zero water speed returns an exact zero force")

	var forward_drag := HYDRO.calculate_foil_forces(Vector3(0.0, 0.0, -2.0), 0.0, 1.0)
	_expect(Vector3(forward_drag["net_force_local_n"]).z > 0.0, "foil drag opposes forward boat motion")
	_expect(Vector3(forward_drag["net_force_local_n"]).dot(Vector3(0.0, 0.0, -2.0)) < 0.0, "foil drag never injects energy into the boat")

	var port_leeway := HYDRO.calculate_foil_forces(Vector3(0.6, 0.0, -2.0), 0.0, 1.35)
	var starboard_leeway := HYDRO.calculate_foil_forces(Vector3(-0.6, 0.0, -2.0), 0.0, 1.35)
	var port_force: Vector3 = port_leeway["net_force_local_n"]
	var starboard_force: Vector3 = starboard_leeway["net_force_local_n"]
	_expect(port_force.x < 0.0 and starboard_force.x > 0.0, "keel side force opposes leeway on both tacks")
	_expect(absf(port_force.x + starboard_force.x) < 0.01, "keel side-force response mirrors across port and starboard leeway")
	_expect(absf(port_force.y) < 0.001 and absf(starboard_force.y) < 0.001, "horizontal foil model does not add vertical force")

	var double_speed := HYDRO.calculate_foil_forces(Vector3(1.2, 0.0, -4.0), 0.0, 1.35)
	_expect(
		absf(Vector3(double_speed["net_force_local_n"]).x - port_force.x * 4.0) < absf(port_force.x) * 0.02,
		"foil force follows dynamic-pressure speed-squared scaling at equal sideslip"
	)
	_expect(absf(float(port_leeway["cl"])) <= 1.15 and absf(float(port_leeway["cd"])) <= 2.0, "keel lift and drag coefficients remain bounded")
	_expect(
		HYDRO.calculate_foil_forces(Vector3(INF, 0.0, 1.0), 0.0, 1.0)["net_force_local_n"] == Vector3.ZERO,
		"non-finite water velocity safely returns zero force"
	)

	var rudder_positive := HYDRO.calculate_foil_forces(Vector3(0.0, 0.0, -2.0), deg_to_rad(20.0), 0.5)
	var rudder_negative := HYDRO.calculate_foil_forces(Vector3(0.0, 0.0, -2.0), deg_to_rad(-20.0), 0.5)
	var positive_rudder_force: Vector3 = rudder_positive["net_force_local_n"]
	var negative_rudder_force: Vector3 = rudder_negative["net_force_local_n"]
	var rudder_com_lever: Vector3 = PROFILE.get("rudder_center_local_m") - PROFILE.get("center_of_mass_m")
	var positive_rudder_yaw := rudder_com_lever.cross(positive_rudder_force).y
	var negative_rudder_yaw := rudder_com_lever.cross(negative_rudder_force).y
	_expect(positive_rudder_force.x < 0.0 and positive_rudder_yaw < 0.0, "positive starboard rudder turns the bow to starboard while moving forward")
	_expect(negative_rudder_force.x > 0.0 and negative_rudder_yaw > 0.0, "negative port rudder turns the bow to port while moving forward")
	_expect(absf(positive_rudder_force.x + negative_rudder_force.x) < 0.01, "rudder side forces are symmetric for equal opposite helm")
	_expect(positive_rudder_yaw < 0.0, "stern rudder force creates the intended yaw moment sign")
	var reverse_rudder := HYDRO.calculate_foil_forces(Vector3(0.0, 0.0, 2.0), deg_to_rad(20.0), 0.5)
	_expect(Vector3(reverse_rudder["net_force_local_n"]).x > 0.0, "rudder steering force reverses when water flow reverses")

	var angular_point_velocity := Vector3(0.0, 0.2, 0.0).cross(rudder_com_lever)
	_expect(angular_point_velocity.x > 0.5, "stern point velocity includes rigid-body yaw rotation")


func _test_hull_resistance() -> void:
	var rest_force := HYDRO.calculate_hull_resistance(Vector3.ZERO, 220.0, 85.0, 350.0, 180.0)
	_expect(rest_force == Vector3.ZERO, "hull resistance is zero at rest")
	var moving := Vector3(1.0, 0.0, -2.0)
	var resistance := HYDRO.calculate_hull_resistance(moving, 220.0, 85.0, 350.0, 180.0)
	_expect(resistance.x < 0.0 and resistance.z > 0.0, "hull drag opposes both lateral and longitudinal motion")
	_expect(resistance.dot(moving) < 0.0, "hull resistance cannot provide propulsion")
	var capped := HYDRO.calculate_hull_resistance(moving * 1000.0, 220.0, 85.0, 350.0, 180.0, 5000.0)
	_expect(capped.length() <= 5000.01, "hull drag has a configurable finite force cap")


func _test_rudder_angle_limits() -> void:
	var limited_step := HYDRO.move_rudder_angle_toward(0.0, 1.0, 1.0 / 60.0, deg_to_rad(60.0), deg_to_rad(35.0))
	_expect(absf(limited_step - deg_to_rad(1.0)) < 0.0001, "rudder angle respects mechanical slew speed per physics step")
	var reached_limit := HYDRO.move_rudder_angle_toward(0.0, 1.0, 1.0, deg_to_rad(60.0), deg_to_rad(35.0))
	_expect(absf(reached_limit - deg_to_rad(35.0)) < 0.0001, "rudder target is clamped to its mechanical limit")
	var mirrored_step := HYDRO.move_rudder_angle_toward(0.0, -1.0, 1.0 / 60.0, deg_to_rad(60.0), deg_to_rad(35.0))
	_expect(absf(limited_step + mirrored_step) < 0.0001, "rudder slew limits mirror for port and starboard helm")


func _test_lab_zero_wind_and_stationary_rudder() -> void:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	var boat: RigidBody3D = lab.get_node("SailboatBody")
	var debug_panel: CanvasLayer = lab.get_node("DebugPanel")
	var tabs := debug_panel.find_child("SailboatDebugTabs", true, false) as TabContainer
	_expect(tabs != null and tabs.get_tab_count() == 8, "underwater inspection and engine diagnostics are added alongside the existing hydrodynamics tabs")
	_expect(lab.get_node_or_null("SailboatBody/VisualRoot/RudderPivot/RudderBlade") != null, "low-poly visual rudder is attached to the boat model")
	boat.call("set_dynamic_waves_enabled", false)
	boat.call("reset_to_neutral")
	for _step in range(120):
		await physics_frame
	var rest: Dictionary = boat.call("get_debug_snapshot")
	_expect(float(rest["linear_speed_mps"]) < 0.04, "no wind and zero helm leave the vessel at rest")
	_expect(absf(float(rest["yaw_rate_rad_s"])) < 0.01, "zero wind and zero helm do not produce spontaneous yaw")
	_expect(Vector3(rest["sail_net_force_local_n"]).length() < 0.01, "zero wind yields no sail force")
	_expect(int(rest["wave_query_count_per_tick"]) == 0, "still-water mode performs no wave queries")

	boat.call("set_target_rudder_angle", deg_to_rad(35.0))
	for _step in range(120):
		await physics_frame
	var stationary_helm: Dictionary = boat.call("get_debug_snapshot")
	_expect(absf(rad_to_deg(float(stationary_helm["actual_rudder_angle_rad"])) - 35.0) < 0.1, "stationary helm reaches but does not exceed its rudder stop")
	_expect(float(stationary_helm["rudder_water_speed_mps"]) < 0.03, "a rudder at rest has no point-flow speed")
	_expect(absf(float(stationary_helm["yaw_rate_rad_s"])) < 0.01, "full rudder at rest cannot spin the boat without water flow")
	var d_key := InputEventKey.new()
	d_key.physical_keycode = KEY_D
	d_key.pressed = true
	boat.call("_input", d_key)
	_expect(float(boat.get_debug_snapshot()["target_rudder_angle_rad"]) > 0.0, "D key maps to starboard helm")
	d_key.pressed = false
	boat.call("_input", d_key)
	_expect(is_zero_approx(float(boat.get_debug_snapshot()["target_rudder_angle_rad"])), "releasing A/D returns the rudder target to centre")
	lab.queue_free()
	await process_frame


func _test_sailing_and_rudder_response() -> void:
	var neutral_helm := await _run_sailing_case(0.0)
	var starboard_helm := await _run_sailing_case(deg_to_rad(20.0))
	var port_helm := await _run_sailing_case(deg_to_rad(-20.0))
	var mirrored_tack := await _run_sailing_case(0.0, 90.0, -30.0)
	for label: String in ["no helm", "starboard helm", "port helm", "mirrored tack"]:
		var sample: Dictionary = {
			"no helm": neutral_helm,
			"starboard helm": starboard_helm,
			"port helm": port_helm,
			"mirrored tack": mirrored_tack,
		}[label]
		_expect(_finite_vector(sample["linear_velocity_mps"]), "%s retains finite rigid-body velocity" % label)
		_expect(float(sample["forward_mps"]) > 0.1, "%s scenario establishes forward motion from sail force" % label)
		_expect(int(sample["wind_query_count_per_tick"]) == 1, "%s scenario preserves one WindField query per physics step" % label)
	_expect(float(neutral_helm["distance_m"]) > 1.0, "sail-driven test moves through water instead of only rotating")
	_expect(absf(float(neutral_helm["forward_mps"]) - float(mirrored_tack["forward_mps"])) < 0.05, "opposite crosswind tacks produce matching forward speed")
	_expect(absf(float(neutral_helm["lateral_mps"]) + float(mirrored_tack["lateral_mps"])) < 0.05, "opposite crosswind tacks mirror lateral velocity")
	_expect(absf(float(neutral_helm["roll_degrees"]) + float(mirrored_tack["roll_degrees"])) < 1.0, "opposite crosswind tacks mirror physical heel")
	_expect(absf(wrapf(float(neutral_helm["heading_degrees"]) + float(mirrored_tack["heading_degrees"]), -180.0, 180.0)) < 1.0, "opposite crosswind tacks produce mirrored heading response")
	_expect(
		float(starboard_helm["rudder_yaw_torque_nm"]) < float(neutral_helm["rudder_yaw_torque_nm"]),
		"D/starboard helm adds starboard-turning moment around the existing leeway load"
	)
	_expect(
		wrapf(float(starboard_helm["heading_degrees"]) - float(neutral_helm["heading_degrees"]), -180.0, 180.0) > 0.0
			and wrapf(float(port_helm["heading_degrees"]) - float(neutral_helm["heading_degrees"]), -180.0, 180.0) < 0.0,
		"D steers the bow to starboard and A steers it to port in the moving-vessel test"
	)
	_expect(float(starboard_helm["actual_rudder_angle_rad"]) > 0.0 and float(port_helm["actual_rudder_angle_rad"]) < 0.0, "actual rudder angle follows the persistent helm target")
	var expected_sail_cp: Vector3 = (
		PROFILE.get("main_sail_pivot_local_m")
		+ Basis(Vector3.UP, float(neutral_helm["actual_sail_angle_rad"]))
			* PROFILE.get("main_sail_pressure_center_from_pivot_m")
	)
	var expected_sail_yaw: float = (expected_sail_cp - PROFILE.get("center_of_mass_m")).cross(neutral_helm["sail_force_local_n"]).y
	_expect(absf(expected_sail_yaw - float(neutral_helm["sail_yaw_torque_nm"])) < 0.1, "sail yaw torque uses r × F about the configured centre of mass")
	print("[SAILBOAT_C2_RUN] 10 s trim 30° crosswind: left tack heading=%.1f° forward=%.3f lateral=%+.3f roll=%+.1f° distance=%.2f m; right tack heading=%.1f° forward=%.3f lateral=%+.3f roll=%+.1f°; D20 heading=%.1f°; A20 heading=%.1f°" % [
		float(neutral_helm["heading_degrees"]), float(neutral_helm["forward_mps"]), float(neutral_helm["lateral_mps"]), float(neutral_helm["roll_degrees"]), float(neutral_helm["distance_m"]),
		float(mirrored_tack["heading_degrees"]), float(mirrored_tack["forward_mps"]), float(mirrored_tack["lateral_mps"]), float(mirrored_tack["roll_degrees"]),
		float(starboard_helm["heading_degrees"]),
		float(port_helm["heading_degrees"]),
	])
	print("[SAILBOAT_C2_PERF] keel avg/P95=%d/%d μs · rudder=%d/%d μs · hull drag=%d/%d μs · total=%d/%d μs" % [
		int(neutral_helm["keel_average_usec"]), int(neutral_helm["keel_p95_usec"]),
		int(neutral_helm["rudder_average_usec"]), int(neutral_helm["rudder_p95_usec"]),
		int(neutral_helm["hull_average_usec"]), int(neutral_helm["hull_p95_usec"]),
		int(neutral_helm["total_average_usec"]), int(neutral_helm["total_p95_usec"]),
	])


func _run_sailing_case(rudder_angle_rad: float, wind_from_degrees: float = 270.0, sail_angle_degrees: float = 30.0) -> Dictionary:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	var boat: RigidBody3D = lab.get_node("SailboatBody")
	boat.call("set_dynamic_waves_enabled", false)
	boat.call("reset_to_neutral")
	for _step in range(60):
		await physics_frame
	boat.call("set_lab_test_wind", 8.0, wind_from_degrees)
	boat.call("set_target_sail_angle", deg_to_rad(sail_angle_degrees))
	boat.call("set_target_rudder_angle", rudder_angle_rad)
	boat.call("reset_performance_history")
	var start_position: Vector3 = boat.global_position
	for _step in range(600):
		await physics_frame
	var data: Dictionary = boat.call("get_debug_snapshot")
	var result := {
		"heading_degrees": float(data["heading_degrees"]),
		"roll_degrees": float(data["roll_degrees"]),
		"forward_mps": float(data["longitudinal_velocity_mps"]),
		"lateral_mps": float(data["lateral_velocity_mps"]),
		"yaw_rate_rad_s": float(data["yaw_rate_rad_s"]),
		"linear_velocity_mps": data["linear_velocity_mps"],
		"distance_m": boat.global_position.distance_to(start_position),
		"rudder_yaw_torque_nm": float(data["rudder_yaw_torque_nm"]),
		"sail_yaw_torque_nm": float(data["sail_yaw_torque_nm"]),
		"sail_force_local_n": data["sail_net_force_local_n"],
		"actual_sail_angle_rad": float(data["actual_sail_angle_rad"]),
		"actual_rudder_angle_rad": float(data["actual_rudder_angle_rad"]),
		"wind_query_count_per_tick": int(data["wind_query_count_per_tick"]),
		"keel_average_usec": int(data["keel_calculation_average_usec"]),
		"keel_p95_usec": int(data["keel_calculation_p95_usec"]),
		"rudder_average_usec": int(data["rudder_calculation_average_usec"]),
		"rudder_p95_usec": int(data["rudder_calculation_p95_usec"]),
		"hull_average_usec": int(data["hull_drag_calculation_average_usec"]),
		"hull_p95_usec": int(data["hull_drag_calculation_p95_usec"]),
		"total_average_usec": int(data["total_physics_calculation_average_usec"]),
		"total_p95_usec": int(data["total_physics_calculation_p95_usec"]),
	}
	lab.queue_free()
	await process_frame
	return result


func _test_dynamic_wave_combination() -> void:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	var boat: RigidBody3D = lab.get_node("SailboatBody")
	boat.call("reset_to_neutral")
	boat.call("set_lab_test_wind", 6.0, 270.0)
	boat.call("set_target_sail_angle", deg_to_rad(30.0))
	for _step in range(180):
		await physics_frame
	var data: Dictionary = boat.call("get_debug_snapshot")
	_expect(bool(data["dynamic_waves_enabled"]), "sail and hydro forces run with shared dynamic waves enabled")
	_expect(int(data["wave_query_count_per_tick"]) == 4, "C2 forces preserve the four-sample dynamic-wave budget")
	_expect(int(data["wind_query_count_per_tick"]) == 1, "C2 forces preserve the one-query WindField budget")
	_expect(_finite_vector(data["linear_velocity_mps"]), "wind, keel, rudder and B2 buoyancy coexist without invalid velocity")
	_expect(is_finite(float(data["yaw_rate_rad_s"])), "wind, keel, rudder and waves keep yaw state finite")
	lab.queue_free()
	await process_frame


func _finite_vector(value: Variant) -> bool:
	var vector := Vector3(value)
	return is_finite(vector.x) and is_finite(vector.y) and is_finite(vector.z)


func _near(left: Vector3, right: Vector3, epsilon: float = 0.001) -> bool:
	return left.distance_to(right) <= epsilon


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("Sailboat hydrodynamics test failed: %s" % description)
