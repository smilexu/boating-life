extends CanvasLayer
class_name RainVisualDebugPanel

## Local-only rain, lightning, and audio presentation tools. R toggles this panel.
## Closing the panel clears every local override and resumes formal input.

@export_node_path("Node") var rain_visual_controller_path := NodePath("../RainVisualController")
@export_node_path("Node") var lightning_event_controller_path := NodePath("../LightningEventController")
@export_node_path("Node") var environment_audio_manager_path := NodePath("../EnvironmentAudioManager")
@export_node_path("Node") var boat_audio_controller_path := NodePath("../BoatAudioController")
@export var show_in_debug_builds := true

const RAIN_PRESETS := [
	{"label": "无雨", "rate": 0.0},
	{"label": "毛毛雨", "rate": 0.25},
	{"label": "小雨", "rate": 1.5},
	{"label": "中雨", "rate": 5.0},
	{"label": "大雨", "rate": 11.0},
	{"label": "强降雨", "rate": 22.0},
]

var _rain_controller: Node
var _environment_audio_manager: Node
var _boat_audio_controller: Node
var _audio_status_label: Label
var _panel: PanelContainer
var _status_label: Label
var _quality_option: OptionButton
var _rate_slider: HSlider
var _density_slider: HSlider
var _near_density_slider: HSlider
var _length_slider: HSlider
var _opacity_slider: HSlider
var _wind_slider: HSlider
var _micro_slider: HSlider
var _ring_size_slider: HSlider
var _ring_probability_slider: HSlider
var _impact_slider: HSlider
var _haze_slider: HSlider
var _lightning_controller: Node
var _thunder_status_label: Label
var _thunder_override_toggle: CheckButton
var _thunder_intensity_slider: HSlider
var _thunder_frequency_slider: HSlider
var _thunder_flash_slider: HSlider
var _thunder_cloud_flash_slider: HSlider
var _thunder_environment_flash_slider: HSlider
var _thunder_distance_slider: HSlider
var _thunder_width_slider: HSlider
var _thunder_curve_slider: HSlider
var _thunder_primary_density_slider: HSlider
var _thunder_secondary_density_slider: HSlider
var _thunder_glow_slider: HSlider
var _thunder_seed_spin: SpinBox
var _thunder_quality_option: OptionButton
var _reduce_flashes_toggle: CheckButton
var _thunder_freeze_toggle: CheckButton
var _refresh_elapsed := 0.0
var _syncing_controls := false


func _ready() -> void:
	layer = 70
	_rain_controller = get_node_or_null(rain_visual_controller_path)
	_lightning_controller = get_node_or_null(lightning_event_controller_path)
	_environment_audio_manager = get_node_or_null(environment_audio_manager_path)
	_boat_audio_controller = get_node_or_null(boat_audio_controller_path)
	visible = false
	if not show_in_debug_builds or not OS.is_debug_build() or OS.has_feature("dedicated_server") or DisplayServer.get_name().to_lower() == "headless":
		set_process(false)
		set_process_unhandled_key_input(false)
		return
	_build_panel()
	set_process_unhandled_key_input(true)


func _process(delta: float) -> void:
	_refresh_elapsed += delta
	if _refresh_elapsed < 0.25:
		return
	_refresh_elapsed = 0.0
	_refresh_status()
	_refresh_audio_status()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is not InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode != KEY_R or event.shift_pressed or event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return
	_set_panel_open(not visible)
	get_viewport().set_input_as_handled()


func is_panel_open() -> bool:
	return visible


