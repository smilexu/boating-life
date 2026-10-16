extends RefCounted
class_name LocalAuthority

## Temporary single-player clock authority. Its injectable sources also make time tests deterministic.

var _monotonic_source: Callable
var _utc_source: Callable


func set_clock_sources(monotonic_usec_source: Callable, utc_unix_source: Callable) -> void:
	_monotonic_source = monotonic_usec_source
	_utc_source = utc_unix_source


func get_monotonic_usec() -> int:
	if _monotonic_source.is_valid():
		return int(_monotonic_source.call())
	return Time.get_ticks_usec()


func get_utc_unix_time() -> float:
	if _utc_source.is_valid():
		return float(_utc_source.call())
	return Time.get_unix_time_from_system()
