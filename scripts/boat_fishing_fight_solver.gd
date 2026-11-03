class_name BoatFishingFightSolver
extends RefCounted

## Scene-independent P6.4.3 line/drag solver. It never owns canonical line length;
## callers pass the current length and apply the returned delta exactly once.

const DEFAULT_PROFILE_PATH := "res://resources/boat_fishing/line_profiles/standard_boat_fishing_line.tres"
const EPSILON := 0.000001
const MAX_FISH_PARTICIPANTS := 5

var _profile: BoatFishingLineProfile
var _drag_paying_out := false
var _break_danger_seconds := 0.0
var _transient_peak_n := 0.0
var _previous_effective_load_n := 0.0
var _has_previous_load := false
var _snapped := false
var _break_reason := ""
var _latest_snapshot: Dictionary = {}


func _init(profile: BoatFishingLineProfile = null) -> void:
	var candidate := profile if profile != null else ResourceLoader.load(DEFAULT_PROFILE_PATH) as BoatFishingLineProfile
	if candidate == null or not candidate.is_valid():
		_profile = null
		push_error("BoatFishingFightSolver requires a valid BoatFishingLineProfile")
	else:
		_profile = candidate
	reset_session()


func configure(profile: BoatFishingLineProfile) -> bool:
	if profile == null or not profile.is_valid():
		return false
	_profile = profile
	reset_session()
	return true


func reset_session() -> void:
	_drag_paying_out = false
	_break_danger_seconds = 0.0
	_transient_peak_n = 0.0
	_previous_effective_load_n = 0.0
	_has_previous_load = false
	_snapped = false
	_break_reason = ""
	_latest_snapshot = _empty_snapshot("")
	if _profile != null:
		_latest_snapshot["drag_setting"] = clampf(_profile.default_drag_setting, 0.0, 1.0)
		_latest_snapshot["drag_threshold_n"] = _profile.get_drag_threshold_n(_profile.default_drag_setting)