func _build_panel() -> void:
	_panel = PanelContainer.new()
	_panel.name = "RainVisualDebugPanel"
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_panel.offset_left = -430.0
	_panel.offset_top = 22.0
	_panel.offset_right = -22.0
	_panel.offset_bottom = 590.0
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.025, 0.065, 0.085, 0.95)
	panel_style.border_color = Color(0.29, 0.58, 0.63, 0.9)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 14.0
	panel_style.content_margin_right = 14.0
	panel_style.content_margin_top = 12.0
	panel_style.content_margin_bottom = 12.0
	_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel.add_child(scroll)
	var body := VBoxContainer.new()
	body.custom_minimum_size.x = 380.0
	body.add_theme_constant_override("separation", 9)
	scroll.add_child(body)

	var header := HBoxContainer.new()
	body.add_child(header)
	var title := Label.new()
	title.text = "降雨视觉调试"
	title.add_theme_font_size_override("font_size", 19)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button := Button.new()
	close_button.text = "关闭"
	close_button.pressed.connect(func(): _set_panel_open(false))
	header.add_child(close_button)

	var key_hint := Label.new()
	key_hint.text = "R · 仅改本地视觉；关闭面板会解除覆盖"
	key_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	key_hint.add_theme_font_size_override("font_size", 12)
	key_hint.add_theme_color_override("font_color", Color(0.69, 0.83, 0.85))
	body.add_child(key_hint)
	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 13)
	body.add_child(_status_label)

	var preset_title := Label.new()
	preset_title.text = "测试雨量（mm/h）"
	preset_title.add_theme_font_size_override("font_size", 14)
	body.add_child(preset_title)
	var preset_grid := GridContainer.new()
	preset_grid.columns = 3
	preset_grid.add_theme_constant_override("h_separation", 6)
	preset_grid.add_theme_constant_override("v_separation", 6)
	body.add_child(preset_grid)
	for preset in RAIN_PRESETS:
		var button := Button.new()
		button.text = str(preset["label"])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var rate := float(preset["rate"])
		button.pressed.connect(func(): _set_debug_rate(rate))
		preset_grid.add_child(button)
	_rate_slider = _add_slider(body, "本地覆盖雨量（mm/h）", 0.0, 30.0, 0.0, 0.1)
	_rate_slider.value_changed.connect(_on_rate_changed)
	var restore_button := Button.new()
	restore_button.text = "使用正式天气雨量"
	restore_button.pressed.connect(_clear_debug_override)
	body.add_child(restore_button)

	_quality_option = OptionButton.new()
	_quality_option.add_item("Low · 少量近处雨丝", RainVisualController.Quality.LOW)
	_quality_option.add_item("Medium · 雨幕与海面细节", RainVisualController.Quality.MEDIUM)
	_quality_option.add_item("High · 更丰富雨幕与细节", RainVisualController.Quality.HIGH)
	_quality_option.item_selected.connect(_on_quality_selected)
	_add_labeled_control(body, "画面质量", _quality_option)

	var streak_section := Label.new()
	streak_section.text = "雨丝层次"
	streak_section.add_theme_font_size_override("font_size", 15)
	body.add_child(streak_section)
	_density_slider = _add_slider(body, "中景雨幕密度", 0.0, 2.0, 1.0, 0.05)
	_near_density_slider = _add_slider(body, "近景雨丝强度", 0.0, 2.0, 1.0, 0.05)
	_length_slider = _add_slider(body, "雨丝长度（m）", 0.05, 1.5, 0.70, 0.05)
	_opacity_slider = _add_slider(body, "雨丝透明度", 0.0, 1.0, 0.62, 0.02)
	_wind_slider = _add_slider(body, "风倾斜影响", 0.0, 1.0, 0.22, 0.02)
	var water_section := Label.new()
	water_section.text = "海面雨滴细节"
	water_section.add_theme_font_size_override("font_size", 15)
	body.add_child(water_section)
	_micro_slider = _add_slider(body, "微小撞击密度", 0.0, 2.0, 1.0, 0.05)
	_ring_size_slider = _add_slider(body, "涟漪平均尺寸", 0.4, 1.5, 1.0, 0.05)
	_ring_probability_slider = _add_slider(body, "圆环出现比例", 0.0, 2.0, 1.0, 0.05)
	_impact_slider = _add_slider(body, "海面细节强度", 0.0, 2.0, 1.0, 0.02)
	var atmosphere_section := Label.new()
	atmosphere_section.text = "远景空气"
	atmosphere_section.add_theme_font_size_override("font_size", 15)
	body.add_child(atmosphere_section)
	_haze_slider = _add_slider(body, "远景雨幕强度", 0.0, 1.0, 1.0, 0.02)
	for slider in [_density_slider, _near_density_slider, _length_slider, _opacity_slider, _wind_slider, _micro_slider, _ring_size_slider, _ring_probability_slider, _impact_slider, _haze_slider]:
		slider.value_changed.connect(_on_visual_control_changed)
	_add_thunderstorm_debug_section(body)
	_add_audio_debug_section(body)
	_refresh_status()


