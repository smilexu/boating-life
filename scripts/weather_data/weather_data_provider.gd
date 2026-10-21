extends RefCounted
class_name WeatherDataProvider

## Region forecast orchestration with injected network, storage, clock, and
## retry scheduling. No game weather, scene, boat, HUD, or WindField dependency.

const Codec := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const STANDARD_CACHE_SCHEMA_VERSION := 1
const DEFAULT_USER_AGENT_PRODUCT := "MaritimeLifeSimulator/0.1"

var regions: Dictionary = {}
var http_adapter: Object
var cache_store: Object
var clock: Object
var scheduler: Object
var user_agent_contact := ""
var user_agent_product := DEFAULT_USER_AGENT_PRODUCT
var request_timeout_seconds := 20.0
var max_retries := 3
var retry_base_seconds := 1.0
var retry_max_seconds := 20.0
var failure_cooldown_base_seconds := 30.0
var failure_cooldown_max_seconds := 900.0
var max_stale_seconds := 86400.0
var fallback_cache_ttl_seconds := 3600.0
var error_log_interval_seconds := 60.0

var _memory_cache: Dictionary = {}
var _inflight: Dictionary = {}
var _failure_state: Dictionary = {}
var _last_error_log_by_region: Dictionary = {}
var _cache_diagnostics: Dictionary = {}


func configure(
	region_catalog: Array,
	network_adapter: Object,
	disk_cache_store: Object,
	clock_adapter: Object,
	retry_scheduler: Object,
	contact: String = ""
) -> void:
	regions.clear()
	for region in region_catalog:
		if region is WeatherRegion and not region.region_id.is_empty():
			regions[region.region_id] = region
	http_adapter = network_adapter
	cache_store = disk_cache_store
	clock = clock_adapter
	scheduler = retry_scheduler
	user_agent_contact = contact.strip_edges()


func set_user_agent_contact(contact: String) -> void:
	user_agent_contact = contact.strip_edges()


## Reads current memory/disk data without starting a request. `refresh_due` is
## intentionally separate from cache availability so callers can display stale
## data immediately and schedule a refresh independently.
func read_forecast(region_id: String) -> Dictionary:
	if not regions.has(region_id):
		return _unavailable(region_id, "unknown_region")
	var loaded := _load_envelope(region_id)
	if not bool(loaded.get("ok", false)):
		return _unavailable(region_id, str(loaded.get("reason", "cache_miss")), bool(loaded.get("cache_corrupt", false)))
	return _snapshot_from_envelope(region_id, loaded["envelope"], str(loaded.get("cache_source", "disk")))


## Starts a single non-blocking refresh when the HTTP cache entry is due.
## Callers cannot override the server's freshness lifetime. Multiple callers
## for one region share one request and each receive the same final result.
func refresh_region(region_id: String, callback: Callable = Callable()) -> Dictionary:
	if not regions.has(region_id):
		return _deliver_immediate(callback, _unavailable(region_id, "unknown_region"))
	var snapshot := read_forecast(region_id)
	if _inflight.has(region_id):
		var inflight_state: Dictionary = _inflight[region_id]
		if callback.is_valid():
			(inflight_state["callbacks"] as Array).append(callback)
		return {
			"status": "request_in_flight",
			"region_id": region_id,
			"has_data": bool(snapshot.get("has_data", false)),
			"data": snapshot.get("data", {}),
			"refresh_due": true,
		}
	if bool(snapshot.get("has_data", false)) and not bool(snapshot.get("refresh_due", true)):
		return _deliver_immediate(callback, snapshot)
	if not _has_valid_contact(user_agent_contact):
		var contact_error := snapshot.duplicate(true)
		contact_error["status"] = "configuration_required"
		contact_error["refresh_due"] = true
		contact_error["error"] = "user_agent_contact_required"
		return _deliver_immediate(callback, contact_error)
	if http_adapter == null or cache_store == null or clock == null or scheduler == null:
		var dependency_error := snapshot.duplicate(true)
		dependency_error["status"] = "unavailable" if not snapshot.get("has_data", false) else snapshot["status"]
		dependency_error["error"] = "provider_adapter_missing"
		return _deliver_immediate(callback, dependency_error)
	var now := _now_unix()
	var failure: Dictionary = _failure_state.get(region_id, {})
	if now < int(failure.get("retry_after_unix", 0)):
		var cooling := _fallback_result(region_id, snapshot, "cooldown_active")
		cooling["retry_after_unix"] = int(failure["retry_after_unix"])
		return _deliver_immediate(callback, cooling)
	var envelope: Dictionary = snapshot.get("cache_envelope", {})
	var request_data := _build_request(region_id, envelope)
	var callbacks: Array[Callable] = []
	if callback.is_valid():
		callbacks.append(callback)
	_inflight[region_id] = {
		"callbacks": callbacks,
		"request_data": request_data,
		"attempt": 0,
		"cache_snapshot": snapshot,
	}
	_send_attempt(region_id)
	return {
		"status": "request_started",
		"region_id": region_id,
		"has_data": bool(snapshot.get("has_data", false)),
		"data": snapshot.get("data", {}),
		"refresh_due": true,
		"request_url": request_data["url"],
	}


