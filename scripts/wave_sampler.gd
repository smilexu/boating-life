@tool
class_name WaveSampler
extends Node

## CPU counterpart to the surface-displacement section in sea_water.gdshader.
## Wave settings and strength are also written to the shader from this node, so
## the boat and visible sea use the same parameters and shared time value.

const MAX_SHADER_WAVES := 8
const TIME_WRAP_SECONDS := 3600.0
const INVERSE_ITERATIONS := 4
const EXTREME_TRANSITION_SECONDS := 2.5
const EXTREME_SHAPE_TRANSITION_SECONDS := EXTREME_TRANSITION_SECONDS

@export_node_path("Node3D") var ocean_path := NodePath("../Ocean")

@export var wave_settings: SeaWaveSettings:
	set(value):
		wave_settings = value
		_apply_wave_parameters()

@export var water_material: ShaderMaterial:
	set(value):
		water_material = value
		_apply_wave_parameters()

@export_range(0.0, 2.0, 0.05) var wave_strength := 1.25:
	set(value):
		wave_strength = value
		_apply_wave_parameters()

var wave_time_seconds := 0.0
var _ocean: Node3D
var _extreme_test_active := false
var _extreme_test_restoring := false
var _extreme_test_target_height_m := 0.0
var _extreme_test_settings: SeaWaveSettings
var _extreme_test_strength := 1.0
var _transition_active := false
var _transition_elapsed := 0.0
var _transition_from_settings: SeaWaveSettings
var _transition_output_settings: SeaWaveSettings
var _transition_from_strength := 1.0
var _transition_output_strength := 1.0
var _transition_duration_seconds := EXTREME_TRANSITION_SECONDS
var _wave_parameter_revision := 0


func _enter_tree() -> void:
	add_to_group("wave_sampler")


func _ready() -> void:
	_ocean = get_node_or_null(ocean_path) as Node3D
	_apply_wave_parameters()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	if _transition_active:
		_advance_extreme_transition(delta)
	if water_material == null:
		return
	wave_time_seconds = fposmod(wave_time_seconds + delta, TIME_WRAP_SECONDS)
	water_material.set_shader_parameter("WaveTime", wave_time_seconds)


## Applies test-only wave data without modifying the weather resource or its
## strength. The returned boolean indicates whether a transition was started.
func set_extreme_sea_test(settings: SeaWaveSettings, target_height_m: float) -> bool:
	if settings == null or wave_settings == null:
		return false
	if settings.waves.size() != wave_settings.waves.size() or settings.waves.size() > MAX_SHADER_WAVES:
		push_warning("Extreme sea-state settings must keep the current wave count (up to %d)." % MAX_SHADER_WAVES)
		return false
	var same_test_target := (
		_extreme_test_active
		and not _extreme_test_restoring
		and is_equal_approx(target_height_m, _extreme_test_target_height_m)
	)
	var from_settings := _copy_wave_settings(get_effective_wave_settings())
	var from_strength := get_effective_wave_strength()
	_extreme_test_settings = _copy_wave_settings(settings)
	_extreme_test_strength = 1.0
	_extreme_test_target_height_m = target_height_m
	_extreme_test_active = true
	_extreme_test_restoring = false
	if same_test_target and _transition_active:
		# During a transition, keep the current interpolation clock and replace
		# only its endpoint so continuous slider drags do not restart the blend.
		return true
	var duration := EXTREME_SHAPE_TRANSITION_SECONDS if same_test_target else EXTREME_TRANSITION_SECONDS
	_begin_extreme_transition(from_settings, from_strength, duration)
	return true


## Restores the current weather waves and strength through a smooth blend.
func clear_extreme_sea_test() -> void:
	if not _extreme_test_active:
		return
	var from_settings := _copy_wave_settings(get_effective_wave_settings())
	var from_strength := get_effective_wave_strength()
	_extreme_test_restoring = true
	_begin_extreme_transition(from_settings, from_strength, EXTREME_TRANSITION_SECONDS)


