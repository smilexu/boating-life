extends RefCounted
## Evaluates sampled real-physics snapshots. Does not modify the vessel.

const MATH := preload("res://scripts/polar_test_math.gd")


static func heading_failure_persisted(start_seconds: float, current_seconds: float, confirmation_seconds: float) -> bool:
	return start_seconds >= 0.0 and current_seconds - start_seconds >= maxf(confirmation_seconds, 0.0)


static func evaluate(samples: Array[Dictionary], settings: Dictionary, target_twa_degrees: float) -> Dictionary:
	if samples.is_empty():
		return {"stable": false, "reason": "no samples", "metrics": {}}
	for sample in samples:
		for key in ["sog_mps", "vlong_mps", "heel_deg", "heading_error_deg", "twa_error_deg", "rudder_deg", "rudder_limit_deg", "yaw_rate_deg_s"]:
			if not is_finite(float(sample.get(key, NAN))):
				return {"stable": false, "reason": "non-finite %s" % key, "metrics": {}}
	var metrics := _metrics(samples, target_twa_degrees)
	var mean_twa_error := float(metrics["mean_abs_twa_error_deg"])
	var mean_heading_error := float(metrics["mean_abs_heading_error_deg"])
	var saturation := float(metrics["rudder_saturation_fraction"])
	if mean_twa_error > float(settings.get("maximum_mean_twa_error_degrees", 5.0)) or mean_heading_error > float(settings.get("maximum_heading_error_degrees", 5.0)) or saturation > float(settings.get("maximum_rudder_saturation_fraction", 0.20)):
		return {"stable": false, "heading_failed": true, "reason": "target TWA could not be held within the configured error/saturation limits", "metrics": metrics}
	if float(metrics["sog_stddev_mps"]) > float(settings.get("maximum_speed_standard_deviation_mps", 0.20)):
		return {"stable": false, "reason": "speed variation exceeds threshold", "metrics": metrics}
	if float(metrics["speed_half_window_delta_mps"]) > float(settings.get("maximum_speed_half_window_delta_mps", 0.12)):
		return {"stable": false, "reason": "speed trend remains above threshold", "metrics": metrics}
	if float(metrics["mean_abs_yaw_rate_deg_s"]) > 4.0:
		return {"stable": false, "reason": "persistent yaw oscillation", "metrics": metrics}
	if float(metrics["mean_vlong_mps"]) <= float(settings.get("no_forward_progress_threshold_mps", 0.10)):
		return {"stable": false, "no_forward_progress": true, "reason": "target heading held but forward progress is below threshold", "metrics": metrics}
	return {"stable": true, "reason": "stability criteria met", "metrics": metrics}


