extends RefCounted
class_name WorldTimeClientView

## Read-only client presentation clock. It consumes authority snapshots and
## advances from caller-supplied real (unscaled) elapsed seconds. It has no
## setters for authority-controlled values and no SceneTree/render dependency.

const WorldTimeManagerScript := preload("res://scripts/world_time_manager.gd")
const WorldTimeStateScript := preload("res://scripts/world_time_state.gd")
const SolarPositionScript := preload("res://scripts/solar_position.gd")
const DAY_CYCLE_SECONDS := 86400.0
const SNAPSHOT_SCHEMA_VERSION := 1
const SMALL_SYNC_ERROR_SECONDS := 2.0
const CORRECTION_DURATION_SECONDS := 0.75

var authority_session_id := ""
var authority_source := "Unknown"
var calendar_date: Dictionary = {}
var real_calendar_date: Dictionary = {}
var day_cycle_index := 0
var cycle_seconds := 0.0
var time_scale := 24.0
var paused := false
var state_revision := -1
var authority_control_revision := -1
var authority_snapshot_sequence := -1
var revision_reason := "uninitialized"
var authoritative_timestamp_utc := 0.0
var estimated_utc_timestamp := 0.0
var calendar_override_enabled := false
var calendar_override_date: Dictionary = {}
var local_day_cycle_ordinal := 0
var local_day_cycle_date: Dictionary = {}
var cycle_starts_by_local_date: Dictionary = {}

var is_initialized := false
var last_snapshot_rejection := ""
var last_sync_error_seconds := 0.0
var _phase_correction_remaining := 0.0
var _phase_correction_time_remaining := 0.0


## estimated_one_way_delay_seconds must come from the transport/RTT estimator.
## It is deliberately not guessed from a client wall clock.
func apply_authority_snapshot(snapshot: Dictionary, estimated_one_way_delay_seconds: float = 0.0) -> bool:
	if not _is_valid_snapshot(snapshot, estimated_one_way_delay_seconds):
		last_snapshot_rejection = "invalid_snapshot"
		return false

	var incoming_revision := int(snapshot.get("state_revision", -1))
	var incoming_timestamp := float(snapshot.get("authoritative_timestamp_utc", -1.0))
	var incoming_sequence := int(snapshot.get("authority_snapshot_sequence", -1))
	var incoming_session := str(snapshot.get("authority_session_id", "legacy-authority"))
	var same_session := is_initialized and incoming_session == authority_session_id
	if same_session:
		if incoming_revision < state_revision:
			last_snapshot_rejection = "older_revision"
			return false
		if incoming_sequence >= 0 and authority_snapshot_sequence >= 0 and incoming_sequence <= authority_snapshot_sequence:
			last_snapshot_rejection = "older_snapshot_sequence"
			return false
		if incoming_revision == state_revision and (incoming_sequence < 0 or authority_snapshot_sequence < 0) and incoming_timestamp <= authoritative_timestamp_utc:
			last_snapshot_rejection = "older_or_duplicate_timestamp"
			return false

	var previous_total := _absolute_cycle_seconds()
	var previous_cycle_index := day_cycle_index
	var previous_revision := state_revision
	var previous_control_revision := authority_control_revision
	var previous_reason := revision_reason
	var previous_override_enabled := calendar_override_enabled
	var previous_override_date := calendar_override_date.duplicate(true)
	var previous_session := authority_session_id
	var was_initialized := is_initialized

	_load_authority_state(snapshot)
	# Predict through packet transit using the snapshot's newly authoritative
	# scale/pause state, so clients with different packet delays land together.
	_advance_state(estimated_one_way_delay_seconds)
	var target_total := _absolute_cycle_seconds()
	var sync_error := target_total - previous_total
	last_sync_error_seconds = sync_error
	var new_authority_epoch := was_initialized and incoming_session != previous_session
	var incoming_control_revision := int(snapshot.get("authority_control_revision", -1))
	var explicit_authority_edit := same_session and (
		incoming_control_revision > previous_control_revision
		or not snapshot.has("authority_control_revision") and incoming_revision > previous_revision and revision_reason != "natural_cycle"
	)
	var calendar_edit := calendar_override_enabled != previous_override_enabled or calendar_override_date != previous_override_date
	var should_snap := not was_initialized or new_authority_epoch or explicit_authority_edit or calendar_edit or absf(sync_error) > SMALL_SYNC_ERROR_SECONDS or previous_cycle_index != day_cycle_index

	if should_snap:
		_set_absolute_cycle_seconds(target_total)
		_phase_correction_remaining = 0.0
		_phase_correction_time_remaining = 0.0
	else:
		# Keep the currently displayed phase and spread only small drift over a
		# short interval. Date, pause, scale, revision and override metadata above
		# already reflect the newest authority state.
		_set_absolute_cycle_seconds(previous_total)
		_phase_correction_remaining = sync_error
		_phase_correction_time_remaining = CORRECTION_DURATION_SECONDS if absf(sync_error) > 0.0001 else 0.0

	is_initialized = true
	last_snapshot_rejection = ""
	return true


