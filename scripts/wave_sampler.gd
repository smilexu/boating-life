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
## World-space point whose wave phase stays continuous while test wavelengths change.
@export_node_path("Node3D") var phase_anchor_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node") var bathymetry_manager_path := NodePath("../BathymetryManager")

@export_category("Shallow Wave Constraint")
@export var shallow_wave_constraint_enabled := false:
	set(value):
		shallow_wave_constraint_enabled = value and OS.is_debug_build()
		_apply_shallow_wave_parameters()
@export_range(30.0, 60.0, 1.0) var shallow_wave_full_depth_m := 30.0:
	set(value):
		shallow_wave_full_depth_m = clampf(value, 30.0, 60.0)
		_apply_shallow_wave_parameters()
@export_range(0.0, 0.60, 0.01) var shallow_wave_min_amplitude_scale := 0.40:
	set(value):
		shallow_wave_min_amplitude_scale = clampf(value, 0.0, 0.60)
		_apply_shallow_wave_parameters()
@export_range(0.10, 0.50, 0.01) var shallow_wave_safe_depth_ratio := 0.20:
	set(value):
		shallow_wave_safe_depth_ratio = clampf(value, 0.10, 0.50)
		_apply_shallow_wave_parameters()

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
var _phase_anchor: Node3D
var _bathymetry_manager: BathymetryManager
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
var _transition_phase_anchor_world := Vector2.ZERO
var _transition_anchor_phase_radians: Array[float] = []
var _transition_phase_correction_radians: Array[float] = []
var _transition_phase_correction_start_progress := 0.0
var _wave_parameter_revision := 0


func _enter_tree() -> void:
	add_to_group("wave_sampler")


func _ready() -> void:
	_ocean = get_node_or_null(ocean_path) as Node3D
	_phase_anchor = get_node_or_null(phase_anchor_path) as Node3D
	_bathymetry_manager = get_node_or_null(bathymetry_manager_path) as BathymetryManager
	_apply_wave_parameters()
	_apply_shallow_wave_parameters()


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return

	if water_material != null:
		wave_time_seconds = fposmod(wave_time_seconds + delta, TIME_WRAP_SECONDS)
	if _transition_active:
		_advance_extreme_transition(delta)
	if water_material == null:
		return
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
		_reanchor_transition_phase_continuity(false)
		return true
	var duration := EXTREME_SHAPE_TRANSITION_SECONDS if same_test_target else EXTREME_TRANSITION_SECONDS
	_begin_extreme_transition(from_settings, from_strength, duration)
	return true


## Restores the current weather waves and strength through a smooth blend.
func clear_extreme_sea_test() -> void:
	if not _extreme_test_active:
		return
	shallow_wave_constraint_enabled = false
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


func set_shallow_wave_constraint_options(
	enabled: bool,
	full_depth_m: float,
	minimum_scale: float,
	safe_depth_ratio: float
) -> void:
	shallow_wave_full_depth_m = full_depth_m
	shallow_wave_min_amplitude_scale = minimum_scale
	shallow_wave_safe_depth_ratio = safe_depth_ratio
	shallow_wave_constraint_enabled = enabled
	_apply_shallow_wave_parameters()


func get_theoretical_max_trough_excursion() -> float:
	return _theoretical_max_trough_excursion(get_effective_wave_settings(), get_effective_wave_strength())


func get_shallow_wave_diagnostics(world_position: Vector3) -> Dictionary:
	var surface := sample_surface(world_position, wave_time_seconds)
	var source_xz: Vector2 = surface.get("source_xz", Vector2(world_position.x, world_position.z))
	var state: Dictionary = surface.get("shallow_wave_state", {})
	if state.is_empty() or not state.has("depth_m"):
		state = _calculate_shallow_wave_state(source_xz, _get_water_plane_y(), get_theoretical_max_trough_excursion())
	state["wavelength_scale"] = 1.0
	state["frequency_scale"] = 1.0
	state["theoretical_max_trough_excursion_m"] = get_theoretical_max_trough_excursion()
	state["constrained_max_trough_excursion_m"] = (
		float(state.get("amplitude_scale", 1.0))
		* float(state["theoretical_max_trough_excursion_m"])
	)
	state["source_xz"] = source_xz
	return state