func clear_memory_cache(region_id: String = "") -> void:
	if region_id.is_empty():
		_memory_cache.clear()
	else:
		_memory_cache.erase(region_id)


func parse_response_for_region(region_id: String, response: Variant, metadata: Dictionary = {}) -> Dictionary:
	if not regions.has(region_id):
		return {"ok": false, "error": "unknown_region"}
	var region: WeatherRegion = regions[region_id]
	return Codec.parse_met_response(
		response,
		region_id,
		region.latitude,
		region.longitude,
		_now_utc_iso(),
		metadata
	)


func get_cache_diagnostic(region_id: String) -> Dictionary:
	return (_cache_diagnostics.get(region_id, {}) as Dictionary).duplicate(true)


func _send_attempt(region_id: String) -> void:
	if not _inflight.has(region_id):
		return
	var state: Dictionary = _inflight[region_id]
	var callback := Callable(self, "_on_http_response").bind(region_id)
	http_adapter.call("request", state["request_data"], callback)


func _on_http_response(response: Dictionary, region_id: String) -> void:
	if not _inflight.has(region_id):
		return
	var state: Dictionary = _inflight[region_id]
	var transport_result := int(response.get("transport_result", -1))
	var status_code := int(response.get("status_code", 0))
	if _should_retry(transport_result, status_code, int(state["attempt"])):
		var delay := _retry_delay_seconds(response, int(state["attempt"]))
		state["attempt"] = int(state["attempt"]) + 1
		_inflight[region_id] = state
		scheduler.call("schedule", delay, Callable(self, "_send_attempt").bind(region_id))
		return
	var result := _process_response(region_id, response, state)
	if bool(result.get("ok", false)):
		_failure_state.erase(region_id)
	else:
		_register_failure(region_id, result)
	_complete_request(region_id, result)