## Pass real elapsed time, not Engine.time_scale-adjusted simulation time.
func advance(real_elapsed_seconds: float) -> void:
	if not is_initialized or not is_finite(real_elapsed_seconds) or real_elapsed_seconds <= 0.0:
		return
	_advance_state(real_elapsed_seconds)
	if absf(_phase_correction_remaining) > 0.0001 and _phase_correction_time_remaining > 0.0:
		var correction_fraction := minf(1.0, real_elapsed_seconds / _phase_correction_time_remaining)
		var correction := _phase_correction_remaining * correction_fraction
		_set_absolute_cycle_seconds(_absolute_cycle_seconds() + correction)
		_phase_correction_remaining -= correction
		_phase_correction_time_remaining = maxf(0.0, _phase_correction_time_remaining - real_elapsed_seconds)
	else:
		_phase_correction_remaining = 0.0
		_phase_correction_time_remaining = 0.0
	_refresh_calendar_fields()


func get_snapshot() -> Dictionary:
	if not is_initialized:
		return {}
	return {
		"snapshot_kind": "world_time_client_view",
		"authority_session_id": authority_session_id,
		"authority_source": authority_source,
		"calendar_date": calendar_date.duplicate(true),
		"real_calendar_date": real_calendar_date.duplicate(true),
		"day_cycle_index": day_cycle_index,
		"cycle_seconds": cycle_seconds,
		"time_scale": time_scale,
		"paused": paused,
		"state_revision": state_revision,
		"authority_control_revision": authority_control_revision,
		"authority_snapshot_sequence": authority_snapshot_sequence,
		"revision_reason": revision_reason,
		"authoritative_timestamp_utc": authoritative_timestamp_utc,
		"estimated_utc_timestamp": estimated_utc_timestamp,
		"calendar_override_enabled": calendar_override_enabled,
		"calendar_override_date": calendar_override_date.duplicate(true),
		"local_day_cycle_ordinal": local_day_cycle_ordinal,
		"local_day_cycle_date": local_day_cycle_date.duplicate(true),
		"cycle_starts_by_local_date": cycle_starts_by_local_date.duplicate(true),
	}


func get_solar_state(latitude_deg: float, longitude_deg: float) -> Dictionary:
	if not is_initialized:
		return {}
	return SolarPositionScript.calculate(calendar_date, cycle_seconds, latitude_deg, longitude_deg)


func get_sync_diagnostics() -> Dictionary:
	return {
		"initialized": is_initialized,
		"authority_session_id": authority_session_id,
		"state_revision": state_revision,
		"revision_reason": revision_reason,
		"last_sync_error_seconds": last_sync_error_seconds,
		"phase_correction_remaining_seconds": _phase_correction_remaining,
		"phase_correction_time_remaining_seconds": _phase_correction_time_remaining,
		"last_snapshot_rejection": last_snapshot_rejection,
	}


