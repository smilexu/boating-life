extends CanvasLayer
## All new S1-B1 debug controls are kept in this tabbed SailboatLab panel.

const REFRESH_INTERVAL_S := 0.15
const EXTREME_WAVE_PRESETS := preload("res://scripts/extreme_sea_state_presets.gd")
const FLOAT_POINT_NAMES := ["前左 FL", "前右 FR", "后左 RL", "后右 RR"]

@export var boat_path: NodePath = ^"../SailboatBody"

var _boat: Node
var _wave_sampler: WaveSampler
var _refresh_elapsed := 0.0
var _metrics_label: Label
var _attitude_feedback_label: Label
var _wave_mode_toggle: CheckButton
var _wave_status_label: Label
var _wave_points_label: Label
var _wave_performance_label: Label
var _wave_profile_label: Label
var _wave_compactness_label: Label
var _wave_sharpness_label: Label
var _wave_direction_label: Label
var _wave_compactness_slider: HSlider
var _wave_sharpness_slider: HSlider
var _wave_direction_offset_slider: HSlider
var _selected_extreme_height_m := 0.0
var _strength_label: Label
var _damping_label: Label
var _strength_slider: HSlider
var _damping_slider: HSlider


func _ready() -> void:
	_boat = get_node_or_null(boat_path)
	_wave_sampler = get_node_or_null(^"../WaveSampler") as WaveSampler
	_build_panel()
	if _boat == null:
		push_error("SailboatLabDebugPanel cannot find its test RigidBody3D.")
		set_process(false)


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed < REFRESH_INTERVAL_S:
		return
	_refresh_elapsed = 0.0
	_refresh_metrics()