func _process_response(region_id: String, response: Dictionary, state: Dictionary) -> Dictionary:
	var transport_result := int(response.get("transport_result", -1))
	var status_code := int(response.get("status_code", 0))
	var headers := _headers_to_dictionary(response.get("headers", PackedStringArray()))
	var snapshot: Dictionary = state["cache_snapshot"]
	var envelope: Dictionary = snapshot.get("cache_envelope", {})
	if transport_result != HTTPRequest.RESULT_SUCCESS:
		return _fallback_result(region_id, snapshot, "network_error", {"transport_result": transport_result})
	if status_code == 304:
		if envelope.is_empty():
			return _fallback_result(region_id, snapshot, "not_modified_without_cache")
		var updated := envelope.duplicate(true)
		var now := _now_unix()
		updated["last_checked_at_unix"] = now
		updated["last_checked_at_utc"] = _now_utc_iso()
		updated["expires_header"] = str(headers.get("expires", updated.get("expires_header", "")))
		updated["cache_control_header"] = str(headers.get("cache-control", updated.get("cache_control_header", "")))
		updated["date_header"] = str(headers.get("date", updated.get("date_header", "")))
		updated["age_header_seconds"] = int(str(headers.get("age", updated.get("age_header_seconds", 0)))) if str(headers.get("age", updated.get("age_header_seconds", 0))).is_valid_int() else 0
		updated["last_modified_header"] = str(headers.get("last-modified", updated.get("last_modified_header", "")))
		updated["etag"] = str(headers.get("etag", updated.get("etag", "")))
		updated["expires_at_unix"] = _resolve_expiry(headers, now)
		cache_store.call("save_envelope", region_id, updated)
		_memory_cache[region_id] = updated
		return _snapshot_from_envelope(region_id, updated, "http_304", {"ok": true, "http_status_code": 304})
	if status_code == 203:
		return _fallback_result(region_id, snapshot, "deprecated_product_response", {"http_status_code": status_code})
	if status_code != 200:
		return _fallback_result(region_id, snapshot, "http_status_%d" % status_code, {"http_status_code": status_code})
	var body_value: Variant = response.get("body", PackedByteArray())
	var body: String = body_value.get_string_from_utf8() if body_value is PackedByteArray else str(body_value)
	var json_parser := JSON.new()
	if json_parser.parse(body) != OK:
		return _fallback_result(region_id, snapshot, "invalid_json")
	var parsed: Variant = json_parser.data
	var metadata := {
		"http_status_code": status_code,
		"last_modified": str(headers.get("last-modified", "")),
		"expires": str(headers.get("expires", "")),
		"cache_control": str(headers.get("cache-control", "")),
		"date": str(headers.get("date", "")),
		"age_seconds": int(str(headers.get("age", "0"))) if str(headers.get("age", "0")).is_valid_int() else 0,
		"etag": str(headers.get("etag", "")),
	}
	var normalized_result := parse_response_for_region(region_id, parsed, metadata)
	if not bool(normalized_result.get("ok", false)):
		return _fallback_result(region_id, snapshot, "invalid_forecast:%s" % str(normalized_result.get("error", "unknown")))
	var now := _now_unix()
	var region: WeatherRegion = regions[region_id]
	var new_envelope := {
		"cache_schema_version": STANDARD_CACHE_SCHEMA_VERSION,
		"provider_id": Codec.PROVIDER_ID,
		"region_id": region_id,
		"latitude": region.latitude,
		"longitude": region.longitude,
		"fetched_at_unix": now,
		"fetched_at_utc": _now_utc_iso(),
		"last_checked_at_unix": now,
		"last_checked_at_utc": _now_utc_iso(),
		"valid_from_utc": normalized_result["data"]["valid_from_utc"],
		"valid_until_utc": normalized_result["data"]["valid_until_utc"],
		"expires_at_unix": _resolve_expiry(headers, now),
		"expires_header": str(headers.get("expires", "")),
		"cache_control_header": str(headers.get("cache-control", "")),
		"date_header": str(headers.get("date", "")),
		"age_header_seconds": int(str(headers.get("age", "0"))) if str(headers.get("age", "0")).is_valid_int() else 0,
		"last_modified_header": str(headers.get("last-modified", "")),
		"etag": str(headers.get("etag", "")),
		"source_url": str(state["request_data"]["url"]),
		"raw_response": parsed,
		"standardized_forecast": normalized_result["data"],
	}
	if str(headers.get("cache-control", "")).to_lower().contains("no-store"):
		var transient := _snapshot_from_envelope(region_id, new_envelope, "network", {"ok": true, "http_status_code": status_code, "cache_write_ok": false, "cache_write_error": "cache_control_no_store"})
		transient["status"] = "network_uncached"
		transient["cache_hit"] = false
		transient["refresh_due"] = true
		transient["stale"] = false
		transient["stale_acceptable"] = false
		transient["cache_envelope"] = {}
		return transient
	var write_result: Dictionary = cache_store.call("save_envelope", region_id, new_envelope)
	_memory_cache[region_id] = new_envelope
	return _snapshot_from_envelope(region_id, new_envelope, "network", {
		"ok": true,
		"http_status_code": status_code,
		"cache_write_ok": bool(write_result.get("ok", false)),
		"cache_write_error": str(write_result.get("error", "")),
	})


