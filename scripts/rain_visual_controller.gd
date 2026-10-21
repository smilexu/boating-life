extends Node
class_name RainVisualController

## Client-only presentation for authoritative precipitation. Rain never feeds
## back into weather, WindField, WaveSampler, or vessel physics.

enum Quality { LOW, MEDIUM, HIGH }

@export_node_path("Node") var weather_state_controller_path := NodePath("../WeatherStateController")
@export_node_path("Node") var wind_field_path := NodePath("../WindField")
@export_node_path("WeatherController") var weather_controller_path := NodePath("../WeatherController")
@export var water_material: ShaderMaterial
@export_enum("Low", "Medium", "High") var quality_level: int = Quality.MEDIUM
@export_range(0.1, 10.0, 0.1) var rain_response_time_seconds := 2.0
@export_range(0.0, 2.0, 0.01) var streak_density_multiplier := 1.0
@export_range(0.0, 2.0, 0.01) var near_streak_multiplier := 1.0
@export_range(0.0, 1.0, 0.01) var wind_tilt_influence := 0.22
@export_range(0.0, 1.0, 0.01) var streak_opacity := 0.62
@export_range(0.05, 1.5, 0.05) var streak_length_meters := 0.72
@export_range(0.0, 2.0, 0.01) var micro_impact_density_multiplier := 1.0
@export_range(0.4, 1.5, 0.01) var ring_size_multiplier := 1.0
@export_range(0.0, 2.0, 0.01) var ring_probability_multiplier := 1.0
@export_range(0.0, 2.0, 0.01) var sea_impact_multiplier := 1.0
@export_range(0.0, 1.0, 0.01) var haze_multiplier := 1.0

const RAIN_SHADER_DENSITY := "rain_impact_density"
const RAIN_SHADER_STRENGTH := "rain_impact_strength"
const RAIN_SHADER_CELL_SIZE := "rain_impact_cell_size"
const RAIN_SHADER_MICRO_DENSITY := "rain_micro_density"
const RAIN_SHADER_MICRO_CELL_SIZE := "rain_micro_cell_size"
const RAIN_SHADER_RING_SIZE := "rain_ring_size"
const WIND_SAMPLE_INTERVAL_SECONDS := 0.75
const EMITTER_FOLLOW_INTERVAL_SECONDS := 0.10
const PARTICLE_AMOUNT_BUCKETS := 12

var formal_rate_mm_per_hour := 0.0
var formal_rate_available := false
var formal_data_quality := "unavailable"
var current_visual_rate_mm_per_hour := 0.0
var debug_override_active := false
var debug_override_rate_mm_per_hour := 0.0
var audio_intensity := 0.0
var rain_haze_strength := 0.0

var _weather_state_controller: Node
var _wind_field: Node
var _weather_controller: Node
var _particles: GPUParticles3D
var _near_particles: GPUParticles3D
var _particle_process_material: ParticleProcessMaterial
var _near_particle_process_material: ParticleProcessMaterial
var _particle_draw_material: StandardMaterial3D
var _near_particle_draw_material: StandardMaterial3D
var _rain_quad: QuadMesh
var _near_rain_quad: QuadMesh
var _target_rate_mm_per_hour := 0.0
var _current_profile: Dictionary = {}
var _current_wind_velocity := Vector3.ZERO
var _wind_sample_elapsed := 0.0
var _follow_elapsed := 0.0
var _amount_update_elapsed := 0.0
var _last_mid_amount_bucket := -1
var _last_near_amount_bucket := -1
var _visuals_created := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_weather_state_controller = get_node_or_null(weather_state_controller_path)
	_wind_field = get_node_or_null(wind_field_path)
	_weather_controller = get_node_or_null(weather_controller_path)
	if _weather_state_controller != null:
		if _weather_state_controller.has_signal("precipitation_visual_target_changed"):
			_weather_state_controller.precipitation_visual_target_changed.connect(_on_formal_precipitation_changed)
		if _weather_state_controller.has_method("get_precipitation_visual_state"):
			_on_formal_precipitation_changed(_weather_state_controller.call("get_precipitation_visual_state"))
	if water_material != null:
		_set_surface_rain_parameters(0.0, 0.0, 0.0, 1.0)
	if not _should_create_client_visuals(OS.has_feature("dedicated_server"), DisplayServer.get_name()):
		set_process(false)
		return
	_create_particle_system()
	_visuals_created = true


