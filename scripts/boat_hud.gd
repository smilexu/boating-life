extends CanvasLayer

## Small status display for the boat prototype. Speed is stored in m/s and
## converted to knots only for display (1 m/s = 1.94384 kn).

const COMPASS_HUD_SCRIPT := preload("res://scripts/compass_hud.gd")
const LocalTimeControlScript := preload("res://scripts/local_world_time_control.gd")
const MoonPositionScript := preload("res://scripts/moon_position.gd")
const SolarPositionScript := preload("res://scripts/solar_position.gd")
const ExtremeSeaStatePresetsScript := preload("res://scripts/extreme_sea_state_presets.gd")
const TIME_SCALE_PRESETS := [1.0, 6.0, 12.0, 24.0, 60.0]

@export_node_path("Node3D") var controller_path := NodePath("../MotionRoot")
@export_node_path("Node") var weather_controller_path := NodePath("../../WeatherController")
@export_node_path("Node") var day_night_visual_controller_path := NodePath("../../DayNightVisualController")
@export_node_path("Node") var wave_sampler_path := NodePath("../../WaveSampler")
@export_node_path("Node") var quality_manager_path := NodePath("../../QualityManager")
@export_node_path("Node") var fish_resource_manager_path := NodePath("../../FishResourceManager")
@export_node_path("Node3D") var fish_school_renderer_path := NodePath("../../FishResourceManager/FishSchoolRenderer")
@export_node_path("Node") var dolphin_world_manager_path := NodePath("../../DolphinWorldManager")
@export_node_path("Node") var navigation_depth_monitor_path := NodePath("../../NavigationDepthMonitor")
@export_node_path("Node") var cargo_economy_manager_path := NodePath("../../CargoEconomyManager")
@export_node_path("Node") var autopilot_controller_path := NodePath("../../AutopilotController")
@export_node_path("Node") var oresund_region_path := NodePath("../../OresundRegion")

var _controller: BoatController
var _weather_controller: Node
var _day_night_visual_controller: Node
var _wave_sampler: Node
var _quality_manager: Node
var _fish_resource_manager: FishResourceManager
var _fish_school_renderer: FishSchoolRenderer
var _dolphin_world_manager: Node
var _navigation_depth_monitor: NavigationDepthMonitor
var _cargo_economy_manager: CargoEconomyManager
var _autopilot_controller: AutopilotController
var _oresund_region: Node
var _selected_fish_school_id := ""
var _world_time_control: WorldTimeControlPort
var _status_panel: PanelContainer
var _status_label: Label
var _fps_label: Label
var _depth_label: Label
var _cargo_task_label: Label
var _debug_panel: PanelContainer
var _debug_scroll: ScrollContainer
var _debug_layout: VBoxContainer
var _weather_label: Label
var _sun_label: Label
var _moon_label: Label
var _cloud_label: Label
var _wave_label: Label
var _performance_label: Label
var _fish_location_feedback: Label
var _fish_motion_toggle: CheckButton
var _fish_motion_status: Label
var _fish_observation_status: Label
var _dolphin_status: Label
var _world_time_label: Label
var _world_time_feedback: Label
var _sun_elevation_slider: HSlider
var _sun_azimuth_slider: HSlider
var _cloud_slider: HSlider
var _wave_slider: HSlider
var _extreme_sea_option: OptionButton
var _extreme_sea_status: Label
var _wave_compactness_slider: HSlider
var _wave_sharpness_slider: HSlider
var _extreme_wave_defaults_button: Button
var _shallow_wave_constraint_toggle: CheckButton
var _shallow_wave_full_depth_slider: HSlider
var _shallow_wave_min_scale_slider: HSlider
var _shallow_wave_safe_ratio_slider: HSlider
var _shallow_wave_defaults_button: Button
var _shallow_wave_status: Label
var _quality_option: OptionButton
var _frame_limit_option: OptionButton
var _window_mode_button: Button
var _cycle_hour_spin: SpinBox
var _cycle_minute_spin: SpinBox
var _time_scale_option: OptionButton
var _time_pause_toggle: CheckButton
var _calendar_year_spin: SpinBox
var _calendar_month_spin: SpinBox
var _calendar_day_spin: SpinBox
var _time_admin_controls: Array[Control] = []
var _has_custom_time_scale_item := false
var _custom_time_scale_value := -1.0
var _clouds_toggle: CheckButton
var _fps_elapsed := 0.0
var _runtime_elapsed := 0.0
var _debug_refresh_elapsed := 0.0
var _autopilot_refresh_elapsed := 0.0
var _autopilot_panel: PanelContainer
var _autopilot_label: Label
var _peberholm_debug_button: Button
var _peberholm_debug_feedback: Label


func _ready() -> void:
	_controller = get_node_or_null(controller_path) as BoatController
	if _controller == null:
		push_error("Boat HUD could not find its controller at %s." % controller_path)
		return
	_weather_controller = get_node_or_null(weather_controller_path)
	_day_night_visual_controller = get_node_or_null(day_night_visual_controller_path)
	_wave_sampler = get_node_or_null(wave_sampler_path)
	_quality_manager = get_node_or_null(quality_manager_path)
	_fish_resource_manager = get_node_or_null(fish_resource_manager_path) as FishResourceManager
	_fish_school_renderer = get_node_or_null(fish_school_renderer_path) as FishSchoolRenderer
	_dolphin_world_manager = get_node_or_null(dolphin_world_manager_path)
	_navigation_depth_monitor = get_node_or_null(navigation_depth_monitor_path) as NavigationDepthMonitor
	_cargo_economy_manager = get_node_or_null(cargo_economy_manager_path) as CargoEconomyManager
	_autopilot_controller = get_node_or_null(autopilot_controller_path) as AutopilotController
	_oresund_region = get_node_or_null(oresund_region_path)
	var time_manager := get_node_or_null("/root/WorldTimeManager")
	_world_time_control = LocalTimeControlScript.new(time_manager) as WorldTimeControlPort

	_status_panel = PanelContainer.new()
	_status_panel.position = Vector2(24.0, 24.0)
	_status_panel.custom_minimum_size = Vector2(470.0, 170.0)
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
	_depth_label = Label.new()
	_depth_label.name = "ReferenceDepthStatus"
	_depth_label.add_theme_color_override("font_color", Color(0.82, 0.93, 0.92, 1.0))
	_depth_label.add_theme_font_size_override("font_size", 14)
	_depth_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_layout.add_child(_depth_label)
	_cargo_task_label = Label.new()
	_cargo_task_label.name = "CargoTaskStatus"
	_cargo_task_label.add_theme_color_override("font_color", Color(0.84, 0.88, 0.77, 1.0))
	_cargo_task_label.add_theme_font_size_override("font_size", 14)
	_cargo_task_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_layout.add_child(_cargo_task_label)
	add_child(_status_panel)
	_build_autopilot_panel()
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
	_autopilot_refresh_elapsed += delta
	if _autopilot_refresh_elapsed >= 0.2:
		_autopilot_refresh_elapsed = fmod(_autopilot_refresh_elapsed, 0.2)
		_update_autopilot_panel()
	if _debug_panel != null and _debug_panel.visible:
		_debug_refresh_elapsed += delta
		if _debug_refresh_elapsed >= 0.5:
			_debug_refresh_elapsed = fmod(_debug_refresh_elapsed, 0.5)
			_update_debug_status()


func _build_autopilot_panel() -> void:
	_autopilot_panel = PanelContainer.new()
	_autopilot_panel.name = "AutopilotStatusPanel"
	_autopilot_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_autopilot_panel.offset_left = -420.0
	_autopilot_panel.offset_top = 24.0
	_autopilot_panel.offset_right = -24.0
	_autopilot_panel.offset_bottom = 170.0
	_autopilot_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.12, 0.16, 0.84)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	_autopilot_panel.add_theme_stylebox_override("panel", style)
	var layout := VBoxContainer.new()
	_autopilot_panel.add_child(layout)
	_autopilot_label = Label.new()
	_autopilot_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_autopilot_label.add_theme_color_override("font_color", Color("#e6f1e8"))
	layout.add_child(_autopilot_label)
	var takeover := Button.new()
	takeover.name = "ManualTakeoverButton"
	takeover.text = "手动接管 · T"
	takeover.pressed.connect(_on_manual_takeover_pressed)
	layout.add_child(takeover)
	add_child(_autopilot_panel)
	_update_autopilot_panel()


func _update_autopilot_panel() -> void:
	if _autopilot_panel == null or _autopilot_controller == null:
		return
	var snapshot := _autopilot_controller.get_status_snapshot()
	var state := str(snapshot.get("state", AutopilotController.STATE_IDLE))
	var active := _controller != null and _controller.is_autopilot
	var message_age := float(snapshot.get("message_age_seconds", INF))
	_autopilot_panel.visible = active or state == AutopilotController.STATE_COMPLETED or (message_age < 4.0 and not str(snapshot.get("message", "")).is_empty())
	if not _autopilot_panel.visible:
		return
	if not active and state != AutopilotController.STATE_COMPLETED:
		_autopilot_label.text = str(snapshot.get("message", ""))
		return
	var state_text: String = {
		AutopilotController.STATE_ACQUIRING: "接入航线",
		AutopilotController.STATE_CRUISING: "自动巡航中",
		AutopilotController.STATE_APPROACHING: "接近港外等待点",
		AutopilotController.STATE_SAFETY_HOLD: "水深/偏航保护",
		AutopilotController.STATE_COMPLETED: "已到达 · 手动进港",
	}.get(state, "自动巡航")
	var origin := _cargo_economy_manager.get_port_display_name(str(snapshot.get("origin_port_id", ""))) if _cargo_economy_manager != null else str(snapshot.get("origin_port_id", ""))
	var destination := _cargo_economy_manager.get_port_display_name(str(snapshot.get("destination_port_id", ""))) if _cargo_economy_manager != null else str(snapshot.get("destination_port_id", ""))
	var eta_seconds := float(snapshot.get("eta_seconds", -1.0))
	var eta_minutes := int(round(eta_seconds / 60.0)) if eta_seconds >= 0.0 else -1
	var eta_text := "%d h %02d min" % [int(eta_minutes / 60), eta_minutes % 60] if eta_minutes >= 60 else "%d min" % eta_minutes if eta_minutes >= 0 else "未知"
	var cruise_adjustment_hint := " · + / - 临时调速" if OS.has_feature("editor") or OS.has_feature("debug") else ""
	var route_notice := str(snapshot.get("safety_hold_reason", ""))
	if route_notice.is_empty():
		route_notice = str(snapshot.get("depth_notice", ""))
	_autopilot_label.text = "%s  ·  %s\n%s → %s\n目标：%s  ·  航段 %d/%d\n进度 %.0f%%  ·  剩余 %.1f km\n航速 %.1f / 目标 %.1f m/s%s  ·  预计 %s%s" % [
		state_text, str(snapshot.get("route_name", "")), origin, destination,
		str(snapshot.get("target_waypoint", "等待点")), int(snapshot.get("segment_index", 0)), int(snapshot.get("segment_count", 0)),
		float(snapshot.get("progress_fraction", 0.0)) * 100.0, float(snapshot.get("remaining_m", 0.0)) / 1000.0,
		float(snapshot.get("actual_speed_mps", 0.0)), float(snapshot.get("target_speed_mps", 0.0)), cruise_adjustment_hint, eta_text,
		"\n" + route_notice if not route_notice.is_empty() else "",
	]