func is_extreme_sea_test_active() -> bool:
	return _extreme_test_active


func is_extreme_sea_test_transitioning() -> bool:
	return _transition_active


func is_extreme_sea_test_restoring() -> bool:
	return _transition_active and _extreme_test_restoring


func get_extreme_sea_test_target_height() -> float:
	return _extreme_test_target_height_m


func get_effective_wave_settings() -> SeaWaveSettings:
	if _transition_active:
		return _transition_output_settings
	if _extreme_test_active:
		return _extreme_test_settings
	return wave_settings


func get_effective_wave_strength() -> float:
	if _transition_active:
		return _transition_output_strength
	if _extreme_test_active:
		return _extreme_test_strength
	return wave_strength


func get_wave_parameter_revision() -> int:
	return _wave_parameter_revision


## `world_position.xz` is a world-space position on the undeformed water plane.
## The sampler inverts Gerstner horizontal displacement before returning height
## and the shader's approximate normal at that world-space location.
func sample_surface(world_position: Vector3, sample_time_seconds: float) -> Dictionary:
	var water_y := _get_water_plane_y()
	var active_settings := get_effective_wave_settings()
	if active_settings == null or active_settings.waves.is_empty():
		return {"height": water_y, "normal": Vector3.UP, "displacement": Vector3.ZERO}

	var effective_time := sample_time_seconds
	if water_material != null and bool(water_material.get_shader_parameter("freeze_time")):
		effective_time = 0.0

	var target_xz := Vector2(world_position.x, world_position.z)
	var source_xz := target_xz
	for _iteration in range(INVERSE_ITERATIONS):
		var field := _calculate_wave_field(source_xz, effective_time)
		var fade := _vertex_wave_fade(source_xz, water_y)
		var displacement: Vector3 = field["displacement"]
		if fade >= 0.999:
			var residual := source_xz + Vector2(displacement.x, displacement.z) - target_xz
			var jacobian: Vector4 = field["horizontal_jacobian"]
			var determinant := jacobian.x * jacobian.w - jacobian.y * jacobian.z
			if absf(determinant) > 0.0001:
				var correction := Vector2(
					(jacobian.w * residual.x - jacobian.y * residual.y) / determinant,
					(-jacobian.z * residual.x + jacobian.x * residual.y) / determinant
				)
				source_xz -= correction
			else:
				source_xz = target_xz - Vector2(displacement.x, displacement.z)
		else:
			# The shader fades displacement by camera distance. Use fixed-point
			# inversion in the fade band, where that extra spatial gradient matters.
			source_xz = target_xz - Vector2(displacement.x, displacement.z) * fade

	var final_field := _calculate_wave_field(source_xz, effective_time)
	var final_fade := _vertex_wave_fade(source_xz, water_y)
	var final_displacement: Vector3 = final_field["displacement"] * final_fade
	var wave_normal: Vector3 = final_field["normal"].normalized()
	var final_normal := Vector3.UP.lerp(wave_normal, final_fade).normalized()
	return {
		"height": water_y + final_displacement.y,
		"normal": final_normal,
		"displacement": final_displacement,
		"source_xz": source_xz,
	}


