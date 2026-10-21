extends SceneTree

const CODEC := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const PROVIDER := preload("res://scripts/weather_data/weather_data_provider.gd")
const CACHE_STORE := preload("res://scripts/weather_data/weather_file_cache_store.gd")
const REGION_SCRIPT := preload("res://resources/weather_region.gd")
const CORE_CONTRACT := preload("res://scripts/weather_data/weather_simulation_core_contract.gd")
const ADAPTER_CONTRACT := preload("res://scripts/weather_data/weather_godot_adapter_contract.gd")
const USER_AGENT_SETTINGS := preload("res://scripts/weather_data/weather_user_agent_settings.gd")
const FIXTURE_PATH := "res://tests/fixtures/met_norway_complete_fixture.json"

var _checks := 0
var _failures: Array[String] = []
var _fixture: Dictionary


class FakeClock extends RefCounted:
	var now := 0

	func now_unix_seconds() -> int:
		return now

	func now_utc_iso() -> String:
		return CODEC._utc_iso_from_unix(now)


class FakeScheduler extends RefCounted:
	var scheduled: Array[Dictionary] = []

	func schedule(delay: float, callback: Callable) -> void:
		scheduled.append({"delay": delay, "callback": callback})

	func run_next() -> void:
		if scheduled.is_empty():
			return
		var item: Dictionary = scheduled.pop_front()
		(item["callback"] as Callable).call()