func _add_thunderstorm_debug_section(body: VBoxContainer) -> void:
	var separator := HSeparator.new()
	body.add_child(separator)
	var title := Label.new()
	title.text = "雷暴与闪电（本地视觉）"
	title.add_theme_font_size_override("font_size", 15)
	body.add_child(title)
	var hint := Label.new()
	hint.text = "普通雨不会触发闪电；测试覆盖不会改天气、风场或存档。设置种子后再触发可复现形状。冻结预览仅用于检查几何；关闭 R 面板会解除覆盖。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.69, 0.83, 0.85))
	body.add_child(hint)
	_thunder_status_label = Label.new()
	_thunder_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_thunder_status_label.add_theme_font_size_override("font_size", 12)
	body.add_child(_thunder_status_label)
	_thunder_override_toggle = CheckButton.new()
	_thunder_override_toggle.text = "启用本地雷暴覆盖"
	_thunder_override_toggle.toggled.connect(_on_thunder_override_toggled)
	body.add_child(_thunder_override_toggle)
	_thunder_intensity_slider = _add_slider(body, "雷暴视觉强度", 0.0, 1.0, 0.55, 0.01)
	_thunder_intensity_slider.value_changed.connect(_on_thunder_intensity_changed)
	_thunder_frequency_slider = _add_slider(body, "闪电频率倍率", 0.25, 3.0, 1.0, 0.05)
	_thunder_frequency_slider.value_changed.connect(_on_thunder_frequency_changed)
	_thunder_flash_slider = _add_slider(body, "闪光强度上限", 0.0, 1.0, 1.0, 0.02)
	_thunder_flash_slider.value_changed.connect(_on_thunder_flash_changed)
	_thunder_cloud_flash_slider = _add_slider(body, "云层局部闪光", 0.0, 1.5, 1.0, 0.02)
	_thunder_cloud_flash_slider.value_changed.connect(_on_thunder_cloud_flash_changed)
	_thunder_environment_flash_slider = _add_slider(body, "环境与海面照明", 0.0, 1.5, 1.0, 0.02)
	_thunder_environment_flash_slider.value_changed.connect(_on_thunder_environment_flash_changed)
	_thunder_distance_slider = _add_slider(body, "闪电距离范围", 0.5, 1.5, 1.0, 0.02)
	_thunder_distance_slider.value_changed.connect(_on_thunder_distance_changed)
	_thunder_width_slider = _add_slider(body, "主干宽度倍率", 0.5, 3.0, 1.65, 0.05)
	_thunder_width_slider.value_changed.connect(_on_thunder_width_changed)
	_thunder_curve_slider = _add_slider(body, "路径曲折程度", 0.4, 2.5, 1.35, 0.05)
	_thunder_curve_slider.value_changed.connect(_on_thunder_curve_changed)
	_thunder_primary_density_slider = _add_slider(body, "一级分叉密度", 0.35, 2.0, 1.0, 0.05)
	_thunder_primary_density_slider.value_changed.connect(_on_thunder_primary_density_changed)
	_thunder_secondary_density_slider = _add_slider(body, "二级分叉密度", 0.35, 2.0, 1.0, 0.05)
	_thunder_secondary_density_slider.value_changed.connect(_on_thunder_secondary_density_changed)
	_thunder_glow_slider = _add_slider(body, "闪电辉光强度", 0.4, 2.0, 1.2, 0.05)
	_thunder_glow_slider.value_changed.connect(_on_thunder_glow_changed)
	_thunder_seed_spin = SpinBox.new()
	_thunder_seed_spin.min_value = 0
	_thunder_seed_spin.max_value = 2147483647
	_thunder_seed_spin.step = 1
	_thunder_seed_spin.value = 629104
	_thunder_seed_spin.value_changed.connect(_on_thunder_seed_changed)
	_add_labeled_control(body, "闪电固定随机种子", _thunder_seed_spin)
	_reduce_flashes_toggle = CheckButton.new()
	_reduce_flashes_toggle.text = "减少闪光强度（视觉舒适）"
	_reduce_flashes_toggle.toggled.connect(_on_reduce_flashes_toggled)
	body.add_child(_reduce_flashes_toggle)
	_thunder_freeze_toggle = CheckButton.new()
	_thunder_freeze_toggle.text = "冻结近距离闪电几何预览"
	_thunder_freeze_toggle.toggled.connect(_on_thunder_freeze_toggled)
	body.add_child(_thunder_freeze_toggle)
	_thunder_quality_option = OptionButton.new()
	_thunder_quality_option.add_item("Low · 云内闪光与简化远雷", LightningEventController.Quality.LOW)
	_thunder_quality_option.add_item("Medium · 远雷与少量近雷", LightningEventController.Quality.MEDIUM)
	_thunder_quality_option.add_item("High · 更多分支与环境照明", LightningEventController.Quality.HIGH)
	_thunder_quality_option.item_selected.connect(_on_thunder_quality_selected)
	_add_labeled_control(body, "雷暴画质", _thunder_quality_option)
	var event_grid := GridContainer.new()
	event_grid.columns = 2
	event_grid.add_theme_constant_override("h_separation", 6)
	event_grid.add_theme_constant_override("v_separation", 6)
	body.add_child(event_grid)
	_add_event_button(event_grid, "云内闪光", "in_cloud")
	_add_event_button(event_grid, "云间闪电", "cloud_to_cloud")
	_add_event_button(event_grid, "远处云地闪电", "distant_cg")
	_add_event_button(event_grid, "中距离云地闪电", "medium_cg")
	_add_event_button(event_grid, "近处云地闪电", "near_cg")
	var restore := Button.new()
	restore.text = "恢复正式雷暴信号"
	restore.pressed.connect(_clear_thunder_debug_override)
	body.add_child(restore)


