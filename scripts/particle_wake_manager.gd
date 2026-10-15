extends Node3D

## Independent GPUParticles3D wake for the SimpleParticleWake comparison scene.
## One scene unit is one meter; the boat model's bow points along local -Z, so
## the emitter is placed 2.75 m aft in local +Z. Particle positions are world-space.

const FOAM_SHADER := preload("res://shaders/particle_wake_foam.gdshader")
const MAX_WAVES := 8

@export_category("Scene references")
@export_node_path("Node3D") var boat_motion_path := NodePath("../Main/PlayerBoat/MotionRoot")
@export_node_path("Node") var wave_sampler_path := NodePath("../Main/WaveSampler")
@export_node_path("Node3D") var ocean_path := NodePath("../Main/Ocean")

@export_category("Emitter")
@export_range(0.0, 10.0, 0.05) var stern_offset_m := 2.75
@export_range(100, 300, 10) var particle_capacity := 240
@export_range(1.0, 10.0, 0.1) var particle_lifetime_seconds := 4.0
@export_range(0.0, 0.2, 0.005) var surface_offset_m := 0.045
@export_range(0.0, 0.3, 0.01) var emitter_height_offset_m := 0.025

@export_category("Speed response")
@export_range(0.1, 3.0, 0.1) var emission_start_speed_mps := 0.35
@export_range(1.0, 20.0, 0.5) var full_speed_mps := 12.0
@export_range(0.0, 1.0, 0.01) var low_speed_emission_ratio := 0.08
@export_range(0.0, 1.0, 0.01) var high_speed_emission_ratio := 0.86
@export_range(0.1, 5.0, 0.1) var response_speed := 1.8

@export_category("Foam appearance")
@export var wake_tint := Color(0.28, 0.62, 0.64, 1.0)
@export var foam_tint := Color(0.83, 0.92, 0.89, 1.0)
@export_range(0.0, 1.0, 0.01) var wake_opacity := 0.26
@export_range(0.0, 1.0, 0.01) var foam_opacity := 0.76
@export_range(0.0, 1.0, 0.01) var foam_threshold := 0.51
@export_range(0.01, 0.5, 0.01) var foam_softness := 0.14

var _boat: BoatController
var _wave_sampler: Node
var _ocean: Node3D
var _particles: GPUParticles3D
var _process_material: ParticleProcessMaterial
var _draw_material: ShaderMaterial
var _last_boat_position := Vector3.ZERO
var _measured_speed_mps := 0.0
var _smoothed_speed_mps := 0.0
var _emission_ratio := 0.0
var _active := false


func _ready() -> void:
	process_priority = 200
	_boat = get_node_or_null(boat_motion_path) as BoatController
	_wave_sampler = get_node_or_null(wave_sampler_path)
	_ocean = get_node_or_null(ocean_path) as Node3D
	if _boat == null:
		push_error("ParticleWakeManager could not find the boat at %s." % boat_motion_path)
		return
	if _wave_sampler == null or not _wave_sampler.has_method("sample_surface"):
		push_error("ParticleWakeManager requires WaveSampler.sample_surface().")
		return
	_create_emitter()
	_sync_wave_parameters(true)
	_last_boat_position = _boat.global_position
	set_process(false)


func set_wake_active(active: bool) -> void:
	if _particles == null or _active == active:
		return
	_active = active
	if active:
		_last_boat_position = _boat.global_position
		_measured_speed_mps = 0.0
		_smoothed_speed_mps = 0.0
		_emission_ratio = 0.0
		_particles.visible = true
		_particles.emitting = false
		_particles.restart()
		_particles.emitting = true
		set_process(true)
	else:
		_particles.emitting = false
		_particles.visible = false
		set_process(false)


func get_measured_speed_mps() -> float:
	return _measured_speed_mps


func get_emission_ratio() -> float:
	return _emission_ratio


func get_particle_capacity() -> int:
	return particle_capacity


