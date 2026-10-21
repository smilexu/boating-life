extends CanvasLayer
class_name WeatherRuntimePreviewPanel

## Read-only developer panel for inspecting the active authoritative timeline.
## Ctrl+Shift+F12 is intentionally distinct from the F12 wind override panel.

@export_node_path("Node") var authority_path := NodePath("../WeatherRuntimeAuthority")
@export_node_path("Node") var state_controller_path := NodePath("../WeatherStateController")
@export var show_in_debug_builds := true

var _authority: Node
var _state_controller: Node
var _panel: PanelContainer
var _range_label: Label
var _selected_offset: SpinBox
var _current_details: Label
var _preview_details: Label
var _source_details: Label
var _refresh_elapsed := 0.0
var _has_selected_offset := false


func _ready() -> void:
	layer = 34
	_authority = get_node_or_null(authority_path)
	_state_controller = get_node_or_null(state_controller_path)
	_build_ui()
	visible = false
	set_process(show_in_debug_builds and OS.is_debug_build())


func _unhandled_key_input(event: InputEvent) -> void:
	if not show_in_debug_builds or not OS.is_debug_build():
		return
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.physical_keycode != KEY_F12 or not event.ctrl_pressed or not event.shift_pressed or event.alt_pressed or event.meta_pressed:
		return
	visible = not visible
	if visible:
		_refresh_panel()
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_elapsed += delta
	if _refresh_elapsed < 0.25:
		return
	_refresh_elapsed = 0.0
	_refresh_panel()


func set_preview_offset_for_testing(cycle_offset: float) -> void:
	if _selected_offset != null:
		_has_selected_offset = true
		_selected_offset.set_value_no_signal(cycle_offset)
		_refresh_panel()


func get_preview_details_for_testing() -> String:
	return _preview_details.text if _preview_details != null else ""


func is_panel_open() -> bool:
	return visible


func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.name = "WeatherRuntimePreview"
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_panel.offset_left = 22.0
	_panel.offset_top = 190.0
	_panel.offset_right = 742.0
	_panel.offset_bottom = 650.0
	_panel.custom_minimum_size = Vector2(620.0, 0.0)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.025, 0.065, 0.085, 0.96)
	panel_style.border_color = Color(0.26, 0.57, 0.63, 0.92)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 14.0
	panel_style.content_margin_right = 14.0
	panel_style.content_margin_top = 12.0
	panel_style.content_margin_bottom = 12.0
	_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.name = "PreviewScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)

	var title := Label.new()
	title.text = "天气时间线预览 · Ctrl+Shift+F12"
	title.add_theme_font_size_override("font_size", 19)
	title.add_theme_color_override("font_color", Color(0.90, 0.97, 0.98))
	content.add_child(title)
	_source_details = _make_label("数据源 · --", 13, Color(0.67, 0.84, 0.86))
	content.add_child(_source_details)

	var selection := HBoxContainer.new()
	selection.add_theme_constant_override("separation", 10)
	content.add_child(selection)
	_range_label = _make_label("日轮偏移", 14, Color(0.82, 0.92, 0.93))
	selection.add_child(_range_label)
	_selected_offset = SpinBox.new()
	_selected_offset.min_value = 0.0
	_selected_offset.max_value = 1.0
	_selected_offset.step = 0.25
	_selected_offset.custom_minimum_size = Vector2(110.0, 34.0)
	_selected_offset.value_changed.connect(_on_offset_changed)
	selection.add_child(_selected_offset)
	var current_button := Button.new()
	current_button.text = "定位当前权威游标"
	current_button.pressed.connect(_select_current_cursor)
	selection.add_child(current_button)

	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 10)
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(cards)
	_current_details = _make_card(cards, "当前正式天气")
	_preview_details = _make_card(cards, "所选日轮预览")
	var note := _make_label("只读预览：不会改变游戏时间、正式天气、风场、存档，也不会请求网络。", 12, Color(0.58, 0.75, 0.78))
	content.add_child(note)


