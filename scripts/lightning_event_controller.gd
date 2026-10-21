extends Node
class_name LightningEventController

const BoltGeometryScript := preload("res://scripts/lightning_bolt_geometry.gd")

## Client-side thunderstorm visuals. Forecast ownership stays in
## WeatherStateController; this node only schedules and renders local effects.

enum Quality { LOW, MEDIUM, HIGH }

@export_node_path("Node") var weather_state_controller_path := NodePath("../WeatherStateController")
@export_node_path("Node") var weather_controller_path := NodePath("../WeatherController")
@export_node_path("Node") var day_night_visual_controller_path := NodePath("../DayNightVisualController")
@export_node_path("Node") var sunshine_clouds_driver_path := NodePath("../SunshineCloudsDriverGD")
@export_enum("Low", "Medium", "High") var quality_level: int = Quality.MEDIUM
@export var random_seed := 629104
@export var debug_visual_seed := 629104
@export_range(0.0, 2.0, 0.01) var flash_sensitivity := 1.0
@export_range(0.25, 3.0, 0.05) var frequency_multiplier := 1.0
@export_range(0.0, 1.5, 0.02) var cloud_flash_multiplier := 1.0
@export_range(0.0, 1.5, 0.02) var environment_flash_multiplier := 1.0
@export_range(0.5, 1.5, 0.02) var distance_multiplier := 1.0
@export_range(0.5, 3.0, 0.02) var bolt_width_multiplier := 1.65
@export_range(0.4, 2.5, 0.02) var bolt_curve_multiplier := 1.35
@export_range(0.35, 2.0, 0.02) var primary_branch_density_multiplier := 1.0
@export_range(0.35, 2.0, 0.02) var secondary_branch_density_multiplier := 1.0
@export_range(0.4, 2.0, 0.02) var glow_multiplier := 1.2

signal lightning_event_started(event: Dictionary)

const FORMAL_SYMBOL_INTENSITY := 0.32
const BOLT_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

uniform float flash_level : hint_range(0.0, 1.0) = 0.0;
uniform float emission_gain : hint_range(0.0, 24.0) = 10.0;
uniform float primary_branch_level : hint_range(0.0, 1.0) = 1.0;
uniform float secondary_branch_level : hint_range(0.0, 1.0) = 1.0;