func _build_panel() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.02
	panel.anchor_top = 0.025
	panel.anchor_right = 0.34
	panel.anchor_bottom = 0.965
	panel.offset_left = 0.0
	panel.offset_top = 0.0
	panel.offset_right = 0.0
	panel.offset_bottom = 0.0
	root.add_child(panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	panel.add_child(outer)
	var title := Label.new()
	title.text = "S1-B2 · 帆船动态海浪实验室"
	title.add_theme_font_size_override("font_size", 22)
	outer.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "8 m 原型调参艇 · 四点刚体浮力 · 共用动态海浪"
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(subtitle)

	var tabs := TabContainer.new()
	tabs.name = "SailboatDebugTabs"
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(tabs)

	var status_page := _new_scroll_page(tabs, "状态")
	_metrics_label = Label.new()
	_metrics_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_metrics_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_metrics_label.add_theme_font_size_override("font_size", 16)
	status_page.add_child(_section_title("物理状态 · 约 6.7 Hz 刷新"))
	status_page.add_child(_metrics_label)
	status_page.add_child(_make_button("重置到水平静水漂浮", _reset_neutral))
	status_page.add_child(_make_note("这里只显示浮力计算代码段耗时，不代表整个 Godot 物理服务器耗时。"))

	var attitude_page := _new_scroll_page(tabs, "姿态释放")
	attitude_page.add_child(_section_title("先设置初始姿态，再由刚体自行恢复"))
	attitude_page.add_child(_make_button("左倾 25° 后释放", _set_port_heel))
	attitude_page.add_child(_make_button("右倾 25° 后释放", _set_starboard_heel))
	attitude_page.add_child(_make_button("船首下俯 18° 后释放", _set_bow_down_pitch))
	attitude_page.add_child(_make_button("船首上仰 18° 后释放", _set_bow_up_pitch))
	attitude_page.add_child(_make_button("返回水平漂浮", _reset_neutral))
	_attitude_feedback_label = _make_note("尚未触发姿态测试。点击按钮后，刚体会在下一物理步设置姿态并自由恢复。")
	_attitude_feedback_label.name = "AttitudeFeedback"
	attitude_page.add_child(_attitude_feedback_label)
	attitude_page.add_child(_make_note("姿态只在按钮触发时设置一次；运行中的横摇与纵摇由 RigidBody3D 求解。"))

	var impulse_page := _new_scroll_page(tabs, "外力扰动")
	impulse_page.add_child(_section_title("一次性冲量 · 不按帧重复施加"))
	impulse_page.add_child(_make_button("水平横向冲量", _apply_horizontal_impulse))
	impulse_page.add_child(_make_button("横摇力矩冲量", _apply_roll_impulse))
	impulse_page.add_child(_make_button("纵摇力矩冲量", _apply_pitch_impulse))
	impulse_page.add_child(_make_button("清除速度并复位", _reset_neutral))
	impulse_page.add_child(_make_note("冲量仅用于观察刚体响应；这里没有帆推进、舵力或波浪力。"))

	var parameters_page := _new_scroll_page(tabs, "浮力参数")
	parameters_page.add_child(_section_title("仅本次实验运行时调节，不写入资源文件"))
	_strength_label = Label.new()
	_strength_slider = HSlider.new()
	_strength_slider.min_value = 0.25
	_strength_slider.max_value = 1.75
	_strength_slider.step = 0.05
	_strength_slider.value = 1.0
	_strength_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_strength_slider.value_changed.connect(_on_strength_changed)
	parameters_page.add_child(_strength_label)
	parameters_page.add_child(_strength_slider)
	_damping_label = Label.new()
	_damping_slider = HSlider.new()
	_damping_slider.min_value = 0.1
	_damping_slider.max_value = 1.5
	_damping_slider.step = 0.05
	_damping_slider.value = 0.55
	_damping_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_damping_slider.value_changed.connect(_on_damping_changed)
	parameters_page.add_child(_damping_label)
	parameters_page.add_child(_damping_slider)
	parameters_page.add_child(_make_note("调节值有硬范围保护。恢复默认值请使用“重置到水平静水漂浮”。"))
	_update_parameter_labels()

	var waves_page := _new_scroll_page(tabs, "海浪耦合")
	waves_page.add_child(_section_title("共用正式海浪采样与 F3 极端海况预设"))
	_wave_mode_toggle = CheckButton.new()
	_wave_mode_toggle.text = "动态海浪（WaveSampler）"
	_wave_mode_toggle.button_pressed = bool(_boat.call("get_debug_snapshot").get("dynamic_waves_enabled", false)) if _boat != null else false
	_wave_mode_toggle.toggled.connect(_on_dynamic_wave_toggled)
	waves_page.add_child(_wave_mode_toggle)
	waves_page.add_child(_make_note("极端预设与 main 的 F3 控制使用同一套设置、2.5 秒平滑过渡和浅水振幅约束。"))
	waves_page.add_child(_make_button("正常天气海况", _clear_extreme_wave_test))
	for target_height in [5.0, 10.0, 20.0, 30.0]:
		waves_page.add_child(_make_button(
			"F3 极端海况 %.0f m" % target_height,
			_set_extreme_wave_test.bind(target_height)
		))
	waves_page.add_child(_make_button("10 m 横浪 · 快速观察", _set_ten_meter_beam_sea))
	waves_page.add_child(_section_title("波形观察调节 · 只影响本实验场"))
	waves_page.add_child(_make_note("紧凑度会缩短波长、提高空间频率并缩短周期；目标波高不变。选中极端海况后可调。"))
	_wave_compactness_slider = _make_wave_slider(0.5, 2.5, 0.05, 1.0)
	_wave_compactness_slider.name = "WaveCompactness"
	_wave_compactness_slider.value_changed.connect(_on_wave_shape_changed)
	_wave_compactness_label = _make_note("波长紧凑度：1.00×")
	waves_page.add_child(_wave_compactness_label)
	waves_page.add_child(_wave_compactness_slider)
	_wave_sharpness_slider = _make_wave_slider(0.0, 1.0, 0.01, 0.0)
	_wave_sharpness_slider.name = "WaveSharpness"
	_wave_sharpness_slider.value_changed.connect(_on_wave_shape_changed)
	_wave_sharpness_label = _make_note("波峰水平陡度：0.00")
	waves_page.add_child(_wave_sharpness_label)
	waves_page.add_child(_wave_sharpness_slider)
	_wave_direction_offset_slider = _make_wave_slider(-180.0, 180.0, 1.0, 0.0)
	_wave_direction_offset_slider.name = "WaveDirectionOffset"
	_wave_direction_offset_slider.value_changed.connect(_on_wave_shape_changed)
	_wave_direction_label = _make_note("主浪传播方向偏转：0°")
	waves_page.add_child(_wave_direction_label)
	waves_page.add_child(_wave_direction_offset_slider)
	waves_page.add_child(_make_note("方向角按世界坐标测量：0°沿 +Z，90°沿 +X；测试船船首为 -Z。横浪会让左右浮力点采到更明显的高度差。"))
	_wave_profile_label = _make_note("选择 5 / 10 / 20 / 30 m 海况以查看并调整波长和频率。")
	_wave_profile_label.name = "WaveProfileDiagnostics"
	waves_page.add_child(_wave_profile_label)
	_wave_compactness_slider.editable = false
	_wave_sharpness_slider.editable = false
	_wave_direction_offset_slider.editable = false
	_wave_status_label = _make_note("WaveSampler 状态加载中。")
	_wave_status_label.name = "WaveStatus"
	waves_page.add_child(_wave_status_label)
	_wave_points_label = _make_note("四个浮力点水面高度 / 浸没深度")
	_wave_points_label.name = "WavePointDiagnostics"
	waves_page.add_child(_wave_points_label)
	_wave_performance_label = _make_note("波浪查询与浮力耗时统计")
	_wave_performance_label.name = "WavePerformanceDiagnostics"
	waves_page.add_child(_wave_performance_label)

	var footer := Label.new()
	footer.text = "独立场景 · 不接入动力船；使用现有 WaveSampler 与 F3 海况预设"
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(footer)
	_refresh_metrics()


func _new_scroll_page(parent: TabContainer, page_name: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = page_name
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 9)
	scroll.add_child(content)
	return content


func _section_title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 17)
	return label


