extends SceneTree

const SABIKI_RIG: BoatFishingRigProfile = preload("res://resources/boat_fishing/sabiki_rig.tres")
const SINGLE_JIG: BoatFishingRigProfile = preload("res://resources/boat_fishing/single_jig.tres")
const HERRING_PROFILE: FishSpeciesProfile = preload("res://resources/fish_species/herring.tres")
const SEA_TROUT_PROFILE: FishSpeciesProfile = preload("res://resources/fish_species/sea_trout.tres")
const MAIN_SCENE: PackedScene = preload("res://scenes/main.tscn")


class FakeAmbientAuthorityManager extends Node:
	var profiles: Dictionary = {}
	var schools: Dictionary = {}
	var ambient_fish: Dictionary = {}
	var settled_ambient: Dictionary = {}
	var next_ambient_sequence := 1
	var last_search_position := Vector3.ZERO
	var last_search_radius := 0.0
	var school_batch_calls := 0

	func get_species_profile(species_id: String) -> FishSpeciesProfile:
		return profiles.get(species_id) as FishSpeciesProfile

	func get_world_seed() -> int:
		return 462031

	func get_world_game_time_seconds() -> float:
		return 0.0

	func get_school(school_id: String) -> Dictionary:
		return (schools.get(school_id, {}) as Dictionary).duplicate(true)

	func get_schools_near(position: Vector3, radius_m: float, include_unavailable: bool = false) -> Array[Dictionary]:
		last_search_position = position
		last_search_radius = radius_m
		var result: Array[Dictionary] = []
		for school_variant in schools.values():
			var school: Dictionary = school_variant
			if not include_unavailable and int(school.get("population", 0)) <= 0:
				continue
			var point: Array = school.get("world_position", [])
			if point.size() < 3:
				continue
			var dx := float(point[0]) - position.x
			var dz := float(point[2]) - position.z
			if dx * dx + dz * dz <= radius_m * radius_m:
				result.append(school.duplicate(true))
		return result

	func evaluate_ambient_fishing_candidates(context: Dictionary) -> Dictionary:
		if not bool(context.get("action_qualified", false)):
			return {"candidates": [], "reason": "action_requirement_not_met", "environment_quality": 0.0}
		var rig_type := str(context.get("rig_type", ""))
		var species_id := "herring" if rig_type == "sabiki" else "sea_trout"
		var profile := get_species_profile(species_id)
		var rig_ids: Array = context.get("rig_compatible_species_ids", [])
		var rig_tags: Array = context.get("rig_compatible_lure_tags", [])
		var compatible := rig_ids.has(species_id)
		if rig_ids.is_empty():
			for tag in rig_tags:
				compatible = compatible or (profile != null and profile.compatible_lure_tags.has(tag))
		if profile == null or not compatible or not profile.supported_fishing_methods.has("boat_fishing"):
			return {"candidates": [], "reason": "method_or_rig_mismatch", "environment_quality": 0.0}
		return {
			"candidates": [{
				"species_id": species_id,
				"ecological_weight": 0.27 if species_id == "herring" else 0.015,
				"spawn_chance": profile.spawn_chance,
				"chart_depth_m": 20.0,
				"habitat_region": "test_water",
				"activity_depth_weight": 1.0,
			}],
			"reason": "ambient_species_available",
			"environment_quality": 1.0,
		}

	func request_ambient_fish_encounter(context: Dictionary) -> Dictionary:
		var evaluated := evaluate_ambient_fishing_candidates(context)
		var candidates: Array = evaluated.get("candidates", [])
		if candidates.is_empty():
			return {"accepted": false, "reason": str(evaluated.get("reason", "no_legal_species"))}
		var species_id := str(candidates[0].get("species_id", ""))
		var ambient_id := "test_ambient_%04d" % next_ambient_sequence
		next_ambient_sequence += 1
		var hook_position: Vector3 = context.get("hook_world_position", Vector3.ZERO)
		var record := {
			"ambient_fish_id": ambient_id,
			"source_type": "ambient",
			"species_id": species_id,
			"body_length_m": 0.34 if species_id == "herring" else 0.52,
			"fishing_session_id": str(context.get("fishing_session_id", "")),
			"cast_session_id": str(context.get("cast_session_id", "")),
			"hook_index": int(context.get("hook_index", -1)),
			"lifecycle_state": "reserved",
			"hook_world_position": [hook_position.x, hook_position.y, hook_position.z],
			"spawn_world_position": [hook_position.x - 3.0, hook_position.y, hook_position.z],
			"hook_depth_m": float(context.get("hook_depth_m", 0.0)),
			"chart_depth_m": 20.0,
			"habitat_region": "test_water",
			"ecological_weight": float(candidates[0].get("ecological_weight", 0.0)),
		}
		ambient_fish[ambient_id] = record
		return {"accepted": true, "fish": record.duplicate(true), "evaluation": evaluated}

	func get_ambient_fish_encounter(ambient_id: String) -> Dictionary:
		return (ambient_fish.get(ambient_id, {}) as Dictionary).duplicate(true)

	func confirm_ambient_fish_encounter(ambient_id: String, session_id: String, hook_index: int) -> bool:
		var record: Dictionary = ambient_fish.get(ambient_id, {})
		if record.is_empty() or str(record.get("fishing_session_id", "")) != session_id or int(record.get("hook_index", -1)) != hook_index or str(record.get("lifecycle_state", "")) != "reserved":
			return false
		record["lifecycle_state"] = "hooked"
		ambient_fish[ambient_id] = record
		return true

	func release_ambient_fish_encounter(ambient_id: String, _reason: String = "cancelled") -> bool:
		if not ambient_fish.has(ambient_id):
			return false
		ambient_fish.erase(ambient_id)
		return true

	func release_ambient_fishing_session(session_id: String, _reason: String = "session_ended") -> int:
		var count := 0
		for ambient_id in ambient_fish.keys():
			if str(ambient_fish[ambient_id].get("fishing_session_id", "")) == session_id:
				ambient_fish.erase(ambient_id)
				count += 1
		return count

	func settle_ambient_fish_encounter(ambient_id: String) -> Dictionary:
		var record: Dictionary = ambient_fish.get(ambient_id, {})
		if record.is_empty() or str(record.get("lifecycle_state", "")) != "hooked" or settled_ambient.has(ambient_id):
			return {"accepted": false, "reason": "ambient_fish_not_hooked_or_already_settled"}
		ambient_fish.erase(ambient_id)
		settled_ambient[ambient_id] = true
		return {"accepted": true, "fish": record.duplicate(true)}

	func get_ambient_fish_session_snapshot(session_id: String) -> Array[Dictionary]:
		var result: Array[Dictionary] = []
		for record_variant in ambient_fish.values():
			var record: Dictionary = record_variant
			if str(record.get("fishing_session_id", "")) == session_id:
				result.append(record.duplicate(true))
		return result

	func settle_boat_fishing_catch_batch(changes: Dictionary, ambient_ids: Array[String]) -> Dictionary:
		for ambient_id in ambient_ids:
			var record: Dictionary = ambient_fish.get(ambient_id, {})
			if record.is_empty() or str(record.get("lifecycle_state", "")) != "hooked" or settled_ambient.has(ambient_id):
				return {"accepted": false, "reason": "ambient_batch_member_invalid"}
		for school_id_variant in changes.keys():
			var school: Dictionary = schools.get(str(school_id_variant), {})
			if school.is_empty() or int(school.get("population", 0)) < -int(changes[school_id_variant]):
				return {"accepted": false, "reason": "school_batch_invalid"}
		var populations: Dictionary = {}
		for school_id_variant in changes.keys():
			var school_id := str(school_id_variant)
			var school: Dictionary = schools[school_id]
			school["population"] = int(school.get("population", 0)) + int(changes[school_id_variant])
			populations[school_id] = int(school["population"])
			school["resource_state"] = "depleted" if int(school["population"]) <= 0 else "available"
			schools[school_id] = school
			school_batch_calls += 1
		for ambient_id in ambient_ids:
			ambient_fish.erase(ambient_id)
			settled_ambient[ambient_id] = true
		return {"accepted": true, "populations": populations}


