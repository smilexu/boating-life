extends RefCounted
class_name WeatherSimulationAnalysis

## Independent, read-only audit statistics for a standardized forecast and a
## generated timeline. This module does not change WeatherSimulationCore.

const CODEC := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const CORE := preload("res://scripts/weather_data/weather_simulation_core.gd")
const MAX_GAP_SECONDS := 43200.0
const POSSIBLE_PRECIPITATION_PROBABILITY := 0.55

const SERIES_FIELDS := [
	"wind", "gust", "cloud", "temperature", "pressure", "humidity", "direction",
]


static func analyze_forecast(document: Dictionary, start_utc: String, end_utc: String) -> Dictionary:
	var validation := CODEC.validate_standardized_document(document)
	if not bool(validation.get("ok", false)):
		return {"ok": false, "error": "forecast_invalid:%s" % str(validation.get("error", "unknown"))}
	var samples := _prepare_samples(document.get("timeseries", []), false)
	var periods := _collect_precipitation_periods(samples)
	return _analyze_series(samples, periods, start_utc, end_utc, false, document, start_utc, end_utc)


static func precipitation_rate_for_document(document: Dictionary, unix_time: float) -> Variant:
	var samples := _prepare_samples(document.get("timeseries", []), false)
	var info := _precipitation_rate_at(_collect_precipitation_periods(samples), unix_time)
	return float(info["rate_mm_per_hour"]) if bool(info.get("amount_available", false)) else null


static func sample_forecast_at_utc(document: Dictionary, valid_time_utc: String) -> Dictionary:
	var unix_time := CODEC.parse_utc_timestamp_to_unix(valid_time_utc)
	if unix_time < 0:
		return {"ok": false, "error": "sample_time_invalid"}
	var samples := _prepare_samples(document.get("timeseries", []), false)
	var pair: Array = _find_pair(samples, float(unix_time))
	if pair.size() < 2:
		return {"ok": true, "supported": false, "valid_time_utc": valid_time_utc, "fields": {}, "precipitation": {}}
	var left: Dictionary = pair[0]
	var right: Dictionary = pair[1]
	var gap := float(right["_unix_time"]) - float(left["_unix_time"])
	if gap <= 0.0 or gap > MAX_GAP_SECONDS:
		return {"ok": true, "supported": false, "valid_time_utc": valid_time_utc, "fields": {}, "precipitation": {}}
	var fields := {}
	for field in ["air_temperature_c", "relative_humidity_percent", "air_pressure_hpa", "wind_speed_mps", "wind_gust_mps", "wind_from_direction_deg", "cloud_fraction"]:
		var value: Variant = _interpolate_field(left, right, field, float(unix_time))
		if value != null:
			fields[field] = value
	var precipitation := _precipitation_rate_at(_collect_precipitation_periods(samples), float(unix_time))
	var symbol_periods := _collect_weather_symbol_periods(samples)
	var symbol_window := _weather_symbol_at(symbol_periods, float(unix_time))
	return {
		"ok": true,
		"supported": true,
		"valid_time_utc": valid_time_utc,
		"fields": fields,
		"weather_symbol": str(symbol_window.get("symbol_code", "")) if not symbol_window.is_empty() else "N/A",
		"weather_symbol_window": symbol_window,
		"classification_basis": _classification_basis(str(symbol_window.get("symbol_code", "")), precipitation, fields),
		"precipitation": precipitation,
		"provider_id": str(document.get("provider_id", "")),
	}


static func analyze_timeline(
	timeline: Dictionary,
	forecast_document: Dictionary,
	cycle_start: float = 0.0,
	cycle_end: float = -1.0
) -> Dictionary:
	var frames_value: Variant = timeline.get("keyframes", [])
	if not frames_value is Array or frames_value.size() < 2:
		return {"ok": false, "error": "timeline_keyframes_missing"}
	var frames := _prepare_samples(frames_value, true)
	var max_cycle := float((timeline.get("real_day_boundaries_utc", []).size() - 1) * int(timeline.get("cycles_per_real_day", 24)))
	var selected_end := max_cycle if cycle_end < 0.0 else clampf(cycle_end, 0.0, max_cycle)
	var selected_start := clampf(cycle_start, 0.0, selected_end)
	var selected_start_utc := _cycle_offset_to_utc(timeline, selected_start)
	var selected_end_utc := _cycle_offset_to_utc(timeline, selected_end)
	var source_start := str(forecast_document.get("valid_from_utc", selected_start_utc))
	var source_end := str(forecast_document.get("valid_until_utc", selected_end_utc))
	return _analyze_series(frames, [], selected_start_utc, selected_end_utc, true, forecast_document, source_start, source_end)


