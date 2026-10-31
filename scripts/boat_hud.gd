extends CanvasLayer

## Small status display for the boat prototype. Speed is stored in m/s and
## converted to knots only for display (1 m/s = 1.94384 kn).

const COMPASS_HUD_SCRIPT := preload("res://scripts/compass_hud.gd")
const LocalTimeControlScript := preload("res://scripts/local_world_time_control.gd")
const MoonPositionScript := preload("res://scripts/moon_position.gd")
const SolarPositionScript := preload("res://scripts/solar_position.gd")
const ExtremeSeaStatePresetsScript := preload("res://scripts/extreme_sea_state_presets.gd")
const VesselPreviewCardScript := preload("res://scripts/vessel_preview_card.gd")
const SAILING_NAVIGATION_INSTRUMENT_SCRIPT := preload("res://scripts/sailboat_navigation_instrument.gd")
const SAILING_POLAR_CHART_SCRIPT := preload("res://scripts/sailing_polar_chart.gd")
const FISHING_DEBUG_PANEL_SCRIPT := preload("res://scripts/fishing_debug_panel.gd")
const FISHING_PLAYER_PANEL_SCRIPT := preload("res://scripts/fishing_player_panel.gd")
const FISH_FINDER_DISPLAY_SCRIPT := preload("res://scripts/fish_finder_display.gd")
const NAVIGATION_HUD_FORMAT := preload("res://scripts/navigation_hud_format.gd")
const TIME_SCALE_PRESETS := [1.0, 6.0, 12.0, 24.0, 60.0]

@export_node_path("Node3D") var controller_path := NodePath("../MotionRoot")
@export_node_path("Node") var weather_controller_path := NodePath("../../WeatherController")
@export_node_path("Node") var weather_state_controller_path := NodePath("../../WeatherStateController")
@export_node_path("Node") var day_night_visual_controller_path := NodePath("../../DayNightVisualController")
@export_node_path("Node") var wave_sampler_path := NodePath("../../WaveSampler")
@export_node_path("Node") var quality_manager_path := NodePath("../../QualityManager")
@export_node_path("Node") var fish_resource_manager_path := NodePath("../../FishResourceManager")
@export_node_path("Node") var wind_field_path := NodePath("../../WindField")
@export_node_path("Node3D") var fish_school_renderer_path := NodePath("../../FishResourceManager/FishSchoolRenderer")
@export_node_path("Node") var dolphin_world_manager_path := NodePath("../../DolphinWorldManager")
@export_node_path("Node") var navigation_depth_monitor_path := NodePath("../../NavigationDepthMonitor")
@export_node_path("Node") var cargo_economy_manager_path := NodePath("../../CargoEconomyManager")
@export_node_path("Node") var autopilot_controller_path := NodePath("../../AutopilotController")
@export_node_path("Node") var oresund_region_path := NodePath("../../OresundRegion")
@export_node_path("Node") var boat_audio_controller_path := NodePath("../../BoatAudioController")
@export_node_path("Node") var game_menu_path := NodePath("../../GameMenu")
@export_node_path("Node") var fish_map_path := NodePath("../../FishResourceMap")
@export_node_path("Node") var fishing_rod_system_path := NodePath("../FishingRodSystem")
@export_node_path("Node") var weather_runtime_authority_path := NodePath("../../WeatherRuntimeAuthority")

var _controller: BoatController
var _weather_controller: Node
var _weather_state_controller: Node
var _day_night_visual_controller: Node
var _wave_sampler: Node
var _quality_manager: Node
var _diagnostic_bathymetry: Node
var _diagnostic_seabed_manager: Node
var _fish_resource_manager: FishResourceManager
var _wind_field: Node
var _fish_school_renderer: FishSchoolRenderer
var _fish_finder_display: Control
var _fish_finder_toggle_button: Button
var _dolphin_world_manager: Node
var _navigation_depth_monitor: NavigationDepthMonitor
var _cargo_economy_manager: CargoEconomyManager
var _autopilot_controller: AutopilotController
var _boat_audio_controller: Node
var _oresund_region: Node
var _game_menu: Node
var _fish_map: Node
var _fishing_rod_system: FishingRodSystem
var _weather_runtime_authority: Node
var _fishing_player_panel: FishingPlayerPanel
var _catch_result_panel: PanelContainer
var _catch_result_title: Label
var _catch_result_species: Label
var _catch_result_length: Label
var _catch_result_weight: Label
var _catch_result_card_hold_remaining := 0.0
var _catch_result_card_is_retained := false
const CATCH_RESULT_CARD_HOLD_SECONDS := 12.0
const CATCH_RESULT_CARD_FADE_SECONDS := 0.6
var _port_service_controllers: Array[Node] = []
var _selected_fish_school_id := ""
var _world_time_control: WorldTimeControlPort
var _status_panel: PanelContainer
var _status_label: Label
var _environment_title_label: Label
var _environment_details_button: Button
var _environment_detail_panel: PanelContainer
var _environment_detail_label: Label
var _activity_button: Button
var _activity_menu: PanelContainer
var _navigation_core_panel: PanelContainer
var _navigation_core_title: Label
var _navigation_speed_label: Label
var _navigation_core_detail: Label
var _navigation_core_extra_detail: Label
var _navigation_detail_button: Button
var _navigation_detail_requested := false
var _environment_detail_requested := false
var _restore_map_mini_after_finder := false
var _help_panel: PanelContainer
var _help_label: Label
var _map_button: Button
var _fps_label: Label
var _depth_label: Label
var _cargo_task_label: Label
var _debug_panel: PanelContainer
var _debug_scroll: TabContainer
var _debug_layout: VBoxContainer
var _weather_label: Label
var _weather_runtime_status_label: Label
var _sun_label: Label
var _moon_label: Label
var _cloud_label: Label
var _wave_label: Label
var _performance_label: Label
var _perf_sample_duration_option: OptionButton
var _perf_sample_button: Button
var _diagnostic_scale_option: OptionButton
var _water_fragment_toggle: CheckButton
var _building_visual_toggle: CheckButton
var _seagrass_visual_toggle: CheckButton
var _perf_frame_samples := PackedFloat64Array()
var _perf_last_tick_usec := 0
var _perf_elapsed_seconds := 0.0
var _perf_target_duration_seconds := 30.0
var _perf_sampling_active := false
var _perf_sample_result := "等待开始"
var _building_visual_roots: Array[Node] = []
var _building_visual_previous_states: Dictionary = {}
var _building_visuals_hidden := false
var _debug_panel_snapshot: Dictionary = {}
var _debug_panel_visual_snapshot: Dictionary = {}
var _sailboat_physics_label: Label
var _fish_location_feedback: Label
var _fish_observation_species_row: GridContainer
var _fish_observation_species_status: Label
var _fish_resources_initialized := false
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
var _status_refresh_elapsed := 0.0
var _navigation_refresh_elapsed := 0.0
var _autopilot_panel: PanelContainer
var _autopilot_label: Label
var _peberholm_debug_button: Button
var _peberholm_debug_feedback: Label
var _city_lighting_toggle: CheckButton
var _city_window_strength_slider: HSlider
var _city_density_mode_option: OptionButton
var _city_window_density_slider: HSlider
var _city_mask_debug_toggle: CheckButton
var _city_turning_torso_slider: HSlider
var _city_contour_slider: HSlider
var _city_residential_slider: HSlider
var _city_office_slider: HSlider
var _city_street_slider: HSlider
var _city_lighting_mode_option: OptionButton
var _city_lighting_status: Label
var _city_lighting_save_button: Button
var _city_lighting_reset_button: Button
var _sailing_panel: PanelContainer
var _sailing_speed_label: Label
var _sailing_heading_label: Label
var _sailing_heel_label: Label
var _sailing_true_wind_speed_label: Label
var _sailing_true_wind_direction_label: Label
var _sailing_relative_wind_label: Label
var _sailing_mode_label: Label
var _sailing_status_label: Label
var _sailing_trim_angles_label: Label
var _sailing_detail_label: Label
var _sailing_control_hint_label: Label
var _sailing_auto_toggle: CheckButton
var _main_deployment_slider: HSlider
var _main_deployment_status: Label
var _jib_deployment_slider: HSlider
var _jib_deployment_status: Label
var _auto_reef_toggle: CheckButton
var _auto_reef_status: Label
var _aux_engine_status_label: Label
var _aux_engine_fuel_label: Label
var _aux_engine_panel: VBoxContainer
var _aux_engine_toggle_button: Button
var _aux_engine_gear_option: OptionButton
var _aux_engine_throttle_slider: HSlider
var _aux_engine_feedback_label: Label
var _aux_engine_feedback_key := "hud.sailing.engine_controls_help"
var _sailing_navigation_instrument: Control
var _polar_toggle_button: Button
var _polar_panel: PanelContainer
var _polar_chart: Control
var _polar_detail_label: Label
var _polar_requested := false
var _compass_widget: Control
var _sailing_refresh_elapsed := 0.0
var _last_auto_trim_state := false
var _last_auto_reef_state := false
var _manual_trim_notice_until_msec := 0
var _manual_reef_notice_until_msec := 0
var _vessel_picker_overlay: Control
var _vessel_picker_close_button: Button
var _vessel_picker_title: Label
var _vessel_picker_note: Label
var _vessel_picker_cards: Array[Control] = []
var _vessel_picker_previous_manual_input := true


func _ready() -> void:
	_controller = get_node_or_null(controller_path) as BoatController
	if _controller == null:
		push_error("Boat HUD could not find its controller at %s." % controller_path)
		return
	_weather_controller = get_node_or_null(weather_controller_path)
	_weather_state_controller = get_node_or_null(weather_state_controller_path)
	_day_night_visual_controller = get_node_or_null(day_night_visual_controller_path)
	_wave_sampler = get_node_or_null(wave_sampler_path)
	_quality_manager = get_node_or_null(quality_manager_path)
	_diagnostic_bathymetry = get_node_or_null("../../BathymetryManager")
	_diagnostic_seabed_manager = get_node_or_null("../../ShallowSeabedManager")
	_cache_building_visual_roots()
	_fish_resource_manager = get_node_or_null(fish_resource_manager_path) as FishResourceManager
	_wind_field = get_node_or_null(wind_field_path)
	_fish_school_renderer = get_node_or_null(fish_school_renderer_path) as FishSchoolRenderer
	_fish_resources_initialized = _fish_resource_manager != null and _fish_resource_manager.is_node_ready()
	if _fish_resource_manager != null and not _fish_resources_initialized and _fish_resource_manager.has_signal("resources_ready"):
		_fish_resource_manager.connect("resources_ready", _on_fish_resources_ready, CONNECT_ONE_SHOT)
	_dolphin_world_manager = get_node_or_null(dolphin_world_manager_path)
	_navigation_depth_monitor = get_node_or_null(navigation_depth_monitor_path) as NavigationDepthMonitor
	_cargo_economy_manager = get_node_or_null(cargo_economy_manager_path) as CargoEconomyManager
	_autopilot_controller = get_node_or_null(autopilot_controller_path) as AutopilotController
	_boat_audio_controller = get_node_or_null(boat_audio_controller_path)
	_oresund_region = get_node_or_null(oresund_region_path)
	_game_menu = get_node_or_null(game_menu_path)
	_fish_map = get_node_or_null(fish_map_path)
	_weather_runtime_authority = get_node_or_null(weather_runtime_authority_path)
	if _fish_map != null and _fish_map.has_signal("display_mode_changed"):
		_fish_map.connect("display_mode_changed", _on_map_display_mode_changed)
	_fishing_rod_system = get_node_or_null(fishing_rod_system_path) as FishingRodSystem
	for service_path in [
		NodePath("../../MalmoHarbor/PortServiceController"),
		NodePath("../../CopenhagenHarbor/PortServiceController"),
	]:
		var service := get_node_or_null(service_path)
		if service != null:
			_port_service_controllers.append(service)
	var time_manager := get_tree().root.get_node_or_null("WorldTimeManager")
	_world_time_control = LocalTimeControlScript.new(time_manager) as WorldTimeControlPort

	_status_panel = PanelContainer.new()
	_status_panel.name = "EnvironmentSummaryPanel"
	_status_panel.position = Vector2(24.0, 24.0)
	_status_panel.custom_minimum_size = Vector2(300.0, 0.0)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.035, 0.12, 0.16, 0.82)
	panel_style.set_corner_radius_all(8)
	panel_style.content_margin_left = 15.0
	panel_style.content_margin_right = 15.0
	panel_style.content_margin_top = 8.0
	panel_style.content_margin_bottom = 8.0
	_status_panel.add_theme_stylebox_override("panel", panel_style)
	var status_layout := VBoxContainer.new()
	status_layout.add_theme_constant_override("separation", 3)
	_status_panel.add_child(status_layout)
	var environment_header := HBoxContainer.new()
	_environment_title_label = Label.new()
	_environment_title_label.text = tr("hud.environment.title")
	_environment_title_label.add_theme_color_override("font_color", Color(0.58, 0.83, 0.82))
	_environment_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	environment_header.add_child(_environment_title_label)
	_environment_details_button = Button.new()
	_environment_details_button.name = "EnvironmentDetailsButton"
	_environment_details_button.text = tr("hud.environment.details")
	_environment_details_button.focus_mode = Control.FOCUS_NONE
	_environment_details_button.pressed.connect(_toggle_environment_details)
	environment_header.add_child(_environment_details_button)
	status_layout.add_child(environment_header)
	_status_label = Label.new()
	_status_label.name = "EnvironmentSummaryText"
	_status_label.add_theme_color_override("font_color", Color(0.91, 0.96, 0.94, 1.0))
	_status_label.add_theme_font_size_override("font_size", 14)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_layout.add_child(_status_label)
	_fps_label = Label.new()
	_fps_label.name = "FPSDisplay"
	_fps_label.text = "FPS: --"
	_fps_label.add_theme_color_override("font_color", Color(0.68, 0.80, 0.79, 1.0))
	_fps_label.add_theme_font_size_override("font_size", 13)
	_fps_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	status_layout.add_child(_fps_label)
	_depth_label = Label.new()
	_depth_label.name = "ReferenceDepthStatus"
	_depth_label.add_theme_color_override("font_color", Color(0.82, 0.93, 0.92, 1.0))
	_depth_label.add_theme_font_size_override("font_size", 14)
	_depth_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_depth_label.visible = false
	status_layout.add_child(_depth_label)
	_cargo_task_label = Label.new()
	_cargo_task_label.name = "CargoTaskStatus"
	_cargo_task_label.add_theme_color_override("font_color", Color(0.84, 0.88, 0.77, 1.0))
	_cargo_task_label.add_theme_font_size_override("font_size", 14)
	_cargo_task_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_cargo_task_label.visible = false
	status_layout.add_child(_cargo_task_label)
	add_child(_status_panel)
	_build_environment_detail_panel()
	_build_activity_menu()
	_build_navigation_core_panel()
	_build_autopilot_panel()
	_build_fish_finder_display()
	_build_debug_panel()
	_add_compass_widget()
	_build_sailing_panel()
	_build_fishing_player_panel()
	_build_catch_result_panel()
	_build_vessel_picker()
	_controller.vessel_mode_changed.connect(_on_vessel_mode_changed)
	var localization_manager := get_node_or_null("/root/LocalizationManager")
	if localization_manager != null and localization_manager.has_signal("locale_changed"):
		localization_manager.connect("locale_changed", _on_locale_changed)
	if _quality_manager != null and _quality_manager.has_signal("settings_changed"):
		_quality_manager.connect("settings_changed", _on_interface_settings_changed)
	_update_status()
	_update_navigation_core_panel()
	_update_hud_layout()
	get_viewport().size_changed.connect(_update_hud_layout)


func _build_environment_detail_panel() -> void:
	_environment_detail_panel = PanelContainer.new()
	_environment_detail_panel.name = "EnvironmentDetailsPanel"
	_environment_detail_panel.custom_minimum_size = Vector2(340.0, 0.0)
	_environment_detail_panel.visible = false
	_environment_detail_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.12, 0.16, 0.91)
	style.border_color = Color(0.28, 0.52, 0.55, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 9.0
	style.content_margin_bottom = 9.0
	_environment_detail_panel.add_theme_stylebox_override("panel", style)
	var layout := VBoxContainer.new()
	_environment_detail_panel.add_child(layout)
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = tr("hud.environment.details")
	title.name = "EnvironmentDetailsTitle"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button := Button.new()
	close_button.name = "CloseEnvironmentDetails"
	close_button.text = "×"
	close_button.tooltip_text = tr("hud.close")
	close_button.pressed.connect(_toggle_environment_details)
	header.add_child(close_button)
	layout.add_child(header)
	_environment_detail_label = Label.new()
	_environment_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_environment_detail_label)
	add_child(_environment_detail_panel)


func _build_activity_menu() -> void:
	_activity_button = Button.new()
	_activity_button.name = "ActivitiesButton"
	_activity_button.text = tr("hud.activities.title")
	_activity_button.focus_mode = Control.FOCUS_NONE
	_activity_button.custom_minimum_size = Vector2(180.0, 42.0)
	_activity_button.pressed.connect(_toggle_activity_menu)
	add_child(_activity_button)
	_activity_menu = PanelContainer.new()
	_activity_menu.name = "ActivitiesMenu"
	_activity_menu.visible = false
	_activity_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.12, 0.16, 0.91)
	style.border_color = Color(0.28, 0.52, 0.55, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	_activity_menu.add_theme_stylebox_override("panel", style)
	var menu := VBoxContainer.new()
	menu.add_theme_constant_override("separation", 5)
	_activity_menu.add_child(menu)
	var trolling := Button.new()
	trolling.name = "OpenTrollingActivity"
	trolling.text = tr("hud.activities.trolling")
	trolling.pressed.connect(_open_trolling_activity)
	menu.add_child(trolling)
	var finder := Button.new()
	finder.name = "OpenFishFinderTool"
	finder.text = tr("hud.activities.fish_finder")
	finder.pressed.connect(_open_fish_finder_tool)
	menu.add_child(finder)
	var help := Button.new()
	help.name = "OpenControlsHelp"
	help.text = tr("hud.activities.controls_help")
	help.pressed.connect(_toggle_controls_help)
	menu.add_child(help)
	add_child(_activity_menu)

	_map_button = Button.new()
	_map_button.name = "MapToolButton"
	_map_button.text = tr("hud.map.open")
	_map_button.focus_mode = Control.FOCUS_NONE
	_map_button.custom_minimum_size = Vector2(112.0, 38.0)
	_map_button.pressed.connect(_open_map_tool)
	add_child(_map_button)
	_build_controls_help_panel()


func _build_controls_help_panel() -> void:
	_help_panel = PanelContainer.new()
	_help_panel.name = "ControlsHelpPanel"
	_help_panel.visible = false
	_help_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.12, 0.16, 0.92)
	style.border_color = Color(0.28, 0.52, 0.55, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 9.0
	style.content_margin_bottom = 9.0
	_help_panel.add_theme_stylebox_override("panel", style)
	var layout := VBoxContainer.new()
	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = tr("hud.activities.controls_help")
	title.name = "ControlsHelpTitle"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button := Button.new()
	close_button.name = "CloseControlsHelp"
	close_button.text = "×"
	close_button.tooltip_text = tr("hud.close")
	close_button.pressed.connect(func() -> void: _help_panel.visible = false)
	header.add_child(close_button)
	layout.add_child(header)
	_help_label = Label.new()
	_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_help_label)
	_help_panel.add_child(layout)
	add_child(_help_panel)
	_update_controls_help_text()


