extends Node

## World clock service. The day-cycle uses a monotonic clock; calendar dates use UTC wall time.
## This script has no references to scene presentation, cameras, or rendering devices.

signal state_changed(snapshot: Dictionary)

const WorldTimeStateScript = preload("res://scripts/world_time_state.gd")
const LocalAuthorityScript = preload("res://scripts/local_authority.gd")

const SAVE_PATH := "user://world_time_state.json"
const DAY_CYCLE_SECONDS := 86400.0
const CALENDAR_TIMEZONE := "Europe/Stockholm"
const MAX_DAILY_HISTORY_DAYS := 45
const AUTOSAVE_INTERVAL_SECONDS := 30.0
const SNAPSHOT_SCHEMA_VERSION := 1

var state: WorldTimeState
var authority_name := "LocalAuthority"
var autosave_enabled := true
var authority_session_id := ""

var _authority: LocalAuthority
var _last_monotonic_usec: int = 0
var _last_wall_utc: float = 0.0
var _autosave_elapsed: float = 0.0
var _runtime_started := false
var _snapshot_sequence := 0


func _ready() -> void:
	initialize_runtime(true)


func _process(_delta: float) -> void:
	if not _runtime_started:
		return
	update_time()
	_autosave_elapsed += state.last_real_delta_seconds
	if autosave_enabled and _autosave_elapsed >= AUTOSAVE_INTERVAL_SECONDS:
		_autosave_elapsed = 0.0
		save_state()


func _exit_tree() -> void:
	if _runtime_started and autosave_enabled:
		update_time()
		save_state()


## Allows deterministic tests or a future server clock to inject time without waiting.
## Call before initialize_runtime().
func set_clock_sources(monotonic_usec_source: Callable, utc_unix_source: Callable) -> void:
	if _runtime_started:
		return
	if _authority == null:
		_authority = LocalAuthorityScript.new()
	_authority.set_clock_sources(monotonic_usec_source, utc_unix_source)


func initialize_runtime(load_persisted_state: bool = true) -> void:
	if _runtime_started:
		return
	if _authority == null:
		_authority = LocalAuthorityScript.new()
	var monotonic_now := _authority.get_monotonic_usec()
	var wall_now := _authority.get_utc_unix_time()
	if authority_session_id.is_empty():
		authority_session_id = "local-%d-%d-%d" % [int(floor(wall_now)), monotonic_now, get_instance_id()]
	var restored := false
	if load_persisted_state:
		var saved := _read_saved_dictionary(SAVE_PATH)
		if not saved.is_empty():
			restored = _apply_persisted_dictionary(saved, monotonic_now, wall_now)
	if not restored:
		state = WorldTimeStateScript.new()
		state.day_cycle_index = 0
		state.cycle_seconds = 0.0
		state.time_scale = WorldTimeStateScript.DEFAULT_TIME_SCALE
		state.paused = false
		state.state_revision = 1
		state.revision_reason = "runtime_start"
		state.authoritative_timestamp_utc = wall_now
		state.monotonic_anchor_usec = monotonic_now
		state.real_calendar_date = stockholm_date_from_utc(wall_now)
		state.calendar_date = state.real_calendar_date.duplicate(true)
		_record_cycle_start(wall_now, "initial")
	_last_monotonic_usec = monotonic_now
	_last_wall_utc = wall_now
	_runtime_started = true
	_refresh_calendar_state(wall_now)
	set_process(true)


## Advances cycle time from monotonic elapsed time and refreshes calendar from UTC wall time.
func update_time() -> WorldTimeState:
	if not _runtime_started:
		initialize_runtime(false)
	var monotonic_now := _authority.get_monotonic_usec()
	var wall_now := _authority.get_utc_unix_time()
	var monotonic_delta := monotonic_now - _last_monotonic_usec
	var real_delta := maxf(0.0, float(monotonic_delta) / 1000000.0)
	if monotonic_delta < 0:
		# A faulty injected source must not reverse the day-cycle.
		_last_monotonic_usec = monotonic_now
	state.last_real_delta_seconds = real_delta
	var old_calendar_key := date_key(state.real_calendar_date)
	var old_cycle_index := state.day_cycle_index
	if not state.paused and real_delta > 0.0:
		_advance_cycle(real_delta, wall_now)
	state.authoritative_timestamp_utc = wall_now
	state.monotonic_anchor_usec = monotonic_now
	_last_monotonic_usec = monotonic_now
	_last_wall_utc = wall_now
	_refresh_calendar_state(wall_now)
	if old_calendar_key != date_key(state.real_calendar_date) or old_cycle_index != state.day_cycle_index:
		state_changed.emit(create_snapshot(false))
	return state


