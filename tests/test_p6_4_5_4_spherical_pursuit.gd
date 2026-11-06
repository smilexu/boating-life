extends SceneTree

const SINGLE_JIG: BoatFishingRigProfile = preload("res://resources/boat_fishing/single_jig.tres")
const SEA_TROUT: FishSpeciesProfile = preload("res://resources/fish_species/sea_trout.tres")
const HERRING: FishSpeciesProfile = preload("res://resources/fish_species/herring.tres")
const NEEDLEFISH: FishSpeciesProfile = preload("res://resources/fish_species/needlefish.tres")
const CONTACT_RADIUS_M := 0.08


class FakeFishingManager extends Node:
	var profiles: Dictionary = {}
	var schools: Dictionary = {}
	var last_query_radius_m := 0.0

	func get_species_profile(species_id: String) -> FishSpeciesProfile:
		return profiles.get(species_id) as FishSpeciesProfile

	func get_world_seed() -> int:
		return 20261103

	func get_world_game_time_seconds() -> float:
		return 0.0

	func set_school(school_id: String, species_id: String, x: float, depth_m: float, population: int = 3) -> void:
		schools[school_id] = {
			"school_id": school_id,
			"species_id": species_id,
			"world_position": [x, 0.0, 0.0],
			"population": population,
			"resource_state": "available" if population > 0 else "depleted",
			"effective_activity_depth_m": depth_m,
			"activity_depth_m": depth_m,
			"effective_activity_depth_target_m": depth_m,
			"effective_surface_activity_state": "near_surface",
			"surface_activity_state": "near_surface",
		}

	func get_school(school_id: String) -> Dictionary:
		return (schools.get(school_id, {}) as Dictionary).duplicate(true)

	func get_schools_near(position: Vector3, radius_m: float, include_unavailable: bool = false) -> Array[Dictionary]:
		last_query_radius_m = radius_m
		var result: Array[Dictionary] = []
		for value in schools.values():
			var school: Dictionary = value
			if not include_unavailable and int(school.get("population", 0)) <= 0:
				continue
			var p: Array = school.get("world_position", [])
			if p.size() >= 3 and Vector2(float(p[0]) - position.x, float(p[2]) - position.z).length() <= radius_m:
				result.append(school.duplicate(true))
		return result


