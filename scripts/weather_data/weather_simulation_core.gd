extends RefCounted
class_name WeatherSimulationCore

## Deterministic, provider-neutral weather timeline generation.
## This script consumes only serialized dictionaries and has no scene, network,
## filesystem, engine clock, or random-number-generator dependency.

const CODEC := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const CONTRACT := preload("res://scripts/weather_data/weather_simulation_core_contract.gd")

const DAY_SECONDS := 86400.0
const EDGE_HOLD_SECONDS := 10800.0
const MAX_INTERPOLATION_GAP_SECONDS := 43200.0
const DEFAULT_RESOLUTION_PER_CYCLE := 4
const DEFAULT_GUST_EXCESS_FACTOR := 0.5
const DEFAULT_GUST_TIME_SCALE_SECONDS := 18.0
const DEFAULT_GUST_SPACE_SCALE_METERS := 250.0
const NOISE_WIND_SPEED_MPS := 0.35
const NOISE_DIRECTION_DEGREES := 3.0
const NOISE_CLOUD_FRACTION := 0.025
const POSSIBLE_PRECIPITATION_PROBABILITY := 0.55
const SKY_CLEAR_MAX_CLOUD := 0.30
const SKY_PARTLY_MAX_CLOUD := 0.72

const CONTINUOUS_FIELDS := [
	"air_temperature_c", "relative_humidity_percent", "air_pressure_hpa",
	"wind_speed_mps", "cloud_fraction",
]
const TIMELINE_NUMERIC_FIELDS := [
	"air_temperature_c", "relative_humidity_percent", "air_pressure_hpa",
	"mean_wind_speed_mps", "cloud_fraction", "gust_forecast_mps",
]


static func generate_timeline(request: Dictionary) -> Dictionary:
	var validation := CONTRACT.validate_timeline_request(request)
	if not bool(validation.get("ok", false)):
		return validation
	var start_unix := CODEC.parse_utc_timestamp_to_unix(str(request["requested_start_utc"]))
	var end_unix := CODEC.parse_utc_timestamp_to_unix(str(request["requested_end_utc"]))
	var day_boundaries := _request_day_boundaries(request, start_unix, end_unix)
	var cycles_per_day := int(request["cycles_per_real_day"])
	var resolution := int(request.get("resolution_per_cycle", DEFAULT_RESOLUTION_PER_CYCLE))
	var day_count := day_boundaries.size() - 1
	var total_cycles := float(day_count * cycles_per_day)
	var documents := _request_documents(request)
	var samples := _collect_samples(documents)
	var requested_quality := str(request.get("forecast_quality", "fresh"))
	var data_quality := _resolve_data_quality(requested_quality, samples, start_unix, end_unix)
	var seed := int(request["simulation_seed"])
	var anchor: Dictionary = request["simulation_anchor"]
	var anchor_utc_unix := CODEC.parse_utc_timestamp_to_unix(str(anchor["authoritative_timestamp_utc"]))
	if anchor_utc_unix < start_unix or anchor_utc_unix > end_unix:
		return {"ok": false, "error": "simulation_anchor_outside_forecast_range"}
	var anchor_timeline_offset := _unix_time_to_cycle_offset(anchor_utc_unix, day_boundaries, cycles_per_day)
	var cycle_offsets: Array[float] = []
	for frame_index in range(int(round(total_cycles * float(resolution))) + 1):
		var regular_offset := minf(float(frame_index) / float(resolution), total_cycles)
		if frame_index == int(round(total_cycles * float(resolution))):
			regular_offset = total_cycles
		_add_unique_cycle_offset(cycle_offsets, regular_offset)
	for boundary_unix in _collect_weather_window_boundaries(samples, start_unix, end_unix):
		_add_unique_cycle_offset(cycle_offsets, _unix_time_to_cycle_offset(float(boundary_unix), day_boundaries, cycles_per_day))
	cycle_offsets.sort()
	var keyframes: Array[Dictionary] = []
	for offset in cycle_offsets:
		var valid_unix := _cycle_offset_to_unix(offset, day_boundaries, cycles_per_day)
		var frame := _make_weather_frame(samples, valid_unix, offset, seed, data_quality, request)
		var absolute_cycle_position := float(anchor["day_cycle_index"]) + float(anchor["cycle_seconds"]) / DAY_SECONDS + offset - anchor_timeline_offset
		frame["game_day_cycle_index"] = floori(absolute_cycle_position)
		frame["day_cycle_progress"] = fposmod(absolute_cycle_position, 1.0)
		frame["weather_process_time_seconds"] = offset / float(cycles_per_day) * DAY_SECONDS
		frame["real_forecast_day_index"] = _day_index_for_cycle_offset(offset, cycles_per_day, day_count)
		keyframes.append(frame)
	_apply_weather_hysteresis(keyframes)
	anchor = anchor.duplicate(true)
	var anchor_cycle_position := float(anchor["day_cycle_index"]) + float(anchor["cycle_seconds"]) / DAY_SECONDS
	var anchor_scale_matches := absf(float(anchor["time_scale"]) - float(cycles_per_day)) < 0.000001
	var timeline := {
		"schema_version": CONTRACT.TIMELINE_SCHEMA_VERSION,
		"timeline_version": "%s:%d" % [str(request["request_id"]), seed],
		"request_id": str(request["request_id"]),
		"region_id": str(request["region_id"]),
		"provider_id": _provider_id(documents),
		"source_data_quality": data_quality,
		"forecast_issued_at_utc": _latest_issued_at(documents),
		"forecast_retrieved_at_utc": _latest_retrieved_at(documents),
		"forecast_valid_from_utc": _earliest_valid_time(documents),
		"forecast_valid_until_utc": _latest_valid_time(documents),
		"source_metadata": _combined_source_metadata(documents),
		"real_start_utc": str(request["requested_start_utc"]),
		"real_end_utc": str(request["requested_end_utc"]),
		"real_day_boundaries_utc": day_boundaries,
		"calendar_day_labels": _request_day_labels(request, day_boundaries),
		"calendar_boundary_basis": str(request.get("calendar_boundary_basis", "UTC")),
		"generated_at_utc": str(request["generated_at_utc"]),
		"simulation_seed": seed,
		"cycles_per_real_day": cycles_per_day,
		"resolution_per_cycle": resolution,
		"simulation_anchor": anchor,
		"simulation_anchor_cycle_position": anchor_cycle_position,
		"simulation_anchor_timeline_cycle_offset": anchor_timeline_offset,
		"simulation_day_cycle_seconds": DAY_SECONDS,
		"world_time_mapping": {
			"nominally_matches_world_time_scale": anchor_scale_matches,
			"time_scale_at_generation": float(anchor["time_scale"]),
			"cycles_per_real_day": cycles_per_day,
			"valid_while_unpaused_and_time_scale_unchanged": true,
			"calendar_boundary_basis": str(request.get("calendar_boundary_basis", "UTC")),
		},
		"forecast_day_summaries": _build_day_summaries(samples, day_boundaries, _request_day_labels(request, day_boundaries)),
		"keyframes": keyframes,
		"generation_parameters": {
			"gust_excess_factor": float(request.get("gust_excess_factor", DEFAULT_GUST_EXCESS_FACTOR)),
			"gust_time_scale_seconds": float(request.get("gust_time_scale_seconds", DEFAULT_GUST_TIME_SCALE_SECONDS)),
			"gust_space_scale_meters": float(request.get("gust_space_scale_meters", DEFAULT_GUST_SPACE_SCALE_METERS)),
			"deterministic_wind_noise_mps": NOISE_WIND_SPEED_MPS,
			"deterministic_direction_noise_degrees": NOISE_DIRECTION_DEGREES,
			"deterministic_cloud_noise_fraction": NOISE_CLOUD_FRACTION,
		},
		"authority_time_base": {
			"clock": "world_time_day_cycle_index_and_cycle_seconds",
			"authority_session_id": str(anchor.get("authority_session_id", "")),
			"authority_snapshot_sequence": int(anchor.get("authority_snapshot_sequence", 0)),
			"authoritative_timestamp_utc": str(anchor["authoritative_timestamp_utc"]),
			"time_scale_at_generation": float(anchor["time_scale"]),
			"paused_at_generation": bool(anchor["paused"]),
		},
	}
	var timeline_validation := CONTRACT.validate_timeline(timeline)
	if not bool(timeline_validation.get("ok", false)):
		return {"ok": false, "error": "generated_timeline_invalid:%s" % str(timeline_validation.get("error", "unknown"))}
	return {"ok": true, "timeline": timeline}