func _is_valid_snapshot(snapshot: Dictionary, delay_seconds: float) -> bool:
	if not is_finite(delay_seconds) or delay_seconds < 0.0:
		return false
	if str(snapshot.get("snapshot_kind", "")) != "world_time_authority":
		return false
	var snapshot_schema := int(snapshot.get("snapshot_schema_version", SNAPSHOT_SCHEMA_VERSION))
	var state_schema := int(snapshot.get("schema_version", -1))
	if snapshot_schema != SNAPSHOT_SCHEMA_VERSION:
		return false
	if state_schema < WorldTimeStateScript.MIN_SUPPORTED_SCHEMA_VERSION or state_schema > WorldTimeStateScript.SCHEMA_VERSION:
		return false
	for key in ["day_cycle_index", "cycle_seconds", "time_scale", "paused", "state_revision", "authoritative_timestamp_utc", "calendar_date"]:
		if not snapshot.has(key):
			return false
	if not is_finite(float(snapshot["cycle_seconds"])) or not is_finite(float(snapshot["time_scale"])):
		return false
	if float(snapshot["cycle_seconds"]) < 0.0 or float(snapshot["cycle_seconds"]) >= DAY_CYCLE_SECONDS:
		return false
	if int(snapshot["day_cycle_index"]) < 0 or int(snapshot["state_revision"]) < 0:
		return false
	if float(snapshot["time_scale"]) <= 0.0 or float(snapshot["time_scale"]) > 1000.0 or not is_finite(float(snapshot["authoritative_timestamp_utc"])):
		return false
	var date: Variant = snapshot["calendar_date"]
	if not date is Dictionary or not WorldTimeManagerScript.is_valid_gregorian_date(int(date.get("year", 0)), int(date.get("month", 0)), int(date.get("day", 0))):
		return false
	if bool(snapshot.get("calendar_override_enabled", false)):
		var override_date: Variant = snapshot.get("calendar_override_date", {})
		if not override_date is Dictionary or not WorldTimeManagerScript.is_valid_gregorian_date(int(override_date.get("year", 0)), int(override_date.get("month", 0)), int(override_date.get("day", 0))):
			return false
	if snapshot.has("authority_sync_anchor"):
		var anchor: Variant = snapshot["authority_sync_anchor"]
		if not anchor is Dictionary or str(anchor.get("clock", "")) != "utc_unix_seconds":
			return false
		if int(anchor.get("state_revision", -1)) != int(snapshot["state_revision"]):
			return false
		if snapshot.has("authority_control_revision") and int(anchor.get("authority_control_revision", -1)) != int(snapshot["authority_control_revision"]):
			return false
		if not is_equal_approx(float(anchor.get("cycle_seconds", NAN)), float(snapshot["cycle_seconds"])):
			return false
		if int(anchor.get("day_cycle_index", -1)) != int(snapshot["day_cycle_index"]):
			return false
		if not is_equal_approx(float(anchor.get("time_scale", NAN)), float(snapshot["time_scale"])) or bool(anchor.get("paused", not bool(snapshot["paused"]))) != bool(snapshot["paused"]):
			return false
		if not is_equal_approx(float(anchor.get("authoritative_timestamp_utc", NAN)), float(snapshot["authoritative_timestamp_utc"])):
			return false
		if snapshot.has("authority_snapshot_sequence") and int(anchor.get("authority_snapshot_sequence", -1)) != int(snapshot["authority_snapshot_sequence"]):
			return false
	return true


