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
	_check(manager.get_species_profiles().size() == 4, "four species profiles loaded")
	_check(bathymetry != null and bathymetry.data_available, "existing EMODnet bathymetry loaded")
	_check(georeference != null, "existing GeoReference loaded")
	if bathymetry == null or georeference == null:
		_finish()
		return

	var profiles := manager.get_species_profiles()
	var previous_locale := TranslationServer.get_locale()
	TranslationServer.set_locale("en")
	var sea_trout_profile := manager.get_species_profile("sea_trout")
	_check(TranslationServer.translate(sea_trout_profile.name_key) == "Sea trout", "English locale resolves the stable sea trout name key")
	TranslationServer.set_locale("zh_CN")
	_check(TranslationServer.translate(sea_trout_profile.name_key) == "海鳟", "Simplified Chinese resolves the same stable sea trout name key")
	_check(TranslationServer.translate(sea_trout_profile.description_key) != sea_trout_profile.description_key, "sea trout habitat description uses a localization key")
	var fish_ui_translation_keys := [
		"fish.map.title", "fish.map.close", "fish.map.subtitle", "fish.map.tab.fish_resources",
		"fish.map.species_heading", "fish.map.filter_hint", "fish.map.dolphin_filter", "fish.map.summary",
		"fish.map.detail_heading", "fish.map.detail_prompt", "fish.map.footer",
		"fish.debug.observation_title", "fish.debug.camera.enter", "fish.debug.camera.return",
		"fish.debug.location.initial", "fish.debug.motion_toggle", "fish.debug.renderer_unavailable",
		"fish.debug.manager_unavailable", "fish.debug.profile_or_depth_unavailable",
		"fish.debug.location.no_resource", "fish.debug.location.no_safe_approach",
		"fish.debug.location.camera_started", "fish.debug.location.camera_available",
		"fish.debug.location.arrived", "fish.debug.location.no_visible_school",
		"fish.debug.location.no_safe_surface_approach", "fish.debug.location.activity_near_surface",
		"fish.debug.location.activity_visible_layer", "fish.debug.location.arrived_surface",
		"fish.debug.camera.select_school_first", "fish.debug.camera.school_unavailable",
		"fish.debug.enabled", "fish.debug.disabled",
	]
	var fish_ui_translations_resolve := true
	for locale in ["en", "zh_CN"]:
		TranslationServer.set_locale(locale)
		for key in fish_ui_translation_keys:
			if TranslationServer.translate(key) == key:
				fish_ui_translations_resolve = false
	_check(fish_ui_translations_resolve, "fish map and observation HUD labels resolve localization keys in English and Simplified Chinese")
	TranslationServer.set_locale(previous_locale)
	var first_authority := FishLocalAuthority.new()
	var authority_init_usec := Time.get_ticks_usec()
	first_authority.initialize(manager.get_world_seed(), bathymetry, georeference, profiles)
	authority_init_usec = Time.get_ticks_usec() - authority_init_usec
	var first_snapshot := first_authority.create_snapshot()
	var second_authority := FishLocalAuthority.new()
	second_authority.initialize(manager.get_world_seed(), bathymetry, georeference, profiles)
	var second_snapshot := second_authority.create_snapshot()
	_check(_snapshot_layouts_equal(first_snapshot, second_snapshot), "initial resources are deterministic for the same seed")
	var reindexed_profiles: Array[FishSpeciesProfile] = []
	for profile in profiles:
		var reindexed := profile.duplicate(true) as FishSpeciesProfile
		reindexed.species_index = 100 - profile.species_index
		reindexed_profiles.append(reindexed)
	var reindexed_authority := FishLocalAuthority.new()
	reindexed_authority.initialize(manager.get_world_seed(), bathymetry, georeference, reindexed_profiles)
	_check(_snapshot_layouts_equal(first_snapshot, reindexed_authority.create_snapshot()), "species_index reassignment does not change species identity or generated school layout")
	_check(reindexed_authority.restore_snapshot(first_snapshot), "species_index reassignment does not invalidate an otherwise identical ecology snapshot")
	var reversed_profiles := profiles.duplicate()
	reversed_profiles.reverse()
	var reversed_authority := FishLocalAuthority.new()
	reversed_authority.initialize(manager.get_world_seed(), bathymetry, georeference, reversed_profiles)
	_check(_snapshot_layouts_equal(first_snapshot, reversed_authority.create_snapshot()), "profile resource array order does not change the generated fish layout")
	var changed_profiles: Array[FishSpeciesProfile] = []
	for profile in profiles:
		var changed := profile.duplicate(true) as FishSpeciesProfile
		if changed.species_id == "sea_trout":
			changed.spawn_chance += 0.01
		changed_profiles.append(changed)
	var changed_authority := FishLocalAuthority.new()
	changed_authority.initialize(manager.get_world_seed(), bathymetry, georeference, changed_profiles)
	_check(not changed_authority.restore_snapshot(first_snapshot), "authority rejects snapshots created with a different ecology profile signature")
	_check(first_authority.restore_snapshot(first_snapshot), "authority snapshot restores")
	var legacy_school_state: Dictionary = first_snapshot["schools"][0].duplicate(true)
	legacy_school_state["schema_version"] = 2
	_check(FishSchoolState.from_dictionary(legacy_school_state) == null, "legacy school schema v2 is explicitly rejected instead of being reinterpreted")
	var legacy_snapshot: Dictionary = first_snapshot.duplicate(true)
	legacy_snapshot["schema_version"] = 2
	legacy_snapshot["layout_version"] = 4
	_check(not first_authority.restore_snapshot(legacy_snapshot), "pre-recovery authority snapshot v2/layout4 is explicitly rejected")
	var wrong_layout: Dictionary = first_snapshot.duplicate(true)
	wrong_layout["layout_version"] = 99
	_check(not first_authority.restore_snapshot(wrong_layout), "unsupported layout snapshots are rejected")

	var species_counts := {"needlefish": 0, "herring": 0, "three_spined_stickleback": 0, "sea_trout": 0}
	var population_totals := {"needlefish": 0, "herring": 0, "three_spined_stickleback": 0, "sea_trout": 0}
	var invalid_school_count := 0
	var unsuitable_school_count := 0
	var out_of_profile_population_count := 0
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
		var school_population := int(school.get("population", 0))
		population_totals[str(school["species_id"])] = int(population_totals.get(str(school["species_id"]), 0)) + school_population
		if school_population < profile.population_min or school_population > profile.population_max:
			out_of_profile_population_count += 1
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
	_check(species_counts["sea_trout"] > 0, "sea trout resources exist in the map region")
	_check(species_counts["sea_trout"] < species_counts["herring"] and float(species_counts["sea_trout"]) / float(all_schools.size()) < 0.1, "sea trout remains a sparse minority rather than dominating the regional schools")
	_check(invalid_school_count == 0, "all generated school locations pass real water and land-mask validation")
	_check(unsuitable_school_count == 0, "all generated schools satisfy their profile depth rules")
	_check(out_of_profile_population_count == 0, "all generated school populations satisfy their species profile bounds")
	_check(seagrass_proxy_school_count > 0, "some stickleback resources align with deterministic eelgrass meadow habitat")
	var stickleback_profile := manager.get_species_profile("three_spined_stickleback")
	_check(stickleback_profile != null and is_equal_approx(stickleback_profile.maximum_depth_m, 6.0), "stickleback habitat is restricted to the 0-6 m shallows")
	_check(stickleback_school_count > 0 and stickleback_bad_depth_count == 0, "all stickleback resource anchors are inside the usable shallow range")
	_check(stickleback_small_groups > 0 and stickleback_common_groups > 0 and stickleback_large_groups > 0, "deterministic stickleback schools include small, common and large size classes")
	_check(not nearest_shallow_stickleback.is_empty(), "a 1.3-3.3 m stickleback school exists for local observation")
	print("[FISH_TEST] stickleback schools=%d population_tiers={small:%d common:%d large:%d}; nearest_shallow_distance_m=%.1f school=%s" % [stickleback_school_count, stickleback_small_groups, stickleback_common_groups, stickleback_large_groups, nearest_stickleback_distance, str(nearest_shallow_stickleback.get("school_id", "none"))])
	_check(manager.get_map_distribution(["herring"]).all(func(school: Dictionary) -> bool: return str(school["species_id"]) == "herring"), "map filter returns only the selected species")

	var nearby := manager.get_schools_near(boat.global_position, 1200.0)
	var nearby_by_species := {"needlefish": 0, "herring": 0, "three_spined_stickleback": 0, "sea_trout": 0}
	for school in nearby:
		var id := str(school["species_id"])
		nearby_by_species[id] = int(nearby_by_species.get(id, 0)) + 1
	print("[FISH_TEST] regional school counts=%s; total fish=%s; schools within 1200m of boat=%s" % [species_counts, population_totals, nearby_by_species])
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
		if profile.species_id == "sea_trout":
			var sea_trout_mesh := (mesh_nodes[0] as MeshInstance3D).mesh if not mesh_nodes.is_empty() else null
			_check(mesh_nodes.size() == 1 and sea_trout_mesh != null and sea_trout_mesh.get_surface_count() == 1, "sea trout model matches the current single-mesh, single-surface MultiMesh adapter")
		if not mesh_nodes.is_empty():
			var mesh_instance := mesh_nodes[0] as MeshInstance3D
			_check(mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0, "%s mesh has surfaces" % profile.species_id)
			if mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0:
				var material := mesh_instance.mesh.surface_get_material(0) as BaseMaterial3D
				_check(material != null and material.albedo_texture != null, "%s GLB carries a base-color texture" % profile.species_id)
		model.free()

	var resource_map := main_root.get_node("FishResourceMap") as FishResourceMap
	var map_canvas := resource_map.find_child("ResourceDistributionMap", true, false) as FishResourceMapCanvas
	var depth_map_canvas := resource_map.find_child("DepthQualityMap", true, false) as DepthQualityMapCanvas
	var sea_chart := main_root.get_node("DepthChartHUD") as CanvasLayer
	var sea_chart_view := sea_chart.find_child("Chart", true, false) as DepthChartView
	var chart_clip_rect := Rect2(Vector2(10.0, 8.0), Vector2(80.0, 60.0))
	var crossing_line := PackedVector2Array([Vector2(-20.0, 30.0), Vector2(120.0, 30.0)])
	var clipped_crossing := DepthChartView.clip_polyline_to_rect(crossing_line, chart_clip_rect)
	_check(clipped_crossing.size() == 1 and clipped_crossing[0][0].is_equal_approx(Vector2(10.0, 30.0)) and clipped_crossing[0][1].is_equal_approx(Vector2(90.0, 30.0)), "Sea Chart clips projected coastline and contour segments to the inner map frame")
	var outside_excursion := PackedVector2Array([Vector2(20.0, 20.0), Vector2(120.0, 20.0), Vector2(20.0, 40.0)])
	var clipped_excursion := DepthChartView.clip_polyline_to_rect(outside_excursion, chart_clip_rect)
	_check(clipped_excursion.size() == 2, "Sea Chart does not bridge a polyline excursion outside the map frame")
	_check(resource_map.get_display_mode() == "mini" and sea_chart.visible and sea_chart_view.visible, "the compact local Sea Chart is shown by default")
	_check(map_canvas != null and not map_canvas.visible and not map_canvas.is_processing() and depth_map_canvas != null and not depth_map_canvas.visible, "both expanded map canvases remain idle while the local Sea Chart is shown")
	var sea_chart_stats := sea_chart_view.get_chart_build_statistics()
	_check(int(sea_chart_stats.get("pixels_total", 0)) == 128 * 92 and int(sea_chart_stats.get("pixels_per_frame_budget", 0)) == 256, "Sea Chart raster sampling has a fixed per-frame budget")
	var sea_chart_wait_start_usec := Time.get_ticks_usec()
	while not sea_chart_view.is_chart_ready() and Time.get_ticks_usec() - sea_chart_wait_start_usec < 5000000:
		await process_frame
	sea_chart_stats = sea_chart_view.get_chart_build_statistics()
	_check(sea_chart_view.is_chart_ready() and int(sea_chart_stats.get("texture_uploads_last_build", 0)) == 1, "Sea Chart uploads one completed raster per chart refresh")
	var chart_map_rect: Rect2 = sea_chart_view.get("_map_rect")
	var clipped_chart_cache := true
	for coastline: PackedVector2Array in sea_chart_view.get("_cached_coastline_lines"):
		for point in coastline:
			if point.x < chart_map_rect.position.x - 0.01 or point.x > chart_map_rect.end.x + 0.01 or point.y < chart_map_rect.position.y - 0.01 or point.y > chart_map_rect.end.y + 0.01:
				clipped_chart_cache = false
	for contour: Dictionary in sea_chart_view.get("_cached_contour_lines"):
		var contour_points: PackedVector2Array = contour["points"]
		for point in contour_points:
			if point.x < chart_map_rect.position.x - 0.01 or point.x > chart_map_rect.end.x + 0.01 or point.y < chart_map_rect.position.y - 0.01 or point.y > chart_map_rect.end.y + 0.01:
				clipped_chart_cache = false
	_check(clipped_chart_cache, "cached coastline and contour geometry remains inside the Sea Chart map frame")
	var sea_chart_uploads_before_hidden_refresh := int(sea_chart_stats.get("texture_uploads_total", 0))
	sea_chart.set_chart_visible(false)
	sea_chart_view.request_chart_refresh()
	for _frame in range(2):
		await process_frame
	sea_chart_stats = sea_chart_view.get_chart_build_statistics()
	_check(not bool(sea_chart_stats.get("building", true)) and int(sea_chart_stats.get("texture_uploads_total", 0)) == sea_chart_uploads_before_hidden_refresh, "hidden Sea Chart does not start or continue raster sampling")
	sea_chart.set_chart_visible(true)
	var sea_chart_resume_frames := 0
	while sea_chart_resume_frames < 200 and (bool(sea_chart_view.get_chart_build_statistics().get("building", false)) or int(sea_chart_view.get_chart_build_statistics().get("texture_uploads_total", 0)) == sea_chart_uploads_before_hidden_refresh):
		await process_frame
		sea_chart_resume_frames += 1
	sea_chart_stats = sea_chart_view.get_chart_build_statistics()
	_check(int(sea_chart_stats.get("texture_uploads_total", 0)) == sea_chart_uploads_before_hidden_refresh + 1 and int(sea_chart_stats.get("texture_uploads_last_build", 0)) == 1, "Sea Chart resumes with a single texture upload after being shown")
	var details_label := resource_map.get("_details_label") as Label
	var sample_by_species: Dictionary = {}
	for school in manager.get_all_school_snapshots():
		var species_id := str(school.get("species_id", ""))
		if not sample_by_species.has(species_id):
			sample_by_species[species_id] = school
	for locale in ["en", "zh_CN"]:
		TranslationServer.set_locale(locale)
		for profile in profiles:
			var school: Dictionary = sample_by_species.get(profile.species_id, {})
			if school.is_empty() or details_label == null:
				continue
			resource_map.call("_update_school_details", school)
			var expected_name := TranslationServer.translate(profile.name_key)
			_check(details_label.text.contains(expected_name), "%s M-chart details show the localized %s name" % [locale, profile.species_id])
			_check(not details_label.text.contains("fish.map.") and not details_label.text.contains("%s"), "%s M-chart details resolve species, habitat, activity and format keys" % locale)
	TranslationServer.set_locale(previous_locale)
	var map_key := InputEventKey.new()
	map_key.physical_keycode = KEY_M
	map_key.pressed = true
	resource_map.call("_unhandled_key_input", map_key)
	_check(resource_map.is_map_open() and not sea_chart.visible, "M opens the full chart and hides the compact Sea Chart")
	var raster_wait_start_usec := Time.get_ticks_usec()
	var raster_frame_max_usec := 0
	while not map_canvas.is_raster_ready() and Time.get_ticks_usec() - raster_wait_start_usec < 5000000:
		var frame_start_usec := Time.get_ticks_usec()
		await process_frame
		raster_frame_max_usec = maxi(raster_frame_max_usec, Time.get_ticks_usec() - frame_start_usec)
	var raster_stats := map_canvas.get_raster_build_statistics()
	_check(map_canvas.is_raster_ready(), "M-opened resource chart raster completes incrementally")
	_check(float(raster_stats.get("maximum_slice_ms", INF)) < 12.0, "resource chart raster work is spread across short frame slices")
	print("[FISH_TEST] map_raster=%s; waited_ms=%.2f; worst_frame_wait_ms=%.2f" % [raster_stats, float(Time.get_ticks_usec() - raster_wait_start_usec) / 1000.0, float(raster_frame_max_usec) / 1000.0])
	resource_map.set_map_open(true)
	_check(resource_map.is_map_open() and map_canvas != null, "expanded chart includes the fish-resource layer")
	_check(map_canvas != null and map_canvas.get_school_count() > 0, "expanded chart reads resource points from FishResourceManager")
	resource_map.call("_unhandled_key_input", map_key)
	_check(not resource_map.is_map_open() and sea_chart.visible and not depth_map_canvas.visible, "M closes the full chart and restores the compact Sea Chart")

	var renderer := main_root.get_node("FishResourceManager/FishSchoolRenderer") as FishSchoolRenderer
	_test_surface_fish_crossing_old_boat_clearance(renderer, manager, boat, bathymetry)
	var authority_population_before_budget_change := 0
	for school in manager.get_all_school_snapshots():
		authority_population_before_budget_change += int(school.get("population", 0))
	var previous_visible_budget := renderer.maximum_visible_fish
	renderer.maximum_visible_fish = 100
	await process_frame
	var authority_population_after_budget_change := 0
	for school in manager.get_all_school_snapshots():
		authority_population_after_budget_change += int(school.get("population", 0))
	_check(authority_population_before_budget_change == authority_population_after_budget_change, "changing the visual fish budget does not alter authoritative population")
	renderer.maximum_visible_fish = previous_visible_budget
	await create_timer(0.5).timeout
	var render_stats := renderer.get_render_statistics()
	_check(int(render_stats.get("multimesh_batches", 0)) == 4, "renderer builds one MultiMesh batch per fish species")
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
	var saved_initial_boat_position := boat.global_position
	if not nearest_shallow_stickleback.is_empty():
		var school: Dictionary = nearest_shallow_stickleback
		var profile := manager.get_species_profile(str(school["species_id"]))
		var school_position_data: Array = school["world_position"]
		boat.global_position = Vector3(float(school_position_data[0]) + 100.0, 0.0, float(school_position_data[2]))
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
	boat.global_position = saved_initial_boat_position
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
		var visual_school_snapshot: Dictionary = nearest_shallow_stickleback.duplicate(true)
		visual_school_snapshot["disturbance_state"] = "CALM"
		visual_school_snapshot["disturbance_level"] = 0.0
		for tick in range(16):
			stickle_depth_cache.clear()
			stickle_surface_cache.clear()
			renderer._build_school_fish(visual_school_snapshot, stickleback_profile, stickle_count, 0.16, 4.0 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
		var calm_overhead_flee_count := 0
		for index in range(stickle_count):
			var key := "%s:%d" % [str(nearest_shallow_stickleback["school_id"]), index]
			if str(renderer._individual_states.get(key, {}).get("behavior_state", "")) == "flee":
				calm_overhead_flee_count += 1
		_check(calm_overhead_flee_count == 0, "boat directly overhead does not start fleeing without an Authority disturbance state")
		boat.global_position = stickleback_center + Vector3(100.0, 0.0, 0.0)
		visual_school_snapshot["disturbance_state"] = "ALERT"
		visual_school_snapshot["disturbance_level"] = 0.4
		for tick in range(4):
			stickle_depth_cache.clear()
			stickle_surface_cache.clear()
			renderer._build_school_fish(visual_school_snapshot, stickleback_profile, stickle_count, 0.16, 6.56 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
		var alert_count := 0
		var alert_flee_count := 0
		for index in range(stickle_count):
			var key := "%s:%d" % [str(nearest_shallow_stickleback["school_id"]), index]
			var alert_state: Dictionary = renderer._individual_states.get(key, {})
			if str(alert_state.get("behavior_state", "")) == "alert":
				alert_count += 1
			if str(alert_state.get("behavior_state", "")) == "flee":
				alert_flee_count += 1
		_check(alert_count > 0 and alert_flee_count == 0, "Authority ALERT redirects eligible visuals without entering the FLEEING behavior")
		radius_before_evasion = 0.0
		for index in range(stickle_count):
			var key := "%s:%d" % [str(nearest_shallow_stickleback["school_id"]), index]
			var alert_fish_state: Dictionary = renderer._individual_states[key]
			var alert_local_position: Vector2 = alert_fish_state.get("local_position", Vector2.ZERO)
			radius_before_evasion += alert_local_position.length()
		radius_before_evasion /= maxf(float(stickle_count), 1.0)
		boat.global_position = stickleback_center
		visual_school_snapshot["disturbance_state"] = "FLEEING"
		visual_school_snapshot["disturbance_level"] = 0.8
		for tick in range(16):
			stickle_depth_cache.clear()
			stickle_surface_cache.clear()
			renderer._build_school_fish(visual_school_snapshot, stickleback_profile, stickle_count, 0.16, 7.20 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
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
		_check(fleeing_count == stickle_count, "Authority FLEEING state triggers lateral evasion for the whole stickleback school")
		_check(shallow_evasion_count == stickle_count, "panicked sticklebacks stay in the shallow visible layer instead of diving into seagrass")
		_check(radius_after_evasion > radius_before_evasion + 0.05, "boat disturbance spreads sticklebacks outward without moving their shared school anchor")
		var recovery_start_distance := 0.0
		boat.global_position = stickleback_center + Vector3(100.0, 0.0, 0.0)
		visual_school_snapshot["disturbance_state"] = "CALM"
		visual_school_snapshot["disturbance_level"] = 0.1
		for tick in range(16):
			stickle_depth_cache.clear()
			stickle_surface_cache.clear()
			renderer._build_school_fish(visual_school_snapshot, stickleback_profile, stickle_count, 0.16, 9.76 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
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
			renderer._build_school_fish(visual_school_snapshot, stickleback_profile, stickle_count, 0.16, 13.12 + float(tick) * 0.16, stickle_depth_cache, stickle_surface_cache)
		var recovery_end_distance := _mean_stickleback_pair_distance(renderer, str(nearest_shallow_stickleback["school_id"]), stickle_count)
		_check(recovery_end_distance < recovery_start_distance, "sticklebacks gradually return toward their original formation after the boat passes")
		var recovered_visual_phase_count := 0
		for index in range(stickle_count):
			var key := "%s:%d" % [str(nearest_shallow_stickleback["school_id"]), index]
			if str(renderer._individual_states.get(key, {}).get("disturbance_state", "")) == "recovering":
				recovered_visual_phase_count += 1
		_check(recovered_visual_phase_count == 0, "Authority returning to CALM lets the presentation recovery phase complete")
		var authority_anchor_before_transition: Array = manager.get_school(str(nearest_shallow_stickleback["school_id"])).get("world_position", []).duplicate()
		var transition_key := "%s:0" % str(nearest_shallow_stickleback["school_id"])
		var transition_state: Dictionary = renderer._individual_states[transition_key]
		var base_radius := renderer._school_wander_radius(stickleback_profile)
		var transition_extension := renderer.stickleback_scatter_radius_extension_m * 0.8
		var previous_offset: Vector2 = transition_state.get("local_position", Vector2.RIGHT)
		var escape_direction := previous_offset.normalized() if previous_offset.length_squared() > 0.001 else Vector2.RIGHT
		var position_before_alert := escape_direction * (base_radius + transition_extension)
		transition_state["local_position"] = position_before_alert
		transition_state["velocity"] = Vector2.ZERO
		transition_state["disturbance_state"] = "scattering"
		transition_state["visual_disturbance_state"] = "scattering"
		transition_state["visual_scatter_radius_expansion_m"] = transition_extension
		renderer._individual_states[transition_key] = transition_state
		visual_school_snapshot["disturbance_state"] = "ALERT"
		visual_school_snapshot["disturbance_level"] = 0.8
		stickle_depth_cache.clear()
		stickle_surface_cache.clear()
		var alert_transition_records := renderer._build_school_fish(visual_school_snapshot, stickleback_profile, stickle_count, 0.16, 20.80, stickle_depth_cache, stickle_surface_cache)
		var position_after_alert: Vector2 = renderer._individual_states[transition_key].get("local_position", Vector2.ZERO)
		var fleeing_to_alert_displacement := position_before_alert.distance_to(position_after_alert)
		var transition_record_exists := false
		for record in alert_transition_records:
			if str(record.get("individual_key", "")) == transition_key:
				transition_record_exists = true
				break
		_check(transition_record_exists, "FLEEING to ALERT transition updates the test fish in the rendered sample")
		_check(fleeing_to_alert_displacement < 0.75, "FLEEING to ALERT contracts the visual envelope without snapping an escaped fish back to the core (observed %.2f m)" % fleeing_to_alert_displacement)
		var authority_anchor_after_transition: Array = manager.get_school(str(nearest_shallow_stickleback["school_id"])).get("world_position", [])
		_check(authority_anchor_before_transition == authority_anchor_after_transition, "Renderer-only flee spreading leaves the Authority school anchor unchanged")
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
			var authority_school_state := manager.get_school(selected_school_id)
			var authority_disturbance_state := str(authority_school_state.get("disturbance_state", "CALM"))
			var scattering_count := int(observation_behaviors.get("scattering", 0))
			_check(scattering_count > 0 if authority_disturbance_state == "FLEEING" else scattering_count == 0, "F3 fish behavior follows Authority state rather than the boat's horizontal proximity alone")
	print("[FISH_TEST] renderer=%s; init_elapsed_ms=%.1f" % [render_stats, float(Time.get_ticks_usec() - start_usec) / 1000.0])
	print("[FISH_TEST] authority=%s; revision=%d; schools=%d; deterministic_init_ms=%.2f; step_total_ms=%.2f; worst_budgeted_frame_ms=%.2f; step_frames=%d" % [manager.get_authority_source(), manager.get_state_revision(), all_schools.size(), float(authority_init_usec) / 1000.0, float(simulation_update_usec) / 1000.0, float(worst_simulation_frame_usec) / 1000.0, frame_count])
	_finish()


func _test_surface_fish_crossing_old_boat_clearance(
	renderer: FishSchoolRenderer,
	manager: FishResourceManager,
	boat: Node3D,
	bathymetry: BathymetryManager
) -> void:
	var saved_boat_position := boat.global_position
	var species_ids := ["herring", "sea_trout", "needlefish"]
	for species_id_variant in species_ids:
		var species_id := str(species_id_variant)
		var profile := manager.get_species_profile(species_id)
		if profile == null or not profile.surface_activity_cycle_enabled:
			_check(false, "%s uses the surface-school renderer path" % species_id)
			continue
		var school: Dictionary = {}
		var school_position := Vector3.ZERO
		var school_depth_m := 0.0
		for candidate in manager.get_all_school_snapshots():
			if str(candidate.get("species_id", "")) != species_id:
				continue
			var position_values: Array = candidate.get("world_position", [])
			if position_values.size() < 3:
				continue
			var candidate_position := Vector3(float(position_values[0]), 0.0, float(position_values[2]))
			var depth_sample := bathymetry.get_depth_at_world_position(candidate_position)
			if not bool(depth_sample.get("valid", false)) or float(depth_sample.get("depth_m", 0.0)) < 1.0:
				continue
			school = candidate.duplicate(true)
			school_position = candidate_position
			school_depth_m = float(depth_sample.get("depth_m", 0.0))
			break
		_check(not school.is_empty(), "%s has a valid water school for a controlled boat-crossing check" % species_id)
		if school.is_empty():
			continue

		var synthetic_school_id := "renderer_boat_crossing_%s" % species_id
		school["school_id"] = synthetic_school_id
		school["world_position"] = [school_position.x, 0.0, school_position.z]
		school["depth_m"] = school_depth_m
		school["population"] = 1
		school["movement_speed_mps"] = maxf(profile.movement_speed_min_mps, 0.1)
		school["surface_activity_state"] = "near_surface"
		school["effective_surface_activity_state"] = "near_surface"
		school["activity_depth_m"] = 1.0
		school["effective_activity_depth_m"] = 1.0
		school["effective_activity_depth_target_m"] = 1.0
		school["disturbance_state"] = "CALM"
		school["disturbance_level"] = 0.0
		var individual_key := "%s:0" % synthetic_school_id
		var individual_state := renderer._create_individual_state(int(school.get("seed", 1)), 0, profile, 1.0)
		individual_state["local_position"] = Vector2.ZERO
		individual_state["formation_anchor"] = Vector2.ZERO
		individual_state["velocity"] = Vector2(maxf(profile.movement_speed_min_mps * 0.25, 0.05), 0.0)
		individual_state["visual_scatter_radius_expansion_m"] = 0.0
		individual_state["boat_crossing_test_marker"] = species_id
		renderer._individual_states[individual_key] = individual_state

		var depth_cache: Dictionary = {}
		var surface_cache: Dictionary = {}
		boat.global_position = school_position + Vector3(6.0, saved_boat_position.y, 0.0)
		var outside_records := renderer._build_school_fish(school, profile, 1, 0.16, 100.0, depth_cache, surface_cache)
		_check(outside_records.size() == 1, "%s renders the tracked fish before crossing the old 5m boundary" % species_id)
		_retain_test_school_states(renderer, synthetic_school_id, outside_records)
		var outside_state: Dictionary = renderer._individual_states.get(individual_key, {})
		var outside_position: Vector3 = outside_state.get("visual_to_transform", Transform3D.IDENTITY).origin

		boat.global_position = school_position + Vector3(0.0, saved_boat_position.y, 0.0)
		school["disturbance_state"] = "FLEEING"
		school["disturbance_level"] = 0.8
		depth_cache.clear()
		surface_cache.clear()
		var inside_records := renderer._build_school_fish(school, profile, 1, 0.16, 100.16, depth_cache, surface_cache)
		_check(inside_records.size() == 1, "%s keeps its fish record inside the former 5m hard-cull radius" % species_id)
		_retain_test_school_states(renderer, synthetic_school_id, inside_records)
		var inside_state: Dictionary = renderer._individual_states.get(individual_key, {})
		var inside_offset: Vector2 = inside_state.get("local_position", Vector2.ZERO)
		var inside_distance := (school_position + Vector3(inside_offset.x, 0.0, inside_offset.y)).distance_to(Vector3(boat.global_position.x, school_position.y, boat.global_position.z))
		_check(inside_distance < 5.0, "%s crossing check places the tracked fish inside 5m" % species_id)
		_check(str(inside_state.get("boat_crossing_test_marker", "")) == species_id, "%s retains the same individual state inside the old cull radius" % species_id)
		_check(str(inside_state.get("behavior_state", "")) == "flee", "%s still uses its Authority-driven FLEEING presentation" % species_id)
		_check(float(inside_state.get("visual_scatter_radius_expansion_m", 0.0)) > 0.0, "%s continues the existing smooth scatter-radius update" % species_id)
		var inside_position: Vector3 = inside_state.get("visual_to_transform", Transform3D.IDENTITY).origin
		_check(outside_position.distance_to(inside_position) > 0.001, "%s continues moving its visual transform through the boat crossing" % species_id)

		boat.global_position = school_position + Vector3(6.0, saved_boat_position.y, 0.0)
		school["disturbance_state"] = "CALM"
		school["disturbance_level"] = 0.0
		depth_cache.clear()
		surface_cache.clear()
		var after_records := renderer._build_school_fish(school, profile, 1, 0.16, 100.32, depth_cache, surface_cache)
		_check(after_records.size() == 1, "%s remains in the render records after the boat leaves" % species_id)
		_retain_test_school_states(renderer, synthetic_school_id, after_records)
		var after_state: Dictionary = renderer._individual_states.get(individual_key, {})
		_check(str(after_state.get("boat_crossing_test_marker", "")) == species_id, "%s does not reinitialize the tracked fish after the crossing" % species_id)
		renderer._individual_states.erase(individual_key)
	boat.global_position = saved_boat_position


func _retain_test_school_states(renderer: FishSchoolRenderer, school_id: String, records: Array[Dictionary]) -> void:
	var active_keys: Dictionary = {}
	for record in records:
		active_keys[str(record.get("individual_key", ""))] = true
	var prefix := school_id + ":"
	for key_variant in renderer._individual_states.keys():
		var key := str(key_variant)
		if key.begins_with(prefix) and not active_keys.has(key):
			renderer._individual_states.erase(key_variant)


func _snapshot_layouts_equal(a: Dictionary, b: Dictionary) -> bool:
	var schools_a: Array = a.get("schools", [])
	var schools_b: Array = b.get("schools", [])
	if schools_a.size() != schools_b.size():
		return false
	var schools_by_id: Dictionary = {}
	for school in schools_b:
		schools_by_id[str(school.get("school_id", ""))] = school
	for one in schools_a:
		var school_id := str(one.get("school_id", ""))
		var two: Dictionary = schools_by_id.get(school_id, {})
		if two.is_empty() or one["population"] != two["population"] or one["world_position"] != two["world_position"] or one["seed"] != two["seed"]:
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
