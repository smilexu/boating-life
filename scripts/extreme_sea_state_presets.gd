class_name ExtremeSeaStatePresets
extends RefCounted

## Development-only Gerstner presets. The 10 m test profile uses three bands:
## a dominant swell, a cross swell, and compact wind waves. Two further wave
## slots add nearby medium-scale variation without changing the target envelope.

const GRAVITY_M_S2 := 9.81
const MAX_HORIZONTAL_SLOPE := 0.85
const VERTICAL_ENVELOPE_SHARES := [0.62, 0.18, 0.12, 0.05, 0.03]
const HORIZONTAL_AMPLITUDES := [0.65, 0.55, 0.50, 0.45, 0.40]
const PRESET_WAVELENGTHS := {
	5: [160.0, 90.0, 32.0, 38.0, 25.0],
	10: [120.0, 55.0, 20.0, 24.0, 16.0],
	20: [320.0, 190.0, 42.0, 50.0, 34.0],
	30: [420.0, 250.0, 58.0, 70.0, 46.0],
}


static func build_settings(
	base_settings: SeaWaveSettings,
	target_height_m: float,
	compactness: float = 1.0,
	crest_sharpness: float = 0.0
) -> SeaWaveSettings:
	if base_settings == null:
		push_error("Extreme sea state needs the current SeaWaveSettings resource.")
		return null
	var wave_count := mini(base_settings.waves.size(), WaveSampler.MAX_SHADER_WAVES)
	if wave_count < 3 or wave_count != base_settings.waves.size():
		push_error("Extreme sea state expects 3 to %d waves without truncation." % WaveSampler.MAX_SHADER_WAVES)
		return null
	if not is_finite(target_height_m) or target_height_m <= 0.0:
		push_error("Extreme sea-state target height must be positive.")
		return null
	var preset_key := int(round(target_height_m))
	if not PRESET_WAVELENGTHS.has(preset_key):
		push_error("Unsupported extreme sea-state target: %s m." % target_height_m)
		return null

	var base_wavelengths: Array = PRESET_WAVELENGTHS[preset_key]
	var active_count := mini(wave_count, VERTICAL_ENVELOPE_SHARES.size())
	var share_total := 0.0
	for index in range(active_count):
		share_total += float(VERTICAL_ENVELOPE_SHARES[index])
	var safe_compactness := clampf(compactness, 0.5, 2.5)
	var safe_sharpness := clampf(crest_sharpness, 0.0, 1.0)
	var sharpness_multiplier := 1.0 + 3.0 * pow(safe_sharpness, 1.5)
	var required_steepness_sum := target_height_m * float(wave_count) * 0.5
	var main_direction := base_settings.waves[0].direction_degrees
	var direction_offsets := [0.0, 28.0, -12.0, 45.0, -37.0]
	var result := SeaWaveSettings.new()

	for index in range(wave_count):
		var source: GerstnerWave = base_settings.waves[index]
		var wave := GerstnerWave.new()
		wave.phase_degrees = source.phase_degrees
		if index < active_count:
			var base_wavelength_m := float(base_wavelengths[index])
			var effective_wavelength_m := base_wavelength_m / safe_compactness
			var share := float(VERTICAL_ENVELOPE_SHARES[index]) / share_total
			wave.steepness = required_steepness_sum * share
			# In this shader, steepness controls vertical displacement while
			# amplitude controls horizontal Gerstner displacement and normals.
			wave.amplitude = float(HORIZONTAL_AMPLITUDES[index]) * sharpness_multiplier
			wave.direction_degrees = fposmod(main_direction + float(direction_offsets[index]), 360.0)
			_set_deep_water_dispersion(wave, effective_wavelength_m)
		else:
			# Keep the existing wave-count divisor stable without increasing
			# the designed target-height envelope.
			wave.steepness = 0.0
			wave.amplitude = 0.0
			wave.direction_degrees = source.direction_degrees
			_set_deep_water_dispersion(wave, float(base_wavelengths[-1]) / safe_compactness)
		result.waves.append(wave)

	_limit_horizontal_slope(result.waves, wave_count)
	return result


static func profile_for_height(target_height_m: float, compactness: float = 1.0) -> Dictionary:
	var preset_key := int(round(target_height_m))
	if not PRESET_WAVELENGTHS.has(preset_key):
		return {}
	var base_wavelengths: Array = PRESET_WAVELENGTHS[preset_key]
	var safe_compactness := clampf(compactness, 0.5, 2.5)
	var main_wavelength_m := float(base_wavelengths[0]) / safe_compactness
	var cross_wavelength_m := float(base_wavelengths[1]) / safe_compactness
	var medium_wavelength_m := float(base_wavelengths[2]) / safe_compactness
	return {
		"target_height_m": float(preset_key),
		"main_wavelength_m": main_wavelength_m,
		"cross_wavelength_m": cross_wavelength_m,
		"medium_wavelength_m": medium_wavelength_m,
		"main_period_s": _deep_water_period(main_wavelength_m),
		"cross_period_s": _deep_water_period(cross_wavelength_m),
		"medium_period_s": _deep_water_period(medium_wavelength_m),
	}


static func _limit_horizontal_slope(waves: Array[GerstnerWave], wave_count: int) -> void:
	if wave_count <= 0:
		return
	var worst_case_slope := 0.0
	for wave: GerstnerWave in waves:
		worst_case_slope += TAU * wave.frequency * absf(wave.steepness * wave.amplitude)
	worst_case_slope /= float(wave_count)
	if worst_case_slope <= MAX_HORIZONTAL_SLOPE:
		return
	var amplitude_scale := MAX_HORIZONTAL_SLOPE / worst_case_slope
	for wave: GerstnerWave in waves:
		wave.amplitude *= amplitude_scale


static func _set_deep_water_dispersion(wave: GerstnerWave, wavelength_m: float) -> void:
	wave.frequency = 1.0 / wavelength_m
	# `speed` is angular frequency in the shader phase equation, not distance
	# per second: omega = sqrt(g*k), where k = 2*pi/lambda.
	wave.speed = sqrt(GRAVITY_M_S2 * TAU * wave.frequency)


static func _deep_water_period(wavelength_m: float) -> float:
	return TAU / sqrt(GRAVITY_M_S2 * TAU / wavelength_m)
