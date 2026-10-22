extends SceneTree

const AERO := preload("res://scripts/sailboat_aero_math.gd")
const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const PROFILE := preload("res://resources/sailing/sailboat_lab_profile.tres")

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_geometry_and_shared_aero()
	await _test_lab_physics_and_visuals()
	if _failures.is_empty():
		print("Sailboat independent headsail tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_geometry_and_shared_aero() -> void:
	var head := Vector3(0.0, 4.95, -0.75)
	var tack := Vector3(0.0, 0.65, -3.55)
	var clew := Vector3(0.0, 0.65, -1.15)
	_expect(absf(AERO.triangular_sail_area_m2(head, tack, clew) - 5.16) < 0.001, "deck-clear Jib candidate has the expected nominal triangular planform area")
	_expect(AERO.triangular_sail_centroid(head, tack, clew).distance_to(Vector3(0.0, 2.083333, -1.816667)) < 0.001, "neutral headsail pressure-centre starting point is the triangle centroid")
	var positive_clew := AERO.headsail_clew_from_sheet(tack, clew, deg_to_rad(30.0))
	var negative_clew := AERO.headsail_clew_from_sheet(tack, clew, deg_to_rad(-30.0))
	_expect(positive_clew.x > 0.0 and negative_clew.x < 0.0, "positive and negative jib sheet angles move Clew to mirrored sides")
	_expect(positive_clew.distance_to(tack) - clew.distance_to(tack) < 0.0001, "sheet rotation preserves the Clew-to-Tack foot length")
	_expect(AERO.triangular_sail_area_m2(head, tack, positive_clew) > 0.0, "sheeted Jib remains a valid triangle")
	_expect(positive_clew.y > 0.63 and negative_clew.y > 0.63, "both sheet extremes keep the Clew above the test deck")
	_expect(AERO.triangular_sail_area_m2(head, tack, negative_clew) > 0.0, "opposite sheet angle remains a valid triangle")
	var overlap_found := false
	var checked_angle_pairs := 0
	var main_tack_local := Vector3(0.0, 0.73, -0.75)
	var main_head_local := Vector3(0.0, 5.10, -0.71)
	var main_clew_neutral_local := Vector3(0.0, 0.73, 3.90)
	for main_angle_degrees in range(-80, 81, 5):
		var main_clew_local := main_tack_local + Basis(Vector3.UP, deg_to_rad(float(main_angle_degrees))) * (main_clew_neutral_local - main_tack_local)
		var main_triangle := PackedVector3Array([main_head_local, main_tack_local, main_clew_local])
		for jib_angle_degrees in range(-70, 71, 5):
			var jib_clew := AERO.headsail_clew_from_sheet(tack, clew, deg_to_rad(float(jib_angle_degrees)))
			var jib_triangle := PackedVector3Array([head, tack, jib_clew])
			checked_angle_pairs += 1
			if _triangles_overlap(main_triangle, jib_triangle):
				overlap_found = true
	_expect(not overlap_found and checked_angle_pairs == 957, "sampled full mainsail/Jib trim range has no triangle intersection")

	var port := AERO.calculate_sail_forces_for_chord(Vector3(8.0, 0.0, 0.0), Vector2(sin(deg_to_rad(30.0)), cos(deg_to_rad(30.0))), 5.196, 1.225, 1.25, 0.384, 0.08, 0.55, 0.9, 0.611, 0.873, 0.20)
	var starboard := AERO.calculate_sail_forces_for_chord(Vector3(-8.0, 0.0, 0.0), Vector2(-sin(deg_to_rad(30.0)), cos(deg_to_rad(30.0))), 5.196, 1.225, 1.25, 0.384, 0.08, 0.55, 0.9, 0.611, 0.873, 0.20)
	var port_force: Vector3 = port.get("net_force_local_n", Vector3.ZERO)
	var starboard_force: Vector3 = starboard.get("net_force_local_n", Vector3.ZERO)
	_expect(port_force.z < 0.0 and starboard_force.z < 0.0, "both mirrored jib crosswind cases produce forward force")
	_expect(absf(port_force.z - starboard_force.z) < 0.01 and absf(port_force.x + starboard_force.x) < 0.01, "generic chord aerodynamics preserve port/starboard force symmetry")
	_expect(float(port.get("wrong_side_lift_scale", 0.0)) > 0.99 and float(starboard.get("wrong_side_lift_scale", 0.0)) > 0.99, "correct crosswind jib trim retains its lift on each mirrored tack")
	var backed := AERO.calculate_sail_forces_for_chord(Vector3(8.0, 0.0, 0.0), Vector2(-sin(deg_to_rad(30.0)), cos(deg_to_rad(30.0))), 5.196, 1.225, 1.25, 0.384, 0.08, 0.55, 0.9, 0.611, 0.873, 0.20)
	_expect(float(backed.get("wrong_side_lift_scale", 1.0)) < 0.21, "wrong-side jib sheet receives the configured continuous backing penalty")
	var calm := AERO.calculate_sail_forces_for_chord(Vector3.ZERO, Vector2(0.5, 0.866), 5.196)
	_expect(Vector3(calm.get("net_force_local_n", Vector3.ONE)) == Vector3.ZERO, "zero wind produces exactly zero jib force")
	var headwind := AERO.calculate_sail_forces_for_chord(Vector3(0.0, 0.0, 8.0), Vector2.ZERO, 5.196)
	_expect(not bool(headwind.get("valid", true)), "invalid zero chord is safely rejected")
	var luff := AERO.calculate_sail_forces_for_chord(Vector3(0.0, 0.0, 8.0), Vector2(0.0, 1.0), 5.196, 1.225, 1.25, 0.384, 0.08, 0.55, 0.9, 0.611, 0.873, 0.20)
	_expect(is_zero_approx(float(luff.get("cl", 0.0))), "direct headwind jib luffs without artificial lift propulsion")


func _test_lab_physics_and_visuals() -> void:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	var boat := lab.get_node("SailboatBody") as RigidBody3D
	var profile: Resource = boat.get("profile")
	var visual := boat.get_node("VisualRoot/HeadsailVisual") as MeshInstance3D
	var debug_panel := lab.get_node("DebugPanel")
	var jib_controls := debug_panel.find_child("HeadsailTargetAngle", true, false) as HSlider
	var tabs := debug_panel.find_child("SailboatDebugTabs", true, false) as TabContainer
	_expect(visual != null and visual.mesh is ArrayMesh, "Jib is a lightweight ArrayMesh component under the boat visual root")
	_expect(visual != null and visual.get_script().resource_path.ends_with("headsail_triangle_visual.gd"), "Jib visual has its independent low-cost triangle controller")
	_expect(jib_controls != null and tabs != null and tabs.get_tab_count() == 6, "headsail controls extend the existing sail tab without adding another debug tab")
	_expect(absf(float(profile.get("headsail_area_m2")) - 5.16) < 0.001, "Jib nominal area comes from the vessel Resource")
	var jib_key := InputEventKey.new()
	jib_key.keycode = KEY_J
	jib_key.pressed = true
	boat.call("_input", jib_key)
	_expect(absf(float(boat.call("get_target_headsail_angle")) + deg_to_rad(10.0)) < 0.0001, "J decrements the independent Jib target angle")
	jib_key.keycode = KEY_L
	boat.call("_input", jib_key)
	_expect(absf(float(boat.call("get_target_headsail_angle"))) < 0.0001, "L increments the independent Jib target angle")
	boat.call("set_target_headsail_angle", PI)
	var max_jib_angle := float(boat.call("get_debug_snapshot").get("max_headsail_angle_rad", 0.0))
	_expect(absf(float(boat.call("get_target_headsail_angle")) - max_jib_angle) < 0.0001, "Jib target is clamped to the vessel-specific mechanical limit")
	boat.set("actual_headsail_angle_rad", 0.0)
	await physics_frame
	var trim_step_rad := float(boat.call("get_actual_headsail_angle"))
	var trim_step_limit_rad := float(profile.get("headsail_rotation_speed_rad_s")) / float(Engine.physics_ticks_per_second)
	_expect(trim_step_rad > 0.0 and trim_step_rad <= trim_step_limit_rad + 0.0001, "actual Jib angle follows its target at the configured mechanical rate")
	boat.call("reset_to_neutral")
	await physics_frame
	if visual != null:
		var mesh := visual.mesh as ArrayMesh
		var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		_expect(vertices.size() == 3, "dynamic headsail uses exactly one low-poly triangle")
		if vertices.size() == 3:
			_expect(vertices[0].y > vertices[1].y and vertices[0].y > vertices[2].y, "Jib head remains above Tack and Clew")
			_expect(vertices[1].z < vertices[2].z, "neutral jib Clew sits aft of its bow Tack")
		var pivot_parent := visual.get_parent()
		_expect(pivot_parent == boat.get_node("VisualRoot"), "Jib Head and Tack do not inherit the mainsail Boom pivot")
		visual.call("set_sheet_angle", deg_to_rad(30.0))
		vertices = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		_expect(vertices[0].is_equal_approx(profile.get("headsail_head_local_m")) and vertices[1].is_equal_approx(profile.get("headsail_tack_local_m")), "sheet movement keeps Jib Head and Tack fixed")
		var positive_visual_vertices: PackedVector3Array = visual.call("get_vertices_for_angle", deg_to_rad(30.0))
		_expect(positive_visual_vertices[2].x > 0.0, "positive sheet moves the visual Clew to starboard")
		visual.call("set_sheet_angle", deg_to_rad(-30.0))
		var negative_visual_vertices: PackedVector3Array = visual.call("get_vertices_for_angle", deg_to_rad(-30.0))
		_expect(negative_visual_vertices[2].x < 0.0, "negative sheet moves the visual Clew to port")

	boat.call("set_dynamic_waves_enabled", false)
	boat.call("reset_to_neutral")
	await physics_frame
	boat.call("set_lab_test_wind", 8.0, 270.0)
	boat.call("set_target_sail_angle", 0.0)
	boat.set("actual_sail_angle_rad", 0.0)
	boat.call("set_target_headsail_angle", deg_to_rad(30.0))
	boat.set("actual_headsail_angle_rad", deg_to_rad(30.0))
	boat.call("set_headsail_enabled", true)
	boat.sleeping = false
	await physics_frame
	var active: Dictionary = boat.call("get_debug_snapshot")
	var jib_force: Vector3 = active.get("headsail_net_force_local_n", Vector3.ZERO)
	_expect(jib_force.length() > 10.0, "enabled Jib produces an independent force at the crosswind test")
	_expect(jib_force.z < 0.0, "crosswind Jib force has a forward component")
	_expect(absf(float(active.get("headsail_effective_area_m2", 0.0)) - float(profile.get("headsail_area_m2"))) < 0.001, "Jib physical area remains the vessel profile value at nonzero sheet angle")
	_expect(int(active.get("wind_query_count_per_tick", 0)) == 1, "main and Jib share exactly one WindField query per physics tick")
	_expect(int(active.get("wave_query_count_per_tick", -1)) == 0, "Jib adds no WaveSampler queries in static water")
	var cp: Vector3 = active.get("headsail_pressure_center_local_m", Vector3.ZERO)
	var expected_torque := (cp - Vector3(profile.get("center_of_mass_m"))).cross(jib_force).y
	_expect(absf(float(active.get("headsail_yaw_torque_nm", 0.0)) - expected_torque) < 0.1, "Jib torque uses its own centre-of-pressure lever arm relative to COM")
	var expected_roll_torque := (cp - Vector3(profile.get("center_of_mass_m"))).cross(jib_force).z
	_expect(absf(float(active.get("headsail_roll_torque_local_nm", 0.0)) - expected_roll_torque) < 0.1, "Jib roll moment is reported from the same independent force application point")
	var total_force: Vector3 = active.get("total_horizontal_force_local_n", Vector3.ZERO)
	_expect(total_force.distance_to(Vector3(active.get("sail_net_force_local_n", Vector3.ZERO)) + jib_force + Vector3(active.get("hull_drag_force_local_n", Vector3.ZERO)) + Vector3(active.get("keel_force_local_n", Vector3.ZERO)) + Vector3(active.get("rudder_force_local_n", Vector3.ZERO))) < 0.1, "total force snapshot includes each sail and waterfoil once")
	var nav: Dictionary = boat.call("get_navigation_snapshot")
	_expect(absf(float(nav.get("actual_headsail_angle_rad", -1.0)) - float(boat.get("actual_headsail_angle_rad"))) < 0.0001, "navigation snapshot exposes the actual Jib angle")

	boat.call("set_headsail_enabled", false)
	await physics_frame
	var disabled: Dictionary = boat.call("get_debug_snapshot")
	_expect(not bool(disabled.get("headsail_enabled", true)), "Jib debug toggle disables the Jib force and visual")
	_expect(Vector3(disabled.get("headsail_net_force_local_n", Vector3.ONE)) == Vector3.ZERO, "disabled Jib has zero cached force")
	_expect(is_zero_approx(float(disabled.get("headsail_yaw_torque_nm", 1.0))), "disabled Jib has no residual yaw moment")
	_expect(is_zero_approx(float(disabled.get("headsail_roll_torque_local_nm", 1.0))), "disabled Jib has no residual roll moment")
	_expect(Vector3(disabled.get("total_horizontal_force_local_n", Vector3.ZERO)).distance_to(Vector3(disabled.get("sail_net_force_local_n", Vector3.ZERO)) + Vector3(disabled.get("hull_drag_force_local_n", Vector3.ZERO)) + Vector3(disabled.get("keel_force_local_n", Vector3.ZERO)) + Vector3(disabled.get("rudder_force_local_n", Vector3.ZERO))) < 0.1, "disabled Jib restores the single-mainsail force sum")
	_expect(not visual.visible, "disabled Jib visual is hidden without changing the mainsail")
	var saved_main_area := float(boat.get("_sail_area_m2"))
	_expect(absf(saved_main_area - float(profile.get("main_sail_area_m2"))) < 0.0001, "Jib enable toggle does not change the mainsail area")
	lab.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL: " + message)


func _triangles_overlap(first: PackedVector3Array, second: PackedVector3Array) -> bool:
	var first_edges := [first[1] - first[0], first[2] - first[1], first[0] - first[2]]
	var second_edges := [second[1] - second[0], second[2] - second[1], second[0] - second[2]]
	var first_normal: Vector3 = first_edges[0].cross(first_edges[1])
	var second_normal: Vector3 = second_edges[0].cross(second_edges[1])
	var axes: Array[Vector3] = [first_normal, second_normal]
	for first_edge in first_edges:
		for second_edge in second_edges:
			axes.append(first_edge.cross(second_edge))
			axes.append(first_normal.cross(first_edge))
			axes.append(first_normal.cross(second_edge))
			axes.append(second_normal.cross(first_edge))
			axes.append(second_normal.cross(second_edge))
	for axis in axes:
		if axis.length_squared() < 0.00000001:
			continue
		var first_min := first[0].dot(axis)
		var first_max := first_min
		var second_min := second[0].dot(axis)
		var second_max := second_min
		for index in range(1, 3):
			var first_projection := first[index].dot(axis)
			var second_projection := second[index].dot(axis)
			first_min = minf(first_min, first_projection)
			first_max = maxf(first_max, first_projection)
			second_min = minf(second_min, second_projection)
			second_max = maxf(second_max, second_projection)
		if first_max < second_min - 0.00001 or second_max < first_min - 0.00001:
			return false
	return true
