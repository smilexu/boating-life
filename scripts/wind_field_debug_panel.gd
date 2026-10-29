extends CanvasLayer

signal sample_location_changed(world_position: Vector3)
signal visualization_settings_changed(grid_count: int, meters_per_mps: float)

@export_node_path("Node") var wind_field_path := NodePath("../WindField")
@export_node_path("Node3D") var sample_source_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node") var weather_state_controller_path := NodePath("../WeatherStateController")
@export var start_visible := false
@export var start_test_clock := false
@export var allow_f12_toggle := true
@export var sample_east_m := 0.0
@export var sample_north_m := 0.0

const WindArrowScript := preload("res://scripts/wind_field_indicator.gd")
const WindGraphScript := preload("res://scripts/wind_field_speed_graph.gd")
const KNOTS_PER_MPS := 1.94384
const VALIDATION_TOLERANCE_MPS := 0.05

var _wind_field: WindField
var _weather_state_controller: Node
var _sample_source: Node3D
var _panel: PanelContainer
var _layout: VBoxContainer
var _drag_handle: Control
var _arrow: Control
var _graph: Control
var _status_label: Label
var _mode_label: Label
var _sample_label: Label
var _summary_label: Label
var _validation_label: Label
var _seed_spin: SpinBox
var _time_rate_spin: SpinBox
var _test_clock_toggle: CheckButton
var _grid_density_spin: SpinBox
var _arrow_scale_spin: SpinBox
var _mean_speed_spin: SpinBox
var _mean_direction_spin: SpinBox
var _gust_strength_spin: SpinBox
var _gust_time_scale_spin: SpinBox
var _gust_space_scale_spin: SpinBox
var _gust_direction_variation_spin: SpinBox
var _debug_override_toggle: CheckButton
var _refresh_elapsed := 0.0
var _test_clock_seconds := 0.0
var _test_clock_running := false
var _panel_dragging := false
var _panel_position_manually_set := false
var _panel_drag_offset := Vector2.ZERO
var _panel_layout_size := Vector2.ZERO
var _next_graph_sample_time := -INF
var _lab_mode := false
var _validation_expected := Vector3.ZERO
var _validation_enabled := false
var _active_preset_id := ""


static func preset_definition(preset_id: String) -> Dictionary:
	match preset_id:
		"north":
			return {
				"title": "北风",
				"mean_speed_mps": 8.0,
				"wind_from_degrees": 0.0,
				"gust_strength_mps": 0.0,
				"expected_wind": Vector3(0.0, 0.0, 8.0),
			}
		"west":
			return {
				"title": "西风",
				"mean_speed_mps": 8.0,
				"wind_from_degrees": 270.0,
				"gust_strength_mps": 0.0,
				"expected_wind": Vector3(8.0, 0.0, 0.0),
			}
		"calm":
			return {
				"title": "无风",
				"mean_speed_mps": 0.0,
				"wind_from_degrees": 0.0,
				"gust_strength_mps": 0.0,
				"expected_wind": Vector3.ZERO,
			}
		"gust":
			return {
				"title": "阵风测试",
				"mean_speed_mps": 8.0,
				"wind_from_degrees": 0.0,
				"gust_strength_mps": 3.0,
				"expected_wind": Vector3.ZERO,
				"has_expected_wind": false,
			}
	return {}


static func panel_size_for_viewport(viewport_size: Vector2, lab_mode: bool) -> Vector2:
	var horizontal_margin := 36.0 if not lab_mode else 36.0
	var vertical_margin := 96.0 if not lab_mode else 36.0
	var desired := Vector2(390.0, 620.0) if not lab_mode else Vector2(520.0, 820.0)
	return Vector2(
		minf(desired.x, maxf(viewport_size.x - horizontal_margin, 220.0)),
		minf(desired.y, maxf(viewport_size.y - vertical_margin, 220.0))
	)


func _ready() -> void:
	_wind_field = get_node_or_null(wind_field_path) as WindField
	_sample_source = get_node_or_null(sample_source_path) as Node3D
	_weather_state_controller = get_node_or_null(weather_state_controller_path)
	if _wind_field == null:
		push_error("WindFieldDebugPanel could not find WindField at %s." % wind_field_path)
		set_process(false)
		return
	_lab_mode = _sample_source == null
	_build_panel()
	_panel.visible = start_visible
	get_viewport().size_changed.connect(_fit_panel_to_viewport)
	_fit_panel_to_viewport()
	if start_test_clock:
		_test_clock_toggle.button_pressed = true
		_set_test_clock_enabled(true)
	if _lab_mode:
		visualization_settings_changed.emit(int(_grid_density_spin.value), _arrow_scale_spin.value)
	_refresh_status()


