extends SceneTree

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed_scene := load("res://scenes/main.tscn") as PackedScene
	if packed_scene == null:
		_fail("main.tscn failed to load")
		return
	var main := packed_scene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	var provider := main.get_node_or_null("NavigationDepthProvider") as NavigationDepthProvider
	var monitor := main.get_node_or_null("NavigationDepthMonitor") as NavigationDepthMonitor
	var harbor := main.get_node_or_null("MalmoHarbor") as Node
	var boat := main.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	var georeference := load("res://resources/oresund_georeference.tres") as GeoReference
	if provider == null or monitor == null or harbor == null or boat == null or georeference == null:
		_fail("Phase 2 nodes or GeoReference are missing")
		return
	var test_polygon := PackedVector2Array([
		Vector2(-5.0, -5.0), Vector2(5.0, -5.0), Vector2(5.0, 5.0), Vector2(-5.0, 5.0),
	])

	var metadata := main.get_node("BathymetryManager").call("get_source_metadata_at", 55.7) as Dictionary
	_expect(float(metadata.get("resolution_east_m", 0.0)) > 60.0 and float(metadata.get("resolution_east_m", 0.0)) < 70.0, "DTM east-west resolution is reported")
	_expect(float(metadata.get("resolution_north_m", 0.0)) > 110.0 and float(metadata.get("resolution_north_m", 0.0)) < 120.0, "DTM north-south resolution is reported")
	_expect(str(metadata.get("vertical_datum", "")) == "LAT" and not bool(metadata.get("navigation_grade", true)), "DTM is identified as LAT and non-navigation-grade")

	var open_water_position := georeference.geodetic_to_world(55.7, 12.75)
	var deep_query := provider.query_world_position(open_water_position)
	_expect(bool(deep_query.get("valid", false)) and str(deep_query.get("source", "")).contains("EMODnet"), "valid open-water sample uses DTM data")
	var deep_status := NavigationDepthProvider.evaluate_depth_sample(deep_query, 1.0, 0.5)
	_expect(str(deep_status.get("status", "")) == NavigationDepthProvider.STATUS_SAFE, "sufficient reference depth passes")

	var shallow_position := georeference.geodetic_to_world(55.60587, 12.96300)
	var shallow_query := provider.evaluate_world_position(shallow_position, 2.0)
	_expect(bool(shallow_query.get("valid", false)), "Malmö spawn depth is queried from the real DTM cache")
	_expect(str(shallow_query.get("status", "")) == NavigationDepthProvider.STATUS_CAUTION, "shallow DTM water produces a caution for the test draft")
	var unsafe_status := NavigationDepthProvider.evaluate_depth_sample({"valid": true, "depth_m": 0.6, "data_state": "water"}, 0.8, 0.5)
	_expect(str(unsafe_status.get("status", "")) == NavigationDepthProvider.STATUS_UNSAFE, "depth below draft is unsafe")
	var unknown_status := NavigationDepthProvider.evaluate_depth_sample({"valid": false, "data_state": "no_data"}, 0.8, 0.5)
	_expect(str(unknown_status.get("status", "")) == NavigationDepthProvider.STATUS_UNKNOWN, "missing data cannot be treated as safe")
	_expect(NavigationDepthProvider.worse_status(NavigationDepthProvider.STATUS_SAFE, NavigationDepthProvider.STATUS_UNKNOWN) == NavigationDepthProvider.STATUS_UNKNOWN, "aggregated checks preserve unknown as a blocking status")

	var land_position := georeference.geodetic_to_world(55.619, 12.977)
	var land_query := provider.query_world_position(land_position)
	_expect(not bool(land_query.get("valid", true)) and str(land_query.get("data_state", "")) == "land", "OSM land area is distinguished from water")
	var coast_edge_position := georeference.geodetic_to_world(55.7, 12.6)
	var coast_edge_query := provider.query_world_position(coast_edge_position)
	_expect(not bool(coast_edge_query.get("valid", true)) and str(coast_edge_query.get("data_state", "")) == "no_data", "water-side interpolation gap remains no-data, distinct from land")
	var outside_position := georeference.geodetic_to_world(55.7, 11.5)
	var outside_query := provider.query_world_position(outside_position)
	_expect(not bool(outside_query.get("valid", true)) and str(outside_query.get("data_state", "")) == "outside_coverage", "outside-grid data remains unknown")

	var original_draft := boat.get_current_draft_m()
	var maximum_cargo := boat.draft_profile.max_cargo_weight_kg
	boat.current_cargo_weight_kg = 0.0
	var empty_draft := boat.get_current_draft_m()
	boat.current_cargo_weight_kg = maximum_cargo
	var full_draft := boat.get_current_draft_m()
	_expect(full_draft > empty_draft, "empty and full-load drafts differ")
	boat.current_cargo_weight_kg = -100.0
	_expect(is_equal_approx(boat.get_current_draft_m(), empty_draft), "negative cargo weight clamps to empty load")
	boat.current_cargo_weight_kg = maximum_cargo * 4.0
	_expect(is_equal_approx(boat.get_current_draft_m(), full_draft), "overload clamps at full-load draft")
	boat.current_cargo_weight_kg = 0.0
	_expect(is_equal_approx(boat.get_current_draft_m(), empty_draft), "test cargo is restored")

	var test_anchor := open_water_position
	_expect(provider.register_polygon_override("test-low", test_anchor, test_polygon, 2.0, 5), "local test polygon registers")
	_expect(provider.register_polygon_override("test-high", test_anchor, test_polygon, 6.0, 10), "overlapping polygon registers")
	var override_query := provider.query_world_position(test_anchor)
	_expect(float(override_query.get("depth_m", 0.0)) == 6.0 and str(override_query.get("override_id", "")) == "test-high", "higher-priority local override wins")
	_expect(str(provider.query_world_position(open_water_position + Vector3(50.0, 0.0, 0.0)).get("source", "")).contains("EMODnet"), "local override does not change surrounding DTM data")
	provider.remove_depth_override("test-high")
	provider.remove_depth_override("test-low")
	var round_trip := georeference.world_to_geodetic(georeference.geodetic_to_world(55.619, 12.977))
	_expect(absf(round_trip.x - 55.619) < 0.000001 and absf(round_trip.y - 12.977) < 0.000001, "GeoReference forward/reverse conversion is consistent")

	var harbor_config: Dictionary = harbor.call("get_port_configuration")
	var berth_result: Dictionary = harbor.call("refresh_berth_depth_cache")
	var berth_samples: Array = berth_result.get("samples", [])
	_expect(berth_samples.size() == 5, "berth checks center plus four representative points")
	_expect(bool(berth_result.get("depth_ok", false)), "default berth gameplay depth supports the test vessel unloaded")
	for sample in berth_samples:
		var evaluation: Dictionary = sample.get("evaluation", {})
		_expect(bool(evaluation.get("valid", false)) and str(evaluation.get("override_id", "")).begins_with("malmo_"), "each berth sample uses a local, tagged gameplay override")

	var loaded_berth_polygon := PackedVector2Array([
		Vector2(-30.0, -30.0), Vector2(30.0, -30.0), Vector2(30.0, 30.0), Vector2(-30.0, 30.0),
	])
	_expect(provider.register_polygon_override("test_loaded_shallow_berth", harbor_config["berth_position"], loaded_berth_polygon, 1.0, 130), "shallow loaded-berth test override registers")
	boat.global_position = harbor_config["berth_position"]
	boat.global_rotation.y = deg_to_rad(float(harbor_config["berth_heading_degrees"]))
	boat.speed_mps = 0.0
	boat.is_motion_paused = false
	boat.current_cargo_weight_kg = maximum_cargo
	var loaded_berth: Dictionary = harbor.call("refresh_berth_depth_cache")
	var loaded_status: Dictionary = harbor.call("get_docking_diagnostics")
	_expect(not bool(loaded_berth.get("depth_ok", true)) and str(loaded_berth.get("status", "")) == NavigationDepthProvider.STATUS_CAUTION, "one-metre test berth lacks safety margin at loaded draft")
	_expect(not bool(loaded_status.get("can_dock", true)), "loaded vessel cannot dock at the shallow test berth")
	provider.remove_depth_override("test_loaded_shallow_berth")
	boat.current_cargo_weight_kg = 0.0
	harbor.call("refresh_berth_depth_cache")
	var unloaded_status: Dictionary = harbor.call("get_docking_diagnostics")
	_expect(bool(unloaded_status.get("can_dock", false)), "safe unloaded vessel retains Phase 1 docking")
	_expect(bool(harbor.call("request_dock")), "E-equivalent docking request still succeeds")
	_expect(boat.is_motion_paused and is_zero_approx(boat.speed_mps), "docking pauses boat motion")
	_expect(bool(harbor.call("request_undock")) and not boat.is_motion_paused, "undocking restores Phase 1 motion state")

	var center_sample: Dictionary = berth_samples[0]
	var center_position: Vector3 = center_sample["world_position"]
	var anchor_position: Vector3 = harbor_config["port_position"]
	var center_en := Vector2(center_position.x - anchor_position.x, -(center_position.z - anchor_position.z))
	var shallow_polygon := PackedVector2Array([
		center_en + Vector2(-1.0, -1.0), center_en + Vector2(1.0, -1.0),
		center_en + Vector2(1.0, 1.0), center_en + Vector2(-1.0, 1.0),
	])
	provider.register_polygon_override("test_shallow_berth", anchor_position, shallow_polygon, 0.2, 200)
	var blocked_berth: Dictionary = harbor.call("refresh_berth_depth_cache")
	_expect(not bool(blocked_berth.get("depth_ok", true)) and str(blocked_berth.get("status", "")) == NavigationDepthProvider.STATUS_UNSAFE, "one unsafe berth sample blocks the whole berth")
	provider.remove_depth_override("test_shallow_berth")
	harbor.call("refresh_berth_depth_cache")
	boat.current_cargo_weight_kg = 0.0
	boat.global_position = harbor_config["berth_position"]
	boat.global_rotation.y = deg_to_rad(float(harbor_config["berth_heading_degrees"]))
	boat.speed_mps = 0.0
	boat.speed_mps = 2.0
	var fast_status: Dictionary = harbor.call("get_docking_diagnostics")
	_expect(not bool(fast_status.get("can_dock", true)) and not bool(fast_status.get("speed_ok", true)), "high-speed docking rejection remains active")
	boat.speed_mps = 0.0
	boat.global_rotation.y += PI * 0.5
	var misaligned_status: Dictionary = harbor.call("get_docking_diagnostics")
	_expect(not bool(misaligned_status.get("can_dock", true)) and not bool(misaligned_status.get("heading_ok", true)), "heading rejection remains active")
	boat.global_rotation.y -= PI * 0.5
	boat.global_position += Vector3(20.0, 0.0, 0.0)
	var outside_status: Dictionary = harbor.call("get_docking_diagnostics")
	_expect(not bool(outside_status.get("can_dock", true)) and not bool(outside_status.get("position_ok", true)), "position rejection remains active")
	boat.current_cargo_weight_kg = 0.0
	_expect(original_draft >= 0.0, "configured vessel profile remains available")

	monitor.call("refresh_now")
	var monitor_snapshot: Dictionary = monitor.call("get_snapshot")
	_expect(monitor_snapshot.has("current") and monitor_snapshot.has("ahead"), "monitor provides current and predicted-position samples")
	var registered_overrides := provider.get_registered_overrides()
	var malmo_override_count := 0
	var copenhagen_override_count := 0
	for override in registered_overrides:
		var area_id := str(override.get("area_id", ""))
		if area_id.begins_with("malmo_"):
			malmo_override_count += 1
		elif area_id.begins_with("copenhagen_"):
			copenhagen_override_count += 1
	_expect(registered_overrides.size() == 6 and malmo_override_count == 3 and copenhagen_override_count == 3, "each port registers only its three bounded gameplay depth areas")
	harbor.queue_free()
	await process_frame
	var remaining_overrides := provider.get_registered_overrides()
	var only_copenhagen_remains := remaining_overrides.size() == 3
	for override in remaining_overrides:
		only_copenhagen_remains = only_copenhagen_remains and str(override.get("area_id", "")).begins_with("copenhagen_")
	_expect(only_copenhagen_remains, "freeing one harbor removes only its own depth overrides")

	main.queue_free()
	await process_frame
	if _failures == 0:
		print("Navigation depth tests passed.")
		quit(0)
	else:
		push_error("Navigation depth tests failed: %d" % _failures)
		quit(1)


func _expect(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		_failures += 1
		push_error("FAIL: %s" % description)


func _fail(message: String) -> void:
	_failures += 1
	push_error(message)
	quit(1)
