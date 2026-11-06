class_name FishSchoolDisturbanceModel
extends RefCounted

## Small deterministic model shared by the local fish authority and focused
## tests. Configuration is supplied by FishResourceManager's Inspector fields.


static func vessel_disturbance(snapshot: Dictionary, config: Dictionary) -> Dictionary:
	var speed_mps := _safe_abs(float(snapshot.get("speed_mps", 0.0)))
	var engine_data_available := bool(snapshot.get("engine_data_available", false))
	var engine_running := engine_data_available and bool(snapshot.get("engine_running", false))
	var throttle := clampf(_safe_nonnegative(float(snapshot.get("throttle_demand", 0.0))), 0.0, 1.0)
	var intensity := 0.0
	var mode := "engine_data_unavailable"
	if engine_running:
		var idle := _config_value(config, "engine_idle", 0.30)
		var low := _config_value(config, "engine_low_speed", 0.50)
		var cruise := _config_value(config, "engine_cruise", 0.80)
		var high := _config_value(config, "engine_high_speed", 1.0)
		var idle_speed := _config_value(config, "engine_idle_speed_mps", 0.25)
		var low_speed := maxf(idle_speed + 0.01, _config_value(config, "engine_low_speed_end_mps", 1.5))
		var cruise_speed := maxf(low_speed + 0.01, _config_value(config, "engine_cruise_speed_end_mps", 5.5))
		var high_speed := maxf(cruise_speed + 0.01, _config_value(config, "engine_high_speed_end_mps", 8.0))
		if speed_mps <= idle_speed:
			intensity = idle
			mode = "engine_idle"
		elif speed_mps <= low_speed:
			intensity = low
			mode = "powered_low_speed"
		elif speed_mps <= cruise_speed:
			intensity = lerpf(low, cruise, inverse_lerp(low_speed, cruise_speed, speed_mps))
			mode = "powered_cruise"
		elif speed_mps <= high_speed:
			intensity = lerpf(cruise, high, inverse_lerp(cruise_speed, high_speed, speed_mps))
			mode = "powered_high_speed"
		else:
			intensity = high
			mode = "powered_high_speed"
		var throttle_intensity := lerpf(idle, cruise, throttle)
		intensity = maxf(intensity, throttle_intensity)
	else:
		var still_speed := _config_value(config, "off_still_speed_mps", 0.08)
		var drift := _config_value(config, "engine_off_stationary", 0.08)
		var drift_base := _config_value(config, "engine_off_drifting", 0.12)
		var movement_max := _config_value(config, "engine_off_movement_max", 0.50)
		var drift_speed := maxf(0.1, _config_value(config, "engine_off_full_movement_speed_mps", 6.0))
		if speed_mps <= still_speed:
			intensity = drift
			mode = "engine_off_stationary"
		else:
			intensity = lerpf(drift_base, movement_max, clampf(speed_mps / drift_speed, 0.0, 1.0))
			mode = "engine_off_drifting"
	return {
		"vessel_disturbance": clampf(intensity, 0.0, 1.0) if is_finite(intensity) else 0.0,
		"engine_data_available": engine_data_available,
		"engine_running": engine_running,
		"throttle_demand": throttle,
		"speed_mps": speed_mps,
		"mode": mode,
	}


static func target_for_school(horizontal_distance_m: float, vertical_below_hull_m: float, vessel_disturbance_value: float, species_sensitivity: float, config: Dictionary) -> float:
	if not is_finite(horizontal_distance_m) or not is_finite(vertical_below_hull_m):
		return 0.0
	var horizontal_scale := maxf(0.1, _config_value(config, "horizontal_falloff_m", 12.0))
	var vertical_scale := maxf(0.1, _config_value(config, "vertical_falloff_m", 3.5))
	var horizontal_distance := maxf(0.0, horizontal_distance_m)
	var vertical_distance := maxf(0.0, vertical_below_hull_m)
	var vessel_intensity := clampf(_safe_nonnegative(vessel_disturbance_value), 0.0, 1.0)
	var sensitivity := clampf(_safe_nonnegative(species_sensitivity), 0.0, 4.0)
	var horizontal_factor := exp(-pow(horizontal_distance / horizontal_scale, 2.0))
	var vertical_factor := exp(-vertical_distance / vertical_scale)
	return clampf(horizontal_factor * vertical_factor * vessel_intensity * sensitivity, 0.0, 1.0)


static func advance_school_state(level: float, state: String, strong_seconds: float, target: float, delta_seconds: float, config: Dictionary) -> Dictionary:
	var safe_level := clampf(_safe_nonnegative(level), 0.0, 1.0)
	var safe_target := clampf(_safe_nonnegative(target), 0.0, 1.0)
	var current_state := _normalized_state(state)
	var strong_duration := _safe_nonnegative(strong_seconds)
	var dt := _safe_nonnegative(delta_seconds)
	if dt > 0.0:
		var rising := safe_target > safe_level
		var time_constant := maxf(0.01, _config_value(config, "rise_time_constant_s", 3.0) if rising else _config_value(config, "fall_time_constant_s", 12.0))
		var alpha := 1.0 - exp(-dt / time_constant)
		safe_level = clampf(safe_level + (safe_target - safe_level) * alpha, 0.0, 1.0)
		var strong_threshold := _config_value(config, "flee_enter_level", 0.65)
		if safe_target >= strong_threshold:
			strong_duration += dt
		else:
			strong_duration = 0.0
	var alert_enter := _config_value(config, "alert_enter_level", 0.20)
	var alert_exit := minf(alert_enter, _config_value(config, "alert_exit_level", 0.12))
	var flee_enter := maxf(alert_enter, _config_value(config, "flee_enter_level", 0.65))
	var flee_exit := clampf(_config_value(config, "flee_exit_level", 0.45), alert_exit, flee_enter)
	var strong_duration_required := _config_value(config, "flee_strong_duration_s", 1.5)
	if current_state == "FLEEING":
		if safe_level <= flee_exit:
			current_state = "ALERT" if safe_level > alert_exit else "CALM"
	elif safe_level >= flee_enter and strong_duration >= strong_duration_required:
		current_state = "FLEEING"
	elif current_state == "ALERT":
		if safe_level <= alert_exit:
			current_state = "CALM"
	elif safe_level >= alert_enter:
		current_state = "ALERT"
	else:
		current_state = "CALM"
	return {
		"disturbance_level": safe_level,
		"disturbance_state": current_state,
		"strong_disturbance_duration_seconds": strong_duration,
	}


static func bite_willingness(state: String, config: Dictionary) -> float:
	match _normalized_state(state):
		"ALERT":
			return clampf(_config_value(config, "bite_willingness_alert", 0.80), 0.0, 1.0)
		"FLEEING":
			return clampf(_config_value(config, "bite_willingness_fleeing", 0.25), 0.0, 1.0)
		_:
			return clampf(_config_value(config, "bite_willingness_calm", 1.0), 0.0, 1.0)


static func _normalized_state(value: String) -> String:
	var normalized := value.to_upper()
	return normalized if normalized in ["CALM", "ALERT", "FLEEING"] else "CALM"


static func _config_value(config: Dictionary, key: String, fallback: float) -> float:
	var value := float(config.get(key, fallback))
	return value if is_finite(value) else fallback


static func _safe_nonnegative(value: float) -> float:
	return maxf(0.0, value) if is_finite(value) else 0.0


static func _safe_abs(value: float) -> float:
	return absf(value) if is_finite(value) else 0.0
