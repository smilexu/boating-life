extends SceneTree

const Adapter := preload("res://scripts/weather_runtime/weather_stockholm_calendar_adapter.gd")
const Codec := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const WorldTimeManagerScript := preload("res://scripts/world_time_manager.gd")

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect_day("2026-01-15T12:00:00Z", 86400, "2026-01-15", "winter date uses CET midnight boundaries")
	_expect_day("2026-07-15T12:00:00Z", 86400, "2026-07-15", "summer date uses CEST midnight boundaries")
	_expect_day("2026-03-29T12:00:00Z", 82800, "2026-03-29", "2026-03-29 Stockholm date spans 23 hours")
	_expect_day("2026-10-25T12:00:00Z", 90000, "2026-10-25", "2026-10-25 Stockholm date spans 25 hours")
	var utc_late_evening := Codec.parse_utc_timestamp_to_unix("2026-10-19T22:30:00Z")
	var local_date := WorldTimeManagerScript.stockholm_date_from_utc(utc_late_evening)
	_expect(WorldTimeManagerScript.date_key(local_date) == "2026-10-20", "UTC and Stockholm calendar dates may differ at the same instant")
	_expect(_failures.is_empty(), "all Stockholm calendar assertions pass")
	if _failures.is_empty():
		print("WeatherStockholmCalendarAdapter tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _expect_day(utc: String, expected_seconds: int, label: String, description: String) -> void:
	var timestamp := Codec.parse_utc_timestamp_to_unix(utc)
	var result := Adapter.build_day_boundaries(timestamp, 1)
	_expect(bool(result.get("ok", false)), description + " (boundary build)")
	if not bool(result.get("ok", false)):
		return
	var boundaries: Array = result["real_day_boundaries_utc"]
	var start := Codec.parse_utc_timestamp_to_unix(str(boundaries[0]))
	var finish := Codec.parse_utc_timestamp_to_unix(str(boundaries[1]))
	_expect(str(result["calendar_day_labels"][0]) == label, description + " (local label)")
	_expect(finish - start == expected_seconds, description + " (actual UTC day duration)")


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL: " + message)