func _add_audio_debug_section(body: VBoxContainer) -> void:
	var separator := HSeparator.new()
	body.add_child(separator)
	var title := Label.new()
	title.text = "动态音效测试（本地）"
	title.add_theme_font_size_override("font_size", 15)
	body.add_child(title)
	var hint := Label.new()
	hint.text = "仅覆盖声音混音输入，不改正式天气、风场、波浪、船舶状态或设置存档。关闭 R 面板自动恢复。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.69, 0.83, 0.85))
	body.add_child(hint)
	_audio_status_label = Label.new()
	_audio_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_audio_status_label.add_theme_font_size_override("font_size", 12)
	body.add_child(_audio_status_label)
	var presets := GridContainer.new()
	presets.columns = 2
	presets.add_theme_constant_override("h_separation", 6)
	presets.add_theme_constant_override("v_separation", 6)
	body.add_child(presets)
	_add_audio_test_preset(presets, "静水 / 熄火", {
		"relative_wind_mps": 0.0, "rain_mm_per_hour": 0.0, "sea_amplitude_rms_m": 0.3,
		"engine_running": false, "engine_power": 0.0, "heave_speed_mps": 0.0,
		"pitch_rate_rad_s": 0.0, "roll_rate_rad_s": 0.0, "storm_intensity": 0.0,
	})
	_add_audio_test_preset(presets, "平静巡航", {
		"relative_wind_mps": 5.0, "rain_mm_per_hour": 0.0, "sea_amplitude_rms_m": 0.8,
		"engine_running": true, "engine_power": 0.72, "heave_speed_mps": 0.05,
		"pitch_rate_rad_s": 0.08, "roll_rate_rad_s": 0.08, "storm_intensity": 0.0,
	})
	_add_audio_test_preset(presets, "中雨", {
		"relative_wind_mps": 8.0, "rain_mm_per_hour": 5.0, "sea_amplitude_rms_m": 1.8,
		"engine_running": true, "engine_power": 0.62, "heave_speed_mps": 0.12,
		"pitch_rate_rad_s": 0.18, "roll_rate_rad_s": 0.16, "storm_intensity": 0.0,
	})
	_add_audio_test_preset(presets, "强降雨 + 大浪", {
		"relative_wind_mps": 16.0, "rain_mm_per_hour": 22.0, "sea_amplitude_rms_m": 4.0,
		"engine_running": true, "engine_power": 0.72, "heave_speed_mps": 0.4,
		"pitch_rate_rad_s": 0.55, "roll_rate_rad_s": 0.5, "storm_intensity": 0.0,
	})
	_add_audio_test_preset(presets, "强雷暴", {
		"relative_wind_mps": 15.0, "rain_mm_per_hour": 22.0, "sea_amplitude_rms_m": 4.0,
		"engine_running": true, "engine_power": 0.62, "heave_speed_mps": 0.4,
		"pitch_rate_rad_s": 0.35, "roll_rate_rad_s": 0.3, "storm_intensity": 0.8,
	})
	var restore_audio := Button.new()
	restore_audio.text = "恢复正式音效输入"
	restore_audio.pressed.connect(_clear_audio_debug_override)
	body.add_child(restore_audio)
	_refresh_audio_status()