func _make_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.focus_mode = Control.FOCUS_ALL
	button.custom_minimum_size.y = 38.0
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	return button


func _make_note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_color_override("font_color", Color(0.72, 0.82, 0.87))
	return label


func _make_wave_slider(minimum: float, maximum: float, step: float, initial_value: float) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = initial_value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.y = 28.0
	return slider


func _refresh_metrics() -> void:
	if _boat == null or not _boat.has_method("get_debug_snapshot"):
		return
	var data: Dictionary = _boat.call("get_debug_snapshot")
	if _attitude_feedback_label != null:
		var action_text := str(data.get("last_test_action", "尚无姿态测试"))
		if bool(data.get("pose_command_pending", false)):
			action_text += "（等待物理步）"
		else:
			action_text += "\n当前：横倾 %+.1f° · 纵摇 %+.1f°" % [
				float(data.get("roll_degrees", 0.0)),
				float(data.get("pitch_degrees", 0.0)),
			]
		_attitude_feedback_label.text = action_text
	_refresh_wave_metrics(data)
	var velocity: Vector3 = data.get("linear_velocity_mps", Vector3.ZERO)
	var angular_velocity: Vector3 = data.get("angular_velocity_rad_s", Vector3.ZERO)
	_metrics_label.text = (
		"质量：%.0f kg\n"
		+ "浮力点：%d（浸没 %d）\n"
		+ "线速度：%.2f m/s · (%.2f, %.2f, %.2f)\n"
		+ "角速度：%.3f rad/s · (%.3f, %.3f, %.3f)\n"
		+ "横倾：%+.1f°\n纵摇：%+.1f°\n"
		+ "水面：Y = %.2f m\n"
		+ "总浮力：%.0f N · 静态重量参考 %.0f N\n"
		+ "浮力计算：%d μs / 物理步 %.4f s\n"
		+ "浮力倍率：%.2f · 阻尼比：%.2f"
	) % [
		float(data.get("mass_kg", 0.0)),
		int(data.get("float_point_count", 0)),
		int(data.get("submerged_point_count", 0)),
		float(data.get("linear_speed_mps", 0.0)), velocity.x, velocity.y, velocity.z,
		angular_velocity.length(), angular_velocity.x, angular_velocity.y, angular_velocity.z,
		float(data.get("roll_degrees", 0.0)),
		float(data.get("pitch_degrees", 0.0)),
		float(data.get("water_height_m", 0.0)),
		float(data.get("buoyancy_total_n", 0.0)),
		float(data.get("mass_kg", 0.0)) * 9.8,
		int(data.get("force_calculation_usec", 0)),
		float(data.get("physics_delta_s", 0.0)),
		float(data.get("buoyancy_strength", 1.0)),
		float(data.get("damping_ratio", 0.0)),
	]