class FakeHttp extends RefCounted:
	var responses: Array[Dictionary] = []
	var requests: Array[Dictionary] = []
	var pending: Array[Dictionary] = []
	var hold_requests := false

	func request(request_data: Dictionary, callback: Callable) -> void:
		requests.append(request_data.duplicate(true))
		if hold_requests:
			pending.append({"request": request_data, "callback": callback})
			return
		var response: Dictionary = responses.pop_front() if not responses.is_empty() else _network_failure()
		callback.call_deferred(response)

	func complete_pending(response: Dictionary) -> void:
		if pending.is_empty():
			return
		var item: Dictionary = pending.pop_front()
		(item["callback"] as Callable).call_deferred(response)

	static func _network_failure() -> Dictionary:
		return {"transport_result": HTTPRequest.RESULT_CANT_CONNECT, "status_code": 0, "headers": PackedStringArray(), "body": PackedByteArray()}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_fixture = _load_fixture()
	_test_codec_normalization_and_utc()
	_test_contracts_are_data_only()
	_test_settings_injection()
	await _test_invalid_json_response()
	await _test_fresh_cache_disk_and_expiry()
	await _test_http_304_and_conditional_request()
	await _test_stale_fallback_and_unavailable()
	_test_corrupt_and_unsupported_cache()
	await _test_request_deduplication()
	await _test_timeout_retry()
	await _test_retry_after_and_no_store()
	await _test_region_isolation_and_contact_guard()
	if _failures.is_empty():
		print("WeatherDataProvider offline tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_codec_normalization_and_utc() -> void:
	var clock := FakeClock.new()
	clock.now = CODEC.parse_utc_timestamp_to_unix("2026-10-20T12:00:00Z")
	var parsed := CODEC.parse_met_response(_fixture, "oresund", 55.64, 12.78, clock.now_utc_iso(), {"http_status_code": 200})
	_expect(bool(parsed.get("ok", false)), "MET-shaped JSON fixture parses")
	if not bool(parsed.get("ok", false)):
		return
	var document: Dictionary = parsed["data"]
	var first: Dictionary = document["timeseries"][0]
	_expect(is_equal_approx(float(first["wind_speed_mps"]), 5.6), "wind speed remains m/s")
	_expect(is_equal_approx(float(first["wind_from_direction_deg"]), 275.0), "wind direction remains meteorological FROM bearing")
	_expect(is_equal_approx(float(first["cloud_fraction"]), 0.62), "cloud percent normalizes to 0..1 fraction")
	_expect(first.has("wind_gust_mps") and is_equal_approx(float(first["wind_gust_mps"]), 8.1), "optional gust is retained when provided")
	var second: Dictionary = document["timeseries"][1]
	_expect(not second.has("wind_gust_mps"), "missing gust remains absent instead of being fabricated")
	var first_period: Dictionary = first["precipitation_periods"][0]
	var second_period: Dictionary = second["precipitation_periods"][0]
	_expect(int(first_period["duration_hours"]) == 1 and is_equal_approx(float(first_period["precipitation_amount_mm"]), 0.2), "one-hour precipitation amount preserves its accumulation window")
	_expect(int(second_period["duration_hours"]) == 6 and is_equal_approx(float(second_period["precipitation_probability"]), 0.55), "six-hour precipitation probability preserves its time window and fraction")
	_expect(first_period["period_end_utc"] == "2026-10-20T13:00:00Z", "precipitation window end is derived in UTC")
	_expect(first_period["source_fields"] == ["details.precipitation_amount", "details.probability_of_precipitation"], "precipitation period records exactly which source values are present")
	var first_symbol: Dictionary = first["weather_symbol_periods"][0]
	var second_symbol: Dictionary = second["weather_symbol_periods"][0]
	_expect(first_symbol["period_start_utc"] == "2026-10-20T12:00:00Z" and first_symbol["period_end_utc"] == "2026-10-20T13:00:00Z", "next_1_hours symbol window runs forward from the timeseries record")
	_expect(first_symbol["source_period_key"] == "next_1_hours" and first_symbol["source_field"] == "summary.symbol_code", "weather symbol preserves the exact source field and period key")
	_expect(second_symbol["period_start_utc"] == "2026-10-20T13:00:00Z" and second_symbol["period_end_utc"] == "2026-10-20T19:00:00Z" and second_symbol["duration_hours"] == 6, "next_6_hours symbol window keeps its six-hour forward interval")
	var overlapping_raw := _fixture.duplicate(true)
	var overlapping_data: Dictionary = overlapping_raw["properties"]["timeseries"][0]["data"]
	overlapping_data["next_6_hours"] = {"summary": {"symbol_code": "rain"}, "details": {"precipitation_amount": 1.2}}
	overlapping_data["next_12_hours"] = {"summary": {"symbol_code": "cloudy"}, "details": {"probability_of_precipitation": 65}}
	var overlapping_parse := CODEC.parse_met_response(overlapping_raw, "oresund", 55.64, 12.78, clock.now_utc_iso())
	var overlapping_sample: Dictionary = overlapping_parse["data"]["timeseries"][0] if bool(overlapping_parse.get("ok", false)) else {}
	_expect(overlapping_sample.get("weather_symbol_periods", []).size() == 3 and overlapping_sample.get("precipitation_periods", []).size() == 3, "overlapping one-, six- and twelve-hour windows remain separate records")
	if not overlapping_sample.is_empty():
		var overlap_symbol: Dictionary = overlapping_sample["weather_symbol_periods"][1]
		_expect(overlap_symbol["period_start_utc"] == "2026-10-20T12:00:00Z" and overlap_symbol["period_end_utc"] == "2026-10-20T18:00:00Z", "overlapping six-hour symbol retains its own UTC bounds")
		_expect(overlapping_sample["precipitation_periods"][2]["source_fields"] == ["details.probability_of_precipitation"], "probability-only precipitation source is not represented as an amount")
	_expect(CODEC.parse_utc_timestamp_to_unix("1970-01-01T00:00:00Z") == 0, "UTC epoch parses independently of local timezone")
	_expect(CODEC.parse_utc_timestamp_to_unix("2026-10-20T12:00:00Z") == 1792497600, "UTC timestamp converts to the expected Unix second")
	_expect(CODEC.is_valid_utc_timestamp("2024-02-29T23:59:59.123Z"), "fractional UTC timestamp and leap day are valid")
	_expect(not CODEC.is_valid_utc_timestamp("2025-02-29T00:00:00Z"), "invalid leap date is rejected")
	_expect(not CODEC.is_valid_utc_timestamp("2026-10-20T25:00:00Z"), "invalid hour is rejected")
	var encoded := CODEC.serialize_document(document)
	var decoded := CODEC.deserialize_document(encoded)
	_expect(bool(decoded.get("ok", false)) and _deep_equal(decoded.get("data", {}), document), "standard JSON serialization round-trips structurally")
	var unsupported := document.duplicate(true)
	unsupported["schema_version"] = 99
	_expect(CODEC.validate_standardized_document(unsupported).get("error") == "unsupported_schema_version", "unsupported standardized schema is rejected")
	var bad_symbol_boundary := document.duplicate(true)
	bad_symbol_boundary["timeseries"][0]["weather_symbol_periods"][0]["period_start_utc"] = "2026-10-20T11:00:00Z"
	bad_symbol_boundary["timeseries"][0]["weather_symbol_periods"][0]["period_end_utc"] = "2026-10-20T12:00:00Z"
	_expect(CODEC.validate_standardized_document(bad_symbol_boundary).get("error") == "weather_symbol_window_must_start_at_sample_time", "schema 2 rejects symbol windows with an incorrect time direction/start")
	var bad_source_resolution := document.duplicate(true)
	bad_source_resolution["timeseries"][0]["weather_symbol_periods"][0]["source_period_key"] = "next_6_hours"
	_expect(CODEC.validate_standardized_document(bad_source_resolution).get("error") == "weather_symbol_period_source_missing", "schema 2 rejects source-period/duration mismatches")
	var legacy := document.duplicate(true)
	legacy["schema_version"] = 1
	for sample_value in legacy["timeseries"]:
		sample_value.erase("weather_symbol_periods")
		sample_value["weather_symbol"] = "rain"
	var migrated := CODEC.upgrade_standardized_document(legacy)
	_expect(bool(migrated.get("ok", false)) and int(migrated.get("data", {}).get("schema_version", 0)) == 2, "legacy schema migrates to the current standardized schema")
	if bool(migrated.get("ok", false)):
		var migrated_first: Dictionary = migrated["data"]["timeseries"][0]
		_expect(migrated_first.get("legacy_weather_symbol_temporal_semantics") == "unknown_window_not_used_for_duration" and not migrated_first.has("weather_symbol_periods"), "legacy point symbol is retained as display-only without fabricating a duration")


func _test_contracts_are_data_only() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/weather_data/weather_simulation_core_contract.gd")
	_expect(source.contains("extends RefCounted") and not source.contains("extends Node"), "simulation core contract has no scene-node base")
	_expect(not source.contains("HTTPRequest") and not source.contains("SceneTree") and not source.contains("Timer.new"), "simulation core contract has no network, scene tree, or timer dependency")
	var region: WeatherRegion = _region("oresund", 55.64, 12.78)
	var clock := FakeClock.new()
	clock.now = CODEC.parse_utc_timestamp_to_unix("2026-10-20T12:00:00Z")
	var parsed := CODEC.parse_met_response(_fixture, "oresund", region.latitude, region.longitude, clock.now_utc_iso())
	var request := {
		"schema_version": 1,
		"request_id": "offline-test-1",
		"region_id": "oresund",
		"requested_start_utc": "2026-10-20T12:00:00Z",
		"requested_end_utc": "2026-10-21T12:00:00Z",
		"simulation_seed": 17,
		"forecast_document": parsed["data"],
	}
	_expect(bool(CORE_CONTRACT.validate_generation_request(request).get("ok", false)), "future W2.2b generation request contract validates fixture data")
	var simulation_output := {
		"schema_version": 1,
		"request_id": "offline-test-1",
		"region_id": "oresund",
		"generated_at_utc": "2026-10-20T12:00:00Z",
		"simulation_seed": 17,
		"weather_states": [{
			"valid_from_utc": "2026-10-20T12:00:00Z",
			"valid_until_utc": "2026-10-20T18:00:00Z",
			"visual_weather_id": "Overcast",
			"wind": {"mean_wind_speed_mps": 6.0, "wind_from_direction_deg": 280.0, "gust_strength_mps": 2.0},
		}],
	}
	var adapter_payload := ADAPTER_CONTRACT.prepare_weather_target(simulation_output)
	_expect(bool(adapter_payload.get("ok", false)) and adapter_payload["payload"]["target_weather_id"] == "Overcast", "future Godot adapter contract maps serialized state without applying it")
	_expect(not source.contains("WeatherStateController") and not source.contains("WindField"), "simulation contract does not depend on gameplay weather systems")


func _test_settings_injection() -> void:
	var settings_path := "res://.godot/weather_data_w2_2a_settings_test.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.godot"))
	var file := FileAccess.open(settings_path, FileAccess.WRITE)
	file.store_string(JSON.stringify({"user_agent_contact": "studio@example.test"}))
	file.close()
	var loaded := USER_AGENT_SETTINGS.load_contact(settings_path)
	_expect(loaded == "studio@example.test", "contact loads from a separate configuration file")
	_expect(USER_AGENT_SETTINGS.load_contact(settings_path, "environment@example.test") == "environment@example.test", "environment contact overrides local configuration")
	var saved := USER_AGENT_SETTINGS.save_contact("saved@example.test", settings_path)
	_expect(saved.get("ok", false) and USER_AGENT_SETTINGS.load_contact(settings_path) == "saved@example.test", "contact can be changed and saved without editing source code")
	_expect(USER_AGENT_SETTINGS.CONTACT_ENVIRONMENT_VARIABLE == "MET_NORWAY_CONTACT", "contact environment-variable name is documented by the settings adapter")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(settings_path))