func _build_request(region_id: String, envelope: Dictionary) -> Dictionary:
	var region: WeatherRegion = regions[region_id]
	var latitude := snappedf(region.latitude, 0.0001)
	var longitude := snappedf(region.longitude, 0.0001)
	var query := "lat=%.4f&lon=%.4f" % [latitude, longitude]
	if region.use_altitude:
		query += "&altitude=%d" % region.altitude_m
	var headers := PackedStringArray([
		"User-Agent: %s (%s)" % [user_agent_product.strip_edges(), user_agent_contact.strip_edges()],
		"Accept: application/json",
	])
	var modified := str(envelope.get("last_modified_header", ""))
	if not modified.is_empty():
		headers.append("If-Modified-Since: %s" % modified)
	var etag := str(envelope.get("etag", ""))
	if not etag.is_empty():
		headers.append("If-None-Match: %s" % etag)
	return {
		"url": "%s?%s" % [Codec.SOURCE_URL, query],
		"headers": headers,
		"timeout_seconds": request_timeout_seconds,
		"region_id": region_id,
	}


func _load_envelope(region_id: String) -> Dictionary:
	if _memory_cache.has(region_id):
		var memory_envelope: Dictionary = _memory_cache[region_id]
		var memory_validation := _validate_envelope(region_id, memory_envelope)
		if bool(memory_validation.get("ok", false)):
			return {"ok": true, "envelope": memory_envelope, "cache_source": "memory"}
		_memory_cache.erase(region_id)
	var disk_result: Dictionary = cache_store.call("load_envelope", region_id) if cache_store != null else {"ok": false, "status": "missing_store"}
	if not bool(disk_result.get("ok", false)):
		var status := str(disk_result.get("status", "miss"))
		var corrupt := status in ["corrupt", "unsupported_schema", "unreadable"]
		_cache_diagnostics[region_id] = {"status": status, "reason": str(disk_result.get("reason", disk_result.get("error", "")))}
		return {"ok": false, "reason": "cache_%s" % status if corrupt else "cache_miss", "cache_corrupt": corrupt}
	var envelope: Dictionary = disk_result["envelope"]
	var validation := _validate_envelope(region_id, envelope)
	if not bool(validation.get("ok", false)):
		_cache_diagnostics[region_id] = {"status": "corrupt", "reason": str(validation.get("error", "invalid_envelope"))}
		return {"ok": false, "reason": "cache_%s" % str(validation.get("error", "invalid_envelope")), "cache_corrupt": true}
	_memory_cache[region_id] = envelope
	_cache_diagnostics[region_id] = {"status": "valid", "source": "disk"}
	return {"ok": true, "envelope": envelope, "cache_source": "disk"}


func _validate_envelope(region_id: String, envelope: Dictionary) -> Dictionary:
	if int(envelope.get("cache_schema_version", -1)) != STANDARD_CACHE_SCHEMA_VERSION:
		return {"ok": false, "error": "unsupported_cache_schema"}
	if str(envelope.get("region_id", "")) != region_id:
		return {"ok": false, "error": "region_mismatch"}
	var standardized: Variant = envelope.get("standardized_forecast", null)
	var validation := Codec.validate_standardized_document(standardized)
	if not bool(validation.get("ok", false)):
		return {"ok": false, "error": str(validation.get("error", "invalid_standardized_forecast"))}
	if not envelope.has("raw_response") or not envelope["raw_response"] is Dictionary:
		return {"ok": false, "error": "raw_response_missing"}
	return {"ok": true}


