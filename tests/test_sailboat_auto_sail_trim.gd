extends SceneTree

const AUTO_TRIM := preload("res://scripts/sailboat_auto_sail_trim.gd")
const AERO := preload("res://scripts/sailboat_aero_math.gd")
const NAV := preload("res://scripts/sailboat_navigation_math.gd")
const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_angle_sign_truth()
	_test_curves_and_limits()
	_test_side_hysteresis_and_low_wind()
	await _test_lab_integration()
	if _failures.is_empty():
		print("Sailboat auto-trim tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_angle_sign_truth() -> void:
	_expect(is_equal_approx(NAV.signed_relative_bearing_degrees(270.0, 0.0), -90.0), "wind from 270° at HDG 000° is port-side TWA -90°")
	_expect(is_equal_approx(NAV.signed_relative_bearing_degrees(90.0, 0.0), 90.0), "wind from 090° at HDG 000° is starboard-side TWA +90°")
	var port_apparent := AERO.calculate_apparent_wind(Vector3.RIGHT * 8.0, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Basis.IDENTITY)
	var starboard_apparent := AERO.calculate_apparent_wind(Vector3.LEFT * 8.0, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Basis.IDENTITY)
	_expect(is_equal_approx(float(port_apparent["apparent_from_angle_degrees"]), -90.0), "wind-to +X produces negative port-side AWA")
	_expect(is_equal_approx(float(starboard_apparent["apparent_from_angle_degrees"]), 90.0), "wind-to -X produces positive starboard-side AWA")
	var positive_boom := NAV.boom_direction_from_sail_angle(deg_to_rad(60.0))
	var negative_boom := NAV.boom_direction_from_sail_angle(deg_to_rad(-60.0))
	_expect(positive_boom.x > 0.0 and negative_boom.x < 0.0, "main boom positive/negative angles move to starboard/port")
	var tack := Vector3(0.0, 0.65, -3.55)
	var clew := Vector3(0.0, 0.65, -1.15)
	var positive_jib_clew: Vector3 = AERO.headsail_clew_from_sheet(tack, clew, deg_to_rad(45.0))
	var negative_jib_clew: Vector3 = AERO.headsail_clew_from_sheet(tack, clew, deg_to_rad(-45.0))
	_expect(positive_jib_clew.x > 0.0 and negative_jib_clew.x < 0.0, "Jib positive/negative angles move its clew to starboard/port")
	var port_wind_good := AERO.calculate_sail_forces(Vector3.RIGHT * 8.0, deg_to_rad(60.0), 10.16, 1.225, 1.25, 0.384, 0.08, 0.55, 0.9, 0.611, 0.873, 0.20)
	var port_wind_backed := AERO.calculate_sail_forces(Vector3.RIGHT * 8.0, deg_to_rad(-60.0), 10.16, 1.225, 1.25, 0.384, 0.08, 0.55, 0.9, 0.611, 0.873, 0.20)
	_expect(float(port_wind_good["wrong_side_lift_scale"]) > 0.99 and float(port_wind_backed["wrong_side_lift_scale"]) < 0.21, "port wind retains lift with a starboard-trimmed main and backs the opposite trim")
	var port_jib_chord := AERO.headsail_clew_from_sheet(tack, clew, deg_to_rad(45.0)) - tack
	var port_jib := AERO.calculate_sail_forces_for_chord(Vector3.RIGHT * 8.0, Vector2(port_jib_chord.x, port_jib_chord.z), 5.16, 1.225, 1.25, 0.384, 0.08, 0.55, 0.9, 0.611, 0.873, 0.20)
	_expect(float(port_jib["wrong_side_lift_scale"]) > 0.99, "port wind and positive Jib sheet align the visual clew with the leeward side")
	var controller := AUTO_TRIM.new()
	var target := controller.update_from_snapshot(_snapshot(-90.0, 8.0, -90.0, 8.0))
	_expect(float(target["main_target_angle_rad"]) > 0.0 and float(target["headsail_target_angle_rad"]) > 0.0, "AUTO maps port-side AWA -90° to starboard-trimmed positive angles")
	controller.reset()
	target = controller.update_from_snapshot(_snapshot(90.0, 8.0, 90.0, 8.0))
	_expect(float(target["main_target_angle_rad"]) < 0.0 and float(target["headsail_target_angle_rad"]) < 0.0, "AUTO mirrors the target angle signs for starboard-side wind")


func _test_curves_and_limits() -> void:
	var points := [
		{"awa": 0.0, "main": 10.0, "jib": 10.0},
		{"awa": 30.0, "main": 10.0, "jib": 10.0},
		{"awa": 45.0, "main": 20.0, "jib": 15.0},
		{"awa": 60.0, "main": 30.0, "jib": 25.0},
		{"awa": 90.0, "main": 50.0, "jib": 40.0},
		{"awa": 120.0, "main": 60.0, "jib": 50.0},
		{"awa": 150.0, "main": 70.0, "jib": 60.0},
		{"awa": 180.0, "main": 75.0, "jib": 65.0},
	]
	for point in points:
		var controller := AUTO_TRIM.new()
		var result: Dictionary = controller.update_from_snapshot(_snapshot(-float(point["awa"]), 8.0, -90.0, 8.0))
		_expect(absf(rad_to_deg(float(result["main_target_angle_rad"])) - float(point["main"])) < 0.001, "main trim curve matches its %.0f° AWA control point" % float(point["awa"]))
		_expect(absf(rad_to_deg(float(result["headsail_target_angle_rad"])) - float(point["jib"])) < 0.001, "Jib trim curve matches its %.0f° AWA control point" % float(point["awa"]))
	var interpolation_controller := AUTO_TRIM.new()
	var lower: Dictionary = interpolation_controller.update_from_snapshot(_snapshot(-59.9, 8.0, -90.0, 8.0))
	var upper: Dictionary = interpolation_controller.update_from_snapshot(_snapshot(-60.1, 8.0, -90.0, 8.0))
	_expect(absf(float(upper["main_target_angle_rad"]) - float(lower["main_target_angle_rad"])) < deg_to_rad(0.15), "trim curve changes continuously across the 60° AWA control point")
	var limited: Dictionary = AUTO_TRIM.new().update_from_snapshot(_snapshot(-180.0, 8.0, -180.0, 8.0, -1.0, 1.0, -0.5, 0.5))
	_expect(float(limited["main_target_angle_rad"]) <= 1.0 and float(limited["headsail_target_angle_rad"]) <= 0.5, "AUTO respects asymmetric vessel-specific angle limits")
	var disabled_snapshot := _snapshot(-90.0, 8.0, -90.0, 8.0)
	disabled_snapshot["headsail_enabled"] = false
	disabled_snapshot["target_headsail_angle_rad"] = deg_to_rad(-17.0)
	var disabled_result: Dictionary = AUTO_TRIM.new().update_from_snapshot(disabled_snapshot)
	_expect(absf(float(disabled_result["headsail_target_angle_rad"]) - deg_to_rad(-17.0)) < 0.0001, "disabled Jib retains its previous target while AUTO can still trim the main")
	var configurable := AUTO_TRIM.new()
	var custom_main := PackedVector2Array([Vector2(0.0, 8.0), Vector2(60.0, 40.0), Vector2(180.0, 70.0)])
	var custom_jib := PackedVector2Array([Vector2(0.0, 6.0), Vector2(60.0, 30.0), Vector2(180.0, 60.0)])
	_expect(configurable.configure_curves(custom_main, custom_jib), "profile-provided monotonic AWA curves are accepted")
	var custom_result: Dictionary = configurable.update_from_snapshot(_snapshot(-90.0, 8.0, -90.0, 8.0))
	_expect(absf(rad_to_deg(float(custom_result["main_target_angle_rad"])) - 47.5) < 0.001, "configured mainsail curve is linearly interpolated")
	_expect(absf(rad_to_deg(float(custom_result["headsail_target_angle_rad"])) - 37.5) < 0.001, "configured headsail curve is linearly interpolated")
	var invalid_curve := PackedVector2Array([Vector2(0.0, 10.0), Vector2(180.0, 80.0), Vector2(60.0, 30.0)])
	_expect(not configurable.configure_curves(invalid_curve, custom_jib), "unordered profile curve points are rejected")
	custom_result = configurable.update_from_snapshot(_snapshot(-90.0, 8.0, -90.0, 8.0))
	_expect(absf(rad_to_deg(float(custom_result["main_target_angle_rad"])) - 47.5) < 0.001, "invalid curve update leaves the last valid curve active")


func _test_side_hysteresis_and_low_wind() -> void:
	var controller := AUTO_TRIM.new()
	var result: Dictionary = controller.update_from_snapshot(_snapshot(-90.0, 8.0, -90.0, 8.0))
	var selected_sign := float(result["trim_sign"])
	result = controller.update_from_snapshot(_snapshot(4.0, 8.0, 4.0, 8.0))
	_expect(float(result["trim_sign"]) == selected_sign, "heading-side selection is held inside the head-to-wind dead zone")
	result = controller.update_from_snapshot(_snapshot(179.0, 8.0, 179.0, 8.0))
	_expect(float(result["trim_sign"]) == selected_sign, "downwind angular seam does not flip the selected sheet side")
	result = controller.update_from_snapshot(_snapshot(-179.0, 8.0, -179.0, 8.0))
	_expect(float(result["trim_sign"]) == selected_sign, "crossing signed AWA through 180° retains the prior sheet side")
	var low_wind := _snapshot(90.0, 0.2, 90.0, 0.2)
	low_wind["target_sail_angle_rad"] = float(result["main_target_angle_rad"])
	low_wind["target_headsail_angle_rad"] = float(result["headsail_target_angle_rad"])
	var held: Dictionary = controller.update_from_snapshot(low_wind)
	_expect(not bool(held["updated"]) and float(held["trim_sign"]) == selected_sign, "low apparent wind holds its last side and target instead of oscillating")
	var no_go_controller := AUTO_TRIM.new()
	var no_go: Dictionary = no_go_controller.update_from_snapshot(_snapshot(-29.0, 8.0, -29.0, 8.0))
	_expect(bool(no_go["no_go"]), "AUTO reports NO-GO inside the 30° upwind entry threshold")
	no_go = no_go_controller.update_from_snapshot(_snapshot(-33.0, 8.0, -33.0, 8.0))
	_expect(bool(no_go["no_go"]), "NO-GO remains stable inside the 30–35° hysteresis band")
	no_go = no_go_controller.update_from_snapshot(_snapshot(-35.0, 8.0, -35.0, 8.0))
	_expect(not bool(no_go["no_go"]), "NO-GO clears at the 35° exit threshold")
	var calm: Dictionary = AUTO_TRIM.new().update_from_snapshot(_snapshot(0.0, 0.0, 0.0, 0.0))
	_expect(not bool(calm["no_go"]) and not bool(calm["updated"]), "zero wind keeps manual targets and does not claim an active NO-GO state")


func _test_lab_integration() -> void:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	var boat: RigidBody3D = lab.get_node("SailboatBody")
	var panel := lab.get_node("DebugPanel")
	var toggle := panel.find_child("AutoSailTrimToggle", true, false) as CheckButton
	var tabs := panel.find_child("SailboatDebugTabs", true, false) as TabContainer
	_expect(toggle != null and tabs != null and tabs.get_tab_count() == 6, "AUTO toggle is integrated in the existing sail tab without adding a tab")
	if boat.has_method("set_auto_sail_trim_enabled"):
		boat.call("set_dynamic_waves_enabled", false)
		boat.call("set_lab_test_wind", 8.0, 270.0)
		if toggle != null:
			toggle.button_pressed = true
		else:
			boat.call("set_auto_sail_trim_enabled", true)
		await physics_frame
		var navigation: Dictionary = boat.call("get_navigation_snapshot")
		_expect(bool(navigation.get("auto_sail_trim_enabled", false)), "the vessel exposes AUTO mode through its read-only navigation snapshot")
		_expect(float(navigation.get("target_sail_angle_rad", 0.0)) > 0.0 and float(navigation.get("target_headsail_angle_rad", 0.0)) > 0.0, "production body maps port crosswind to positive main and Jib targets")
		var debug: Dictionary = boat.call("get_debug_snapshot")
		_expect(int(debug.get("wind_query_count_per_tick", -1)) == 1, "AUTO consumes the cached wind snapshot and keeps one WindField query per physics tick")
		_expect(int(debug.get("wave_query_count_per_tick", -1)) == 0, "static-water integration does not add WaveSampler queries")
		boat.call("set_dynamic_waves_enabled", true)
		await physics_frame
		navigation = boat.call("get_navigation_snapshot")
		debug = boat.call("get_debug_snapshot")
		_expect(int(debug.get("wind_query_count_per_tick", -1)) == 1 and int(debug.get("wave_query_count_per_tick", -1)) == 4, "AUTO preserves one WindField and four WaveSampler queries in dynamic-wave mode")
		var profile: Resource = boat.get("profile")
		_expect(typeof(profile.get("auto_main_trim_curve_points_degrees")) == TYPE_PACKED_VECTOR2_ARRAY and typeof(profile.get("auto_headsail_trim_curve_points_degrees")) == TYPE_PACKED_VECTOR2_ARRAY, "AUTO curves are stored in the vessel profile resource")
		var profile_controller := AUTO_TRIM.new()
		var main_curve: PackedVector2Array = profile.get("auto_main_trim_curve_points_degrees")
		var jib_curve: PackedVector2Array = profile.get("auto_headsail_trim_curve_points_degrees")
		_expect(profile_controller.configure_curves(main_curve, jib_curve), "the calibrated vessel profile curves are accepted by AutoSailTrim")
		var tuned_port := profile_controller.update_from_snapshot(_snapshot(-80.2, 8.0, -90.0, 8.0))
		_expect(absf(rad_to_deg(float(tuned_port["main_target_angle_rad"])) - 60.0) < 0.1 and absf(rad_to_deg(float(tuned_port["headsail_target_angle_rad"])) - 55.0) < 0.1, "C7b calibrated trim anchors match the 8 m/s TWA 90° measured candidate")
		profile_controller.reset()
		var tuned_starboard := profile_controller.update_from_snapshot(_snapshot(108.1, 8.0, 120.0, 8.0))
		_expect(absf(rad_to_deg(float(tuned_starboard["main_target_angle_rad"])) + 79.9) < 0.1 and absf(rad_to_deg(float(tuned_starboard["headsail_target_angle_rad"])) + 70.0) < 0.1, "C7b high-AWA trim mirrors the measured port-side candidate on starboard tack")
		_expect(absf(float(navigation.get("actual_sail_angle_rad", 0.0))) <= float(profile.get("sail_rotation_speed_rad_s")) / float(Engine.physics_ticks_per_second) + 0.0001, "main sail actual angle follows the existing per-physics-step rotation limit")
		_expect(absf(float(navigation.get("actual_headsail_angle_rad", 0.0))) <= float(profile.get("headsail_rotation_speed_rad_s")) / float(Engine.physics_ticks_per_second) + 0.0001, "Jib actual angle follows its existing per-physics-step rotation limit")
		boat.call("set_dynamic_waves_enabled", false)
		boat.call("set_target_sail_angle", deg_to_rad(20.0))
		_expect(not bool(boat.call("get_auto_sail_trim_enabled")), "a manual sail target change automatically returns the body to MANUAL")
		if toggle != null:
			toggle.button_pressed = false
			toggle.button_pressed = true
			await physics_frame
			boat.call("set_target_rudder_angle", deg_to_rad(-10.0))
			_expect(bool(boat.call("get_auto_sail_trim_enabled")), "manual rudder control leaves automatic sail trim enabled")
			var jib_key := InputEventKey.new()
			jib_key.keycode = KEY_J
			jib_key.pressed = true
			boat.call("_input", jib_key)
			_expect(not bool(boat.call("get_auto_sail_trim_enabled")), "J/L manual Jib input takes control and switches AUTO back to MANUAL")
		boat.call("reset_to_neutral")
		await physics_frame
	lab.queue_free()
	await process_frame


func _snapshot(awa: float, aws: float, twa: float, tws: float, main_min: float = -1.396, main_max: float = 1.396, jib_min: float = -1.222, jib_max: float = 1.222) -> Dictionary:
	return {
		"apparent_wind_from_relative_degrees": awa,
		"apparent_wind_speed_mps": aws,
		"true_wind_from_relative_degrees": twa,
		"true_wind_speed_mps": tws,
		"sog_mps": 0.0,
		"target_sail_angle_rad": 0.0,
		"target_headsail_angle_rad": 0.0,
		"min_sail_angle_rad": main_min,
		"max_sail_angle_rad": main_max,
		"min_headsail_angle_rad": jib_min,
		"max_headsail_angle_rad": jib_max,
		"headsail_enabled": true,
	}


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[AUTO TRIM] " + description)