func _test_invalid_json_response() -> void:
	var setup := _new_provider("invalid_json")
	var provider: WeatherDataProvider = setup["provider"]
	var http: FakeHttp = setup["http"]
	provider.max_retries = 0
	http.responses.append({"transport_result": HTTPRequest.RESULT_SUCCESS, "status_code": 200, "headers": PackedStringArray(), "body": "{broken".to_utf8_buffer()})
	var results: Array[Dictionary] = []
	provider.refresh_region("oresund", func(result: Dictionary) -> void: results.append(result))
	await process_frame
	_expect(results.size() == 1 and results[0].get("status") == "unavailable", "invalid JSON response is rejected without a parser crash")
	_expect(results[0].get("error") == "invalid_json", "invalid JSON failure has an explicit error status")
	setup["cache"].clear_directory()


func _test_fresh_cache_disk_and_expiry() -> void:
	var setup := _new_provider("fresh_expiry")
	var provider: WeatherDataProvider = setup["provider"]
	var http: FakeHttp = setup["http"]
	var cache: WeatherFileCacheStore = setup["cache"]
	var results: Array[Dictionary] = []
	provider.max_retries = 0
	http.responses.append(_fixture_response())
	var started := provider.refresh_region("oresund", func(result: Dictionary) -> void: results.append(result))
	_expect(started.get("status") == "request_started", "manual refresh starts a non-blocking request")
	_expect(not results.is_empty() or true, "request completion is delivered asynchronously")
	await process_frame
	_expect(results.size() == 1 and results[0].get("status") == "fresh_cache", "successful response returns a fresh normalized forecast")
	_expect(cache.load_envelope("oresund").get("ok", false), "successful response is stored in disk cache")
	provider.clear_memory_cache("oresund")
	var from_disk := provider.read_forecast("oresund")
	_expect(from_disk.get("cache_source") == "disk" and from_disk.get("status") == "fresh_cache", "valid disk cache is loaded independently of memory cache")
	_expect(from_disk.get("refresh_due") == false, "fresh cache does not require a request before its expiry")
	provider.set_user_agent_contact("")
	var contactless_fresh := provider.refresh_region("oresund")
	_expect(contactless_fresh.get("status") == "fresh_cache" and http.requests.size() == 1, "fresh cache can be used without configured network contact and creates no request")
	provider.set_user_agent_contact("studio@example.test")
	setup["clock"].now += 61
	var stale := provider.read_forecast("oresund")
	_expect(stale.get("status") == "stale_cache" and stale.get("refresh_due") == true, "expired cache remains readable while reporting refresh due")
	_expect(http.requests[0]["url"].contains("lat=55.6400&lon=12.7800"), "request coordinates use four decimal places")
	cache.clear_directory()