func _refresh_wave_metrics(data: Dictionary) -> void:
	if _wave_status_label == null:
		return
	if _wave_sampler == null:
		_wave_status_label.text = "WaveSampler 未连接 · 当前为静水模式"
		_wave_points_label.text = ""
		_wave_performance_label.text = ""
		return
	var enabled := bool(data.get("dynamic_waves_enabled", false))
	var target_height := float(data.get("extreme_wave_target_height_m", 0.0))
	var transitioning := bool(data.get("extreme_wave_transitioning", false))
	var sea_state := "正常天气波浪" if target_height <= 0.0 else "F3 极端海况目标 %.0f m" % target_height
	var transition_text := " · 参数平滑过渡中" if transitioning else ""
	var shallow_state: Dictionary = {}
	var heights: PackedFloat32Array = data.get("point_water_heights_m", PackedFloat32Array())
	var submergences: PackedFloat32Array = data.get("point_submergences_m", PackedFloat32Array())
	var shallow_scales: PackedFloat32Array = data.get("point_shallow_scales", PackedFloat32Array())
	var effective_depths: PackedFloat32Array = data.get("point_effective_depths_m", PackedFloat32Array())
	var shallow_text := ""
	if not shallow_scales.is_empty():
		shallow_text = "\n浅水振幅倍率：%.2f · 有效水深：%.1f m" % [shallow_scales[0], effective_depths[0]]
	_wave_status_label.text = (
		"模式：%s\n海况：%s%s\n共用波浪时间：%.3f s · 每物理步查询：%d/4%s"
	) % [
		"动态" if enabled else "静水",
		sea_state,
		transition_text,
		float(data.get("wave_time_seconds", 0.0)),
		int(data.get("wave_query_count_per_tick", 0)),
		shallow_text,
	]
	var point_lines: PackedStringArray = []
	var crosswise_difference := 0.0
	var longitudinal_difference := 0.0
	if heights.size() >= 4:
		var port_average := (heights[0] + heights[2]) * 0.5
		var starboard_average := (heights[1] + heights[3]) * 0.5
		var forward_average := (heights[0] + heights[1]) * 0.5
		var aft_average := (heights[2] + heights[3]) * 0.5
		crosswise_difference = port_average - starboard_average
		longitudinal_difference = aft_average - forward_average
	for index in range(mini(4, heights.size())):
		var immersion := submergences[index] if index < submergences.size() else 0.0
		point_lines.append("%s：水面 %.2f m · 浸没 %.2f m" % [FLOAT_POINT_NAMES[index], heights[index], immersion])
	_wave_points_label.text = (
		"左右水面高差：%+.3f m · 前后水面高差：%+.3f m\n" % [crosswise_difference, longitudinal_difference]
		+ "\n".join(point_lines)
	)
	_wave_performance_label.text = (
		"本步波浪采样：%d μs · 平均 / P95：%d / %d μs · 样本 %d\n"
		+ "完整浮力计算：当前 %d μs · 平均 / P95：%d / %d μs"
	) % [
		int(data.get("wave_sample_usec", 0)),
		int(data.get("wave_sample_average_usec", 0)),
		int(data.get("wave_sample_p95_usec", 0)),
		int(data.get("performance_sample_count", 0)),
		int(data.get("force_calculation_usec", 0)),
		int(data.get("total_physics_calculation_average_usec", 0)),
		int(data.get("total_physics_calculation_p95_usec", 0)),
	]
	if _wave_mode_toggle != null:
		_wave_mode_toggle.set_pressed_no_signal(enabled)
	_refresh_wave_profile_label()


func _on_strength_changed(value: float) -> void:
	if _boat != null:
		_boat.call("set_runtime_buoyancy_strength", value)
	_update_parameter_labels()


func _on_damping_changed(value: float) -> void:
	if _boat != null:
		_boat.call("set_runtime_damping_ratio", value)
	_update_parameter_labels()


