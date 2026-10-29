extends SceneTree

const MATH := preload("res://scripts/polar_test_math.gd")
const STABILITY := preload("res://scripts/polar_stability_detector.gd")

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(is_equal_approx(MATH.target_heading_degrees(180.0, -90.0), 270.0), "signed port TWA maps to compass target")
	_check(is_equal_approx(MATH.relative_twa_degrees(180.0, 270.0), -90.0), "port TWA sign matches navigation convention")
	_check(MATH.target_course_forward(90.0).is_equal_approx(Vector3.RIGHT), "target course 090 is east in world coordinates")
	_check(is_equal_approx(MATH.target_course_vmg_kn(Vector3(1.0, 0.0, 0.0), 90.0), MATH.KNOTS_PER_MPS), "VMG projects onto actual compass target course")
	_check(is_nan(MATH.relative_leeway_degrees(0.0, 0.0)), "leeway is undefined at very low speed")
	var settings := {
		"maximum_mean_twa_error_degrees": 5.0,
		"maximum_heading_error_degrees": 5.0,
		"maximum_rudder_saturation_fraction": 0.20,
		"no_forward_progress_threshold_mps": 0.10,
		"maximum_speed_standard_deviation_mps": 0.20,
		"maximum_speed_half_window_delta_mps": 0.12,
	}
	var stable_samples: Array[Dictionary] = []
	for index in range(30):
		stable_samples.append(_sample(index, 2.0, 90.0, 0.5, 3.0, 90.0))
	var stable := STABILITY.evaluate(stable_samples, settings, 90.0)
	_check(bool(stable.get("stable", false)), "constant positive-forward physical sample meets stable classification")
	var stable_metrics: Dictionary = stable.get("metrics", {})
	_check(is_equal_approx(float(stable_metrics.get("velocity_world_x_mps", NAN)), 0.5), "world velocity components remain available for wind-axis VMG analysis")
	_check(is_equal_approx(float(stable_metrics.get("hull_resistance_forward_n", NAN)), -110.0), "forward hydrodynamic resistance is averaged from measured force components")
	_check(is_equal_approx(float(stable_metrics.get("maximum_body_calculation_p95_usec", NAN)), 22.0), "body calculation P95 is retained for the sampling window")
	var circular_samples: Array[Dictionary] = []
	for index in range(30):
		var wind_sample := _sample(index, 2.0, 90.0, 0.5, 3.0, 90.0)
		wind_sample["measured_twa_deg"] = 179.0 if index % 2 == 0 else -179.0
		wind_sample["tws_kn"] = 12.0
		wind_sample["aws_kn"] = 8.0
		wind_sample["awa_deg"] = 179.0 if index % 2 == 0 else -179.0
		circular_samples.append(wind_sample)
	var circular_metrics: Dictionary = STABILITY.evaluate(circular_samples, settings, 90.0).get("metrics", {})
	_check(is_equal_approx(float(circular_metrics.get("mean_tws_kn", NAN)), 12.0), "wind-speed mean is captured from the evaluated window")
	_check(absf(absf(float(circular_metrics.get("mean_twa_deg", NAN))) - 180.0) < 0.01, "signed wind-angle mean wraps across 180 degrees")
	var stalled_samples: Array[Dictionary] = []
	for index in range(30):
		stalled_samples.append(_sample(index, 0.02, 20.0, 0.0, 0.0, 20.0))
	var stalled := STABILITY.evaluate(stalled_samples, settings, 20.0)
	_check(bool(stalled.get("no_forward_progress", false)), "held upwind heading with near-zero forward speed is not a valid polar point")
	var failed_samples: Array[Dictionary] = []
	for index in range(30):
		var sample := _sample(index, 1.0, 60.0, 0.0, 35.0, 90.0)
		sample["rudder_limit_deg"] = 35.0
		failed_samples.append(sample)
	var heading_failed := STABILITY.evaluate(failed_samples, settings, 90.0)
	_check(bool(heading_failed.get("heading_failed", false)), "target TWA error/limit marks heading failure")
	_check(not STABILITY.heading_failure_persisted(60.0, 89.9, 30.0), "heading failure must persist through the entire confirmation window")
	_check(STABILITY.heading_failure_persisted(60.0, 90.0, 30.0), "persistent heading failure can be classified after one full confirmation window")
	_check(not STABILITY.heading_failure_persisted(-1.0, 300.0, 30.0), "unstarted heading failure timer does not classify a case")
	if _failures.is_empty():
		print("Polar P1 helper tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _sample(index: int, sog: float, twa: float, vlong: float, rudder: float, target_twa: float) -> Dictionary:
	return {
		"sim_time_s": float(index),
		"sog_mps": sog,
		"velocity_world_x_mps": 0.5,
		"velocity_world_z_mps": 0.0,
		"heading_deg": 90.0,
		"vlong_mps": vlong,
		"heel_deg": 5.0,
		"heading_error_deg": 0.0,
		"twa_error_deg": twa - target_twa,
		"rudder_deg": rudder,
		"rudder_limit_deg": 35.0,
		"yaw_rate_deg_s": 0.0,
		"vmg_kn": 1.0,
		"leeway_deg": 0.0,
		"main_sail_deg": 50.0,
		"headsail_deg": 40.0,
		"main_force_forward_n": 300.0,
		"headsail_force_forward_n": 100.0,
		"hull_resistance_forward_n": -110.0,
		"keel_force_forward_n": -5.0,
		"rudder_force_forward_n": 0.0,
		"total_water_force_forward_n": -115.0,
		"body_calculation_average_usec": 15.0,
		"body_calculation_p95_usec": 22.0,
	}


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[polar p1] " + label)
