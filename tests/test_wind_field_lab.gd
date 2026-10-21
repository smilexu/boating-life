extends SceneTree

const WIND_FIELD_SCRIPT := preload("res://scripts/wind_field.gd")
const WIND_PANEL_SCRIPT := preload("res://scripts/wind_field_debug_panel.gd")
const WIND_LAB_SCRIPT := preload("res://scripts/wind_field_lab.gd")
const WIND_GRAPH_SCRIPT := preload("res://scripts/wind_field_speed_graph.gd")

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	_test_direction_presets()
	_test_arrow_mapping()
	_test_grid_sampling_coordinates()
	_test_gust_spatial_continuity()
	_test_graph_window()
	_test_panel_sizes()
	if _failures.is_empty():
		print("WindFieldLab tests: all checks passed (%d checks)." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_direction_presets() -> void:
	var cases := ["north", "west", "calm"]
	for preset_id in cases:
		var preset: Dictionary = WIND_PANEL_SCRIPT.preset_definition(preset_id)
		var field: WindField = WIND_FIELD_SCRIPT.new() as WindField
		field.set_random_seed(74291)
		field.set_test_simulation_time(0.0)
		field.set_mean_wind(float(preset["mean_speed_mps"]), float(preset["wind_from_degrees"]))
		field.gust_strength_mps = float(preset["gust_strength_mps"])
		var expected: Vector3 = preset["expected_wind"]
		var actual := field.get_wind_at(Vector3.ZERO)
		_expect(actual.distance_to(expected) <= 0.05, "%s preset matches its expected world vector" % preset_id)
		_expect(float(preset["gust_strength_mps"]) == 0.0, "%s is a no-gust preset" % preset_id)
		field.free()
	var gust_preset: Dictionary = WIND_PANEL_SCRIPT.preset_definition("gust")
	_expect(is_equal_approx(float(gust_preset["mean_speed_mps"]), 8.0), "gust preset mean wind is 8 m/s")
	_expect(is_equal_approx(float(gust_preset["gust_strength_mps"]), 3.0), "gust preset strength is 3 m/s")
	_expect(not bool(gust_preset.get("has_expected_wind", true)), "gust preset has no fixed instantaneous vector")


func _test_arrow_mapping() -> void:
	var vectors := [Vector3(0.0, 0.0, 8.0), Vector3(8.0, 0.0, 0.0), Vector3(0.0, 0.0, -8.0), Vector3(-8.0, 0.0, 0.0)]
	for wind in vectors:
		var basis: Basis = WIND_LAB_SCRIPT.arrow_basis_for_wind(wind)
		var displayed_flow := -basis.z.normalized()
		var expected_flow := Vector3(wind.x, 0.0, wind.z).normalized()
		_expect(displayed_flow.distance_to(expected_flow) <= 0.0001, "3D array arrow forward axis matches actual airflow")
	_expect(WIND_LAB_SCRIPT.arrow_basis_for_wind(Vector3.ZERO).is_equal_approx(Basis.IDENTITY), "calm arrow uses neutral orientation")


func _test_grid_sampling_coordinates() -> void:
	var origin := Vector3(120.0, 5.0, -340.0)
	_expect(WIND_LAB_SCRIPT.grid_sample_position(origin, 3, 3, 7) == origin, "odd vector grid places center sample at origin")
	_expect(WIND_LAB_SCRIPT.grid_sample_position(origin, 0, 3, 7) == origin + Vector3(0.0, 0.0, -300.0), "grid north samples toward negative Z")
	_expect(WIND_LAB_SCRIPT.grid_sample_position(origin, 3, 6, 7) == origin + Vector3(300.0, 0.0, 0.0), "grid east samples toward positive X")


func _test_gust_spatial_continuity() -> void:
	var field: WindField = WIND_FIELD_SCRIPT.new() as WindField
	field.set_random_seed(74291)
	field.set_mean_wind(8.0, 0.0)
	field.set_gust_parameters(3.0, 18.0, 350.0)
	field.set_test_simulation_time(23.5)
	var first := field.get_wind_at(Vector3.ZERO)
	var neighbor := field.get_wind_at(Vector3(100.0, 0.0, 0.0))
	_expect(first.distance_to(neighbor) < 3.5, "adjacent vector-array samples have spatially continuous gusts")
	field.set_test_simulation_time(23.52)
	var next := field.get_wind_at(Vector3.ZERO)
	_expect(first.distance_to(next) < 0.5, "gust sample changes smoothly at short simulation intervals")
	field.set_mean_wind(0.0, 0.0)
	_expect(field.get_wind_at(Vector3.ZERO) == Vector3.ZERO, "calm array samples display no residual wind")
	field.free()


func _test_graph_window() -> void:
	var graph := WIND_GRAPH_SCRIPT.new() as Control
	graph.window_seconds = 120.0
	graph.append_sample(0.0, 4.0, 8.0)
	graph.append_sample(60.0, 5.0, 8.0)
	graph.append_sample(120.0, 7.0, 8.0)
	graph.append_sample(180.0, 6.0, 8.0)
	var stats: Dictionary = graph.get_statistics()
	_expect(is_equal_approx(float(stats["current"]), 6.0), "speed graph reports current sample")
	_expect(is_equal_approx(float(stats["minimum"]), 5.0), "speed graph trims samples older than 120 simulated seconds")
	_expect(is_equal_approx(float(stats["maximum"]), 7.0), "speed graph reports maximum in visible time window")
	_expect(is_equal_approx(float(stats["mean"]), 8.0), "speed graph retains mean-speed reference value")
	graph.free()


func _test_panel_sizes() -> void:
	var resolutions := [Vector2(1280.0, 720.0), Vector2(1920.0, 1080.0), Vector2(3456.0, 2234.0)]
	for resolution in resolutions:
		var main_size: Vector2 = WIND_PANEL_SCRIPT.panel_size_for_viewport(resolution, false)
		var lab_size: Vector2 = WIND_PANEL_SCRIPT.panel_size_for_viewport(resolution, true)
		_expect(main_size.x <= resolution.x - 36.0 and main_size.y <= resolution.y - 96.0, "main F12 panel fits viewport %s" % resolution)
		_expect(lab_size.x <= resolution.x - 36.0 and lab_size.y <= resolution.y - 36.0, "WindFieldLab panel fits viewport %s" % resolution)


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("WindFieldLab test failed: %s" % description)
