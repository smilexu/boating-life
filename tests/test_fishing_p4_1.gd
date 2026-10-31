extends SceneTree

const GEOREFERENCE := preload("res://resources/oresund_georeference.tres")
const WAVE_SETTINGS := preload("res://resources/sea_waves.tres")
const FISH_FINDER_DISPLAY_SCRIPT := preload("res://scripts/fish_finder_display.gd")
const SEA_TROUT_PROFILE := preload("res://resources/fish_species/sea_trout.tres")

class FinderTestBoat extends Node3D:
	var speed_mps := 0.0
	var sailing_active := false
	var sailing_body: Node3D

	func is_sailing_active() -> bool:
		return sailing_active

	func get_sailing_body() -> Node3D:
		return sailing_body if sailing_active else null


class FinderTestManager extends Node:
	var boat: Node3D
	var schools: Array[Dictionary] = []
	var game_time_seconds := 1234.0
	var query_count := 0
	var finder: FishFinderSensor

	func get_boat() -> Node3D:
		return boat

	func get_world_game_time_seconds() -> float:
		return game_time_seconds

	func get_fish_finder_sensor() -> FishFinderSensor:
		return finder

	func get_species_profile(species_id: String) -> FishSpeciesProfile:
		return SEA_TROUT_PROFILE if species_id == "sea_trout" else null

	func get_schools_near(world_position: Vector3, radius_m: float) -> Array[Dictionary]:
		query_count += 1
		var result: Array[Dictionary] = []
		for school in schools:
			var position_value: Variant = school.get("world_position", [])
			if not position_value is Array or position_value.size() < 3:
				result.append(school.duplicate(true))
				continue
			var position := Vector3(float(position_value[0]), float(position_value[1]), float(position_value[2]))
			if Vector2(position.x - world_position.x, position.z - world_position.z).length() <= radius_m:
				result.append(school.duplicate(true))
		return result


