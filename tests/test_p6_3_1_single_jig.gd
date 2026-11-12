extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const SINGLE_JIG := preload("res://resources/boat_fishing/single_jig.tres")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(BoatFishingCastingSystem.should_visualize_bite_approach(2.0), "2 m lure depth uses the visible bite approach")
	_check(BoatFishingCastingSystem.should_visualize_bite_approach(5.0), "5 m lure depth uses the visible bite approach")
	_check(not BoatFishingCastingSystem.should_visualize_bite_approach(6.0), "6 m is the deep-water transition threshold")
	_check(not BoatFishingCastingSystem.should_visualize_bite_approach(8.0), "8 m catch can skip the visible approach without being rejected")
	_check(BoatFishingCastingSystem.should_visualize_bite_approach(8.0, 6.0, true), "F3 can request an approach in deep water for testing")
	_check(is_equal_approx(BoatFishingCastingSystem.get_automatic_line_burst_offset_m("BACKING_OUT", 10.2, 9.0), 1.2), "P3 fish-pull line bursts are converted to bounded real boat-line payout")
	_check(is_zero_approx(BoatFishingCastingSystem.get_automatic_line_burst_offset_m("REELING", 10.2, 9.0)), "P3 line distance is not treated as payout outside a true backing-out phase")
	_check(FishingEncounterSystem.boat_fishing_action_weight(0.0) < FishingEncounterSystem.boat_fishing_action_weight(1.5), "lure movement raises action weighting without requiring a button-only bonus")
	_check(FishingEncounterSystem.rig_matches_profile(ResourceLoader.load("res://resources/fish_species/sea_trout.tres") as FishSpeciesProfile, SINGLE_JIG), "Single Jig compatibility uses the species and rig lure tags")
	_check(FishingEncounterSystem.rig_matches_profile(ResourceLoader.load("res://resources/fish_species/herring.tres") as FishSpeciesProfile, SINGLE_JIG), "Herring is compatible with the Single Jig through its small-fish lure tag")
	var fallback_profile := BoatFishingFightProfileCatalog.load_profile("boat_fish_without_tuned_profile_test", 0.82)
	_check(fallback_profile != null and fallback_profile.is_valid_for_species("boat_fish_without_tuned_profile_test") and is_equal_approx(fallback_profile.size_reference_length_m, 0.82), "unprofiled boat-fishable species receives a safe generic fight profile")

	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	for _frame in range(30):
		await process_frame
	var manager := main.find_child("FishResourceManager", true, false) as FishResourceManager
	var casting := main.find_child("BoatFishingCastingSystem", true, false) as BoatFishingCastingSystem
	var onboard := casting.get("_onboard") as OnboardActivityController if casting != null else null
	var rod_system := main.find_child("FishingRodSystem", true, false) as FishingRodSystem
	var boat_controller := main.find_child("MotionRoot", true, false) as Node3D
	var activities_button := main.find_child("ActivitiesButton", true, false) as Button
	var boat_fishing_button := main.find_child("OpenBoatFishingActivity", true, false) as Button
	var fishing_debug_panel := main.find_child("FishingDebugTab", true, false) as Control
	var fishing_player_panel := main.find_child("FishingPlayerPanel", true, false) as FishingPlayerPanel
	var camera_rig := main.find_child("FollowCameraRig", true, false) as BoatFollowCamera
	_check(manager != null and casting != null and rod_system != null and boat_controller != null and onboard != null, "Main scene exposes the shared Authority, boat cast, and trolling presentation controller")
	_check(fishing_player_panel != null and camera_rig != null, "Main scene exposes the trolling activity panel and shared camera for mode-isolation checks")
	_check(fishing_debug_panel != null, "F3 Fishing tab is present in the normal debug UI")
	if manager == null or casting == null or rod_system == null or boat_controller == null or activities_button == null or boat_fishing_button == null:
		await _finish(main)
		return

	activities_button.pressed.emit()
	boat_fishing_button.pressed.emit()
	await process_frame
	_check(casting.is_activity_active(), "Boat Fishing activity starts before casting")
	_check(casting.select_rig(&"single_jig"), "Natural and test catch use the Single Jig")
	if onboard != null and onboard.is_first_person_active() and not onboard.is_fishing_fight_view_active():
		var initial_rod_view_pitch := onboard.get_camera_pitch()
		var pitch_sensitivity := onboard.profile.mouse_sensitivity * 0.01 if onboard.profile != null else 0.01
		var rod_view_snapshot: Dictionary = onboard.get_debug_snapshot()
		_check(bool(rod_view_snapshot.get("fishing_rod_view_pitch_constraint_active", false)), "visible boat-fishing rod enables the bounded first-person pitch range")
		onboard.apply_mouse_look(Vector2(0.0, -10000.0))
		_check(is_equal_approx(rad_to_deg(onboard.get_camera_pitch()), 35.0), "visible rod limits upward camera pitch to the rod framing range")
		onboard.apply_mouse_look(Vector2(0.0, 10000.0))
		_check(is_equal_approx(rad_to_deg(onboard.get_camera_pitch()), -65.0), "visible rod limits downward camera pitch to the rod framing range")
		var pitch_restore_delta := initial_rod_view_pitch - onboard.get_camera_pitch()
		onboard.apply_mouse_look(Vector2(0.0, -pitch_restore_delta / maxf(pitch_sensitivity, 0.0001)))
		_check(is_equal_approx(onboard.get_camera_pitch(), initial_rod_view_pitch), "pitch-bound check restores the original rod view")
	var encounter := manager.get_fishing_encounter_system()
	var wave_sampler := main.find_child("WaveSampler", true, false) as WaveSampler
	var natural_fixture := _find_nearby_shallow_natural_candidate(manager, encounter, boat_controller, wave_sampler)
	_check(not natural_fixture.is_empty(), "real Authority exposes a shallow boat-fishing candidate with matching species and lure")
	if natural_fixture.is_empty():
		await _finish(main)
		return

	var school: Dictionary = natural_fixture["school"]
	var lure_position: Vector3 = natural_fixture["lure_position"]
	var school_id := str(school.get("school_id", ""))
	var population_before := int(manager.get_school(school_id).get("population", 0))
	var hooked_events: Array[String] = []
	var catch_results: Array[FishingCatchResult] = []
	encounter.fish_hooked.connect(func(pending: FishingPendingCatch) -> void: hooked_events.append(pending.catch_id))
	encounter.catch_succeeded.connect(func(result: FishingCatchResult) -> void: catch_results.append(result))
	_prepare_landed_lure(casting, boat_controller, lure_position)
	var hook_position: Vector3 = casting.call("_get_single_jig_hook_attachment_world")
	var depth := float(casting.call("_depth_below_surface_at", hook_position))
	var diagnostics := encounter.evaluate_boat_fishing_candidates(hook_position, depth, 0.8, SINGLE_JIG)
	var target_candidate: Dictionary = {}
	for valid_variant in diagnostics.get("valid_candidates", []):
		if str(valid_variant.get("school_id", "")) == school_id:
			target_candidate = valid_variant
			break
	_check(not target_candidate.is_empty(), "natural candidate query uses the real lure world position and water depth")
	if not target_candidate.is_empty():
		var target_profile := manager.get_species_profile(str(target_candidate.get("species_id", "")))
		var pursuit_distance := float(target_candidate.get("pursuit_distance_m", -1.0))
		_check(
			pursuit_distance > float(target_candidate.get("school_horizontal_radius_m", 0.0))
			and pursuit_distance <= float(target_candidate.get("pursuit_radius_m", 0.0))
			and not bool(target_candidate.get("inside_school_volume", true))
			and target_profile != null,
			"a real Authority school remains eligible at 9 m beyond its core ellipsoid"
		)
	var far_diagnostics := encounter.evaluate_boat_fishing_candidates(hook_position + Vector3(100000.0, 0.0, 100000.0), depth, 0.8, SINGLE_JIG)
	_check(int(far_diagnostics.get("valid_candidate_count", 0)) == 0, "empty water outside the Authority query cannot produce a natural bite")
	var wrong_depth := encounter.evaluate_boat_fishing_candidates(hook_position - Vector3.UP * 10.0, depth + 10.0, 0.8, SINGLE_JIG)
	var wrong_depth_has_target := false
	for wrong_variant in wrong_depth.get("valid_candidates", []):
		wrong_depth_has_target = wrong_depth_has_target or str(wrong_variant.get("school_id", "")) == school_id
	_check(not wrong_depth_has_target, "a lure outside the school's vertical activity layer is rejected")
	if target_candidate.is_empty():
		await _finish(main)
		return

	encounter.reset_boat_fishing_trigger_state()
	var trigger: Dictionary = {}
	for _sample in range(24):
		trigger = encounter.advance_boat_fishing_trigger_for_hook(diagnostics, 0.5, 0)
		if not (trigger.get("candidate", {}) as Dictionary).is_empty():
			break
	var chosen: Dictionary = trigger.get("candidate", {})
	_check(str(trigger.get("trigger_mode", "")) == "SCHOOL_TARGETED" and not chosen.is_empty(), "qualifying real school uses the short targeted response instead of the old hazard roll")
	_check(str(chosen.get("school_id", "")) == school_id, "deterministic test fixture leaves the selected real school as the sampled candidate")
	var pre_fight_camera := onboard.get_activity_camera()
	var pre_fight_rod := casting.get("_rod_visual_root") as Node3D
	var pre_fight_butt_screen := Vector2.ZERO
	var pre_fight_axis_camera_dot := 0.0
	if pre_fight_camera != null and pre_fight_rod != null:
		pre_fight_butt_screen = pre_fight_camera.unproject_position(pre_fight_rod.global_position)
		var pre_fight_tip: Vector3 = casting.call("_get_fight_solver_rod_tip_world")
		var pre_fight_axis := (pre_fight_tip - pre_fight_rod.global_position).normalized()
		pre_fight_axis_camera_dot = pre_fight_axis.dot(-pre_fight_camera.global_basis.z.normalized())
	var began := bool(casting.call("_begin_bite_event", chosen, false, false))
	var natural_pending := encounter.pending_catch
	_check(began and natural_pending != null and not natural_pending.debug_spawned, "natural Authority catch reserves one non-debug pending fish")
	_check(encounter.state == FishingEncounterSystem.State.BOAT_BITE_APPROACH and hooked_events.is_empty(), "shallow fish remains unhooked while its visual approaches the lure")
	var approach_fish := casting.find_child("TemporaryBoatCatchFish", true, false) as Node3D
	_check(approach_fish != null, "shallow catch creates one temporary visual for the already-authorized fish")
	if approach_fish != null:
		var start_position := approach_fish.global_position
		casting.set("_bite_duration", 0.22)
		await create_timer(0.06).timeout
		_check(approach_fish.global_position.distance_to(start_position) > 0.02, "temporary fish visibly swims during the approach instead of teleporting")
	else:
		casting.set("_bite_duration", 0.05)
	while casting.get_casting_state() == BoatFishingCastingSystem.CastState.BITE_APPROACH:
		await process_frame
	# Bite confirmation and the fight solver run on successive process frames.
	await process_frame
	_check(hooked_events.size() == 1 and encounter.state == FishingEncounterSystem.State.HOOKED, "Authority bite is confirmed once only when the fish reaches the hook")
	var live_pursuit: Dictionary = casting.get_natural_bite_diagnostics().get("active_pursuit_approach", {})
	var live_contact_error := float(live_pursuit.get("actual_mouth_to_hook_distance_m", INF))
	_check(str(live_pursuit.get("state", "")) == "hooked" and live_contact_error <= BoatFishingCastingSystem.BOAT_FISHING_BITE_CONTACT_RADIUS_M, "9 m runtime pursuit reaches mouth-hook contact before Authority confirms the bite")
	print("[P6.3.1] 9m runtime pursuit: species=%s, approach=%.2f s, start=%.2f m, contact=%.3f m" % [str(chosen.get("species_id", "")), float(live_pursuit.get("elapsed_seconds", 0.0)), float(live_pursuit.get("start_distance_to_hook_m", 0.0)), live_contact_error])
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.FIGHTING and bool(casting.get_debug_snapshot().get("fight_session_active", false)), "confirmed single-jig bite enters the boat fight session")
	_check(not casting.is_automatic_control_owned(), "the player owns boat-fight reel input instead of the old automatic timeline")
	_check(rod_system.get_presentation_source_name() == "NONE", "boat catch does not start the trolling rod presentation timeline")
	_check(not encounter.start_trolling() and encounter.pending_catch == natural_pending, "trolling cannot replace a confirmed boat-fishing catch in the shared Encounter")
	_check(InputMap.has_action("boat_fishing_drag_loosen") and InputMap.has_action("boat_fishing_drag_tighten"), "boat fight drag adjustment is available through dedicated InputMap actions")
	var drag_before := float(casting.get_debug_snapshot().get("drag_setting", -1.0))
	Input.action_press("boat_fishing_drag_tighten")
	casting.call("_update_fight_controls", 0.5)
	Input.action_release("boat_fishing_drag_tighten")
	var drag_after := float(casting.get_debug_snapshot().get("drag_setting", -1.0))
	_check(drag_after > drag_before, "holding the drag-tighten action raises drag continuously during a fight")
	Input.action_press("boat_fishing_drag_loosen")
	casting.call("_update_fight_controls", 0.5)
	Input.action_release("boat_fishing_drag_loosen")
	var drag_loosened := float(casting.get_debug_snapshot().get("drag_setting", -1.0))
	_check(drag_loosened < drag_after, "holding the drag-loosen action lowers drag continuously during a fight")
	_check(camera_rig == null or camera_rig.get_camera_mode_name() == "onboard_activity", "a Boat Fishing bite keeps the player's onboard first-person camera")
	_check(fishing_player_panel == null or not fishing_player_panel.is_trolling_active(), "a Boat Fishing bite does not activate the separate Trolling panel")
	var trolling_mount := main.find_child("FishingRodMountP3", true, false) as Node3D
	_check(trolling_mount == null or not trolling_mount.visible, "a Boat Fishing bite keeps the fixed Trolling rod hidden")
	var handheld_rod := casting.get("_rod_visual_root") as Node3D
	_check(handheld_rod != null and handheld_rod.visible, "the handheld Boat Fishing rod remains visible during the fight")
	var handheld_rod_mesh := handheld_rod.find_child("FirstPersonFishingRod", true, false) as MeshInstance3D if handheld_rod != null else null
	_check(handheld_rod_mesh != null and handheld_rod_mesh.is_visible_in_tree(), "the handheld rod mesh itself remains visible during the fight")
	_check(float(casting.get_debug_snapshot().get("rod_bend_angle_deg", 0.0)) > 0.0, "confirmed fish tension drives a visible handheld rod bend")
	var rod_visual_snapshot := casting.get_fight_snapshot()
	_check(float(rod_visual_snapshot.get("rod_visual_target_bend_deg", 0.0)) > 8.0, "ordinary herring load targets a clearly visible rod arc using the visual load reference")
	_check(float(rod_visual_snapshot.get("rod_visual_actual_bend_deg", 0.0)) > 0.0 and rod_visual_snapshot.has("line_visual_slack_ratio"), "fight exposes smoothed rod bend and tension-driven line slack diagnostics")
	var fight_geometry := casting.get_fight_snapshot(true)
	var fight_participants: Array = fight_geometry.get("participants", [])
	_check(fight_participants.size() == 1, "single-jig fight exposes one live geometry participant")
	if not fight_participants.is_empty():
		var mouth_error := float((fight_participants[0] as Dictionary).get("mouth_hook_error_m", -1.0))
		print("[P6.4.5][SINGLE_GEOMETRY] live mouth-hook error=%.6fm" % mouth_error)
		_check(mouth_error >= 0.0 and mouth_error <= 0.01, "live single-jig fish mouth stays within 1 cm of its actual hook tip")
	if handheld_rod != null and onboard != null and onboard.is_first_person_active():
		var view_snapshot: Dictionary = onboard.get_debug_snapshot()
		var fight_yaw_base_deg := float(view_snapshot.get("fishing_fight_yaw_base_degrees", 0.0))
		var fight_pitch_base_deg := float(view_snapshot.get("fishing_fight_pitch_degrees", 0.0))
		_check(bool(view_snapshot.get("fishing_fight_view_active", false)), "boat fight activates the bounded onboard view")
		var fight_camera := onboard.get_activity_camera()
		var rod_swing := casting.get("_rod_swing") as Node3D
		var fight_reel := casting.get("_reel_visual_root") as Node3D
		var fight_butt_screen := fight_camera.unproject_position(handheld_rod.global_position) if fight_camera != null else Vector2.ZERO
		var fight_butt_camera_local := fight_camera.to_local(handheld_rod.global_position) if fight_camera != null else Vector3.ZERO
		var fight_reel_camera_local := fight_camera.to_local(fight_reel.global_position) if fight_camera != null and fight_reel != null else Vector3.ZERO
		var fight_axis_camera_dot := pre_fight_axis_camera_dot
		if fight_camera != null and rod_swing != null:
			var solver_tip: Vector3 = casting.call("_get_fight_solver_rod_tip_world")
			var rod_axis := (solver_tip - rod_swing.global_position).normalized()
			var camera_forward := -fight_camera.global_basis.z.normalized()
			fight_axis_camera_dot = rod_axis.dot(camera_forward)
			_check(
				absf(fight_axis_camera_dot - pre_fight_axis_camera_dot) <= 0.01,
				"fight entry preserves the rod's prior angular offset from the camera"
			)
		_check(
			fight_camera != null and pre_fight_camera != null and fight_butt_screen.distance_to(pre_fight_butt_screen) <= 2.0,
			"single-jig fight entry keeps the rod butt at its pre-fight screen anchor"
		)
		onboard.apply_mouse_look(Vector2(-10000.0, -10000.0))
		await create_timer(0.32).timeout
		view_snapshot = onboard.get_debug_snapshot()
		var fight_yaw_offset_deg := absf(float(view_snapshot.get("fishing_fight_yaw_offset_degrees", 999.0)))
		_check(fight_yaw_offset_deg <= 55.1, "boat-fight yaw stays inside the fixed range around the fight-start heading")
		var fight_pitch_deg := float(view_snapshot.get("fishing_fight_pitch_degrees", INF))
		_check(fight_pitch_deg >= -65.1 and fight_pitch_deg <= 35.1, "boat-fight pitch stays inside the vertical framing bounds")
		if fight_camera != null and handheld_rod != null:
			var moved_relative := fight_camera.to_local(handheld_rod.global_position)
			_check(
				moved_relative.distance_to(fight_butt_camera_local) <= 0.001,
				"single-jig rod butt keeps its camera-relative anchor while the fight camera turns"
			)
			if fight_reel != null:
				var moved_reel_relative := fight_camera.to_local(fight_reel.global_position)
				_check(
					moved_reel_relative.distance_to(fight_reel_camera_local) <= 0.001,
					"single-jig reel keeps its camera-relative placement while the fight camera turns"
				)
			var moved_tip: Vector3 = casting.call("_get_fight_solver_rod_tip_world")
			var moved_axis := (moved_tip - handheld_rod.global_position).normalized()
			_check(
				absf(moved_axis.dot(-fight_camera.global_basis.z.normalized()) - fight_axis_camera_dot) <= 0.01,
				"single-jig rod keeps its fight-start angular offset as the camera turns"
			)
		var sensitivity := onboard.profile.mouse_sensitivity if onboard.profile != null else 1.0
		var yaw_restore_delta := deg_to_rad(fight_yaw_base_deg) - onboard.get_player_local_yaw()
		var pitch_restore_delta := deg_to_rad(fight_pitch_base_deg) - onboard.get_camera_pitch()
		onboard.apply_mouse_look(Vector2(
			-yaw_restore_delta / maxf(sensitivity * 0.01, 0.0001),
			-pitch_restore_delta / maxf(sensitivity * 0.01, 0.0001)
		))
		await process_frame
	_check(int(manager.get_school(school_id).get("population", 0)) == population_before, "candidate reservation and bite do not consume the school before settlement")
	var initial_line_length := float(casting.get_interaction_snapshot().get("line_length_m", 0.0))
	casting.set_manual_reeling(true, true)
	await create_timer(0.23).timeout
	var moving_line_length := float(casting.get_interaction_snapshot().get("line_length_m", 0.0))
	casting.set_manual_reeling(false, true)
	_check(moving_line_length < initial_line_length and moving_line_length > 0.0, "player-held reel input shortens the one authoritative boat-fishing line")
	var safe_minimum := float(casting.call("_get_fight_minimum_line_length_m"))
	casting.set("_line_paid_out_length_m", safe_minimum)
	casting.set_manual_reeling(true, true)
	casting.call("_advance_boat_fight", 0.016)
	casting.set_manual_reeling(false, true)
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.LANDING, "reeling the tackle to the hull-safe boundary starts the boat landing phase")
	var landing_view_snapshot: Dictionary = onboard.get_debug_snapshot() if onboard != null else {}
	_check(bool(landing_view_snapshot.get("fishing_presentation_tracking_active", false)), "landing enables automatic vertical framing for the surfaced fish")
	for _frame in range(8):
		await process_frame
	landing_view_snapshot = onboard.get_debug_snapshot() if onboard != null else {}
	var tracked_pitch_deg := float(landing_view_snapshot.get("fishing_presentation_pitch_target_degrees", INF))
	_check(
		bool(landing_view_snapshot.get("fishing_presentation_pitch_target_valid", false))
		and tracked_pitch_deg >= -65.0 and tracked_pitch_deg <= 35.0,
		"landing derives a bounded camera pitch target from the live fish positions"
	)
	var settled_natural := await _wait_until(func() -> bool: return not catch_results.is_empty(), 180)
	_check(settled_natural, "boat landing reaches the shared authoritative catch settlement")
	_check(fishing_player_panel == null or fishing_player_panel.get("_last_catch_result") == null, "trolling result panel ignores Boat Fishing settlement events")
	if not catch_results.is_empty():
		var natural_result := catch_results[0]
		_check(natural_result.fishing_method == "boat_fishing" and not natural_result.debug_spawned, "natural CatchResult is identified as a boat-fishing catch")
		_check(natural_result.school_id == school_id and int(manager.get_school(school_id).get("population", 0)) == population_before - 1, "settlement decrements exactly one fish from the matched Authority school")
		var profile := manager.get_species_profile(natural_result.species_id)
		_check(profile != null and natural_result.length_m >= profile.body_length_range_m.x and natural_result.length_m <= profile.body_length_range_m.y, "settled fish length remains inside its species profile")
	_check(int(casting.get_debug_snapshot()["fishing_audio_event_counts"].get("catch_success", 0)) == 1, "natural settlement reports one success cue")
	await create_timer(0.6).timeout

	var f3_button := fishing_debug_panel.find_child("BoatFishingSpawnTestFishBite", true, false) as Button if fishing_debug_panel != null else null
	_check(f3_button != null, "F3 Fishing tab exposes Spawn Test Fish & Bite")
	if f3_button != null:
		_check(not f3_button.disabled, "F3 test-fish control is available when the test species is selected")
	var total_population_before_debug := _total_population(manager)
	_prepare_landed_lure(casting, boat_controller, lure_position)
	if f3_button != null:
		f3_button.pressed.emit()
	else:
		casting.debug_spawn_test_fish("sea_trout")
	var debug_pending := encounter.pending_catch
	_check(debug_pending != null and debug_pending.debug_spawned and debug_pending.school_id.is_empty(), "F3 test uses a temporary catch record with no Authority school reservation")
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.BITE_APPROACH, "F3 test joins the same shallow visual approach state")
	var duplicate_debug := casting.debug_spawn_test_fish(debug_pending.species_id if debug_pending != null else "sea_trout")
	_check(not bool(duplicate_debug.get("accepted", false)) and casting.find_children("TemporaryBoatCatchFish", "Node3D", true, false).size() <= 1, "repeated F3 activation cannot create a second active bite fish")
	casting.set("_bite_duration", 0.16)
	while casting.get_casting_state() == BoatFishingCastingSystem.CastState.BITE_APPROACH:
		await process_frame
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.FIGHTING and rod_system.get_presentation_source_name() == "NONE", "F3 test fish enters player-controlled boat fighting without trolling presentation")
	_check(camera_rig == null or camera_rig.get_camera_mode_name() == "onboard_activity", "clicking the F3 boat test does not switch to the stern trolling view")
	_check(fishing_player_panel == null or not fishing_player_panel.is_trolling_active(), "F3 Boat Fishing catch does not mark Trolling as active")
	_check(trolling_mount == null or not trolling_mount.visible, "F3 Boat Fishing catch does not show the fixed trolling rod")
	_check(handheld_rod != null and handheld_rod.visible, "F3 Boat Fishing catch retains the handheld first-person rod")
	safe_minimum = float(casting.call("_get_fight_minimum_line_length_m"))
	casting.set("_line_paid_out_length_m", safe_minimum)
	casting.set_manual_reeling(true, true)
	casting.call("_advance_boat_fight", 0.016)
	casting.set_manual_reeling(false, true)
	var settled_debug := await _wait_until(func() -> bool: return catch_results.size() >= 2, 180)
	_check(settled_debug and catch_results.back().debug_spawned, "F3 temporary fish follows player reel, landing, and the shared result event")
	_check(_total_population(manager) == total_population_before_debug, "debug catch does not decrement any natural Authority population")
	_check(int(casting.get_debug_snapshot()["fishing_audio_event_counts"].get("catch_success", 0)) == 2, "debug catch produces one success cue through the shared path")

	_prepare_landed_lure(casting, boat_controller, lure_position)
	var line_profile := ResourceLoader.load("res://resources/boat_fishing/line_profiles/standard_boat_fishing_line.tres") as BoatFishingLineProfile
	var solver := casting.get("_fight_solver") as BoatFishingFightSolver
	var low_break_profile := line_profile.duplicate(true) as BoatFishingLineProfile if line_profile != null else null
	var previous_max_line := casting.maximum_line_length_m
	if low_break_profile != null and solver != null:
		low_break_profile.line_break_force_n = 1.0
		low_break_profile.drag_min_force_n = 0.0
		low_break_profile.drag_max_force_n = 0.0
		low_break_profile.default_drag_setting = 0.0
		low_break_profile.break_danger_seconds_to_snap = 0.1
		low_break_profile.transient_peak_gain = 0.0
		solver.configure(low_break_profile)
		var snap_result := casting.debug_spawn_test_fish("sea_trout")
		if bool(snap_result.get("accepted", false)):
			casting.set("_bite_duration", 0.05)
			while casting.get_casting_state() == BoatFishingCastingSystem.CastState.BITE_APPROACH:
				await process_frame
			var trout_rod_mesh := handheld_rod.find_child("FirstPersonFishingRod", true, false) as MeshInstance3D if handheld_rod != null else null
			_check(str(casting.get("_active_catch_species_id")) == "sea_trout", "the line-break scenario is fighting the explicitly spawned Sea Trout")
			_check(handheld_rod != null and handheld_rod.visible and trout_rod_mesh != null and trout_rod_mesh.is_visible_in_tree(), "the handheld rod remains visible in the Sea Trout fight")
			var results_before_snap := catch_results.size()
			var line_at_snap_limit := float(casting.get_interaction_snapshot().get("line_length_m", 0.0))
			casting.maximum_line_length_m = line_at_snap_limit
			casting.call("_advance_boat_fight", 0.5)
			_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.LINE_BROKEN, "overloaded boat line enters the explicit snapped state")
			_check(encounter.pending_catch == null and catch_results.size() == results_before_snap, "snapping cancels the pending catch without settlement")
			_check(is_zero_approx(float(casting.get_debug_snapshot().get("paid_out_line_length_m", 1.0))) and not bool(casting.get_debug_snapshot().get("fight_session_active", false)), "snapping clears the fight session and authoritative paid-out line")
			_check(float(casting.get_debug_snapshot().get("rod_bend_angle_deg", 1.0)) <= 0.001, "snapping releases the handheld rod bend")
			var recovered := await _wait_until(func() -> bool: return casting.get_casting_state() == BoatFishingCastingSystem.CastState.READY, 120)
			_check(recovered and not onboard.is_movement_locked(), "snapping returns the player to a ready, movable state")
		else:
			_check(false, "F3 test catch starts the line-break integration scenario")
		casting.maximum_line_length_m = previous_max_line
	else:
		_check(false, "standard line profile and boat fight solver load for line-break integration")
	if casting.is_activity_active():
		casting.end_activity()
	await _finish(main)