func _make_card(parent: Control, heading: String) -> Label:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.045, 0.11, 0.13, 0.95)
	style.border_color = Color(0.16, 0.34, 0.37, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 9.0
	style.content_margin_bottom = 9.0
	card.add_theme_stylebox_override("panel", style)
	parent.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	card.add_child(box)
	var heading_label := _make_label(heading, 15, Color(0.79, 0.93, 0.92))
	box.add_child(heading_label)
	var details := _make_label("等待天气时间线…", 13, Color(0.86, 0.93, 0.94))
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(details)
	return details


func _make_label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _refresh_panel() -> void:
	if _authority == null or _range_label == null:
		return
	var range_data: Dictionary = _authority.call("get_timeline_range")
	if not bool(range_data.get("available", false)):
		_range_label.text = "日轮偏移 · 暂无可用时间线"
		_source_details.text = "状态：%s · %s" % [str(_authority.get("mapping_status")), str(_authority.get("provider_status"))]
		_current_details.text = _format_weather(_authority.get("current_sample"), -1.0, "当前正式天气")
		_preview_details.text = "当前暂无可预览的天气时间线。"
		return
	var range_start := float(range_data.get("start_cycle_offset", 0.0))
	var range_end := float(range_data.get("end_cycle_offset", 0.0))
	var cycles_per_day := int(range_data.get("cycles_per_real_day", 24))
	_selected_offset.min_value = range_start
	_selected_offset.max_value = maxf(range_start, range_end)
	if not _has_selected_offset:
		var current_offset := float(_authority.call("get_current_timeline_cycle_offset"))
		_selected_offset.set_value_no_signal(clampf(current_offset, range_start, range_end))
		_has_selected_offset = true
	elif _selected_offset.value < range_start or _selected_offset.value > range_end:
		_selected_offset.set_value_no_signal(clampf(float(_authority.call("get_current_timeline_cycle_offset")), range_start, range_end))
	var metadata: Dictionary = _authority.call("get_timeline_metadata")
	var preview_offset := _selected_offset.value
	var day_number := int(floor(preview_offset / float(maxi(cycles_per_day, 1)))) + 1
	var in_day := fposmod(preview_offset, float(maxi(cycles_per_day, 1))) / float(maxi(cycles_per_day, 1))
	_range_label.text = "日轮偏移：第 %d 个游戏日轮 · 日内 %.0f%% · 覆盖余量 %.2f 日轮" % [day_number, in_day * 100.0, float(metadata.get("remaining_coverage_cycles", 0.0))]
	_source_details.text = "区域 %s · 来源 %s · 质量 %s · 映射 %s\n预报发布时间 %s · 时间线 %s\n下次刷新：%s · 最近滚动：%s %s" % [
		str(_authority.get("region_id")), str(_authority.get("data_source_status")), str(_authority.get("forecast_data_quality")),
		str(_authority.get("mapping_status")), str(metadata.get("forecast_issued_at_utc", "N/A")), str(metadata.get("timeline_version", "N/A")),
		str(_authority.get("next_refresh_status")), str(_authority.get("last_rollover_reason")), str(_authority.get("last_rollover_utc")),
	]
	var current_state: Dictionary = _authority.get("current_sample")
	_current_details.text = _format_weather(current_state, float(_authority.call("get_current_timeline_cycle_offset")), "当前正式天气")
	var preview: Dictionary = _authority.call("get_preview_weather_at_cycle_offset", preview_offset)
	if bool(preview.get("ok", false)):
		_preview_details.text = _format_weather(preview.get("state", {}), preview_offset, "所选日轮预览")
	else:
		_preview_details.text = "该位置无可用预报：%s" % str(preview.get("error", "unknown"))


func _format_weather(state_value: Variant, offset: float, heading: String) -> String:
	if not state_value is Dictionary or state_value.is_empty():
		return "%s\n当前没有天气样本。" % heading
	var state: Dictionary = state_value
	var wind := "N/A"
	if state.has("mean_wind_speed_mps"):
		wind = "%.1f m/s · %.0f° 来向" % [float(state["mean_wind_speed_mps"]), float(state.get("wind_from_direction_deg", 0.0))]
	var gust := "N/A"
	var gust_target: Variant = state.get("gust_target", {})
	if gust_target is Dictionary and gust_target.has("gust_strength_mps"):
		gust = "%.1f m/s" % float(gust_target["gust_strength_mps"])
	var rain := "N/A"
	if state.has("precipitation_intensity_mm_per_hour"):
		rain = "%.2f mm/h (%s)" % [float(state["precipitation_intensity_mm_per_hour"]), str(state.get("precipitation_state", "unknown"))]
	return "%s · %s\n%s\n阵风目标 %s · 云量 %s\n降水 %s\n气温 %s °C · 气压 %s hPa\n有效时刻 %s\n数据质量 %s" % [
		heading, str(state.get("weather_type", state.get("visual_weather_id", "Unknown"))), wind, gust,
		"%.0f%%" % (float(state["cloud_fraction"]) * 100.0) if state.has("cloud_fraction") else "N/A", rain,
		"%.1f" % float(state["air_temperature_c"]) if state.has("air_temperature_c") else "N/A",
		"%.0f" % float(state["air_pressure_hpa"]) if state.has("air_pressure_hpa") else "N/A",
		str(state.get("valid_time_utc", "N/A")), str(state.get("data_quality", "unavailable")),
	]


func _select_current_cursor() -> void:
	if _authority == null:
		return
	var current_offset := float(_authority.call("get_current_timeline_cycle_offset"))
	if current_offset >= 0.0:
		_has_selected_offset = true
		_selected_offset.set_value_no_signal(current_offset)
		_refresh_panel()


func _on_offset_changed(_value: float) -> void:
	_has_selected_offset = true
	_refresh_panel()
