extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_root := MAIN_SCENE.instantiate()
	root.add_child(main_root)
	await process_frame
	var manager := main_root.get_node("FishResourceManager") as FishResourceManager
	var herring_profile := manager.get_species_profile("herring")
	var profiles: Array[FishSpeciesProfile] = [herring_profile]
	var authority := FishLocalAuthority.new()
	authority.initialize(manager.get_world_seed(), manager.get_bathymetry_manager(), manager.get_georeference(), profiles, 0.0)
	var schools := authority.get_all_school_snapshots()
	var target: Dictionary = {}
	var untouched: Dictionary = {}
	for school in schools:
		if target.is_empty() and int(school.get("population", 0)) >= 20:
			target = school
		elif not target.is_empty() and str(school.get("school_id", "")) != str(target.get("school_id", "")):
			untouched = school
			break
	_check(not target.is_empty() and not untouched.is_empty(), "test herring profile supplies a depleted target and untouched control school")
	if target.is_empty() or untouched.is_empty():
		_finish(main_root)
		return

	var school_id := str(target["school_id"])
	var untouched_id := str(untouched["school_id"])
	var baseline := int(target["population"])
	var untouched_population := int(untouched["population"])
	var removal := authority.request_population_change(school_id, -baseline, 0.0)
	_check(bool(removal.get("accepted", false)), "simulated removal reduces school population to zero")
	var depleted := authority.get_school(school_id)
	_check(int(depleted.get("population", -1)) == 0 and str(depleted.get("resource_state", "")) == "depleted", "zero-population school retains stable depleted identity")
	_check(not authority.get_all_school_snapshots().any(func(school: Dictionary) -> bool: return str(school.get("school_id", "")) == school_id), "depleted school is absent from active resource snapshots")

	var time_120_hours := 120.0 * 3600.0
	await _run_authority_batch(authority, time_120_hours)
	var recovered := authority.get_school(school_id)
	var effective_recovered := float(recovered.get("population", 0)) + float(recovered.get("recovery_fractional_population", 0.0))
	var expected_recovered := float(baseline) * (1.0 - exp(-FishLocalAuthority.POPULATION_RECOVERY_RATE_PER_GAME_HOUR * 120.0))
	_check(is_equal_approx(effective_recovered, expected_recovered), "population follows the configured exponential curve in game hours")
	_check(int(recovered.get("population", 0)) > 0 and str(recovered.get("resource_state", "")) == "available", "depleted school returns to active resources after enough game time")
	_check(int(authority.get_school(untouched_id).get("population", -1)) == untouched_population, "an unconsumed school population does not change")

	var population_before_rewind := int(recovered.get("population", 0))
	var fraction_before_rewind := float(recovered.get("recovery_fractional_population", 0.0))
	await _run_authority_batch(authority, 60.0 * 3600.0)
	var after_rewind := authority.get_school(school_id)
	_check(int(after_rewind.get("population", -1)) == population_before_rewind and is_equal_approx(float(after_rewind.get("recovery_fractional_population", -1.0)), fraction_before_rewind), "rewinding world time resets the recovery anchor without reducing or granting fish")
	await _run_authority_batch(authority, 61.0 * 3600.0)
	var after_forward := authority.get_school(school_id)
	_check(float(after_forward.get("population", 0)) + float(after_forward.get("recovery_fractional_population", 0.0)) > float(population_before_rewind) + fraction_before_rewind, "recovery resumes from the new anchor after the clock moves forward")

	await _run_authority_batch(authority, 12000.0 * 3600.0)
	var capped := authority.get_school(school_id)
	_check(int(capped.get("population", -1)) == baseline and is_zero_approx(float(capped.get("recovery_fractional_population", 1.0))), "recovery reaches but never exceeds the original school baseline")
	var snapshot := authority.create_snapshot()
	_check(int(snapshot.get("schema_version", 0)) == 3 and int(snapshot.get("layout_version", 0)) == 5, "recovery snapshot advertises schema3/layout5")
	var restored_authority := FishLocalAuthority.new()
	restored_authority.initialize(manager.get_world_seed(), manager.get_bathymetry_manager(), manager.get_georeference(), profiles, 0.0)
	_check(restored_authority.restore_snapshot(snapshot), "recovery fields survive a current snapshot roundtrip")
	_check(restored_authority.get_school(school_id) == capped, "restored school state retains population and recovery baseline")
	var malformed: Dictionary = snapshot.duplicate(true)
	malformed["schools"][0]["baseline_population"] = -2
	_check(not restored_authority.restore_snapshot(malformed), "invalid recovery fields reject the entire snapshot")

	_finish(main_root)


func _run_authority_batch(authority: FishLocalAuthority, game_time_seconds: float) -> void:
	authority.update(FishLocalAuthority.SIMULATION_STEP_SECONDS, game_time_seconds)
	for frame_index in range(128):
		var pending: Variant = authority.get("_pending_school_ids")
		if pending is Array and pending.is_empty():
			break
		authority.update(0.016, game_time_seconds)
		await process_frame


func _check(condition: bool, label: String) -> void:
	if condition:
		print("[FISH_RECOVERY][PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FISH_RECOVERY][FAIL] %s" % label)


func _finish(main_root: Node) -> void:
	main_root.queue_free()
	print("[FISH_RECOVERY] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)
