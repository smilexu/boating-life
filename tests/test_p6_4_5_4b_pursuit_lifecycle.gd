extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const SINGLE_JIG := preload("res://resources/boat_fishing/single_jig.tres")
const SABIKI_RIG := preload("res://resources/boat_fishing/sabiki_rig.tres")
const CONTACT_RADIUS_M := 0.08

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	for _frame in range(30):
		await process_frame
	var manager := main.find_child("FishResourceManager", true, false) as FishResourceManager
	var casting := main.find_child("BoatFishingCastingSystem", true, false) as BoatFishingCastingSystem
	var boat := main.find_child("MotionRoot", true, false) as Node3D
	var activities := main.find_child("ActivitiesButton", true, false) as Button
	var boat_fishing := main.find_child("OpenBoatFishingActivity", true, false) as Button
	var debug_panel := main.find_child("FishingDebugTab", true, false) as Control
	_check(manager != null and casting != null and boat != null and activities != null and boat_fishing != null, "Main scene provides Authority, boat casting, and activity controls")
	if manager == null or casting == null or boat == null or activities == null or boat_fishing == null:
		await _finish(main)
		return
	activities.pressed.emit()
	boat_fishing.pressed.emit()
	for _frame in range(3):
		await process_frame
	_check(casting.is_activity_active() and casting.select_rig(&"single_jig"), "Boat Fishing starts with Single Jig")
	var encounter := manager.get_fishing_encounter_system()
	var wave_sampler := main.find_child("WaveSampler", true, false) as WaveSampler
	var fixture := _find_nearby_shallow_candidate(manager, encounter, boat, wave_sampler)
	_check(not fixture.is_empty(), "A matching shallow Sea Trout school is available from the real Authority")
	if fixture.is_empty():
		await _finish(main)
		return
	var school_id := str((fixture["school"] as Dictionary).get("school_id", ""))
	var school := manager.get_school(school_id)
	var authority := manager.get("_authority") as Object
	var school_states: Dictionary = authority.get("_schools") if authority != null else {}
	var school_state := school_states.get(school_id) as FishSchoolState
	_check(school_state != null, "The selected Authority school has mutable simulation state for deterministic phase timing")
	if school_state == null:
		await _finish(main)
		return
	var lure_position: Vector3 = fixture["lure_position"]
	_prepare_landed_lure(casting, boat, lure_position)
	var initial_depth := float(school.get("effective_activity_depth_m", school.get("activity_depth_m", 2.0)))
	_set_school_surface_phase(authority, school_state, initial_depth, 60.0)

	# First approach: force a short, real state-machine timeout and verify that its
	# completed result survives subsequent candidate sampling.
	var timeout_candidate := _get_targeted_candidate(casting, encounter, lure_position)
	_check(not timeout_candidate.is_empty(), "The timeout fixture still qualifies through the unchanged pre-reservation rules")
	if timeout_candidate.is_empty() or not bool(casting.call("_begin_bite_event", timeout_candidate, false, false)):
		_check(false, "A targeted school reservation starts the timeout fixture")
		await _finish(main)
		return
	var timeout_pending := encounter.pending_catch as FishingPendingCatch
	casting.set("_bite_approach_timeout_seconds", 0.01)
	casting.call("_advance_bite_approach", 0.02)
	var timeout_record: Dictionary = casting.get_natural_bite_diagnostics().get("last_pursuit_result", {})
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.WAITING and encounter.pending_catch == null, "Timeout returns to WAITING and releases the pending catch")
	_check(str(timeout_record.get("result", "")) == "failed" and str(timeout_record.get("end_reason", "")) == "approach_timeout", "Timeout writes an exact failed-pursuit record")
	_check(str(timeout_record.get("pending_release_result", "")) in ["released_by_authority", "released"], "Timeout diagnostics report a confirmed release, not an assumed success")
	_check(timeout_pending != null and int(manager.get_school(school_id).get("population", 0)) == int(school.get("population", 0)), "A cancelled reservation does not consume school population")
	var resampled_candidate := _get_targeted_candidate(casting, encounter, lure_position)
	var after_resample: Dictionary = casting.get_natural_bite_diagnostics().get("last_pursuit_result", {})
	_check(not resampled_candidate.is_empty() and str(after_resample.get("end_reason", "")) == "approach_timeout", "Candidate resampling does not overwrite the last completed pursuit")
	_check(bool(casting.call("_begin_bite_event", resampled_candidate, false, false)), "A new targeted approach can start after timeout cleanup")
	var authority_cancel_pending := encounter.pending_catch as FishingPendingCatch
	_check(encounter.cancel_boat_fishing_catch("test_authority_external_cancel"), "Authority can externally cancel the active approach reservation")
	var authority_cancel_record: Dictionary = casting.get_natural_bite_diagnostics().get("last_pursuit_result", {})
	_check(casting.get_casting_state() == BoatFishingCastingSystem.CastState.WAITING, "External Authority cancellation returns the casting state to WAITING")
	_check(str(authority_cancel_record.get("end_reason", "")) == "test_authority_external_cancel", "The most recent result preserves the exact Authority cancellation reason")
	_check(str(authority_cancel_record.get("pending_release_result", "")) == "released_by_authority" and authority_cancel_pending != null, "External Authority cancellation records its confirmed release status")

	# Second approach: the school transitions downward while its reserved fish is
	# already pursuing. The pursuit keeps its initial sphere center and finishes
	# through the actual casting state machine at 16 FPS.
	_set_school_surface_phase(authority, school_state, initial_depth, 0.6)
	var depth_candidate := _get_targeted_candidate(casting, encounter, lure_position)
	_check(not depth_candidate.is_empty(), "The second attempt passes initial activity-depth qualification")
	if depth_candidate.is_empty() or not bool(casting.call("_begin_bite_event", depth_candidate, false, false)):
		_check(false, "A second targeted approach begins after the timeout reservation is released")
		await _finish(main)
		return
	var pending := encounter.pending_catch as FishingPendingCatch
	var anchor: Vector3 = casting.get("_bite_candidate").get("pursuit_anchor_world_position", Vector3.ZERO)
	_check(pending != null and casting.get_casting_state() == BoatFishingCastingSystem.CastState.BITE_APPROACH, "The reserved fish enters the real BITE_APPROACH state")
	_check(anchor.is_finite() and anchor.distance_to(casting.call("_get_single_jig_hook_attachment_world")) <= 16.0, "The pursuit stores its initial three-dimensional school sphere center")
	var live_candidate: Dictionary = casting.get("_bite_candidate")
	var live_hook: Vector3 = casting.call("_get_single_jig_hook_attachment_world")
	var outside_hook := anchor + (live_hook - anchor).normalized() * 17.0
	var outside_result: Dictionary = casting.call("_school_pursuit_still_valid_at_anchor", live_candidate, pending, outside_hook, anchor)
	_check(not bool(outside_result.get("valid", true)) and str(outside_result.get("reason", "")) == "pursuit_range_exited", "Leaving the original pursuit sphere still invalidates the active pursuit")
	var invalid_pending := FishingPendingCatch.new()
	invalid_pending.catch_id = "stale_pending_test"
	invalid_pending.school_id = pending.school_id
	invalid_pending.species_id = pending.species_id
	invalid_pending.source_type = pending.source_type
	invalid_pending.fishing_method = pending.fishing_method
	var stale_result: Dictionary = casting.call("_school_pursuit_still_valid_at_anchor", live_candidate, invalid_pending, live_hook, anchor)
	_check(not bool(stale_result.get("valid", true)) and str(stale_result.get("reason", "")) == "pending_catch_invalid", "A stale or replaced pending catch still invalidates the pursuit")
	var missing_pending_result: Dictionary = casting.call("_school_pursuit_still_valid_at_anchor", live_candidate, null, live_hook, anchor)
	_check(not bool(missing_pending_result.get("valid", true)) and str(missing_pending_result.get("reason", "")) == "pending_catch_invalid", "A missing Authority pending catch invalidates the pursuit")
	var original_resource_state := school_state.resource_state
	school_state.resource_state = "unavailable"
	var unavailable_result: Dictionary = casting.call("_school_pursuit_still_valid_at_anchor", live_candidate, pending, live_hook, anchor)
	school_state.resource_state = original_resource_state
	_check(not bool(unavailable_result.get("valid", true)) and str(unavailable_result.get("reason", "")) == "school_unavailable", "An unavailable Authority school still invalidates the pursuit")
	var sabiki_pending := FishingPendingCatch.new()
	sabiki_pending.catch_id = "sabiki_depth_transition_test"
	sabiki_pending.school_id = school_id
	sabiki_pending.species_id = pending.species_id
	sabiki_pending.source_type = "school"
	sabiki_pending.fishing_method = "boat_fishing"
	sabiki_pending.hook_index = 2
	var live_sabiki_catches: Array = encounter.get("_sabiki_hook_catches")
	live_sabiki_catches.append(sabiki_pending)
	var single_rig := casting.get("_current_rig") as BoatFishingRigProfile
	casting.set("_current_rig", SABIKI_RIG)
	var sabiki_depth_start := school_state.activity_depth_m
	school_state.activity_depth_m = initial_depth + 5.0
	school_state.activity_depth_target_m = initial_depth + 5.0
	school_state.surface_activity_state = "descending"
	var sabiki_validity: Dictionary = casting.call("_school_pursuit_still_valid_at_anchor", live_candidate, sabiki_pending, live_hook, anchor)
	school_state.activity_depth_m = sabiki_depth_start
	_set_school_surface_phase(authority, school_state, initial_depth, 0.6)
	live_sabiki_catches.erase(sabiki_pending)
	casting.set("_current_rig", single_rig)
	_check(bool(sabiki_validity.get("valid", false)) and float(sabiki_validity.get("school_activity_depth_m", initial_depth)) - initial_depth > 2.94, "Sabiki uses the same post-reservation depth-independent pursuit validation")
	var timeout_record_while_active: Dictionary = casting.get_natural_bite_diagnostics().get("last_pursuit_result", {})
	_check(str(timeout_record_while_active.get("end_reason", "")) == "test_authority_external_cancel", "Starting a new approach does not clear the previous completed result")

	var maximum_school_depth_difference := 0.0
	var reached_fight := false
	var max_frames := 16 * 36
	for _frame in range(max_frames):
		await process_frame
		var current_school := manager.get_school(school_id)
		var current_depth := float(current_school.get("effective_activity_depth_m", current_school.get("activity_depth_m", initial_depth)))
		maximum_school_depth_difference = maxf(maximum_school_depth_difference, absf(current_depth - initial_depth))
		if casting.get_casting_state() == BoatFishingCastingSystem.CastState.FIGHTING:
			reached_fight = true
			break
		if casting.get_casting_state() != BoatFishingCastingSystem.CastState.BITE_APPROACH:
			break
	var completed_record: Dictionary = casting.get_natural_bite_diagnostics().get("last_pursuit_result", {})
	var final_distance := float(completed_record.get("fish_mouth_to_hook_distance_m", INF))
	_check(maximum_school_depth_difference > 2.94, "The Authority school representative depth changed beyond the former pursuit tolerance (observed %.2f m)" % maximum_school_depth_difference)
	_check(reached_fight, "A targeted fish continues pursuing while the Authority school dives")
	_check(str(completed_record.get("result", "")) == "success" and str(completed_record.get("end_reason", "")) == "bite_confirmed", "The descending-school approach records confirmed contact rather than depth cancellation")
	_check(final_distance <= CONTACT_RADIUS_M, "Authority confirms only after the fish mouth reaches the unchanged 0.08 m contact radius")
	_check(pending != null and int(manager.get_school(school_id).get("population", 0)) == int(school.get("population", 0)), "The reservation does not decrement population before catch settlement")
	var final_snapshot: Dictionary = casting.get_natural_bite_diagnostics(true).get("last_pursuit_result", {})
	_check(str(final_snapshot.get("end_reason", "")) == "bite_confirmed", "Fresh diagnostics preserve the most recent completed result")
	_check(debug_panel != null and debug_panel.find_child("BoatFishingLastPursuitResult", true, false) is Label, "F3 has a separate persistent Last Pursuit Result readout")
	var panel_text := str(debug_panel.call("_boat_last_pursuit_result_text", final_snapshot)) if debug_panel != null else ""
	print("[P6.4.5.4b][F3] %s" % panel_text)
	_check(not panel_text.is_empty() and (panel_text.contains("bite_confirmed") or panel_text.contains("Bite confirmed") or panel_text.contains("已确认咬钩")), "F3 formats the recorded result and localized reason for diagnosis")

	print("[P6.4.5.4b][RESULT] timeout=%s timeout_release=%s depth_change=%.3fm approach_elapsed=%.3fs end=%s contact=%.4fm final_state=%s" % [str(timeout_record.get("end_reason", "")), str(timeout_record.get("pending_release_result", "")), maximum_school_depth_difference, float(completed_record.get("elapsed_seconds", -1.0)), str(completed_record.get("end_reason", "")), final_distance, casting.get_casting_state_name()])
	if casting.is_activity_active():
		casting.end_activity()
	await _finish(main)