func _snapshot_from_envelope(region_id: String, envelope: Dictionary, cache_source: String, extra: Dictionary = {}) -> Dictionary:
	var now := _now_unix()
	var expires_at := int(envelope.get("expires_at_unix", 0))
	var fresh := expires_at > now
	var stale_age := 0.0 if fresh else maxf(float(now - expires_at), 0.0)
	var result := {
		"status": "fresh_cache" if fresh else "stale_cache",
		"region_id": region_id,
		"has_data": true,
		"cache_hit": cache_source in ["memory", "disk", "http_304"],
		"cache_source": cache_source,
		"refresh_due": not fresh,
		"stale_acceptable": fresh or stale_age <= max_stale_seconds,
		"stale_age_seconds": stale_age,
		"stale": not fresh,
		"data": envelope["standardized_forecast"],
		"cache_envelope": envelope,
		"fetched_at_unix": int(envelope.get("fetched_at_unix", 0)),
		"last_checked_at_unix": int(envelope.get("last_checked_at_unix", envelope.get("fetched_at_unix", 0))),
		"expires_at_unix": expires_at,
		"last_modified": str(envelope.get("last_modified_header", "")),
	}
	for key in extra:
		result[key] = extra[key]
	return result


func _unavailable(region_id: String, reason: String, corrupt: bool = false) -> Dictionary:
	return {
		"status": "unavailable",
		"region_id": region_id,
		"has_data": false,
		"cache_hit": false,
		"refresh_due": true,
		"stale_acceptable": false,
		"cache_corrupt": corrupt,
		"error": reason,
		"data": {},
	}


func _fallback_result(region_id: String, snapshot: Dictionary, reason: String, extra: Dictionary = {}) -> Dictionary:
	var result := snapshot.duplicate(true)
	if bool(snapshot.get("has_data", false)) and bool(snapshot.get("stale_acceptable", false)):
		var is_stale := int(snapshot.get("expires_at_unix", 0)) <= _now_unix()
		result["status"] = "stale_cache" if is_stale else "fresh_cache"
		result["refresh_status"] = "failed"
		result["stale"] = is_stale
	else:
		result = _unavailable(region_id, reason, bool(snapshot.get("cache_corrupt", false)))
		result["refresh_status"] = "failed"
	result["error"] = reason
	for key in extra:
		result[key] = extra[key]
	return result


func _should_retry(transport_result: int, status_code: int, attempt: int) -> bool:
	if attempt >= max_retries:
		return false
	if transport_result != HTTPRequest.RESULT_SUCCESS:
		return transport_result in [HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CONNECTION_ERROR, HTTPRequest.RESULT_NO_RESPONSE, HTTPRequest.RESULT_TIMEOUT]
	return status_code in [408, 425, 429, 500, 502, 503, 504]


func _retry_delay_seconds(response: Dictionary, attempt: int) -> float:
	var headers := _headers_to_dictionary(response.get("headers", PackedStringArray()))
	var retry_after := str(headers.get("retry-after", ""))
	if retry_after.is_valid_int():
		return clampf(float(retry_after), 0.0, retry_max_seconds)
	var retry_after_date := _parse_http_date(retry_after)
	if retry_after_date >= 0:
		return clampf(float(retry_after_date - _now_unix()), 0.0, retry_max_seconds)
	return minf(retry_base_seconds * pow(2.0, float(attempt)), retry_max_seconds)


func _register_failure(region_id: String, result: Dictionary) -> void:
	var old: Dictionary = _failure_state.get(region_id, {})
	var count := int(old.get("count", 0)) + 1
	var delay := minf(failure_cooldown_base_seconds * pow(2.0, float(count - 1)), failure_cooldown_max_seconds)
	var now := _now_unix()
	_failure_state[region_id] = {"count": count, "retry_after_unix": now + int(ceil(delay)), "last_error": str(result.get("error", "unknown"))}
	var last_log := int(_last_error_log_by_region.get(region_id, -1_000_000_000))
	if now - last_log >= int(error_log_interval_seconds):
		push_warning("Weather data refresh failed for %s (%s); next retry is rate-limited." % [region_id, str(result.get("error", "unknown"))])
		_last_error_log_by_region[region_id] = now