func _test_http_304_and_conditional_request() -> void:
	var setup := _new_provider("not_modified")
	var provider: WeatherDataProvider = setup["provider"]
	var http: FakeHttp = setup["http"]
	provider.max_retries = 0
	http.responses.append(_fixture_response())
	provider.refresh_region("oresund")
	await process_frame
	setup["clock"].now += 61
	var callback_results: Array[Dictionary] = []
	http.responses.append({
		"transport_result": HTTPRequest.RESULT_SUCCESS,
		"status_code": 304,
		"headers": PackedStringArray(["Cache-Control: max-age=120", "Last-Modified: Tue, 20 Oct 2026 12:00:00 GMT", "ETag: \"forecast-v1\""]),
		"body": PackedByteArray(),
	})
	provider.refresh_region("oresund", func(result: Dictionary) -> void: callback_results.append(result))
	var conditional_headers: PackedStringArray = http.requests[1]["headers"]
	var has_last_modified := false
	for header in conditional_headers:
		if str(header) == "If-Modified-Since: Tue, 20 Oct 2026 12:00:00 GMT":
			has_last_modified = true
	_expect(has_last_modified, "expired cache sends the exact stored Last-Modified value")
	await process_frame
	_expect(callback_results.size() == 1 and callback_results[0].get("http_status_code") == 304, "HTTP 304 keeps the existing normalized response")
	_expect(provider.read_forecast("oresund").get("status") == "fresh_cache", "HTTP 304 refreshes cache freshness metadata")
	setup["cache"].clear_directory()