func _find_nearby_shallow_candidate(manager: FishResourceManager, encounter: FishingEncounterSystem, boat: Node3D, waves: WaveSampler) -> Dictionary:
	if manager == null or encounter == null or waves == null:
		return {}
	var best: Dictionary = {}
	var best_distance := INF
	for school in manager.get_all_school_snapshots():
		if str(school.get("species_id", "")) != "sea_trout":
			continue
		var profile := manager.get_species_profile("sea_trout")
		var depth := float(school.get("effective_activity_depth_m", school.get("activity_depth_m", INF)))
		if profile == null or depth >= 6.0 or not FishingEncounterSystem.rig_matches_profile(profile, SINGLE_JIG):
			continue
		var world_position: Array = school.get("world_position", [])
		if world_position.size() < 3:
			continue
		var center := Vector3(float(world_position[0]), 0.0, float(world_position[2]))
		var boat_distance := Vector2(center.x - boat.global_position.x, center.z - boat.global_position.z).length()
		if boat_distance >= best_distance:
			continue
		var lure := center + Vector3.RIGHT * 9.0
		var surface := waves.sample_physics_surface(lure, waves.get_effective_wave_time_seconds())
		lure.y = float(surface.get("height", 0.0)) - depth
		var candidate_data := encounter.evaluate_boat_fishing_candidates(lure, depth, 0.8, SINGLE_JIG)
		for candidate_variant in candidate_data.get("valid_candidates", []):
			var candidate: Dictionary = candidate_variant
			if str(candidate.get("school_id", "")) == str(school.get("school_id", "")):
				best_distance = boat_distance
				best = {"school": school, "lure_position": lure}
				break
	return best


