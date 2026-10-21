extends CanvasLayer
class_name RainVisualDebugPanel

## Local-only rain presentation tools. R toggles this panel.
## Closing the panel always clears the rain override and resumes formal input.

@export_node_path("Node") var rain_visual_controller_path := NodePath("../RainVisualController")
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
var _refresh_elapsed := 0.0
var _syncing_controls := false


func _ready() -> void:
	layer = 70
	_rain_controller = get_node_or_null(rain_visual_controller_path)
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
	_refresh_status()


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
	else:
		_refresh_status()


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