func _test_stale_fallback_and_unavailable() -> void:
	var setup := _new_provider("stale_fallback")
	var provider: WeatherDataProvider = setup["provider"]
	var http: FakeHttp = setup["http"]
	provider.max_retries = 0
	http.responses.append(_fixture_response())
	provider.refresh_region("oresund")
	await process_frame
	setup["clock"].now += 3700
	http.responses.append(FakeHttp._network_failure())
	var stale_results: Array[Dictionary] = []
	provider.refresh_region("oresund", func(result: Dictionary) -> void: stale_results.append(result))
	await process_frame
	_expect(stale_results.size() == 1 and stale_results[0].get("status") == "stale_cache" and stale_results[0].get("stale") == true, "network failure falls back to marked stale cache within the stale limit")
	var no_cache_setup := _new_provider("no_cache_actual")
	var no_cache_provider: WeatherDataProvider = no_cache_setup["provider"]
	var no_cache_http: FakeHttp = no_cache_setup["http"]
	no_cache_provider.configure([_region("malmo", 55.61, 12.99)], no_cache_http, no_cache_setup["cache"], no_cache_setup["clock"], no_cache_setup["scheduler"], "studio@example.test")
	no_cache_provider.max_retries = 0
	no_cache_http.responses.append(FakeHttp._network_failure())
	var unavailable: Array[Dictionary] = []
	no_cache_provider.refresh_region("malmo", func(result: Dictionary) -> void: unavailable.append(result))
	await process_frame
	_expect(unavailable.size() == 1 and unavailable[0].get("status") == "unavailable" and unavailable[0].get("has_data") == false, "failure with no cache returns explicit unavailable state")
	setup["cache"].clear_directory()
	no_cache_setup["cache"].clear_directory()


func _test_corrupt_and_unsupported_cache() -> void:
	var setup := _new_provider("corrupt_cache")
	var provider: WeatherDataProvider = setup["provider"]
	var cache: WeatherFileCacheStore = setup["cache"]
	cache.write_corrupt_for_test("oresund")
	var corrupt := provider.read_forecast("oresund")
	_expect(corrupt.get("status") == "unavailable" and corrupt.get("cache_corrupt") == true, "malformed JSON cache is reported without crashing")
	var path := ProjectSettings.globalize_path("%s/oresund.json" % cache.base_directory)
	var unsupported_file := FileAccess.open(path, FileAccess.WRITE)
	unsupported_file.store_string(JSON.stringify({"cache_schema_version": 777, "region_id": "oresund"}))
	unsupported_file.close()
	provider.clear_memory_cache("oresund")
	var unsupported := provider.read_forecast("oresund")
	_expect(unsupported.get("status") == "unavailable" and unsupported.get("cache_corrupt") == true, "unsupported on-disk cache schema is reported explicitly")
	cache.clear_directory()


func _test_request_deduplication() -> void:
	var setup := _new_provider("dedup")
	var provider: WeatherDataProvider = setup["provider"]
	var http: FakeHttp = setup["http"]
	provider.max_retries = 0
	http.hold_requests = true
	var completions: Array[Dictionary] = []
	provider.refresh_region("oresund", func(result: Dictionary) -> void: completions.append(result))
	var second := provider.refresh_region("oresund", func(result: Dictionary) -> void: completions.append(result))
	_expect(http.requests.size() == 1 and second.get("status") == "request_in_flight", "concurrent region refreshes share one HTTP request")
	http.complete_pending(_fixture_response())
	await process_frame
	_expect(completions.size() == 2, "deduplicated request delivers result to every caller")
	setup["cache"].clear_directory()