func _get_targeted_candidate(casting: BoatFishingCastingSystem, encounter: FishingEncounterSystem, lure_position: Vector3) -> Dictionary:
	var hook_world: Vector3 = casting.call("_get_single_jig_hook_attachment_world")
	var depth := float(casting.call("_depth_below_surface_at", hook_world))
	var evaluation := encounter.evaluate_boat_fishing_candidates(hook_world, depth, 0.8, SINGLE_JIG)
	for _sample in range(24):
		var trigger := encounter.advance_boat_fishing_trigger_for_hook(evaluation, 0.5, 0)
		var candidate: Dictionary = trigger.get("candidate", {})
		if str(trigger.get("trigger_mode", "")) == "SCHOOL_TARGETED" and not candidate.is_empty():
			return candidate
	return {}


func _set_school_surface_phase(authority: Object, state: FishSchoolState, depth_m: float, remaining_seconds: float) -> void:
	state.activity_depth_m = depth_m
	state.activity_depth_target_m = depth_m
	state.surface_activity_state = "near_surface"
	state.surface_activity_remaining_seconds = remaining_seconds
	state.activity_depth_state_timestamp_seconds = float(authority.get("_simulation_seconds")) + float(authority.get("_step_accumulator"))


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


func _check(condition: bool, label: String) -> void:
	if condition:
		print("[P6.4.5.4b][PASS] %s" % label)
	else:
		_failures += 1
		push_error("[P6.4.5.4b][FAIL] %s" % label)


func _finish(main: Node) -> void:
	if is_instance_valid(main):
		main.queue_free()
	await process_frame
	await process_frame
	print("[P6.4.5.4b] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)