func solve_step(
	dt_real: float,
	current_line_length_m: float,
	minimum_line_length_m: float,
	maximum_line_length_m: float,
	reel_pressed: bool,
	drag_setting: float,
	fish_snapshots: Array = [],
	main_line_outward_direction: Vector3 = Vector3.ZERO
) -> Dictionary:
	if _profile == null:
		return _empty_snapshot("invalid_profile")
	var safe_dt := dt_real if is_finite(dt_real) and dt_real > 0.0 else 0.0
	var bounds := _sanitize_line_bounds(current_line_length_m, minimum_line_length_m, maximum_line_length_m)
	var current_length := float(bounds["current"])
	var minimum_length := float(bounds["minimum"])
	var maximum_length := float(bounds["maximum"])
	var safe_setting := clampf(drag_setting, 0.0, 1.0) if is_finite(drag_setting) else clampf(_profile.default_drag_setting, 0.0, 1.0)
	var drag_threshold := _profile.get_drag_threshold_n(safe_setting)
	var line_direction_valid := main_line_outward_direction.is_finite() and main_line_outward_direction.length_squared() > EPSILON
	var line_direction := main_line_outward_direction.normalized() if line_direction_valid else Vector3.ZERO
	var fish_load_result := _calculate_effective_fish_load(fish_snapshots, line_direction, line_direction_valid)
	var fish_load := float(fish_load_result["effective_load_n"])
	var participant_count := int(fish_load_result["participant_count"])

	if _snapped:
		return _store_snapshot(_make_snapshot(
			current_length, minimum_length, maximum_length, safe_setting, drag_threshold,
			fish_load, 0.0, 0.0, 0.0, false, participant_count,
			float(fish_load_result["maximum_branch_load_n"]), line_direction_valid, safe_dt > 0.0
		))

	var transient_average_n := _transient_peak_n
	if safe_dt > 0.0:
		transient_average_n = _advance_transient_peak(safe_dt, fish_load)
	else:
		_transient_peak_n = 0.0 if not _has_previous_load else _transient_peak_n

	var available_out_m := maxf(0.0, maximum_length - current_length)
	var available_in_m := maxf(0.0, current_length - minimum_length)
	var can_pay_out := available_out_m > EPSILON
	var deadband := _finite_nonnegative(_profile.drag_hysteresis_n, 0.0)
	if not can_pay_out:
		_drag_paying_out = false
	elif _drag_paying_out:
		if fish_load < drag_threshold - deadband:
			_drag_paying_out = false
	elif fish_load > drag_threshold + deadband:
		_drag_paying_out = true

	var desired_line_rate_mps := 0.0
	var desired_reel_in_rate_mps := 0.0
	var desired_line_out_rate_mps := 0.0
	if safe_dt > 0.0 and _drag_paying_out and fish_load > drag_threshold:
		var excess_n := fish_load - drag_threshold
		var full_speed_delta_n := maxf(EPSILON, _finite_nonnegative(_profile.payout_full_speed_force_delta_n, 30.0))
		desired_line_out_rate_mps = _finite_nonnegative(_profile.max_line_out_speed_mps, 0.0) * clampf(excess_n / full_speed_delta_n, 0.0, 1.0)
		desired_line_rate_mps = desired_line_out_rate_mps
	elif safe_dt > 0.0 and reel_pressed and not _drag_paying_out and fish_load <= drag_threshold:
		if available_in_m > EPSILON:
			var load_fraction := clampf(fish_load / maxf(drag_threshold, EPSILON), 0.0, 1.0)
			var reel_fraction := pow(maxf(0.0, 1.0 - load_fraction), maxf(0.1, _profile.reel_load_slowdown_exponent))
			desired_reel_in_rate_mps = _finite_nonnegative(_profile.reel_in_speed_mps, 0.0) * reel_fraction
			desired_line_rate_mps = -desired_reel_in_rate_mps

	var line_delta_m := _bound_line_delta(desired_line_rate_mps, safe_dt, current_length, minimum_length, maximum_length)
	var line_rate_mps := line_delta_m / safe_dt if safe_dt > 0.0 else 0.0
	var payout_active_seconds := 0.0
	var blocked_payout_seconds := 0.0
	if desired_line_out_rate_mps > EPSILON and safe_dt > 0.0:
		payout_active_seconds = minf(safe_dt, line_delta_m / desired_line_out_rate_mps)
		blocked_payout_seconds = maxf(0.0, safe_dt - payout_active_seconds)

	var reaches_maximum := current_length + line_delta_m >= maximum_length - EPSILON
	var paying_out_at_end := _drag_paying_out and desired_line_out_rate_mps > EPSILON and not reaches_maximum
	var steady_tension_n := minf(fish_load, drag_threshold) if paying_out_at_end else fish_load
	var end_tension_n := clampf(steady_tension_n + _transient_peak_n, 0.0, _safe_maximum_tension_n())
	var snapped_during_step := false
	var elapsed_before_snap := safe_dt

	if safe_dt > 0.0:
		if desired_line_out_rate_mps > EPSILON and payout_active_seconds > 0.0:
			var payout_tension := clampf(minf(fish_load, drag_threshold) + transient_average_n, 0.0, _safe_maximum_tension_n())
			var payout_result := _advance_break_danger(payout_tension, payout_active_seconds)
			if bool(payout_result["snapped"]):
				snapped_during_step = true
				elapsed_before_snap = float(payout_result["elapsed_s"])
				line_delta_m = minf(available_out_m, desired_line_out_rate_mps * elapsed_before_snap)
			else:
				elapsed_before_snap = payout_active_seconds
			if not snapped_during_step and blocked_payout_seconds > 0.0:
				var blocked_tension := clampf(fish_load + transient_average_n, 0.0, _safe_maximum_tension_n())
				var blocked_result := _advance_break_danger(blocked_tension, blocked_payout_seconds)
				if bool(blocked_result["snapped"]):
					snapped_during_step = true
					elapsed_before_snap += float(blocked_result["elapsed_s"])
					line_delta_m = available_out_m
				else:
					elapsed_before_snap = safe_dt
		else:
			var danger_tension_n := clampf(steady_tension_n + transient_average_n, 0.0, _safe_maximum_tension_n())
			var danger_result := _advance_break_danger(danger_tension_n, safe_dt)
			if bool(danger_result["snapped"]):
				snapped_during_step = true
				elapsed_before_snap = float(danger_result["elapsed_s"])
				if desired_reel_in_rate_mps > EPSILON:
					line_delta_m = -minf(available_in_m, desired_reel_in_rate_mps * elapsed_before_snap)

	if snapped_during_step:
		_snapped = true
		_break_reason = "continuous_high_tension"
		_drag_paying_out = false
		paying_out_at_end = false

	line_rate_mps = line_delta_m / safe_dt if safe_dt > 0.0 else 0.0
	var actual_line_out_rate_mps := maxf(0.0, line_rate_mps)
	var actual_reel_in_rate_mps := maxf(0.0, -line_rate_mps)
	if reaches_maximum and not _snapped:
		_drag_paying_out = false
		paying_out_at_end = false
		steady_tension_n = fish_load
		end_tension_n = clampf(steady_tension_n + _transient_peak_n, 0.0, _safe_maximum_tension_n())
	var frame := _make_snapshot(
		current_length, minimum_length, maximum_length, safe_setting, drag_threshold,
		fish_load, steady_tension_n, end_tension_n, line_rate_mps, paying_out_at_end,
		participant_count, float(fish_load_result["maximum_branch_load_n"]), line_direction_valid, safe_dt > 0.0
	)
	frame["line_delta_m"] = line_delta_m
	frame["reel_in_rate_mps"] = actual_reel_in_rate_mps
	frame["line_out_rate_mps"] = actual_line_out_rate_mps
	frame["transient_peak_n"] = _transient_peak_n
	frame["transient_peak_average_n"] = transient_average_n
	frame["break_danger_seconds"] = _break_danger_seconds
	frame["break_danger_ratio"] = clampf(_break_danger_seconds / maxf(EPSILON, _profile.break_danger_seconds_to_snap), 0.0, 1.0)
	frame["snapped"] = _snapped
	frame["break_reason"] = _break_reason
	frame["elapsed_before_snap_s"] = elapsed_before_snap if _snapped else 0.0
	frame["line_at_minimum"] = current_length + line_delta_m <= minimum_length + EPSILON
	frame["line_at_maximum"] = current_length + line_delta_m >= maximum_length - EPSILON
	return _store_snapshot(frame)


