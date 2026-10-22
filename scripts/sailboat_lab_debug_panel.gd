extends CanvasLayer
## All new S1-B1 debug controls are kept in this tabbed SailboatLab panel.

const REFRESH_INTERVAL_S := 0.15
const EXTREME_WAVE_PRESETS := preload("res://scripts/extreme_sea_state_presets.gd")
const NAVIGATION_INSTRUMENT_SCRIPT := preload("res://scripts/sailboat_navigation_instrument.gd")
const FLOAT_POINT_NAMES := ["前左 FL", "前右 FR", "后左 RL", "后右 RR"]

@export var boat_path: NodePath = ^"../SailboatBody"

var _boat: Node
var _lab_root: Node
var _wave_sampler: WaveSampler
var _refresh_elapsed := 0.0
var _metrics_label: Label
var _camera_mode_label: Label
var _turn_diagnostics_label: Label
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
var _sail_metrics_label: Label
var _sail_target_slider: HSlider
var _sail_target_value_label: Label
var _auto_trim_toggle: CheckButton
var _auto_trim_status_label: Label
var _headsail_toggle: CheckButton
var _headsail_target_slider: HSlider
var _headsail_target_value_label: Label
var _headsail_metrics_label: Label
var _rudder_target_slider: HSlider
var _rudder_target_value_label: Label
var _hydrodynamics_metrics_label: Label
var _wind_test_status_label: Label
var _wind_test_buttons: Array[Button] = []


