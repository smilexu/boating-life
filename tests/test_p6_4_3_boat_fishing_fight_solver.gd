extends SceneTree

const SOLVER_SCRIPT := preload("res://scripts/boat_fishing_fight_solver.gd")
const PROFILE_CATALOG := preload("res://scripts/boat_fishing_fight_profile_catalog.gd")
const LINE_PROFILE: BoatFishingLineProfile = preload("res://resources/boat_fishing/line_profiles/standard_boat_fishing_line.tres")

const LINE_MIN := 0.55
const LINE_MAX := 100.0
const LINE_OUT := Vector3.RIGHT

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_profile_and_empty_line()
	_test_drag_reel_and_pay_out()
	_test_multifish_load()
	_test_transient_peak()
	_test_break_danger_and_reset()
	_test_line_bounds_invalid_inputs_and_large_dt()
	_test_update_rate_consistency()
	_test_participant_limit_and_deduplication()
	_test_numeric_report_examples()
	print("[P6.4.3] failures=%d" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_profile_and_empty_line() -> void:
	var solver := _new_solver()
	_check(LINE_PROFILE.is_valid(), "standard boat line profile loads and validates")
	_check(is_equal_approx(LINE_PROFILE.line_break_force_n, 68.0), "initial main-line break force is 68 N")
	_check(is_equal_approx(LINE_PROFILE.get_drag_threshold_n(0.0), 4.0), "drag setting 0 maps to minimum force")
	_check(is_equal_approx(LINE_PROFILE.get_drag_threshold_n(1.0), 52.0), "drag setting 1 maps to maximum force")
	_check(is_equal_approx(LINE_PROFILE.get_drag_threshold_n(LINE_PROFILE.default_drag_setting), 18.4), "default drag setting maps to its configured threshold")
	var invalid_profile := BoatFishingLineProfile.new()
	invalid_profile.danger_onset_ratio = 1.1
	_check(not invalid_profile.is_valid(), "invalid danger thresholds reject a malformed line profile")
	var idle: Dictionary = solver.solve_step(1.0, 10.0, LINE_MIN, LINE_MAX, false, 0.3, [], LINE_OUT)
	_check(is_equal_approx(float(idle.get("line_rate_mps", -1.0)), 0.0) and is_equal_approx(float(idle.get("line_delta_m", -1.0)), 0.0), "no fish and no reel input holds line length")
	_check(is_equal_approx(float(idle.get("tension_n", -1.0)), 0.0), "empty tackle produces zero tension")
	var reeling: Dictionary = solver.solve_step(1.0, 10.0, LINE_MIN, LINE_MAX, true, 0.3, [], LINE_OUT)
	_check(is_equal_approx(float(reeling.get("line_rate_mps", 0.0)), -0.65), "empty tackle reels at configured rate")
	_check(is_equal_approx(float(reeling.get("line_delta_m", 0.0)), -0.65), "solver returns one authoritative-step delta without storing length")


func _test_drag_reel_and_pay_out() -> void:
	var herring := _fish(5.17, LINE_OUT)
	var holding := _new_solver()
	var below_drag: Dictionary = holding.solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, 0.3, [herring], LINE_OUT)
	_check(not bool(below_drag.get("drag_paying_out", true)) and is_equal_approx(float(below_drag.get("line_rate_mps", 1.0)), 0.0), "fish below drag does not cause passive payout")
	_check(is_equal_approx(float(below_drag.get("tension_n", 0.0)), 5.17), "sub-drag tension follows the effective single-fish load")

	var lower_drag := _new_solver()
	var higher_drag := _new_solver()
	var medium_fish := _fish(30.0, LINE_OUT)
	var low_result: Dictionary = lower_drag.solve_step(0.2, 20.0, LINE_MIN, LINE_MAX, false, 0.1, [medium_fish], LINE_OUT)
	var high_result: Dictionary = higher_drag.solve_step(0.2, 20.0, LINE_MIN, LINE_MAX, false, 0.9, [medium_fish], LINE_OUT)
	_check(float(low_result.get("line_out_rate_mps", 0.0)) > 0.0, "low drag allows a strong fish to pay line out")
	_check(is_equal_approx(float(high_result.get("line_out_rate_mps", 1.0)), 0.0), "higher drag resists the same fish load")
	_check(float(low_result.get("drag_threshold_n", INF)) < float(high_result.get("drag_threshold_n", 0.0)), "lower drag setting reduces the payout threshold")
	_check(float(low_result.get("line_delta_m", 0.0)) > 0.0, "payout uses positive line delta")

	var reeling_solver := _new_solver()
	var trout := _fish(35.0, LINE_OUT)
	var held_reel: Dictionary = reeling_solver.solve_step(0.2, 20.0, LINE_MIN, LINE_MAX, true, 0.3, [trout], LINE_OUT)
	_check(float(held_reel.get("line_out_rate_mps", 0.0)) > 0.0 and is_equal_approx(float(held_reel.get("reel_in_rate_mps", -1.0)), 0.0), "strong fish payout overrides held reel input")
	_check(float(held_reel.get("steady_tension_n", 0.0)) <= float(held_reel.get("drag_threshold_n", 0.0)) + 0.001, "sustained payout tension is limited near the drag threshold")

	var reel_slowdown := _new_solver()
	var low_load_reel: Dictionary = reel_slowdown.solve_step(0.2, 20.0, LINE_MIN, LINE_MAX, true, 0.9, [_fish(8.0, LINE_OUT)], LINE_OUT)
	var high_load_reel_solver := _new_solver()
	var high_load_reel: Dictionary = high_load_reel_solver.solve_step(0.2, 20.0, LINE_MIN, LINE_MAX, true, 0.9, [_fish(40.0, LINE_OUT)], LINE_OUT)
	_check(float(low_load_reel.get("reel_in_rate_mps", 0.0)) > float(high_load_reel.get("reel_in_rate_mps", INF)), "larger fish load slows active reeling")