func get_read_only_snapshot() -> Dictionary:
	return _latest_snapshot.duplicate(true)


func is_snapped() -> bool:
	return _snapped


func _calculate_effective_fish_load(
	fish_snapshots: Array,
	line_direction: Vector3,
	line_direction_valid: bool
) -> Dictionary:
	var exponent := clampf(_finite_positive(_profile.multi_fish_load_exponent, 1.5), 1.0, 3.0)
	var directional_floor := clampf(_finite_nonnegative(_profile.minimum_directional_load_fraction, 0.25), 0.0, 1.0)
	var branch_limit := maxf(0.1, _finite_positive(_profile.maximum_single_fish_load_n, 500.0))
	var sum_power := 0.0
	var participant_count := 0
	var maximum_branch_load_n := 0.0
	var seen_catch_ids: Dictionary = {}
	for fish_variant in fish_snapshots:
		if not fish_variant is Dictionary:
			continue
		var fish: Dictionary = fish_variant
		var catch_id := str(fish.get("catch_id", ""))
		if not catch_id.is_empty():
			if seen_catch_ids.has(catch_id):
				continue
			seen_catch_ids[catch_id] = true
		if participant_count >= MAX_FISH_PARTICIPANTS:
			break
		participant_count += 1
		var raw_force := _finite_nonnegative(_as_float(fish.get("current_pull_n", 0.0), 0.0), 0.0)
		if raw_force <= 0.0:
			continue
		var force_n := minf(raw_force, branch_limit)
		var directional_factor := 1.0
		var direction_variant: Variant = fish.get("swim_direction", Vector3.ZERO)
		if line_direction_valid and typeof(direction_variant) == TYPE_VECTOR3:
			var fish_direction: Vector3 = direction_variant
			if fish_direction.is_finite() and fish_direction.length_squared() > EPSILON:
				var alignment := maxf(0.0, fish_direction.normalized().dot(line_direction))
				directional_factor = directional_floor + (1.0 - directional_floor) * alignment
			else:
				directional_factor = directional_floor
		elif line_direction_valid:
			directional_factor = directional_floor
		var branch_load_n := force_n * clampf(directional_factor, 0.0, 1.0)
		maximum_branch_load_n = maxf(maximum_branch_load_n, branch_load_n)
		sum_power += pow(branch_load_n, exponent)
	var effective_load := pow(maxf(0.0, sum_power), 1.0 / exponent)
	var effective_limit := maxf(0.1, _finite_positive(_profile.maximum_effective_fish_load_n, 1000.0))
	effective_load = minf(effective_limit, effective_load) if is_finite(effective_load) else effective_limit
	return {
		"effective_load_n": effective_load,
		"participant_count": participant_count,
		"maximum_branch_load_n": maximum_branch_load_n,
	}