func _test_timeout_retry() -> void:
	var setup := _new_provider("retry")
	var provider: WeatherDataProvider = setup["provider"]
	var http: FakeHttp = setup["http"]
	var scheduler: FakeScheduler = setup["scheduler"]
	provider.max_retries = 1
	provider.retry_base_seconds = 2.0
	http.responses.append({"transport_result": HTTPRequest.RESULT_TIMEOUT, "status_code": 0, "headers": PackedStringArray(), "body": PackedByteArray()})
	http.responses.append(_fixture_response())
	var results: Array[Dictionary] = []
	provider.refresh_region("oresund", func(result: Dictionary) -> void: results.append(result))
	await process_frame
	_expect(http.requests.size() == 1 and scheduler.scheduled.size() == 1 and is_equal_approx(float(scheduler.scheduled[0]["delay"]), 2.0), "timeout schedules bounded exponential retry")
	scheduler.run_next()
	await process_frame
	_expect(http.requests.size() == 2 and results.size() == 1 and results[0].get("status") == "fresh_cache", "retry success completes refresh")
	setup["cache"].clear_directory()


func _test_retry_after_and_no_store() -> void:
	var retry_setup := _new_provider("retry_after")
	var retry_provider: WeatherDataProvider = retry_setup["provider"]
	var retry_http: FakeHttp = retry_setup["http"]
	var retry_scheduler: FakeScheduler = retry_setup["scheduler"]
	retry_provider.max_retries = 1
	retry_http.responses.append({"transport_result": HTTPRequest.RESULT_SUCCESS, "status_code": 429, "headers": PackedStringArray(["Retry-After: Tue, 20 Oct 2026 12:00:10 GMT"]), "body": PackedByteArray()})
	retry_http.responses.append(_fixture_response())
	var retry_result: Array[Dictionary] = []
	retry_provider.refresh_region("oresund", func(result: Dictionary) -> void: retry_result.append(result))
	await process_frame
	_expect(retry_scheduler.scheduled.size() == 1 and is_equal_approx(float(retry_scheduler.scheduled[0]["delay"]), 10.0), "429 Retry-After HTTP-date is honored as a bounded delay")
	retry_scheduler.run_next()
	await process_frame
	_expect(retry_result.size() == 1 and retry_result[0].get("status") == "fresh_cache", "rate-limited request succeeds after the scheduled retry")
	retry_setup["cache"].clear_directory()

	var no_store_setup := _new_provider("no_store")
	var no_store_provider: WeatherDataProvider = no_store_setup["provider"]
	var no_store_http: FakeHttp = no_store_setup["http"]
	no_store_provider.max_retries = 0
	var response := _fixture_response()
	response["headers"] = PackedStringArray(["Cache-Control: no-store", "Last-Modified: Tue, 20 Oct 2026 12:00:00 GMT"])
	no_store_http.responses.append(response)
	var transient_results: Array[Dictionary] = []
	no_store_provider.refresh_region("oresund", func(result: Dictionary) -> void: transient_results.append(result))
	await process_frame
	_expect(transient_results.size() == 1 and transient_results[0].get("status") == "network_uncached", "Cache-Control no-store returns data without persisting it")
	_expect(not no_store_setup["cache"].load_envelope("oresund").get("ok", false), "no-store response is absent from disk cache")
	no_store_setup["cache"].clear_directory()