func _on_manual_takeover_pressed() -> void:
	if _autopilot_controller != null:
		_autopilot_controller.request_manual_takeover()
		_update_autopilot_panel()


func _on_peberholm_debug_button_pressed() -> void:
	if not is_instance_valid(_oresund_region) or not _oresund_region.has_method("toggle_peberholm_render_debug"):
		_peberholm_debug_feedback.text = "找不到 Peberholm 诊断控制器。"
		return
	var was_enabled := bool(_oresund_region.call("is_peberholm_render_debug_enabled"))
	var enabled := bool(_oresund_region.call("toggle_peberholm_render_debug"))
	_sync_peberholm_debug_control()
	if enabled:
		_peberholm_debug_feedback.text = "诊断已开启：绿色为岛顶，红色为岸坡。"
	elif was_enabled:
		_peberholm_debug_feedback.text = "诊断已关闭，原始地形显示已恢复。"
	else:
		_peberholm_debug_feedback.text = "未能开启诊断，请查看运行日志。"


func _sync_peberholm_debug_control() -> void:
	if not is_instance_valid(_oresund_region):
		return
	if _peberholm_debug_button != null and _oresund_region.has_method("is_peberholm_render_debug_enabled"):
		var debug_enabled := bool(_oresund_region.call("is_peberholm_render_debug_enabled"))
		_peberholm_debug_button.text = "关闭顶面 / 岸坡颜色诊断" if debug_enabled else "开启顶面 / 岸坡颜色诊断"


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F3:
		_debug_panel.visible = not _debug_panel.visible
		if _debug_panel.visible:
			_update_debug_status()
			_sync_peberholm_debug_control()
		get_viewport().set_input_as_handled()


func _update_status() -> void:
	if _controller == null:
		return
	var knots := _controller.speed_mps * 1.94384
	var mode_text := "自动巡航" if _controller.is_autopilot else "手动驾驶"
	if _controller.is_motion_paused:
		mode_text += " · 已暂停"
	_status_label.text = "航速  %.1f m/s  ·  %.1f kn\n模式  %s\nW 前进  ·  S 减速/倒车  ·  A/D 转向  ·  Space 暂停  ·  T 自动巡航\n右键拖动观察 / 调整高视角角度  ·  O 高视角切换  ·  1/2/3 天气  ·  M 地图调试  ·  F3 视觉调试  ·  F10 水面诊断" % [
		_controller.speed_mps,
		knots,
		mode_text
	]
	_update_navigation_depth_status()
	_update_cargo_task_status()


func _update_cargo_task_status() -> void:
	if _cargo_task_label == null:
		return
	if _cargo_economy_manager == null:
		_cargo_task_label.text = "货运：未接入"
		return
	var active := _cargo_economy_manager.get_active_contracts()
	var destination_names := PackedStringArray()
	for card in active:
		var definition := card.get("definition") as CargoContractDefinition
		if definition == null:
			continue
		var destination := _cargo_economy_manager.get_port_display_name(str(definition.destination_port_id))
		if not destination_names.has(destination):
			destination_names.append(destination)
	var loadout := _controller.get_node_or_null("CargoLoadout") as CargoLoadoutController
	var used_space := loadout.get_used_space_units() if loadout != null else 0
	var capacity := _controller.draft_profile.cargo_capacity_space_units if _controller.draft_profile != null else 0
	var target := " · 目的港 %s" % " / ".join(destination_names) if not destination_names.is_empty() else ""
	_cargo_task_label.text = "货运 %d/%d  ·  舱位 %d/%d%s" % [
		active.size(), CargoEconomyManager.ACTIVE_CONTRACT_LIMIT, used_space, capacity, target,
	]


func _update_navigation_depth_status() -> void:
	if _depth_label == null:
		return
	if _navigation_depth_monitor == null:
		_depth_label.text = "游戏参考水深未知 · 监视器未配置 · 非航海安全信息"
		return
	var snapshot := _navigation_depth_monitor.get_snapshot()
	var current: Dictionary = snapshot.get("current", {})
	var ahead: Dictionary = snapshot.get("ahead", {})
	var draft := float(snapshot.get("draft_m", -1.0))
	var margin := float(snapshot.get("safety_margin_m", 0.0))
	var status := str(snapshot.get("status", NavigationDepthProvider.STATUS_UNKNOWN))
	var ahead_status := str(ahead.get("status", NavigationDepthProvider.STATUS_UNKNOWN))
	if not bool(current.get("valid", false)):
		_depth_label.text = "游戏参考水深未知 · %s\n吃水 %s · 前方 %.0f m：%s · 非航海安全信息" % [
			str(current.get("reason", "No valid data")),
			"未配置" if draft < 0.0 else "%.2f m" % draft,
			float(snapshot.get("lookahead_distance_m", 0.0)), ahead_status,
		]
		return
	var source_tag := "港口游戏覆盖" if current.has("override_id") else "EMODnet LAT 粗网格"
	_depth_label.text = "参考水深 %.1f m · 吃水 %.2f m · 余量 %.1f m · %s\n前方 %.0f m：%s · %s（非航海安全信息）" % [
		float(current.get("depth_m", 0.0)), draft, margin, status,
		float(snapshot.get("lookahead_distance_m", 0.0)), ahead_status, source_tag,
	]


func _update_fps_display() -> void:
	var fps := Engine.get_frames_per_second()
	_fps_label.text = "FPS: %d" % fps if _runtime_elapsed >= 1.5 and fps >= 5 else "FPS: --"


func _build_debug_panel() -> void:
	_debug_panel = PanelContainer.new()
	_debug_panel.name = "DebugPanel"
	_debug_panel.anchor_left = 1.0
	_debug_panel.anchor_right = 1.0
	_debug_panel.anchor_top = 0.0
	_debug_panel.anchor_bottom = 1.0
	_debug_panel.offset_left = -414.0
	_debug_panel.offset_top = 196.0
	_debug_panel.offset_right = -24.0
	_debug_panel.offset_bottom = -16.0
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
	_debug_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_debug_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_debug_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_debug_panel.add_child(_debug_scroll)
	_debug_layout = VBoxContainer.new()
	_debug_layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_debug_layout.add_theme_constant_override("separation", 7)
	_debug_scroll.add_child(_debug_layout)
	var layout := _debug_layout
	var title := Label.new()
	title.text = "天气与画面调试"
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
	layout.add_child(title)
	if OS.is_debug_build():
		_add_peberholm_render_debug_control(layout)

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
	_add_fish_observation_controls(layout)
	_add_dolphin_controls(layout)

	_sun_elevation_slider = _add_slider_row(layout, "太阳高度（时间驱动）", -90.0, 90.0, 0.1)
	_sun_elevation_slider.editable = false
	_sun_azimuth_slider = _add_slider_row(layout, "太阳方位（真北顺时针）", 0.0, 360.0, 0.1)
	_sun_azimuth_slider.editable = false
	_cloud_slider = _add_slider_row(layout, "云量", 0.0, 1.0, 0.01)
	_cloud_slider.value = 0.18
	_cloud_slider.value_changed.connect(_on_cloud_changed)
	_wave_slider = _add_slider_row(layout, "波浪强度", 0.0, 2.0, 0.05)
	_wave_slider.value = 1.05
	_wave_slider.value_changed.connect(_on_wave_changed)
	if OS.is_debug_build():
		_extreme_sea_option = _add_option_row(layout, "极端海况测试", ["正常天气", "5 m", "10 m", "20 m", "30 m"])
		_extreme_sea_option.item_selected.connect(_on_extreme_sea_selected)
		_wave_compactness_slider = _add_slider_row(layout, "波浪紧凑度", 0.5, 2.5, 0.05)
		_wave_compactness_slider.value = 1.0
		_wave_compactness_slider.editable = false
		_wave_compactness_slider.value_changed.connect(_on_extreme_wave_shape_changed)
		_wave_sharpness_slider = _add_slider_row(layout, "波峰陡度", 0.0, 1.0, 0.01)
		_wave_sharpness_slider.value = 0.0
		_wave_sharpness_slider.editable = false
		_wave_sharpness_slider.value_changed.connect(_on_extreme_wave_shape_changed)
		_extreme_wave_defaults_button = Button.new()
		_extreme_wave_defaults_button.text = "恢复默认波形"
		_extreme_wave_defaults_button.disabled = true
		_extreme_wave_defaults_button.pressed.connect(_on_extreme_wave_defaults_pressed)
		layout.add_child(_extreme_wave_defaults_button)
		_extreme_sea_status = _make_debug_label()
		layout.add_child(_extreme_sea_status)

		var shallow_wave_title := Label.new()
		shallow_wave_title.text = "浅水波浪约束（仅开发测试）"
		shallow_wave_title.add_theme_font_size_override("font_size", 15)
		shallow_wave_title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
		layout.add_child(shallow_wave_title)
		_shallow_wave_constraint_toggle = CheckButton.new()
		_shallow_wave_constraint_toggle.text = "开启浅水波浪约束"
		_shallow_wave_constraint_toggle.toggled.connect(_on_shallow_wave_constraint_toggled)
		layout.add_child(_shallow_wave_constraint_toggle)
		_shallow_wave_full_depth_slider = _add_slider_row(layout, "深水完整波浪阈值（m）", 30.0, 60.0, 1.0)
		_shallow_wave_min_scale_slider = _add_slider_row(layout, "3 m 水深振幅保留率", 0.0, 0.60, 0.01)
		_shallow_wave_safe_ratio_slider = _add_slider_row(layout, "波谷安全余量（%）", 0.10, 0.50, 0.01)
		_shallow_wave_min_scale_slider.value = 0.40
		_shallow_wave_safe_ratio_slider.value = 0.20
		_shallow_wave_full_depth_slider.value_changed.connect(_on_shallow_wave_options_changed)
		_shallow_wave_min_scale_slider.value_changed.connect(_on_shallow_wave_options_changed)
		_shallow_wave_safe_ratio_slider.value_changed.connect(_on_shallow_wave_options_changed)
		_shallow_wave_defaults_button = Button.new()
		_shallow_wave_defaults_button.text = "恢复浅水约束默认值"
		_shallow_wave_defaults_button.pressed.connect(_on_shallow_wave_defaults_pressed)
		layout.add_child(_shallow_wave_defaults_button)
		_shallow_wave_status = _make_debug_label()
		layout.add_child(_shallow_wave_status)
		_sync_shallow_wave_controls()

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
	_add_world_time_controls(layout)
	_add_astronomy_debug_controls(layout)

	_sun_label = _make_debug_label()
	_moon_label = _make_debug_label()
	_cloud_label = _make_debug_label()
	_wave_label = _make_debug_label()
	_performance_label = _make_debug_label()
	layout.add_child(_sun_label)
	layout.add_child(_moon_label)
	layout.add_child(_cloud_label)
	layout.add_child(_wave_label)
	layout.add_child(_performance_label)
	add_child(_debug_panel)
	_refresh_weather_controls()
	_refresh_settings_controls()