## Matches the vertical displacement envelope in P_DEG after the shader's
## wave-count average. The ratio is reserved against the LAT depth from the
## shared bathymetry sample; the seabed renderer separately applies its LAT
## surface offset. Everyday low-energy seas retain the existing zone protection.
static func calculate_shallow_wave_scale_components(
	effective_depth_m: float,
	max_trough_excursion_m: float,
	safe_depth_ratio: float,
	full_depth_m: float,
	minimum_scale: float
) -> Dictionary:
	var max_trough := maxf(max_trough_excursion_m, 0.0)
	var depth := maxf(effective_depth_m, 0.0)
	var ratio := clampf(safe_depth_ratio, 0.10, 0.50)
	var minimum_at_three_m := clampf(minimum_scale, 0.0, 0.60)
	var visual_zone_scale: float
	if depth < 3.0:
		visual_zone_scale = lerpf(0.0, minimum_at_three_m, _smoothstep(0.0, 3.0, depth))
	elif depth < 5.0:
		visual_zone_scale = lerpf(minimum_at_three_m, 0.60, _smoothstep(3.0, 5.0, depth))
	elif depth < 10.0:
		visual_zone_scale = lerpf(0.60, 0.80, _smoothstep(5.0, 10.0, depth))
	elif depth < 15.0:
		visual_zone_scale = lerpf(0.80, 0.90, _smoothstep(10.0, 15.0, depth))
	elif depth < 20.0:
		visual_zone_scale = lerpf(0.90, 0.95, _smoothstep(15.0, 20.0, depth))
	elif depth < full_depth_m:
		visual_zone_scale = lerpf(0.95, 1.0, _smoothstep(20.0, maxf(full_depth_m, 20.01), depth))
	else:
		visual_zone_scale = 1.0
	# The profile fades in from ordinary low-energy weather to the 5 m trough
	# envelope of the 10 m test preset. Its safety cap remains independent.
	var extreme_weight := _smoothstep(1.0, 5.0, max_trough)
	visual_zone_scale = lerpf(1.0, visual_zone_scale, extreme_weight)
	var allowed_trough_m := maxf(depth * (1.0 - ratio), 0.0)
	var safety_scale := 1.0
	if max_trough > 0.000001:
		safety_scale = clampf(allowed_trough_m / max_trough, 0.0, 1.0)
	var final_scale := clampf(minf(visual_zone_scale, safety_scale), 0.0, 1.0)
	return {
		"visual_zone_scale": visual_zone_scale,
		"safety_scale": safety_scale,
		"allowed_trough_m": allowed_trough_m,
		"amplitude_scale": final_scale,
	}


static func calculate_shallow_wave_amplitude_scale(
	effective_depth_m: float,
	max_trough_excursion_m: float,
	safe_depth_ratio: float,
	full_depth_m: float,
	minimum_scale: float
) -> float:
	return float(calculate_shallow_wave_scale_components(
		effective_depth_m,
		max_trough_excursion_m,
		safe_depth_ratio,
		full_depth_m,
		minimum_scale
	)["amplitude_scale"])