func _exit_tree() -> void:
	if _particles != null:
		_particles.emitting = false
	if _near_particles != null:
		_near_particles.emitting = false
	if water_material != null:
		_set_surface_rain_parameters(0.0, 0.0, 0.0, 1.0)
	if _weather_controller != null and _weather_controller.has_method("set_rain_haze_strength"):
		_weather_controller.call("set_rain_haze_strength", 0.0)
	if _weather_state_controller != null and _weather_state_controller.has_signal("precipitation_visual_target_changed"):
		var callback := Callable(self, "_on_formal_precipitation_changed")
		if _weather_state_controller.is_connected("precipitation_visual_target_changed", callback):
			_weather_state_controller.disconnect("precipitation_visual_target_changed", callback)


func _process(delta: float) -> void:
	if delta <= 0.0 or not is_finite(delta):
		return
	var desired_rate := debug_override_rate_mm_per_hour if debug_override_active else formal_rate_mm_per_hour
	_target_rate_mm_per_hour = maxf(desired_rate, 0.0)
	current_visual_rate_mm_per_hour = RainVisualProfile.smooth_value(
		current_visual_rate_mm_per_hour,
		_target_rate_mm_per_hour,
		delta,
		rain_response_time_seconds
	)
	_current_profile = RainVisualProfile.from_precipitation_rate(current_visual_rate_mm_per_hour)
	_update_visual_outputs(delta)


func set_debug_override(rate_mm_per_hour: float) -> void:
	debug_override_active = true
	debug_override_rate_mm_per_hour = clampf(rate_mm_per_hour, 0.0, 30.0) if is_finite(rate_mm_per_hour) else 0.0


func set_debug_controls(values: Dictionary) -> void:
	wind_tilt_influence = clampf(float(values.get("wind_tilt_influence", wind_tilt_influence)), 0.0, 1.0)
	streak_density_multiplier = clampf(float(values.get("streak_density_multiplier", streak_density_multiplier)), 0.0, 2.0)
	near_streak_multiplier = clampf(float(values.get("near_streak_multiplier", near_streak_multiplier)), 0.0, 2.0)
	streak_opacity = clampf(float(values.get("streak_opacity", streak_opacity)), 0.0, 1.0)
	streak_length_meters = clampf(float(values.get("streak_length_meters", streak_length_meters)), 0.05, 1.5)
	micro_impact_density_multiplier = clampf(float(values.get("micro_impact_density_multiplier", micro_impact_density_multiplier)), 0.0, 2.0)
	ring_size_multiplier = clampf(float(values.get("ring_size_multiplier", ring_size_multiplier)), 0.4, 1.5)
	ring_probability_multiplier = clampf(float(values.get("ring_probability_multiplier", ring_probability_multiplier)), 0.0, 2.0)
	sea_impact_multiplier = clampf(float(values.get("sea_impact_multiplier", sea_impact_multiplier)), 0.0, 2.0)
	haze_multiplier = clampf(float(values.get("haze_multiplier", haze_multiplier)), 0.0, 1.0)
	quality_level = clampi(int(values.get("quality_level", quality_level)), Quality.LOW, Quality.HIGH)
	_apply_quality_to_particles()


func clear_debug_override() -> void:
	debug_override_active = false
	# The following frame eases toward the most recent formal AUTO/manual target.