func _add_peberholm_render_debug_control(parent: VBoxContainer) -> void:
	var section_title := Label.new()
	section_title.text = "Peberholm 地形渲染诊断"
	section_title.add_theme_font_size_override("font_size", 16)
	section_title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
	parent.add_child(section_title)
	_peberholm_debug_button = Button.new()
	_peberholm_debug_button.name = "PeberholmRenderDiagnosticToggle"
	_peberholm_debug_button.text = "开启顶面 / 岸坡颜色诊断"
	_peberholm_debug_button.disabled = not is_instance_valid(_oresund_region)
	_peberholm_debug_button.pressed.connect(_on_peberholm_debug_button_pressed)
	parent.add_child(_peberholm_debug_button)
	_peberholm_debug_feedback = _make_debug_label()
	_peberholm_debug_feedback.text = "绿色显示岛顶，红色显示岸坡。"
	parent.add_child(_peberholm_debug_feedback)


func _add_fish_observation_controls(parent: VBoxContainer) -> void:
	var title := Label.new()
	title.text = "鱼群观察点 · 调试传送"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
	parent.add_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	for fish in [["needlefish", "前往观察针鱼"], ["herring", "前往观察鲱鱼"], ["three_spined_stickleback", "前往观察三刺鱼"]]:
		var button := Button.new()
		button.text = str(fish[1])
		button.tooltip_text = "将船移到三刺鱼群上方，鱼群会在浅水层侧向躲避。" if str(fish[0]) == "three_spined_stickleback" else "将船停在鱼群惊扰范围外，并切换到真实鱼群位置的水下观察视角。"
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_fish_observation_pressed.bind(str(fish[0])))
		row.add_child(button)
	parent.add_child(row)
	var observer_row := HBoxContainer.new()
	observer_row.add_theme_constant_override("separation", 6)
	var observe_button := Button.new()
	observe_button.text = "进入水下鱼群观察视角"
	observe_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	observe_button.pressed.connect(_on_fish_observation_camera_pressed)
	observer_row.add_child(observe_button)
	var return_button := Button.new()
	return_button.text = "返回船上视角"
	return_button.pressed.connect(_on_fish_observation_camera_return_pressed)
	observer_row.add_child(return_button)
	parent.add_child(observer_row)
	_fish_location_feedback = _make_debug_label()
	_fish_location_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fish_location_feedback.text = "移动船只到真实鱼群观察位置；不会移动鱼群的共享生态锚点。"
	parent.add_child(_fish_location_feedback)
	_fish_observation_status = _make_debug_label()
	_fish_observation_status.name = "FishObservationStatus"
	_fish_observation_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fish_observation_status.text = "选择三刺鱼后显示鱼群实际尺寸、水层与海床净空。"
	parent.add_child(_fish_observation_status)
	_fish_motion_toggle = CheckButton.new()
	_fish_motion_toggle.name = "FishSmoothMotionToggle"
	_fish_motion_toggle.text = "鱼群逐帧平滑运动（A/B 调试）"
	_fish_motion_toggle.button_pressed = _fish_school_renderer != null and _fish_school_renderer.smooth_motion_enabled
	_fish_motion_toggle.disabled = _fish_school_renderer == null
	_fish_motion_toggle.toggled.connect(_on_fish_smoothing_toggled)
	parent.add_child(_fish_motion_toggle)
	_fish_motion_status = _make_debug_label()
	_fish_motion_status.name = "FishMotionStatus"
	parent.add_child(_fish_motion_status)
	_update_fish_motion_status()


