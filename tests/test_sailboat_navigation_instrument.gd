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
	_expect(tabs != null and tabs.get_tab_count() == 6, "the existing six debug tabs remain unchanged beside the instrument")
	_expect(instrument != null and tabs != null and not tabs.is_ancestor_of(instrument), "navigation instrument is a separate panel rather than a tab")
	if instrument != null:
		var viewport_width := instrument.get_viewport().get_visible_rect().size.x
		var expected_width := clampf(viewport_width * 0.235, 270.0, 320.0)
		_expect(
			absf(instrument.position.x - (viewport_width - expected_width - 16.0)) < 0.1
				and absf(instrument.position.y - 16.0) < 0.1,
			"navigation panel follows the viewport's upper-right anchor"
		)

	var visual_root := boat.get_node("VisualRoot")
	var hull := visual_root.get_node("Hull") as MeshInstance3D
	var deck := visual_root.get_node("Deck") as MeshInstance3D
	_expect(hull.mesh is ArrayMesh and deck.mesh is ArrayMesh, "the hull and deck use generated low-poly visual meshes")
	if hull.mesh is ArrayMesh:
		var hull_arrays := (hull.mesh as ArrayMesh).surface_get_arrays(0)
		var vertices: PackedVector3Array = hull_arrays[Mesh.ARRAY_VERTEX]
		var bow_half_width := _max_abs_x_near_z(vertices, -3.9)
		var stern_half_width := _max_abs_x_near_z(vertices, 3.9)
		_expect(bow_half_width < 0.1, "the visual bow tapers to a point at local -Z")
		_expect(stern_half_width > 1.0, "the visual stern remains broad at local +Z")
	var collision := boat.get_node("CollisionShape3D") as CollisionShape3D
	var hull_shape := collision.shape as BoxShape3D
	_expect(hull_shape.size.is_equal_approx(Vector3(2.5, 1.2, 7.4)), "the C3 visual change leaves the original collision box unchanged")
	var profile: Resource = boat.get("profile")
	_expect(profile.get("mass_kg") == 3200.0, "the visual change leaves the test-vessel mass profile unchanged")

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
	var sail_pivot := visual_root.get_node("SailPivot") as Node3D
	var rudder_pivot := visual_root.get_node("RudderPivot") as Node3D
	var rudder_marker := visual_root.get_node("RudderAngleMarker") as Node3D
	_expect(absf(sail_pivot.rotation.y - deg_to_rad(27.0)) < 0.0001, "3D mainsail visual follows actual rather than target trim angle")
	_expect(absf(rudder_pivot.rotation.y - deg_to_rad(18.0)) < 0.0001, "underwater rudder visual follows actual rudder angle")
	_expect(absf(rudder_marker.rotation.y - deg_to_rad(18.0)) < 0.0001, "visible stern rudder marker exactly mirrors the underwater rudder")

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
	lab.queue_free()
	await process_frame


func _max_abs_x_near_z(vertices: PackedVector3Array, z_value: float) -> float:
	var maximum := 0.0
	for vertex in vertices:
		if absf(vertex.z - z_value) < 0.01:
			maximum = maxf(maximum, absf(vertex.x))
	return maximum


func _near_angle(actual: float, expected: float, tolerance: float = 0.001) -> bool:
	return absf(wrapf(actual - expected, -180.0, 180.0)) <= tolerance


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL: " + description)
