extends SceneTree

const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_apparent_wind()
	_test_sail_force_model()
	_test_trim_and_lateral_resistance()
	await _test_lab_integration()
	if _failures.is_empty():
		print("Sailboat aerodynamics tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_apparent_wind() -> void:
	var still := AERO_MATH.calculate_apparent_wind(
		Vector3(0.0, 0.0, 8.0), Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Basis.IDENTITY
	)
	_expect(_near(still["apparent_velocity_world_mps"], Vector3(0.0, 0.0, 8.0)), "apparent wind is air velocity minus vessel point velocity")
	_expect(is_equal_approx(float(still["apparent_speed_mps"]), 8.0), "apparent wind speed remains in m/s")
	var rotating := AERO_MATH.calculate_apparent_wind(
		Vector3.ZERO,
		Vector3(0.0, 0.0, -2.0),
		Vector3(0.0, 1.0, 0.0),
		Vector3(1.0, 0.0, 0.0),
		Basis.IDENTITY
	)
	_expect(_near(rotating["sail_point_velocity_world_mps"], Vector3(0.0, 0.0, -3.0)), "apparent wind includes angular velocity crossed with sail lever arm")
	_expect(_near(rotating["apparent_velocity_world_mps"], Vector3(0.0, 0.0, 3.0)), "rotating sail point velocity is subtracted from air flow")
	var no_wind := AERO_MATH.calculate_apparent_wind(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Basis.IDENTITY)
	_expect(not bool(no_wind["valid"]), "zero apparent wind is safely marked invalid")


func _test_sail_force_model() -> void:
	var still_force := AERO_MATH.calculate_sail_forces(Vector3.ZERO, 0.7, 26.0)
	_expect(not bool(still_force["valid"]) and still_force["net_force_local_n"] == Vector3.ZERO, "zero relative wind produces exactly zero sail force")
	var four_mps := AERO_MATH.calculate_sail_forces(Vector3(8.0, 0.0, 0.0) * 0.5, 0.7, 26.0)
	var eight_mps := AERO_MATH.calculate_sail_forces(Vector3(8.0, 0.0, 0.0), 0.7, 26.0)
	_expect(absf(float(eight_mps["dynamic_pressure_pa"]) / float(four_mps["dynamic_pressure_pa"]) - 4.0) < 0.0001, "dynamic pressure scales with wind speed squared")
	_expect(float(eight_mps["cl"]) > 0.0, "port-side crosswind and starboard-trimmed sail have positive signed lift coefficient")
	var port_force: Vector3 = eight_mps["net_force_local_n"]
	var starboard := AERO_MATH.calculate_sail_forces(Vector3(-8.0, 0.0, 0.0), -0.7, 26.0)
	var starboard_force: Vector3 = starboard["net_force_local_n"]
	_expect(float(starboard["cl"]) < 0.0, "starboard-side crosswind mirrors the signed attack angle")
	_expect(port_force.z < 0.0 and starboard_force.z < 0.0, "both mirrored crosswind cases produce forward force")
	_expect(absf(port_force.z - starboard_force.z) < 0.01, "port and starboard forward forces are symmetric")
	_expect(absf(port_force.x + starboard_force.x) < 0.01, "port and starboard lateral forces are mirrored")
	var wrong_trim := AERO_MATH.calculate_sail_forces(Vector3(8.0, 0.0, 0.0), -0.7, 26.0)
	_expect(-port_force.z > -Vector3(wrong_trim["net_force_local_n"]).z, "incorrectly trimmed sail produces less forward force")
	var crosswind_right_sheet := AERO_MATH.calculate_sail_forces(
		Vector3(8.0, 0.0, 0.0), deg_to_rad(30.0), 10.16025, 1.225, 1.25, 0.384, 0.08, 0.55, 0.90, 0.611, 0.873, 0.20
	)
	var crosswind_backed_sheet := AERO_MATH.calculate_sail_forces(
		Vector3(8.0, 0.0, 0.0), deg_to_rad(-30.0), 10.16025, 1.225, 1.25, 0.384, 0.08, 0.55, 0.90, 0.611, 0.873, 0.20
	)
	var right_sheet_force: Vector3 = crosswind_right_sheet["net_force_local_n"]
	var backed_sheet_force: Vector3 = crosswind_backed_sheet["net_force_local_n"]
	_expect(float(crosswind_right_sheet["wrong_side_lift_scale"]) > 0.99, "leeward boom geometry retains full lift in crosswind")
	_expect(is_equal_approx(float(crosswind_backed_sheet["wrong_side_lift_scale"]), 0.20), "windward/backed boom geometry applies the configured bounded lift retention")
	_expect(right_sheet_force.z < backed_sheet_force.z, "backed-side crosswind trim produces less forward force")
	_expect(Vector3(crosswind_backed_sheet["drag_force_local_n"]).length() > 0.0, "backed-side drag remains available for downwind drive")
	var following_right := AERO_MATH.calculate_sail_forces(
		Vector3(0.0, 0.0, -8.0), deg_to_rad(60.0), 10.16025, 1.225, 1.25, 0.384, 0.08, 0.55, 0.90, 0.611, 0.873, 0.20
	)
	var following_left := AERO_MATH.calculate_sail_forces(
		Vector3(0.0, 0.0, -8.0), deg_to_rad(-60.0), 10.16025, 1.225, 1.25, 0.384, 0.08, 0.55, 0.90, 0.611, 0.873, 0.20
	)
	_expect(is_equal_approx(float(following_right["wrong_side_lift_scale"]), 1.0) and is_equal_approx(float(following_left["wrong_side_lift_scale"]), 1.0), "pure following wind has no arbitrary port/starboard penalty")
	_expect(Vector3(following_right["net_force_local_n"]).z < 0.0 and Vector3(following_left["net_force_local_n"]).z < 0.0, "following-wind drag still produces forward force for either boom side")
	var crossing_negative := AERO_MATH.calculate_sail_forces(
		Vector3(8.0, 0.0, 0.0), deg_to_rad(-0.01), 10.16025, 1.225, 1.25, 0.384, 0.08, 0.55, 0.90, 0.611, 0.873, 0.20
	)
	var crossing_positive := AERO_MATH.calculate_sail_forces(
		Vector3(8.0, 0.0, 0.0), deg_to_rad(0.01), 10.16025, 1.225, 1.25, 0.384, 0.08, 0.55, 0.90, 0.611, 0.873, 0.20
	)
	_expect(Vector3(crossing_negative["net_force_local_n"]).distance_to(Vector3(crossing_positive["net_force_local_n"])) < 1.0, "sheet-side efficiency is continuous through the centerline")
	var headwind := AERO_MATH.calculate_sail_forces(Vector3(0.0, 0.0, 8.0), 0.0, 26.0)
	_expect(float(Vector3(headwind["net_force_local_n"]).z) >= 0.0, "direct headwind cannot propel the bow forward")
	for trim_degrees in range(-80, 81, 20):
		var any_trim_headwind := AERO_MATH.calculate_sail_forces(
			Vector3(0.0, 0.0, 8.0), deg_to_rad(float(trim_degrees)), 26.0
		)
		var any_trim_headwind_force: Vector3 = any_trim_headwind["net_force_local_n"]
		_expect(any_trim_headwind_force.z >= 0.0, "direct headwind stays outside the propulsion envelope for every tested sheet angle")
		_expect(is_zero_approx(float(any_trim_headwind["cl"])), "the sail luffs and generates no lift in the direct headwind sector")
	var just_inside_luff := deg_to_rad(34.9)
	var just_outside_luff := deg_to_rad(35.1)
	var inside_vector := Vector3(-sin(just_inside_luff), 0.0, cos(just_inside_luff)) * 8.0
	var outside_vector := Vector3(-sin(just_outside_luff), 0.0, cos(just_outside_luff)) * 8.0
	var inside_luff := AERO_MATH.calculate_sail_forces(inside_vector, deg_to_rad(70.0), 26.0)
	var outside_luff := AERO_MATH.calculate_sail_forces(outside_vector, deg_to_rad(70.0), 26.0)
	_expect(absf(float(inside_luff["cl"]) - float(outside_luff["cl"])) < 0.005, "lift fades continuously at the configurable edge of the no-sail zone")
	var following := AERO_MATH.calculate_sail_forces(Vector3(0.0, 0.0, -8.0), 1.1, 26.0)
	_expect(float(Vector3(following["net_force_local_n"]).z) < 0.0, "following wind with eased sail produces forward drag")
	var torque_port := Vector3(0.0, 2.0, 0.0).cross(port_force)
	var torque_starboard := Vector3(0.0, 2.0, 0.0).cross(starboard_force)
	_expect(torque_port.z * torque_starboard.z < 0.0, "mirrored lateral sail forces create opposite roll moments at the elevated pressure centre")
	for degrees in range(-180, 181, 5):
		var sample := AERO_MATH.calculate_sail_forces(Vector3(11.0, 0.0, -3.0), deg_to_rad(float(degrees)), 26.0)
		_expect(is_finite(float(sample["cl"])) and absf(float(sample["cl"])) <= 1.25001, "lift coefficient stays finite and within its configured bound")
		_expect(is_finite(float(sample["cd"])) and float(sample["cd"]) >= 0.0 and float(sample["cd"]) <= 2.0, "drag coefficient stays finite and bounded")
		var force: Vector3 = sample["net_force_local_n"]
		_expect(is_finite(force.x) and is_finite(force.y) and is_finite(force.z), "sail force stays finite across the full angle sweep")


func _test_trim_and_lateral_resistance() -> void:
	var first_step := AERO_MATH.move_sail_angle_toward(0.0, deg_to_rad(80.0), 0.02, 0.35, deg_to_rad(-80.0), deg_to_rad(80.0))
	_expect(absf(first_step - 0.007) < 0.000001, "sail trim changes only by the configured rate per fixed physics step")
	var clamped_target := AERO_MATH.move_sail_angle_toward(0.0, deg_to_rad(120.0), 10.0, 2.0, deg_to_rad(-80.0), deg_to_rad(80.0))
	_expect(clamped_target <= deg_to_rad(80.0) + 0.000001, "sail trim respects its mechanical angle limit")
	var side := AERO_MATH.side_resistance_force_local(Vector3(3.0, 0.0, -2.0), 7000.0, 3000.0, 10000.0)
	_expect(side.x < 0.0 and side.z == 0.0, "temporary lateral resistance opposes leeway without adding forward drive")
	_expect(AERO_MATH.side_resistance_force_local(Vector3(0.0, 0.0, 5.0), 7000.0, 3000.0, 10000.0) == Vector3.ZERO, "zero lateral velocity has zero temporary side resistance")
	var opposite_side := AERO_MATH.side_resistance_force_local(Vector3(-3.0, 0.0, 0.0), 7000.0, 3000.0, 10000.0)
	_expect(opposite_side.x > 0.0, "lateral resistance reverses sign with leeway direction")


func _test_lab_integration() -> void:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	var boat := lab.get_node("SailboatBody") as RigidBody3D
	var field := lab.get_node("WindField") as WindField
	var debug_panel := lab.get_node("DebugPanel") as CanvasLayer
	var visual_root := boat.get_node("VisualRoot") as Node3D
	var mast := visual_root.get_node("Mast") as MeshInstance3D
	var sail_visual := visual_root.get_node("VisualBoomPivot") as Node3D
	var boom := sail_visual.get_node("Boom") as MeshInstance3D
	var mainsail := sail_visual.get_node("MainSailMesh") as MeshInstance3D
	var mast_material := mast.material_override as StandardMaterial3D
	var sail_material := mainsail.material_override as ShaderMaterial
	var tabs := debug_panel.find_child("SailboatDebugTabs", true, false) as TabContainer
	_expect(boat != null and field != null, "SailboatLab has an independent body and local WindField")
	var visual_profile: Resource = visual_root.get_node("VisualRigAnchors").get("visual_profile")
	_expect(
		visual_root.position.is_equal_approx(visual_profile.get("visual_assembly_offset_local_m"))
			and visual_root.position.is_equal_approx(Vector3(0.0, -0.30, 0.0)),
		"Nordic 28 visual assembly uses the shared 30 cm draft offset"
	)
	_expect(mast != null and mast.mesh is CylinderMesh, "fixed mast uses a lightweight cylinder outside the sail pivot")
	_expect(boom != null and boom.mesh is CylinderMesh, "boom is a lightweight cylinder attached to the sail pivot")
	_expect(mainsail != null and mainsail.mesh is ArrayMesh, "mainsail is a static ArrayMesh rather than a rectangular placeholder")
	_expect(mast_material != null and mast_material.albedo_color.r > 0.50 and mast_material.metallic > 0.25 and mast_material.roughness > 0.45, "mast and Boom use the approved soft silver-gray aluminum finish")
	_expect(sail_material != null and not sail_material.shader.code.contains("blend_") , "mainsail uses opaque solid cloth shading")
	_expect(sail_material != null and sail_material.shader.code.contains("cull_disabled"), "mainsail shader renders both sides")
	if mast != null and mast.mesh is CylinderMesh:
		var mast_mesh := mast.mesh as CylinderMesh
		var rig_snapshot: Dictionary = visual_root.get_node("VisualRigAnchors").call("get_alignment_snapshot")
		var visual_mast_base: Vector3 = rig_snapshot.get("visual_mast_base_local_m", Vector3.ZERO)
		var visual_mast_top: Vector3 = rig_snapshot.get("visual_mast_top_local_m", Vector3.ZERO)
		_expect(absf((mast.position.y - mast_mesh.height * 0.5) - visual_mast_base.y) < 0.01, "visual mast foot follows the approved Nordic 28 V2 mast step")
		_expect(absf((mast.position.y + mast_mesh.height * 0.5) - visual_mast_top.y) < 0.02, "visual mast head follows the Nordic 28 rig anchor")
		_expect(absf(mast_mesh.height - 6.50) < 0.001, "Nordic 28 V2 mast is 6.50 m tall")
	if boom != null and boom.mesh is CylinderMesh:
		_expect(absf((boom.mesh as CylinderMesh).height - 3.30) < 0.001, "Nordic 28 V2 Boom is 3.30 m and stops before the stern helm position")
	_expect(tabs != null and tabs.get_tab_count() == 7, "underwater inspection is added while sail telemetry stays in the shared debug panel")
	if boat == null or field == null:
		lab.queue_free()
		await process_frame
		return
	var profile: Resource = boat.get("profile")
	var sail_area := float(profile.get("main_sail_area_m2"))
	var pressure_from_pivot: Vector3 = profile.get("main_sail_pressure_center_from_pivot_m")
	_expect(absf(sail_area - 10.16025) < 0.001, "Nordic 28 visual update leaves the calibrated physical mainsail area unchanged")
	var rig_geometry: Dictionary = visual_root.get_node("VisualRigAnchors").call("get_alignment_snapshot")
	_expect(absf(float(rig_geometry.get("main_visual_area_m2", 0.0)) - 9.450) < 0.002, "raised Boom gives a 9.45 m2 visual mainsail without changing physical area")
	_expect(absf(float(rig_geometry.get("visual_boom_local_m", Vector3.ZERO).y) - 1.9111) < 0.001, "Nordic 28 V2.1 raises the visual Boom 10 cm")
	_expect(absf(float(rig_geometry.get("jib_visual_area_m2", 0.0)) - 5.160) < 0.002, "Nordic 28 V2 fractional-height Jib remains near 5.16 m2 visually")
	_expect(absf(pressure_from_pivot.y - 2.4) < 0.001 and absf(pressure_from_pivot.z - 0.8) < 0.001, "the original calibrated physical pressure-centre offset is unchanged")
	if mainsail != null and mainsail.mesh is ArrayMesh:
		var sail_arrays: Array = (mainsail.mesh as ArrayMesh).surface_get_arrays(0)
		var sail_vertices: PackedVector3Array = sail_arrays[Mesh.ARRAY_VERTEX]
		var sail_uvs: PackedVector2Array = sail_arrays[Mesh.ARRAY_TEX_UV]
		_expect(sail_vertices.size() == 297 and sail_uvs.size() == sail_vertices.size(), "Bermuda sail has a subdivided UV-mapped cloth grid")
		if sail_vertices.size() == 297:
			var head := sail_vertices[26 * 11]
			var tack := sail_vertices[0]
			var clew := sail_vertices[10]
			_expect(head.y > tack.y and head.y > clew.y, "sail head is above the tack and clew")
			_expect(absf(head.x) < 0.001 and absf(tack.x) < 0.001 and absf(clew.x) < 0.001, "luff, tack, and clew share the sail plane at the mast")
			_expect(clew.z > tack.z, "clew and boom extend aft along local +Z")
			_expect(absf(tack.y - clew.y) < 0.001, "sail foot follows the boom at a consistent height")
	_expect(mast.get_parent() == visual_root and mast.get_parent() != sail_visual, "mast stays fixed while the sail and boom share the trim pivot")
	_expect(is_equal_approx(sail_visual.rotation.y, 0.0), "zero trim starts with the boom aimed aft on the centerline")
	for trim_degrees in [-80.0, -60.0, -30.0, 0.0, 30.0, 60.0, 80.0]:
		var expected_angle := deg_to_rad(trim_degrees)
		boat.set("actual_sail_angle_rad", expected_angle)
		boat.call("_process", 0.0)
		_expect(absf(sail_visual.rotation.y - expected_angle) < 0.001, "visual pivot follows actual sail angle at %d degrees" % int(trim_degrees))
		var rotated_clew := sail_visual.transform.basis * Vector3(0.0, 0.0, 3.30)
		if trim_degrees > 0.0:
			_expect(rotated_clew.x > 0.0, "positive trim angles from 30 to 50 degrees rotate aft hardware toward starboard")
		elif trim_degrees < 0.0:
			_expect(rotated_clew.x < 0.0, "negative trim angles from -30 to -50 degrees rotate aft hardware toward port")
		else:
			_expect(absf(rotated_clew.x) < 0.001 and rotated_clew.z > 0.0, "zero trim keeps the boom directed aft")
	boat.set("actual_sail_angle_rad", 0.0)
	boat.call("_process", 0.0)
	boat.call("set_dynamic_waves_enabled", false)
	boat.call("reset_to_neutral")
	for _step in range(60):
		await physics_frame
	_expect(bool(boat.call("can_set_lab_test_wind")), "isolated lab permits local test wind")
	_expect(bool(boat.call("set_lab_test_wind", 8.0, 270.0)), "local wind preset changes only the laboratory WindField")
	boat.call("set_target_sail_angle", deg_to_rad(70.0))
	for _step in range(120):
		await physics_frame
	var port_snapshot: Dictionary = boat.call("get_debug_snapshot")
	_expect(int(port_snapshot.get("wind_query_count_per_tick", -1)) == 1, "exactly one WindField query is performed per physics tick")
	_expect(int(port_snapshot.get("wave_query_count_per_tick", -1)) == 0, "sail aerodynamics adds no wave queries")
	_expect(float(port_snapshot.get("true_wind_speed_mps", 0.0)) > 7.99, "body reads the local WindField vector in m/s")
	_expect(float(port_snapshot.get("sail_net_force_local_n", Vector3.ZERO).z) < 0.0, "the laboratory applies an actual forward sail force")
	_expect(float(port_snapshot.get("longitudinal_velocity_mps", 0.0)) > 0.01, "rigid-body solver converts sail force into vessel motion")
	_expect(float(port_snapshot.get("sail_sheet_efficiency_scale", 1.0)) > 0.99, "production body applies the configured leeward sheet model")
	_expect(absf(float(port_snapshot.get("roll_degrees", 0.0))) > 0.1, "elevated sail pressure centre creates a physical hull heel response")
	for _step in range(120):
		await physics_frame
	port_snapshot = boat.call("get_debug_snapshot")
	_expect(absf(float(port_snapshot.get("actual_sail_angle_rad", 0.0)) - deg_to_rad(70.0)) < 0.03, "visual and physical sail angle reach the same rate-limited target")
	var expected_pressure_center: Vector3 = profile.get("main_sail_pivot_local_m") + Basis(Vector3.UP, float(port_snapshot.get("actual_sail_angle_rad", 0.0))) * pressure_from_pivot
	_expect(_near(port_snapshot.get("sail_pressure_center_local_m", Vector3.ZERO), expected_pressure_center), "pressure centre position follows the actual boom angle in the sail-pivot frame")
	_expect(absf(sail_visual.rotation.y - float(port_snapshot.get("actual_sail_angle_rad", 0.0))) < 0.001, "Bermuda mainsail and boom mirror the rate-limited physical sail angle")
	var local_boom_direction := sail_visual.transform.basis * Vector3(0.0, 0.0, 1.0)
	_expect(local_boom_direction.x > 0.0, "positive trim angle swings the aft boom toward starboard (+X)")
	var target_before := float(port_snapshot.get("target_sail_angle_rad", 0.0))
	boat.call("reset_performance_history")
	boat.call("set_dynamic_waves_enabled", true)
	for _step in range(120):
		await physics_frame
	var combined_snapshot: Dictionary = boat.call("get_debug_snapshot")
	_expect(int(combined_snapshot.get("wave_query_count_per_tick", -1)) == 4, "adding sail forces preserves the four-point dynamic-wave sample budget")
	_expect(int(combined_snapshot.get("wind_query_count_per_tick", -1)) == 1, "dynamic-wave sailing still performs only one WindField query")
	print("[SAILBOAT_C1_PERF] sail + normal-wave avg/P95=%d/%d μs · wind %d/%d μs · aero %d/%d μs · wave queries=%d · wind queries=%d" % [
		int(combined_snapshot.get("total_physics_calculation_average_usec", 0)),
		int(combined_snapshot.get("total_physics_calculation_p95_usec", 0)),
		int(combined_snapshot.get("wind_sample_average_usec", 0)),
		int(combined_snapshot.get("wind_sample_p95_usec", 0)),
		int(combined_snapshot.get("aero_calculation_average_usec", 0)),
		int(combined_snapshot.get("aero_calculation_p95_usec", 0)),
		int(combined_snapshot.get("wave_query_count_per_tick", -1)),
		int(combined_snapshot.get("wind_query_count_per_tick", -1)),
	])
	boat.call("set_dynamic_waves_enabled", false)
	boat.call("reset_performance_history")
	for _step in range(120):
		await physics_frame
	var wind_only_snapshot: Dictionary = boat.call("get_debug_snapshot")
	_expect(int(wind_only_snapshot.get("wave_query_count_per_tick", -1)) == 0, "wind-only measurement runs without wave sampling")
	_expect(int(wind_only_snapshot.get("wind_query_count_per_tick", -1)) == 1, "wind-only measurement keeps one WindField query per step")
	print("[SAILBOAT_C1_PERF] wind-only avg/P95=%d/%d μs · wind %d/%d μs · aero %d/%d μs · wave queries=%d · wind queries=%d" % [
		int(wind_only_snapshot.get("total_physics_calculation_average_usec", 0)),
		int(wind_only_snapshot.get("total_physics_calculation_p95_usec", 0)),
		int(wind_only_snapshot.get("wind_sample_average_usec", 0)),
		int(wind_only_snapshot.get("wind_sample_p95_usec", 0)),
		int(wind_only_snapshot.get("aero_calculation_average_usec", 0)),
		int(wind_only_snapshot.get("aero_calculation_p95_usec", 0)),
		int(wind_only_snapshot.get("wave_query_count_per_tick", -1)),
		int(wind_only_snapshot.get("wind_query_count_per_tick", -1)),
	])
	field.set_debug_wind_override({
		"mean_wind_speed_mps": 12.0,
		"mean_wind_from_degrees": 90.0,
		"gust_strength_mps": 0.0,
		"gust_direction_variation_degrees": 0.0,
	})
	await physics_frame
	var overlay_snapshot: Dictionary = boat.call("get_debug_snapshot")
	_expect(str(overlay_snapshot.get("wind_debug_override_state", "")) == "active", "WindField's temporary debug overlay is visible to this physical consumer")
	_expect(absf(float(overlay_snapshot.get("true_wind_speed_mps", 0.0)) - 12.0) < 0.01, "F12-style overlay changes sampled wind without a second query")
	_expect(is_equal_approx(float(overlay_snapshot.get("target_sail_angle_rad", 0.0)), target_before), "wind overlay does not alter the sail control target")
	field.clear_debug_wind_override(0.0)
	_expect(is_equal_approx(field.mean_wind_speed_mps, 8.0) and is_equal_approx(field.mean_wind_from_degrees, 270.0), "clearing the temporary wind overlay restores the local formal wind target")
	field.apply_formal_weather_settings({
		"mean_wind_speed_mps": 5.0,
		"mean_wind_from_degrees": 120.0,
		"gust_strength_mps": 0.0,
		"gust_time_scale_seconds": 24.0,
		"gust_space_scale_meters": 450.0,
		"gust_direction_variation_degrees": 0.0,
	})
	var formal_speed_before := field.mean_wind_speed_mps
	_expect(not bool(boat.call("can_set_lab_test_wind")), "formal WeatherStateController ownership disables local test controls")
	_expect(not bool(boat.call("set_lab_test_wind", 20.0, 180.0)), "local preset refuses to write into a formally owned field")
	_expect(is_equal_approx(field.mean_wind_speed_mps, formal_speed_before), "refused local override leaves formal wind unchanged")
	lab.queue_free()
	await process_frame


func _near(left: Vector3, right: Vector3, epsilon: float = 0.0001) -> bool:
	return left.distance_to(right) <= epsilon


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("Sailboat aerodynamics test failed: %s" % description)