static func _metrics(samples: Array[Dictionary], _target_twa_degrees: float) -> Dictionary:
	var sog_values := PackedFloat64Array()
	var totals := {
		"sog_mps": 0.0, "vlong_mps": 0.0, "vmg_kn": 0.0,
		"velocity_world_x_mps": 0.0, "velocity_world_z_mps": 0.0,
		"tws_kn": 0.0, "aws_kn": 0.0,
		"heel_deg": 0.0, "abs_heading_error_deg": 0.0, "abs_twa_error_deg": 0.0,
		"rudder_deg": 0.0, "rudder_limit_deg": 0.0, "abs_yaw_rate_deg_s": 0.0,
		"leeway_deg": 0.0, "leeway_count": 0.0, "main_sail_deg": 0.0,
		"headsail_deg": 0.0, "main_force_forward_n": 0.0, "headsail_force_forward_n": 0.0,
		"hull_resistance_forward_n": 0.0, "keel_force_forward_n": 0.0,
		"rudder_force_forward_n": 0.0, "total_water_force_forward_n": 0.0,
		"body_calculation_average_usec": 0.0,
	}
	var saturated_count := 0
	var twa_sin_total := 0.0
	var twa_cos_total := 0.0
	var twa_count := 0
	var awa_sin_total := 0.0
	var awa_cos_total := 0.0
	var awa_count := 0
	var tws_count := 0
	var aws_count := 0
	var heading_sin_total := 0.0
	var heading_cos_total := 0.0
	var heading_count := 0
	var maximum_body_p95_usec := -INF
	var body_p95_count := 0
	for sample in samples:
		var sog := float(sample["sog_mps"])
		sog_values.append(sog)
		totals["sog_mps"] += sog
		totals["vlong_mps"] += float(sample["vlong_mps"])
		totals["vmg_kn"] += float(sample.get("vmg_kn", 0.0))
		for field in ["velocity_world_x_mps", "velocity_world_z_mps", "hull_resistance_forward_n", "keel_force_forward_n", "rudder_force_forward_n", "total_water_force_forward_n", "body_calculation_average_usec"]:
			var measured_value := float(sample.get(field, NAN))
			if is_finite(measured_value):
				totals[field] += measured_value
		var heading := float(sample.get("heading_deg", NAN))
		if is_finite(heading):
			var heading_rad := deg_to_rad(heading)
			heading_sin_total += sin(heading_rad)
			heading_cos_total += cos(heading_rad)
			heading_count += 1
		var body_p95_usec := float(sample.get("body_calculation_p95_usec", NAN))
		if is_finite(body_p95_usec):
			maximum_body_p95_usec = maxf(maximum_body_p95_usec, body_p95_usec)
			body_p95_count += 1
		for field in ["tws_kn", "aws_kn"]:
			var wind_value := float(sample.get(field, NAN))
			if is_finite(wind_value):
				totals[field] += wind_value
				if field == "tws_kn":
					tws_count += 1
				else:
					aws_count += 1
		var measured_twa := float(sample.get("measured_twa_deg", NAN))
		if is_finite(measured_twa):
			var measured_twa_rad := deg_to_rad(measured_twa)
			twa_sin_total += sin(measured_twa_rad)
			twa_cos_total += cos(measured_twa_rad)
			twa_count += 1
		var apparent_wind_angle := float(sample.get("awa_deg", NAN))
		if is_finite(apparent_wind_angle):
			var apparent_wind_angle_rad := deg_to_rad(apparent_wind_angle)
			awa_sin_total += sin(apparent_wind_angle_rad)
			awa_cos_total += cos(apparent_wind_angle_rad)
			awa_count += 1
		totals["heel_deg"] += float(sample["heel_deg"])
		totals["abs_heading_error_deg"] += absf(float(sample["heading_error_deg"]))
		totals["abs_twa_error_deg"] += absf(float(sample["twa_error_deg"]))
		totals["rudder_deg"] += float(sample["rudder_deg"])
		totals["rudder_limit_deg"] += float(sample["rudder_limit_deg"])
		totals["abs_yaw_rate_deg_s"] += absf(float(sample["yaw_rate_deg_s"]))
		totals["main_sail_deg"] += float(sample.get("main_sail_deg", 0.0))
		totals["headsail_deg"] += float(sample.get("headsail_deg", 0.0))
		totals["main_force_forward_n"] += float(sample.get("main_force_forward_n", 0.0))
		totals["headsail_force_forward_n"] += float(sample.get("headsail_force_forward_n", 0.0))
		var leeway := float(sample.get("leeway_deg", NAN))
		if is_finite(leeway):
			totals["leeway_deg"] += leeway
			totals["leeway_count"] += 1.0
		if absf(float(sample["rudder_deg"])) >= float(sample["rudder_limit_deg"]) * 0.95:
			saturated_count += 1
	var count := float(samples.size())
	for key in totals:
		totals[key] = totals[key] / count if key not in ["leeway_deg", "leeway_count", "tws_kn", "aws_kn"] else totals[key]
	totals["mean_twa_deg"] = rad_to_deg(atan2(twa_sin_total, twa_cos_total)) if twa_count > 0 else NAN
	totals["mean_tws_kn"] = totals["tws_kn"] / float(tws_count) if tws_count > 0 else NAN
	totals["mean_aws_kn"] = totals["aws_kn"] / float(aws_count) if aws_count > 0 else NAN
	totals["mean_awa_deg"] = rad_to_deg(atan2(awa_sin_total, awa_cos_total)) if awa_count > 0 else NAN
	totals["mean_heading_deg"] = rad_to_deg(atan2(heading_sin_total, heading_cos_total)) if heading_count > 0 else NAN
	totals["maximum_body_calculation_p95_usec"] = maximum_body_p95_usec if body_p95_count > 0 else NAN
	if totals["leeway_count"] > 0.0:
		totals["mean_leeway_deg"] = totals["leeway_deg"] / totals["leeway_count"]
	else:
		totals["mean_leeway_deg"] = NAN
	var mean_sog := float(totals["sog_mps"])
	var variance := 0.0
	for value in sog_values:
		variance += (value - mean_sog) * (value - mean_sog)
	totals["sog_stddev_mps"] = sqrt(variance / count)
	var half_count := maxi(1, int(floor(count / 2.0)))
	var first_half := 0.0
	var second_half := 0.0
	for index in range(half_count):
		first_half += sog_values[index]
		second_half += sog_values[samples.size() - half_count + index]
	totals["speed_half_window_delta_mps"] = absf(second_half / half_count - first_half / half_count)
	totals["rudder_saturation_fraction"] = float(saturated_count) / count
	totals["mean_abs_heading_error_deg"] = float(totals["abs_heading_error_deg"])
	totals["mean_abs_twa_error_deg"] = float(totals["abs_twa_error_deg"])
	totals["mean_abs_yaw_rate_deg_s"] = float(totals["abs_yaw_rate_deg_s"])
	totals["mean_vlong_mps"] = float(totals["vlong_mps"])
	totals["mean_sog_mps"] = float(totals["sog_mps"])
	totals["sample_count"] = samples.size()
	return totals