func get_time_state() -> WorldTimeState:
	return update_time()


func get_authoritative_state() -> Dictionary:
	update_time()
	return create_snapshot(false)


func get_real_utc_timestamp() -> float:
	return _authority.get_utc_unix_time() if _authority != null else Time.get_unix_time_from_system()


func get_real_calendar_date() -> Dictionary:
	return stockholm_date_from_utc(get_real_utc_timestamp())


func get_calendar_date() -> Dictionary:
	update_time()
	return state.calendar_date.duplicate(true)


func get_day_cycle_ordinal_today() -> int:
	update_time()
	return state.local_day_cycle_ordinal


func get_cycle_time_dictionary() -> Dictionary:
	update_time()
	var whole_seconds := int(floor(state.cycle_seconds))
	return {
		"hour": int(whole_seconds / 3600),
		"minute": int((whole_seconds % 3600) / 60),
		"second": whole_seconds % 60,
		"cycle_seconds": state.cycle_seconds,
	}


func get_last_real_delta_seconds() -> float:
	return state.last_real_delta_seconds if state != null else 0.0


func set_cycle_seconds(seconds: float) -> bool:
	if not is_finite(seconds):
		return false
	update_time()
	state.cycle_seconds = fposmod(seconds, DAY_CYCLE_SECONDS)
	state.state_revision += 1
	state.authority_control_revision += 1
	state.revision_reason = "cycle_time_set"
	_commit_local_change()
	return true


func set_cycle_time(hour: int, minute: int, second: float = 0.0) -> bool:
	if hour < 0 or hour > 23 or minute < 0 or minute > 59 or not is_finite(second) or second < 0.0 or second >= 60.0:
		return false
	return set_cycle_seconds(float(hour * 3600 + minute * 60) + second)


func set_time_scale(scale: float) -> bool:
	if not is_finite(scale) or scale <= 0.0 or scale > 1000.0:
		return false
	update_time()
	if is_equal_approx(state.time_scale, scale):
		return true
	state.time_scale = scale
	state.state_revision += 1
	state.authority_control_revision += 1
	state.revision_reason = "time_scale_set"
	_commit_local_change()
	return true


func pause_time() -> void:
	update_time()
	if state.paused:
		return
	state.paused = true
	state.state_revision += 1
	state.authority_control_revision += 1
	state.revision_reason = "paused"
	_commit_local_change()


func resume_time() -> void:
	update_time()
	if not state.paused:
		return
	state.paused = false
	state.state_revision += 1
	state.authority_control_revision += 1
	state.revision_reason = "resumed"
	_commit_local_change()


func set_calendar_date(year: int, month: int, day: int) -> bool:
	if not is_valid_gregorian_date(year, month, day):
		return false
	update_time()
	state.calendar_override_enabled = true
	state.calendar_override_date = {"year": year, "month": month, "day": day}
	state.calendar_date = state.calendar_override_date.duplicate(true)
	state.state_revision += 1
	state.authority_control_revision += 1
	state.revision_reason = "calendar_override_set"
	_commit_local_change()
	return true


func clear_calendar_override() -> void:
	update_time()
	if not state.calendar_override_enabled:
		return
	state.calendar_override_enabled = false
	state.calendar_override_date.clear()
	state.calendar_date = state.real_calendar_date.duplicate(true)
	state.state_revision += 1
	state.authority_control_revision += 1
	state.revision_reason = "calendar_override_cleared"
	_commit_local_change()


## A manual jump changes phase only. It never counts as a naturally completed cycle.
func set_day_cycle_time(hour: int, minute: int, second: float = 0.0) -> bool:
	return set_cycle_time(hour, minute, second)


func create_snapshot(sync_first: bool = true) -> Dictionary:
	if sync_first and _runtime_started:
		update_time()
	if state == null:
		return {}
	_snapshot_sequence += 1
	var snapshot := state.to_dictionary()
	snapshot["snapshot_kind"] = "world_time_authority"
	snapshot["snapshot_schema_version"] = SNAPSHOT_SCHEMA_VERSION
	snapshot["authority_source"] = "Server" if authority_name.to_lower().contains("server") else "Local"
	snapshot["authority_session_id"] = authority_session_id
	snapshot["authority_snapshot_sequence"] = _snapshot_sequence
	# The monotonic clock is process-local and never crosses the wire. This UTC
	# anchor identifies the state sample; clients add measured transport delay and
	# then advance using their own monotonic elapsed time.
	snapshot["authority_sync_anchor"] = {
		"clock": "utc_unix_seconds",
		"authoritative_timestamp_utc": state.authoritative_timestamp_utc,
		"day_cycle_index": state.day_cycle_index,
		"cycle_seconds": state.cycle_seconds,
		"time_scale": state.time_scale,
		"paused": state.paused,
		"state_revision": state.state_revision,
		"authority_control_revision": state.authority_control_revision,
		"authority_snapshot_sequence": _snapshot_sequence,
	}
	# A monotonic clock anchor is local to one process and is deliberately not transferable.
	snapshot.erase("monotonic_anchor_usec")
	return snapshot