func _exit_tree() -> void:
	if _wind_field == null:
		return
	_wind_field.clear_debug_wind_override(0.0)
	if _test_clock_running:
		_wind_field.clear_test_simulation_time()


func _process(delta: float) -> void:
	if _test_clock_running and _wind_field != null:
		_test_clock_seconds += delta * _time_rate_spin.value
		_wind_field.set_test_simulation_time(_test_clock_seconds)
	_refresh_elapsed += delta
	if _panel == null or not _panel.visible:
		return
	_update_graph_sample()
	if _refresh_elapsed >= 0.1:
		_refresh_elapsed = 0.0
		_refresh_status()


func _unhandled_key_input(event: InputEvent) -> void:
	if not allow_f12_toggle or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode != KEY_F12 or event.shift_pressed or event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return
	_panel.visible = not _panel.visible
	if _panel.visible:
		_sync_main_controls_from_wind_field()
		_refresh_status()
	else:
		_close_debug_session()
	get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	if not _panel_dragging:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_panel_dragging = false
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		_apply_panel_top_left(_clamped_panel_top_left(event.global_position - _panel_drag_offset))
		_panel_position_manually_set = true
		get_viewport().set_input_as_handled()


func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.name = "WindFieldTestPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.025, 0.075, 0.10, 0.96)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 15.0
	panel_style.content_margin_right = 15.0
	panel_style.content_margin_top = 13.0
	panel_style.content_margin_bottom = 13.0
	_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(scroll)
	_layout = VBoxContainer.new()
	_layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_layout.add_theme_constant_override("separation", 8)
	scroll.add_child(_layout)

	_drag_handle = HBoxContainer.new()
	_drag_handle.name = "WindPanelDragHandle"
	_drag_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	_drag_handle.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_drag_handle.gui_input.connect(_on_drag_handle_gui_input)
	var title := _make_label("全局风场 W1 · F12 打开 / 关闭", 18)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drag_handle.add_child(title)
	var drag_hint := _make_label("拖动此栏", 12)
	drag_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	drag_hint.add_theme_color_override("font_color", Color(0.62, 0.76, 0.77))
	_drag_handle.add_child(drag_hint)
	_layout.add_child(_drag_handle)
	_layout.add_child(_make_label("X=东，Y=上，Z=南；风向角按真北顺时针表示气象来向。箭头表示空气实际流去方向。", 13))
	_mode_label = _make_label("", 14)
	_mode_label.name = "WindFieldOperatingMode"
	_layout.add_child(_mode_label)
	if _lab_mode:
		_add_preset_buttons()
		_validation_label = _make_label("无风预设会在此显示预期矢量、采样矢量及误差。", 13)
		_validation_label.name = "PresetValidationResult"
		_validation_label.add_theme_color_override("font_color", Color(0.85, 0.89, 0.78))
		_layout.add_child(_validation_label)
		_add_visualization_controls()
	_add_section_title("风场参数")
	_mean_speed_spin = _add_number_row("平均风速 (m/s)", 0.0, 30.0, 0.1, _wind_field.mean_wind_speed_mps, _on_mean_speed_changed)
	_mean_direction_spin = _add_number_row("平均风向 (° 来向)", 0.0, 360.0, 0.1, _wind_field.mean_wind_from_degrees, _on_mean_direction_changed)
	_gust_strength_spin = _add_number_row("阵风强度 (m/s)", 0.0, 15.0, 0.1, _wind_field.gust_strength_mps, _on_gust_strength_changed)
	_gust_time_scale_spin = _add_number_row("阵风时间尺度 (s)", 1.0, 180.0, 0.5, _wind_field.gust_time_scale_seconds, _on_gust_time_scale_changed)
	_gust_space_scale_spin = _add_number_row("阵风空间尺度 (m)", 50.0, 10000.0, 10.0, _wind_field.gust_space_scale_meters, _on_gust_space_scale_changed)
	_gust_direction_variation_spin = _add_number_row("风向扰动幅度 (°)", 0.0, 30.0, 0.1, _wind_field.gust_direction_variation_degrees, _on_gust_direction_variation_changed)
	_seed_spin = _add_number_row("随机种子", -999999999.0, 999999999.0, 1.0, float(_wind_field.random_seed), _on_seed_changed)
	if not _lab_mode:
		_seed_spin.editable = false
		_add_section_title("正式天气隔离覆盖")
		_debug_override_toggle = CheckButton.new()
		_debug_override_toggle.name = "TemporaryWindOverrideToggle"
		_debug_override_toggle.text = "启用临时风场参数覆盖"
		_debug_override_toggle.toggled.connect(_on_debug_override_toggled)
		_layout.add_child(_debug_override_toggle)
		_layout.add_child(_make_label("正式天气会在覆盖期间继续更新；关闭覆盖后平滑恢复最新正式风况。正式随机种子由天气状态控制器管理。", 12))

	_add_section_title("阵风测试时钟（仅驱动此风场，不改世界时间 / 天气）")
	_time_rate_spin = _add_number_row("模拟时间倍率", 0.1, 100.0, 0.1, 1.0, _on_time_rate_changed)
	_test_clock_toggle = CheckButton.new()
	_test_clock_toggle.text = "启用本地测试时钟"
	_test_clock_toggle.add_theme_font_size_override("font_size", 14)
	_test_clock_toggle.toggled.connect(_set_test_clock_enabled)
	_layout.add_child(_test_clock_toggle)

	_add_section_title("采样位置")
	if _lab_mode:
		_add_number_row("东向 X / m", -1000000.0, 1000000.0, 1.0, sample_east_m, _on_sample_east_changed)
		_add_number_row("北向 N / m", -1000000.0, 1000000.0, 1.0, sample_north_m, _on_sample_north_changed)
	else:
		_layout.add_child(_make_label("使用玩家船只的世界位置采样。", 13))

	var readout := HBoxContainer.new()
	readout.add_theme_constant_override("separation", 14)
	_arrow = Control.new()
	_arrow.name = "WindDirectionArrow"
	_arrow.custom_minimum_size = Vector2(112.0, 112.0)
	_arrow.set_script(WindArrowScript)
	readout.add_child(_arrow)
	var summary_column := VBoxContainer.new()
	summary_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var graph_title := _make_label("风速 m/s · 近 120 秒阵风运行时间", 14)
	summary_column.add_child(graph_title)
	_summary_label = _make_label("当前 / 最小 / 最大 / 平均：等待采样", 13)
	summary_column.add_child(_summary_label)
	readout.add_child(summary_column)
	_layout.add_child(readout)

	_graph = Control.new()
	_graph.name = "WindSpeedHistory"
	_graph.custom_minimum_size = Vector2(340.0, 175.0) if _lab_mode else Vector2(340.0, 145.0)
	_graph.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_graph.set_script(WindGraphScript)
	_layout.add_child(_graph)

	_sample_label = _make_label("", 13)
	_status_label = _make_label("", 14)
	_layout.add_child(_sample_label)
	_layout.add_child(_status_label)
	_layout.add_child(_make_label("W1 测试风场尚未接入正式天气、船舶、海浪或风机系统。", 12))