func _calculate_wave_field(source_xz: Vector2, sample_time_seconds: float) -> Dictionary:
	var active_settings := get_effective_wave_settings()
	if active_settings == null:
		return {"displacement": Vector3.ZERO, "normal": Vector3.UP}
	var active_strength := get_effective_wave_strength()
	var wave_count := mini(active_settings.waves.size(), MAX_SHADER_WAVES)
	var displacement := Vector3.ZERO
	var normal_sum := Vector3.ZERO
	var horizontal_jacobian := Vector4(1.0, 0.0, 0.0, 1.0)
	if wave_count == 0:
		return {
			"displacement": displacement,
			"normal": Vector3.UP,
			"horizontal_jacobian": horizontal_jacobian,
		}

	for index in range(wave_count):
		var wave: GerstnerWave = active_settings.waves[index]
		var direction_radians := deg_to_rad(wave.direction_degrees)
		var direction := Vector2(sin(direction_radians), cos(direction_radians))
		var phase_radians := deg_to_rad(wave.phase_degrees)
		var steepness := wave.steepness * active_strength
		var amplitude := wave.amplitude * active_strength
		var theta := (
			TAU * wave.frequency * direction.dot(source_xz)
			+ wave.speed * (sample_time_seconds + phase_radians)
		)
		var cosine := cos(theta)
		var sine := sin(theta)
		var wave_number := TAU * wave.frequency

		# Matches P_DEG: steepness drives vertical height; amplitude scales
		# horizontal particle displacement as well as the normal calculation.
		displacement.x += steepness * amplitude * direction.x * cosine
		displacement.y += steepness * sine
		displacement.z += steepness * amplitude * direction.y * cosine
		var horizontal_derivative := -steepness * amplitude * wave_number * sine
		horizontal_jacobian.x += horizontal_derivative * direction.x * direction.x / float(wave_count)
		horizontal_jacobian.y += horizontal_derivative * direction.x * direction.y / float(wave_count)
		horizontal_jacobian.z += horizontal_derivative * direction.y * direction.x / float(wave_count)
		horizontal_jacobian.w += horizontal_derivative * direction.y * direction.y / float(wave_count)

		# Matches N_DEG from the water shader before its final normalization.
		normal_sum.x += -direction.x * wave.frequency * amplitude * cosine
		normal_sum.y += 1.0 - steepness * wave.frequency * amplitude * sine
		normal_sum.z += -direction.y * wave.frequency * amplitude * cosine

	var divisor := float(wave_count)
	return {
		"displacement": displacement / divisor,
		"normal": normal_sum / divisor,
		"horizontal_jacobian": horizontal_jacobian,
	}


func _vertex_wave_fade(source_xz: Vector2, water_y: float) -> float:
	if water_material == null:
		return 1.0
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return 1.0

	var fade_min := float(water_material.get_shader_parameter("vertex_wave_fade_min"))
	var fade_max := float(water_material.get_shader_parameter("vertex_wave_fade_max"))
	if fade_max <= fade_min:
		return 1.0
	var base_position := Vector3(source_xz.x, water_y, source_xz.y)
	var camera_distance := base_position.distance_to(camera.global_position)
	var blend := clampf((camera_distance - fade_min) / (fade_max - fade_min), 0.0, 1.0)
	return 1.0 - blend * blend * (3.0 - 2.0 * blend)


func _get_water_plane_y() -> float:
	return _ocean.global_position.y if _ocean != null else 0.0


func _apply_wave_parameters() -> void:
	var active_settings := get_effective_wave_settings()
	if active_settings == null or water_material == null:
		return

	var active_strength := get_effective_wave_strength()
	var count := mini(active_settings.waves.size(), MAX_SHADER_WAVES)
	var steepnesses := PackedFloat32Array()
	var amplitudes := PackedFloat32Array()
	var directions := PackedFloat32Array()
	var frequencies := PackedFloat32Array()
	var speeds := PackedFloat32Array()
	var phases := PackedFloat32Array()
	for index in range(count):
		var wave: GerstnerWave = active_settings.waves[index]
		steepnesses.append(wave.steepness * active_strength)
		amplitudes.append(wave.amplitude * active_strength)
		directions.append(wave.direction_degrees)
		frequencies.append(wave.frequency)
		speeds.append(wave.speed)
		phases.append(wave.phase_degrees)

	water_material.set_shader_parameter("WaveCount", count)
	water_material.set_shader_parameter("WaveSteepnesses", steepnesses)
	water_material.set_shader_parameter("WaveAmplitudes", amplitudes)
	water_material.set_shader_parameter("WaveDirectionsDegrees", directions)
	water_material.set_shader_parameter("WaveFrequencies", frequencies)
	water_material.set_shader_parameter("WaveSpeeds", speeds)
	water_material.set_shader_parameter("WavePhases", phases)
	water_material.set_shader_parameter("WaveTime", wave_time_seconds)
	_wave_parameter_revision += 1