static func build_quality_report(forecast: Dictionary, timeline: Dictionary, forecast_stats: Dictionary, generated_stats: Dictionary) -> Dictionary:
	var metrics := {}
	var pairs := {
		"mean_wind_speed_mps": "mean_wind_speed_mps",
		"wind_speed_p90_mps": "wind_speed_p90_mps",
		"max_wind_speed_mps": "max_wind_speed_mps",
		"mean_cloud_fraction": "mean_cloud_fraction",
		"precipitation_signal_share": "precipitation_signal_share",
		"explicit_precipitation_time_share_fraction": "explicit_precipitation_time_share_fraction",
		"possible_precipitation_time_share_fraction": "possible_precipitation_time_share_fraction",
		"explicit_precipitation_day_fraction": "explicit_precipitation_day_fraction",
		"possible_precipitation_day_fraction": "possible_precipitation_day_fraction",
		"expected_precipitation_total_mm": "expected_precipitation_total_mm",
	}
	for metric_name in pairs:
		var field_name: String = pairs[metric_name]
		var real_value: Variant = forecast_stats.get("metrics", {}).get(field_name, null)
		var game_value: Variant = generated_stats.get("metrics", {}).get(field_name, null)
		metrics[metric_name] = {
			"forecast": real_value,
			"generated": game_value,
			"difference": float(game_value) - float(real_value) if _is_number(real_value) and _is_number(game_value) else null,
		}
	var forecast_direction: Variant = forecast_stats.get("metrics", {}).get("dominant_wind_from_deg", null)
	var generated_direction: Variant = generated_stats.get("metrics", {}).get("dominant_wind_from_deg", null)
	metrics["dominant_wind_direction"] = {
		"forecast_deg": forecast_direction,
		"generated_deg": generated_direction,
		"shortest_signed_difference_deg": _signed_angle_difference(float(forecast_direction), float(generated_direction)) if _is_number(forecast_direction) and _is_number(generated_direction) else null,
	}
	var background_comparison := {}
	for metric_name in ["explicit_precipitation_time_share_fraction", "possible_precipitation_time_share_fraction", "explicit_precipitation_day_fraction", "possible_precipitation_day_fraction", "mean_precipitation_rate_mm_per_hour", "max_precipitation_rate_mm_per_hour"]:
		var forecast_value: Variant = forecast_stats.get("metrics", {}).get(metric_name, null)
		var generated_value: Variant = generated_stats.get("metrics", {}).get(metric_name, null)
		background_comparison[metric_name] = {
			"forecast": forecast_value,
			"generated": generated_value,
			"difference": float(generated_value) - float(forecast_value) if _is_number(generated_value) and _is_number(forecast_value) else null,
		}
	var forecast_background: Dictionary = forecast_stats.get("metrics", {}).get("weather_background", {})
	var generated_background: Dictionary = generated_stats.get("metrics", {}).get("weather_background", {})
	return {
		"schema_version": 2,
		"report_type": "weather_simulation_quality",
		"region_id": str(timeline.get("region_id", forecast.get("region_id", ""))),
		"calendar_day_utc": str(timeline.get("calendar_day_labels", [""])[0]) if not timeline.get("calendar_day_labels", []).is_empty() else "",
		"timeline_version": str(timeline.get("timeline_version", "")),
		"simulation_seed": int(timeline.get("simulation_seed", 0)),
		"cycles_per_real_day": int(timeline.get("cycles_per_real_day", 0)),
		"source": {
			"provider_id": str(forecast.get("provider_id", "")),
			"data_quality": str(timeline.get("source_data_quality", "unknown")),
			"issued_at_utc": str(forecast.get("forecast_issued_at_utc", "")),
			"valid_from_utc": str(forecast.get("valid_from_utc", "")),
			"valid_until_utc": str(forecast.get("valid_until_utc", "")),
			"sample_count": forecast.get("timeseries", []).size(),
		},
		"comparison": metrics,
		"weather_background_retention": {
			"precipitation_comparison": background_comparison,
			"forecast": forecast_background,
			"generated": generated_background,
			"classification": "time-weighted forecast-window estimates; explicit and possible precipitation are separate; uncovered time is not treated as dry",
		},
		"forecast_statistics": forecast_stats,
		"generated_statistics": generated_stats,
		"quality_diagnostics": {
			"forecast_wind_coverage_fraction": forecast_stats.get("coverage", {}).get("wind", null),
			"generated_wind_coverage_fraction": generated_stats.get("coverage", {}).get("wind", null),
			"forecast_missing_field_fraction": forecast_stats.get("missing_field_fraction", {}),
			"generated_missing_field_fraction": generated_stats.get("missing_field_fraction", {}),
			"storm_category_generated": _contains_storm(generated_stats.get("metrics", {}).get("weather_type_share_percent", {})),
			"unsupported": ["unforecast_extreme_wind_threshold_not_defined"],
		},
		"method_notes": {
			"time_weighting": "piecewise-linear trapezoidal integration on covered intervals; gaps over 12 hours excluded",
			"precipitation_total": "integrates only the shortest active amount window at each instant; overlapping windows are not summed and probability is never converted to rainfall amount",
			"precipitation_duration": "forecast symbols and accumulation windows indicate a time-window estimate, not observed rain duration; resolution is reported separately",
			"p90": "duration-weighted midpoint percentile of covered intervals",
			"extreme_weather": "no climate-based pass threshold is asserted",
		},
	}