func _add_preset_buttons() -> void:
	_add_section_title("确定性方向预设")
	var buttons := GridContainer.new()
	buttons.columns = 2
	buttons.add_theme_constant_override("h_separation", 8)
	buttons.add_theme_constant_override("v_separation", 6)
	_layout.add_child(buttons)
	_add_preset_button(buttons, "北风 · 0° · 8 m/s", "north")
	_add_preset_button(buttons, "西风 · 270° · 8 m/s", "west")
	_add_preset_button(buttons, "无风 · 0 m/s", "calm")
	_add_preset_button(buttons, "阵风 · 平均 8 + 3 m/s", "gust")


func _add_preset_button(parent: GridContainer, title: String, preset_id: String) -> void:
	var button := Button.new()
	button.text = title
	button.custom_minimum_size.y = 36.0
	button.add_theme_font_size_override("font_size", 13)
	button.pressed.connect(apply_test_preset.bind(preset_id))
	parent.add_child(button)


func _add_visualization_controls() -> void:
	_add_section_title("空间风场显示")
	_grid_density_spin = _add_number_row("箭头阵列边数", 3.0, 17.0, 2.0, 7.0, _on_visualization_density_changed)
	_arrow_scale_spin = _add_number_row("箭长比例 (m / m/s)", 1.0, 20.0, 0.5, 5.0, _on_visualization_scale_changed)


func _add_section_title(title: String) -> void:
	var label := _make_label(title, 15)
	label.add_theme_color_override("font_color", Color(0.69, 0.84, 0.83))
	_layout.add_child(label)