var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(is_equal_approx(HERRING.boat_fishing_pursuit_radius_m, 12.0), "Herring pursuit radius is configured to 12 m")
	_check(is_equal_approx(SEA_TROUT.boat_fishing_pursuit_radius_m, 16.0), "Sea Trout pursuit radius is configured to 16 m")
	_check(is_equal_approx(NEEDLEFISH.boat_fishing_pursuit_radius_m, 14.0), "Needlefish pursuit radius is configured to 14 m")
	var manager := FakeFishingManager.new()
	manager.profiles = {"sea_trout": SEA_TROUT, "herring": HERRING, "needlefish": NEEDLEFISH}
	root.add_child(manager)
	var encounter := FishingEncounterSystem.new()
	root.add_child(encounter)
	encounter.configure(manager, null)
	encounter.set_process(false)
	encounter.begin_boat_fishing_session()
	_test_spherical_eligibility(encounter, manager)
	_test_nine_meter_physical_approach(encounter, manager)
	_test_frame_rate_and_moving_target()
	encounter.queue_free()
	manager.queue_free()
	await process_frame
	print("[P6.4.5.4] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _test_spherical_eligibility(encounter: FishingEncounterSystem, manager: FakeFishingManager) -> void:
	var hook := Vector3(0.0, -2.0, 0.0)
	manager.set_school("trout_9m", "sea_trout", 9.0, 2.0)
	var nine := encounter.evaluate_boat_fishing_candidates(hook, 2.0, 0.2, SINGLE_JIG, false, 0)
	var nine_candidate: Dictionary = nine.get("candidate_schools", [])[0] if not nine.get("candidate_schools", []).is_empty() else {}
	_check(bool(nine_candidate.get("target_eligible", false)), "Sea Trout at 9 m is pursuit-eligible outside its old school ellipse")
	_check(not bool(nine_candidate.get("inside_school_volume", true)) and bool(nine_candidate.get("inside_pursuit_sphere", false)), "old ellipse remains diagnostic only while sphere qualifies the lure")
	_check(is_equal_approx(float(nine_candidate.get("pursuit_distance_m", -1.0)), 9.0), "pursuit distance is full 3D distance to the activity center")

	manager.schools.clear()
	manager.set_school("trout_15_9m", "sea_trout", 15.9, 2.0)
	var inside_edge := encounter.evaluate_boat_fishing_candidates(hook, 2.0, 0.2, SINGLE_JIG, false, 0)
	_check(int(inside_edge.get("targeted_candidate_count", 0)) == 1, "15.9 m remains inside the 16 m Sea Trout sphere")
	manager.schools.clear()
	manager.set_school("trout_16_1m", "sea_trout", 16.1, 2.0)
	var outside_edge := encounter.evaluate_boat_fishing_candidates(hook, 2.0, 0.2, SINGLE_JIG, false, 0)
	var outside_candidate: Dictionary = outside_edge.get("candidate_schools", [])[0] if not outside_edge.get("candidate_schools", []).is_empty() else {}
	_check(int(outside_edge.get("targeted_candidate_count", 0)) == 0 and str(outside_candidate.get("rejection_reason", "")) == "outside_pursuit_sphere", "16.1 m is rejected with an explicit outside-pursuit reason")

	manager.schools.clear()
	manager.set_school("trout_vertical", "sea_trout", 0.0, 1.6)
	var vertical_mismatch := encounter.evaluate_boat_fishing_candidates(Vector3(0.0, -18.6, 0.0), 18.6, 0.2, SINGLE_JIG, false, 0)
	var vertical_candidate: Dictionary = vertical_mismatch.get("candidate_schools", [])[0] if not vertical_mismatch.get("candidate_schools", []).is_empty() else {}
	_check(float(vertical_candidate.get("pursuit_distance_m", 0.0)) > SEA_TROUT.boat_fishing_pursuit_radius_m and int(vertical_mismatch.get("targeted_candidate_count", 0)) == 0, "17 m vertical separation is outside the same 3D pursuit sphere")
	_check(manager.last_query_radius_m == FishingEncounterSystem.BOAT_FISHING_MAX_HORIZONTAL_RANGE_M, "candidate discovery still uses the shared horizontal Authority query")
	manager.schools.clear()


func _test_nine_meter_physical_approach(encounter: FishingEncounterSystem, manager: FakeFishingManager) -> void:
	var hook := Vector3(0.0, -2.0, 0.0)
	manager.set_school("trout_pursuit", "sea_trout", 9.0, 2.0)
	var evaluation := encounter.evaluate_boat_fishing_candidates(hook, 2.0, 0.2, SINGLE_JIG, false, 0)
	var trigger := encounter.advance_boat_fishing_trigger_for_hook(evaluation, 0.5, 0)
	if (trigger.get("candidate", {}) as Dictionary).is_empty():
		trigger = encounter.advance_boat_fishing_trigger_for_hook(evaluation, 0.5, 0)
	var candidate: Dictionary = trigger.get("candidate", {})
	_check(
		str(trigger.get("trigger_mode", "")) == "SCHOOL_TARGETED"
		and str(candidate.get("trigger_mode", "")) == "SCHOOL_TARGETED"
		and int(candidate.get("hook_index", -1)) == 0,
		"9 m reaction passes targeted source ownership and hook index into the approach candidate"
	)
	if candidate.is_empty():
		return
	var pending := encounter.begin_boat_fishing_approach(candidate)
	_check(pending != null, "Authority accepts one real pending Sea Trout catch")
	if pending == null:
		return
	var start := BoatFishingCastingSystem.school_pursuit_start_world(
		candidate.get("school_center_world_position", Vector3.ZERO),
		hook,
		SEA_TROUT.school_wander_radius_m
	)
	var start_distance := start.distance_to(hook)
	_check(is_equal_approx(start_distance, 8.0), "fish begins about 8 m from hook, inside the school's core rather than near the hook")
	var speed := (SEA_TROUT.movement_speed_min_mps + SEA_TROUT.movement_speed_max_mps) * 0.5
	var fish_mouth := start
	var elapsed := 0.0
	var maximum_speed := 0.0
	var reached_contact := false
	while elapsed < 60.0:
		var before := fish_mouth
		fish_mouth = BoatFishingCastingSystem.advance_fish_pursuit_world(fish_mouth, hook, speed, 1.0 / 30.0)
		var step_speed := before.distance_to(fish_mouth) * 30.0
		maximum_speed = maxf(maximum_speed, step_speed)
		elapsed += 1.0 / 30.0
		if fish_mouth.distance_to(hook) <= CONTACT_RADIUS_M:
			reached_contact = true
			break
	_check(reached_contact, "fish mouth reaches hook contact after swimming instead of being tweened or snapped")
	_check(maximum_speed <= speed + 0.0001, "pursuit movement never exceeds species swim speed")
	_check(fish_mouth.distance_to(hook) <= CONTACT_RADIUS_M, "mouth-to-hook error at bite stays within contact radius")
	_check(encounter.confirm_boat_fishing_bite(), "Authority confirms only after the simulated mouth reaches contact")
	print("[P6.4.5.4] trout 9m: eligible=yes, approach=yes, start=%.2f m, duration=%.2f s, max_speed=%.3f m/s, contact=%.3f m, reservation=accepted/confirmed" % [start_distance, elapsed, maximum_speed, fish_mouth.distance_to(hook)])
	encounter.cancel_boat_fishing_catch("p6_4_5_4_test_cleanup")


func _test_frame_rate_and_moving_target() -> void:
	var start := Vector3(8.0, -2.0, 0.0)
	var hook := Vector3.ZERO
	var speed := 0.7
	var seconds_30 := _simulate_arrival_seconds(start, hook, speed, 1.0 / 30.0)
	var seconds_60 := _simulate_arrival_seconds(start, hook, speed, 1.0 / 60.0)
	_check(absf(seconds_30 - seconds_60) <= 1.0 / 30.0 + 0.001, "30 and 60 FPS pursuit contact times differ by at most one 30 FPS step")
	var moved := BoatFishingCastingSystem.advance_fish_pursuit_world(start, Vector3(0.1, -2.0, 0.0), speed, 0.1)
	_check(moved.distance_to(start) <= speed * 0.1 + 0.0001, "fish tracks a moving hook while retaining its physical speed cap")
	_check(moved.distance_to(Vector3(0.1, -2.0, 0.0)) < start.distance_to(Vector3(0.1, -2.0, 0.0)), "fish makes continuous progress toward the current hook position")


func _simulate_arrival_seconds(start: Vector3, hook: Vector3, speed: float, dt: float) -> float:
	var mouth := start
	var elapsed := 0.0
	while elapsed < 60.0 and mouth.distance_to(hook) > CONTACT_RADIUS_M:
		mouth = BoatFishingCastingSystem.advance_fish_pursuit_world(mouth, hook, speed, dt)
		elapsed += dt
	return elapsed


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[P6.4.5.4] " + message)