func _build_navigation_core_panel() -> void:
	_navigation_core_panel = PanelContainer.new()
	_navigation_core_panel.name = "NavigationCorePanel"
	_navigation_core_panel.anchor_left = 1.0
	_navigation_core_panel.anchor_right = 1.0
	_navigation_core_panel.anchor_top = 1.0
	_navigation_core_panel.anchor_bottom = 1.0
	_navigation_core_panel.offset_left = -330.0
	_navigation_core_panel.offset_top = -150.0
	_navigation_core_panel.offset_right = -18.0
	_navigation_core_panel.offset_bottom = -18.0
	_navigation_core_panel.custom_minimum_size = Vector2(310.0, 116.0)
	_navigation_core_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.12, 0.16, 0.88)
	style.border_color = Color(0.28, 0.52, 0.55, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 8.0
	style.content_margin_bottom = 8.0
	_navigation_core_panel.add_theme_stylebox_override("panel", style)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 2)
	_navigation_core_panel.add_child(layout)
	var header := HBoxContainer.new()
	_navigation_core_title = Label.new()
	_navigation_core_title.text = tr("hud.navigation.title")
	_navigation_core_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_navigation_core_title)
	_navigation_detail_button = Button.new()
	_navigation_detail_button.name = "NavigationInstrumentExpandButton"
	_navigation_detail_button.text = tr("hud.navigation.expand")
	_navigation_detail_button.focus_mode = Control.FOCUS_NONE
	_navigation_detail_button.pressed.connect(_toggle_navigation_details)
	header.add_child(_navigation_detail_button)
	layout.add_child(header)
	_navigation_speed_label = Label.new()
	_navigation_speed_label.add_theme_font_size_override("font_size", 28)
	_navigation_speed_label.add_theme_color_override("font_color", Color(0.97, 0.99, 0.95))
	layout.add_child(_navigation_speed_label)
	_navigation_core_detail = Label.new()
	_navigation_core_detail.name = "NavigationCoreStatus"
	_navigation_core_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_navigation_core_detail.add_theme_color_override("font_color", Color(0.72, 0.84, 0.81))
	_navigation_core_detail.visible = true
	layout.add_child(_navigation_core_detail)
	_navigation_core_extra_detail = Label.new()
	_navigation_core_extra_detail.name = "NavigationCoreExtraStatus"
	_navigation_core_extra_detail.add_theme_font_size_override("font_size", 12)
	_navigation_core_extra_detail.add_theme_color_override("font_color", Color(0.62, 0.75, 0.73))
	_navigation_core_extra_detail.visible = false
	layout.add_child(_navigation_core_extra_detail)
	add_child(_navigation_core_panel)


func _toggle_activity_menu() -> void:
	_activity_menu.visible = not _activity_menu.visible
	if _activity_menu.visible and _help_panel != null:
		_help_panel.visible = false
	_update_hud_layout()


func _open_trolling_activity() -> void:
	_activity_menu.visible = false
	if _fishing_player_panel == null:
		return
	_fishing_player_panel.set_collapsed(false)
	_fishing_player_panel.visible = true
	_update_hud_layout()


func _open_fish_finder_tool() -> void:
	_activity_menu.visible = false
	if _fish_map != null and _fish_map.has_method("get_display_mode") and str(_fish_map.call("get_display_mode")) == "mini":
		_restore_map_mini_after_finder = true
		_fish_map.call("set_display_mode", "hidden")
	_prepare_major_tool("finder")
	if _fish_finder_display != null:
		_fish_finder_display.call("set_expanded", false)
		_fish_finder_display.call("open_display")
	_update_hud_layout()


func _open_map_tool() -> void:
	if _fish_map == null:
		return
	_activity_menu.visible = false
	_prepare_major_tool("map")
	if _fish_map.has_method("set_display_mode"):
		_fish_map.call("set_display_mode", "expanded")
	elif _fish_map.has_method("set_map_open"):
		_fish_map.call("set_map_open", true)
	_update_hud_layout()


func _toggle_environment_details() -> void:
	_environment_detail_requested = not _environment_detail_requested
	_environment_detail_panel.visible = _environment_detail_requested
	if _environment_detail_requested:
		_prepare_major_tool("environment")
		_update_environment_summary()
	_update_hud_layout()


func _toggle_navigation_details() -> void:
	_navigation_detail_requested = not _navigation_detail_requested
	_navigation_detail_button.text = tr("hud.navigation.collapse") if _navigation_detail_requested else tr("hud.navigation.expand")
	if _navigation_detail_requested:
		_prepare_major_tool("navigation")
	_update_sailing_panel()
	_update_navigation_core_panel()
	_update_hud_layout()


func _toggle_controls_help() -> void:
	_activity_menu.visible = false
	_help_panel.visible = not _help_panel.visible
	if _help_panel.visible:
		_prepare_major_tool("help")
	_update_controls_help_text()
	_update_hud_layout()


func _prepare_major_tool(tool_name: String) -> void:
	if tool_name != "environment":
		_environment_detail_requested = false
		if _environment_detail_panel != null:
			_environment_detail_panel.visible = false
	if tool_name != "map" and _fish_map != null and _fish_map.has_method("set_display_mode"):
		if str(_fish_map.call("get_display_mode")) == "expanded":
			_fish_map.call("set_display_mode", "mini")
	if tool_name != "finder" and _fish_finder_display != null:
		if str(_fish_finder_display.call("get_display_mode")) != "hidden":
			_fish_finder_display.call("close_display")
			if _restore_map_mini_after_finder and tool_name != "map" and _fish_map != null:
				_fish_map.call("set_display_mode", "mini")
			_restore_map_mini_after_finder = false
	if tool_name != "navigation":
		_navigation_detail_requested = false
		if _navigation_detail_button != null:
			_navigation_detail_button.text = tr("hud.navigation.expand")
	if tool_name != "help" and _help_panel != null:
		_help_panel.visible = false
	_update_sailing_panel()


func _build_trolling_panel_signals() -> void:
	if _fishing_player_panel == null:
		return
	_fishing_player_panel.close_requested.connect(_on_trolling_configuration_closed)
	_fishing_player_panel.activity_state_changed.connect(_on_trolling_activity_state_changed)


func _on_trolling_configuration_closed() -> void:
	if _fishing_player_panel != null and not _fishing_player_panel.is_trolling_active():
		_fishing_player_panel.visible = false


func _on_trolling_activity_state_changed(active: bool) -> void:
	if _fishing_player_panel == null:
		return
	_fishing_player_panel.visible = active
	if active:
		_fishing_player_panel.set_collapsed(false)
	_update_hud_layout()


func _update_controls_help_text() -> void:
	if _help_label == null or _controller == null:
		return
	if _controller.is_sailing_active():
		_help_label.text = tr("hud.help.sailboat") % [
			NAVIGATION_HUD_FORMAT.action_key_hint("boat_turn_left"),
			NAVIGATION_HUD_FORMAT.action_key_hint("boat_turn_right"),
			NAVIGATION_HUD_FORMAT.action_key_hint("sailboat_main_trim_ease"),
			NAVIGATION_HUD_FORMAT.action_key_hint("sailboat_main_trim_out"),
			NAVIGATION_HUD_FORMAT.action_key_hint("sailboat_toggle_auto_trim"),
		]
	else:
		_help_label.text = tr("hud.help.powerboat") % [
			NAVIGATION_HUD_FORMAT.action_key_hint("boat_accelerate"),
			NAVIGATION_HUD_FORMAT.action_key_hint("boat_brake"),
			NAVIGATION_HUD_FORMAT.action_key_hint("boat_turn_left"),
			NAVIGATION_HUD_FORMAT.action_key_hint("boat_turn_right"),
			NAVIGATION_HUD_FORMAT.action_key_hint("boat_toggle_autopilot"),
		]


func _on_locale_changed(_locale_id: String) -> void:
	if _environment_title_label != null:
		_environment_title_label.text = tr("hud.environment.title")
	if _environment_details_button != null:
		_environment_details_button.text = tr("hud.environment.details")
		_environment_details_button.tooltip_text = tr("hud.environment.details_tooltip")
	var environment_title := get_node_or_null("EnvironmentDetailsPanel/VBoxContainer/EnvironmentDetailsTitle") as Label
	if environment_title != null:
		environment_title.text = tr("hud.environment.details")
	var environment_close := get_node_or_null("EnvironmentDetailsPanel/VBoxContainer/HBoxContainer/CloseEnvironmentDetails") as Button
	if environment_close != null:
		environment_close.tooltip_text = tr("hud.close")
	if _activity_button != null:
		_activity_button.text = tr("hud.activities.title")
		var menu := _activity_menu.get_child(0) as VBoxContainer
		if menu != null:
			(menu.get_node("OpenTrollingActivity") as Button).text = tr("hud.activities.trolling")
			(menu.get_node("OpenFishFinderTool") as Button).text = tr("hud.activities.fish_finder")
			(menu.get_node("OpenControlsHelp") as Button).text = tr("hud.activities.controls_help")
		var help_title := get_node_or_null("ControlsHelpPanel/VBoxContainer/HBoxContainer/ControlsHelpTitle") as Label
		if help_title != null:
			help_title.text = tr("hud.activities.controls_help")
		var help_close := get_node_or_null("ControlsHelpPanel/VBoxContainer/HBoxContainer/CloseControlsHelp") as Button
		if help_close != null:
			help_close.tooltip_text = tr("hud.close")
	if _map_button != null:
		_map_button.text = tr("hud.map.open")
	if _fish_finder_toggle_button != null:
		_fish_finder_toggle_button.text = tr("fish.finder.open")
	var takeover_button := find_child("ManualTakeoverButton", true, false) as Button
	if takeover_button != null:
		takeover_button.text = tr("hud.autopilot.manual_takeover")
	if _fishing_player_panel != null:
		_fishing_player_panel.refresh_localized_text()
	if _fish_finder_display != null and _fish_finder_display.has_method("refresh_localized_text"):
		_fish_finder_display.call("refresh_localized_text")
	if _fish_map != null and _fish_map.has_method("refresh_localized_text"):
		_fish_map.call("refresh_localized_text")
	if _navigation_detail_button != null:
		_navigation_detail_button.text = tr("hud.navigation.collapse") if _navigation_detail_requested else tr("hud.navigation.expand")
	_update_controls_help_text()
	_update_status()
	_update_navigation_core_panel()
	_update_autopilot_panel()
	_update_sailing_panel()
	if _compass_widget != null:
		_compass_widget.queue_redraw()
	_refresh_sailing_static_text()
	_refresh_vessel_picker_text()
	_update_hud_layout()


func _refresh_sailing_static_text() -> void:
	if _polar_toggle_button != null:
		_polar_toggle_button.text = tr("hud.sailing.polar")
	if _sailing_auto_toggle != null:
		_sailing_auto_toggle.text = tr("hud.sailing.auto_trim_toggle")
	if _auto_reef_toggle != null:
		_auto_reef_toggle.text = tr("hud.sailing.auto_reef_toggle")
	if _main_deployment_status != null:
		var main_title := _main_deployment_status.get_parent().get_child(0) as Label
		main_title.text = tr("hud.sailing.main_sail_deployment")
	if _jib_deployment_status != null:
		var jib_title := _jib_deployment_status.get_parent().get_child(0) as Label
		jib_title.text = tr("hud.sailing.headsail_deployment")
	var main_label := find_child("MainSailControlLabel", true, false) as Label
	if main_label != null:
		main_label.text = tr("hud.sailing.main_sail_angle")
	var jib_label := find_child("HeadsailControlLabel", true, false) as Label
	if jib_label != null:
		jib_label.text = tr("hud.sailing.headsail_angle")
	if _aux_engine_gear_option != null and _aux_engine_gear_option.item_count >= 3:
		_aux_engine_gear_option.set_item_text(0, tr("hud.sailing.gear.reverse"))
		_aux_engine_gear_option.set_item_text(1, tr("hud.sailing.gear.neutral"))
		_aux_engine_gear_option.set_item_text(2, tr("hud.sailing.gear.forward"))
	if _aux_engine_feedback_label != null:
		_aux_engine_feedback_label.text = tr(_aux_engine_feedback_key)
	if _polar_panel != null:
		var polar_title := _polar_panel.find_child("PolarTitle", true, false) as Label
		if polar_title != null:
			polar_title.text = tr("hud.sailing.polar_title")
		var polar_help := _polar_panel.find_child("PolarHelp", true, false) as Label
		if polar_help != null:
			polar_help.text = tr("hud.sailing.polar_help")
		var polar_close := _polar_panel.find_child("CloseNordic28Polar", true, false) as Button
		if polar_close != null:
			polar_close.text = tr("hud.close") + "  ×"
	_update_sailing_panel()


func _refresh_vessel_picker_text() -> void:
	if _vessel_picker_title != null:
		_vessel_picker_title.text = tr("vessel.picker.title")
	if _vessel_picker_note != null:
		_vessel_picker_note.text = tr("vessel.picker.note")
	if _vessel_picker_close_button != null:
		_vessel_picker_close_button.text = tr("vessel.picker.close")
	for card in _vessel_picker_cards:
		if is_instance_valid(card):
			card.call("refresh_localized_text")


func _update_navigation_core_panel() -> void:
	if _navigation_core_panel == null or _controller == null:
		return
	var knots := absf(_controller.speed_mps) * 1.94384
	_navigation_speed_label.text = tr("hud.navigation.speed_format") % knots
	if _controller.is_sailing_active():
		_navigation_core_title.text = tr("hud.navigation.sailing")
		var body := _controller.get_sailing_body()
		var snapshot: Dictionary = body.call("get_navigation_snapshot") if body != null and body.has_method("get_navigation_snapshot") else {}
		var apparent_valid := bool(snapshot.get("apparent_wind_valid", false))
		var apparent_speed := float(snapshot.get("apparent_wind_speed_mps", 0.0))
		var apparent_angle := float(snapshot.get("apparent_wind_from_relative_degrees", 0.0))
		var deployment: Dictionary = snapshot.get("sail_deployment", {})
		var sail_percent := float(deployment.get("main_current_deployment", 0.0)) * 100.0
		_navigation_core_detail.text = tr("hud.navigation.sailing_compact") % [
			tr("hud.navigation.apparent_wind_format") % [apparent_angle, apparent_speed] if apparent_valid else tr("hud.navigation.wind_unavailable"),
			tr("hud.navigation.sail_deployment_format") % sail_percent,
			tr("hud.navigation.auto_trim_on") if bool(snapshot.get("auto_sail_trim_enabled", false)) else tr("hud.navigation.auto_trim_off"),
		]
		_navigation_core_extra_detail.visible = false
	else:
		_navigation_core_title.text = tr("hud.navigation.powerboat")
		if _controller.is_autopilot:
			var autopilot_snapshot: Dictionary = _autopilot_controller.get_status_snapshot() if _autopilot_controller != null and _autopilot_controller.has_method("get_status_snapshot") else {}
			var target_knots := float(autopilot_snapshot.get("target_speed_mps", 0.0)) * 1.94384
			_navigation_core_detail.text = tr("hud.navigation.powerboat_autopilot_compact") % target_knots if not autopilot_snapshot.is_empty() else tr("hud.navigation.autopilot_on")
		else:
			var throttle := maxf(Input.get_action_strength("boat_accelerate"), Input.get_action_strength("boat_brake")) * 100.0
			_navigation_core_detail.text = tr("hud.navigation.powerboat_compact") % [tr("hud.navigation.manual"), throttle]
		_navigation_core_detail.visible = true
		_navigation_core_extra_detail.visible = _navigation_detail_requested
		if _navigation_detail_requested:
			_navigation_core_extra_detail.text = tr("hud.navigation.speed_limits_format") % [
				_controller.max_speed_mps * 1.94384,
				_controller.get_reverse_max_speed_mps() * 1.94384,
			]
	_navigation_detail_button.text = tr("hud.navigation.collapse") if _navigation_detail_requested else tr("hud.navigation.expand")


func _update_environment_summary() -> void:
	if _controller == null:
		return
	var weather_id := str(_weather_state_controller.get("current_weather_id")) if _weather_state_controller != null else str(_weather_controller.get("current_weather_name")) if _weather_controller != null else ""
	var weather_key := "hud.weather." + weather_id.to_lower().replace(" ", "_")
	var weather_name := tr(weather_key) if tr(weather_key) != weather_key else str(_weather_controller.get("current_weather_name")) if _weather_controller != null else tr("hud.weather.unknown")
	var wind_details: Dictionary = _wind_field.call("get_wind_details_at", _controller.global_position) if _wind_field != null and _wind_field.has_method("get_wind_details_at") else {}
	var wind_speed := float(wind_details.get("instant_speed_mps", -1.0))
	var wind_direction := float(wind_details.get("instant_wind_from_degrees", -1.0))
	var wave_scale := float(_wave_sampler.call("get_effective_wave_strength")) if _wave_sampler != null and _wave_sampler.has_method("get_effective_wave_strength") else -1.0
	_status_label.text = tr("hud.environment.summary_format") % [weather_name, "—" if wind_speed < 0.0 else "%.1f" % wind_speed, "—" if wind_direction < 0.0 else "%03.0f°" % wind_direction, "—" if wave_scale < 0.0 else "%.2f×" % wave_scale]
	if _environment_detail_label != null:
		_environment_detail_label.text = tr("hud.environment.detail_format") % [weather_name, "—" if wind_speed < 0.0 else "%.1f m/s" % wind_speed, "—" if wind_direction < 0.0 else "%03.0f°" % wind_direction, "—" if float(wind_details.get("mean_speed_mps", -1.0)) < 0.0 else "%.1f m/s" % float(wind_details.get("mean_speed_mps", -1.0)), "—" if wave_scale < 0.0 else "%.2f×" % wave_scale]


func _add_compass_widget() -> void:
	_compass_widget = Control.new()
	_compass_widget.name = "CompassHUD"
	_compass_widget.set_script(COMPASS_HUD_SCRIPT)
	add_child(_compass_widget)
	_compass_widget.call("configure", _controller)


func _build_fishing_player_panel() -> void:
	_fishing_player_panel = FISHING_PLAYER_PANEL_SCRIPT.new() as FishingPlayerPanel
	_fishing_player_panel.name = "FishingPlayerPanel"
	_fishing_player_panel.anchor_left = 1.0
	_fishing_player_panel.anchor_right = 1.0
	_fishing_player_panel.anchor_top = 0.0
	_fishing_player_panel.anchor_bottom = 0.0
	_fishing_player_panel.offset_left = -334.0
	_fishing_player_panel.offset_top = 72.0
	_fishing_player_panel.offset_right = -24.0
	_fishing_player_panel.offset_bottom = 280.0
	_fishing_player_panel.visible = false
	add_child(_fishing_player_panel)
	_fishing_player_panel.configure(_fish_resource_manager, _fishing_rod_system)
	_build_trolling_panel_signals()


