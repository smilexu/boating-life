class_name WakeSystem
extends Node3D

## Reusable, world-space GPUParticles3D wake. The emitting boat node is only
## sampled for displacement; particles remain at their old world positions.

const FOAM_SHADER := preload("res://shaders/particle_wake_foam.gdshader")
const MAX_WAVES := 8

@export_category("References")
@export_node_path("Node3D") var boat_motion_path := NodePath("../..")
@export_node_path("Node3D") var emitter_path := NodePath("WakeEmitter")
@export_node_path("Node") var wave_sampler_path := NodePath("../../../../WaveSampler")
@export_node_path("Node3D") var ocean_path := NodePath("../../../../Ocean")
@export var profile: WakeProfile

@export_category("Water and reset")
@export_range(0.0, 0.2, 0.005) var surface_offset_m := 0.045
@export_range(0.0, 0.3, 0.005) var emitter_height_offset_m := 0.025
@export_range(10.0, 500.0, 5.0) var teleport_reset_distance_m := 30.0
@export var wake_enabled := true

var _boat: Node3D
var _emitter: Node3D
var _wave_sampler: Node
var _ocean: Node3D
var _particles: GPUParticles3D
var _process_material: ParticleProcessMaterial
var _draw_material: ShaderMaterial
var _last_boat_position := Vector3.ZERO
var _measured_speed_mps := 0.0
var _smoothed_speed_mps := 0.0
var _emission_ratio := 0.0
var _density_multiplier := 1.0
var _density_target := 1.0
var _density_change_time := 0.0
var _seconds_since_emission := 0.0
var _particle_system_live := false
var _source_wave_parameter_revision := -1


func _ready() -> void:
	process_priority = 200
	_boat = get_node_or_null(boat_motion_path) as Node3D
	_emitter = get_node_or_null(emitter_path) as Node3D
	_wave_sampler = get_node_or_null(wave_sampler_path)
	_ocean = get_node_or_null(ocean_path) as Node3D
	if _boat == null:
		push_error("WakeSystem could not find BoatController at %s." % boat_motion_path)
		return
	if _emitter == null:
		push_error("WakeSystem could not find its stern WakeEmitter at %s." % emitter_path)
		return
	if _wave_sampler == null or not _wave_sampler.has_method("sample_surface"):
		push_error("WakeSystem requires WaveSampler.sample_surface().")
		return
	if profile == null:
		push_error("WakeSystem needs a WakeProfile resource.")
		return
	_create_emitter()
	_last_boat_position = _boat.global_position
	_update_particle_transform()
	_sync_wave_parameters(true)
	_particles.visible = wake_enabled
	_particles.emitting = false
	_seconds_since_emission = profile.particle_lifetime_max_seconds
	set_process(wake_enabled)


func _process(delta: float) -> void:
	if _boat == null or _particles == null or profile == null:
		return
	var current_position := _boat.global_position
	var displacement := current_position - _last_boat_position
	displacement.y = 0.0
	_last_boat_position = current_position
	if displacement.length() > teleport_reset_distance_m:
		reset_wake()
		return
	_measured_speed_mps = displacement.length() / maxf(delta, 0.0001)
	var response := 1.0 - exp(-profile.response_speed * delta)
	_smoothed_speed_mps = lerpf(_smoothed_speed_mps, _measured_speed_mps, response)
	_update_particle_transform()
	_update_density_variation(delta)
	_update_speed_response(delta)
	_sync_wave_parameters(false)
	if _particles.emitting:
		_seconds_since_emission = 0.0
	else:
		_seconds_since_emission += delta
	if not wake_enabled and _seconds_since_emission >= profile.particle_lifetime_max_seconds * 1.15:
		_particles.visible = false
		_particle_system_live = false
		set_process(false)


func set_wake_enabled(enabled: bool) -> void:
	if wake_enabled == enabled:
		return
	wake_enabled = enabled
	if enabled:
		_last_boat_position = _boat.global_position if _boat != null else Vector3.ZERO
		if not _particle_system_live and _particles != null:
			_particles.restart()
			_particle_system_live = true
		if _particles != null:
			_particles.visible = true
		set_process(true)
	elif _particles != null:
		_particles.emitting = false
		set_process(true)


