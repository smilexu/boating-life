extends CanvasLayer

## Small status display for the boat prototype. Speed is stored in m/s and
## converted to knots only for display (1 m/s = 1.94384 kn).

const COMPASS_HUD_SCRIPT := preload("res://scripts/compass_hud.gd")

@export_node_path("Node3D") var controller_path := NodePath("../MotionRoot")
@export_node_path("Node") var weather_controller_path := NodePath("../../WeatherController")
@export_node_path("Node") var wave_sampler_path := NodePath("../../WaveSampler")
@export_node_path("Node") var quality_manager_path := NodePath("../../QualityManager")

var _controller: BoatController
var _weather_controller: Node
var _wave_sampler: Node
var _quality_manager: Node
var _status_panel: PanelContainer
var _status_label: Label
var _fps_label: Label
var _debug_panel: PanelContainer
var _debug_scroll: ScrollContainer
var _debug_layout: VBoxContainer
var _weather_label: Label
var _sun_label: Label
var _cloud_label: Label
var _wave_label: Label
var _performance_label: Label
var _sun_elevation_slider: HSlider
var _sun_azimuth_slider: HSlider
var _cloud_slider: HSlider
var _wave_slider: HSlider
var _quality_option: OptionButton
var _frame_limit_option: OptionButton
var _window_mode_button: Button
var _clouds_toggle: CheckButton
var _fps_elapsed := 0.0
var _runtime_elapsed := 0.0
var _debug_refresh_elapsed := 0.0


func _ready() -> void:
	_controller = get_node_or_null(controller_path) as BoatController
	if _controller == null:
		push_error("Boat HUD could not find its controller at %s." % controller_path)
		return
	_weather_controller = get_node_or_null(weather_controller_path)
	_wave_sampler = get_node_or_null(wave_sampler_path)
	_quality_manager = get_node_or_null(quality_manager_path)

	_status_panel = PanelContainer.new()
	_status_panel.position = Vector2(24.0, 24.0)
	_status_panel.custom_minimum_size = Vector2(470.0, 138.0)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.035, 0.12, 0.16, 0.82)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 15.0
	panel_style.content_margin_right = 15.0
	panel_style.content_margin_top = 10.0
	panel_style.content_margin_bottom = 10.0
	_status_panel.add_theme_stylebox_override("panel", panel_style)
	var status_layout := VBoxContainer.new()
	status_layout.add_theme_constant_override("separation", 1)
	_status_panel.add_child(status_layout)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", Color(0.91, 0.96, 0.94, 1.0))
	_status_label.add_theme_font_size_override("font_size", 18)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_layout.add_child(_status_label)
	_fps_label = Label.new()
	_fps_label.text = "FPS: --"
	_fps_label.add_theme_color_override("font_color", Color(0.91, 0.96, 0.94, 1.0))
	_fps_label.add_theme_font_size_override("font_size", 17)
	var fps_font := SystemFont.new()
	fps_font.font_names = PackedStringArray(["Menlo", "Consolas", "Courier New", "monospace"])
	_fps_label.add_theme_font_override("font", fps_font)
	status_layout.add_child(_fps_label)
	add_child(_status_panel)
	_build_debug_panel()
	_add_compass_widget()
	_update_status()
	_update_hud_layout()
	get_viewport().size_changed.connect(_update_hud_layout)


func _add_compass_widget() -> void:
	var compass := Control.new()
	compass.name = "CompassHUD"
	compass.set_script(COMPASS_HUD_SCRIPT)
	add_child(compass)
	compass.call("configure", _controller)


func _process(delta: float) -> void:
	_runtime_elapsed += delta
	_fps_elapsed += delta
	if _fps_elapsed >= 0.5:
		_fps_elapsed = fmod(_fps_elapsed, 0.5)
		_update_fps_display()
	if _controller != null:
		_update_status()
	if _debug_panel != null and _debug_panel.visible:
		_debug_refresh_elapsed += delta
		if _debug_refresh_elapsed >= 0.5:
			_debug_refresh_elapsed = fmod(_debug_refresh_elapsed, 0.5)
			_update_debug_status()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F3:
		_debug_panel.visible = not _debug_panel.visible
		if _debug_panel.visible:
			_update_debug_status()
		get_viewport().set_input_as_handled()