func _ready() -> void:
	_boat = get_node_or_null(boat_path)
	_lab_root = get_parent()
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
	title.text = "S1-C1 · 帆船风帆实验室"
	title.add_theme_font_size_override("font_size", 22)
	outer.add_child(title)
	var subtitle := Label.new()
	subtitle.text = "8 m 原型调参艇 · 四点刚体浮力 · 共用动态海浪 · C 跟随视角 / Delete 全场景重置"
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(subtitle)
	_camera_mode_label = _make_note("摄像机模式读取中。")
	_camera_mode_label.name = "CameraModeStatus"
	outer.add_child(_camera_mode_label)

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
	status_page.add_child(_section_title("航向与已测偏航力矩"))
	_turn_diagnostics_label = _make_note("等待转向诊断快照。")
	_turn_diagnostics_label.name = "TurnDiagnostics"
	status_page.add_child(_turn_diagnostics_label)
	status_page.add_child(_make_note("符号约定：局部 +Y 偏航角速度/力矩为左转趋势，HDG 随之下降；HDG 角速度 = -局部偏航角速度。力矩合计仅包含缓存的帆、Jib、龙骨、舵与显式偏航阻尼分项，不包含 Godot 内部角阻尼、浮力不对称及求解器接触等全部项。"))
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

	var sail_page := _new_scroll_page(tabs, "风与主帆")
	sail_page.add_child(_section_title("操帆模式"))
	_auto_trim_toggle = CheckButton.new()
	_auto_trim_toggle.name = "AutoSailTrimToggle"
	_auto_trim_toggle.text = "自动操帆（AUTO）"
	_auto_trim_toggle.button_pressed = bool(_boat.call("get_auto_sail_trim_enabled")) if _boat != null and _boat.has_method("get_auto_sail_trim_enabled") else false
	_auto_trim_toggle.toggled.connect(_on_auto_trim_toggled)
	sail_page.add_child(_auto_trim_toggle)
	_auto_trim_status_label = _make_note("MANUAL · 自动操帆关闭")
	_auto_trim_status_label.name = "AutoSailTrimStatus"
	sail_page.add_child(_auto_trim_status_label)
	sail_page.add_child(_make_note("AUTO 按实际 AWA 连续调节两张帆的目标角；不会改变航向或舵角。手动拖动任一帆角滑块，或按 J/L，会自动切回 MANUAL。迎风禁航区只显示提示，不注入推进力。"))
	sail_page.add_child(_section_title("手动操帆 · 只改变目标帆角"))
	_sail_target_value_label = _make_note("目标角 0° · 实际角 0°")
	sail_page.add_child(_sail_target_value_label)
	_sail_target_slider = _make_wave_slider(-80.0, 80.0, 1.0, 0.0)
	_sail_target_slider.name = "SailTargetAngle"
	_sail_target_slider.value_changed.connect(_on_sail_target_changed)
	sail_page.add_child(_sail_target_slider)
	sail_page.add_child(_make_note("角度约定：负 TWA/AWA = 左舷来风，正 = 右舷来风；正帆角使 Boom/Clew 向右舷，负角向左舷。AUTO 将帆放到相对风的背风侧。实际帆角按资源限速追随。"))
	sail_page.add_child(_section_title("独立前帆 Jib · J / L 每次改变目标角 10°"))
	_headsail_toggle = CheckButton.new()
	_headsail_toggle.text = "启用前帆气动力与视觉"
	_headsail_toggle.button_pressed = bool(_boat.call("is_headsail_enabled")) if _boat != null and _boat.has_method("is_headsail_enabled") else true
	_headsail_toggle.toggled.connect(_on_headsail_toggled)
	sail_page.add_child(_headsail_toggle)
	_headsail_target_value_label = _make_note("JIB 目标 0° · 实际 0°")
	sail_page.add_child(_headsail_target_value_label)
	_headsail_target_slider = _make_wave_slider(-70.0, 70.0, 1.0, 0.0)
	_headsail_target_slider.name = "HeadsailTargetAngle"
	_headsail_target_slider.value_changed.connect(_on_headsail_target_changed)
	sail_page.add_child(_headsail_target_slider)
	sail_page.add_child(_make_note("正角：前帆 Clew 向右舷移动；负角：向左舷移动。前帆 Head/Tack 固定，Clew 随实际角度移动；J/L 仅改变目标角，实际角按资源中的转帆限速追随。"))
	_headsail_metrics_label = _make_note("等待前帆物理快照。")
	_headsail_metrics_label.name = "HeadsailAerodynamicsDiagnostics"
	sail_page.add_child(_headsail_metrics_label)
	sail_page.add_child(_section_title("本地风向测试 · 不修改正式天气"))
	_wind_test_status_label = _make_note("风场状态读取中。")
	sail_page.add_child(_wind_test_status_label)
	_add_wind_test_button(sail_page, "无风 0 m/s", 0.0, 0.0)
	_add_wind_test_button(sail_page, "迎风 8 m/s（来向 0°）", 8.0, 0.0)
	_add_wind_test_button(sail_page, "顺风 8 m/s（来向 180°）", 8.0, 180.0)
	_add_wind_test_button(sail_page, "左舷横风 8 m/s（来向 270°）", 8.0, 270.0)
	_add_wind_test_button(sail_page, "右舷横风 8 m/s（来向 90°）", 8.0, 90.0)
	sail_page.add_child(_make_note("实验风按钮只写入 SailboatLab 自己的 WindField；若连接由 WeatherStateController 管理的风场，按钮会锁定。F12 临时覆盖仍按 WindField 现有规则生效。"))
	sail_page.add_child(_section_title("手动掌舵 · A 左舵，D 右舵，松开回中"))
	_rudder_target_value_label = _make_note("目标舵角 0° · 实际舵角 0°")
	sail_page.add_child(_rudder_target_value_label)
	_rudder_target_slider = _make_wave_slider(-35.0, 35.0, 1.0, 0.0)
	_rudder_target_slider.name = "RudderTargetAngle"
	_rudder_target_slider.value_changed.connect(_on_rudder_target_changed)
	sail_page.add_child(_rudder_target_slider)
	sail_page.add_child(_make_note("正舵角为右舷舵：向前航行时预期船首向右转。A/D 为按住输入，滑块可设定持续舵角。舵力依赖舵位置相对水速，静止时不产生主动转向。"))
	sail_page.add_child(_make_button("回中舵", _center_rudder))
	sail_page.add_child(_section_title("风场、视风与帆力"))
	_sail_metrics_label = _make_note("等待帆船物理快照。")
	_sail_metrics_label.name = "SailAerodynamicsDiagnostics"
	sail_page.add_child(_sail_metrics_label)
	sail_page.add_child(_section_title("龙骨、船舵与合力诊断"))
	_hydrodynamics_metrics_label = _make_note("等待水动力快照。")
	_hydrodynamics_metrics_label.name = "SailboatHydrodynamicsDiagnostics"
	sail_page.add_child(_hydrodynamics_metrics_label)

	var footer := Label.new()
	footer.text = "独立场景 · 不接入动力船或正式天气；主帆仅以真实力驱动刚体"
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(footer)

	var navigation_instrument := Control.new()
	navigation_instrument.name = "NavigationInstrument"
	navigation_instrument.set_script(NAVIGATION_INSTRUMENT_SCRIPT)
	root.add_child(navigation_instrument)
	navigation_instrument.call("configure", _boat)
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
	_refresh_sail_metrics(data)
	_refresh_auto_trim_controls(data)
	_refresh_headsail_metrics(data)
	_refresh_hydrodynamics_metrics(data)
	_refresh_turn_diagnostics(data)
	if _camera_mode_label != null:
		var follow_enabled := bool(_lab_root.call("is_camera_follow_enabled")) if _lab_root != null and _lab_root.has_method("is_camera_follow_enabled") else false
		_camera_mode_label.text = "摄像机：%s · C 切换，Delete/Backspace 重载整个 SailboatLab" % ("平滑跟随" if follow_enabled else "固定观察")
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


