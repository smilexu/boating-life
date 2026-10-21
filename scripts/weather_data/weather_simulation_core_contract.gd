extends RefCounted
class_name WeatherSimulationCoreContract

## Provider-neutral request/response contracts for the future simulation core.
## This file contains validation only; it deliberately generates no weather.

const FORECAST_CODEC := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const REQUEST_SCHEMA_VERSION := 1
const OUTPUT_SCHEMA_VERSION := 1
const TIMELINE_SCHEMA_VERSION := 1
const DAY_CYCLE_SECONDS := 86400.0


static func validate_generation_request(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"ok": false, "error": "request_not_object"}
	if int(value.get("schema_version", -1)) != REQUEST_SCHEMA_VERSION:
		return {"ok": false, "error": "unsupported_request_schema"}
	for field in ["request_id", "region_id", "requested_start_utc", "requested_end_utc"]:
		if str(value.get(field, "")).is_empty():
			return {"ok": false, "error": "request_field_missing:%s" % field}
	for field in ["requested_start_utc", "requested_end_utc"]:
		if not FORECAST_CODEC.is_valid_utc_timestamp(str(value[field])):
			return {"ok": false, "error": "request_timestamp_invalid:%s" % field}
	if int(value.get("simulation_seed", -1)) < 0:
		return {"ok": false, "error": "simulation_seed_invalid"}
	var forecast_validation := FORECAST_CODEC.validate_standardized_document(value.get("forecast_document", null))
	if not bool(forecast_validation.get("ok", false)):
		return {"ok": false, "error": "forecast_invalid:%s" % str(forecast_validation.get("error", "unknown"))}
	if str(value["forecast_document"].get("region_id", "")) != str(value["region_id"]):
		return {"ok": false, "error": "forecast_region_mismatch"}
	return {"ok": true, "data": value}


## W2.2b request contract. All clocks, forecast quality and generation metadata
## are supplied explicitly so the same request is portable to an authority server.
static func validate_timeline_request(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"ok": false, "error": "request_not_object"}
	if int(value.get("schema_version", -1)) != REQUEST_SCHEMA_VERSION:
		return {"ok": false, "error": "unsupported_request_schema"}
	for field in ["request_id", "region_id", "requested_start_utc", "requested_end_utc", "generated_at_utc"]:
		if str(value.get(field, "")).is_empty():
			return {"ok": false, "error": "request_field_missing:%s" % field}
	for field in ["requested_start_utc", "requested_end_utc", "generated_at_utc"]:
		if not FORECAST_CODEC.is_valid_utc_timestamp(str(value[field])):
			return {"ok": false, "error": "request_timestamp_invalid:%s" % field}
	var start_unix := FORECAST_CODEC.parse_utc_timestamp_to_unix(str(value["requested_start_utc"]))
	var end_unix := FORECAST_CODEC.parse_utc_timestamp_to_unix(str(value["requested_end_utc"]))
	if end_unix <= start_unix:
		return {"ok": false, "error": "requested_range_invalid"}
	var boundaries: Variant = value.get("real_day_boundaries_utc", null)
	if boundaries is Array:
		if boundaries.size() < 2 or str(boundaries[0]) != str(value["requested_start_utc"]) or str(boundaries[-1]) != str(value["requested_end_utc"]):
			return {"ok": false, "error": "real_day_boundaries_invalid"}
		var previous_boundary := -9223372036854775807
		for boundary in boundaries:
			if not FORECAST_CODEC.is_valid_utc_timestamp(str(boundary)):
				return {"ok": false, "error": "real_day_boundary_timestamp_invalid"}
			var boundary_unix := FORECAST_CODEC.parse_utc_timestamp_to_unix(str(boundary))
			if boundary_unix <= previous_boundary:
				return {"ok": false, "error": "real_day_boundaries_not_ordered"}
			previous_boundary = boundary_unix
		var labels: Variant = value.get("calendar_day_labels", [])
		if labels is Array and not labels.is_empty() and labels.size() != boundaries.size() - 1:
			return {"ok": false, "error": "calendar_day_labels_invalid"}
	elif (end_unix - start_unix) % 86400 != 0:
		return {"ok": false, "error": "requested_range_must_be_whole_days_or_define_boundaries"}
	var seed := int(value.get("simulation_seed", -1))
	if seed < 0 or seed > 2147483647:
		return {"ok": false, "error": "simulation_seed_invalid"}
	if not int(value.get("cycles_per_real_day", 0)) in [12, 24]:
		return {"ok": false, "error": "cycles_per_real_day_invalid"}
	var quality := str(value.get("forecast_quality", "fresh"))
	if not quality in ["fresh", "stale", "partial", "unavailable"]:
		return {"ok": false, "error": "forecast_quality_invalid"}
	var resolution := int(value.get("resolution_per_cycle", 4))
	if resolution < 1 or resolution > 8:
		return {"ok": false, "error": "resolution_per_cycle_invalid"}
	var anchor: Variant = value.get("simulation_anchor", null)
	if not anchor is Dictionary:
		return {"ok": false, "error": "simulation_anchor_missing"}
	for field in ["day_cycle_index", "cycle_seconds", "authoritative_timestamp_utc", "time_scale", "paused"]:
		if not anchor.has(field):
			return {"ok": false, "error": "simulation_anchor_field_missing:%s" % field}
	if int(anchor["day_cycle_index"]) < 0 or not FORECAST_CODEC.is_finite_number(anchor["cycle_seconds"]):
		return {"ok": false, "error": "simulation_anchor_cycle_invalid"}
	if float(anchor["cycle_seconds"]) < 0.0 or float(anchor["cycle_seconds"]) >= DAY_CYCLE_SECONDS:
		return {"ok": false, "error": "simulation_anchor_cycle_seconds_invalid"}
	if not FORECAST_CODEC.is_valid_utc_timestamp(str(anchor["authoritative_timestamp_utc"])):
		return {"ok": false, "error": "simulation_anchor_timestamp_invalid"}
	if not FORECAST_CODEC.is_finite_number(anchor["time_scale"]) or float(anchor["time_scale"]) <= 0.0:
		return {"ok": false, "error": "simulation_anchor_time_scale_invalid"}
	var documents: Array = []
	var documents_value: Variant = value.get("forecast_documents", null)
	if documents_value is Array:
		documents = documents_value
	elif value.get("forecast_document", null) is Dictionary:
		documents = [value["forecast_document"]]
	if quality != "unavailable" and documents.is_empty():
		return {"ok": false, "error": "forecast_documents_missing"}
	for document in documents:
		var forecast_validation := FORECAST_CODEC.validate_standardized_document(document)
		if not bool(forecast_validation.get("ok", false)):
			return {"ok": false, "error": "forecast_invalid:%s" % str(forecast_validation.get("error", "unknown"))}
		if str(document.get("region_id", "")) != str(value["region_id"]):
			return {"ok": false, "error": "forecast_region_mismatch"}
	return {"ok": true, "data": value}


