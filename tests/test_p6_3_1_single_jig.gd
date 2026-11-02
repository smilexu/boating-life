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
	_check(not FishingEncounterSystem.rig_matches_profile(ResourceLoader.load("res://resources/fish_species/herring.tres") as FishSpeciesProfile, SINGLE_JIG), "incompatible Herring cannot enter the single-jig natural candidate pool")

	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	for _frame in range(30):
		await process_frame
	var manager := main.find_child("FishResourceManager", true, false) as FishResourceManager
	var casting := main.find_child("BoatFishingCastingSystem", true, false) as BoatFishingCastingSystem
	var rod_system := main.find_child("FishingRodSystem", true, false) as FishingRodSystem
	var boat_controller := main.find_child("MotionRoot", true, false) as Node3D
	var activities_button := main.find_child("ActivitiesButton", true, false) as Button
	var boat_fishing_button := main.find_child("OpenBoatFishingActivity", true, false) as Button
	var fishing_debug_panel := main.find_child("FishingDebugTab", true, false) as Control
	var fishing_player_panel := main.find_child("FishingPlayerPanel", true, false) as FishingPlayerPanel
	var camera_rig := main.find_child("FollowCameraRig", true, false) as BoatFollowCamera
	_check(manager != null and casting != null and rod_system != null and boat_controller != null, "Main scene exposes the shared Authority, boat cast, and automatic fight controller")
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
	rod_system.hook_strike_seconds = 0.08
	rod_system.fish_struggle_seconds = 0.08
	rod_system.progressive_retrieval_seconds = 0.32
	rod_system.surface_landing_seconds = 0.24
	rod_system.catch_presentation_seconds = 0.22
	_prepare_landed_lure(casting, boat_controller, lure_position)
	var depth := casting.get_bait_depth_below_surface_m()
	var diagnostics := encounter.evaluate_boat_fishing_candidates(lure_position, depth, 0.8, SINGLE_JIG)
	var target_candidate: Dictionary = {}
	for valid_variant in diagnostics.get("valid_candidates", []):
		if str(valid_variant.get("school_id", "")) == school_id:
			target_candidate = valid_variant
			break
	_check(not target_candidate.is_empty(), "natural candidate query uses the real lure world position and water depth")
	var far_diagnostics := encounter.evaluate_boat_fishing_candidates(lure_position + Vector3(100000.0, 0.0, 100000.0), depth, 0.8, SINGLE_JIG)
	_check(int(far_diagnostics.get("valid_candidate_count", 0)) == 0, "empty water outside the Authority query cannot produce a natural bite")
	var wrong_depth := encounter.evaluate_boat_fishing_candidates(lure_position, depth + 10.0, 0.8, SINGLE_JIG)
	var wrong_depth_has_target := false
	for wrong_variant in wrong_depth.get("valid_candidates", []):
		wrong_depth_has_target = wrong_depth_has_target or str(wrong_variant.get("school_id", "")) == school_id
	_check(not wrong_depth_has_target, "a lure outside the school's vertical activity layer is rejected")
	if target_candidate.is_empty():
		await _finish(main)
		return

	encounter.reset_boat_fishing_hazard()
	var deterministic_diagnostics := diagnostics.duplicate(true)
	deterministic_diagnostics["valid_candidates"] = [target_candidate]
	deterministic_diagnostics["total_event_rate_per_real_hour"] = float(target_candidate.get("event_rate_per_real_hour", 0.0))
	var selected_candidate := encounter.advance_boat_fishing_hazard(deterministic_diagnostics, FishingEncounterSystem.SECONDS_PER_GAME_HOUR * 100000.0)
	_check(not selected_candidate.is_empty(), "real-time hazard selects a candidate from the sampled Authority pool")
	var chosen := selected_candidate
	_check(str(chosen.get("school_id", "")) == school_id, "deterministic test fixture leaves the selected real school as the sampled candidate")
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
	_check(hooked_events.size() == 1 and encounter.state == FishingEncounterSystem.State.HOOKED, "Authority bite is confirmed once only when the fish reaches the hook")
	_check(rod_system.get_presentation_source_name() == "REAL_CATCH", "the hook signal starts the existing real automatic fight timeline")
	_check(rod_system.get_presentation_method() == "boat_fishing", "the shared fight timeline retains Boat Fishing ownership")
	_check(camera_rig == null or camera_rig.get_camera_mode_name() == "onboard_activity", "a Boat Fishing bite keeps the player's onboard first-person camera")
	_check(fishing_player_panel == null or not fishing_player_panel.is_trolling_active(), "a Boat Fishing bite does not activate the separate Trolling panel")
	var trolling_mount := main.find_child("FishingRodMountP3", true, false) as Node3D
	_check(trolling_mount == null or not trolling_mount.visible, "a Boat Fishing bite keeps the fixed Trolling rod hidden")
	var handheld_rod := casting.get("_rod_visual_root") as Node3D
	_check(handheld_rod != null and handheld_rod.visible, "the handheld Boat Fishing rod remains visible during the fight")
	_check(int(manager.get_school(school_id).get("population", 0)) == population_before, "candidate reservation and bite do not consume the school before settlement")
	var initial_line_length := float(casting.get_interaction_snapshot().get("line_length_m", 0.0))
	await create_timer(0.23).timeout
	var moving_line_length := float(casting.get_interaction_snapshot().get("line_length_m", 0.0))
	_check(moving_line_length < initial_line_length and moving_line_length > 0.0, "automatic retrieval continuously shortens the real boat-fishing line")
	await create_timer(1.0).timeout
	_check(not catch_results.is_empty(), "automatic fight reaches the shared authoritative catch settlement")
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
	_check(rod_system.get_presentation_method() == "boat_fishing", "F3 test fish enters the shared fight timeline as Boat Fishing")
	_check(camera_rig == null or camera_rig.get_camera_mode_name() == "onboard_activity", "clicking the F3 boat test does not switch to the stern trolling view")
	_check(fishing_player_panel == null or not fishing_player_panel.is_trolling_active(), "F3 Boat Fishing catch does not mark Trolling as active")
	_check(trolling_mount == null or not trolling_mount.visible, "F3 Boat Fishing catch does not show the fixed trolling rod")
	_check(handheld_rod != null and handheld_rod.visible, "F3 Boat Fishing catch retains the handheld first-person rod")
	await create_timer(1.0).timeout
	_check(catch_results.size() >= 2 and catch_results.back().debug_spawned, "F3 temporary fish runs through the shared automatic retrieval and result event")
	_check(_total_population(manager) == total_population_before_debug, "debug catch does not decrement any natural Authority population")
	_check(int(casting.get_debug_snapshot()["fishing_audio_event_counts"].get("catch_success", 0)) == 2, "debug catch produces one batch success cue through the shared path")

	_prepare_landed_lure(casting, boat_controller, lure_position)
	var cancellation_result := casting.debug_spawn_test_fish("sea_trout")
	if bool(cancellation_result.get("accepted", false)):
		casting.end_activity()
		_check(encounter.pending_catch == null and not casting.is_automatic_control_owned(), "ending boat fishing cancels and releases an unfinished pending bite")
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
			var lure_position := school_position + Vector3.RIGHT * 4.0
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