var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager := FakeAmbientAuthorityManager.new()
	manager.profiles = {"herring": HERRING_PROFILE, "sea_trout": SEA_TROUT_PROFILE}
	root.add_child(manager)
	var encounter := FishingEncounterSystem.new()
	root.add_child(encounter)
	encounter.configure(manager, null)
	encounter.set_process(false)
	_test_first_drop_and_open_water_ambient(encounter, manager)
	_test_target_priority_and_switching(encounter, manager)
	_test_shared_sabiki_hazard(encounter, manager)
	_test_single_ambient_lifecycle(encounter, manager)
	_test_mixed_sabiki_settlement_and_cancel(encounter, manager)
	encounter.end_boat_fishing_session("test_complete")
	encounter.queue_free()
	manager.queue_free()
	await process_frame
	await _test_live_local_authority_ambient()
	print("[P6.4.5.2] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _start_session(encounter: FishingEncounterSystem, rig: BoatFishingRigProfile) -> Dictionary:
	encounter.end_boat_fishing_session("test_restart")
	var session_id := encounter.begin_boat_fishing_session()
	var first_drop := encounter.begin_boat_fishing_cast_session(Vector3(123.0, -1.5, 456.0), rig)
	return {"session_id": session_id, "first_drop": first_drop}


func _ambient_context(encounter: FishingEncounterSystem, hook_index: int, rig: BoatFishingRigProfile, position: Vector3 = Vector3(10.0, -1.5, 20.0)) -> Dictionary:
	return {
		"hook_world_position": position,
		"hook_depth_m": 1.5,
		"water_column_m": 20.0,
		"relative_speed_mps": 0.0,
		"action_weight": 0.8,
		"action_qualified": true,
		"rig_id": str(rig.rig_id),
		"rig_type": "sabiki" if rig.rig_type == BoatFishingRigProfile.RigType.SABIKI else "single_jig",
		"rig_compatible_species_ids": rig.compatible_species_ids,
		"rig_compatible_lure_tags": rig.compatible_lure_tags,
		"hook_index": hook_index,
		"fishing_session_id": str(encounter.get_boat_fishing_session_snapshot().get("fishing_session_id", "")),
		"cast_session_id": str(encounter.get_boat_fishing_session_snapshot().get("cast_session_id", "")),
	}


func _test_first_drop_and_open_water_ambient(encounter: FishingEncounterSystem, manager: FakeAmbientAuthorityManager) -> void:
	manager.schools.clear()
	var session := _start_session(encounter, SABIKI_RIG)
	var first_drop: Dictionary = session.get("first_drop", {})
	_check(bool(first_drop.get("accepted", false)) and float(first_drop.get("initial_search_radius_m", 0.0)) == 15.0, "first-drop search records the configured 15 m diagnostic radius")
	_check(manager.last_search_position == Vector3(123.0, -1.5, 456.0) and manager.last_search_radius == 15.0 and int(first_drop.get("initial_candidate_school_count", -1)) == 0, "initial school search is anchored to first entry and does not invent a school")
	var evaluation := encounter.evaluate_boat_fishing_candidates(Vector3(10.0, -1.5, 20.0), 1.5, 0.0, SABIKI_RIG, false, 0)
	_check(evaluation.get("candidate_schools", []).is_empty() and str(evaluation.get("trigger_mode", "")) == "AMBIENT_ENCOUNTER", "no real school within 50 m still permits Authority-filtered ambient eligibility")
	_check(is_equal_approx(float(evaluation.get("ambient_event_rate_per_real_hour", 0.0)), 2.0) and is_equal_approx(float(evaluation.get("average_wait_seconds", 0.0)), 1800.0), "ordinary suitable water starts at 2 events per real hour, about a 30 minute mean")
	var hazard_eval := evaluation.duplicate(true)
	encounter.set("_boat_ambient_hazard_accumulated", 0.0)
	encounter.set("_boat_ambient_hazard_threshold", 0.1)
	var trigger := encounter.advance_boat_fishing_ambient_hazard([hazard_eval], 1800.0)
	_check(str(trigger.get("phase", "")) == "triggered" and str(trigger.get("trigger_mode", "")) == "AMBIENT_ENCOUNTER", "real-time cumulative hazard can fire without any nearby school")
	var trigger_context: Dictionary = trigger.get("ambient_context", {}).duplicate(true)
	var stale_cast_context := trigger_context.duplicate(true)
	stale_cast_context["cast_session_id"] = "stale_cast_session"
	var stale_request := encounter.request_ambient_boat_fishing_catch(stale_cast_context, SABIKI_RIG)
	_check(not bool(stale_request.get("accepted", false)) and str(stale_request.get("reason", "")) == "ambient_session_or_hook_mismatch", "ambient requests from a previous cast cannot reserve a fish")
	var requested := encounter.request_ambient_boat_fishing_catch(trigger_context, SABIKI_RIG)
	_check(bool(requested.get("accepted", false)), "Authority creates a legitimate ambient fish after the hazard fires")
	var pending := requested.get("pending") as FishingPendingCatch
	var candidate: Dictionary = requested.get("candidate", {})
	_check(pending != null and pending.source_type == "ambient" and pending.school_id.is_empty() and not pending.ambient_fish_id.is_empty() and pending.body_length_m >= HERRING_PROFILE.body_length_range_m.x and pending.body_length_m <= HERRING_PROFILE.body_length_range_m.y, "ambient catch keeps unique Authority identity, legal species size, and no fabricated School ID")
	if pending != null:
		encounter.confirm_sabiki_hook(pending.catch_id)
	var active: Array[Dictionary] = encounter.get_boat_fishing_ambient_catch_snapshots()
	_check(active.size() == 1 and str(active[0].get("source_type", "")) == "ambient" and str(active[0].get("lifecycle_state", "")) == "hooked", "Authority snapshot exposes the pending natural individual and its reservation state")
	_check(manager.schools.is_empty(), "ordinary ambient encounter does not mutate the unrelated school ledger")
	encounter.cancel_sabiki_catches("ambient_cancel_test")
	_check(manager.ambient_fish.is_empty() and manager.schools.is_empty(), "cancelled ambient fish releases Authority state without consuming population")


func _test_target_priority_and_switching(encounter: FishingEncounterSystem, manager: FakeAmbientAuthorityManager) -> void:
	_start_session(encounter, SABIKI_RIG)
	manager.schools["target_herring"] = {
		"school_id": "target_herring", "species_id": "herring", "world_position": [0.5, 0.0, 0.0],
		"population": 8, "resource_state": "available", "effective_activity_depth_m": 1.5,
		"effective_activity_depth_target_m": 1.5, "activity_depth_m": 1.5,
		"effective_surface_activity_state": "near_surface", "surface_activity_state": "near_surface",
	}
	var hook := Vector3(0.0, -1.5, 0.0)
	var targeted := encounter.evaluate_boat_fishing_candidates(hook, 1.5, 0.0, SABIKI_RIG, false, 0)
	_check(str(targeted.get("trigger_mode", "")) == "SCHOOL_TARGETED" and targeted.get("ambient_candidates", []).is_empty(), "a hook in a compatible school's 3D target area never accrues ambient hazard")
	encounter.set("_boat_ambient_hazard_accumulated", 0.4)
	encounter.set("_boat_ambient_mode_active", true)
	var target_trigger := encounter.advance_boat_fishing_trigger_for_hook(targeted, 0.5, 0)
	var switched := encounter.advance_boat_fishing_ambient_hazard([targeted], 0.5)
	_check(str(target_trigger.get("trigger_mode", "")) == "SCHOOL_TARGETED" and float(switched.get("hazard_accumulated", -1.0)) == 0.0, "entering a targeted school clears stale ambient hazard instead of mixing modes")
	manager.schools.clear()
	manager.schools["incompatible_trout"] = {
		"school_id": "incompatible_trout", "species_id": "sea_trout", "world_position": [0.05, 0.0, 0.0],
		"population": 3, "resource_state": "available", "effective_activity_depth_m": 1.5,
		"activity_depth_m": 1.5, "surface_activity_state": "near_surface",
	}
	var blocked := encounter.evaluate_boat_fishing_candidates(hook, 1.5, 0.0, SABIKI_RIG, false, 1)
	_check(str(blocked.get("trigger_mode", "")) == "BLOCKED" and bool(blocked.get("ambient_blocked_by_school", false)) and blocked.get("ambient_candidates", []).is_empty(), "an in-volume but incompatible school blocks ambient generation from bypassing rig eligibility")
	manager.schools.clear()


func _test_shared_sabiki_hazard(encounter: FishingEncounterSystem, _manager: FakeAmbientAuthorityManager) -> void:
	_start_session(encounter, SABIKI_RIG)
	var evaluations: Array[Dictionary] = []
	for hook_index in range(SABIKI_RIG.hook_count):
		var context_position := Vector3(5.0 + float(hook_index) * 0.1, -1.5, 15.0)
		var evaluated := encounter.evaluate_boat_fishing_candidates(context_position, 1.5, 0.0, SABIKI_RIG, false, hook_index)
		evaluated["ambient_context"]["fishing_session_id"] = str(encounter.get_boat_fishing_session_snapshot().get("fishing_session_id", ""))
		evaluated["ambient_context"]["cast_session_id"] = str(encounter.get_boat_fishing_session_snapshot().get("cast_session_id", ""))
		evaluations.append(evaluated)
	var one_hook := encounter.advance_boat_fishing_ambient_hazard([evaluations[0]], 900.0)
	var one_progress := float(one_hook.get("hazard_accumulated", -1.0))
	var one_rate := float(one_hook.get("ambient_event_rate_per_real_hour", 0.0))
	encounter.set("_boat_ambient_hazard_accumulated", 0.0)
	encounter.set("_boat_ambient_hazard_threshold", 99.0)
	var five_hooks := encounter.advance_boat_fishing_ambient_hazard(evaluations, 900.0)
	_check(evaluations.size() == SABIKI_RIG.hook_count and is_equal_approx(float(five_hooks.get("ambient_event_rate_per_real_hour", 0.0)), one_rate), "Sabiki's shared ambient rate does not multiply by five hooks")
	_check(is_equal_approx(float(five_hooks.get("hazard_accumulated", -1.0)), one_progress) and int(five_hooks.get("eligible_hook_count", 0)) == SABIKI_RIG.hook_count, "five empty eligible hooks advance one shared hazard accumulator exactly once")
	var mixed := evaluations.duplicate()
	mixed[0] = evaluations[0].duplicate(true)
	mixed[0]["trigger_locked"] = true
	var mixed_result := encounter.advance_boat_fishing_ambient_hazard(mixed, 30.0)
	_check(float(mixed_result.get("ambient_event_rate_per_real_hour", 0.0)) == one_rate and int(mixed_result.get("eligible_hook_count", 0)) == SABIKI_RIG.hook_count - 1, "a targeted/approaching hook is excluded while other Sabiki hooks share the same ambient rate")


func _test_single_ambient_lifecycle(encounter: FishingEncounterSystem, manager: FakeAmbientAuthorityManager) -> void:
	_start_session(encounter, SINGLE_JIG)
	var context := _ambient_context(encounter, 0, SINGLE_JIG)
	var requested := encounter.request_ambient_boat_fishing_catch(context, SINGLE_JIG)
	var pending := requested.get("pending") as FishingPendingCatch
	_check(bool(requested.get("accepted", false)) and pending != null and pending.source_type == "ambient" and encounter.state == FishingEncounterSystem.State.BOAT_BITE_APPROACH, "Single Jig ambient fish enters the existing bite-approach state")
	var ambient_id := pending.ambient_fish_id if pending != null else ""
	_check(encounter.confirm_boat_fishing_bite() and manager.get_ambient_fish_encounter(ambient_id).get("lifecycle_state", "") == "hooked", "single ambient individual confirms through the existing hook event")
	var started := encounter.begin_retrieval()
	var result := encounter.complete_retrieval(pending.catch_id if pending != null else "") if started else {"accepted": false}
	var catch_result: Dictionary = result.get("result", {})
	_check(bool(result.get("accepted", false)) and str(catch_result.get("source_type", "")) == "ambient" and str(catch_result.get("school_id", "ambient")) == "" and catch_result.get("ambient_fish_id", "") == ambient_id, "ambient fish settles through the normal catch result without decrementing a school")
	_check(manager.settled_ambient.has(ambient_id) and manager.ambient_fish.is_empty() and manager.schools.is_empty(), "successful ambient settlement consumes its temporary Authority record exactly once")


func _test_mixed_sabiki_settlement_and_cancel(encounter: FishingEncounterSystem, manager: FakeAmbientAuthorityManager) -> void:
	_start_session(encounter, SABIKI_RIG)
	manager.schools["mixed_herring"] = {
		"school_id": "mixed_herring", "species_id": "herring", "world_position": [4.0, 0.0, 0.0],
		"population": 3, "resource_state": "available",
	}
	var school_candidate := {"school_id": "mixed_herring", "species_id": "herring", "population": 3, "activity_depth_m": 1.5}
	var school_pending := encounter.reserve_sabiki_hook(school_candidate, SABIKI_RIG, 0)
	var ambient_context := _ambient_context(encounter, 1, SABIKI_RIG, Vector3(8.0, -1.5, 15.0))
	var ambient_request := encounter.request_ambient_boat_fishing_catch(ambient_context, SABIKI_RIG)
	var ambient_pending := ambient_request.get("pending") as FishingPendingCatch
	var confirmed_school := school_pending != null and encounter.confirm_sabiki_hook(school_pending.catch_id)
	var confirmed_ambient := ambient_pending != null and encounter.confirm_sabiki_hook(ambient_pending.catch_id)
	var representative := encounter.begin_sabiki_batch_retrieval()
	var retrieval_started := representative != null and encounter.begin_retrieval()
	var settlement := encounter.complete_retrieval(representative.catch_id) if retrieval_started and representative != null else {"accepted": false}
	var results: Array = settlement.get("results", [])
	_check(confirmed_school and confirmed_ambient and bool(settlement.get("accepted", false)) and results.size() == 2, "Sabiki can settle one school fish and one ambient fish in one atomic batch")
	_check(int(manager.get_school("mixed_herring").get("population", 0)) == 2 and manager.school_batch_calls == 1, "mixed batch decrements only its one real school fish exactly once")
	var sources: Dictionary = {}
	for result_variant in results:
		var result := result_variant as Dictionary
		sources[str(result.get("source_type", ""))] = true
	_check(sources.has("school") and sources.has("ambient") and manager.settled_ambient.has(ambient_pending.ambient_fish_id), "batch results preserve both origins and mark the temporary Authority fish settled")

	var release_context := _ambient_context(encounter, 3, SABIKI_RIG, Vector3(20.0, -1.5, 15.0))
	var release_request := encounter.request_ambient_boat_fishing_catch(release_context, SABIKI_RIG)
	var release_pending := release_request.get("pending") as FishingPendingCatch
	var release_id := release_pending.ambient_fish_id if release_pending != null else ""
	var had_reservation := release_pending != null and manager.ambient_fish.has(release_id)
	encounter.cancel_sabiki_catches("test_release")
	_check(had_reservation and not manager.ambient_fish.has(release_id) and not manager.settled_ambient.has(release_id), "cancelled Sabiki ambient reservation releases the temporary fish without settlement")


func _test_live_local_authority_ambient() -> void:
	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	for _frame in range(30):
		await process_frame
	var manager := main.find_child("FishResourceManager", true, false) as FishResourceManager
	var bathymetry := main.find_child("BathymetryManager", true, false) as BathymetryManager
	var wave_sampler := main.find_child("WaveSampler", true, false) as WaveSampler
	var boat := manager.get_boat() if manager != null else null
	_check(manager != null and bathymetry != null and boat != null, "main scene creates the real local Authority and bathymetry needed for ambient validation")	
	if manager == null or bathymetry == null or boat == null:
		await _free_main(main)
		return
	var chosen_position := Vector3.ZERO
	var chosen_context: Dictionary = {}
	var chosen_evaluation: Dictionary = {}
	var found_open_water := false
	for radius in [90.0, 140.0, 210.0, 300.0, 430.0, 600.0, 850.0, 1150.0, 1550.0, 2100.0, 2800.0]:
		for sector in range(12):
			var angle := TAU * float(sector) / 12.0
			var position := boat.global_position + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			var seabed: Dictionary = bathymetry.get_depth_at_world_position(position)
			if not bool(seabed.get("valid", false)) or manager.get_schools_near(position, 50.0, true).size() > 0:
				continue
			var surface_y := position.y
			if wave_sampler != null:
				var wave_time := wave_sampler.get_effective_wave_time_seconds()
				var surface: Dictionary = wave_sampler.sample_physics_surface(position, wave_time)
				if bool(surface.get("valid", true)):
					surface_y = float(surface.get("height", surface_y))
			var water_column := maxf(0.0, float(seabed.get("depth_m", 0.0)) + surface_y)
			if water_column < HERRING_PROFILE.minimum_water_column_m:
				continue
			var hook_depth := 1.5
			var hook_position := Vector3(position.x, surface_y - hook_depth, position.z)
			var context := {
				"hook_world_position": hook_position,
				"hook_depth_m": hook_depth,
				"water_column_m": water_column,
				"relative_speed_mps": 0.0,
				"action_weight": 0.8,
				"action_qualified": true,
				"rig_id": str(SABIKI_RIG.rig_id),
				"rig_type": "sabiki",
				"rig_compatible_species_ids": SABIKI_RIG.compatible_species_ids,
				"rig_compatible_lure_tags": SABIKI_RIG.compatible_lure_tags,
				"hook_index": 0,
				"fishing_session_id": "live_authority_test",
				"cast_session_id": "live_authority_test_cast",
				"ambient_spawn_direction": position - boat.global_position,
			}
			var evaluation := manager.evaluate_ambient_fishing_candidates(context)
			if not evaluation.get("candidates", []).is_empty():
				chosen_position = position
				chosen_context = context
				chosen_evaluation = evaluation
				found_open_water = true
				break
		if found_open_water:
			break
	_check(found_open_water, "real Authority finds legal ambient species in open water with no school within 50 m")
	if not found_open_water:
		await _free_main(main)
		return
	var population_before := _total_population(manager)
	var evaluation_candidates: Array = chosen_evaluation.get("candidates", [])
	_check(evaluation_candidates.size() == 1 and str(evaluation_candidates[0].get("species_id", "")) == "herring", "Sabiki Authority candidate filtering respects its configured Herring species ID")
	var request := manager.request_ambient_fish_encounter(chosen_context)
	var fish: Dictionary = request.get("fish", {})
	var ambient_id := str(fish.get("ambient_fish_id", ""))
	_check(bool(request.get("accepted", false)) and not ambient_id.is_empty() and str(fish.get("source_type", "")) == "ambient" and str(fish.get("species_id", "")) == "herring", "Local Authority creates one legal temporary Herring identity without a school ID")
	var length_m := float(fish.get("body_length_m", 0.0))
	_check(length_m >= HERRING_PROFILE.body_length_range_m.x and length_m <= HERRING_PROFILE.body_length_range_m.y, "Local Authority rolls individual size from the configured Herring length range")
	if bool(request.get("accepted", false)):
		var confirmed := manager.confirm_ambient_fish_encounter(ambient_id, "live_authority_test", 0)
		var settled := manager.settle_ambient_fish_encounter(ambient_id)
		_check(confirmed and bool(settled.get("accepted", false)), "real Authority temporary fish follows reserved → hooked → settled lifecycle")
		_check(not bool(manager.settle_ambient_fish_encounter(ambient_id).get("accepted", false)), "real Authority rejects a duplicate ambient settlement")
	_check(_total_population(manager) == population_before and manager.get_schools_near(chosen_position, 50.0, true).is_empty(), "ambient capture leaves all real school populations unchanged and creates no School ID")
	await _test_live_ambient_cast_pipeline(main, manager, bathymetry, wave_sampler, boat as Node3D)
	await _free_main(main)


func _test_live_ambient_cast_pipeline(main: Node, manager: FishResourceManager, bathymetry: BathymetryManager, wave_sampler: WaveSampler, boat: Node3D) -> void:
	var casting := main.find_child("BoatFishingCastingSystem", true, false) as BoatFishingCastingSystem
	var activities_button := main.find_child("ActivitiesButton", true, false) as Button
	var fishing_button := main.find_child("OpenBoatFishingActivity", true, false) as Button
	if casting == null or activities_button == null or fishing_button == null or boat == null:
		_check(false, "live boat-fishing controls are available for the ambient end-to-end path")
		return
	activities_button.pressed.emit()
	fishing_button.pressed.emit()
	await process_frame
	_check(casting.is_activity_active() and casting.select_rig(&"single_jig"), "live Boat Fishing enters Single Jig mode for an ambient encounter")
	if not casting.is_activity_active():
		return
	var encounter := manager.get_fishing_encounter_system()
	var school_population_before := _total_population(manager)
	var origin := boat.global_position
	var fixture: Dictionary = {}
	for radius in [90.0, 140.0, 210.0, 300.0, 430.0, 600.0, 850.0, 1150.0, 1550.0, 2100.0, 2800.0]:
		for sector in range(12):
			var angle := TAU * float(sector) / 12.0
			var position := origin + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			if not manager.get_schools_near(position, 50.0, true).is_empty():
				continue
			var seabed := bathymetry.get_depth_at_world_position(position)
			if not bool(seabed.get("valid", false)):
				continue
			var surface_y := position.y
			if wave_sampler != null:
				var surface := wave_sampler.sample_physics_surface(position, wave_sampler.get_effective_wave_time_seconds())
				if bool(surface.get("valid", true)):
					surface_y = float(surface.get("height", surface_y))
			var water_column := maxf(0.0, float(seabed.get("depth_m", 0.0)) + surface_y)
			for depth_m in [1.5, 2.5, 4.0, 7.5, 10.0]:
				var hook_position := Vector3(position.x, surface_y - float(depth_m), position.z)
				var context := {
					"hook_world_position": hook_position,
					"hook_depth_m": float(depth_m),
					"water_column_m": water_column,
					"relative_speed_mps": 0.8,
					"action_weight": FishingEncounterSystem.boat_fishing_action_weight(0.8),
					"action_qualified": true,
					"rig_id": str(SINGLE_JIG.rig_id),
					"rig_type": "single_jig",
					"rig_compatible_species_ids": SINGLE_JIG.compatible_species_ids,
					"rig_compatible_lure_tags": SINGLE_JIG.compatible_lure_tags,
					"hook_index": 0,
				}
				var evaluated := manager.evaluate_ambient_fishing_candidates(context)
				if not evaluated.get("candidates", []).is_empty():
					fixture = {"position": position, "surface_y": surface_y, "depth_m": depth_m}
					break
			if not fixture.is_empty():
				break
		if not fixture.is_empty():
			break
	_check(not fixture.is_empty(), "real Authority finds Single Jig-compatible ambient fish in school-free water")
	if fixture.is_empty():
		casting.end_activity()
		return
	var bait_position := Vector3(float((fixture["position"] as Vector3).x), float(fixture["surface_y"]) - float(fixture["depth_m"]), float((fixture["position"] as Vector3).z))
	boat.global_position = Vector3(bait_position.x - 4.0, boat.global_position.y, bait_position.z)
	casting.set("_bait_world", bait_position)
	casting.set("_bait_velocity_world", Vector3.ZERO)
	casting.set("_bait_has_landed", true)
	casting.set("_bait_flight_started", true)
	var rod_tip: Vector3 = casting.call("_get_rod_tip_world")
	casting.set("_line_paid_out_length_m", clampf(rod_tip.distance_to(bait_position), 1.0, casting.maximum_line_length_m))
	var onboard := casting.get("_onboard") as OnboardActivityController
	if onboard != null:
		onboard.set_movement_locked(true)
	casting.call("_set_state", BoatFishingCastingSystem.CastState.WAITING)
	casting.call("_record_boat_fishing_first_entry")
	var hook_position: Vector3 = casting.call("_get_single_jig_hook_attachment_world")
	var hook_depth := float(casting.call("_depth_below_surface_at", hook_position))
	var evaluation := encounter.evaluate_boat_fishing_candidates(hook_position, hook_depth, 0.8, SINGLE_JIG, false, 0)
	_check(evaluation.get("candidate_schools", []).is_empty() and not evaluation.get("ambient_candidates", []).is_empty() and str(evaluation.get("trigger_mode", "")) == "AMBIENT_ENCOUNTER", "live hook uses ambient candidates with no Authority school inside 50 m")
	if evaluation.get("ambient_candidates", []).is_empty():
		casting.end_activity()
		return
	casting.set_process(false)
	encounter.set("_boat_ambient_hazard_accumulated", 0.0)
	encounter.set("_boat_ambient_hazard_threshold", 0.000001)
	var trigger := encounter.advance_boat_fishing_ambient_hazard([evaluation], 1.0)
	var request := encounter.request_ambient_boat_fishing_catch(trigger.get("ambient_context", {}), SINGLE_JIG)
	encounter.set_boat_fishing_ambient_authority_result(request)
	var pending := request.get("pending") as FishingPendingCatch
	var bite_started := pending != null and bool(casting.call("_begin_bite_event", request.get("candidate", {}), false, false, pending))
	_check(str(trigger.get("phase", "")) == "triggered" and bool(request.get("accepted", false)) and bite_started and casting.get_casting_state() == BoatFishingCastingSystem.CastState.BITE_APPROACH, "Authority ambient fish enters the existing visible bite-approach state")
	if not bite_started:
		if pending != null:
			encounter.cancel_boat_fishing_catch("ambient_test_approach_failed")
		casting.end_activity()
		return
	var hooked_events: Array[String] = []
	var catch_results: Array[FishingCatchResult] = []
	encounter.fish_hooked.connect(func(fish_pending: FishingPendingCatch) -> void: hooked_events.append(fish_pending.catch_id))
	encounter.catch_succeeded.connect(func(result: FishingCatchResult) -> void: catch_results.append(result))
	casting.set("_bite_duration", 0.16)
	casting.set_process(true)
	for _frame in range(180):
		if casting.get_casting_state() != BoatFishingCastingSystem.CastState.BITE_APPROACH:
			break
		await process_frame
	await process_frame
	_check(hooked_events.size() == 1 and casting.get_casting_state() == BoatFishingCastingSystem.CastState.FIGHTING, "ambient fish reaches the hook and enters the normal player-controlled fight")
	var ambient_id := pending.ambient_fish_id
	var safe_minimum := float(casting.call("_get_fight_minimum_line_length_m"))
	casting.set("_line_paid_out_length_m", safe_minimum)
	casting.set_manual_reeling(true, true)
	casting.call("_advance_boat_fight", 0.016)
	casting.set_manual_reeling(false, true)
	for _frame in range(180):
		if not catch_results.is_empty():
			break
		await process_frame
	var settled := not catch_results.is_empty()
	_check(settled and catch_results[0].source_type == "ambient" and catch_results[0].school_id.is_empty() and catch_results[0].ambient_fish_id == ambient_id, "ambient fish completes normal landing settlement with its source identity preserved")
	_check(manager.get_ambient_fish_encounter(ambient_id).is_empty() and _total_population(manager) == school_population_before, "settled ambient Authority record is removed without a school debit")
	casting.end_activity()


func _total_population(manager: FishResourceManager) -> int:
	var total := 0
	for school in manager.get_all_school_snapshots():
		total += int(school.get("population", 0))
	return total


func _free_main(main: Node) -> void:
	if is_instance_valid(main):
		main.queue_free()
	await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[P6.4.5.2] " + message)
