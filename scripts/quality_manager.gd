extends Node
class_name QualityManager

## Applies lightweight runtime quality profiles to the existing sea scene.
## High keeps the scene's authored values as its visual baseline.

signal settings_changed

enum Quality { HIGH, MEDIUM, LOW }
enum FrameLimit { FPS_30, FPS_60, UNLIMITED }
enum GraphicsPreset { PERFORMANCE, BALANCED, HIGH, ULTRA, CUSTOM }
enum RenderResolution { NATIVE, HIGH, BALANCED, PERFORMANCE, ULTRA_PERFORMANCE }
enum DisplayMode { WINDOWED, BORDERLESS, FULLSCREEN }
enum UpscalerMode { AUTO, FSR2, FSR1, BILINEAR }

const SETTINGS_PATH := "user://quality_settings.cfg"
const SHADOW_SIZE_SETTING := "rendering/lights_and_shadows/directional_shadow/size"

const QUALITY_NAMES := ["画质优先", "平衡", "性能优先"]
const RESOLUTION_SCALES := [1.0, 0.75, 0.67]
const FRAME_LIMIT_NAMES := ["30 FPS", "60 FPS", "Unlimited"]
const GRAPHICS_PRESET_NAMES := ["Performance", "Balanced", "High", "Ultra", "Custom"]
const RENDER_RESOLUTION_NAMES := ["Native — 100%", "High — 85%", "Balanced — 70%", "Performance — 55%", "Ultra Performance — 45%"]
const RENDER_RESOLUTION_SCALES := [1.0, 0.85, 0.70, 0.55, 0.45]
const DISPLAY_MODE_NAMES := ["Windowed", "Borderless Window", "Fullscreen"]
const UPSCALER_NAMES := ["Auto", "FSR2", "FSR1", "Bilinear"]
const EXTRA_3D_SCALE_NAMES := ["100%", "85%", "75%", "67%", "55%", "50%"]
const EXTRA_3D_SCALES := [1.0, 0.85, 0.75, 0.67, 0.55, 0.50]
const UI_SCALE_NAMES := ["小 · 90%", "标准 · 100%", "大 · 125%", "特大 · 150%", "超大 · 175%"]
const UI_SCALE_FACTORS := [0.9, 1.0, 1.25, 1.5, 1.75]
const DISPLAY_CONFIRM_SECONDS := 15.0
const CLOUD_QUALITY_LEVELS := [
	{"cloud_resolution": 3, "cloud_steps": 96.0, "cloud_lighting_steps": 8.0},
	{"cloud_resolution": 2, "cloud_steps": 128.0, "cloud_lighting_steps": 10.0},
	{"cloud_resolution": 2, "cloud_steps": 160.0, "cloud_lighting_steps": 12.0},
]
const OCEAN_QUALITY_LEVELS := [
	{"ocean_resolution": 8, "ocean_lods": 3, "detail_fade_end": 540.0, "albedo_detail_fade_end": 1200.0},
	{"ocean_resolution": 10, "ocean_lods": 4, "detail_fade_end": 780.0, "albedo_detail_fade_end": 1800.0},
	{"ocean_resolution": 12, "ocean_lods": 4, "detail_fade_end": 950.0, "albedo_detail_fade_end": 2200.0},
]

# Keep the approved surface-normal contrast in every profile; increasing this
# scalar had reintroduced broad mottling without a meaningful performance gain.
const QUALITY_PROFILES := [
	{
		"shadow_size": 4096,
		"shadows_enabled": true,
		"shadow_distance": 260.0,
		"shadow_blur": 1.8,
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
		"detail_normal_strength": 0.8,
		"detail_fade_end": 950.0,
		"albedo_detail_fade_end": 2200.0,
		"vegetation_density": 1.0,
	},
	{
		"shadow_size": 2048,
		"shadows_enabled": true,
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
		"detail_normal_strength": 0.8,
		"detail_fade_end": 780.0,
		"albedo_detail_fade_end": 1800.0,
		"vegetation_density": 0.85,
	},
	{
		"shadow_size": 1024,
		"shadows_enabled": true,
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
		"detail_normal_strength": 0.8,
		"detail_fade_end": 540.0,
		"albedo_detail_fade_end": 1200.0,
		"vegetation_density": 0.65,
	},
]

@export_node_path("Node3D") var ocean_path := NodePath("../Ocean")
@export_node_path("DirectionalLight3D") var sunlight_path := NodePath("../Sunlight")
@export_node_path("WorldEnvironment") var world_environment_path := NodePath("../WorldEnvironment")
@export_node_path("Node") var seabed_manager_path := NodePath("../ShallowSeabedManager")
@export var water_material: ShaderMaterial
@export var clouds_resource: SunshineCloudsGD

var current_quality_index := Quality.HIGH
var current_frame_limit_index := FrameLimit.FPS_60
var ui_scale_index := 2
var navigation_detail_enabled := false
var _is_fullscreen := false
var _quality_user_selected := false
var graphics_preset_index := GraphicsPreset.HIGH
var render_resolution_index := RenderResolution.NATIVE
var display_mode_index := DisplayMode.WINDOWED
var extra_3d_scale := 1.0
var upscaler_mode_index := UpscalerMode.AUTO
var fsr_sharpness := 0.2
var graphics_visual_values: Dictionary = {}
var _ocean: Ocean
var _sunlight: DirectionalLight3D
var _world_environment: WorldEnvironment
var _environment: Environment
var _seabed_manager: Node
var _window: Window
var _windowed_position := Vector2i.ZERO
var _windowed_size := Vector2i(1280, 720)
var _windowed_screen_position := Vector2i.ZERO
var _windowed_screen_size := Vector2i.ZERO
var _windowed_screen_scale := 1.0
var _has_windowed_rect := false
var _last_observed_screen := -1
var _last_topology_signature := ""
var _topology_poll_elapsed := 0.0
var _window_persist_elapsed := 0.0
var _window_state_dirty := false
var _last_window_position := Vector2i.ZERO
var _last_window_size := Vector2i.ZERO
var _diagnostic_snapshot: Dictionary = {}
var _diagnostic_clouds_enabled := true
var _diagnostic_active := false
var _pending_revert_snapshot: Dictionary = {}
var _display_confirmation_deadline_msec := 0
var _display_confirmation_last_seconds := -1
var _display_validation_deadline_msec := 0