func _add_dolphin_controls(parent: VBoxContainer) -> void:
	var title := Label.new()
	title.text = "海豚 · 世界生态调试"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
	parent.add_child(title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var follow_button := Button.new()
	follow_button.text = "召唤海豚跟船"
	follow_button.tooltip_text = "开发观察工具：必要时只移动船到固定海域，海豚会从原位置游近。保持船上视角。"
	follow_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	follow_button.disabled = _dolphin_world_manager == null
	follow_button.pressed.connect(_on_dolphin_follow_pressed)
	row.add_child(follow_button)
	var leap_button := Button.new()
	leap_button.text = "触发一次跃出"
	leap_button.tooltip_text = "只触发一只现存海豚的调试跃出动作，不新增或传送海豚。"
	leap_button.disabled = _dolphin_world_manager == null
	leap_button.pressed.connect(_on_dolphin_leap_pressed)
	row.add_child(leap_button)
	parent.add_child(row)
	_dolphin_status = _make_debug_label()
	_dolphin_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(_dolphin_status)
	_update_dolphin_status()


func _on_dolphin_follow_pressed() -> void:
	if _dolphin_world_manager == null or not _dolphin_world_manager.has_method("debug_summon_follow"):
		if _dolphin_status != null:
			_dolphin_status.text = "海豚管理器不可用。"
		return
	var result: Dictionary = _dolphin_world_manager.call("debug_summon_follow", _controller)
	if _fish_location_feedback != null:
		_fish_location_feedback.text = str(result.get("reason", "已开始海豚伴游观察。")) if not bool(result.get("accepted", false)) else ("F3 调试：船已移到安全活动海域；海豚从原位置游近，未传送海豚。保持船上镜头。" if bool(result.get("teleported_boat", false)) else "F3 调试：已请求现存海豚自然靠近伴游。保持船上镜头。")
	_update_dolphin_status()


func _on_dolphin_leap_pressed() -> void:
	if _dolphin_world_manager == null or not _dolphin_world_manager.has_method("trigger_debug_leap"):
		return
	var started := bool(_dolphin_world_manager.call("trigger_debug_leap"))
	if _fish_location_feedback != null:
		if started:
			_fish_location_feedback.text = "已安排一只现存海豚先上浮，再执行一次跃出动作。"
		else:
			var stats: Dictionary = _dolphin_world_manager.call("get_debug_status") if _dolphin_world_manager.has_method("get_debug_status") else {}
			_fish_location_feedback.text = "低速绕船期间暂停跃出；船速达到 2.0 m/s 并稳定 1 秒后恢复。" if str(stats.get("follow_mode", "")) == "orbit" else "当前没有可用海豚或其正在跃出。"
	_update_dolphin_status()


func _update_dolphin_status() -> void:
	if _dolphin_status == null:
		return
	if _dolphin_world_manager == null or not _dolphin_world_manager.has_method("get_debug_status"):
		_dolphin_status.text = "海豚世界状态不可用。"
		return
	var stats: Dictionary = _dolphin_world_manager.call("get_debug_status")
	var scheduled := int(stats.get("follow_leaps_scheduled", 0))
	var completed := int(stats.get("follow_leaps_completed", 0))
	var remaining := int(stats.get("follow_leaps_remaining", 0))
	var next_leap := float(stats.get("follow_next_leap_in", -1.0))
	var follow_leap_text := "伴游跃出：%d/%d 完成 · 排队 %d" % [completed, scheduled, remaining]
	if next_leap >= 0.0:
		follow_leap_text += " · 下次约 %.1f 秒" % next_leap
	elif bool(stats.get("following", false)) and str(stats.get("follow_mode", "")) == "orbit":
		follow_leap_text += " · 绕船期间暂停新跃出"
	var follow_mode_label := "未进行"
	if bool(stats.get("following", false)):
		follow_mode_label = "低速绕船" if str(stats.get("follow_mode", "cruise")) == "orbit" else "跟船巡游"
		follow_mode_label += "（≤ %.1f / ≥ %.1f m/s）" % [
			float(stats.get("follow_orbit_enter_mps", 1.5)),
			float(stats.get("follow_cruise_resume_mps", 2.0)),
		]
	var motion: Dictionary = stats.get("leap_motion", {})
	var motion_text := "Leap Transform：DolphinVisual.advance_visual（单一写入者）"
	if not motion.is_empty():
		motion_text = "跃出轨迹：%s · t %.2f/%.2f s · vy %+.2f m/s · Y %.2f m / 水面 %.2f m" % [
			str(motion.get("leap_phase", "")),
			float(motion.get("leap_elapsed", 0.0)),
			float(motion.get("leap_duration", 0.0)),
			float(motion.get("vertical_speed", 0.0)),
			float(motion.get("world_y", 0.0)),
			float(motion.get("surface_y", 0.0)),
		]
	_dolphin_status.text = "%s Authority · 固定世界实体 %d · 当前绘制 %d · 露背 %d · 跃出 %d\n伴游：%s · 剩余 %.0f 秒\n%s\n%s\n水花触发：接触帧 %d · 表层 %d · 出入水 %d · 活跃发射器 %d" % [
		str(stats.get("authority", "Unavailable")),
		int(stats.get("population", 0)),
		int(stats.get("rendered", 0)),
		int(stats.get("surface_count", 0)),
		int(stats.get("leap_count", 0)),
		follow_mode_label,
		float(stats.get("follow_remaining", 0.0)),
		follow_leap_text,
		motion_text,
		int(stats.get("surface_contact_count", 0)),
		int(stats.get("micro_splash_emissions", 0)),
		int(stats.get("impact_splash_emissions", 0)),
		int(stats.get("active_splash_emitters", 0)),
	]


func _on_fish_smoothing_toggled(enabled: bool) -> void:
	if _fish_school_renderer == null:
		return
	_fish_school_renderer.set_smooth_motion_enabled(enabled)
	_update_fish_motion_status()


func _update_fish_motion_status() -> void:
	_update_fish_observation_status()
	if _fish_motion_status == null:
		return
	if _fish_school_renderer == null:
		_fish_motion_status.text = "鱼群渲染器不可用。"
		return
	var stats := _fish_school_renderer.get_render_statistics()
	_fish_motion_status.text = "运动平滑 %s · AI %.2f Hz · 可见 %d 条 · 近表层群 %d · 水纹 %d\n针鱼视觉/逻辑 %d/%d · 鲱鱼视觉/逻辑 %d/%d\nAI 更新 %.2f ms · MultiMesh 提交 %.2f ms/帧" % [
		"开" if _fish_school_renderer.smooth_motion_enabled else "关",
		float(stats.get("movement_update_hz", 0.0)),
		int(stats.get("visible_fish", 0)),
		int(stats.get("near_surface_schools", 0)),
		int(stats.get("surface_ripple_count", 0)),
		int(stats.get("visual_needlefish_schools", 0)),
		int(stats.get("logical_needlefish_schools", 0)),
		int(stats.get("visual_herring_schools", 0)),
		int(stats.get("logical_herring_schools", 0)),
		float(stats.get("ai_update_ms", 0.0)),
		float(stats.get("multimesh_submit_ms", 0.0)),
	]


func _update_fish_observation_status() -> void:
	if _fish_observation_status == null:
		return
	if _fish_school_renderer == null or _selected_fish_school_id.is_empty():
		_fish_observation_status.text = "鱼群观察数据：未选择鱼群。"
		return
	var stats := _fish_school_renderer.get_school_visual_debug(_selected_fish_school_id)
	if stats.is_empty():
		_fish_observation_status.text = "鱼群观察数据：鱼群正在加载或已离开可见范围。"
		return
	var behaviors: Dictionary = stats.get("behavior_counts", {})
	var behavior_text := "巡游 %d · 转向 %d · 悬停 %d · 受惊 %d" % [
		int(behaviors.get("cruise", 0)),
		int(behaviors.get("turn", 0)),
		int(behaviors.get("hover", 0)),
		int(behaviors.get("flee", 0)),
	]
	var visibility_text := "视觉鱼" if str(stats.get("render_state", "visual")) == "visual" else "逻辑鱼（无 3D 渲染）"
	_fish_observation_status.text = "选中群体 · %s · 显示长度 %.0f cm · 数量 %d（可见 %d）\n距水面 %.2f m · 图表水深 %.2f m · 距海床 %.2f m\n生境：%s · 行为：%s · 活动：%s" % [
		visibility_text,
		float(stats.get("average_visual_length_m", 0.0)) * 100.0,
		int(stats.get("school_population", 0)),
		int(stats.get("visible_fish", 0)),
		float(stats.get("depth_from_surface_m", 0.0)),
		float(stats.get("bathymetry_depth_m", 0.0)),
		float(stats.get("seabed_clearance_m", 0.0)),
		str(stats.get("habitat_region", "unknown")),
		behavior_text,
		str(stats.get("activity_label", "巡游")),
	]


func _on_fish_observation_pressed(species_id: String) -> void:
	if _fish_resource_manager == null or _controller == null:
		_fish_location_feedback.text = "鱼类资源管理器不可用。"
		return
	var profile := _fish_resource_manager.get_species_profile(species_id)
	var bathymetry := _fish_resource_manager.get_bathymetry_manager()
	if profile == null or bathymetry == null:
		_fish_location_feedback.text = "鱼种配置或水深数据不可用。"
		return
	if species_id in ["needlefish", "herring"]:
		_on_surface_species_observation_pressed(profile, bathymetry)
		return
	var origin := _controller.global_position
	var nearest_school: Dictionary = {}
	var nearest_distance := INF
	var nearest_preferred_school: Dictionary = {}
	var nearest_preferred_distance := INF
	var target_position := Vector3.ZERO
	var preferred_depth_min := float(profile.preferred_depth_min_m)
	var preferred_depth_max := float(profile.preferred_depth_max_m)
	for school in _fish_resource_manager.get_all_school_snapshots():
		if str(school.get("species_id", "")) != species_id:
			continue
		var position_data: Array = school.get("world_position", [])
		if position_data.size() != 3:
			continue
		var school_position := Vector3(float(position_data[0]), origin.y, float(position_data[2]))
		var distance := Vector2(school_position.x - origin.x, school_position.z - origin.z).length()
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_school = school
			target_position = school_position
		var school_depth := float(school.get("depth_m", 0.0))
		if school_depth >= preferred_depth_min and school_depth <= preferred_depth_max and distance < nearest_preferred_distance:
			nearest_preferred_distance = distance
			nearest_preferred_school = school
	if not nearest_preferred_school.is_empty():
		nearest_school = nearest_preferred_school
		nearest_distance = nearest_preferred_distance
		var preferred_position: Array = nearest_school.get("world_position", [])
		if preferred_position.size() == 3:
			target_position = Vector3(float(preferred_position[0]), origin.y, float(preferred_position[2]))
	if nearest_school.is_empty():
		_fish_location_feedback.text = "当前世界没有可用的%s鱼群资源点。" % profile.display_name
		return
	var destination_result: Dictionary
	if species_id == "three_spined_stickleback":
		destination_result = _find_stickleback_overhead_position(target_position, origin, bathymetry)
	else:
		destination_result = _find_safe_fish_observation_position(target_position, origin, float(nearest_school.get("depth_m", 0.0)), species_id, bathymetry)
	if not bool(destination_result.get("valid", false)):
		_fish_location_feedback.text = "找到了%s鱼群，但附近没有可用水深的靠近位置。" % profile.display_name
		return
	var destination: Vector3 = destination_result["position"]
	_controller.speed_mps = 0.0
	_controller.is_autopilot = false
	_controller.is_motion_paused = false
	_controller.global_position = destination
	var direction := Vector2(target_position.x - destination.x, target_position.z - destination.z).normalized()
	if direction.length_squared() > 0.001:
		_controller.global_rotation.y = atan2(-direction.x, -direction.y)
	var wake := _controller.get_node_or_null("VisualRoot/WakeSystem")
	if wake != null and wake.has_method("reset_wake"):
		wake.call("reset_wake")
	var school_id := str(nearest_school.get("school_id", ""))
	_selected_fish_school_id = school_id
	var observation_started := not school_id.is_empty() and _fish_school_renderer != null and _fish_school_renderer.begin_observation(school_id)
	var departure_distance_km := nearest_distance / 1000.0
	var camera_note := "已切换到水下观察视角；鱼群会在浅水层侧向散开，按‘返回船上视角’恢复。" if observation_started else "可按‘进入水下鱼群观察视角’查看。"
	var location_label := "鱼群正上方" if species_id == "three_spined_stickleback" else "鱼群附近"
	_fish_location_feedback.text = "已到最近%s%s：船距群中心 %.0f m · 水深 %.1f m · 群体 %d 条 · 出发点距群 %.1f km。%s" % [
		profile.display_name,
		location_label,
		float(destination_result.get("school_distance_m", 0.0)),
		float(destination_result.get("depth_m", 0.0)),
		int(nearest_school.get("population", 0)),
		departure_distance_km,
		camera_note,
	]


func _on_surface_species_observation_pressed(profile: FishSpeciesProfile, bathymetry: BathymetryManager) -> void:
	var origin := _controller.global_position
	var nearest_school: Dictionary = {}
	var nearest_rank := 99
	var nearest_distance := INF
	var target_position := Vector3.ZERO
	var local_search_radius := _fish_school_renderer.observation_search_radius_m if _fish_school_renderer != null else 5000.0
	var preferred_search_radius := _fish_school_renderer.preferred_observation_search_radius_m if _fish_school_renderer != null else 1500.0
	for school in _fish_resource_manager.get_all_school_snapshots():
		if str(school.get("species_id", "")) != profile.species_id:
			continue
		if _fish_resource_manager.get_school_render_state(school) != "visual":
			continue
		var activity_depth := float(school.get("activity_depth_m", INF))
		if activity_depth > 6.0:
			continue
		var position_data: Array = school.get("world_position", [])
		if position_data.size() != 3:
			continue
		var school_position := Vector3(float(position_data[0]), origin.y, float(position_data[2]))
		var distance := Vector2(school_position.x - origin.x, school_position.z - origin.z).length()
		if distance > local_search_radius:
			continue
		var activity_state := str(school.get("surface_activity_state", ""))
		var has_surface_activity := activity_depth <= 2.0 and activity_state in ["near_surface", "ascending", "descending"]
		var has_clear_surface_activity := activity_depth <= 1.2 and has_surface_activity
		var activity_rank := 2
		if has_clear_surface_activity:
			activity_rank = 0
		elif has_surface_activity:
			activity_rank = 1
		# Search local schools first so a distant active group does not displace
		# a nearby visual group the player can already observe.
		var distance_rank := 0 if distance <= preferred_search_radius else 1
		var rank := distance_rank * 3 + activity_rank
		if rank < nearest_rank or (rank == nearest_rank and distance < nearest_distance):
			nearest_rank = rank
			nearest_distance = distance
			nearest_school = school
			target_position = school_position
	if nearest_school.is_empty():
		_fish_location_feedback.text = "%.0f km 内没有可观察的%s视觉鱼群；深水逻辑鱼群仍保留在世界资源中。" % [local_search_radius / 1000.0, profile.display_name]
		return
	var destination_result := _find_surface_species_observation_position(target_position, origin, bathymetry)
	if not bool(destination_result.get("valid", false)):
		_fish_location_feedback.text = "找到了%s视觉鱼群，但鱼群附近没有安全水面位置。" % profile.display_name
		return
	var destination: Vector3 = destination_result["position"]
	_controller.speed_mps = 0.0
	_controller.is_autopilot = false
	_controller.is_motion_paused = false
	_controller.global_position = destination
	var direction := Vector2(target_position.x - destination.x, target_position.z - destination.z).normalized()
	if direction.length_squared() > 0.001:
		_controller.global_rotation.y = atan2(-direction.x, -direction.y)
	var wake := _controller.get_node_or_null("VisualRoot/WakeSystem")
	if wake != null and wake.has_method("reset_wake"):
		wake.call("reset_wake")
	if _fish_school_renderer != null and _fish_school_renderer.is_observation_active():
		_fish_school_renderer.end_observation()
	_selected_fish_school_id = str(nearest_school.get("school_id", ""))
	var activity_depth := float(nearest_school.get("activity_depth_m", 0.0))
	var activity_label := "正在近表层活动" if nearest_rank <= 1 else "位于可见水层"
	_fish_location_feedback.text = "已到%s%s：船距群中心 %.0f m · 鱼群深度 %.1f m · 海图水深 %.1f m · 群体 %d 条 · 出发点距群 %.1f km。保持船上镜头；需要水下近景时再手动切换。" % [
		profile.display_name,
		activity_label,
		float(destination_result.get("school_distance_m", 0.0)),
		activity_depth,
		float(nearest_school.get("depth_m", 0.0)),
		int(nearest_school.get("population", 0)),
		nearest_distance / 1000.0,
	]


func _find_surface_species_observation_position(school_position: Vector3, boat_position: Vector3, bathymetry: BathymetryManager) -> Dictionary:
	var base_direction := Vector2(boat_position.x - school_position.x, boat_position.z - school_position.z)
	if base_direction.length_squared() < 0.001:
		var forward := -_controller.global_transform.basis.z
		base_direction = Vector2(-forward.x, -forward.z)
	base_direction = base_direction.normalized()
	var best_position := Vector3.ZERO
	var best_depth := 0.0
	var best_score := INF
	for distance_m in [18.0, 20.0, 23.0]:
		for angle_degrees in [-150.0, -120.0, -90.0, -60.0, -30.0, 0.0, 30.0, 60.0, 90.0, 120.0, 150.0, 180.0]:
			var offset := base_direction.rotated(deg_to_rad(float(angle_degrees))) * float(distance_m)
			var candidate := Vector3(school_position.x + offset.x, boat_position.y, school_position.z + offset.y)
			var sample := bathymetry.get_depth_at_world_position(candidate)
			if not bool(sample.get("valid", false)):
				continue
			var depth := float(sample.get("depth_m", 0.0))
			if depth < 1.5:
				continue
			var score := absf(float(distance_m) - 18.0) + absf(float(angle_degrees)) * 0.002
			if score < best_score:
				best_score = score
				best_position = candidate
				best_depth = depth
	if not is_finite(best_score):
		return {"valid": false}
	return {
		"valid": true,
		"position": best_position,
		"depth_m": best_depth,
		"school_distance_m": Vector2(best_position.x - school_position.x, best_position.z - school_position.z).length(),
	}


func _find_stickleback_overhead_position(school_position: Vector3, boat_position: Vector3, bathymetry: BathymetryManager) -> Dictionary:
	var sample := bathymetry.get_depth_at_world_position(school_position)
	if not bool(sample.get("valid", false)):
		return {"valid": false}
	var depth := float(sample.get("depth_m", 0.0))
	if depth < 0.85 or depth > 6.0:
		return {"valid": false}
	var destination := Vector3(school_position.x, boat_position.y, school_position.z)
	return {
		"valid": true,
		"position": destination,
		"depth_m": depth,
		"school_distance_m": 0.0,
		"directly_over_school": true,
	}


func _on_fish_observation_camera_pressed() -> void:
	if _fish_school_renderer == null or _selected_fish_school_id.is_empty():
		if _fish_location_feedback != null:
			_fish_location_feedback.text = "先选择一个鱼种，传送到鱼群后再进入观察视角。"
		return
	if not _fish_school_renderer.begin_observation(_selected_fish_school_id) and _fish_location_feedback != null:
		_fish_location_feedback.text = "所选鱼群当前不在 6 米视觉层或已不可用，请重新选择近表层鱼群。"


func _on_fish_observation_camera_return_pressed() -> void:
	if _fish_school_renderer != null:
		_fish_school_renderer.end_observation()


func _find_safe_fish_observation_position(school_position: Vector3, boat_position: Vector3, school_depth: float, species_id: String, bathymetry: BathymetryManager) -> Dictionary:
	var base_direction := Vector2(boat_position.x - school_position.x, boat_position.z - school_position.z)
	if base_direction.length_squared() < 0.001:
		var forward := -_controller.global_transform.basis.z
		base_direction = Vector2(-forward.x, -forward.z)
	base_direction = base_direction.normalized()
	var flee_clearance := 12.0
	match species_id:
		"needlefish": flee_clearance += 85.0
		"herring": flee_clearance += 55.0
		"three_spined_stickleback": flee_clearance += 24.0
	var preferred_distance := flee_clearance + 5.0
	var best_position := Vector3.ZERO
	var best_depth := 0.0
	var best_score := 1.0e30
	for distance_m in [preferred_distance, preferred_distance + 8.0, preferred_distance + 16.0, preferred_distance + 24.0]:
		for angle_degrees in [-120.0, -90.0, -60.0, -30.0, 0.0, 30.0, 60.0, 90.0, 120.0, 150.0]:
			var offset := base_direction.rotated(deg_to_rad(float(angle_degrees))) * float(distance_m)
			var candidate := Vector3(school_position.x + offset.x, boat_position.y, school_position.z + offset.y)
			var sample := bathymetry.get_depth_at_world_position(candidate)
			if not bool(sample.get("valid", false)):
				continue
			var depth := float(sample.get("depth_m", 0.0))
			if depth < 1.3:
				continue
			var score := absf(float(distance_m) - preferred_distance) + absf(depth - school_depth) * 2.0 + absf(float(angle_degrees)) * 0.01
			if score < best_score:
				best_score = score
				best_position = candidate
				best_depth = depth
	if best_score >= 1.0e29:
		return {"valid": false}
	return {
		"valid": true,
		"position": best_position,
		"depth_m": best_depth,
		"school_distance_m": Vector2(best_position.x - school_position.x, best_position.z - school_position.z).length(),
	}


func _add_astronomy_debug_controls(parent: VBoxContainer) -> void:
	var title := Label.new()
	title.text = "日月与星空测试"
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
	parent.add_child(title)
	var note := _make_debug_label()
	note.text = "相位按世界日历日期；月亮沿日轮时刻连续运行。下方日期覆盖可恢复现实日历。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(note)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var moonrise := Button.new()
	moonrise.name = "NextMoonrise"
	moonrise.text = "下一次月出"
	moonrise.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	moonrise.pressed.connect(_jump_to_next_moonrise)
	row.add_child(moonrise)
	var full_moon := Button.new()
	full_moon.name = "FullMoonTest"
	full_moon.text = "满月夜"
	full_moon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	full_moon.pressed.connect(_jump_to_lunar_phase.bind(true))
	row.add_child(full_moon)
	var new_moon := Button.new()
	new_moon.name = "NewMoonTest"
	new_moon.text = "新月夜"
	new_moon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_moon.pressed.connect(_jump_to_lunar_phase.bind(false))
	row.add_child(new_moon)
	parent.add_child(row)
	_time_admin_controls.append(moonrise)
	_time_admin_controls.append(full_moon)
	_time_admin_controls.append(new_moon)


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
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _add_world_time_controls(parent: VBoxContainer) -> void:
	var section_title := Label.new()
	section_title.text = "世界时间管理员"
	section_title.add_theme_font_size_override("font_size", 16)
	section_title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
	parent.add_child(section_title)
	_world_time_label = _make_debug_label()
	_world_time_label.name = "WorldTimeStatus"
	_world_time_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(_world_time_label)

	var cycle_row := HBoxContainer.new()
	cycle_row.add_theme_constant_override("separation", 6)
	var cycle_title := Label.new()
	cycle_title.text = "日轮时间"
	cycle_title.custom_minimum_size.x = 76.0
	cycle_row.add_child(cycle_title)
	_cycle_hour_spin = _make_spin_box(0.0, 23.0, 1.0, 54.0)
	_cycle_hour_spin.name = "CycleHour"
	cycle_row.add_child(_cycle_hour_spin)
	var hour_suffix := Label.new()
	hour_suffix.text = "时"
	cycle_row.add_child(hour_suffix)
	_cycle_minute_spin = _make_spin_box(0.0, 59.0, 1.0, 54.0)
	_cycle_minute_spin.name = "CycleMinute"
	cycle_row.add_child(_cycle_minute_spin)
	var minute_suffix := Label.new()
	minute_suffix.text = "分"
	cycle_row.add_child(minute_suffix)
	var set_time_button := Button.new()
	set_time_button.name = "ApplyCycleTime"
	set_time_button.text = "应用时间"
	set_time_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	set_time_button.pressed.connect(_on_cycle_time_apply_pressed)
	cycle_row.add_child(set_time_button)
	parent.add_child(cycle_row)
	_time_admin_controls.append(_cycle_hour_spin)
	_time_admin_controls.append(_cycle_minute_spin)
	_time_admin_controls.append(set_time_button)

	var quick_row := HBoxContainer.new()
	quick_row.add_theme_constant_override("separation", 6)
	var quick_title := Label.new()
	quick_title.text = "快速跳时"
	parent.add_child(quick_title)
	for quick_time in [[6, 0], [12, 0], [18, 0], [0, 0]]:
		var quick_button := Button.new()
		quick_button.name = "QuickTime_%02d_00" % int(quick_time[0])
		quick_button.text = "%02d:00" % int(quick_time[0])
		quick_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		quick_button.pressed.connect(_on_quick_time_pressed.bind(int(quick_time[0]), int(quick_time[1])))
		quick_row.add_child(quick_button)
		_time_admin_controls.append(quick_button)
	parent.add_child(quick_row)

	_time_scale_option = _add_option_row(parent, "日轮倍率", ["1×", "6×", "12×", "24×", "60×"])
	_time_scale_option.name = "TimeScaleOption"
	_time_scale_option.item_selected.connect(_on_time_scale_selected)
	_time_admin_controls.append(_time_scale_option)
	var time_actions := HBoxContainer.new()
	time_actions.add_theme_constant_override("separation", 8)
	_time_pause_toggle = CheckButton.new()
	_time_pause_toggle.name = "PauseToggle"
	_time_pause_toggle.text = "暂停日轮"
	_time_pause_toggle.toggled.connect(_on_time_pause_toggled)
	_time_pause_toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_actions.add_child(_time_pause_toggle)
	var default_rate_button := Button.new()
	default_rate_button.name = "DefaultTimeScale"
	default_rate_button.text = "恢复默认 24×"
	default_rate_button.pressed.connect(_on_default_time_scale_pressed)
	time_actions.add_child(default_rate_button)
	parent.add_child(time_actions)
	_time_admin_controls.append(_time_pause_toggle)
	_time_admin_controls.append(default_rate_button)

	var date_note := Label.new()
	date_note.text = "日期调试覆盖（固定显示日期，不改变真实天气时钟）"
	date_note.add_theme_color_override("font_color", Color(0.79, 0.87, 0.89))
	date_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(date_note)
	var date_row := HBoxContainer.new()
	date_row.add_theme_constant_override("separation", 6)
	_calendar_year_spin = _make_spin_box(1.0, 9999.0, 1.0, 68.0)
	_calendar_month_spin = _make_spin_box(1.0, 12.0, 1.0, 50.0)
	_calendar_day_spin = _make_spin_box(1.0, 31.0, 1.0, 50.0)
	_calendar_year_spin.name = "CalendarYear"
	_calendar_month_spin.name = "CalendarMonth"
	_calendar_day_spin.name = "CalendarDay"
	date_row.add_child(_calendar_year_spin)
	date_row.add_child(_calendar_month_spin)
	date_row.add_child(_calendar_day_spin)
	var date_apply_button := Button.new()
	date_apply_button.name = "ApplyCalendarOverride"
	date_apply_button.text = "应用覆盖"
	date_apply_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	date_apply_button.pressed.connect(_on_calendar_override_pressed)
	date_row.add_child(date_apply_button)
	parent.add_child(date_row)
	_time_admin_controls.append(_calendar_year_spin)
	_time_admin_controls.append(_calendar_month_spin)
	_time_admin_controls.append(_calendar_day_spin)
	_time_admin_controls.append(date_apply_button)
	var clear_override_button := Button.new()
	clear_override_button.name = "ClearCalendarOverride"
	clear_override_button.text = "取消覆盖 · 恢复现实日历"
	clear_override_button.pressed.connect(_on_clear_calendar_override_pressed)
	parent.add_child(clear_override_button)
	_time_admin_controls.append(clear_override_button)
	_world_time_feedback = _make_debug_label()
	_world_time_feedback.name = "WorldTimeFeedback"
	parent.add_child(_world_time_feedback)
	_refresh_world_time_controls()


func _make_spin_box(low: float, high: float, step: float, minimum_width: float) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = low
	spin.max_value = high
	spin.step = step
	spin.rounded = true
	spin.custom_minimum_size.x = minimum_width
	spin.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	return spin


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
	if _depth_label != null:
		_depth_label.custom_minimum_size.x = panel_width - 32.0
	if _debug_panel != null:
		var debug_width := minf(390.0, maxf(280.0, viewport_width - 48.0))
		_debug_panel.custom_minimum_size.x = debug_width
		_debug_panel.offset_left = -debug_width - 24.0
		_debug_panel.offset_right = -24.0
		_debug_panel.offset_top = minf(196.0, maxf(80.0, viewport_size.y * 0.2))
		_debug_panel.offset_bottom = -16.0
		_debug_panel.custom_minimum_size.y = 0.0
		_debug_scroll.custom_minimum_size.y = 0.0


func _refresh_weather_controls() -> void:
	if _weather_controller == null:
		_weather_label.text = "天气控制器未连接"
		return
	_refresh_solar_controls()
	_cloud_slider.set_value_no_signal(float(_weather_controller.call("get_cloud_coverage")))
	_wave_slider.set_value_no_signal(float(_wave_sampler.get("wave_strength")) if _wave_sampler != null else 1.0)
	_update_extreme_sea_status()
	_weather_label.text = "当前天气：%s   ·   按 1 / 2 / 3 切换" % _weather_controller.get("current_weather_name")


func _update_debug_status() -> void:
	_refresh_world_time_controls()
	_update_fish_motion_status()
	_update_dolphin_status()
	if _weather_controller != null:
		_weather_label.text = "当前天气：%s   ·   按 1 / 2 / 3 切换" % _weather_controller.get("current_weather_name")
		var sun_elevation := _get_solar_value("elevation_degrees")
		var sun_azimuth := _get_solar_value("azimuth_degrees")
		_sun_label.text = "太阳：高度 %.1f°  ·  方位 %.0f°" % [sun_elevation, sun_azimuth]
		var lunar: Dictionary = _day_night_visual_controller.call("get_moon_state") if _day_night_visual_controller != null else {}
		var solar: Dictionary = _day_night_visual_controller.call("get_solar_state") if _day_night_visual_controller != null else {}
		_moon_label.text = "月亮：高度 %+.1f° · 方位 %.0f° · %s · 照亮 %.0f%%\n日光 %.2f · 月光 %.3f · 星空 %.0f%%" % [
			float(lunar.get("elevation_degrees", -90.0)),
			float(lunar.get("azimuth_degrees", 0.0)),
		_phase_name_zh(str(lunar.get("phase_name", "Unavailable"))),
			float(lunar.get("illumination_fraction", 0.0)) * 100.0,
			float(solar.get("direct_light_strength", 0.0)),
			float(lunar.get("moonlight_strength", 0.0)),
			float(lunar.get("star_strength", 0.0)) * 100.0,
		]
		_cloud_label.text = "云量：%.0f%%" % (float(_weather_controller.call("get_cloud_coverage")) * 100.0)
		_refresh_solar_controls()
		if not _cloud_slider.has_focus():
			_cloud_slider.set_value_no_signal(float(_weather_controller.call("get_cloud_coverage")))
	if _wave_sampler != null:
		var extreme_active := bool(_wave_sampler.call("is_extreme_sea_test_active")) if _wave_sampler.has_method("is_extreme_sea_test_active") else false
		if extreme_active:
			_wave_label.text = "极端海况：目标 %.0f m · Shader / WaveSampler 同步" % float(_wave_sampler.call("get_extreme_sea_test_target_height"))
		else:
			_wave_label.text = "波浪强度：%.2f" % float(_wave_sampler.get("wave_strength"))
		if not _wave_slider.has_focus():
			_wave_slider.set_value_no_signal(float(_wave_sampler.get("wave_strength")))
		_wave_slider.editable = not extreme_active
		_update_extreme_sea_status()
		_update_shallow_wave_status()
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


func _refresh_world_time_controls() -> void:
	if _world_time_label == null:
		return
	if _world_time_control == null:
		_world_time_label.text = "世界时间控制端口不可用"
		return
	var snapshot := _world_time_control.get_snapshot()
	if snapshot.is_empty():
		_world_time_label.text = "世界时间状态不可用"
		_set_time_controls_enabled(false)
		return
	var date: Dictionary = snapshot.get("calendar_date", {})
	var cycle_seconds := float(snapshot.get("cycle_seconds", 0.0))
	var cycle_whole_seconds := int(floor(cycle_seconds))
	var hour := int(cycle_whole_seconds / 3600)
	var minute := int((cycle_whole_seconds % 3600) / 60)
	var second := cycle_whole_seconds % 60
	var global_cycle_number := int(snapshot.get("day_cycle_index", 0)) + 1
	var today_ordinal := int(snapshot.get("local_day_cycle_ordinal", 0))
	var ordinal_text := "今日第 %d 轮" % today_ordinal if today_ordinal > 0 else "今日尚未开始新日轮"
	var scale := float(snapshot.get("time_scale", 24.0))
	var paused := bool(snapshot.get("paused", false))
	var has_override := bool(snapshot.get("calendar_override_enabled", false))
	var authority := _world_time_control.get_authority_label()
	_world_time_label.text = "%04d-%02d-%02d · 全局第 %d 轮 · %s\n%02d:%02d:%02d · %.0f× · %s\n权威来源：%s · 日期调试覆盖：%s" % [
		int(date.get("year", 0)),
		int(date.get("month", 0)),
		int(date.get("day", 0)),
		global_cycle_number,
		ordinal_text,
		hour,
		minute,
		second,
		scale,
		"已暂停" if paused else "运行中",
		authority,
		"已启用" if has_override else "关闭",
	]
	if not _time_pause_toggle.has_focus():
		_time_pause_toggle.set_pressed_no_signal(paused)
	if not _control_has_focus(_cycle_hour_spin):
		_cycle_hour_spin.set_value_no_signal(hour)
	if not _control_has_focus(_cycle_minute_spin):
		_cycle_minute_spin.set_value_no_signal(minute)
	if not _control_has_focus(_calendar_year_spin):
		_calendar_year_spin.set_value_no_signal(int(date.get("year", 2026)))
	if not _control_has_focus(_calendar_month_spin):
		_calendar_month_spin.set_value_no_signal(int(date.get("month", 1)))
	if not _control_has_focus(_calendar_day_spin):
		_calendar_day_spin.set_value_no_signal(int(date.get("day", 1)))
	_sync_time_scale_option(scale)
	var can_modify := _world_time_control.can_modify()
	_set_time_controls_enabled(can_modify)
	if _world_time_feedback.text.is_empty():
		_world_time_feedback.text = "本地开发权限通过控制适配器提供。"


func _set_time_controls_enabled(enabled: bool) -> void:
	for control in _time_admin_controls:
		if control is BaseButton:
			(control as BaseButton).disabled = not enabled
		elif control is SpinBox:
			(control as SpinBox).editable = enabled


func _sync_time_scale_option(scale: float) -> void:
	var selected_scale_index := -1
	for index in range(TIME_SCALE_PRESETS.size()):
		var preset_scale := float(TIME_SCALE_PRESETS[index])
		if is_equal_approx(scale, preset_scale):
			selected_scale_index = index
	if selected_scale_index < 0:
		if not _has_custom_time_scale_item or not is_equal_approx(_custom_time_scale_value, scale):
			if _has_custom_time_scale_item:
				_time_scale_option.remove_item(TIME_SCALE_PRESETS.size())
			_time_scale_option.add_item("当前 %.2f×" % scale)
			_has_custom_time_scale_item = true
			_custom_time_scale_value = scale
		selected_scale_index = TIME_SCALE_PRESETS.size()
	elif _has_custom_time_scale_item:
		_time_scale_option.remove_item(TIME_SCALE_PRESETS.size())
		_has_custom_time_scale_item = false
		_custom_time_scale_value = -1.0
	_time_scale_option.select(selected_scale_index)


func _control_has_focus(control: Control) -> bool:
	var focus_owner := get_viewport().gui_get_focus_owner()
	return focus_owner == control or (focus_owner != null and control.is_ancestor_of(focus_owner))


func _on_cycle_time_apply_pressed() -> void:
	_apply_cycle_time(int(_cycle_hour_spin.value), int(_cycle_minute_spin.value))


func _on_quick_time_pressed(hour: int, minute: int) -> void:
	_cycle_hour_spin.set_value_no_signal(hour)
	_cycle_minute_spin.set_value_no_signal(minute)
	_apply_cycle_time(hour, minute)


func _apply_cycle_time(hour: int, minute: int) -> void:
	var succeeded := _world_time_control != null and _world_time_control.request_set_cycle_time(hour, minute)
	_world_time_feedback.text = "日轮时间已设置为 %02d:%02d。" % [hour, minute] if succeeded else "无法设置日轮时间。"
	_refresh_world_time_controls()


func _on_time_scale_selected(index: int) -> void:
	if index < 0 or index >= TIME_SCALE_PRESETS.size():
		return
	var selected_scale := float(TIME_SCALE_PRESETS[index])
	var succeeded := _world_time_control != null and _world_time_control.request_set_time_scale(selected_scale)
	_world_time_feedback.text = "日轮倍率已设置为 %.0f×。" % selected_scale if succeeded else "无法设置日轮倍率。"
	_refresh_world_time_controls()


func _on_default_time_scale_pressed() -> void:
	var succeeded := _world_time_control != null and _world_time_control.request_set_time_scale(24.0)
	_world_time_feedback.text = "已恢复默认日轮倍率 24×。" if succeeded else "无法恢复默认倍率。"
	_refresh_world_time_controls()


func _on_time_pause_toggled(paused: bool) -> void:
	var succeeded := _world_time_control != null and _world_time_control.request_set_paused(paused)
	_world_time_feedback.text = "日轮已暂停。" if succeeded and paused else "日轮已恢复。" if succeeded else "无法更改暂停状态。"
	_refresh_world_time_controls()


func _on_calendar_override_pressed() -> void:
	var succeeded := _world_time_control != null and _world_time_control.request_set_calendar_override(
		int(_calendar_year_spin.value),
		int(_calendar_month_spin.value),
		int(_calendar_day_spin.value)
	)
	_world_time_feedback.text = "已启用固定日期调试覆盖。" if succeeded else "日期无效或权限不足，未应用覆盖。"
	_refresh_world_time_controls()


func _on_clear_calendar_override_pressed() -> void:
	var succeeded := _world_time_control != null and _world_time_control.request_clear_calendar_override()
	_world_time_feedback.text = "已恢复权威现实日历。" if succeeded else "无法恢复现实日历。"
	_refresh_world_time_controls()


func _on_weather_button_pressed(index: int) -> void:
	if _weather_controller != null:
		_weather_controller.call("set_weather_by_index", index)
		_refresh_weather_controls()


func _refresh_solar_controls() -> void:
	if _sun_elevation_slider == null or _sun_azimuth_slider == null:
		return
	_sun_elevation_slider.set_value_no_signal(_get_solar_value("elevation_degrees"))
	_sun_azimuth_slider.set_value_no_signal(_get_solar_value("azimuth_degrees"))


func _get_solar_value(key: String) -> float:
	if _day_night_visual_controller == null or not is_instance_valid(_day_night_visual_controller):
		return 0.0
	var state: Dictionary = _day_night_visual_controller.call("get_solar_state")
	return float(state.get(key, 0.0))


func _jump_to_next_moonrise() -> void:
	if not _can_run_astronomy_debug():
		return
	var snapshot := _world_time_control.get_snapshot()
	var date: Dictionary = snapshot.get("calendar_date", {})
	var cycle_seconds := float(snapshot.get("cycle_seconds", 0.0))
	var geo := _get_astronomy_georeference()
	if date.is_empty() or geo == null:
		_world_time_feedback.text = "无法读取当前日期或地图位置。"
		return
	var previous: Dictionary = MoonPositionScript.calculate(date, cycle_seconds, geo.origin_latitude_deg, geo.origin_longitude_deg)
	var found_seconds := -1.0
	for minute_offset in range(1, 1441):
		var candidate_seconds := fposmod(cycle_seconds + float(minute_offset * 60), 86400.0)
		var current: Dictionary = MoonPositionScript.calculate(date, candidate_seconds, geo.origin_latitude_deg, geo.origin_longitude_deg)
		if float(previous.get("elevation_degrees", -90.0)) < 0.0 and float(current.get("elevation_degrees", -90.0)) >= 0.0:
			found_seconds = candidate_seconds
			break
		previous = current
	if found_seconds < 0.0:
		_world_time_feedback.text = "当前日期和测试日轮中没有找到月出交点。"
		return
	var target_hour := int(found_seconds / 3600.0)
	var target_minute := int(fposmod(found_seconds, 3600.0) / 60.0)
	var succeeded := _world_time_control.request_set_cycle_time(target_hour, target_minute)
	_world_time_feedback.text = "已跳到下一次估算月出 %02d:%02d。" % [target_hour, target_minute] if succeeded else "跳转失败：当前控制端没有管理员权限。"
	_refresh_world_time_controls()


func _jump_to_lunar_phase(find_full_moon: bool) -> void:
	if not _can_run_astronomy_debug():
		return
	var snapshot := _world_time_control.get_snapshot()
	var start_date: Dictionary = snapshot.get("calendar_date", {})
	var geo := _get_astronomy_georeference()
	if start_date.is_empty() or geo == null:
		_world_time_feedback.text = "无法读取当前日期或地图位置。"
		return
	var best_score := INF
	var best_date: Dictionary = {}
	var best_seconds := -1.0
	for day_offset in range(0, 36):
		var candidate_date := _shift_gregorian_date(start_date, day_offset)
		var phase_state: Dictionary = MoonPositionScript.calculate(candidate_date, 12.0 * 3600.0, geo.origin_latitude_deg, geo.origin_longitude_deg)
		var illumination := float(phase_state.get("illumination_fraction", 0.0))
		var phase_score := 1.0 - illumination if find_full_moon else illumination
		for time_step in range(36, 48): # 18:00 through 23:30 Stockholm civil time.
			var seconds := float(time_step * 1800)
			var moon: Dictionary = MoonPositionScript.calculate(candidate_date, seconds, geo.origin_latitude_deg, geo.origin_longitude_deg)
			var sun: Dictionary = SolarPositionScript.calculate(candidate_date, seconds, geo.origin_latitude_deg, geo.origin_longitude_deg)
			var moon_elevation := float(moon.get("elevation_degrees", -90.0))
			var sun_elevation := float(sun.get("elevation_degrees", 90.0))
			var visibility_penalty := maxf(0.0, 8.0 - moon_elevation) * 0.002 + maxf(0.0, sun_elevation + 6.0) * 0.003
			var score := phase_score + visibility_penalty
			if moon_elevation > 0.0 and sun_elevation < -3.0 and score < best_score:
				best_score = score
				best_date = candidate_date
				best_seconds = seconds
	if best_date.is_empty():
		_world_time_feedback.text = "搜索期内没有合适的月相夜景时间。"
		return
	var date_applied := _world_time_control.request_set_calendar_override(int(best_date["year"]), int(best_date["month"]), int(best_date["day"]))
	var hour := int(best_seconds / 3600.0)
	var minute := int(fposmod(best_seconds, 3600.0) / 60.0)
	var time_applied := _world_time_control.request_set_cycle_time(hour, minute)
	var name := "满月" if find_full_moon else "新月"
	_world_time_feedback.text = "已启用日期调试覆盖：%04d-%02d-%02d %02d:%02d（%s测试）。“取消覆盖”可恢复现实日历。" % [int(best_date["year"]), int(best_date["month"]), int(best_date["day"]), hour, minute, name] if date_applied and time_applied else "月相测试跳转失败：当前控制端没有管理员权限。"
	_refresh_world_time_controls()


func _can_run_astronomy_debug() -> bool:
	if _world_time_control == null or not _world_time_control.can_modify():
		_world_time_feedback.text = "此控制端不允许修改权威世界时间。"
		return false
	return true


func _get_astronomy_georeference() -> GeoReference:
	if _day_night_visual_controller == null:
		return null
	return _day_night_visual_controller.get("georeference") as GeoReference


func _shift_gregorian_date(source: Dictionary, days: int) -> Dictionary:
	var year := int(source.get("year", 2026))
	var month := int(source.get("month", 1))
	var day := int(source.get("day", 1))
	for _step in range(days):
		day += 1
		var month_days := _days_in_month(year, month)
		if day > month_days:
			day = 1
			month += 1
			if month > 12:
				month = 1
				year += 1
	return {"year": year, "month": month, "day": day}


func _days_in_month(year: int, month: int) -> int:
	var days := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if month == 2 and (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)):
		return 29
	return int(days[clampi(month - 1, 0, 11)])