static func _analyze_series(
	samples: Array[Dictionary],
	periods: Array[Dictionary],
	start_utc: String,
	end_utc: String,
	is_generated: bool,
	forecast_document: Dictionary,
	source_start_utc: String,
	source_end_utc: String
) -> Dictionary:
	var start_unix := CODEC.parse_utc_timestamp_to_unix(start_utc)
	var end_unix := CODEC.parse_utc_timestamp_to_unix(end_utc)
	var valid_start := CODEC.parse_utc_timestamp_to_unix(source_start_utc)
	var valid_end := CODEC.parse_utc_timestamp_to_unix(source_end_utc)
	if start_unix < 0 or end_unix <= start_unix:
		return {"ok": false, "error": "analysis_time_range_invalid"}
	if valid_start < 0:
		valid_start = start_unix
	if valid_end < 0:
		valid_end = end_unix
	var symbol_periods: Array[Dictionary] = []
	if not is_generated:
		symbol_periods = _collect_weather_symbol_periods(samples)
	if not is_generated:
		for period in periods:
			valid_start = mini(valid_start, int(period["start"]))
			valid_end = maxi(valid_end, int(period["end"]))
		for period in symbol_periods:
			valid_start = mini(valid_start, int(period["start"]))
			valid_end = maxi(valid_end, int(period["end"]))
	var edges: Array[float] = [float(start_unix), float(end_unix)]
	for sample in samples:
		var at := float(sample["_unix_time"])
		if at > start_unix and at < end_unix:
			edges.append(at)
		if is_generated:
			for timestamp_field in ["precipitation_window_start_utc", "precipitation_window_end_utc", "weather_symbol_window_start_utc", "weather_symbol_window_end_utc"]:
				var timestamp := CODEC.parse_utc_timestamp_to_unix(str(sample.get(timestamp_field, "")))
				if timestamp > start_unix and timestamp < end_unix:
					edges.append(float(timestamp))
	if is_generated:
		for index in range(samples.size() - 1):
			var a := float(samples[index]["_unix_time"])
			var b := float(samples[index + 1]["_unix_time"])
			if b > start_unix and a < end_unix:
				edges.append((a + b) * 0.5)
	if not is_generated:
		for period in periods:
			for edge in [float(period["start"]), float(period["end"])]:
				if edge > start_unix and edge < end_unix:
					edges.append(edge)
		for period in symbol_periods:
			for edge in [float(period["start"]), float(period["end"])]:
				if edge > start_unix and edge < end_unix:
					edges.append(edge)
	if valid_start > start_unix and valid_start < end_unix:
		edges.append(float(valid_start))
	if valid_end > start_unix and valid_end < end_unix:
		edges.append(float(valid_end))
	edges.sort()
	var unique_edges: Array[float] = []
	for edge in edges:
		if unique_edges.is_empty() or absf(edge - unique_edges.back()) > 0.001:
			unique_edges.append(edge)
	var integrals := {}
	var coverage_hours := {}
	for field in SERIES_FIELDS:
		integrals[field] = 0.0
		coverage_hours[field] = 0.0
	var weighted_winds: Array[Dictionary] = []
	var weighted_clouds: Array[Dictionary] = []
	var category_hours := {}
	var sky_state_hours := {}
	var precipitation_state_hours := {}
	var precipitation_type_hours := {}
	var precip_total := 0.0
	var precip_coverage_hours := 0.0
	var precip_signal_hours := 0.0
	var precip_possible_hours := 0.0
	var precip_evidence_hours := 0.0
	var precip_window_coverage_hours := 0.0
	var precipitation_resolution_weighted_hours := 0.0
	var precipitation_resolution_weighted_sum := 0.0
	var minimum_precipitation_resolution := INF
	var maximum_precipitation_resolution := 0.0
	var mean_precipitation_rate_integral := 0.0
	var maximum_precipitation_rate := -INF
	var direction_north := 0.0
	var direction_east := 0.0
	var max_wind := -INF
	var max_gust := -INF
	var min_temp := INF
	var max_temp := -INF
	var min_pressure := INF
	var max_pressure := -INF
	var max_wind_rate := 0.0
	var max_direction_rate := 0.0
	var switches := 0
	var previous_category := ""
	var previous_segment_end := -INF
	var current_rain_run := 0.0
	var longest_rain_run := 0.0
	var current_possible_run := 0.0
	var longest_possible_run := 0.0
	var current_clear_run := 0.0
	var longest_clear_run := 0.0
	var covered_hours := 0.0
	var weather_evidence_hours := 0.0
	var sky_coverage_hours := 0.0
	var supported_segments := 0
	for index in range(unique_edges.size() - 1):
		var left_t := unique_edges[index]
		var right_t := unique_edges[index + 1]
		if right_t <= left_t:
			continue
		var mid_t := (left_t + right_t) * 0.5
		if mid_t < valid_start or mid_t > valid_end:
			previous_category = ""
			current_rain_run = 0.0
			current_clear_run = 0.0
			continue
		var hours := (right_t - left_t) / 3600.0
		if hours <= 0.0:
			continue
		var sample_pair: Array = _find_pair(samples, mid_t)
		var has_continuous_pair := false
		var segment_values := {}
		var left_sample: Dictionary = {}
		var right_sample: Dictionary = {}
		if sample_pair.size() >= 2:
			left_sample = sample_pair[0]
			right_sample = sample_pair[1]
			var sample_gap := float(right_sample["_unix_time"]) - float(left_sample["_unix_time"])
			has_continuous_pair = sample_gap > 0.0 and sample_gap <= MAX_GAP_SECONDS
		if has_continuous_pair:
			supported_segments += 1
			covered_hours += hours
			for field in SERIES_FIELDS:
				var core_field := _core_field(field, is_generated)
				var left_value: Variant = _interpolate_field(left_sample, right_sample, core_field, left_t)
				var right_value: Variant = _interpolate_field(left_sample, right_sample, core_field, right_t)
				if left_value == null or right_value == null:
					continue
				var mid_value := (float(left_value) + float(right_value)) * 0.5
				if field == "direction":
					mid_value = _interpolate_angle(float(left_value), float(right_value), 0.5)
				integrals[field] = float(integrals[field]) + mid_value * hours
				coverage_hours[field] = float(coverage_hours[field]) + hours
				segment_values[field] = {"left": float(left_value), "right": float(right_value), "mid": mid_value}
		if segment_values.has("wind"):
			var wind_entry: Dictionary = segment_values["wind"]
			max_wind = maxf(max_wind, maxf(float(wind_entry["left"]), float(wind_entry["right"])))
			weighted_winds.append({"value": float(wind_entry["mid"]), "weight": hours})
			max_wind_rate = maxf(max_wind_rate, absf(float(wind_entry["right"]) - float(wind_entry["left"])) / hours)
		if segment_values.has("gust"):
			max_gust = maxf(max_gust, maxf(float(segment_values["gust"]["left"]), float(segment_values["gust"]["right"])))
		if segment_values.has("cloud"):
			weighted_clouds.append({"value": float(segment_values["cloud"]["mid"]), "weight": hours})
		if segment_values.has("temperature"):
			min_temp = minf(min_temp, minf(float(segment_values["temperature"]["left"]), float(segment_values["temperature"]["right"])))
			max_temp = maxf(max_temp, maxf(float(segment_values["temperature"]["left"]), float(segment_values["temperature"]["right"])))
		if segment_values.has("pressure"):
			min_pressure = minf(min_pressure, minf(float(segment_values["pressure"]["left"]), float(segment_values["pressure"]["right"])))
			max_pressure = maxf(max_pressure, maxf(float(segment_values["pressure"]["left"]), float(segment_values["pressure"]["right"])))
		if segment_values.has("direction") and segment_values.has("wind"):
			var wind_speed := maxf(0.0, float(segment_values["wind"]["mid"]))
			var radians := deg_to_rad(float(segment_values["direction"]["mid"]))
			direction_north += cos(radians) * wind_speed * hours
			direction_east += sin(radians) * wind_speed * hours
			var dir_delta := absf(_signed_angle_difference(float(segment_values["direction"]["left"]), float(segment_values["direction"]["right"])))
			max_direction_rate = maxf(max_direction_rate, dir_delta / hours)
		var selected_generated: Dictionary = _generated_frame_at(samples, mid_t) if is_generated else {}
		var rate_info: Dictionary = _precipitation_rate_at(periods, mid_t) if not is_generated else _generated_precipitation_rate_for_sample(selected_generated)
		if bool(rate_info.get("amount_available", false)):
			var rate := float(rate_info.get("rate_mm_per_hour", 0.0))
			precip_total += rate * hours
			precip_coverage_hours += hours
			mean_precipitation_rate_integral += rate * hours
			maximum_precipitation_rate = maxf(maximum_precipitation_rate, rate)
		var symbol_info: Dictionary = _generated_symbol_window(selected_generated) if is_generated else _weather_symbol_at(symbol_periods, mid_t)
		var symbol := str(symbol_info.get("symbol_code", ""))
		var category := str(selected_generated.get("weather_type", "Unknown")) if is_generated else _classify_forecast(symbol, segment_values, rate_info)
		if category.is_empty():
			category = "Unknown"
		var sky_category := str(selected_generated.get("weather_type", "Unknown")) if is_generated and str(selected_generated.get("weather_type", "Unknown")) in ["Clear", "PartlyCloudy", "Overcast"] else _classify_sky_state(segment_values, symbol)
		if sky_category in ["Clear", "PartlyCloudy", "Overcast"]:
			sky_state_hours[sky_category] = float(sky_state_hours.get(sky_category, 0.0)) + hours
			sky_coverage_hours += hours
		var precipitation_state := str(selected_generated.get("precipitation_state", "unknown")) if is_generated else _classify_precipitation_state(symbol, rate_info)
		var has_precipitation_evidence := bool(rate_info.get("window_available", false)) or not symbol_info.is_empty() or (is_generated and precipitation_state != "unknown")
		if has_precipitation_evidence:
			precip_window_coverage_hours += hours
			precipitation_state_hours[precipitation_state] = float(precipitation_state_hours.get(precipitation_state, 0.0)) + hours
			precip_evidence_hours += hours
			var resolution := _precipitation_time_resolution(rate_info, symbol_info, symbol)
			if resolution > 0.0:
				minimum_precipitation_resolution = minf(minimum_precipitation_resolution, resolution)
				maximum_precipitation_resolution = maxf(maximum_precipitation_resolution, resolution)
				precipitation_resolution_weighted_sum += resolution * hours
				precipitation_resolution_weighted_hours += hours
		if not is_generated and _is_wet_symbol(symbol):
			var precipitation_type := _symbol_precipitation_type(symbol)
			precipitation_type_hours[precipitation_type] = float(precipitation_type_hours.get(precipitation_type, 0.0)) + hours
		elif is_generated and str(selected_generated.get("precipitation_type", "unknown")) != "unknown":
			var precipitation_type := str(selected_generated["precipitation_type"])
			precipitation_type_hours[precipitation_type] = float(precipitation_type_hours.get(precipitation_type, 0.0)) + hours
		var is_explicit_precipitation := precipitation_state == "explicit"
		if category != "Unknown":
			category_hours[category] = float(category_hours.get(category, 0.0)) + hours
			weather_evidence_hours += hours
		if is_explicit_precipitation:
			precip_signal_hours += hours
		elif precipitation_state == "possible":
			precip_possible_hours += hours
		if not previous_category.is_empty() and previous_category != category and previous_category != "Unknown" and category != "Unknown" and absf(left_t - previous_segment_end) < 0.01:
			switches += 1
		previous_category = category if category != "Unknown" else ""
		previous_segment_end = right_t if category != "Unknown" else -INF
		if is_explicit_precipitation:
			current_rain_run += hours
		else:
			longest_rain_run = maxf(longest_rain_run, current_rain_run)
			current_rain_run = 0.0
		if precipitation_state == "possible":
			current_possible_run += hours
		else:
			longest_possible_run = maxf(longest_possible_run, current_possible_run)
			current_possible_run = 0.0
		if category == "Clear":
			current_clear_run += hours
		else:
			longest_clear_run = maxf(longest_clear_run, current_clear_run)
			current_clear_run = 0.0
	longest_rain_run = maxf(longest_rain_run, current_rain_run)
	longest_possible_run = maxf(longest_possible_run, current_possible_run)
	longest_clear_run = maxf(longest_clear_run, current_clear_run)
	var full_hours := float(end_unix - start_unix) / 3600.0
	var explicit_share: Variant = precip_signal_hours / precip_evidence_hours if precip_evidence_hours > 0.0 else null
	var possible_share: Variant = precip_possible_hours / precip_evidence_hours if precip_evidence_hours > 0.0 else null
	var metrics := {
		"mean_wind_speed_mps": _mean(integrals, coverage_hours, "wind"),
		"wind_speed_p90_mps": _weighted_percentile(weighted_winds, 0.90),
		"max_wind_speed_mps": max_wind if is_finite(max_wind) else null,
		"max_forecast_gust_mps": max_gust if is_finite(max_gust) else null,
		"dominant_wind_from_deg": fposmod(rad_to_deg(atan2(direction_east, direction_north)), 360.0) if Vector2(direction_east, direction_north).length() > 0.000001 else null,
		"mean_cloud_fraction": _mean(integrals, coverage_hours, "cloud"),
		"precipitation_signal_share": explicit_share,
		"explicit_precipitation_time_share_fraction": explicit_share,
		"explicit_precipitation_day_fraction": precip_signal_hours / full_hours if full_hours > 0.0 else null,
		"possible_precipitation_time_share_fraction": possible_share,
		"possible_precipitation_day_fraction": precip_possible_hours / full_hours if full_hours > 0.0 else null,
		"precipitation_evidence_coverage_fraction": precip_evidence_hours / full_hours if full_hours > 0.0 else 0.0,
		"precipitation_window_coverage_fraction": precip_window_coverage_hours / full_hours if full_hours > 0.0 else 0.0,
		"expected_precipitation_total_mm": precip_total if precip_coverage_hours > 0.0 else null,
		"precipitation_amount_coverage_fraction": precip_coverage_hours / full_hours if full_hours > 0.0 else 0.0,
		"mean_precipitation_rate_mm_per_hour": mean_precipitation_rate_integral / precip_coverage_hours if precip_coverage_hours > 0.0 else null,
		"max_precipitation_rate_mm_per_hour": maximum_precipitation_rate if is_finite(maximum_precipitation_rate) else null,
		"explicit_precipitation_hours": precip_signal_hours,
		"possible_precipitation_hours": precip_possible_hours,
		"precipitation_time_resolution_mean_hours": precipitation_resolution_weighted_sum / precipitation_resolution_weighted_hours if precipitation_resolution_weighted_hours > 0.0 else null,
		"precipitation_time_resolution_min_hours": minimum_precipitation_resolution if is_finite(minimum_precipitation_resolution) else null,
		"precipitation_time_resolution_max_hours": maximum_precipitation_resolution if maximum_precipitation_resolution > 0.0 else null,
		"temperature_min_c": min_temp if is_finite(min_temp) else null,
		"temperature_max_c": max_temp if is_finite(max_temp) else null,
		"pressure_min_hpa": min_pressure if is_finite(min_pressure) else null,
		"pressure_max_hpa": max_pressure if is_finite(max_pressure) else null,
		"state_transition_count": switches,
		"max_continuous_precipitation_signal_hours": longest_rain_run,
		"max_continuous_possible_precipitation_hours": longest_possible_run,
		"max_continuous_clear_hours": longest_clear_run,
		"max_wind_speed_change_mps_per_hour": max_wind_rate,
		"max_wind_direction_change_deg_per_hour": max_direction_rate,
		"weather_type_share_percent": {},
		"sky_condition_time_share_percent": {},
		"precipitation_state_time_share_percent": {},
		"precipitation_type_time_share_percent": {},
		"weather_background_coverage_fraction": weather_evidence_hours / full_hours if full_hours > 0.0 else 0.0,
		"weather_background_coverage_status": _coverage_status(weather_evidence_hours, full_hours),
		"sky_condition_coverage_fraction": sky_coverage_hours / full_hours if full_hours > 0.0 else 0.0,
		"precipitation_evidence_coverage_status": _coverage_status(precip_evidence_hours, full_hours),
	}
	for field in SERIES_FIELDS:
		var coverage := float(coverage_hours[field]) / full_hours if full_hours > 0.0 else 0.0
		if field == "wind": metrics["mean_wind_speed_coverage_fraction"] = coverage
		if field == "cloud": metrics["mean_cloud_coverage_fraction"] = coverage
	for category in category_hours:
		metrics["weather_type_share_percent"][category] = float(category_hours[category]) / weather_evidence_hours * 100.0 if weather_evidence_hours > 0.0 else 0.0
	for state in sky_state_hours:
		metrics["sky_condition_time_share_percent"][state] = float(sky_state_hours[state]) / sky_coverage_hours * 100.0 if sky_coverage_hours > 0.0 else 0.0
	for state in precipitation_state_hours:
		metrics["precipitation_state_time_share_percent"][state] = float(precipitation_state_hours[state]) / precip_evidence_hours * 100.0 if precip_evidence_hours > 0.0 else 0.0
	for precipitation_type in precipitation_type_hours:
		metrics["precipitation_type_time_share_percent"][precipitation_type] = float(precipitation_type_hours[precipitation_type]) / precip_signal_hours * 100.0 if precip_signal_hours > 0.0 else 0.0
	metrics["weather_background"] = {
		"sky_condition_time_share_percent": metrics["sky_condition_time_share_percent"],
		"precipitation_state_time_share_percent": metrics["precipitation_state_time_share_percent"],
		"explicit_precipitation_time_share_fraction": explicit_share,
		"possible_precipitation_time_share_fraction": possible_share,
		"expected_precipitation_total_mm": metrics["expected_precipitation_total_mm"],
		"mean_precipitation_rate_mm_per_hour": metrics["mean_precipitation_rate_mm_per_hour"],
		"max_precipitation_rate_mm_per_hour": metrics["max_precipitation_rate_mm_per_hour"],
		"max_continuous_precipitation_hours": longest_rain_run,
		"weather_coverage_fraction": metrics["weather_background_coverage_fraction"],
		"precipitation_window_coverage_fraction": metrics["precipitation_window_coverage_fraction"],
		"precipitation_time_resolution_mean_hours": metrics["precipitation_time_resolution_mean_hours"],
	}
	var missing_fraction := _missing_field_fractions(samples, is_generated)
	var coverage := {}
	for field in SERIES_FIELDS:
		coverage[field] = float(coverage_hours[field]) / full_hours if full_hours > 0.0 else 0.0
	var max_gap := _max_gap_hours(samples, start_unix, end_unix)
	return {
		"ok": true,
		"range_utc": {"start": start_utc, "end": end_utc},
		"covered_hours": covered_hours,
		"range_hours": full_hours,
		"sample_or_keyframe_count": samples.size(),
		"supported_segment_count": supported_segments,
		"max_sample_gap_hours": max_gap,
		"coverage": coverage,
		"missing_field_fraction": missing_fraction,
		"metrics": metrics,
	}