func _advance_transient_peak(dt: float, effective_load_n: float) -> float:
	var previous_peak := _transient_peak_n
	var decay_tau := maxf(0.01, _finite_positive(_profile.transient_peak_decay_s, 0.55))
	var decay := exp(-dt / decay_tau)
	var delta_load := maxf(0.0, effective_load_n - _previous_effective_load_n) if _has_previous_load else 0.0
	var forcing_rate := _finite_nonnegative(_profile.transient_peak_gain, 0.0) * delta_load / dt
	var response_fraction := 1.0 - decay
	var peak_end := previous_peak * decay + forcing_rate * decay_tau * response_fraction
	var average_decay_fraction := decay_tau / dt * response_fraction
	var peak_average := previous_peak * average_decay_fraction + forcing_rate * decay_tau * (1.0 - average_decay_fraction)
	var peak_cap := _finite_nonnegative(_profile.transient_peak_cap_n, 0.0)
	_transient_peak_n = clampf(peak_end, 0.0, peak_cap)
	_previous_effective_load_n = effective_load_n
	_has_previous_load = true
	return clampf(peak_average, 0.0, peak_cap)


func _advance_break_danger(tension_n: float, duration_s: float) -> Dictionary:
	var safe_duration := _finite_nonnegative(duration_s, 0.0)
	if safe_duration <= 0.0:
		return {"snapped": false, "elapsed_s": 0.0}
	var break_force := maxf(EPSILON, _finite_positive(_profile.line_break_force_n, 68.0))
	var ratio := maxf(0.0, tension_n) / break_force
	var danger_rate := _danger_rate_for_ratio(ratio)
	if danger_rate > 0.0:
		var remaining_danger := maxf(0.0, _profile.break_danger_seconds_to_snap - _break_danger_seconds)
		var snap_time := remaining_danger / danger_rate
		if snap_time <= safe_duration:
			_break_danger_seconds = maxf(0.0, _profile.break_danger_seconds_to_snap)
			return {"snapped": true, "elapsed_s": snap_time}
		_break_danger_seconds = minf(_profile.break_danger_seconds_to_snap, _break_danger_seconds + danger_rate * safe_duration)
	else:
		_break_danger_seconds = maxf(0.0, _break_danger_seconds + danger_rate * safe_duration)
	return {"snapped": false, "elapsed_s": safe_duration}


func _danger_rate_for_ratio(ratio: float) -> float:
	var safe_ratio := clampf(_profile.danger_safe_ratio, 0.0, 1.0)
	var onset_ratio := maxf(safe_ratio, clampf(_profile.danger_onset_ratio, 0.0, 1.0))
	var limit_ratio := maxf(onset_ratio + 0.001, _profile.danger_limit_ratio)
	var severe_ratio := maxf(limit_ratio + 0.001, _profile.danger_severe_ratio)
	var recovery_rate := _finite_nonnegative(_profile.danger_recovery_rate, 1.8)
	if ratio < safe_ratio:
		return -recovery_rate
	if ratio < onset_ratio:
		return -recovery_rate * 0.25
	if ratio < limit_ratio:
		var t := clampf((ratio - onset_ratio) / (limit_ratio - onset_ratio), 0.0, 1.0)
		return lerpf(_finite_nonnegative(_profile.danger_rate_at_onset, 0.2), _finite_nonnegative(_profile.danger_rate_at_limit, 1.5), t)
	if ratio < severe_ratio:
		var t := clampf((ratio - limit_ratio) / (severe_ratio - limit_ratio), 0.0, 1.0)
		return lerpf(_finite_nonnegative(_profile.danger_rate_at_limit, 1.5), _finite_nonnegative(_profile.danger_rate_at_severe, 16.0), t)
	return _finite_nonnegative(_profile.danger_rate_at_severe, 16.0) + (ratio - severe_ratio) * _finite_nonnegative(_profile.danger_severe_rate_per_ratio, 80.0)


func _bound_line_delta(rate_mps: float, dt: float, current: float, minimum: float, maximum: float) -> float:
	if dt <= 0.0 or not is_finite(rate_mps) or absf(rate_mps) <= EPSILON:
		return 0.0
	if rate_mps > 0.0:
		var available := maxf(0.0, maximum - current)
		if available <= EPSILON:
			return 0.0
		if dt >= available / rate_mps:
			return available
		return rate_mps * dt
	var available_in := maxf(0.0, current - minimum)
	if available_in <= EPSILON:
		return 0.0
	var reel_rate := -rate_mps
	if dt >= available_in / reel_rate:
		return -available_in
	return rate_mps * dt


