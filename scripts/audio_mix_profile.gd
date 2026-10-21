extends RefCounted
class_name AudioMixProfile

## Small, deterministic mappings used by the local audio presentation layer.
## The functions do not own or modify weather, wave, wind, or vessel state.

const SILENT_DB := -80.0


static func runtime_audio_allowed(is_dedicated_server: bool, is_headless: bool = false) -> bool:
	return not is_dedicated_server and not is_headless


static func linear_gain_to_db(gain: float) -> float:
	if not is_finite(gain) or gain <= 0.0001:
		return SILENT_DB
	return linear_to_db(clampf(gain, 0.0, 1.0))


static func wind_layer_gains(relative_wind_mps: float) -> Dictionary:
	var speed := maxf(relative_wind_mps, 0.0) if is_finite(relative_wind_mps) else 0.0
	var overall := _smooth_range(0.0, 18.0, speed) * 0.72
	var strong_mix := _smooth_range(4.0, 14.0, speed)
	var angle := strong_mix * PI * 0.5
	return {
		"light": overall * cos(angle),
		"strong": overall * sin(angle),
		"blend": strong_mix,
	}


static func rain_layer_gains(rate_mm_per_hour: float) -> Dictionary:
	var rate := maxf(rate_mm_per_hour, 0.0) if is_finite(rate_mm_per_hour) else 0.0
	# Raise only the rain stems; the shared Weather bus also carries wind and thunder.
	var overall := minf(_smooth_range(0.0, 13.0, rate) * 0.72 * 1.15, 0.90)
	var storm_mix := _smooth_range(4.0, 15.0, rate)
	var angle := storm_mix * PI * 0.5
	return {
		"moderate": overall * cos(angle),
		"heavy": overall * sin(angle),
		"blend": storm_mix,
	}


static func sea_layer_weights(amplitude_rms_m: float) -> Dictionary:
	var amplitude := maxf(amplitude_rms_m, 0.0) if is_finite(amplitude_rms_m) else 0.0
	var calm := 1.0 - _smooth_range(0.6, 2.2, amplitude)
	var large := _smooth_range(2.6, 5.0, amplitude)
	var moderate := clampf(1.0 - calm - large, 0.0, 1.0)
	return {"small": calm, "medium": moderate, "large": large}


static func sea_layer_gains(amplitude_rms_m: float) -> Dictionary:
	var amplitude := maxf(amplitude_rms_m, 0.0) if is_finite(amplitude_rms_m) else 0.0
	# Keep a quiet SW01 bed present on calm water; larger observed waves raise
	# the shared ambience level and crossfade toward SW02/SW03.
	var overall := 0.26 + _smooth_range(0.0, 4.5, amplitude) * 0.42
	var weights := sea_layer_weights(amplitude)
	return {
		"small": overall * sqrt(float(weights["small"])),
		"medium": overall * sqrt(float(weights["medium"])),
		"large": overall * sqrt(float(weights["large"])),
		"amplitude_rms_m": amplitude,
	}


static func hull_layer_gains(heave_speed_mps: float, angular_rate_rad_s: float) -> Dictionary:
	var motion := maxf(heave_speed_mps, 0.0) + maxf(angular_rate_rad_s, 0.0) * 0.55
	var impact := _smooth_range(0.025, 0.42, motion)
	return {
		"light": 0.14 + impact * 0.20,
		"heavy": _smooth_range(0.22, 0.82, impact) * 0.34,
		"impact": impact,
	}


static func thunder_delay_seconds(distance_m: float) -> float:
	return maxf(distance_m, 0.0) / 343.0 if is_finite(distance_m) else 0.0


static func thunder_stem_for_distance(distance_m: float) -> String:
	if distance_m < 1200.0:
		return "T03"
	if distance_m < 3500.0:
		return "T02"
	return "T01"


static func music_ducking_db(storm_intensity: float, near_thunder_active: bool) -> float:
	var intensity := clampf(storm_intensity, 0.0, 1.0) if is_finite(storm_intensity) else 0.0
	var duck := (-3.0 - 1.5 * intensity) if intensity > 0.0 else 0.0
	if near_thunder_active:
		duck -= 1.5
	return clampf(duck, -6.0, 0.0)


static func _smooth_range(start: float, end: float, value: float) -> float:
	if end <= start:
		return 1.0 if value >= end else 0.0
	var t := clampf((value - start) / (end - start), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
