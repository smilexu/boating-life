extends SceneTree

const STARTER_BOAT_DECK_PROFILE := preload("res://resources/onboard_activity/starter_cargo_boat.tres")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	_check(main_scene != null, "Main scene loads for P6.2 casting integration")
	if main_scene == null:
		quit(1)
		return
	var previous_locale := TranslationServer.get_locale()
	TranslationServer.set_locale("en")
	var english_gunwale_hint := TranslationServer.translate("hud.boat_fishing.cast_near_gunwale")
	TranslationServer.set_locale("zh_CN")
	var chinese_gunwale_hint := TranslationServer.translate("hud.boat_fishing.cast_near_gunwale")
	TranslationServer.set_locale(previous_locale)
	_check(english_gunwale_hint == "Move close to a gunwale before casting." and chinese_gunwale_hint == "请靠近船舷后再抛竿。", "Gunwale casting feedback is localized in English and Chinese")
	var deck_polygon: PackedVector2Array = STARTER_BOAT_DECK_PROFILE.walkable_polygon_xz
	var deck_height := float(STARTER_BOAT_DECK_PROFILE.deck_height_m)
	var inside_to_water := BoatFishingCastingSystem.get_hull_clearance_line_route(
		Vector3(0.0, deck_height + 1.5, 1.2), Vector3(0.0, 0.0, -4.0), deck_polygon, deck_height
	)
	_check(inside_to_water.size() == 4, "Line leaving the deck receives a boundary guide and an outboard fairlead")
	if inside_to_water.size() == 4:
		var fairlead := inside_to_water[2]
		_check(fairlead.y >= deck_height + 1.34, "Fairlead clears the deck and guard rail height")
		_check(not Geometry2D.is_point_in_polygon(Vector2(fairlead.x, fairlead.z), deck_polygon), "Fairlead is routed just outside the boat deck footprint")
	var across_deck := BoatFishingCastingSystem.get_hull_clearance_line_route(
		Vector3(-2.0, deck_height + 1.6, 1.2), Vector3(2.0, 0.0, 1.2), deck_polygon, deck_height
	)
	_check(across_deck.size() == 6, "A line crossing the deck gets guides at both hull edges")
	if across_deck.size() == 6:
		var all_crossing_points_clear := true
		for point_index in range(1, 5):
			all_crossing_points_clear = all_crossing_points_clear and across_deck[point_index].y >= deck_height + 1.34
		_check(all_crossing_points_clear, "A line crossing the deck stays raised from the first boundary to the last outboard guide")
		_check(across_deck[1].x < across_deck[2].x and across_deck[3].x < across_deck[4].x, "Boundary and outboard guide order follows the line on both sides")
	var same_side := BoatFishingCastingSystem.get_hull_clearance_line_route(
		Vector3(2.0, deck_height + 1.6, 1.2), Vector3(3.0, 0.0, -4.0), deck_polygon, deck_height
	)
	_check(same_side.size() == 2, "A clear line on one side of the boat remains unchanged")
	var center_launch := BoatFishingCastingSystem.validate_cast_launch_position(
		Vector3(0.0, deck_height, 1.2), Vector3(0.0, 1.5, -0.6), Vector3(0.0, 0.0, -4.0), deck_polygon
	)
	_check(not bool(center_launch.get("valid", true)) and center_launch.get("reason_key") == "hud.boat_fishing.cast_near_gunwale", "Casting from the middle of the deck is rejected")
	var outward_launch := BoatFishingCastingSystem.validate_cast_launch_position(
		Vector3(0.53, deck_height, 1.2), Vector3(2.3, 1.5, 1.2), Vector3(5.5, 0.0, 1.2), deck_polygon
	)
	_check(bool(outward_launch.get("valid", false)), "Casting outward from close to the gunwale is accepted")
	var charged_rod_launch := BoatFishingCastingSystem.validate_cast_launch_position(
		Vector3(0.53, deck_height, 1.2), Vector3(0.78, 2.5, 1.2), Vector3(5.5, 0.0, 1.2), deck_polygon
	)
	_check(bool(charged_rod_launch.get("valid", false)), "A charged rod can finish its forward swing after an outward cast is validated")
	var inward_launch := BoatFishingCastingSystem.validate_cast_launch_position(
		Vector3(0.53, deck_height, 1.2), Vector3(-1.3, 1.5, 1.2), Vector3(-4.5, 0.0, 1.2), deck_polygon
	)
	_check(not bool(inward_launch.get("valid", true)) and inward_launch.get("reason_key") == "hud.boat_fishing.cast_aim_outside", "Casting back through the hull from a gunwale is rejected")
	var parallel_launch := BoatFishingCastingSystem.validate_cast_launch_position(
		Vector3(0.53, deck_height, 1.2), Vector3(2.3, 1.5, 1.2), Vector3(2.3, 0.0, 4.5), deck_polygon
	)
	_check(not bool(parallel_launch.get("valid", true)), "A cast parallel to the rail is rejected")
	var main := main_scene.instantiate()
	root.add_child(main)
	for _frame in range(20):
		await physics_frame
	var boat := main.get_node_or_null("PlayerBoat") as Node3D
	var boat_controller := main.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	var onboard := main.get_node_or_null("PlayerBoat/MotionRoot/VisualRoot/OnboardActivityController") as OnboardActivityController
	var camera := main.get_node_or_null("PlayerBoat/FollowCameraRig") as BoatFollowCamera
	var casting := main.get_node_or_null("PlayerBoat/BoatFishingCastingSystem") as BoatFishingCastingSystem
	var hud := main.find_child("BoatHUD", true, false) as CanvasLayer
	var activities_button := main.find_child("ActivitiesButton", true, false) as Button
	var boat_fishing_button := main.find_child("OpenBoatFishingActivity", true, false) as Button
	var retrieve_button := main.find_child("RetrieveBoatFishingCast", true, false) as Button
	var rig_selector := main.find_child("BoatFishingRigSelector", true, false) as OptionButton
	var rod_system := main.get_node_or_null("PlayerBoat/FishingRodSystem") as FishingRodSystem
	_check(boat != null and boat_controller != null and onboard != null and camera != null and casting != null and hud != null, "Boat exposes the P6.1 activity controller and P6.2 casting component")
	_check(casting != null and casting.minimum_cast_distance_m >= 3.0 and casting.maximum_cast_distance_m <= 25.0, "Cast range stays inside the configured 3–25 m test range")
	_check(casting != null and casting.maximum_line_length_m >= 100.0 and is_equal_approx(casting.manual_line_release_speed_mps, 2.0), "Manual line release uses the configured 100 m cap and 2 m/s speed")
	if boat_controller == null or onboard == null or camera == null or casting == null or activities_button == null or boat_fishing_button == null:
		quit(1)
		return
	_check(retrieve_button != null, "Boat Fishing panel exposes the shared retrieve action")
	_check(rig_selector != null and rig_selector.item_count == 2, "Boat Fishing exposes the two data-driven rig choices")
	var payout_key_check := InputEventKey.new()
	payout_key_check.physical_keycode = KEY_F
	_check(InputMap.has_action("boat_fishing_pay_out") and InputMap.event_is_action(payout_key_check, "boat_fishing_pay_out"), "F is mapped to active Boat Fishing line payout")
	var old_release_key_check := InputEventKey.new()
	old_release_key_check.physical_keycode = KEY_R
	_check(not InputMap.event_is_action(old_release_key_check, "boat_fishing_pay_out"), "R is not reused for the new line payout control")
	activities_button.pressed.emit()
	boat_fishing_button.pressed.emit()
	await process_frame
	_check(bool(hud.call("is_boat_fishing_active")) and casting.is_activity_active(), "Boat Fishing activates the casting presentation without starting a cast")
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY, "New activity starts in READY")
	_check(camera.get_camera_mode_name() == "onboard_activity" and onboard.is_first_person_active(), "Opening Boat Fishing directly enters first person")
	var handheld_reel := onboard.find_child("HandheldFishingReel", true, false) as Node3D
	var handheld_reel_spool := handheld_reel.find_child("ReelSpool", true, false) as MeshInstance3D if handheld_reel != null else null
	var handheld_reel_rotor := handheld_reel.find_child("ReelSpinningAssembly", true, false) as Node3D if handheld_reel != null else null
	var handheld_reel_mount := handheld_reel.get_parent() as Node3D if handheld_reel != null else null
	_check(handheld_reel != null and handheld_reel_mount != null and handheld_reel_mount.name == "ReelMount" and handheld_reel_spool != null and handheld_reel_rotor != null, "Handheld rod uses a dedicated local mount with the shared trolling reel assembly")
	_check(handheld_reel_spool != null and handheld_reel_spool.get_parent() == handheld_reel_rotor, "Drum spool is part of the rotating assembly shared with trolling")
	var handheld_winding := handheld_reel.find_child("ReelWoundLine", true, false) as MultiMeshInstance3D if handheld_reel != null else null
	_check(handheld_winding != null and handheld_winding.multimesh != null and handheld_winding.multimesh.instance_count == FishingRodRig.REEL_WINDING_RING_COUNT and handheld_winding.visible, "Shared drum reel keeps a fixed, visible multi-ring winding layer")
	var handheld_reel_axis := handheld_reel_mount.basis.z.normalized() if handheld_reel_mount != null else Vector3.ZERO
	var handheld_rod_mesh := onboard.find_child("FirstPersonFishingRod", true, false) as MeshInstance3D
	var handheld_rod_axis := handheld_rod_mesh.transform.basis.y.normalized() if handheld_rod_mesh != null else Vector3.ZERO
	var reel_mount_distance := handheld_reel_mount.position.dot(handheld_rod_axis) if handheld_reel_mount != null else -1.0
	_check(handheld_reel_mount != null and handheld_reel_axis.dot(handheld_rod_axis) > 0.99 and reel_mount_distance >= 0.05 and reel_mount_distance <= 0.07, "Handheld reel moves 0.20 m toward the grip along the rod shaft")
	var first_person_camera := onboard.get_activity_camera()
	if handheld_reel_spool != null and first_person_camera != null and handheld_rod_mesh != null and handheld_reel_mount != null:
		var reel_screen_position: Vector2 = first_person_camera.unproject_position(handheld_reel_spool.global_position)
		var reel_axial_distance: float = (handheld_reel_spool.global_position - handheld_reel_mount.get_parent().global_position).dot(handheld_rod_mesh.global_basis.y)
		var rod_reference: Vector3 = handheld_reel_mount.get_parent().global_position + handheld_rod_mesh.global_basis.y * reel_axial_distance
		var rod_screen_position: Vector2 = first_person_camera.unproject_position(rod_reference)
		var reel_viewport_rect: Rect2 = first_person_camera.get_viewport().get_visible_rect()
		_check(not first_person_camera.is_position_behind(handheld_reel_spool.global_position) and reel_viewport_rect.grow(-24.0).has_point(reel_screen_position), "Handheld drum spool projects inside the active first-person viewport")
		_check(reel_screen_position.x < rod_screen_position.x, "Handheld drum sits on the player's screen-left side of the rod")
	var guide_nodes := onboard.find_children("FirstPersonRodGuide_*", "MeshInstance3D", true, false)
	_check(guide_nodes.size() == 6, "Handheld rod includes six guide rings for a continuous reel-to-tip path")
	var boat_fishing_line := casting.find_child("BoatFishingLine", true, false) as MeshInstance3D
	var boat_fishing_line_material: StandardMaterial3D = casting.get("_line_material")
	_check(boat_fishing_line != null and boat_fishing_line_material != null and not boat_fishing_line_material.no_depth_test and boat_fishing_line_material.depth_draw_mode == BaseMaterial3D.DEPTH_DRAW_DISABLED and boat_fishing_line_material.render_priority > 0, "Casting line respects hull depth while remaining late-rendered without writing depth")
	_check(is_equal_approx(BoatFishingCastingSystem.LINE_RADIUS_M, FishingRodRig.LINE_RADIUS_M), "Handheld reel-to-tip line uses the same fine visual radius as the trolling rig")
	_check(StringName(casting.get_rig_snapshot()["rig_id"]) == &"single_jig", "Single Jig is the default boat-fishing rig")
	_check(rod_system == null or rod_system.get_encounter_system() == null or rod_system.get_encounter_system().state == FishingEncounterSystem.State.IDLE, "P6.2 does not start P2 trolling or hook logic")
	_check(casting.select_rig(&"sabiki_rig"), "Sabiki can be selected before the line is deployed")
	var sabiki_profile: Dictionary = casting.get_rig_snapshot()
	_check(int(sabiki_profile["hook_count"]) == 5 and int(sabiki_profile["maximum_catch_count"]) == 5, "Sabiki data defines five hook positions without creating catch results")
	_check(is_equal_approx(float(sabiki_profile["effective_height_m"]), 1.8) and sabiki_profile["compatible_species_ids"] == PackedStringArray(["herring"]), "Sabiki covers its configured 1.8 m depth span and declares Herring compatibility")
	var sabiki_root := casting.find_child("SabikiRigVisual", true, false) as Node3D
	_check(
		sabiki_root != null
		and boat_fishing_line != null
		and sabiki_root.find_child("SabikiMainline", true, false) == null
		and casting.find_child("SabikiBackboneLine", true, false) == null
		and casting.find_child("SabikiRodSideEye", true, false) == null,
		"Sabiki uses one free-line mesh and has no independent backbone or top-eye object"
	)
	_check(sabiki_root != null and sabiki_root.find_child("SabikiLeadWeight", true, false) is MeshInstance3D, "Sabiki visual has a distinct bottom sinker")
	var complete_sabiki := sabiki_root != null
	if sabiki_root != null:
		for hook_index in range(1, 6):
			var hook_node := sabiki_root.find_child("SabikiHook_%d" % hook_index, true, false) as Node3D
			complete_sabiki = complete_sabiki and hook_node != null and hook_node.find_child("SabikiBranchLine", true, false) is MeshInstance3D and hook_node.find_child("SabikiSmallHook", true, false) is Node3D and hook_node.find_child("SabikiFlashFeather_1", true, false) is MeshInstance3D
	_check(complete_sabiki, "Sabiki visual has five separate branch lines, small hooks, and feather dressing")
	var synthetic_sinker := Vector3(2.0, -12.0, -1.0)
	var saved_bait_position: Vector3 = casting.get_sinker_world_position()
	var saved_boat_velocity: Vector3 = casting.get("_boat_velocity_estimate_world")
	var saved_rod_tension := float(casting.get("_rod_tension"))
	var saved_cast_state := casting.get_casting_state()
	var saved_airborne_retrieval := bool(casting.get("_bait_airborne_retrieval"))
	var saved_airborne_elapsed := float(casting.get("_airborne_retrieval_elapsed"))
	var saved_manual_reeling := bool(casting.get("_manual_reeling"))
	var saved_rig_profile: BoatFishingRigProfile = casting.get("_current_rig")
	casting.set("_state", BoatFishingCastingSystem.CastState.WAITING)
	casting.set("_bait_world", synthetic_sinker)
	casting.set("_boat_velocity_estimate_world", Vector3.ZERO)
	casting.set("_rod_tension", 0.0)
	casting.set("_bait_airborne_retrieval", false)
	var actual_rig_up: Vector3 = casting.call("_get_sabiki_rig_up_direction_world")
	var ordered_hooks: Array[Vector3] = casting.get_rig_hook_positions()
	_check(ordered_hooks.size() == 5, "Sabiki topology returns exactly five hook points")
	var hook_order_valid := ordered_hooks.size() == 5
	if ordered_hooks.size() == 5:
		for hook_index in range(ordered_hooks.size() - 1):
			hook_order_valid = hook_order_valid and ordered_hooks[hook_index].y > ordered_hooks[hook_index + 1].y
		hook_order_valid = hook_order_valid and ordered_hooks[4].y > synthetic_sinker.y
		var rod_side_connection: Vector3 = casting.call("_get_main_line_terminal_world")
		hook_order_valid = hook_order_valid and rod_side_connection.y > ordered_hooks[0].y
	_check(hook_order_valid, "Sabiki topology orders Hook 1–5 along the single line toward the sinker")
	casting.set("_boat_velocity_estimate_world", Vector3(15.0, 0.0, -8.0))
	casting.set("_rod_tension", 1.0)
	var leaned_rig_up: Vector3 = casting.call("_get_sabiki_rig_up_direction_world")
	var leaned_hooks: Array[Vector3] = casting.get_rig_hook_positions()
	var leaned_order_valid := leaned_rig_up.y > 0.8 and leaned_hooks.size() == 5
	if leaned_hooks.size() == 5:
		for hook_index in range(leaned_hooks.size() - 1):
			leaned_order_valid = leaned_order_valid and leaned_hooks[hook_index].y > leaned_hooks[hook_index + 1].y
	_check(leaned_order_valid, "Boat flow leans the rig without flipping its top-to-bottom hook order")
	var rod_tip_for_rig: Vector3 = casting.call("_get_rod_tip_world")
	var tether_direction := Vector3(-0.52, 0.79, 0.32).normalized()
	var aligned_sinker := rod_tip_for_rig - tether_direction * 3.0
	casting.set("_bait_world", aligned_sinker)
	var expected_rig_axis: Vector3 = casting.call("_get_sabiki_rig_up_direction_world")
	var same_rig_axis_across_states := true
	for rig_state in [BoatFishingCastingSystem.CastState.CASTING, BoatFishingCastingSystem.CastState.WAITING, BoatFishingCastingSystem.CastState.RETRIEVING]:
		casting.set("_state", rig_state)
		var state_rig_up: Vector3 = casting.call("_get_sabiki_rig_up_direction_world")
		same_rig_axis_across_states = same_rig_axis_across_states and state_rig_up.dot(expected_rig_axis) > 0.9999
	_check(same_rig_axis_across_states, "Sabiki local hook layout does not jump between cast, waiting, and retrieval states")
	var aligned_connection: Vector3 = casting.call("_get_main_line_terminal_world")
	_check(aligned_connection.distance_to(aligned_sinker) < 0.0001, "Sabiki free line terminates directly at the sinker; fixed rig length remains material-only")
	var gravity_sag_stays_below_chord := true
	for progress in [0.15, 0.35, 0.65, 0.85]:
		var span_start := Vector3.ZERO
		var span_end := Vector3(1.0, -0.3, 0.0)
		var chord_point := span_start.lerp(span_end, progress)
		var taut_point := BoatFishingCastingSystem._line_path_span(span_start, span_end, span_end - span_start, span_end - span_start, Vector3.ZERO, progress)
		var slack_point := BoatFishingCastingSystem._line_path_span(span_start, span_end, span_end - span_start, span_end - span_start, Vector3.DOWN * 0.18, progress)
		gravity_sag_stays_below_chord = gravity_sag_stays_below_chord and taut_point.distance_to(chord_point) < 0.000001
		gravity_sag_stays_below_chord = gravity_sag_stays_below_chord and slack_point.y <= chord_point.y
	_check(gravity_sag_stays_below_chord, "Shared taut line follows its chord and slack line sags only with gravity, independent of rig axis")
	var previous_tube_side := Vector3.ZERO
	var tube_frame_continuous := true
	for direction in [Vector3(0.5, -0.866, 0.0), Vector3(0.25, -0.968, 0.0), Vector3(0.05, -0.999, 0.0), Vector3.DOWN]:
		var side_direction := BoatFishingCastingSystem.calculate_line_tube_side_direction(direction, previous_tube_side)
		if previous_tube_side.length_squared() > 0.001:
			tube_frame_continuous = tube_frame_continuous and side_direction.dot(previous_tube_side.normalized()) > 0.95
		previous_tube_side = side_direction
	_check(tube_frame_continuous, "Line tube cross-sections transport continuously as the backbone approaches vertical")
	casting.set("_bait_airborne_retrieval", true)
	casting.set("_airborne_retrieval_elapsed", 0.65)
	casting.set("_state", BoatFishingCastingSystem.CastState.WAITING)
	casting.set("_manual_reeling", true)
	var airborne_rig_up: Vector3 = casting.call("_get_sabiki_rig_up_direction_world")
	casting.set("_bait_airborne_retrieval", false)
	casting.set("_airborne_retrieval_elapsed", 0.0)
	var submerged_rig_up: Vector3 = casting.call("_get_sabiki_rig_up_direction_world")
	_check(airborne_rig_up.dot(submerged_rig_up) > 0.9999, "Rig axis does not switch when the waterline or airborne timer changes")
	casting.set("_state", BoatFishingCastingSystem.CastState.WAITING)
	casting.set("_manual_reeling", true)
	casting.set("_bait_airborne_retrieval", true)
	var sabiki_airborne_line_state: Dictionary = casting.call("_get_main_line_visual_state")
	var sabiki_profile_for_line_state: BoatFishingRigProfile = casting.get("_current_rig")
	casting.set("_current_rig", BoatFishingCastingSystem.SINGLE_JIG_PROFILE)
	var single_airborne_line_state: Dictionary = casting.call("_get_main_line_visual_state")
	_check(
		not bool(sabiki_airborne_line_state.get("taut", true))
		and sabiki_airborne_line_state == single_airborne_line_state,
		"A fully airborne line uses the same slack state for Single Jig and Sabiki"
	)
	casting.set("_current_rig", sabiki_profile_for_line_state)
	casting.set("_bait_airborne_retrieval", false)
	var sabiki_reeling_line_state: Dictionary = casting.call("_get_main_line_visual_state")
	casting.set("_current_rig", BoatFishingCastingSystem.SINGLE_JIG_PROFILE)
	var single_reeling_line_state: Dictionary = casting.call("_get_main_line_visual_state")
	_check(
		bool(sabiki_reeling_line_state.get("taut", false))
		and sabiki_reeling_line_state == single_reeling_line_state,
		"Manual reeling uses the same taut-state rule for Single Jig and Sabiki"
	)
	casting.set("_bait_world", saved_bait_position)
	casting.set("_boat_velocity_estimate_world", saved_boat_velocity)
	casting.set("_rod_tension", saved_rod_tension)
	casting.set("_state", saved_cast_state)
	casting.set("_bait_airborne_retrieval", saved_airborne_retrieval)
	casting.set("_airborne_retrieval_elapsed", saved_airborne_elapsed)
	casting.set("_manual_reeling", saved_manual_reeling)
	casting.set("_current_rig", saved_rig_profile)
	var synthetic_surface_y := 0.0
	var previous_exit_step := -1
	var exit_order_valid := true
	for component_index in range(6):
		var component_y := ordered_hooks[component_index].y if component_index < 5 else synthetic_sinker.y
		var exit_step := ceili((synthetic_surface_y - component_y) / 0.05)
		exit_order_valid = exit_order_valid and exit_step > previous_exit_step
		previous_exit_step = exit_step
	_check(exit_order_valid, "A vertically raised Sabiki rig exits in order Hook 1, Hook 2–5, then sinker")
	var invalid_walk_area := OnboardActivityProfile.new()
	invalid_walk_area.walkable_polygon_xz = PackedVector2Array()
	var previous_profile := onboard.profile
	onboard.profile = invalid_walk_area
	_check(not onboard.is_supported(), "First-person activity is rejected if its walkable area is missing")
	onboard.profile = previous_profile
	_check(onboard.is_supported() and bool(onboard.call("_has_valid_walkable_area")), "Configured deck movement remains restricted to a valid hull-local activity area")
	_check(casting.select_rig(&"single_jig") and int(casting.get_rig_snapshot()["hook_count"]) == 1, "Single Jig remains a one-hook rig and the default selectable option")
	var spoon_visual := casting.find_child("BoatFishingBait", true, false) as MeshInstance3D
	var spoon_hook := casting.find_child("SpoonTrebleHook", true, false) as Node3D
	_check(spoon_visual != null and spoon_visual.mesh is ArrayMesh, "Single Jig is a curved spoon mesh rather than a sphere")
	_check(spoon_visual != null and spoon_visual.find_child("SpoonLineEye", true, false) is MeshInstance3D and spoon_hook != null and spoon_hook.get_child_count() == 3, "Spoon lure has a line eye and a three-tine treble hook")
	var spoon_bounds := spoon_visual.mesh.get_aabb().size if spoon_visual != null and spoon_visual.mesh != null else Vector3.ZERO
	var spoon_material := spoon_visual.material_override as StandardMaterial3D if spoon_visual != null else null
	_check(spoon_bounds.y >= 0.08 and spoon_bounds.y <= 0.09 and spoon_bounds.x >= 0.02 and spoon_bounds.x <= 0.03 and spoon_bounds.z > 0.004, "Spoon mesh has the configured slender, curved plate proportions")
	_check(spoon_material != null and spoon_material.metallic >= 0.8 and spoon_material.roughness <= 0.25, "Spoon surface uses a bright metallic material rather than baked shading")

	# O remains the view-cycle input after the activity opened directly in first person.
	var activity_player := onboard.find_child("OnboardActivityPlayer", true, false) as CharacterBody3D
	var head_pivot := onboard.find_child("HeadPivot", true, false) as Node3D
	_check(activity_player != null and onboard.find_child("FirstPersonFishingRod", true, false) is MeshInstance3D, "First-person rod is a visual mesh attached to the hull-local activity controller")
	if activity_player == null or head_pivot == null:
		quit(1)
		return

	# Place the test player inside the safe movement inset but close to the
	# starboard gunwale, then aim outward so the accepted cast clears the hull.
	var test_gunwale_position := Vector3(0.53, onboard.profile.deck_height_m, 1.28)
	onboard.set("_player_local_position", test_gunwale_position)
	activity_player.position = test_gunwale_position
	onboard.set("_player_local_yaw", -PI * 0.5)
	onboard.set("_look_pitch", -0.34)
	head_pivot.rotation.x = -0.34
	onboard.call("_set_player_transform_from_hull")
	var camera_node := onboard.get_activity_camera()
	_check(camera_node != null and camera_node.current, "Activity camera is current before casting")
	_check(casting.select_rig(&"sabiki_rig"), "Sabiki selection is applied for the cast presentation")
	var feedback_keys: Array[String] = []
	casting.feedback_requested.connect(func(key: String) -> void: feedback_keys.append(key))
	var left_click := InputEventMouseButton.new()
	left_click.button_index = MOUSE_BUTTON_LEFT
	left_click.pressed = true
	_check(InputMap.has_action("boat_fishing_cast") and InputMap.event_is_action(left_click, "boat_fishing_cast"), "Left mouse casting is registered in the existing InputMap")
	casting._unhandled_input(left_click)
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.CHARGING, "Mouse left press begins the CHARGING state from first-person view")
	_check(not onboard.is_movement_locked() and not casting.get_debug_snapshot()["line_active"] and not casting.find_child("BoatFishingBait", true, false).visible, "Charging creates no bait or line and does not lock movement")
	var previous_back_angle := -1.0
	var previous_bend_angle := -1.0
	for checkpoint in [0.5, 1.0, 1.5, 2.0, 2.5]:
		var pose: Dictionary = casting.call("_charge_pose_for_elapsed", checkpoint)
		var back_angle := float(pose["back_angle_deg"])
		var bend_angle := float(pose["bend_angle_deg"])
		_check(back_angle > previous_back_angle and bend_angle > previous_bend_angle, "Charge pose increases continuously at %.1f seconds" % checkpoint)
		previous_back_angle = back_angle
		previous_bend_angle = bend_angle
	_check(is_equal_approx(previous_back_angle, 65.0), "The 2.5 second charge reaches the configured 65 degree back angle")
	_check(is_equal_approx(previous_bend_angle, casting.cast_full_bend_angle_deg), "The full charge produces the configured rod-tip bend")
	_check(is_equal_approx(casting.get_cast_distance_for_charge(0.0), casting.minimum_cast_distance_m), "An immediate tap maps to the minimum cast distance")
	_check(casting.get_cast_distance_for_charge(0.5) > casting.minimum_cast_distance_m and casting.get_cast_distance_for_charge(0.5) < casting.maximum_cast_distance_m, "Intermediate charge maps inside the configured cast range")
	_check(is_equal_approx(casting.get_cast_distance_for_charge(1.0), casting.maximum_cast_distance_m) and is_equal_approx(casting.get_cast_distance_for_charge(1.5), casting.maximum_cast_distance_m), "Full and overfull charge clamp to the maximum distance")
	if casting.get_casting_state() != BoatFishingCastingSystem.CastState.CHARGING:
		# A clear failure is preferable to bypassing water/path validation in the test.
		_check(false, "Deterministic charge input was accepted (actual failure feedback: %s)" % ", ".join(feedback_keys))
		main.queue_free()
		await process_frame
		quit(1)
		return
	for _frame in range(10):
		await process_frame
	var final_aim_yaw := -PI * 0.5 + 0.08
	onboard.set("_player_local_yaw", final_aim_yaw)
	onboard.call("_set_player_transform_from_hull")
	var left_release := InputEventMouseButton.new()
	left_release.button_index = MOUSE_BUTTON_LEFT
	left_release.pressed = false
	casting._unhandled_input(left_release)
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.CASTING, "Mouse release validates and starts the cast")
	var cast_target: Vector3 = casting.get_debug_snapshot()["cast_target_world_position"]
	var target_direction := Vector2(cast_target.x - camera_node.global_position.x, cast_target.z - camera_node.global_position.z).normalized()
	var final_view_direction := Vector2(-camera_node.global_basis.z.x, -camera_node.global_basis.z.z).normalized()
	_check(target_direction.dot(final_view_direction) > 0.995, "Changing aim during charge affects the release-time water target")
	_check(onboard.is_movement_locked(), "A valid released cast locks walking and jumping")
	_check(casting.get_debug_snapshot()["line_active"] and not casting.find_child("BoatFishingBait", true, false).visible, "Cast begins before bait release, without teleporting bait to the landing point")
	_check(camera.get_camera_mode_name() == "onboard_activity", "Casting does not change the camera mode")
	var cast_rod_root := casting.find_child("BoatFishingRodVisual", true, false) as Node3D
	var cast_rod_camera_transform_before := first_person_camera.global_transform.affine_inverse() * cast_rod_root.global_transform
	var cast_pitch_before := onboard.get_camera_pitch()
	var cast_look_press := InputEventMouseButton.new()
	cast_look_press.button_index = MOUSE_BUTTON_RIGHT
	cast_look_press.pressed = true
	camera._unhandled_input(cast_look_press)
	var cast_look_motion := InputEventMouseMotion.new()
	cast_look_motion.relative = Vector2(0.0, 12.0)
	camera._unhandled_input(cast_look_motion)
	await process_frame
	var cast_rod_camera_transform_after := first_person_camera.global_transform.affine_inverse() * cast_rod_root.global_transform
	_check(not is_equal_approx(onboard.get_camera_pitch(), cast_pitch_before), "Camera pitch input remains active during the cast")
	_check(cast_rod_camera_transform_before.origin.distance_to(cast_rod_camera_transform_after.origin) < 0.002, "Casting no longer freezes the rod in its release-time world pose")
	_check(cast_rod_camera_transform_before.basis.z.dot(cast_rod_camera_transform_after.basis.z) > 0.9999, "The rod keeps the same camera-relative angle during the cast")
	var cast_look_release := cast_look_press.duplicate() as InputEventMouseButton
	cast_look_release.pressed = false
	camera._unhandled_input(cast_look_release)
	for _frame in range(15):
		await process_frame
	_check(bool(casting.get_debug_snapshot()["bait_flying"]) and casting.find_child("SabikiRigVisual", true, false).visible, "Sabiki rig follows the bait through visible flight")
	_check(bool(casting.get_debug_snapshot()["fishing_audio_loops"]["line_out"]), "Cast flight requests the shared line-out audio loop")
	_check(not casting.find_child("BoatFishingBait", true, false).visible, "The Sabiki terminal weight is not confused with the single-jig bait visual")

	boat_controller.speed_mps = 2.0
	boat_controller.is_autopilot = true
	boat_controller.set("_autopilot_target_speed_mps", 2.0)
	for _frame in range(105):
		await process_frame
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.WAITING, "Cast animation advances automatically to WAITING")
	_check(bool(casting.get_debug_snapshot()["bait_landed"]), "Bait reaches the sampled dynamic surface before WAITING")
	var boat_line_mesh := boat_fishing_line.mesh as ImmediateMesh if boat_fishing_line != null else null
	if boat_line_mesh != null and boat_line_mesh.get_surface_count() > 0:
		var line_surface_arrays: Array = boat_line_mesh.surface_get_arrays(0)
		var line_route_vertices: PackedVector3Array = line_surface_arrays[Mesh.ARRAY_VERTEX]
		_check(line_route_vertices.size() >= 450, "Deployed line draws from drum exit through all guide rings to the waterline")
	else:
		_check(false, "Deployed line has a rendered reel-to-water mesh surface")
	_test_sabiki_line_transition_geometry(casting, boat_fishing_line, sabiki_root)
	_check(int(casting.get_debug_snapshot()["fishing_audio_event_counts"]["splash"]) == 0, "Bait water impact keeps the visual splash but does not play the fish-caught splash sound")
	_check(not bool(casting.get_debug_snapshot()["fishing_audio_loops"]["line_out"]), "Cast line-out loop stops when the bait lands")
	_check(onboard.is_movement_locked(), "WAITING retains the player movement lock")
	_check(boat_controller.is_autopilot and boat_controller.speed_mps > 0.0, "Casting leaves vessel motion and autopilot enabled")
	var waiting_snapshot := casting.get_debug_snapshot()
	_check(casting.get_hook_world_positions().size() == 5 and int(waiting_snapshot["rig"]["maximum_catch_count"]) == 5, "Active Sabiki exposes five derived hook positions and a five-fish capacity contract")
	var hook_depth_range: Dictionary = casting.get_hook_depth_range_m()
	_check(bool(hook_depth_range["valid"]) and float(hook_depth_range["deep_m"]) >= float(hook_depth_range["shallow_m"]) and float(hook_depth_range["deep_m"]) - float(hook_depth_range["shallow_m"]) <= 1.81, "Sabiki HUD water-layer range comes from surface- and seabed-clamped hook positions")
	_check(not casting.select_rig(&"single_jig"), "An active line prevents switching rigs")
	var seabed_sample: Dictionary = casting.call("_sample_seabed", waiting_snapshot["bait_world_position"])
	if bool(seabed_sample.get("valid", false)):
		var bait_before_floor_test: Vector3 = waiting_snapshot["bait_world_position"]
		casting.set("_bait_world", Vector3(bait_before_floor_test.x, float(seabed_sample["bottom_world_y"]) - 2.0, bait_before_floor_test.z))
		casting.call("_clamp_bait_to_water_column")
		_check(float(casting.get_debug_snapshot()["bait_world_position"].y) >= float(seabed_sample["bottom_world_y"]) + 0.21, "Valid LAT bathymetry prevents the bait from penetrating the seabed")
		var surface_y := float(casting.call("_sample_water", bait_before_floor_test).get("height", bait_before_floor_test.y))
		var surface_start := Vector3(bait_before_floor_test.x, surface_y + 0.018, bait_before_floor_test.z)
		casting.set("_bait_world", surface_start)
		casting.set("_bait_velocity_world", Vector3.ZERO)
		var cast_rod_tip: Vector3 = casting.call("_get_rod_tip_world")
		casting.set("_line_paid_out_length_m", cast_rod_tip.distance_to(surface_start) + 1.0)
	var payout_start_snapshot := casting.get_debug_snapshot()
	var payout_key_press := InputEventKey.new()
	payout_key_press.physical_keycode = KEY_F
	payout_key_press.keycode = KEY_F
	payout_key_press.pressed = true
	var line_before_pay_out := float(payout_start_snapshot["line_length_m"])
	var depth_before_pay_out := float(payout_start_snapshot["bait_depth_below_surface_m"])
	casting._input(payout_key_press)
	for _frame in range(30):
		await process_frame
	var paying_out_snapshot := casting.get_debug_snapshot()
	_check(bool(paying_out_snapshot["manual_line_releasing"]) and float(paying_out_snapshot["line_length_m"]) > line_before_pay_out + 0.5, "Holding F continuously pays out line at its configured rate")
	_check(bool(paying_out_snapshot["fishing_audio_loops"]["line_out"]), "F payout requests the shared line-out loop while actual line length grows")
	_check(absf(float(paying_out_snapshot["line_length_m"]) - float(paying_out_snapshot["bait_depth_below_surface_m"])) > 0.1, "Paid line length is maintained separately from real lure depth")
	var payout_key_release := payout_key_press.duplicate() as InputEventKey
	payout_key_release.pressed = false
	casting._input(payout_key_release)
	_check(not bool(casting.get_debug_snapshot()["manual_line_releasing"]), "Releasing F stops active payout")
	await process_frame
	_check(not bool(casting.get_debug_snapshot()["fishing_audio_loops"]["line_out"]), "Releasing F stops the requested line-out loop")
	_check(float(paying_out_snapshot["bait_depth_below_surface_m"]) > depth_before_pay_out, "The lure sinks progressively while line is being released")
	casting.set_automatic_control_owned(true)
	casting._input(payout_key_press)
	_check(not bool(casting.get_debug_snapshot()["manual_line_releasing"]), "Automatic line ownership rejects manual payout")
	casting._input(payout_key_release)
	casting.set_automatic_control_owned(false)
	casting.set("_line_paid_out_length_m", casting.maximum_line_length_m - 0.01)
	casting._input(payout_key_press)
	await process_frame
	_check(float(casting.get_debug_snapshot()["line_length_m"]) <= casting.maximum_line_length_m + 0.001, "Manual payout clamps to the configured maximum line length")
	casting._input(payout_key_release)
	casting.set("_line_paid_out_length_m", float(paying_out_snapshot["line_length_m"]))
	_check(casting.set_manual_reeling(true), "Left mouse or the shared reel control can request gradual manual reeling")
	casting._input(payout_key_press)
	var conflict_snapshot := casting.get_debug_snapshot()
	_check(bool(conflict_snapshot["line_controls_conflicted"]) and not bool(conflict_snapshot["manual_reeling"]) and not bool(conflict_snapshot["manual_line_releasing"]), "Simultaneous reel and payout inputs deterministically stop both actions")
	casting._input(payout_key_release)
	casting.set_manual_reeling(false)
	_check(not bool(casting.get_debug_snapshot()["line_controls_conflicted"]), "The simultaneous-input interlock clears after both controls are released")
	var rod_tip_before_look: Vector3 = casting.get_debug_snapshot()["rod_tip_world_position"]
	var rod_visual_root := casting.find_child("BoatFishingRodVisual", true, false) as Node3D
	var view_camera := onboard.get_activity_camera()
	var rod_camera_transform_before := view_camera.global_transform.affine_inverse() * rod_visual_root.global_transform
	var reel_screen_position_before: Vector2 = view_camera.unproject_position(handheld_reel_spool.global_position)
	var pitch_before_look := onboard.get_camera_pitch()
	var yaw_before_look := onboard.get_player_local_yaw()
	var right_mouse_press := InputEventMouseButton.new()
	right_mouse_press.button_index = MOUSE_BUTTON_RIGHT
	right_mouse_press.pressed = true
	camera._unhandled_input(right_mouse_press)
	var look_motion := InputEventMouseMotion.new()
	look_motion.relative = Vector2(-80.0, -40.0)
	camera._unhandled_input(look_motion)
	await process_frame
	var looked_snapshot := casting.get_debug_snapshot()
	_check(onboard.get_player_local_yaw() > yaw_before_look and onboard.get_camera_pitch() > pitch_before_look, "Right-drag moves the shared camera view in both yaw and pitch while fishing")
	_check(rod_tip_before_look.distance_to(looked_snapshot["rod_tip_world_position"]) > 0.05, "The rod tip follows the changed camera view and remains the active line anchor")
	var rod_camera_transform_after := view_camera.global_transform.affine_inverse() * rod_visual_root.global_transform
	_check(rod_camera_transform_before.origin.distance_to(rod_camera_transform_after.origin) < 0.002, "The rod hand anchor stays fixed relative to the camera while looking around")
	_check(rod_camera_transform_before.basis.x.dot(rod_camera_transform_after.basis.x) > 0.9999 and rod_camera_transform_before.basis.y.dot(rod_camera_transform_after.basis.y) > 0.9999, "The rod's full camera-relative orientation remains unchanged")
	_check(rod_camera_transform_before.basis.z.dot(rod_camera_transform_after.basis.z) > 0.9999, "The rod orientation follows the camera without a separate waiting aim transform")
	var reel_screen_position_after: Vector2 = view_camera.unproject_position(handheld_reel_spool.global_position)
	_check(reel_screen_position_before.distance_to(reel_screen_position_after) < 1.5, "Camera movement keeps the reel at the same screen position")
	var right_mouse_release := right_mouse_press.duplicate() as InputEventMouseButton
	right_mouse_release.pressed = false
	camera._unhandled_input(right_mouse_release)
	casting.set("_line_paid_out_length_m", maxf(0.55, float(looked_snapshot["actual_line_length_m"]) - 0.4))
	casting.set("_boat_velocity_estimate_world", Vector3.ZERO)
	casting.set("_bait_velocity_world", Vector3.ZERO)
	var bait_before_line_pull: Vector3 = looked_snapshot["bait_world_position"]
	casting.call("_update_waiting_bait", 0.05)
	var bait_after_line_pull: Vector3 = casting.get_debug_snapshot()["bait_world_position"]
	_check(bait_after_line_pull.distance_to(bait_before_line_pull) > 0.02, "A taut line makes the bait respond gradually to rod-tip movement and line tension")
	casting.set("_line_paid_out_length_m", casting.get_debug_snapshot()["actual_line_length_m"])
	var bait_before_view_switch: Vector3 = casting.get_debug_snapshot()["bait_world_position"]
	camera.cycle_camera_view()
	_check(camera.get_camera_mode_name() == "follow" and casting.get_casting_state() == BoatFishingCastingSystem.CastState.WAITING, "O returns to the driving view without clearing the active cast")
	_check(not bool(casting.get_debug_snapshot()["manual_reeling"]) and not bool(casting.get_debug_snapshot()["rod_camera_relative_pose_captured"]), "Changing view releases held controls and invalidates the first-person hand anchor")
	var bait_after_view_switch: Vector3 = casting.get_debug_snapshot()["bait_world_position"]
	_check(bait_after_view_switch.distance_to(bait_before_view_switch) < 0.001, "Changing view does not teleport or reset the bait")
	camera.cycle_camera_view()
	camera.cycle_camera_view()
	_check(onboard.is_first_person_active() and casting.get_casting_state() == BoatFishingCastingSystem.CastState.WAITING, "Returning to first person resumes the same waiting cast")
	_check(casting.get_debug_snapshot()["bait_world_position"].distance_to(bait_after_view_switch) < 0.001, "Re-entering first person does not reset the bait position")
	await process_frame
	casting._input(payout_key_press)
	_check(bool(casting.get_debug_snapshot()["manual_line_releasing"]), "F payout can be held before changing view")
	var line_before_payout_view_switch := float(casting.get_debug_snapshot()["line_length_m"])
	camera.cycle_camera_view()
	_check(not bool(casting.get_debug_snapshot()["manual_line_releasing"]) and is_equal_approx(float(casting.get_debug_snapshot()["line_length_m"]), line_before_payout_view_switch), "O clears held payout input without changing deployed line or bait state")
	casting._input(payout_key_release)
	for _frame in range(20):
		await process_frame
	var moving_snapshot := casting.get_debug_snapshot()
	_check(float(moving_snapshot["line_length_m"]) <= casting.maximum_line_length_m + 0.02, "World-space line remains bounded while the boat moves")
	_check(float(moving_snapshot["actual_line_length_m"]) <= casting.maximum_line_length_m + 0.5, "The constrained bait remains within the maximum effective line length")
	_check(moving_snapshot["bait_world_position"] != bait_after_view_switch, "Bait continues updating in world space while the driving camera is active")
	_check(retrieve_button != null and retrieve_button.visible and not retrieve_button.disabled, "Driving HUD exposes retrieve only while the cast is waiting")
	# Stabilize the boat after verifying moving-vessel behavior above so the
	# following check can validate reel state and rig geometry independently.
	var autopilot_before_static_reel := boat_controller.is_autopilot
	var speed_before_static_reel := boat_controller.speed_mps
	boat_controller.is_autopilot = false
	boat_controller.speed_mps = 0.0
	casting.set("_boat_velocity_estimate_world", Vector3.ZERO)
	var line_before_reel := float(moving_snapshot["paid_out_line_length_m"])
	if retrieve_button != null:
		retrieve_button.button_down.emit()
	for _frame in range(90):
		await process_frame
	var reeling_snapshot := casting.get_debug_snapshot()
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.WAITING and bool(reeling_snapshot["manual_reeling"]), "Holding the HUD reel control performs manual retrieval without ending the cast")
	_check(float(reeling_snapshot["paid_out_line_length_m"]) < line_before_reel, "Manual reeling shortens the paid-out line gradually")
	_check(bool(reeling_snapshot["fishing_audio_loops"]["reel_in"]), "Manual retrieval requests the shared reel-in loop")
	_check(absf(float(reeling_snapshot["reel_spin_speed_rad_s"])) > 0.0 and absf(float(reeling_snapshot["reel_visual_rotation_rad"])) > 0.1, "The shared drum rotor follows measured line retrieval")
	var reeled_hooks: Array[Vector3] = casting.get_hook_world_positions()
	var reeled_hook_order_valid := reeled_hooks.size() == 5
	if reeled_hooks.size() == 5:
		for hook_index in range(reeled_hooks.size() - 1):
			reeled_hook_order_valid = reeled_hook_order_valid and reeled_hooks[hook_index].y > reeled_hooks[hook_index + 1].y
	_check(reeled_hook_order_valid and is_equal_approx(float(reeling_snapshot["sinker_depth_below_surface_m"]), casting.get_sinker_depth_below_surface_m()), "Reeling preserves Hook 1–5 order and reports sinker depth from its world position")
	if retrieve_button != null:
		retrieve_button.button_up.emit()
	await process_frame
	_check(not bool(casting.get_debug_snapshot()["manual_reeling"]) and casting.get_casting_state() == BoatFishingCastingSystem.CastState.WAITING, "Releasing the HUD reel control stops manual reeling and leaves the lure in water")
	_check(not bool(casting.get_debug_snapshot()["fishing_audio_loops"]["reel_in"]), "Releasing the HUD reel control stops the requested reel-in loop")
	boat_controller.speed_mps = speed_before_static_reel
	boat_controller.is_autopilot = autopilot_before_static_reel
	casting.set("_boat_velocity_estimate_world", Vector3.ZERO)
	if retrieve_button != null:
		retrieve_button.button_down.emit()
	var automatic_reel_audio_seen := false
	for _frame in range(1600):
		if casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY:
			break
		await process_frame
		var retrieve_snapshot := casting.get_debug_snapshot()
		if casting.get_casting_state() == BoatFishingCastingSystem.CastState.RETRIEVING:
			automatic_reel_audio_seen = automatic_reel_audio_seen or bool(retrieve_snapshot["fishing_audio_loops"]["reel_in"])
	if casting.get_casting_state() != BoatFishingCastingSystem.CastState.READY:
		var retrieval_debug: Dictionary = casting.get_debug_snapshot()
		print("RETRIEVAL DEBUG: state=%s paid=%.3f actual=%.3f depth=%.3f tension=%.3f reeling=%s bait=%s tip=%s boat=%s" % [
			str(retrieval_debug["state"]), float(retrieval_debug["paid_out_line_length_m"]),
			float(retrieval_debug["actual_line_length_m"]), float(retrieval_debug["bait_depth_below_surface_m"]),
			float(retrieval_debug["line_tension"]), str(retrieval_debug["manual_reeling"]),
			str(retrieval_debug["bait_world_position"]), str(retrieval_debug["rod_tip_world_position"]), str(boat.global_position)
		])
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY, "Retrieval completes and returns to READY")
	_check(automatic_reel_audio_seen, "Final automatic retrieval spins the shared reel and requests reel-in audio")
	_check(casting.select_rig(&"single_jig"), "The rig can be changed again after the terminal tackle is recovered")
	if retrieve_button != null:
		retrieve_button.button_up.emit()
	_check(not onboard.is_movement_locked(), "Completed retrieval restores deck movement")
	_check(boat_controller.is_autopilot and boat_controller.speed_mps > 0.0, "Retrieval does not stop the vessel or autopilot")
	_check(not retrieve_button.visible, "Retrieve action disappears once the line is recovered")

	# Return to first person and confirm casting can be repeated, then end safely.
	boat_controller.is_autopilot = false
	boat_controller.speed_mps = 0.0
	camera.cycle_camera_view()
	camera.cycle_camera_view()
	_check(onboard.is_first_person_active(), "O can return to first-person after retrieval")
	var invalid_upward_cast := casting._calculate_water_target(camera_node.global_position, Vector3.UP)
	_check(not bool(invalid_upward_cast.get("valid", true)), "Upward aim is rejected as an invalid water cast")
	casting._unhandled_input(left_click)
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.CHARGING, "Casting can be charged again after retrieval")
	camera.cycle_camera_view()
	for _frame in range(20):
		await process_frame
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY and not onboard.is_movement_locked() and not casting.get_debug_snapshot()["line_active"], "O smoothly cancels charge without creating a line or locking movement")
	camera.cycle_camera_view()
	camera.cycle_camera_view()
	_check(onboard.is_first_person_active(), "O returns to first person after charge cancellation")
	var ready_rod_tip: Vector3 = casting.get_debug_snapshot()["rod_tip_world_position"]
	casting._unhandled_input(left_click)
	for _frame in range(165):
		await process_frame
	var fully_charged_snapshot := casting.get_debug_snapshot()
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.CHARGING and is_equal_approx(float(fully_charged_snapshot["charge_progress"]), 1.0), "Holding for 2.5 seconds reaches full charge")
	_check(is_equal_approx(float(fully_charged_snapshot["rod_back_angle_deg"]), 65.0) and is_equal_approx(float(fully_charged_snapshot["rod_bend_angle_deg"]), casting.cast_full_bend_angle_deg), "Full charge holds the maximum rod-back and flex pose")
	_check(ready_rod_tip.distance_to(fully_charged_snapshot["rod_tip_world_position"]) > 0.4, "The full charge visibly displaces the curved rod tip from its ready pose")
	var rod_visual := onboard.find_child("FirstPersonFishingRod", true, false) as MeshInstance3D
	var rod_material := rod_visual.material_override as ShaderMaterial if rod_visual != null else null
	var applied_bend_value := float(rod_material.get_shader_parameter("bend_angle")) if rod_material != null else -1.0
	_check(rod_material != null and is_equal_approx(applied_bend_value, deg_to_rad(casting.cast_full_bend_angle_deg)), "The rod mesh receives its full local vertex-bend shader value (%.3f)" % applied_bend_value)
	for _frame in range(20):
		await process_frame
	var overheld_snapshot := casting.get_debug_snapshot()
	_check(is_equal_approx(float(overheld_snapshot["charge_progress"]), 1.0) and is_equal_approx(float(overheld_snapshot["rod_back_angle_deg"]), 65.0), "Holding beyond full charge neither cycles nor loses power")
	casting.cancel_charge_smoothly()
	for _frame in range(20):
		await process_frame
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY and not onboard.is_movement_locked(), "A full charge can be cancelled without locking movement")
	onboard.set("_look_pitch", 0.18)
	head_pivot.rotation.x = 0.18
	casting._unhandled_input(left_click)
	left_release = InputEventMouseButton.new()
	left_release.button_index = MOUSE_BUTTON_LEFT
	left_release.pressed = false
	casting._unhandled_input(left_release)
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.CHARGING and not onboard.is_movement_locked() and not casting.find_child("BoatFishingBait", true, false).visible, "Releasing toward an invalid water direction creates no cast")
	_check(feedback_keys.has("hud.boat_fishing.cast_aim_down"), "Invalid release reports the water-aim reason")
	for _frame in range(20):
		await process_frame
	onboard.set("_look_pitch", -0.34)
	head_pivot.rotation.x = -0.34
	casting._unhandled_input(left_click)
	hud.call("_toggle_activity_menu")
	for _frame in range(20):
		await process_frame
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY and not casting.get_debug_snapshot()["line_active"], "Opening the activity menu smoothly cancels charge")
	hud.call("_toggle_activity_menu")
	casting._unhandled_input(left_click)
	left_release = InputEventMouseButton.new()
	left_release.button_index = MOUSE_BUTTON_LEFT
	left_release.pressed = false
	casting._unhandled_input(left_release)
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.CASTING, "A subsequent press and release can cast again")
	var autopilot_before_end := boat_controller.is_autopilot
	var speed_before_end := boat_controller.speed_mps
	hud.call("end_boat_fishing_activity")
	_check(not casting.is_activity_active() and not casting.is_cast_active() and not onboard.is_movement_locked(), "Ending Boat Fishing clears visuals and releases movement lock")
	_check(not camera.is_onboard_activity_active(), "Ending Boat Fishing restores the normal O camera cycle")
	_check(boat_controller.is_autopilot == autopilot_before_end and is_equal_approx(boat_controller.speed_mps, speed_before_end), "Ending the activity leaves vessel motion untouched")

	# Trolling opens the fixed rod-side view without entering the separate
	# deck-walking first-person activity camera.
	var fishing_panel := main.find_child("FishingPlayerPanel", true, false) as FishingPlayerPanel
	hud.call("_open_trolling_activity")
	await process_frame
	_check(fishing_panel != null and camera.get_camera_mode_name() == "fight_camera" and camera.is_trolling_rod_view_active() and not camera.is_onboard_activity_active() and not onboard.is_first_person_active(), "Opening Trolling enters the fixed rod-side view without entering deck walking view")
	_check(camera.get_available_camera_modes().has("fight_camera"), "The trolling rod view remains available in the O-key cycle")
	onboard.set_debug_bounds_visible(true)
	var trolling_debug_boundary := onboard.find_child("OnboardActivityDebugForbiddenBoundary", true, false) as MeshInstance3D
	_check(trolling_debug_boundary == null or not trolling_debug_boundary.visible, "Onboard bounds stay hidden during trolling without onboard activity")
	onboard.set_debug_bounds_visible(false)
	var trolling_action := main.find_child("TrollingActionButton", true, false) as Button
	var trolling_mount := main.find_child("FishingRodMountP3", true, false) as FishingRodMount
	_check(trolling_mount != null and trolling_mount.visible, "Opening Trolling shows the mounted rod without starting line deployment")
	var setup_rig := trolling_mount.find_child("FishingRodRig", true, false) as FishingRodRig if trolling_mount != null else null
	_check(rod_system.visual_state == FishingRodSystem.VisualState.IDLE and setup_rig != null and not setup_rig.is_line_active(), "Trolling setup shows the rod only; the line remains undeployed")
	hud.call("_on_trolling_configuration_closed")
	await process_frame
	trolling_mount = main.find_child("FishingRodMountP3", true, false) as FishingRodMount
	_check(trolling_mount != null and not trolling_mount.visible and not camera.is_trolling_rod_view_active(), "Closing inactive Trolling hides the rod and ends the temporary rod-side view")
	hud.call("_open_trolling_activity")
	await process_frame
	if trolling_action != null:
		trolling_action.pressed.emit()
	for _frame in range(5):
		await process_frame
	trolling_mount = main.find_child("FishingRodMountP3", true, false) as FishingRodMount
	_check(rod_system != null and rod_system.visual_state in [FishingRodSystem.VisualState.CASTING, FishingRodSystem.VisualState.TROLLING], "Trolling starts through the existing encounter and visual systems")
	_check(trolling_mount != null and trolling_mount.visible, "The mounted rod remains visible while trolling runs")
	camera.cycle_camera_view()
	_check(trolling_mount != null and trolling_mount.visible and camera.get_camera_mode_name() != "fight_camera", "O leaves the rod-side view without hiding the active trolling rod")
	if trolling_action != null:
		trolling_action.pressed.emit()
	for _frame in range(3):
		await process_frame
	trolling_mount = main.find_child("FishingRodMountP3", true, false) as FishingRodMount
	_check(trolling_mount != null and not trolling_mount.visible, "Stopping trolling hides the mounted rod and its attached visuals")
	_check(not camera.is_onboard_activity_active(), "Stopping trolling leaves the normal camera cycle active")
	_check(not camera.is_trolling_rod_view_active(), "Stopping trolling removes its temporary rod-side camera option")

	Input.action_release("boat_accelerate")
	Input.action_release("boat_brake")
	Input.action_release("boat_turn_left")
	Input.action_release("boat_turn_right")
	Input.action_release("boat_pause")
	main.queue_free()
	await process_frame
	if _failures == 0:
		print("P6.2 casting tests passed")
		quit(0)
	else:
		printerr("P6.2 casting tests failed: %d" % _failures)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		_failures += 1
		printerr("FAIL: %s" % message)