func _test_multifish_load() -> void:
	var one := _new_solver()
	var five_herring: Array = []
	for _index in range(5):
		five_herring.append(_fish(5.17, LINE_OUT))
	var single_result: Dictionary = one.solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, 0.3, [_fish(5.17, LINE_OUT)], LINE_OUT)
	var group_solver := _new_solver()
	var group_result: Dictionary = group_solver.solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, 0.3, five_herring, LINE_OUT)
	var expected_group_load := 5.17 * pow(5.0, 1.0 / 1.5)
	_check(is_equal_approx(float(single_result.get("effective_fish_load_n", 0.0)), 5.17), "one aligned fish contributes its projected pull")
	_check(is_equal_approx(float(group_result.get("effective_fish_load_n", 0.0)), expected_group_load), "five aligned fish use the configured sublinear L-p norm")
	_check(int(group_result.get("participant_count", 0)) == 5, "solver counts five independent fish participants")
	_check(float(group_result.get("effective_fish_load_n", 0.0)) > 5.17 and float(group_result.get("effective_fish_load_n", INF)) < 5.17 * 5.0, "group load is greater than one fish and below unconditional sum")

	var opposing_solver := _new_solver()
	var opposing: Dictionary = opposing_solver.solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, 0.3, [_fish(10.0, LINE_OUT), _fish(10.0, Vector3.LEFT)], LINE_OUT)
	_check(float(opposing.get("effective_fish_load_n", 0.0)) > 10.0, "opposing branch directions cannot cancel one another to zero")
	_check(is_finite(float(opposing.get("effective_fish_load_n", NAN))), "multi-fish load remains finite")

	var invalid_direction_solver := _new_solver()
	var invalid_direction: Dictionary = invalid_direction_solver.solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, 0.3, [_fish(10.0, Vector3.ZERO)], Vector3.ZERO)
	_check(is_equal_approx(float(invalid_direction.get("effective_fish_load_n", 0.0)), 10.0), "invalid line direction conservatively uses the full valid fish load")