static func _prepare_samples(values: Array, is_generated: bool) -> Array[Dictionary]:
	var samples: Array[Dictionary] = []
	for value in values:
		if not value is Dictionary:
			continue
		var sample: Dictionary = value.duplicate(true)
		var timestamp := str(sample.get("valid_time_utc", ""))
		var unix := CODEC.parse_utc_timestamp_to_unix(timestamp)
		if unix < 0:
			continue
		sample["_unix_time"] = float(unix)
		sample["_generated"] = is_generated
		samples.append(sample)
	samples.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["_unix_time"]) < float(b["_unix_time"]))
	return samples


static func _collect_precipitation_periods(samples: Array[Dictionary]) -> Array[Dictionary]:
	var periods_by_key := {}
	for sample in samples:
		for value in sample.get("precipitation_periods", []):
			if not value is Dictionary:
				continue
			var period: Dictionary = value
			var start := CODEC.parse_utc_timestamp_to_unix(str(period.get("period_start_utc", "")))
			var end := CODEC.parse_utc_timestamp_to_unix(str(period.get("period_end_utc", "")))
			if start < 0 or end <= start:
				continue
			var key := "%d:%d" % [start, end]
			if not periods_by_key.has(key):
				var copy := period.duplicate(true)
				copy["start"] = float(start)
				copy["end"] = float(end)
				copy["hours"] = float(end - start) / 3600.0
				periods_by_key[key] = copy
	var result: Array[Dictionary] = []
	for value in periods_by_key.values():
		result.append(value)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a["start"]) == float(b["start"]):
			return float(a["hours"]) < float(b["hours"])
		return float(a["start"]) < float(b["start"])
	)
	return result