void fragment() {
    // Vertex alpha stores the branch tier relative to the base opacity of each
    // glow layer. This lets fine branches decay ahead of the trunk in a pulse.
    float layer_alpha = COLOR.r < 0.55 ? 0.055 : (COLOR.r < 0.85 ? 0.34 : 0.98);
    float branch_gain = clamp(COLOR.a / layer_alpha, 0.0, 1.0);
    float primary_mask = 1.0 - smoothstep(0.65, 0.88, branch_gain);
    float secondary_mask = 1.0 - smoothstep(0.48, 0.65, branch_gain);
    float branch_factor = mix(1.0, primary_branch_level, primary_mask);
    branch_factor *= mix(1.0, secondary_branch_level, secondary_mask);
    float opacity = clamp(COLOR.a * flash_level * branch_factor, 0.0, 1.0);
	ALBEDO = COLOR.rgb;
	ALPHA = opacity;
    EMISSION = COLOR.rgb * flash_level * emission_gain * branch_factor;
}
"""

var _weather_state_controller: Node
var _weather_controller: Node
var _day_night_visual_controller: Node
var _clouds_driver: Node
var _formal_intensity := 0.0
var _formal_data_quality := "unavailable"
var _formal_symbol := ""
var _debug_override_active := false
var _debug_intensity := 0.55
var _reduce_flashes := false
var _schedule_rng := RandomNumberGenerator.new()
var _debug_rng := RandomNumberGenerator.new()
var _schedule_remaining := -1.0
var _active_event: Dictionary = {}
var _event_sequence := 0
var _active_event_elapsed := 0.0
var _current_flash_level := 0.0
var _preview_frozen := false
var _frozen_flash_level := 0.0
var _last_geometry_stats: Dictionary = {}
var _lightning_mesh: MeshInstance3D
var _lightning_material: ShaderMaterial
var _flash_light: OmniLight3D
var _graphics_available := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	process_priority = 50
	_schedule_rng.seed = random_seed
	_debug_rng.seed = debug_visual_seed
	_weather_state_controller = get_node_or_null(weather_state_controller_path)
	_weather_controller = get_node_or_null(weather_controller_path)
	_day_night_visual_controller = get_node_or_null(day_night_visual_controller_path)
	_clouds_driver = get_node_or_null(sunshine_clouds_driver_path)
	if _weather_state_controller != null:
		if _weather_state_controller.has_signal("thunderstorm_visual_target_changed"):
			_weather_state_controller.thunderstorm_visual_target_changed.connect(_on_formal_thunderstorm_changed)
		if _weather_state_controller.has_method("get_thunderstorm_visual_state"):
			_on_formal_thunderstorm_changed(_weather_state_controller.call("get_thunderstorm_visual_state"))
	_graphics_available = not OS.has_feature("dedicated_server") and DisplayServer.get_name().to_lower() != "headless"
	if _graphics_available:
		set_process(false)
		_create_visual_resources.call_deferred()
	else:
		set_process(false)


func _exit_tree() -> void:
	if _day_night_visual_controller != null and is_instance_valid(_day_night_visual_controller):
		if _day_night_visual_controller.has_method("set_lightning_flash_strength"):
			_day_night_visual_controller.call("set_lightning_flash_strength", 0.0)
	if _weather_controller != null and is_instance_valid(_weather_controller):
		if _weather_controller.has_method("set_thunderstorm_atmosphere_intensity"):
			_weather_controller.call("set_thunderstorm_atmosphere_intensity", 0.0)
	_unregister_cloud_light()


func set_random_seed(value: int) -> void:
	random_seed = value
	_schedule_rng.seed = random_seed
	_schedule_remaining = -1.0


func set_debug_visual_seed(value: int) -> void:
	debug_visual_seed = value
	_debug_rng.seed = debug_visual_seed
	if _preview_frozen:
		trigger_debug_event("near_cg")


func set_quality_level(value: int) -> void:
	quality_level = clampi(value, Quality.LOW, Quality.HIGH)
	if quality_level == Quality.LOW and _flash_light != null:
		_flash_light.visible = false
		_flash_light.light_energy = 0.0
	if _active_event.size() > 0 and str(_active_event.get("type", "")) in ["near_cg", "medium_cg", "distant_cg", "cloud_to_cloud"]:
		_configure_event_geometry(_active_event)


func set_flash_sensitivity(value: float) -> void:
	flash_sensitivity = clampf(value, 0.0, 2.0) if is_finite(value) else 1.0
	_refresh_frozen_preview()


func set_frequency_multiplier(value: float) -> void:
	frequency_multiplier = clampf(value, 0.25, 3.0) if is_finite(value) else 1.0


func set_cloud_flash_multiplier(value: float) -> void:
	cloud_flash_multiplier = clampf(value, 0.0, 1.5) if is_finite(value) else 1.0
	_refresh_frozen_preview()


func set_environment_flash_multiplier(value: float) -> void:
	environment_flash_multiplier = clampf(value, 0.0, 1.5) if is_finite(value) else 1.0
	_refresh_frozen_preview()


func set_distance_multiplier(value: float) -> void:
	distance_multiplier = clampf(value, 0.5, 1.5) if is_finite(value) else 1.0
	if not _active_event.is_empty():
		_configure_event_geometry(_active_event)


func set_bolt_width_multiplier(value: float) -> void:
	bolt_width_multiplier = clampf(value, 0.5, 3.0) if is_finite(value) else 1.65
	if not _active_event.is_empty():
		_configure_event_geometry(_active_event)


func set_bolt_curve_multiplier(value: float) -> void:
	bolt_curve_multiplier = clampf(value, 0.4, 2.5) if is_finite(value) else 1.35
	if not _active_event.is_empty():
		_configure_event_geometry(_active_event)


func set_primary_branch_density_multiplier(value: float) -> void:
	primary_branch_density_multiplier = clampf(value, 0.35, 2.0) if is_finite(value) else 1.0
	if not _active_event.is_empty():
		_configure_event_geometry(_active_event)


func set_secondary_branch_density_multiplier(value: float) -> void:
	secondary_branch_density_multiplier = clampf(value, 0.35, 2.0) if is_finite(value) else 1.0
	if not _active_event.is_empty():
		_configure_event_geometry(_active_event)


func set_glow_multiplier(value: float) -> void:
	glow_multiplier = clampf(value, 0.4, 2.0) if is_finite(value) else 1.2
	if not _active_event.is_empty():
		_configure_event_geometry(_active_event)
	elif _lightning_material != null:
		_lightning_material.set_shader_parameter("emission_gain", 10.0 * glow_multiplier)


func set_preview_frozen(enabled: bool) -> void:
	if enabled == _preview_frozen:
		return
	if enabled:
		if str(_active_event.get("type", "")) != "near_cg":
			trigger_debug_event("near_cg")
		_preview_frozen = true
		_active_event_elapsed = 0.04
		_frozen_flash_level = clampf(0.86 * flash_sensitivity * (0.48 if _reduce_flashes else 1.0), 0.0, 1.0)
		_current_flash_level = _frozen_flash_level
		_apply_flash_contributions()
		_update_visual_material_and_light()
	else:
		_preview_frozen = false
		_frozen_flash_level = 0.0
		_active_event_elapsed = maxf(_active_event_elapsed, 0.04)


func set_reduce_flashes(enabled: bool) -> void:
	_reduce_flashes = enabled
	_refresh_frozen_preview()


func _refresh_frozen_preview() -> void:
	if not _preview_frozen:
		return
	_frozen_flash_level = clampf(0.86 * flash_sensitivity * (0.48 if _reduce_flashes else 1.0), 0.0, 1.0)
	_current_flash_level = _frozen_flash_level
	_apply_flash_contributions()
	_update_visual_material_and_light()


func set_debug_override(enabled: bool, intensity: float = 0.55) -> void:
	var was_enabled := _debug_override_active
	_debug_override_active = enabled
	_debug_intensity = clampf(intensity, 0.0, 1.0) if is_finite(intensity) else 0.0
	if not enabled and was_enabled and str(_active_event.get("source", "")) == "debug":
		_preview_frozen = false
		_cancel_active_event()
	if _effective_intensity() <= 0.001:
		_schedule_remaining = -1.0
	elif not was_enabled:
		_schedule_remaining = -1.0
	_apply_storm_atmosphere()


func clear_debug_override() -> void:
	set_debug_override(false, _debug_intensity)


func trigger_debug_event(event_type: String) -> bool:
	if not event_type in ["in_cloud", "cloud_to_cloud", "distant_cg", "medium_cg", "near_cg"]:
		return false
	if not _debug_override_active:
		set_debug_override(true, maxf(_debug_intensity, 0.55))
	_debug_rng.seed = debug_visual_seed
	var event := _make_event(event_type, _effective_intensity(), "debug", _debug_rng)
	event["seed"] = debug_visual_seed
	_start_visual_event(event)
	if _preview_frozen:
		_active_event_elapsed = 0.04
		_current_flash_level = _frozen_flash_level
		_apply_flash_contributions()
		_update_visual_material_and_light()
	return true


func advance_schedule(delta: float) -> Array[Dictionary]:
	## Deterministic event-clock entry point, also used by offline tests.
	var started: Array[Dictionary] = []
	var intensity := _effective_intensity()
	if intensity < 0.05 or delta <= 0.0:
		if intensity < 0.05:
			_schedule_remaining = -1.0
		return started
	if _schedule_remaining < 0.0:
		_schedule_remaining = _sample_event_interval(intensity)
	_schedule_remaining -= delta
	if _schedule_remaining <= 0.0:
		var event := _make_scheduled_event(intensity)
		started.append(event)
		_schedule_remaining = _sample_event_interval(intensity)
	return started


func get_diagnostic_state() -> Dictionary:
	return {
		"formal_signal": _formal_intensity > 0.0,
		"formal_intensity": _formal_intensity,
		"formal_data_quality": _formal_data_quality,
		"formal_weather_symbol": _formal_symbol,
		"debug_override_active": _debug_override_active,
		"debug_intensity": _debug_intensity,
		"debug_visual_seed": debug_visual_seed,
		"effective_intensity": _effective_intensity(),
		"quality": ["Low", "Medium", "High"][quality_level],
		"next_event_in_seconds": maxf(_schedule_remaining, 0.0),
		"cloud_flash_multiplier": cloud_flash_multiplier,
		"environment_flash_multiplier": environment_flash_multiplier,
		"distance_multiplier": distance_multiplier,
		"active_event_type": str(_active_event.get("type", "none")),
		"preview_frozen": _preview_frozen,
		"flash_level": _current_flash_level,
		"reduce_flashes": _reduce_flashes,
		"temporary_light_count": 1 if _flash_light != null and _flash_light.visible else 0,
		"graphics_available": _graphics_available,
		"geometry": _last_geometry_stats.duplicate(true),
		"bolt_width_multiplier": bolt_width_multiplier,
		"bolt_curve_multiplier": bolt_curve_multiplier,
		"primary_branch_density_multiplier": primary_branch_density_multiplier,
		"secondary_branch_density_multiplier": secondary_branch_density_multiplier,
		"glow_multiplier": glow_multiplier,
	}


func _process(delta: float) -> void:
	if _preview_frozen:
		return
	for event in advance_schedule(delta):
		_start_visual_event(event)
	_update_active_event(delta)


func _on_formal_thunderstorm_changed(state: Dictionary) -> void:
	var active := bool(state.get("available", false))
	var next_intensity := clampf(float(state.get("intensity", FORMAL_SYMBOL_INTENSITY)), 0.0, 1.0) if active else 0.0
	var was_active := _formal_intensity > 0.0
	_formal_intensity = next_intensity
	_formal_data_quality = str(state.get("data_quality", "unavailable"))
	_formal_symbol = str(state.get("weather_symbol", ""))
	if was_active != (_formal_intensity > 0.0):
		_schedule_remaining = -1.0
	_apply_storm_atmosphere()


func _effective_intensity() -> float:
	return _debug_intensity if _debug_override_active else _formal_intensity


func _apply_storm_atmosphere() -> void:
	var intensity := _effective_intensity()
	if _weather_controller != null and _weather_controller.has_method("set_thunderstorm_atmosphere_intensity"):
		_weather_controller.call("set_thunderstorm_atmosphere_intensity", intensity)


func _sample_event_interval(intensity: float) -> float:
	var mean_seconds := lerpf(82.0, 13.0, pow(clampf(intensity, 0.0, 1.0), 1.15))
	var spread := _schedule_rng.randf_range(0.62, 1.72)
	return clampf(mean_seconds * spread / maxf(frequency_multiplier, 0.01), 8.0, 145.0)


func _make_scheduled_event(intensity: float) -> Dictionary:
	var roll := _schedule_rng.randf()
	var near_probability := 0.0 if quality_level == Quality.LOW else lerpf(0.012, 0.065, intensity)
	var distant_probability := lerpf(0.06, 0.30, intensity)
	var kind := "in_cloud"
	if roll < near_probability:
		kind = "near_cg"
	elif roll < near_probability + distant_probability:
		kind = "distant_cg"
	elif roll < near_probability + distant_probability + 0.36:
		kind = "cloud_to_cloud"
	return _make_event(kind, intensity, "formal" if not _debug_override_active else "debug")


func _make_event(event_type: String, intensity: float, source: String, event_rng: RandomNumberGenerator = null) -> Dictionary:
	var rng: RandomNumberGenerator = event_rng if event_rng != null else _schedule_rng
	var pulse_count := rng.randi_range(2, 4)
	var pulses: Array[Dictionary] = []
	var elapsed := 0.0
	for index in range(pulse_count):
		if index > 0:
			elapsed += rng.randf_range(0.075, 0.14)
		var amplitude := 1.0 if index == 0 else rng.randf_range(0.32, 0.76)
		var duration := rng.randf_range(0.055, 0.11)
		pulses.append({"start": elapsed, "duration": duration, "amplitude": amplitude})
	var total_duration := float(pulses.back()["start"]) + float(pulses.back()["duration"]) + 0.04
	return {
		"type": event_type,
		"source": source,
		"intensity": clampf(intensity, 0.0, 1.0),
		"pulses": pulses,
		"duration": total_duration,
		"seed": int(rng.randi()),
	}


func _start_visual_event(event: Dictionary) -> void:
	if event.is_empty():
		return
	_active_event = event.duplicate(true)
	_event_sequence += 1
	_active_event["event_id"] = _event_sequence
	_active_event_elapsed = 0.0
	_current_flash_level = 0.0
	if _graphics_available:
		_configure_event_geometry(_active_event)
	lightning_event_started.emit(_active_event.duplicate(true))


func _update_active_event(delta: float) -> void:
	if _active_event.is_empty():
		return
	if _preview_frozen:
		_current_flash_level = _frozen_flash_level
		_apply_flash_contributions()
		_update_visual_material_and_light()
		return
	_active_event_elapsed += delta
	var pulse_level := 0.0
	for pulse_value in _active_event.get("pulses", []):
		var pulse: Dictionary = pulse_value
		var local_time := _active_event_elapsed - float(pulse.get("start", 0.0))
		var duration := float(pulse.get("duration", 0.08))
		if local_time < 0.0 or local_time > duration:
			continue
		var attack := smoothstep(0.0, 0.012, local_time)
		var decay := exp(-local_time * 18.0)
		var value := float(pulse.get("amplitude", 1.0)) * attack * decay
		pulse_level = maxf(pulse_level, value)
	var intensity := float(_active_event.get("intensity", 0.0))
	var visual_scale := lerpf(0.44, 0.88, intensity)
	if _reduce_flashes:
		visual_scale *= 0.48
	_current_flash_level = clampf(pulse_level * visual_scale * flash_sensitivity, 0.0, 1.0)
	_apply_flash_contributions()
	_update_visual_material_and_light()
	if _active_event_elapsed >= float(_active_event.get("duration", 0.0)):
		_cancel_active_event()


func _apply_flash_contributions() -> void:
	if _day_night_visual_controller == null:
		return
	if _day_night_visual_controller.has_method("set_lightning_flash_contributions"):
		_day_night_visual_controller.call(
			"set_lightning_flash_contributions",
			_current_flash_level * cloud_flash_multiplier,
			_current_flash_level * environment_flash_multiplier
		)
	elif _day_night_visual_controller.has_method("set_lightning_flash_strength"):
		_day_night_visual_controller.call("set_lightning_flash_strength", _current_flash_level)


func _cancel_active_event() -> void:
	_active_event.clear()
	_active_event_elapsed = 0.0
	_current_flash_level = 0.0
	_preview_frozen = false
	_frozen_flash_level = 0.0
	if _lightning_mesh != null:
		_lightning_mesh.visible = false
		_lightning_mesh.mesh = null
	if _flash_light != null:
		_flash_light.visible = false
		_flash_light.light_energy = 0.0
	if _day_night_visual_controller != null and _day_night_visual_controller.has_method("set_lightning_flash_strength"):
		_day_night_visual_controller.call("set_lightning_flash_strength", 0.0)


func _create_visual_resources() -> void:
	if not _graphics_available or not is_inside_tree():
		return
	if _lightning_mesh != null or _flash_light != null:
		return
	_lightning_material = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = BOLT_SHADER_CODE
	_lightning_material.shader = shader
	_lightning_material.set_shader_parameter("emission_gain", 8.0 * glow_multiplier)
	_lightning_mesh = MeshInstance3D.new()
	_lightning_mesh.name = "LightningBoltVisual"
	_lightning_mesh.material_override = _lightning_material
	_lightning_mesh.visible = false
	add_child(_lightning_mesh)
	_flash_light = OmniLight3D.new()
	_flash_light.name = "LightningFlashLight"
	_flash_light.light_color = Color(0.70, 0.82, 1.0)
	_flash_light.light_energy = 0.0
	_flash_light.omni_range = 1800.0
	_flash_light.shadow_enabled = false
	_flash_light.visible = false
	add_child(_flash_light)
	_register_cloud_light()
	set_process(true)


func _register_cloud_light() -> void:
	if _clouds_driver == null or _flash_light == null:
		return
	var lights: Array[OmniLight3D] = _clouds_driver.get("tracked_point_lights")
	if not lights.has(_flash_light):
		lights.append(_flash_light)
		_clouds_driver.set("tracked_point_lights", lights)


func _unregister_cloud_light() -> void:
	if _clouds_driver != null and is_instance_valid(_clouds_driver) and _flash_light != null:
		var lights: Array[OmniLight3D] = _clouds_driver.get("tracked_point_lights")
		lights.erase(_flash_light)
		_clouds_driver.set("tracked_point_lights", lights)


func _configure_event_geometry(event: Dictionary) -> void:
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = int(event.get("seed", random_seed))
	var camera_position := camera.global_position
	var forward := -camera.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	if forward.length_squared() < 0.5:
		forward = Vector3.FORWARD
	var event_type := str(event.get("type", "in_cloud"))
	var angle_range := 112.0
	var distance := 2200.0
	var cloud_height := rng.randf_range(1850.0, 2350.0)
	match event_type:
		"near_cg":
			distance = rng.randf_range(620.0, 1050.0)
			angle_range = 78.0
		"medium_cg":
			distance = rng.randf_range(1350.0, 2450.0)
			angle_range = 96.0
		"distant_cg":
			distance = rng.randf_range(3600.0, 7600.0)
			angle_range = 132.0
		"cloud_to_cloud":
			distance = rng.randf_range(1500.0, 3600.0)
			cloud_height = rng.randf_range(1750.0, 2550.0)
		"in_cloud":
			distance = rng.randf_range(1650.0, 4200.0)
			cloud_height = rng.randf_range(1750.0, 2750.0)
	var angle := deg_to_rad(rng.randf_range(-angle_range, angle_range))
	distance *= distance_multiplier
	var direction := forward.rotated(Vector3.UP, angle).normalized()
	var origin := camera_position + direction * distance
	origin.y = cloud_height
	event["world_position"] = origin
	event["distance_m"] = camera_position.distance_to(origin)
	var sound_source_position := origin
	if event_type in ["near_cg", "medium_cg", "distant_cg"]:
		sound_source_position.y = 0.0
	event["sound_source_position"] = sound_source_position
	if _lightning_mesh == null or _flash_light == null:
		return
	var event_intensity := float(event.get("intensity", 0.0))
	var geometry := BoltGeometryScript.build(
		event_type,
		int(event.get("seed", random_seed)),
		quality_level,
		event_intensity,
		bolt_width_multiplier,
		bolt_curve_multiplier,
		primary_branch_density_multiplier,
		secondary_branch_density_multiplier,
		maxf(cloud_height - 20.0, 100.0)
	)
	_last_geometry_stats = {
		"path_count": int(geometry.get("path_count", 0)),
		"primary_branch_count": int(geometry.get("primary_branch_count", 0)),
		"secondary_branch_count": int(geometry.get("secondary_branch_count", 0)),
		"vertex_count": int(geometry.get("vertex_count", 0)),
		"triangle_count": int(geometry.get("triangle_count", 0)),
		"max_segment_length": float(geometry.get("max_segment_length", 0.0)),
		"core_radius_m": float(geometry.get("main_core_radius", 0.0)),
		"aura_radius_m": float(geometry.get("main_aura_radius", 0.0)),
		"halo_radius_m": float(geometry.get("main_halo_radius", 0.0)),
		"distance_m": distance,
		"cloud_height_m": cloud_height,
	}
	var vertices: PackedVector3Array = geometry.get("vertices", PackedVector3Array())
	var colors: PackedColorArray = geometry.get("colors", PackedColorArray())
	var indices: PackedInt32Array = geometry.get("indices", PackedInt32Array())
	if not vertices.is_empty() and not indices.is_empty():
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = indices
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		_lightning_mesh.mesh = mesh
		_lightning_mesh.global_position = origin
		_lightning_mesh.visible = event_type != "in_cloud"
	else:
		_lightning_mesh.visible = false
		_lightning_mesh.mesh = null
	_flash_light.global_position = origin
	var light_height := cloud_height * 0.58
	if event_type in ["near_cg", "medium_cg"]:
		light_height = 160.0
	elif event_type == "distant_cg":
		light_height = cloud_height * 0.82
	_flash_light.global_position = origin + Vector3(0.0, -cloud_height + light_height, 0.0)
	var distance_class := 0.15
	var range_value := 1750.0
	var energy_value := 4.0
	match event_type:
		"near_cg":
			distance_class = 1.0
			range_value = 3000.0
			energy_value = 30.0 + event_intensity * 48.0
		"medium_cg":
			distance_class = 0.62
			range_value = 2500.0
			energy_value = 17.0 + event_intensity * 28.0
		"distant_cg":
			distance_class = 0.2
			range_value = 1900.0
			energy_value = 5.0 + event_intensity * 9.0
		"cloud_to_cloud":
			distance_class = 0.46
			range_value = 1900.0
			energy_value = 5.0 + event_intensity * 8.0
		"in_cloud":
			range_value = 1200.0
			energy_value = 3.0 + event_intensity * 5.0
	_flash_light.omni_range = range_value
	_flash_light.light_color = Color(0.72, 0.84, 1.0)
	var use_scene_light := quality_level != Quality.LOW
	_flash_light.set_meta("enabled_for_event", use_scene_light)
	_flash_light.visible = use_scene_light
	_flash_light.light_energy = 0.0
	var quality_energy_scale := 0.78 if quality_level == Quality.LOW else (1.12 if quality_level == Quality.HIGH else 1.0)
	_flash_light.set_meta("max_light_energy", energy_value * quality_energy_scale)
	if _lightning_material != null:
		var core_gain := lerpf(5.5, 11.0, distance_class) * glow_multiplier
		_lightning_material.set_shader_parameter("emission_gain", core_gain)
	if _preview_frozen:
		_update_visual_material_and_light()


func _update_visual_material_and_light() -> void:
	if _lightning_material != null:
		_lightning_material.set_shader_parameter("flash_level", _current_flash_level)
		var branch_levels := get_branch_pulse_levels(_active_event_elapsed, _active_event.get("pulses", []))
		_lightning_material.set_shader_parameter("primary_branch_level", lerpf(0.55, 1.0, float(branch_levels["primary"])))
		_lightning_material.set_shader_parameter("secondary_branch_level", lerpf(0.18, 1.0, float(branch_levels["secondary"])))
	if _flash_light != null:
		if quality_level == Quality.LOW or not bool(_flash_light.get_meta("enabled_for_event", false)):
			_flash_light.visible = false
			_flash_light.light_energy = 0.0
		else:
			_flash_light.visible = _current_flash_level > 0.005
			_flash_light.light_energy = float(_flash_light.get_meta("max_light_energy", 0.0)) * _current_flash_level * environment_flash_multiplier


func get_branch_pulse_levels(elapsed: float, pulses: Array) -> Dictionary:
	var primary_level := 0.0
	var secondary_level := 0.0
	for pulse_value in pulses:
		var pulse: Dictionary = pulse_value
		var local_time := elapsed - float(pulse.get("start", 0.0))
		var duration := float(pulse.get("duration", 0.08))
		if local_time < 0.0 or local_time > duration:
			continue
		var attack := smoothstep(0.0, 0.008, local_time)
		var amplitude := float(pulse.get("amplitude", 1.0))
		primary_level = maxf(primary_level, amplitude * attack * exp(-25.0 * local_time))
		secondary_level = maxf(secondary_level, amplitude * attack * exp(-48.0 * local_time))
	return {"primary": primary_level, "secondary": secondary_level}