func restore_snapshot(snapshot: Dictionary, advance_from_authoritative_timestamp: bool = false) -> bool:
	if not _is_supported_state_dictionary(snapshot) or not _is_supported_snapshot(snapshot):
		return false
	var restored_state: WorldTimeState = WorldTimeStateScript.from_dictionary(snapshot)
	if restored_state.calendar_date.is_empty() or restored_state.real_calendar_date.is_empty():
		return false
	var now_mono := _authority.get_monotonic_usec() if _authority != null else Time.get_ticks_usec()
	var now_utc := _authority.get_utc_unix_time() if _authority != null else Time.get_unix_time_from_system()
	state = restored_state
	authority_session_id = str(snapshot.get("authority_session_id", authority_session_id))
	_snapshot_sequence = int(snapshot.get("authority_snapshot_sequence", _snapshot_sequence))
	if authority_session_id.is_empty():
		authority_session_id = "restored-local-%d" % get_instance_id()
	if advance_from_authoritative_timestamp and not state.paused:
		var catchup_seconds := maxf(0.0, now_utc - state.authoritative_timestamp_utc)
		_advance_cycle(catchup_seconds, now_utc, state.authoritative_timestamp_utc)
	state.authoritative_timestamp_utc = now_utc
	state.monotonic_anchor_usec = now_mono
	_refresh_calendar_state(now_utc)
	_last_monotonic_usec = now_mono
	_last_wall_utc = now_utc
	_runtime_started = true
	_commit_local_change()
	return true


func save_state(path: String = SAVE_PATH) -> bool:
	if _runtime_started:
		update_time()
	if state == null:
		return false
	var payload := state.to_dictionary()
	payload["save_format"] = "world_time_state"
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Could not save world time state: %s" % FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	return true


func load_state(path: String = SAVE_PATH) -> bool:
	var payload := _read_saved_dictionary(path)
	if payload.is_empty():
		return false
	var mono_now := _authority.get_monotonic_usec() if _authority != null else Time.get_ticks_usec()
	var wall_now := _authority.get_utc_unix_time() if _authority != null else Time.get_unix_time_from_system()
	var loaded := _apply_persisted_dictionary(payload, mono_now, wall_now)
	if loaded:
		_runtime_started = true
		_last_monotonic_usec = mono_now
		_last_wall_utc = wall_now
		set_process(true)
		_commit_local_change()
	return loaded


func get_persistence_dictionary() -> Dictionary:
	update_time()
	var payload := state.to_dictionary()
	payload["save_format"] = "world_time_state"
	return payload


static func stockholm_date_from_utc(utc_unix_time: float) -> Dictionary:
	var offset := stockholm_offset_seconds_at_utc(utc_unix_time)
	var local_fields := Time.get_datetime_dict_from_unix_time(int(floor(utc_unix_time)) + offset)
	return {"year": int(local_fields["year"]), "month": int(local_fields["month"]), "day": int(local_fields["day"])}


## Current Europe/Stockholm civil-time rules: CET (UTC+1) and CEST (UTC+2), EU DST transitions.
static func stockholm_offset_seconds_at_utc(utc_unix_time: float) -> int:
	var utc_fields := Time.get_datetime_dict_from_unix_time(int(floor(utc_unix_time)))
	var year := int(utc_fields["year"])
	var month := int(utc_fields["month"])
	var day := int(utc_fields["day"])
	var hour := int(utc_fields["hour"])
	if month < 3 or month > 10:
		return 3600
	if month > 3 and month < 10:
		return 7200
	var transition_month := 3 if month == 3 else 10
	var transition_day := _last_sunday_of_month(year, transition_month)
	if day < transition_day:
		return 3600 if month == 3 else 7200
	if day > transition_day:
		return 7200 if month == 3 else 3600
	if hour < 1:
		return 3600 if month == 3 else 7200
	return 7200 if month == 3 else 3600