static func _find_pair(samples: Array[Dictionary], unix_time: float) -> Array:
	var previous: Dictionary = {}
	for index in range(samples.size()):
		var sample: Dictionary = samples[index]
		var at := float(sample["_unix_time"])
		if absf(at - unix_time) < 0.001:
			var exact_next_index := index + 1
			if exact_next_index < samples.size():
				return [sample, samples[exact_next_index]]
			if not previous.is_empty():
				return [previous, sample]
			return []
		if at < unix_time:
			previous = sample
		elif at > unix_time:
			return [previous, sample] if not previous.is_empty() else []
	return []


static func _interpolate_field(a: Dictionary, b: Dictionary, field: String, unix_time: float) -> Variant:
	if field == "gust_target_strength":
		if not a.has("gust_target") or not b.has("gust_target"):
			return null
		var strength_a := float(a["gust_target"].get("gust_strength_mps", 0.0))
		var strength_b := float(b["gust_target"].get("gust_strength_mps", 0.0))
		var gust_duration := float(b["_unix_time"]) - float(a["_unix_time"])
		if gust_duration <= 0.0:
			return null
		return lerpf(strength_a, strength_b, clampf((unix_time - float(a["_unix_time"])) / gust_duration, 0.0, 1.0))
	if not a.has(field) or not b.has(field):
		return null
	var duration := float(b["_unix_time"]) - float(a["_unix_time"])
	if duration <= 0.0:
		return null
	var weight := clampf((unix_time - float(a["_unix_time"])) / duration, 0.0, 1.0)
	if field == "wind_from_direction_deg":
		return _interpolate_angle(float(a[field]), float(b[field]), weight)
	return lerpf(float(a[field]), float(b[field]), weight)