func _test_transient_peak() -> void:
	var solver := _new_solver()
	solver.solve_step(0.05, 20.0, LINE_MIN, LINE_MAX, false, 0.3, [], LINE_OUT)
	var jump: Dictionary = solver.solve_step(0.05, 20.0, LINE_MIN, LINE_MAX, false, 0.3, [_fish(35.0, LINE_OUT)], LINE_OUT)
	var peak := float(jump.get("transient_peak_n", 0.0))
	_check(peak > 0.0 and peak <= LINE_PROFILE.transient_peak_cap_n, "rising fish load produces a bounded deterministic transient peak")
	_check(float(jump.get("tension_n", 0.0)) > float(jump.get("steady_tension_n", INF)), "transient peak is distinct from sustained tension")
	var repeated: Dictionary = solver.solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, 0.3, [_fish(35.0, LINE_OUT)], LINE_OUT)
	_check(float(repeated.get("transient_peak_n", INF)) < peak, "unchanged force lets a transient peak decay instead of accumulating")
	_check(float(repeated.get("tension_n", INF)) < float(jump.get("tension_n", 0.0)), "transient tension decays with real elapsed time")
	var peak_at_maximum := _new_solver()
	peak_at_maximum.solve_step(0.05, LINE_MAX, LINE_MIN, LINE_MAX, false, 0.3, [], LINE_OUT)
	var peak_danger: Dictionary = peak_at_maximum.solve_step(0.05, LINE_MAX, LINE_MIN, LINE_MAX, false, 0.3, [_fish(45.0, LINE_OUT)], LINE_OUT)
	_check(float(peak_danger.get("break_danger_seconds", 0.0)) > 0.0, "bounded transient peak contributes briefly to overload danger when payout is blocked")


func _test_break_danger_and_reset() -> void:
	var safe_solver := _new_solver()
	var sixty_percent := 68.0 * 0.6
	var safe: Dictionary = safe_solver.solve_step(10.0, LINE_MAX, LINE_MIN, LINE_MAX, false, 0.3, [_fish(sixty_percent, LINE_OUT)], LINE_OUT)
	_check(not bool(safe.get("snapped", true)) and is_equal_approx(float(safe.get("break_danger_seconds", -1.0)), 0.0), "60 percent line load is safe for ten real seconds")

	var danger_solver := _new_solver()
	var ninety_percent := 68.0 * 0.9
	var danger: Dictionary = danger_solver.solve_step(3.0, LINE_MAX, LINE_MIN, LINE_MAX, false, 0.3, [_fish(ninety_percent, LINE_OUT)], LINE_OUT)
	_check(float(danger.get("break_danger_seconds", 0.0)) > 0.0 and not bool(danger.get("snapped", true)), "90 percent sustained load accumulates gradual danger")
	var above_break: Dictionary = _new_solver().solve_step(0.1, LINE_MAX, LINE_MIN, LINE_MAX, false, 0.3, [_fish(68.0 * 1.1, LINE_OUT)], LINE_OUT)
	_check(float(above_break.get("break_danger_seconds", 0.0)) > float(danger.get("break_danger_seconds", INF)) / 30.0, "load above line strength accumulates danger faster than 90 percent load")
	var snapped: Dictionary = danger_solver.solve_step(5.0, LINE_MAX, LINE_MIN, LINE_MAX, false, 0.3, [_fish(ninety_percent, LINE_OUT)], LINE_OUT)
	_check(bool(snapped.get("snapped", false)) and str(snapped.get("break_reason", "")) == "continuous_high_tension", "continued high load deterministically snaps after its danger threshold")
	_check(is_equal_approx(float(snapped.get("line_rate_mps", 1.0)), 0.0), "snapped solver stops further line movement")
	var snapped_copy: Dictionary = danger_solver.get_read_only_snapshot()
	snapped_copy["snapped"] = false
	_check(bool(danger_solver.get_read_only_snapshot().get("snapped", false)), "snapshot mutation cannot clear solver break state")

	var overload_solver := _new_solver()
	var overload: Dictionary = overload_solver.solve_step(0.2, LINE_MAX, LINE_MIN, LINE_MAX, false, 0.3, [_fish(90.0, LINE_OUT)], LINE_OUT)
	_check(bool(overload.get("snapped", false)), "severe overload snaps rapidly and deterministically")

	var recovery_solver := _new_solver()
	recovery_solver.solve_step(1.0, LINE_MAX, LINE_MIN, LINE_MAX, false, 0.3, [_fish(ninety_percent, LINE_OUT)], LINE_OUT)
	var before_recovery := float(recovery_solver.get_read_only_snapshot().get("break_danger_seconds", 0.0))
	var recovered: Dictionary = recovery_solver.solve_step(1.0, LINE_MAX, LINE_MIN, LINE_MAX, false, 0.3, [_fish(68.0 * 0.6, LINE_OUT)], LINE_OUT)
	_check(float(recovered.get("break_danger_seconds", INF)) < before_recovery, "safe tension quickly clears short-term danger")
	recovery_solver.reset_session()
	_check(is_equal_approx(float(recovery_solver.get_read_only_snapshot().get("break_danger_seconds", -1.0)), 0.0) and not recovery_solver.is_snapped(), "reset starts a fresh fight without inherited danger")