## Builds the serializable anchor from a WorldTimeManager snapshot. This helper
## reads only the dictionary; the core itself never reaches into the manager.
static func make_simulation_anchor_from_world_time_snapshot(snapshot: Dictionary) -> Dictionary:
	var base: Dictionary = snapshot.get("authority_sync_anchor", snapshot)
	var raw_timestamp: Variant = base.get("authoritative_timestamp_utc", snapshot.get("authoritative_timestamp_utc", ""))
	var timestamp := str(raw_timestamp)
	if not CODEC.is_valid_utc_timestamp(timestamp):
		if (raw_timestamp is int or raw_timestamp is float) and float(raw_timestamp) > 0.0:
			timestamp = CODEC._utc_iso_from_unix(int(raw_timestamp))
		else:
			timestamp = ""
	return {
		"day_cycle_index": int(base.get("day_cycle_index", snapshot.get("day_cycle_index", -1))),
		"cycle_seconds": float(base.get("cycle_seconds", snapshot.get("cycle_seconds", -1.0))),
		"authoritative_timestamp_utc": timestamp,
		"time_scale": float(base.get("time_scale", snapshot.get("time_scale", 0.0))),
		"paused": bool(base.get("paused", snapshot.get("paused", false))),
		"authority_session_id": str(snapshot.get("authority_session_id", base.get("authority_session_id", ""))),
		"authority_snapshot_sequence": int(snapshot.get("authority_snapshot_sequence", base.get("authority_snapshot_sequence", 0))),
	}


## simulation_time can be either {"elapsed_cycles": float} (relative to the
## timeline authority anchor), or a WorldTimeManager-like dictionary containing
## day_cycle_index and cycle_seconds. It is never inferred from a local clock.
static func sample_weather(timeline: Dictionary, simulation_time: Variant) -> Dictionary:
	var validation := CONTRACT.validate_timeline(timeline)
	if not bool(validation.get("ok", false)):
		return {"ok": false, "error": "timeline_invalid:%s" % str(validation.get("error", "unknown"))}
	var elapsed_result := _simulation_elapsed_cycles(timeline, simulation_time)
	if not bool(elapsed_result.get("ok", false)):
		return elapsed_result
	var elapsed_from_authority := float(elapsed_result["elapsed_cycles"])
	var elapsed := float(timeline["simulation_anchor_timeline_cycle_offset"]) + elapsed_from_authority
	var frames: Array = timeline["keyframes"]
	var max_offset := float(frames.back()["cycle_offset"])
	if elapsed < -0.000001 or elapsed > max_offset + 0.000001:
		return {"ok": false, "error": "simulation_time_outside_timeline", "elapsed_cycles": elapsed, "timeline_end_cycles": max_offset}
	elapsed = clampf(elapsed, 0.0, max_offset)
	var lower: Dictionary = frames[0]
	var upper: Dictionary = frames.back()
	for i in range(frames.size()):
		var frame: Dictionary = frames[i]
		if absf(float(frame["cycle_offset"]) - elapsed) <= 0.000001:
			var exact := frame.duplicate(true)
			exact["sampled_cycle_offset"] = elapsed
			exact["elapsed_since_authority_cycles"] = elapsed_from_authority
			var exact_day_index := int(exact.get("real_forecast_day_index", 0))
			var exact_labels: Array = timeline.get("calendar_day_labels", [])
			if exact_day_index >= 0 and exact_day_index < exact_labels.size():
				exact["calendar_day_label"] = str(exact_labels[exact_day_index])
			exact["timeline_version"] = str(timeline["timeline_version"])
			exact["simulation_seed"] = int(timeline["simulation_seed"])
			exact["region_id"] = str(timeline["region_id"])
			return {"ok": true, "state": exact}
		if float(frame["cycle_offset"]) < elapsed:
			lower = frame
		elif float(frame["cycle_offset"]) > elapsed:
			upper = frame
			break
	var lower_offset := float(lower["cycle_offset"])
	var upper_offset := float(upper["cycle_offset"])
	var weight := inverse_lerp(lower_offset, upper_offset, elapsed) if upper_offset > lower_offset else 0.0
	var sampled := _interpolate_weather_frames(lower, upper, weight)
	sampled["sampled_cycle_offset"] = elapsed
	sampled["elapsed_since_authority_cycles"] = elapsed_from_authority
	var sampled_unix := int(round(_cycle_offset_to_unix(elapsed, timeline["real_day_boundaries_utc"], int(timeline["cycles_per_real_day"]))))
	sampled["valid_time_utc"] = CODEC._utc_iso_from_unix(sampled_unix)
	var anchor_position := float(timeline["simulation_anchor_cycle_position"])
	var absolute_position := anchor_position + elapsed_from_authority
	sampled["game_day_cycle_index"] = floori(absolute_position)
	sampled["day_cycle_progress"] = fposmod(absolute_position, 1.0)
	sampled["weather_process_time_seconds"] = elapsed / float(timeline["cycles_per_real_day"]) * DAY_SECONDS
	sampled["real_forecast_day_index"] = _day_index_for_cycle_offset(elapsed, int(timeline["cycles_per_real_day"]), timeline["real_day_boundaries_utc"].size() - 1)
	var sampled_day_index := int(sampled["real_forecast_day_index"])
	var sampled_labels: Array = timeline.get("calendar_day_labels", [])
	if sampled_day_index >= 0 and sampled_day_index < sampled_labels.size():
		sampled["calendar_day_label"] = str(sampled_labels[sampled_day_index])
	sampled["timeline_version"] = str(timeline["timeline_version"])
	sampled["simulation_seed"] = int(timeline["simulation_seed"])
	sampled["region_id"] = str(timeline["region_id"])
	return {"ok": true, "state": sampled}


## MET's forecast gust is a forecast peak, not WindField's additive gust amplitude.
## This first-pass conversion maps half of the forecast excess above mean wind to
## the gust-strength target. The factor is explicit/configurable and uncalibrated.
static func map_forecast_gust_to_windfield_target(mean_wind_mps: Variant, forecast_gust_mps: Variant, excess_factor: float = DEFAULT_GUST_EXCESS_FACTOR) -> Dictionary:
	if not CODEC.is_finite_number(mean_wind_mps) or not CODEC.is_finite_number(forecast_gust_mps):
		return {"available": false, "reason": "mean_or_gust_missing"}
	if float(mean_wind_mps) < 0.0 or float(forecast_gust_mps) < 0.0 or not is_finite(excess_factor) or excess_factor < 0.0:
		return {"available": false, "reason": "input_out_of_range"}
	return {
		"available": true,
		"gust_strength_mps": maxf(0.0, float(forecast_gust_mps) - float(mean_wind_mps)) * excess_factor,
		"mapping": "max(0, forecast_gust_mps - mean_wind_mps) * excess_factor",
		"excess_factor": excess_factor,
		"calibration_status": "uncalibrated_first_pass_assumption",
	}


