extends SceneTree

const CASTING_SCRIPT := preload("res://scripts/boat_fishing_casting_system.gd")

var _failures := 0


func _initialize() -> void:
	_test_load_to_rod_bend_mapping()
	_test_visual_line_tension()
	_test_continuous_drag_adjustment()
	_test_directional_bend()
	_test_actual_reel_audio_targets()
	print("[P6.4.6.1] failures=%d" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_load_to_rod_bend_mapping() -> void:
	var light_load := CASTING_SCRIPT.calculate_rod_visual_bend_angle_deg(2.2, 18.0, 34.0, 0.6)
	var medium_load := CASTING_SCRIPT.calculate_rod_visual_bend_angle_deg(10.0, 18.0, 34.0, 0.6)
	var heavy_load := CASTING_SCRIPT.calculate_rod_visual_bend_angle_deg(30.0, 18.0, 34.0, 0.6)
	var over_reference := CASTING_SCRIPT.calculate_rod_visual_bend_angle_deg(1000.0, 18.0, 34.0, 0.6)
	_check(light_load > 8.0 and light_load < 12.0, "a herring-like 2.2 N load has a clearly visible bend target")
	_check(medium_load > light_load and medium_load < 30.0, "medium load bends more than a light load without reaching the cap")
	_check(heavy_load == 34.0 and over_reference == 34.0, "high and out-of-range loads are capped at the visual maximum")
	_check(CASTING_SCRIPT.calculate_rod_visual_bend_angle_deg(-4.0, 18.0, 34.0, 0.6) == 0.0, "negative tension cannot bend the rod")
	_check(CASTING_SCRIPT.calculate_rod_visual_bend_angle_deg(NAN, 18.0, 34.0, 0.6) == 0.0, "non-finite tension safely returns a neutral visual value")
	print("[P6.4.6.1][ROD] 2.2N=%.2fdeg 10N=%.2fdeg 30N=%.2fdeg" % [light_load, medium_load, heavy_load])


func _test_visual_line_tension() -> void:
	var slack := CASTING_SCRIPT.calculate_line_visual_slack_ratio(0.0, 8.0)
	var herring_load := CASTING_SCRIPT.calculate_line_visual_slack_ratio(2.2, 8.0)
	var taut := CASTING_SCRIPT.calculate_line_visual_slack_ratio(8.0, 8.0)
	_check(is_equal_approx(slack, 1.0), "an unloaded fight line keeps its natural slack")
	_check(herring_load < slack and herring_load > taut, "a light fish reduces but does not erase line sag")
	_check(is_equal_approx(taut, 0.0), "reference load visually straightens the line")
	_check(CASTING_SCRIPT.calculate_line_visual_slack_ratio(INF, 8.0) == 1.0, "invalid line load safely uses neutral slack")


func _test_continuous_drag_adjustment() -> void:
	var increased := CASTING_SCRIPT.calculate_drag_setting_after_input(0.3, false, true, 1.0, 0.35)
	var decreased := CASTING_SCRIPT.calculate_drag_setting_after_input(0.3, true, false, 1.0, 0.35)
	_check(is_equal_approx(increased, 0.65), "one second of R continuously increases the existing drag setting")
	_check(is_equal_approx(decreased, 0.0), "one second of Q lowers drag and clamps at the minimum")
	_check(is_equal_approx(CASTING_SCRIPT.calculate_drag_setting_after_input(0.9, false, true, 2.0, 0.35), 1.0), "continuous adjustment clamps at maximum drag")
	_check(is_equal_approx(CASTING_SCRIPT.calculate_drag_setting_after_input(0.3, true, true, 1.0, 0.35), 0.3), "holding Q and R together does not alter the setting")
	_check(is_equal_approx(CASTING_SCRIPT.calculate_drag_setting_after_input(0.3, false, true, 0.0, 0.35), 0.3), "zero-time input cannot change the setting")


func _test_directional_bend() -> void:
	var right := CASTING_SCRIPT.calculate_bend_direction_local(Vector3.RIGHT, Basis.IDENTITY)
	var left := CASTING_SCRIPT.calculate_bend_direction_local(Vector3.LEFT, Basis.IDENTITY)
	var aft := CASTING_SCRIPT.calculate_bend_direction_local(Vector3(0.0, 0.0, 1.0), Basis.IDENTITY)
	var invalid := CASTING_SCRIPT.calculate_bend_direction_local(Vector3(NAN, 0.0, 0.0), Basis.IDENTITY)
	_check(right.distance_to(Vector2.RIGHT) < 0.001, "rightward line pull bends in the corresponding rod-local direction")
	_check(left.distance_to(Vector2.LEFT) < 0.001, "leftward fish motion reverses the rod's bend direction")
	_check(aft.distance_to(Vector2.DOWN) < 0.001, "fore/aft line pull is represented in the rod's second bend axis")
	_check(invalid.is_finite() and invalid.distance_to(Vector2.RIGHT) < 0.001, "invalid direction uses a stable finite fallback")


func _test_actual_reel_audio_targets() -> void:
	var payout := CASTING_SCRIPT.get_boat_fishing_audio_targets(CASTING_SCRIPT.CastState.FIGHTING, 0.05, true, false, true, false, true)
	var reeling := CASTING_SCRIPT.get_boat_fishing_audio_targets(CASTING_SCRIPT.CastState.FIGHTING, -0.05, true, false, true, false, true)
	var held := CASTING_SCRIPT.get_boat_fishing_audio_targets(CASTING_SCRIPT.CastState.FIGHTING, 0.0, true, false, true, false, true)
	_check(bool(payout.get("drag", false)) and not bool(payout.get("reel_in", false)), "actual solver payout selects the drag sound even while reel input is held")
	_check(bool(reeling.get("reel_in", false)) and not bool(reeling.get("drag", false)), "actual inward line motion selects the reel-in sound")
	_check(not bool(held.get("drag", false)) and not bool(held.get("reel_in", false)), "zero actual line motion stops both reel loops")


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[P6.4.6.1] FAIL: " + description)