func _phase_name_zh(phase_name: String) -> String:
	match phase_name:
		"New Moon": return "新月"
		"Waxing Crescent": return "蛾眉月（盈）"
		"First Quarter": return "上弦月"
		"Waxing Gibbous": return "盈凸月"
		"Full Moon": return "满月"
		"Waning Gibbous": return "亏凸月"
		"Last Quarter": return "下弦月"
		"Waning Crescent": return "残月"
		_: return "不可用"


func _on_cloud_changed(value: float) -> void:
	if _weather_controller != null:
		_weather_controller.call("set_cloud_coverage", value)


func _on_wave_changed(value: float) -> void:
	if _weather_controller != null:
		_weather_controller.call("set_wave_strength", value)
	elif _wave_sampler != null:
		_wave_sampler.set("wave_strength", value)


func _on_extreme_sea_selected(index: int) -> void:
	if _wave_sampler == null or not _wave_sampler.has_method("clear_extreme_sea_test"):
		return
	if index == 0:
		_wave_sampler.call("clear_extreme_sea_test")
		if _shallow_wave_constraint_toggle != null:
			_shallow_wave_constraint_toggle.set_pressed_no_signal(false)
			_apply_shallow_wave_options()
		_update_extreme_sea_status()
		return
	if not _apply_selected_extreme_sea_shape():
		_extreme_sea_option.select(0)
		_update_extreme_sea_status()
		return
	_wave_slider.editable = false
	if _shallow_wave_constraint_toggle != null:
		_shallow_wave_constraint_toggle.set_pressed_no_signal(true)
		_apply_shallow_wave_options()
	_update_extreme_sea_status()


