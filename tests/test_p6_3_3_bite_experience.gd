extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const SABIKI_RIG: BoatFishingRigProfile = preload("res://resources/boat_fishing/sabiki_rig.tres")
const SINGLE_JIG: BoatFishingRigProfile = preload("res://resources/boat_fishing/single_jig.tres")
const HERRING_PROFILE: FishSpeciesProfile = preload("res://resources/fish_species/herring.tres")
const SEA_TROUT_PROFILE: FishSpeciesProfile = preload("res://resources/fish_species/sea_trout.tres")
const SAMPLE_INTERVAL_SECONDS := 0.5
const STAT_SAMPLE_COUNT := 10000
const STAT_OBSERVATION_WINDOW_SECONDS := 120.0


class FakeFishingManager extends Node:
	var profiles: Dictionary = {}
	var schools: Dictionary = {}
	var query_radius_m := 0.0
	var game_time_seconds := 0.0

	func get_species_profile(species_id: String) -> FishSpeciesProfile:
		return profiles.get(species_id) as FishSpeciesProfile

	func get_world_seed() -> int:
		return 331903

	func get_world_game_time_seconds() -> float:
		return game_time_seconds

	func set_school(school_id: String, species_id: String, position: Vector3, depth_m: float, population: int, activity_state: String = "near_surface", resource_state: String = "available") -> void:
		schools[school_id] = {
			"school_id": school_id,
			"species_id": species_id,
			"world_position": [position.x, position.y, position.z],
			"population": population,
			"resource_state": resource_state,
			"activity_depth_m": depth_m,
			"activity_depth_target_m": depth_m,
			"effective_activity_depth_m": depth_m,
			"surface_activity_state": activity_state,
			"effective_surface_activity_state": activity_state,
		}

	func get_school(school_id: String) -> Dictionary:
		return (schools.get(school_id, {}) as Dictionary).duplicate(true)

	func get_schools_near(position: Vector3, radius_m: float, include_unavailable: bool = false) -> Array[Dictionary]:
		query_radius_m = radius_m
		var rows: Array[Dictionary] = []
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
				rows.append(school.duplicate(true))
		return rows