static func validate_timeline(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"ok": false, "error": "timeline_not_object"}
	if int(value.get("schema_version", -1)) != TIMELINE_SCHEMA_VERSION:
		return {"ok": false, "error": "unsupported_timeline_schema"}
	for field in ["timeline_version", "request_id", "region_id", "real_start_utc", "real_end_utc", "real_day_boundaries_utc", "generated_at_utc", "simulation_seed", "cycles_per_real_day", "simulation_anchor", "simulation_anchor_timeline_cycle_offset", "keyframes"]:
		if not value.has(field):
			return {"ok": false, "error": "timeline_field_missing:%s" % field}
	for field in ["real_start_utc", "real_end_utc", "generated_at_utc"]:
		if not FORECAST_CODEC.is_valid_utc_timestamp(str(value[field])):
			return {"ok": false, "error": "timeline_timestamp_invalid:%s" % field}
	if not int(value["cycles_per_real_day"]) in [12, 24] or int(value["simulation_seed"]) < 0:
		return {"ok": false, "error": "timeline_parameters_invalid"}
	if not value["simulation_anchor"] is Dictionary:
		return {"ok": false, "error": "timeline_simulation_anchor_invalid"}
	var day_boundaries: Variant = value["real_day_boundaries_utc"]
	if not day_boundaries is Array or day_boundaries.size() < 2:
		return {"ok": false, "error": "timeline_day_boundaries_invalid"}
	if str(day_boundaries[0]) != str(value["real_start_utc"]) or str(day_boundaries[-1]) != str(value["real_end_utc"]):
		return {"ok": false, "error": "timeline_day_boundary_range_mismatch"}
	var previous_day_unix := -9223372036854775807
	for boundary in day_boundaries:
		if not FORECAST_CODEC.is_valid_utc_timestamp(str(boundary)):
			return {"ok": false, "error": "timeline_day_boundary_invalid"}
		var boundary_unix := FORECAST_CODEC.parse_utc_timestamp_to_unix(str(boundary))
		if boundary_unix <= previous_day_unix:
			return {"ok": false, "error": "timeline_day_boundaries_not_ordered"}
		previous_day_unix = boundary_unix
	if not FORECAST_CODEC.is_finite_number(value["simulation_anchor_timeline_cycle_offset"]):
		return {"ok": false, "error": "timeline_anchor_mapping_invalid"}
	var frames: Variant = value["keyframes"]
	if not frames is Array or frames.size() < 2:
		return {"ok": false, "error": "timeline_keyframes_invalid"}
	var previous_offset := -INF
	var expected_end_offset := float((day_boundaries.size() - 1) * int(value["cycles_per_real_day"]))
	for frame in frames:
		if not frame is Dictionary or not FORECAST_CODEC.is_finite_number(frame.get("cycle_offset", NAN)):
			return {"ok": false, "error": "timeline_keyframe_invalid"}
		if float(frame["cycle_offset"]) <= previous_offset:
			return {"ok": false, "error": "timeline_keyframes_not_ordered"}
		if not FORECAST_CODEC.is_valid_utc_timestamp(str(frame.get("valid_time_utc", ""))):
			return {"ok": false, "error": "timeline_keyframe_timestamp_invalid"}
		for field in ["air_temperature_c", "relative_humidity_percent", "air_pressure_hpa", "mean_wind_speed_mps", "wind_from_direction_deg", "gust_forecast_mps", "cloud_fraction", "precipitation_intensity_mm_per_hour", "precipitation_probability", "precipitation_amount_mm"]:
			if frame.has(field) and not FORECAST_CODEC.is_finite_number(frame[field]):
				return {"ok": false, "error": "timeline_keyframe_value_invalid:%s" % field}
		if frame.has("mean_wind_speed_mps") and float(frame["mean_wind_speed_mps"]) < 0.0:
			return {"ok": false, "error": "timeline_keyframe_wind_negative"}
		if frame.has("wind_from_direction_deg") and (float(frame["wind_from_direction_deg"]) < 0.0 or float(frame["wind_from_direction_deg"]) >= 360.0):
			return {"ok": false, "error": "timeline_keyframe_direction_invalid"}
		if frame.has("cloud_fraction") and (float(frame["cloud_fraction"]) < 0.0 or float(frame["cloud_fraction"]) > 1.0):
			return {"ok": false, "error": "timeline_keyframe_cloud_invalid"}
		if frame.has("precipitation_probability") and (float(frame["precipitation_probability"]) < 0.0 or float(frame["precipitation_probability"]) > 1.0):
			return {"ok": false, "error": "timeline_keyframe_precipitation_probability_invalid"}
		if frame.has("precipitation_state") and not str(frame["precipitation_state"]) in ["explicit", "possible", "none", "unknown"]:
			return {"ok": false, "error": "timeline_keyframe_precipitation_state_invalid"}
		for resolution_field in ["precipitation_resolution_hours", "precipitation_amount_window_hours", "precipitation_probability_window_hours"]:
			if frame.has(resolution_field) and not int(frame[resolution_field]) in [1, 6, 12]:
				return {"ok": false, "error": "timeline_keyframe_precipitation_resolution_invalid:%s" % resolution_field}
		for timestamp_field in [
			"precipitation_window_start_utc", "precipitation_window_end_utc",
			"precipitation_amount_window_start_utc", "precipitation_amount_window_end_utc",
			"precipitation_probability_window_start_utc", "precipitation_probability_window_end_utc",
			"weather_symbol_window_start_utc", "weather_symbol_window_end_utc",
		]:
			if frame.has(timestamp_field) and not FORECAST_CODEC.is_valid_utc_timestamp(str(frame[timestamp_field])):
				return {"ok": false, "error": "timeline_keyframe_window_timestamp_invalid:%s" % timestamp_field}
		previous_offset = float(frame["cycle_offset"])
	if absf(float(frames[0]["cycle_offset"])) > 0.000001 or absf(float(frames.back()["cycle_offset"]) - expected_end_offset) > 0.000001:
		return {"ok": false, "error": "timeline_keyframe_range_invalid"}
	return {"ok": true, "data": value}


