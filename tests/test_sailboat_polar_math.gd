extends SceneTree

const POLAR_MATH := preload("res://tests/sailboat_polar_math.gd")

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(is_equal_approx(POLAR_MATH.target_heading_degrees(180.0, 90.0), 90.0), "positive TWA target heading")
	_check(is_equal_approx(POLAR_MATH.target_heading_degrees(180.0, -90.0), 270.0), "negative TWA target heading")
	_check(is_equal_approx(POLAR_MATH.relative_twa_degrees(180.0, 90.0), 90.0), "positive relative TWA")
	_check(is_equal_approx(POLAR_MATH.relative_twa_degrees(180.0, 270.0), -90.0), "negative relative TWA")
	_check(is_equal_approx(POLAR_MATH.relative_twa_degrees(0.0, 180.0), -180.0), "stern wind wraps consistently")
	_check(is_equal_approx(POLAR_MATH.rudder_command_degrees(10.0, 0.0, 1.0, 1.0, 35.0), 10.0), "positive heading error requests starboard rudder")
	_check(is_equal_approx(POLAR_MATH.rudder_command_degrees(-10.0, 0.0, 1.0, 1.0, 35.0), -10.0), "negative heading error requests port rudder")
	_check(is_equal_approx(POLAR_MATH.rudder_command_degrees(0.0, 4.0, 1.0, 2.0, 35.0), -8.0), "yaw-rate term damps overshoot")
	_check(is_equal_approx(POLAR_MATH.rudder_command_degrees(100.0, 0.0, 1.0, 0.0, 35.0), 35.0), "rudder command respects limit")
	_check(is_equal_approx(POLAR_MATH.upwind_vmg_mps(Vector3(0.0, 0.0, -2.0), 0.0), 2.0), "northward motion is upwind VMG for northerly wind")
	_check(is_equal_approx(POLAR_MATH.upwind_vmg_mps(Vector3(0.0, 0.0, 2.0), 0.0), -2.0), "southward motion is negative upwind VMG")
	_check(is_equal_approx(POLAR_MATH.upwind_vmg_mps(Vector3(2.0, 0.0, 0.0), 90.0), 2.0), "eastward motion is upwind VMG for easterly wind")
	if _failures.is_empty():
		print("Sailboat polar math tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[polar math] " + label)
