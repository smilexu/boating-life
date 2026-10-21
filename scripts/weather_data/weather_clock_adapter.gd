extends RefCounted
class_name WeatherClockAdapter

## Wall clock used only for retrieval and cache metadata. Simulated weather
## clocks belong to WeatherSimulationCore, not this provider.


func now_unix_seconds() -> int:
	return int(Time.get_unix_time_from_system())


func now_utc_iso() -> String:
	var values := Time.get_datetime_dict_from_system(true)
	return "%04d-%02d-%02dT%02d:%02d:%02dZ" % [values.year, values.month, values.day, values.hour, values.minute, values.second]