func get_diagnostic_state() -> Dictionary:
	var adjusted := _profile_with_debug_adjustments(_current_profile)
	var surface_micro_density := 0.0
	var surface_micro_cell_size := 0.0
	var surface_impact_strength := 0.0
	var surface_ring_density := 0.0
	if water_material != null:
		surface_micro_density = float(water_material.get_shader_parameter(RAIN_SHADER_MICRO_DENSITY))
		surface_micro_cell_size = float(water_material.get_shader_parameter(RAIN_SHADER_MICRO_CELL_SIZE))
		surface_impact_strength = float(water_material.get_shader_parameter(RAIN_SHADER_STRENGTH))
		surface_ring_density = float(water_material.get_shader_parameter(RAIN_SHADER_DENSITY))
	return {
		"formal_rate_mm_per_hour": formal_rate_mm_per_hour,
		"formal_rate_available": formal_rate_available,
		"formal_data_quality": formal_data_quality,
		"operating_mode": String(_weather_state_controller.call("get_operating_mode_name")) if _weather_state_controller != null and _weather_state_controller.has_method("get_operating_mode_name") else "N/A",
		"visual_rate_mm_per_hour": current_visual_rate_mm_per_hour,
		"debug_override_active": debug_override_active,
		"debug_override_rate_mm_per_hour": debug_override_rate_mm_per_hour,
		"quality": _quality_name(quality_level),
		"rain_intensity": float(adjusted.get("intensity", 0.0)),
		"mid_streak_density": float(adjusted.get("streak_density", 0.0)),
		"near_streak_density": float(adjusted.get("near_streak_density", 0.0)),
		"micro_impact_density": float(adjusted.get("micro_impact_density", 0.0)),
		"ring_probability": float(adjusted.get("sea_impact_density", 0.0)),
		"surface_micro_density": surface_micro_density,
		"surface_micro_cell_size": surface_micro_cell_size,
		"surface_impact_strength": surface_impact_strength,
		"surface_ring_density": surface_ring_density,
		"haze_strength": rain_haze_strength,
		"wind_velocity_to": _current_wind_velocity,
		"wind_flow_direction": RainVisualProfile.blend_wind_flow_toward(_current_wind_velocity, wind_tilt_influence),
		"audio_intensity_reserved": audio_intensity,
		"particle_count": (_particles.amount + _near_particles.amount) if _particles != null and _near_particles != null else 0,
		"particle_count_budget": int(_quality_configuration(quality_level)["amount"]),
		"visuals_created": _visuals_created,
	}


func get_formal_precipitation_state() -> Dictionary:
	return {
		"intensity_mm_per_hour": formal_rate_mm_per_hour,
		"available": formal_rate_available,
		"data_quality": formal_data_quality,
	}


func is_debug_override_active() -> bool:
	return debug_override_active


func set_quality_level(level: int) -> void:
	quality_level = clampi(level, Quality.LOW, Quality.HIGH)
	_apply_quality_to_particles()


static func _should_create_client_visuals(is_dedicated_server: bool, display_server_name: String) -> bool:
	return not is_dedicated_server and display_server_name.to_lower() != "headless"


static func _quality_configuration(level: int) -> Dictionary:
	match clampi(level, Quality.LOW, Quality.HIGH):
		Quality.LOW:
			return {"amount": 1000, "mid_amount": 760, "near_amount": 240, "cell_size": 2.7, "micro_cell_size": 0.62, "haze_cap": 0.22}
		Quality.MEDIUM:
			return {"amount": 2200, "mid_amount": 1700, "near_amount": 500, "cell_size": 2.5, "micro_cell_size": 0.42, "haze_cap": 0.52}
		_:
			return {"amount": 3800, "mid_amount": 2850, "near_amount": 950, "cell_size": 2.3, "micro_cell_size": 0.30, "haze_cap": 0.62}


func _on_formal_precipitation_changed(state: Dictionary) -> void:
	formal_rate_available = bool(state.get("available", false))
	formal_rate_mm_per_hour = maxf(float(state.get("intensity_mm_per_hour", 0.0)), 0.0) if formal_rate_available else 0.0
	formal_data_quality = str(state.get("data_quality", "unavailable"))
	if not debug_override_active:
		_target_rate_mm_per_hour = formal_rate_mm_per_hour