func get_estimated_steady_state_particle_count() -> int:
	# GPUParticles3D does not expose exact active count without GPU readback.
	# At steady speed, amount * amount_ratio is its live-particle budget.
	return roundi(float(particle_capacity) * _emission_ratio)


func get_lifetime_range_seconds() -> Vector2:
	var speed_factor := _speed_factor(_smoothed_speed_mps)
	var simulation_scale := lerpf(1.12, 0.88, speed_factor)
	var effective_lifetime := particle_lifetime_seconds / simulation_scale
	return Vector2(effective_lifetime, effective_lifetime)


func _process(delta: float) -> void:
	if not _active or _boat == null or _particles == null:
		return
	var displacement := _boat.global_position - _last_boat_position
	displacement.y = 0.0
	_measured_speed_mps = displacement.length() / maxf(delta, 0.0001)
	_last_boat_position = _boat.global_position
	var response := 1.0 - exp(-response_speed * delta)
	_smoothed_speed_mps = lerpf(_smoothed_speed_mps, _measured_speed_mps, response)
	_update_emitter_transform()
	_update_speed_response(delta)
	_sync_wave_parameters(false)


func _create_emitter() -> void:
	_particles = GPUParticles3D.new()
	_particles.name = "WorldSpaceFoamParticles"
	_particles.amount = particle_capacity
	_particles.lifetime = particle_lifetime_seconds
	_particles.emitting = false
	_particles.one_shot = false
	_particles.local_coords = false
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.visibility_aabb = AABB(Vector3(-72.0, -18.0, -72.0), Vector3(144.0, 36.0, 144.0))
	_particles.visible = false

	var plane := PlaneMesh.new()
	plane.size = Vector2(0.95, 0.95)
	plane.subdivide_width = 1
	plane.subdivide_depth = 1
	_particles.draw_pass_1 = plane

	_process_material = ParticleProcessMaterial.new()
	_process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_process_material.emission_box_extents = Vector3(0.3, 0.015, 0.2)
	_process_material.direction = Vector3(0.0, 0.0, 1.0)
	_process_material.spread = 12.0
	_process_material.initial_velocity_min = 0.05
	_process_material.initial_velocity_max = 0.55
	_process_material.gravity = Vector3.ZERO
	_process_material.inherit_velocity_ratio = 0.0
	_process_material.particle_flag_rotate_y = true
	_process_material.angle_min = -180.0
	_process_material.angle_max = 180.0
	_process_material.scale_min = 0.48
	_process_material.scale_max = 0.92
	_process_material.scale_curve = _make_scale_curve()
	_process_material.color_ramp = _make_color_ramp()
	_particles.process_material = _process_material

	_draw_material = ShaderMaterial.new()
	_draw_material.shader = FOAM_SHADER
	_draw_material.render_priority = 13
	_draw_material.set_shader_parameter("wake_tint", wake_tint)
	_draw_material.set_shader_parameter("foam_tint", foam_tint)
	_draw_material.set_shader_parameter("wake_opacity", wake_opacity)
	_draw_material.set_shader_parameter("foam_opacity", foam_opacity)
	_draw_material.set_shader_parameter("foam_threshold", foam_threshold)
	_draw_material.set_shader_parameter("foam_softness", foam_softness)
	plane.material = _draw_material
	add_child(_particles)


func _make_scale_curve() -> CurveTexture:
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.58))
	curve.add_point(Vector2(0.14, 0.92))
	curve.add_point(Vector2(0.72, 1.16))
	curve.add_point(Vector2(1.0, 1.24))
	var texture := CurveTexture.new()
	texture.curve = curve
	return texture


func _make_color_ramp() -> GradientTexture1D:
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.94, 1.0, 0.98, 0.22))
	gradient.add_point(0.12, Color(0.91, 1.0, 0.98, 0.86))
	gradient.add_point(0.62, Color(0.78, 0.91, 0.90, 0.72))
	gradient.set_color(gradient.get_point_count() - 1, Color(0.72, 0.84, 0.84, 0.0))
	var texture := GradientTexture1D.new()
	texture.gradient = gradient
	return texture