signal display_confirmation_changed(active: bool, seconds_remaining: int, message: String)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_window = get_window()
	_ocean = get_node_or_null(ocean_path) as Ocean
	_sunlight = get_node_or_null(sunlight_path) as DirectionalLight3D
	_world_environment = get_node_or_null(world_environment_path) as WorldEnvironment
	_seabed_manager = get_node_or_null(seabed_manager_path)
	if _world_environment != null:
		_environment = _world_environment.environment

	if _ocean == null or _sunlight == null or _environment == null or water_material == null or clouds_resource == null:
		push_error("QualityManager needs Ocean, Sunlight, WorldEnvironment, sea material, and Sunshine Clouds 2 resource.")
		return

	var config := ConfigFile.new()
	var has_saved_quality := false
	if config.load(SETTINGS_PATH) == OK:
		has_saved_quality = config.has_section_key("graphics", "quality")
		current_quality_index = clampi(int(config.get_value("graphics", "quality", Quality.HIGH)), Quality.HIGH, Quality.LOW)
		current_frame_limit_index = clampi(int(config.get_value("graphics", "frame_limit", FrameLimit.FPS_60)), FrameLimit.FPS_30, FrameLimit.UNLIMITED)
		_quality_user_selected = bool(config.get_value("graphics", "quality_user_selected", has_saved_quality))
		ui_scale_index = clampi(int(config.get_value("interface", "ui_scale_index", ui_scale_index)), 0, UI_SCALE_FACTORS.size() - 1)
		navigation_detail_enabled = bool(config.get_value("interface", "navigation_detail", navigation_detail_enabled))
	if not has_saved_quality:
		current_quality_index = _recommend_initial_quality()
		_quality_user_selected = false
	_load_graphics_settings(config)
	_apply_ui_scale()
	_apply_graphics_settings_internal(get_graphics_settings(), true, false)
	if _window != null:
		_window.size_changed.connect(_on_window_size_changed)
		_last_observed_screen = DisplayServer.window_get_current_screen()
		_last_topology_signature = _get_display_topology_signature()
		_last_window_position = _window.position
		_last_window_size = _window.size
	if not has_saved_quality:
		_save_settings()
	settings_changed.emit()


func _process(_delta: float) -> void:
	if _display_confirmation_deadline_msec > 0:
		var remaining_msec := _display_confirmation_deadline_msec - Time.get_ticks_msec()
		var seconds := maxi(0, ceili(float(remaining_msec) / 1000.0))
		if seconds != _display_confirmation_last_seconds:
			_display_confirmation_last_seconds = seconds
			display_confirmation_changed.emit(true, seconds, "保留这组显示设置？")
		if remaining_msec <= 0:
			_revert_pending_graphics_settings("显示设置未确认，已恢复之前的设置。")
	elif _display_validation_deadline_msec > 0 and Time.get_ticks_msec() >= _display_validation_deadline_msec:
		_display_validation_deadline_msec = 0
		if not _window_matches_display_mode(display_mode_index):
			_revert_pending_graphics_settings("当前平台未能应用所选窗口模式，已恢复之前的设置。")

	_topology_poll_elapsed += _get_process_delta_fallback()
	if _topology_poll_elapsed >= 0.5:
		_topology_poll_elapsed = 0.0
		var screen := DisplayServer.window_get_current_screen()
		var topology := _get_display_topology_signature()
		if display_mode_index == DisplayMode.WINDOWED and _window != null and not _window.borderless:
			if _window.position != _last_window_position or _window.size != _last_window_size:
				_window_state_dirty = true
				_last_window_position = _window.position
				_last_window_size = _window.size
		if screen != _last_observed_screen or topology != _last_topology_signature:
			_last_observed_screen = screen
			_last_topology_signature = topology
			if display_mode_index != DisplayMode.WINDOWED:
				_apply_root_render_resolution()
			else:
				_apply_root_render_resolution()
			settings_changed.emit()

	if _window_state_dirty and display_mode_index == DisplayMode.WINDOWED and _window != null and not _window.borderless:
		_window_persist_elapsed += _get_process_delta_fallback()
		if _window_persist_elapsed >= 1.0:
			_window_state_dirty = false
			_window_persist_elapsed = 0.0
			_capture_windowed_state()
			_save_settings()


func _get_process_delta_fallback() -> float:
	return get_process_delta_time()


func _on_window_size_changed() -> void:
	_apply_root_render_resolution()
	_window_state_dirty = display_mode_index == DisplayMode.WINDOWED and _window != null and not _window.borderless


func set_quality(index: int) -> void:
	if index < Quality.HIGH or index > Quality.LOW:
		return
	_quality_user_selected = true
	current_quality_index = index
	graphics_preset_index = _graphics_preset_for_legacy_quality(index)
	graphics_visual_values = QUALITY_PROFILES[index].duplicate(true)
	_apply_quality_profile(true)
	_save_settings()
	settings_changed.emit()


## Temporary profile switch for the isolated performance benchmark. It never writes user settings.
func set_quality_for_benchmark(index: int) -> void:
	if index < Quality.HIGH or index > Quality.LOW:
		return
	if current_quality_index == index:
		return
	current_quality_index = index
	_apply_quality_profile(true)
	_apply_resolution_scale(RESOLUTION_SCALES[index], UpscalerMode.FSR2)
	settings_changed.emit()


func set_quality_for_diagnostic(index: int) -> void:
	if index < Quality.HIGH or index > Quality.LOW:
		return
	if not _diagnostic_active:
		begin_diagnostic_override()
	current_quality_index = index
	_apply_quality_profile(true)
	_apply_resolution_scale(RESOLUTION_SCALES[index], UpscalerMode.FSR2)
	settings_changed.emit()


func begin_diagnostic_override() -> void:
	if _diagnostic_active:
		return
	_diagnostic_snapshot = get_graphics_settings()
	_diagnostic_clouds_enabled = get_clouds_enabled()
	_diagnostic_active = true


func restore_diagnostic_overrides() -> void:
	if not _diagnostic_active:
		return
	var snapshot := _diagnostic_snapshot.duplicate(true)
	_diagnostic_active = false
	_diagnostic_snapshot.clear()
	_apply_graphics_settings_internal(snapshot, false, false)
	if clouds_resource != null:
		clouds_resource.enabled = _diagnostic_clouds_enabled
	settings_changed.emit()


func is_diagnostic_override_active() -> bool:
	return _diagnostic_active


func set_frame_limit_for_diagnostic(index: int) -> void:
	if index < FrameLimit.FPS_30 or index > FrameLimit.UNLIMITED:
		return
	if not _diagnostic_active:
		begin_diagnostic_override()
	current_frame_limit_index = index
	_apply_frame_limit()
	settings_changed.emit()