## Replace forecast data without rewriting experienced weather. Old frames through
## preserve_through_cycle_offset are copied exactly. Future frames blend over a
## configurable interval from the old boundary state toward the newly generated
## forecast. Both timelines must share the same authority anchor and range.
static func update_forecast(old_timeline: Dictionary, new_request: Dictionary, preserve_through_cycle_offset: float, blend_cycles: float = 1.0) -> Dictionary:
	var old_validation := CONTRACT.validate_timeline(old_timeline)
	if not bool(old_validation.get("ok", false)):
		return {"ok": false, "error": "old_timeline_invalid"}
	if blend_cycles <= 0.0 or not is_finite(blend_cycles):
		return {"ok": false, "error": "blend_cycles_invalid"}
	var generated := generate_timeline(new_request)
	if not bool(generated.get("ok", false)):
		return generated
	var updated: Dictionary = generated["timeline"]
	if str(updated["region_id"]) != str(old_timeline["region_id"]) or str(updated["real_start_utc"]) != str(old_timeline["real_start_utc"]):
		return {"ok": false, "error": "timeline_anchor_or_region_mismatch"}
	if JSON.stringify(updated["real_day_boundaries_utc"]) != JSON.stringify(old_timeline["real_day_boundaries_utc"]):
		return {"ok": false, "error": "calendar_boundaries_mismatch"}
	var old_cycle_to_forecast_offset := float(old_timeline["simulation_anchor_timeline_cycle_offset"]) - float(old_timeline["simulation_anchor_cycle_position"])
	var new_cycle_to_forecast_offset := float(updated["simulation_anchor_timeline_cycle_offset"]) - float(updated["simulation_anchor_cycle_position"])
	if int(updated["cycles_per_real_day"]) != int(old_timeline["cycles_per_real_day"]) or absf(old_cycle_to_forecast_offset - new_cycle_to_forecast_offset) > 0.0001:
		return {"ok": false, "error": "simulation_time_mapping_changed"}
	var old_frames: Array = old_timeline["keyframes"]
	var new_frames: Array = updated["keyframes"]
	var old_end := float(old_frames.back()["cycle_offset"])
	var new_end := float(new_frames.back()["cycle_offset"])
	if preserve_through_cycle_offset < 0.0 or preserve_through_cycle_offset >= minf(old_end, new_end):
		return {"ok": false, "error": "preserve_boundary_out_of_range"}
	var boundary_state_result := sample_weather(old_timeline, {"elapsed_cycles": preserve_through_cycle_offset - float(old_timeline["simulation_anchor_timeline_cycle_offset"])})
	if not bool(boundary_state_result.get("ok", false)):
		return boundary_state_result
	var boundary_state: Dictionary = boundary_state_result["state"]
	for metadata_field in ["sampled_cycle_offset", "elapsed_since_authority_cycles", "calendar_day_label", "timeline_version", "simulation_seed", "region_id"]:
		boundary_state.erase(metadata_field)
	boundary_state["cycle_offset"] = preserve_through_cycle_offset
	var merged: Array[Dictionary] = []
	for frame in old_frames:
		if float(frame["cycle_offset"]) < preserve_through_cycle_offset - 0.000001:
			merged.append((frame as Dictionary).duplicate(true))
	if merged.is_empty() or absf(float(merged.back()["cycle_offset"]) - preserve_through_cycle_offset) > 0.000001:
		merged.append(boundary_state.duplicate(true))
	for frame_value in new_frames:
		var frame: Dictionary = frame_value
		var offset := float(frame["cycle_offset"])
		if offset <= preserve_through_cycle_offset + 0.000001:
			continue
		var next_frame := frame.duplicate(true)
		if offset < preserve_through_cycle_offset + blend_cycles:
			var blend_weight := _smoothstep01((offset - preserve_through_cycle_offset) / blend_cycles)
			next_frame = _blend_weather_states(boundary_state, next_frame, blend_weight)
			next_frame["cycle_offset"] = offset
			next_frame["valid_time_utc"] = CODEC._utc_iso_from_unix(int(round(_cycle_offset_to_unix(offset, updated["real_day_boundaries_utc"], int(updated["cycles_per_real_day"])))))
		merged.append(next_frame)
	updated["keyframes"] = merged
	updated["timeline_version"] = "%s:update:%d" % [str(updated["request_id"]), int(updated["simulation_seed"])]
	updated["forecast_update"] = {
		"preserved_through_cycle_offset": preserve_through_cycle_offset,
		"future_blend_cycles": blend_cycles,
		"previous_timeline_version": str(old_timeline["timeline_version"]),
	}
	var final_validation := CONTRACT.validate_timeline(updated)
	if not bool(final_validation.get("ok", false)):
		return {"ok": false, "error": "updated_timeline_invalid:%s" % str(final_validation.get("error", "unknown"))}
	return {"ok": true, "timeline": updated}


static func serialize_timeline(timeline: Dictionary) -> String:
	if not bool(CONTRACT.validate_timeline(timeline).get("ok", false)):
		return ""
	return JSON.stringify(timeline, "", true, true)


static func deserialize_timeline(json_text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(json_text)
	var validation := CONTRACT.validate_timeline(parsed)
	if not bool(validation.get("ok", false)):
		return validation
	return {"ok": true, "timeline": parsed}


static func _request_documents(request: Dictionary) -> Array:
	var value: Variant = request.get("forecast_documents", null)
	if value is Array:
		var upgraded_documents: Array[Dictionary] = []
		for document_value in value:
			var upgraded := CODEC.upgrade_standardized_document(document_value)
			if bool(upgraded.get("ok", false)):
				upgraded_documents.append(upgraded["data"])
		return upgraded_documents
	if request.get("forecast_document", null) is Dictionary:
		var upgraded := CODEC.upgrade_standardized_document(request["forecast_document"])
		return [upgraded["data"]] if bool(upgraded.get("ok", false)) else []
	return []


static func _request_day_boundaries(request: Dictionary, start_unix: int, end_unix: int) -> Array[String]:
	var result: Array[String] = []
	var supplied: Variant = request.get("real_day_boundaries_utc", null)
	if supplied is Array:
		for boundary in supplied:
			result.append(str(boundary))
		return result
	var day_count := int((end_unix - start_unix) / 86400)
	for day in range(day_count + 1):
		result.append(CODEC._utc_iso_from_unix(start_unix + day * 86400))
	return result


static func _request_day_labels(request: Dictionary, boundaries: Array[String]) -> Array[String]:
	var supplied: Variant = request.get("calendar_day_labels", null)
	if supplied is Array and supplied.size() == boundaries.size() - 1:
		var labels: Array[String] = []
		for value in supplied:
			labels.append(str(value))
		return labels
	var result: Array[String] = []
	for index in range(boundaries.size() - 1):
		result.append(CODEC._utc_iso_from_unix(CODEC.parse_utc_timestamp_to_unix(boundaries[index])).substr(0, 10))
	return result


static func _unix_time_to_cycle_offset(unix_time: float, boundaries: Array[String], cycles_per_day: int) -> float:
	var last_index := boundaries.size() - 1
	if unix_time <= float(CODEC.parse_utc_timestamp_to_unix(boundaries[0])):
		return 0.0
	if unix_time >= float(CODEC.parse_utc_timestamp_to_unix(boundaries[last_index])):
		return float(last_index * cycles_per_day)
	for day in range(last_index):
		var day_start := float(CODEC.parse_utc_timestamp_to_unix(boundaries[day]))
		var day_end := float(CODEC.parse_utc_timestamp_to_unix(boundaries[day + 1]))
		if unix_time <= day_end:
			var fraction := clampf((unix_time - day_start) / (day_end - day_start), 0.0, 1.0)
			return float(day * cycles_per_day) + fraction * float(cycles_per_day)
	return float(last_index * cycles_per_day)


static func _cycle_offset_to_unix(cycle_offset: float, boundaries: Array, cycles_per_day: int) -> float:
	var day_count := boundaries.size() - 1
	var total_cycles := float(day_count * cycles_per_day)
	var offset := clampf(cycle_offset, 0.0, total_cycles)
	if offset >= total_cycles:
		return float(CODEC.parse_utc_timestamp_to_unix(str(boundaries.back())))
	var day := mini(day_count - 1, floori(offset / float(cycles_per_day)))
	var fraction := fposmod(offset, float(cycles_per_day)) / float(cycles_per_day)
	var start_unix := float(CODEC.parse_utc_timestamp_to_unix(str(boundaries[day])))
	var end_unix := float(CODEC.parse_utc_timestamp_to_unix(str(boundaries[day + 1])))
	return lerpf(start_unix, end_unix, fraction)


static func _day_index_for_cycle_offset(cycle_offset: float, cycles_per_day: int, day_count: int) -> int:
	if cycle_offset >= float(day_count * cycles_per_day):
		return maxi(0, day_count - 1)
	return clampi(floori(maxf(0.0, cycle_offset) / float(cycles_per_day)), 0, maxi(0, day_count - 1))


static func _collect_samples(documents: Array) -> Array[Dictionary]:
	var by_time: Dictionary = {}
	for document_value in documents:
		if not document_value is Dictionary:
			continue
		for sample_value in document_value.get("timeseries", []):
			if not sample_value is Dictionary:
				continue
			var unix_time := CODEC.parse_utc_timestamp_to_unix(str(sample_value.get("valid_time_utc", "")))
			if unix_time < 0:
				continue
			var key := str(unix_time)
			if not by_time.has(key):
				var copy: Dictionary = sample_value.duplicate(true)
				copy["_unix_time"] = unix_time
				by_time[key] = copy
			else:
				var existing: Dictionary = by_time[key]
				for field in sample_value.keys():
					if not existing.has(field):
						existing[field] = sample_value[field].duplicate(true) if sample_value[field] is Array or sample_value[field] is Dictionary else sample_value[field]
	var result: Array[Dictionary] = []
	for value in by_time.values():
		result.append(value)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a["_unix_time"]) < int(b["_unix_time"]))
	return result