static func _core_field(field: String, is_generated: bool) -> String:
	match field:
		"wind": return "mean_wind_speed_mps" if is_generated else "wind_speed_mps"
		"gust": return "gust_target_strength" if is_generated else "wind_gust_mps"
		"cloud": return "cloud_fraction"
		"temperature": return "air_temperature_c"
		"pressure": return "air_pressure_hpa"
		"humidity": return "relative_humidity_percent"
		"direction": return "wind_from_direction_deg"
	return ""


static func _generated_precipitation_rate_for_sample(sample: Dictionary) -> Dictionary:
	if sample.is_empty():
		return {"amount_available": false, "window_available": false}
	var has_amount := sample.has("precipitation_intensity_mm_per_hour")
	var has_window := sample.has("precipitation_window_start_utc") or sample.has("precipitation_probability_window_start_utc")
	if not has_amount and not has_window and not sample.has("precipitation_probability"):
		return {"amount_available": false, "window_available": false}
	return {
		"amount_available": has_amount,
		"window_available": has_window,
		"rate_mm_per_hour": float(sample.get("precipitation_intensity_mm_per_hour", 0.0)),
		"window_hours": float(sample.get("precipitation_amount_window_hours", sample.get("precipitation_window_hours", sample.get("precipitation_probability_window_hours", 0.0)))),
		"amount_window_hours": float(sample.get("precipitation_amount_window_hours", sample.get("precipitation_window_hours", 0.0))),
		"probability_window_hours": float(sample.get("precipitation_probability_window_hours", sample.get("precipitation_window_hours", 0.0))),
		"probability": sample.get("precipitation_probability", null),
		"period_start_utc": str(sample.get("precipitation_window_start_utc", "")),
		"period_end_utc": str(sample.get("precipitation_window_end_utc", "")),
	}


static func _precipitation_rate_at(periods: Array[Dictionary], unix_time: float) -> Dictionary:
	var amount_period: Dictionary = {}
	var probability_period: Dictionary = {}
	var amount_start := -INF
	var probability_start := -INF
	for period in periods:
		if unix_time < float(period["start"]) or unix_time >= float(period["end"]):
			continue
		if period.has("precipitation_amount_mm") and (amount_period.is_empty() or float(period["hours"]) < float(amount_period["hours"]) or (float(period["hours"]) == float(amount_period["hours"]) and float(period["start"]) > amount_start)):
			amount_period = period
			amount_start = float(period["start"])
		if period.has("precipitation_probability") and (probability_period.is_empty() or float(period["hours"]) < float(probability_period["hours"]) or (float(period["hours"]) == float(probability_period["hours"]) and float(period["start"]) > probability_start)):
			probability_period = period
			probability_start = float(period["start"])
	if amount_period.is_empty() and probability_period.is_empty():
		return {"amount_available": false, "window_available": false}
	var selected_window: Dictionary = amount_period if not amount_period.is_empty() else probability_period
	var selected_hours := float(selected_window["hours"])
	var result := {
		"amount_available": not amount_period.is_empty(),
		"window_available": true,
		"window_hours": selected_hours,
		"amount_window_hours": float(amount_period.get("hours", 0.0)),
		"probability_window_hours": float(probability_period.get("hours", 0.0)),
		"period_start_utc": str(selected_window.get("period_start_utc", "")),
		"period_end_utc": str(selected_window.get("period_end_utc", "")),
		"source_period_key": str(selected_window.get("source_period_key", "")),
		"precipitation_amount_mm": amount_period.get("precipitation_amount_mm", null),
		"probability": probability_period.get("precipitation_probability", null),
	}
	if not amount_period.is_empty():
		result["amount_period_start_utc"] = str(amount_period.get("period_start_utc", ""))
		result["amount_period_end_utc"] = str(amount_period.get("period_end_utc", ""))
		result["amount_source_period_key"] = str(amount_period.get("source_period_key", ""))
		result["rate_mm_per_hour"] = float(amount_period["precipitation_amount_mm"]) / float(amount_period["hours"])
	if not probability_period.is_empty():
		result["probability_period_start_utc"] = str(probability_period.get("period_start_utc", ""))
		result["probability_period_end_utc"] = str(probability_period.get("period_end_utc", ""))
		result["probability_source_period_key"] = str(probability_period.get("source_period_key", ""))
	return result


