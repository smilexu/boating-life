extends SceneTree

const NAV := preload("res://scripts/sailboat_navigation_math.gd")
const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_navigation_math()
	await _test_lab_instrument_and_visuals()
	if _failures.is_empty():
		print("Sailboat navigation instrument tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_navigation_math() -> void:
	_expect(_near_angle(NAV.heading_degrees_from_forward(Vector3(0.0, 0.0, -1.0)), 0.0), "local -Z bow maps to north heading 000°")
	_expect(_near_angle(NAV.heading_degrees_from_forward(Vector3.RIGHT), 90.0), "east maps to heading 090°")
	_expect(_near_angle(NAV.heading_degrees_from_forward(Vector3(0.0, 0.0, 1.0)), 180.0), "local +Z stern direction maps to heading 180°")
	_expect(_near_angle(NAV.heading_degrees_from_forward(Vector3.LEFT), 270.0), "west maps to heading 270°")
	_expect(_near_angle(NAV.signed_relative_bearing_degrees(5.0, 355.0), 10.0), "relative compass bearing wraps through north by the short path")
	_expect(NAV.compass_bearing_to_screen_direction(0.0).distance_to(Vector2.UP) < 0.001, "relative bearing 000° points to the top of the boat instrument")
	_expect(NAV.compass_bearing_to_screen_direction(90.0).distance_to(Vector2.RIGHT) < 0.001, "relative bearing 090° points to starboard")
	_expect(NAV.compass_bearing_to_screen_direction(-90.0).distance_to(Vector2.LEFT) < 0.001, "relative bearing -090° points to port")
	_expect(_near_angle(NAV.wind_from_bearing_from_wind_to(Vector3.RIGHT), 270.0), "wind-to east is displayed as wind-from west")
	_expect(_near_angle(NAV.wind_from_bearing_from_wind_to(Vector3.LEFT), 90.0), "wind-to west is displayed as wind-from east")
	var centered_boom := NAV.boom_direction_from_sail_angle(0.0)
	var positive_boom := NAV.boom_direction_from_sail_angle(deg_to_rad(30.0))
	var negative_boom := NAV.boom_direction_from_sail_angle(deg_to_rad(-30.0))
	_expect(centered_boom.is_equal_approx(Vector2(0.0, 1.0)), "zero sail angle points the boom aft")
	_expect(positive_boom.x > 0.0 and positive_boom.y > 0.0, "positive sail angle projects toward starboard and aft")
	_expect(negative_boom.x < 0.0 and negative_boom.y > 0.0, "negative sail angle projects toward port and aft")
	_expect(absf(NAV.sog_knots(1.0) - 1.94384449) < 0.0001, "SOG converts metres per second to knots")
	_expect(not NAV.cog_is_reliable(0.149), "COG direction is hidden below the reliability threshold")
	_expect(NAV.cog_is_reliable(0.15), "COG direction becomes available at the documented threshold")


func _test_lab_instrument_and_visuals() -> void:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	var boat := lab.get_node("SailboatBody") as RigidBody3D
	var debug_panel := lab.get_node("DebugPanel")
	var instrument := debug_panel.find_child("NavigationInstrument", true, false) as Control
	_expect(instrument != null, "the live instrument is added to the existing SailboatLab debug canvas")
	_expect(instrument != null and instrument.mouse_filter == Control.MOUSE_FILTER_IGNORE, "the instrument does not intercept existing debug controls")
	var tabs := debug_panel.find_child("SailboatDebugTabs", true, false) as TabContainer
	_expect(tabs != null and tabs.get_tab_count() == 8, "underwater inspection and engine tabs coexist with the existing debug pages and instrument")
	_expect(instrument != null and tabs != null and not tabs.is_ancestor_of(instrument), "navigation instrument is a separate panel rather than a tab")
	if instrument != null:
		var viewport_width := instrument.get_viewport().get_visible_rect().size.x
		var expected_width := clampf(viewport_width * 0.235, 270.0, 320.0)
		_expect(
			absf(instrument.position.x - (viewport_width - expected_width - 16.0)) < 0.1
				and absf(instrument.position.y - 16.0) < 0.1,
			"navigation panel follows the viewport's upper-right anchor"
		)
	var turn_diagnostics := debug_panel.find_child("TurnDiagnostics", true, false) as Label
	_expect(turn_diagnostics != null, "the existing status page includes cached turn and measured yaw-torque diagnostics")
	var camera_mode_status := debug_panel.find_child("CameraModeStatus", true, false) as Label
	_expect(camera_mode_status != null, "the lab panel documents the camera toggle and full-scene reset shortcuts")
	_expect(bool(lab.call("is_camera_follow_enabled")), "the test lab starts with smooth follow enabled")

	var visual_root := boat.get_node("VisualRoot")
	var hull_adapter := visual_root.get_node("HullModelAdapter") as Node3D
	var nordic28_model := hull_adapter.get_node("Nordic28Model") as Node3D
	var hull_mesh := nordic28_model.find_child("node_0", true, false) as MeshInstance3D
	_expect(hull_mesh != null and hull_mesh.mesh != null, "Nordic 28 GLB is instanced under the visual-only hull adapter")
	_expect(not visual_root.has_node("Hull") and not visual_root.has_node("Deck") and not visual_root.has_node("KeelPlaceholder"), "temporary hull, deck, and duplicate keel visuals are removed")
	var bow_direction := (hull_adapter.transform.basis * Vector3.RIGHT).normalized()
	_expect(bow_direction.distance_to(Vector3(0.0, 0.0, -1.0)) < 0.001, "the GLB +X bow is aligned with vessel-local -Z")
	if hull_mesh != null and hull_mesh.mesh != null:
		var adapted_bounds := (hull_adapter.transform * hull_mesh.transform) * hull_mesh.get_aabb()
		_expect(absf(adapted_bounds.size.z - 8.0) < 0.02, "GLB is scaled uniformly to an 8 m vessel length")
		_expect(absf(adapted_bounds.size.x - 2.754) < 0.02, "uniform scaling keeps beam near the 2.65–2.95 m reference range")
		_expect(absf(adapted_bounds.size.y - 3.24) < 0.02, "the GLB keeps its imported vertical proportions")
		var adapted_material := hull_mesh.get_surface_override_material(0) as StandardMaterial3D
		_expect(adapted_material != null and adapted_material.metallic == 0.0, "the imported material receives a non-metallic hull finish")
		_expect(adapted_material != null and adapted_material.albedo_texture != null, "the original embedded colour texture is retained")
		_expect(adapted_material != null and absf(adapted_material.roughness - 0.68) < 0.001, "the imported hull specular response is softened")
	var collision := boat.get_node("CollisionShape3D") as CollisionShape3D
	var hull_shape := collision.shape as BoxShape3D
	_expect(hull_shape.size.is_equal_approx(Vector3(2.5, 1.2, 7.4)), "the C3 visual change leaves the original collision box unchanged")
	_expect(collision.position.is_equal_approx(Vector3(0.0, 0.03, 0.0)), "the 30 cm draft adjustment does not move the physical collision shape")
	var profile: Resource = boat.get("profile")
	_expect(profile.get("mass_kg") == 3200.0, "the visual change leaves the test-vessel mass profile unchanged")
	_expect(profile.get("main_sail_area_m2") == 10.16025 and profile.get("headsail_area_m2") == 5.16, "the visual change leaves both sail areas unchanged")
	_expect(profile.get("main_sail_pivot_local_m").is_equal_approx(Vector3(0.0, 0.65, -0.75)), "the physical mainsail pivot remains at its calibrated experimental position")
	_expect(profile.get("main_sail_pressure_center_from_pivot_m").is_equal_approx(Vector3(0.0, 2.4, 0.8)), "the physical mainsail force centre is unchanged")
	_expect(profile.get("headsail_head_local_m").is_equal_approx(Vector3(0.0, 4.95, -0.75)), "the physical Jib head is unchanged")
	_expect(profile.get("headsail_tack_local_m").is_equal_approx(Vector3(0.0, 0.65, -3.55)), "the physical Jib tack is unchanged")
	var rig := visual_root.get_node("VisualRigAnchors")
	var rig_state: Dictionary = rig.call("get_alignment_snapshot")
	var visual_profile: Resource = rig.get("visual_profile")
	var assembly_offset: Vector3 = visual_profile.get("visual_assembly_offset_local_m")
	_expect(assembly_offset.is_equal_approx(Vector3(0.0, -0.30, 0.0)), "Nordic 28 shared visual profile specifies one 30 cm down offset")
	_expect(visual_root.position.is_equal_approx(assembly_offset), "all visible Nordic 28 components use the configured assembly offset exactly once")
	var visual_root_position_before_reconfigure: Vector3 = visual_root.position
	rig.call("apply_visual_assembly_offset")
	_expect(visual_root.position.is_equal_approx(visual_root_position_before_reconfigure), "reapplying assembly setup does not accumulate the visual draft offset")
	var static_water := lab.get_node("WaterSurfaceStatic") as MeshInstance3D
	var visual_surface_y: float = static_water.global_position.y - visual_root.global_position.y
	var body_surface_y: float = static_water.global_position.y - boat.global_position.y
	_expect(absf(visual_surface_y - body_surface_y - 0.30) < 0.001, "the sea surface sits 30 cm higher relative to the complete visual boat assembly")
	_expect(bool(rig_state.get("configured", false)), "Nordic 28 visual rig anchors are derived from the imported hull mesh")
	var roof_y := float(rig_state.get("cabin_roof_y_m", 0.0))
	var visual_mast_base: Vector3 = rig_state.get("visual_mast_base_local_m", Vector3.ZERO)
	var visual_boom: Vector3 = rig_state.get("visual_boom_local_m", Vector3.ZERO)
	var visual_mast_top: Vector3 = rig_state.get("visual_mast_top_local_m", Vector3.ZERO)
	var visual_jib_tack: Vector3 = rig_state.get("visual_jib_tack_local_m", Vector3.ZERO)
	var visual_main_head: Vector3 = rig_state.get("visual_main_head_local_m", Vector3.ZERO)
	var visual_main_clew: Vector3 = rig_state.get("visual_main_clew_local_m", Vector3.ZERO)
	var visual_jib_head: Vector3 = rig_state.get("visual_jib_head_local_m", Vector3.ZERO)
	var visual_jib_clew: Vector3 = rig_state.get("visual_jib_clew_local_m", Vector3.ZERO)
	var support_y := float(rig_state.get("mast_centerline_support_y_m", NAN))
	_expect(absf(float(rig_state.get("mast_step_embed_measured_m", NAN)) - 0.03) < 0.002, "mast base embeds 3 cm into the true centerline hull surface")
	_expect(absf(support_y - visual_mast_base.y - 0.03) < 0.002, "MastBase is aligned against the transformed GLB surface at its exact station")
	_expect(absf(visual_boom.y - roof_y - 0.40) < 0.03, "visual Boom keeps roughly 0.40 m clearance above the cabin-roof scan")
	_expect(visual_jib_tack.y > float(profile.get("headsail_tack_local_m").y) + 0.5, "visual Jib tack is lifted to the Nordic 28 foredeck independently of the physical tack")
	_expect(visual_mast_top.y > visual_boom.y + 4.0, "visual mast and sail head extend above the raised boom")
	_expect(absf(float(rig_state.get("mast_length_m", 0.0)) - 6.50) < 0.001, "Nordic 28 V2 mast length matches the approved 6.50 m configuration")
	_expect(absf(float(rig_state.get("boom_length_m", 0.0)) - 3.30) < 0.001, "Nordic 28 V2 Boom length matches the approved 3.30 m configuration")
	_expect(visual_mast_base.is_equal_approx(Vector3(0.0, 1.3184, -1.0)), "MastBase matches the approved visual anchor")
	_expect(visual_boom.is_equal_approx(Vector3(0.0, 1.9111, -1.0)), "BoomPivot matches the Nordic 28 V2.1 raised visual anchor")
	_expect(visual_mast_top.is_equal_approx(Vector3(0.0, 7.8184, -1.0)), "MastTop matches the approved 6.5 m mast height")
	_expect(visual_main_head.is_equal_approx(Vector3(0.0, 7.6384, -1.0)), "MainHead remains 18 cm below MastTop")
	_expect(visual_main_clew.is_equal_approx(Vector3(0.0, 1.9111, 2.3)), "MainClew follows the raised 3.3 m neutral Boom")
	_expect(visual_jib_head.is_equal_approx(Vector3(0.0, 5.95, -1.0)), "JibHead uses the approved fractional forestay height")
	_expect(visual_jib_tack.is_equal_approx(Vector3(0.0, 1.9614, -3.5498)), "JibTack remains on the approved foredeck visual anchor")
	_expect(visual_jib_clew.is_equal_approx(Vector3(0.0, 1.6686, -1.1498)), "JibClew starts at the approved neutral sheet anchor")
	_expect(absf(float(rig_state.get("main_visual_area_m2", 0.0)) - 9.450) < 0.002, "raised Boom changes only the visual main triangle area to about 9.45 m2")
	_expect(absf(float(rig_state.get("jib_visual_area_m2", 0.0)) - 5.160) < 0.002, "visual Jib triangle matches its approved fractional-height layout")
	var main_clearances: Dictionary = rig_state.get("main_lower_edge_clearance_m", {})
	for angle_degrees in [0.0, 30.0, -30.0, 60.0, -60.0, 70.0, -70.0, 80.0, -80.0]:
		_expect(float(main_clearances.get(angle_degrees, -1.0)) >= 0.29, "raised main Boom lower edge clears cabin geometry at %s°" % str(angle_degrees))
	var jib_clearances: Dictionary = rig_state.get("jib_lower_edge_clearance_m", {})
	for angle_degrees in [0.0, 30.0, -30.0, 60.0, -60.0, 70.0, -70.0, 80.0, -80.0]:
		_expect(float(jib_clearances.get(angle_degrees, -1.0)) >= 0.14, "visual Jib foot clears the foredeck/cabin at %s°" % str(angle_degrees))
	var main_clews_by_angle: Dictionary = rig_state.get("main_clew_by_angle_local_m", {})
	for angle_degrees in [-80.0, -60.0, -30.0, 0.0, 30.0, 60.0, 80.0]:
		var clew: Vector3 = main_clews_by_angle.get(angle_degrees, Vector3.ZERO)
		_expect(absf(clew.y - visual_boom.y) < 0.001, "main sail foot remains on the Boom at %s°" % str(angle_degrees))
		_expect(absf(clew.distance_to(visual_boom) - 3.30) < 0.001, "Boom and Clew stay linked at %s°" % str(angle_degrees))
	print("[NORDIC28_VISUAL_RIG] " + str(rig_state))
	var original_visual_root_rotation: Vector3 = visual_root.rotation
	for roll_degrees in [0.0, 5.0, 10.0]:
		visual_root.rotation.z = deg_to_rad(roll_degrees)
		var rolled_clearances: Dictionary = rig.call("get_alignment_snapshot").get("main_lower_edge_clearance_m", {})
		for angle_degrees in [0.0, 70.0, -70.0]:
			_expect(float(rolled_clearances.get(angle_degrees, -1.0)) >= 0.29, "raised Boom clearance is retained at %s° trim and %s° hull roll" % [str(angle_degrees), str(roll_degrees)])
	visual_root.rotation = original_visual_root_rotation
	var visual_jib := visual_root.get_node("HeadsailVisual") as MeshInstance3D
	boat.call("set_headsail_enabled", false)
	_expect(not visual_jib.visible, "the geometry-adjusted Jib visual still follows the enabled switch")
	boat.call("set_headsail_enabled", true)
	var main_boat_source := FileAccess.get_file_as_string("res://scenes/Boat.tscn")
	var sailing_boat_source := FileAccess.get_file_as_string("res://scenes/boats/SailingBoat8m.tscn")
	_expect(main_boat_source.contains("path=\"res://scenes/boats/SailingBoat8m.tscn\""), "Main references the same packed sailboat entity as SailboatLab")
	_expect(sailing_boat_source.contains("res://resources/sailing/sailboat_lab_profile.tres"), "the shared boat entity retains the unchanged vessel physics profile")

	boat.call("set_dynamic_waves_enabled", false)
	# reset_to_neutral takes Godot yaw degrees internally; a negative yaw makes
	# the local -Z bow point east (compass 090°) under this project's axes.
	boat.call("reset_to_neutral", -90.0)
	await physics_frame
	var heading_snapshot: Dictionary = boat.call("get_navigation_snapshot")
	_expect(_near_angle(float(heading_snapshot["heading_degrees"]), 90.0, 0.1), "HDG follows the actual rigid-body transform after the vessel rotates")
	_expect(not bool(heading_snapshot["cog_valid"]), "stationary vessel does not display an unreliable course direction")

	boat.call("set_lab_test_wind", 6.0, 270.0)
	await physics_frame
	var wind_snapshot: Dictionary = boat.call("get_navigation_snapshot")
	_expect(float(wind_snapshot["true_wind_speed_mps"]) > 5.9, "true-wind readout uses the live SailboatLab WindField sample")
	_expect(_near_angle(float(wind_snapshot["true_wind_from_degrees"]), 270.0, 0.2), "wind-to vector is reversed once to display its meteorological FROM bearing")
	boat.linear_velocity = Vector3(0.0, 0.0, -2.0)
	await physics_frame
	var moving_snapshot: Dictionary = boat.call("get_navigation_snapshot")
	_expect(bool(moving_snapshot["apparent_wind_valid"]), "apparent-wind direction is read from the cached physical calculation")
	_expect(absf(float(moving_snapshot["apparent_wind_speed_mps"]) - float(moving_snapshot["true_wind_speed_mps"])) > 0.1, "apparent wind responds to vessel motion instead of copying true wind")

	boat.set("actual_sail_angle_rad", deg_to_rad(27.0))
	boat.set("target_sail_angle_rad", deg_to_rad(42.0))
	boat.set("actual_rudder_angle_rad", deg_to_rad(18.0))
	boat.call("_process", 0.0)
	var sail_pivot := visual_root.get_node("VisualBoomPivot") as Node3D
	var rudder_pivot := visual_root.get_node("RudderPivot") as Node3D
	var rudder_marker := visual_root.get_node("RudderAngleMarker") as Node3D
	_expect(absf(sail_pivot.rotation.y - deg_to_rad(27.0)) < 0.0001, "3D mainsail visual follows actual rather than target trim angle")
	_expect(absf(rudder_pivot.rotation.y - deg_to_rad(18.0)) < 0.0001, "underwater rudder visual follows actual rudder angle")
	_expect(absf(rudder_marker.rotation.y - deg_to_rad(18.0)) < 0.0001, "visible stern rudder marker exactly mirrors the underwater rudder")
	boat.call("set_auto_sail_trim_enabled", true)
	boat.set("actual_sail_angle_rad", deg_to_rad(70.0))
	boat.call("_process", 0.0)
	_expect(absf(sail_pivot.rotation.y - deg_to_rad(70.0)) < 0.0001, "AUTO trim keeps the visible boom on the actual +70° mainsail angle")
	boat.call("set_auto_sail_trim_enabled", false)
	boat.set("actual_sail_angle_rad", deg_to_rad(-70.0))
	boat.call("_process", 0.0)
	_expect(absf(sail_pivot.rotation.y - deg_to_rad(-70.0)) < 0.0001, "MANUAL trim keeps the visible boom on the actual -70° mainsail angle")

	var before_transform := boat.global_transform
	var before_velocity := boat.linear_velocity
	var before_debug: Dictionary = boat.call("get_debug_snapshot")
	var before_wind_queries := int(before_debug["wind_query_count_per_tick"])
	var before_wave_queries := int(before_debug["wave_query_count_per_tick"])
	instrument.call("refresh_data")
	instrument.call("refresh_data")
	var after_snapshot: Dictionary = boat.call("get_navigation_snapshot")
	_expect(boat.global_transform.is_equal_approx(before_transform), "instrument refresh does not change the rigid-body transform")
	_expect(boat.linear_velocity.is_equal_approx(before_velocity), "instrument refresh does not change physical velocity")
	_expect(int(after_snapshot["wind_query_count_per_tick"]) == before_wind_queries, "instrument refresh does not issue another WindField query")
	_expect(int(after_snapshot["wave_query_count_per_tick"]) == before_wave_queries, "instrument refresh does not issue another WaveSampler query")
	_expect(float(after_snapshot["actual_sail_angle_rad"]) == float(boat.get("actual_sail_angle_rad")), "instrument state comes from the body's actual sail angle")
	var toggle_camera_event := InputEventKey.new()
	toggle_camera_event.physical_keycode = KEY_C
	toggle_camera_event.pressed = true
	lab.call("_input", toggle_camera_event)
	_expect(not bool(lab.call("is_camera_follow_enabled")), "C switches the lab to the fixed observation camera")
	lab.call("_input", toggle_camera_event)
	_expect(int(lab.call("get_camera_mode")) == 2, "second C selects the underwater inspection camera")
	lab.call("_input", toggle_camera_event)
	_expect(bool(lab.call("is_camera_follow_enabled")), "third C returns the lab to smooth camera follow")
	_expect(boat.global_transform.is_equal_approx(before_transform) and boat.linear_velocity.is_equal_approx(before_velocity), "camera mode changes do not write boat transform or velocity")
	lab.queue_free()
	await process_frame


func _near_angle(actual: float, expected: float, tolerance: float = 0.001) -> bool:
	return absf(wrapf(actual - expected, -180.0, 180.0)) <= tolerance


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL: " + description)