func _complete_request(region_id: String, result: Dictionary) -> void:
	if not _inflight.has(region_id):
		return
	var state: Dictionary = _inflight[region_id]
	_inflight.erase(region_id)
	for callback in state["callbacks"]:
		if callback is Callable and callback.is_valid():
			callback.call(result.duplicate(true))


func _deliver_immediate(callback: Callable, result: Dictionary) -> Dictionary:
	if callback.is_valid():
		callback.call(result.duplicate(true))
	return result


func _resolve_expiry(headers: Dictionary, now: int) -> int:
	var cache_control := str(headers.get("cache-control", ""))
	var lowered_cache_control := cache_control.to_lower()
	if lowered_cache_control.contains("no-cache") or lowered_cache_control.contains("no-store"):
		return now
	var max_age := _parse_max_age(cache_control)
	var age := maxi(int(str(headers.get("age", "0"))) if str(headers.get("age", "0")).is_valid_int() else 0, 0)
	if max_age >= 0:
		return now + maxi(max_age - age, 0)
	var expiry_header := str(headers.get("expires", ""))
	var parsed_expiry := _parse_http_date(expiry_header)
	if parsed_expiry >= 0:
		return maxi(now, parsed_expiry - age)
	return now + int(fallback_cache_ttl_seconds)


func _parse_http_date(value: String) -> int:
	if value.is_empty():
		return -1
	var regex := RegEx.new()
	regex.compile("^[A-Za-z]{3},\\s*(\\d{1,2})\\s+([A-Za-z]{3})\\s+(\\d{4})\\s+(\\d{2}):(\\d{2}):(\\d{2})\\s+GMT$")
	var match := regex.search(value.strip_edges())
	if match == null:
		return -1
	var months := {"Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6, "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12}
	var month_name := match.get_string(2)
	if not months.has(month_name):
		return -1
	var date_time := {
		"year": int(match.get_string(3)),
		"month": int(months[month_name]),
		"day": int(match.get_string(1)),
		"hour": int(match.get_string(4)),
		"minute": int(match.get_string(5)),
		"second": int(match.get_string(6)),
	}
	var timestamp := "%04d-%02d-%02dT%02d:%02d:%02dZ" % [date_time["year"], date_time["month"], date_time["day"], date_time["hour"], date_time["minute"], date_time["second"]]
	return Codec.parse_utc_timestamp_to_unix(timestamp)


func _parse_max_age(cache_control: String) -> int:
	for segment in cache_control.split(","):
		var pair := segment.strip_edges().split("=", false, 1)
		if pair.size() == 2 and pair[0].strip_edges().to_lower() == "max-age" and pair[1].strip_edges().is_valid_int():
			return max(int(pair[1].strip_edges()), 0)
	return -1


func _headers_to_dictionary(raw_headers: Variant) -> Dictionary:
	var result := {}
	var headers: Array = []
	if raw_headers is PackedStringArray:
		headers = Array(raw_headers)
	elif raw_headers is Array:
		headers = raw_headers
	for header in headers:
		var line := str(header)
		var separator := line.find(":")
		if separator <= 0:
			continue
		var key := line.substr(0, separator).strip_edges().to_lower()
		var value := line.substr(separator + 1).strip_edges()
		result[key] = value
	return result


func _has_valid_contact(value: String) -> bool:
	var contact := value.strip_edges()
	if contact.is_empty() or contact.contains("\n") or contact.contains("\r"):
		return false
	if contact.contains("@"):
		var email_parts := contact.split("@", false, 1)
		return email_parts.size() == 2 and not email_parts[0].is_empty() and email_parts[1].contains(".")
	if contact.begins_with("https://") or contact.begins_with("http://"):
		var url_without_scheme := contact.trim_prefix("https://").trim_prefix("http://")
		return not url_without_scheme.is_empty() and url_without_scheme.get_slice("/", 0).contains(".")
	return false


func _now_unix() -> int:
	return int(clock.call("now_unix_seconds")) if clock != null else 0


func _now_utc_iso() -> String:
	return str(clock.call("now_utc_iso")) if clock != null else "1970-01-01T00:00:00Z"