static func _generated_frame_at(samples: Array[Dictionary], unix_time: float) -> Dictionary:
	var selected: Dictionary = {}
	for sample in samples:
		if float(sample["_unix_time"]) <= unix_time:
			selected = sample
		else:
			break
	return selected if not selected.is_empty() else (samples[0] if not samples.is_empty() else {})


static func _generated_symbol_window(sample: Dictionary) -> Dictionary:
	if sample.is_empty() or not sample.has("weather_symbol") or not sample.has("weather_symbol_window_start_utc"):
		return {}
	return {
		"symbol_code": str(sample.get("weather_symbol", "")),
		"period_start_utc": str(sample.get("weather_symbol_window_start_utc", "")),
		"period_end_utc": str(sample.get("weather_symbol_window_end_utc", "")),
		"duration_hours": int(sample.get("weather_symbol_window_hours", 0)),
		"hours": float(sample.get("weather_symbol_window_hours", 0.0)),
		"source_period_key": str(sample.get("weather_symbol_source_period_key", "")),
	}


static func _collect_weather_symbol_periods(samples: Array[Dictionary]) -> Array[Dictionary]:
	var unique: Dictionary = {}
	for sample in samples:
		for value in sample.get("weather_symbol_periods", []):
			if not value is Dictionary:
				continue
			var period: Dictionary = value
			var start := CODEC.parse_utc_timestamp_to_unix(str(period.get("period_start_utc", "")))
			var end := CODEC.parse_utc_timestamp_to_unix(str(period.get("period_end_utc", "")))
			if start < 0 or end <= start:
				continue
			var key := "%d:%d:%s" % [start, end, str(period.get("symbol_code", ""))]
			if not unique.has(key):
				var copy := period.duplicate(true)
				copy["start"] = float(start)
				copy["end"] = float(end)
				copy["hours"] = float(end - start) / 3600.0
				unique[key] = copy
	var result: Array[Dictionary] = []
	for period in unique.values():
		result.append(period)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a["start"]) == float(b["start"]):
			return float(a["hours"]) < float(b["hours"])
		return float(a["start"]) < float(b["start"])
	)
	return result


static func _weather_symbol_at(periods: Array[Dictionary], unix_time: float) -> Dictionary:
	var selected: Dictionary = {}
	var selected_start := -INF
	for period in periods:
		if unix_time < float(period["start"]) or unix_time >= float(period["end"]):
			continue
		if selected.is_empty() or float(period["hours"]) < float(selected["hours"]) or (float(period["hours"]) == float(selected["hours"]) and float(period["start"]) > selected_start):
			selected = period
			selected_start = float(period["start"])
	return selected


static func _classify_forecast(symbol_value: Variant, values: Dictionary, precipitation: Dictionary) -> String:
	var symbol := str(symbol_value).to_lower()
	var precip_state := _classify_precipitation_state(symbol, precipitation)
	if symbol.contains("thunder") and precip_state == "explicit":
		return "ThunderstormForecast"
	if precip_state == "explicit":
		return "Precipitation"
	if precip_state == "possible":
		return "PrecipitationPossible"
	var cloud_value: Variant = values.get("cloud", null)
	var cloud: Variant = cloud_value.get("mid", null) if cloud_value is Dictionary else cloud_value
	return _classify_sky_state(values, symbol, cloud)


static func _classify_sky_state(values: Dictionary, symbol_value: String, cloud_override: Variant = null) -> String:
	var cloud_value: Variant = cloud_override
	if cloud_value == null:
		cloud_value = values.get("cloud", null)
	var cloud: Variant = cloud_value.get("mid", null) if cloud_value is Dictionary else cloud_value
	if _is_number(cloud):
		if float(cloud) >= 0.72:
			return "Overcast"
		if float(cloud) >= 0.30:
			return "PartlyCloudy"
		return "Clear"
	var symbol := symbol_value.to_lower()
	if _is_wet_symbol(symbol) or symbol.contains("cloudy") or symbol.contains("fog"):
		return "PartlyCloudy" if symbol.contains("partlycloudy") else "Overcast"
	if symbol.contains("clearsky") or symbol.contains("fair"):
		return "Clear"
	return "Unknown"


static func _classify_precipitation_state(symbol_value: String, precipitation: Dictionary) -> String:
	var symbol := symbol_value.to_lower()
	if _is_wet_symbol(symbol):
		return "explicit"
	if bool(precipitation.get("amount_available", false)) and float(precipitation.get("rate_mm_per_hour", 0.0)) > 0.0:
		return "explicit"
	var probability: Variant = precipitation.get("probability", null)
	if bool(precipitation.get("window_available", false)) and _is_number(probability) and float(probability) >= POSSIBLE_PRECIPITATION_PROBABILITY:
		return "possible"
	if bool(precipitation.get("window_available", false)) or not symbol.is_empty():
		return "none"
	return "unknown"