func _add_audio_test_preset(parent: GridContainer, label: String, values: Dictionary) -> void:
	var button := Button.new()
	button.text = label
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(func(): _apply_audio_debug_override(values))
	parent.add_child(button)


func _apply_audio_debug_override(values: Dictionary) -> void:
	if _environment_audio_manager != null and _environment_audio_manager.has_method("set_debug_audio_override"):
		_environment_audio_manager.call("set_debug_audio_override", values)
	if _boat_audio_controller != null and _boat_audio_controller.has_method("set_debug_audio_override"):
		_boat_audio_controller.call("set_debug_audio_override", values)
	_refresh_audio_status()


func _clear_audio_debug_override() -> void:
	if _environment_audio_manager != null and _environment_audio_manager.has_method("clear_debug_audio_override"):
		_environment_audio_manager.call("clear_debug_audio_override")
	if _boat_audio_controller != null and _boat_audio_controller.has_method("clear_debug_audio_override"):
		_boat_audio_controller.call("clear_debug_audio_override")
	_refresh_audio_status()


func _refresh_audio_status() -> void:
	if _audio_status_label == null:
		return
	if _environment_audio_manager == null or not _environment_audio_manager.has_method("get_audio_diagnostics"):
		_audio_status_label.text = "音效诊断不可用。"
		return
	var environment: Dictionary = _environment_audio_manager.call("get_audio_diagnostics")
	var boat: Dictionary = _boat_audio_controller.call("get_audio_diagnostics") if _boat_audio_controller != null and _boat_audio_controller.has_method("get_audio_diagnostics") else {}
	var targets: Dictionary = environment.get("target_loop_gains", {})
	var actuals: Dictionary = environment.get("actual_loop_gains", {})
	var boat_targets: Dictionary = boat.get("target_loop_gains", {})
	var boat_actuals: Dictionary = boat.get("actual_loop_gains", {})
	var override_label := "本地音效覆盖" if bool(environment.get("audio_test_override_active", false)) else "正式天气 / 运行状态"
	_audio_status_label.text = "%s · 风 %.1f m/s · 雨 %.1f mm/h · 海况 RMS %.2f m · duck %.1f dB\n目标 W01 %.0f%% W02 %.0f%% R02 %.0f%% R03 %.0f%% SW01 %.0f%% SW02 %.0f%% SW03 %.0f%%\n实际 W01 %.0f%% W02 %.0f%% R02 %.0f%% R03 %.0f%% SW01 %.0f%% SW02 %.0f%% SW03 %.0f%% · 引擎 %.0f%% / %.0f%%" % [
		override_label,
		float(environment.get("relative_wind_mps", 0.0)),
		float(environment.get("rain_mm_per_hour", 0.0)),
		float(environment.get("sea_amplitude_rms_m", 0.0)),
		float(environment.get("music_ducking_db", 0.0)),
		float(targets.get("W01", 0.0)) * 100.0,
		float(targets.get("W02", 0.0)) * 100.0,
		float(targets.get("R02", 0.0)) * 100.0,
		float(targets.get("R03", 0.0)) * 100.0,
		float(targets.get("SW01", 0.0)) * 100.0,
		float(targets.get("SW02", 0.0)) * 100.0,
		float(targets.get("SW03", 0.0)) * 100.0,
		float(actuals.get("W01", 0.0)) * 100.0,
		float(actuals.get("W02", 0.0)) * 100.0,
		float(actuals.get("R02", 0.0)) * 100.0,
		float(actuals.get("R03", 0.0)) * 100.0,
		float(actuals.get("SW01", 0.0)) * 100.0,
		float(actuals.get("SW02", 0.0)) * 100.0,
		float(actuals.get("SW03", 0.0)) * 100.0,
		float(boat_targets.get("engine", 0.0)) * 100.0,
		float(boat_actuals.get("engine", 0.0)) * 100.0,
	]
	_audio_status_label.text += "\n船体 S01 %.0f%% / %.0f%% · S02 %.0f%% / %.0f%%" % [
		float(boat_targets.get("S01", 0.0)) * 100.0,
		float(boat_actuals.get("S01", 0.0)) * 100.0,
		float(boat_targets.get("S02", 0.0)) * 100.0,
		float(boat_actuals.get("S02", 0.0)) * 100.0,
	]


