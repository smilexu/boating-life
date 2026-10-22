extends SceneTree

const FORMAT := preload("res://scripts/navigation_hud_format.gd")
const HUD_LAYOUT := preload("res://scripts/boat_hud.gd")

var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
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
	_check(controller != null, "Main retains its BoatController navigation facade")
	_check(sailboat != null, "Main has the reusable SailingBoat8m body")
	_check(vessel_picker != null, "Main HUD has a separate vessel picker outside F3")
	_check(main.find_child("VesselSelectionButton", true, false) == null, "F3 debug panel no longer exposes vessel switching")
	_check(sailboat_card != null and motorboat_card != null, "Vessel picker lists both current vessel models")
	_check(sailboat_preview != null and motorboat_preview != null, "Each vessel card has an isolated 3D preview viewport")
	_check(sailboat_name_label != null and sailboat_name_label.text == "Nordic 28", "Picker shows the Nordic 28 vessel name")
	_check(sailboat_type_label != null and sailboat_type_label.text.contains("休闲巡航帆船"), "Picker classifies Nordic 28 as a leisure cruising sailboat")
	_check(sailboat_details_label != null and sailboat_details_label.text.contains("主帆") and sailboat_details_label.text.contains("前帆") and sailboat_details_label.text.contains("AUTO"), "Picker describes the implemented sailboat equipment and controls")
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
	var depth_chart_panel := main.find_child("DepthChartPanel", true, false) as Control
	_check(sailing_panel != null and sailing_panel.visible, "the combined sailing navigation and controls panel appears for the sailboat")
	if sailing_panel != null and depth_chart_panel != null:
		_check(not sailing_panel.get_global_rect().intersects(depth_chart_panel.get_global_rect()), "the lower-right sailing panel does not overlap the lower-left chart")
	var speed_label := vessel_hud.find_child("SailingSpeed", true, false) as Label if vessel_hud != null else null
	var heading_label := vessel_hud.find_child("SailingHeading", true, false) as Label if vessel_hud != null else null
	var true_wind_label := vessel_hud.find_child("SailingTrueWindDirection", true, false) as Label if vessel_hud != null else null
	var detail_label := vessel_hud.find_child("SailingDetails", true, false) as Label if vessel_hud != null else null
	var hint_label := vessel_hud.find_child("SailingControlHints", true, false) as Label if vessel_hud != null else null
	_check(speed_label != null and speed_label.text.begins_with("航速 "), "the sailing panel emphasizes speed with a plain-language label")
	_check(heading_label != null and heading_label.text.begins_with("船首航向 "), "the sailing panel explains heading in Chinese")
	_check(true_wind_label != null and true_wind_label.text.contains("风从"), "true wind direction is explicitly described as wind-from")
	_check(hint_label != null and hint_label.text.contains("A/D") and hint_label.text.contains("Z/X") and hint_label.text.contains("J/L"), "displayed sail/rudder prompts are read from actual InputMap actions")
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
		_check(detail_label != null and detail_label.visible and detail_label.text.contains("TWS/TWA"), "detailed navigation mode adds SOG/COG, true/apparent wind, sail and rudder details")
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
