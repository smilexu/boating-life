extends RefCounted
class_name WeatherForecastCodec

## Pure data conversion and validation. It does not access scenes, nodes, time,
## network services, or storage.

const STANDARD_SCHEMA_VERSION := 2
const LEGACY_STANDARD_SCHEMA_VERSION := 1
const PROVIDER_ID := "met_norway_locationforecast_2_0_complete"
const SOURCE_URL := "https://api.met.no/weatherapi/locationforecast/2.0/complete"
const ATTRIBUTION := "Data from MET Norway"
const LICENSE := "CC BY 4.0; Norwegian Licence for Open Government Data (NLOD) 2.0"


static func parse_met_response(
	response: Variant,
	region_id: String,
	requested_latitude: float,
	requested_longitude: float,
	retrieved_at_utc: String,
	response_metadata: Dictionary = {}
) -> Dictionary:
	if not response is Dictionary:
		return {"ok": false, "error": "root_not_object"}
	var properties: Variant = response.get("properties", {})
	if not properties is Dictionary:
		return {"ok": false, "error": "properties_missing"}
	var metadata: Variant = properties.get("meta", {})
	if not metadata is Dictionary:
		return {"ok": false, "error": "forecast_metadata_missing"}
	var issued_at := str(metadata.get("updated_at", ""))
	if not is_valid_utc_timestamp(issued_at):
		return {"ok": false, "error": "forecast_issued_at_invalid"}
	var timeseries: Variant = properties.get("timeseries", [])
	if not timeseries is Array or timeseries.is_empty():
		return {"ok": false, "error": "timeseries_missing"}

	var normalized_series: Array[Dictionary] = []
	var first_time := ""
	var last_time := ""
	for raw_entry in timeseries:
		if not raw_entry is Dictionary:
			continue
		var valid_time := str(raw_entry.get("time", ""))
		if not is_valid_utc_timestamp(valid_time):
			continue
		var raw_data: Variant = raw_entry.get("data", {})
		if not raw_data is Dictionary:
			continue
		var instant: Variant = raw_data.get("instant", {})
		if not instant is Dictionary:
			continue
		var details: Variant = instant.get("details", {})
		if not details is Dictionary:
			continue
		var sample := {"valid_time_utc": valid_time}
		_copy_number(details, "air_temperature", sample, "air_temperature_c")
		_copy_number(details, "relative_humidity", sample, "relative_humidity_percent")
		_copy_number(details, "air_pressure_at_sea_level", sample, "air_pressure_hpa")
		_copy_number(details, "wind_speed", sample, "wind_speed_mps")
		_copy_number(details, "wind_speed_of_gust", sample, "wind_gust_mps")
		_copy_number(details, "wind_from_direction", sample, "wind_from_direction_deg")
		if sample.has("wind_from_direction_deg"):
			sample["wind_from_direction_deg"] = fposmod(float(sample["wind_from_direction_deg"]), 360.0)
		_copy_fraction(details, "cloud_area_fraction", sample, "cloud_fraction")

		var precipitation_periods := _read_precipitation_periods(raw_data, valid_time)
		if not precipitation_periods.is_empty():
			sample["precipitation_periods"] = precipitation_periods
		var weather_symbol_periods := _read_weather_symbol_periods(raw_data, valid_time)
		if not weather_symbol_periods.is_empty():
			sample["weather_symbol_periods"] = weather_symbol_periods
		normalized_series.append(sample)
		if first_time.is_empty():
			first_time = valid_time
		last_time = valid_time

	if normalized_series.is_empty():
		return {"ok": false, "error": "no_valid_forecast_samples"}
	var geometry: Variant = response.get("geometry", {})
	var coordinates: Variant = geometry.get("coordinates", []) if geometry is Dictionary else []
	var actual_latitude := requested_latitude
	var actual_longitude := requested_longitude
	if coordinates is Array and coordinates.size() >= 2:
		actual_longitude = float(coordinates[0])
		actual_latitude = float(coordinates[1])

	var source_metadata := {
		"attribution": ATTRIBUTION,
		"source_url": SOURCE_URL,
		"license": LICENSE,
		"provider_updated_at_utc": issued_at,
		"provider_units": _copy_unit_metadata(metadata.get("units", {})),
		"http_status_code": int(response_metadata.get("http_status_code", 200)),
		"last_modified": str(response_metadata.get("last_modified", "")),
		"expires": str(response_metadata.get("expires", "")),
		"cache_control": str(response_metadata.get("cache_control", "")),
		"date": str(response_metadata.get("date", "")),
		"age_seconds": int(response_metadata.get("age_seconds", 0)),
		"etag": str(response_metadata.get("etag", "")),
	}
	var standardized := {
		"schema_version": STANDARD_SCHEMA_VERSION,
		"provider_id": PROVIDER_ID,
		"region_id": region_id,
		"latitude": actual_latitude,
		"longitude": actual_longitude,
		"forecast_issued_at_utc": issued_at,
		"retrieved_at_utc": retrieved_at_utc,
		"valid_from_utc": first_time,
		"valid_until_utc": last_time,
		"timeseries": normalized_series,
		"source_metadata": source_metadata,
	}
	var standardized_validation := validate_standardized_document(standardized)
	if not bool(standardized_validation.get("ok", false)):
		return {"ok": false, "error": "standardized_validation_failed:%s" % str(standardized_validation.get("error", "unknown"))}
	return {"ok": true, "data": standardized}


