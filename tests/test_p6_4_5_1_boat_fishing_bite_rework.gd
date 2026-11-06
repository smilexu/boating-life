extends SceneTree

const SABIKI_RIG: BoatFishingRigProfile = preload("res://resources/boat_fishing/sabiki_rig.tres")
const SINGLE_JIG: BoatFishingRigProfile = preload("res://resources/boat_fishing/single_jig.tres")
const HERRING_PROFILE: FishSpeciesProfile = preload("res://resources/fish_species/herring.tres")
const SEA_TROUT_PROFILE: FishSpeciesProfile = preload("res://resources/fish_species/sea_trout.tres")


class FakeFishingManager extends Node:
	var profiles: Dictionary = {}
	var schools: Dictionary = {}
	var last_query_radius_m := 0.0

	func get_species_profile(species_id: String) -> FishSpeciesProfile:
		return profiles.get(species_id) as FishSpeciesProfile

	func get_world_seed() -> int:
		return 194205

	func get_world_game_time_seconds() -> float:
		return 0.0

	func set_school(school_id: String, species_id: String, position: Vector3, depth_m: float, population: int) -> void:
		schools[school_id] = {
			"school_id": school_id,
			"species_id": species_id,
			"world_position": [position.x, position.y, position.z],
			"population": population,
			"resource_state": "available" if population > 0 else "depleted",
			"effective_activity_depth_m": depth_m,
			"activity_depth_m": depth_m,
			"effective_activity_depth_target_m": depth_m,
			"surface_activity_state": "near_surface",
			"effective_surface_activity_state": "near_surface",
		}

	func get_school(school_id: String) -> Dictionary:
		return (schools.get(school_id, {}) as Dictionary).duplicate(true)

	func get_schools_near(position: Vector3, radius_m: float, include_unavailable: bool = false) -> Array[Dictionary]:
		last_query_radius_m = radius_m
		var result: Array[Dictionary] = []
		for value in schools.values():
			var school: Dictionary = value
			if not include_unavailable and (int(school.get("population", 0)) <= 0 or str(school.get("resource_state", "available")) != "available"):
				continue
			var p: Array = school.get("world_position", [])
			if p.size() < 3:
				continue
			var dx := float(p[0]) - position.x
			var dz := float(p[2]) - position.z
			if dx * dx + dz * dz <= radius_m * radius_m:
				result.append(school.duplicate(true))
		return result

	func evaluate_ambient_fishing_candidates(context: Dictionary) -> Dictionary:
		var rig_type := str(context.get("rig_type", ""))
		var hook_depth := float(context.get("hook_depth_m", 0.0))
		if not bool(context.get("action_qualified", false)):
			return {"candidates": [], "reason": "action_requirement_not_met", "environment_quality": 0.0}
		var candidates: Array[Dictionary] = []
		for species_id in profiles:
			var profile := profiles[species_id] as FishSpeciesProfile
			if profile == null or not profile.supported_fishing_methods.has("boat_fishing"):
				continue
			var species_ids: Array = context.get("rig_compatible_species_ids", [])
			var tags: Array = context.get("rig_compatible_lure_tags", [])
			var compatible := species_ids.has(species_id) if not species_ids.is_empty() else false
			if species_ids.is_empty():
				for tag in tags:
					compatible = compatible or profile.compatible_lure_tags.has(tag)
			if not compatible:
				continue
			var depth_compatible := true
			if profile.surface_activity_cycle_enabled:
				depth_compatible = (hook_depth >= profile.surface_activity_depth_m.x and hook_depth <= profile.surface_activity_depth_m.y) or (hook_depth >= profile.deep_activity_depth_m.x and hook_depth <= profile.deep_activity_depth_m.y)
			if not depth_compatible:
				continue
			candidates.append({"species_id": species_id, "ecological_weight": maxf(profile.spawn_chance, 0.001), "environment_quality": 1.0, "hook_depth_m": hook_depth})
		if candidates.is_empty():
			return {"candidates": [], "reason": "activity_depth_mismatch", "environment_quality": 0.0}
		return {"candidates": candidates, "reason": "ambient_species_available", "environment_quality": 1.0}