func toggle_fullscreen_for_diagnostic() -> void:
	if not _diagnostic_active:
		begin_diagnostic_override()
	display_mode_index = DisplayMode.WINDOWED if display_mode_index == DisplayMode.FULLSCREEN else DisplayMode.FULLSCREEN
	_is_fullscreen = display_mode_index == DisplayMode.FULLSCREEN
	_apply_display_mode(false)
	_apply_root_render_resolution()
	settings_changed.emit()


func get_quality_index() -> int:
	return current_quality_index


func get_quality_name() -> String:
	return QUALITY_NAMES[current_quality_index]


func get_quality_selection_source() -> String:
	return "玩家手动选择" if _quality_user_selected else "首次启动推荐"


func get_resolution_scale() -> float:
	return extra_3d_scale


func get_graphics_settings() -> Dictionary:
	return {
		"display_mode": display_mode_index,
		"vsync_enabled": DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED,
		"frame_limit": current_frame_limit_index,
		"render_resolution": render_resolution_index,
		"graphics_preset": graphics_preset_index,
		"visual_values": graphics_visual_values.duplicate(true),
		"extra_3d_scale": extra_3d_scale,
		"upscaler": upscaler_mode_index,
		"fsr_sharpness": fsr_sharpness,
		"windowed_position": _windowed_position,
		"windowed_size": _windowed_size,
		"windowed_screen_position": _windowed_screen_position,
		"windowed_screen_size": _windowed_screen_size,
		"has_windowed_rect": _has_windowed_rect,
		"quality_user_selected": _quality_user_selected,
	}


func get_default_graphics_settings() -> Dictionary:
	var recommended_quality := _recommend_initial_quality()
	var preset := _graphics_preset_for_legacy_quality(recommended_quality)
	var default_extra_scale: float = RESOLUTION_SCALES[recommended_quality]
	var default_values := get_graphics_preset_visual_values(preset)
	return {
		"display_mode": DisplayMode.WINDOWED,
		"vsync_enabled": true,
		"frame_limit": FrameLimit.FPS_60,
		"render_resolution": RenderResolution.NATIVE,
		"graphics_preset": preset,
		"visual_values": default_values,
		"extra_3d_scale": default_extra_scale,
		"upscaler": UpscalerMode.FSR2 if default_extra_scale < 0.999 else UpscalerMode.AUTO,
		"fsr_sharpness": 0.2,
		"windowed_position": Vector2i.ZERO,
		"windowed_size": Vector2i(1280, 720),
		"windowed_screen_position": Vector2i.ZERO,
		"windowed_screen_size": Vector2i.ZERO,
		"has_windowed_rect": false,
		"quality_user_selected": false,
	}


func get_graphics_preset_visual_values(index: int) -> Dictionary:
	match index:
		GraphicsPreset.PERFORMANCE:
			return QUALITY_PROFILES[Quality.LOW].duplicate(true)
		GraphicsPreset.BALANCED:
			return QUALITY_PROFILES[Quality.MEDIUM].duplicate(true)
		GraphicsPreset.HIGH:
			return QUALITY_PROFILES[Quality.HIGH].duplicate(true)
		GraphicsPreset.ULTRA:
			return _get_ultra_quality_profile()
		GraphicsPreset.CUSTOM:
			return graphics_visual_values.duplicate(true) if not graphics_visual_values.is_empty() else QUALITY_PROFILES[Quality.HIGH].duplicate(true)
		_:
			return QUALITY_PROFILES[Quality.HIGH].duplicate(true)


func apply_graphics_settings(settings: Dictionary) -> Dictionary:
	if _display_confirmation_deadline_msec > 0:
		return {"ok": false, "confirmation_required": true, "message": "请先确认或恢复当前显示设置。"}
	var previous := get_graphics_settings()
	var normalized := _normalize_graphics_settings(settings)
	var risky_change := int(normalized["display_mode"]) != display_mode_index or int(normalized["render_resolution"]) != render_resolution_index
	_pending_revert_snapshot = previous if risky_change else {}
	_apply_graphics_settings_internal(normalized, false, true)
	if int(normalized["graphics_preset"]) != int(previous["graphics_preset"]):
		_quality_user_selected = true
	if risky_change:
		_display_confirmation_deadline_msec = Time.get_ticks_msec() + roundi(DISPLAY_CONFIRM_SECONDS * 1000.0)
		_display_confirmation_last_seconds = -1
		_display_validation_deadline_msec = Time.get_ticks_msec() + 4000
		display_confirmation_changed.emit(true, roundi(DISPLAY_CONFIRM_SECONDS), "保留这组显示设置？")
	else:
		_save_settings()
	settings_changed.emit()
	return {
		"ok": true,
		"confirmation_required": risky_change,
		"message": "请在 15 秒内确认显示设置。" if risky_change else "图形设置已应用。",
	}


func confirm_graphics_settings() -> void:
	if _display_confirmation_deadline_msec <= 0:
		return
	_display_confirmation_deadline_msec = 0
	_display_validation_deadline_msec = 0
	_pending_revert_snapshot.clear()
	_save_settings()
	display_confirmation_changed.emit(false, 0, "显示设置已保留。")
	settings_changed.emit()


func revert_graphics_settings() -> void:
	_revert_pending_graphics_settings("已恢复之前的图形设置。")


func is_display_confirmation_pending() -> bool:
	return _display_confirmation_deadline_msec > 0


func get_display_confirmation_seconds_remaining() -> int:
	if _display_confirmation_deadline_msec <= 0:
		return 0
	return maxi(0, ceili(float(_display_confirmation_deadline_msec - Time.get_ticks_msec()) / 1000.0))


func get_render_resolution_label(index: int) -> String:
	if index < 0 or index >= RENDER_RESOLUTION_NAMES.size():
		return RENDER_RESOLUTION_NAMES[RenderResolution.NATIVE]
	return RENDER_RESOLUTION_NAMES[index]


func get_graphics_preset_names() -> PackedStringArray:
	return PackedStringArray(GRAPHICS_PRESET_NAMES)


func get_display_mode_names() -> PackedStringArray:
	return PackedStringArray(DISPLAY_MODE_NAMES)


func get_upscaler_names() -> PackedStringArray:
	return PackedStringArray(UPSCALER_NAMES)


func get_extra_3d_scale_names() -> PackedStringArray:
	return PackedStringArray(EXTRA_3D_SCALE_NAMES)


func get_render_resolution_names() -> PackedStringArray:
	return PackedStringArray(RENDER_RESOLUTION_NAMES)


func get_cloud_quality_names() -> PackedStringArray:
	return PackedStringArray(["Performance", "Balanced", "High"])