func _create_particle_system() -> void:
	var mid_configuration := _build_particle_layer("LocalRainVolume", false)
	_particles = mid_configuration["particles"] as GPUParticles3D
	_particle_process_material = mid_configuration["process_material"] as ParticleProcessMaterial
	_particle_draw_material = mid_configuration["draw_material"] as StandardMaterial3D
	_rain_quad = mid_configuration["quad"] as QuadMesh
	var near_configuration := _build_particle_layer("NearRainVolume", true)
	_near_particles = near_configuration["particles"] as GPUParticles3D
	_near_particle_process_material = near_configuration["process_material"] as ParticleProcessMaterial
	_near_particle_draw_material = near_configuration["draw_material"] as StandardMaterial3D
	_near_rain_quad = near_configuration["quad"] as QuadMesh
	_apply_quality_to_particles()


func _build_particle_layer(layer_name: String, is_near_layer: bool) -> Dictionary:
	var particles := GPUParticles3D.new()
	particles.name = layer_name
	particles.one_shot = false
	particles.emitting = false
	particles.local_coords = false
	particles.explosiveness = 0.0
	particles.speed_scale = 1.0
	var process_material := ParticleProcessMaterial.new()
	process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process_material.direction = Vector3(0.0, -1.0, 0.0)
	process_material.particle_flag_align_y = true
	if is_near_layer:
		particles.lifetime = 0.62
		particles.visibility_aabb = AABB(Vector3(-18.0, -22.0, -18.0), Vector3(36.0, 42.0, 36.0))
		process_material.emission_box_extents = Vector3(10.0, 5.0, 10.0)
		process_material.spread = 1.1
		process_material.initial_velocity_min = 20.0
		process_material.initial_velocity_max = 27.0
		process_material.gravity = Vector3(0.0, -2.0, 0.0)
		process_material.scale_min = 0.85
		process_material.scale_max = 1.25
		process_material.color = Color(0.84, 0.89, 0.92, 1.0)
	else:
		particles.lifetime = 2.0
		particles.visibility_aabb = AABB(Vector3(-58.0, -64.0, -58.0), Vector3(116.0, 128.0, 116.0))
		process_material.emission_box_extents = Vector3(34.0, 16.0, 34.0)
		process_material.spread = 1.5
		process_material.initial_velocity_min = 18.0
		process_material.initial_velocity_max = 23.0
		process_material.gravity = Vector3(0.0, -3.0, 0.0)
		process_material.scale_min = 0.8
		process_material.scale_max = 1.2
		process_material.color = Color(0.82, 0.88, 0.92, 1.0)
	particles.process_material = process_material
	var quad := QuadMesh.new()
	quad.size = Vector2(0.014, streak_length_meters * (1.18 if is_near_layer else 1.0))
	var draw_material := StandardMaterial3D.new()
	draw_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	draw_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	draw_material.roughness = 1.0
	draw_material.albedo_color = Color(0.70, 0.76, 0.81, 0.5)
	quad.material = draw_material
	particles.draw_passes = 1
	particles.draw_pass_1 = quad
	add_child(particles)
	return {"particles": particles, "process_material": process_material, "draw_material": draw_material, "quad": quad}