static func _collect_weather_window_boundaries(samples: Array[Dictionary], range_start: int, range_end: int) -> Array[int]:
	var boundaries: Dictionary = {}
	for sample in samples:
		for list_name in ["precipitation_periods", "weather_symbol_periods"]:
			var windows: Variant = sample.get(list_name, [])
			if not windows is Array:
				continue
			for window_value in windows:
				if not window_value is Dictionary:
					continue
				var window: Dictionary = window_value
				for time_field in ["period_start_utc", "period_end_utc"]:
					var unix := CODEC.parse_utc_timestamp_to_unix(str(window.get(time_field, "")))
					if unix >= range_start and unix <= range_end:
						boundaries[unix] = true
	var result: Array[int] = []
	for value in boundaries.keys():
		result.append(int(value))
	result.sort()
	return result


static func _add_unique_cycle_offset(offsets: Array[float], value: float) -> void:
	for existing in offsets:
		if absf(existing - value) < 0.000001:
			return
	offsets.append(value)


static func _make_weather_frame(samples: Array[Dictionary], valid_unix: float, cycle_offset: float, seed: int, quality: String, request: Dictionary) -> Dictionary:
	var forecast := _sample_forecast_at(samples, valid_unix)
	var frame := {
		"cycle_offset": cycle_offset,
		"valid_time_utc": CODEC._utc_iso_from_unix(int(round(valid_unix))),
		"data_quality": quality if bool(forecast.get("has_any_data", false)) else "unavailable",
		"held_fields": forecast.get("held_fields", []),
		"interpolated_fields": forecast.get("interpolated_fields", []),
	}
	if not bool(forecast.get("has_any_data", false)):
		frame["weather_type"] = "Unknown"
		frame["visual_weather_id"] = "Unknown"
		return frame
	var offset_phase := cycle_offset
	var phase_a := _seed_phase(seed, 17)
	var phase_b := _seed_phase(seed, 71)
	var wind_noise := 0.62 * sin(offset_phase * 0.77 + phase_a) + 0.38 * sin(offset_phase * 0.29 + phase_b)
	var cloud_noise := 0.65 * sin(offset_phase * 0.51 + phase_b) + 0.35 * sin(offset_phase * 0.19 + phase_a)
	var values: Dictionary = forecast.get("values", {})
	for field in ["air_temperature_c", "relative_humidity_percent", "air_pressure_hpa"]:
		if values.has(field):
			frame[field] = float(values[field])
	if values.has("wind_speed_mps"):
		frame["mean_wind_speed_mps"] = maxf(0.0, float(values["wind_speed_mps"]) + NOISE_WIND_SPEED_MPS * wind_noise)
	if values.has("wind_from_direction_deg"):
		var direction := float(values["wind_from_direction_deg"])
		var base_speed := float(values.get("wind_speed_mps", 0.0))
		if base_speed >= 0.5:
			direction = fposmod(direction + NOISE_DIRECTION_DEGREES * cloud_noise, 360.0)
		frame["wind_from_direction_deg"] = direction
	if values.has("cloud_fraction"):
		frame["cloud_fraction"] = clampf(float(values["cloud_fraction"]) + NOISE_CLOUD_FRACTION * cloud_noise, 0.0, 1.0)
	if forecast.has("wind_gust_mps"):
		frame["gust_forecast_mps"] = float(forecast["wind_gust_mps"])
		var gust_target := map_forecast_gust_to_windfield_target(
			frame.get("mean_wind_speed_mps", values.get("wind_speed_mps", 0.0)),
			forecast["wind_gust_mps"],
			float(request.get("gust_excess_factor", DEFAULT_GUST_EXCESS_FACTOR))
		)
		frame["gust_target"] = {
			"gust_strength_mps": float(gust_target.get("gust_strength_mps", 0.0)),
			"time_scale_seconds": float(request.get("gust_time_scale_seconds", DEFAULT_GUST_TIME_SCALE_SECONDS)),
			"space_scale_meters": float(request.get("gust_space_scale_meters", DEFAULT_GUST_SPACE_SCALE_METERS)),
			"source": "met_forecast_peak_excess_mapping",
			"mapping_assumption": str(gust_target.get("mapping", "")),
			"calibration_status": str(gust_target.get("calibration_status", "unavailable")),
		}
	if forecast.has("weather_symbol"):
		frame["weather_symbol"] = str(forecast["weather_symbol"])
	if forecast.has("weather_symbol_window"):
		var symbol_window: Dictionary = forecast["weather_symbol_window"]
		frame["weather_symbol"] = str(symbol_window.get("symbol_code", ""))
		frame["weather_symbol_window_start_utc"] = str(symbol_window.get("period_start_utc", ""))
		frame["weather_symbol_window_end_utc"] = str(symbol_window.get("period_end_utc", ""))
		frame["weather_symbol_window_hours"] = int(symbol_window.get("duration_hours", 0))
		frame["weather_symbol_source_period_key"] = str(symbol_window.get("source_period_key", ""))
	if forecast.has("legacy_weather_symbol"):
		frame["legacy_weather_symbol"] = str(forecast["legacy_weather_symbol"])
		frame["legacy_weather_symbol_note"] = "窗口时长未知；仅展示，不参与天气持续时间分类"
	var precipitation: Dictionary = forecast.get("precipitation", {})
	for key in [
		"precipitation_amount_mm", "precipitation_probability", "precipitation_intensity_mm_per_hour",
		"precipitation_window_hours", "precipitation_window_start_utc", "precipitation_window_end_utc", "precipitation_source_period_key", "precipitation_window_id",
		"precipitation_amount_window_hours", "precipitation_amount_window_start_utc", "precipitation_amount_window_end_utc", "precipitation_amount_source_period_key",
		"precipitation_probability_window_hours", "precipitation_probability_window_start_utc", "precipitation_probability_window_end_utc", "precipitation_probability_source_period_key",
	]:
		if precipitation.has(key):
			frame[key] = precipitation[key]
	if precipitation.has("precipitation_amount_mm"):
		frame["precipitation_rate_semantics"] = "uniform_window_mean_estimate"
	if precipitation.has("precipitation_window_hours"):
		frame["precipitation_resolution_hours"] = int(precipitation["precipitation_window_hours"])
	var precipitation_state := _precipitation_state(frame)
	if precipitation_state != "unknown":
		frame["precipitation_state"] = precipitation_state
	frame["precipitation_type"] = _precipitation_type(str(frame.get("weather_symbol", "")))
	frame["thunderstorm_forecast"] = str(frame.get("weather_symbol", "")).to_lower().contains("thunder")
	frame["weather_classification_basis"] = _classification_basis(frame)
	frame["weather_type"] = _classify_weather(frame)
	frame["visual_weather_id"] = _visual_weather_id(frame)
	return frame


