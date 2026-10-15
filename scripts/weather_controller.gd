extends Node
class_name WeatherController

## Applies the prototype's weather to the native sky, sunlight, volumetric
## clouds, sea material, fog, and shared Gerstner sampler.
## Sun azimuth is degrees clockwise from the camera's forward (-Z) direction.

enum Preset { CLEAR, PARTLY_CLOUDY, OVERCAST }

@export_node_path("WorldEnvironment") var world_environment_path := NodePath("../WorldEnvironment")
@export_node_path("DirectionalLight3D") var sunlight_path := NodePath("../Sunlight")
@export_node_path("Node") var wave_sampler_path := NodePath("../WaveSampler")
@export_node_path("Node") var sunshine_clouds_driver_path := NodePath("../SunshineCloudsDriverGD")
@export var water_material: ShaderMaterial
@export var cloud_profiles: CloudWeatherProfiles
@export_range(0.5, 20.0, 0.5) var transition_seconds := 5.0
@export_enum("Clear", "PartlyCloudy", "Overcast") var initial_weather: int = Preset.CLEAR

const WEATHER_PRESETS := [
	{
		"name": "Clear",
		"sky_top": Color(0.055, 0.245, 0.56),
		"sky_horizon": Color(0.40, 0.64, 0.82),
		"haze": Color(0.62, 0.75, 0.83),
		"sun_elevation": 10.0,
		"sun_azimuth": 28.0,
		"sun_color": Color(1.0, 0.91, 0.77),
		"sun_disk_color": Color(1.0, 0.98, 0.92),
		"sun_disk_radius": 0.42,
		"sun_disk_edge": 0.07,
		"sun_core_radiance": 3.4,
		"sun_halo_strength": 0.22,
		"sun_halo_radius": 5.5,
		"sun_energy": 1.18,
		"ambient_color": Color(0.64, 0.77, 0.87),
		"ambient_energy": 0.84,
		"fog_color": Color(0.40, 0.58, 0.72),
		"fog_density": 0.0007,
		"water_color": Color(0.14, 0.43, 0.58),
		"water_fresnel": Color(0.20, 0.50, 0.61),
		"shallow_water_color": Color(0.33, 0.57, 0.57),
		"mid_water_color": Color(0.19, 0.46, 0.55),
		"blue_water_color": Color(0.14, 0.38, 0.54),
		"water_specular": 0.08,
		"water_roughness": 0.075,
		"wave_strength": 1.05,
	},
	{
		"name": "PartlyCloudy",
		"sky_top": Color(0.075, 0.23, 0.44),
		"sky_horizon": Color(0.39, 0.56, 0.68),
		"haze": Color(0.71, 0.77, 0.80),
		"sun_elevation": 20.0,
		"sun_azimuth": 28.0,
		"sun_color": Color(0.96, 0.93, 0.86),
		"sun_disk_color": Color(0.98, 0.97, 0.92),
		"sun_disk_radius": 0.40,
		"sun_disk_edge": 0.08,
		"sun_core_radiance": 3.0,
		"sun_halo_strength": 0.10,
		"sun_halo_radius": 5.0,
		"sun_energy": 0.85,
		"ambient_color": Color(0.54, 0.63, 0.70),
		"ambient_energy": 0.83,
		"fog_color": Color(0.63, 0.73, 0.78),
		"fog_density": 0.00165,
		"water_color": Color(0.044, 0.36, 0.35),
		"water_fresnel": Color(0.15, 0.39, 0.40),
		"shallow_water_color": Color(0.22, 0.62, 0.48),
		"mid_water_color": Color(0.06, 0.42, 0.46),
		"blue_water_color": Color(0.04, 0.30, 0.44),
		"water_specular": 0.16,
		"water_roughness": 0.12,
		"wave_strength": 1.25,
	},
	{
		"name": "Overcast",
		"sky_top": Color(0.18, 0.27, 0.37),
		"sky_horizon": Color(0.54, 0.63, 0.67),
		"haze": Color(0.68, 0.73, 0.75),
		"sun_elevation": 16.0,
		"sun_azimuth": 28.0,
		"sun_color": Color(0.82, 0.87, 0.92),
		"sun_disk_color": Color(0.82, 0.87, 0.92),
		"sun_disk_radius": 0.32,
		"sun_disk_edge": 0.10,
		"sun_core_radiance": 2.2,
		"sun_halo_strength": 0.025,
		"sun_halo_radius": 4.0,
		"sun_energy": 0.42,
		"ambient_color": Color(0.56, 0.64, 0.69),
		"ambient_energy": 1.08,
		"fog_color": Color(0.54, 0.63, 0.68),
		"fog_density": 0.0022,
		"water_color": Color(0.07, 0.30, 0.36),
		"water_fresnel": Color(0.14, 0.34, 0.39),
		"shallow_water_color": Color(0.22, 0.62, 0.48),
		"mid_water_color": Color(0.06, 0.42, 0.46),
		"blue_water_color": Color(0.04, 0.30, 0.44),
		"water_specular": 0.10,
		"water_roughness": 0.22,
		"wave_strength": 1.5,
	},
]