func _on_dynamic_wave_toggled(enabled: bool) -> void:
	var lab_root := get_parent()
	if lab_root != null and lab_root.has_method("set_dynamic_waves_enabled"):
		lab_root.call("set_dynamic_waves_enabled", enabled)
	elif _boat != null:
		_boat.call("set_dynamic_waves_enabled", enabled)
	_refresh_metrics()


func _set_extreme_wave_test(target_height_m: float) -> void:
	_selected_extreme_height_m = target_height_m
	_wave_compactness_slider.editable = true
	_wave_sharpness_slider.editable = true
	_wave_direction_offset_slider.editable = true
	_apply_lab_extreme_wave_test()


func _on_wave_shape_changed(_value: float) -> void:
	_refresh_wave_profile_label()
	if _selected_extreme_height_m > 0.0:
		_apply_lab_extreme_wave_test()


func _apply_lab_extreme_wave_test() -> void:
	if _wave_sampler == null or _selected_extreme_height_m <= 0.0:
		return
	var base_settings: SeaWaveSettings = _copy_wave_settings_with_direction_offset(
		_wave_sampler.wave_settings,
		_wave_direction_offset_slider.value
	)
	var test_settings: SeaWaveSettings = EXTREME_WAVE_PRESETS.build_settings(
		base_settings,
		_selected_extreme_height_m,
		_wave_compactness_slider.value,
		_wave_sharpness_slider.value
	)
	if test_settings == null:
		return
	if _wave_sampler.set_extreme_sea_test(test_settings, _selected_extreme_height_m):
		_wave_sampler.set_shallow_wave_constraint_options(
			true,
			float(_wave_sampler.get("shallow_wave_full_depth_m")),
			float(_wave_sampler.get("shallow_wave_min_amplitude_scale")),
			float(_wave_sampler.get("shallow_wave_safe_depth_ratio"))
		)
		_wave_mode_toggle.set_pressed_no_signal(true)
		_on_dynamic_wave_toggled(true)
	_refresh_wave_profile_label()


func _clear_extreme_wave_test() -> void:
	if _wave_sampler == null:
		return
	_wave_sampler.clear_extreme_sea_test()
	_selected_extreme_height_m = 0.0
	_wave_compactness_slider.set_value_no_signal(1.0)
	_wave_sharpness_slider.set_value_no_signal(0.0)
	_wave_direction_offset_slider.set_value_no_signal(0.0)
	_wave_compactness_slider.editable = false
	_wave_sharpness_slider.editable = false
	_wave_direction_offset_slider.editable = false
	_wave_mode_toggle.set_pressed_no_signal(true)
	_on_dynamic_wave_toggled(true)
	_refresh_wave_profile_label()


func _copy_wave_settings_with_direction_offset(
	base_settings: SeaWaveSettings,
	direction_offset_degrees: float
) -> SeaWaveSettings:
	if base_settings == null:
		return null
	var adjusted := SeaWaveSettings.new()
	for source: GerstnerWave in base_settings.waves:
		var wave := GerstnerWave.new()
		wave.steepness = source.steepness
		wave.amplitude = source.amplitude
		wave.direction_degrees = fposmod(source.direction_degrees + direction_offset_degrees, 360.0)
		wave.frequency = source.frequency
		wave.speed = source.speed
		wave.phase_degrees = source.phase_degrees
		adjusted.waves.append(wave)
	return adjusted