func _add_event_button(parent: GridContainer, label: String, event_type: String) -> void:
	var button := Button.new()
	button.text = label
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(func():
		if _lightning_controller != null:
			_lightning_controller.call("trigger_debug_event", event_type)
		_refresh_thunder_status()
	)
	parent.add_child(button)


func _add_slider(parent: VBoxContainer, title_text: String, minimum: float, maximum: float, initial: float, step: float) -> HSlider:
	var wrapper := VBoxContainer.new()
	parent.add_child(wrapper)
	var label := Label.new()
	label.text = title_text
	label.add_theme_font_size_override("font_size", 13)
	wrapper.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_child(slider)
	return slider


func _add_labeled_control(parent: VBoxContainer, title_text: String, control: Control) -> void:
	var wrapper := VBoxContainer.new()
	parent.add_child(wrapper)
	var label := Label.new()
	label.text = title_text
	label.add_theme_font_size_override("font_size", 13)
	wrapper.add_child(label)
	wrapper.add_child(control)


func _set_panel_open(open: bool) -> void:
	if visible == open:
		return
	visible = open
	if not open:
		_clear_debug_override()
		_clear_thunder_debug_override()
		_clear_audio_debug_override()
	else:
		_refresh_status()
		_refresh_audio_status()


func _set_debug_rate(rate_mm_per_hour: float) -> void:
	if _rate_slider != null:
		_rate_slider.value = rate_mm_per_hour
	if _rain_controller != null:
		_rain_controller.call("set_debug_override", rate_mm_per_hour)
	_refresh_status()


func _on_rate_changed(value: float) -> void:
	if _syncing_controls or _rain_controller == null:
		return
	_rain_controller.call("set_debug_override", value)


func _clear_debug_override() -> void:
	if _rain_controller != null:
		_rain_controller.call("clear_debug_override")
	_refresh_status()


func _on_thunder_override_toggled(enabled: bool) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_debug_override", enabled, _thunder_intensity_slider.value)
	_refresh_thunder_status()


func _on_thunder_intensity_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	if _thunder_override_toggle.button_pressed:
		_lightning_controller.call("set_debug_override", true, value)
	_refresh_thunder_status()


func _on_thunder_frequency_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_frequency_multiplier", value)
	_refresh_thunder_status()


func _on_thunder_flash_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_flash_sensitivity", value)


func _on_thunder_cloud_flash_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_cloud_flash_multiplier", value)


func _on_thunder_environment_flash_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_environment_flash_multiplier", value)


func _on_thunder_distance_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_distance_multiplier", value)
	_refresh_thunder_status()


func _on_thunder_width_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_bolt_width_multiplier", value)
	_refresh_thunder_status()


func _on_thunder_curve_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_bolt_curve_multiplier", value)
	_refresh_thunder_status()


func _on_thunder_primary_density_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_primary_branch_density_multiplier", value)
	_refresh_thunder_status()


func _on_thunder_secondary_density_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_secondary_branch_density_multiplier", value)
	_refresh_thunder_status()


func _on_thunder_glow_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_glow_multiplier", value)
	_refresh_thunder_status()


func _on_thunder_seed_changed(value: float) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_debug_visual_seed", int(value))
	_refresh_thunder_status()