func get_ocean_quality_names() -> PackedStringArray:
	return PackedStringArray(["Performance", "Balanced", "High"])


func get_graphics_settings_for_preset(settings: Dictionary, preset: int) -> Dictionary:
	var result := _normalize_graphics_settings(settings)
	if preset == GraphicsPreset.CUSTOM:
		result["graphics_preset"] = GraphicsPreset.CUSTOM
		return result
	result["graphics_preset"] = clampi(preset, GraphicsPreset.PERFORMANCE, GraphicsPreset.ULTRA)
	result["visual_values"] = get_graphics_preset_visual_values(int(result["graphics_preset"]))
	return result


func get_cloud_quality_index(values: Dictionary) -> int:
	var resolution := int(values.get("cloud_resolution", 2))
	var steps := float(values.get("cloud_steps", 128.0))
	if resolution >= 3 or steps <= 100.0:
		return 0
	if steps >= 150.0:
		return 2
	return 1


func set_cloud_quality_in_settings(settings: Dictionary, quality_index: int) -> Dictionary:
	var result := _normalize_graphics_settings(settings)
	var level: Dictionary = CLOUD_QUALITY_LEVELS[clampi(quality_index, 0, CLOUD_QUALITY_LEVELS.size() - 1)]
	for key in level:
		result["visual_values"][key] = level[key]
	result["graphics_preset"] = GraphicsPreset.CUSTOM
	return result


func get_ocean_quality_index(values: Dictionary) -> int:
	var resolution := int(values.get("ocean_resolution", 10))
	if resolution <= 8:
		return 0
	if resolution >= 12:
		return 2
	return 1


func set_ocean_quality_in_settings(settings: Dictionary, quality_index: int) -> Dictionary:
	var result := _normalize_graphics_settings(settings)
	var level: Dictionary = OCEAN_QUALITY_LEVELS[clampi(quality_index, 0, OCEAN_QUALITY_LEVELS.size() - 1)]
	for key in level:
		result["visual_values"][key] = level[key]
	result["graphics_preset"] = GraphicsPreset.CUSTOM
	return result


func get_render_resolution_preview(index: int, extra_scale: float = -1.0, mode_override: int = -1) -> Dictionary:
	var target_mode := display_mode_index if mode_override < 0 else clampi(mode_override, DisplayMode.WINDOWED, DisplayMode.FULLSCREEN)
	var output_size := _get_output_size_for_mode(target_mode)
	var scale: float = RENDER_RESOLUTION_SCALES[clampi(index, 0, RENDER_RESOLUTION_SCALES.size() - 1)]
	var root_size := _scaled_even_size(output_size, scale)
	var three_d_scale := extra_3d_scale if extra_scale < 0.0 else clampf(extra_scale, 0.25, 1.5)
	var three_d_size := _scaled_even_size(root_size, three_d_scale)
	var cloud_divisor := 1 << maxi(0, int(roundf(clouds_resource.resolution_scale))) if clouds_resource != null else 1
	var cloud_work_size := Vector2i(maxi(1, three_d_size.x / cloud_divisor), maxi(1, three_d_size.y / cloud_divisor))
	return {
		"output_size": output_size,
		"root_viewport_size": root_size,
		"three_d_internal_size_estimate": three_d_size,
		"cloud_compute_size_estimate": cloud_work_size,
		"resolution_scale": scale,
		"extra_3d_scale": three_d_scale,
	}


func get_ui_scale_index() -> int:
	return ui_scale_index


func get_ui_scale_factor() -> float:
	return UI_SCALE_FACTORS[ui_scale_index]


func get_ui_scale_name() -> String:
	return UI_SCALE_NAMES[ui_scale_index]


func set_ui_scale_index(index: int, persist: bool = true) -> void:
	if index < 0 or index >= UI_SCALE_FACTORS.size():
		return
	if ui_scale_index == index:
		return
	ui_scale_index = index
	_apply_ui_scale()
	if persist:
		_save_settings()
	settings_changed.emit()


func get_navigation_detail_enabled() -> bool:
	return navigation_detail_enabled


func set_navigation_detail_enabled(enabled: bool, persist: bool = true) -> void:
	if navigation_detail_enabled == enabled:
		return
	navigation_detail_enabled = enabled
	if persist:
		_save_settings()
	settings_changed.emit()


func _load_interface_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	ui_scale_index = clampi(int(config.get_value("interface", "ui_scale_index", ui_scale_index)), 0, UI_SCALE_FACTORS.size() - 1)
	navigation_detail_enabled = bool(config.get_value("interface", "navigation_detail", navigation_detail_enabled))


func _apply_ui_scale() -> void:
	var window := get_window()
	if window != null:
		window.content_scale_factor = UI_SCALE_FACTORS[ui_scale_index]