func _update_status() -> void:
	if _controller == null:
		return
	var knots := _controller.speed_mps * 1.94384
	var mode_text := "自动巡航" if _controller.is_autopilot else "手动驾驶"
	if _controller.is_motion_paused:
		mode_text += " · 已暂停"
	_status_label.text = "航速  %.1f m/s  ·  %.1f kn\n模式  %s\nW/S 加速减速  ·  A/D 转向  ·  Space 暂停  ·  T 自动巡航\n右键拖动观察  ·  1/2/3 天气  ·  M 地图调试  ·  F3 视觉调试  ·  F10 水面诊断" % [
		_controller.speed_mps,
		knots,
		mode_text
	]


func _update_fps_display() -> void:
	var fps := Engine.get_frames_per_second()
	_fps_label.text = "FPS: %d" % fps if _runtime_elapsed >= 1.5 and fps >= 5 else "FPS: --"


func _build_debug_panel() -> void:
	_debug_panel = PanelContainer.new()
	_debug_panel.position = Vector2(24.0, 196.0)
	_debug_panel.custom_minimum_size = Vector2(390.0, 0.0)
	_debug_panel.visible = false
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.035, 0.09, 0.13, 0.88)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 14.0
	panel_style.content_margin_right = 14.0
	panel_style.content_margin_top = 12.0
	panel_style.content_margin_bottom = 12.0
	_debug_panel.add_theme_stylebox_override("panel", panel_style)

	_debug_scroll = ScrollContainer.new()
	_debug_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_debug_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_debug_panel.add_child(_debug_scroll)
	_debug_layout = VBoxContainer.new()
	_debug_layout.add_theme_constant_override("separation", 7)
	_debug_scroll.add_child(_debug_layout)
	var layout := _debug_layout
	var title := Label.new()
	title.text = "天气与画面调试"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
	layout.add_child(title)

	_weather_label = _make_debug_label()
	layout.add_child(_weather_label)
	var preset_row := HBoxContainer.new()
	preset_row.add_theme_constant_override("separation", 6)
	for preset in [["1  晴天", 0], ["2  少云", 1], ["3  阴天", 2]]:
		var button := Button.new()
		button.text = preset[0]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_weather_button_pressed.bind(preset[1]))
		preset_row.add_child(button)
	layout.add_child(preset_row)

	_sun_elevation_slider = _add_slider_row(layout, "太阳高度", 3.0, 75.0, 0.5)
	_sun_elevation_slider.value = 10.0
	_sun_elevation_slider.value_changed.connect(_on_sun_elevation_changed)
	_sun_azimuth_slider = _add_slider_row(layout, "太阳方位", 0.0, 360.0, 1.0)
	_sun_azimuth_slider.value = 28.0
	_sun_azimuth_slider.value_changed.connect(_on_sun_azimuth_changed)
	_cloud_slider = _add_slider_row(layout, "云量", 0.0, 1.0, 0.01)
	_cloud_slider.value = 0.18
	_cloud_slider.value_changed.connect(_on_cloud_changed)
	_wave_slider = _add_slider_row(layout, "波浪强度", 0.0, 2.0, 0.05)
	_wave_slider.value = 1.05
	_wave_slider.value_changed.connect(_on_wave_changed)

	var settings_title := Label.new()
	settings_title.text = "性能与显示"
	settings_title.add_theme_font_size_override("font_size", 16)
	settings_title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
	layout.add_child(settings_title)
	_quality_option = _add_option_row(layout, "画质 / 3D 分辨率", ["画质优先 · 100%", "平衡 · 75%", "性能优先 · 67%"])
	_quality_option.item_selected.connect(_on_quality_selected)
	_frame_limit_option = _add_option_row(layout, "帧率上限", ["30 FPS", "60 FPS", "Unlimited"])
	_frame_limit_option.item_selected.connect(_on_frame_limit_selected)
	_clouds_toggle = CheckButton.new()
	_clouds_toggle.text = "体积云渲染（性能对照）"
	_clouds_toggle.toggled.connect(_on_clouds_toggled)
	layout.add_child(_clouds_toggle)
	_window_mode_button = Button.new()
	_window_mode_button.pressed.connect(_on_window_mode_pressed)
	layout.add_child(_window_mode_button)

	_sun_label = _make_debug_label()
	_cloud_label = _make_debug_label()
	_wave_label = _make_debug_label()
	_performance_label = _make_debug_label()
	layout.add_child(_sun_label)
	layout.add_child(_cloud_label)
	layout.add_child(_wave_label)
	layout.add_child(_performance_label)
	add_child(_debug_panel)
	_refresh_weather_controls()
	_refresh_settings_controls()