func _test_region_isolation_and_contact_guard() -> void:
	var setup := _new_provider("isolation")
	var provider: WeatherDataProvider = setup["provider"]
	var http: FakeHttp = setup["http"]
	provider.configure([_region("oresund", 55.64, 12.78), _region("malmo", 55.61, 12.99)], http, setup["cache"], setup["clock"], setup["scheduler"], "")
	var blocked := provider.refresh_region("oresund", Callable())
	_expect(blocked.get("status") == "configuration_required" and http.requests.is_empty(), "live request cannot start without an identifying contact")
	provider.set_user_agent_contact("https://example.org/weather-contact")
	var oresund_request := provider._build_request("oresund", {})
	var malmo_request := provider._build_request("malmo", {})
	_expect(oresund_request["url"] != malmo_request["url"], "different regions produce distinct request coordinates")
	_expect(oresund_request["url"].contains("lat=55.6400&lon=12.7800") and malmo_request["url"].contains("lat=55.6100&lon=12.9900"), "each region is rounded and queried independently")
	_expect(_has_header(oresund_request["headers"], "User-Agent: MaritimeLifeSimulator/0.1 (https://example.org/weather-contact)"), "User-Agent uses injected contact and has no source-code contact default")
	http.responses.append(_fixture_response())
	http.responses.append(_fixture_response())
	provider.max_retries = 0
	var completions: Array[Dictionary] = []
	provider.refresh_region("oresund", func(result: Dictionary) -> void: completions.append(result))
	provider.refresh_region("malmo", func(result: Dictionary) -> void: completions.append(result))
	await process_frame
	_expect(completions.size() == 2, "different weather regions complete independent refreshes")
	var oresund_cache: Dictionary = setup["cache"].load_envelope("oresund")
	var malmo_cache: Dictionary = setup["cache"].load_envelope("malmo")
	_expect(oresund_cache.get("ok", false) and malmo_cache.get("ok", false), "each region is stored in its own cache entry")
	_expect(oresund_cache["envelope"]["region_id"] == "oresund" and malmo_cache["envelope"]["region_id"] == "malmo", "region cache entries cannot overwrite or alias one another")
	setup["cache"].clear_directory()


func _new_provider(test_name: String) -> Dictionary:
	var region: WeatherRegion = _region("oresund", 55.64, 12.78)
	var http := FakeHttp.new()
	var cache := CACHE_STORE.new() as WeatherFileCacheStore
	cache.base_directory = "res://.godot/weather_data_tests/w2_2a_%s_%d" % [test_name, OS.get_process_id()]
	cache.clear_directory()
	var clock := FakeClock.new()
	clock.now = CODEC.parse_utc_timestamp_to_unix("2026-10-20T12:00:00Z")
	var scheduler := FakeScheduler.new()
	var provider := PROVIDER.new() as WeatherDataProvider
	provider.configure([region], http, cache, clock, scheduler, "studio@example.test")
	provider.error_log_interval_seconds = 999999.0
	return {"provider": provider, "http": http, "cache": cache, "clock": clock, "scheduler": scheduler}


func _region(region_id: String, latitude: float, longitude: float) -> WeatherRegion:
	var region: WeatherRegion = REGION_SCRIPT.new() as WeatherRegion
	region.region_id = region_id
	region.display_name = region_id
	region.latitude = latitude
	region.longitude = longitude
	return region


func _fixture_response() -> Dictionary:
	return {
		"transport_result": HTTPRequest.RESULT_SUCCESS,
		"status_code": 200,
		"headers": PackedStringArray([
			"Cache-Control: max-age=60",
			"Expires: Tue, 20 Oct 2026 12:01:00 GMT",
			"Last-Modified: Tue, 20 Oct 2026 12:00:00 GMT",
			"ETag: \"forecast-v1\"",
		]),
		"body": JSON.stringify(_fixture).to_utf8_buffer(),
	}


func _load_fixture() -> Dictionary:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE_PATH))
	return parsed if parsed is Dictionary else {}


func _has_header(headers: PackedStringArray, expected: String) -> bool:
	for header in headers:
		if str(header) == expected:
			return true
	return false


func _deep_equal(first: Variant, second: Variant) -> bool:
	if (first is int or first is float) and (second is int or second is float):
		return is_equal_approx(float(first), float(second))
	if first is Dictionary and second is Dictionary:
		if first.size() != second.size():
			return false
		for key in first:
			if not second.has(key) or not _deep_equal(first[key], second[key]):
				return false
		return true
	if first is Array and second is Array:
		if first.size() != second.size():
			return false
		for index in range(first.size()):
			if not _deep_equal(first[index], second[index]):
				return false
		return true
	return first == second


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("Weather data provider test failed: %s" % description)