static func validate_simulation_output(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"ok": false, "error": "output_not_object"}
	if int(value.get("schema_version", -1)) != OUTPUT_SCHEMA_VERSION:
		return {"ok": false, "error": "unsupported_output_schema"}
	for field in ["request_id", "region_id", "generated_at_utc"]:
		if str(value.get(field, "")).is_empty():
			return {"ok": false, "error": "output_field_missing:%s" % field}
	if not FORECAST_CODEC.is_valid_utc_timestamp(str(value["generated_at_utc"])):
		return {"ok": false, "error": "generated_timestamp_invalid"}
	var states: Variant = value.get("weather_states", null)
	if not states is Array or states.is_empty():
		return {"ok": false, "error": "weather_states_missing"}
	for state in states:
		if not state is Dictionary:
			return {"ok": false, "error": "weather_state_invalid"}
		for field in ["valid_from_utc", "valid_until_utc", "visual_weather_id", "wind"]:
			if not state.has(field):
				return {"ok": false, "error": "weather_state_field_missing:%s" % field}
		if not FORECAST_CODEC.is_valid_utc_timestamp(str(state["valid_from_utc"])) or not FORECAST_CODEC.is_valid_utc_timestamp(str(state["valid_until_utc"])):
			return {"ok": false, "error": "weather_state_timestamp_invalid"}
		if not state["wind"] is Dictionary:
			return {"ok": false, "error": "wind_payload_invalid"}
		for wind_field in ["mean_wind_speed_mps", "wind_from_direction_deg", "gust_strength_mps"]:
			if not state["wind"].has(wind_field) or not FORECAST_CODEC.is_finite_number(state["wind"][wind_field]):
				return {"ok": false, "error": "wind_field_invalid:%s" % wind_field}
		if float(state["wind"]["mean_wind_speed_mps"]) < 0.0 or float(state["wind"]["gust_strength_mps"]) < 0.0:
			return {"ok": false, "error": "wind_speed_negative"}
	return {"ok": true, "data": value}