func _on_extreme_wave_shape_changed(_value: float) -> void:
	if _extreme_sea_option == null or _extreme_sea_option.selected == 0:
		return
	_apply_selected_extreme_sea_shape()
	_update_extreme_sea_status()


func _on_extreme_wave_defaults_pressed() -> void:
	if _wave_compactness_slider == null or _wave_sharpness_slider == null:
		return
	_wave_compactness_slider.set_value_no_signal(1.0)
	_wave_sharpness_slider.set_value_no_signal(0.0)
	if _extreme_sea_option != null and _extreme_sea_option.selected > 0:
		_apply_selected_extreme_sea_shape()
	_update_extreme_sea_status()


func _on_shallow_wave_constraint_toggled(_enabled: bool) -> void:
	_apply_shallow_wave_options()


func _on_shallow_wave_options_changed(_value: float) -> void:
	_apply_shallow_wave_options()


func _on_shallow_wave_defaults_pressed() -> void:
	if _shallow_wave_constraint_toggle == null:
		return
	_shallow_wave_full_depth_slider.set_value_no_signal(30.0)
	_shallow_wave_min_scale_slider.set_value_no_signal(0.40)
	_shallow_wave_safe_ratio_slider.set_value_no_signal(0.20)
	_shallow_wave_constraint_toggle.set_pressed_no_signal(
		_extreme_sea_option != null and _extreme_sea_option.selected > 0
	)
	_apply_shallow_wave_options()