func _refresh_wave_profile_label() -> void:
	if _wave_profile_label == null:
		return
	_update_wave_slider_labels()
	if _selected_extreme_height_m <= 0.0:
		_wave_profile_label.text = "选择 5 / 10 / 20 / 30 m 海况以查看并调整波长、空间频率和浪向。"
		return
	var profile: Dictionary = EXTREME_WAVE_PRESETS.profile_for_height(
		_selected_extreme_height_m,
		_wave_compactness_slider.value
	)
	if profile.is_empty():
		_wave_profile_label.text = "当前波浪参数不可用。"
		return
	var base_direction := float(_wave_sampler.wave_settings.waves[0].direction_degrees)
	var main_propagation_direction := fposmod(
		base_direction + _wave_direction_offset_slider.value + 180.0,
		360.0
	)
	_wave_profile_label.text = (
		"目标海况：%.0f m · 主浪传播方位 %.0f°\n"
		+ "主浪：λ %.1f m · 空间频率 %.4f m⁻¹ · T %.1f s\n"
		+ "次浪：λ %.1f m · 空间频率 %.4f m⁻¹ · T %.1f s\n"
		+ "短浪：λ %.1f m · 空间频率 %.4f m⁻¹ · T %.1f s\n"
		+ "紧凑度 %.2f× · 水平波形陡度 %.2f"
	) % [
		_selected_extreme_height_m,
		main_propagation_direction,
		float(profile.get("main_wavelength_m", 0.0)),
		1.0 / maxf(float(profile.get("main_wavelength_m", 1.0)), 0.001),
		float(profile.get("main_period_s", 0.0)),
		float(profile.get("cross_wavelength_m", 0.0)),
		1.0 / maxf(float(profile.get("cross_wavelength_m", 1.0)), 0.001),
		float(profile.get("cross_period_s", 0.0)),
		float(profile.get("medium_wavelength_m", 0.0)),
		1.0 / maxf(float(profile.get("medium_wavelength_m", 1.0)), 0.001),
		float(profile.get("medium_period_s", 0.0)),
		_wave_compactness_slider.value,
		_wave_sharpness_slider.value,
	]


func _update_wave_slider_labels() -> void:
	if _wave_compactness_slider != null and _wave_compactness_label != null:
		_wave_compactness_label.text = "波长紧凑度：%.2f×" % _wave_compactness_slider.value
	if _wave_sharpness_slider != null and _wave_sharpness_label != null:
		_wave_sharpness_label.text = "波峰水平陡度：%.2f" % _wave_sharpness_slider.value
	if _wave_direction_offset_slider != null and _wave_direction_label != null:
		_wave_direction_label.text = "主浪传播方向偏转：%+.0f°" % _wave_direction_offset_slider.value


func _set_ten_meter_beam_sea() -> void:
	if _wave_sampler == null or _wave_sampler.wave_settings == null or _wave_sampler.wave_settings.waves.is_empty():
		return
	var base_propagation_direction := fposmod(
		_wave_sampler.wave_settings.waves[0].direction_degrees + 180.0,
		360.0
	)
	var beam_propagation_direction := 270.0
	var direction_offset := fposmod(
		beam_propagation_direction - base_propagation_direction + 180.0,
		360.0
	) - 180.0
	_selected_extreme_height_m = 10.0
	_wave_compactness_slider.set_value_no_signal(2.5)
	_wave_sharpness_slider.set_value_no_signal(0.25)
	_wave_direction_offset_slider.set_value_no_signal(direction_offset)
	_wave_compactness_slider.editable = true
	_wave_sharpness_slider.editable = true
	_wave_direction_offset_slider.editable = true
	_apply_lab_extreme_wave_test()


func _update_parameter_labels() -> void:
	if _strength_label != null:
		_strength_label.text = "浮力强度：%.2f×" % _strength_slider.value
	if _damping_label != null:
		_damping_label.text = "浮点阻尼比：%.2f" % _damping_slider.value


func _reset_neutral() -> void:
	if _boat != null:
		_boat.call("reset_to_neutral")
		_strength_slider.value = 1.0
		_damping_slider.value = 0.55


func _set_port_heel() -> void:
	if _boat != null:
		_boat.call("set_test_attitude", 25.0, 0.0)


func _set_starboard_heel() -> void:
	if _boat != null:
		_boat.call("set_test_attitude", -25.0, 0.0)


func _set_bow_down_pitch() -> void:
	if _boat != null:
		_boat.call("set_test_attitude", 0.0, 18.0)


func _set_bow_up_pitch() -> void:
	if _boat != null:
		_boat.call("set_test_attitude", 0.0, -18.0)


func _apply_horizontal_impulse() -> void:
	if _boat != null:
		_boat.call("apply_horizontal_test_impulse")


func _apply_roll_impulse() -> void:
	if _boat != null:
		_boat.call("apply_roll_test_impulse")


func _apply_pitch_impulse() -> void:
	if _boat != null:
		_boat.call("apply_pitch_test_impulse")