func _on_thunder_freeze_toggled(enabled: bool) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_preview_frozen", enabled)
	_refresh_thunder_status()


func _on_reduce_flashes_toggled(enabled: bool) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_reduce_flashes", enabled)


func _on_thunder_quality_selected(index: int) -> void:
	if _syncing_controls or _lightning_controller == null:
		return
	_lightning_controller.call("set_quality_level", _thunder_quality_option.get_item_id(index))


func _clear_thunder_debug_override() -> void:
	if _lightning_controller != null:
		_lightning_controller.call("clear_debug_override")
	if _thunder_override_toggle != null:
		_syncing_controls = true
		_thunder_override_toggle.button_pressed = false
		_syncing_controls = false
	_refresh_thunder_status()


func _on_quality_selected(index: int) -> void:
	if _syncing_controls or _rain_controller == null:
		return
	_rain_controller.call("set_quality_level", _quality_option.get_item_id(index))


func _on_visual_control_changed(_value: float) -> void:
	if _syncing_controls or _rain_controller == null:
		return
	_rain_controller.call("set_debug_controls", {
		"streak_density_multiplier": _density_slider.value,
		"near_streak_multiplier": _near_density_slider.value,
		"streak_length_meters": _length_slider.value,
		"streak_opacity": _opacity_slider.value,
		"wind_tilt_influence": _wind_slider.value,
		"micro_impact_density_multiplier": _micro_slider.value,
		"ring_size_multiplier": _ring_size_slider.value,
		"ring_probability_multiplier": _ring_probability_slider.value,
		"sea_impact_multiplier": _impact_slider.value,
		"haze_multiplier": _haze_slider.value,
		"quality_level": _quality_option.get_selected_id(),
	})


func _refresh_status() -> void:
	if _status_label == null:
		return
	if _rain_controller == null:
		_status_label.text = "RainVisualController 不可用。"
		return
	var state: Dictionary = _rain_controller.call("get_diagnostic_state")
	var source := "有正式降水数据" if bool(state.get("formal_rate_available", false)) else "正式降水量 N/A（视觉按无雨处理）"
	var mode := "本地视觉覆盖" if bool(state.get("debug_override_active", false)) else "正式天气驱动"
	_status_label.text = "%s · %s\n正式雨量：%.2f mm/h · %s\n当前视觉雨量：%.2f mm/h · %s\n质量：%s · GPU 粒子预算：%d / %d" % [
		mode,
		str(state.get("formal_data_quality", "unavailable")),
		float(state.get("formal_rate_mm_per_hour", 0.0)),
		source,
		float(state.get("visual_rate_mm_per_hour", 0.0)),
		str(state.get("operating_mode", "")),
		str(state.get("quality", "Medium")),
		int(state.get("particle_count", 0)),
		int(state.get("particle_count_budget", 0)),
	]
	_status_label.text += "\n中景 %.2f · 近景 %.2f · 水面微粒 %.2f · 圆环 %.0f%%" % [
		float(state.get("mid_streak_density", 0.0)),
		float(state.get("near_streak_density", 0.0)),
		float(state.get("micro_impact_density", 0.0)),
		float(state.get("ring_probability", 0.0)) * 100.0,
	]
	_status_label.text += "\n海面 Shader 实收：微撞击 %.2f · 单元 %.2f m · 强度 %.2f · 圆环 %.2f" % [
		float(state.get("surface_micro_density", 0.0)),
		float(state.get("surface_micro_cell_size", 0.0)),
		float(state.get("surface_impact_strength", 0.0)),
		float(state.get("surface_ring_density", 0.0)),
	]
	_sync_controls_from_controller()
	_refresh_thunder_status()