func _load_authority_state(snapshot: Dictionary) -> void:
	authority_session_id = str(snapshot.get("authority_session_id", "legacy-authority"))
	authority_source = str(snapshot.get("authority_source", "Unknown"))
	calendar_date = snapshot.get("calendar_date", {}).duplicate(true)
	real_calendar_date = snapshot.get("real_calendar_date", {}).duplicate(true)
	day_cycle_index = maxi(0, int(snapshot.get("day_cycle_index", 0)))
	cycle_seconds = fposmod(float(snapshot.get("cycle_seconds", 0.0)), DAY_CYCLE_SECONDS)
	time_scale = float(snapshot.get("time_scale", 24.0))
	paused = bool(snapshot.get("paused", false))
	state_revision = int(snapshot.get("state_revision", 0))
	authority_control_revision = int(snapshot.get("authority_control_revision", -1))
	authority_snapshot_sequence = int(snapshot.get("authority_snapshot_sequence", -1))
	revision_reason = str(snapshot.get("revision_reason", "legacy_restore"))
	authoritative_timestamp_utc = float(snapshot.get("authoritative_timestamp_utc", 0.0))
	estimated_utc_timestamp = authoritative_timestamp_utc
	calendar_override_enabled = bool(snapshot.get("calendar_override_enabled", false))
	calendar_override_date = snapshot.get("calendar_override_date", {}).duplicate(true)
	local_day_cycle_ordinal = maxi(0, int(snapshot.get("local_day_cycle_ordinal", 0)))
	local_day_cycle_date = snapshot.get("local_day_cycle_date", {}).duplicate(true)
	var history: Variant = snapshot.get("cycle_starts_by_local_date", {})
	cycle_starts_by_local_date = history.duplicate(true) if history is Dictionary else {}
	if not local_day_cycle_date.is_empty() and local_day_cycle_ordinal > 0:
		var ordinal_key := WorldTimeManagerScript.date_key(local_day_cycle_date)
		if not cycle_starts_by_local_date.has(ordinal_key):
			cycle_starts_by_local_date[ordinal_key] = local_day_cycle_ordinal
	if snapshot.has("authority_sync_anchor"):
		var anchor: Dictionary = snapshot["authority_sync_anchor"]
		authoritative_timestamp_utc = float(anchor.get("authoritative_timestamp_utc", authoritative_timestamp_utc))
		estimated_utc_timestamp = authoritative_timestamp_utc


func _advance_state(real_elapsed_seconds: float) -> void:
	if real_elapsed_seconds <= 0.0:
		_refresh_calendar_fields()
		return
	var start_utc := estimated_utc_timestamp
	if not paused:
		var remaining_real := real_elapsed_seconds
		var wraps := 0
		while remaining_real > 0.0:
			var to_wrap_game := DAY_CYCLE_SECONDS - cycle_seconds
			var to_wrap_real := to_wrap_game / time_scale
			if remaining_real + 0.0000001 < to_wrap_real:
				cycle_seconds += remaining_real * time_scale
				remaining_real = 0.0
			else:
				remaining_real = maxf(0.0, remaining_real - to_wrap_real)
				estimated_utc_timestamp = start_utc + (real_elapsed_seconds - remaining_real)
				day_cycle_index += 1
				_record_cycle_start(estimated_utc_timestamp)
				cycle_seconds = 0.0
				wraps += 1
				if wraps >= 1000:
					break
	estimated_utc_timestamp = start_utc + real_elapsed_seconds
	_refresh_calendar_fields()


func _record_cycle_start(utc_timestamp: float) -> void:
	var date := WorldTimeManagerScript.stockholm_date_from_utc(utc_timestamp)
	var key := WorldTimeManagerScript.date_key(date)
	cycle_starts_by_local_date[key] = int(cycle_starts_by_local_date.get(key, 0)) + 1
	_prune_cycle_history(date)


func _prune_cycle_history(_today: Dictionary) -> void:
	var keys: Array[String] = []
	for key in cycle_starts_by_local_date.keys():
		var text_key := str(key)
		if text_key.begins_with("20") or text_key.begins_with("19"):
			keys.append(text_key)
	keys.sort()
	while keys.size() > 45:
		cycle_starts_by_local_date.erase(keys.pop_front())


func _refresh_calendar_fields() -> void:
	real_calendar_date = WorldTimeManagerScript.stockholm_date_from_utc(estimated_utc_timestamp)
	calendar_date = calendar_override_date.duplicate(true) if calendar_override_enabled else real_calendar_date.duplicate(true)
	local_day_cycle_date = real_calendar_date.duplicate(true)
	var key := WorldTimeManagerScript.date_key(real_calendar_date)
	var derived_ordinal := int(cycle_starts_by_local_date.get(key, 0))
	# Snapshot ordinal is retained when there is no local history entry for this
	# date; cycles naturally started after this anchor are tracked in the map.
	local_day_cycle_ordinal = derived_ordinal


func _absolute_cycle_seconds() -> float:
	return float(day_cycle_index) * DAY_CYCLE_SECONDS + cycle_seconds


func _set_absolute_cycle_seconds(value: float) -> void:
	var safe_value := maxf(0.0, value)
	day_cycle_index = int(floor(safe_value / DAY_CYCLE_SECONDS))
	cycle_seconds = fposmod(safe_value, DAY_CYCLE_SECONDS)
	_refresh_calendar_fields()