func _test_line_bounds_invalid_inputs_and_large_dt() -> void:
	var maximum_solver := _new_solver()
	var at_max: Dictionary = maximum_solver.solve_step(1.0, LINE_MAX, LINE_MIN, LINE_MAX, false, 0.1, [_fish(40.0, LINE_OUT)], LINE_OUT)
	_check(is_equal_approx(float(at_max.get("line_out_rate_mps", 1.0)), 0.0) and is_equal_approx(float(at_max.get("line_delta_m", 1.0)), 0.0), "maximum line length blocks further payout")
	_check(is_equal_approx(float(at_max.get("tension_n", 0.0)), 40.0), "fish load reaches line tension when maximum payout is blocked")
	var minimum_solver := _new_solver()
	var at_min: Dictionary = minimum_solver.solve_step(1.0, LINE_MIN, LINE_MIN, LINE_MAX, true, 0.3, [], LINE_OUT)
	_check(is_equal_approx(float(at_min.get("line_rate_mps", -1.0)), 0.0), "minimum line length blocks further reeling")
	var zero_time: Dictionary = minimum_solver.solve_step(0.0, 10.0, LINE_MIN, LINE_MAX, true, 0.3, [], LINE_OUT)
	var negative_time: Dictionary = minimum_solver.solve_step(-1.0, 10.0, LINE_MIN, LINE_MAX, true, 0.3, [], LINE_OUT)
	_check(is_equal_approx(float(zero_time.get("line_delta_m", 1.0)), 0.0) and is_equal_approx(float(negative_time.get("line_delta_m", 1.0)), 0.0), "zero and negative dt cannot move line")
	var nan_time: Dictionary = minimum_solver.solve_step(NAN, 10.0, LINE_MIN, LINE_MAX, true, 0.3, [], LINE_OUT)
	_check(is_equal_approx(float(nan_time.get("line_rate_mps", 1.0)), 0.0), "non-finite dt is safely rejected")
	var invalid_force_solver := _new_solver()
	var invalid_force: Dictionary = invalid_force_solver.solve_step(0.1, 10.0, LINE_MIN, LINE_MAX, false, 0.3, [_fish(INF, LINE_OUT)], LINE_OUT)
	_check(is_equal_approx(float(invalid_force.get("effective_fish_load_n", -1.0)), 0.0) and is_finite(float(invalid_force.get("tension_n", NAN))), "non-finite fish force cannot poison the solver")
	var huge_force: Dictionary = invalid_force_solver.solve_step(0.1, 10.0, LINE_MIN, LINE_MAX, false, 0.3, [_fish(1.0e100, LINE_OUT)], LINE_OUT)
	_check(float(huge_force.get("effective_fish_load_n", INF)) <= LINE_PROFILE.maximum_effective_fish_load_n, "extreme finite force is bounded")
	var extreme_solver := _new_solver()
	var extreme: Dictionary = extreme_solver.solve_step(600.0, LINE_MAX, LINE_MIN, LINE_MAX, false, 0.3, [_fish(68.0 * 0.6, LINE_OUT)], LINE_OUT)
	_check(is_finite(float(extreme.get("tension_n", NAN))) and is_finite(float(extreme.get("break_danger_seconds", NAN))), "600 second dt is advanced without overflow or a substep loop")