static func validate_standardized_document(document: Variant) -> Dictionary:
	if not document is Dictionary:
		return {"ok": false, "error": "document_not_object"}
	var schema_version := int(document.get("schema_version", -1))
	if not schema_version in [LEGACY_STANDARD_SCHEMA_VERSION, STANDARD_SCHEMA_VERSION]:
		return {"ok": false, "error": "unsupported_schema_version"}
	for key in ["provider_id", "region_id", "forecast_issued_at_utc", "retrieved_at_utc", "valid_from_utc", "valid_until_utc"]:
		if str(document.get(key, "")).is_empty():
			return {"ok": false, "error": "required_field_missing:%s" % key}
	for key in ["latitude", "longitude"]:
		if not document.has(key) or not is_finite(float(document[key])):
			return {"ok": false, "error": "coordinate_invalid:%s" % key}
	if float(document["latitude"]) < -90.0 or float(document["latitude"]) > 90.0 or float(document["longitude"]) < -180.0 or float(document["longitude"]) > 180.0:
		return {"ok": false, "error": "coordinate_out_of_range"}
	for key in ["forecast_issued_at_utc", "retrieved_at_utc", "valid_from_utc", "valid_until_utc"]:
		if not is_valid_utc_timestamp(str(document[key])):
			return {"ok": false, "error": "timestamp_invalid:%s" % key}
	var timeseries: Variant = document.get("timeseries", null)
	if not timeseries is Array or timeseries.is_empty():
		return {"ok": false, "error": "timeseries_missing"}
	for sample in timeseries:
		if not sample is Dictionary or not is_valid_utc_timestamp(str(sample.get("valid_time_utc", ""))):
			return {"ok": false, "error": "timeseries_timestamp_invalid"}
		for optional_number in [
			"air_temperature_c", "relative_humidity_percent", "air_pressure_hpa",
			"wind_speed_mps", "wind_gust_mps", "wind_from_direction_deg", "cloud_fraction",
		]:
			if sample.has(optional_number) and not is_finite_number(sample[optional_number]):
				return {"ok": false, "error": "timeseries_number_invalid:%s" % optional_number}
		if sample.has("relative_humidity_percent") and not _number_in_range(sample["relative_humidity_percent"], 0.0, 100.0):
			return {"ok": false, "error": "relative_humidity_out_of_range"}
		if sample.has("air_pressure_hpa") and float(sample["air_pressure_hpa"]) <= 0.0:
			return {"ok": false, "error": "air_pressure_out_of_range"}
		if sample.has("wind_speed_mps") and float(sample["wind_speed_mps"]) < 0.0:
			return {"ok": false, "error": "wind_speed_negative"}
		if sample.has("wind_gust_mps") and float(sample["wind_gust_mps"]) < 0.0:
			return {"ok": false, "error": "wind_gust_negative"}
		if sample.has("wind_from_direction_deg") and (float(sample["wind_from_direction_deg"]) < 0.0 or float(sample["wind_from_direction_deg"]) >= 360.0):
			return {"ok": false, "error": "wind_direction_out_of_range"}
		if sample.has("cloud_fraction") and not _number_in_range(sample["cloud_fraction"], 0.0, 1.0):
			return {"ok": false, "error": "cloud_fraction_out_of_range"}
		if sample.has("precipitation_periods"):
			if not sample["precipitation_periods"] is Array:
				return {"ok": false, "error": "precipitation_periods_invalid"}
			for period in sample["precipitation_periods"]:
				if not period is Dictionary:
					return {"ok": false, "error": "precipitation_period_invalid"}
				if not is_valid_utc_timestamp(str(period.get("period_start_utc", ""))) or not is_valid_utc_timestamp(str(period.get("period_end_utc", ""))):
					return {"ok": false, "error": "precipitation_period_time_invalid"}
				if not int(period.get("duration_hours", 0)) in [1, 6, 12]:
					return {"ok": false, "error": "precipitation_period_duration_invalid"}
				for period_number in ["precipitation_amount_mm", "precipitation_probability"]:
					if period.has(period_number) and not is_finite_number(period[period_number]):
						return {"ok": false, "error": "precipitation_number_invalid:%s" % period_number}
				if period.has("precipitation_amount_mm") and float(period["precipitation_amount_mm"]) < 0.0:
					return {"ok": false, "error": "precipitation_amount_negative"}
				if period.has("precipitation_probability") and not _number_in_range(period["precipitation_probability"], 0.0, 1.0):
					return {"ok": false, "error": "precipitation_probability_out_of_range"}
				var start_unix := parse_utc_timestamp_to_unix(str(period["period_start_utc"]))
				var end_unix := parse_utc_timestamp_to_unix(str(period["period_end_utc"]))
				if end_unix <= start_unix or end_unix - start_unix != int(period["duration_hours"]) * 3600:
					return {"ok": false, "error": "precipitation_period_duration_mismatch"}
				if schema_version >= STANDARD_SCHEMA_VERSION:
					var valid_unix := parse_utc_timestamp_to_unix(str(sample["valid_time_utc"]))
					if start_unix != valid_unix:
						return {"ok": false, "error": "precipitation_window_must_start_at_sample_time"}
					if str(period.get("source_period_key", "")) != "next_%d_hours" % int(period["duration_hours"]):
						return {"ok": false, "error": "precipitation_period_source_missing"}
					if str(period.get("source_field", "")) != "details.precipitation_amount/probability":
						return {"ok": false, "error": "precipitation_period_field_invalid"}
					var source_fields: Variant = period.get("source_fields", null)
					if not source_fields is Array or source_fields.is_empty():
						return {"ok": false, "error": "precipitation_period_source_fields_missing"}
					if JSON.stringify(source_fields) != JSON.stringify(_standardized_precipitation_source_fields(period)):
						return {"ok": false, "error": "precipitation_source_fields_mismatch"}
		if sample.has("weather_symbol_periods"):
			if not sample["weather_symbol_periods"] is Array:
				return {"ok": false, "error": "weather_symbol_periods_invalid"}
			for symbol_period in sample["weather_symbol_periods"]:
				if not symbol_period is Dictionary:
					return {"ok": false, "error": "weather_symbol_period_invalid"}
				if not int(symbol_period.get("duration_hours", 0)) in [1, 6, 12]:
					return {"ok": false, "error": "weather_symbol_period_duration_invalid"}
				if not str(symbol_period.get("symbol_code", "")).strip_edges():
					return {"ok": false, "error": "weather_symbol_period_symbol_missing"}
				if not is_valid_utc_timestamp(str(symbol_period.get("period_start_utc", ""))) or not is_valid_utc_timestamp(str(symbol_period.get("period_end_utc", ""))):
					return {"ok": false, "error": "weather_symbol_period_time_invalid"}
				var symbol_start := parse_utc_timestamp_to_unix(str(symbol_period["period_start_utc"]))
				var symbol_end := parse_utc_timestamp_to_unix(str(symbol_period["period_end_utc"]))
				if symbol_end <= symbol_start or symbol_end - symbol_start != int(symbol_period["duration_hours"]) * 3600:
					return {"ok": false, "error": "weather_symbol_period_duration_mismatch"}
				if schema_version >= STANDARD_SCHEMA_VERSION:
					var symbol_valid_unix := parse_utc_timestamp_to_unix(str(sample["valid_time_utc"]))
					if symbol_start != symbol_valid_unix:
						return {"ok": false, "error": "weather_symbol_window_must_start_at_sample_time"}
					if str(symbol_period.get("source_period_key", "")) != "next_%d_hours" % int(symbol_period["duration_hours"]):
						return {"ok": false, "error": "weather_symbol_period_source_missing"}
					if str(symbol_period.get("source_field", "")) != "summary.symbol_code":
						return {"ok": false, "error": "weather_symbol_period_field_invalid"}
		if schema_version >= STANDARD_SCHEMA_VERSION and sample.has("weather_symbol"):
			return {"ok": false, "error": "weather_symbol_point_semantics_not_allowed_in_schema_2"}
	return {"ok": true, "data": document}


