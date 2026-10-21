extends SceneTree

const CODEC := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const CONTRACT := preload("res://scripts/weather_data/weather_simulation_core_contract.gd")
const CORE := preload("res://scripts/weather_data/weather_simulation_core.gd")
const ANALYSIS := preload("res://scripts/weather_data/weather_simulation_analysis.gd")
const FIXTURE_PATH := "res://tests/fixtures/weather_simulation_two_day_fixture.json"

var _checks := 0
var _failures: Array[String] = []
var _fixture: Dictionary


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_fixture = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_PATH))
	_expect(_fixture is Dictionary, "offline weather simulation fixture loads")
	_test_twelve_and_twenty_four_cycle_mapping()
	_test_determinism_and_seed_variation()
	_test_direction_and_calm_wind()
	_test_weather_category_hysteresis()
	_test_clear_rain_and_strong_wind_constraints()
	_test_explicit_thunder_symbol_signal()
	_test_nonuniform_interval_weighting()
	_test_missing_gust_stale_and_unavailable()
	_test_cross_midnight_and_authority_sampling()
	_test_stockholm_dst_calendar_boundaries()
	_test_forecast_update_preserves_history()
	_test_serialization_contract_and_purity()
	if _failures.is_empty():
		print("WeatherSimulationCore offline tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_twelve_and_twenty_four_cycle_mapping() -> void:
	var request_12 := _request(12)
	var result_12 := CORE.generate_timeline(request_12)
	_expect(bool(result_12.get("ok", false)), "12 game cycles per real date generates a timeline")
	if not bool(result_12.get("ok", false)):
		return
	var timeline_12: Dictionary = result_12["timeline"]
	_expect(timeline_12["keyframes"].size() == 97, "12-cycle two-day timeline has configured quarter-cycle sampling")
	var noon_12 := CORE.sample_weather(timeline_12, {"elapsed_cycles": 6.0})
	_expect(bool(noon_12.get("ok", false)) and noon_12["state"]["valid_time_utc"] == "2026-10-20T12:00:00Z", "12 cycles map six game cycles to half a real forecast day")
	var request_24 := _request(24)
	var result_24 := CORE.generate_timeline(request_24)
	_expect(bool(result_24.get("ok", false)), "24 game cycles per real date generates a timeline")
	if not bool(result_24.get("ok", false)):
		return
	var timeline_24: Dictionary = result_24["timeline"]
	_expect(timeline_24["keyframes"].size() == 193, "24-cycle two-day timeline has configured quarter-cycle sampling")
	var noon_24 := CORE.sample_weather(timeline_24, {"elapsed_cycles": 12.0})
	_expect(bool(noon_24.get("ok", false)) and noon_24["state"]["valid_time_utc"] == "2026-10-20T12:00:00Z", "24 cycles map twelve game cycles to half a real forecast day")
	var outside := CORE.sample_weather(timeline_24, {"elapsed_cycles": 49.0})
	_expect(not bool(outside.get("ok", false)) and outside.get("error") == "simulation_time_outside_timeline", "sampling outside the authoritative timeline is explicit")


func _test_determinism_and_seed_variation() -> void:
	var first := CORE.generate_timeline(_request(24, 12345))
	var repeat := CORE.generate_timeline(_request(24, 12345))
	var other_seed := CORE.generate_timeline(_request(24, 54321))
	_expect(bool(first.get("ok", false)) and bool(repeat.get("ok", false)), "fixed seed timelines generate")
	if not bool(first.get("ok", false)) or not bool(repeat.get("ok", false)) or not bool(other_seed.get("ok", false)):
		return
	_expect(_deep_equal(first["timeline"], repeat["timeline"]), "same forecast, seed and time parameters serialize identically")
	_expect(not _deep_equal(first["timeline"]["keyframes"], other_seed["timeline"]["keyframes"]), "different seeds produce small deterministic weather variation")
	var state_a := CORE.sample_weather(first["timeline"], {"elapsed_cycles": 5.125})
	var state_b := CORE.sample_weather(first["timeline"], {"elapsed_cycles": 5.125})
	_expect(_deep_equal(state_a, state_b), "same timeline and authority time return identical samples")


func _test_direction_and_calm_wind() -> void:
	var result := CORE.generate_timeline(_request(24))
	_expect(bool(result.get("ok", false)), "direction fixture timeline generates")
	if bool(result.get("ok", false)):
		var around_north := CORE.sample_weather(result["timeline"], {"elapsed_cycles": 0.5})
		_expect(bool(around_north.get("ok", false)) and _angle_distance(float(around_north["state"].get("wind_from_direction_deg", 180.0)), 0.0) < 10.0, "wind direction crosses 358 to 1 degrees through north")
	var calm_document: Dictionary = _fixture.duplicate(true)
	for sample in calm_document["timeseries"]:
		sample["wind_speed_mps"] = 0.0
		sample["wind_from_direction_deg"] = 180.0 if int(sample["valid_time_utc"].substr(14, 2)) % 2 == 0 else 0.0
	var calm := CORE.generate_timeline(_request(24, 19, calm_document))
	_expect(bool(calm.get("ok", false)), "calm wind fixture timeline generates")
	if bool(calm.get("ok", false)):
		var calm_state: Dictionary = CORE.sample_weather(calm["timeline"], {"elapsed_cycles": 2.0})["state"]
		_expect(float(calm_state.get("mean_wind_speed_mps", 1.0)) < 0.5, "zero-wind forecast remains calm")
		_expect(is_finite(float(calm_state.get("wind_from_direction_deg", NAN))), "calm wind direction remains finite and does not rotate numerically without bound")
	var zero_gust := CORE.map_forecast_gust_to_windfield_target(5.0, 4.0)
	_expect(bool(zero_gust.get("available", false)) and is_equal_approx(float(zero_gust["gust_strength_mps"]), 0.0), "forecast gust below mean maps to a nonnegative zero target")
	var missing_gust := CORE.map_forecast_gust_to_windfield_target(5.0, null)
	_expect(not bool(missing_gust.get("available", true)), "missing forecast gust remains unavailable")


func _test_weather_category_hysteresis() -> void:
	var threshold_document: Dictionary = _fixture.duplicate(true)
	for sample in threshold_document["timeseries"]:
		sample["cloud_fraction"] = 0.30
		_set_weather_symbol_periods(sample, "clearsky_day")
		sample.erase("precipitation_periods")
	var result := CORE.generate_timeline(_request(24, 191, threshold_document))
	_expect(bool(result.get("ok", false)), "near-threshold cloud forecast generates")
	if not bool(result.get("ok", false)):
		return
	var first_type := str(result["timeline"]["keyframes"][0].get("weather_type", ""))
	var stable := not first_type.is_empty()
	for frame in result["timeline"]["keyframes"]:
		if str(frame.get("weather_type", "")) != first_type:
			stable = false
			break
	_expect(stable, "small deterministic cloud perturbations do not flicker the discrete weather category")


func _test_clear_rain_and_strong_wind_constraints() -> void:
	var clear_document := _hourly_weather_document("clear", -1, false)
	var clear_result := CORE.generate_timeline(_request(24, 71, clear_document, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z"))
	_expect(bool(clear_result.get("ok", false)), "clear-day fixture generates")
	if bool(clear_result.get("ok", false)):
		var all_clear := true
		for frame in clear_result["timeline"]["keyframes"]:
			if str(frame.get("weather_type", "")) != "Clear":
				all_clear = false
		_expect(all_clear, "persistent clear forecast remains clear without unrelated random weather changes")
	var rain_document := _hourly_weather_document("rain", -1, false)
	var rain_result := CORE.generate_timeline(_request(24, 72, rain_document, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z"))
	_expect(bool(rain_result.get("ok", false)), "persistent rain fixture generates")
	if bool(rain_result.get("ok", false)):
		var rain_seen := false
		var rain_cloud_consistent := true
		var invented_storm := false
		for frame in rain_result["timeline"]["keyframes"]:
			if str(frame.get("weather_type", "")) == "Precipitation":
				rain_seen = true
				if float(frame.get("cloud_fraction", 0.0)) < 0.45:
					rain_cloud_consistent = false
			if str(frame.get("weather_type", "")).to_lower().contains("storm") or str(frame.get("weather_symbol", "")).to_lower().contains("thunder"):
				invented_storm = true
		_expect(rain_seen, "forecast precipitation creates a sustained precipitation state")
		_expect(rain_cloud_consistent, "precipitation states preserve the cloudy forecast background")
		_expect(not invented_storm, "ordinary rain is never upgraded to an unforecast storm")
		var rain_sample: Dictionary = CORE.sample_weather(rain_result["timeline"], {"elapsed_cycles": 13.0})["state"]
		_expect(float(rain_sample.get("precipitation_intensity_mm_per_hour", 0.0)) > 0.0, "forecast amount is converted with its explicit duration to mm per hour")
		var rain_day_summary: Dictionary = rain_result["timeline"]["forecast_day_summaries"][0]
		_expect(not rain_day_summary["precipitation_forecast_periods"].is_empty() and rain_day_summary["weather_symbol_periods"].size() > 0, "daily background retains explicit precipitation and symbol windows")
		var forecast_stats: Dictionary = ANALYSIS.analyze_forecast(rain_document, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z")
		var generated_stats: Dictionary = ANALYSIS.analyze_timeline(rain_result["timeline"], rain_document)
		_expect(absf(float(forecast_stats["metrics"]["explicit_precipitation_day_fraction"]) - 1.0) < 0.001, "24h explicit rain forecast remains explicit across the full day")
		_expect(absf(float(generated_stats["metrics"]["explicit_precipitation_day_fraction"]) - 1.0) < 0.001, "generated weather retains the persistent-rain day background")
	var strong_document: Dictionary = _fixture.duplicate(true)
	for sample in strong_document["timeseries"]:
		sample["wind_speed_mps"] = 22.0
		sample["wind_gust_mps"] = 29.0
	var strong_result := CORE.generate_timeline(_request(24, 73, strong_document))
	_expect(bool(strong_result.get("ok", false)), "strong-wind forecast generates")
	if bool(strong_result.get("ok", false)):
		var no_storm_type := true
		for frame in strong_result["timeline"]["keyframes"]:
			if str(frame.get("weather_type", "")).to_lower().contains("storm"):
				no_storm_type = false
		_expect(no_storm_type, "high forecast wind alone does not invent a storm classification")
		var strong_sample: Dictionary = CORE.sample_weather(strong_result["timeline"], {"elapsed_cycles": 3.0})["state"]
		_expect(float(strong_sample.get("mean_wind_speed_mps", 0.0)) > 20.0, "strong forecast wind remains represented")
		_expect(strong_sample.has("gust_target") and str(strong_sample["gust_target"]["calibration_status"]) == "uncalibrated_first_pass_assumption", "gust excess mapping remains explicit and uncalibrated")


func _test_nonuniform_interval_weighting() -> void:
	var document := _minimal_document("2026-10-20T00:00:00Z", [
		{"valid_time_utc":"2026-10-20T00:00:00Z","wind_speed_mps":0.0,"wind_from_direction_deg":0.0,"cloud_fraction":0.2,"air_temperature_c":10.0,"air_pressure_hpa":1010.0},
		{"valid_time_utc":"2026-10-20T01:00:00Z","wind_speed_mps":10.0,"wind_from_direction_deg":0.0,"cloud_fraction":0.2,"air_temperature_c":10.0,"air_pressure_hpa":1010.0},
		{"valid_time_utc":"2026-10-20T10:00:00Z","wind_speed_mps":10.0,"wind_from_direction_deg":0.0,"cloud_fraction":0.2,"air_temperature_c":10.0,"air_pressure_hpa":1010.0},
		{"valid_time_utc":"2026-10-20T22:00:00Z","wind_speed_mps":0.0,"wind_from_direction_deg":0.0,"cloud_fraction":0.2,"air_temperature_c":10.0,"air_pressure_hpa":1010.0},
		{"valid_time_utc":"2026-10-21T00:00:00Z","wind_speed_mps":0.0,"wind_from_direction_deg":0.0,"cloud_fraction":0.2,"air_temperature_c":10.0,"air_pressure_hpa":1010.0},
	])
	var result := CORE.generate_timeline(_request(24, 77, document, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z"))
	_expect(bool(result.get("ok", false)), "nonuniform forecast sample times generate")
	if bool(result.get("ok", false)):
		var mean := float(result["timeline"]["forecast_day_summaries"][0]["fields"]["wind_speed_mps"]["time_weighted_mean"])
		_expect(absf(mean - (155.0 / 24.0)) < 0.01, "daily weather background uses elapsed-time trapezoidal weighting rather than sample count")
		_expect(float(result["timeline"]["forecast_day_summaries"][0]["fields"]["wind_speed_mps"]["coverage_fraction"]) > 0.99, "nonuniform forecast interval coverage is measured in time")


func _test_explicit_thunder_symbol_signal() -> void:
	var thunder_document := _hourly_weather_document("rain", -1, false)
	for sample in thunder_document["timeseries"]:
		_set_weather_symbol_periods(sample, "lightrainandthunder_day")
	var thunder_result := CORE.generate_timeline(_request(24, 7281, thunder_document, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z"))
	_expect(bool(thunder_result.get("ok", false)), "explicit MET thunder symbol generates a timeline")
	if bool(thunder_result.get("ok", false)):
		var sample: Dictionary = CORE.sample_weather(thunder_result["timeline"], {"elapsed_cycles": 8.5})["state"]
		_expect(bool(sample.get("thunderstorm_forecast", false)), "the sampled keyframe preserves thunder as an explicit forecast marker")
		_expect(str(sample.get("weather_type", "")) == "ThunderstormForecast", "explicit thunder symbol plus explicit precipitation keeps the thunder forecast classification")
	var heavy_rain_document := _hourly_weather_document("rain", -1, false)
	for sample in heavy_rain_document["timeseries"]:
		_set_weather_symbol_periods(sample, "rain")
	var heavy_rain_result := CORE.generate_timeline(_request(24, 7282, heavy_rain_document, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z"))
	_expect(bool(heavy_rain_result.get("ok", false)), "heavy-rain non-thunder fixture generates")
	if bool(heavy_rain_result.get("ok", false)):
		var heavy_sample: Dictionary = CORE.sample_weather(heavy_rain_result["timeline"], {"elapsed_cycles": 8.5})["state"]
		_expect(not bool(heavy_sample.get("thunderstorm_forecast", false)), "rainfall amount without a thunder symbol does not activate the storm marker")


func _test_missing_gust_stale_and_unavailable() -> void:
	var no_gust_document: Dictionary = _fixture.duplicate(true)
	for sample in no_gust_document["timeseries"]:
		sample.erase("wind_gust_mps")
	var no_gust := CORE.generate_timeline(_request(24, 80, no_gust_document))
	_expect(bool(no_gust.get("ok", false)), "forecast without gust fields still generates")
	if bool(no_gust.get("ok", false)):
		var state: Dictionary = CORE.sample_weather(no_gust["timeline"], {"elapsed_cycles": 4.0})["state"]
		_expect(not state.has("gust_forecast_mps") and not state.has("gust_target"), "missing gust stays absent instead of being manufactured")
	var stale := CORE.generate_timeline(_request(24, 81, _fixture, "2026-10-20T00:00:00Z", "2026-10-22T00:00:00Z", "stale"))
	_expect(bool(stale.get("ok", false)) and stale["timeline"]["source_data_quality"] == "stale", "stale forecast remains explicitly marked stale")
	if bool(stale.get("ok", false)):
		_expect(CORE.sample_weather(stale["timeline"], {"elapsed_cycles": 2.0})["state"]["data_quality"] == "stale", "sample does not relabel stale forecast as current")
	var unavailable := CORE.generate_timeline(_request(24, 82, {}, "2026-10-20T00:00:00Z", "2026-10-22T00:00:00Z", "unavailable"))
	_expect(bool(unavailable.get("ok", false)), "unavailable source produces an explicit empty-data timeline")
	if bool(unavailable.get("ok", false)):
		var state_unavailable: Dictionary = CORE.sample_weather(unavailable["timeline"], {"elapsed_cycles": 1.0})["state"]
		_expect(state_unavailable["data_quality"] == "unavailable" and not state_unavailable.has("mean_wind_speed_mps"), "unavailable weather has no fabricated wind values")
	var partial_document: Dictionary = _fixture.duplicate(true)
	for sample in partial_document["timeseries"]:
		sample.erase("cloud_fraction")
	var partial := CORE.generate_timeline(_request(24, 83, partial_document))
	_expect(bool(partial.get("ok", false)) and partial["timeline"]["source_data_quality"] == "partial", "missing forecast fields are identified as partial data")


func _test_cross_midnight_and_authority_sampling() -> void:
	var result := CORE.generate_timeline(_request(24))
	_expect(bool(result.get("ok", false)), "cross-midnight fixture timeline generates")
	if not bool(result.get("ok", false)):
		return
	var timeline: Dictionary = result["timeline"]
	var before_midnight := CORE.sample_weather(timeline, {"elapsed_cycles": 23.9})
	var at_midnight := CORE.sample_weather(timeline, {"elapsed_cycles": 24.0})
	var after_midnight := CORE.sample_weather(timeline, {"elapsed_cycles": 24.1})
	_expect(before_midnight["state"]["valid_time_utc"] == "2026-10-20T23:54:00Z" and at_midnight["state"]["valid_time_utc"] == "2026-10-21T00:00:00Z" and after_midnight["state"]["valid_time_utc"] == "2026-10-21T00:06:00Z", "forecast time mapping crosses UTC midnight continuously")
	var wind_before := float(before_midnight["state"].get("mean_wind_speed_mps", 0.0))
	var wind_after := float(after_midnight["state"].get("mean_wind_speed_mps", 0.0))
	_expect(absf(wind_after - wind_before) < 1.0, "wind has no midnight discontinuity when adjacent forecast samples connect")
	var anchor: Dictionary = timeline["simulation_anchor"]
	var authority_sample := CORE.sample_weather(timeline, {
		"day_cycle_index": int(anchor["day_cycle_index"]) + 12,
		"cycle_seconds": float(anchor["cycle_seconds"]),
	})
	_expect(bool(authority_sample.get("ok", false)) and authority_sample["state"]["valid_time_utc"] == "2026-10-20T12:00:00Z", "WorldTimeManager authority cycle coordinates sample the same timeline on server and client")
	var snapshot_anchor := CORE.make_simulation_anchor_from_world_time_snapshot({
		"authority_session_id": "server-session",
		"authority_snapshot_sequence": 88,
		"authority_sync_anchor": {
			"day_cycle_index": 10,
			"cycle_seconds": 900.0,
			"authoritative_timestamp_utc": 1792454400.0,
			"time_scale": 24.0,
			"paused": false,
		},
	})
	_expect(snapshot_anchor["authority_session_id"] == "server-session" and snapshot_anchor["authority_snapshot_sequence"] == 88 and CODEC.is_valid_utc_timestamp(snapshot_anchor["authoritative_timestamp_utc"]), "WorldTimeManager server snapshot becomes a serializable weather anchor")
	var midday_request := _request(24)
	midday_request["simulation_anchor"]["authoritative_timestamp_utc"] = "2026-10-20T12:00:00Z"
	var midday_timeline := CORE.generate_timeline(midday_request)
	_expect(bool(midday_timeline.get("ok", false)), "timeline accepts an authority anchor inside its forecast date range")
	if bool(midday_timeline.get("ok", false)):
		var at_anchor := CORE.sample_weather(midday_timeline["timeline"], {"day_cycle_index": 36, "cycle_seconds": 18000.0})
		_expect(bool(at_anchor.get("ok", false)) and at_anchor["state"]["valid_time_utc"] == "2026-10-20T12:00:00Z", "authority-time anchor maps the current simulation instant to the matching forecast hour")


func _test_forecast_update_preserves_history() -> void:
	var old_result := CORE.generate_timeline(_request(24, 90))
	var revised_document: Dictionary = _fixture.duplicate(true)
	for sample in revised_document["timeseries"]:
		sample["wind_speed_mps"] = minf(20.0, float(sample.get("wind_speed_mps", 0.0)) + 5.0)
	var new_request := _request(24, 91, revised_document)
	new_request["simulation_anchor"]["day_cycle_index"] = 42
	new_request["simulation_anchor"]["authoritative_timestamp_utc"] = "2026-10-20T06:00:00Z"
	var update_result := CORE.update_forecast(old_result["timeline"], new_request, 6.0, 1.0)
	_expect(bool(update_result.get("ok", false)), "new forecast can update an active timeline")
	if not bool(update_result.get("ok", false)):
		return
	var updated: Dictionary = update_result["timeline"]
	var old_frames: Array = old_result["timeline"]["keyframes"]
	var updated_frames: Array = updated["keyframes"]
	var history_matches := true
	for old_frame in old_frames:
		if float(old_frame["cycle_offset"]) > 6.0 + 0.000001:
			break
		var found := false
		for new_frame in updated_frames:
			if absf(float(new_frame["cycle_offset"]) - float(old_frame["cycle_offset"])) < 0.000001:
				found = _deep_equal(old_frame, new_frame)
				break
		if not found:
			history_matches = false
			break
	_expect(history_matches, "already elapsed timeline keyframes are preserved exactly after forecast update")
	var old_boundary: Dictionary = CORE.sample_weather(old_result["timeline"], {"elapsed_cycles": 6.0})["state"]
	var new_boundary: Dictionary = CORE.sample_weather(updated, {"day_cycle_index": 42, "cycle_seconds": 18000.0})["state"]
	_expect(_weather_values_equal(old_boundary, new_boundary), "weather values at the update boundary are unchanged")
	var just_after: Dictionary = CORE.sample_weather(updated, {"day_cycle_index": 42, "cycle_seconds": 27000.0})["state"]
	_expect(absf(float(just_after.get("mean_wind_speed_mps", 0.0)) - float(old_boundary.get("mean_wind_speed_mps", 0.0))) < 2.0, "future forecast revision blends from current weather instead of jumping immediately")


func _test_stockholm_dst_calendar_boundaries() -> void:
	var spring_start := "2026-03-28T23:00:00Z"
	var spring_mid := "2026-03-29T10:30:00Z"
	var spring_end := "2026-03-29T22:00:00Z"
	var spring_document := _minimal_document(spring_start, _calendar_samples(spring_start, spring_mid, spring_end))
	var spring_request := _request(24, 97, spring_document, spring_start, spring_end)
	spring_request["requested_start_utc"] = spring_start
	spring_request["requested_end_utc"] = spring_end
	spring_request["real_day_boundaries_utc"] = [spring_start, spring_end]
	spring_request["calendar_day_labels"] = ["2026-03-29"]
	spring_request["calendar_boundary_basis"] = "Europe/Stockholm"
	spring_request["simulation_anchor"]["authoritative_timestamp_utc"] = spring_start
	var spring := CORE.generate_timeline(spring_request)
	_expect(bool(spring.get("ok", false)), "23-hour Stockholm calendar day is accepted with explicit UTC boundaries")
	if bool(spring.get("ok", false)):
		var spring_midpoint: Dictionary = CORE.sample_weather(spring["timeline"], {"elapsed_cycles": 12.0})["state"]
		_expect(spring_midpoint["valid_time_utc"] == spring_mid, "12 of 24 cycles maps to the midpoint of a 23-hour spring DST day")
		_expect(spring_midpoint["calendar_day_label"] == "2026-03-29" and spring["timeline"]["forecast_day_summaries"][0]["duration_seconds"] == 23 * 3600, "spring DST local date and real duration are preserved")
	var autumn_start := "2026-10-24T22:00:00Z"
	var autumn_mid := "2026-10-25T10:30:00Z"
	var autumn_end := "2026-10-25T23:00:00Z"
	var autumn_document := _minimal_document(autumn_start, _calendar_samples(autumn_start, autumn_mid, autumn_end))
	var autumn_request := _request(24, 98, autumn_document, autumn_start, autumn_end)
	autumn_request["requested_start_utc"] = autumn_start
	autumn_request["requested_end_utc"] = autumn_end
	autumn_request["real_day_boundaries_utc"] = [autumn_start, autumn_end]
	autumn_request["calendar_day_labels"] = ["2026-10-25"]
	autumn_request["calendar_boundary_basis"] = "Europe/Stockholm"
	autumn_request["simulation_anchor"]["authoritative_timestamp_utc"] = autumn_start
	var autumn := CORE.generate_timeline(autumn_request)
	_expect(bool(autumn.get("ok", false)), "25-hour Stockholm calendar day is accepted with explicit UTC boundaries")
	if bool(autumn.get("ok", false)):
		var autumn_midpoint: Dictionary = CORE.sample_weather(autumn["timeline"], {"elapsed_cycles": 12.0})["state"]
		_expect(autumn_midpoint["valid_time_utc"] == autumn_mid, "12 of 24 cycles maps to the midpoint of a 25-hour autumn DST day")
		_expect(autumn_midpoint["calendar_day_label"] == "2026-10-25" and autumn["timeline"]["forecast_day_summaries"][0]["duration_seconds"] == 25 * 3600, "autumn DST local date and real duration are preserved")


func _test_serialization_contract_and_purity() -> void:
	var result := CORE.generate_timeline(_request(12))
	_expect(bool(result.get("ok", false)), "timeline for serialization test generates")
	if bool(result.get("ok", false)):
		var encoded := CORE.serialize_timeline(result["timeline"])
		var decoded := CORE.deserialize_timeline(encoded)
		_expect(not encoded.is_empty() and bool(decoded.get("ok", false)), "timeline JSON serializes and validates on load")
		_expect(_deep_equal(result["timeline"], decoded.get("timeline", {})), "timeline JSON round-trips without changing authority or weather state")
		_expect(CONTRACT.validate_timeline(result["timeline"]).get("ok", false), "versioned timeline contract accepts generated output")
		var optional_metadata_removed: Dictionary = result["timeline"].duplicate(true)
		for frame in optional_metadata_removed["keyframes"]:
			for field in ["precipitation_amount_window_hours", "precipitation_amount_window_start_utc", "precipitation_amount_window_end_utc", "precipitation_amount_source_period_key", "precipitation_probability_window_hours", "precipitation_probability_window_start_utc", "precipitation_probability_window_end_utc", "precipitation_probability_source_period_key"]:
				frame.erase(field)
		_expect(CONTRACT.validate_timeline(optional_metadata_removed).get("ok", false), "older timeline schema remains readable when optional separate-window diagnostics are absent")
	var source := FileAccess.get_file_as_string("res://scripts/weather_data/weather_simulation_core.gd")
	_expect(source.contains("extends RefCounted") and not source.contains("extends Node"), "simulation core is a data-only RefCounted module")
	_expect(not source.contains("HTTPRequest") and not source.contains("SceneTree") and not source.contains("Time.get_"), "simulation core has no network, scene-tree or wall-clock dependency")
	_expect(not source.contains("RandomNumberGenerator") and not source.contains("randf("), "simulation core does not depend on mutable/system random state")
	var bad_version: Dictionary = result.get("timeline", {}).duplicate(true)
	bad_version["schema_version"] = 90
	_expect(CONTRACT.validate_timeline(bad_version).get("error") == "unsupported_timeline_schema", "unknown serialized timeline versions are rejected")


func _request(cycles_per_day: int, seed: int = 177, document: Dictionary = {}, start_utc: String = "2026-10-20T00:00:00Z", end_utc: String = "2026-10-22T00:00:00Z", quality: String = "fresh") -> Dictionary:
	var selected_document: Dictionary = document if not document.is_empty() else _fixture
	var documents: Array = [] if quality == "unavailable" else [selected_document]
	return {
		"schema_version": 1,
		"request_id": "simulation-%d-%d" % [cycles_per_day, seed],
		"region_id": "oresund",
		"requested_start_utc": start_utc,
		"requested_end_utc": end_utc,
		"generated_at_utc": "2026-10-20T00:00:00Z",
		"simulation_seed": seed,
		"cycles_per_real_day": cycles_per_day,
		"resolution_per_cycle": 4,
		"forecast_quality": quality,
		"forecast_documents": documents,
		"simulation_anchor": {
			"day_cycle_index": 36,
			"cycle_seconds": 18000.0,
			"authoritative_timestamp_utc": "2026-10-20T00:00:00Z",
			"time_scale": 24.0,
			"paused": false,
			"authority_session_id": "test-authority",
			"authority_snapshot_sequence": 4,
		},
	}


func _minimal_document(start_utc: String, samples: Array) -> Dictionary:
	var first := str(samples.front()["valid_time_utc"])
	var last := str(samples.back()["valid_time_utc"])
	return {
		"schema_version": 1,
		"provider_id": "offline_minimal_fixture",
		"region_id": "oresund",
		"latitude": 55.64,
		"longitude": 12.78,
		"forecast_issued_at_utc": "2026-10-19T18:00:00Z",
		"retrieved_at_utc": "2026-10-19T18:05:00Z",
		"valid_from_utc": first,
		"valid_until_utc": last,
		"timeseries": samples,
		"source_metadata": {"fixture": true},
	}


func _set_weather_symbol_periods(sample: Dictionary, symbol_code: String) -> void:
	var periods: Array[Dictionary] = []
	for period_value in sample.get("weather_symbol_periods", []):
		if not period_value is Dictionary:
			continue
		var period: Dictionary = period_value.duplicate(true)
		period["symbol_code"] = symbol_code
		periods.append(period)
	if periods.is_empty():
		var start := str(sample.get("valid_time_utc", ""))
		var start_unix := CODEC.parse_utc_timestamp_to_unix(start)
		periods.append({"duration_hours": 1, "period_start_utc": start, "period_end_utc": CODEC._utc_iso_from_unix(start_unix + 3600), "symbol_code": symbol_code, "source_period_key": "next_1_hours", "source_field": "summary.symbol_code"})
	sample["weather_symbol_periods"] = periods
	sample.erase("weather_symbol")


func _hourly_weather_document(kind: String, shower_hour: int, probability_only: bool) -> Dictionary:
	var samples: Array[Dictionary] = []
	var start_unix := CODEC.parse_utc_timestamp_to_unix("2026-10-20T00:00:00Z")
	for hour in range(25):
		var timestamp := CODEC._utc_iso_from_unix(start_unix + hour * 3600)
		var wet := kind == "rain" or hour == shower_hour
		if kind == "shower":
			wet = hour == shower_hour
		var symbol_code := "rain" if wet else ("clearsky_day" if kind == "clear" else "cloudy")
		var sample := {
			"valid_time_utc": timestamp,
			"wind_speed_mps": 5.0,
			"wind_gust_mps": 7.0,
			"wind_from_direction_deg": 270.0,
			"cloud_fraction": 0.9 if wet else (0.05 if kind == "clear" else 0.65),
			"air_temperature_c": 10.0,
			"air_pressure_hpa": 1012.0,
		}
		if hour < 24:
			sample["weather_symbol_periods"] = [{"duration_hours": 1, "period_start_utc": timestamp, "period_end_utc": CODEC._utc_iso_from_unix(start_unix + (hour + 1) * 3600), "symbol_code": symbol_code, "source_period_key": "next_1_hours", "source_field": "summary.symbol_code"}]
			var precipitation_period := {"duration_hours": 1, "period_start_utc": timestamp, "period_end_utc": CODEC._utc_iso_from_unix(start_unix + (hour + 1) * 3600), "source_period_key": "next_1_hours", "source_field": "details.precipitation_amount/probability", "source_fields": ["details.probability_of_precipitation"] if probability_only else ["details.precipitation_amount", "details.probability_of_precipitation"]}
			if not probability_only:
				precipitation_period["precipitation_amount_mm"] = 0.4 if wet else 0.0
			precipitation_period["precipitation_probability"] = 0.85 if probability_only or wet else 0.05
			sample["precipitation_periods"] = [precipitation_period]
		samples.append(sample)
	var document := _minimal_document("2026-10-20T00:00:00Z", samples)
	document["schema_version"] = CODEC.STANDARD_SCHEMA_VERSION
	document["valid_until_utc"] = "2026-10-21T00:00:00Z"
	return document


func _calendar_samples(start_utc: String, mid_utc: String, end_utc: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for timestamp in [start_utc, mid_utc, end_utc]:
		result.append({
			"valid_time_utc": timestamp,
			"air_temperature_c": 8.0,
			"air_pressure_hpa": 1010.0,
			"wind_speed_mps": 5.0,
			"wind_from_direction_deg": 270.0,
			"cloud_fraction": 0.5,
		})
	return result


func _angle_distance(a: float, b: float) -> float:
	return absf(fposmod(a - b + 180.0, 360.0) - 180.0)


func _deep_equal(a: Variant, b: Variant) -> bool:
	if (a is int or a is float) and (b is int or b is float):
		return is_equal_approx(float(a), float(b))
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for key in a.keys():
			if not b.has(key) or not _deep_equal(a[key], b[key]):
				return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for index in range(a.size()):
			if not _deep_equal(a[index], b[index]):
				return false
		return true
	return a == b


func _weather_values_equal(a: Dictionary, b: Dictionary) -> bool:
	for field in ["mean_wind_speed_mps", "wind_from_direction_deg", "cloud_fraction", "air_temperature_c", "air_pressure_hpa", "weather_type", "visual_weather_id", "precipitation_intensity_mm_per_hour"]:
		if a.has(field) != b.has(field):
			return false
		if a.has(field) and not _deep_equal(a[field], b[field]):
			return false
	return true


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL: " + description)
	else:
		print("PASS: " + description)