func _test_update_rate_consistency() -> void:
	var thirty_solver := _new_solver()
	var sixty_solver := _new_solver()
	var line_30 := 20.0
	var line_60 := 20.0
	var load := [_fish(8.0, LINE_OUT)]
	for _index in range(300):
		var result_30: Dictionary = thirty_solver.solve_step(1.0 / 30.0, line_30, LINE_MIN, LINE_MAX, true, 0.9, load, LINE_OUT)
		line_30 = clampf(line_30 + float(result_30.get("line_delta_m", 0.0)), LINE_MIN, LINE_MAX)
	for _index in range(600):
		var result_60: Dictionary = sixty_solver.solve_step(1.0 / 60.0, line_60, LINE_MIN, LINE_MAX, true, 0.9, load, LINE_OUT)
		line_60 = clampf(line_60 + float(result_60.get("line_delta_m", 0.0)), LINE_MIN, LINE_MAX)
	_check(absf(line_30 - line_60) < 0.001, "30 and 60 FPS produce matching line length over the same ten real seconds")
	_check(absf(float(thirty_solver.get_read_only_snapshot().get("tension_n", INF)) - float(sixty_solver.get_read_only_snapshot().get("tension_n", 0.0))) < 0.001, "30 and 60 FPS produce matching steady tension")


func _test_participant_limit_and_deduplication() -> void:
	var repeated_fish := _fish(10.0, LINE_OUT, "catch-a")
	var duplicate_result: Dictionary = _new_solver().solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, 0.3, [repeated_fish, repeated_fish], LINE_OUT)
	_check(is_equal_approx(float(duplicate_result.get("effective_fish_load_n", 0.0)), 10.0) and int(duplicate_result.get("participant_count", 0)) == 1, "duplicate catch identity is counted only once")
	var more_than_five: Array = []
	for index in range(6):
		more_than_five.append(_fish(10.0, LINE_OUT, "catch-%d" % index))
	var capped: Dictionary = _new_solver().solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, 0.3, more_than_five, LINE_OUT)
	var expected_five := 10.0 * pow(5.0, 1.0 / 1.5)
	_check(int(capped.get("participant_count", 0)) == 5 and is_equal_approx(float(capped.get("effective_fish_load_n", 0.0)), expected_five), "solver accepts no more than five unique fish participants")