func _refresh_turn_diagnostics(data: Dictionary) -> void:
	if _turn_diagnostics_label == null or _boat == null or not _boat.has_method("get_s1_c4_diagnostic_snapshot"):
		return
	var physics: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
	var navigation: Dictionary = _boat.call("get_navigation_snapshot")
	var heading := float(physics.get("heading_degrees", 0.0))
	var sog_knots := float(navigation.get("sog_knots", 0.0))
	var v_long := float(physics.get("longitudinal_velocity_mps", 0.0))
	var v_lateral := float(physics.get("lateral_velocity_mps", 0.0))
	var yaw_rate_local_deg_s := rad_to_deg(float(physics.get("yaw_rate_rad_s", 0.0)))
	var hdg_rate_deg_s := -yaw_rate_local_deg_s
	var target_rudder_deg := rad_to_deg(float(physics.get("target_rudder_angle_rad", 0.0)))
	var actual_rudder_deg := rad_to_deg(float(physics.get("actual_rudder_angle_rad", 0.0)))
	var max_rudder_deg := rad_to_deg(float(navigation.get("max_rudder_angle_rad", 0.0)))
	var at_limit := absf(actual_rudder_deg) >= maxf(max_rudder_deg - 0.5, 0.0)
	var limit_side := "左限位" if actual_rudder_deg < 0.0 else "右限位" if actual_rudder_deg > 0.0 else "未到限位"
	if not at_limit:
		limit_side = "未到限位"
	var twa := float(navigation.get("true_wind_from_relative_degrees", 0.0))
	var awa := float(navigation.get("apparent_wind_from_relative_degrees", 0.0))
	var rudder_water_speed := float(data.get("rudder_water_speed_mps", 0.0))
	var rudder_aoa_deg := rad_to_deg(float(data.get("rudder_angle_of_attack_rad", 0.0)))
	_turn_diagnostics_label.text = (
		"HDG %.1f° · SOG %.2f kn · TWA/AWA %+.1f° / %+.1f°\n"
		+ "船体 Vlong %+.3f m/s · Vlat %+.3f m/s\n"
		+ "局部 +Y 偏航角速度 %+.2f°/s · HDG 变化率 %+.2f°/s（正值=右转）\n"
		+ "舵目标/实际 %+.1f° / %+.1f° · ±%.1f° · %s\n"
		+ "舵处相对水速 %.3f m/s · 水动力攻角 %+.1f°\n"
		+ "局部 +Y 已测力矩 N·m：主帆 %+.0f · Jib %+.0f\n"
		+ "龙骨 %+.0f · 舵 %+.0f · 显式偏航阻尼 %+.0f\n"
		+ "已测分项合计 %+.0f N·m"
	) % [
		heading, sog_knots, twa, awa,
		v_long, v_lateral,
		yaw_rate_local_deg_s, hdg_rate_deg_s,
		target_rudder_deg, actual_rudder_deg, max_rudder_deg, limit_side,
		rudder_water_speed, rudder_aoa_deg,
		float(physics.get("sail_yaw_torque_local_nm", 0.0)),
		float(physics.get("headsail_yaw_torque_local_nm", 0.0)),
		float(physics.get("keel_yaw_torque_local_nm", 0.0)),
		float(physics.get("rudder_yaw_torque_local_nm", 0.0)),
		float(physics.get("explicit_yaw_damping_torque_local_nm", 0.0)),
		float(physics.get("summed_measured_yaw_torque_local_nm", 0.0)),
	]