static func serialize_document(document: Dictionary) -> String:
	var normalized := upgrade_standardized_document(document)
	var validation := validate_standardized_document(normalized.get("data", {}))
	if not bool(validation.get("ok", false)):
		return ""
	return JSON.stringify(normalized["data"], "", true, true)


static func deserialize_document(json_text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(json_text)
	var validation := validate_standardized_document(parsed)
	if not bool(validation.get("ok", false)):
		return validation
	return upgrade_standardized_document(parsed)


## Upgrades old point-symbol documents without inventing a symbol window. The
## ambiguous v1 symbol remains available for display, but is explicitly marked
## unusable as duration evidence.
static func upgrade_standardized_document(document: Variant) -> Dictionary:
	var validation := validate_standardized_document(document)
	if not bool(validation.get("ok", false)):
		return validation
	var upgraded: Dictionary = document.duplicate(true)
	var source_version := int(upgraded.get("schema_version", -1))
	if source_version == LEGACY_STANDARD_SCHEMA_VERSION:
		for sample_value in upgraded.get("timeseries", []):
			if not sample_value is Dictionary:
				continue
			var sample: Dictionary = sample_value
			if sample.has("weather_symbol"):
				sample["legacy_weather_symbol"] = str(sample["weather_symbol"])
				sample["legacy_weather_symbol_temporal_semantics"] = "unknown_window_not_used_for_duration"
				sample.erase("weather_symbol")
			for period_value in sample.get("precipitation_periods", []):
				if not period_value is Dictionary:
					continue
				var period: Dictionary = period_value
				var hours := int(period.get("duration_hours", 0))
				period["source_period_key"] = "next_%d_hours" % hours
				period["source_field"] = "details.precipitation_amount/probability"
				period["source_fields"] = _standardized_precipitation_source_fields(period)
			for symbol_period_value in sample.get("weather_symbol_periods", []):
				if not symbol_period_value is Dictionary:
					continue
				var symbol_period: Dictionary = symbol_period_value
				var symbol_hours := int(symbol_period.get("duration_hours", 0))
				symbol_period["source_period_key"] = "next_%d_hours" % symbol_hours
				symbol_period["source_field"] = "summary.symbol_code"
		upgraded["schema_version"] = STANDARD_SCHEMA_VERSION
		upgraded["schema_migration"] = {
			"from_schema_version": LEGACY_STANDARD_SCHEMA_VERSION,
			"to_schema_version": STANDARD_SCHEMA_VERSION,
			"legacy_weather_symbol_note": "Original symbol window was not retained; legacy symbols are display-only and excluded from time-weighted classification.",
		}
	var upgraded_validation := validate_standardized_document(upgraded)
	if not bool(upgraded_validation.get("ok", false)):
		return {"ok": false, "error": "upgraded_document_invalid:%s" % str(upgraded_validation.get("error", "unknown"))}
	return {"ok": true, "data": upgraded, "migrated": source_version == LEGACY_STANDARD_SCHEMA_VERSION}


static func parse_utc_timestamp_to_unix(timestamp: String) -> int:
	var date_time := _parse_utc_components(timestamp)
	if date_time.is_empty():
		return -1
	return _days_from_civil(int(date_time["year"]), int(date_time["month"]), int(date_time["day"])) * 86400 \
		+ int(date_time["hour"]) * 3600 + int(date_time["minute"]) * 60 + int(date_time["second"])


static func is_valid_utc_timestamp(timestamp: String) -> bool:
	return not _parse_utc_components(timestamp).is_empty()


static func _read_precipitation_periods(raw_data: Dictionary, valid_time: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for period_name in ["next_1_hours", "next_6_hours", "next_12_hours"]:
		var period_data: Variant = raw_data.get(period_name, {})
		if not period_data is Dictionary:
			continue
		var period_details: Variant = period_data.get("details", {})
		if not period_details is Dictionary:
			continue
		var has_amount: bool = period_details.has("precipitation_amount") and is_finite_number(period_details["precipitation_amount"])
		var has_probability: bool = period_details.has("probability_of_precipitation") and is_finite_number(period_details["probability_of_precipitation"])
		if not has_amount and not has_probability:
			continue
		var hours := int(period_name.trim_prefix("next_").trim_suffix("_hours"))
		# MET's next_* window starts at this timeseries record's `time` and runs forward.
		var start_seconds := parse_utc_timestamp_to_unix(valid_time)
		var start_iso := valid_time
		var end_iso := _utc_iso_from_unix(start_seconds + hours * 3600)
		var period := {
			"duration_hours": hours,
			"period_start_utc": start_iso,
			"period_end_utc": end_iso,
			"source_period_key": period_name,
			"source_field": "details.precipitation_amount/probability",
			"source_fields": _precipitation_source_fields(period_details),
		}
		_copy_number(period_details, "precipitation_amount", period, "precipitation_amount_mm")
		_copy_fraction(period_details, "probability_of_precipitation", period, "precipitation_probability")
		result.append(period)
	return result


static func _precipitation_source_fields(details: Dictionary) -> Array[String]:
	var result: Array[String] = []
	if details.has("precipitation_amount") and is_finite_number(details["precipitation_amount"]):
		result.append("details.precipitation_amount")
	if details.has("probability_of_precipitation") and is_finite_number(details["probability_of_precipitation"]):
		result.append("details.probability_of_precipitation")
	return result


static func _standardized_precipitation_source_fields(period: Dictionary) -> Array[String]:
	var result: Array[String] = []
	if period.has("precipitation_amount_mm"):
		result.append("details.precipitation_amount")
	if period.has("precipitation_probability"):
		result.append("details.probability_of_precipitation")
	return result


static func _read_weather_symbol_periods(raw_data: Dictionary, valid_time: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for period_name in ["next_1_hours", "next_6_hours", "next_12_hours"]:
		var period: Variant = raw_data.get(period_name, {})
		if not period is Dictionary:
			continue
		var summary: Variant = period.get("summary", {})
		var symbol := str(summary.get("symbol_code", "")) if summary is Dictionary else ""
		if symbol.is_empty():
			continue
		var hours := int(period_name.trim_prefix("next_").trim_suffix("_hours"))
		# Symbol summaries describe their own next_* period, not the sample instant.
		var start_unix := parse_utc_timestamp_to_unix(valid_time)
		result.append({
			"duration_hours": hours,
			"period_start_utc": valid_time,
			"period_end_utc": _utc_iso_from_unix(start_unix + hours * 3600),
			"symbol_code": symbol,
			"source_period_key": period_name,
			"source_field": "summary.symbol_code",
		})
	return result


static func _copy_number(source: Dictionary, source_key: String, destination: Dictionary, destination_key: String) -> void:
	if source.has(source_key) and is_finite_number(source[source_key]):
		var value := float(source[source_key])
		destination[destination_key] = value


static func _copy_fraction(source: Dictionary, source_key: String, destination: Dictionary, destination_key: String) -> void:
	if not source.has(source_key):
		return
	if not is_finite_number(source[source_key]):
		return
	destination[destination_key] = float(source[source_key]) / 100.0


static func _copy_unit_metadata(units: Variant) -> Dictionary:
	if not units is Dictionary:
		return {}
	var result := {}
	for key in ["air_pressure_at_sea_level", "air_temperature", "cloud_area_fraction", "precipitation_amount", "probability_of_precipitation", "relative_humidity", "wind_from_direction", "wind_speed", "wind_speed_of_gust"]:
		if units.has(key):
			result[key] = str(units[key])
	return result


static func _utc_iso_from_unix(timestamp: int) -> String:
	var days := floori(float(timestamp) / 86400.0)
	var seconds_in_day := timestamp - days * 86400
	var civil := _civil_from_days(days)
	var hour := floori(float(seconds_in_day) / 3600.0)
	var minute := floori(float(seconds_in_day - hour * 3600) / 60.0)
	var second := seconds_in_day - hour * 3600 - minute * 60
	return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [civil["year"], civil["month"], civil["day"], hour, minute, second]


static func parse_utc_timestamp_to_unix_unchecked(base: String) -> int:
	return parse_utc_timestamp_to_unix(base + "Z")


static func _parse_utc_components(timestamp: String) -> Dictionary:
	var regex := RegEx.new()
	regex.compile("^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.\\d+)?Z$")
	var matched := regex.search(timestamp)
	if matched == null:
		return {}
	var year := int(matched.get_string(1))
	var month := int(matched.get_string(2))
	var day := int(matched.get_string(3))
	var hour := int(matched.get_string(4))
	var minute := int(matched.get_string(5))
	var second := int(matched.get_string(6))
	if year < 1 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59:
		return {}
	var days_in_month := [31, 29 if _is_leap_year(year) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if day < 1 or day > int(days_in_month[month - 1]):
		return {}
	return {"year": year, "month": month, "day": day, "hour": hour, "minute": minute, "second": second}


static func _is_leap_year(year: int) -> bool:
	return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


static func _days_from_civil(year_value: int, month: int, day: int) -> int:
	var year := year_value - (1 if month <= 2 else 0)
	var era := floori(float(year) / 400.0)
	var year_of_era := year - era * 400
	var adjusted_month := month + (-3 if month > 2 else 9)
	var day_of_year := floori((153.0 * float(adjusted_month) + 2.0) / 5.0) + day - 1
	var day_of_era := year_of_era * 365 + floori(float(year_of_era) / 4.0) - floori(float(year_of_era) / 100.0) + day_of_year
	return era * 146097 + day_of_era - 719468


static func _civil_from_days(days_since_epoch: int) -> Dictionary:
	var shifted_days := days_since_epoch + 719468
	var era := floori(float(shifted_days) / 146097.0)
	var day_of_era := shifted_days - era * 146097
	var year_of_era := floori((float(day_of_era) - float(day_of_era) / 1460.0 + float(day_of_era) / 36524.0 - float(day_of_era) / 146096.0) / 365.0)
	var year := year_of_era + era * 400
	var day_of_year := day_of_era - (365 * year_of_era + floori(float(year_of_era) / 4.0) - floori(float(year_of_era) / 100.0))
	var month_prime := floori((5.0 * float(day_of_year) + 2.0) / 153.0)
	var day := day_of_year - floori((153.0 * float(month_prime) + 2.0) / 5.0) + 1
	var month := month_prime + (3 if month_prime < 10 else -9)
	year += 1 if month <= 2 else 0
	return {"year": year, "month": month, "day": day}


static func is_finite_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))


static func _number_in_range(value: Variant, minimum: float, maximum: float) -> bool:
	return is_finite_number(value) and float(value) >= minimum and float(value) <= maximum
