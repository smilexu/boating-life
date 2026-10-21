extends SceneTree

const WIND_FIELD_SCRIPT := preload("res://scripts/wind_field.gd")

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	_test_zero_wind()
	_test_constant_wind_and_cardinal_bearings()
	_test_determinism_and_same_time_repeatability()
	_test_simulation_step_independence()
	_test_continuity_in_time_and_space()
	_test_extreme_and_large_coordinates()
	if _failures.is_empty():
		print("WindField tests: all 10 requested categories passed (%d checks)." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_zero_wind() -> void:
	var field := _new_field()
	field.set_mean_wind(0.0, 275.0)
	field.gust_strength_mps = 10.0
	field.set_test_simulation_time(456.0)
	_expect(field.get_wind_at(Vector3(120.0, 0.0, -80.0)) == Vector3.ZERO, "zero mean is a true calm test")
	field.free()


func _test_constant_wind_and_cardinal_bearings() -> void:
	var field := _new_field()
	field.set_mean_wind(7.5, 0.0)
	field.gust_strength_mps = 0.0
	field.set_test_simulation_time(100.0)
	var north := field.get_wind_at(Vector3.ZERO)
	_expect(_near(north, Vector3(0.0, 0.0, 7.5)), "wind from north flows south (+Z)")
	_expect(is_equal_approx(north.length(), 7.5), "constant speed is returned in m/s")
	_expect(is_equal_approx(float(field.get_wind_details_at(Vector3.ZERO)["instant_wind_from_degrees"]), 0.0), "north wind is reported using meteorological FROM bearing")
	field.set_mean_wind(7.5, 90.0)
	_expect(_near(field.get_wind_at(Vector3.ZERO), Vector3(-7.5, 0.0, 0.0)), "wind from east flows west (-X)")
	_expect(_near_angle(float(field.get_wind_details_at(Vector3.ZERO)["instant_wind_from_degrees"]), 90.0), "east wind reports east as its meteorological FROM bearing")
	field.set_mean_wind(7.5, 180.0)
	_expect(_near(field.get_wind_at(Vector3.ZERO), Vector3(0.0, 0.0, -7.5)), "wind from south flows north (-Z)")
	_expect(_near_angle(float(field.get_wind_details_at(Vector3.ZERO)["instant_wind_from_degrees"]), 180.0), "south wind reports south as its meteorological FROM bearing")
	field.set_mean_wind(7.5, 270.0)
	_expect(_near(field.get_wind_at(Vector3.ZERO), Vector3(7.5, 0.0, 0.0)), "wind from west flows east (+X)")
	_expect(_near_angle(float(field.get_wind_details_at(Vector3.ZERO)["instant_wind_from_degrees"]), 270.0), "west wind reports west as its meteorological FROM bearing")
	field.free()


func _test_determinism_and_same_time_repeatability() -> void:
	var first := _new_field()
	var second := _new_field()
	first.set_test_simulation_time(12345.678)
	second.set_test_simulation_time(12345.678)
	var position := Vector3(987.25, 12.0, -4321.5)
	var expected := first.get_wind_at(position)
	_expect(_near(first.get_wind_at(position), first.get_wind_at(position), 0.0), "same-time repeated query is identical")
	_expect(_near(expected, second.get_wind_at(position), 0.0), "same seed, position, and time are deterministic")
	second.set_random_seed(first.random_seed + 1)
	_expect(not _near(expected, second.get_wind_at(position), 0.00001), "changing the seed changes the gust sample")
	first.free()
	second.free()


func _test_simulation_step_independence() -> void:
	var field_a := _new_field()
	var field_b := _new_field()
	var position := Vector3(42.0, 0.0, -63.0)
	# Simulate two different frame schedules, then sample the same simulation instant.
	for time_value in [0.0, 0.016, 0.032, 0.048, 73.25]:
		field_a.set_test_simulation_time(float(time_value))
	for time_value in [0.0, 0.033, 0.066, 73.25]:
		field_b.set_test_simulation_time(float(time_value))
	_expect(_near(field_a.get_wind_at(position), field_b.get_wind_at(position), 0.0), "different frame schedules agree at the same simulation time")
	field_a.free()
	field_b.free()


func _test_continuity_in_time_and_space() -> void:
	var field := _new_field()
	field.set_mean_wind(9.0, 205.0)
	field.gust_strength_mps = 5.0
	field.gust_time_scale_seconds = 32.0
	field.gust_space_scale_meters = 1600.0
	field.set_test_simulation_time(55.0)
	var point := Vector3(240.0, 0.0, -650.0)
	var before := field.get_wind_at(point)
	field.set_test_simulation_time(55.02)
	var after_time := field.get_wind_at(point)
	_expect(before.distance_to(after_time) < 0.5, "wind varies continuously over short time steps")
	var neighbor := field.get_wind_at(point + Vector3(1.0, 0.0, 0.0))
	_expect(after_time.distance_to(neighbor) < 0.5, "nearby positions have correlated wind")
	field.set_test_simulation_time(55.04)
	var later := field.get_wind_at(point)
	_expect(before.distance_to(later) > 0.000001, "gust field evolves with simulation time")
	field.free()


func _test_extreme_and_large_coordinates() -> void:
	var field := _new_field()
	field.set_mean_wind(30.0, 333.0)
	field.gust_strength_mps = 15.0
	field.gust_space_scale_meters = 50.0
	field.set_test_simulation_time(9.9e12)
	for position in [Vector3.ZERO, Vector3(1.0e12, 0.0, -1.0e12), Vector3(-1.0e15, 100000.0, 1.0e15)]:
		var wind := field.get_wind_at(position)
		_expect(is_finite(wind.x) and is_finite(wind.y) and is_finite(wind.z), "extreme values and large positions remain finite")
		_expect(wind.length() >= 0.0 and wind.length() <= 45.001, "extreme wind speed remains in a bounded range")
	field.free()


func _new_field() -> WindField:
	var field := WIND_FIELD_SCRIPT.new() as WindField
	field.random_seed = 74291
	field.mean_wind_speed_mps = 6.0
	field.mean_wind_from_degrees = 240.0
	field.gust_strength_mps = 2.0
	field.gust_time_scale_seconds = 24.0
	field.gust_space_scale_meters = 450.0
	field.gust_direction_variation_degrees = 8.0
	field.set_test_simulation_time(0.0)
	return field


func _near(a: Vector3, b: Vector3, epsilon: float = 0.0001) -> bool:
	return a.distance_to(b) <= epsilon


func _near_angle(a: float, b: float, epsilon: float = 0.0001) -> bool:
	var difference := absf(fposmod(a - b + 180.0, 360.0) - 180.0)
	return difference <= epsilon


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("WindField test failed: %s" % description)
