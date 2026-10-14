extends Node
class_name QualityManager

## Applies lightweight runtime quality profiles to the existing sea scene.
## High keeps the scene's authored values as its visual baseline.

signal settings_changed

enum Quality { HIGH, MEDIUM, LOW }
enum FrameLimit { FPS_30, FPS_60, UNLIMITED }

const SETTINGS_PATH := "user://quality_settings.cfg"
const SHADOW_SIZE_SETTING := "rendering/lights_and_shadows/directional_shadow/size"

const QUALITY_NAMES := ["High", "Medium", "Low"]
const FRAME_LIMIT_NAMES := ["30 FPS", "60 FPS", "Unlimited"]

const QUALITY_PROFILES := [
	{
		"shadow_size": 4096,
		"shadow_distance": 260.0,
		"shadow_blur": 1.6,
		"ssr_enabled": true,
		"ssr_max_steps": 48,
		"ssao_enabled": true,
		"ssao_radius": 0.65,
		"ssao_intensity": 1.1,
		"cloud_resolution": 2,
		"cloud_steps": 160.0,
		"cloud_lighting_steps": 12.0,
		"ocean_resolution": 12,
		"ocean_lods": 4,
		"detail_normal_strength": 2.5,
		"detail_fade_end": 950.0,
		"albedo_detail_fade_end": 2200.0,
	},
	{
		"shadow_size": 2048,
		"shadow_distance": 200.0,
		"shadow_blur": 1.25,
		"ssr_enabled": true,
		"ssr_max_steps": 32,
		"ssao_enabled": true,
		"ssao_radius": 0.55,
		"ssao_intensity": 0.85,
		"cloud_resolution": 2,
		"cloud_steps": 128.0,
		"cloud_lighting_steps": 10.0,
		"ocean_resolution": 10,
		"ocean_lods": 4,
		"detail_normal_strength": 2.2,
		"detail_fade_end": 780.0,
		"albedo_detail_fade_end": 1800.0,
	},
	{
		"shadow_size": 1024,
		"shadow_distance": 120.0,
		"shadow_blur": 0.8,
		"ssr_enabled": false,
		"ssr_max_steps": 16,
		"ssao_enabled": false,
		"ssao_radius": 0.4,
		"ssao_intensity": 0.6,
		"cloud_resolution": 3,
		"cloud_steps": 96.0,
		"cloud_lighting_steps": 8.0,
		"ocean_resolution": 8,
		"ocean_lods": 3,
		"detail_normal_strength": 1.5,
		"detail_fade_end": 540.0,
		"albedo_detail_fade_end": 1200.0,
	},
]

@export_node_path("Node3D") var ocean_path := NodePath("../Ocean")
@export_node_path("DirectionalLight3D") var sunlight_path := NodePath("../Sunlight")
@export_node_path("WorldEnvironment") var world_environment_path := NodePath("../WorldEnvironment")
@export var water_material: ShaderMaterial
@export var clouds_resource: SunshineCloudsGD

var current_quality_index := Quality.HIGH
var current_frame_limit_index := FrameLimit.FPS_60
var _is_fullscreen := false
var _ocean: Ocean
var _sunlight: DirectionalLight3D
var _world_environment: WorldEnvironment
var _environment: Environment


func _ready() -> void:
	_ocean = get_node_or_null(ocean_path) as Ocean
	_sunlight = get_node_or_null(sunlight_path) as DirectionalLight3D
	_world_environment = get_node_or_null(world_environment_path) as WorldEnvironment
	if _world_environment != null:
		_environment = _world_environment.environment

	if _ocean == null or _sunlight == null or _environment == null or water_material == null or clouds_resource == null:
		push_error("QualityManager needs Ocean, Sunlight, WorldEnvironment, sea material, and Sunshine Clouds 2 resource.")
		return

	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		current_quality_index = clampi(int(config.get_value("graphics", "quality", Quality.HIGH)), Quality.HIGH, Quality.LOW)
		current_frame_limit_index = clampi(int(config.get_value("graphics", "frame_limit", FrameLimit.FPS_60)), FrameLimit.FPS_30, FrameLimit.UNLIMITED)
		_is_fullscreen = bool(config.get_value("display", "fullscreen", false))

	_apply_quality_profile(false)
	_apply_frame_limit()
	_apply_window_mode()
	settings_changed.emit()