func _refresh_sail_metrics(data: Dictionary) -> void:
	if _sail_metrics_label == null:
		return
	var local_wind: Vector3 = data.get("true_wind_world_mps", Vector3.ZERO)
	var apparent_local: Vector3 = data.get("apparent_wind_local_mps", Vector3.ZERO)
	var lift_local: Vector3 = data.get("sail_lift_force_local_n", Vector3.ZERO)
	var drag_local: Vector3 = data.get("sail_drag_force_local_n", Vector3.ZERO)
	var net_world: Vector3 = data.get("sail_net_force_world_n", Vector3.ZERO)
	var target_degrees := rad_to_deg(float(data.get("target_sail_angle_rad", 0.0)))
	var actual_degrees := rad_to_deg(float(data.get("actual_sail_angle_rad", 0.0)))
	var alpha_degrees := rad_to_deg(float(data.get("sail_angle_of_attack_rad", 0.0)))
	if _sail_target_slider != null:
		_sail_target_slider.set_value_no_signal(target_degrees)
	if _sail_target_value_label != null:
		_sail_target_value_label.text = "目标角 %+.0f° · 实际角 %+.1f° · 机械速度上限 %.1f°/s" % [
			target_degrees,
			actual_degrees,
			rad_to_deg(float(data.get("sail_rotation_speed_rad_s", 0.0))),
		]
	if _wind_test_status_label != null:
		var can_test_wind := bool(_boat.call("can_set_lab_test_wind")) if _boat.has_method("can_set_lab_test_wind") else false
		for button in _wind_test_buttons:
			button.disabled = not can_test_wind
		_wind_test_status_label.text = (
			"风场：%s · 权威天气所有权：%s · F12 覆盖：%s\n"
			+ "本步查询 %d 次 · 采样 %d μs（均值/P95 %d/%d）"
		) % [
			"可调本地测试风" if bool(data.get("wind_field_available", false)) and can_test_wind else "正式风场只读" if bool(data.get("wind_field_available", false)) else "未连接",
			"是" if bool(data.get("wind_field_weather_controlled", false)) else "否",
			str(data.get("wind_debug_override_state", "formal")),
			int(data.get("wind_query_count_per_tick", 0)),
			int(data.get("wind_sample_usec", 0)),
			int(data.get("wind_sample_average_usec", 0)),
			int(data.get("wind_sample_p95_usec", 0)),
		]
	_sail_metrics_label.text = (
		"真风：%.2f m/s · 气象来向 %.0f°\n"
		+ "真风向量（世界，wind-to）：(%.2f, %.2f, %.2f) m/s\n"
		+ "视风：%.2f m/s · 相对船首来向角 %+.1f° · %s\n"
		+ "视风向量（船体局部）：(%.2f, %.2f, %.2f) m/s\n"
		+ "帆面积：%.1f m² · 攻角：%+.1f° · CL %.3f · CD %.3f · 失风权重 %.2f · q %.1f Pa\n"
		+ "升力：%.0f N · 阻力：%.0f N · 合力世界向量：(%.0f, %.0f, %.0f) N\n"
		+ "船速：纵向 %.2f m/s · 横向 %.2f m/s · 横倾 %+.1f° · 偏航角速度 %+.3f rad/s\n"
		+ "帆计算：当前 %d μs · 均值/P95 %d/%d μs · 完整物理：%d μs · 均值/P95 %d/%d μs"
	) % [
		float(data.get("true_wind_speed_mps", 0.0)),
		float(data.get("true_wind_from_degrees", 0.0)),
		local_wind.x, local_wind.y, local_wind.z,
		float(data.get("apparent_wind_speed_mps", 0.0)),
		float(data.get("apparent_wind_from_angle_degrees", 0.0)),
		str(data.get("windward_side", "无有效视风")),
		apparent_local.x, apparent_local.y, apparent_local.z,
		float(data.get("sail_area_m2", 0.0)), alpha_degrees,
		float(data.get("sail_cl", 0.0)), float(data.get("sail_cd", 0.0)),
		float(data.get("sail_luffing_scale", 0.0)),
		float(data.get("sail_dynamic_pressure_pa", 0.0)),
		lift_local.length(), drag_local.length(),
		net_world.x, net_world.y, net_world.z,
		float(data.get("longitudinal_velocity_mps", 0.0)),
		float(data.get("lateral_velocity_mps", 0.0)),
		float(data.get("roll_degrees", 0.0)),
		float(data.get("yaw_rate_rad_s", 0.0)),
		int(data.get("aero_calculation_usec", 0)),
		int(data.get("aero_calculation_average_usec", 0)),
		int(data.get("aero_calculation_p95_usec", 0)),
		int(data.get("force_calculation_usec", 0)),
		int(data.get("total_physics_calculation_average_usec", 0)),
		int(data.get("total_physics_calculation_p95_usec", 0)),
	]