## Returns the Europe/Stockholm UTC offset for a civil date and a 24-hour
## simulation clock. On the two DST transition dates the post-transition
## offset is used for the whole accelerated cycle, avoiding a one-hour visual
## jump as the simulated clock passes a skipped or repeated civil hour.
static func stockholm_offset_seconds_for_civil_time(date: Dictionary, _local_seconds: float) -> int:
	var year := int(date.get("year", 0))
	var month := int(date.get("month", 0))
	var day := int(date.get("day", 0))
	if not is_valid_gregorian_date(year, month, day):
		return 0
	if month < 3 or month > 10:
		return 3600
	if month > 3 and month < 10:
		return 7200
	var transition_day := _last_sunday_of_month(year, month)
	if day < transition_day:
		return 3600 if month == 3 else 7200
	if day > transition_day:
		return 7200 if month == 3 else 3600
	# The accelerated clock always has 24 distinct hours. On a transition date,
	# use that date's post-transition offset for the full cycle.
	return 7200 if month == 3 else 3600


## Converts Stockholm civil date + simulated day-cycle time to a UTC timestamp.
## The Gregorian calendar is treated as proleptic, as in the solar calculator.
static func stockholm_civil_datetime_to_utc(date: Dictionary, local_seconds: float) -> float:
	if not is_valid_gregorian_date(int(date.get("year", 0)), int(date.get("month", 0)), int(date.get("day", 0))) or not is_finite(local_seconds):
		return NAN
	var normalized_seconds := fposmod(local_seconds, DAY_CYCLE_SECONDS)
	var whole_seconds := int(floor(normalized_seconds))
	var fields := {
		"year": int(date["year"]),
		"month": int(date["month"]),
		"day": int(date["day"]),
		"hour": int(whole_seconds / 3600),
		"minute": int((whole_seconds % 3600) / 60),
		"second": whole_seconds % 60,
	}
	var fractional_second := normalized_seconds - float(whole_seconds)
	var local_as_utc := float(Time.get_unix_time_from_datetime_dict(fields)) + fractional_second
	var offset := stockholm_offset_seconds_for_civil_time(date, normalized_seconds)
	return local_as_utc - float(offset)


static func date_key(date: Dictionary) -> String:
	if date.is_empty():
		return ""
	return "%04d-%02d-%02d" % [int(date.get("year", 0)), int(date.get("month", 0)), int(date.get("day", 0))]


