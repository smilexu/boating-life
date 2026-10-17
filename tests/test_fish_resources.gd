extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var start_usec := Time.get_ticks_usec()
	var main_root := MAIN_SCENE.instantiate()
	root.add_child(main_root)
	await process_frame
	var manager := main_root.get_node("FishResourceManager") as FishResourceManager
	var bathymetry := manager.get_bathymetry_manager()
	var georeference := manager.get_georeference()
	_check(manager.get_all_school_snapshots().size() > 0, "local authority generated fish resources")
	_check(manager.get_species_profiles().size() == 3, "three species profiles loaded")
	_check(bathymetry != null and bathymetry.data_available, "existing EMODnet bathymetry loaded")
	_check(georeference != null, "existing GeoReference loaded")
	if bathymetry == null or georeference == null:
		_finish()
		return

	var profiles := manager.get_species_profiles()
	var first_authority := FishLocalAuthority.new()
	var authority_init_usec := Time.get_ticks_usec()
	first_authority.initialize(manager.get_world_seed(), bathymetry, georeference, profiles)
	authority_init_usec = Time.get_ticks_usec() - authority_init_usec
	var first_snapshot := first_authority.create_snapshot()
	var second_authority := FishLocalAuthority.new()
	second_authority.initialize(manager.get_world_seed(), bathymetry, georeference, profiles)
	var second_snapshot := second_authority.create_snapshot()
	_check(_snapshot_layouts_equal(first_snapshot, second_snapshot), "initial resources are deterministic for the same seed")
	_check(first_authority.restore_snapshot(first_snapshot), "authority snapshot restores")
	var wrong_layout: Dictionary = first_snapshot.duplicate(true)
	wrong_layout["layout_version"] = 99
	_check(not first_authority.restore_snapshot(wrong_layout), "unsupported layout snapshots are rejected")

	var species_counts := {"needlefish": 0, "herring": 0, "three_spined_stickleback": 0}
	var invalid_school_count := 0
	var unsuitable_school_count := 0
	var seagrass_proxy_school_count := 0
	var stickleback_small_groups := 0
	var stickleback_common_groups := 0
	var stickleback_large_groups := 0
	var stickleback_school_count := 0
	var stickleback_bad_depth_count := 0
	var nearest_shallow_stickleback: Dictionary = {}
	var nearest_stickleback_distance := INF
	var all_schools := manager.get_all_school_snapshots()
	var boat := main_root.get_node("PlayerBoat/MotionRoot") as Node3D
	for school in all_schools:
		var profile := manager.get_species_profile(str(school["species_id"]))
		var position_data: Array = school["world_position"]
		var position := Vector3(float(position_data[0]), 0.0, float(position_data[2]))
		var sample := bathymetry.get_depth_at_world_position(position)
		if not bool(sample.get("valid", false)):
			invalid_school_count += 1
		if bool(sample.get("valid", false)):
			if profile.suitability_for_depth(float(sample["depth_m"])) <= 0.0:
				unsuitable_school_count += 1
		species_counts[str(school["species_id"])] = int(species_counts.get(str(school["species_id"]), 0)) + 1
		if str(school["species_id"]) == "three_spined_stickleback":
			stickleback_school_count += 1
			var population := int(school.get("population", 0))
			if population >= 5 and population <= 10:
				stickleback_small_groups += 1
			elif population >= 12 and population <= 25:
				stickleback_common_groups += 1
			elif population >= 26 and population <= 40:
				stickleback_large_groups += 1
			var chart_depth := float(school.get("depth_m", 0.0))
			if chart_depth < 0.8 or chart_depth > 6.0:
				stickleback_bad_depth_count += 1
			var world_delta := Vector2(position.x - boat.global_position.x, position.z - boat.global_position.z).length()
			if chart_depth >= 1.3 and chart_depth <= 3.3 and world_delta < nearest_stickleback_distance:
				nearest_stickleback_distance = world_delta
				nearest_shallow_stickleback = school
		if str(school.get("habitat_region", "")) == "coastal_eelgrass_proxy":
			seagrass_proxy_school_count += 1
	_check(species_counts["needlefish"] > 0, "needlefish resources exist in the map region")
	_check(species_counts["herring"] > 0, "herring resources exist in the map region")
	_check(species_counts["three_spined_stickleback"] > 0, "stickleback resources exist in the map region")
	_check(invalid_school_count == 0, "all generated school locations pass real water and land-mask validation")
	_check(unsuitable_school_count == 0, "all generated schools satisfy their profile depth rules")
	_check(seagrass_proxy_school_count > 0, "some stickleback resources align with deterministic eelgrass meadow habitat")
	var stickleback_profile := manager.get_species_profile("three_spined_stickleback")
	_check(stickleback_profile != null and is_equal_approx(stickleback_profile.maximum_depth_m, 6.0), "stickleback habitat is restricted to the 0-6 m shallows")
	_check(stickleback_school_count > 0 and stickleback_bad_depth_count == 0, "all stickleback resource anchors are inside the usable shallow range")
	_check(stickleback_small_groups > 0 and stickleback_common_groups > 0 and stickleback_large_groups > 0, "deterministic stickleback schools include small, common and large size classes")
	_check(not nearest_shallow_stickleback.is_empty(), "a 1.3-3.3 m stickleback school exists for local observation")
	print("[FISH_TEST] stickleback schools=%d population_tiers={small:%d common:%d large:%d}; nearest_shallow_distance_m=%.1f school=%s" % [stickleback_school_count, stickleback_small_groups, stickleback_common_groups, stickleback_large_groups, nearest_stickleback_distance, str(nearest_shallow_stickleback.get("school_id", "none"))])
	_check(manager.get_map_distribution(["herring"]).all(func(school: Dictionary) -> bool: return str(school["species_id"]) == "herring"), "map filter returns only the selected species")

	var nearby := manager.get_schools_near(boat.global_position, 1200.0)
	var nearby_by_species := {"needlefish": 0, "herring": 0, "three_spined_stickleback": 0}
	for school in nearby:
		var id := str(school["species_id"])
		nearby_by_species[id] = int(nearby_by_species.get(id, 0)) + 1
	print("[FISH_TEST] regional species counts=%s; schools within 1200m of boat=%s" % [species_counts, nearby_by_species])
	var revision_before_step := first_authority.get_state_revision()
	var simulation_start_usec := Time.get_ticks_usec()
	var worst_simulation_frame_usec := 0
	var simulation_delta := FishLocalAuthority.SIMULATION_STEP_SECONDS
	var frame_count := 0
	while first_authority.get_state_revision() == revision_before_step and frame_count < 100:
		var frame_start_usec := Time.get_ticks_usec()
		first_authority.update(simulation_delta)
		worst_simulation_frame_usec = maxi(worst_simulation_frame_usec, Time.get_ticks_usec() - frame_start_usec)
		simulation_delta = 0.016
		frame_count += 1
		await process_frame
	var simulation_update_usec := Time.get_ticks_usec() - simulation_start_usec
	_check(first_authority.get_state_revision() > revision_before_step, "8 second school simulation step completes incrementally")

	for profile in profiles:
		_check(profile.model_forward_axis in [0, 1], "%s has an explicit model forward axis" % profile.species_id)
		_check((profile.model_head_x < 0.0) == (profile.model_forward_axis == 1), "%s head position matches its configured GLB forward axis" % profile.species_id)
		var expected_forward := Vector3(0.6, 0.0, 0.8).normalized()
		var orientation_basis := FishSchoolRenderer.basis_for_model_heading(expected_forward, profile.model_forward_axis)
		var model_nose_axis := Vector3.LEFT if profile.model_forward_axis == 1 else Vector3.RIGHT
		var world_nose_axis := (orientation_basis * model_nose_axis).normalized()
		_check(world_nose_axis.dot(expected_forward) > 0.999, "%s model nose points along its world travel direction" % profile.species_id)
		var packed := ResourceLoader.load(profile.model_path) as PackedScene
		_check(packed != null, "%s optimized GLB imports as PackedScene" % profile.species_id)
		if packed == null:
			continue
		var model := packed.instantiate()
		var mesh_nodes := model.find_children("*", "MeshInstance3D", true, false)
		_check(not mesh_nodes.is_empty(), "%s contains a renderable mesh" % profile.species_id)
		if not mesh_nodes.is_empty():
			var mesh_instance := mesh_nodes[0] as MeshInstance3D
			_check(mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0, "%s mesh has surfaces" % profile.species_id)
			if mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0:
				var material := mesh_instance.mesh.surface_get_material(0) as BaseMaterial3D
				_check(material != null and material.albedo_texture != null, "%s GLB carries a base-color texture" % profile.species_id)
		model.free()

	var resource_map := main_root.get_node("FishResourceMap") as FishResourceMap
	var map_canvas := resource_map.find_child("ResourceDistributionMap", true, false) as FishResourceMapCanvas
	var map_key := InputEventKey.new()
	map_key.physical_keycode = KEY_F4
	map_key.pressed = true
	manager._unhandled_key_input(map_key)
	_check(resource_map.is_map_open(), "F4 key toggles the fish resource map")
	var raster_wait_start_usec := Time.get_ticks_usec()
	var raster_frame_max_usec := 0
	while not map_canvas.is_raster_ready() and Time.get_ticks_usec() - raster_wait_start_usec < 5000000:
		var frame_start_usec := Time.get_ticks_usec()
		await process_frame
		raster_frame_max_usec = maxi(raster_frame_max_usec, Time.get_ticks_usec() - frame_start_usec)
	var raster_stats := map_canvas.get_raster_build_statistics()
	_check(map_canvas.is_raster_ready(), "F4 offline bathymetry raster completes incrementally")
	_check(float(raster_stats.get("maximum_slice_ms", INF)) < 12.0, "F4 raster work is spread across short frame slices")
	print("[FISH_TEST] map_raster=%s; waited_ms=%.2f; worst_frame_wait_ms=%.2f" % [raster_stats, float(Time.get_ticks_usec() - raster_wait_start_usec) / 1000.0, float(raster_frame_max_usec) / 1000.0])
	resource_map.set_map_open(true)
	_check(resource_map.is_map_open() and map_canvas != null, "F4 fish resource layer opens")
	_check(map_canvas != null and map_canvas.get_school_count() > 0, "F4 layer reads resource points from FishResourceManager")
	manager._unhandled_key_input(map_key)
	_check(not resource_map.is_map_open(), "F4 key closes the fish resource map")

	var renderer := main_root.get_node("FishResourceManager/FishSchoolRenderer") as FishSchoolRenderer
	await create_timer(0.5).timeout
	var render_stats := renderer.get_render_statistics()
	_check(int(render_stats.get("multimesh_batches", 0)) == 3, "renderer builds one MultiMesh batch per fish species")
	_check(renderer.smooth_motion_enabled, "fish visual interpolation is enabled by default")
	_check(is_equal_approx(float(render_stats.get("movement_update_hz", 0.0)), 6.25), "fish behavior tick remains at 6.25 Hz")
	var start_transform := Transform3D(Basis(Vector3.UP, deg_to_rad(170.0)), Vector3(0.0, -2.0, 0.0))
	var end_transform := Transform3D(Basis(Vector3.UP, deg_to_rad(-170.0)), Vector3(4.0, -2.0, 0.0))
	var middle_transform := FishSchoolRenderer.interpolate_visual_transform(start_transform, end_transform, 0.5)
	_check(middle_transform.origin.is_equal_approx(Vector3(2.0, -2.0, 0.0)), "visual interpolation advances linearly to the midpoint")
	var middle_forward := (middle_transform.basis.orthonormalized() * Vector3.FORWARD).normalized()
	_check(middle_forward.dot(Vector3.BACK) > 0.99, "heading interpolation takes the short path across the angle wrap")
	_check(FishSchoolRenderer.interpolate_visual_transform(start_transform, end_transform, -1.0).origin.is_equal_approx(start_transform.origin), "visual interpolation clamps below zero")
	_check(FishSchoolRenderer.interpolate_visual_transform(start_transform, end_transform, 2.0).origin.is_equal_approx(end_transform.origin), "visual interpolation clamps above one")
	var authority_sample_a := {"authoritative_timestamp": 100.0, "world_position": [0.0, 0.0, 0.0], "direction_radians": deg_to_rad(170.0)}
	var authority_sample_b := {"authoritative_timestamp": 101.7, "world_position": [8.5, 0.0, 0.0], "direction_radians": deg_to_rad(-170.0), "world_velocity": [2.0, 0.0, 0.0]}
	var authority_midpoint := FishSchoolRenderer.interpolate_authoritative_school_motion(authority_sample_a, authority_sample_b, 100.85)
	_check(is_equal_approx(float(authority_midpoint["world_position"][0]), 4.25), "future authority interpolation uses sample timestamps rather than a fixed arrival interval")
	_check(float(authority_midpoint["direction_radians"]) > deg_to_rad(179.0) or float(authority_midpoint["direction_radians"]) < deg_to_rad(-179.0), "future authority heading also uses shortest-angle interpolation")
	var authority_prediction := FishSchoolRenderer.interpolate_authoritative_school_motion(authority_sample_a, authority_sample_b, 102.7, 0.25)
	_check(is_equal_approx(float(authority_prediction["world_position"][0]), 9.0), "future authority prediction is bounded to the configured horizon")
	var hud := main_root.get_node("PlayerBoat/BoatHUD") as CanvasLayer
	var smoothing_toggle := hud.find_child("FishSmoothMotionToggle", true, false) as CheckButton
	_check(smoothing_toggle != null, "F3 exposes the fish smooth-motion A/B toggle")
	if smoothing_toggle != null:
		smoothing_toggle.set_pressed_no_signal(false)
		hud.call("_on_fish_smoothing_toggled", false)
		_check(not renderer.smooth_motion_enabled, "F3 A/B toggle disables visual interpolation")
		smoothing_toggle.set_pressed_no_signal(true)
		hud.call("_on_fish_smoothing_toggled", true)
		_check(renderer.smooth_motion_enabled, "F3 A/B toggle restores visual interpolation")
	var vertical_test_passed := 0
	var vertical_test_count := 0
	var wave_sampler := main_root.get_node("WaveSampler") as WaveSampler
	if not nearby.is_empty():
		var school: Dictionary = nearby[0]
		var profile := manager.get_species_profile(str(school["species_id"]))
		var test_records := renderer._build_school_fish(school, profile, mini(12, int(school["population"])), 0.16, 1.0, {})
		if not test_records.is_empty():
			var individual_key := str(test_records[0]["individual_key"])
			var individual_state: Dictionary = renderer._individual_states[individual_key]
			var previous_endpoint: Transform3D = individual_state["visual_to_transform"]
			var next_records := renderer._build_school_fish(school, profile, mini(12, int(school["population"])), 0.16, 1.16, {})
			_check(not next_records.is_empty(), "second low-frequency movement tick returns the active individual")
			individual_state = renderer._individual_states[individual_key]
			var next_endpoint: Transform3D = individual_state["visual_to_transform"]
			var buffered_start: Transform3D = individual_state["visual_from_transform"]
			_check(buffered_start.origin.is_equal_approx(previous_endpoint.origin), "each AI tick starts visual interpolation from the prior endpoint")
			var rendered_midpoint := FishSchoolRenderer.interpolate_visual_transform(buffered_start, next_endpoint, 0.5)
			var segment_midpoint := buffered_start.origin.lerp(next_endpoint.origin, 0.5)
			_check(rendered_midpoint.origin.is_equal_approx(segment_midpoint), "visible fish transform follows the stored continuous path between AI ticks")
		for record in test_records:
			var fish_position: Vector3 = record["transform"].origin
			var depth_data := bathymetry.get_depth_at_world_position(fish_position)
			if not bool(depth_data.get("valid", false)):
				continue
			vertical_test_count += 1
			var surface_height := float(wave_sampler.sample_surface(fish_position, wave_sampler.wave_time_seconds).get("height", 0.0))
			var depth_m := float(depth_data.get("depth_m", 0.0))
			if fish_position.y < surface_height - 0.06 and fish_position.y > surface_height - depth_m + 0.06:
				vertical_test_passed += 1
	_check(vertical_test_count > 0, "client generated school transforms for local fish")
	_check(vertical_test_passed == vertical_test_count, "client fish transforms remain between sampled wave surface and seabed")
	if not nearest_shallow_stickleback.is_empty() and stickleback_profile != null:
		var saved_boat_position := boat.global_position
		var stickleback_position_values: Array = nearest_shallow_stickleback["world_position"]
		var stickleback_center := Vector3(float(stickleback_position_values[0]), 0.0, float(stickleback_position_values[2]))
		boat.global_position = stickleback_center + Vector3(100.0, 0.0, 0.0)
		var stickle_count := mini(24, int(nearest_shallow_stickleback["population"]))
		var stickle_depth_cache: Dictionary = {}
		var stickle_surface_cache: Dictionary = {}
		var stickle_records := renderer._build_school_fish(nearest_shallow_stickleback, stickleback_profile, stickle_count, 0.16, 1.0, stickle_depth_cache, stickle_surface_cache)
		_check(stickle_records.size() == stickle_count, "selected stickleback school produces all visible individuals in usable shallow water")
		var min_length := INF
		var max_length := 0.0
		var near_surface_visits := 0
		var size_sum := 0.0
		var stickleback_core_count := 0
		var stickleback_max_radius := 0.0
		var fish_visual: Dictionary = renderer._species_visuals["three_spined_stickleback"]
		var stickle_mesh: Mesh = fish_visual["mesh"]
		var stickle_aabb := stickle_mesh.get_aabb()
		var model_transform: Transform3D = fish_visual["model_transform"]
		var visible_transform: Transform3D = stickle_records[0]["transform"] if not stickle_records.is_empty() else Transform3D.IDENTITY
		var actual_mesh_length := stickle_aabb.size.x * model_transform.basis.x.length() * visible_transform.basis.x.length()
		for record in stickle_records:
			var fish_position: Vector3 = record["transform"].origin
			var formation_radius := Vector2(fish_position.x - stickleback_center.x, fish_position.z - stickleback_center.z).length()
			stickleback_max_radius = maxf(stickleback_max_radius, formation_radius)
			if formation_radius <= 1.05:
				stickleback_core_count += 1
			var fish_state: Dictionary = renderer._individual_states[str(record["individual_key"])]
			var fish_length := float(fish_state.get("visual_length_m", 0.0))
			min_length = minf(min_length, fish_length)
			max_length = maxf(max_length, fish_length)
			size_sum += fish_length
			var water_surface := float(wave_sampler.sample_surface(fish_position, wave_sampler.wave_time_seconds).get("height", 0.0))
			var distance_from_surface := water_surface - fish_position.y
			if distance_from_surface >= 0.25 and distance_from_surface <= 0.66:
				near_surface_visits += 1
			var local_depth_data := bathymetry.get_depth_at_world_position(fish_position)
			if bool(local_depth_data.get("valid", false)):
				_check(fish_position.y > water_surface - float(local_depth_data["depth_m"]) + 0.04, "stickleback has positive seabed clearance")
		_check(near_surface_visits > 0, "some sticklebacks make near-surface visits without reaching the surface")
		_check(stickleback_max_radius <= stickleback_profile.school_activity_radius_m, "stickleback school remains inside its 2.8 m activity zone")
		_check(stickleback_core_count >= ceili(float(stickle_records.size()) * 0.5), "most sticklebacks form a recognizable 1.05 m inner school core")
		print("[FISH_TEST] stickleback_mesh_aabb=%s actual_first_length_cm=%.1f visuals=%d mean_length_cm=%.1f range_cm=%.1f-%.1f near_surface=%d core=%d max_radius=%.2fm selected=%s" % [stickle_aabb.size, actual_mesh_length * 100.0, stickle_records.size(), size_sum / maxf(float(stickle_records.size()), 1.0) * 100.0, min_length * 100.0, max_length * 100.0, near_surface_visits, stickleback_core_count, stickleback_max_radius, str(nearest_shallow_stickleback["school_id"])])
		var first_stickle_key := str(stickle_records[0]["individual_key"]) if not stickle_records.is_empty() else ""
		var depth_before := float(renderer._individual_states.get(first_stickle_key, {}).get("swim_depth_m", 0.0))
		for tick in range(70):
			stickle_surface_cache.clear()
			renderer._build_school_fish(nearest_shallow_stickleback, stickleback_profile, stickle_count, 0.16, 1.16 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
		var depth_after := float(renderer._individual_states.get(first_stickle_key, {}).get("swim_depth_m", 0.0))
		_check(absf(depth_after - depth_before) > 0.01, "stickleback vertical activity changes gradually across low-frequency behavior ticks")
		var radius_before_evasion := 0.0
		for index in range(stickle_count):
			var key := "%s:%d" % [str(nearest_shallow_stickleback["school_id"]), index]
			var initial_fish_state: Dictionary = renderer._individual_states[key]
			var initial_local_position: Vector2 = initial_fish_state.get("local_position", Vector2.ZERO)
			radius_before_evasion += initial_local_position.length()
		radius_before_evasion /= maxf(float(stickle_count), 1.0)
		boat.global_position = stickleback_center
		for tick in range(16):
			stickle_depth_cache.clear()
			stickle_surface_cache.clear()
			renderer._build_school_fish(nearest_shallow_stickleback, stickleback_profile, stickle_count, 0.16, 5.0 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
		var fleeing_count := 0
		var shallow_evasion_count := 0
		var radius_after_evasion := 0.0
		for index in range(stickle_count):
			var key := "%s:%d" % [str(nearest_shallow_stickleback["school_id"]), index]
			var fish_state: Dictionary = renderer._individual_states.get(key, {})
			if str(fish_state.get("behavior_state", "")) == "flee":
				fleeing_count += 1
			if float(fish_state.get("depth_target_m", INF)) <= stickleback_profile.flee_swim_depth_m.y:
				shallow_evasion_count += 1
			var evaded_local_position: Vector2 = fish_state.get("local_position", Vector2.ZERO)
			radius_after_evasion += evaded_local_position.length()
		radius_after_evasion /= maxf(float(stickle_count), 1.0)
		_check(fleeing_count == stickle_count, "boat overhead triggers lateral evasion for the whole stickleback school")
		_check(shallow_evasion_count == stickle_count, "panicked sticklebacks stay in the shallow visible layer instead of diving into seagrass")
		_check(radius_after_evasion > radius_before_evasion + 0.05, "boat disturbance spreads sticklebacks outward without moving their shared school anchor")
		var recovery_start_distance := 0.0
		boat.global_position = stickleback_center + Vector3(100.0, 0.0, 0.0)
		for tick in range(16):
			stickle_depth_cache.clear()
			stickle_surface_cache.clear()
			renderer._build_school_fish(nearest_shallow_stickleback, stickleback_profile, stickle_count, 0.16, 8.0 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
		var regrouping_count := 0
		for index in range(stickle_count):
			var key := "%s:%d" % [str(nearest_shallow_stickleback["school_id"]), index]
			if str(renderer._individual_states.get(key, {}).get("disturbance_state", "")) == "recovering":
				regrouping_count += 1
		_check(regrouping_count == stickle_count, "sticklebacks enter a visible recovering phase after the boat passes and threat decays")
		recovery_start_distance = _mean_stickleback_pair_distance(renderer, str(nearest_shallow_stickleback["school_id"]), stickle_count)
		for tick in range(48):
			stickle_depth_cache.clear()
			stickle_surface_cache.clear()
			renderer._build_school_fish(nearest_shallow_stickleback, stickleback_profile, stickle_count, 0.16, 10.56 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
		var recovery_end_distance := _mean_stickleback_pair_distance(renderer, str(nearest_shallow_stickleback["school_id"]), stickle_count)
		_check(recovery_end_distance < recovery_start_distance, "sticklebacks gradually return toward their original formation after the boat passes")
		var two_threats: Array[Dictionary] = [
			{"id": "simulated_boat_left", "world_position": stickleback_center + Vector3(-10.0, 0.0, 0.0), "velocity": Vector3(7.0, 0.0, 0.0)},
			{"id": "simulated_boat_right", "world_position": stickleback_center + Vector3(10.0, 0.0, 0.0), "velocity": Vector3(-7.0, 0.0, 0.0)},
		]
		_check(manager.set_authoritative_disturbance_snapshot(two_threats), "authority can supply a shared multi-boat threat snapshot")
		for tick in range(16):
			stickle_depth_cache.clear()
			stickle_surface_cache.clear()
			renderer._build_school_fish(nearest_shallow_stickleback, stickleback_profile, stickle_count, 0.16, 20.0 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
		var multi_threat_scattering_count := 0
		for index in range(stickle_count):
			var key := "%s:%d" % [str(nearest_shallow_stickleback["school_id"]), index]
			if str(renderer._individual_states.get(key, {}).get("disturbance_state", "")) == "scattering":
				multi_threat_scattering_count += 1
		_check(multi_threat_scattering_count == stickle_count, "multiple approaching boats can trigger the shared scattering response")
		var remaining_threat: Array[Dictionary] = [
			{"id": "simulated_boat_right", "world_position": stickleback_center, "velocity": Vector3.ZERO},
		]
		manager.set_authoritative_disturbance_snapshot(remaining_threat)
		for tick in range(12):
			stickle_depth_cache.clear()
			stickle_surface_cache.clear()
			renderer._build_school_fish(nearest_shallow_stickleback, stickleback_profile, stickle_count, 0.16, 22.56 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
		var remaining_threat_scattering_count := 0
		for index in range(stickle_count):
			var key := "%s:%d" % [str(nearest_shallow_stickleback["school_id"]), index]
			if str(renderer._individual_states.get(key, {}).get("disturbance_state", "")) == "scattering":
				remaining_threat_scattering_count += 1
		_check(remaining_threat_scattering_count == stickle_count, "one nearby vessel prevents premature regrouping after another leaves")
		manager.set_authoritative_disturbance_snapshot([])
		for tick in range(16):
			stickle_depth_cache.clear()
			stickle_surface_cache.clear()
			renderer._build_school_fish(nearest_shallow_stickleback, stickleback_profile, stickle_count, 0.16, 24.48 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
		var no_threat_recovering_count := 0
		for index in range(stickle_count):
			var key := "%s:%d" % [str(nearest_shallow_stickleback["school_id"]), index]
			if str(renderer._individual_states.get(key, {}).get("disturbance_state", "")) == "recovering":
				no_threat_recovering_count += 1
		_check(no_threat_recovering_count == stickle_count, "the school begins recovering after all authoritative threats leave")
		renderer.use_local_disturbance_sources()
		boat.global_position = saved_boat_position
		var selected_school_id_before := str(nearest_shallow_stickleback["school_id"])
		var selected_school_before := manager.get_school(selected_school_id_before)
		var selected_world_position_before: Array = selected_school_before.get("world_position", [])
		hud.call("_on_fish_observation_pressed", "three_spined_stickleback")
		var selected_school_id := str(hud.get("_selected_fish_school_id"))
		var selected_after_teleport := manager.get_school(selected_school_id)
		var selected_world_position_after: Array = selected_after_teleport.get("world_position", [])
		var boat_to_selected_school := Vector2(boat.global_position.x - float(selected_world_position_after[0]), boat.global_position.z - float(selected_world_position_after[2])).length() if selected_world_position_after.size() == 3 else INF
		_check(boat_to_selected_school < 1.0, "F3 stickleback command places the boat directly over its real school anchor")
		_check(selected_school_id == selected_school_id_before and selected_world_position_before == selected_world_position_after, "overhead observation does not move the shared fish school")
		await create_timer(0.5).timeout
		_check(renderer.is_observation_active(), "F3 stickleback observation follows the real school underwater")
		var selected_visual_stats := renderer.get_school_visual_debug(selected_school_id)
		_check(not selected_school_id.is_empty() and not selected_visual_stats.is_empty(), "F3 selected stickleback school is prioritized and produces visible instances")
		if not selected_visual_stats.is_empty():
			_check(int(selected_visual_stats.get("visible_fish", 0)) >= mini(5, int(selected_visual_stats.get("school_population", 0))), "overhead F3 observation keeps the school visible instead of culling fish under the boat")
			var observation_behaviors: Dictionary = selected_visual_stats.get("behavior_counts", {})
			_check(int(observation_behaviors.get("scattering", 0)) > 0, "F3 uses the same visible shallow-water evasion as normal boat approaches")
	print("[FISH_TEST] renderer=%s; init_elapsed_ms=%.1f" % [render_stats, float(Time.get_ticks_usec() - start_usec) / 1000.0])
	print("[FISH_TEST] authority=%s; revision=%d; schools=%d; deterministic_init_ms=%.2f; step_total_ms=%.2f; worst_budgeted_frame_ms=%.2f; step_frames=%d" % [manager.get_authority_source(), manager.get_state_revision(), all_schools.size(), float(authority_init_usec) / 1000.0, float(simulation_update_usec) / 1000.0, float(worst_simulation_frame_usec) / 1000.0, frame_count])
	_finish()


func _snapshot_layouts_equal(a: Dictionary, b: Dictionary) -> bool:
	var schools_a: Array = a.get("schools", [])
	var schools_b: Array = b.get("schools", [])
	if schools_a.size() != schools_b.size():
		return false
	for index in range(schools_a.size()):
		var one: Dictionary = schools_a[index]
		var two: Dictionary = schools_b[index]
		if one["school_id"] != two["school_id"] or one["population"] != two["population"] or one["world_position"] != two["world_position"]:
			return false
	return true


func _mean_stickleback_pair_distance(renderer: FishSchoolRenderer, school_id: String, count: int) -> float:
	var positions: Array[Vector2] = []
	for index in range(count):
		var key := "%s:%d" % [school_id, index]
		var state: Dictionary = renderer._individual_states.get(key, {})
		positions.append(state.get("local_position", Vector2.ZERO))
	var distance_sum := 0.0
	var pair_count := 0
	for first in range(positions.size()):
		for second in range(first + 1, positions.size()):
			distance_sum += positions[first].distance_to(positions[second])
			pair_count += 1
	return distance_sum / float(pair_count) if pair_count > 0 else 0.0


func _check(condition: bool, label: String) -> void:
	if condition:
		print("[PASS] %s" % label)
	else:
		_failures += 1
		push_error("[FAIL] %s" % label)


func _finish() -> void:
	print("[FISH_TEST] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)