static func _smoothstep(edge0: float, edge1: float, value: float) -> float:
	if edge1 <= edge0:
		return 1.0 if value >= edge1 else 0.0
	var t := clampf((value - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _theoretical_max_trough_excursion(settings: SeaWaveSettings, strength: float) -> float:
	if settings == null or settings.waves.is_empty():
		return 0.0
	var count := mini(settings.waves.size(), MAX_SHADER_WAVES)
	var total := 0.0
	for index in range(count):
		var wave: GerstnerWave = settings.waves[index]
		total += absf(wave.steepness * strength)
	return total / float(count)


func _get_depth_coverage_limits() -> Vector2:
	if water_material == null:
		return Vector2(0.20, 0.80)
	return Vector2(
		float(water_material.get_shader_parameter("valid_coverage_min")),
		float(water_material.get_shader_parameter("valid_coverage_max"))
	)


func _calculate_shallow_wave_state(source_xz: Vector2, surface_y: float, max_trough: float) -> Dictionary:
	var limits := _get_depth_coverage_limits()
	var depth_sample: Dictionary
	if _bathymetry_manager != null and _bathymetry_manager.has_method("sample_shader_depth_at_world_position"):
		depth_sample = _bathymetry_manager.sample_shader_depth_at_world_position(
			Vector3(source_xz.x, surface_y, source_xz.y), limits.x, limits.y
		)
	else:
		depth_sample = {
			"depth_m": 64.0,
			"coverage": 0.0,
			"validity": 0.0,
			"effective_depth_m": 0.0,
			"valid": false,
		}
	var effective_depth := float(depth_sample.get("effective_depth_m", 0.0))
	var scale_components := calculate_shallow_wave_scale_components(
		effective_depth,
		max_trough,
		shallow_wave_safe_depth_ratio,
		shallow_wave_full_depth_m,
		shallow_wave_min_amplitude_scale
	)
	var active := shallow_wave_constraint_enabled and OS.is_debug_build()
	return {
		"depth_m": float(depth_sample.get("depth_m", 64.0)),
		"effective_depth_m": effective_depth,
		"coverage": float(depth_sample.get("coverage", 0.0)),
		"validity": float(depth_sample.get("validity", 0.0)),
		"valid": bool(depth_sample.get("valid", false)),
		"depth_zone_and_safety_scale": float(scale_components["amplitude_scale"]),
		"visual_zone_scale": float(scale_components["visual_zone_scale"]),
		"safety_scale": float(scale_components["safety_scale"]),
		"allowed_trough_m": float(scale_components["allowed_trough_m"]),
		"safe_depth_ratio": clampf(shallow_wave_safe_depth_ratio, 0.10, 0.50),
		"constrained_amplitude_scale": float(scale_components["amplitude_scale"]),
		"amplitude_scale": float(scale_components["amplitude_scale"]) if active else 1.0,
		"enabled": active,
	}


func _apply_shallow_wave_parameters() -> void:
	if water_material == null:
		return
	water_material.set_shader_parameter("shallow_wave_constraint_enabled", shallow_wave_constraint_enabled and OS.is_debug_build())
	water_material.set_shader_parameter("shallow_wave_full_depth_m", shallow_wave_full_depth_m)
	water_material.set_shader_parameter("shallow_wave_min_amplitude_scale", shallow_wave_min_amplitude_scale)
	water_material.set_shader_parameter("shallow_wave_safe_depth_ratio", shallow_wave_safe_depth_ratio)
	water_material.set_shader_parameter(
		"shallow_wave_max_trough_excursion_m",
		get_theoretical_max_trough_excursion()
	)


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
	var constraint_active := shallow_wave_constraint_enabled and OS.is_debug_build()
	for _iteration in range(INVERSE_ITERATIONS):
		var field := _calculate_wave_field(source_xz, effective_time)
		var fade := _vertex_wave_fade(source_xz, water_y)
		var displacement: Vector3 = field["displacement"]
		if fade >= 0.999 and not constraint_active:
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
		"shallow_wave_state": final_field.get("shallow_wave_state", {}),
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
	var max_trough := _theoretical_max_trough_excursion(active_settings, active_strength)
	var shallow_state := {
		"amplitude_scale": 1.0,
		"depth_zone_and_safety_scale": 1.0,
		"enabled": false,
	}
	if shallow_wave_constraint_enabled and OS.is_debug_build():
		shallow_state = _calculate_shallow_wave_state(source_xz, _get_water_plane_y(), max_trough)
	if wave_count == 0:
		return {
			"displacement": displacement,
			"normal": Vector3.UP,
			"horizontal_jacobian": horizontal_jacobian,
			"shallow_wave_state": shallow_state,
		}
	var shallow_scale := float(shallow_state.get("amplitude_scale", 1.0))

	for index in range(wave_count):
		var wave: GerstnerWave = active_settings.waves[index]
		var direction_radians := deg_to_rad(wave.direction_degrees)
		var direction := Vector2(sin(direction_radians), cos(direction_radians))
		var phase_radians := deg_to_rad(wave.phase_degrees)
		var steepness := wave.steepness * active_strength * shallow_scale
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
		"shallow_wave_state": shallow_state,
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
	water_material.set_shader_parameter(
		"shallow_wave_max_trough_excursion_m",
		_theoretical_max_trough_excursion(active_settings, active_strength)
	)
	_apply_shallow_wave_parameters()
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
	_reanchor_transition_phase_continuity(true)
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
	var phase_correction_weight := _get_transition_phase_correction_weight(linear_weight)
	for index in range(_transition_output_settings.waves.size()):
		var from_wave: GerstnerWave = _transition_from_settings.waves[index]
		var target_wave: GerstnerWave = target_settings.waves[index]
		var output_wave: GerstnerWave = _transition_output_settings.waves[index]
		var previous_omega := output_wave.speed
		output_wave.steepness = lerpf(from_wave.steepness, target_wave.steepness, weight)
		output_wave.amplitude = lerpf(from_wave.amplitude, target_wave.amplitude, weight)
		output_wave.direction_degrees = _lerp_degrees(from_wave.direction_degrees, target_wave.direction_degrees, weight)
		output_wave.frequency = lerpf(from_wave.frequency, target_wave.frequency, weight)
		output_wave.speed = lerpf(from_wave.speed, target_wave.speed, weight)
		var phase_time_delta := delta if _is_wave_time_advancing() else 0.0
		_transition_anchor_phase_radians[index] += (previous_omega + output_wave.speed) * 0.5 * phase_time_delta
		var desired_anchor_phase := (
			_transition_anchor_phase_radians[index]
			+ _transition_phase_correction_radians[index] * phase_correction_weight
		)
		output_wave.phase_degrees = _solve_phase_degrees_at_anchor(output_wave, desired_anchor_phase)
	_transition_output_strength = lerpf(_transition_from_strength, target_strength, weight)
	if linear_weight >= 1.0:
		_transition_active = false
		if _extreme_test_restoring:
			_extreme_test_active = false
			_extreme_test_restoring = false
			_extreme_test_target_height_m = 0.0
			_extreme_test_settings = null
	_apply_wave_parameters()


func _reanchor_transition_phase_continuity(reset_anchor: bool) -> void:
	# Interpolating frequency/direction changes k·x by many cycles at large
	# world coordinates. Integrate the local angular phase and solve the shader
	# phase offset so that this coordinate does not inherit that spatial drift.
	if _transition_output_settings == null or _transition_from_settings == null:
		return
	var target_settings := wave_settings if _extreme_test_restoring else _extreme_test_settings
	if target_settings == null or target_settings.waves.size() != _transition_output_settings.waves.size():
		return
	if reset_anchor or _transition_anchor_phase_radians.size() != _transition_output_settings.waves.size():
		_transition_phase_anchor_world = _get_phase_anchor_world_xz()
	_transition_anchor_phase_radians.clear()
	_transition_phase_correction_radians.clear()
	var start_progress := clampf(_transition_elapsed / _transition_duration_seconds, 0.0, 1.0)
	_transition_phase_correction_start_progress = start_progress
	var remaining_duration := _transition_duration_seconds * (1.0 - start_progress)
	var effective_phase_time := _get_effective_wave_phase_time()
	var phase_time_remaining := remaining_duration if _is_wave_time_advancing() else 0.0
	var target_phase_time := (
		fposmod(wave_time_seconds + remaining_duration, TIME_WRAP_SECONDS)
		if _is_wave_time_advancing()
		else effective_phase_time
	)
	for index in range(_transition_output_settings.waves.size()):
		var current_wave: GerstnerWave = _transition_output_settings.waves[index]
		var from_wave: GerstnerWave = _transition_from_settings.waves[index]
		var target_wave: GerstnerWave = target_settings.waves[index]
		var current_phase := _wave_phase_at_anchor(current_wave, _transition_phase_anchor_world, effective_phase_time)
		_transition_anchor_phase_radians.append(current_phase)
		var average_weight := _average_transition_weight(start_progress)
		var predicted_end_phase := current_phase + phase_time_remaining * lerpf(
			from_wave.speed,
			target_wave.speed,
			average_weight
		)
		var target_end_phase := _wave_phase_at_anchor(
			target_wave,
			_transition_phase_anchor_world,
			target_phase_time
		)
		_transition_phase_correction_radians.append(_wrap_signed_radians(target_end_phase - predicted_end_phase))


func _get_transition_phase_correction_weight(progress: float) -> float:
	var remaining_progress := 1.0 - _transition_phase_correction_start_progress
	if remaining_progress <= 0.000001:
		return 1.0
	var local_progress := clampf((progress - _transition_phase_correction_start_progress) / remaining_progress, 0.0, 1.0)
	return local_progress * local_progress * (3.0 - 2.0 * local_progress)


func _average_transition_weight(start_progress: float) -> float:
	if start_progress >= 0.999999:
		return 1.0
	var integral_at_start := start_progress * start_progress * start_progress - 0.5 * pow(start_progress, 4.0)
	return clampf((0.5 - integral_at_start) / (1.0 - start_progress), 0.0, 1.0)


func _get_phase_anchor_world_xz() -> Vector2:
	if is_instance_valid(_phase_anchor):
		return Vector2(_phase_anchor.global_position.x, _phase_anchor.global_position.z)
	var camera := get_viewport().get_camera_3d() if is_inside_tree() else null
	if camera != null:
		return Vector2(camera.global_position.x, camera.global_position.z)
	return Vector2.ZERO


func _wave_phase_at_anchor(wave: GerstnerWave, anchor_xz: Vector2, sample_time_seconds: float) -> float:
	var direction_radians := deg_to_rad(wave.direction_degrees)
	var direction := Vector2(sin(direction_radians), cos(direction_radians))
	return (
		TAU * wave.frequency * direction.dot(anchor_xz)
		+ wave.speed * (sample_time_seconds + deg_to_rad(wave.phase_degrees))
	)


func _solve_phase_degrees_at_anchor(wave: GerstnerWave, desired_phase_radians: float) -> float:
	if absf(wave.speed) <= 0.000001:
		return wave.phase_degrees
	var direction_radians := deg_to_rad(wave.direction_degrees)
	var direction := Vector2(sin(direction_radians), cos(direction_radians))
	var spatial_phase := TAU * wave.frequency * direction.dot(_transition_phase_anchor_world)
	# P_DEG encodes phase as omega * (time + phase_radians), so solve its
	# time-offset value rather than changing height or horizontal steepness.
	var phase_time_seconds := (desired_phase_radians - spatial_phase) / wave.speed - _get_effective_wave_phase_time()
	phase_time_seconds = fposmod(phase_time_seconds, TAU / absf(wave.speed))
	return rad_to_deg(phase_time_seconds)


func _is_wave_time_advancing() -> bool:
	return water_material != null and not bool(water_material.get_shader_parameter("freeze_time"))


func _get_effective_wave_phase_time() -> float:
	return 0.0 if water_material != null and bool(water_material.get_shader_parameter("freeze_time")) else wave_time_seconds


func _wrap_signed_radians(value: float) -> float:
	return fposmod(value + PI, TAU) - PI


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