static func _sample_forecast_at(samples: Array[Dictionary], unix_time: float) -> Dictionary:
	var located := _locate_samples(samples, unix_time)
	if samples.is_empty():
		return {"has_any_data": false, "values": {}}
	var previous: Dictionary = located.get("previous", {})
	var following: Dictionary = located.get("following", {})
	var exact: Dictionary = located.get("exact", {})
	var values := {}
	var held_fields: Array[String] = []
	var interpolated_fields: Array[String] = []
	for field in CONTINUOUS_FIELDS:
		var result := _interpolate_sample_field(previous, following, exact, field, unix_time)
		if bool(result.get("available", false)):
			values[field] = float(result["value"])
			if bool(result.get("held", false)):
				held_fields.append(field)
			if bool(result.get("interpolated", false)):
				interpolated_fields.append(field)
	var speed: Variant = values.get("wind_speed_mps", null)
	var direction_result := _interpolate_sample_field(previous, following, exact, "wind_from_direction_deg", unix_time)
	if bool(direction_result.get("available", false)):
		var direction := float(direction_result["value"])
		if speed is float or speed is int:
			if float(speed) < 0.5 and previous.has("wind_from_direction_deg"):
				direction = float(previous["wind_from_direction_deg"])
		values["wind_from_direction_deg"] = fposmod(direction, 360.0)
		if bool(direction_result.get("held", false)):
			held_fields.append("wind_from_direction_deg")
		if bool(direction_result.get("interpolated", false)):
			interpolated_fields.append("wind_from_direction_deg")
	var result := {"has_any_data": not values.is_empty(), "values": values, "held_fields": held_fields, "interpolated_fields": interpolated_fields}
	var symbol_window := _weather_symbol_at(samples, unix_time)
	if not symbol_window.is_empty():
		result["weather_symbol_window"] = symbol_window
		result["weather_symbol"] = str(symbol_window.get("symbol_code", ""))
	var legacy_symbol := _legacy_weather_symbol_at(exact)
	if not legacy_symbol.is_empty():
		result["legacy_weather_symbol"] = legacy_symbol
	var gust_result := _interpolate_sample_field(previous, following, exact, "wind_gust_mps", unix_time)
	if bool(gust_result.get("available", false)):
		result["wind_gust_mps"] = float(gust_result["value"])
		if bool(gust_result.get("held", false)):
			held_fields.append("wind_gust_mps")
	var precip := _precipitation_at(samples, unix_time)
	if not precip.is_empty():
		result["precipitation"] = precip
	result["has_any_data"] = bool(result["has_any_data"]) or not symbol_window.is_empty() or not legacy_symbol.is_empty() or not precip.is_empty()
	result["held_fields"] = held_fields
	result["interpolated_fields"] = interpolated_fields
	return result


static func _locate_samples(samples: Array[Dictionary], unix_time: float) -> Dictionary:
	var previous := {}
	var following := {}
	for sample in samples:
		var sample_time := float(sample["_unix_time"])
		if absf(sample_time - unix_time) < 0.5:
			return {"exact": sample, "previous": sample, "following": sample}
		if sample_time < unix_time:
			previous = sample
		elif sample_time > unix_time:
			following = sample
			break
	return {"previous": previous, "following": following, "exact": {}}


static func _interpolate_sample_field(previous: Dictionary, following: Dictionary, exact: Dictionary, field: String, unix_time: float) -> Dictionary:
	if not exact.is_empty() and exact.has(field):
		return {"available": true, "value": float(exact[field]), "held": false, "interpolated": false}
	var has_previous := not previous.is_empty() and previous.has(field)
	var has_following := not following.is_empty() and following.has(field)
	if has_previous and has_following:
		var prev_t := float(previous["_unix_time"])
		var next_t := float(following["_unix_time"])
		var gap := next_t - prev_t
		if gap <= 0.0 or gap > MAX_INTERPOLATION_GAP_SECONDS:
			return {"available": false}
		var weight := clampf((unix_time - prev_t) / gap, 0.0, 1.0)
		var value: float
		if field == "wind_from_direction_deg":
			value = _interpolate_angle_degrees(float(previous[field]), float(following[field]), weight)
		else:
			value = lerpf(float(previous[field]), float(following[field]), weight)
		return {"available": true, "value": value, "held": false, "interpolated": true}
	if has_previous and unix_time - float(previous["_unix_time"]) <= EDGE_HOLD_SECONDS:
		return {"available": true, "value": float(previous[field]), "held": true, "interpolated": false}
	if has_following and float(following["_unix_time"]) - unix_time <= EDGE_HOLD_SECONDS:
		return {"available": true, "value": float(following[field]), "held": true, "interpolated": false}
	return {"available": false}


static func _nearest_sample_with_field(previous: Dictionary, following: Dictionary, exact: Dictionary, field: String, unix_time: float) -> Dictionary:
	if not exact.is_empty() and exact.has(field):
		return exact
	var candidates: Array[Dictionary] = []
	if not previous.is_empty() and previous.has(field):
		candidates.append(previous)
	if not following.is_empty() and following.has(field):
		candidates.append(following)
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return absf(float(a["_unix_time"]) - unix_time) < absf(float(b["_unix_time"]) - unix_time)
	)
	if absf(float(candidates[0]["_unix_time"]) - unix_time) <= EDGE_HOLD_SECONDS:
		return candidates[0]
	return {}


static func _weather_symbol_at(samples: Array[Dictionary], unix_time: float) -> Dictionary:
	var selected: Dictionary = {}
	var selected_hours := 2147483647
	var selected_start := -INF
	for sample in samples:
		var periods_value: Variant = sample.get("weather_symbol_periods", [])
		if not periods_value is Array:
			continue
		for period_value in periods_value:
			if not period_value is Dictionary:
				continue
			var period: Dictionary = period_value
			var start := CODEC.parse_utc_timestamp_to_unix(str(period.get("period_start_utc", "")))
			var end := CODEC.parse_utc_timestamp_to_unix(str(period.get("period_end_utc", "")))
			var hours := int(period.get("duration_hours", 0))
			if start < 0 or end <= start or hours <= 0 or unix_time < float(start) or unix_time >= float(end):
				continue
			if hours < selected_hours or (hours == selected_hours and float(start) > selected_start):
				selected = period
				selected_hours = hours
				selected_start = float(start)
	return selected


static func _legacy_weather_symbol_at(exact_sample: Dictionary) -> String:
	if exact_sample.has("legacy_weather_symbol"):
		return str(exact_sample["legacy_weather_symbol"])
	# Direct schema-v1 callers are tolerated, but the point symbol is never held
	# or used as evidence for a duration.
	return str(exact_sample.get("weather_symbol", ""))