func get_render_metrics() -> Dictionary:
	var window_size := _get_output_size_for_current_window()
	var screen_index := DisplayServer.window_get_current_screen()
	if screen_index < 0 or screen_index >= DisplayServer.get_screen_count():
		screen_index = DisplayServer.SCREEN_PRIMARY
	var screen_size := DisplayServer.screen_get_size(screen_index)
	var screen_scale := DisplayServer.screen_get_scale(screen_index)
	var viewport := get_viewport()
	var root_viewport_size: Vector2i = viewport.size
	var internal_size := _scaled_even_size(root_viewport_size, viewport.scaling_3d_scale)
	var cloud_divisor := 1 << maxi(0, int(roundf(clouds_resource.resolution_scale))) if clouds_resource != null else 1
	var cloud_main_size := Vector2i(maxi(1, floori(float(internal_size.x) / float(cloud_divisor))), maxi(1, floori(float(internal_size.y) / float(cloud_divisor))))
	var design_viewport_size := Vector2i(
		int(ProjectSettings.get_setting("display/window/size/viewport_width", 1920)),
		int(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
	)
	return {
		"window_px": window_size,
		"screen_px": screen_size,
		"window_screen_index": DisplayServer.window_get_current_screen(),
		"screens": _get_screen_metrics(),
		"screen_scale": screen_scale,
		"ui_scale_factor": get_ui_scale_factor(),
		"window_content_scale_factor": _window.content_scale_factor if _window != null else 1.0,
		"content_scale_mode": "VIEWPORT" if _window != null and _window.content_scale_mode == Window.CONTENT_SCALE_MODE_VIEWPORT else str(_window.content_scale_mode) if _window != null else "unknown",
		"content_scale_aspect": "IGNORE" if _window != null and _window.content_scale_aspect == Window.CONTENT_SCALE_ASPECT_IGNORE else str(_window.content_scale_aspect) if _window != null else "unknown",
		"screen_count": DisplayServer.get_screen_count(),
		"hidpi_enabled": bool(ProjectSettings.get_setting("display/window/dpi/allow_hidpi", true)),
		"viewport_px": root_viewport_size,
		"root_viewport_actual_px": root_viewport_size,
		"root_viewport_requested_px": _window.content_scale_size if _window != null else root_viewport_size,
		"design_viewport_px": design_viewport_size,
		"internal_3d_px_estimate": internal_size,
		"cloud_compute_px_estimate": cloud_main_size,
		"cloud_postprocess_px_estimate": internal_size,
		"render_resolution": render_resolution_index,
		"render_resolution_scale": RENDER_RESOLUTION_SCALES[render_resolution_index],
		"resolution_scale": viewport.scaling_3d_scale,
		"upscaler": _get_effective_upscaler_name(),
		"platform": OS.get_name(),
		"vsync": DisplayServer.window_get_vsync_mode(),
		"refresh_hz": DisplayServer.screen_get_refresh_rate(screen_index),
		"max_fps": Engine.max_fps,
		"adapter": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"fullscreen": display_mode_index == DisplayMode.FULLSCREEN,
		"window_mode": _get_window_mode_label(),
		"supersampling": viewport.scaling_3d_scale > 1.001,
	}


func _get_window_mode_label() -> String:
	match DisplayServer.window_get_mode():
		DisplayServer.WINDOW_MODE_WINDOWED:
			return "窗口"
		DisplayServer.WINDOW_MODE_FULLSCREEN:
			return "全屏"
		DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			return "独占全屏"
		DisplayServer.WINDOW_MODE_MAXIMIZED:
			return "最大化窗口"
		_:
			return "未知"


func _get_screen_metrics() -> Array[Dictionary]:
	var screens: Array[Dictionary] = []
	for screen_index in range(DisplayServer.get_screen_count()):
		screens.append({
			"index": screen_index,
			"size": DisplayServer.screen_get_size(screen_index),
			"scale": DisplayServer.screen_get_scale(screen_index),
			"refresh_hz": DisplayServer.screen_get_refresh_rate(screen_index),
		})
	return screens


func set_clouds_enabled(enabled: bool) -> void:
	if clouds_resource != null:
		clouds_resource.enabled = enabled


func get_clouds_enabled() -> bool:
	return clouds_resource != null and clouds_resource.enabled


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
	display_mode_index = DisplayMode.WINDOWED if display_mode_index == DisplayMode.FULLSCREEN else DisplayMode.FULLSCREEN
	_is_fullscreen = display_mode_index == DisplayMode.FULLSCREEN
	_apply_display_mode(false)
	_apply_root_render_resolution()
	_save_settings()
	settings_changed.emit()


func is_fullscreen() -> bool:
	return display_mode_index == DisplayMode.FULLSCREEN


func _apply_quality_profile(rebuild_ocean: bool) -> void:
	var profile: Dictionary = QUALITY_PROFILES[current_quality_index]
	_apply_quality_values(profile, rebuild_ocean)


func _apply_quality_values(profile: Dictionary, rebuild_ocean: bool) -> void:
	var old_resolution := _ocean.outermost_resolution
	var old_lods := _ocean.levels_of_detail

	_sunlight.shadow_enabled = bool(profile.get("shadows_enabled", true))
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
	if _seabed_manager != null and _seabed_manager.get("seagrass_render_density_scale") != null:
		_seabed_manager.set("seagrass_render_density_scale", float(profile.get("vegetation_density", 1.0)))


func _apply_resolution_scale(scale: float, requested_mode: int = UpscalerMode.AUTO) -> void:
	var viewport := get_viewport()
	viewport.scaling_3d_scale = clampf(scale, 0.25, 1.5)
	var mode := requested_mode
	if mode == UpscalerMode.AUTO:
		mode = UpscalerMode.FSR2 if viewport.scaling_3d_scale < 0.999 else UpscalerMode.BILINEAR
	match mode:
		UpscalerMode.FSR2:
			viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
		UpscalerMode.FSR1:
			viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR
		UpscalerMode.BILINEAR, _:
			viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	viewport.fsr_sharpness = fsr_sharpness


func _recommend_initial_quality() -> int:
	# Use the largest attached display target and hardware class for the one-time
	# recommendation. Later display/window/FPS changes never reapply it.
	var framebuffer_size := DisplayServer.window_get_size()
	if framebuffer_size.x <= 0 or framebuffer_size.y <= 0:
		framebuffer_size = Vector2i(
			int(ProjectSettings.get_setting("display/window/size/viewport_width", 1920)),
			int(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
		)
	var largest_display_area := framebuffer_size.x * framebuffer_size.y
	for screen_index in range(DisplayServer.get_screen_count()):
		var screen_size := DisplayServer.screen_get_size(screen_index)
		var screen_area := screen_size.x * screen_size.y
		if screen_area > largest_display_area:
			framebuffer_size = screen_size
			largest_display_area = screen_area
	var megapixels := float(framebuffer_size.x * framebuffer_size.y) / 1_000_000.0
	var hardware := (RenderingServer.get_video_adapter_name() + " " + OS.get_processor_name()).to_lower()
	var cores := OS.get_processor_count()
	if hardware.contains("apple") or hardware.contains("m1") or hardware.contains("m2") or hardware.contains("m3") or hardware.contains("m4") or hardware.contains("m5"):
		var newer_apple_silicon := hardware.contains("m3") or hardware.contains("m4") or hardware.contains("m5")
		var high_limit := 4.0 if newer_apple_silicon else 2.5
		var medium_limit := 7.0 if newer_apple_silicon else 5.0
		if megapixels <= high_limit and cores >= 8:
			return Quality.HIGH
		if megapixels <= medium_limit:
			return Quality.MEDIUM
		return Quality.LOW
	if hardware.contains("nvidia") or hardware.contains("amd") or hardware.contains("radeon"):
		if megapixels <= 3.0 and cores >= 8:
			return Quality.HIGH
		if megapixels <= 7.0:
			return Quality.MEDIUM
		return Quality.LOW
	if megapixels <= 2.1 and cores >= 8:
		return Quality.MEDIUM
	return Quality.LOW


func _apply_frame_limit() -> void:
	match current_frame_limit_index:
		FrameLimit.FPS_30:
			Engine.max_fps = 30
		FrameLimit.FPS_60:
			Engine.max_fps = 60
		FrameLimit.UNLIMITED:
			Engine.max_fps = 0


func _set_vsync_mode(mode: DisplayServer.VSyncMode) -> void:
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(mode)


func _apply_window_mode() -> void:
	_apply_display_mode(true)


func _save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("graphics", "quality", current_quality_index)
	config.set_value("graphics", "quality_user_selected", _quality_user_selected)
	config.set_value("graphics", "frame_limit", current_frame_limit_index)
	config.set_value("graphics", "preset", graphics_preset_index)
	config.set_value("graphics", "visual_values", graphics_visual_values.duplicate(true))
	config.set_value("graphics", "render_resolution", render_resolution_index)
	config.set_value("graphics", "extra_3d_scale", extra_3d_scale)
	config.set_value("graphics", "upscaler", upscaler_mode_index)
	config.set_value("graphics", "fsr_sharpness", fsr_sharpness)
	config.set_value("graphics", "vsync_enabled", DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED)
	config.set_value("display", "mode", display_mode_index)
	config.set_value("display", "fullscreen", display_mode_index == DisplayMode.FULLSCREEN)
	if _has_windowed_rect:
		config.set_value("window", "position", _windowed_position)
		config.set_value("window", "size", _windowed_size)
		config.set_value("window", "screen_position", _windowed_screen_position)
		config.set_value("window", "screen_size", _windowed_screen_size)
		config.set_value("window", "screen_scale", _windowed_screen_scale)
	config.set_value("interface", "ui_scale_index", ui_scale_index)
	config.set_value("interface", "navigation_detail", navigation_detail_enabled)
	var error := config.save(SETTINGS_PATH)
	if error != OK:
		push_warning("Could not save graphics settings: %s" % error_string(error))


func _load_graphics_settings(config: ConfigFile) -> void:
	if config.has_section_key("graphics", "preset"):
		graphics_preset_index = clampi(int(config.get_value("graphics", "preset", GraphicsPreset.HIGH)), GraphicsPreset.PERFORMANCE, GraphicsPreset.CUSTOM)
		render_resolution_index = clampi(int(config.get_value("graphics", "render_resolution", RenderResolution.NATIVE)), RenderResolution.NATIVE, RenderResolution.ULTRA_PERFORMANCE)
		extra_3d_scale = clampf(float(config.get_value("graphics", "extra_3d_scale", 1.0)), 0.25, 1.5)
		upscaler_mode_index = clampi(int(config.get_value("graphics", "upscaler", UpscalerMode.AUTO)), UpscalerMode.AUTO, UpscalerMode.BILINEAR)
		fsr_sharpness = clampf(float(config.get_value("graphics", "fsr_sharpness", 0.2)), 0.0, 2.0)
		var saved_values: Variant = config.get_value("graphics", "visual_values", get_graphics_preset_visual_values(graphics_preset_index))
		graphics_visual_values = saved_values.duplicate(true) if saved_values is Dictionary else get_graphics_preset_visual_values(graphics_preset_index)
		display_mode_index = clampi(int(config.get_value("display", "mode", DisplayMode.FULLSCREEN if bool(config.get_value("display", "fullscreen", false)) else DisplayMode.WINDOWED)), DisplayMode.WINDOWED, DisplayMode.FULLSCREEN)
	else:
		# Migrate the previous High/Medium/Low profile without changing its 3D resolution.
		graphics_preset_index = _graphics_preset_for_legacy_quality(current_quality_index)
		render_resolution_index = RenderResolution.NATIVE
		extra_3d_scale = RESOLUTION_SCALES[current_quality_index]
		upscaler_mode_index = UpscalerMode.FSR2 if extra_3d_scale < 0.999 else UpscalerMode.AUTO
		fsr_sharpness = 0.2
		graphics_visual_values = QUALITY_PROFILES[current_quality_index].duplicate(true)
		display_mode_index = DisplayMode.FULLSCREEN if bool(config.get_value("display", "fullscreen", false)) else DisplayMode.WINDOWED
	if config.has_section_key("graphics", "vsync_enabled"):
		_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(config.get_value("graphics", "vsync_enabled", true)) else DisplayServer.VSYNC_DISABLED)
	else:
		_set_vsync_mode(DisplayServer.VSYNC_ENABLED if current_frame_limit_index == FrameLimit.FPS_60 else DisplayServer.VSYNC_DISABLED)
	_is_fullscreen = display_mode_index == DisplayMode.FULLSCREEN
	_windowed_position = config.get_value("window", "position", Vector2i.ZERO)
	_windowed_size = config.get_value("window", "size", Vector2i(1280, 720))
	_windowed_screen_position = config.get_value("window", "screen_position", Vector2i.ZERO)
	_windowed_screen_size = config.get_value("window", "screen_size", Vector2i.ZERO)
	_windowed_screen_scale = float(config.get_value("window", "screen_scale", 1.0))
	_has_windowed_rect = config.has_section_key("window", "position") and config.has_section_key("window", "size")
	current_quality_index = _legacy_quality_for_preset(graphics_preset_index, current_quality_index)


func _normalize_graphics_settings(source: Dictionary) -> Dictionary:
	var defaults := get_graphics_settings()
	for key in defaults.keys():
		if source.has(key):
			defaults[key] = source[key]
	defaults["display_mode"] = clampi(int(defaults["display_mode"]), DisplayMode.WINDOWED, DisplayMode.FULLSCREEN)
	defaults["frame_limit"] = clampi(int(defaults["frame_limit"]), FrameLimit.FPS_30, FrameLimit.UNLIMITED)
	defaults["render_resolution"] = clampi(int(defaults["render_resolution"]), RenderResolution.NATIVE, RenderResolution.ULTRA_PERFORMANCE)
	defaults["graphics_preset"] = clampi(int(defaults["graphics_preset"]), GraphicsPreset.PERFORMANCE, GraphicsPreset.CUSTOM)
	defaults["extra_3d_scale"] = clampf(float(defaults["extra_3d_scale"]), 0.25, 1.5)
	defaults["upscaler"] = clampi(int(defaults["upscaler"]), UpscalerMode.AUTO, UpscalerMode.BILINEAR)
	defaults["fsr_sharpness"] = clampf(float(defaults["fsr_sharpness"]), 0.0, 2.0)
	var values: Variant = defaults["visual_values"]
	var profile := get_graphics_preset_visual_values(int(defaults["graphics_preset"]))
	if values is Dictionary:
		for key in profile.keys():
			if values.has(key):
				profile[key] = values[key]
	defaults["visual_values"] = _sanitize_visual_values(profile)
	return defaults


func _sanitize_visual_values(values: Dictionary) -> Dictionary:
	var clean := values.duplicate(true)
	clean["shadow_size"] = clampi(int(clean.get("shadow_size", 2048)), 512, 8192)
	clean["shadows_enabled"] = bool(clean.get("shadows_enabled", true))
	clean["shadow_distance"] = clampf(float(clean.get("shadow_distance", 200.0)), 40.0, 1000.0)
	clean["shadow_blur"] = clampf(float(clean.get("shadow_blur", 1.0)), 0.0, 4.0)
	clean["ssr_enabled"] = bool(clean.get("ssr_enabled", true))
	clean["ssr_max_steps"] = clampi(int(clean.get("ssr_max_steps", 32)), 4, 128)
	clean["ssao_enabled"] = bool(clean.get("ssao_enabled", true))
	clean["ssao_radius"] = clampf(float(clean.get("ssao_radius", 0.55)), 0.1, 2.0)
	clean["ssao_intensity"] = clampf(float(clean.get("ssao_intensity", 0.85)), 0.0, 4.0)
	clean["cloud_resolution"] = clampi(int(clean.get("cloud_resolution", 2)), 1, 4)
	clean["cloud_steps"] = clampf(float(clean.get("cloud_steps", 128.0)), 32.0, 256.0)
	clean["cloud_lighting_steps"] = clampf(float(clean.get("cloud_lighting_steps", 10.0)), 2.0, 32.0)
	clean["ocean_resolution"] = clampi(int(clean.get("ocean_resolution", 10)), 4, 24)
	clean["ocean_lods"] = clampi(int(clean.get("ocean_lods", 4)), 1, 8)
	clean["detail_normal_strength"] = clampf(float(clean.get("detail_normal_strength", 0.8)), 0.0, 2.0)
	clean["detail_fade_end"] = clampf(float(clean.get("detail_fade_end", 780.0)), 100.0, 5000.0)
	clean["albedo_detail_fade_end"] = clampf(float(clean.get("albedo_detail_fade_end", 1800.0)), 100.0, 10000.0)
	clean["vegetation_density"] = clampf(float(clean.get("vegetation_density", 0.85)), 0.0, 1.5)
	return clean


func _apply_graphics_settings_internal(source: Dictionary, startup: bool, rebuild_ocean: bool) -> void:
	var settings := _normalize_graphics_settings(source)
	var previous_display_mode := display_mode_index
	graphics_preset_index = int(settings["graphics_preset"])
	_quality_user_selected = bool(settings.get("quality_user_selected", _quality_user_selected))
	render_resolution_index = int(settings["render_resolution"])
	extra_3d_scale = float(settings["extra_3d_scale"])
	upscaler_mode_index = int(settings["upscaler"])
	fsr_sharpness = float(settings["fsr_sharpness"])
	current_frame_limit_index = int(settings["frame_limit"])
	display_mode_index = int(settings["display_mode"])
	_is_fullscreen = display_mode_index == DisplayMode.FULLSCREEN
	graphics_visual_values = settings["visual_values"].duplicate(true)
	current_quality_index = _legacy_quality_for_preset(graphics_preset_index, current_quality_index)
	_apply_quality_values(graphics_visual_values, rebuild_ocean)
	_apply_frame_limit()
	_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(settings["vsync_enabled"]) else DisplayServer.VSYNC_DISABLED)
	_apply_resolution_scale(extra_3d_scale, upscaler_mode_index)
	if startup:
		_restore_windowed_state_before_mode()
		_apply_display_mode(true)
	elif previous_display_mode != display_mode_index:
		_apply_display_mode(false)
	_apply_root_render_resolution()
	settings_changed.emit()