static func is_valid_gregorian_date(year: int, month: int, day: int) -> bool:
	if year < 1 or year > 9999 or month < 1 or month > 12 or day < 1:
		return false
	var month_days := [31, 29 if _is_leap_year(year) else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	return day <= int(month_days[month - 1])


func _advance_cycle(real_delta: float, wall_now: float, wall_start: float = -1.0) -> void:
	if real_delta <= 0.0 or state.paused:
		return
	var old_cycle_seconds := state.cycle_seconds
	var game_delta := real_delta * state.time_scale
	var total := old_cycle_seconds + game_delta
	var wraps := int(floor(total / DAY_CYCLE_SECONDS))
	if wraps <= 0:
		state.cycle_seconds = total
		return
	var start_utc := _last_wall_utc if wall_start < 0.0 else wall_start
	var utc_delta := wall_now - start_utc
	var utc_per_monotonic_second := utc_delta / real_delta
	var wall_clock_adjusted := absf(utc_delta - real_delta) > maxf(2.0, real_delta * 0.1)
	for wrap_index in range(wraps):
		var game_seconds_to_boundary := DAY_CYCLE_SECONDS * float(wrap_index + 1) - old_cycle_seconds
		var real_seconds_to_boundary := game_seconds_to_boundary / state.time_scale
		var event_utc := wall_now - (real_delta - real_seconds_to_boundary) if wall_clock_adjusted else start_utc + real_seconds_to_boundary * utc_per_monotonic_second
		state.day_cycle_index += 1
		_record_cycle_start(event_utc, "natural")
	state.cycle_seconds = fposmod(total, DAY_CYCLE_SECONDS)
	state.state_revision += wraps
	state.revision_reason = "natural_cycle"


func _record_cycle_start(utc_timestamp: float, reason: String) -> void:
	var local_date := stockholm_date_from_utc(utc_timestamp)
	var key := date_key(local_date)
	state.cycle_starts_by_local_date[key] = int(state.cycle_starts_by_local_date.get(key, 0)) + 1
	state.cycle_starts_by_local_date["_last_start"] = {
		"utc_timestamp": utc_timestamp,
		"day_cycle_index": state.day_cycle_index,
		"reason": reason,
	}
	_prune_cycle_history(local_date)


func _prune_cycle_history(_today: Dictionary) -> void:
	var keys: Array[String] = []
	for key in state.cycle_starts_by_local_date.keys():
		if str(key).begins_with("20") or str(key).begins_with("19"):
			keys.append(str(key))
	keys.sort()
	while keys.size() > MAX_DAILY_HISTORY_DAYS:
		state.cycle_starts_by_local_date.erase(keys.pop_front())


func _refresh_calendar_state(wall_now: float) -> void:
	state.real_calendar_date = stockholm_date_from_utc(wall_now)
	state.calendar_date = state.calendar_override_date.duplicate(true) if state.calendar_override_enabled else state.real_calendar_date.duplicate(true)
	state.local_day_cycle_date = state.real_calendar_date.duplicate(true)
	state.local_day_cycle_ordinal = int(state.cycle_starts_by_local_date.get(date_key(state.real_calendar_date), 0))


func _apply_persisted_dictionary(payload: Dictionary, monotonic_now: int, wall_now: float) -> bool:
	if not _is_supported_state_dictionary(payload):
		push_warning("World time save has a missing or unsupported schema/state; starting with local defaults.")
		return false
	var loaded: WorldTimeState = WorldTimeStateScript.from_dictionary(payload)
	if (
		not is_finite(loaded.cycle_seconds)
		or loaded.cycle_seconds < 0.0
		or loaded.cycle_seconds >= DAY_CYCLE_SECONDS
		or not is_finite(loaded.time_scale)
		or loaded.time_scale <= 0.0
		or loaded.time_scale > 1000.0
		or loaded.day_cycle_index < 0
		or loaded.calendar_override_enabled and not is_valid_gregorian_date(
			int(loaded.calendar_override_date.get("year", 0)),
			int(loaded.calendar_override_date.get("month", 0)),
			int(loaded.calendar_override_date.get("day", 0))
		)
	):
		push_warning("World time save contains invalid values; starting with local defaults.")
		return false
	state = loaded
	if int(payload.get("schema_version", -1)) < WorldTimeStateScript.SCHEMA_VERSION:
		state.revision_reason = "legacy_restore"
	# Offline time does not advance the day-cycle; only the wall-clock calendar is refreshed.
	state.authoritative_timestamp_utc = wall_now
	state.monotonic_anchor_usec = monotonic_now
	_refresh_calendar_state(wall_now)
	return true


func _read_saved_dictionary(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Could not read world time state: %s" % FileAccess.get_open_error())
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is Dictionary:
		return parsed
	push_warning("World time state file is not a valid JSON object; starting with local defaults.")
	return {}


func _is_supported_state_dictionary(payload: Dictionary) -> bool:
	var schema := int(payload.get("schema_version", -1))
	if schema < WorldTimeStateScript.MIN_SUPPORTED_SCHEMA_VERSION or schema > WorldTimeStateScript.SCHEMA_VERSION:
		return false
	# These fields existed in the first released format and are necessary to
	# restore meaningful time. Newer metadata remains optional for v1 migration.
	for key in ["day_cycle_index", "cycle_seconds", "time_scale", "paused"]:
		if not payload.has(key):
			return false
	if not is_finite(float(payload.get("cycle_seconds", NAN))) or not is_finite(float(payload.get("time_scale", NAN))):
		return false
	return true


func _is_supported_snapshot(snapshot: Dictionary) -> bool:
	if snapshot.has("snapshot_schema_version") and int(snapshot["snapshot_schema_version"]) != SNAPSHOT_SCHEMA_VERSION:
		return false
	if snapshot.has("snapshot_kind") and str(snapshot["snapshot_kind"]) != "world_time_authority":
		return false
	if snapshot.has("authority_sync_anchor"):
		var anchor: Variant = snapshot["authority_sync_anchor"]
		if not anchor is Dictionary or str(anchor.get("clock", "")) != "utc_unix_seconds":
			return false
	return true


func _commit_local_change() -> void:
	if _runtime_started:
		state.authoritative_timestamp_utc = _authority.get_utc_unix_time()
		state.monotonic_anchor_usec = _authority.get_monotonic_usec()
		_last_wall_utc = state.authoritative_timestamp_utc
		_last_monotonic_usec = state.monotonic_anchor_usec
	if autosave_enabled:
		save_state()
	state_changed.emit(create_snapshot(false))


static func _last_sunday_of_month(year: int, month: int) -> int:
	var last_day := 31 if month in [3, 10] else 30
	var last_day_unix := Time.get_unix_time_from_datetime_dict({
		"year": year,
		"month": month,
		"day": last_day,
		"hour": 0,
		"minute": 0,
		"second": 0,
	})
	var weekday_sunday_zero := posmod(int(floor(last_day_unix / 86400.0)) + 4, 7)
	return last_day - weekday_sunday_zero


static func _is_leap_year(year: int) -> bool:
	return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