static func _precipitation_at(samples: Array[Dictionary], unix_time: float) -> Dictionary:
	var amount_period: Dictionary = {}
	var probability_period: Dictionary = {}
	var amount_hours := 2147483647
	var probability_hours := 2147483647
	var amount_start := -INF
	var probability_start := -INF
	for sample in samples:
		var periods_value: Variant = sample.get("precipitation_periods", [])
		if not periods_value is Array:
			continue
		for period_value in periods_value:
			if not period_value is Dictionary:
				continue
			var period: Dictionary = period_value
			var start := CODEC.parse_utc_timestamp_to_unix(str(period.get("period_start_utc", "")))
			var end := CODEC.parse_utc_timestamp_to_unix(str(period.get("period_end_utc", "")))
			var hours := int(period.get("duration_hours", 0))
			if start < 0 or end <= start or unix_time < float(start) or unix_time >= float(end) or hours <= 0:
				continue
			if period.has("precipitation_amount_mm") and (hours < amount_hours or (hours == amount_hours and float(start) > amount_start)):
				amount_period = period
				amount_hours = hours
				amount_start = float(start)
			if period.has("precipitation_probability") and (hours < probability_hours or (hours == probability_hours and float(start) > probability_start)):
				probability_period = period
				probability_hours = hours
				probability_start = float(start)
	if amount_period.is_empty() and probability_period.is_empty():
		return {}
	var result := {}
	if not amount_period.is_empty():
		var amount_start_utc := str(amount_period["period_start_utc"])
		var amount_end_utc := str(amount_period["period_end_utc"])
		var amount_source := str(amount_period.get("source_period_key", amount_hours))
		result["precipitation_amount_mm"] = float(amount_period["precipitation_amount_mm"])
		result["precipitation_intensity_mm_per_hour"] = float(amount_period["precipitation_amount_mm"]) / float(amount_hours)
		result["precipitation_amount_window_hours"] = amount_hours
		result["precipitation_amount_window_start_utc"] = amount_start_utc
		result["precipitation_amount_window_end_utc"] = amount_end_utc
		result["precipitation_amount_source_period_key"] = amount_source
		result["precipitation_amount_window_id"] = "%s|%s|%s" % [amount_start_utc, amount_end_utc, amount_source]
	if not probability_period.is_empty():
		var probability_start_utc := str(probability_period["period_start_utc"])
		var probability_end_utc := str(probability_period["period_end_utc"])
		var probability_source := str(probability_period.get("source_period_key", probability_hours))
		result["precipitation_probability"] = float(probability_period["precipitation_probability"])
		result["precipitation_probability_window_hours"] = probability_hours
		result["precipitation_probability_window_start_utc"] = probability_start_utc
		result["precipitation_probability_window_end_utc"] = probability_end_utc
		result["precipitation_probability_source_period_key"] = probability_source
		result["precipitation_probability_window_id"] = "%s|%s|%s" % [probability_start_utc, probability_end_utc, probability_source]
	# Compatibility aliases identify the value-bearing window when there is an
	# amount. Probability-only periods remain distinguishable and do not imply mm.
	var selected_period: Dictionary = amount_period if not amount_period.is_empty() else probability_period
	var selected_hours := amount_hours if not amount_period.is_empty() else probability_hours
	result["precipitation_window_hours"] = selected_hours
	result["precipitation_window_start_utc"] = str(selected_period.get("period_start_utc", ""))
	result["precipitation_window_end_utc"] = str(selected_period.get("period_end_utc", ""))
	result["precipitation_source_period_key"] = str(selected_period.get("source_period_key", ""))
	result["precipitation_window_id"] = "%s|%s|%s" % [str(selected_period.get("period_start_utc", "")), str(selected_period.get("period_end_utc", "")), str(selected_period.get("source_period_key", selected_hours))]
	return result


static func _classify_weather(frame: Dictionary) -> String:
	var symbol := str(frame.get("weather_symbol", "")).to_lower()
	var precipitation_state := _precipitation_state(frame)
	if symbol.contains("thunder") and precipitation_state == "explicit":
		return "ThunderstormForecast"
	if precipitation_state == "explicit":
		return "Precipitation"
	if precipitation_state == "possible":
		return "PrecipitationPossible"
	if frame.has("cloud_fraction"):
		if float(frame["cloud_fraction"]) >= SKY_PARTLY_MAX_CLOUD:
			return "Overcast"
		if float(frame["cloud_fraction"]) >= SKY_CLEAR_MAX_CLOUD:
			return "PartlyCloudy"
		return "Clear"
	if symbol.contains("cloudy") or symbol.contains("fog"):
		return "Overcast" if symbol.contains("cloudy") and not symbol.contains("partlycloudy") else "PartlyCloudy"
	if symbol.contains("clearsky") or symbol.contains("fair"):
		return "Clear"
	return "Unknown"


static func _visual_weather_id(frame: Dictionary) -> String:
	var kind := str(frame.get("weather_type", "Unknown"))
	if kind in ["Overcast", "Precipitation", "PrecipitationPossible"]:
		return "Overcast"
	if kind == "ThunderstormForecast":
		return "Overcast"
	if kind == "PartlyCloudy":
		return "PartlyCloudy"
	if kind == "Clear":
		return "Clear"
	return "Unknown"


## Prevents seed noise close to cloud thresholds from flipping the discrete
## weather label every sample. Precipitation symbols/amounts remain authoritative.
static func _apply_weather_hysteresis(frames: Array[Dictionary]) -> void:
	if frames.is_empty():
		return
	var stable_type := str(frames[0].get("weather_type", "Unknown"))
	for index in range(1, frames.size()):
		var frame: Dictionary = frames[index]
		var raw_type := str(frame.get("weather_type", "Unknown"))
		var precipitation_state := _precipitation_state(frame)
		var cloud := float(frame.get("cloud_fraction", 0.0))
		if str(frame.get("weather_type", "")) == "ThunderstormForecast":
			stable_type = "ThunderstormForecast"
		elif precipitation_state == "explicit":
			stable_type = "Precipitation"
		elif precipitation_state == "possible":
			stable_type = "PrecipitationPossible"
		elif raw_type == "Unknown":
			stable_type = "Unknown"
		elif not frame.has("cloud_fraction"):
			stable_type = raw_type
		else:
			match stable_type:
				"Overcast":
					if cloud >= 0.66:
						stable_type = "Overcast"
					elif cloud >= 0.25:
						stable_type = "PartlyCloudy"
					else:
						stable_type = "Clear"
				"PartlyCloudy":
					if cloud >= 0.76:
						stable_type = "Overcast"
					elif cloud >= 0.25:
						stable_type = "PartlyCloudy"
					else:
						stable_type = "Clear"
				_:
					if cloud >= 0.76:
						stable_type = "Overcast"
					elif cloud >= 0.35:
						stable_type = "PartlyCloudy"
					else:
						stable_type = "Clear"
		frame["weather_type"] = stable_type
		frame["visual_weather_id"] = _visual_weather_id(frame)


static func _precipitation_state(frame: Dictionary) -> String:
	var symbol := str(frame.get("weather_symbol", "")).to_lower()
	var wet_symbol := _symbol_is_wet(symbol)
	var amount_available := frame.has("precipitation_amount_mm")
	var amount := float(frame.get("precipitation_amount_mm", 0.0))
	if wet_symbol or (amount_available and amount > 0.0):
		return "explicit"
	var probability: Variant = frame.get("precipitation_probability", null)
	var has_precipitation_window := amount_available or frame.has("precipitation_probability_window_start_utc") or frame.has("weather_symbol_window_start_utc")
	if has_precipitation_window and (probability is int or probability is float):
		if float(probability) >= POSSIBLE_PRECIPITATION_PROBABILITY:
			return "possible"
	if amount_available or frame.has("weather_symbol_window_start_utc"):
		return "none"
	return "unknown"


static func _symbol_is_wet(symbol: String) -> bool:
	var normalized := symbol.to_lower()
	return normalized.contains("rain") or normalized.contains("sleet") or normalized.contains("snow") or normalized.contains("thunder")


static func _precipitation_type(symbol_value: String) -> String:
	var symbol := symbol_value.to_lower()
	if symbol.contains("thunder"):
		if symbol.contains("sleet"):
			return "thunderstorm_sleet"
		if symbol.contains("snow"):
			return "thunderstorm_snow"
		if symbol.contains("rain"):
			return "thunderstorm_rain"
		return "thunderstorm"
	if symbol.contains("sleet"):
		return "sleet"
	if symbol.contains("snow"):
		return "snow"
	if symbol.contains("rain"):
		return "rain"
	return "unknown"


static func _classification_basis(frame: Dictionary) -> String:
	var symbol := str(frame.get("weather_symbol", "")).to_lower()
	if _symbol_is_wet(symbol):
		return "weather_symbol_period"
	if frame.has("precipitation_amount_mm") and float(frame["precipitation_amount_mm"]) > 0.0:
		return "precipitation_amount_period"
	if frame.has("precipitation_probability") and float(frame["precipitation_probability"]) >= POSSIBLE_PRECIPITATION_PROBABILITY:
		return "precipitation_probability_and_cloud"
	if frame.has("cloud_fraction"):
		return "instant_cloud_fraction"
	return "insufficient_evidence"