static func _precipitation_time_resolution(precipitation: Dictionary, symbol_period: Dictionary, symbol: String) -> float:
	var resolutions: Array[float] = []
	for key in ["amount_window_hours", "probability_window_hours"]:
		if bool(precipitation.get("window_available", false)) and _is_number(precipitation.get(key, null)) and float(precipitation[key]) > 0.0:
			resolutions.append(float(precipitation[key]))
	if resolutions.is_empty() and bool(precipitation.get("window_available", false)) and _is_number(precipitation.get("window_hours", null)) and float(precipitation["window_hours"]) > 0.0:
		resolutions.append(float(precipitation["window_hours"]))
	if _is_wet_symbol(symbol) and _is_number(symbol_period.get("hours", symbol_period.get("duration_hours", null))):
		resolutions.append(float(symbol_period.get("hours", symbol_period.get("duration_hours", 0.0))))
	if resolutions.is_empty():
		return 0.0
	var selected := resolutions[0]
	for resolution in resolutions:
		selected = minf(selected, resolution)
	return selected


static func _is_wet_symbol(symbol: String) -> bool:
	var normalized := symbol.to_lower()
	return normalized.contains("rain") or normalized.contains("sleet") or normalized.contains("snow") or normalized.contains("thunder")


static func _symbol_precipitation_type(symbol_value: String) -> String:
	var symbol := symbol_value.to_lower()
	if symbol.contains("thunder"):
		if symbol.contains("sleet"): return "thunderstorm_sleet"
		if symbol.contains("snow"): return "thunderstorm_snow"
		if symbol.contains("rain"): return "thunderstorm_rain"
		return "thunderstorm"
	if symbol.contains("sleet"): return "sleet"
	if symbol.contains("snow"): return "snow"
	if symbol.contains("rain"): return "rain"
	return "unknown"


static func _classification_basis(symbol: String, precipitation: Dictionary, fields: Dictionary) -> String:
	if _is_wet_symbol(symbol):
		return "weather_symbol_period"
	if bool(precipitation.get("amount_available", false)) and float(precipitation.get("rate_mm_per_hour", 0.0)) > 0.0:
		return "precipitation_amount_period"
	if bool(precipitation.get("window_available", false)) and _is_number(precipitation.get("probability", null)) and float(precipitation["probability"]) >= POSSIBLE_PRECIPITATION_PROBABILITY:
		return "precipitation_probability_only_possible"
	if fields.has("cloud_fraction"):
		return "instant_cloud_fraction"
	if not symbol.is_empty():
		return "weather_symbol_period"
	return "insufficient_evidence"


static func _coverage_status(covered_hours: float, range_hours: float) -> String:
	if range_hours <= 0.0 or covered_hours <= 0.0:
		return "unavailable"
	if absf(covered_hours - range_hours) <= 0.001:
		return "complete"
	return "partial"


static func _missing_field_fractions(samples: Array[Dictionary], is_generated: bool) -> Dictionary:
	var fields := {
		"wind": _core_field("wind", is_generated),
		"gust": "gust_target" if is_generated else "wind_gust_mps",
		"cloud": "cloud_fraction",
		"temperature": "air_temperature_c",
		"pressure": "air_pressure_hpa",
		"direction": "wind_from_direction_deg",
		"precipitation": "precipitation_intensity_mm_per_hour" if is_generated else "precipitation_periods",
	}
	var result := {}
	for label in fields:
		var missing := 0
		for sample in samples:
			if not sample.has(str(fields[label])):
				missing += 1
		result[label] = float(missing) / float(samples.size()) if not samples.is_empty() else 1.0
	return result


static func _max_gap_hours(samples: Array[Dictionary], start_unix: int, end_unix: int) -> float:
	var maximum := 0.0
	for index in range(samples.size() - 1):
		var a := float(samples[index]["_unix_time"])
		var b := float(samples[index + 1]["_unix_time"])
		if b > start_unix and a < end_unix:
			maximum = maxf(maximum, (b - a) / 3600.0)
	return maximum


static func _mean(integrals: Dictionary, coverage: Dictionary, field: String) -> Variant:
	return float(integrals[field]) / float(coverage[field]) if float(coverage[field]) > 0.0 else null


static func _weighted_percentile(entries: Array[Dictionary], percentile: float) -> Variant:
	if entries.is_empty():
		return null
	var sorted := entries.duplicate(true)
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["value"]) < float(b["value"]))
	var total := 0.0
	for entry in sorted:
		total += float(entry["weight"])
	var target := total * clampf(percentile, 0.0, 1.0)
	var elapsed := 0.0
	for entry in sorted:
		elapsed += float(entry["weight"])
		if elapsed >= target:
			return float(entry["value"])
	return float(sorted.back()["value"])


static func _cycle_offset_to_utc(timeline: Dictionary, cycle_offset: float) -> String:
	var boundaries: Array = timeline.get("real_day_boundaries_utc", [])
	var cycles_per_day := int(timeline.get("cycles_per_real_day", 24))
	if boundaries.size() < 2:
		return ""
	var total_cycles := float((boundaries.size() - 1) * cycles_per_day)
	var offset := clampf(cycle_offset, 0.0, total_cycles)
	if offset >= total_cycles:
		return str(boundaries.back())
	var day_index := mini(boundaries.size() - 2, floori(offset / float(cycles_per_day)))
	var within := fposmod(offset, float(cycles_per_day)) / float(cycles_per_day)
	var day_start := float(CODEC.parse_utc_timestamp_to_unix(str(boundaries[day_index])))
	var day_end := float(CODEC.parse_utc_timestamp_to_unix(str(boundaries[day_index + 1])))
	return CODEC._utc_iso_from_unix(int(round(lerpf(day_start, day_end, within))))


static func _signed_angle_difference(a: float, b: float) -> float:
	return fposmod(b - a + 180.0, 360.0) - 180.0


static func _interpolate_angle(a: float, b: float, weight: float) -> float:
	return fposmod(a + _signed_angle_difference(a, b) * weight, 360.0)


static func _is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _contains_storm(shares: Dictionary) -> bool:
	for category in shares.keys():
		if str(category).to_lower().contains("storm"):
			return true
	return false