func _build_fish_finder_display() -> void:
	_fish_finder_toggle_button = Button.new()
	_fish_finder_toggle_button.name = "FishFinderOpenButton"
	_fish_finder_toggle_button.text = tr("fish.finder.open")
	_fish_finder_toggle_button.z_index = 18
	_fish_finder_toggle_button.focus_mode = Control.FOCUS_NONE
	_fish_finder_toggle_button.custom_minimum_size = Vector2(170.0, 42.0)
	_fish_finder_toggle_button.anchor_left = 1.0
	_fish_finder_toggle_button.anchor_right = 1.0
	_fish_finder_toggle_button.anchor_top = 1.0
	_fish_finder_toggle_button.anchor_bottom = 1.0
	_fish_finder_toggle_button.offset_left = -188.0
	_fish_finder_toggle_button.offset_right = -18.0
	_fish_finder_toggle_button.offset_top = -60.0
	_fish_finder_toggle_button.offset_bottom = -18.0
	_fish_finder_toggle_button.visible = false
	_fish_finder_toggle_button.pressed.connect(_on_fish_finder_open_pressed)
	add_child(_fish_finder_toggle_button)
	_fish_finder_display = FISH_FINDER_DISPLAY_SCRIPT.new() as Control
	_fish_finder_display.name = "FishFinderDisplay"
	_fish_finder_display.call("configure", _fish_resource_manager, _controller)
	_fish_finder_display.connect("close_requested", _on_fish_finder_close_requested)
	_fish_finder_display.connect("display_mode_changed", _on_fish_finder_mode_changed)
	add_child(_fish_finder_display)
	_fish_finder_display.visible = false


func _on_fish_finder_open_pressed() -> void:
	if _fish_finder_display != null and is_instance_valid(_fish_finder_display):
		_prepare_major_tool("finder")
		_fish_finder_display.call("open_display")
		_fish_finder_toggle_button.visible = false
		_update_hud_layout()


func _on_fish_finder_close_requested() -> void:
	if _fish_finder_toggle_button != null:
		_fish_finder_toggle_button.visible = false
	if _restore_map_mini_after_finder and _fish_map != null and str(_fish_map.call("get_display_mode")) == "hidden":
		_fish_map.call("set_display_mode", "mini")
	_restore_map_mini_after_finder = false
	_update_hud_layout()


func _on_fish_finder_mode_changed(mode: String) -> void:
	if mode == "expanded":
		_prepare_major_tool("finder")
	_update_hud_layout()


func _on_map_display_mode_changed(mode: String) -> void:
	if mode == "expanded":
		_prepare_major_tool("map")
	_update_hud_layout()


func _build_catch_result_panel() -> void:
	_catch_result_panel = PanelContainer.new()
	_catch_result_panel.name = "CatchResultCard"
	_catch_result_panel.anchor_left = 1.0
	_catch_result_panel.anchor_right = 1.0
	_catch_result_panel.anchor_top = 0.34
	_catch_result_panel.anchor_bottom = 0.34
	_catch_result_panel.offset_left = -360.0
	_catch_result_panel.offset_right = -24.0
	_catch_result_panel.offset_top = 0.0
	_catch_result_panel.offset_bottom = 138.0
	_catch_result_panel.custom_minimum_size = Vector2(336.0, 138.0)
	_catch_result_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_catch_result_panel.visible = false
	_catch_result_panel.z_index = 20
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.12, 0.16, 0.92)
	style.border_color = Color(0.28, 0.52, 0.55, 0.78)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 16.0
	style.content_margin_right = 16.0
	style.content_margin_top = 11.0
	style.content_margin_bottom = 11.0
	_catch_result_panel.add_theme_stylebox_override("panel", style)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 3)
	_catch_result_panel.add_child(content)
	_catch_result_title = Label.new()
	_catch_result_title.add_theme_font_size_override("font_size", 14)
	_catch_result_title.add_theme_color_override("font_color", Color(0.42, 0.82, 0.77, 1.0))
	content.add_child(_catch_result_title)
	_catch_result_species = Label.new()
	_catch_result_species.add_theme_font_size_override("font_size", 23)
	_catch_result_species.add_theme_color_override("font_color", Color(0.94, 0.97, 0.93, 1.0))
	content.add_child(_catch_result_species)
	_catch_result_length = Label.new()
	_catch_result_length.add_theme_font_size_override("font_size", 16)
	_catch_result_length.add_theme_color_override("font_color", Color(0.82, 0.92, 0.88, 1.0))
	content.add_child(_catch_result_length)
	_catch_result_weight = Label.new()
	_catch_result_weight.add_theme_font_size_override("font_size", 16)
	_catch_result_weight.add_theme_color_override("font_color", Color(0.82, 0.92, 0.88, 1.0))
	content.add_child(_catch_result_weight)
	add_child(_catch_result_panel)
	if _fishing_rod_system != null and _fishing_rod_system.has_signal("catch_display_updated"):
		_fishing_rod_system.catch_display_updated.connect(_on_catch_display_updated)


func _on_catch_display_updated(snapshot: Dictionary) -> void:
	if _catch_result_panel == null:
		return
	if not bool(snapshot.get("visible", false)):
		if _catch_result_card_is_retained and _catch_result_card_hold_remaining > 0.0:
			_catch_result_panel.visible = true
			_catch_result_panel.modulate.a = 1.0
			return
		_catch_result_panel.visible = false
		_catch_result_card_is_retained = false
		return
	var simulated := str(snapshot.get("source", "")) == "DEBUG_SIMULATION"
	_catch_result_card_is_retained = simulated or not str(snapshot.get("catch_id", "")).is_empty()
	_catch_result_card_hold_remaining = CATCH_RESULT_CARD_HOLD_SECONDS if _catch_result_card_is_retained else 0.0
	_catch_result_title.text = tr("fishing.ui.simulation_preview") if simulated else tr("fishing.ui.catch_confirmed")
	_catch_result_species.text = tr(str(snapshot.get("species_name_key", "fishing.ui.unknown_fish")))
	_catch_result_length.text = tr("fishing.ui.catch_length_format") % float(snapshot.get("length_cm", 0.0))
	_catch_result_weight.text = tr("fishing.ui.catch_weight_format") % float(snapshot.get("weight_kg", 0.0))
	_catch_result_panel.visible = true
	if simulated:
		_catch_result_panel.modulate.a = clampf(float(snapshot.get("alpha", 1.0)), 0.0, 1.0)
	else:
		var presentation_elapsed := float(snapshot.get("presentation_elapsed", 0.0))
		_catch_result_panel.modulate.a = _smoothstep01(presentation_elapsed / 0.4)


func _advance_catch_result_card(delta: float) -> void:
	if not _catch_result_card_is_retained or _catch_result_panel == null or not _catch_result_panel.visible:
		return
	_catch_result_card_hold_remaining = maxf(0.0, _catch_result_card_hold_remaining - delta)
	if _catch_result_card_hold_remaining <= 0.0:
		_catch_result_card_is_retained = false
		_catch_result_panel.visible = false
		_catch_result_panel.modulate.a = 1.0
		return
	if _catch_result_card_hold_remaining < CATCH_RESULT_CARD_FADE_SECONDS:
		_catch_result_panel.modulate.a = _catch_result_card_hold_remaining / CATCH_RESULT_CARD_FADE_SECONDS


func _smoothstep01(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _build_sailing_panel() -> void:
	_sailing_panel = PanelContainer.new()
	_sailing_panel.name = "SailingControlsPanel"
	_sailing_panel.anchor_left = 1.0
	_sailing_panel.anchor_right = 1.0
	_sailing_panel.anchor_top = 1.0
	_sailing_panel.anchor_bottom = 1.0
	_sailing_panel.offset_left = -470.0
	_sailing_panel.offset_top = -500.0
	_sailing_panel.offset_right = -24.0
	_sailing_panel.offset_bottom = -24.0
	_sailing_panel.custom_minimum_size = Vector2(470.0, 500.0)
	_sailing_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.12, 0.16, 0.88)
	style.border_color = Color(0.28, 0.52, 0.55, 0.72)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	_sailing_panel.add_theme_stylebox_override("panel", style)
	var scroll := ScrollContainer.new()
	scroll.name = "SailingPanelScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sailing_panel.add_child(scroll)
	var layout := VBoxContainer.new()
	layout.name = "SailingPanelContent"
	layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_theme_constant_override("separation", 7)
	scroll.add_child(layout)
	var heading_row := HBoxContainer.new()
	heading_row.add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = tr("hud.navigation.instrument_title")
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading_row.add_child(title)
	_sailing_mode_label = Label.new()
	_sailing_mode_label.name = "SailingTrimMode"
	_sailing_mode_label.add_theme_font_size_override("font_size", 15)
	_sailing_mode_label.add_theme_color_override("font_color", Color(0.95, 0.77, 0.36))
	heading_row.add_child(_sailing_mode_label)
	_polar_toggle_button = Button.new()
	_polar_toggle_button.name = "OpenNordic28Polar"
	_polar_toggle_button.text = tr("hud.sailing.polar")
	_polar_toggle_button.custom_minimum_size = Vector2(108.0, 34.0)
	_polar_toggle_button.pressed.connect(_toggle_polar_panel)
	heading_row.add_child(_polar_toggle_button)
	layout.add_child(heading_row)
	var core_row := HBoxContainer.new()
	core_row.name = "CoreNavigationRow"
	core_row.add_theme_constant_override("separation", 12)
	_sailing_navigation_instrument = Control.new()
	_sailing_navigation_instrument.name = "SailingNavigationInstrument"
	_sailing_navigation_instrument.set_script(SAILING_NAVIGATION_INSTRUMENT_SCRIPT)
	_sailing_navigation_instrument.custom_minimum_size = Vector2(150.0, 164.0)
	_sailing_navigation_instrument.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	core_row.add_child(_sailing_navigation_instrument)
	_sailing_navigation_instrument.call("configure", _controller, true)
	var core_data := VBoxContainer.new()
	core_data.name = "CoreNavigationData"
	core_data.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	core_data.add_theme_constant_override("separation", 4)
	core_row.add_child(core_data)
	_sailing_speed_label = _make_sailing_label("2.3 kn", 32, Color(0.97, 0.99, 0.95))
	_sailing_speed_label.name = "SailingSpeed"
	core_data.add_child(_sailing_speed_label)
	_sailing_heading_label = _make_sailing_label(tr("hud.navigation.heading_format") % 0.0, 19, Color(0.9, 0.96, 0.94))
	_sailing_heading_label.name = "SailingHeading"
	core_data.add_child(_sailing_heading_label)
	_sailing_heel_label = _make_sailing_label(tr("hud.navigation.heel_format") % 0.0, 16, Color(0.95, 0.77, 0.36))
	_sailing_heel_label.name = "SailingHeel"
	core_data.add_child(_sailing_heel_label)
	_sailing_true_wind_speed_label = _make_sailing_label(tr("hud.sailing.true_wind_speed") % 0.0, 16, Color(0.22, 0.81, 0.73))
	_sailing_true_wind_speed_label.name = "SailingTrueWindSpeed"
	core_data.add_child(_sailing_true_wind_speed_label)
	_sailing_true_wind_direction_label = _make_sailing_label(tr("hud.sailing.true_wind_direction_unknown"), 14, Color(0.22, 0.81, 0.73))
	_sailing_true_wind_direction_label.name = "SailingTrueWindDirection"
	_sailing_true_wind_direction_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	core_data.add_child(_sailing_true_wind_direction_label)
	_sailing_relative_wind_label = _make_sailing_label(tr("hud.sailing.relative_wind_calm"), 14, Color(1.0, 0.62, 0.29))
	_sailing_relative_wind_label.name = "SailingRelativeWind"
	_sailing_relative_wind_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	core_data.add_child(_sailing_relative_wind_label)
	layout.add_child(core_row)
	_sailing_status_label = _make_sailing_label(tr("hud.sailing.manual_trim"), 15, Color(0.86, 0.93, 0.90))
	_sailing_status_label.name = "SailingStatus"
	_sailing_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_sailing_status_label)
	_sailing_trim_angles_label = _make_sailing_label(tr("hud.sailing.trim_angles_format") % [0.0, tr("hud.sailing.off"), 0.0], 14, Color(0.85, 0.9, 0.88))
	_sailing_trim_angles_label.name = "SailingTrimAngles"
	layout.add_child(_sailing_trim_angles_label)
	_sailing_detail_label = _make_sailing_label("", 13, Color(0.75, 0.85, 0.84))
	_sailing_detail_label.name = "SailingDetails"
	_sailing_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sailing_detail_label.visible = false
	layout.add_child(_sailing_detail_label)
	_sailing_auto_toggle = CheckButton.new()
	_sailing_auto_toggle.name = "AutoSailTrimToggle"
	_sailing_auto_toggle.text = tr("hud.sailing.auto_trim_toggle")
	_sailing_auto_toggle.custom_minimum_size.y = 42.0
	_sailing_auto_toggle.add_theme_font_size_override("font_size", 16)
	_sailing_auto_toggle.toggled.connect(_on_sailing_auto_toggled)
	layout.add_child(_sailing_auto_toggle)
	var main_deployment_box := VBoxContainer.new()
	main_deployment_box.name = "MainSailFurlControl"
	main_deployment_box.add_theme_constant_override("separation", 2)
	var main_deployment_header := HBoxContainer.new()
	var main_deployment_title := _make_sailing_label(tr("hud.sailing.main_sail_deployment"), 14, Color(0.88, 0.93, 0.90))
	main_deployment_title.name = "MainSailDeploymentTitle"
	main_deployment_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_deployment_header.add_child(main_deployment_title)
	_main_deployment_status = _make_sailing_label("", 13, Color(0.69, 0.84, 0.80))
	main_deployment_header.add_child(_main_deployment_status)
	main_deployment_box.add_child(main_deployment_header)
	_main_deployment_slider = HSlider.new()
	_main_deployment_slider.name = "MainSailDeployment"
	_main_deployment_slider.min_value = 0.0
	_main_deployment_slider.max_value = 100.0
	_main_deployment_slider.step = 1.0
	_main_deployment_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_deployment_slider.custom_minimum_size.y = 24.0
	_main_deployment_slider.value_changed.connect(_on_main_deployment_changed)
	main_deployment_box.add_child(_main_deployment_slider)
	layout.add_child(main_deployment_box)
	var jib_deployment_box := VBoxContainer.new()
	jib_deployment_box.name = "JibFurlControl"
	jib_deployment_box.add_theme_constant_override("separation", 2)
	var jib_deployment_header := HBoxContainer.new()
	var jib_deployment_title := _make_sailing_label(tr("hud.sailing.headsail_deployment"), 14, Color(0.88, 0.93, 0.90))
	jib_deployment_title.name = "HeadsailDeploymentTitle"
	jib_deployment_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jib_deployment_header.add_child(jib_deployment_title)
	_jib_deployment_status = _make_sailing_label("", 13, Color(0.69, 0.84, 0.80))
	jib_deployment_header.add_child(_jib_deployment_status)
	jib_deployment_box.add_child(jib_deployment_header)
	_jib_deployment_slider = HSlider.new()
	_jib_deployment_slider.name = "JibDeployment"
	_jib_deployment_slider.min_value = 0.0
	_jib_deployment_slider.max_value = 100.0
	_jib_deployment_slider.step = 1.0
	_jib_deployment_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_jib_deployment_slider.custom_minimum_size.y = 24.0
	_jib_deployment_slider.value_changed.connect(_on_jib_deployment_changed)
	jib_deployment_box.add_child(_jib_deployment_slider)
	layout.add_child(jib_deployment_box)
	_auto_reef_toggle = CheckButton.new()
	_auto_reef_toggle.name = "AutoReefToggle"
	_auto_reef_toggle.text = tr("hud.sailing.auto_reef_toggle")
	_auto_reef_toggle.custom_minimum_size.y = 40.0
	_auto_reef_toggle.add_theme_font_size_override("font_size", 16)
	_auto_reef_toggle.toggled.connect(_on_auto_reef_toggled)
	layout.add_child(_auto_reef_toggle)
	_auto_reef_status = _make_sailing_label(tr("hud.sailing.auto_reef_off_manual"), 13, Color(0.72, 0.84, 0.81))
	_auto_reef_status.name = "AutoReefStatus"
	_auto_reef_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_auto_reef_status)
	var main_row := HBoxContainer.new()
	var main_label := Label.new()
	main_label.name = "MainSailControlLabel"
	main_label.text = tr("hud.sailing.main_sail_angle")
	main_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_label.add_theme_font_size_override("font_size", 15)
	main_row.add_child(main_label)
	main_row.add_child(_make_trim_button("−10°", _adjust_main_trim.bind(-1)))
	main_row.add_child(_make_trim_button("+10°", _adjust_main_trim.bind(1)))
	layout.add_child(main_row)
	var jib_row := HBoxContainer.new()
	var jib_label := Label.new()
	jib_label.name = "HeadsailControlLabel"
	jib_label.text = tr("hud.sailing.headsail_angle")
	jib_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	jib_label.add_theme_font_size_override("font_size", 15)
	jib_row.add_child(jib_label)
	jib_row.add_child(_make_trim_button("−10°", _adjust_headsail.bind(-1)))
	jib_row.add_child(_make_trim_button("+10°", _adjust_headsail.bind(1)))
	layout.add_child(jib_row)
	_aux_engine_panel = VBoxContainer.new()
	_aux_engine_panel.name = "AuxiliaryEnginePanel"
	_aux_engine_panel.add_theme_constant_override("separation", 5)
	_aux_engine_panel.add_child(HSeparator.new())
	var engine_title := _make_sailing_label(tr("hud.sailing.aux_engine"), 15, Color(0.91, 0.96, 0.92))
	engine_title.name = "AuxiliaryEngineTitle"
	_aux_engine_panel.add_child(engine_title)
	_aux_engine_status_label = _make_sailing_label(tr("hud.sailing.engine_status_format") % [tr("hud.sailing.engine_off"), tr("hud.sailing.gear.neutral"), 0.0, 0.0], 14, Color(0.86, 0.92, 0.89))
	_aux_engine_status_label.name = "AuxiliaryEngineStatus"
	_aux_engine_panel.add_child(_aux_engine_status_label)
	_aux_engine_fuel_label = _make_sailing_label(tr("hud.sailing.fuel_format") % [40.0, 40.0, 0.0, 0.0, "", ""], 13, Color(0.72, 0.84, 0.81))
	_aux_engine_fuel_label.name = "AuxiliaryEngineFuel"
	_aux_engine_panel.add_child(_aux_engine_fuel_label)
	var engine_controls := HBoxContainer.new()
	engine_controls.add_theme_constant_override("separation", 8)
	_aux_engine_toggle_button = Button.new()
	_aux_engine_toggle_button.name = "AuxiliaryEngineToggle"
	_aux_engine_toggle_button.text = tr("hud.sailing.engine_start")
	_aux_engine_toggle_button.custom_minimum_size = Vector2(112.0, 38.0)
	_aux_engine_toggle_button.pressed.connect(_on_aux_engine_toggle_pressed)
	engine_controls.add_child(_aux_engine_toggle_button)
	_aux_engine_gear_option = OptionButton.new()
	_aux_engine_gear_option.name = "AuxiliaryEngineGear"
	_aux_engine_gear_option.add_item(tr("hud.sailing.gear.reverse"), -1)
	_aux_engine_gear_option.add_item(tr("hud.sailing.gear.neutral"), 0)
	_aux_engine_gear_option.add_item(tr("hud.sailing.gear.forward"), 1)
	_aux_engine_gear_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_aux_engine_gear_option.item_selected.connect(_on_aux_engine_gear_selected)
	engine_controls.add_child(_aux_engine_gear_option)
	_aux_engine_panel.add_child(engine_controls)
	var throttle_row := HBoxContainer.new()
	var throttle_label := _make_sailing_label(tr("hud.sailing.throttle"), 13, Color(0.76, 0.85, 0.82))
	throttle_label.custom_minimum_size.x = 42.0
	throttle_row.add_child(throttle_label)
	_aux_engine_throttle_slider = HSlider.new()
	_aux_engine_throttle_slider.name = "AuxiliaryEngineThrottle"
	_aux_engine_throttle_slider.min_value = 0.0
	_aux_engine_throttle_slider.max_value = 1.0
	_aux_engine_throttle_slider.step = 0.01
	_aux_engine_throttle_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_aux_engine_throttle_slider.value_changed.connect(_on_aux_engine_throttle_changed)
	throttle_row.add_child(_aux_engine_throttle_slider)
	_aux_engine_panel.add_child(throttle_row)
	_aux_engine_feedback_label = _make_sailing_label(tr("hud.sailing.engine_controls_help"), 12, Color(0.65, 0.79, 0.78))
	_aux_engine_feedback_label.name = "AuxiliaryEngineFeedback"
	_aux_engine_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_aux_engine_panel.add_child(_aux_engine_feedback_label)
	layout.add_child(_aux_engine_panel)
	_sailing_control_hint_label = _make_sailing_label("", 12, Color(0.66, 0.79, 0.8))
	_sailing_control_hint_label.name = "SailingControlHints"
	_sailing_control_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_sailing_control_hint_label)
	add_child(_sailing_panel)
	_build_polar_panel()
	_update_sailing_panel()