func _update_visual_outputs(delta: float) -> void:
	if not _visuals_created:
		return
	var profile := _profile_with_debug_adjustments(_current_profile)
	var intensity := float(profile.get("intensity", 0.0))
	var daylight := _get_daylight_weight()
	# Muted grey rain remains legible in darkness without becoming emissive.
	var alpha_scale := lerpf(0.62, 1.0, daylight)
	_particle_process_material.color = Color(0.82, 0.88, 0.92, 1.0)
	_near_particle_process_material.color = Color(0.84, 0.89, 0.92, 1.0)
	_particle_draw_material.albedo_color = Color(
		0.68, 0.74, 0.79,
		streak_opacity * alpha_scale * pow(intensity, 0.9) * float(profile.get("mid_streak_alpha_scale", 1.0))
	)
	_near_particle_draw_material.albedo_color = Color(0.72, 0.78, 0.82, streak_opacity * alpha_scale * pow(intensity, 0.82) * 1.10)
	_rain_quad.size = Vector2(
		0.014,
		streak_length_meters * float(profile.get("mid_streak_length_scale", 1.0))
	)
	_near_rain_quad.size = Vector2(0.018, streak_length_meters * 1.22)
	_update_wind(delta)
	_update_emitter_follow(delta)
	_update_particle_emission(delta, float(profile.get("streak_density", 0.0)), float(profile.get("near_streak_density", 0.0)))
	var impact_density := float(profile.get("sea_impact_density", 0.0))
	var impact_strength := float(profile.get("sea_impact_strength", 0.0)) * sea_impact_multiplier
	var micro_density := float(profile.get("micro_impact_density", 0.0)) * micro_impact_density_multiplier
	_set_surface_rain_parameters(impact_density, impact_strength, micro_density, ring_size_multiplier)
	var haze_cap := float(_quality_configuration(quality_level)["haze_cap"])
	rain_haze_strength = minf(float(profile.get("haze_strength", 0.0)) * haze_multiplier, haze_cap)
	if _weather_controller != null and _weather_controller.has_method("set_rain_haze_strength"):
		_weather_controller.call("set_rain_haze_strength", rain_haze_strength)
	audio_intensity = intensity


func _profile_with_debug_adjustments(base: Dictionary) -> Dictionary:
	var adjusted := base.duplicate(true)
	adjusted["streak_density"] = clampf(float(adjusted.get("streak_density", 0.0)) * streak_density_multiplier, 0.0, 1.0)
	adjusted["near_streak_density"] = clampf(float(adjusted.get("near_streak_density", 0.0)) * near_streak_multiplier, 0.0, 1.0)
	adjusted["micro_impact_density"] = clampf(float(adjusted.get("micro_impact_density", 0.0)) * micro_impact_density_multiplier, 0.0, 1.0)
	adjusted["sea_impact_density"] = clampf(float(adjusted.get("sea_impact_density", 0.0)) * ring_probability_multiplier, 0.0, 0.35)
	return adjusted


func _update_particle_emission(delta: float, mid_density: float, near_density: float) -> void:
	if current_visual_rate_mm_per_hour <= 0.002:
		_particles.emitting = false
		_near_particles.emitting = false
		_last_mid_amount_bucket = 0
		_last_near_amount_bucket = 0
		return
	if not _particles.emitting:
		_particles.emitting = true
		_particles.restart()
	if not _near_particles.emitting:
		_near_particles.emitting = true
		_near_particles.restart()
	var mid_bucket := _density_bucket(mid_density)
	var near_bucket := _density_bucket(near_density)
	_amount_update_elapsed += delta
	if (mid_bucket != _last_mid_amount_bucket or near_bucket != _last_near_amount_bucket) and _amount_update_elapsed >= 0.35:
		var config := _quality_configuration(quality_level)
		var mid_target := maxi(1, roundi(float(config["mid_amount"]) * float(mid_bucket) / float(PARTICLE_AMOUNT_BUCKETS)))
		var near_target := maxi(1, roundi(float(config["near_amount"]) * float(near_bucket) / float(PARTICLE_AMOUNT_BUCKETS)))
		_particles.amount = mid_target
		_near_particles.amount = near_target
		_last_mid_amount_bucket = mid_bucket
		_last_near_amount_bucket = near_bucket
		_amount_update_elapsed = 0.0


func _density_bucket(density: float) -> int:
	if density <= 0.001:
		return 0
	return clampi(roundi(clampf(density, 0.0, 1.0) * PARTICLE_AMOUNT_BUCKETS), 1, PARTICLE_AMOUNT_BUCKETS)