func _test_numeric_report_examples() -> void:
	var herring_profile: BoatFishingFightProfile = PROFILE_CATALOG.load_profile("herring")
	var trout_profile: BoatFishingFightProfile = PROFILE_CATALOG.load_profile("sea_trout")
	_check(herring_profile != null and trout_profile != null, "solver examples use the configured herring and sea trout profiles")
	if herring_profile == null or trout_profile == null:
		return
	var herring_burst := herring_profile.get_bounded_pull_n(herring_profile.base_pull_n * herring_profile.burst_multiplier)
	var herring_result: Dictionary = _new_solver().solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, LINE_PROFILE.default_drag_setting, [_fish(herring_burst, LINE_OUT)], LINE_OUT)
	_check(is_equal_approx(float(herring_result.get("tension_n", 0.0)), herring_burst) and is_equal_approx(float(herring_result.get("line_rate_mps", 1.0)), 0.0), "reference-size herring example holds line below default drag")
	var trout_burst := trout_profile.get_bounded_pull_n(trout_profile.base_pull_n * trout_profile.burst_multiplier)
	var trout_result: Dictionary = _new_solver().solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, LINE_PROFILE.default_drag_setting, [_fish(trout_burst, LINE_OUT)], LINE_OUT)
	_check(float(trout_result.get("line_out_rate_mps", 0.0)) > 0.0 and is_equal_approx(float(trout_result.get("steady_tension_n", 0.0)), LINE_PROFILE.get_drag_threshold_n(LINE_PROFILE.default_drag_setting)), "reference-size sea trout burst pays line at the default setting")
	var trout_low_drag: Dictionary = _new_solver().solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, 0.1, [_fish(trout_burst, LINE_OUT)], LINE_OUT)
	var trout_high_drag: Dictionary = _new_solver().solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, 0.9, [_fish(trout_burst, LINE_OUT)], LINE_OUT)
	_check(float(trout_low_drag.get("line_out_rate_mps", 0.0)) > float(trout_result.get("line_out_rate_mps", 0.0)) and is_equal_approx(float(trout_high_drag.get("line_out_rate_mps", -1.0)), 0.0), "same sea trout burst pays out faster at low drag and holds at high drag")
	var five_herring: Array = []
	for index in range(5):
		five_herring.append(_fish(herring_burst, LINE_OUT, "example-herring-%d" % index))
	var group_solver := _new_solver()
	var group_result: Dictionary = group_solver.solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, true, LINE_PROFILE.default_drag_setting, five_herring, LINE_OUT)
	var group_low_drag: Dictionary = _new_solver().solve_step(0.1, 20.0, LINE_MIN, LINE_MAX, false, 0.1, five_herring, LINE_OUT)
	var group_load := herring_burst * pow(5.0, 1.0 / LINE_PROFILE.multi_fish_load_exponent)
	_check(is_equal_approx(float(group_result.get("effective_fish_load_n", 0.0)), group_load) and float(group_result.get("reel_in_rate_mps", 0.0)) > 0.0, "five-herring example produces sublinear load while actively reeling")
	_check(float(group_low_drag.get("line_out_rate_mps", 0.0)) > 0.0 and is_equal_approx(float(group_low_drag.get("steady_tension_n", 0.0)), LINE_PROFILE.get_drag_threshold_n(0.1)), "five-herring load pays line at low drag and remains capped during payout")
	print("[P6.4.3][EXAMPLE] Herring burst: load=%.2fN, tension=%.2fN, rate=%.3fm/s, danger=%.3fs" % [float(herring_result["effective_fish_load_n"]), float(herring_result["tension_n"]), float(herring_result["line_rate_mps"]), float(herring_result["break_danger_seconds"])])
	print("[P6.4.3][EXAMPLE] Sea trout drag=0.1: load=%.2fN, tension=%.2fN, drag=%.2fN, out=%.3fm/s, danger=%.3fs" % [float(trout_low_drag["effective_fish_load_n"]), float(trout_low_drag["tension_n"]), float(trout_low_drag["drag_threshold_n"]), float(trout_low_drag["line_out_rate_mps"]), float(trout_low_drag["break_danger_seconds"])])
	print("[P6.4.3][EXAMPLE] Sea trout drag=0.3: load=%.2fN, tension=%.2fN, drag=%.2fN, out=%.3fm/s, danger=%.3fs" % [float(trout_result["effective_fish_load_n"]), float(trout_result["tension_n"]), float(trout_result["drag_threshold_n"]), float(trout_result["line_out_rate_mps"]), float(trout_result["break_danger_seconds"])])
	print("[P6.4.3][EXAMPLE] Sea trout drag=0.9: load=%.2fN, tension=%.2fN, drag=%.2fN, out=%.3fm/s, danger=%.3fs" % [float(trout_high_drag["effective_fish_load_n"]), float(trout_high_drag["tension_n"]), float(trout_high_drag["drag_threshold_n"]), float(trout_high_drag["line_out_rate_mps"]), float(trout_high_drag["break_danger_seconds"])])
	print("[P6.4.3][EXAMPLE] Five herring drag=0.3 + reel: load=%.2fN, tension=%.2fN, reel=%.3fm/s, danger=%.3fs" % [float(group_result["effective_fish_load_n"]), float(group_result["tension_n"]), float(group_result["reel_in_rate_mps"]), float(group_result["break_danger_seconds"])])
	print("[P6.4.3][EXAMPLE] Five herring drag=0.1: load=%.2fN, tension=%.2fN, out=%.3fm/s, danger=%.3fs" % [float(group_low_drag["effective_fish_load_n"]), float(group_low_drag["tension_n"]), float(group_low_drag["line_out_rate_mps"]), float(group_low_drag["break_danger_seconds"])])


func _new_solver() -> BoatFishingFightSolver:
	return SOLVER_SCRIPT.new(LINE_PROFILE) as BoatFishingFightSolver


func _fish(force_n: float, swim_direction: Vector3, catch_id: String = "") -> Dictionary:
	return {"current_pull_n": force_n, "swim_direction": swim_direction, "catch_id": catch_id}


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[P6.4.3][PASS] %s" % message)
	else:
		_failures += 1
		push_error("[P6.4.3][FAIL] %s" % message)