func _build_polar_panel() -> void:
	_polar_panel = PanelContainer.new()
	_polar_panel.name = "Nordic28PolarPanel"
	_polar_panel.anchor_left = 0.5
	_polar_panel.anchor_right = 0.5
	_polar_panel.anchor_top = 0.5
	_polar_panel.anchor_bottom = 0.5
	_polar_panel.offset_left = -520.0
	_polar_panel.offset_right = 520.0
	_polar_panel.offset_top = -390.0
	_polar_panel.offset_bottom = 390.0
	_polar_panel.custom_minimum_size = Vector2(1040.0, 780.0)
	_polar_panel.visible = false
	_polar_panel.z_index = 30
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.025, 0.085, 0.11, 0.96)
	style.border_color = Color(0.28, 0.52, 0.55, 0.82)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 16.0
	style.content_margin_right = 16.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	_polar_panel.add_theme_stylebox_override("panel", style)
	var layout := VBoxContainer.new()
	layout.name = "PolarPanelContent"
	layout.add_theme_constant_override("separation", 8)
	_polar_panel.add_child(layout)
	var header := HBoxContainer.new()
	var title := _make_sailing_label(tr("hud.sailing.polar_title"), 20, Color(0.92, 0.97, 0.95))
	title.name = "PolarTitle"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var close_button := Button.new()
	close_button.name = "CloseNordic28Polar"
	close_button.text = tr("hud.close") + "  ×"
	close_button.custom_minimum_size = Vector2(92.0, 34.0)
	close_button.pressed.connect(_close_polar_panel)
	header.add_child(close_button)
	layout.add_child(header)
	var subtitle := _make_sailing_label(tr("hud.sailing.polar_help"), 13, Color(0.65, 0.8, 0.79))
	subtitle.name = "PolarHelp"
	layout.add_child(subtitle)
	_polar_detail_label = _make_sailing_label(tr("hud.sailing.waiting_vessel_data"), 14, Color(0.38, 0.91, 0.99))
	_polar_detail_label.name = "Nordic28PolarCurrentState"
	_polar_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(_polar_detail_label)
	_polar_chart = Control.new()
	_polar_chart.name = "Nordic28PolarChart"
	_polar_chart.set_script(SAILING_POLAR_CHART_SCRIPT)
	_polar_chart.custom_minimum_size = Vector2(700.0, 460.0)
	_polar_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_polar_chart.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(_polar_chart)
	add_child(_polar_panel)
	_update_hud_layout()


func _make_sailing_label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _build_vessel_picker() -> void:
	_vessel_picker_overlay = Control.new()
	_vessel_picker_overlay.name = "VesselPickerOverlay"
	_vessel_picker_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_vessel_picker_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_vessel_picker_overlay.visible = false
	var backdrop := ColorRect.new()
	backdrop.name = "Backdrop"
	backdrop.color = Color(0.008, 0.025, 0.032, 0.78)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.gui_input.connect(_on_vessel_picker_backdrop_input)
	_vessel_picker_overlay.add_child(backdrop)
	var center := CenterContainer.new()
	center.name = "DialogCenter"
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vessel_picker_overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.name = "VesselPickerDialog"
	panel.custom_minimum_size = Vector2(800.0, 560.0)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.025, 0.075, 0.09, 0.98)
	panel_style.border_color = Color(0.30, 0.53, 0.54, 0.95)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(12)
	panel_style.content_margin_left = 18.0
	panel_style.content_margin_right = 18.0
	panel_style.content_margin_top = 16.0
	panel_style.content_margin_bottom = 16.0
	panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(panel)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	panel.add_child(layout)
	var heading := HBoxContainer.new()
	heading.name = "Heading"
	_vessel_picker_title = Label.new()
	_vessel_picker_title.text = tr("vessel.picker.title")
	_vessel_picker_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vessel_picker_title.add_theme_font_size_override("font_size", 24)
	_vessel_picker_title.add_theme_color_override("font_color", Color(0.95, 0.97, 0.94))
	heading.add_child(_vessel_picker_title)
	_vessel_picker_close_button = Button.new()
	_vessel_picker_close_button.name = "CloseButton"
	_vessel_picker_close_button.text = tr("vessel.picker.close")
	_vessel_picker_close_button.pressed.connect(_close_vessel_picker)
	heading.add_child(_vessel_picker_close_button)
	layout.add_child(heading)
	_vessel_picker_note = Label.new()
	_vessel_picker_note.text = tr("vessel.picker.note")
	_vessel_picker_note.add_theme_color_override("font_color", Color(0.72, 0.82, 0.82))
	layout.add_child(_vessel_picker_note)
	var card_row := HBoxContainer.new()
	card_row.add_theme_constant_override("separation", 14)
	card_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(card_row)
	var motorboat_source := _controller.get_node_or_null("VisualRoot") as Node3D
	var sailboat_body := _controller.get_node_or_null("../SailingBoat8m")
	var sailboat_source: Node3D = sailboat_body.get_node_or_null("VisualRoot") as Node3D if sailboat_body != null else null
	var motor_profile: VesselDraftProfile = _controller.draft_profile
	var motor_name_key := "vessel.picker.powerboat.cargo_name" if motor_profile != null else "vessel.picker.powerboat.name"
	var motor_length_m := float(motor_profile.get("vessel_length_m")) if motor_profile != null else 7.2
	var motor_beam_m := float(motor_profile.get("vessel_beam_m")) if motor_profile != null else 2.56
	var motor_empty_draft_m := float(motor_profile.get("empty_draft_m")) if motor_profile != null else 0.32
	var motor_full_draft_m := float(motor_profile.get("full_load_draft_m")) if motor_profile != null else 0.75
	var motor_cargo_capacity := int(motor_profile.get("cargo_capacity_space_units")) if motor_profile != null else 0
	var sail_profile: Resource = sailboat_body.get("profile") as Resource if sailboat_body != null else null
	var sail_name_key := "vessel.picker.sailboat.name"
	var sail_length_m := float(sail_profile.get("vessel_length_m")) if sail_profile != null else 8.0
	var sail_draft_m := float(sail_profile.get("draft_m")) if sail_profile != null else 0.9
	var main_sail_area_m2 := float(sail_profile.get("main_sail_area_m2")) if sail_profile != null else 10.16
	var headsail_area_m2 := float(sail_profile.get("headsail_area_m2")) if sail_profile != null else 5.16
	var motor_card := VesselPreviewCardScript.new() as Control
	motor_card.name = "PowerboatCard"
	motor_card.call("configure", false, motor_name_key, "vessel.picker.powerboat.type", "vessel.picker.powerboat.details", [motor_length_m, motor_beam_m, motor_empty_draft_m, motor_full_draft_m, motor_cargo_capacity], motorboat_source)
	motor_card.connect("vessel_selected", _on_vessel_picker_card_selected)
	card_row.add_child(motor_card)
	_vessel_picker_cards.append(motor_card)
	var sail_card := VesselPreviewCardScript.new() as Control
	sail_card.name = "SailboatCard"
	sail_card.call("configure", true, sail_name_key, "vessel.picker.sailboat.type", "vessel.picker.sailboat.details", [sail_length_m, sail_draft_m, main_sail_area_m2, headsail_area_m2], sailboat_source)
	sail_card.connect("vessel_selected", _on_vessel_picker_card_selected)
	card_row.add_child(sail_card)
	_vessel_picker_cards.append(sail_card)
	add_child(_vessel_picker_overlay)
	_update_vessel_picker_selection()
	_update_vessel_picker_layout()
	get_viewport().size_changed.connect(_update_vessel_picker_layout)


func _update_vessel_picker_layout() -> void:
	if _vessel_picker_overlay == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var dialog := _vessel_picker_overlay.get_node("DialogCenter/VesselPickerDialog") as PanelContainer
	dialog.custom_minimum_size = Vector2(minf(800.0, viewport_size.x - 36.0), minf(560.0, viewport_size.y - 36.0))
	for card in _vessel_picker_cards:
		if is_instance_valid(card):
			card.custom_minimum_size = Vector2(maxf(170.0, (dialog.custom_minimum_size.x - 70.0) * 0.5), 440.0)


func _is_vessel_picker_blocked_by_other_overlay() -> bool:
	if is_instance_valid(_game_menu) and _game_menu.has_method("is_menu_open") and bool(_game_menu.call("is_menu_open")):
		return true
	if is_instance_valid(_fish_map) and _fish_map.has_method("is_map_open") and bool(_fish_map.call("is_map_open")):
		return true
	for service in _port_service_controllers:
		if is_instance_valid(service) and service.has_method("is_menu_open") and bool(service.call("is_menu_open")):
			return true
	return false


func _open_vessel_picker() -> void:
	if _vessel_picker_overlay == null or _is_vessel_picker_blocked_by_other_overlay():
		return
	_vessel_picker_previous_manual_input = bool(_controller.get("manual_input_enabled"))
	_controller.set_sailing_manual_controls_enabled(false)
	if has_node("../FollowCameraRig"):
		var camera_rig := get_node("../FollowCameraRig")
		if camera_rig.has_method("release_mouse_look"):
			camera_rig.call("release_mouse_look")
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_vessel_picker_overlay.visible = true
	for card in _vessel_picker_cards:
		if is_instance_valid(card):
			card.call("set_preview_enabled", true)
	_update_vessel_picker_selection()
	if _vessel_picker_close_button != null:
		_vessel_picker_close_button.grab_focus()


func _close_vessel_picker() -> void:
	if _vessel_picker_overlay == null or not _vessel_picker_overlay.visible:
		return
	_vessel_picker_overlay.visible = false
	for card in _vessel_picker_cards:
		if is_instance_valid(card):
			card.call("set_preview_enabled", false)
	var restore_input := _vessel_picker_previous_manual_input
	if is_instance_valid(_game_menu) and _game_menu.has_method("is_menu_open") and bool(_game_menu.call("is_menu_open")):
		restore_input = false
	_controller.set_sailing_manual_controls_enabled(restore_input)
	get_viewport().gui_release_focus()
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _on_vessel_picker_card_selected(sailing: bool) -> void:
	if _controller.set_sailing_enabled(sailing):
		_close_vessel_picker()
		_update_vessel_picker_selection()


func _update_vessel_picker_selection() -> void:
	if _controller == null:
		return
	for card in _vessel_picker_cards:
		if is_instance_valid(card):
			card.call("set_current", bool(card.call("is_sailing_vessel")) == _controller.is_sailing_active())


func _on_vessel_picker_backdrop_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_close_vessel_picker()
		get_viewport().set_input_as_handled()