func _begin_extreme_transition(
	from_settings: SeaWaveSettings,
	from_strength: float,
	duration_seconds: float = EXTREME_TRANSITION_SECONDS
) -> void:
	_transition_from_settings = from_settings
	_transition_from_strength = from_strength
	_transition_output_settings = _copy_wave_settings(from_settings)
	_transition_output_strength = from_strength
	_transition_elapsed = 0.0
	_transition_duration_seconds = maxf(duration_seconds, 0.01)
	_transition_active = true
	_apply_wave_parameters()


func _advance_extreme_transition(delta: float) -> void:
	if _transition_output_settings == null or _transition_from_settings == null:
		_transition_active = false
		return
	_transition_elapsed += delta
	var linear_weight := clampf(_transition_elapsed / _transition_duration_seconds, 0.0, 1.0)
	var weight := linear_weight * linear_weight * (3.0 - 2.0 * linear_weight)
	var target_settings := wave_settings if _extreme_test_restoring else _extreme_test_settings
	var target_strength := wave_strength if _extreme_test_restoring else _extreme_test_strength
	if target_settings == null or target_settings.waves.size() != _transition_output_settings.waves.size():
		push_warning("Extreme sea-state transition aborted because the wave count changed.")
		_transition_active = false
		_extreme_test_active = false
		_extreme_test_restoring = false
		_apply_wave_parameters()
		return
	for index in range(_transition_output_settings.waves.size()):
		var from_wave: GerstnerWave = _transition_from_settings.waves[index]
		var target_wave: GerstnerWave = target_settings.waves[index]
		var output_wave: GerstnerWave = _transition_output_settings.waves[index]
		output_wave.steepness = lerpf(from_wave.steepness, target_wave.steepness, weight)
		output_wave.amplitude = lerpf(from_wave.amplitude, target_wave.amplitude, weight)
		output_wave.direction_degrees = _lerp_degrees(from_wave.direction_degrees, target_wave.direction_degrees, weight)
		output_wave.frequency = lerpf(from_wave.frequency, target_wave.frequency, weight)
		output_wave.speed = lerpf(from_wave.speed, target_wave.speed, weight)
		output_wave.phase_degrees = _lerp_degrees(from_wave.phase_degrees, target_wave.phase_degrees, weight)
	_transition_output_strength = lerpf(_transition_from_strength, target_strength, weight)
	_apply_wave_parameters()
	if linear_weight >= 1.0:
		_transition_active = false
		if _extreme_test_restoring:
			_extreme_test_active = false
			_extreme_test_restoring = false
			_extreme_test_target_height_m = 0.0
			_extreme_test_settings = null
			_apply_wave_parameters()


func _copy_wave_settings(source: SeaWaveSettings) -> SeaWaveSettings:
	if source == null:
		return null
	var result := SeaWaveSettings.new()
	for source_wave: GerstnerWave in source.waves:
		var wave := GerstnerWave.new()
		wave.steepness = source_wave.steepness
		wave.amplitude = source_wave.amplitude
		wave.direction_degrees = source_wave.direction_degrees
		wave.frequency = source_wave.frequency
		wave.speed = source_wave.speed
		wave.phase_degrees = source_wave.phase_degrees
		result.waves.append(wave)
	return result


func _lerp_degrees(from_degrees: float, to_degrees: float, weight: float) -> float:
	var delta := fposmod(to_degrees - from_degrees + 180.0, 360.0) - 180.0
	return fposmod(from_degrees + delta * weight, 360.0)