func _add_slider_row(parent: VBoxContainer, row_title: String, low: float, high: float, increment: float) -> HSlider:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 1)
	var title := Label.new()
	title.text = row_title
	title.add_theme_color_override("font_color", Color(0.79, 0.87, 0.89))
	row.add_child(title)
	var slider := HSlider.new()
	slider.min_value = low
	slider.max_value = high
	slider.step = increment
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)
	parent.add_child(row)
	return slider


func _make_debug_label() -> Label:
	var label := Label.new()
	label.add_theme_color_override("font_color", Color(0.86, 0.92, 0.92))
	return label


func _add_option_row(parent: VBoxContainer, row_title: String, options: Array[String]) -> OptionButton:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = row_title
	title.custom_minimum_size.x = 104.0
	title.add_theme_color_override("font_color", Color(0.79, 0.87, 0.89))
	row.add_child(title)
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.custom_minimum_size.x = 150.0
	for item in options:
		option.add_item(item)
	row.add_child(option)
	parent.add_child(row)
	return option


func _refresh_settings_controls() -> void:
	if _quality_manager == null:
		_quality_option.disabled = true
		_frame_limit_option.disabled = true
		_clouds_toggle.disabled = true
		_window_mode_button.disabled = true
		_window_mode_button.text = "画面设置不可用"
		return
	_quality_option.select(int(_quality_manager.call("get_quality_index")))
	_frame_limit_option.select(int(_quality_manager.call("get_frame_limit_index")))
	_clouds_toggle.set_pressed_no_signal(bool(_quality_manager.call("get_clouds_enabled")))
	_update_window_mode_button()


func _update_window_mode_button() -> void:
	if _quality_manager == null or _window_mode_button == null:
		return
	_window_mode_button.text = "切换至窗口模式" if bool(_quality_manager.call("is_fullscreen")) else "切换至全屏"


func _update_hud_layout() -> void:
	if _status_panel == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var viewport_width := viewport_size.x
	var panel_width := minf(470.0, maxf(280.0, viewport_width - 48.0))
	_status_panel.custom_minimum_size.x = panel_width
	_status_label.custom_minimum_size.x = panel_width - 32.0
	_fps_label.custom_minimum_size.x = panel_width - 32.0
	if _debug_panel != null:
		_debug_panel.custom_minimum_size.x = minf(390.0, maxf(280.0, viewport_width - 48.0))
		var available_height := maxf(280.0, viewport_size.y - _debug_panel.position.y - 16.0)
		var content_height := _debug_layout.get_combined_minimum_size().y
		var panel_height := minf(content_height + 24.0, available_height)
		_debug_panel.custom_minimum_size.y = panel_height
		_debug_scroll.custom_minimum_size.y = maxf(220.0, panel_height - 24.0)


func _refresh_weather_controls() -> void:
	if _weather_controller == null:
		_weather_label.text = "天气控制器未连接"
		return
	_sun_elevation_slider.set_value_no_signal(float(_weather_controller.call("get_sun_elevation")))
	_sun_azimuth_slider.set_value_no_signal(float(_weather_controller.call("get_sun_azimuth")))
	_cloud_slider.set_value_no_signal(float(_weather_controller.call("get_cloud_coverage")))
	_wave_slider.set_value_no_signal(float(_wave_sampler.get("wave_strength")) if _wave_sampler != null else 1.0)
	_weather_label.text = "当前天气：%s   ·   按 1 / 2 / 3 切换" % _weather_controller.get("current_weather_name")