func _find_nearby_shallow_natural_candidate(manager: FishResourceManager, encounter: FishingEncounterSystem, boat: Node3D, waves: WaveSampler) -> Dictionary:
	if manager == null or encounter == null or waves == null:
		return {}
	var schools := manager.get_all_school_snapshots()
	var best: Dictionary = {}
	var best_distance := INF
	var origin := boat.global_position
	for school in schools:
		var species_id := str(school.get("species_id", ""))
		var profile := manager.get_species_profile(species_id)
		var depth := float(school.get("activity_depth_m", INF))
		if profile == null or not profile.supported_fishing_methods.has("boat_fishing") or not FishingEncounterSystem.rig_matches_profile(profile, SINGLE_JIG) or depth >= 6.0:
			continue
		var values: Array = school.get("world_position", [])
		if values.size() < 3:
			continue
		var school_position := Vector3(float(values[0]), 0.0, float(values[2]))
		var distance := Vector2(school_position.x - origin.x, school_position.z - origin.z).length()
		if distance < best_distance:
			var lure_position := school_position + Vector3.RIGHT * 9.0
			var lure_surface := waves.sample_physics_surface(lure_position, waves.get_effective_wave_time_seconds())
			lure_position.y = float(lure_surface.get("height", 0.0)) - depth
			var diagnostics := encounter.evaluate_boat_fishing_candidates(lure_position, depth, 0.8, SINGLE_JIG)
			for candidate in diagnostics.get("valid_candidates", []):
				if str(candidate.get("school_id", "")) == str(school.get("school_id", "")):
					best_distance = distance
					best = {"school": school, "candidate": candidate, "lure_position": lure_position}
					break
	return best