func _fit_panel_to_viewport() -> void:
	if _panel == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var panel_size := panel_size_for_viewport(viewport_size, _lab_mode)
	var previous_position := _panel.get_global_rect().position
	_panel_layout_size = panel_size
	_panel.custom_minimum_size = panel_size
	_panel.size = panel_size
	if _panel_position_manually_set:
		_apply_panel_top_left(_clamped_panel_top_left(previous_position))
	elif _lab_mode:
		_panel.anchor_left = 0.0
		_panel.anchor_right = 0.0
		_panel.anchor_top = 0.0
		_panel.anchor_bottom = 0.0
		_panel.offset_left = 18.0
		_panel.offset_top = 18.0
		_panel.offset_right = 18.0 + panel_size.x
		_panel.offset_bottom = 18.0 + panel_size.y
	else:
		_panel.anchor_left = 1.0
		_panel.anchor_right = 1.0
		_panel.anchor_top = 0.0
		_panel.anchor_bottom = 0.0
		_panel.offset_left = -panel_size.x - 18.0
		_panel.offset_top = 76.0
		_panel.offset_right = -18.0
		_panel.offset_bottom = 76.0 + panel_size.y


func _on_drag_handle_gui_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or event.button_index != MOUSE_BUTTON_LEFT:
		return
	if event.pressed:
		var panel_position := _panel.get_global_rect().position
		_apply_panel_top_left(panel_position)
		_panel_drag_offset = event.global_position - panel_position
		_panel_dragging = true
		_panel_position_manually_set = true
	_drag_handle.accept_event()


func _clamped_panel_top_left(position: Vector2) -> Vector2:
	var viewport_size := get_viewport().get_visible_rect().size
	var maximum := Vector2(
		maxf(12.0, viewport_size.x - _panel_layout_size.x - 12.0),
		maxf(12.0, viewport_size.y - _panel_layout_size.y - 12.0)
	)
	return Vector2(clampf(position.x, 12.0, maximum.x), clampf(position.y, 12.0, maximum.y))


func _apply_panel_top_left(position: Vector2) -> void:
	_panel.anchor_left = 0.0
	_panel.anchor_right = 0.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.position = position
	_panel.size = _panel_layout_size


func _add_number_row(label_text: String, minimum: float, maximum: float, step: float, value: float, callback: Callable) -> SpinBox:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var label := _make_label(label_text, 13)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.step = step
	spin.value = clampf(value, minimum, maximum)
	spin.custom_minimum_size = Vector2(118.0, 0.0)
	spin.add_theme_font_size_override("font_size", 14)
	spin.value_changed.connect(callback)
	row.add_child(spin)
	_layout.add_child(row)
	return spin


func _make_label(text: String, font_size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(0.88, 0.94, 0.93))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _update_graph_sample() -> void:
	var sample := _get_sample_position()
	var details := _wind_field.get_wind_details_at(sample)
	var simulation_time := float(details["simulation_time_seconds"])
	if simulation_time + 0.0001 < _next_graph_sample_time:
		return
	_graph.call("append_sample", simulation_time, float(details["instant_speed_mps"]), float(details["mean_speed_mps"]))
	_next_graph_sample_time = simulation_time + 0.5


func apply_test_preset(preset_id: String) -> void:
	if not _lab_mode or _wind_field == null:
		return
	var preset := preset_definition(preset_id)
	if preset.is_empty():
		return
	var mean_speed := float(preset["mean_speed_mps"])
	var wind_from := float(preset["wind_from_degrees"])
	var gust_strength := float(preset["gust_strength_mps"])
	_mean_speed_spin.set_value_no_signal(mean_speed)
	_mean_direction_spin.set_value_no_signal(wind_from)
	_gust_strength_spin.set_value_no_signal(gust_strength)
	_seed_spin.set_value_no_signal(74291.0)
	_wind_field.set_random_seed(74291)
	_wind_field.set_mean_wind(mean_speed, wind_from)
	_wind_field.set_gust_parameters(gust_strength, _wind_field.gust_time_scale_seconds, _wind_field.gust_space_scale_meters)
	_wind_field.set_test_simulation_time(0.0)
	_test_clock_seconds = 0.0
	_next_graph_sample_time = -INF
	_validation_enabled = bool(preset.get("has_expected_wind", true))
	_validation_expected = preset.get("expected_wind", Vector3.ZERO)
	_active_preset_id = preset_id
	_refresh_status()


func _get_sample_position() -> Vector3:
	if is_instance_valid(_sample_source):
		return _sample_source.global_position
	return Vector3(sample_east_m, 0.0, -sample_north_m)


