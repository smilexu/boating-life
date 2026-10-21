extends SceneTree

const LAB_SCENE := preload("res://scenes/WeatherSimulationLab.tscn")
const CACHE_PATH := "res://.godot/weather_live_request_cache/oresund.json"

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if not FileAccess.file_exists(CACHE_PATH):
		print("WeatherSimulationLab cache check: SKIPPED (no local live cache; no network request made).")
		quit(0)
		return
	var lab: Control = LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	lab.call("_load_live_cache")
	await process_frame
	var source_status := lab.find_child("SourceStatus", true, false) as Label
	var metadata := lab.find_child("ForecastMetadata", true, false) as Label
	var document: Dictionary = lab.get("_forecast_document")
	var envelope: Dictionary = lab.get("_cache_envelope")
	var expected_freshness := "STALE CACHE" if int(envelope.get("expires_at_unix", 0)) <= int(Time.get_unix_time_from_system()) else "FRESH CACHE"
	_expect(source_status != null and source_status.text.contains("LIVE CACHE"), "local real cache is identified as LIVE CACHE")
	_expect(source_status != null and source_status.text.contains(expected_freshness), "real cache freshness agrees with its expiry timestamp")
	_expect(document.get("provider_id") == "met_norway_locationforecast_2_0_complete", "cache retains the actual MET Norway provider ID")
	_expect(document.get("timeseries", []).size() == 86, "cached raw sample count remains distinct from generated keyframes")
	_expect(str(envelope.get("fetched_at_utc", "")).begins_with("2026-10-20T"), "cache fetch timestamp is displayed from its stored metadata")
	_expect(metadata != null and metadata.text.contains("1h×54") and metadata.text.contains("6h×31"), "nonuniform one-hour and six-hour sample intervals are visible")
	if _failures.is_empty():
		print("WeatherSimulationLab local cache check: %d checks passed; no HTTP request made." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[Cache #%d] %s" % [_checks, message])