func set_wake_profile(new_profile: WakeProfile) -> void:
	if new_profile == null or new_profile == profile:
		return
	profile = new_profile
	if _particles == null:
		return
	_apply_profile_to_particles()
	_sync_wave_parameters(true)


## Clear existing world-space particles after a teleport or scene relocation.
func reset_wake() -> void:
	if _particles == null:
		return
	_last_boat_position = _boat.global_position if _boat != null else Vector3.ZERO
	_measured_speed_mps = 0.0
	_smoothed_speed_mps = 0.0
	_emission_ratio = 0.0
	_seconds_since_emission = 0.0
	_particles.emitting = false
	_particles.restart()
	_particles.visible = wake_enabled
	_particle_system_live = wake_enabled
	_update_particle_transform()
	if wake_enabled:
		set_process(true)
	else:
		_seconds_since_emission = profile.particle_lifetime_max_seconds
		set_process(false)


func get_measured_speed_mps() -> float:
	return _measured_speed_mps


func get_smoothed_speed_mps() -> float:
	return _smoothed_speed_mps


func get_emission_ratio() -> float:
	return _emission_ratio


func get_particle_capacity() -> int:
	return profile.max_particle_budget if profile != null else 0


func get_lifetime_range_seconds() -> Vector2:
	if profile == null:
		return Vector2.ZERO
	return Vector2(profile.particle_lifetime_min_seconds, profile.particle_lifetime_max_seconds)


func get_estimated_steady_state_particle_count() -> int:
	# Exact live-particle count requires GPU readback; this is the active budget estimate.
	return roundi(float(get_particle_capacity()) * _emission_ratio)


func get_profile_name() -> String:
	return profile.profile_name if profile != null else "None"


func _create_emitter() -> void:
	_particles = GPUParticles3D.new()
	_particles.name = "WorldSpaceFoamParticles"
	_particles.one_shot = false
	_particles.local_coords = false
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.visibility_aabb = AABB(Vector3(-72.0, -18.0, -72.0), Vector3(144.0, 36.0, 144.0))
	_particles.emitting = false
	_emitter.add_child(_particles)

	var plane := PlaneMesh.new()
	plane.size = Vector2(0.95, 0.95)
	plane.subdivide_width = 1
	plane.subdivide_depth = 1
	_particles.draw_pass_1 = plane

	_process_material = ParticleProcessMaterial.new()
	_process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_process_material.direction = Vector3(0.0, 0.0, 1.0)
	_process_material.gravity = Vector3.ZERO
	_process_material.inherit_velocity_ratio = 0.0
	_process_material.particle_flag_rotate_y = true
	_process_material.angle_min = -180.0
	_process_material.angle_max = 180.0
	_process_material.scale_curve = _make_scale_curve()
	_particles.process_material = _process_material

	_draw_material = ShaderMaterial.new()
	_draw_material.shader = FOAM_SHADER
	_draw_material.render_priority = 13
	plane.material = _draw_material
	_apply_profile_to_particles()
	_particles.visible = true
	add_to_group("wake_system")


func _apply_profile_to_particles() -> void:
	if _particles == null or _process_material == null or _draw_material == null or profile == null:
		return
	_particles.amount = profile.max_particle_budget
	_particles.lifetime = profile.particle_lifetime_max_seconds
	_process_material.lifetime_randomness = clampf(
		1.0 - profile.particle_lifetime_min_seconds / maxf(profile.particle_lifetime_max_seconds, 0.01),
		0.0,
		0.95
	)
	_process_material.color_ramp = _make_color_ramp(profile)
	_process_material.hue_variation_min = -profile.color_hue_variation
	_process_material.hue_variation_max = profile.color_hue_variation
	_process_material.scale_min = profile.particle_size_min_m
	_process_material.scale_max = profile.particle_size_max_m
	_process_material.emission_box_extents = Vector3(profile.spawn_half_width_min_m, 0.012, profile.spawn_length_half_extent_m)
	_process_material.spread = profile.lateral_spread_min_degrees
	_process_material.initial_velocity_min = profile.initial_velocity_min_mps
	_process_material.initial_velocity_max = profile.initial_velocity_max_mps
	_draw_material.set_shader_parameter("wake_tint", profile.wake_tint)
	_draw_material.set_shader_parameter("foam_tint", profile.foam_tint)
	_draw_material.set_shader_parameter("particle_opacity_min", 0.56)
	_draw_material.set_shader_parameter("particle_opacity_max", 1.0)