const COLOR_KEYS := [
	"sky_top", "sky_horizon", "haze", "sun_color", "sun_disk_color", "ambient_color", "fog_color",
	"water_color", "water_fresnel", "shallow_water_color", "mid_water_color", "blue_water_color",
	"cloud_ambient_color", "cloud_ambient_tint",
]

var current_weather_name := "Clear"
var _world_environment: WorldEnvironment
var _environment: Environment
var _sunlight: DirectionalLight3D
var _wave_sampler: Node
var _sunshine_clouds_driver: SunshineCloudsDriverGD
var _sunshine_clouds: SunshineCloudsGD
var _sky_material: ShaderMaterial
var _current: Dictionary = {}
var _from: Dictionary = {}
var _target: Dictionary = {}
var _transition_elapsed := 0.0
var _transition_active := false
var _last_applied_wave_strength := -1.0


func _ready() -> void:
	_world_environment = get_node_or_null(world_environment_path) as WorldEnvironment
	_sunlight = get_node_or_null(sunlight_path) as DirectionalLight3D
	_wave_sampler = get_node_or_null(wave_sampler_path)
	_sunshine_clouds_driver = get_node_or_null(sunshine_clouds_driver_path) as SunshineCloudsDriverGD
	if _sunshine_clouds_driver != null:
		_sunshine_clouds = _sunshine_clouds_driver.clouds_resource
	if _world_environment == null or _sunlight == null or water_material == null or cloud_profiles == null or _sunshine_clouds == null:
		push_error("WeatherController needs WorldEnvironment, Sunlight, sea material, cloud profiles, and Sunshine Clouds 2.")
		set_process(false)
		return

	_environment = _world_environment.environment
	if _environment == null or _environment.sky == null:
		push_error("WeatherController needs a WorldEnvironment with a Sky resource.")
		set_process(false)
		return
	_sky_material = _environment.sky.sky_material as ShaderMaterial
	if _sky_material == null:
		push_error("WeatherController needs the project's sky ShaderMaterial.")
		set_process(false)
		return

	var preset: Dictionary = WEATHER_PRESETS[initial_weather]
	current_weather_name = str(preset["name"])
	_current = _copy_state(preset, initial_weather)
	_from = _current.duplicate(true)
	_target = _current.duplicate(true)
	_apply_current_state()


func _process(delta: float) -> void:
	if not _transition_active:
		return

	_transition_elapsed += delta
	var duration := maxf(transition_seconds, 0.05)
	var linear_weight := clampf(_transition_elapsed / duration, 0.0, 1.0)
	var weight := linear_weight * linear_weight * (3.0 - 2.0 * linear_weight)
	for key in _current.keys():
		if key == "sun_azimuth":
			var from_angle := deg_to_rad(float(_from[key]))
			var to_angle := deg_to_rad(float(_target[key]))
			_current[key] = rad_to_deg(lerp_angle(from_angle, to_angle, weight))
		elif COLOR_KEYS.has(key):
			_current[key] = (_from[key] as Color).lerp(_target[key] as Color, weight)
		elif _from[key] is Vector2:
			_current[key] = Vector2(_from[key]).lerp(Vector2(_target[key]), weight)
		else:
			_current[key] = lerpf(float(_from[key]), float(_target[key]), weight)

	_apply_current_state()
	if linear_weight >= 1.0:
		_transition_active = false


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_1:
			set_weather_by_index(Preset.CLEAR)
		KEY_2:
			set_weather_by_index(Preset.PARTLY_CLOUDY)
		KEY_3:
			set_weather_by_index(Preset.OVERCAST)
		_:
			return
	get_viewport().set_input_as_handled()


func set_weather_by_index(index: int) -> void:
	if index < 0 or index >= WEATHER_PRESETS.size():
		return
	var preset: Dictionary = WEATHER_PRESETS[index]
	current_weather_name = str(preset["name"])
	_from = _current.duplicate(true)
	_target = _copy_state(preset, index)
	_transition_elapsed = 0.0
	_transition_active = true


func set_weather_by_name(preset_name: String) -> void:
	for index in range(WEATHER_PRESETS.size()):
		if WEATHER_PRESETS[index]["name"] == preset_name:
			set_weather_by_index(index)
			return


func set_sun_elevation(degrees: float) -> void:
	_set_live_value("sun_elevation", clampf(degrees, 3.0, 75.0))