func _sanitize_line_bounds(current: float, minimum: float, maximum: float) -> Dictionary:
	var safe_min := _finite_nonnegative(minimum, 0.0)
	var safe_max := _finite_nonnegative(maximum, 100.0)
	if safe_max < safe_min:
		safe_max = safe_min
	var safe_current := current if is_finite(current) else safe_min
	safe_current = clampf(safe_current, safe_min, safe_max)
	return {"current": safe_current, "minimum": safe_min, "maximum": safe_max}


func _make_snapshot(
	current_length: float,
	minimum_length: float,
	maximum_length: float,
	drag_setting: float,
	drag_threshold: float,
	fish_load: float,
	steady_tension: float,
	tension: float,
	line_rate: float,
	drag_paying_out: bool,
	participant_count: int,
	maximum_branch_load: float,
	line_direction_valid: bool,
	valid_dt: bool
) -> Dictionary:
	var break_force := maxf(EPSILON, _finite_positive(_profile.line_break_force_n, 68.0))
	return {
		"input_valid": valid_dt,
		"line_length_input_m": current_length,
		"minimum_line_length_m": minimum_length,
		"maximum_line_length_m": maximum_length,
		"line_delta_m": 0.0,
		"effective_fish_load_n": fish_load,
		"maximum_branch_load_n": maximum_branch_load,
		"participant_count": participant_count,
		"steady_tension_n": steady_tension,
		"tension_n": tension,
		"tension_ratio": tension / break_force,
		"drag_setting": drag_setting,
		"drag_threshold_n": drag_threshold,
		"line_rate_mps": line_rate,
		"reel_in_rate_mps": maxf(0.0, -line_rate),
		"line_out_rate_mps": maxf(0.0, line_rate),
		"drag_paying_out": drag_paying_out,
		"transient_peak_n": _transient_peak_n,
		"transient_peak_average_n": _transient_peak_n,
		"break_danger_seconds": _break_danger_seconds,
		"break_danger_ratio": clampf(_break_danger_seconds / maxf(EPSILON, _profile.break_danger_seconds_to_snap), 0.0, 1.0),
		"snapped": _snapped,
		"break_reason": _break_reason,
		"line_direction_valid": line_direction_valid,
		"line_at_minimum": current_length <= minimum_length + EPSILON,
		"line_at_maximum": current_length >= maximum_length - EPSILON,
	}


func _empty_snapshot(reason: String) -> Dictionary:
	return {
		"input_valid": false,
		"effective_fish_load_n": 0.0,
		"maximum_branch_load_n": 0.0,
		"participant_count": 0,
		"steady_tension_n": 0.0,
		"tension_n": 0.0,
		"tension_ratio": 0.0,
		"drag_setting": 0.0,
		"drag_threshold_n": 0.0,
		"line_rate_mps": 0.0,
		"line_delta_m": 0.0,
		"reel_in_rate_mps": 0.0,
		"line_out_rate_mps": 0.0,
		"drag_paying_out": false,
		"break_danger_seconds": 0.0,
		"break_danger_ratio": 0.0,
		"transient_peak_n": 0.0,
		"transient_peak_average_n": 0.0,
		"snapped": false,
		"break_reason": reason,
		"line_direction_valid": false,
		"line_at_minimum": false,
		"line_at_maximum": false,
		"line_length_input_m": 0.0,
		"minimum_line_length_m": 0.0,
		"maximum_line_length_m": 0.0,
	}


func _store_snapshot(snapshot: Dictionary) -> Dictionary:
	_latest_snapshot = snapshot.duplicate(true)
	return _latest_snapshot.duplicate(true)


func _safe_maximum_tension_n() -> float:
	return maxf(1.0, _finite_positive(_profile.maximum_instantaneous_tension_n, _profile.line_break_force_n * 2.0))


static func _as_float(value: Variant, fallback: float) -> float:
	if typeof(value) != TYPE_FLOAT and typeof(value) != TYPE_INT:
		return fallback
	var converted := float(value)
	return converted if is_finite(converted) else fallback


static func _finite_nonnegative(value: float, fallback: float) -> float:
	return maxf(0.0, value) if is_finite(value) else fallback


static func _finite_positive(value: float, fallback: float) -> float:
	return value if is_finite(value) and value > EPSILON else fallback