func _make_scale_curve() -> CurveTexture:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.58))
	curve.add_point(Vector2(0.14, 0.92))
	curve.add_point(Vector2(0.72, 1.16))
	curve.add_point(Vector2(1.0, 1.24))
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture


func _make_color_ramp(_wake_profile: WakeProfile) -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.96, 1.0, 0.99, 0.28))
	gradient.add_point(0.12, Color(0.93, 1.0, 0.99, 0.92))
	gradient.add_point(0.58, Color(0.84, 0.94, 0.92, 0.78))
	gradient.set_color(gradient.get_point_count() - 1, Color(0.72, 0.84, 0.84, 0.0))
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture


func _update_density_variation(delta: float) -> void:
	_density_change_time -= delta
	if _density_change_time <= 0.0:
		_density_target = randf_range(0.84, 1.16)
		_density_change_time = randf_range(1.8, 4.4)
	_density_multiplier = lerpf(_density_multiplier, _density_target, 1.0 - exp(-0.85 * delta))


func _update_particle_transform() -> void:
	if _emitter == null or _particles == null:
		return
	var stern_world := _emitter.global_position
	var sample_time := float(_wave_sampler.get("wave_time_seconds"))
	var surface: Dictionary = _wave_sampler.call("sample_surface", stern_world, sample_time)
	stern_world.y = float(surface["height"]) + emitter_height_offset_m
	var heading := -_boat.global_basis.z
	heading.y = 0.0
	if heading.length_squared() < 0.0001:
		heading = Vector3.FORWARD
	var horizontal_heading_basis := Basis.looking_at(heading.normalized(), Vector3.UP)
	_particles.global_transform = Transform3D(horizontal_heading_basis, stern_world)


func _update_speed_response(delta: float) -> void:
	var normalized := clampf(
		(_smoothed_speed_mps - profile.minimum_visible_speed_mps)
		/ maxf(profile.full_effect_speed_mps - profile.minimum_visible_speed_mps, 0.1),
		0.0,
		1.0
	)
	var speed_factor := pow(normalized, 1.0 / maxf(profile.speed_influence, 0.05))
	speed_factor = speed_factor * speed_factor * (3.0 - 2.0 * speed_factor)
	var moving_gate := smoothstep(profile.minimum_visible_speed_mps * 0.68, profile.minimum_visible_speed_mps * 1.75, _smoothed_speed_mps)
	var target_ratio := 0.0
	if wake_enabled:
		target_ratio = moving_gate * lerpf(profile.emission_strength_min, profile.emission_strength_max, speed_factor)
	var response := 1.0 - exp(-profile.response_speed * delta)
	_emission_ratio = lerpf(_emission_ratio, target_ratio * _density_multiplier, response)
	_particles.amount_ratio = clampf(_emission_ratio, 0.0, 1.0)
	_particles.speed_scale = lerpf(1.12, 0.88, speed_factor)
	_process_material.emission_box_extents = Vector3(
		lerpf(profile.spawn_half_width_min_m, profile.spawn_half_width_max_m, speed_factor),
		0.012,
		profile.spawn_length_half_extent_m
	)
	_process_material.spread = lerpf(profile.lateral_spread_min_degrees, profile.lateral_spread_max_degrees, speed_factor)
	_process_material.initial_velocity_min = profile.initial_velocity_min_mps
	_process_material.initial_velocity_max = lerpf(profile.initial_velocity_min_mps, profile.initial_velocity_max_mps, speed_factor)
	_process_material.scale_min = lerpf(profile.particle_size_min_m * 0.82, profile.particle_size_min_m, speed_factor)
	_process_material.scale_max = lerpf(profile.particle_size_max_m * 0.82, profile.particle_size_max_m, speed_factor)
	_draw_material.set_shader_parameter(
		"wake_opacity",
		lerpf(profile.wake_opacity_min, profile.wake_opacity_max, speed_factor)
	)
	_draw_material.set_shader_parameter(
		"foam_opacity",
		lerpf(profile.foam_opacity_min, profile.foam_opacity_max, speed_factor)
	)
	if not wake_enabled or _emission_ratio <= 0.008:
		_particles.emitting = false
	else:
		if not _particle_system_live:
			_particles.restart()
			_particles.visible = true
			_particle_system_live = true
		_particles.emitting = true