func _sync_shallow_wave_controls() -> void:
	if _shallow_wave_constraint_toggle == null:
		return
	if _wave_sampler == null:
		_shallow_wave_constraint_toggle.set_pressed_no_signal(false)
		return
	_shallow_wave_constraint_toggle.set_pressed_no_signal(bool(_wave_sampler.get("shallow_wave_constraint_enabled")))
	_shallow_wave_full_depth_slider.set_value_no_signal(float(_wave_sampler.get("shallow_wave_full_depth_m")))
	_shallow_wave_min_scale_slider.set_value_no_signal(float(_wave_sampler.get("shallow_wave_min_amplitude_scale")))
	_shallow_wave_safe_ratio_slider.set_value_no_signal(float(_wave_sampler.get("shallow_wave_safe_depth_ratio")))


func _apply_shallow_wave_options() -> void:
	if _wave_sampler == null or not _wave_sampler.has_method("set_shallow_wave_constraint_options"):
		return
	_wave_sampler.call(
		"set_shallow_wave_constraint_options",
		_shallow_wave_constraint_toggle.button_pressed,
		_shallow_wave_full_depth_slider.value,
		_shallow_wave_min_scale_slider.value,
		_shallow_wave_safe_ratio_slider.value
	)
	_update_shallow_wave_status()