var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_distance_surface_and_rate_models()
	_test_real_time_hazard_units()
	await _test_shared_activity_depth_projection()
	_test_bite_time_statistics()
	print("[P6.3.3] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _test_distance_surface_and_rate_models() -> void:
	for sample in [
		{"distance": 5.0, "expected": 1.0},
		{"distance": 15.0, "expected": 0.85},
		{"distance": 25.0, "expected": 0.55},
		{"distance": 35.0, "expected": 0.25},
		{"distance": 45.0, "expected": 0.0833333333},
		{"distance": 50.0, "expected": 0.0},
		{"distance": 55.0, "expected": 0.0},
	]:
		var measured := FishingEncounterSystem.boat_fishing_horizontal_distance_weight(float(sample["distance"]))
		_check(is_equal_approx(measured, float(sample["expected"])), "50 m horizontal curve at %.1f m = %.3f" % [float(sample["distance"]), measured])
	_check(is_equal_approx(FishingEncounterSystem.boat_fishing_surface_activity_multiplier("deep", 15.0, HERRING_PROFILE), 1.0), "deep fish use multiplier 1.0")
	_check(is_equal_approx(FishingEncounterSystem.boat_fishing_surface_activity_multiplier("ascending", 4.0, HERRING_PROFILE), 1.2), "shallow transitioning fish use multiplier 1.2")
	_check(is_equal_approx(FishingEncounterSystem.boat_fishing_surface_activity_multiplier("near_surface", 1.5, HERRING_PROFILE), 1.6), "active surface fish use multiplier 1.6")
	_check(is_equal_approx(FishingEncounterSystem.boat_fishing_surface_activity_multiplier("near_surface", 2.4, HERRING_PROFILE), 1.2), "surface-active but not surface-indicated schools use the lower multiplier")
	_check(HERRING_PROFILE.is_surface_activity_visually_indicated("ascending", 1.9), "surface-indication gate matches ecological state and depth, independent of rendering instances")
	var non_surface_profile := FishSpeciesProfile.new()
	_check(is_equal_approx(FishingEncounterSystem.boat_fishing_surface_activity_multiplier("near_surface", 1.5, non_surface_profile), 1.0), "species without a surface cycle receive no surface bonus")

	var fake := FakeFishingManager.new()
	fake.profiles = {"herring": HERRING_PROFILE, "sea_trout": SEA_TROUT_PROFILE}
	root.add_child(fake)
	var encounter := FishingEncounterSystem.new()
	root.add_child(encounter)
	encounter.configure(fake, null)
	encounter.set_process(false)
	fake.set_school("surface", "herring", Vector3(15.0, 0.0, 0.0), 1.6, 64)
	var sabiki := encounter.evaluate_boat_fishing_candidates(Vector3.ZERO, 1.6, 0.0, SABIKI_RIG)
	var school: Dictionary = sabiki.get("candidate_schools", [])[0]
	_check(is_equal_approx(fake.query_radius_m, 50.0), "candidate query remains 50 m")
	_check(is_equal_approx(float(school.get("surface_activity_multiplier", 0.0)), 1.6), "surface multiplier is part of natural Sabiki event evaluation")
	_check(is_equal_approx(float(sabiki.get("base_event_rate_per_real_hour", 0.0)), 50.0), "Sabiki keeps its own 50/h per-hook base")
	fake.set_school("empty", "herring", Vector3(2.0, 0.0, 0.0), 1.6, 0, "near_surface", "depleted")
	var unavailable := encounter.evaluate_boat_fishing_candidates(Vector3.ZERO, 1.6, 0.0, SABIKI_RIG, true)
	var found_empty := false
	for row in unavailable.get("candidate_schools", []):
		if str(row.get("school_id", "")) == "empty" and str(row.get("rejection_reason", "")) == "empty_school":
			found_empty = true
	_check(found_empty, "F3 diagnostic query can distinguish a nearby depleted school")
	fake.schools.clear()
	fake.set_school("outside_natural_range", "herring", Vector3(55.0, 0.0, 0.0), 1.6, 64)
	var natural_outside := encounter.evaluate_boat_fishing_candidates(Vector3.ZERO, 1.6, 0.0, SABIKI_RIG)
	_check(is_equal_approx(fake.query_radius_m, 50.0) and int(natural_outside.get("candidate_school_count", -1)) == 0, "natural boat-fishing query remains capped at 50 m")
	var debug_outside := encounter.evaluate_boat_fishing_candidates(Vector3.ZERO, 1.6, 0.0, SABIKI_RIG, true)
	var outside_row: Dictionary = debug_outside.get("candidate_schools", [])[0] if int(debug_outside.get("candidate_school_count", 0)) > 0 else {}
	_check(is_equal_approx(fake.query_radius_m, 65.0), "F3-only school scan uses its 65 m diagnostic radius")
	_check(str(outside_row.get("rejection_reason", "")) == "lure_outside_school" and float(debug_outside.get("total_event_rate_per_real_hour", 0.0)) == 0.0, "a school at 55 m is diagnosed but cannot add natural bite hazard")
	encounter.queue_free()
	fake.queue_free()


func _test_real_time_hazard_units() -> void:
	var fake := FakeFishingManager.new()
	fake.profiles = {"herring": HERRING_PROFILE}
	root.add_child(fake)
	var encounter := FishingEncounterSystem.new()
	root.add_child(encounter)
	encounter.configure(fake, null)
	encounter.set_process(false)
	encounter.set("_boat_hazard_threshold", 100.0)
	encounter.set("_boat_hazard_accumulated", 0.0)
	encounter.advance_boat_fishing_hazard({"total_event_rate_per_real_hour": 3600.0, "valid_candidates": []}, 0.5)
	_check(is_equal_approx(float(encounter.get("_boat_hazard_accumulated")), 0.5), "boat hazard integrates a half real second without a world-time multiplier")
	encounter.queue_free()
	fake.queue_free()


func _test_shared_activity_depth_projection() -> void:
	var scene := MAIN_SCENE.instantiate()
	root.add_child(scene)
	await process_frame
	var manager := scene.get_node("FishResourceManager") as FishResourceManager
	var authority := FishLocalAuthority.new()
	authority.initialize(manager.get_world_seed(), manager.get_bathymetry_manager(), manager.get_georeference(), [HERRING_PROFILE], 0.0)
	var all_states: Dictionary = authority.get("_schools")
	var state: FishSchoolState
	for state_variant in all_states.values():
		var candidate_state := state_variant as FishSchoolState
		if candidate_state.depth_m > 15.0:
			state = candidate_state
			break
	_check(state != null, "test authority has a deep-enough herring school")
	if state == null:
		scene.queue_free()
		await process_frame
		return
	state.surface_activity_state = "ascending"
	state.activity_depth_m = 2.0
	state.activity_depth_target_m = 8.0
	state.surface_activity_remaining_seconds = 0.0
	state.activity_depth_state_timestamp_seconds = 0.0
	authority.set("_simulation_seconds", 0.0)
	authority.set("_step_accumulator", 4.0)
	var rising := authority.get_school(state.school_id)
	var effective_rising := float(rising.get("effective_activity_depth_m", -1.0))
	_check(is_equal_approx(float(rising.get("activity_depth_m", -1.0)), 2.0), "Authority checkpoint depth remains separate from projected depth")
	_check(is_equal_approx(float(rising.get("activity_depth_target_m", -1.0)), 8.0), "Authority target depth remains visible in diagnostics")
	_check(is_equal_approx(effective_rising, 5.0), "effective depth advances at the configured 0.75 m/s instead of jumping to target")
	_check(str(rising.get("effective_surface_activity_state", "")) == "ascending", "effective activity state follows the projected transition")
	var renderer := FishSchoolRenderer.new()
	root.add_child(renderer)
	_check(is_equal_approx(float(renderer.call("_school_activity_depth", rising, 2.0)), effective_rising), "fish renderer reads the same projected depth as Authority consumers")
	var projected_manager := FakeFishingManager.new()
	projected_manager.profiles = {"herring": HERRING_PROFILE}
	var projected_school := rising.duplicate(true)
	projected_school["world_position"] = [0.0, 0.0, 0.0]
	projected_manager.schools[state.school_id] = projected_school
	root.add_child(projected_manager)
	var projected_encounter := FishingEncounterSystem.new()
	root.add_child(projected_encounter)
	projected_encounter.configure(projected_manager, null)
	projected_encounter.set_process(false)
	var projected_candidate_diagnostics := projected_encounter.evaluate_boat_fishing_candidates(Vector3.ZERO, effective_rising, 0.0, SABIKI_RIG)
	var projected_candidate: Dictionary = projected_candidate_diagnostics.get("candidate_schools", [])[0] if int(projected_candidate_diagnostics.get("candidate_school_count", 0)) > 0 else {}
	_check(is_equal_approx(float(projected_candidate.get("effective_activity_depth_m", -1.0)), effective_rising), "natural bite evaluator consumes the same effective depth as rendering")
	_check(is_equal_approx(float(projected_candidate.get("activity_depth_target_m", -1.0)), 8.0), "natural bite diagnostics retain the transition target separately")
	state.surface_activity_state = "near_surface"
	state.activity_depth_m = 2.0
	state.activity_depth_target_m = 2.0
	state.surface_activity_remaining_seconds = 1.0
	state.activity_depth_state_timestamp_seconds = 0.0
	authority.set("_step_accumulator", 5.0)
	var descending := authority.get_school(state.school_id)
	_check(str(descending.get("effective_surface_activity_state", "")) == "descending", "surface dwell expiry projects into the descending state")
	_check(float(descending.get("effective_activity_depth_m", 99.0)) > 2.0 and float(descending.get("effective_activity_depth_m", 0.0)) < float(descending.get("effective_activity_depth_target_m", 99.0)), "downward transition remains continuous between Authority steps")
	state.surface_activity_state = "deep"
	state.activity_depth_m = 15.0
	state.activity_depth_target_m = 15.0
	state.surface_activity_remaining_seconds = 1.0
	state.activity_depth_state_timestamp_seconds = 0.0
	var bottom_clearance := maxf(0.5, state.depth_m - 0.8)
	state.activity_depth_m = minf(state.activity_depth_m, bottom_clearance)
	state.activity_depth_target_m = state.activity_depth_m
	var ascending := authority.get_school(state.school_id)
	_check(str(ascending.get("effective_surface_activity_state", "")) == "ascending", "deep dwell expiry projects into the ascending state")
	_check(float(ascending.get("effective_activity_depth_m", -1.0)) < float(ascending.get("activity_depth_m", 0.0)), "upward transition uses the same continuous depth for fishing and rendering")
	renderer.queue_free()
	projected_encounter.queue_free()
	projected_manager.queue_free()
	scene.queue_free()
	await process_frame


func _test_bite_time_statistics() -> void:
	var fake := FakeFishingManager.new()
	fake.profiles = {"herring": HERRING_PROFILE, "sea_trout": SEA_TROUT_PROFILE}
	root.add_child(fake)
	var encounter := FishingEncounterSystem.new()
	root.add_child(encounter)
	encounter.configure(fake, null)
	encounter.set_process(false)
	var scenarios := [
		{"name": "surface Sabiki 5 m", "distance": 5.0, "school_depth": 1.6, "lure_depth": 1.6, "population": 64, "state": "near_surface", "species": "herring", "rig": SABIKI_RIG, "hooks": 5},
		{"name": "surface Sabiki 15 m", "distance": 15.0, "school_depth": 1.6, "lure_depth": 1.6, "population": 64, "state": "near_surface", "species": "herring", "rig": SABIKI_RIG, "hooks": 5},
		{"name": "surface Sabiki 30 m", "distance": 30.0, "school_depth": 1.6, "lure_depth": 1.6, "population": 64, "state": "near_surface", "species": "herring", "rig": SABIKI_RIG, "hooks": 5},
		{"name": "deep Sabiki 15 m", "distance": 15.0, "school_depth": 15.0, "lure_depth": 15.0, "population": 64, "state": "deep", "species": "herring", "rig": SABIKI_RIG, "hooks": 5},
		{"name": "surface Sabiki wrong layer", "distance": 15.0, "school_depth": 1.6, "lure_depth": 10.0, "population": 64, "state": "near_surface", "species": "herring", "rig": SABIKI_RIG, "hooks": 5},
		{"name": "incompatible Sabiki", "distance": 5.0, "school_depth": 1.6, "lure_depth": 1.6, "population": 64, "state": "near_surface", "species": "sea_trout", "rig": SABIKI_RIG, "hooks": 5},
		{"name": "surface Sabiki only two fish", "distance": 5.0, "school_depth": 1.6, "lure_depth": 1.6, "population": 2, "state": "near_surface", "species": "herring", "rig": SABIKI_RIG, "hooks": 5},
		{"name": "surface Single Jig 10 m", "distance": 10.0, "school_depth": 1.6, "lure_depth": 1.6, "population": 64, "state": "near_surface", "species": "sea_trout", "rig": SINGLE_JIG, "hooks": 1},
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = 639033
	for scenario in scenarios:
		fake.schools.clear()
		fake.set_school("scenario_school", str(scenario["species"]), Vector3(float(scenario["distance"]), 0.0, 0.0), float(scenario["school_depth"]), int(scenario["population"]), str(scenario["state"]))
		var diagnostics := encounter.evaluate_boat_fishing_candidates(Vector3.ZERO, float(scenario["lure_depth"]), 0.0, scenario["rig"])
		var per_hook_rate := float(diagnostics.get("total_event_rate_per_real_hour", 0.0))
		var aggregate_rate := per_hook_rate * int(scenario["hooks"])
		if aggregate_rate > 0.0:
			var distribution := _sample_quantized_first_bite_times(aggregate_rate, rng)
			print("[P6.3.3][STAT] %s rate=%.2f/h median=%.2fs p90=%.2fs no_bite_120s=%.2f%%" % [str(scenario["name"]), aggregate_rate, float(distribution["median"]), float(distribution["p90"]), float(distribution["no_bite_percent"])])
			_check(float(distribution["no_bite_percent"]) < 1.0, "%s has a non-zero natural bite probability" % str(scenario["name"]))
			if str(scenario["name"]) == "surface Sabiki 5 m":
				_check(float(distribution["median"]) >= 1.0 and float(distribution["median"]) <= 3.5, "near surface 5 m first Sabiki bite median is within the 1–3 s target, allowing 0.5 s sampling quantization")
			elif str(scenario["name"]) == "surface Sabiki 15 m":
				_check(float(distribution["median"]) >= 2.0 and float(distribution["median"]) <= 5.5, "surface 15 m first Sabiki bite median is within the 2–5 s target, allowing sampling quantization")
			elif str(scenario["name"]) == "surface Sabiki 30 m":
				_check(float(distribution["median"]) >= 5.0 and float(distribution["median"]) <= 12.0, "surface 30 m first Sabiki bite median is within the 5–12 s target")
			elif str(scenario["name"]) == "deep Sabiki 15 m":
				_check(float(distribution["median"]) > 3.0, "deep school bites slower than the matching surface case")
		else:
			_check(int(diagnostics.get("valid_candidate_count", 0)) == 0, "%s cannot naturally bite" % str(scenario["name"]))
			print("[P6.3.3][STAT] %s rate=0.00/h median=none p90=none no_bite_120s=100.00%%" % str(scenario["name"]))
	encounter.queue_free()
	fake.queue_free()
	await process_frame


func _sample_quantized_first_bite_times(rate_per_real_hour: float, rng: RandomNumberGenerator) -> Dictionary:
	var times: Array[float] = []
	var no_bite_count := 0
	var lambda_per_second := rate_per_real_hour / 3600.0
	for _index in range(STAT_SAMPLE_COUNT):
		var exponential_time := -log(maxf(0.000000001, 1.0 - rng.randf())) / lambda_per_second
		var sampled_time := ceilf(exponential_time / SAMPLE_INTERVAL_SECONDS) * SAMPLE_INTERVAL_SECONDS
		if sampled_time > STAT_OBSERVATION_WINDOW_SECONDS:
			no_bite_count += 1
		else:
			times.append(sampled_time)
	times.sort()
	return {
		"median": _quantile(times, 0.50),
		"p90": _quantile(times, 0.90),
		"no_bite_percent": float(no_bite_count) * 100.0 / float(STAT_SAMPLE_COUNT),
	}


func _quantile(sorted_values: Array[float], quantile: float) -> float:
	if sorted_values.is_empty():
		return INF
	return sorted_values[clampi(floori(float(sorted_values.size() - 1) * quantile), 0, sorted_values.size() - 1)]


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[P6.3.3][PASS] %s" % message)
	else:
		_failures += 1
		push_error("[P6.3.3][FAIL] %s" % message)