func set_sun_azimuth(degrees: float) -> void:
	_set_live_value("sun_azimuth", fposmod(degrees, 360.0))


func set_cloud_coverage(value: float) -> void:
	var coverage := clampf(value, 0.0, 1.0)
	for state in [_current, _from, _target]:
		if state.is_empty():
			continue
		state["clouds_coverage"] = coverage
		state["cloud_coverage"] = coverage
	_apply_current_state()


func set_wave_strength(value: float) -> void:
	_set_live_value("wave_strength", clampf(value, 0.0, 2.0))


func get_sun_elevation() -> float:
	return float(_current.get("sun_elevation", 10.0))


func get_sun_azimuth() -> float:
	return float(_current.get("sun_azimuth", 28.0))


func get_cloud_coverage() -> float:
	return float(_current.get("cloud_coverage", 0.57))


func _set_live_value(key: String, value: float) -> void:
	if _current.is_empty():
		return
	_current[key] = value
	_from[key] = value
	_target[key] = value
	_apply_current_state()


func _copy_state(preset: Dictionary, weather_index: int) -> Dictionary:
	var state := preset.duplicate(true)
	state.merge(cloud_profiles.state_for_weather(weather_index), true)
	return state


func _apply_current_state() -> void:
	_sky_material.set_shader_parameter("sky_top_color", _color_to_vector3(_current["sky_top"]))
	_sky_material.set_shader_parameter("sky_horizon_color", _color_to_vector3(_current["sky_horizon"]))
	_sky_material.set_shader_parameter("ground_horizon_color", _color_to_vector3(_current["haze"]))
	_sky_material.set_shader_parameter("sun_disk_color", _color_to_vector3(_current["sun_disk_color"]))
	_sky_material.set_shader_parameter("sun_disk_radius_degrees", float(_current["sun_disk_radius"]))
	_sky_material.set_shader_parameter("sun_edge_softness_degrees", float(_current["sun_disk_edge"]))
	_sky_material.set_shader_parameter("sun_core_radiance", float(_current["sun_core_radiance"]))
	_sky_material.set_shader_parameter("sun_halo_strength", float(_current["sun_halo_strength"]))
	_sky_material.set_shader_parameter("sun_halo_radius_degrees", float(_current["sun_halo_radius"]))

	_sunshine_clouds.enabled = true
	_sunshine_clouds.clouds_coverage = float(_current["clouds_coverage"])
	_sunshine_clouds.clouds_density = float(_current["clouds_density"])
	_sunshine_clouds.lighting_density = float(_current["lighting_density"])
	_sunshine_clouds.atmospheric_density = float(_current["atmospheric_density"])
	_sunshine_clouds.cloud_ambient_color = _current["cloud_ambient_color"]
	_sunshine_clouds.cloud_ambient_tint = _current["cloud_ambient_tint"]

	_sunlight.light_color = _current["sun_color"]
	_sunlight.light_energy = float(_current["sun_energy"])
	var elevation := deg_to_rad(float(_current["sun_elevation"]))
	var azimuth := deg_to_rad(float(_current["sun_azimuth"]))
	var sun_direction := Vector3(
		sin(azimuth) * cos(elevation),
		sin(elevation),
		-cos(azimuth) * cos(elevation)
	).normalized()
	_sky_material.set_shader_parameter("sun_direction", sun_direction)
	_sky_material.set_shader_parameter("sun_energy", float(_current["sun_energy"]))
	_sunlight.global_basis = Basis.looking_at(-sun_direction, Vector3.UP)

	_environment.ambient_light_color = _current["ambient_color"]
	_environment.ambient_light_energy = float(_current["ambient_energy"])
	_environment.fog_light_color = _current["fog_color"]
	_environment.fog_density = float(_current["fog_density"])

	water_material.set_shader_parameter("albedo", _current["water_color"])
	water_material.set_shader_parameter("albedo_fresnel", _current["water_fresnel"])
	water_material.set_shader_parameter("shallow_water_color", _current["shallow_water_color"])
	water_material.set_shader_parameter("mid_water_color", _current["mid_water_color"])
	water_material.set_shader_parameter("blue_water_color", _current["blue_water_color"])
	water_material.set_shader_parameter("specular", _current["water_specular"])
	water_material.set_shader_parameter("water_roughness_near", _current["water_roughness"])

	var wave_strength := float(_current["wave_strength"])
	if _wave_sampler != null and absf(wave_strength - _last_applied_wave_strength) > 0.001:
		_wave_sampler.set("wave_strength", wave_strength)
		_last_applied_wave_strength = wave_strength


func _color_to_vector3(color: Color) -> Vector3:
	return Vector3(color.r, color.g, color.b)