func _test_sabiki_line_transition_geometry(
	casting: BoatFishingCastingSystem,
	line_instance: MeshInstance3D,
	sabiki_root: Node3D
) -> void:
	if casting == null or line_instance == null or sabiki_root == null:
		_check(false, "Sabiki transition geometry fixture is available")
		return
	var saved_bait: Vector3 = casting.get_sinker_world_position()
	var saved_line_length := float(casting.get("_line_paid_out_length_m"))
	var saved_airborne := bool(casting.get("_bait_airborne_retrieval"))
	var saved_airborne_elapsed := float(casting.get("_airborne_retrieval_elapsed"))
	var saved_manual_reeling := bool(casting.get("_manual_reeling"))
	var saved_boat_velocity: Vector3 = casting.get("_boat_velocity_estimate_world")
	var saved_rod_tension := float(casting.get("_rod_tension"))
	var surface_y := float(casting.call("_sample_water", saved_bait).get("height", saved_bait.y))
	var stages := [
		{"offset": -1.0, "airborne": false, "elapsed": 0.0},
		{"offset": -0.35, "airborne": false, "elapsed": 0.0},
		{"offset": 0.0, "airborne": false, "elapsed": 0.0},
		{"offset": 0.06, "airborne": true, "elapsed": 0.0},
		{"offset": 0.06, "airborne": true, "elapsed": 0.325},
		{"offset": 0.06, "airborne": true, "elapsed": 0.65},
	]
	var all_stages_connected := true
	var hooks_unchanged := true
	var rig_connection_moves_with_sinker := true
	var previous_sinker := Vector3.ZERO
	var previous_connection := Vector3.ZERO
	var has_previous_connection := false
	for stage in stages:
		var stage_bait := saved_bait
		stage_bait.y = surface_y + float(stage["offset"])
		casting.set("_bait_world", stage_bait)
		casting.set("_bait_airborne_retrieval", bool(stage["airborne"]))
		casting.set("_airborne_retrieval_elapsed", float(stage["elapsed"]))
		casting.set("_manual_reeling", saved_manual_reeling)
		casting.call("_update_rig_visual_position")
		var hooks_before_line_render: Array[Vector3] = casting.get_hook_attachment_world_positions()
		casting.call("_update_line_and_bait_visuals")
		var connection: Vector3 = casting.call("_get_main_line_terminal_world")
		var hook_roots: Array[Vector3] = casting.get_rig_hook_positions()
		var current_hooks: Array[Vector3] = casting.get_hook_attachment_world_positions()
		var mesh_contains_connection := _line_mesh_contains_world_point(line_instance, connection, 0.004)
		var mesh_contains_sinker := _line_mesh_contains_world_point(line_instance, stage_bait, 0.004)
		if has_previous_connection:
			rig_connection_moves_with_sinker = rig_connection_moves_with_sinker and (connection - previous_connection).distance_to(stage_bait - previous_sinker) < 0.0001
		all_stages_connected = all_stages_connected and mesh_contains_connection and mesh_contains_sinker
		for hook_root in hook_roots:
			all_stages_connected = all_stages_connected and _line_mesh_contains_world_point(line_instance, hook_root, 0.004)
		hooks_unchanged = hooks_unchanged and _vector_arrays_approximately_equal(hooks_before_line_render, current_hooks, 0.00001)
		previous_sinker = stage_bait
		previous_connection = connection
		has_previous_connection = true
	_check(all_stages_connected, "Single free-line mesh joins rod tip to sinker and passes through all five hook stations during submerged, partial-exit, and airborne stages")
	_check(hooks_unchanged, "Line continuity rendering leaves all five actual hook positions unchanged")
	_check(rig_connection_moves_with_sinker, "Partial-exit connection does not jump relative to the continuously moving sinker")
	_check(is_equal_approx(float(casting.get("_line_paid_out_length_m")), saved_line_length), "Line continuity rendering does not change authoritative paid-out length")
	var rod_tip: Vector3 = casting.call("_get_rod_tip_world")
	casting.set("_boat_velocity_estimate_world", Vector3.ZERO)
	casting.set("_bait_world", rod_tip + Vector3(5.0, -3.0, 0.0))
	casting.set("_bait_airborne_retrieval", false)
	casting.set("_rod_tension", 0.0)
	var previous_up: Vector3 = casting.call("_get_sabiki_rig_up_direction_world")
	var max_load_orientation_step_deg := 0.0
	for frame_index in range(1, 31):
		casting.set("_rod_tension", float(frame_index) / 30.0)
		var current_up: Vector3 = casting.call("_get_sabiki_rig_up_direction_world")
		max_load_orientation_step_deg = maxf(max_load_orientation_step_deg, rad_to_deg(previous_up.angle_to(current_up)))
		previous_up = current_up
	_check(max_load_orientation_step_deg < 0.001, "Sabiki hook layout remains stable under changing rod load at 30 FPS")
	casting.set("_bait_world", saved_bait)
	casting.set("_bait_airborne_retrieval", saved_airborne)
	casting.set("_airborne_retrieval_elapsed", saved_airborne_elapsed)
	casting.set("_manual_reeling", saved_manual_reeling)
	casting.set("_boat_velocity_estimate_world", saved_boat_velocity)
	casting.set("_rod_tension", saved_rod_tension)
	casting.call("_update_rig_visual_position")
	casting.call("_update_line_and_bait_visuals")


func _line_mesh_contains_world_point(line_instance: MeshInstance3D, world_point: Vector3, tolerance_m: float) -> bool:
	if line_instance == null or not (line_instance.mesh is ImmediateMesh):
		return false
	var immediate := line_instance.mesh as ImmediateMesh
	if immediate.get_surface_count() <= 0:
		return false
	var arrays := immediate.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for local_vertex in vertices:
		if line_instance.to_global(local_vertex).distance_to(world_point) <= tolerance_m:
			return true
	return false


func _vector_arrays_approximately_equal(first: Array[Vector3], second: Array[Vector3], tolerance_m: float) -> bool:
	if first.size() != second.size():
		return false
	for index in range(first.size()):
		if first[index].distance_to(second[index]) > tolerance_m:
			return false
	return true