func _refresh_status() -> void:
	if _wind_field == null or _status_label == null:
		return
	if _lab_mode:
		_mode_label.text = "模式：WindFieldLab 独立测试风场"
	else:
		var state_text := "正式天气"
		if _weather_state_controller != null:
			state_text += " · %s" % String(_weather_state_controller.call("get_current_weather_name"))
		match _wind_field.get_debug_override_state():
			"active":
				_mode_label.text = "模式：临时测试覆盖 · %s" % state_text
			"restoring":
				_mode_label.text = "模式：%s · 覆盖正在平滑解除" % state_text
			_:
				_mode_label.text = "模式：%s" % state_text
	var sample := _get_sample_position()
	var details := _wind_field.get_wind_details_at(sample)
	var wind: Vector3 = details["wind_vector"]
	if _arrow != null:
		_arrow.call("set_wind_vector", wind)
	var instant_mps := float(details["instant_speed_mps"])
	var mean_mps := float(details["mean_speed_mps"])
	var from_degrees := float(details["instant_wind_from_degrees"])
	if not _lab_mode and _mode_label != null:
		var override_state := _wind_field.get_debug_override_state()
		if override_state == "active" or override_state == "restoring":
			_mode_label.text += "\n当前有效平均风：%.1f m/s · %.0f° 来向" % [
				mean_mps, float(_wind_field.mean_wind_from_degrees),
			]
	var vector_text := "(E %.2f, U %.2f, S %.2f) m/s" % [wind.x, wind.y, wind.z]
	_status_label.text = (
		"Seed %d · 阵风时间 %.1f s\n平均 %.2f m/s (%.2f kn) · 瞬时 %.2f m/s (%.2f kn)\n"
		+ "气象风向 %.1f° 来向 · 阵风增量 %+.2f m/s\n世界风矢量 %s"
	) % [
		int(details["random_seed"]), float(details["simulation_time_seconds"]),
		mean_mps, mean_mps * KNOTS_PER_MPS, instant_mps, instant_mps * KNOTS_PER_MPS,
		from_degrees, float(details["gust_increment_mps"]), vector_text,
	]
	var north := -sample.z
	_sample_label.text = "采样世界位置：E/X %.1f m · N/−Z %.1f m · Y %.1f m" % [sample.x, north, sample.y]
	if _graph != null and _summary_label != null:
		var statistics: Dictionary = _graph.call("get_statistics")
		_summary_label.text = "当前 %.2f · 最小 %.2f · 最大 %.2f · 平均 %.2f m/s" % [
			float(statistics["current"]), float(statistics["minimum"]), float(statistics["maximum"]), mean_mps,
		]
	if _validation_enabled:
		_update_validation()
	elif _lab_mode and _active_preset_id == "gust" and _validation_label != null:
		_validation_label.text = "阵风预设 · 平均 8 m/s · 强度 3 m/s · 当前采样 %.2f m/s（无固定瞬时目标）" % instant_mps
		_validation_label.add_theme_color_override("font_color", Color(0.91, 0.84, 0.62))


func _update_validation() -> void:
	if _validation_label == null or _wind_field == null or not _validation_enabled:
		return
	var actual := _wind_field.get_wind_at(_get_sample_position())
	var error_mps := actual.distance_to(_validation_expected)
	var passes := error_mps <= VALIDATION_TOLERANCE_MPS
	_validation_label.text = "%s · 预期 %s · 实际 %s · 误差 %.4f m/s · %s" % [
		"PASS" if passes else "FAIL",
		_format_vector(_validation_expected),
		_format_vector(actual),
		error_mps,
		"容差 %.2f m/s" % VALIDATION_TOLERANCE_MPS,
	]
	_validation_label.add_theme_color_override("font_color", Color(0.54, 0.91, 0.65) if passes else Color(1.0, 0.48, 0.42))


func is_panel_open() -> bool:
	return _panel != null and _panel.visible


func _format_vector(value: Vector3) -> String:
	return "(E %.2f, U %.2f, S %.2f)" % [value.x, value.y, value.z]


func _set_test_clock_enabled(enabled: bool) -> void:
	if _wind_field == null:
		return
	_test_clock_running = enabled
	if enabled:
		_test_clock_seconds = _wind_field.get_simulation_time_seconds()
		_wind_field.set_test_simulation_time(_test_clock_seconds)
	else:
		_wind_field.clear_test_simulation_time()
	_refresh_status()


func _on_mean_speed_changed(value: float) -> void:
	_set_wind_parameter("mean_wind_speed_mps", value)


