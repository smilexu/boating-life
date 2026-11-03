extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
const SABIKI_RIG: BoatFishingRigProfile = preload("res://resources/boat_fishing/sabiki_rig.tres")
const SINGLE_JIG: BoatFishingRigProfile = preload("res://resources/boat_fishing/single_jig.tres")
const HERRING_PROFILE: FishSpeciesProfile = preload("res://resources/fish_species/herring.tres")
const SEA_TROUT_PROFILE: FishSpeciesProfile = preload("res://resources/fish_species/sea_trout.tres")


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

	func evaluate_ambient_fishing_candidates(context: Dictionary) -> Dictionary:
		if not bool(context.get("action_qualified", false)):
			return {"candidates": [], "reason": "action_requirement_not_met", "environment_quality": 0.0}
		var rig_species: Array = context.get("rig_compatible_species_ids", [])
		var rig_tags: Array = context.get("rig_compatible_lure_tags", [])
		var hook_depth := float(context.get("hook_depth_m", 0.0))
		var candidates: Array[Dictionary] = []
		for species_variant in profiles.keys():
			var species_id := str(species_variant)
			var profile := profiles[species_variant] as FishSpeciesProfile
			if profile == null or not profile.supported_fishing_methods.has("boat_fishing"):
				continue
			var compatible := rig_species.has(species_id)
			if rig_species.is_empty():
				for tag in rig_tags:
					compatible = compatible or profile.compatible_lure_tags.has(str(tag))
			if not compatible:
				continue
			var depth_match := false
			if profile.surface_activity_cycle_enabled:
				depth_match = (hook_depth >= profile.surface_activity_depth_m.x and hook_depth <= profile.surface_activity_depth_m.y) or (hook_depth >= profile.deep_activity_depth_m.x and hook_depth <= profile.deep_activity_depth_m.y)
			elif profile.vertical_layer == "surface":
				depth_match = hook_depth <= profile.preferred_swim_depth_m.y
			else:
				depth_match = hook_depth <= 30.0
			if depth_match:
				candidates.append({"species_id": species_id, "ecological_weight": maxf(profile.spawn_chance, 0.001), "environment_quality": 1.0})
		if candidates.is_empty():
			return {"candidates": [], "reason": "activity_depth_mismatch", "environment_quality": 0.0}
		return {"candidates": candidates, "reason": "ambient_species_available", "environment_quality": 1.0}


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
	encounter.begin_boat_fishing_session()
	encounter.begin_boat_fishing_cast_session(Vector3.ZERO, SABIKI_RIG)
	fake.set_school("surface", "herring", Vector3(15.0, 0.0, 0.0), 1.6, 64)
	var sabiki := encounter.evaluate_boat_fishing_candidates(Vector3.ZERO, 1.6, 0.0, SABIKI_RIG)
	var school: Dictionary = sabiki.get("candidate_schools", [])[0]
	_check(is_equal_approx(fake.query_radius_m, 50.0), "candidate query remains 50 m")
	_check(is_equal_approx(float(school.get("surface_activity_multiplier", 0.0)), 1.6), "surface multiplier is part of natural Sabiki event evaluation")
	_check(str(sabiki.get("trigger_mode", "")) == "AMBIENT_ENCOUNTER" and float(sabiki.get("ambient_event_rate_per_real_hour", 0.0)) > 0.0, "out-of-volume hooks may use Authority-filtered ambient eligibility")
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
	_check(str(outside_row.get("rejection_reason", "")) == "outside_horizontal_range" and str(debug_outside.get("trigger_mode", "")) == "AMBIENT_ENCOUNTER" and float(debug_outside.get("ambient_event_rate_per_real_hour", 0.0)) > 0.0, "a school at 55 m is excluded while open-water ambient eligibility remains independent")
	encounter.queue_free()
	fake.queue_free()