func _refresh_auto_trim_controls(data: Dictionary) -> void:
	if _auto_trim_toggle == null or _boat == null or not _boat.has_method("get_auto_sail_trim_snapshot"):
		return
	var enabled := bool(data.get("auto_sail_trim_enabled", false))
	_auto_trim_toggle.set_pressed_no_signal(enabled)
	var trim: Dictionary = _boat.call("get_auto_sail_trim_snapshot")
	var selected_side := str(trim.get("selected_side", "未选舷侧"))
	var status := str(trim.get("status", "自动操帆已关闭"))
	var awa := float(data.get("apparent_wind_from_angle_degrees", 0.0))
	var aws := float(data.get("apparent_wind_speed_mps", 0.0))
	var status_text := "NO-GO" if bool(trim.get("no_go", false)) else status
	_auto_trim_status_label.text = "%s · AWA %+.1f° / AWS %.2f m/s · %s · %s · 控制计算 %d μs" % [
		"AUTO" if enabled else "MANUAL", awa, aws, selected_side, status_text,
		int(data.get("auto_trim_calculation_usec", 0)),
	]


func _refresh_headsail_metrics(data: Dictionary) -> void:
	if _headsail_target_slider == null:
		return
	var target_degrees := rad_to_deg(float(data.get("target_headsail_angle_rad", 0.0)))
	var actual_degrees := rad_to_deg(float(data.get("actual_headsail_angle_rad", 0.0)))
	_headsail_toggle.set_pressed_no_signal(bool(data.get("headsail_enabled", false)))
	_headsail_target_slider.set_value_no_signal(target_degrees)
	_headsail_target_value_label.text = "JIB TARGET %+.0f° · 实际 %+.1f° · 限速 %.1f°/s" % [
		target_degrees,
		actual_degrees,
		rad_to_deg(float(data.get("headsail_rotation_speed_rad_s", 0.0))),
	]
	var apparent: Vector3 = data.get("headsail_apparent_wind_local_mps", Vector3.ZERO)
	var lift: Vector3 = data.get("headsail_lift_force_local_n", Vector3.ZERO)
	var drag: Vector3 = data.get("headsail_drag_force_local_n", Vector3.ZERO)
	var force: Vector3 = data.get("headsail_net_force_local_n", Vector3.ZERO)
	var center: Vector3 = data.get("headsail_pressure_center_local_m", Vector3.ZERO)
	_headsail_metrics_label.text = (
		"状态：%s · 名义/当前面积 %.2f / %.2f m² · CP (%.2f, %.2f, %.2f) m\n"
		+ "视风 %.2f m/s · 攻角 %+.1f° · CL %.3f · CD %.3f · 失风 %.2f · 反吹保留 %.2f\n"
		+ "Jib 升力 %.0f N · 阻力 %.0f N · 合力 (%.0f, %.0f, %.0f) N · 横倾矩 %+.0f / 偏航矩 %+.0f N·m\n"
		+ "帆计算 Jib 当前/均值/P95 %d/%d/%d μs · WindField/物理步 %d · WaveSampler/物理步 %d"
	) % [
		"启用" if bool(data.get("headsail_enabled", false)) else "禁用",
		float(data.get("headsail_area_m2", 0.0)), float(data.get("headsail_effective_area_m2", 0.0)),
		center.x, center.y, center.z,
		float(data.get("headsail_apparent_wind_speed_mps", 0.0)),
		rad_to_deg(float(data.get("headsail_angle_of_attack_rad", 0.0))),
		float(data.get("headsail_cl", 0.0)), float(data.get("headsail_cd", 0.0)),
		float(data.get("headsail_luffing_scale", 0.0)), float(data.get("headsail_wrong_side_lift_scale", 1.0)),
		lift.length(), drag.length(), force.x, force.y, force.z,
		float(data.get("headsail_roll_torque_local_nm", 0.0)),
		float(data.get("headsail_yaw_torque_nm", 0.0)),
		int(data.get("headsail_aero_calculation_usec", 0)),
		int(data.get("headsail_aero_calculation_average_usec", 0)),
		int(data.get("headsail_aero_calculation_p95_usec", 0)),
		int(data.get("wind_query_count_per_tick", 0)), int(data.get("wave_query_count_per_tick", 0)),
	]


