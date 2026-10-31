extends SceneTree

const FORMAT := preload("res://scripts/navigation_hud_format.gd")
const HUD_LAYOUT := preload("res://scripts/boat_hud.gd")

var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var localization_manager := root.get_node_or_null("LocalizationManager")
	var previous_locale := str(localization_manager.get("current_locale_id")) if localization_manager != null else TranslationServer.get_locale()
	if localization_manager != null and localization_manager.has_method("set_locale_id"):
		localization_manager.call("set_locale_id", "zh_CN")
	else:
		TranslationServer.set_locale("zh_CN")
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	_check(main_scene != null, "Main PackedScene loads")
	if main_scene == null:
		quit(1)
		return
	var main := main_scene.instantiate()
	root.add_child(main)
	for _frame in range(12):
		await physics_frame

	var controller := main.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	var sailboat := main.get_node_or_null("PlayerBoat/SailingBoat8m") as RigidBody3D
	var vessel_picker := main.find_child("VesselPickerOverlay", true, false) as Control
	var vessel_hud := main.find_child("BoatHUD", true, false) as CanvasLayer
	var quality_manager := main.get_node_or_null("QualityManager") as QualityManager
	var sailboat_card := main.find_child("SailboatCard", true, false) as Control
	var motorboat_card := main.find_child("PowerboatCard", true, false) as Control
	var sailboat_preview := sailboat_card.find_child("ModelPreviewViewport", true, false) as SubViewport if sailboat_card != null else null
	var motorboat_preview := motorboat_card.find_child("ModelPreviewViewport", true, false) as SubViewport if motorboat_card != null else null
	var sailboat_name_label := sailboat_card.find_child("VesselNameLabel", true, false) as Label if sailboat_card != null else null
	var sailboat_type_label := sailboat_card.find_child("VesselTypeLabel", true, false) as Label if sailboat_card != null else null
	var sailboat_details_label := sailboat_card.find_child("VesselDetailsLabel", true, false) as Label if sailboat_card != null else null
	var activities_button := vessel_hud.find_child("ActivitiesButton", true, false) as Button if vessel_hud != null else null
	var activities_menu := vessel_hud.find_child("ActivitiesMenu", true, false) as Control if vessel_hud != null else null
	var trolling_panel := vessel_hud.find_child("FishingPlayerPanel", true, false) as FishingPlayerPanel if vessel_hud != null else null
	var fish_finder := vessel_hud.find_child("FishFinderDisplay", true, false) as FishFinderDisplay if vessel_hud != null else null
	var fish_map := main.find_child("FishResourceMap", true, false) as FishResourceMap
	var fish_map_instances := main.find_children("FishResourceMap", "CanvasLayer", true, false)
	var sea_chart := main.get_node_or_null("DepthChartHUD") as CanvasLayer
	var sea_chart_view := sea_chart.find_child("Chart", true, false) as DepthChartView if sea_chart != null else null
	var depth_map_canvas := fish_map.find_child("DepthQualityMap", true, false) as DepthQualityMapCanvas if fish_map != null else null
	var resource_map_canvas := fish_map.find_child("ResourceDistributionMap", true, false) as FishResourceMapCanvas if fish_map != null else null
	var weather_runtime_diagnostics := main.get_node_or_null("WeatherRuntimeDiagnostics") as CanvasLayer
	var environment_summary := vessel_hud.find_child("EnvironmentSummaryPanel", true, false) as Control if vessel_hud != null else null
	var navigation_core_panel := vessel_hud.find_child("NavigationCorePanel", true, false) as Control if vessel_hud != null else null
	var navigation_core_status := vessel_hud.find_child("NavigationCoreStatus", true, false) as Label if vessel_hud != null else null
	var weather_runtime_readout := vessel_hud.find_child("WeatherRuntimeReadout", true, false) as Label if vessel_hud != null else null
	var developer_panel := vessel_hud.find_child("DebugPanel", true, false) as Control if vessel_hud != null else null
	_check(controller != null, "Main retains its BoatController navigation facade")
	_check(sailboat != null, "Main has the reusable SailingBoat8m body")
	_check(vessel_picker != null, "Main HUD has a separate vessel picker outside F3")
	_check(main.find_child("VesselSelectionButton", true, false) == null, "F3 debug panel no longer exposes vessel switching")
	_check(sailboat_card != null and motorboat_card != null, "Vessel picker lists both current vessel models")
	_check(sailboat_preview != null and motorboat_preview != null, "Each vessel card has an isolated 3D preview viewport")
	_check(sailboat_name_label != null and sailboat_name_label.text == "Nordic 28", "Picker shows the Nordic 28 vessel name")
	_check(sailboat_type_label != null and sailboat_type_label.text.contains("近海休闲帆船"), "Picker classifies Nordic 28 as a coastal cruising sailboat")
	_check(sailboat_details_label != null and sailboat_details_label.text.contains("主帆") and sailboat_details_label.text.contains("前帆") and sailboat_details_label.text.contains("自动操帆"), "Picker describes the implemented sailboat equipment and controls")
	_check(activities_button != null and activities_menu != null and not activities_menu.visible, "Activities entry is visible while its menu starts closed")
	_check(trolling_panel != null and not trolling_panel.visible and fish_finder != null and not fish_finder.visible, "Trolling and Fish Finder remain hidden until opened")
	_check(fish_map != null and fish_map.get_display_mode() == "mini" and sea_chart != null and sea_chart.visible, "The local Sea Chart starts in the lower-left corner")
	_check(sea_chart_view != null and sea_chart_view.visible and resource_map_canvas != null and not resource_map_canvas.visible and depth_map_canvas != null and not depth_map_canvas.visible, "Mini mode shows the local chart and keeps both full-map canvases hidden")
	var sea_chart_stats := sea_chart_view.get_chart_build_statistics() if sea_chart_view != null else {}
	_check(sea_chart_view != null and int(sea_chart_stats.get("pixels_total", 0)) == 128 * 92 and int(sea_chart_stats.get("pixels_per_frame_budget", 0)) == 256, "Sea Chart bathymetry sampling uses a bounded per-frame budget")
	_check(InputMap.has_action("map_toggle") and InputMap.action_get_events("map_toggle").size() == 1, "M is assigned to the chart toggle action")
	_check(sea_chart != null and fish_map_instances.size() == 1, "Main scene instantiates one compact Sea Chart and one full-map tool")
	_check(weather_runtime_diagnostics != null and not weather_runtime_diagnostics.visible, "Weather runtime diagnostics stay out of normal HUD while remaining available as a debug node")
	_check(weather_runtime_readout != null and developer_panel != null and not developer_panel.visible, "Detailed weather runtime data is placed inside the closed F3 panel")
	if weather_runtime_readout != null and developer_panel != null:
		developer_panel.visible = true
		vessel_hud.call("_update_debug_status")
		_check(weather_runtime_readout.text.contains("Weather runtime") and weather_runtime_readout.text.contains("Timeline wind") and weather_runtime_readout.text.contains("effective wind"), "F3 retains the weather source, quality, timeline and effective wind diagnostics")
		developer_panel.visible = false
	_check(environment_summary != null and environment_summary.size.y <= 115.0, "Environment summary uses a compact content-sized height")
	var fps_display := environment_summary.find_child("FPSDisplay", true, false) as Label if environment_summary != null else null
	_check(fps_display != null and fps_display.visible and fps_display.text.begins_with("FPS:"), "Environment summary shows a live FPS readout")
	_check(navigation_core_panel != null and navigation_core_status != null and navigation_core_status.visible and navigation_core_status.text.contains("油门输入"), "Powerboat compact instrument shows the real driving mode and throttle input")
	_check(navigation_core_panel != null and navigation_core_panel.size.y <= 130.0, "Powerboat compact instrument stays within the compact height target")
	var map_panel := fish_map.find_child("MapPanel", true, false) as Control if fish_map != null else null
	_check(map_panel != null, "The single production chart exposes its actual display panel")
	var original_window_size := root.size
	for test_size in [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080), Vector2i(1280, 1024)]:
		root.size = test_size
		await process_frame
		if vessel_hud != null:
			vessel_hud.call("_update_hud_layout")
		var viewport_rect := Rect2(Vector2.ZERO, get_root().get_visible_rect().size)
		var environment_rect := environment_summary.get_global_rect() if environment_summary != null else Rect2()
		var navigation_rect := navigation_core_panel.get_global_rect() if navigation_core_panel != null else Rect2()
		_check(environment_summary != null and viewport_rect.encloses(environment_rect), "Environment summary remains inside the viewport at %s" % test_size)
		_check(navigation_core_panel != null and viewport_rect.encloses(navigation_rect), "Navigation instrument remains inside the viewport at %s" % test_size)
	root.size = original_window_size
	await process_frame
	if vessel_hud != null:
		vessel_hud.call("_update_hud_layout")
	if activities_button != null and activities_menu != null and trolling_panel != null:
		activities_button.pressed.emit()
		var open_trolling := activities_menu.find_child("OpenTrollingActivity", true, false) as Button
		if open_trolling != null:
			open_trolling.pressed.emit()
		await process_frame
		_check(trolling_panel.visible and not trolling_panel.is_trolling_active(), "Opening trolling configuration does not start trolling")
		var trolling_speed_label := trolling_panel.find_child("TrollingSpeedSuitability", true, false) as Label
		_check(trolling_speed_label != null and trolling_speed_label.text.begins_with("船速：") and trolling_speed_label.text.contains("节"), "Trolling configuration reports speed suitability using P2's speed rules")
		var close_trolling := trolling_panel.find_child("ConfigurationCloseButton", true, false) as Button
		if close_trolling != null:
			close_trolling.pressed.emit()
		await process_frame
		_check(not trolling_panel.visible and not trolling_panel.is_trolling_active(), "Cancelling trolling configuration closes it without changing activity state")
		activities_button.pressed.emit()
		open_trolling = activities_menu.find_child("OpenTrollingActivity", true, false) as Button
		if open_trolling != null:
			open_trolling.pressed.emit()
		var trolling_action := trolling_panel.find_child("TrollingActionButton", true, false) as Button
		var collapse_activity := trolling_panel.find_child("ActivityCollapseButton", true, false) as Button
		if trolling_action != null:
			trolling_action.pressed.emit()
		await process_frame
		_check(trolling_panel.visible and trolling_panel.is_trolling_active(), "Starting trolling opens the status panel from the authoritative activity state")
		if collapse_activity != null:
			collapse_activity.pressed.emit()
		_check(trolling_panel.visible and trolling_panel.is_trolling_active(), "Collapsing the activity panel does not stop trolling")
		if trolling_action != null:
			trolling_action.pressed.emit()
		await process_frame
		_check(not trolling_panel.visible and not trolling_panel.is_trolling_active(), "Stopping trolling clears the in-progress activity panel")
		activities_button.pressed.emit()
		open_trolling = activities_menu.find_child("OpenTrollingActivity", true, false) as Button
		if open_trolling != null:
			open_trolling.pressed.emit()
		var game_menu := main.get_node_or_null("GameMenu")
		var language_option := game_menu.find_child("LanguageOption", true, false) as OptionButton if game_menu != null else null
		var lure_option := trolling_panel.find_child("LureSelector", true, false) as OptionButton
		if game_menu != null:
			game_menu.call("_open_menu")
			game_menu.call("_show_settings_page")
		_check(language_option != null and language_option.item_count == 2, "Settings exposes both supported interface languages")
		if language_option != null:
			language_option.select(1)
			language_option.item_selected.emit(1)
			await process_frame
			var english_lure_found := false
			if lure_option != null:
				for item_index in range(lure_option.item_count):
					english_lure_found = english_lure_found or lure_option.get_item_text(item_index).contains("Surface lure")
			_check(activities_button.text == "Activities" and english_lure_found, "Choosing English immediately translates the HUD and open trolling setup")
			var saved_locale := ConfigFile.new()
			var english_locale_persisted := saved_locale.load("user://localization_settings.cfg") == OK and str(saved_locale.get_value("localization", "locale", "")) == "en"
			_check(english_locale_persisted, "Choosing English persists the language for the next launch")
			language_option.select(0)
			language_option.item_selected.emit(0)
			await process_frame
			var chinese_lure_found := false
			if lure_option != null:
				for item_index in range(lure_option.item_count):
					chinese_lure_found = chinese_lure_found or lure_option.get_item_text(item_index).contains("表层拟饵")
			_check(activities_button.text == "活动" and chinese_lure_found, "Choosing Simplified Chinese immediately translates the HUD and open trolling setup")
		if game_menu != null:
			game_menu.call("_close_menu")
		var close_trolling_after_locale := trolling_panel.find_child("ConfigurationCloseButton", true, false) as Button
		if close_trolling_after_locale != null:
			close_trolling_after_locale.pressed.emit()
		await process_frame
	if activities_button != null and activities_menu != null and fish_finder != null and fish_map != null:
		activities_button.pressed.emit()
		var open_finder := activities_menu.find_child("OpenFishFinderTool", true, false) as Button
		if open_finder != null:
			open_finder.pressed.emit()
		await process_frame
		_check(fish_finder.visible and fish_map.get_display_mode() == "hidden", "Opening Fish Finder temporarily hides the compact chart")
		var finder_title := fish_finder.find_child("FishFinderTitle", true, false) as Label
		var sea_chart_title := sea_chart.find_child("SeaChartTitle", true, false) as Label if sea_chart != null else null
		if localization_manager != null and localization_manager.has_method("set_locale_id"):
			localization_manager.call("set_locale_id", "en")
			await process_frame
			_check(finder_title != null and finder_title.text.begins_with("Fish Finder") and sea_chart_title != null and sea_chart_title.text == "SEA CHART · ØRESUND", "Open Fish Finder and the compact Sea Chart refresh in English at runtime")
			localization_manager.call("set_locale_id", "zh_CN")
			await process_frame
			_check(finder_title != null and finder_title.text.begins_with("鱼探仪") and sea_chart_title != null and sea_chart_title.text == "海图 · 厄勒海峡", "Open Fish Finder and the compact Sea Chart refresh in Chinese at runtime")
		fish_finder.close_display()
		await process_frame
		_check(not fish_finder.visible and fish_map.get_display_mode() == "mini", "Closing Fish Finder restores the compact chart")
	if controller == null or sailboat == null:
		quit(1)
		return
	_check(not controller.is_sailing_active(), "Motorboat remains selected by default")
	_check(controller.has_engine() and controller.supports_autopilot() and controller.supports_cargo(), "Default powerboat keeps engine, autopilot, and cargo capabilities")
	_check(sailboat.freeze and not sailboat.visible, "Inactive sailboat is frozen and hidden")
	_check(get_nodes_in_group("wave_sampler").size() == 1, "Main has exactly one WaveSampler")
	var depth_provider := main.get_node_or_null("NavigationDepthProvider") as NavigationDepthProvider
	var spawn_marker := main.get_node_or_null("SailingBoatSpawn") as Marker3D
	_check(spawn_marker != null, "Main defines an explicit sailboat open-water spawn marker")
	if depth_provider != null:
		var depth_position := spawn_marker.global_position if spawn_marker != null else controller.global_position
		var spawn_depth := depth_provider.query_world_position(depth_position)
		var spawn_evaluation := NavigationDepthProvider.evaluate_depth_sample(spawn_depth, 0.9, 0.5)
		print("C8 spawn depth: %.2f m LAT · status=%s · quality=%s" % [
			float(spawn_depth.get("depth_m", -1.0)),
			str(spawn_evaluation.get("status", "unknown")),
			str(spawn_depth.get("quality", "unknown")),
		])
		_check(bool(spawn_depth.get("valid", false)), "Sailboat spawn resolves to a water depth sample")
		_check(float(spawn_depth.get("depth_m", 0.0)) >= 1.4, "Sailboat spawn DTM depth exceeds 0.9 m draft plus 0.5 m nominal margin")
		_check(not bool(spawn_depth.get("navigation_grade", false)), "Spawn depth is explicitly treated as coarse DTM, not navigation-grade")

	var reference_position := controller.global_position
	if vessel_hud != null:
		var open_picker_event := InputEventKey.new()
		open_picker_event.physical_keycode = KEY_I
		open_picker_event.pressed = true
		vessel_hud.call("_unhandled_key_input", open_picker_event)
	_check(vessel_picker != null and vessel_picker.visible, "I opens the current vessel picker")
	if vessel_hud != null:
		var close_picker_event := InputEventKey.new()
		close_picker_event.physical_keycode = KEY_I
		close_picker_event.pressed = true
		vessel_hud.call("_unhandled_key_input", close_picker_event)
	_check(vessel_picker != null and not vessel_picker.visible, "I closes the current vessel picker")
	if vessel_hud != null:
		vessel_hud.call("_open_vessel_picker")
	var sailboat_select_button := sailboat_card.find_child("SelectButton", true, false) as Button if sailboat_card != null else null
	if sailboat_select_button != null:
		sailboat_select_button.pressed.emit()
	else:
		controller.set_sailing_enabled(true)
	_check(controller.is_sailing_active(), "Vessel picker activates the sailboat")
	var player_forward := -controller.global_transform.basis.z
	var sailboat_forward := -sailboat.global_transform.basis.z
	player_forward.y = 0.0
	sailboat_forward.y = 0.0
	_check(player_forward.normalized().dot(sailboat_forward.normalized()) > 0.99, "Sailboat preserves the current player vessel heading at spawn")
	for _frame in range(30):
		await physics_frame
	_check(controller.is_sailing_active(), "Sailboat becomes the active vessel")
	_check(not sailboat.freeze and sailboat.visible, "Selected sailboat is active and visible")
	_check(sailboat.get_node("CollisionShape3D").disabled == false, "Selected sailboat collision is enabled")
	var follow_camera := main.get_node_or_null("PlayerBoat/FollowCameraRig")
	_check(follow_camera != null and float(follow_camera.call("_get_vessel_follow_distance")) >= 17.5, "Shared third-person camera backs out for the taller Nordic 28 rig")
	if follow_camera != null:
		var zoom_out_event := InputEventMouseButton.new()
		zoom_out_event.button_index = MOUSE_BUTTON_WHEEL_DOWN
		zoom_out_event.pressed = true
		follow_camera.call("_unhandled_input", zoom_out_event)
		_check(float(follow_camera.get("_zoom_offset_m")) > 0.0, "Mouse wheel can pull the third-person camera back to show the full rig")
		var zoom_in_event := InputEventMouseButton.new()
		zoom_in_event.button_index = MOUSE_BUTTON_WHEEL_UP
		zoom_in_event.pressed = true
		follow_camera.call("_unhandled_input", zoom_in_event)
		_check(is_zero_approx(float(follow_camera.get("_zoom_offset_m"))), "Mouse wheel zoom restores its previous camera distance")
	_check(sailboat.scene_file_path == "res://scenes/boats/SailingBoat8m.tscn", "Main instantiates the same reusable SailingBoat8m scene used by SailboatLab")
	var spawn_distance_from_player := Vector2(sailboat.global_position.x - reference_position.x, sailboat.global_position.z - reference_position.z).length()
	_check(spawn_distance_from_player >= 8.0 and spawn_distance_from_player <= 30.0, "Sailboat selects a clear, depth-checked spawn close to the current player vessel")
	if depth_provider != null:
		var selected_spawn_depth := depth_provider.evaluate_world_position(sailboat.global_position, 0.9, 0.5)
		_check(str(selected_spawn_depth.get("status", "")) == NavigationDepthProvider.STATUS_SAFE, "Selected nearby sailboat spawn meets the configured draft and depth margin")
	var wind_path: NodePath = sailboat.get("wind_field_path")
	var wave_path: NodePath = sailboat.get("wave_sampler_path")
	_check(sailboat.get_node_or_null(wind_path) == main.get_node("WindField"), "Sailboat reads Main WindField")
	_check(sailboat.get_node_or_null(wave_path) == main.get_node("WaveSampler"), "Sailboat reads Main WaveSampler")
	_check(str(main.get_node("WindField").call("get_debug_override_state")) == "formal", "Main WindField remains on formal weather with no test override")
	var sailing_panel := vessel_hud.find_child("SailingControlsPanel", true, false) as Control if vessel_hud != null else null
	var compact_navigation_panel := vessel_hud.find_child("NavigationCorePanel", true, false) as Control if vessel_hud != null else null
	var depth_chart_panel := fish_map.find_child("MapPanel", true, false) as Control if fish_map != null else null
	_check(compact_navigation_panel != null and compact_navigation_panel.visible and sailing_panel != null and not sailing_panel.visible, "the sailboat starts with compact navigation information and hides expanded controls")
	var navigation_details_button := vessel_hud.find_child("NavigationInstrumentExpandButton", true, false) as Button if vessel_hud != null else null
	if navigation_details_button != null:
		navigation_details_button.pressed.emit()
		await process_frame
	_check(sailing_panel != null and sailing_panel.visible, "the expanded sailboat instrument and controls open on demand")
	_check(compact_navigation_panel != null and compact_navigation_panel.size.y >= 140.0, "Sailing compact navigation retains enough height for wind, sail and autopilot state")
	var engine_snapshot: Dictionary = sailboat.call("get_auxiliary_engine_snapshot")
	_check(bool(engine_snapshot.get("available", false)), "Nordic 28 exposes its configured auxiliary diesel and fuel tank")
	_check(str(engine_snapshot.get("state_name", "")) == "关闭" and is_equal_approx(float(engine_snapshot.get("tank", {}).get("remaining_l", 0.0)), 40.0), "auxiliary diesel starts off with the vessel's 40 L tank full")
	_check(controller.supports_auxiliary_engine() and controller.supports_fuel_system(), "active sailboat advertises auxiliary engine and fuel capabilities")
	var engine_panel := sailing_panel.find_child("AuxiliaryEnginePanel", true, false) as Control if sailing_panel != null else null
	_check(engine_panel != null and engine_panel.visible, "Main sailing HUD displays engine and fuel controls for Nordic 28")
	var engine_fuel_label := sailing_panel.find_child("AuxiliaryEngineFuel", true, false) as Label if sailing_panel != null else null
	var fuel_tank := sailboat.get_node_or_null("FuelTank") as FuelTankComponent
	_check(engine_fuel_label != null and engine_fuel_label.text.contains("柴油"), "Main HUD displays the current diesel quantity and consumption estimate")
	if fuel_tank != null and vessel_hud != null:
		fuel_tank.set_fuel_remaining_l(7.9)
		vessel_hud.call("_update_sailing_panel")
		_check(engine_fuel_label != null and engine_fuel_label.text.contains("燃油偏低"), "Main HUD shows a steady low-fuel warning below the vessel profile threshold")
		fuel_tank.set_fuel_remaining_l(40.0)
		vessel_hud.call("_update_sailing_panel")
	_check(InputMap.has_action("sailboat_engine_toggle") and InputMap.has_action("sailboat_engine_gear_cycle"), "engine hotkeys are registered without replacing powerboat throttle actions")
	if sailing_panel != null and depth_chart_panel != null:
		_check(not sailing_panel.get_global_rect().intersects(depth_chart_panel.get_global_rect()), "the lower-right sailing panel does not overlap the lower-left chart")
	var speed_label := vessel_hud.find_child("SailingSpeed", true, false) as Label if vessel_hud != null else null
	var heading_label := vessel_hud.find_child("SailingHeading", true, false) as Label if vessel_hud != null else null
	var true_wind_label := vessel_hud.find_child("SailingTrueWindDirection", true, false) as Label if vessel_hud != null else null
	var detail_label := vessel_hud.find_child("SailingDetails", true, false) as Label if vessel_hud != null else null
	var hint_label := vessel_hud.find_child("SailingControlHints", true, false) as Label if vessel_hud != null else null
	_check(speed_label != null and speed_label.text.begins_with("航速 "), "the sailing panel emphasizes speed with a plain-language label")
	_check(heading_label != null and heading_label.text.begins_with("航向 "), "the sailing panel displays heading in Chinese")
	_check(true_wind_label != null and true_wind_label.text.contains("来向"), "true wind direction is explicitly described as wind-from")
	var expected_sail_hints := [
		FORMAT.action_key_hint("boat_turn_left"),
		FORMAT.action_key_hint("boat_turn_right"),
		FORMAT.action_key_hint("sailboat_main_trim_ease"),
		FORMAT.action_key_hint("sailboat_main_trim_out"),
		FORMAT.action_key_hint("sailboat_headsail_trim_ease"),
		FORMAT.action_key_hint("sailboat_headsail_trim_out"),
	]
	var prompts_match_bindings := hint_label != null
	if hint_label != null:
		for expected_hint in expected_sail_hints:
			prompts_match_bindings = prompts_match_bindings and hint_label.text.contains(str(expected_hint))
	_check(prompts_match_bindings, "displayed sail/rudder prompts are read from actual InputMap actions")
	_check(quality_manager != null, "Main has the shared graphics and interface settings manager")
	if quality_manager != null:
		var old_ui_scale := quality_manager.get_ui_scale_index()
		var old_detail := quality_manager.get_navigation_detail_enabled()
		var render_scale_before := get_root().get_viewport().scaling_3d_scale
		quality_manager.set_ui_scale_index(3, false)
		_check(absf(get_root().content_scale_factor - QualityManager.UI_SCALE_FACTORS[3]) < 0.001, "UI Scale updates Window canvas content immediately")
		_check(absf(get_root().get_viewport().scaling_3d_scale - render_scale_before) < 0.001, "changing UI Scale leaves the 3D render scale unchanged")
		quality_manager.set_navigation_detail_enabled(true, false)
		if vessel_hud != null:
			vessel_hud.call("_update_sailing_panel")
		_check(detail_label != null and detail_label.visible and detail_label.text.contains("真风") and detail_label.text.contains("视风"), "detailed navigation mode adds SOG/COG, true/apparent wind, sail and rudder details")
		quality_manager.set_navigation_detail_enabled(false, false)
		if vessel_hud != null:
			vessel_hud.call("_update_sailing_panel")
		_check(detail_label != null and not detail_label.visible, "simple navigation mode hides secondary sailing metrics")
		quality_manager.set_ui_scale_index(old_ui_scale, false)
		quality_manager.set_navigation_detail_enabled(old_detail, false)
		if vessel_hud != null:
			vessel_hud.call("_update_sailing_panel")
	var ui_scale_layout_checks := _test_sailing_layout_sizes()
	_check(ui_scale_layout_checks, "sailing panel layout stays on-screen and clear of the depth chart at target resolutions and every UI scale")
	_check(not controller.supports_autopilot() and not controller.supports_cargo(), "Unsupported autopilot and cargo capabilities are disabled")
	var economy := main.get_node_or_null("CargoEconomyManager") as CargoEconomyManager
	if economy != null:
		var cargo_result := economy.accept_contract("c8_sailboat_disabled_probe")
		_check(not bool(cargo_result.get("accepted", true)) and str(cargo_result.get("code", "")) == "unsupported_vessel", "Cargo API clearly rejects task entry for the sailboat prototype")
	var snapshot: Dictionary = sailboat.call("get_debug_snapshot")
	_check(int(snapshot.get("wind_query_count_per_tick", -1)) == 1, "Sailboat performs one wind query per physics tick")
	_check(int(snapshot.get("wave_query_count_per_tick", -1)) == 4, "Sailboat performs four wave queries per physics tick")
	print("[C8_HEADLESS_PHYSICS] sailboat code avg/P95=%d/%d μs · wave avg/P95=%d/%d μs · wind avg/P95=%d/%d μs · per tick wave/wind queries=%d/%d" % [
		int(snapshot.get("total_physics_calculation_average_usec", 0)),
		int(snapshot.get("total_physics_calculation_p95_usec", 0)),
		int(snapshot.get("wave_sample_average_usec", 0)),
		int(snapshot.get("wave_sample_p95_usec", 0)),
		int(snapshot.get("wind_sample_average_usec", 0)),
		int(snapshot.get("wind_sample_p95_usec", 0)),
		int(snapshot.get("wave_query_count_per_tick", 0)),
		int(snapshot.get("wind_query_count_per_tick", 0)),
	])
	_check(bool(sailboat.call("get_navigation_snapshot").get("headsail_enabled", false)), "Both-sail profile is active")
	sailboat.call("set_auto_sail_trim_enabled", true)
	_check(bool(sailboat.call("get_auto_sail_trim_enabled")), "AUTO can be enabled through the shared sailing entity")
	if fuel_tank != null:
		fuel_tank.set_fuel_remaining_l(17.5)
		sailboat.call("start_auxiliary_engine")
		_check(str(sailboat.call("get_auxiliary_engine_snapshot").get("state_name", "")) == "启动中", "Main start control begins the auxiliary engine start sequence")
		_check(controller.set_sailing_enabled(false), "Main can switch away while the auxiliary diesel is starting")
		await physics_frame
		var switched_engine: Dictionary = sailboat.call("get_auxiliary_engine_snapshot")
		_check(is_equal_approx(fuel_tank.fuel_remaining_l, 17.5), "switching away preserves Nordic 28's tank instead of refilling it")
		_check(str(switched_engine.get("state_name", "")) == "关闭", "switching away stops the diesel without affecting its stored fuel")
		_check(controller.set_sailing_enabled(true), "Nordic 28 can be reselected after checking its engine state")
		await physics_frame
		_check(is_equal_approx(fuel_tank.fuel_remaining_l, 17.5), "reselecting Nordic 28 retains the same fuel quantity")

	if vessel_hud != null:
		vessel_hud.call("_open_vessel_picker")
	var motorboat_select_button := motorboat_card.find_child("SelectButton", true, false) as Button if motorboat_card != null else null
	if motorboat_select_button != null:
		motorboat_select_button.pressed.emit()
	else:
		controller.set_sailing_enabled(false)
	_check(not controller.is_sailing_active(), "Vessel selector switches back to the motorboat")
	await physics_frame
	_check(not controller.is_sailing_active(), "Motorboat is selected again")
	_check(sailboat.freeze and not sailboat.visible, "Deselected sailboat is frozen and hidden")
	if fuel_tank != null:
		var engine_after_switch: Dictionary = sailboat.call("get_auxiliary_engine_snapshot")
		_check(is_equal_approx(fuel_tank.fuel_remaining_l, 17.5), "switching back to the powerboat preserves the last sailboat fuel amount")
		_check(str(engine_after_switch.get("state_name", "")) == "关闭", "the hidden sailboat diesel remains stopped after switching vessels")
	_check(sailing_panel != null and not sailing_panel.visible, "sailing-only navigation controls hide for the powerboat")
	var compass_widget := vessel_hud.find_child("CompassHUD", true, false) as Control if vessel_hud != null else null
	_check(compass_widget != null and compass_widget.visible, "the shared heading ribbon returns when the powerboat is active")
	_check(controller.has_engine(), "Powerboat engine capability is restored")
	_check(follow_camera != null and is_equal_approx(float(follow_camera.call("_get_vessel_follow_distance")), float(follow_camera.get("follow_distance"))), "Camera returns to the original powerboat distance after switching back")
	if economy != null:
		var motorboat_result := economy.accept_contract("c8_motorboat_unknown_probe")
		_check(str(motorboat_result.get("code", "")) == "unknown_contract", "Powerboat cargo API retains its previous contract lookup path")
	_check(get_nodes_in_group("wave_sampler").size() == 1, "Vessel switching does not duplicate WaveSampler")
	for switch_index in range(5):
		_check(controller.set_sailing_enabled(true), "Repeated switch %d activates Nordic 28" % (switch_index + 1))
		await physics_frame
		_check(controller.is_sailing_active() and not sailboat.freeze, "Nordic 28 remains the active physics vessel after repeated switch")
		_check(controller.set_sailing_enabled(false), "Repeated switch %d returns to the powerboat" % (switch_index + 1))
		await physics_frame
		_check(not controller.is_sailing_active() and sailboat.freeze and not sailboat.visible, "Powerboat switch freezes and hides Nordic 28")
		_check(get_nodes_in_group("wave_sampler").size() == 1, "Repeated switching keeps one shared WaveSampler")
	_check(main.find_children("SailingBoat8m", "RigidBody3D", true, false).size() == 1, "Repeated switching does not instantiate duplicate sailboat bodies")
	_check(main.find_children("WindField", "Node", true, false).size() == 1, "Repeated switching keeps one shared WindField")
	_check(main.find_children("WaveSampler", "Node", true, false).size() == 1, "Repeated switching keeps one shared WaveSampler scene node")
	if localization_manager != null and localization_manager.has_method("set_locale_id"):
		localization_manager.call("set_locale_id", previous_locale)
	else:
		TranslationServer.set_locale(previous_locale)
	print("S1-C8 integration checks: %d failed" % _failures.size())
	for failure in _failures:
		push_error(failure)
	quit(1 if not _failures.is_empty() else 0)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("PASS: %s" % label)
	else:
		_failures.append(label)


func _test_sailing_layout_sizes() -> bool:
	for resolution in [Vector2(1280.0, 720.0), Vector2(1600.0, 900.0), Vector2(1920.0, 1080.0), Vector2(2560.0, 1440.0)]:
		for scale_value in QualityManager.UI_SCALE_FACTORS:
			var layout: Dictionary = HUD_LAYOUT.sailing_panel_layout_metrics(resolution, float(scale_value), true)
			var left := float(layout["screen_left"])
			var top := float(layout["screen_top"])
			var right := left + float(layout["screen_width"])
			var bottom := top + float(layout["screen_height"])
			if left < float(380.0 * scale_value) or top < 0.0 or right > resolution.x or bottom > resolution.y:
				return false
	return true