func _test_real_time_hazard_units() -> void:
	var fake := FakeFishingManager.new()
	fake.profiles = {"herring": HERRING_PROFILE}
	root.add_child(fake)
	fake.set_school("ambient_school", "herring", Vector3(15.0, 0.0, 0.0), 1.6, 64)
	var encounter := FishingEncounterSystem.new()
	root.add_child(encounter)
	encounter.configure(fake, null)
	encounter.set_process(false)
	encounter.begin_boat_fishing_session()
	encounter.begin_boat_fishing_cast_session(Vector3.ZERO, SABIKI_RIG)
	var evaluation := encounter.evaluate_boat_fishing_candidates(Vector3.ZERO, 1.6, 0.0, SABIKI_RIG)
	var ambient_rate := float(evaluation.get("ambient_event_rate_per_real_hour", 0.0))
	encounter.set("_boat_ambient_hazard_threshold", 100.0)
	encounter.set("_boat_ambient_hazard_accumulated", 0.0)
	var hazard := encounter.advance_boat_fishing_ambient_hazard([evaluation], 0.5)
	_check(is_equal_approx(float(hazard.get("hazard_accumulated", -1.0)), ambient_rate * 0.5 / 3600.0), "shared ambient hazard integrates a half real second without a world-time multiplier")
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
	encounter.begin_boat_fishing_session()
	encounter.begin_boat_fishing_cast_session(Vector3.ZERO, SABIKI_RIG)
	var origin := Vector3(0.0, -1.6, 0.0)
	var core_scenarios := [
		{"name": "surface core", "horizontal": 1.0, "depth": 1.6, "lure_depth": 1.6, "min": 2.0, "max": 5.0},
		{"name": "surface edge", "horizontal": 2.16, "depth": 1.6, "lure_depth": 1.6, "min": 5.0, "max": 10.0},
		{"name": "deep core", "horizontal": 1.0, "depth": 15.0, "lure_depth": 15.0, "min": 2.0, "max": 5.0},
	]
	for scenario in core_scenarios:
		fake.schools.clear()
		fake.set_school("scenario_school", "herring", Vector3(float(scenario["horizontal"]), 0.0, 0.0), float(scenario["depth"]), 64, "near_surface" if float(scenario["depth"]) < 6.0 else "deep")
		var hook_position := Vector3(origin.x, -float(scenario["lure_depth"]), origin.z)
		var diagnostics := encounter.evaluate_boat_fishing_candidates(hook_position, float(scenario["lure_depth"]), 0.0, SABIKI_RIG, false, 0)
		_check(str(diagnostics.get("trigger_mode", "")) == "SCHOOL_TARGETED" and int(diagnostics.get("targeted_candidate_count", 0)) == 1, "%s enters targeted mode only inside the 3D school volume" % str(scenario["name"]))
		encounter.reset_boat_fishing_trigger_state()
		var trigger: Dictionary = {}
		for _sample in range(24):
			trigger = encounter.advance_boat_fishing_trigger_for_hook(diagnostics, 0.5, 0)
			if not (trigger.get("candidate", {}) as Dictionary).is_empty():
				break
		var reaction_seconds := float(trigger.get("reaction_total_seconds", -1.0))
		_check(reaction_seconds >= float(scenario["min"]) and reaction_seconds <= float(scenario["max"]), "%s natural response is inside its configured %s–%s s range" % [str(scenario["name"]), scenario["min"], scenario["max"]])
		print("[P6.3.3][TARGET] %s zone=%s reaction=%.2fs visual_approach=%.2fs" % [str(scenario["name"]), str(trigger.get("school_zone", "")), reaction_seconds, float(trigger.get("visual_approach_estimate_seconds", 0.0))])

	fake.schools.clear()
	fake.set_school("ambient_school", "herring", Vector3(15.0, 0.0, 0.0), 1.6, 64, "near_surface")
	var ambient_eval := encounter.evaluate_boat_fishing_candidates(origin, 1.6, 0.0, SABIKI_RIG)
	var ambient_rate := float(ambient_eval.get("ambient_event_rate_per_real_hour", 0.0))
	var ambient_mean_minutes := 60.0 / ambient_rate if ambient_rate > 0.0 else INF
	_check(str(ambient_eval.get("trigger_mode", "")) == "AMBIENT_ENCOUNTER" and ambient_mean_minutes >= 20.0 and ambient_mean_minutes <= 40.0, "an eligible open-water Herring ambient source has a 20–40 min mean at the configured base rate")
	print("[P6.3.3][AMBIENT] lambda=%.2f/h mean=%.1f real minutes" % [ambient_rate, ambient_mean_minutes])

	fake.schools.clear()
	fake.set_school("wrong_layer", "herring", Vector3(1.0, 0.0, 0.0), 1.6, 64, "near_surface")
	var wrong_layer := encounter.evaluate_boat_fishing_candidates(origin, 5.0, 0.0, SABIKI_RIG)
	_check(int(wrong_layer.get("valid_candidate_count", 0)) == 0, "wrong water layer cannot use either targeted or ambient mode")

	fake.schools.clear()
	fake.set_school("incompatible", "sea_trout", Vector3(1.0, 0.0, 0.0), 2.0, 64, "near_surface")
	var incompatible := encounter.evaluate_boat_fishing_candidates(Vector3(0.0, -2.0, 0.0), 2.0, 0.0, SABIKI_RIG)
	_check(int(incompatible.get("valid_candidate_count", 0)) == 0, "incompatible Sabiki target cannot use either mode")

	fake.schools.clear()
	fake.set_school("single_jig_school", "sea_trout", Vector3(1.0, 0.0, 0.0), 2.0, 8, "near_surface")
	var still_jig := encounter.evaluate_boat_fishing_candidates(Vector3(0.0, -2.0, 0.0), 2.0, 0.0, SINGLE_JIG)
	var moving_jig := encounter.evaluate_boat_fishing_candidates(Vector3(0.0, -2.0, 0.0), 2.0, 0.2, SINGLE_JIG)
	_check(int(still_jig.get("targeted_candidate_count", 0)) == 0 and int(moving_jig.get("targeted_candidate_count", 0)) == 1, "Single Jig requires a small amount of real lure movement for targeted school mode")
	encounter.queue_free()
	fake.queue_free()
	await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[P6.3.3][PASS] %s" % message)
	else:
		_failures += 1
		push_error("[P6.3.3][FAIL] %s" % message)