func _sync_wave_parameters(force: bool) -> void:
	if _draw_material == null or _wave_sampler == null:
		return
	var wave_time := float(_wave_sampler.get("wave_time_seconds"))
	var wave_settings := _wave_sampler.get("wave_settings") as SeaWaveSettings
	var source_material := _wave_sampler.get("water_material") as ShaderMaterial
	var strength := float(_wave_sampler.get("wave_strength"))
	var parameter_revision := -1
	if _wave_sampler.has_method("get_effective_wave_settings"):
		wave_settings = _wave_sampler.call("get_effective_wave_settings") as SeaWaveSettings
		strength = float(_wave_sampler.call("get_effective_wave_strength"))
		parameter_revision = int(_wave_sampler.call("get_wave_parameter_revision"))
	var count := 0 if wave_settings == null else mini(wave_settings.waves.size(), MAX_WAVES)
	if force or parameter_revision != _source_wave_parameter_revision:
		var steepnesses := PackedFloat32Array()
		var amplitudes := PackedFloat32Array()
		var directions := PackedFloat32Array()
		var frequencies := PackedFloat32Array()
		var speeds := PackedFloat32Array()
		var phases := PackedFloat32Array()
		if wave_settings != null:
			for index in range(count):
				var wave: GerstnerWave = wave_settings.waves[index]
				steepnesses.append(wave.steepness * strength)
				amplitudes.append(wave.amplitude * strength)
				directions.append(wave.direction_degrees)
				frequencies.append(wave.frequency)
				speeds.append(wave.speed)
				phases.append(wave.phase_degrees)
		_draw_material.set_shader_parameter("wave_count", count)
		_draw_material.set_shader_parameter("wave_steepness", steepnesses)
		_draw_material.set_shader_parameter("wave_amplitude", amplitudes)
		_draw_material.set_shader_parameter("wave_direction_degrees", directions)
		_draw_material.set_shader_parameter("wave_frequency", frequencies)
		_draw_material.set_shader_parameter("wave_speed", speeds)
		_draw_material.set_shader_parameter("wave_phase_degrees", phases)
		_source_wave_parameter_revision = parameter_revision
	if source_material != null:
		var frozen := bool(source_material.get_shader_parameter("freeze_time"))
		_draw_material.set_shader_parameter("wave_time", 0.0 if frozen else wave_time)
		_draw_material.set_shader_parameter("vertex_wave_fade_min", float(source_material.get_shader_parameter("vertex_wave_fade_min")))
		_draw_material.set_shader_parameter("vertex_wave_fade_max", float(source_material.get_shader_parameter("vertex_wave_fade_max")))
	else:
		_draw_material.set_shader_parameter("wave_time", wave_time)
	_draw_material.set_shader_parameter("water_plane_y", _ocean.global_position.y if _ocean != null else 0.0)
	var active_camera := get_viewport().get_camera_3d()
	if active_camera != null:
		_draw_material.set_shader_parameter("camera_world_position", active_camera.global_position)
	_draw_material.set_shader_parameter("surface_offset", surface_offset_m)