func _refresh_thunder_status() -> void:
	if _thunder_status_label == null:
		return
	if _lightning_controller == null:
		_thunder_status_label.text = "LightningEventController 不可用。"
		return
	var state: Dictionary = _lightning_controller.call("get_diagnostic_state")
	var source := "本地测试覆盖" if bool(state.get("debug_override_active", false)) else "正式天气"
	var signal_text := "雷暴信号" if bool(state.get("formal_signal", false)) else "无正式雷暴信号"
	var geometry: Dictionary = state.get("geometry", {})
	var frozen_text := " · 冻结预览" if bool(state.get("preview_frozen", false)) else ""
	_thunder_status_label.text = "%s · %s · %.2f · %s\n闪电：%s%s · 下一事件约 %.0f 秒 · 临时灯 %d\n最近几何：主干+%d 一级/%d 二级 · %d 顶点 · 主干核心半径 %.1f m" % [
		source,
		signal_text,
		float(state.get("effective_intensity", 0.0)),
		str(state.get("formal_data_quality", "unavailable")),
		str(state.get("active_event_type", "none")),
		frozen_text,
		float(state.get("next_event_in_seconds", 0.0)),
		int(state.get("temporary_light_count", 0)),
		int(geometry.get("primary_branch_count", 0)),
		int(geometry.get("secondary_branch_count", 0)),
		int(geometry.get("vertex_count", 0)),
		float(geometry.get("core_radius_m", 0.0)),
	]
	if _syncing_controls or _thunder_override_toggle == null:
		return
	_syncing_controls = true
	_thunder_override_toggle.button_pressed = bool(state.get("debug_override_active", false))
	_thunder_intensity_slider.value = float(state.get("debug_intensity", 0.55))
	_thunder_frequency_slider.value = float(_lightning_controller.get("frequency_multiplier"))
	_thunder_flash_slider.value = float(_lightning_controller.get("flash_sensitivity"))
	_thunder_cloud_flash_slider.value = float(_lightning_controller.get("cloud_flash_multiplier"))
	_thunder_environment_flash_slider.value = float(_lightning_controller.get("environment_flash_multiplier"))
	_thunder_distance_slider.value = float(_lightning_controller.get("distance_multiplier"))
	_thunder_width_slider.value = float(_lightning_controller.get("bolt_width_multiplier"))
	_thunder_curve_slider.value = float(_lightning_controller.get("bolt_curve_multiplier"))
	_thunder_primary_density_slider.value = float(_lightning_controller.get("primary_branch_density_multiplier"))
	_thunder_secondary_density_slider.value = float(_lightning_controller.get("secondary_branch_density_multiplier"))
	_thunder_glow_slider.value = float(_lightning_controller.get("glow_multiplier"))
	_thunder_seed_spin.value = float(state.get("debug_visual_seed", 629104))
	_reduce_flashes_toggle.button_pressed = bool(state.get("reduce_flashes", false))
	_thunder_freeze_toggle.button_pressed = bool(state.get("preview_frozen", false))
	for index in range(_thunder_quality_option.item_count):
		if _thunder_quality_option.get_item_id(index) == int(_lightning_controller.get("quality_level")):
			_thunder_quality_option.select(index)
			break
	_syncing_controls = false


func _sync_controls_from_controller() -> void:
	if _rain_controller == null or _quality_option == null:
		return
	_syncing_controls = true
	if _rate_slider != null and not bool(_rain_controller.call("is_debug_override_active")):
		_rate_slider.value = float(state_rate_or_formal(_rain_controller))
	for index in range(_quality_option.item_count):
		if _quality_option.get_item_id(index) == int(_rain_controller.get("quality_level")):
			_quality_option.select(index)
			break
	_density_slider.value = float(_rain_controller.get("streak_density_multiplier"))
	_near_density_slider.value = float(_rain_controller.get("near_streak_multiplier"))
	_length_slider.value = float(_rain_controller.get("streak_length_meters"))
	_opacity_slider.value = float(_rain_controller.get("streak_opacity"))
	_wind_slider.value = float(_rain_controller.get("wind_tilt_influence"))
	_micro_slider.value = float(_rain_controller.get("micro_impact_density_multiplier"))
	_ring_size_slider.value = float(_rain_controller.get("ring_size_multiplier"))
	_ring_probability_slider.value = float(_rain_controller.get("ring_probability_multiplier"))
	_impact_slider.value = float(_rain_controller.get("sea_impact_multiplier"))
	_haze_slider.value = float(_rain_controller.get("haze_multiplier"))
	_syncing_controls = false


func state_rate_or_formal(controller: Node) -> float:
	var diagnostic: Dictionary = controller.call("get_diagnostic_state")
	return float(diagnostic.get("formal_rate_mm_per_hour", 0.0))
