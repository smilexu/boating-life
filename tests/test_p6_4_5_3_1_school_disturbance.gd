extends SceneTree

const MODEL := preload("res://scripts/fish_school_disturbance_model.gd")
const AUTHORITY := preload("res://scripts/fish_local_authority.gd")
const HERRING := preload("res://resources/fish_species/herring.tres")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager := FishResourceManager.new()
	var config := manager.get_school_disturbance_config()
	var cases := [
		{"name": "A", "depth": 1.0, "speed": 1.0, "engine": true, "dt": 1.0 / 60.0},
		{"name": "B", "depth": 3.0, "speed": 1.0, "engine": true, "dt": 1.0 / 60.0},
		{"name": "C", "depth": 8.0, "speed": 1.0, "engine": true, "dt": 1.0 / 60.0},
		{"name": "D", "depth": 1.0, "speed": 9.0, "engine": true, "dt": 1.0 / 60.0},
		{"name": "E", "depth": 3.0, "speed": 0.4, "engine": false, "dt": 1.0 / 60.0},
	]
	var results: Array[Dictionary] = []
	for row in cases:
		var vessel := MODEL.vessel_disturbance({
			"world_position": Vector3.ZERO,
			"hull_bottom_world_y": -0.8,
			"engine_data_available": true,
			"engine_running": bool(row["engine"]),
			"throttle_demand": 0.0,
			"speed_mps": float(row["speed"]),
		}, config)
		var vertical := maxf(0.0, float(row["depth"]) - 0.8)
		var target := MODEL.target_for_school(0.0, vertical, float(vessel["vessel_disturbance"]), HERRING.vessel_disturbance_sensitivity, config)
		var state := _simulate(target, float(row["dt"]), config)
		var result := {
			"name": str(row["name"]),
			"depth_m": float(row["depth"]),
			"vessel_disturbance": float(vessel["vessel_disturbance"]),
			"target": target,
			"level_after_5_s": float(state["disturbance_level"]),
			"state_after_5_s": str(state["disturbance_state"]),
			"bite_willingness": MODEL.bite_willingness(str(state["disturbance_state"]), config),
		}
		results.append(result)
		print("[P6.4.5.3.1] %s depth=%.1fm vessel=%.3f target=%.4f level5=%.4f state=%s bite=%.2f" % [
			str(result["name"]), float(result["depth_m"]), float(result["vessel_disturbance"]), float(result["target"]),
			float(result["level_after_5_s"]), str(result["state_after_5_s"]), float(result["bite_willingness"]),
		])
	_check(results[0]["state_after_5_s"] == "ALERT", "slow powered boat over a one metre school reaches ALERT without immediate flight")
	_check(results[1]["state_after_5_s"] == "ALERT", "slow powered boat over a three metre school may reach ALERT")
	_check(results[2]["state_after_5_s"] == "CALM", "slow powered boat over an eight metre school does not trigger flight")
	_check(results[3]["state_after_5_s"] == "FLEEING", "sustained fast powered passage can trigger flight for a shallow school")
	_check(results[4]["state_after_5_s"] == "CALM", "engine-off drift remains less disturbing than powered passage")
	_check(float(results[0]["target"]) > float(results[2]["target"]), "shallow fish receive more disturbance than deeper fish at the same horizontal distance")
	_check(float(results[4]["vessel_disturbance"]) < float(results[1]["vessel_disturbance"]), "same-speed engine-off drift is less disturbing than powered movement")
	_test_vessel_states(config)
	_test_distance_and_state_hysteresis(config)
	_test_authority_state_and_snapshot(config)
	_test_disturbance_localization()
	manager.free()
	print("[P6.4.5.3.1] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _test_vessel_states(config: Dictionary) -> void:
	var stationary_off := MODEL.vessel_disturbance({"engine_data_available": true, "engine_running": false, "speed_mps": 0.0}, config)
	var drifting_off := MODEL.vessel_disturbance({"engine_data_available": true, "engine_running": false, "speed_mps": 0.4}, config)
	var engine_idle := MODEL.vessel_disturbance({"engine_data_available": true, "engine_running": true, "speed_mps": 0.0, "throttle_demand": 0.0}, config)
	var unknown_engine := MODEL.vessel_disturbance({"engine_data_available": false, "engine_running": true, "speed_mps": 1.0}, config)
	_check(is_equal_approx(float(stationary_off["vessel_disturbance"]), 0.08), "engine-off stationary vessel uses the low baseline disturbance")
	_check(is_equal_approx(float(drifting_off["vessel_disturbance"]), 0.12 + (0.50 - 0.12) * 0.4 / 6.0), "engine-off drift adds movement disturbance without engine noise")
	_check(is_equal_approx(float(engine_idle["vessel_disturbance"]), 0.30), "running engine at near-zero speed still disturbs the school")
	_check(not bool(unknown_engine["engine_data_available"]) and float(unknown_engine["vessel_disturbance"]) < 0.50, "missing engine data falls back to conservative movement-only disturbance")


func _simulate(target: float, dt: float, config: Dictionary) -> Dictionary:
	var state := "CALM"
	var level := 0.0
	var strong_seconds := 0.0
	var steps := roundi(5.0 / dt)
	for _step in range(steps):
		var result: Dictionary = MODEL.advance_school_state(level, state, strong_seconds, target, dt, config)
		level = float(result["disturbance_level"])
		state = str(result["disturbance_state"])
		strong_seconds = float(result["strong_disturbance_duration_seconds"])
	return {"disturbance_level": level, "disturbance_state": state, "strong_seconds": strong_seconds}


func _test_distance_and_state_hysteresis(config: Dictionary) -> void:
	var levels: Array[float] = []
	for horizontal_distance in [0.0, 8.0, 16.0, 32.0]:
		levels.append(MODEL.target_for_school(horizontal_distance, 1.0, 0.8, 1.0, config))
	_check(levels[0] > levels[1] and levels[1] > levels[2] and levels[2] > levels[3], "horizontal disturbance decays monotonically")
	var depths: Array[float] = []
	for depth in [0.0, 1.0, 3.0, 8.0, 16.0]:
		depths.append(MODEL.target_for_school(0.0, depth, 0.8, 1.0, config))
	_check(depths[0] > depths[1] and depths[1] > depths[2] and depths[2] > depths[3] and depths[3] > depths[4], "vertical disturbance decays monotonically")
	var shallow_target := MODEL.target_for_school(0.0, 0.2, 1.0, 1.0, config)
	var _no_flee_after_very_short_pulse: Dictionary = MODEL.advance_school_state(0.0, "CALM", 0.0, shallow_target, 0.05, config)
	_check(str(_no_flee_after_very_short_pulse["disturbance_state"]) != "FLEEING", "horizontal distance zero cannot skip the level and sustained-disturbance gates")
	var at_30 := _simulate(shallow_target, 1.0 / 30.0, config)
	var at_60 := _simulate(shallow_target, 1.0 / 60.0, config)
	_check(absf(float(at_30["disturbance_level"]) - float(at_60["disturbance_level"])) < 0.0001, "exponential disturbance response is effectively frame-rate independent")
	var recovering: Dictionary = MODEL.advance_school_state(float(at_60["disturbance_level"]), str(at_60["disturbance_state"]), 0.0, 0.0, 12.0, config)
	_check(str(recovering["disturbance_state"]) == "ALERT", "FLEEING exits to ALERT through the configured level hysteresis")
	var calm: Dictionary = MODEL.advance_school_state(float(recovering["disturbance_level"]), str(recovering["disturbance_state"]), 0.0, 0.0, 40.0, config)
	_check(str(calm["disturbance_state"]) == "CALM", "disturbance recovers to CALM after the vessel leaves")
	var invalid: Dictionary = MODEL.advance_school_state(NAN, "invalid", NAN, NAN, NAN, config)
	_check(is_finite(float(invalid["disturbance_level"])) and float(invalid["disturbance_level"]) >= 0.0, "invalid values safely fall back to bounded calm state")


func _test_authority_state_and_snapshot(config: Dictionary) -> void:
	var authority := AUTHORITY.new() as FishLocalAuthority
	authority._profiles_by_id["herring"] = HERRING
	var state := FishSchoolState.new()
	state.school_id = "test_herring_disturbance"
	state.species_id = "herring"
	state.world_position = Vector3.ZERO
	state.population = 3
	state.baseline_population = 3
	authority._schools[state.school_id] = state
	var vessel := {
		"world_position": Vector3.ZERO,
		"hull_bottom_world_y": -0.8,
		"engine_data_available": true,
		"engine_running": true,
		"throttle_demand": 0.0,
		"speed_mps": 1.0,
	}
	var samples: Array[Dictionary] = [{"school_id": state.school_id, "surface_height_m": 0.0, "effective_activity_depth_m": 3.0}]
	authority.update_school_disturbance(vessel, samples, 5.0, config)
	var snapshot := authority.get_school(state.school_id)
	_check(str(snapshot.get("disturbance_state", "")) == "ALERT", "local Authority owns and publishes the accumulated school state")
	_check(is_equal_approx(float(snapshot.get("bite_willingness_multiplier", 0.0)), 0.80), "Authority publishes the ALERT bite-willingness multiplier")
	_check(is_equal_approx(float(snapshot.get("disturbance_vertical_below_hull_m", -1.0)), 2.2), "Authority calculates school depth relative to the hull bottom")
	var invalid_vessel := vessel.duplicate(true)
	invalid_vessel["world_position"] = Vector3(NAN, 0.0, 0.0)
	_check(not authority.update_school_disturbance(invalid_vessel, samples, 1.0, config), "invalid vessel coordinates cannot update or relocate Authority disturbance")
	var restored := FishSchoolState.from_dictionary(state.to_dictionary())
	_check(restored != null and restored.disturbance_state == state.disturbance_state and is_equal_approx(restored.disturbance_level, state.disturbance_level), "school disturbance survives Authority snapshot serialization")
	var malformed := state.to_dictionary()
	malformed["disturbance_level"] = NAN
	malformed["disturbance_target"] = INF
	malformed["disturbance_horizontal_distance_m"] = NAN
	malformed["bite_willingness_multiplier"] = INF
	var sanitized := FishSchoolState.from_dictionary(malformed)
	_check(sanitized != null and is_equal_approx(sanitized.disturbance_level, 0.0) and is_equal_approx(sanitized.disturbance_target, 0.0) and is_equal_approx(sanitized.disturbance_horizontal_distance_m, -1.0) and is_equal_approx(sanitized.bite_willingness_multiplier, 1.0), "invalid disturbance snapshot values fall back safely")
	malformed["world_position"] = [NAN, 0.0, 0.0]
	_check(FishSchoolState.from_dictionary(malformed) == null, "invalid school coordinates are rejected during snapshot restore")
	var legacy := state.to_dictionary()
	legacy["schema_version"] = 3
	for key in ["disturbance_level", "disturbance_target", "disturbance_state", "strong_disturbance_duration_seconds", "disturbance_horizontal_distance_m", "disturbance_vertical_below_hull_m", "vessel_disturbance", "bite_willingness_multiplier"]:
		legacy.erase(key)
	var legacy_restored := FishSchoolState.from_dictionary(legacy)
	_check(legacy_restored != null and legacy_restored.disturbance_state == "CALM", "legacy school snapshots safely restore in CALM")


func _test_disturbance_localization() -> void:
	var previous_locale := TranslationServer.get_locale()
	var keys := [
		"fishing.debug.section.school_disturbance",
		"fishing.debug.school_disturbance.no_target",
		"fishing.debug.school_disturbance.row",
		"fishing.debug.school_disturbance.state.calm",
		"fishing.debug.school_disturbance.state.alert",
		"fishing.debug.school_disturbance.state.fleeing",
	]
	for locale in ["en", "zh_CN"]:
		TranslationServer.set_locale(locale)
		for key in keys:
			_check(TranslationServer.translate(key) != key, "%s disturbance F3 key resolves: %s" % [locale, key])
	TranslationServer.set_locale(previous_locale)


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[P6.4.5.3.1] " + message)