var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture_root := Node3D.new()
	fixture_root.name = "FishFinderP4TestFixture"
	root.add_child(fixture_root)
	var bathymetry := BathymetryManager.new()
	bathymetry.name = "BathymetryManager"
	bathymetry.georeference = GEOREFERENCE
	fixture_root.add_child(bathymetry)
	var wave_sampler := WaveSampler.new()
	wave_sampler.name = "WaveSampler"
	wave_sampler.wave_settings = WAVE_SETTINGS
	wave_sampler.bathymetry_manager_path = NodePath("../BathymetryManager")
	fixture_root.add_child(wave_sampler)
	var boat := FinderTestBoat.new()
	boat.name = "Powerboat"
	fixture_root.add_child(boat)
	var sailboat := Node3D.new()
	sailboat.name = "ActiveSailingVesselTest"
	fixture_root.add_child(sailboat)
	var manager := FinderTestManager.new()
	manager.boat = boat
	fixture_root.add_child(manager)
	var sensor := FishFinderSensor.new()
	sensor.name = "FishFinderSensor"
	sensor.configure(manager, boat, bathymetry, wave_sampler)
	manager.finder = sensor
	sensor.automatic_scanning_enabled = false
	sensor.history_capacity = 3
	sensor.minimum_history_seconds = 0.0
	fixture_root.add_child(sensor)
	for _frame in range(4):
		await process_frame
	wave_sampler.set_process(false)

	var open_water := Vector3(0.0, 0.0, 0.0)
	var chart_sample := bathymetry.get_depth_at_world_position(open_water)
	_check(bool(chart_sample.get("valid", false)) and float(chart_sample.get("depth_m", 0.0)) > 3.0, "fixture uses a valid charted-water sample")
	var wave_time := wave_sampler.wave_time_seconds
	var surface := wave_sampler.sample_physics_surface(open_water, wave_time)
	boat.global_position = Vector3(0.0, float(surface.get("height", 0.0)) + 0.55, 0.0)
	sensor.transducer_offset_local_m = Vector3(0.0, -0.55, 0.0)
	sensor.beam_half_cone_angle_deg = 10.0
	sensor.maximum_water_depth_m = 45.0
	sensor.max_slant_range_m = 220.0
	manager.schools = [{
		"school_id": "p4_test_school",
		"species_id": "sea_trout",
		"world_position": [0.0, 0.0, 0.0],
		"activity_depth_m": 2.0,
		"population": 16,
		"surface_activity_state": "inactive",
	}]

	var first_scan := sensor.scan(true)
	var first_echoes: Array = first_scan.get("echoes", [])
	var first_school_diagnostics: Array = first_scan.get("school_diagnostics", [])
	_check(bool(first_scan.get("valid", false)) and first_echoes.size() == 1, "a real-source-shaped school within the downward cone produces one aggregate echo")
	_check(not first_school_diagnostics.is_empty() and bool(first_school_diagnostics[0].get("hit", false)) and str(first_school_diagnostics[0].get("rejection_reason", "")) in ["partial_overlap", "school_volume_detected"], "scan diagnostics identify an Authority school volume under the beam")
	_check(float(first_school_diagnostics[0].get("beam_radius_m", 0.0)) > 0.0 and is_equal_approx(float(first_school_diagnostics[0].get("anchor_horizontal_distance_m", -1.0)), 0.0), "scan diagnostics expose probe-to-anchor distance and depth-specific beam radius")
	_check(str(first_echoes[0].get("school_id", "")) == "p4_test_school" and int(first_echoes[0].get("group_population", 0)) == 16, "echo uses stable school identity and actual group population")
	_check(is_equal_approx(float(first_echoes[0].get("group_intensity", -1.0)), 1.0 - exp(-2.0)) and float(first_echoes[0].get("echo_strength", -1.0)) > 0.0 and float(first_echoes[0].get("overlap_factor", 0.0)) > 0.0, "echo strength is deterministic and responds to population and spatial overlap")
	var repeated_scan := sensor.scan(true)
	var repeated_echo: Dictionary = repeated_scan.get("echoes", [])[0]
	_check(is_equal_approx(float(first_echoes[0].get("echo_strength", -1.0)), float(repeated_echo.get("echo_strength", -2.0))), "same school and scan geometry reproduce the same echo strength")
	_check(bool(first_echoes[0].get("echo_width_is_visual_proxy", false)), "echo width is explicitly identified as a display-only proxy")
	var edge_school := manager.schools[0].duplicate(true)
	edge_school["world_position"] = [5.9, 0.0, 0.0]
	manager.schools = [edge_school]
	var edge_scan := sensor.scan(true)
	var edge_echoes: Array = edge_scan.get("echoes", [])
	var edge_diagnostics: Array = edge_scan.get("school_diagnostics", [])
	_check(edge_echoes.size() == 1 and edge_diagnostics.size() == 1, "a partially overlapping school still emits only one aggregate echo")
	if not edge_echoes.is_empty() and not edge_diagnostics.is_empty():
		_check(float(edge_diagnostics[0].get("overlap_factor", 1.0)) < float(first_school_diagnostics[0].get("overlap_factor", 0.0)) and float(edge_echoes[0].get("echo_strength", 1.0)) < float(first_echoes[0].get("echo_strength", 0.0)), "school-edge overlap produces a weaker deterministic echo than a beam through its center")
	var center_school := manager.schools[0].duplicate(true)
	center_school["world_position"] = [0.0, 0.0, 0.0]
	manager.schools = [center_school]
	var display := FISH_FINDER_DISPLAY_SCRIPT.new() as Control
	display.name = "P4_1DisplayDataPathTest"
	display.call("configure", manager, boat)
	fixture_root.add_child(display)
	await process_frame
	var display_diagnostic: Dictionary = display.call("get_diagnostic_snapshot")
	var plot: Control = display.get("_plot")
	var plot_samples: Array = plot.get("samples") if plot != null else []
	var newest_plot_echoes: Array = plot_samples.back().get("echoes", []) if not plot_samples.is_empty() else []
	_check(int(display_diagnostic.get("echo_count", -1)) == 1 and newest_plot_echoes.size() == 1, "display reads an actual generated echo from immutable sensor history for drawing")
	display.queue_free()
	await process_frame
	_check(is_equal_approx(float(first_scan.get("scan_game_time_seconds", -1.0)), manager.game_time_seconds), "scan records shared world game time")
	_check(float(first_scan.get("scan_runtime_seconds", -1.0)) > 0.0 and str(first_scan.get("active_vessel_id", "")) == "powerboat", "scan records runtime time and current vessel identity")
	_check(float(first_scan.get("bottom_depth_below_transducer_m", -1.0)) > 0.0 and float(first_scan.get("chart_depth_lat_m", -1.0)) > 0.0, "bottom range separates chart datum from transducer depth")
	var recorded_strength := float(sensor.get_scan_history().back().get("echoes", [])[0].get("echo_strength", -1.0))
	first_echoes[0]["echo_strength"] = 0.0
	_check(is_equal_approx(float(sensor.get_scan_history().back().get("echoes", [])[0].get("echo_strength", -1.0)), recorded_strength), "recorded scan columns do not change when a caller edits its returned dictionary")

	var school := manager.schools[0]
	school["world_position"] = [10.0, 0.0, 0.0]
	manager.schools = [school]
	var outside_scan := sensor.scan(true)
	var outside_diagnostics: Array = outside_scan.get("school_diagnostics", [])
	_check(bool(outside_scan.get("valid", false)) and outside_scan.get("echoes", []).is_empty(), "a school wholly outside both the fixed cone and its distribution proxy produces no echo")
	_check(not outside_diagnostics.is_empty() and not bool(outside_diagnostics[0].get("hit", true)) and str(outside_diagnostics[0].get("rejection_reason", "")) == "outside_school_volume" and str(outside_diagnostics[0].get("anchor_geometry_reason", "")) == "outside_beam", "out-of-volume school reports both anchor geometry and spatial exclusion")
	var anchor_geometry := FishFinderSensor.diagnose_target_geometry(Vector3(0.0, -0.5, 0.0), 10.0, 45.0, 220.0)
	var displaced_visual_geometry := FishFinderSensor.diagnose_target_geometry(Vector3(0.5, -0.5, 0.0), 10.0, 45.0, 220.0)
	_check(bool(anchor_geometry.get("hit", false)) and str(displaced_visual_geometry.get("reason", "")) == "outside_beam", "diagnostic distinguishes an in-beam anchor from a rendered individual displaced beyond the same shallow cone")
	_check(sensor.get_scan_history().size() >= 2 and not sensor.get_scan_history()[0].get("echoes", []).is_empty(), "old echo remains in history after the current scan loses the school")
	_check(is_equal_approx(FishFinderSensor.scan_radius_for_depth(10.0, 10.0) / FishFinderSensor.scan_radius_for_depth(1.0, 10.0), 10.0), "beam coverage radius grows linearly with target depth")
	manager.schools = [{"school_id": "malformed_school", "population": 4, "activity_depth_m": 2.0}]
	var malformed_scan := sensor.scan(true)
	_check(bool(malformed_scan.get("valid", false)) and malformed_scan.get("echoes", []).is_empty(), "malformed school positions are ignored without creating invalid echoes")

	manager.schools.clear()
	var empty_scan := sensor.scan(true)
	_check(bool(empty_scan.get("valid", false)) and empty_scan.get("echoes", []).is_empty(), "valid water with no schools creates an empty sonar column")
	var before_switch_origin: Vector3 = empty_scan.get("scan_origin_world_position", Vector3.ZERO)
	manager.boat = boat
	boat.sailing_active = true
	boat.sailing_body = sailboat
	sailboat.global_position = Vector3(0.0, float(surface.get("height", 0.0)) + 1.0, 0.0)
	var switched_scan := sensor.scan(true)
	var expected_switched_origin: Vector3 = sailboat.global_transform * sensor.transducer_offset_local_m
	_check(str(switched_scan.get("active_vessel_id", "")) == "active_sailing_vessel_test" and switched_scan.get("scan_origin_world_position", Vector3.ZERO).is_equal_approx(expected_switched_origin) and switched_scan.get("probe_world_position", Vector3.ZERO).is_equal_approx(expected_switched_origin), "active sailing vessel switch updates both scan and probe origin without using the old hull")
	_check(not before_switch_origin.is_equal_approx(expected_switched_origin), "active-vessel transducer position changes with the selected hull")

	boat.sailing_active = false
	boat.global_position = Vector3(1000000.0, 0.0, 1000000.0)
	var invalid_scan := sensor.scan(true)
	_check(not bool(invalid_scan.get("valid", true)) and not bool(invalid_scan.get("bottom_valid", true)) and invalid_scan.get("echoes", []).is_empty(), "missing chart data yields explicit invalid bottom data and no fabricated echo")
	_check(float(invalid_scan.get("bottom_depth_below_transducer_m", 0.0)) < 0.0, "invalid bottom uses the documented negative sentinel")

	sensor.automatic_scanning_enabled = true
	boat.global_position = Vector3(0.0, float(surface.get("height", 0.0)) + 0.55, 0.0)
	boat.speed_mps = 0.0
	manager.boat = boat
	manager.schools.clear()
	var last_id_before_auto := int(sensor.get_last_scan().get("scan_id", 0))
	await create_timer(0.8).timeout
	var last_scan_after_auto := sensor.get_last_scan()
	_check(int(last_scan_after_auto.get("scan_id", 0)) >= last_id_before_auto + 2, "sensor continues scanning at roughly 3 Hz while vessel speed is zero")
	_check(sensor.get_scan_history().size() <= 3 and sensor.get_scan_history().size() == sensor.history_capacity, "rolling history is bounded by configured capacity")
	_check(sensor.get_history_coverage_seconds() > 0.4, "bounded history stores monotonic scan times for scrolling display")
	_check(manager.query_count > 0, "sensor reuses the manager spatial query rather than enumerating the full world")
	var original_locale := TranslationServer.get_locale()
	TranslationServer.set_locale("en")
	_check(tr("fishing.debug.finder_reason.outside_beam") == "outside cone footprint" and tr("fishing.debug.finder_school_row").begins_with("School "), "sonar diagnostic labels and rejection reasons resolve in English")
	TranslationServer.set_locale("zh_CN")
	_check(tr("fishing.debug.finder_reason.outside_beam") == "在声束覆盖外" and tr("fishing.debug.finder_school_row").begins_with("鱼群 "), "sonar diagnostic labels and rejection reasons resolve in Simplified Chinese")
	TranslationServer.set_locale(original_locale)

	print("[FISHING_P4_1] failures=%d" % _failures)
	fixture_root.queue_free()
	await process_frame
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[FISHING_P4_1][PASS] %s" % message)
	else:
		_failures += 1
		push_error("[FISHING_P4_1][FAIL] %s" % message)