var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager := FakeFishingManager.new()
	manager.profiles = {"herring": HERRING_PROFILE, "sea_trout": SEA_TROUT_PROFILE}
	root.add_child(manager)
	var encounter := FishingEncounterSystem.new()
	root.add_child(encounter)
	encounter.configure(manager, null)
	encounter.set_process(false)
	encounter.begin_boat_fishing_session()
	_test_core_edge_and_ambient_modes(encounter, manager)
	_test_depth_action_and_query_limits(encounter, manager)
	_test_sabiki_hook_independence_and_population_limit(encounter, manager)
	_test_ambient_real_time_and_mode_reset(encounter, manager)
	_test_authority_bite_willingness(encounter, manager)
	encounter.queue_free()
	manager.queue_free()
	await process_frame
	print("[P6.4.5.1] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _test_core_edge_and_ambient_modes(encounter: FishingEncounterSystem, manager: FakeFishingManager) -> void:
	var origin := Vector3(0.0, -1.6, 0.0)
	manager.schools.clear()
	manager.set_school("herring_core", "herring", Vector3(1.0, 0.0, 0.0), 1.6, 40)
	var core := encounter.evaluate_boat_fishing_candidates(origin, 1.6, 0.0, SABIKI_RIG, false, 0)
	_check(manager.last_query_radius_m == 50.0, "natural boat-fishing school query remains capped at 50 m")
	_check(str(core.get("trigger_mode", "")) == "SCHOOL_TARGETED", "a compatible herring school in the 3D core selects targeted mode")
	var core_candidate: Dictionary = core.get("school_targeted_candidates", [])[0] if not core.get("school_targeted_candidates", []).is_empty() else {}
	_check(str(core_candidate.get("school_zone", "")) == "core" and float(core_candidate.get("normalized_3d_distance", 9.0)) <= 0.5, "core classification uses species-scale 3D distance")
	encounter.reset_boat_fishing_trigger_state()
	var core_trigger := _advance_until_trigger(encounter, core, 0, 24)
	_check(str(core_trigger.get("trigger_mode", "")) == "SCHOOL_TARGETED" and not (core_trigger.get("candidate", {}) as Dictionary).is_empty(), "core candidate starts a bite without a random hazard roll")
	var core_total := float(core_trigger.get("reaction_total_seconds", -1.0))
	var core_approach := float(core_trigger.get("visual_approach_estimate_seconds", -1.0))
	_check(core_total >= 2.0 and core_total <= 10.0 and core_approach > 0.0, "target response time interpolates continuously across the pursuit sphere and estimates physical swim time")

	manager.schools.clear()
	manager.set_school("herring_edge", "herring", Vector3(2.16, 0.0, 0.0), 1.6, 40)
	var edge := encounter.evaluate_boat_fishing_candidates(origin, 1.6, 0.0, SABIKI_RIG, false, 1)
	var edge_candidate: Dictionary = edge.get("school_targeted_candidates", [])[0] if not edge.get("school_targeted_candidates", []).is_empty() else {}
	_check(str(edge.get("trigger_mode", "")) == "SCHOOL_TARGETED" and str(edge_candidate.get("school_zone", "")) == "edge", "a compatible school near its per-species boundary remains targeted")
	encounter.reset_boat_fishing_trigger_state()
	var edge_trigger := _advance_until_trigger(encounter, edge, 1, 24)
	var edge_total := float(edge_trigger.get("reaction_total_seconds", -1.0))
	_check(str(edge_trigger.get("trigger_mode", "")) == "SCHOOL_TARGETED" and edge_total >= 2.0 and edge_total <= 10.0, "pursuit response remains within continuous near-to-edge bounds")

	manager.schools.clear()
	manager.schools.clear()
	var ambient := encounter.evaluate_boat_fishing_candidates(origin, 1.6, 0.0, SABIKI_RIG, false, 0)
	var ambient_rate := float(ambient.get("ambient_event_rate_per_real_hour", 0.0))
	_check(str(ambient.get("trigger_mode", "")) == "AMBIENT_ENCOUNTER" and ambient.get("candidate_schools", []).is_empty() and ambient_rate > 0.0 and ambient_rate <= 3.0, "open water with no nearby school uses the capped low-probability ambient mode")
	_check(float(ambient.get("average_wait_seconds", 0.0)) >= 1200.0, "ambient mean wait stays at least 20 real minutes in the best single-school case")

	manager.schools.clear()
	manager.set_school("herring_core", "herring", Vector3(1.0, 0.0, 0.0), 1.6, 40)
	manager.set_school("herring_ambient", "herring", Vector3(12.0, 0.0, 0.0), 1.6, 40)
	var priority := encounter.evaluate_boat_fishing_candidates(origin, 1.6, 0.0, SABIKI_RIG, false, 0)
	_check(str(priority.get("trigger_mode", "")) == "SCHOOL_TARGETED" and float(priority.get("total_event_rate_per_real_hour", -1.0)) == 0.0, "targeted school mode takes priority and does not accrue ambient hazard at the same time")


func _test_depth_action_and_query_limits(encounter: FishingEncounterSystem, manager: FakeFishingManager) -> void:
	var origin := Vector3.ZERO
	manager.schools.clear()
	manager.set_school("herring_wrong_depth", "herring", Vector3(1.0, 0.0, 0.0), 1.6, 20)
	var wrong_depth := encounter.evaluate_boat_fishing_candidates(origin, 7.0, 0.0, SABIKI_RIG)
	_check(int(wrong_depth.get("targeted_candidate_count", 0)) == 0 and float(wrong_depth.get("ambient_event_rate_per_real_hour", 0.0)) == 0.0, "wrong depth blocks both targeted bites and ambient source selection")
	_check(str(wrong_depth.get("reason", "")) == "activity_depth_mismatch", "F3 reason identifies water-layer mismatch")

	manager.schools.clear()
	manager.set_school("herring_action", "herring", Vector3(1.0, 0.0, 0.0), 1.6, 20)
	var no_jig_motion := encounter.evaluate_boat_fishing_candidates(origin, 1.6, 0.0, SINGLE_JIG)
	_check(int(no_jig_motion.get("targeted_candidate_count", 0)) == 0 and str(no_jig_motion.get("reason", "")) in ["method_or_rig_mismatch", "school_target_zone_blocked"], "incompatible Herring cannot be targeted or randomly bypassed by Single Jig inside its school zone")
	manager.set_school("trout_action", "sea_trout", Vector3(1.0, 0.0, 0.0), 2.0, 8)
	var stationary_jig := encounter.evaluate_boat_fishing_candidates(origin, 2.0, 0.0, SINGLE_JIG)
	var moving_jig := encounter.evaluate_boat_fishing_candidates(origin, 2.0, 0.2, SINGLE_JIG)
	_check(int(stationary_jig.get("targeted_candidate_count", 0)) == 0, "stationary Single Jig does not enter high-certainty targeted mode")
	_check(int(moving_jig.get("targeted_candidate_count", 0)) == 1, "compatible Single Jig motion satisfies the minimal targeted action condition")

	manager.schools.clear()
	manager.set_school("too_far", "herring", Vector3(55.0, 0.0, 0.0), 1.6, 20)
	var outside := encounter.evaluate_boat_fishing_candidates(origin, 1.6, 0.0, SABIKI_RIG)
	_check(int(outside.get("candidate_school_count", 0)) == 0 and manager.last_query_radius_m == 50.0, "schools beyond 50 m cannot enter either natural mode")


func _test_sabiki_hook_independence_and_population_limit(encounter: FishingEncounterSystem, manager: FakeFishingManager) -> void:
	var origin := Vector3(0.0, -1.6, 0.0)
	manager.schools.clear()
	manager.set_school("herring_small_school", "herring", Vector3(1.0, 0.0, 0.0), 1.6, 2)
	var hook_one := encounter.evaluate_boat_fishing_candidates(origin, 1.6, 0.0, SABIKI_RIG, false, 0)
	var hook_three := encounter.evaluate_boat_fishing_candidates(origin + Vector3(14.5, 0.0, 0.0), 1.6, 0.0, SABIKI_RIG, false, 2)
	_check(int(hook_one.get("targeted_candidate_count", 0)) == 1 and int(hook_three.get("targeted_candidate_count", 0)) == 0, "Sabiki hooks independently classify their real positions against the species pursuit sphere")
	var candidate: Dictionary = hook_one.get("school_targeted_candidates", [])[0]
	var first := encounter.reserve_sabiki_hook(candidate, SABIKI_RIG, 0)
	var second := encounter.reserve_sabiki_hook(candidate, SABIKI_RIG, 1)
	var third := encounter.reserve_sabiki_hook(candidate, SABIKI_RIG, 2)
	_check(first != null and second != null and third == null, "two available Authority fish reserve only two Sabiki hooks")
	var after_reservations := encounter.evaluate_boat_fishing_candidates(origin, 1.6, 0.0, SABIKI_RIG, false, 3)
	_check(int(after_reservations.get("targeted_candidate_count", 0)) == 0, "reserved fish are removed from the remaining hooks' targeted candidates")
	if first != null:
		encounter.release_sabiki_reservation(first.catch_id)
	if second != null:
		encounter.release_sabiki_reservation(second.catch_id)


func _test_ambient_real_time_and_mode_reset(encounter: FishingEncounterSystem, manager: FakeFishingManager) -> void:
	manager.schools.clear()
	var origin := Vector3(0.0, -1.6, 0.0)
	var evaluation := encounter.evaluate_boat_fishing_candidates(origin, 1.6, 0.0, SABIKI_RIG, false, 0)
	var rate := float(evaluation.get("ambient_event_rate_per_real_hour", 0.0))
	encounter.set("_boat_ambient_hazard_threshold", 100.0)
	encounter.set("_boat_ambient_hazard_accumulated", 0.0)
	var accumulated := encounter.advance_boat_fishing_ambient_hazard([evaluation], 0.5)
	_check(is_equal_approx(float(accumulated.get("hazard_accumulated", 0.0)), rate * 0.5 / 3600.0), "shared ambient hazard uses real elapsed seconds")
	manager.set_school("target_herring", "herring", Vector3(1.0, 0.0, 0.0), 1.6, 40)
	var targeted := encounter.evaluate_boat_fishing_candidates(origin, 1.6, 0.0, SABIKI_RIG, false, 0)
	encounter.advance_boat_fishing_trigger_for_hook(targeted, 0.5, 0)
	var switched := encounter.advance_boat_fishing_ambient_hazard([targeted], 0.5)
	_check(is_equal_approx(float(switched.get("hazard_accumulated", -1.0)), 0.0), "switching to targeted mode clears ambient progress instead of combining hazards")


func _test_authority_bite_willingness(encounter: FishingEncounterSystem, manager: FakeFishingManager) -> void:
	for multiplier in [0.80, 0.25]:
		manager.schools.clear()
		manager.set_school("herring_disturbance", "herring", Vector3(1.0, 0.0, 0.0), 10.0, 40)
		var school: Dictionary = manager.schools["herring_disturbance"]
		school["disturbance_state"] = "ALERT" if is_equal_approx(float(multiplier), 0.80) else "FLEEING"
		school["bite_willingness_multiplier"] = multiplier
		manager.schools["herring_disturbance"] = school
		var evaluation := encounter.evaluate_boat_fishing_candidates(Vector3(0.0, -10.0, 0.0), 10.0, 0.0, SABIKI_RIG, false, 0)
		encounter.reset_boat_fishing_trigger_state()
		var snapshot := encounter.advance_boat_fishing_trigger_for_hook(evaluation, 0.1, 0)
		var progress := float(snapshot.get("reaction_total_seconds", 0.0)) - float(snapshot.get("reaction_remaining_seconds", 0.0)) - float(snapshot.get("visual_approach_estimate_seconds", 0.0))
		_check(absf(progress - 0.1 * multiplier) < 0.01, "Authority bite willingness scales SCHOOL_TARGETED reaction progress exactly once")


func _advance_until_trigger(encounter: FishingEncounterSystem, evaluation: Dictionary, hook_index: int, max_samples: int) -> Dictionary:
	var snapshot: Dictionary = {}
	for _sample in range(max_samples):
		snapshot = encounter.advance_boat_fishing_trigger_for_hook(evaluation, 0.5, hook_index)
		if not (snapshot.get("candidate", {}) as Dictionary).is_empty():
			return snapshot
	return snapshot


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[P6.4.5.1] " + message)