func _update_wind(delta: float) -> void:
	_wind_sample_elapsed += delta
	if _wind_sample_elapsed < WIND_SAMPLE_INTERVAL_SECONDS:
		return
	var sample_delta := _wind_sample_elapsed
	_wind_sample_elapsed = 0.0
	var camera := get_viewport().get_camera_3d()
	if camera == null or _wind_field == null or not _wind_field.has_method("get_wind_at"):
		return
	var sample: Vector3 = _wind_field.call("get_wind_at", camera.global_position)
	# WindField returns airflow TO in world space. Smooth horizontal airflow;
	# gravity remains the rain drop's dominant direction.
	var weight := 1.0 - exp(-sample_delta / 1.25)
	_current_wind_velocity = _current_wind_velocity.lerp(sample, weight)
	var flow_direction := RainVisualProfile.blend_wind_flow_toward(_current_wind_velocity, wind_tilt_influence)
	_particle_process_material.direction = flow_direction
	_near_particle_process_material.direction = flow_direction


func _update_emitter_follow(delta: float) -> void:
	_follow_elapsed += delta
	if _follow_elapsed < EMITTER_FOLLOW_INTERVAL_SECONDS:
		return
	_follow_elapsed = 0.0
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		_particles.emitting = false
		_near_particles.emitting = false
		return
	# Both systems emit in world space. Coarse snapping prevents emitter jitter;
	# existing particles continue along their world trajectories between snaps.
	var camera_position := camera.global_position
	_particles.global_position = Vector3(
		roundf(camera_position.x / 4.0) * 4.0,
		camera_position.y + 19.0,
		roundf(camera_position.z / 4.0) * 4.0
	)
	_near_particles.global_position = Vector3(
		roundf(camera_position.x / 2.0) * 2.0,
		camera_position.y + 8.0,
		roundf(camera_position.z / 2.0) * 2.0
	)


func _set_surface_rain_parameters(ring_probability: float, strength: float, micro_density: float, ring_size: float) -> void:
	if water_material == null:
		return
	var quality := _quality_configuration(quality_level)
	water_material.set_shader_parameter(RAIN_SHADER_DENSITY, clampf(ring_probability, 0.0, 0.35))
	water_material.set_shader_parameter(RAIN_SHADER_STRENGTH, clampf(strength, 0.0, 2.0))
	water_material.set_shader_parameter(RAIN_SHADER_CELL_SIZE, float(quality["cell_size"]))
	water_material.set_shader_parameter(RAIN_SHADER_MICRO_DENSITY, clampf(micro_density, 0.0, 1.0))
	water_material.set_shader_parameter(RAIN_SHADER_MICRO_CELL_SIZE, float(quality["micro_cell_size"]))
	water_material.set_shader_parameter(RAIN_SHADER_RING_SIZE, clampf(ring_size, 0.4, 1.5))


func _apply_quality_to_particles() -> void:
	var config := _quality_configuration(quality_level)
	if _particles != null and _near_particles != null:
		_particles.amount = int(config["mid_amount"])
		_near_particles.amount = int(config["near_amount"])
		_last_mid_amount_bucket = -1
		_last_near_amount_bucket = -1
	var profile := _profile_with_debug_adjustments(_current_profile)
	_set_surface_rain_parameters(
		float(profile.get("sea_impact_density", 0.0)),
		float(profile.get("sea_impact_strength", 0.0)) * sea_impact_multiplier,
		float(profile.get("micro_impact_density", 0.0)),
		ring_size_multiplier
	)


func _get_daylight_weight() -> float:
	if _weather_controller == null or not _weather_controller.has_method("get_sun_elevation"):
		return 0.65
	var elevation := float(_weather_controller.call("get_sun_elevation"))
	return smoothstep(-6.0, 8.0, elevation)


func _quality_name(level: int) -> String:
	match level:
		Quality.LOW: return "Low"
		Quality.HIGH: return "High"
		_: return "Medium"