func _prepare_landed_lure(casting: BoatFishingCastingSystem, boat: Node3D, lure_position: Vector3) -> void:
	boat.global_position = Vector3(lure_position.x - 4.0, boat.global_position.y, lure_position.z)
	casting.set("_bait_world", lure_position)
	casting.set("_bait_velocity_world", Vector3.ZERO)
	casting.set("_bait_has_landed", true)
	casting.set("_bait_flight_started", true)
	var rod_tip: Vector3 = casting.call("_get_rod_tip_world")
	casting.set("_line_paid_out_length_m", clampf(rod_tip.distance_to(lure_position), 1.0, casting.maximum_line_length_m))
	var onboard := casting.get("_onboard") as OnboardActivityController
	if onboard != null:
		onboard.set_movement_locked(true)
	var bait_mesh := casting.find_child("BoatFishingBait", true, false) as MeshInstance3D
	if bait_mesh != null:
		bait_mesh.visible = true
	var line_mesh := casting.find_child("BoatFishingLine", true, false) as MeshInstance3D
	if line_mesh != null:
		line_mesh.visible = true
	casting.call("_set_state", BoatFishingCastingSystem.CastState.WAITING)


func _total_population(manager: FishResourceManager) -> int:
	var total := 0
	for school in manager.get_all_school_snapshots():
		total += int(school.get("population", 0))
	return total


func _wait_until(predicate: Callable, max_frames: int) -> bool:
	for _frame in range(max_frames):
		if predicate.call():
			return true
		await process_frame
	return bool(predicate.call())


func _check(condition: bool, label: String) -> void:
	if condition:
		print("[P6.3.1][PASS] %s" % label)
	else:
		_failures += 1
		push_error("[P6.3.1][FAIL] %s" % label)


func _finish(main: Node) -> void:
	if is_instance_valid(main):
		main.queue_free()
	await process_frame
	await process_frame
	print("[P6.3.1] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)
