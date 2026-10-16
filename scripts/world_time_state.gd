extends RefCounted
class_name WorldTimeState

## Serializable data only. Runtime clocks and rendering objects are owned by the manager.

const SCHEMA_VERSION := 2
const MIN_SUPPORTED_SCHEMA_VERSION := 1
const DEFAULT_TIME_SCALE := 24.0

var calendar_date: Dictionary = {}
var real_calendar_date: Dictionary = {}
var day_cycle_index: int = 0
var cycle_seconds: float = 0.0
var time_scale: float = DEFAULT_TIME_SCALE
var paused: bool = false
var authoritative_timestamp_utc: float = 0.0
var monotonic_anchor_usec: int = 0
var state_revision: int = 0
## Advances only for authoritative controls; natural cycle wraps do not change it.
var authority_control_revision: int = 0
## Identifies whether the latest revision is a natural wrap or an authoritative edit.
## Network views use this to distinguish drift correction from an administrator jump.
var revision_reason: String = "initial"
var calendar_override_enabled: bool = false
var calendar_override_date: Dictionary = {}
var local_day_cycle_ordinal: int = 0
var local_day_cycle_date: Dictionary = {}
var cycle_starts_by_local_date: Dictionary = {}
var last_real_delta_seconds: float = 0.0


func to_dictionary() -> Dictionary:
	return {
		"schema_version": SCHEMA_VERSION,
		"calendar_date": calendar_date.duplicate(true),
		"real_calendar_date": real_calendar_date.duplicate(true),
		"day_cycle_index": day_cycle_index,
		"cycle_seconds": cycle_seconds,
		"time_scale": time_scale,
		"paused": paused,
		"authoritative_timestamp_utc": authoritative_timestamp_utc,
		"monotonic_anchor_usec": monotonic_anchor_usec,
		"state_revision": state_revision,
		"authority_control_revision": authority_control_revision,
		"revision_reason": revision_reason,
		"calendar_override_enabled": calendar_override_enabled,
		"calendar_override_date": calendar_override_date.duplicate(true),
		"local_day_cycle_ordinal": local_day_cycle_ordinal,
		"local_day_cycle_date": local_day_cycle_date.duplicate(true),
		"cycle_starts_by_local_date": cycle_starts_by_local_date.duplicate(true),
	}


static func from_dictionary(data: Dictionary) -> WorldTimeState:
	var result := WorldTimeState.new()
	result.calendar_date = _valid_date(data.get("calendar_date", {}))
	result.real_calendar_date = _valid_date(data.get("real_calendar_date", {}))
	result.day_cycle_index = maxi(0, int(data.get("day_cycle_index", 0)))
	result.cycle_seconds = fposmod(float(data.get("cycle_seconds", 0.0)), 86400.0)
	result.time_scale = maxf(0.001, float(data.get("time_scale", DEFAULT_TIME_SCALE)))
	result.paused = bool(data.get("paused", false))
	result.authoritative_timestamp_utc = float(data.get("authoritative_timestamp_utc", 0.0))
	result.monotonic_anchor_usec = int(data.get("monotonic_anchor_usec", 0))
	result.state_revision = maxi(0, int(data.get("state_revision", 0)))
	result.authority_control_revision = maxi(0, int(data.get("authority_control_revision", 0)))
	result.revision_reason = str(data.get("revision_reason", "legacy_restore"))
	result.calendar_override_enabled = bool(data.get("calendar_override_enabled", false))
	result.calendar_override_date = _valid_date(data.get("calendar_override_date", {}))
	result.local_day_cycle_ordinal = maxi(0, int(data.get("local_day_cycle_ordinal", 0)))
	result.local_day_cycle_date = _valid_date(data.get("local_day_cycle_date", {}))
	var starts: Variant = data.get("cycle_starts_by_local_date", {})
	if starts is Dictionary:
		result.cycle_starts_by_local_date = starts.duplicate(true)
	return result


static func _valid_date(value: Variant) -> Dictionary:
	if value is not Dictionary:
		return {}
	var date: Dictionary = value
	if not date.has("year") or not date.has("month") or not date.has("day"):
		return {}
	return {
		"year": int(date["year"]),
		"month": int(date["month"]),
		"day": int(date["day"]),
	}