func _on_mean_direction_changed(value: float) -> void:
	_set_wind_parameter("mean_wind_from_degrees", value)


func _on_gust_strength_changed(value: float) -> void:
	_set_wind_parameter("gust_strength_mps", value)


func _on_gust_time_scale_changed(value: float) -> void:
	_set_wind_parameter("gust_time_scale_seconds", value)


func _on_gust_space_scale_changed(value: float) -> void:
	_set_wind_parameter("gust_space_scale_meters", value)


func _on_gust_direction_variation_changed(value: float) -> void:
	_set_wind_parameter("gust_direction_variation_degrees", value)


func _on_seed_changed(value: float) -> void:
	if _lab_mode:
		_wind_field.set_random_seed(int(value))


func _on_debug_override_toggled(enabled: bool) -> void:
	if _lab_mode or _wind_field == null:
		return
	if enabled:
		_wind_field.set_debug_wind_override(_wind_field.get_effective_wind_settings())
	else:
		_wind_field.clear_debug_wind_override()
	_refresh_status()


func _set_wind_parameter(key: String, value: float) -> void:
	if _wind_field == null:
		return
	if _lab_mode:
		match key:
			"mean_wind_speed_mps":
				_wind_field.set_mean_wind(value, _wind_field.mean_wind_from_degrees)
			"mean_wind_from_degrees":
				_wind_field.set_mean_wind(_wind_field.mean_wind_speed_mps, value)
			"gust_strength_mps":
				_wind_field.set_gust_parameters(value, _wind_field.gust_time_scale_seconds, _wind_field.gust_space_scale_meters)
			"gust_time_scale_seconds":
				_wind_field.set_gust_parameters(_wind_field.gust_strength_mps, value, _wind_field.gust_space_scale_meters)
			"gust_space_scale_meters":
				_wind_field.set_gust_parameters(_wind_field.gust_strength_mps, _wind_field.gust_time_scale_seconds, value)
			"gust_direction_variation_degrees":
				_wind_field.gust_direction_variation_degrees = value
	else:
		var settings := _wind_field.get_effective_wind_settings()
		settings[key] = value
		if _debug_override_toggle != null and not _debug_override_toggle.button_pressed:
			_debug_override_toggle.set_pressed_no_signal(true)
		_wind_field.set_debug_wind_override(settings)
	_refresh_status()


func _sync_main_controls_from_wind_field() -> void:
	if _lab_mode or _wind_field == null:
		return
	var settings := _wind_field.get_effective_wind_settings()
	_mean_speed_spin.set_value_no_signal(float(settings["mean_wind_speed_mps"]))
	_mean_direction_spin.set_value_no_signal(float(settings["mean_wind_from_degrees"]))
	_gust_strength_spin.set_value_no_signal(float(settings["gust_strength_mps"]))
	_gust_time_scale_spin.set_value_no_signal(float(settings["gust_time_scale_seconds"]))
	_gust_space_scale_spin.set_value_no_signal(float(settings["gust_space_scale_meters"]))
	_gust_direction_variation_spin.set_value_no_signal(float(settings["gust_direction_variation_degrees"]))
	_seed_spin.set_value_no_signal(float(settings["random_seed"]))
	_debug_override_toggle.set_pressed_no_signal(_wind_field.is_debug_wind_override_enabled())


func _close_debug_session() -> void:
	if _wind_field == null:
		return
	if not _lab_mode:
		_debug_override_toggle.set_pressed_no_signal(false)
		_wind_field.clear_debug_wind_override()
	if _test_clock_running:
		_test_clock_toggle.set_pressed_no_signal(false)
		_set_test_clock_enabled(false)


func _on_time_rate_changed(_value: float) -> void:
	pass


func _on_sample_east_changed(value: float) -> void:
	sample_east_m = value
	sample_location_changed.emit(_get_sample_position())
	_refresh_status()


func _on_sample_north_changed(value: float) -> void:
	sample_north_m = value
	sample_location_changed.emit(_get_sample_position())
	_refresh_status()


func _on_visualization_density_changed(value: float) -> void:
	var odd_density := int(value)
	if odd_density % 2 == 0:
		odd_density = mini(odd_density + 1, 17)
		_grid_density_spin.set_value_no_signal(odd_density)
	visualization_settings_changed.emit(odd_density, _arrow_scale_spin.value)


func _on_visualization_scale_changed(value: float) -> void:
	visualization_settings_changed.emit(int(_grid_density_spin.value), value)