func set_quality(index: int) -> void:
	if index < Quality.HIGH or index > Quality.LOW:
		return
	if current_quality_index == index:
		return
	current_quality_index = index
	_apply_quality_profile(true)
	_save_settings()
	settings_changed.emit()


func get_quality_index() -> int:
	return current_quality_index


func get_quality_name() -> String:
	return QUALITY_NAMES[current_quality_index]


func set_frame_limit(index: int) -> void:
	if index < FrameLimit.FPS_30 or index > FrameLimit.UNLIMITED:
		return
	if current_frame_limit_index == index:
		return
	current_frame_limit_index = index
	_apply_frame_limit()
	_save_settings()
	settings_changed.emit()


func get_frame_limit_index() -> int:
	return current_frame_limit_index


func get_frame_limit_name() -> String:
	return FRAME_LIMIT_NAMES[current_frame_limit_index]


func toggle_fullscreen() -> void:
	_is_fullscreen = not _is_fullscreen
	_apply_window_mode()
	_save_settings()
	settings_changed.emit()


func is_fullscreen() -> bool:
	return _is_fullscreen


func _apply_quality_profile(rebuild_ocean: bool) -> void:
	var profile: Dictionary = QUALITY_PROFILES[current_quality_index]
	var old_resolution := _ocean.outermost_resolution
	var old_lods := _ocean.levels_of_detail

	_sunlight.directional_shadow_max_distance = float(profile["shadow_distance"])
	_sunlight.shadow_blur = float(profile["shadow_blur"])
	if DisplayServer.get_name() != "headless":
		RenderingServer.directional_shadow_atlas_set_size(int(profile["shadow_size"]), false)
	ProjectSettings.set_setting(SHADOW_SIZE_SETTING, int(profile["shadow_size"]))

	_environment.ssr_enabled = bool(profile["ssr_enabled"])
	_environment.ssr_max_steps = int(profile["ssr_max_steps"])
	_environment.ssao_enabled = bool(profile["ssao_enabled"])
	_environment.ssao_radius = float(profile["ssao_radius"])
	_environment.ssao_intensity = float(profile["ssao_intensity"])

	clouds_resource.resolution_scale = int(profile["cloud_resolution"])
	clouds_resource.max_step_count = float(profile["cloud_steps"])
	clouds_resource.max_lighting_steps = float(profile["cloud_lighting_steps"])

	_ocean.outermost_resolution = int(profile["ocean_resolution"])
	_ocean.levels_of_detail = int(profile["ocean_lods"])
	if rebuild_ocean and (old_resolution != _ocean.outermost_resolution or old_lods != _ocean.levels_of_detail):
		_ocean.call_deferred("build_meshes")

	water_material.set_shader_parameter("detail_normal_strength_near", float(profile["detail_normal_strength"]))
	water_material.set_shader_parameter("detail_wave_fade_end", float(profile["detail_fade_end"]))
	water_material.set_shader_parameter("albedo_detail_fade_end", float(profile["albedo_detail_fade_end"]))


func _apply_frame_limit() -> void:
	match current_frame_limit_index:
		FrameLimit.FPS_30:
			Engine.max_fps = 30
			# The combined OS VSync wait and 30 FPS limit measured below the target.
			# Keep this cap independent so the engine can hold a steady 30 FPS.
			_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		FrameLimit.FPS_60:
			Engine.max_fps = 60
			_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
		FrameLimit.UNLIMITED:
			Engine.max_fps = 0
			_set_vsync_mode(DisplayServer.VSYNC_DISABLED)


func _set_vsync_mode(mode: DisplayServer.VSyncMode) -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(mode)


func _apply_window_mode() -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(
			DisplayServer.WINDOW_MODE_FULLSCREEN if _is_fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
		)


func _save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("graphics", "quality", current_quality_index)
	config.set_value("graphics", "frame_limit", current_frame_limit_index)
	config.set_value("display", "fullscreen", _is_fullscreen)
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		push_warning("Could not save graphics settings: %s" % error_string(error))