static func _resolve_data_quality(requested: String, samples: Array[Dictionary], start_unix: int, end_unix: int) -> String:
	if requested == "unavailable" or samples.is_empty():
		return "unavailable"
	var partial := requested == "partial"
	if float(samples[0]["_unix_time"]) > float(start_unix) + EDGE_HOLD_SECONDS or float(samples.back()["_unix_time"]) < float(end_unix) - EDGE_HOLD_SECONDS:
		partial = true
	for sample in samples:
		if not sample.has("wind_speed_mps") or not sample.has("cloud_fraction"):
			partial = true
	for index in range(maxi(0, samples.size() - 1)):
		var left_time := float(samples[index]["_unix_time"])
		var right_time := float(samples[index + 1]["_unix_time"])
		if right_time - left_time > MAX_INTERPOLATION_GAP_SECONDS and right_time > float(start_unix) and left_time < float(end_unix):
			partial = true
	if requested == "stale":
		return "stale_partial" if partial else "stale"
	return "partial" if partial else "fresh"


static func _build_day_summaries(samples: Array[Dictionary], boundaries: Array[String], labels: Array[String]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for day in range(boundaries.size() - 1):
		var day_start := float(CODEC.parse_utc_timestamp_to_unix(boundaries[day]))
		var day_end := float(CODEC.parse_utc_timestamp_to_unix(boundaries[day + 1]))
		var day_duration := day_end - day_start
		var day_label := labels[day] if day < labels.size() else CODEC._utc_iso_from_unix(int(day_start)).substr(0, 10)
		var summary := {
			"calendar_day": day_label,
			"start_utc": boundaries[day],
			"end_utc": boundaries[day + 1],
			"duration_seconds": day_duration,
			"fields": {},
			"weather_symbol_samples": [],
			"weather_symbol_periods": [],
			"precipitation_forecast_periods": [],
		}
		for field in ["wind_speed_mps", "wind_gust_mps", "cloud_fraction", "air_temperature_c", "air_pressure_hpa", "relative_humidity_percent"]:
			var integral := 0.0
			var covered := 0.0
			for index in range(maxi(0, samples.size() - 1)):
				var left: Dictionary = samples[index]
				var right: Dictionary = samples[index + 1]
				var left_t := maxf(day_start, float(left["_unix_time"]))
				var right_t := minf(day_end, float(right["_unix_time"]))
				if right_t <= left_t or float(right["_unix_time"]) - float(left["_unix_time"]) > MAX_INTERPOLATION_GAP_SECONDS:
					continue
				var left_value := _interpolate_sample_field(left, right, {}, field, left_t)
				var right_value := _interpolate_sample_field(left, right, {}, field, right_t)
				if bool(left_value.get("available", false)) and bool(right_value.get("available", false)):
					var duration := right_t - left_t
					integral += (float(left_value["value"]) + float(right_value["value"])) * 0.5 * duration
					covered += duration
			var field_entry := {"coverage_fraction": clampf(covered / day_duration, 0.0, 1.0)}
			if covered > 0.0:
				field_entry["time_weighted_mean"] = integral / covered
			summary["fields"][field] = field_entry
		var direction := _time_weighted_direction(samples, day_start, day_end, day_duration)
		if direction.has("direction_deg"):
			summary["wind_from_direction_deg"] = direction
		var period_keys := {}
		for sample in samples:
			var sample_time := float(sample["_unix_time"])
			if sample_time >= day_start and sample_time < day_end and sample.has("legacy_weather_symbol"):
				summary["weather_symbol_samples"].append({
					"valid_time_utc": str(sample["valid_time_utc"]),
					"weather_symbol": str(sample["legacy_weather_symbol"]),
					"temporal_semantics": "unknown_legacy_window_display_only",
				})
			for symbol_period_value in sample.get("weather_symbol_periods", []):
				if not symbol_period_value is Dictionary:
					continue
				var symbol_period: Dictionary = symbol_period_value
				var symbol_start := CODEC.parse_utc_timestamp_to_unix(str(symbol_period.get("period_start_utc", "")))
				var symbol_end := CODEC.parse_utc_timestamp_to_unix(str(symbol_period.get("period_end_utc", "")))
				if symbol_start < 0 or symbol_end <= symbol_start or float(symbol_end) <= day_start or float(symbol_start) >= day_end:
					continue
				var symbol_key := "%d:%d:%s" % [symbol_start, symbol_end, str(symbol_period.get("symbol_code", ""))]
				if not period_keys.has("s:" + symbol_key):
					period_keys["s:" + symbol_key] = true
					summary["weather_symbol_periods"].append(symbol_period.duplicate(true))
			for period_value in sample.get("precipitation_periods", []):
				if not period_value is Dictionary:
					continue
				var period: Dictionary = period_value
				var period_start := CODEC.parse_utc_timestamp_to_unix(str(period.get("period_start_utc", "")))
				var period_end := CODEC.parse_utc_timestamp_to_unix(str(period.get("period_end_utc", "")))
				if period_start < 0 or period_end <= period_start or float(period_end) <= day_start or float(period_start) >= day_end:
					continue
				var period_key := "p:%d:%d:%d" % [period_start, period_end, int(period.get("duration_hours", 0))]
				if not period_keys.has(period_key):
					period_keys[period_key] = true
					summary["precipitation_forecast_periods"].append(period.duplicate(true))
		result.append(summary)
	return result


static func _time_weighted_direction(samples: Array[Dictionary], day_start: float, day_end: float, day_duration: float) -> Dictionary:
	var north_component := 0.0
	var east_component := 0.0
	var covered := 0.0
	for index in range(maxi(0, samples.size() - 1)):
		var left: Dictionary = samples[index]
		var right: Dictionary = samples[index + 1]
		var t0 := maxf(day_start, float(left["_unix_time"]))
		var t1 := minf(day_end, float(right["_unix_time"]))
		if t1 <= t0 or float(right["_unix_time"]) - float(left["_unix_time"]) > MAX_INTERPOLATION_GAP_SECONDS:
			continue
		var d0 := _interpolate_sample_field(left, right, {}, "wind_from_direction_deg", t0)
		var d1 := _interpolate_sample_field(left, right, {}, "wind_from_direction_deg", t1)
		var s0 := _interpolate_sample_field(left, right, {}, "wind_speed_mps", t0)
		var s1 := _interpolate_sample_field(left, right, {}, "wind_speed_mps", t1)
		if not bool(d0.get("available", false)) or not bool(d1.get("available", false)) or not bool(s0.get("available", false)) or not bool(s1.get("available", false)):
			continue
		var duration := t1 - t0
		var mid_direction := _interpolate_angle_degrees(float(d0["value"]), float(d1["value"]), 0.5)
		var weight := (float(s0["value"]) + float(s1["value"])) * 0.5 * duration
		var radians := deg_to_rad(mid_direction)
		north_component += cos(radians) * weight
		east_component += sin(radians) * weight
		covered += duration
	if covered <= 0.0 or Vector2(east_component, north_component).length() < 0.000001:
		return {"coverage_fraction": clampf(covered / day_duration, 0.0, 1.0)}
	return {"direction_deg": fposmod(rad_to_deg(atan2(east_component, north_component)), 360.0), "coverage_fraction": clampf(covered / day_duration, 0.0, 1.0)}


static func _simulation_elapsed_cycles(timeline: Dictionary, simulation_time: Variant) -> Dictionary:
	if simulation_time is int or simulation_time is float:
		if not is_finite(float(simulation_time)):
			return {"ok": false, "error": "simulation_time_not_finite"}
		return {"ok": true, "elapsed_cycles": float(simulation_time)}
	if not simulation_time is Dictionary:
		return {"ok": false, "error": "simulation_time_invalid"}
	if simulation_time.has("elapsed_cycles"):
		if not CODEC.is_finite_number(simulation_time["elapsed_cycles"]):
			return {"ok": false, "error": "elapsed_cycles_invalid"}
		return {"ok": true, "elapsed_cycles": float(simulation_time["elapsed_cycles"])}
	for field in ["day_cycle_index", "cycle_seconds"]:
		if not simulation_time.has(field):
			return {"ok": false, "error": "simulation_time_field_missing:%s" % field}
	if int(simulation_time["day_cycle_index"]) < 0 or not CODEC.is_finite_number(simulation_time["cycle_seconds"]):
		return {"ok": false, "error": "simulation_cycle_position_invalid"}
	var seconds := float(simulation_time["cycle_seconds"])
	if seconds < 0.0 or seconds >= DAY_SECONDS:
		return {"ok": false, "error": "simulation_cycle_seconds_out_of_range"}
	var position := float(simulation_time["day_cycle_index"]) + seconds / DAY_SECONDS
	return {"ok": true, "elapsed_cycles": position - float(timeline["simulation_anchor_cycle_position"])}


static func _interpolate_weather_frames(a: Dictionary, b: Dictionary, weight: float) -> Dictionary:
	var result := {
		"cycle_offset": lerpf(float(a["cycle_offset"]), float(b["cycle_offset"]), weight),
		"data_quality": _combine_quality(str(a.get("data_quality", "unavailable")), str(b.get("data_quality", "unavailable"))),
		"held_fields": [],
		"interpolated_fields": [],
	}
	for field in TIMELINE_NUMERIC_FIELDS:
		if a.has(field) and b.has(field):
			result[field] = lerpf(float(a[field]), float(b[field]), weight)
	if a.has("wind_from_direction_deg") and b.has("wind_from_direction_deg"):
		var low_wind := minf(float(a.get("mean_wind_speed_mps", 0.0)), float(b.get("mean_wind_speed_mps", 0.0))) < 0.5
		result["wind_from_direction_deg"] = fposmod(float(a["wind_from_direction_deg"]) if low_wind else _interpolate_angle_degrees(float(a["wind_from_direction_deg"]), float(b["wind_from_direction_deg"]), weight), 360.0)
	# Discrete forecast-window state is left-continuous until the exact next
	# keyframe. Since period starts/ends are inserted as keyframes, this preserves
	# MET's half-open [start,end) windows without smearing rain over the boundary.
	var source: Dictionary = a
	for field in [
		"weather_type", "visual_weather_id", "weather_symbol", "legacy_weather_symbol",
		"weather_symbol_window_start_utc", "weather_symbol_window_end_utc", "weather_symbol_window_hours", "weather_symbol_source_period_key",
		"precipitation_window_hours", "precipitation_window_start_utc", "precipitation_window_end_utc",
		"precipitation_source_period_key", "precipitation_window_id", "precipitation_state",
		"precipitation_amount_window_hours", "precipitation_amount_window_start_utc", "precipitation_amount_window_end_utc", "precipitation_amount_source_period_key", "precipitation_amount_window_id",
		"precipitation_probability_window_hours", "precipitation_probability_window_start_utc", "precipitation_probability_window_end_utc", "precipitation_probability_source_period_key", "precipitation_probability_window_id",
		"precipitation_type", "thunderstorm_forecast", "weather_classification_basis",
		"precipitation_rate_semantics", "precipitation_resolution_hours",
		"precipitation_amount_mm", "precipitation_probability", "precipitation_intensity_mm_per_hour",
	]:
		if source.has(field):
			result[field] = source[field]
	for field in ["gust_target"]:
		if a.has(field) and b.has(field):
			var gust_a: Dictionary = a[field]
			var gust_b: Dictionary = b[field]
			var gust := gust_b.duplicate(true)
			if gust_a.has("gust_strength_mps") and gust_b.has("gust_strength_mps"):
				gust["gust_strength_mps"] = lerpf(float(gust_a["gust_strength_mps"]), float(gust_b["gust_strength_mps"]), weight)
			result[field] = gust
	result["held_fields"] = a.get("held_fields", []) if weight < 0.5 else b.get("held_fields", [])
	result["interpolated_fields"] = a.get("interpolated_fields", []) + b.get("interpolated_fields", [])
	return result


static func _blend_weather_states(old_state: Dictionary, new_state: Dictionary, weight: float) -> Dictionary:
	var result := new_state.duplicate(true)
	for field in TIMELINE_NUMERIC_FIELDS:
		if old_state.has(field) and new_state.has(field):
			result[field] = lerpf(float(old_state[field]), float(new_state[field]), weight)
	if old_state.has("wind_from_direction_deg") and new_state.has("wind_from_direction_deg"):
		result["wind_from_direction_deg"] = _interpolate_angle_degrees(float(old_state["wind_from_direction_deg"]), float(new_state["wind_from_direction_deg"]), weight)
	if old_state.has("gust_target") and new_state.has("gust_target"):
		var gust: Dictionary = new_state["gust_target"].duplicate(true)
		gust["gust_strength_mps"] = lerpf(float(old_state["gust_target"].get("gust_strength_mps", 0.0)), float(new_state["gust_target"].get("gust_strength_mps", 0.0)), weight)
		result["gust_target"] = gust
	result["data_quality"] = _combine_quality(str(old_state.get("data_quality", "unavailable")), str(new_state.get("data_quality", "unavailable")))
	return result


static func _combine_quality(a: String, b: String) -> String:
	if a == b:
		return a
	if a.begins_with("stale") or b.begins_with("stale"):
		return "stale_partial"
	if a == "unavailable" or b == "unavailable":
		return "partial"
	return "partial"


static func _provider_id(documents: Array) -> String:
	return str(documents[0].get("provider_id", "")) if not documents.is_empty() else ""


static func _latest_issued_at(documents: Array) -> String:
	var latest := ""
	var latest_unix := -1
	for document in documents:
		var timestamp := str(document.get("forecast_issued_at_utc", ""))
		var unix := CODEC.parse_utc_timestamp_to_unix(timestamp)
		if unix > latest_unix:
			latest_unix = unix
			latest = timestamp
	return latest


static func _latest_retrieved_at(documents: Array) -> String:
	var latest := ""
	var latest_unix := -1
	for document in documents:
		var timestamp := str(document.get("retrieved_at_utc", ""))
		var unix := CODEC.parse_utc_timestamp_to_unix(timestamp)
		if unix > latest_unix:
			latest_unix = unix
			latest = timestamp
	return latest


static func _earliest_valid_time(documents: Array) -> String:
	var earliest := ""
	var earliest_unix := 9223372036854775807
	for document in documents:
		var timestamp := str(document.get("valid_from_utc", ""))
		var unix := CODEC.parse_utc_timestamp_to_unix(timestamp)
		if unix >= 0 and unix < earliest_unix:
			earliest = timestamp
			earliest_unix = unix
	return earliest


static func _latest_valid_time(documents: Array) -> String:
	var latest := ""
	var latest_unix := -1
	for document in documents:
		var timestamp := str(document.get("valid_until_utc", ""))
		var unix := CODEC.parse_utc_timestamp_to_unix(timestamp)
		if unix > latest_unix:
			latest = timestamp
			latest_unix = unix
	return latest


static func _combined_source_metadata(documents: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for document in documents:
		result.append({
			"forecast_issued_at_utc": str(document.get("forecast_issued_at_utc", "")),
			"retrieved_at_utc": str(document.get("retrieved_at_utc", "")),
			"source_metadata": document.get("source_metadata", {}).duplicate(true),
		})
	return result


static func _seed_phase(seed: int, salt: int) -> float:
	var raw := posmod(seed * 1103515245 + salt * 12345 + 1013904223, 2147483647)
	return float(raw) / 2147483647.0 * TAU


static func _interpolate_angle_degrees(from_degrees: float, to_degrees: float, weight: float) -> float:
	var difference := fposmod(to_degrees - from_degrees + 180.0, 360.0) - 180.0
	return fposmod(from_degrees + difference * weight, 360.0)


static func _smoothstep01(value: float) -> float:
	var clamped := clampf(value, 0.0, 1.0)
	return clamped * clamped * (3.0 - 2.0 * clamped)