func _make_trim_button(text_value: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text_value
	button.custom_minimum_size = Vector2(72.0, 36.0)
	button.add_theme_font_size_override("font_size", 14)
	button.pressed.connect(callback)
	return button


func _update_sailing_panel() -> void:
	if _sailing_panel == null or _controller == null:
		return
	var active := _controller.is_sailing_active()
	var debug_panel_open := _debug_panel != null and _debug_panel.visible
	_sailing_panel.visible = active and _navigation_detail_requested and not debug_panel_open
	if _polar_panel != null:
		_polar_panel.visible = _polar_requested and active and not debug_panel_open
	if _compass_widget != null:
		_compass_widget.visible = not debug_panel_open
	if not active:
		return
	var body := _controller.get_sailing_body()
	if body == null or not body.has_method("get_navigation_snapshot"):
		return
	var snapshot: Dictionary = body.call("get_navigation_snapshot")
	_update_navigation_core_panel()
	var deployment: Dictionary = snapshot.get("sail_deployment", {})
	if _polar_chart != null:
		_polar_chart.call("set_current_state", snapshot)
		_polar_detail_label.text = str(_polar_chart.call("get_current_detail_text"))
	var engine: Dictionary = snapshot.get("auxiliary_engine", {"available": false})
	var engine_available := bool(engine.get("available", false))
	if _aux_engine_panel != null:
		_aux_engine_panel.visible = engine_available
	if _aux_engine_status_label != null:
		if engine_available:
			var engine_state_key := "hud.sailing.engine_on" if bool(engine.get("running", false)) else "hud.sailing.engine_off"
			var gear_key := "hud.sailing.gear.reverse" if int(engine.get("gear", 0)) < 0 else "hud.sailing.gear.forward" if int(engine.get("gear", 0)) > 0 else "hud.sailing.gear.neutral"
			_aux_engine_status_label.text = tr("hud.sailing.engine_status_format") % [
				tr(engine_state_key), tr(gear_key),
				float(engine.get("target_throttle", 0.0)) * 100.0,
				float(engine.get("actual_throttle", 0.0)) * 100.0,
			]
			var tank: Dictionary = engine.get("tank", {})
			var remaining := float(tank.get("remaining_l", 0.0))
			var capacity := float(tank.get("capacity_l", 0.0))
			var consumption := float(engine.get("consumption_lph", 0.0))
			var runtime_text := tr("hud.sailing.runtime_format") % float(engine.get("remaining_runtime_h", 0.0)) if bool(engine.get("runtime_estimate_valid", false)) else ""
			var fuel_warning := tr("hud.sailing.fuel_low") if bool(tank.get("low_fuel_warning", false)) else tr("hud.sailing.fuel_empty") if bool(tank.get("fuel_depleted", false)) else ""
			_aux_engine_fuel_label.text = tr("hud.sailing.fuel_format") % [remaining, capacity, float(tank.get("fraction", 0.0)) * 100.0, consumption, runtime_text, fuel_warning]
			_aux_engine_toggle_button.text = tr("hud.sailing.engine_stop") if bool(engine.get("running", false)) else tr("hud.sailing.engine_start")
			_aux_engine_throttle_slider.set_value_no_signal(float(engine.get("target_throttle", 0.0)))
			for gear_index in range(_aux_engine_gear_option.item_count):
				if _aux_engine_gear_option.get_item_id(gear_index) == int(engine.get("gear", 0)):
					_aux_engine_gear_option.select(gear_index)
					break
	if _sailing_navigation_instrument != null:
		_sailing_navigation_instrument.call("set_snapshot", snapshot)
	var auto_enabled := bool(snapshot.get("auto_sail_trim_enabled", false))
	if _last_auto_trim_state and not auto_enabled:
		_manual_trim_notice_until_msec = Time.get_ticks_msec() + 2500
	_last_auto_trim_state = auto_enabled
	_sailing_auto_toggle.set_pressed_no_signal(auto_enabled)
	_sailing_auto_toggle.text = tr("hud.sailing.auto_trim_toggle_hint") % NAVIGATION_HUD_FORMAT.action_key_hint("sailboat_toggle_auto_trim")
	var auto_reef_on := bool(deployment.get("auto_reef_enabled", false))
	if _last_auto_reef_state and not auto_reef_on:
		_manual_reef_notice_until_msec = Time.get_ticks_msec() + 2500
	_last_auto_reef_state = auto_reef_on
	_auto_reef_toggle.set_pressed_no_signal(auto_reef_on)
	_auto_reef_toggle.text = tr("hud.sailing.auto_reef_state") % tr("hud.sailing.on" if auto_reef_on else "hud.sailing.off")
	_main_deployment_slider.set_value_no_signal(float(deployment.get("main_target_deployment", 1.0)) * 100.0)
	_jib_deployment_slider.set_value_no_signal(float(deployment.get("jib_target_deployment", 1.0)) * 100.0)
	_main_deployment_status.text = tr("hud.sailing.deployment_format") % [
		float(deployment.get("main_target_deployment", 1.0)) * 100.0,
		float(deployment.get("main_current_deployment", 1.0)) * 100.0,
		float(deployment.get("main_effective_area_m2", 0.0)),
		tr(_sail_deployment_state_key(float(deployment.get("main_target_deployment", 1.0)), float(deployment.get("main_current_deployment", 1.0)))),
	]
	_jib_deployment_status.text = tr("hud.sailing.deployment_format") % [
		float(deployment.get("jib_target_deployment", 1.0)) * 100.0,
		float(deployment.get("jib_current_deployment", 1.0)) * 100.0,
		float(deployment.get("jib_effective_area_m2", 0.0)),
		tr(_sail_deployment_state_key(float(deployment.get("jib_target_deployment", 1.0)), float(deployment.get("jib_current_deployment", 1.0)))),
	]
	var reef_status_id := str(deployment.get("auto_reef_status_id", "manual"))
	var reef_action_id := str(deployment.get("auto_reef_action_id", "none"))
	var reef_state := tr("hud.sailing.reef_status.%s" % reef_status_id) % [float(deployment.get("auto_reef_filtered_heel_deg", 0.0)), tr("hud.sailing.reef_action.%s" % reef_action_id)]
	if auto_reef_on:
		_auto_reef_status.text = tr("hud.sailing.auto_reef_on_status") % reef_state
		_auto_reef_status.add_theme_color_override("font_color", Color(0.43, 0.91, 0.68))
	elif Time.get_ticks_msec() < _manual_reef_notice_until_msec:
		_auto_reef_status.text = tr("hud.sailing.auto_reef_off_returned")
		_auto_reef_status.add_theme_color_override("font_color", Color(0.95, 0.83, 0.52))
	else:
		_auto_reef_status.text = tr("hud.sailing.auto_reef_off_manual")
		_auto_reef_status.add_theme_color_override("font_color", Color(0.72, 0.84, 0.81))
	_refresh_sailing_navigation_text(snapshot)


func _refresh_sailing_navigation_text(snapshot: Dictionary) -> void:
	var engine_state: Dictionary = snapshot.get("auxiliary_engine", {"available": false})
	var engine_available := bool(engine_state.get("available", false))
	var heading := fposmod(float(snapshot.get("heading_degrees", 0.0)), 360.0)
	var speed_knots := float(snapshot.get("sog_knots", 0.0))
	_sailing_speed_label.text = tr("hud.navigation.speed_format") % speed_knots
	_sailing_heading_label.text = tr("hud.navigation.heading_format") % heading
	_sailing_heel_label.text = tr("hud.navigation.heel_format") % float(snapshot.get("heel_degrees", 0.0))
	var true_valid := bool(snapshot.get("true_wind_valid", false))
	var true_speed := float(snapshot.get("true_wind_speed_mps", 0.0))
	var true_bearing := float(snapshot.get("true_wind_from_degrees", 0.0))
	var true_relative := float(snapshot.get("true_wind_from_relative_degrees", 0.0))
	var apparent_valid := bool(snapshot.get("apparent_wind_valid", false))
	var apparent_speed := float(snapshot.get("apparent_wind_speed_mps", 0.0))
	var apparent_relative := float(snapshot.get("apparent_wind_from_relative_degrees", 0.0))
	_sailing_true_wind_speed_label.text = tr("hud.sailing.true_wind_speed") % true_speed if true_valid else tr("hud.sailing.true_wind_calm")
	_sailing_true_wind_direction_label.text = tr("hud.sailing.true_wind_direction_format") % [true_bearing, NAVIGATION_HUD_FORMAT.compass_direction_phrase(true_bearing)] if true_valid else tr("hud.sailing.true_wind_direction_unknown")
	_sailing_relative_wind_label.text = tr("hud.sailing.relative_wind_format") % [NAVIGATION_HUD_FORMAT.relative_wind_location_phrase(apparent_relative), apparent_relative] if apparent_valid else tr("hud.sailing.relative_wind_calm")
	var auto_enabled := bool(snapshot.get("auto_sail_trim_enabled", false))
	_sailing_mode_label.text = tr("hud.sailing.mode_auto") if auto_enabled else tr("hud.sailing.mode_manual")
	_sailing_mode_label.add_theme_color_override("font_color", Color(0.43, 0.91, 0.68) if auto_enabled else Color(0.91, 0.82, 0.53))
	var now := Time.get_ticks_msec()
	var trim: Dictionary = snapshot.get("auto_sail_trim", {})
	if bool(trim.get("no_go", false)):
		_sailing_status_label.text = tr("hud.sailing.no_go_warning")
		_sailing_status_label.add_theme_color_override("font_color", Color(1.0, 0.68, 0.35))
	elif now < _manual_trim_notice_until_msec:
		_sailing_status_label.text = tr("hud.sailing.manual_trim_notice")
		_sailing_status_label.add_theme_color_override("font_color", Color(0.95, 0.83, 0.52))
	else:
		_sailing_status_label.text = tr("hud.sailing.auto_trim_on") if auto_enabled else tr("hud.sailing.manual_trim")
		_sailing_status_label.add_theme_color_override("font_color", Color(0.43, 0.91, 0.68) if auto_enabled else Color(0.86, 0.93, 0.90))
	var main_angle := rad_to_deg(float(snapshot.get("actual_sail_angle_rad", 0.0)))
	var jib_angle := rad_to_deg(float(snapshot.get("actual_headsail_angle_rad", 0.0)))
	var rudder_angle := rad_to_deg(float(snapshot.get("actual_rudder_angle_rad", 0.0)))
	_sailing_trim_angles_label.text = tr("hud.sailing.trim_angles_format") % [main_angle, "%+.0f°" % jib_angle if bool(snapshot.get("headsail_enabled", false)) else tr("hud.sailing.off"), rudder_angle]
	var detail_enabled := _quality_manager != null and _quality_manager.has_method("get_navigation_detail_enabled") and bool(_quality_manager.call("get_navigation_detail_enabled"))
	_sailing_detail_label.visible = detail_enabled
	if detail_enabled:
		var cog_text := "%03.0f°" % float(snapshot.get("cog_degrees", 0.0)) if bool(snapshot.get("cog_valid", false)) else tr("hud.sailing.direction_unreliable")
		var true_text := tr("hud.sailing.wind_detail_format") % [true_speed, true_relative] if true_valid else tr("hud.sailing.calm")
		var apparent_text := tr("hud.sailing.apparent_wind_detail_format") % [apparent_speed, apparent_relative] if apparent_valid else tr("hud.sailing.calm")
		_sailing_detail_label.text = tr("hud.sailing.detail_format") % [
			speed_knots,
			float(snapshot.get("sog_mps", 0.0)),
			cog_text,
			heading,
			true_text,
			apparent_text,
			main_angle,
			rad_to_deg(float(snapshot.get("target_sail_angle_rad", 0.0))),
			("%+.0f° / %s %+.0f°" % [jib_angle, tr("hud.sailing.target"), rad_to_deg(float(snapshot.get("target_headsail_angle_rad", 0.0)))]) if bool(snapshot.get("headsail_enabled", false)) else tr("hud.sailing.off"),
			rudder_angle,
			rad_to_deg(float(snapshot.get("target_rudder_angle_rad", 0.0))),
			float(snapshot.get("heel_degrees", 0.0)),
		rad_to_deg(float(snapshot.get("keel_side_slip_angle_rad", 0.0))),
		]
	var hint_text := tr("hud.sailing.controls_hint") % [
		NAVIGATION_HUD_FORMAT.action_key_hint("boat_turn_left"),
		NAVIGATION_HUD_FORMAT.action_key_hint("boat_turn_right"),
		NAVIGATION_HUD_FORMAT.action_key_hint("sailboat_main_trim_ease"),
		NAVIGATION_HUD_FORMAT.action_key_hint("sailboat_main_trim_out"),
		NAVIGATION_HUD_FORMAT.action_key_hint("sailboat_headsail_trim_ease"),
		NAVIGATION_HUD_FORMAT.action_key_hint("sailboat_headsail_trim_out"),
	]
	_sailing_control_hint_label.text = hint_text + (" · " + tr("hud.sailing.engine_key_hint") if engine_available else "")


func _sail_deployment_state_key(target: float, current: float) -> String:
	if absf(target - current) > 0.005:
		return "hud.sailing.furling.deploying" if target > current else "hud.sailing.furling.retracting"
	if current >= 0.995:
		return "hud.sailing.furling.deployed"
	if current <= 0.005:
		return "hud.sailing.furling.retracted"
	return "hud.sailing.furling.partial"

func _on_vessel_mode_changed(sailboat_active: bool) -> void:
	if _boat_audio_controller != null and _boat_audio_controller.has_method("bind_vessel"):
		var motion_source: Node = _controller.get_sailing_body() if sailboat_active else _controller.get_node_or_null("VisualRoot")
		_boat_audio_controller.call("bind_vessel", _controller, motion_source)
	_update_vessel_picker_selection()
	_update_status()
	_update_sailing_panel()
	_update_autopilot_panel()
	_update_sailing_physics_debug_status()
	_update_hud_layout()


func _on_interface_settings_changed() -> void:
	_update_hud_layout()
	_update_sailing_panel()


func _on_sailing_auto_toggled(enabled: bool) -> void:
	var body := _controller.get_sailing_body() if _controller != null else null
	if body != null and body.has_method("set_auto_sail_trim_enabled"):
		body.call("set_auto_sail_trim_enabled", enabled)


func _toggle_polar_panel() -> void:
	_polar_requested = not _polar_requested
	_update_sailing_panel()


func _close_polar_panel() -> void:
	_polar_requested = false
	_update_sailing_panel()


func _on_main_deployment_changed(value: float) -> void:
	var body := _controller.get_sailing_body() if _controller != null else null
	if body != null and body.has_method("set_main_sail_deployment_target"):
		body.call("set_main_sail_deployment_target", value / 100.0)
		_update_sailing_panel()


func _on_jib_deployment_changed(value: float) -> void:
	var body := _controller.get_sailing_body() if _controller != null else null
	if body != null and body.has_method("set_jib_deployment_target"):
		body.call("set_jib_deployment_target", value / 100.0)
		_update_sailing_panel()


func _on_auto_reef_toggled(enabled: bool) -> void:
	var body := _controller.get_sailing_body() if _controller != null else null
	if body != null and body.has_method("set_auto_reef_enabled"):
		body.call("set_auto_reef_enabled", enabled)
	_update_sailing_panel()


func _on_aux_engine_toggle_pressed() -> void:
	var body := _controller.get_sailing_body() if _controller != null else null
	if body != null and body.has_method("toggle_auxiliary_engine"):
		body.call("toggle_auxiliary_engine")
	_update_sailing_panel()


func _on_aux_engine_gear_selected(index: int) -> void:
	var body := _controller.get_sailing_body() if _controller != null else null
	if body == null or not body.has_method("set_auxiliary_engine_gear"):
		return
	var gear_value := _aux_engine_gear_option.get_item_id(index)
	var accepted := bool(body.call("set_auxiliary_engine_gear", gear_value))
	if _aux_engine_feedback_label != null:
		_aux_engine_feedback_key = "hud.sailing.gear_changed" if accepted else "hud.sailing.gear_change_rejected"
		_aux_engine_feedback_label.text = tr(_aux_engine_feedback_key)
	_update_sailing_panel()


func _on_aux_engine_throttle_changed(value: float) -> void:
	var body := _controller.get_sailing_body() if _controller != null else null
	if body != null and body.has_method("set_auxiliary_engine_target_throttle"):
		body.call("set_auxiliary_engine_target_throttle", value)


func _adjust_main_trim(direction: int) -> void:
	var body := _controller.get_sailing_body() if _controller != null else null
	if body == null:
		return
	var target := float(body.get("target_sail_angle_rad"))
	body.call("set_target_sail_angle", target + deg_to_rad(10.0 * float(direction)))


func _adjust_headsail(direction: int) -> void:
	var body := _controller.get_sailing_body() if _controller != null else null
	if body == null:
		return
	body.call("set_target_headsail_angle", float(body.call("get_target_headsail_angle")) + deg_to_rad(10.0 * float(direction)))


func _process(delta: float) -> void:
	_advance_catch_result_card(delta)
	_sample_debug_frame_time()
	_runtime_elapsed += delta
	_fps_elapsed += delta
	if _fps_elapsed >= 0.5:
		_fps_elapsed = fmod(_fps_elapsed, 0.5)
		_update_fps_display()
	if _controller != null:
		_status_refresh_elapsed += delta
		if _status_refresh_elapsed >= 0.5:
			_status_refresh_elapsed = fmod(_status_refresh_elapsed, 0.5)
			_update_status()
		_navigation_refresh_elapsed += delta
		if _navigation_refresh_elapsed >= 0.1:
			_navigation_refresh_elapsed = fmod(_navigation_refresh_elapsed, 0.1)
			_update_navigation_core_panel()
	_autopilot_refresh_elapsed += delta
	if _autopilot_refresh_elapsed >= 0.2:
		_autopilot_refresh_elapsed = fmod(_autopilot_refresh_elapsed, 0.2)
		_update_autopilot_panel()
	if _debug_panel != null and _debug_panel.visible:
		_debug_refresh_elapsed += delta
		if _debug_refresh_elapsed >= 0.5:
			_debug_refresh_elapsed = fmod(_debug_refresh_elapsed, 0.5)
			_update_debug_status()
	_sailing_refresh_elapsed += delta
	if _sailing_refresh_elapsed >= 0.10:
		_sailing_refresh_elapsed = fmod(_sailing_refresh_elapsed, 0.10)
		_update_sailing_panel()


func _sample_debug_frame_time() -> void:
	if _debug_panel == null or not _debug_panel.visible:
		if _perf_sampling_active:
			_perf_sampling_active = false
			_perf_last_tick_usec = 0
			_perf_sample_result = "采样已中断（F3 面板关闭）"
		return
	if not _perf_sampling_active:
		return
	var now := Time.get_ticks_usec()
	if _perf_last_tick_usec > 0:
		var frame_ms := float(now - _perf_last_tick_usec) / 1000.0
		_perf_frame_samples.append(frame_ms)
		_perf_elapsed_seconds += frame_ms / 1000.0
		if _perf_elapsed_seconds >= _perf_target_duration_seconds:
			_perf_sampling_active = false
			var sorted := _perf_frame_samples.duplicate()
			sorted.sort()
			var mean_ms := _perf_elapsed_seconds * 1000.0 / float(sorted.size())
			var p95 := sorted[clampi(ceili(float(sorted.size()) * 0.95) - 1, 0, sorted.size() - 1)]
			_perf_sample_result = "%d秒：%.1f FPS · 平均 %.2f ms · P95 %.2f ms" % [roundi(_perf_target_duration_seconds), 1000.0 / mean_ms, mean_ms, p95]
	_perf_last_tick_usec = now


func _start_performance_sample() -> void:
	_perf_frame_samples.clear()
	_perf_elapsed_seconds = 0.0
	_perf_last_tick_usec = Time.get_ticks_usec()
	_perf_sampling_active = true
	_perf_sample_result = "采样中：0 / %d s" % roundi(_perf_target_duration_seconds)


func _reset_performance_sample_duration(index: int) -> void:
	_perf_target_duration_seconds = 60.0 if index == 1 else 30.0
	_perf_sampling_active = false
	_perf_last_tick_usec = 0
	_perf_frame_samples.clear()
	_perf_elapsed_seconds = 0.0
	_perf_sample_result = "等待预热后开始 %d 秒采样" % roundi(_perf_target_duration_seconds)


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
	takeover.text = tr("hud.autopilot.manual_takeover")
	takeover.pressed.connect(_on_manual_takeover_pressed)
	layout.add_child(takeover)
	add_child(_autopilot_panel)
	_update_autopilot_panel()


func _update_autopilot_panel() -> void:
	if _autopilot_panel == null or _autopilot_controller == null:
		return
	if _controller != null and not _controller.supports_autopilot():
		_autopilot_panel.visible = false
		return
	var snapshot := _autopilot_controller.get_status_snapshot()
	var state := str(snapshot.get("state", AutopilotController.STATE_IDLE))
	var active := _controller != null and _controller.is_autopilot
	var message_age := float(snapshot.get("message_age_seconds", INF))
	_autopilot_panel.visible = active or state == AutopilotController.STATE_COMPLETED or (message_age < 4.0 and not str(snapshot.get("message", "")).is_empty())
	if not _autopilot_panel.visible:
		return
	var state_key: String = {
		AutopilotController.STATE_ACQUIRING: "hud.autopilot.state.acquiring",
		AutopilotController.STATE_CRUISING: "hud.autopilot.state.cruising",
		AutopilotController.STATE_APPROACHING: "hud.autopilot.state.approaching",
		AutopilotController.STATE_SAFETY_HOLD: "hud.autopilot.state.safety_hold",
		AutopilotController.STATE_COMPLETED: "hud.autopilot.state.completed",
		AutopilotController.STATE_DISENGAGED: "hud.autopilot.state.disengaged",
	}.get(state, "hud.autopilot.state.cruising")
	var state_text := tr(state_key)
	if not active and state != AutopilotController.STATE_COMPLETED:
		_autopilot_label.text = tr("hud.autopilot.recent_status") % state_text
		return
	var origin_id := str(snapshot.get("origin_port_id", ""))
	var destination_id := str(snapshot.get("destination_port_id", ""))
	var origin := _cargo_economy_manager.get_port_display_name(origin_id) if _cargo_economy_manager != null else origin_id
	var destination := _cargo_economy_manager.get_port_display_name(destination_id) if _cargo_economy_manager != null else destination_id
	origin = _localized_autopilot_port(origin_id, origin)
	destination = _localized_autopilot_port(destination_id, destination)
	var route_id := str(snapshot.get("route_id", ""))
	var route_key := "hud.autopilot.route." + route_id
	var route_name := tr(route_key) if tr(route_key) != route_key else str(snapshot.get("route_name", ""))
	var target_waypoint_id := str(snapshot.get("target_waypoint_id", ""))
	var target_key := "hud.autopilot.waypoint." + target_waypoint_id
	var target_name := tr(target_key) if tr(target_key) != target_key else str(snapshot.get("target_waypoint", tr("hud.autopilot.waiting_point")))
	var eta_seconds := float(snapshot.get("eta_seconds", -1.0))
	var eta_minutes := int(round(eta_seconds / 60.0)) if eta_seconds >= 0.0 else -1
	var eta_text := tr("hud.autopilot.eta_hours") % [int(eta_minutes / 60), eta_minutes % 60] if eta_minutes >= 60 else tr("hud.autopilot.eta_minutes") % eta_minutes if eta_minutes >= 0 else tr("hud.unknown")
	var cruise_adjustment_hint := " · " + tr("hud.autopilot.speed_adjust_hint") if OS.has_feature("editor") or OS.has_feature("debug") else ""
	var route_notice := tr("hud.autopilot.safety_notice") if state == AutopilotController.STATE_SAFETY_HOLD else tr("hud.autopilot.depth_limit_notice") if not str(snapshot.get("depth_notice", "")).is_empty() else ""
	_autopilot_label.text = tr("hud.autopilot.status_format") % [
		state_text, route_name, origin, destination,
		target_name, int(snapshot.get("segment_index", 0)), int(snapshot.get("segment_count", 0)),
		float(snapshot.get("progress_fraction", 0.0)) * 100.0, float(snapshot.get("remaining_m", 0.0)) / 1000.0,
		float(snapshot.get("actual_speed_mps", 0.0)), float(snapshot.get("target_speed_mps", 0.0)), cruise_adjustment_hint, eta_text,
		"\n" + route_notice if not route_notice.is_empty() else "",
	]


func _localized_autopilot_port(port_id: String, fallback_name: String) -> String:
	var key := "hud.autopilot.port.malmo" if port_id == "malmo_greybox_v1" else "hud.autopilot.port.copenhagen" if port_id == "kobenhavn_test" else ""
	return tr(key) if not key.is_empty() else fallback_name


func _update_fps_display() -> void:
	if _fps_label == null:
		return
	var fps := Engine.get_frames_per_second()
	_fps_label.text = "FPS: %d" % fps if _runtime_elapsed >= 1.5 and fps >= 5 else "FPS: --"


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


func _input(event: InputEvent) -> void:
	if _polar_requested and event is InputEventKey and event.pressed and not event.echo and (event.physical_keycode == KEY_ESCAPE or event.keycode == KEY_ESCAPE):
		_close_polar_panel()
		get_viewport().set_input_as_handled()
		return
	if _vessel_picker_overlay == null or not _vessel_picker_overlay.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and (event.physical_keycode == KEY_ESCAPE or event.keycode == KEY_ESCAPE):
		_close_vessel_picker()
		get_viewport().set_input_as_handled()


func _unhandled_key_input(event: InputEvent) -> void:
	if _vessel_picker_overlay != null and _vessel_picker_overlay.visible:
		if event is InputEventKey:
			if event.pressed and not event.echo and event.physical_keycode == KEY_I:
				_close_vessel_picker()
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_I:
		if not _is_vessel_picker_blocked_by_other_overlay():
			_open_vessel_picker()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_F3:
		_debug_panel.visible = not _debug_panel.visible
		if _debug_panel.visible:
			_begin_debug_panel_overrides()
			_update_debug_status()
			_sync_peberholm_debug_control()
		else:
			_restore_debug_panel_overrides()
		_update_sailing_panel()
		_update_hud_layout()
		get_viewport().set_input_as_handled()


func _update_status() -> void:
	if _controller == null:
		return
	_update_environment_summary()
	_update_navigation_depth_status()
	_update_cargo_task_status()


func _update_cargo_task_status() -> void:
	if _cargo_task_label == null:
		return
	if _cargo_economy_manager == null:
		_cargo_task_label.text = "货运：未接入"
		return
	if not _controller.supports_cargo():
		_cargo_task_label.text = "帆船模式：货运与自动巡航暂未接入"
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

	_debug_scroll = TabContainer.new()
	_debug_scroll.name = "SailboatDebugTabs"
	_debug_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_debug_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_debug_panel.add_child(_debug_scroll)
	var environment_scroll := ScrollContainer.new()
	environment_scroll.name = "EnvironmentDebugTab"
	environment_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	environment_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_debug_scroll.add_child(environment_scroll)
	_debug_scroll.set_tab_title(0, "天气与画面")
	_debug_layout = VBoxContainer.new()
	_debug_layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_debug_layout.add_theme_constant_override("separation", 7)
	environment_scroll.add_child(_debug_layout)
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
	_weather_runtime_status_label = _make_debug_label()
	_weather_runtime_status_label.name = "WeatherRuntimeReadout"
	layout.add_child(_weather_runtime_status_label)
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
	_add_city_lighting_controls(layout)

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
	_clouds_toggle.text = "体积云渲染（性能 A/B；天气模拟保留）"
	_clouds_toggle.toggled.connect(_on_clouds_toggled)
	layout.add_child(_clouds_toggle)
	if OS.is_debug_build():
		_diagnostic_scale_option = _add_option_row(layout, "测试：仅 3D Rendering Scale", ["0.50 · FSR2", "0.67 · FSR2", "0.75 · FSR2"])
		_diagnostic_scale_option.item_selected.connect(_on_diagnostic_scale_selected)
		_perf_sample_duration_option = _add_option_row(layout, "性能采样时长", ["30 秒筛查", "60 秒复核"])
		_perf_sample_duration_option.select(0)
		_perf_sample_duration_option.item_selected.connect(_reset_performance_sample_duration)
		_perf_sample_button = Button.new()
		_perf_sample_button.text = "开始 / 重置性能采样"
		_perf_sample_button.pressed.connect(_start_performance_sample)
		layout.add_child(_perf_sample_button)
		var restore_graphics_button := Button.new()
		restore_graphics_button.text = "恢复玩家图形设置"
		restore_graphics_button.pressed.connect(_reset_debug_graphics_overrides)
		layout.add_child(restore_graphics_button)
		_water_fragment_toggle = CheckButton.new()
		_water_fragment_toggle.text = "海面片元隔离（保留顶点波浪）"
		_water_fragment_toggle.toggled.connect(_on_water_fragment_isolation_toggled)
		layout.add_child(_water_fragment_toggle)
		_building_visual_toggle = CheckButton.new()
		_building_visual_toggle.text = "岸边建筑 / 港口装饰视觉"
		_building_visual_toggle.toggled.connect(_on_building_visuals_toggled)
		layout.add_child(_building_visual_toggle)
		_seagrass_visual_toggle = CheckButton.new()
		_seagrass_visual_toggle.text = "海底植被视觉（生态与海床保留）"
		_seagrass_visual_toggle.toggled.connect(_on_seagrass_visuals_toggled)
		layout.add_child(_seagrass_visual_toggle)
		var diagnostic_note := _make_debug_label()
		diagnostic_note.text = "A/B 每次只改一项。固定机位和天气，改完预热，再按采样按钮；记录结束后恢复基线。"
		layout.add_child(diagnostic_note)
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
	_performance_label.name = "PerformanceReadout"
	layout.add_child(_sun_label)
	layout.add_child(_moon_label)
	layout.add_child(_cloud_label)
	layout.add_child(_wave_label)
	layout.add_child(_performance_label)
	var sailing_debug_scroll := ScrollContainer.new()
	sailing_debug_scroll.name = "SailingPhysicsDebugTab"
	sailing_debug_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sailing_debug_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	_debug_scroll.add_child(sailing_debug_scroll)
	_debug_scroll.set_tab_title(1, "帆船物理")
	var sailing_debug_layout := VBoxContainer.new()
	sailing_debug_layout.name = "SailingPhysicsDebugContent"
	sailing_debug_layout.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sailing_debug_layout.add_theme_constant_override("separation", 8)
	sailing_debug_scroll.add_child(sailing_debug_layout)
	var sailing_debug_title := Label.new()
	sailing_debug_title.text = "帆力、水动力与采样诊断"
	sailing_debug_title.add_theme_font_size_override("font_size", 17)
	sailing_debug_title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
	sailing_debug_layout.add_child(sailing_debug_title)
	_sailboat_physics_label = _make_debug_label()
	_sailboat_physics_label.name = "SailingPhysicsReadout"
	sailing_debug_layout.add_child(_sailboat_physics_label)
	var fishing_debug_panel := FISHING_DEBUG_PANEL_SCRIPT.new() as ScrollContainer
	fishing_debug_panel.name = "FishingDebugTab"
	_debug_scroll.add_child(fishing_debug_panel)
	_debug_scroll.set_tab_title(2, tr("fishing.debug.tab"))
	add_child(_debug_panel)
	fishing_debug_panel.configure(_fish_resource_manager, _fishing_rod_system, _fish_finder_display, _fish_school_renderer)
	_refresh_weather_controls()
	_refresh_settings_controls()
	_refresh_city_lighting_controls()


func _add_city_lighting_controls(parent: VBoxContainer) -> void:
	var section_title := Label.new()
	section_title.text = "Malmö 城市夜间灯光"
	section_title.add_theme_font_size_override("font_size", 16)
	section_title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
	parent.add_child(section_title)
	_city_lighting_toggle = CheckButton.new()
	_city_lighting_toggle.text = "启用城市夜间灯光"
	_city_lighting_toggle.toggled.connect(_on_city_lighting_toggled)
	parent.add_child(_city_lighting_toggle)
	var mode_note := _make_debug_label()
	mode_note.text = "强制模式仅测试城市灯光，不改变世界时间、天气或太阳。"
	parent.add_child(mode_note)
	_city_lighting_mode_option = _add_option_row(parent, "灯光模式", ["自动昼夜", "强制白天", "强制黄昏", "强制夜晚"])
	_city_lighting_mode_option.item_selected.connect(_on_city_lighting_mode_selected)
	_city_window_strength_slider = _add_slider_row(parent, "窗光总强度 · 0–3 倍", 0.0, 3.0, 0.05)
	_city_window_strength_slider.value = 1.0
	_city_window_strength_slider.value_changed.connect(_on_city_window_strength_changed)
	_city_density_mode_option = _add_option_row(parent, "亮灯密度", ["按建筑配置（自动）", "自定义比例"])
	_city_density_mode_option.item_selected.connect(_on_city_density_mode_selected)
	_city_window_density_slider = _add_slider_row(parent, "自定义亮灯比例 · 0–80%", 0.0, 0.8, 0.01)
	_city_window_density_slider.value = 0.3
	_city_window_density_slider.value_changed.connect(_on_city_window_density_changed)
	_city_mask_debug_toggle = CheckButton.new()
	_city_mask_debug_toggle.text = "诊断：亮紫色显示窗户遮罩"
	_city_mask_debug_toggle.toggled.connect(_on_city_mask_debug_toggled)
	parent.add_child(_city_mask_debug_toggle)
	_city_turning_torso_slider = _add_slider_row(parent, "Turning Torso 窗光", 0.0, 3.0, 0.05)
	_city_turning_torso_slider.value = 1.0
	_city_turning_torso_slider.value_changed.connect(_on_city_turning_torso_changed)
	_city_contour_slider = _add_slider_row(parent, "Turning Torso 弱轮廓补光", 0.0, 2.0, 0.05)
	_city_contour_slider.value = 0.2
	_city_contour_slider.value_changed.connect(_on_city_contour_changed)
	_city_residential_slider = _add_slider_row(parent, "住宅窗光", 0.0, 3.0, 0.05)
	_city_residential_slider.value = 1.0
	_city_residential_slider.value_changed.connect(_on_city_residential_changed)
	_city_office_slider = _add_slider_row(parent, "办公楼窗光", 0.0, 3.0, 0.05)
	_city_office_slider.value = 1.0
	_city_office_slider.value_changed.connect(_on_city_office_changed)
	_city_street_slider = _add_slider_row(parent, "道路与广场照明", 0.0, 3.0, 0.05)
	_city_street_slider.value = 1.0
	_city_street_slider.value_changed.connect(_on_city_street_changed)
	_city_lighting_status = _make_debug_label()
	parent.add_child(_city_lighting_status)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	_city_lighting_save_button = Button.new()
	_city_lighting_save_button.text = "保存灯光参数"
	_city_lighting_save_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_city_lighting_save_button.pressed.connect(_on_city_lighting_save_pressed)
	buttons.add_child(_city_lighting_save_button)
	_city_lighting_reset_button = Button.new()
	_city_lighting_reset_button.text = "恢复城市默认值"
	_city_lighting_reset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_city_lighting_reset_button.pressed.connect(_on_city_lighting_reset_pressed)
	buttons.add_child(_city_lighting_reset_button)
	parent.add_child(buttons)


func _get_city_lighting_controller() -> Node:
	var controllers := get_tree().get_nodes_in_group("city_lighting_controller")
	return controllers[0] if not controllers.is_empty() else null


func _refresh_city_lighting_controls() -> void:
	if _city_lighting_status == null:
		return
	var city_lighting := _get_city_lighting_controller()
	var controls: Array[Control] = [
		_city_lighting_toggle, _city_window_strength_slider, _city_density_mode_option,
		_city_window_density_slider, _city_turning_torso_slider, _city_contour_slider,
		_city_residential_slider, _city_office_slider, _city_street_slider,
		_city_mask_debug_toggle, _city_lighting_mode_option, _city_lighting_save_button, _city_lighting_reset_button,
	]
	if city_lighting == null:
		_set_city_lighting_controls_enabled(controls, false)
		_city_lighting_status.text = "城市灯光控制器尚未加载。"
		return
	_set_city_lighting_controls_enabled(controls, true)
	var state: Dictionary = city_lighting.call("get_debug_state")
	_city_lighting_toggle.set_pressed_no_signal(bool(state.get("enabled", true)))
	if not _city_window_strength_slider.has_focus():
		_city_window_strength_slider.set_value_no_signal(float(state.get("master_window_intensity", 1.0)))
	var density_override := float(state.get("density_override", -1.0))
	_city_density_mode_option.select(1 if density_override >= 0.0 else 0)
	_city_window_density_slider.editable = density_override >= 0.0
	_city_mask_debug_toggle.set_pressed_no_signal(bool(state.get("debug_mask_view", false)))
	if not _city_window_density_slider.has_focus() and density_override >= 0.0:
		_city_window_density_slider.set_value_no_signal(density_override)
	if not _city_turning_torso_slider.has_focus():
		_city_turning_torso_slider.set_value_no_signal(float(state.get("turning_torso_intensity", 1.0)))
	if not _city_contour_slider.has_focus():
		_city_contour_slider.set_value_no_signal(float(state.get("contour_intensity", 0.2)))
	if not _city_residential_slider.has_focus():
		_city_residential_slider.set_value_no_signal(float(state.get("residential_intensity", 1.0)))
	if not _city_office_slider.has_focus():
		_city_office_slider.set_value_no_signal(float(state.get("office_intensity", 1.0)))
	if not _city_street_slider.has_focus():
		_city_street_slider.set_value_no_signal(float(state.get("street_intensity", 1.0)))
	_city_lighting_mode_option.select(int(state.get("forced_mode", 0)))
	_city_lighting_status.text = "状态 %s · %s · 游戏时间 %s · 距城 %.0f m · 近窗 %.0f%% / 远景代理 %.0f%% · 亮灯 %s · 窗光材质组 %d · %s" % [
		"开" if bool(state.get("enabled", true)) else "关",
		str(state.get("mode_name", "自动昼夜")),
		str(state.get("local_time", "--:--")),
		float(state.get("camera_distance_m", 0.0)),
		float(state.get("near_window_factor", 0.0)) * 100.0,
		float(state.get("far_proxy_factor", 0.0)) * 100.0,
		str(state.get("density_text", "自动")),
		int(state.get("overlay_surfaces", 0)),
		"在可见距离内" if bool(state.get("visible", true)) else "超出灯光距离",
	]


func _set_city_lighting_controls_enabled(controls: Array[Control], enabled: bool) -> void:
	for control in controls:
		if control is BaseButton:
			(control as BaseButton).disabled = not enabled
		elif control is Range:
			(control as Range).editable = enabled


func _on_city_lighting_toggled(enabled: bool) -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("set_lighting_enabled", enabled)
		_refresh_city_lighting_controls()


func _on_city_lighting_mode_selected(index: int) -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("set_forced_mode", index)
		_refresh_city_lighting_controls()


func _on_city_window_strength_changed(value: float) -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("set_master_window_intensity", value)
		_refresh_city_lighting_controls()


func _on_city_density_mode_selected(index: int) -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("set_density_override", index == 1, _city_window_density_slider.value)
		_refresh_city_lighting_controls()


func _on_city_window_density_changed(value: float) -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("set_density_override", _city_density_mode_option.selected == 1, value)
		_refresh_city_lighting_controls()


func _on_city_mask_debug_toggled(enabled: bool) -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("set_debug_mask_view", enabled)


func _on_city_turning_torso_changed(value: float) -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("set_category_intensity", "turning_torso", value)


func _on_city_contour_changed(value: float) -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("set_contour_intensity", value)


func _on_city_residential_changed(value: float) -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("set_category_intensity", "residential", value)


func _on_city_office_changed(value: float) -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("set_category_intensity", "office", value)


func _on_city_street_changed(value: float) -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("set_street_lighting_intensity", value)


func _on_city_lighting_save_pressed() -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		var saved := bool(controller.call("save_debug_settings"))
		_city_lighting_status.text = "城市灯光参数已保存到 user://malmo_city_lighting.cfg" if saved else "城市灯光参数保存失败。"


func _on_city_lighting_reset_pressed() -> void:
	var controller := _get_city_lighting_controller()
	if controller != null:
		controller.call("reset_debug_defaults")
		_refresh_city_lighting_controls()


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
	title.text = tr("fish.debug.observation_title")
	title.add_theme_font_size_override("font_size", 16)
	title.add_theme_color_override("font_color", Color(0.94, 0.96, 0.94))
	parent.add_child(title)
	_fish_observation_species_row = GridContainer.new()
	_fish_observation_species_row.name = "FishObservationSpeciesButtons"
	_fish_observation_species_row.columns = 2
	_fish_observation_species_row.add_theme_constant_override("h_separation", 6)
	_fish_observation_species_row.add_theme_constant_override("v_separation", 4)
	_fish_observation_species_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(_fish_observation_species_row)
	_fish_observation_species_status = _make_debug_label()
	_fish_observation_species_status.name = "FishObservationSpeciesStatus"
	_fish_observation_species_status.text = tr("fish.debug.observation.loading")
	parent.add_child(_fish_observation_species_status)
	_populate_fish_observation_species_buttons()
	var observer_row := HBoxContainer.new()
	observer_row.add_theme_constant_override("separation", 6)
	var observe_button := Button.new()
	observe_button.text = tr("fish.debug.camera.enter")
	observe_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	observe_button.pressed.connect(_on_fish_observation_camera_pressed)
	observer_row.add_child(observe_button)
	var return_button := Button.new()
	return_button.text = tr("fish.debug.camera.return")
	return_button.pressed.connect(_on_fish_observation_camera_return_pressed)
	observer_row.add_child(return_button)
	parent.add_child(observer_row)
	_fish_location_feedback = _make_debug_label()
	_fish_location_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fish_location_feedback.text = tr("fish.debug.location.initial")
	parent.add_child(_fish_location_feedback)
	_fish_observation_status = _make_debug_label()
	_fish_observation_status.name = "FishObservationStatus"
	_fish_observation_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fish_observation_status.text = tr("fish.debug.observation_initial_status")
	parent.add_child(_fish_observation_status)
	_fish_motion_toggle = CheckButton.new()
	_fish_motion_toggle.name = "FishSmoothMotionToggle"
	_fish_motion_toggle.text = tr("fish.debug.motion_toggle")
	_fish_motion_toggle.button_pressed = _fish_school_renderer != null and _fish_school_renderer.smooth_motion_enabled
	_fish_motion_toggle.disabled = _fish_school_renderer == null
	_fish_motion_toggle.toggled.connect(_on_fish_smoothing_toggled)
	parent.add_child(_fish_motion_toggle)
	_fish_motion_status = _make_debug_label()
	_fish_motion_status.name = "FishMotionStatus"
	parent.add_child(_fish_motion_status)
	_update_fish_motion_status()


func _on_fish_resources_ready() -> void:
	_fish_resources_initialized = true
	_populate_fish_observation_species_buttons()


func _populate_fish_observation_species_buttons() -> void:
	if _fish_observation_species_row == null:
		return
	var fish_profiles: Array[FishSpeciesProfile] = _fish_resource_manager.get_species_profiles() if _fish_resource_manager != null else []
	for profile in fish_profiles:
		var button_name := "ObserveFishSpecies_%s" % profile.species_id
		if _fish_observation_species_row.has_node(button_name):
			continue
		var button := Button.new()
		button.name = button_name
		button.text = tr("fish.debug.observe_species") % tr(profile.name_key)
		button.tooltip_text = tr("fish.debug.observe_coastal_tooltip") if profile.behavior_type == "coastal_benthic" else tr("fish.debug.observe_surface_tooltip")
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(_on_fish_observation_pressed.bind(profile.species_id))
		_fish_observation_species_row.add_child(button)
	if _fish_observation_species_status != null:
		_fish_observation_species_status.visible = fish_profiles.is_empty()
		if fish_profiles.is_empty():
			if _fish_resource_manager == null:
				_fish_observation_species_status.text = tr("fish.debug.manager_unavailable")
			elif _fish_resources_initialized:
				_fish_observation_species_status.text = tr("fish.debug.profile_or_depth_unavailable")
			else:
				_fish_observation_species_status.text = tr("fish.debug.observation.loading")


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
		_fish_motion_status.text = tr("fish.debug.renderer_unavailable")
		return
	var stats := _fish_school_renderer.get_render_statistics()
	var species_lines := PackedStringArray()
	var species_counts: Dictionary = stats.get("school_counts_by_species", {})
	if _fish_resource_manager != null:
		for profile in _fish_resource_manager.get_species_profiles():
			var counts: Dictionary = species_counts.get(profile.species_id, {})
			species_lines.append(tr("fish.debug.species_render_counts") % [tr(profile.name_key), int(counts.get("visual", 0)), int(counts.get("logical", 0))])
	_fish_motion_status.text = tr("fish.debug.motion_status") % [
	tr("fish.debug.enabled") if _fish_school_renderer.smooth_motion_enabled else tr("fish.debug.disabled"),
		float(stats.get("movement_update_hz", 0.0)),
		int(stats.get("visible_fish", 0)),
		int(stats.get("near_surface_schools", 0)),
		int(stats.get("surface_ripple_count", 0)),
		"\n".join(species_lines),
		float(stats.get("ai_update_ms", 0.0)),
		float(stats.get("multimesh_submit_ms", 0.0)),
	]


func _update_fish_observation_status() -> void:
	if _fish_observation_status == null:
		return
	if _fish_school_renderer == null or _selected_fish_school_id.is_empty():
		_fish_observation_status.text = tr("fish.debug.observation.none")
		return
	var stats := _fish_school_renderer.get_school_visual_debug(_selected_fish_school_id)
	if stats.is_empty():
		_fish_observation_status.text = tr("fish.debug.observation.loading")
		return
	var behaviors: Dictionary = stats.get("behavior_counts", {})
	var behavior_text := tr("fish.debug.behavior_counts") % [
		tr("fish.behavior.cruise"), int(behaviors.get("cruise", 0)),
		tr("fish.behavior.turn"), int(behaviors.get("turn", 0)),
		tr("fish.behavior.hover"), int(behaviors.get("hover", 0)),
		tr("fish.behavior.flee"), int(behaviors.get("flee", 0)),
	]
	var visibility_key := "fish.debug.visibility.visual" if str(stats.get("render_state", "visual")) == "visual" else "fish.debug.visibility.logical"
	var species_profile := _fish_resource_manager.get_species_profile(str(stats.get("species_id", ""))) if _fish_resource_manager != null else null
	var species_name := tr(species_profile.name_key) if species_profile != null else tr("fish.map.unknown_species")
	var habitat_id := str(stats.get("habitat_region", "unknown"))
	var habitat_key := "fish.map.habitat.%s" % habitat_id
	var habitat_text := tr(habitat_key) if tr(habitat_key) != habitat_key else tr("fish.map.habitat.unknown")
	var activity_id := str(stats.get("activity_label", "cruise"))
	var activity_key := "fish.map.activity.%s" % activity_id
	var activity_text := tr(activity_key) if tr(activity_key) != activity_key else tr("fish.map.activity.unknown")
	_fish_observation_status.text = tr("fish.debug.observation_status") % [
		species_name,
		tr(visibility_key),
		float(stats.get("average_visual_length_m", 0.0)) * 100.0,
		int(stats.get("school_population", 0)),
		int(stats.get("visible_fish", 0)),
		float(stats.get("depth_from_surface_m", 0.0)),
		float(stats.get("bathymetry_depth_m", 0.0)),
		float(stats.get("seabed_clearance_m", 0.0)),
		habitat_text,
		behavior_text,
		activity_text,
	]


func _on_fish_observation_pressed(species_id: String) -> void:
	if _fish_resource_manager == null or _controller == null:
		_fish_location_feedback.text = tr("fish.debug.manager_unavailable")
		return
	var profile := _fish_resource_manager.get_species_profile(species_id)
	var bathymetry := _fish_resource_manager.get_bathymetry_manager()
	if profile == null or bathymetry == null:
		_fish_location_feedback.text = tr("fish.debug.profile_or_depth_unavailable")
		return
	if profile.surface_activity_cycle_enabled:
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
		_fish_location_feedback.text = tr("fish.debug.location.no_resource") % tr(profile.name_key)
		return
	var destination_result: Dictionary
	if profile.behavior_type == "coastal_benthic":
		destination_result = _find_coastal_overhead_position(target_position, origin, bathymetry, profile)
	else:
		destination_result = _find_safe_fish_observation_position(target_position, origin, float(nearest_school.get("depth_m", 0.0)), profile, bathymetry)
	if not bool(destination_result.get("valid", false)):
		_fish_location_feedback.text = tr("fish.debug.location.no_safe_approach") % tr(profile.name_key)
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
	var camera_note := tr("fish.debug.location.camera_started") if observation_started else tr("fish.debug.location.camera_available")
	var location_label := tr("fish.debug.location.over_school") if profile.behavior_type == "coastal_benthic" else tr("fish.debug.location.near_school")
	_fish_location_feedback.text = tr("fish.debug.location.arrived") % [
		tr(profile.name_key),
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
	var nearest_remote_school: Dictionary = {}
	var nearest_remote_rank := 99
	var nearest_remote_distance := INF
	var nearest_remote_position := Vector3.ZERO
	var local_search_radius := _fish_school_renderer.observation_search_radius_m if _fish_school_renderer != null else 5000.0
	var preferred_search_radius := _fish_school_renderer.preferred_observation_search_radius_m if _fish_school_renderer != null else 1500.0
	for school in _fish_resource_manager.get_all_school_snapshots():
		if str(school.get("species_id", "")) != profile.species_id:
			continue
		if _fish_resource_manager.get_school_render_state(school) != "visual":
			continue
		var activity_depth := float(school.get("activity_depth_m", INF))
		# Keep this observation target inside the water-reveal fade envelope; a
		# logically visible school at the threshold edge may be too deep to reveal.
		if activity_depth > maxf(0.0, profile.logical_depth_threshold_m - 0.8):
			continue
		var position_data: Array = school.get("world_position", [])
		if position_data.size() != 3:
			continue
		var school_position := Vector3(float(position_data[0]), origin.y, float(position_data[2]))
		var distance := Vector2(school_position.x - origin.x, school_position.z - origin.z).length()
		var activity_state := str(school.get("surface_activity_state", ""))
		var has_surface_activity := activity_depth <= 2.0 and activity_state in ["near_surface", "ascending", "descending"]
		var has_clear_surface_activity := activity_depth <= 1.2 and has_surface_activity
		var activity_rank := 2
		if has_clear_surface_activity:
			activity_rank = 0
		elif has_surface_activity:
			activity_rank = 1
		if distance > local_search_radius:
			if activity_rank < nearest_remote_rank or (activity_rank == nearest_remote_rank and distance < nearest_remote_distance):
				nearest_remote_rank = activity_rank
				nearest_remote_distance = distance
				nearest_remote_school = school
				nearest_remote_position = school_position
			continue
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
		if nearest_remote_school.is_empty():
			_fish_location_feedback.text = tr("fish.debug.location.no_visible_school") % [local_search_radius / 1000.0, tr(profile.name_key)]
			return
		nearest_school = nearest_remote_school
		nearest_distance = nearest_remote_distance
		target_position = nearest_remote_position
	var destination_result := _find_surface_species_observation_position(target_position, origin, bathymetry)
	if not bool(destination_result.get("valid", false)):
		_fish_location_feedback.text = tr("fish.debug.location.no_safe_surface_approach") % tr(profile.name_key)
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
	var activity_label := tr("fish.debug.location.activity_near_surface") if activity_depth <= 2.0 else tr("fish.debug.location.activity_visible_layer")
	_fish_location_feedback.text = tr("fish.debug.location.arrived_surface") % [
		tr(profile.name_key),
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


func _find_coastal_overhead_position(school_position: Vector3, boat_position: Vector3, bathymetry: BathymetryManager, profile: FishSpeciesProfile) -> Dictionary:
	var sample := bathymetry.get_depth_at_world_position(school_position)
	if not bool(sample.get("valid", false)):
		return {"valid": false}
	var depth := float(sample.get("depth_m", 0.0))
	if depth < profile.minimum_depth_m or depth > profile.maximum_depth_m:
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
			_fish_location_feedback.text = tr("fish.debug.camera.select_school_first")
		return
	if not _fish_school_renderer.begin_observation(_selected_fish_school_id) and _fish_location_feedback != null:
		_fish_location_feedback.text = tr("fish.debug.camera.school_unavailable")


func _on_fish_observation_camera_return_pressed() -> void:
	if _fish_school_renderer != null:
		_fish_school_renderer.end_observation()


func _find_safe_fish_observation_position(school_position: Vector3, boat_position: Vector3, school_depth: float, profile: FishSpeciesProfile, bathymetry: BathymetryManager) -> Dictionary:
	var base_direction := Vector2(boat_position.x - school_position.x, boat_position.z - school_position.z)
	if base_direction.length_squared() < 0.001:
		var forward := -_controller.global_transform.basis.z
		base_direction = Vector2(-forward.x, -forward.z)
	base_direction = base_direction.normalized()
	var preferred_distance := maxf(18.0, profile.flee_radius_m + 5.0)
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
	else:
		_quality_option.select(int(_quality_manager.call("get_quality_index")))
		_frame_limit_option.select(int(_quality_manager.call("get_frame_limit_index")))
		_clouds_toggle.set_pressed_no_signal(bool(_quality_manager.call("get_clouds_enabled")))
		_update_window_mode_button()
	_sync_performance_diagnostic_controls()


func _sync_performance_diagnostic_controls() -> void:
	if _diagnostic_scale_option != null:
		var current_scale := get_viewport().scaling_3d_scale
		var scales := [0.50, 0.67, 0.75]
		var closest_index := 0
		var closest_distance := INF
		for index in range(scales.size()):
			var distance := absf(current_scale - float(scales[index]))
			if distance < closest_distance:
				closest_distance = distance
				closest_index = index
		_diagnostic_scale_option.select(closest_index)
	if _water_fragment_toggle != null:
		_water_fragment_toggle.disabled = _diagnostic_bathymetry == null or not _diagnostic_bathymetry.has_method("set_fragment_cost_isolation")
		var water_mode := int(_diagnostic_bathymetry.call("get_water_diagnostic_mode")) if _diagnostic_bathymetry != null and _diagnostic_bathymetry.has_method("get_water_diagnostic_mode") else 0
		_water_fragment_toggle.set_pressed_no_signal(water_mode == 14)
	if _building_visual_toggle != null:
		_building_visual_toggle.disabled = _building_visual_roots.is_empty()
		_building_visual_toggle.set_pressed_no_signal(not _building_visuals_hidden)
	if _seagrass_visual_toggle != null:
		_seagrass_visual_toggle.disabled = _diagnostic_seabed_manager == null or not _diagnostic_seabed_manager.has_method("set_performance_seagrass_render_enabled")
		var grass_visible := bool(_diagnostic_seabed_manager.call("get_performance_seagrass_render_enabled")) if _diagnostic_seabed_manager != null and _diagnostic_seabed_manager.has_method("get_performance_seagrass_render_enabled") else true
		_seagrass_visual_toggle.set_pressed_no_signal(grass_visible)


func _on_diagnostic_scale_selected(index: int) -> void:
	var scales := [0.50, 0.67, 0.75]
	if index < 0 or index >= scales.size():
		return
	var viewport := get_viewport()
	viewport.scaling_3d_scale = float(scales[index])
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR2
	viewport.fsr_sharpness = 0.2
	_update_debug_status()


func _on_water_fragment_isolation_toggled(enabled: bool) -> void:
	if _diagnostic_bathymetry != null and _diagnostic_bathymetry.has_method("set_fragment_cost_isolation"):
		_diagnostic_bathymetry.call("set_fragment_cost_isolation", enabled)
	_sync_performance_diagnostic_controls()


func _on_building_visuals_toggled(enabled: bool) -> void:
	_set_building_visuals_visible(enabled)


func _on_seagrass_visuals_toggled(enabled: bool) -> void:
	if _diagnostic_seabed_manager != null and _diagnostic_seabed_manager.has_method("set_performance_seagrass_render_enabled"):
		_diagnostic_seabed_manager.call("set_performance_seagrass_render_enabled", enabled)


func _cache_building_visual_roots() -> void:
	_building_visual_roots.clear()
	for path in [
		NodePath("../../MalmoHarbor/CityDistrict"),
		NodePath("../../CopenhagenHarbor"),
	]:
		var root := get_node_or_null(path)
		if root != null:
			_building_visual_roots.append(root)


func _set_building_visuals_visible(enabled: bool) -> void:
	if enabled:
		for entry in _building_visual_previous_states.values():
			var visual := entry.get("node") as VisualInstance3D
			if is_instance_valid(visual):
				visual.visible = bool(entry.get("visible", true))
		_building_visual_previous_states.clear()
		_building_visuals_hidden = false
		return
	_building_visual_previous_states.clear()
	for root in _building_visual_roots:
		if is_instance_valid(root):
			var visuals: Array[VisualInstance3D] = []
			_collect_visual_instances(root, visuals)
			for visual in visuals:
				var instance_id := visual.get_instance_id()
				_building_visual_previous_states[instance_id] = {"node": visual, "visible": visual.visible}
				visual.visible = false
	_building_visuals_hidden = true


func _collect_visual_instances(node: Node, output: Array[VisualInstance3D]) -> void:
	if node is VisualInstance3D:
		output.append(node as VisualInstance3D)
	for child in node.get_children():
		_collect_visual_instances(child, output)


func _update_window_mode_button() -> void:
	if _quality_manager == null or _window_mode_button == null:
		return
	_window_mode_button.text = "切换至窗口模式" if bool(_quality_manager.call("is_fullscreen")) else "切换至全屏"


func _update_hud_layout() -> void:
	if _status_panel == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var viewport_width := maxf(viewport_size.x, 1.0)
	var ui_scale := float(_quality_manager.call("get_ui_scale_factor")) if _quality_manager != null and _quality_manager.has_method("get_ui_scale_factor") else 1.0
	var scale := clampf(ui_scale, 0.9, 1.75)
	var margin := 18.0 * scale
	var status_width := minf(300.0 * scale, maxf(220.0 * scale, viewport_width * 0.30))
	status_width = minf(status_width, maxf(160.0 * scale, viewport_width - margin * 2.0))
	_status_panel.anchor_left = 0.0
	_status_panel.anchor_right = 0.0
	_status_panel.anchor_top = 0.0
	_status_panel.anchor_bottom = 0.0
	_status_panel.custom_minimum_size = Vector2(status_width, 0.0)
	_status_label.custom_minimum_size.x = maxf(120.0 * scale, status_width - 32.0 * scale)
	var environment_height := maxf(100.0 * scale, _status_panel.get_combined_minimum_size().y)
	_status_panel.offset_left = margin
	_status_panel.offset_top = margin
	_status_panel.offset_right = margin + status_width
	_status_panel.offset_bottom = margin + environment_height
	if _activity_button != null:
		var activity_width := minf(220.0 * scale, maxf(150.0, viewport_width * 0.24))
		_activity_button.anchor_left = 1.0
		_activity_button.anchor_right = 1.0
		_activity_button.anchor_top = 0.0
		_activity_button.anchor_bottom = 0.0
		_activity_button.offset_left = -activity_width - margin
		_activity_button.offset_right = -margin
		_activity_button.offset_top = margin
		_activity_button.offset_bottom = margin + 42.0 * scale
		if _activity_menu != null:
			_activity_menu.anchor_left = 1.0
			_activity_menu.anchor_right = 1.0
			_activity_menu.anchor_top = 0.0
			_activity_menu.anchor_bottom = 0.0
			_activity_menu.offset_left = -activity_width - margin
			_activity_menu.offset_right = -margin
			var menu_top := margin + 48.0 * scale
			_activity_menu.offset_top = menu_top
			_activity_menu.offset_bottom = menu_top + 148.0 * scale
			_activity_menu.custom_minimum_size.x = activity_width
	if _fishing_player_panel != null:
		var fishing_width := minf(310.0 * scale, maxf(220.0, viewport_width * 0.30))
		_fishing_player_panel.offset_left = -fishing_width - margin
		_fishing_player_panel.offset_right = -margin
		var fishing_top := margin + 52.0 * scale
		if _activity_menu != null and _activity_menu.visible:
			fishing_top = _activity_menu.offset_bottom + 8.0 * scale
		_fishing_player_panel.offset_top = fishing_top
		_fishing_player_panel.offset_bottom = _fishing_player_panel.offset_top + 220.0 * scale
		_fishing_player_panel.custom_minimum_size.x = fishing_width
	if _autopilot_panel != null:
		_autopilot_panel.anchor_left = 1.0
		_autopilot_panel.anchor_right = 1.0
		_autopilot_panel.anchor_top = 0.0
		_autopilot_panel.anchor_bottom = 0.0
		var top_after_activity := margin + 52.0 * scale
		if _fishing_player_panel != null and _fishing_player_panel.visible:
			top_after_activity = _fishing_player_panel.offset_bottom + 8.0 * scale
		if _activity_menu != null and _activity_menu.visible:
			top_after_activity = maxf(top_after_activity, _activity_menu.offset_bottom + 8.0 * scale)
		_autopilot_panel.offset_left = -minf(390.0 * scale, viewport_width * 0.4) - margin
		_autopilot_panel.offset_right = -margin
		_autopilot_panel.offset_top = top_after_activity
		_autopilot_panel.offset_bottom = top_after_activity + 156.0 * scale
	if _environment_detail_panel != null:
		_environment_detail_panel.anchor_left = 0.0
		_environment_detail_panel.anchor_right = 0.0
		_environment_detail_panel.anchor_top = 0.0
		_environment_detail_panel.anchor_bottom = 0.0
		var detail_top := margin + environment_height + 8.0 * scale
		var detail_height := minf(200.0 * scale, maxf(120.0 * scale, viewport_size.y - detail_top - margin))
		_environment_detail_panel.offset_left = margin
		_environment_detail_panel.offset_top = detail_top
		_environment_detail_panel.offset_right = margin + status_width
		_environment_detail_panel.offset_bottom = detail_top + detail_height
		_environment_detail_panel.custom_minimum_size = Vector2(status_width, 0.0)
	if _help_panel != null:
		_help_panel.anchor_left = 1.0
		_help_panel.anchor_right = 1.0
		_help_panel.anchor_top = 0.0
		_help_panel.anchor_bottom = 0.0
		_help_panel.offset_left = -minf(300.0 * scale, viewport_width * 0.34) - margin
		_help_panel.offset_right = -margin
		_help_panel.offset_top = 52.0 * scale + margin
		_help_panel.offset_bottom = 210.0 * scale + margin
	if _map_button != null:
		_map_button.anchor_left = 0.0
		_map_button.anchor_right = 0.0
		_map_button.anchor_top = 1.0
		_map_button.anchor_bottom = 1.0
		_map_button.offset_left = margin
		_map_button.offset_right = margin + 120.0 * scale
		_map_button.offset_top = -52.0 * scale - margin
		_map_button.offset_bottom = -margin
		_map_button.visible = _fish_map != null and _fish_map.has_method("get_display_mode") and str(_fish_map.call("get_display_mode")) == "hidden" and (_fish_finder_display == null or str(_fish_finder_display.call("get_display_mode")) == "hidden")
	if _navigation_core_panel != null:
		var nav_width := minf(310.0 * scale, maxf(230.0 * scale, viewport_width * 0.32))
		var sail_detail := _controller != null and _controller.is_sailing_active() and _navigation_detail_requested
		var sailing_active := _controller != null and _controller.is_sailing_active()
		var nav_height := (150.0 if sailing_active else (136.0 if _navigation_detail_requested else 116.0)) * scale
		nav_height = minf(nav_height, maxf(96.0 * scale, viewport_size.y - margin * 2.0))
		_navigation_core_panel.visible = not sail_detail
		_navigation_core_panel.offset_left = -nav_width - margin
		_navigation_core_panel.offset_right = -margin
		_navigation_core_panel.offset_bottom = -margin
		_navigation_core_panel.offset_top = -nav_height - margin
		_navigation_core_panel.custom_minimum_size = Vector2(nav_width, nav_height)
	if _sailing_panel != null:
		var sailing_width := minf(500.0 * scale, maxf(280.0, viewport_width * 0.46))
		var sailing_height := minf(590.0 * scale, maxf(280.0, viewport_size.y * 0.82))
		_sailing_panel.custom_minimum_size = Vector2(sailing_width, sailing_height)
		_sailing_panel.offset_left = -sailing_width - margin
		_sailing_panel.offset_right = -margin
		_sailing_panel.offset_top = -sailing_height - margin
		_sailing_panel.offset_bottom = -margin
	if _debug_panel != null:
		var debug_width := minf(390.0 * scale, maxf(280.0, viewport_width - 48.0 * scale))
		_debug_panel.custom_minimum_size.x = debug_width
		_debug_panel.offset_left = -debug_width - margin
		_debug_panel.offset_right = -margin
		_debug_panel.offset_top = minf(196.0 * scale, maxf(80.0 * scale, viewport_size.y * 0.2))
		_debug_panel.offset_bottom = -16.0 * scale
		_debug_panel.custom_minimum_size.y = 0.0
		_debug_scroll.custom_minimum_size.y = 0.0
		if _fish_finder_display != null and is_instance_valid(_fish_finder_display) and _fish_finder_display.has_method("set_overlay_obstruction_rect"):
			var obstruction := Rect2()
			if _debug_panel.visible:
				obstruction = Rect2(
					Vector2(viewport_width + _debug_panel.offset_left, _debug_panel.offset_top),
					Vector2(_debug_panel.offset_right - _debug_panel.offset_left, viewport_size.y + _debug_panel.offset_bottom - _debug_panel.offset_top)
				)
			_fish_finder_display.call("set_overlay_obstruction_rect", obstruction)
	if _catch_result_panel != null:
		var catch_scale := scale
		var catch_width := minf(336.0 * catch_scale, maxf(220.0, viewport_width - 48.0 * catch_scale))
		_catch_result_panel.offset_left = -24.0 * catch_scale - catch_width
		_catch_result_panel.offset_right = -24.0 * catch_scale
		_catch_result_panel.anchor_top = 0.34
		_catch_result_panel.anchor_bottom = 0.34
		_catch_result_panel.offset_top = 0.0
		_catch_result_panel.offset_bottom = 138.0 * catch_scale
		_catch_result_panel.custom_minimum_size = Vector2(catch_width, 138.0 * catch_scale)
	if _polar_panel != null:
		var polar_width := minf(1160.0, maxf(760.0, viewport_size.x * 0.94))
		var polar_height := minf(860.0, maxf(560.0, viewport_size.y * 0.92))
		_polar_panel.custom_minimum_size = Vector2(polar_width, polar_height)
		_polar_panel.offset_left = -polar_width * 0.5
		_polar_panel.offset_right = polar_width * 0.5
		_polar_panel.offset_top = -polar_height * 0.5
		_polar_panel.offset_bottom = polar_height * 0.5


static func sailing_panel_layout_metrics(viewport_size: Vector2, ui_scale: float, detailed: bool) -> Dictionary:
	var scale := clampf(ui_scale, 0.9, 1.75)
	var screen_width := minf(420.0 * scale, maxf(260.0, viewport_size.x * 0.44))
	var screen_height_target := (500.0 if detailed else 420.0) * scale
	var screen_height := minf(screen_height_target, maxf(250.0, viewport_size.y * 0.78))
	return {
		"screen_width": screen_width,
		"screen_height": screen_height,
		"local_width": screen_width / scale,
		"local_height": screen_height / scale,
		"screen_left": viewport_size.x - screen_width - 24.0 * scale,
		"screen_top": viewport_size.y - screen_height - 24.0 * scale,
	}


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
	_update_weather_runtime_debug_status()
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
	var primitives := int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	var process_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
	var render_metrics: Dictionary = _quality_manager.call("get_render_metrics") if _quality_manager != null else {}
	var window_px: Vector2i = render_metrics.get("window_px", Vector2i.ZERO)
	var viewport_px: Vector2i = render_metrics.get("viewport_px", Vector2i.ZERO)
	var requested_viewport_px: Vector2i = render_metrics.get("root_viewport_requested_px", viewport_px)
	var design_viewport_px: Vector2i = render_metrics.get("design_viewport_px", Vector2i.ZERO)
	var internal_px: Vector2i = render_metrics.get("internal_3d_px_estimate", Vector2i.ZERO)
	var clouds_compute_px: Vector2i = render_metrics.get("cloud_compute_px_estimate", Vector2i.ZERO)
	var clouds_post_px: Vector2i = render_metrics.get("cloud_postprocess_px_estimate", Vector2i.ZERO)
	var screen_px: Vector2i = render_metrics.get("screen_px", Vector2i.ZERO)
	var window_screen_index := int(render_metrics.get("window_screen_index", -1))
	var screen_count := int(render_metrics.get("screen_count", 0))
	var screen_scale := float(render_metrics.get("screen_scale", 1.0))
	var ui_scale := float(render_metrics.get("ui_scale_factor", 1.0))
	var content_scale_factor := float(render_metrics.get("window_content_scale_factor", 1.0))
	var content_scale_mode := str(render_metrics.get("content_scale_mode", "unknown"))
	var content_scale_aspect := str(render_metrics.get("content_scale_aspect", "unknown"))
	var scale := float(render_metrics.get("resolution_scale", 1.0))
	var source := str(_quality_manager.call("get_quality_selection_source")) if _quality_manager != null else ""
	var vsync_mode := int(render_metrics.get("vsync", 0))
	var max_fps := int(render_metrics.get("max_fps", 0))
	var frame_limit_text := "Unlimited" if max_fps <= 0 else "%d FPS" % max_fps
	var sample_status := "采样中：%.1f / %d s" % [_perf_elapsed_seconds, roundi(_perf_target_duration_seconds)] if _perf_sampling_active else _perf_sample_result
	_performance_label.text = "平台 %s · 窗口模式：%s\n实际 %d FPS · FPS 反算帧时 %.2f ms · Godot Process monitor %.2f ms（不是 GDScript 总耗时）\n%s\nDraw Calls %d · 可见物体 %d · 图元 %d\nGodot 窗口 API 尺寸 %dx%d · 屏幕 API 尺寸 %dx%d · 窗口屏幕索引 %d / %d（从 0 开始）\nHiDPI 允许 %s · DisplayServer 屏幕比例 ×%.1f（API 值，不等同 OS DPI）\nUI Scale ×%.2f · Window 内容因子 ×%.2f · 内容模式 %s / %s · 导航 %s\n项目基准 %dx%d · 根 Viewport 实际 %dx%d / 请求 %dx%d\n3D 内部估算 %dx%d @ %.0f%% (%s) · 超采样 %s\nSunshine Clouds Compute / PostPass 尺寸估算 %dx%d / %dx%d\n帧率上限 %s · VSync %s · 档位来源：%s · GPU：%s" % [
		str(render_metrics.get("platform", OS.get_name())),
		str(render_metrics.get("window_mode", "未知")),
		fps,
		1000.0 / float(fps) if fps > 0 else 0.0,
		process_ms,
		sample_status,
		draw_calls,
		visible_objects,
		primitives,
		window_px.x, window_px.y,
		screen_px.x, screen_px.y,
		window_screen_index, screen_count,
		"开" if bool(render_metrics.get("hidpi_enabled", false)) else "关",
		screen_scale,
		ui_scale,
		content_scale_factor,
		content_scale_mode,
		content_scale_aspect,
		"详细" if _quality_manager != null and _quality_manager.has_method("get_navigation_detail_enabled") and bool(_quality_manager.call("get_navigation_detail_enabled")) else "简洁",
		design_viewport_px.x, design_viewport_px.y,
		viewport_px.x, viewport_px.y,
		requested_viewport_px.x, requested_viewport_px.y,
		internal_px.x, internal_px.y,
		scale * 100.0,
		str(render_metrics.get("upscaler", "n/a")),
		"开" if bool(render_metrics.get("supersampling", false)) else "关",
		clouds_compute_px.x, clouds_compute_px.y,
		clouds_post_px.x, clouds_post_px.y,
		frame_limit_text,
		"开" if vsync_mode == DisplayServer.VSYNC_ENABLED else "关",
		source,
		str(render_metrics.get("adapter", "n/a")),
	]
	_refresh_settings_controls()
	_sync_performance_diagnostic_controls()
	_refresh_city_lighting_controls()
	_update_sailing_physics_debug_status()


func _update_weather_runtime_debug_status() -> void:
	if _weather_runtime_status_label == null:
		return
	if _weather_runtime_authority == null:
		_weather_runtime_status_label.text = "Weather runtime authority: unavailable"
		return
	var data_source := str(_weather_runtime_authority.get("data_source_status"))
	var quality := str(_weather_runtime_authority.get("forecast_data_quality"))
	var mapping := str(_weather_runtime_authority.get("mapping_status"))
	var refresh := str(_weather_runtime_authority.get("last_refresh_status"))
	var region := str(_weather_runtime_authority.get("region_id"))
	var mode := str(_weather_state_controller.call("get_operating_mode_name")) if _weather_state_controller != null and _weather_state_controller.has_method("get_operating_mode_name") else "unknown"
	var sample: Dictionary = _weather_runtime_authority.get("current_sample")
	var timeline_wind := "unavailable"
	if sample.has("mean_wind_speed_mps") and sample.has("wind_from_direction_deg"):
		timeline_wind = "%.1f m/s · %.0f° from" % [float(sample["mean_wind_speed_mps"]), float(sample["wind_from_direction_deg"])]
	var effective_wind := "unavailable"
	var override_state := "formal"
	if _wind_field != null and _wind_field.has_method("get_effective_wind_settings"):
		var wind_settings: Dictionary = _wind_field.call("get_effective_wind_settings")
		effective_wind = "%.1f m/s · %.0f° from" % [float(wind_settings.get("mean_wind_speed_mps", 0.0)), float(wind_settings.get("mean_wind_from_degrees", 0.0))]
		if _wind_field.has_method("get_debug_override_state"):
			override_state = str(_wind_field.call("get_debug_override_state"))
	var provider_error := str(_weather_runtime_authority.get("provider_error"))
	_weather_runtime_status_label.text = "Weather runtime · %s · %s / %s\nRegion %s · quality %s · mapping %s · refresh %s\nTimeline wind %s · effective wind %s (%s)%s" % [
		mode, data_source, quality, region, quality, mapping, refresh, timeline_wind, effective_wind, override_state,
		("\nProvider: " + provider_error.left(96)) if not provider_error.is_empty() else "",
	]


func _update_sailing_physics_debug_status() -> void:
	if _sailboat_physics_label == null:
		return
	var body := _controller.get_sailing_body() if _controller != null else null
	if _controller == null or not _controller.is_sailing_active() or body == null or not body.has_method("get_debug_snapshot"):
		_sailboat_physics_label.text = "当前使用动力艇。切换至帆船后，这里显示缓存的帆力、水动力和性能诊断。"
		return
	var snapshot: Dictionary = body.call("get_debug_snapshot")
	var navigation: Dictionary = body.call("get_navigation_snapshot") if body.has_method("get_navigation_snapshot") else {}
	var profile: Resource = body.get("profile") as Resource
	var main_force: Vector3 = snapshot.get("sail_net_force_local_n", Vector3.ZERO)
	var jib_force: Vector3 = snapshot.get("headsail_net_force_local_n", Vector3.ZERO)
	var yaw_damping_coefficient := float(profile.get("yaw_damping_n_m_s_per_rad")) if profile != null else 0.0
	var explicit_yaw_damping := -float(snapshot.get("yaw_rate_rad_s", 0.0)) * yaw_damping_coefficient
	_sailboat_physics_label.text = "帆船状态：HDG %03.0f° · 航速 %.2f kn\n主帆合力：前向 %+.1f N · 横向 %+.1f N · 偏航力矩 %+.1f N·m\n前帆合力：前向 %+.1f N · 横向 %+.1f N · 偏航力矩 %+.1f N·m\n龙骨偏航力矩：%+.1f N·m · 船舵偏航力矩：%+.1f N·m\n船舵处水速：%.2f m/s · 船体侧滑：%+.1f°\n估算显式偏航阻尼：%+.1f N·m · 已测外部偏航力矩和：%+.1f N·m\n物理代码段平均/P95：%d / %d μs\n风场采样：%d 次/物理步 · 海浪采样：%d 次/物理步" % [
		float(navigation.get("heading_degrees", snapshot.get("heading_degrees", 0.0))),
		float(navigation.get("sog_knots", 0.0)),
		-main_force.z, main_force.x, float(snapshot.get("sail_yaw_torque_nm", 0.0)),
		-jib_force.z, jib_force.x, float(snapshot.get("headsail_yaw_torque_nm", 0.0)),
		float(snapshot.get("keel_yaw_torque_nm", 0.0)),
		float(snapshot.get("rudder_yaw_torque_nm", 0.0)),
		float(snapshot.get("rudder_water_speed_mps", 0.0)),
		rad_to_deg(float(snapshot.get("keel_side_slip_angle_rad", 0.0))),
		explicit_yaw_damping,
		float(snapshot.get("total_external_yaw_torque_nm", 0.0)),
		int(snapshot.get("total_physics_calculation_average_usec", 0)),
		int(snapshot.get("total_physics_calculation_p95_usec", 0)),
		int(snapshot.get("wind_query_count_per_tick", 0)),
		int(snapshot.get("wave_query_count_per_tick", 0)),
	]


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
	if _weather_state_controller != null:
		_weather_state_controller.call("set_weather_by_index", index)
		_refresh_weather_controls()
	elif _weather_controller != null:
		# Fallback for isolated visual-controller tests that do not instantiate W2.1.
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
	if _quality_manager != null and _quality_manager.has_method("is_diagnostic_override_active") and bool(_quality_manager.call("is_diagnostic_override_active")):
		_restore_debug_panel_overrides()
	if is_instance_valid(_wave_sampler) and _wave_sampler.has_method("clear_extreme_sea_test"):
		_wave_sampler.call("clear_extreme_sea_test")


func _on_quality_selected(index: int) -> void:
	if _quality_manager != null:
		_quality_manager.call("set_quality_for_diagnostic", index)
		_refresh_settings_controls()


func _on_frame_limit_selected(index: int) -> void:
	if _quality_manager != null:
		_quality_manager.call("set_frame_limit_for_diagnostic", index)
		_refresh_settings_controls()


func _on_clouds_toggled(enabled: bool) -> void:
	if _quality_manager != null:
		_quality_manager.call("set_clouds_enabled", enabled)


func _on_window_mode_pressed() -> void:
	if _quality_manager != null:
		_quality_manager.call("toggle_fullscreen_for_diagnostic")
		_update_window_mode_button()


func _begin_debug_panel_overrides() -> void:
	if _quality_manager != null and _quality_manager.has_method("begin_diagnostic_override"):
		_quality_manager.call("begin_diagnostic_override")
	_debug_panel_snapshot = {
		"water_fragment_was_active": _diagnostic_bathymetry != null and _diagnostic_bathymetry.has_method("get_water_diagnostic_mode") and int(_diagnostic_bathymetry.call("get_water_diagnostic_mode")) == 14,
		"seagrass_visible": _diagnostic_seabed_manager != null and _diagnostic_seabed_manager.has_method("get_performance_seagrass_render_enabled") and bool(_diagnostic_seabed_manager.call("get_performance_seagrass_render_enabled")),
		"buildings_hidden": _building_visuals_hidden,
	}
	_debug_panel_visual_snapshot.clear()
	for root in _building_visual_roots:
		if not is_instance_valid(root):
			continue
		var visuals: Array[VisualInstance3D] = []
		_collect_visual_instances(root, visuals)
		for visual in visuals:
			_debug_panel_visual_snapshot[visual.get_instance_id()] = {"node": visual, "visible": visual.visible}


func _restore_debug_panel_overrides() -> void:
	if _diagnostic_bathymetry != null and _diagnostic_bathymetry.has_method("get_water_diagnostic_mode") and _diagnostic_bathymetry.has_method("set_fragment_cost_isolation"):
		if not bool(_debug_panel_snapshot.get("water_fragment_was_active", false)) and int(_diagnostic_bathymetry.call("get_water_diagnostic_mode")) == 14:
			_diagnostic_bathymetry.call("set_fragment_cost_isolation", false)
	for entry in _debug_panel_visual_snapshot.values():
		var visual := entry.get("node") as VisualInstance3D
		if is_instance_valid(visual):
			visual.visible = bool(entry.get("visible", true))
	_debug_panel_visual_snapshot.clear()
	_building_visual_previous_states.clear()
	_building_visuals_hidden = bool(_debug_panel_snapshot.get("buildings_hidden", false))
	if _diagnostic_seabed_manager != null and _diagnostic_seabed_manager.has_method("set_performance_seagrass_render_enabled"):
		_diagnostic_seabed_manager.call("set_performance_seagrass_render_enabled", bool(_debug_panel_snapshot.get("seagrass_visible", true)))
	_debug_panel_snapshot.clear()
	if _quality_manager != null and _quality_manager.has_method("restore_diagnostic_overrides"):
		_quality_manager.call("restore_diagnostic_overrides")
	_refresh_settings_controls()
	_update_debug_status()


func _reset_debug_graphics_overrides() -> void:
	_restore_debug_panel_overrides()
	if _quality_manager != null and _quality_manager.has_method("begin_diagnostic_override"):
		_quality_manager.call("begin_diagnostic_override")
	_begin_debug_panel_overrides()
	_sync_performance_diagnostic_controls()
	_update_debug_status()

