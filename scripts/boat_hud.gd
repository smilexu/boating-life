extends CanvasLayer

## Small status display for the boat prototype. Speed is stored in m/s and
## converted to knots only for display (1 m/s = 1.94384 kn).

@export_node_path("Node3D") var controller_path := NodePath("../MotionRoot")
@export_node_path("Node") var weather_controller_path := NodePath("../../WeatherController")
@export_node_path("Node") var wave_sampler_path := NodePath("../../WaveSampler")

var _controller: BoatController
var _weather_controller: Node
var _wave_sampler: Node
var _status_label: Label
var _debug_panel: PanelContainer
var _weather_label: Label
var _sun_label: Label
var _cloud_label: Label
var _wave_label: Label
var _performance_label: Label
var _sun_elevation_slider: HSlider
var _sun_azimuth_slider: HSlider
var _cloud_slider: HSlider
var _wave_slider: HSlider


func _ready() -> void:
	_controller = get_node_or_null(controller_path) as BoatController
	if _controller == null:
		push_error("Boat HUD could not find its controller at %s." % controller_path)
		return
	_weather_controller = get_node_or_null(weather_controller_path)
	_wave_sampler = get_node_or_null(wave_sampler_path)

	var panel := PanelContainer.new()
	panel.position = Vector2(24.0, 24.0)
	panel.custom_minimum_size = Vector2(470.0, 112.0)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.035, 0.12, 0.16, 0.82)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 15.0
	panel_style.content_margin_right = 15.0
	panel_style.content_margin_top = 10.0
	panel_style.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", panel_style)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", Color(0.91, 0.96, 0.94, 1.0))
	_status_label.add_theme_font_size_override("font_size", 18)
	panel.add_child(_status_label)
	add_child(panel)
	_build_debug_panel()
	_update_status()


func _process(delta: float) -> void:
	if _controller != null:
		_update_status()
	if _debug_panel != null and _debug_panel.visible:
		_update_debug_status(delta)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F3:
		_debug_panel.visible = not _debug_panel.visible
		if _debug_panel.visible:
			_update_debug_status(0.0)
		get_viewport().set_input_as_handled()


func _update_status() -> void:
	var knots := _controller.speed_mps * 1.94384
	var mode_text := "自动巡航" if _controller.is_autopilot else "手动驾驶"
	if _controller.is_motion_paused:
		mode_text += " · 已暂停"
	_status_label.text = "航速  %.1f m/s  ·  %.1f kn\n模式  %s\nW/S 加速减速  ·  A/D 转向  ·  Space 暂停  ·  T 自动巡航\n右键拖动观察  ·  1/2/3 天气  ·  F3 视觉调试" % [
		_controller.speed_mps,
		knots,
		mode_text
	]


func _build_debug_panel() -> void:
	_debug_panel = PanelContainer.new()
	_debug_panel.position = Vector2(24.0, 164.0)
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

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 7)
	_debug_panel.add_child(layout)
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


func _refresh_weather_controls() -> void:
	if _weather_controller == null:
		_weather_label.text = "天气控制器未连接"
		return
	_sun_elevation_slider.set_value_no_signal(float(_weather_controller.call("get_sun_elevation")))
	_sun_azimuth_slider.set_value_no_signal(float(_weather_controller.call("get_sun_azimuth")))
	_cloud_slider.set_value_no_signal(float(_weather_controller.call("get_cloud_coverage")))
	_wave_slider.set_value_no_signal(float(_wave_sampler.get("wave_strength")) if _wave_sampler != null else 1.0)
	_weather_label.text = "当前天气：%s   ·   按 1 / 2 / 3 切换" % _weather_controller.get("current_weather_name")


func _update_debug_status(delta: float) -> void:
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
	var frame_ms := delta * 1000.0
	_performance_label.text = "实时帧率：%d FPS  ·  最近帧 %.2f ms" % [fps, frame_ms]


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

