extends SceneTree

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	_check(main_scene != null, "Main scene loads for onboard activity integration")
	if main_scene == null:
		quit(1)
		return
	var main := main_scene.instantiate()
	root.add_child(main)
	for _frame in range(18):
		await physics_frame
	var boat_controller := main.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	var onboard := main.get_node_or_null("PlayerBoat/MotionRoot/VisualRoot/OnboardActivityController") as OnboardActivityController
	var camera := main.get_node_or_null("PlayerBoat/FollowCameraRig") as BoatFollowCamera
	var hud := main.find_child("BoatHUD", true, false) as CanvasLayer
	var rod_system := main.get_node_or_null("PlayerBoat/FishingRodSystem") as FishingRodSystem
	var fishing_panel := main.find_child("FishingPlayerPanel", true, false) as FishingPlayerPanel
	var activities_button := main.find_child("ActivitiesButton", true, false) as Button
	var activity_menu := main.find_child("ActivitiesMenu", true, false) as Control
	var boat_fishing_button := main.find_child("OpenBoatFishingActivity", true, false) as Button
	var boat_fishing_panel := main.find_child("BoatFishingActivityPanel", true, false) as Control
	_check(boat_controller != null and onboard != null and camera != null and hud != null, "Starter cargo boat exposes its activity controller and shared camera rig")
	_check(onboard != null and onboard.is_supported(), "Starter cargo boat profile supports deck activity")
	_check(onboard != null and onboard.profile.walkable_polygon_xz.size() == 8, "Walkable footprint follows the shaped aft deck instead of the hull bounding rectangle")
	_check(onboard != null and onboard.profile.walkable_polygon_xz[0].y > 0.0 and onboard.profile.walkable_polygon_xz[4].y < 3.6, "Walkable footprint excludes the cabin interior and remains inside the measured hull ends")
	_check(camera != null and camera.get_available_camera_modes().size() == 2, "O camera cycle is unchanged before an activity starts")
	_check(InputMap.has_action("god_view_toggle") and InputMap.action_get_events("god_view_toggle").size() == 1, "Existing O key remains the only camera-cycle input")
	_check(boat_fishing_button != null and not boat_fishing_button.text.is_empty(), "Activities menu includes the localized Boat Fishing entry")
	_check(boat_fishing_panel != null and not boat_fishing_panel.visible, "Boat Fishing preparation panel is hidden while inactive")
	if boat_controller == null or onboard == null or camera == null or activities_button == null or boat_fishing_button == null:
		quit(1)
		return

	_press_o(camera)
	_check(camera.get_camera_mode_name() == "god", "The original O input still switches to God view")
	_press_o(camera)
	_check(camera.get_camera_mode_name() == "follow", "The original O input returns to Follow before any activity")
	var starting_mode := camera.get_camera_mode_name()
	activities_button.pressed.emit()
	boat_fishing_button.pressed.emit()
	await process_frame
	var encounter := rod_system.get_encounter_system() if rod_system != null else null
	_check(hud.call("is_boat_fishing_active") and boat_fishing_panel.visible, "Boat Fishing starts a preparation state without casting")
	_check(encounter == null or encounter.state == FishingEncounterSystem.State.IDLE, "Starting Boat Fishing does not start trolling or hook checks")
	_check(camera.get_available_camera_modes().has("onboard_activity"), "Onboard first-person joins the existing O cycle only while Boat Fishing is active")
	_check(bool(boat_controller.get("_onboard_activity_input_suppressed")), "Starting Boat Fishing automatically enters first-person and suppresses vessel input there")

	boat_controller.speed_mps = 0.0
	boat_controller.is_autopilot = true
	boat_controller.set("_autopilot_target_speed_mps", 0.0)
	_check(camera.get_camera_mode_name() == "onboard_activity" and onboard.is_first_person_active(), "Boat Fishing opens directly in the onboard view")
	camera.cycle_camera_view()
	_check(camera.get_camera_mode_name() == "follow" and not onboard.is_first_person_active(), "O returns to the prior driving view without ending Boat Fishing")
	camera.cycle_camera_view()
	camera.cycle_camera_view()
	_check(camera.get_camera_mode_name() == "onboard_activity" and onboard.is_first_person_active(), "O cycle re-enters first-person after the existing Follow and God views")
	_check(root.get_camera_3d() == onboard.find_child("OnboardActivityCamera", true, false), "The onboard camera becomes the active viewport camera")
	_check(bool(boat_controller.get("_onboard_activity_input_suppressed")), "First-person activates vessel-input suppression")

	var activity_player := onboard.find_child("OnboardActivityPlayer", true, false) as CharacterBody3D
	_check(activity_player != null, "Activity controller owns a collision-backed CharacterBody3D")
	if activity_player != null:
		for _frame in range(3):
			await physics_frame
		var original_local_position := onboard.get_player_local_position()
		Input.action_press("boat_accelerate")
		for _frame in range(12):
			await physics_frame
		Input.action_release("boat_accelerate")
		_check(onboard.get_player_local_position().z < original_local_position.z - 0.15, "WASD movement advances relative to the hull")
		_check(is_equal_approx(boat_controller.speed_mps, 0.0) and boat_controller.is_autopilot, "Movement input does not change boat speed or disengage autopilot")

		var lock_position := onboard.get_player_local_position()
		onboard.set_movement_locked(true)
		Input.action_press("boat_accelerate")
		Input.action_press("boat_turn_right")
		for _frame in range(8):
			await physics_frame
		Input.action_release("boat_accelerate")
		Input.action_release("boat_turn_right")
		var locked_local_position := onboard.get_player_local_position()
		var locked_horizontal_delta := Vector2(locked_local_position.x - lock_position.x, locked_local_position.z - lock_position.z).length()
		_check(locked_horizontal_delta <= 0.08, "Movement lock prevents horizontal movement")
		_check(onboard.is_movement_locked(), "Movement lock state is exposed for P6.2 callers")
		onboard.set_movement_locked(false)

		var grounded := false
		for _frame in range(8):
			await physics_frame
			grounded = onboard.is_player_grounded()
			if grounded:
				break
		_check(grounded, "Player is grounded on the deck before jumping")
		Input.action_press("boat_pause")
		await physics_frame
		Input.action_release("boat_pause")
		await physics_frame
		_check(onboard.get_player_local_position().y > onboard.profile.deck_height_m + 0.05, "Space jumps while first-person movement is unlocked")
		_check(not boat_controller.is_motion_paused, "Space does not pause the vessel while in first-person")
		for _frame in range(45):
			await physics_frame
		_check(onboard.is_player_grounded(), "Jump returns to the hull-local deck floor")

		var proxy := onboard.get_node("OnboardActivityCollisionProxy") as AnimatableBody3D
		_check(proxy.collision_layer == (1 << 5) and activity_player.collision_mask == (1 << 5), "Deck boundaries use their dedicated physics layer and player-only mask")
		_check(proxy.get_node_or_null("WalkableDeckFloor") is CollisionShape3D, "Walkable floor follows a convex deck footprint instead of the full boat bounds")
		onboard.set_debug_bounds_visible(true)
		await process_frame
		_check(onboard.find_child("OnboardActivityDebugWalkableArea", true, false) is MeshInstance3D, "F3 visualization includes the allowed deck footprint")
		_check(onboard.find_child("OnboardActivityDebugPlayerCapsule", true, false) is MeshInstance3D, "F3 visualization includes the player collision capsule")
		onboard.set_debug_bounds_visible(false)
		_check(not onboard.find_child("OnboardActivityDebugWalkableArea", true, false).visible, "Activity boundary visualization can be hidden again")
		var safe_before_projection := onboard.get_player_local_position()
		var outside_candidate := safe_before_projection + Vector3(4.0, 0.0, 0.0)
		var projected_candidate: Vector3 = onboard.call("_constrain_player_local_position", outside_candidate, safe_before_projection)
		_check(onboard.call("_is_position_inside_walkable_area", projected_candidate), "Hull-local post-move projection keeps a fast step inside the capsule-clearance footprint")
		_check(projected_candidate.x > safe_before_projection.x + 0.2, "Boundary projection stops at the nearest deck edge rather than teleporting to the spawn point")

		var pre_boundary_position := onboard.get_player_local_position()
		Input.action_press("boat_accelerate")
		for _frame in range(150):
			await physics_frame
		Input.action_release("boat_accelerate")
		var boundary_local_position := onboard.get_player_local_position()
		var cabin_edge := onboard.profile.walkable_polygon_xz[0].y
		var expected_front_clearance := cabin_edge + onboard.profile.capsule_radius_m + onboard.profile.boundary_thickness_m * 0.5 - 0.05
		_check(boundary_local_position.z >= expected_front_clearance, "Continuous bow-side boundary prevents entry through the cabin opening")
		_check(boundary_local_position.z < pre_boundary_position.z, "Boundary collision stops at the edge rather than teleporting to the spawn point")
		_check(onboard.is_player_inside_walkable_area(), "Player remains within the capsule-clearance inset of the walkable polygon")

		Input.action_press("boat_pause")
		Input.action_press("boat_accelerate")
		await physics_frame
		Input.action_release("boat_pause")
		for _frame in range(44):
			await physics_frame
		Input.action_release("boat_accelerate")
		_check(onboard.is_player_inside_walkable_area() and onboard.get_player_local_position().z >= expected_front_clearance - 0.03, "Jumping and pushing against the cabin boundary cannot vault through it")
		for _frame in range(45):
			await physics_frame

		Input.action_press("boat_brake")
		for _frame in range(30):
			await physics_frame
		Input.action_release("boat_brake")
		onboard.profile.move_speed_mps = 4.0
		Input.action_press("boat_turn_right")
		for _frame in range(150):
			await physics_frame
		Input.action_release("boat_turn_right")
		var starboard_position := onboard.get_player_local_position()
		_check(starboard_position.x > 0.30 and starboard_position.x < 0.90, "Player can reach the configured starboard fishing-side area but not cross the rail")
		_check(onboard.is_player_inside_walkable_area(), "High-end walk speed remains constrained by the side boundary")
		Input.action_press("boat_pause")
		Input.action_press("boat_turn_right")
		await physics_frame
		Input.action_release("boat_pause")
		for _frame in range(44):
			await physics_frame
		Input.action_release("boat_turn_right")
		_check(onboard.is_player_inside_walkable_area(), "Jumping against the side boundary cannot cross the gunwale")
		for _frame in range(45):
			await physics_frame
		Input.action_press("boat_turn_left")
		for _frame in range(150):
			await physics_frame
		Input.action_release("boat_turn_left")
		var port_side_position := onboard.get_player_local_position()
		_check(port_side_position.x < -0.30 and port_side_position.x > -0.90, "Player can reach the configured port fishing-side area but not cross the rail")
		_check(onboard.is_player_inside_walkable_area(), "Port-side boundary also retains capsule clearance")
		onboard.profile.move_speed_mps = 2.4
		Input.action_press("boat_brake")
		for _frame in range(180):
			await physics_frame
		Input.action_release("boat_brake")
		var stern_position := onboard.get_player_local_position()
		_check(stern_position.z < 3.36 and onboard.is_player_inside_walkable_area(), "Stern edge confines the player to the designed aft deck fishing zone")
		var visual_root := boat_controller.get_node("VisualRoot") as Node3D
		var original_visual_rotation := visual_root.rotation
		var player_local_before_wave_tilt := onboard.get_player_local_position()
		var player_global_before_wave_tilt := activity_player.global_position
		var visual_root_was_processing := visual_root.is_processing()
		visual_root.set_process(false)
		visual_root.rotation = original_visual_rotation + Vector3(deg_to_rad(5.0), 0.0, deg_to_rad(-4.0))
		await physics_frame
		var local_after_wave_tilt := onboard.get_player_local_position()
		_check(onboard.is_player_inside_walkable_area() and Vector2(local_after_wave_tilt.x - player_local_before_wave_tilt.x, local_after_wave_tilt.z - player_local_before_wave_tilt.z).length() <= 0.08, "Hull roll and pitch keep the player inside the same hull-local deck footprint")
		_check(activity_player.global_position.distance_to(player_global_before_wave_tilt) > 0.05, "Player world transform follows hull roll and pitch")
		visual_root.rotation = original_visual_rotation
		visual_root.set_process(visual_root_was_processing)
		var original_heading := boat_controller.rotation.y
		boat_controller.rotation.y += deg_to_rad(18.0)
		await physics_frame
		_check(onboard.is_player_inside_walkable_area() and Vector2(onboard.get_player_local_position().x - local_after_wave_tilt.x, onboard.get_player_local_position().z - local_after_wave_tilt.z).length() <= 0.08, "Vessel heading change preserves the player's hull-local position")
		boat_controller.rotation.y = original_heading

		var hull_position_before_cruise := boat_controller.global_position
		var player_position_before_cruise := activity_player.global_position
		var local_position_before_cruise := onboard.get_player_local_position()
		boat_controller.speed_mps = 3.0
		boat_controller.is_autopilot = true
		boat_controller.set("_autopilot_target_speed_mps", 3.0)
		for _frame in range(30):
			await physics_frame
		var local_horizontal_delta := Vector2(
			onboard.get_player_local_position().x - local_position_before_cruise.x,
			onboard.get_player_local_position().z - local_position_before_cruise.z
		).length()
		_check(boat_controller.global_position.distance_to(hull_position_before_cruise) > 0.4, "Autopilot continues moving the vessel during first-person activity")
		_check(activity_player.global_position.distance_to(player_position_before_cruise) > 0.4, "First-person player follows vessel translation and wave motion")
		_check(local_horizontal_delta <= 0.08, "Hull motion does not drift the player in deck-local coordinates")
		_check(boat_controller.is_autopilot, "First-person activity preserves active autopilot")
		boat_controller.speed_mps = 0.0
		boat_controller.set("_autopilot_target_speed_mps", 0.0)

	var player_local_position := onboard.get_player_local_position() if onboard != null else Vector3.ZERO
	camera.cycle_camera_view()
	_check(camera.get_camera_mode_name() == "follow" and hud.call("is_boat_fishing_active"), "O leaves first-person without ending Boat Fishing")
	_check(not bool(boat_controller.get("_onboard_activity_input_suppressed")), "Leaving first-person restores vessel input")
	_check(activity_player == null or onboard.get_player_local_position().is_equal_approx(player_local_position), "Camera switching preserves the last hull-local player position")
	camera.cycle_camera_view()
	camera.cycle_camera_view()
	_check(camera.get_camera_mode_name() == "onboard_activity", "The active first-person view can be selected again")
	var end_button := main.find_child("EndBoatFishingActivity", true, false) as Button
	if end_button != null:
		end_button.pressed.emit()
	await process_frame
	_check(not hud.call("is_boat_fishing_active") and not boat_fishing_panel.visible, "Ending Boat Fishing clears its preparation panel")
	_check(camera.get_camera_mode_name() == "god" and starting_mode == "follow", "Ending from first-person restores the ordinary view active immediately before re-entry")
	_check(not camera.get_available_camera_modes().has("onboard_activity"), "Onboard view is removed from O cycle after activity ends")

	activities_button.pressed.emit()
	boat_fishing_button.pressed.emit()
	await process_frame
	if fishing_panel != null:
		var trolling_action := fishing_panel.find_child("TrollingActionButton", true, false) as Button
		if trolling_action != null:
			trolling_action.pressed.emit()
		await process_frame
		_check(encounter == null or encounter.state == FishingEncounterSystem.State.IDLE, "Player trolling start is blocked during Boat Fishing")
	var fishing_debug_panel := main.find_child("FishingDebugTab", true, false) as Control
	if fishing_debug_panel != null and fishing_debug_panel.has_method("_on_start_pressed"):
		fishing_debug_panel.call("_on_start_pressed")
		_check(encounter == null or encounter.state == FishingEncounterSystem.State.IDLE, "F3 trolling start is also blocked during Boat Fishing")
	hud.call("end_boat_fishing_activity")
	await process_frame

	if rod_system != null:
		var trolling_started := rod_system.start_trolling()
		_check(trolling_started, "Trolling remains startable when Boat Fishing is inactive")
	activities_button.pressed.emit()
	boat_fishing_button.pressed.emit()
	await process_frame
	_check(not hud.call("is_boat_fishing_active") and encounter != null and encounter.state == FishingEncounterSystem.State.TROLLING, "Boat Fishing is rejected without cancelling active trolling")
	if rod_system != null:
		rod_system.stop_trolling()

	activities_button.pressed.emit()
	boat_fishing_button.pressed.emit()
	await process_frame
	_check(hud.call("is_boat_fishing_active"), "Boat Fishing can be restarted after trolling is stopped")
	_check(camera.get_camera_mode_name() == "onboard_activity" and onboard.is_first_person_active(), "Starting Boat Fishing from the existing God view enters onboard first-person directly")
	if activity_player != null:
		for _frame in range(3):
			await physics_frame
		for _frame in range(10):
			if onboard.is_player_grounded():
				break
			await physics_frame
		_check(onboard.is_player_grounded(), "Re-entering Boat Fishing restores a grounded deck player")
		Input.action_press("boat_pause")
		await physics_frame
		Input.action_release("boat_pause")
		_check(onboard.get_player_local_position().y > onboard.profile.deck_height_m + 0.02, "Player can be airborne when Boat Fishing ends")
	hud.call("end_boat_fishing_activity")
	for _frame in range(60):
		await physics_frame
	if activity_player != null:
		_check(onboard.is_player_grounded(), "Ending during a jump safely settles the inactive player on deck")
		_check(not activity_player.is_physics_processing(), "Ending during a jump stops inactive player physics after safe deck placement")
		_check(onboard.get_node("OnboardActivityCollisionProxy").collision_layer == 0, "Inactive activity releases its deck collision proxy")

	var controller_switch_result := boat_controller.set_sailing_enabled(true)
	await process_frame
	_check(controller_switch_result and not onboard.is_supported(), "Nordic 28 mode is unsupported by the starter-boat deck profile")
	activities_button.pressed.emit()
	boat_fishing_button.pressed.emit()
	await process_frame
	_check(not hud.call("is_boat_fishing_active") and not camera.get_available_camera_modes().has("onboard_activity"), "Unsupported sailboat cannot start Boat Fishing or add first-person to O")
	boat_controller.set_sailing_enabled(false)
	await process_frame

	var locale_controller := root.get_node_or_null("LocalizationManager")
	if locale_controller != null and locale_controller.has_method("set_locale_id"):
		locale_controller.call("set_locale_id", "en")
		await process_frame
		_check(boat_fishing_button.text == "Boat Fishing" and TranslationServer.translate("camera.mode.onboard_activity") != "camera.mode.onboard_activity", "Boat Fishing and camera labels resolve in English")
		locale_controller.call("set_locale_id", "zh_CN")
		await process_frame
		_check(boat_fishing_button.text == "船钓", "Boat Fishing menu label refreshes in Simplified Chinese")

	Input.action_release("boat_accelerate")
	Input.action_release("boat_brake")
	Input.action_release("boat_turn_left")
	Input.action_release("boat_turn_right")
	Input.action_release("boat_pause")
	main.queue_free()
	await process_frame
	if _failures == 0:
		print("P6.1 onboard activity tests passed")
		quit(0)
	else:
		printerr("P6.1 onboard activity tests failed: %d" % _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		_failures += 1
		printerr("FAIL: %s" % message)


func _press_o(camera: BoatFollowCamera) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_O
	event.pressed = true
	camera._unhandled_input(event)