func _revert_pending_graphics_settings(message: String) -> void:
	if _display_confirmation_deadline_msec <= 0 and _pending_revert_snapshot.is_empty():
		return
	_display_confirmation_deadline_msec = 0
	_display_validation_deadline_msec = 0
	_display_confirmation_last_seconds = -1
	var snapshot := _pending_revert_snapshot.duplicate(true)
	_pending_revert_snapshot.clear()
	if not snapshot.is_empty():
		_apply_graphics_settings_internal(snapshot, false, true)
	display_confirmation_changed.emit(false, 0, message)
	settings_changed.emit()


func _apply_root_render_resolution() -> void:
	if _window == null:
		return
	_window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	_window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	var output_size := _get_output_size_for_current_window()
	_window.content_scale_size = _scaled_even_size(output_size, RENDER_RESOLUTION_SCALES[render_resolution_index])


func _get_output_size_for_current_window() -> Vector2i:
	return _get_output_size_for_mode(display_mode_index)


func _get_output_size_for_mode(mode: int) -> Vector2i:
	var window_size := DisplayServer.window_get_size()
	if mode == DisplayMode.BORDERLESS or mode == DisplayMode.FULLSCREEN:
		var actual_mode := DisplayServer.window_get_mode()
		var mode_is_applied := (mode == DisplayMode.FULLSCREEN and actual_mode in [DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]) or (mode == DisplayMode.BORDERLESS and actual_mode == DisplayServer.WINDOW_MODE_WINDOWED and _window != null and _window.borderless)
		if mode_is_applied and window_size.x > 0 and window_size.y > 0:
			return window_size
		var screen := DisplayServer.window_get_current_screen()
		if screen < 0 or screen >= DisplayServer.get_screen_count():
			screen = DisplayServer.SCREEN_PRIMARY
		return DisplayServer.screen_get_size(screen)
	if mode == DisplayMode.WINDOWED and _has_windowed_rect and (DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED or (_window != null and _window.borderless)):
		window_size = _windowed_size
	if window_size.x <= 0 or window_size.y <= 0:
		window_size = Vector2i(
			int(ProjectSettings.get_setting("display/window/size/viewport_width", 1920)),
			int(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
		)
	return window_size


func _scaled_even_size(size: Vector2i, scale: float) -> Vector2i:
	var width := maxi(2, roundi(float(maxi(2, size.x)) * scale / 2.0) * 2)
	var height := maxi(2, roundi(float(maxi(2, size.y)) * scale / 2.0) * 2)
	return Vector2i(width, height)


func _apply_display_mode(startup: bool) -> void:
	if _window == null or DisplayServer.get_name() == "headless":
		return
	var current_mode := DisplayServer.window_get_mode()
	var current_screen := DisplayServer.window_get_current_screen()
	if current_screen < 0 or current_screen >= DisplayServer.get_screen_count():
		current_screen = DisplayServer.SCREEN_PRIMARY
	if not startup and current_mode == DisplayServer.WINDOW_MODE_WINDOWED and not _window.borderless and display_mode_index != DisplayMode.WINDOWED:
		_capture_windowed_state()
	_is_fullscreen = display_mode_index == DisplayMode.FULLSCREEN
	match display_mode_index:
		DisplayMode.WINDOWED:
			_window.mode = Window.MODE_WINDOWED
			_window.borderless = false
			_restore_windowed_rect_or_center()
		DisplayMode.BORDERLESS:
			if startup and _has_windowed_rect:
				_restore_windowed_rect_or_center()
				var saved_screen := _find_windowed_screen()
				current_screen = saved_screen if saved_screen >= 0 else DisplayServer.window_get_current_screen()
				if current_screen < 0 or current_screen >= DisplayServer.get_screen_count():
					current_screen = DisplayServer.SCREEN_PRIMARY
			var target_size := DisplayServer.screen_get_size(current_screen)
			var target_position := DisplayServer.screen_get_position(current_screen)
			_window.mode = Window.MODE_WINDOWED
			_window.borderless = true
			_window.position = target_position
			_window.size = target_size
		DisplayMode.FULLSCREEN:
			if startup and _has_windowed_rect:
				_restore_windowed_rect_or_center()
			# Do not select a screen here: fullscreen stays on the screen already containing this window.
			_window.mode = Window.MODE_FULLSCREEN


func _restore_windowed_state_before_mode() -> void:
	if _window == null or DisplayServer.get_name() == "headless":
		return
	_window.mode = Window.MODE_WINDOWED
	_window.borderless = false
	_restore_windowed_rect_or_center()


func _restore_windowed_rect_or_center() -> void:
	if _window == null:
		return
	_window.mode = Window.MODE_WINDOWED
	_window.borderless = false
	var saved_screen := _find_windowed_screen() if _has_windowed_rect else -1
	if _has_windowed_rect and saved_screen >= 0:
		_window.size = _windowed_size
		var screen_position := DisplayServer.screen_get_position(saved_screen)
		var restored_position := _windowed_position
		if screen_position != _windowed_screen_position:
			restored_position = screen_position + (_windowed_position - _windowed_screen_position)
		var usable := DisplayServer.screen_get_usable_rect(saved_screen)
		var max_position := usable.position + usable.size - _window.size
		_window.position = Vector2i(clampi(restored_position.x, usable.position.x, maxi(usable.position.x, max_position.x)), clampi(restored_position.y, usable.position.y, maxi(usable.position.y, max_position.y)))
	else:
		var screen := DisplayServer.window_get_current_screen()
		if screen < 0 or screen >= DisplayServer.get_screen_count():
			screen = DisplayServer.SCREEN_PRIMARY
		var usable := DisplayServer.screen_get_usable_rect(screen)
		var fallback_size := Vector2i(mini(1280, usable.size.x), mini(720, usable.size.y))
		_window.size = fallback_size
		_window.position = usable.position + (usable.size - fallback_size) / 2


func _capture_windowed_state() -> void:
	if _window == null or DisplayServer.get_name() == "headless" or _window.borderless or DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var screen := DisplayServer.window_get_current_screen()
	if screen < 0 or screen >= DisplayServer.get_screen_count():
		return
	_windowed_position = _window.position
	_windowed_size = _window.size
	_windowed_screen_position = DisplayServer.screen_get_position(screen)
	_windowed_screen_size = DisplayServer.screen_get_size(screen)
	_windowed_screen_scale = DisplayServer.screen_get_scale(screen)
	_has_windowed_rect = true


func _find_windowed_screen() -> int:
	if _windowed_screen_size == Vector2i.ZERO:
		return -1
	var exact_position_match := -1
	var matching_screens: Array[int] = []
	for screen in range(DisplayServer.get_screen_count()):
		if DisplayServer.screen_get_size(screen) != _windowed_screen_size:
			continue
		if not is_equal_approx(DisplayServer.screen_get_scale(screen), _windowed_screen_scale):
			continue
		matching_screens.append(screen)
		if DisplayServer.screen_get_position(screen) == _windowed_screen_position:
			exact_position_match = screen
	if exact_position_match >= 0:
		return exact_position_match
	var current_screen := DisplayServer.window_get_current_screen()
	if matching_screens.has(current_screen):
		return current_screen
	return matching_screens[0] if matching_screens.size() == 1 else -1


func _window_matches_display_mode(expected_mode: int) -> bool:
	if _window == null or DisplayServer.get_name() == "headless":
		return true
	match expected_mode:
		DisplayMode.WINDOWED:
			return DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED and not _window.borderless
		DisplayMode.BORDERLESS:
			return DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED and _window.borderless
		DisplayMode.FULLSCREEN:
			return DisplayServer.window_get_mode() in [DisplayServer.WINDOW_MODE_FULLSCREEN, DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN]
	return false


func _get_display_topology_signature() -> String:
	var pieces: PackedStringArray = []
	for screen in range(DisplayServer.get_screen_count()):
		pieces.append("%s:%s:%.2f" % [str(DisplayServer.screen_get_position(screen)), str(DisplayServer.screen_get_size(screen)), DisplayServer.screen_get_scale(screen)])
	return "|".join(pieces)


func _get_effective_upscaler_name() -> String:
	var mode := upscaler_mode_index
	if mode == UpscalerMode.AUTO:
		mode = UpscalerMode.FSR2 if extra_3d_scale < 0.999 else UpscalerMode.BILINEAR
	return UPSCALER_NAMES[mode]


func _graphics_preset_for_legacy_quality(index: int) -> int:
	match index:
		Quality.HIGH:
			return GraphicsPreset.HIGH
		Quality.MEDIUM:
			return GraphicsPreset.BALANCED
		Quality.LOW:
			return GraphicsPreset.PERFORMANCE
	return GraphicsPreset.HIGH


func _legacy_quality_for_preset(index: int, fallback: int = Quality.HIGH) -> int:
	match index:
		GraphicsPreset.PERFORMANCE:
			return Quality.LOW
		GraphicsPreset.BALANCED:
			return Quality.MEDIUM
		GraphicsPreset.HIGH, GraphicsPreset.ULTRA:
			return Quality.HIGH
		GraphicsPreset.CUSTOM:
			return clampi(fallback, Quality.HIGH, Quality.LOW)
	return Quality.HIGH


func _get_ultra_quality_profile() -> Dictionary:
	var profile := QUALITY_PROFILES[Quality.HIGH].duplicate(true)
	profile["ssr_max_steps"] = 64
	profile["ssao_radius"] = 0.7
	profile["ssao_intensity"] = 1.2
	profile["cloud_steps"] = 192.0
	profile["cloud_lighting_steps"] = 16.0
	profile["ocean_resolution"] = 14
	profile["vegetation_density"] = 1.15
	return profile
