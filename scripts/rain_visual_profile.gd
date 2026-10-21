extends RefCounted
class_name RainVisualProfile

## Converts the authoritative continuous precipitation rate (mm/h) into
## presentation-only weights. This module never classifies formal weather.

const MAX_VISUAL_RATE_MM_PER_HOUR := 22.0


static func from_precipitation_rate(rate_mm_per_hour: float) -> Dictionary:
	if not is_finite(rate_mm_per_hour) or rate_mm_per_hour <= 0.0:
		return {
			"rain_rate_mm_per_hour": 0.0,
			"intensity": 0.0,
			"streak_density": 0.0,
			"near_streak_density": 0.0,
			"mid_streak_alpha_scale": 0.0,
			"mid_streak_length_scale": 0.0,
			"micro_impact_density": 0.0,
			"sea_impact_density": 0.0,
			"sea_impact_strength": 0.0,
			"haze_strength": 0.0,
			"audio_intensity": 0.0,
		}
	var normalized := clampf(rate_mm_per_hour / MAX_VISUAL_RATE_MM_PER_HOUR, 0.0, 1.0)
	var intensity := pow(normalized, 0.30)
	var haze_input := clampf((intensity - 0.12) / 0.88, 0.0, 1.0)
	# Ease the mid-layer's long, bright streaks down at light/moderate intensity.
	# The full streak profile returns smoothly as rain approaches the strong range.
	var streak_transition := clampf((intensity - 0.45) / 0.48, 0.0, 1.0)
	streak_transition = streak_transition * streak_transition * (3.0 - 2.0 * streak_transition)
	var mid_streak_scale := lerpf(0.92, 1.0, streak_transition)
	return {
		"rain_rate_mm_per_hour": rate_mm_per_hour,
		"intensity": intensity,
		"streak_density": pow(intensity, 0.70),
		# A concentrated near layer makes the change from moderate to strong rain
		# legible without increasing the total particle budget.
		"near_streak_density": pow(intensity, 1.35),
		"mid_streak_alpha_scale": mid_streak_scale,
		"mid_streak_length_scale": mid_streak_scale,
		"micro_impact_density": pow(intensity, 0.58),
		# Complete rings are intentionally uncommon; most water detail comes
		# from the denser, much smaller micro-impact layer.
		"sea_impact_density": 0.14 * pow(intensity, 1.8),
		"sea_impact_strength": intensity,
		# Preserve a restrained response around 5 mm/h, then build a stronger
		# distant curtain as precipitation approaches the strong-rain range.
		"haze_strength": 0.62 * pow(haze_input, 2.2),
		# Reserved for a later audio stage; no audio is played in W2.3-A.
		"audio_intensity": intensity,
	}


static func blend_wind_flow_toward(world_air_velocity: Vector3, influence: float) -> Vector3:
	## WindField returns the direction the air moves to. Rain falls down while
	## drifting with that world-space airflow; it must not use wind-from bearing.
	var horizontal := Vector2(world_air_velocity.x, world_air_velocity.z)
	var drift := horizontal * maxf(influence, 0.0)
	return Vector3(drift.x, -1.0, drift.y).normalized()


static func smooth_value(current: float, target: float, delta: float, time_constant: float) -> float:
	if delta <= 0.0 or not is_finite(delta):
		return current
	var safe_time := maxf(time_constant, 0.001)
	var weight := 1.0 - exp(-delta / safe_time)
	return lerpf(current, target, weight)
