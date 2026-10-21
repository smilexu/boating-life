extends SceneTree

const ANALYSIS := preload("res://scripts/weather_data/weather_simulation_analysis.gd")
const CORE := preload("res://scripts/weather_data/weather_simulation_core.gd")
const CODEC := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const LAB_SCRIPT := preload("res://scripts/weather_simulation_lab.gd")
const FIXTURE_PATH := "res://tests/fixtures/weather_simulation_two_day_fixture.json"

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_PATH))
	_expect(fixture.get("provider_id") == "offline_weather_simulation_fixture", "bundled input is explicitly identified as a test fixture")
	_expect(bool(fixture.get("source_metadata", {}).get("fixture", false)), "fixture metadata marks its values synthetic")
	_expect(LAB_SCRIPT.cache_freshness_label(101, 100) == "FRESH CACHE", "cache expiry after now is fresh")
	_expect(LAB_SCRIPT.cache_freshness_label(100, 100) == "STALE CACHE", "cache expiry at now is stale")
	_test_nonuniform_time_weighting_and_circular_direction()
	_test_overlapping_precipitation_and_probability()
	_test_symbol_window_resolution_and_boundaries()
	_test_persistent_rain_and_short_shower()
	_test_cross_midnight_precipitation_continuity()
	_test_probability_only_and_missing_coverage()
	_test_legacy_schema_migration()
	_test_12_24_day_statistics_and_export()
	_test_direction_chart_unwrap()
	_test_analysis_source_is_independent()
	if _failures.is_empty():
		print("WeatherSimulationAnalysis offline tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_nonuniform_time_weighting_and_circular_direction() -> void:
	var document := _document([
		_sample("2026-10-20T00:00:00Z", 0.0, 359.0),
		_sample("2026-10-20T01:00:00Z", 10.0, 1.0),
		_sample("2026-10-20T05:00:00Z", 10.0, 1.0),
	])
	var stats := ANALYSIS.analyze_forecast(document, "2026-10-20T00:00:00Z", "2026-10-20T05:00:00Z")
	_expect(bool(stats.get("ok", false)), "nonuniform fixture intervals are analyzable")
	if not bool(stats.get("ok", false)):
		return
	var metrics: Dictionary = stats["metrics"]
	_expect(absf(float(metrics["mean_wind_speed_mps"]) - 9.0) < 0.001, "wind average is duration weighted across 1h and 4h intervals")
	_expect(_angle_distance(float(metrics["dominant_wind_from_deg"]), 0.0) < 1.1, "dominant direction uses circular wind-vector statistics across north")
	_expect(absf(float(metrics["wind_speed_p90_mps"]) - 10.0) < 0.001, "P90 uses covered duration rather than sample count")


func _test_overlapping_precipitation_and_probability() -> void:
	var base := _sample("2026-10-20T00:00:00Z", 5.0, 180.0)
	base["precipitation_periods"] = [
		{"duration_hours": 6, "period_start_utc": "2026-10-20T00:00:00Z", "period_end_utc": "2026-10-20T06:00:00Z", "precipitation_amount_mm": 12.0, "precipitation_probability": 0.2},
		{"duration_hours": 1, "period_start_utc": "2026-10-20T00:00:00Z", "period_end_utc": "2026-10-20T01:00:00Z", "precipitation_probability": 0.95},
		{"duration_hours": 1, "period_start_utc": "2026-10-20T05:00:00Z", "period_end_utc": "2026-10-20T06:00:00Z", "precipitation_probability": 0.95},
	]
	var finish := _sample("2026-10-20T06:00:00Z", 5.0, 180.0)
	var document := _document([base, finish])
	var stats := ANALYSIS.analyze_forecast(document, "2026-10-20T00:00:00Z", "2026-10-20T06:00:00Z")
	_expect(bool(stats.get("ok", false)), "overlapping precipitation periods are analyzable")
	if not bool(stats.get("ok", false)):
		return
	var metrics: Dictionary = stats["metrics"]
	_expect(absf(float(metrics["expected_precipitation_total_mm"]) - 12.0) < 0.001, "amount integration uses the shortest active window that actually contains an amount")
	_expect(absf(float(metrics["precipitation_amount_coverage_fraction"]) - 1.0) < 0.001, "a shorter probability-only window does not hide a coarser amount forecast")
	_expect(absf(float(metrics["precipitation_signal_share"]) - 1.0) < 0.001, "explicit amount evidence stays distinct from probability-only evidence")
	var probability_document := _hourly_weather_document("probability", -1)
	_expect(ANALYSIS.precipitation_rate_for_document(probability_document, float(CODEC.parse_utc_timestamp_to_unix("2026-10-20T00:30:00Z"))) == null, "probability-only forecasts are never converted to rainfall amount")


func _test_symbol_window_resolution_and_boundaries() -> void:
	var document := _hourly_weather_document("clear", -1)
	var first: Dictionary = document["timeseries"][0]
	first["weather_symbol_periods"].append({
		"duration_hours": 6,
		"period_start_utc": "2026-10-20T00:00:00Z",
		"period_end_utc": "2026-10-20T06:00:00Z",
		"symbol_code": "rain",
		"source_period_key": "next_6_hours",
		"source_field": "summary.symbol_code",
	})
	document["timeseries"][1].erase("weather_symbol_periods")
	var value_at_start: Dictionary = ANALYSIS.sample_forecast_at_utc(document, "2026-10-20T00:00:00Z")
	var value_mid: Dictionary = ANALYSIS.sample_forecast_at_utc(document, "2026-10-20T00:30:00Z")
	var value_at_one_hour: Dictionary = ANALYSIS.sample_forecast_at_utc(document, "2026-10-20T01:00:00Z")
	_expect(value_at_start.get("weather_symbol") == "clearsky_day", "overlapping weather symbols prefer the active one-hour window")
	_expect(value_mid.get("weather_symbol") == "clearsky_day", "shortest active window governs overlapping symbol time")
	_expect(value_at_one_hour.get("weather_symbol") == "rain", "when the one-hour window ends, the still-active six-hour symbol takes over")
	_expect(value_at_one_hour.get("weather_symbol_window", {}).get("source_period_key") == "next_6_hours", "selected symbol keeps its source-period key")


func _test_persistent_rain_and_short_shower() -> void:
	var rain_document := _hourly_weather_document("rain", -1)
	for cycles in [12, 24]:
		var rain_timeline := CORE.generate_timeline(_timeline_request(rain_document, cycles, 311))
		_expect(bool(rain_timeline.get("ok", false)), "%d-cycle persistent-rain timeline generates" % cycles)
		if bool(rain_timeline.get("ok", false)):
			var forecast_stats := ANALYSIS.analyze_forecast(rain_document, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z")
			var generated_stats := ANALYSIS.analyze_timeline(rain_timeline["timeline"], rain_document)
			_expect(absf(float(forecast_stats["metrics"]["explicit_precipitation_day_fraction"]) - 1.0) < 0.001, "forecast explicit-rain duration is measured as a full day")
			_expect(absf(float(generated_stats["metrics"]["explicit_precipitation_day_fraction"]) - 1.0) < 0.001, "%d-cycle generated weather preserves the full-day rain share" % cycles)
			_expect(absf(float(generated_stats["metrics"]["max_continuous_precipitation_signal_hours"]) - 24.0) < 0.001, "%d-cycle rain duration does not flicker at cycle boundaries" % cycles)
	var shower_document := _hourly_weather_document("shower", 10)
	var shower_forecast := ANALYSIS.analyze_forecast(shower_document, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z")
	var shower_timeline := CORE.generate_timeline(_timeline_request(shower_document, 24, 312))
	var shower_generated := ANALYSIS.analyze_timeline(shower_timeline["timeline"], shower_document) if bool(shower_timeline.get("ok", false)) else {}
	_expect(absf(float(shower_forecast.get("metrics", {}).get("explicit_precipitation_day_fraction", -1.0)) - (1.0 / 24.0)) < 0.001, "a one-hour real shower occupies only one forecast hour")
	_expect(absf(float(shower_generated.get("metrics", {}).get("explicit_precipitation_day_fraction", -1.0)) - (1.0 / 24.0)) < 0.001, "generated weather does not extend a one-hour shower beyond its explicit boundary")
	if bool(shower_timeline.get("ok", false)):
		var before: Dictionary = CORE.sample_weather(shower_timeline["timeline"], {"elapsed_cycles": 10.0 - 0.0001})["state"]
		var at_start: Dictionary = CORE.sample_weather(shower_timeline["timeline"], {"elapsed_cycles": 10.0})["state"]
		var at_end: Dictionary = CORE.sample_weather(shower_timeline["timeline"], {"elapsed_cycles": 11.0})["state"]
		_expect(before.get("precipitation_state", "none") != "explicit", "rain does not smear backward before its start boundary")
		_expect(at_start.get("precipitation_state", "") == "explicit", "rain starts at the forecast window start")
		_expect(at_end.get("precipitation_state", "none") != "explicit", "rain stops at the half-open forecast window end")


func _test_cross_midnight_precipitation_continuity() -> void:
	var samples: Array[Dictionary] = []
	var start_unix := CODEC.parse_utc_timestamp_to_unix("2026-10-20T00:00:00Z")
	for hour in range(49):
		var timestamp := CODEC._utc_iso_from_unix(start_unix + hour * 3600)
		var wet := hour == 23 or hour == 24
		var sample := {"valid_time_utc": timestamp, "wind_speed_mps": 5.0, "wind_from_direction_deg": 270.0, "cloud_fraction": 0.9 if wet else 0.2, "air_temperature_c": 10.0, "air_pressure_hpa": 1012.0}
		if hour < 48:
			var end := CODEC._utc_iso_from_unix(start_unix + (hour + 1) * 3600)
			sample["weather_symbol_periods"] = [{"duration_hours": 1, "period_start_utc": timestamp, "period_end_utc": end, "symbol_code": "rain" if wet else "clearsky_day", "source_period_key": "next_1_hours", "source_field": "summary.symbol_code"}]
			sample["precipitation_periods"] = [{"duration_hours": 1, "period_start_utc": timestamp, "period_end_utc": end, "precipitation_amount_mm": 0.4 if wet else 0.0, "precipitation_probability": 0.8 if wet else 0.05, "source_period_key": "next_1_hours", "source_field": "details.precipitation_amount/probability", "source_fields": ["details.precipitation_amount", "details.probability_of_precipitation"]}]
		samples.append(sample)
	var document := _document(samples)
	document["schema_version"] = 2
	document["valid_until_utc"] = "2026-10-22T00:00:00Z"
	var request := _timeline_request_range(document, 24, 314, "2026-10-20T00:00:00Z", "2026-10-22T00:00:00Z")
	var generated := CORE.generate_timeline(request)
	_expect(bool(generated.get("ok", false)), "cross-midnight precipitation timeline generates")
	if not bool(generated.get("ok", false)):
		return
	var timeline: Dictionary = generated["timeline"]
	var before_midnight: Dictionary = CORE.sample_weather(timeline, {"elapsed_cycles": 23.5})["state"]
	var after_midnight: Dictionary = CORE.sample_weather(timeline, {"elapsed_cycles": 24.5})["state"]
	var after_shower: Dictionary = CORE.sample_weather(timeline, {"elapsed_cycles": 25.0})["state"]
	_expect(before_midnight.get("precipitation_state") == "explicit" and after_midnight.get("precipitation_state") == "explicit", "continuous rain windows stay explicit across UTC midnight")
	_expect(after_shower.get("precipitation_state", "none") != "explicit", "cross-midnight rain ends at the next explicit forecast boundary")
	var stats := ANALYSIS.analyze_timeline(timeline, document)
	_expect(absf(float(stats.get("metrics", {}).get("max_continuous_precipitation_signal_hours", 0.0)) - 2.0) < 0.001, "continuous precipitation statistics join adjacent windows across midnight")


func _test_probability_only_and_missing_coverage() -> void:
	var possible_document := _hourly_weather_document("probability", -1)
	var possible_stats := ANALYSIS.analyze_forecast(possible_document, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z")
	var possible_timeline := CORE.generate_timeline(_timeline_request(possible_document, 24, 313))
	_expect(bool(possible_timeline.get("ok", false)), "probability-only forecast timeline generates")
	_expect(possible_stats.get("metrics", {}).get("expected_precipitation_total_mm") == null, "probability-only forecast has no fabricated precipitation amount")
	_expect(absf(float(possible_stats.get("metrics", {}).get("possible_precipitation_day_fraction", 0.0)) - 1.0) < 0.001, "high precipitation probability remains possible, not explicit rain")
	_expect(possible_stats.get("metrics", {}).get("precipitation_evidence_coverage_status") == "complete", "probability-only coverage is marked complete without claiming rain occurred")
	if bool(possible_timeline.get("ok", false)):
		var sample: Dictionary = CORE.sample_weather(possible_timeline["timeline"], {"elapsed_cycles": 3.5})["state"]
		_expect(sample.get("precipitation_state") == "possible" and not sample.has("precipitation_intensity_mm_per_hour"), "probability-only generated state remains possible without an amount field")
	var sparse_document := _hourly_weather_document("clear", -1)
	for sample in sparse_document["timeseries"]:
		sample.erase("precipitation_periods")
		sample.erase("weather_symbol_periods")
	var sparse_sample: Dictionary = sparse_document["timeseries"][8]
	var start := str(sparse_sample["valid_time_utc"])
	var start_unix := CODEC.parse_utc_timestamp_to_unix(start)
	sparse_sample["weather_symbol_periods"] = [{"duration_hours": 1, "period_start_utc": start, "period_end_utc": CODEC._utc_iso_from_unix(start_unix + 3600), "symbol_code": "rain", "source_period_key": "next_1_hours", "source_field": "summary.symbol_code"}]
	sparse_sample["precipitation_periods"] = [{"duration_hours": 1, "period_start_utc": start, "period_end_utc": CODEC._utc_iso_from_unix(start_unix + 3600), "precipitation_amount_mm": 0.2, "source_period_key": "next_1_hours", "source_field": "details.precipitation_amount/probability", "source_fields": ["details.precipitation_amount"]}]
	var sparse_stats := ANALYSIS.analyze_forecast(sparse_document, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z")
	_expect(absf(float(sparse_stats.get("metrics", {}).get("precipitation_evidence_coverage_fraction", 1.0)) - (1.0 / 24.0)) < 0.001, "precipitation evidence coverage reports only the known one-hour interval")
	_expect(absf(float(sparse_stats.get("metrics", {}).get("explicit_precipitation_day_fraction", 0.0)) - (1.0 / 24.0)) < 0.001, "uncovered hours are not inferred as rain or dry time")
	_expect(sparse_stats.get("metrics", {}).get("precipitation_evidence_coverage_status") == "partial", "limited precip window coverage is visibly marked partial")
	var missing_precip := _hourly_weather_document("clear", -1)
	for sample in missing_precip["timeseries"]:
		sample.erase("precipitation_periods")
		sample.erase("weather_symbol_periods")
	var missing_stats := ANALYSIS.analyze_forecast(missing_precip, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z")
	_expect(missing_stats.get("metrics", {}).get("explicit_precipitation_time_share_fraction") == null and float(missing_stats.get("metrics", {}).get("precipitation_evidence_coverage_fraction", 1.0)) == 0.0, "missing precipitation evidence is N/A rather than treated as a rain-free day")
	_expect(missing_stats.get("metrics", {}).get("precipitation_evidence_coverage_status") == "unavailable", "absent precipitation windows are marked unavailable")


func _test_legacy_schema_migration() -> void:
	var legacy := _document([_sample("2026-10-20T00:00:00Z", 4.0, 250.0), _sample("2026-10-20T01:00:00Z", 4.0, 250.0)])
	legacy["schema_version"] = 1
	var upgraded := CODEC.upgrade_standardized_document(legacy)
	_expect(bool(upgraded.get("ok", false)) and int(upgraded.get("data", {}).get("schema_version", 0)) == CODEC.STANDARD_SCHEMA_VERSION, "legacy standardized data migrates to the current schema")
	if bool(upgraded.get("ok", false)):
		var migrated_sample: Dictionary = upgraded["data"]["timeseries"][0]
		_expect(migrated_sample.get("legacy_weather_symbol_temporal_semantics") == "unknown_window_not_used_for_duration", "legacy point symbols remain display-only because duration is unknowable")
		_expect(migrated_sample.get("weather_symbol_periods", []).is_empty(), "migration never fabricates a symbol time window")


func _test_12_24_day_statistics_and_export() -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_PATH))
	var generated_timelines: Array[Dictionary] = []
	for cycles in [12, 24]:
		var request := {
			"schema_version": 1,
			"request_id": "analysis-%d" % cycles,
			"region_id": "oresund",
			"requested_start_utc": "2026-10-20T00:00:00Z",
			"requested_end_utc": "2026-10-21T00:00:00Z",
			"generated_at_utc": "2026-10-20T00:00:00Z",
			"simulation_seed": 55,
			"cycles_per_real_day": cycles,
			"resolution_per_cycle": 4,
			"forecast_quality": "fresh",
			"forecast_documents": [fixture],
			"simulation_anchor": {
				"day_cycle_index": 10,
				"cycle_seconds": 0.0,
				"authoritative_timestamp_utc": "2026-10-20T00:00:00Z",
				"time_scale": float(cycles),
				"paused": false,
				"authority_session_id": "analysis-test",
				"authority_snapshot_sequence": 1,
			},
		}
		var result := CORE.generate_timeline(request)
		_expect(bool(result.get("ok", false)), "%d-cycle test timeline generates" % cycles)
		if not bool(result.get("ok", false)):
			continue
		var timeline: Dictionary = result["timeline"]
		generated_timelines.append(timeline)
		_expect(timeline["keyframes"].size() == cycles * 4 + 1, "%d-cycle keyframe count matches configured resolution" % cycles)
		var generated_stats := ANALYSIS.analyze_timeline(timeline, fixture)
		_expect(bool(generated_stats.get("ok", false)), "%d-cycle generated weather statistics are available" % cycles)
		if bool(generated_stats.get("ok", false)):
			var shares: Dictionary = generated_stats["metrics"].get("weather_type_share_percent", {})
			var share_sum := 0.0
			for share in shares.values():
				share_sum += float(share)
			_expect(absf(share_sum - 100.0) < 0.01, "%d-cycle type shares sum to 100%% of covered time" % cycles)
	if generated_timelines.size() == 2:
		var forecast_stats := ANALYSIS.analyze_forecast(fixture, "2026-10-20T00:00:00Z", "2026-10-21T00:00:00Z")
		var game_stats := ANALYSIS.analyze_timeline(generated_timelines[1], fixture)
		var report := ANALYSIS.build_quality_report(fixture, generated_timelines[1], forecast_stats, game_stats)
		var report_copy: Variant = JSON.parse_string(JSON.stringify(report))
		_expect(report_copy is Dictionary and report_copy.get("schema_version") == 2, "quality report JSON round-trips with a stable schema")
		_expect(report.get("quality_diagnostics", {}).has("forecast_missing_field_fraction"), "quality report exposes missing-field coverage")
		_expect(report.get("quality_diagnostics", {}).get("unsupported", []).size() > 0, "undefined climate thresholds remain explicitly unsupported")


func _test_direction_chart_unwrap() -> void:
	var lab = LAB_SCRIPT.new()
	var points: Array[Dictionary] = [
		{"cycle": 0.0, "value": 359.0},
		{"cycle": 1.0, "value": 1.0},
		{"cycle": 2.0, "value": 3.0},
	]
	var unwrapped: Array = lab._unwrap_points(points)
	_expect(absf(float(unwrapped[1]["value"]) - 361.0) < 0.001, "wind direction plot unwraps 359° to 1° through north")
	_expect(absf(float(unwrapped[2]["value"]) - 363.0) < 0.001, "unwrapped bearing remains continuous after crossing north")
	lab.free()


func _test_analysis_source_is_independent() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/weather_data/weather_simulation_analysis.gd")
	_expect(source.contains("extends RefCounted") and not source.contains("HTTPRequest") and not source.contains("SceneTree"), "analysis module is independent of scene and network APIs")
	var lab_source := FileAccess.get_file_as_string("res://scripts/weather_simulation_lab.gd")
	_expect(not lab_source.contains("HTTPRequest") and not lab_source.contains("WeatherDataProvider.new"), "Lab never starts its own online request")


func _document(samples: Array[Dictionary]) -> Dictionary:
	return {
		"schema_version": 1,
		"provider_id": "offline_weather_simulation_fixture",
		"region_id": "oresund",
		"latitude": 55.64,
		"longitude": 12.78,
		"forecast_issued_at_utc": "2026-10-19T18:00:00Z",
		"retrieved_at_utc": "2026-10-19T18:05:00Z",
		"valid_from_utc": str(samples.front()["valid_time_utc"]),
		"valid_until_utc": str(samples.back()["valid_time_utc"]),
		"timeseries": samples,
		"source_metadata": {"fixture": true, "attribution": "Synthetic offline test values"},
	}


func _hourly_weather_document(kind: String, shower_hour: int) -> Dictionary:
	var samples: Array[Dictionary] = []
	var start_unix := CODEC.parse_utc_timestamp_to_unix("2026-10-20T00:00:00Z")
	for hour in range(25):
		var timestamp := CODEC._utc_iso_from_unix(start_unix + hour * 3600)
		var wet := kind == "rain" or (kind == "shower" and hour == shower_hour)
		var symbol := "rain" if wet else ("clearsky_day" if kind == "clear" else "cloudy")
		var sample := {"valid_time_utc": timestamp, "wind_speed_mps": 5.0, "wind_from_direction_deg": 270.0, "cloud_fraction": 0.88 if wet else (0.05 if kind == "clear" else 0.65), "air_temperature_c": 10.0, "air_pressure_hpa": 1012.0}
		if hour < 24:
			var end := CODEC._utc_iso_from_unix(start_unix + (hour + 1) * 3600)
			sample["weather_symbol_periods"] = [{"duration_hours": 1, "period_start_utc": timestamp, "period_end_utc": end, "symbol_code": symbol, "source_period_key": "next_1_hours", "source_field": "summary.symbol_code"}]
			if kind == "probability":
				sample["precipitation_periods"] = [{"duration_hours": 1, "period_start_utc": timestamp, "period_end_utc": end, "precipitation_probability": 0.9, "source_period_key": "next_1_hours", "source_field": "details.precipitation_amount/probability", "source_fields": ["details.probability_of_precipitation"]}]
			else:
				sample["precipitation_periods"] = [{"duration_hours": 1, "period_start_utc": timestamp, "period_end_utc": end, "precipitation_amount_mm": 0.4 if wet else 0.0, "precipitation_probability": 0.8 if wet else 0.05, "source_period_key": "next_1_hours", "source_field": "details.precipitation_amount/probability", "source_fields": ["details.precipitation_amount", "details.probability_of_precipitation"]}]
		samples.append(sample)
	var document := _document(samples)
	document["schema_version"] = 2
	document["valid_until_utc"] = "2026-10-21T00:00:00Z"
	return document


func _timeline_request(document: Dictionary, cycles: int, seed: int) -> Dictionary:
	return {
		"schema_version": 1,
		"request_id": "precip-%d-%d" % [cycles, seed],
		"region_id": "oresund",
		"requested_start_utc": "2026-10-20T00:00:00Z",
		"requested_end_utc": "2026-10-21T00:00:00Z",
		"generated_at_utc": "2026-10-20T00:00:00Z",
		"simulation_seed": seed,
		"cycles_per_real_day": cycles,
		"resolution_per_cycle": 4,
		"forecast_quality": "fresh",
		"forecast_documents": [document],
		"simulation_anchor": {"day_cycle_index": 0, "cycle_seconds": 0.0, "authoritative_timestamp_utc": "2026-10-20T00:00:00Z", "time_scale": float(cycles), "paused": false, "authority_session_id": "precip-test", "authority_snapshot_sequence": 1},
	}


func _timeline_request_range(document: Dictionary, cycles: int, seed: int, start_utc: String, end_utc: String) -> Dictionary:
	var request := _timeline_request(document, cycles, seed)
	request["requested_start_utc"] = start_utc
	request["requested_end_utc"] = end_utc
	request["generated_at_utc"] = start_utc
	request["simulation_anchor"]["authoritative_timestamp_utc"] = start_utc
	request["simulation_anchor"]["time_scale"] = float(cycles)
	return request


func _sample(timestamp: String, speed: float, direction: float) -> Dictionary:
	return {
		"valid_time_utc": timestamp,
		"wind_speed_mps": speed,
		"wind_from_direction_deg": direction,
		"cloud_fraction": 0.8,
		"air_temperature_c": 10.0,
		"air_pressure_hpa": 1012.0,
		"weather_symbol": "cloudy",
	}


func _angle_distance(a: float, b: float) -> float:
	return absf(fposmod(a - b + 180.0, 360.0) - 180.0)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[Analysis #%d] %s" % [_checks, message])