func _update_shallow_wave_status() -> void:
	if _shallow_wave_status == null:
		return
	if _wave_sampler == null or not _wave_sampler.has_method("get_shallow_wave_diagnostics"):
		_shallow_wave_status.text = "浅水约束数据不可用"
		return
	var diagnostics: Dictionary = _wave_sampler.call("get_shallow_wave_diagnostics", _controller.global_position)
	var coverage := float(diagnostics.get("coverage", 0.0))
	var depth_text := "未知水深（按浅水保守处理）"
	if bool(diagnostics.get("valid", false)):
		depth_text = "%.2f m LAT · 有效" % float(diagnostics.get("depth_m", 0.0))
	elif coverage > 0.0:
		depth_text = "纹理覆盖 %.0f%% · 保守深度 %.2f m · 无效" % [coverage * 100.0, float(diagnostics.get("effective_depth_m", 0.0))]
	var theoretical_trough := float(diagnostics.get("theoretical_max_trough_excursion_m", 0.0))
	var constrained_trough := float(diagnostics.get("constrained_max_trough_excursion_m", theoretical_trough))
	_shallow_wave_status.text = "当前位置水深：%s\n安全余量 %.0f%% · 允许最大波谷下探 %.2f m · 约束%s\n视觉分区倍率 %.2f · 波谷安全倍率 %.2f · 最终振幅倍率 %.2f\n原始理论最大波谷 %.2f m · 约束后最大波谷 %.2f m\n完整波浪阈值 %.0f m · 3 m 振幅点 %.2f" % [
		depth_text,
		float(diagnostics.get("safe_depth_ratio", 0.20)) * 100.0,
		float(diagnostics.get("allowed_trough_m", 0.0)),
		"开启" if bool(diagnostics.get("enabled", false)) else "关闭",
		float(diagnostics.get("visual_zone_scale", 1.0)),
		float(diagnostics.get("safety_scale", 1.0)),
		float(diagnostics.get("amplitude_scale", 1.0)),
		theoretical_trough,
		constrained_trough,
		float(_wave_sampler.get("shallow_wave_full_depth_m")),
		float(_wave_sampler.get("shallow_wave_min_amplitude_scale")),
	]


func _apply_selected_extreme_sea_shape() -> bool:
	if _wave_sampler == null or _extreme_sea_option == null or _extreme_sea_option.selected == 0:
		return false
	if not _wave_sampler.has_method("set_extreme_sea_test"):
		return false
	var targets := [5.0, 10.0, 20.0, 30.0]
	var target_height_m: float = targets[_extreme_sea_option.selected - 1]
	var base_settings := _wave_sampler.get("wave_settings") as SeaWaveSettings
	var compactness := float(_wave_compactness_slider.value) if _wave_compactness_slider != null else 1.0
	var sharpness := float(_wave_sharpness_slider.value) if _wave_sharpness_slider != null else 0.0
	var test_settings: SeaWaveSettings = ExtremeSeaStatePresetsScript.build_settings(
		base_settings,
		target_height_m,
		compactness,
		sharpness
	)
	if test_settings == null:
		return false
	return bool(_wave_sampler.call("set_extreme_sea_test", test_settings, target_height_m))


func _update_extreme_sea_status() -> void:
	if _extreme_sea_status == null or _extreme_sea_option == null:
		return
	if _wave_sampler == null:
		_extreme_sea_status.text = "WaveSampler 未连接"
		return
	var selected := _extreme_sea_option.selected
	var test_active := bool(_wave_sampler.call("is_extreme_sea_test_active")) if _wave_sampler.has_method("is_extreme_sea_test_active") else false
	_wave_slider.editable = not test_active
	var transitioning := bool(_wave_sampler.call("is_extreme_sea_test_transitioning")) if _wave_sampler.has_method("is_extreme_sea_test_transitioning") else false
	var restoring := bool(_wave_sampler.call("is_extreme_sea_test_restoring")) if _wave_sampler.has_method("is_extreme_sea_test_restoring") else false
	var shape_controls_active := selected > 0 and test_active and not restoring
	if _wave_compactness_slider != null:
		_wave_compactness_slider.editable = shape_controls_active
	if _wave_sharpness_slider != null:
		_wave_sharpness_slider.editable = shape_controls_active
	if _extreme_wave_defaults_button != null:
		_extreme_wave_defaults_button.disabled = not shape_controls_active
	if selected == 0:
		_extreme_sea_status.text = "正常天气波浪" + (" · 正在平滑恢复" if transitioning else " · 天气系统接管")
		return
	var targets := [5.0, 10.0, 20.0, 30.0]
	var target_height_m: float = targets[selected - 1]
	var compactness := float(_wave_compactness_slider.value) if _wave_compactness_slider != null else 1.0
	var sharpness := float(_wave_sharpness_slider.value) if _wave_sharpness_slider != null else 0.0
	var profile: Dictionary = ExtremeSeaStatePresetsScript.profile_for_height(target_height_m, compactness)
	var state_text := "参数平滑过渡中" if transitioning else "测试参数已应用"
	if restoring:
		state_text = "正在恢复当前天气波浪"
	_extreme_sea_status.text = "目标波高 %.0f m（波峰到波谷构造包络，不等同显著波高）\n紧凑度 %.2f · 波峰陡度 %.2f\n主涌浪 λ %.1f m / %.1f s；次涌浪 λ %.1f m / %.1f s；中尺度 λ %.1f m / %.1f s\n%s" % [
		target_height_m,
		compactness,
		sharpness,
		float(profile["main_wavelength_m"]),
		float(profile["main_period_s"]),
		float(profile["cross_wavelength_m"]),
		float(profile["cross_period_s"]),
		float(profile["medium_wavelength_m"]),
		float(profile["medium_period_s"]),
		state_text,
	]


func _exit_tree() -> void:
	if is_instance_valid(_wave_sampler) and _wave_sampler.has_method("clear_extreme_sea_test"):
		_wave_sampler.call("clear_extreme_sea_test")


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