func _update_emitter_transform() -> void:
	var stern_world := _boat.global_transform * Vector3(0.0, 0.0, stern_offset_m)
	var sample_time := float(_wave_sampler.get("wave_time_seconds"))
	var surface: Dictionary = _wave_sampler.call("sample_surface", stern_world, sample_time)
	stern_world.y = float(surface["height"]) + emitter_height_offset_m
	_particles.global_transform = Transform3D(_boat.global_basis.orthonormalized(), stern_world)


func _update_speed_response(delta: float) -> void:
	var speed_factor := _speed_factor(_smoothed_speed_mps)
	var moving_gate := smoothstep(emission_start_speed_mps * 0.65, emission_start_speed_mps * 2.0, _smoothed_speed_mps)
	var target_ratio := moving_gate * lerpf(low_speed_emission_ratio, high_speed_emission_ratio, speed_factor)
	var blend := 1.0 - exp(-response_speed * delta)
	_emission_ratio = lerpf(_emission_ratio, target_ratio, blend)
	_particles.amount_ratio = _emission_ratio
	_particles.speed_scale = lerpf(1.12, 0.88, speed_factor)
	_process_material.emission_box_extents = Vector3(lerpf(0.28, 0.78, speed_factor), 0.015, 0.2)
	_process_material.initial_velocity_max = lerpf(0.3, 0.8, speed_factor)
	_process_material.scale_min = lerpf(0.42, 0.60, speed_factor)
	_process_material.scale_max = lerpf(0.76, 1.08, speed_factor)
	if _emission_ratio <= 0.008:
		_particles.emitting = false
	else:
		_particles.emitting = true


func _sync_wave_parameters(force: bool) -> void:
	if _draw_material == null or _wave_sampler == null:
		return
	var wave_time := float(_wave_sampler.get("wave_time_seconds"))
	var wave_settings := _wave_sampler.get("wave_settings") as SeaWaveSettings
	var source_material := _wave_sampler.get("water_material") as ShaderMaterial
	var strength := float(_wave_sampler.get("wave_strength"))
	var source_strength := -1.0
	if _draw_material.has_meta("wave_strength"):
		source_strength = float(_draw_material.get_meta("wave_strength"))
	var count := 0 if wave_settings == null else mini(wave_settings.waves.size(), MAX_WAVES)
	if force or absf(strength - source_strength) > 0.001:
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
		_draw_material.set_meta("wave_strength", strength)
	if source_material != null:
		var frozen := bool(source_material.get_shader_parameter("freeze_time"))
		_draw_material.set_shader_parameter("wave_time", 0.0 if frozen else wave_time)
		_draw_material.set_shader_parameter(
			"vertex_wave_fade_min",
			float(source_material.get_shader_parameter("vertex_wave_fade_min"))
		)
		_draw_material.set_shader_parameter(
			"vertex_wave_fade_max",
			float(source_material.get_shader_parameter("vertex_wave_fade_max"))
		)
	else:
		_draw_material.set_shader_parameter("wave_time", wave_time)
	_draw_material.set_shader_parameter(
		"water_plane_y",
		_ocean.global_position.y if _ocean != null else 0.0
	)
	var active_camera := get_viewport().get_camera_3d()
	if active_camera != null:
		_draw_material.set_shader_parameter("camera_world_position", active_camera.global_position)
	_draw_material.set_shader_parameter("surface_offset", surface_offset_m)
	_draw_material.set_shader_parameter("wake_tint", wake_tint)
	_draw_material.set_shader_parameter("foam_tint", foam_tint)
	_draw_material.set_shader_parameter("wake_opacity", wake_opacity)
	_draw_material.set_shader_parameter("foam_opacity", foam_opacity)
	_draw_material.set_shader_parameter("foam_threshold", foam_threshold)
	_draw_material.set_shader_parameter("foam_softness", foam_softness)


func _speed_factor(speed_mps: float) -> float:
	var normalized := clampf(speed_mps / maxf(full_speed_mps, 0.1), 0.0, 1.0)
	return normalized * normalized * (3.0 - 2.0 * normalized)