func _update_debug_status() -> void:
	if _weather_controller != null:
		_weather_label.text = "当前天气：%s   ·   按 1 / 2 / 3 切换" % _weather_controller.get("current_weather_name")
		_sun_label.text = "太阳：高度 %.1f°  ·  方位 %.0f°" % [
			float(_weather_controller.call("get_sun_elevation")),
			float(_weather_controller.call("get_sun_azimuth")),
		]
		_cloud_label.text = "云量：%.0f%%" % (float(_weather_controller.call("get_cloud_coverage")) * 100.0)
		if not _sun_elevation_slider.has_focus():
			_sun_elevation_slider.set_value_no_signal(float(_weather_controller.call("get_sun_elevation")))
		if not _sun_azimuth_slider.has_focus():
			_sun_azimuth_slider.set_value_no_signal(float(_weather_controller.call("get_sun_azimuth")))
		if not _cloud_slider.has_focus():
			_cloud_slider.set_value_no_signal(float(_weather_controller.call("get_cloud_coverage")))
	if _wave_sampler != null:
		_wave_label.text = "波浪强度：%.2f" % float(_wave_sampler.get("wave_strength"))
		if not _wave_slider.has_focus():
			_wave_slider.set_value_no_signal(float(_wave_sampler.get("wave_strength")))
	var fps := Engine.get_frames_per_second()
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var visible_objects := int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	var process_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
	var render_metrics: Dictionary = _quality_manager.call("get_render_metrics") if _quality_manager != null else {}
	var window_px: Vector2i = render_metrics.get("window_px", Vector2i.ZERO)
	var viewport_px: Vector2i = render_metrics.get("viewport_px", Vector2i.ZERO)
	var design_viewport_px: Vector2i = render_metrics.get("design_viewport_px", Vector2i.ZERO)
	var internal_px: Vector2i = render_metrics.get("internal_3d_px_estimate", Vector2i.ZERO)
	var screen_px: Vector2i = render_metrics.get("screen_px", Vector2i.ZERO)
	var screen_scale := float(render_metrics.get("screen_scale", 1.0))
	var scale := float(render_metrics.get("resolution_scale", 1.0))
	var source := str(_quality_manager.call("get_quality_selection_source")) if _quality_manager != null else ""
	var vsync_mode := int(render_metrics.get("vsync", 0))
	var max_fps := int(render_metrics.get("max_fps", 0))
	var frame_limit_text := "Unlimited" if max_fps <= 0 else "%d FPS" % max_fps
	_performance_label.text = "实际 %d FPS · 帧间隔 %.2f ms · 脚本 %.2f ms\nDraw Calls %d · 可见物体 %d\n窗口 framebuffer %dx%d · 屏幕 %dx%d · HiDPI %s ×%.1f\n项目基准 %dx%d · 根 Viewport %dx%d\n3D 估算 %dx%d @ %.0f%% (%s) · 超采样 %s\n帧率上限 %s · VSync %s · 档位来源：%s · GPU：%s" % [
		fps,
		1000.0 / float(fps) if fps > 0 else 0.0,
		process_ms,
		draw_calls,
		visible_objects,
		window_px.x, window_px.y,
		screen_px.x, screen_px.y,
		"开" if bool(render_metrics.get("hidpi_enabled", false)) else "关",
		screen_scale,
		design_viewport_px.x, design_viewport_px.y,
		viewport_px.x, viewport_px.y,
		internal_px.x, internal_px.y,
		scale * 100.0,
		str(render_metrics.get("upscaler", "n/a")),
		"开" if bool(render_metrics.get("supersampling", false)) else "关",
		frame_limit_text,
		"开" if vsync_mode == DisplayServer.VSYNC_ENABLED else "关",
		source,
		str(render_metrics.get("adapter", "n/a")),
	]
	_refresh_settings_controls()


func _on_weather_button_pressed(index: int) -> void:
	if _weather_controller != null:
		_weather_controller.call("set_weather_by_index", index)
		_refresh_weather_controls()


func _on_sun_elevation_changed(value: float) -> void:
	if _weather_controller != null:
		_weather_controller.call("set_sun_elevation", value)


func _on_sun_azimuth_changed(value: float) -> void:
	if _weather_controller != null:
		_weather_controller.call("set_sun_azimuth", value)


func _on_cloud_changed(value: float) -> void:
	if _weather_controller != null:
		_weather_controller.call("set_cloud_coverage", value)


func _on_wave_changed(value: float) -> void:
	if _weather_controller != null:
		_weather_controller.call("set_wave_strength", value)
	elif _wave_sampler != null:
		_wave_sampler.set("wave_strength", value)


func _on_quality_selected(index: int) -> void:
	if _quality_manager != null:
		_quality_manager.call("set_quality", index)
		_refresh_settings_controls()


func _on_frame_limit_selected(index: int) -> void:
	if _quality_manager != null:
		_quality_manager.call("set_frame_limit", index)
		_refresh_settings_controls()


func _on_clouds_toggled(enabled: bool) -> void:
	if _quality_manager != null:
		_quality_manager.call("set_clouds_enabled", enabled)


func _on_window_mode_pressed() -> void:
	if _quality_manager != null:
		_quality_manager.call("toggle_fullscreen")
		_update_window_mode_button()

