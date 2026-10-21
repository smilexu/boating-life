extends RefCounted
class_name WeatherStockholmCalendarAdapter

## Converts real UTC instants to Europe/Stockholm civil-day boundaries.
## The UTC offset rules are shared with WorldTimeManager, but boundary
## conversion uses the offset at the actual midnight instant (not the special
## full-day DST offset used by its accelerated 24-hour game clock).

const WorldTimeManagerScript := preload("res://scripts/world_time_manager.gd")
const ForecastCodec := preload("res://scripts/weather_data/weather_forecast_codec.gd")


static func build_day_boundaries(utc_unix_time: float, day_count: int) -> Dictionary:
	if not is_finite(utc_unix_time) or day_count < 1 or day_count > 16:
		return {"ok": false, "error": "calendar_request_invalid"}
	var first_date: Dictionary = WorldTimeManagerScript.stockholm_date_from_utc(utc_unix_time)
	var boundaries: Array[String] = []
	var labels: Array[String] = []
	for day_offset in range(day_count + 1):
		var date := _add_days(first_date, day_offset)
		var midnight_unix := stockholm_midnight_utc(date)
		if not is_finite(midnight_unix):
			return {"ok": false, "error": "stockholm_midnight_conversion_failed"}
		boundaries.append(ForecastCodec._utc_iso_from_unix(int(round(midnight_unix))))
		if day_offset < day_count:
			labels.append(WorldTimeManagerScript.date_key(date))
	return {
		"ok": true,
		"real_day_boundaries_utc": boundaries,
		"calendar_day_labels": labels,
		"calendar_boundary_basis": "Europe/Stockholm civil midnight using WorldTimeManager CET/CEST rules",
	}


static func stockholm_midnight_utc(date: Dictionary) -> float:
	if not WorldTimeManagerScript.is_valid_gregorian_date(
		int(date.get("year", 0)), int(date.get("month", 0)), int(date.get("day", 0))
	):
		return NAN
	var local_midnight_as_utc := Time.get_unix_time_from_datetime_dict({
		"year": int(date["year"]), "month": int(date["month"]), "day": int(date["day"]),
		"hour": 0, "minute": 0, "second": 0,
	})
	var candidate := local_midnight_as_utc - 3600.0
	# Stockholm's DST transition is not at midnight, so this fixed-point lookup
	# resolves the actual offset unambiguously on both transition dates.
	for _iteration in range(4):
		var next_candidate := local_midnight_as_utc - float(WorldTimeManagerScript.stockholm_offset_seconds_at_utc(candidate))
		if absf(next_candidate - candidate) < 0.01:
			return next_candidate
		candidate = next_candidate
	return candidate


static func add_days(date: Dictionary, day_count: int) -> Dictionary:
	return _add_days(date, day_count)


static func _add_days(date: Dictionary, day_count: int) -> Dictionary:
	var noon_as_utc := Time.get_unix_time_from_datetime_dict({
		"year": int(date.get("year", 0)), "month": int(date.get("month", 0)), "day": int(date.get("day", 0)),
		"hour": 12, "minute": 0, "second": 0,
	})
	var fields := Time.get_datetime_dict_from_unix_time(int(noon_as_utc + float(day_count) * 86400.0))
	return {"year": int(fields["year"]), "month": int(fields["month"]), "day": int(fields["day"])}