func _refresh_hydrodynamics_metrics(data: Dictionary) -> void:
	if _hydrodynamics_metrics_label == null:
		return
	var keel_force: Vector3 = data.get("keel_force_local_n", Vector3.ZERO)
	var rudder_force: Vector3 = data.get("rudder_force_local_n", Vector3.ZERO)
	var hull_drag: Vector3 = data.get("hull_drag_force_local_n", Vector3.ZERO)
	var total_force: Vector3 = data.get("total_horizontal_force_local_n", Vector3.ZERO)
	var rudder_target := rad_to_deg(float(data.get("target_rudder_angle_rad", 0.0)))
	var rudder_actual := rad_to_deg(float(data.get("actual_rudder_angle_rad", 0.0)))
	if _rudder_target_slider != null:
		_rudder_target_slider.set_value_no_signal(rudder_target)
	if _rudder_target_value_label != null:
		_rudder_target_value_label.text = "目标舵角 %+.0f° · 实际舵角 %+.1f° · 转舵限速 %.0f°/s" % [
			rudder_target,
			rudder_actual,
			rad_to_deg(float(data.get("rudder_rotation_speed_rad_s", 0.0))),
		]
	var longitudinal := float(data.get("longitudinal_velocity_mps", 0.0))
	var lateral := float(data.get("lateral_velocity_mps", 0.0))
	var sideslip_deg := rad_to_deg(atan2(lateral, maxf(absf(longitudinal), 0.15)))
	_hydrodynamics_metrics_label.text = (
		"船首航向 %.1f° · 纵向 %.2f m/s · 横向 %.2f m/s · 侧滑 %.1f°\n"
		+ "龙骨水速 %.2f m/s · 侧滑 %.1f° · 力 (%.0f, %.0f, %.0f) N · 偏航矩 %+.0f N·m\n"
		+ "船舵水速 %.2f m/s · 攻角 %.1f° · 力 (%.0f, %.0f, %.0f) N · 偏航矩 %+.0f N·m\n"
		+ "舵角目标/实际 %+.0f° / %+.1f° · 机械限位 ±%.0f° · A 左 / D 右，松开回中\n"
		+ "船体水阻 (%.0f, %.0f, %.0f) N · 水动力合力 (%.0f, %.0f, %.0f) N\n"
		+ "帆/龙骨/舵偏航矩 %+.0f / %+.0f / %+.0f N·m · 外力矩合计 %+.0f N·m\n"
		+ "计算 μs 当前 龙骨/舵/船体 %d/%d/%d · 均值/P95 龙骨 %d/%d、舵 %d/%d、全物理 %d/%d"
	) % [
		float(data.get("heading_degrees", 0.0)), longitudinal, lateral, sideslip_deg,
		float(data.get("keel_water_speed_mps", 0.0)), rad_to_deg(float(data.get("keel_side_slip_angle_rad", 0.0))),
		keel_force.x, keel_force.y, keel_force.z, float(data.get("keel_yaw_torque_nm", 0.0)),
		float(data.get("rudder_water_speed_mps", 0.0)), rad_to_deg(float(data.get("rudder_angle_of_attack_rad", 0.0))),
		rudder_force.x, rudder_force.y, rudder_force.z, float(data.get("rudder_yaw_torque_nm", 0.0)),
		rudder_target, rudder_actual, rad_to_deg(float(data.get("max_rudder_angle_rad", 0.0))),
		hull_drag.x, hull_drag.y, hull_drag.z, total_force.x, total_force.y, total_force.z,
		float(data.get("sail_yaw_torque_nm", 0.0)), float(data.get("keel_yaw_torque_nm", 0.0)),
		float(data.get("rudder_yaw_torque_nm", 0.0)), float(data.get("total_external_yaw_torque_nm", 0.0)),
		int(data.get("keel_calculation_usec", 0)), int(data.get("rudder_calculation_usec", 0)), int(data.get("hull_drag_calculation_usec", 0)),
		int(data.get("keel_calculation_average_usec", 0)), int(data.get("keel_calculation_p95_usec", 0)),
		int(data.get("rudder_calculation_average_usec", 0)), int(data.get("rudder_calculation_p95_usec", 0)),
		int(data.get("total_physics_calculation_average_usec", 0)), int(data.get("total_physics_calculation_p95_usec", 0)),
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


func _on_sail_target_changed(value_degrees: float) -> void:
	if _boat != null and _boat.has_method("set_target_sail_angle"):
		_boat.call("set_target_sail_angle", deg_to_rad(value_degrees))


func _on_auto_trim_toggled(enabled: bool) -> void:
	if _boat != null and _boat.has_method("set_auto_sail_trim_enabled"):
		_boat.call("set_auto_sail_trim_enabled", enabled)
	_refresh_metrics()


func _on_headsail_target_changed(value_degrees: float) -> void:
	if _boat != null and _boat.has_method("set_target_headsail_angle"):
		_boat.call("set_target_headsail_angle", deg_to_rad(value_degrees))


func _on_headsail_toggled(enabled: bool) -> void:
	if _boat != null and _boat.has_method("set_headsail_enabled"):
		_boat.call("set_headsail_enabled", enabled)
	_refresh_metrics()


func _on_rudder_target_changed(value_degrees: float) -> void:
	if _boat != null and _boat.has_method("set_target_rudder_angle"):
		_boat.call("set_target_rudder_angle", deg_to_rad(value_degrees))


func _center_rudder() -> void:
	if _boat != null and _boat.has_method("clear_rudder_input"):
		_boat.call("clear_rudder_input")


func _add_wind_test_button(parent: VBoxContainer, text: String, speed_mps: float, from_degrees: float) -> void:
	var button := _make_button(text, _set_lab_test_wind.bind(speed_mps, from_degrees))
	parent.add_child(button)
	_wind_test_buttons.append(button)


func _set_lab_test_wind(speed_mps: float, from_degrees: float) -> void:
	if _boat != null and _boat.has_method("set_lab_test_wind"):
		_boat.call("set_lab_test_wind", speed_mps, from_degrees)
	_refresh_metrics()


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
