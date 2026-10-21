extends Node
class_name WeatherRuntimeAuthority

## Local single-player authority for the MET forecast -> deterministic timeline
## -> formal runtime weather pipeline. Provider, core, and the Godot adapter are
## replaceable boundaries for a future server-owned implementation.

const ProviderScript := preload("res://scripts/weather_data/weather_data_provider.gd")
const HttpAdapterScript := preload("res://scripts/weather_data/met_norway_http_adapter.gd")
const CacheStoreScript := preload("res://scripts/weather_data/weather_file_cache_store.gd")
const ClockAdapterScript := preload("res://scripts/weather_data/weather_clock_adapter.gd")
const RetrySchedulerScript := preload("res://scripts/weather_data/weather_retry_scheduler.gd")
const UserAgentSettings := preload("res://scripts/weather_data/weather_user_agent_settings.gd")
const Core := preload("res://scripts/weather_data/weather_simulation_core.gd")
const Codec := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const CalendarAdapter := preload("res://scripts/weather_runtime/weather_stockholm_calendar_adapter.gd")
const PersistenceScript := preload("res://scripts/weather_runtime/weather_runtime_persistence.gd")
const WorldTimeManagerScript := preload("res://scripts/world_time_manager.gd")

@export var weather_region: WeatherRegion
@export_node_path("Node") var world_time_manager_path := NodePath("../../WorldTimeManager")
@export_node_path("Node") var godot_adapter_path := NodePath("../WeatherRuntimeGodotAdapter")
@export_range(12, 24, 12) var cycles_per_real_day := 24
@export_range(1, 16, 1) var timeline_calendar_days := 7
@export_range(0, 2147483647, 1) var simulation_seed := 74291
@export_range(0.5, 30.0, 0.5) var sample_interval_real_seconds := 2.0
@export_range(10.0, 3600.0, 10.0) var provider_check_interval_seconds := 60.0
@export_range(0.0, 10.0, 0.1) var forecast_update_blend_cycles := 1.0
@export_range(0.25, 10.0, 0.25) var timeline_rollover_lead_cycles := 1.5
@export_range(1, 60, 1) var history_retention_calendar_days := 14
@export_range(5.0, 600.0, 5.0) var persistence_autosave_interval_seconds := 30.0
@export_range(0.0, 86400.0, 60.0) var persistence_cursor_tolerance_game_seconds := 7200.0
@export_range(30.0, 3600.0, 30.0) var wall_clock_replan_tolerance_seconds := 300.0
@export var persistence_enabled := true
@export var persistence_path := "user://weather_data/weather_runtime_state.json"

signal runtime_status_changed(snapshot: Dictionary)

var provider_status := "starting"
var provider_error := ""
var data_source_status := "unavailable"
var forecast_data_quality := "unavailable"
var mapping_status := "waiting_for_forecast"
var region_id := "oresund"
var current_sample: Dictionary = {}
var last_refresh_status := "not_requested"
var last_refresh_attempt_utc := ""
var recovery_status := "not_loaded"
var rollover_status := "not_started"
var last_rollover_reason := ""
var last_rollover_utc := ""
var next_refresh_status := "provider_managed"
var historical_segments: Array[Dictionary] = []

var _provider: Object
var _provider_http_node: Node
var _world_time_manager: Node
var _godot_adapter: Node
var _timeline: Dictionary = {}
var _timeline_anchor_snapshot: Dictionary = {}
var _forecast_document: Dictionary = {}
var _forecast_fingerprint := ""
var _source_snapshot: Dictionary = {}
var _sample_elapsed := 0.0
var _provider_check_elapsed := 0.0
var _configuration_blocked := false
var _time_mapping_conflict_latched := false
var _last_control_revision := -1
var _initialized := false
var _persistence: WeatherRuntimePersistence
var _utc_time_source: Callable
var _last_valid_sample: Dictionary = {}
var _restore_reanchor_pending := false
var _persistence_dirty := false
var _persistence_elapsed := 0.0
var _provider_retry_after_utc := 0.0
var _rollover_retry_after_utc := 0.0
var _last_roll_signature := ""
var _previous_calendar_date_key := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE
	if _world_time_manager == null:
		_world_time_manager = get_node_or_null(world_time_manager_path)
	if _godot_adapter == null:
		_godot_adapter = get_node_or_null(godot_adapter_path)
	if weather_region != null:
		region_id = weather_region.region_id
	if _world_time_manager == null or _godot_adapter == null:
		_set_runtime_error("runtime_dependency_missing", "world_time_manager_or_adapter_missing")
		set_process(false)
		return
	if _world_time_manager.has_signal("state_changed"):
		var time_changed_callback := Callable(self, "_on_world_time_state_changed")
		if not _world_time_manager.is_connected("state_changed", time_changed_callback):
			_world_time_manager.connect("state_changed", time_changed_callback)
	if _provider == null:
		_configure_default_provider()
	if _provider == null:
		_set_runtime_error("provider_unavailable", "provider_configuration_failed")
		set_process(false)
		return
	var controller := _get_weather_state_controller()
	if controller != null:
		if not controller.operating_mode_changed.is_connected(_on_operating_mode_changed):
			controller.operating_mode_changed.connect(_on_operating_mode_changed)
		if controller.has_signal("weather_state_changed") and not controller.weather_state_changed.is_connected(_on_weather_state_changed):
			controller.weather_state_changed.connect(_on_weather_state_changed)
	if persistence_enabled and _persistence == null:
		_persistence = PersistenceScript.new()
		_persistence.file_path = persistence_path
	_initialized = true
	var world_snapshot := _world_time_manager.call("get_authoritative_state") as Dictionary
	var restored := _restore_persisted_state(world_snapshot)
	if not restored and controller != null:
		controller.call("set_auto_mode")
	_bootstrap_from_provider()
	_update_runtime_from_authority(world_snapshot, false)
	set_process(true)
	_previous_calendar_date_key = _current_stockholm_date_key()
	if persistence_enabled and recovery_status == "not_loaded":
		recovery_status = "new_runtime"


func _process(delta: float) -> void:
	if not _initialized:
		return
	_sample_elapsed += delta
	if _sample_elapsed >= sample_interval_real_seconds:
		_sample_elapsed = fposmod(_sample_elapsed, maxf(sample_interval_real_seconds, 0.1))
		update_runtime_now(false)
	_provider_check_elapsed += delta
	if _provider_check_elapsed >= provider_check_interval_seconds:
		_provider_check_elapsed = 0.0
		_check_provider_cache()
	_persistence_elapsed += delta
	if persistence_enabled and _persistence_elapsed >= persistence_autosave_interval_seconds:
		_persistence_elapsed = 0.0
		_save_runtime_state()


func _on_world_time_state_changed(snapshot: Dictionary) -> void:
	# WorldTimeManager emits on pause/resume, explicit time edits and multiplier
	# changes. Latch mapping conflicts immediately without polling its clock each
	# rendered frame.
	_check_time_mapping(snapshot)
	_emit_status()


func _exit_tree() -> void:
	if _initialized and persistence_enabled:
		_save_runtime_state()


## Public deterministic update hook used by virtual-time tests and server hosts.
## It performs one scheduler step at the injected/authoritative UTC instant.
func update_runtime_now(check_provider: bool = false) -> Dictionary:
	if not _initialized:
		return {"ok": false, "status": "not_initialized"}
	var world_snapshot := _world_time_manager.call("get_authoritative_state") as Dictionary
	_check_time_mapping(world_snapshot)
	_update_runtime_from_authority(world_snapshot, check_provider)
	return {"ok": true, "mapping_status": mapping_status, "rollover_status": rollover_status, "timeline_version": str(_timeline.get("timeline_version", ""))}


func _update_runtime_from_authority(world_snapshot: Dictionary, check_provider: bool = false) -> void:
	if check_provider:
		_check_provider_cache(false)
	if _time_mapping_conflict_latched:
		return
	if _timeline.is_empty():
		if not _forecast_document.is_empty():
			if _restore_reanchor_pending and not _last_valid_sample.is_empty():
				_roll_timeline_from_current(world_snapshot, "restore_reanchor_pending")
			else:
				_try_create_initial_timeline(world_snapshot)
		else:
			_hold_last_known("held_last_known")
		return
	# Sample against the current authoritative game cursor before deciding that
	# wall time drifted. This is important for virtual-clock boundary updates and
	# also prevents stale UI samples from looking like forecast discontinuities.
	_publish_current_sample(world_snapshot)
	if _rollover_is_due(world_snapshot):
		var now := _utc_now()
		if now >= _rollover_retry_after_utc:
			_check_provider_cache(false)
			_roll_timeline_from_current(world_snapshot, _rollover_reason(world_snapshot))
	_previous_calendar_date_key = _current_stockholm_date_key()


func _rollover_is_due(world_snapshot: Dictionary) -> bool:
	if bool(world_snapshot.get("paused", false)) or _time_mapping_conflict_latched:
		return false
	if _restore_reanchor_pending:
		return true
	if current_sample.is_empty() and not _last_valid_sample.is_empty():
		return true
	var sampled_date := str(current_sample.get("calendar_day_label", ""))
	var today := _current_stockholm_date_key()
	if not sampled_date.is_empty() and not today.is_empty() and sampled_date != today:
		return true
	var sample_time := str(current_sample.get("valid_time_utc", ""))
	if Codec.is_valid_utc_timestamp(sample_time):
		var forecast_cursor_utc := float(Codec.parse_utc_timestamp_to_unix(sample_time))
		if _utc_now() - forecast_cursor_utc > wall_clock_replan_tolerance_seconds:
			return true
	return _remaining_timeline_cycles(world_snapshot) <= timeline_rollover_lead_cycles


func _rollover_reason(world_snapshot: Dictionary) -> String:
	if _restore_reanchor_pending:
		return "restore_reanchor"
	var sampled_date := str(current_sample.get("calendar_day_label", ""))
	if not sampled_date.is_empty() and sampled_date != _current_stockholm_date_key():
		return "stockholm_calendar_rebase"
	var sample_time := str(current_sample.get("valid_time_utc", ""))
	if Codec.is_valid_utc_timestamp(sample_time) and _utc_now() - float(Codec.parse_utc_timestamp_to_unix(sample_time)) > wall_clock_replan_tolerance_seconds:
		return "world_clock_gap_rebase"
	return "coverage_rollover"


func _roll_timeline_from_current(world_snapshot: Dictionary, reason: String) -> Dictionary:
	if _forecast_document.is_empty():
		rollover_status = "waiting_for_forecast"
		_hold_last_known("held_last_known")
		return {"ok": false, "error": "forecast_unavailable"}
	var now := _utc_now()
	if not _forecast_covers_utc(_forecast_document, now):
		rollover_status = "forecast_coverage_exhausted"
		_rollover_retry_after_utc = now + provider_check_interval_seconds
		_hold_last_known("held_last_known")
		return {"ok": false, "error": "forecast_coverage_exhausted"}
	if not _world_scale_matches(world_snapshot):
		rollover_status = "time_scale_mismatch"
		mapping_status = "time_scale_mismatch_reanchor_required"
		return {"ok": false, "error": "time_scale_mismatch"}
	var today := _current_stockholm_date_key()
	var signature := "%s|%s|%s|%d|%d" % [region_id, today, _forecast_fingerprint, cycles_per_real_day, simulation_seed]
	if signature == _last_roll_signature and not _restore_reanchor_pending:
		_rollover_retry_after_utc = now + provider_check_interval_seconds
		return {"ok": false, "error": "rollover_already_attempted_for_version"}
	var previous_timeline := _timeline.duplicate(true)
	var previous_sample := current_sample.duplicate(true)
	if str(previous_sample.get("data_quality", "")) == "held_last_known":
		previous_sample = _last_valid_sample.duplicate(true)
	if previous_sample.is_empty():
		previous_sample = _last_valid_sample.duplicate(true)
	if previous_sample.is_empty() and not previous_timeline.is_empty():
		var sampled := Core.sample_weather(previous_timeline, world_snapshot)
		if bool(sampled.get("ok", false)):
			previous_sample = (sampled["state"] as Dictionary).duplicate(true)
	var generated := _generate_timeline(_forecast_document, _source_snapshot, world_snapshot)
	if not bool(generated.get("ok", false)):
		rollover_status = "candidate_rejected:%s" % str(generated.get("error", "unknown"))
		_rollover_retry_after_utc = now + provider_check_interval_seconds
		_hold_last_known("held_last_known")
		return generated
	var candidate: Dictionary = generated["timeline"]
	var candidate_offset := float(candidate.get("simulation_anchor_timeline_cycle_offset", 0.0))
	if not previous_sample.is_empty():
		candidate = _stitch_timeline_from_state(candidate, previous_sample, candidate_offset, reason)
	if not previous_timeline.is_empty():
		_archive_timeline_through_cursor(previous_timeline, world_snapshot, previous_sample, reason)
	candidate["timeline_rollover"] = {
		"reason": reason,
		"previous_timeline_version": str(previous_timeline.get("timeline_version", "")),
		"started_at_utc": _timestamp_iso(now),
		"preserved_weather_sample": not previous_sample.is_empty(),
		"transition_cycles": maxf(forecast_update_blend_cycles, 0.05),
	}
	_timeline = candidate
	_timeline_anchor_snapshot = world_snapshot.duplicate(true)
	_timeline["active_from_cycle_offset"] = candidate_offset
	_last_roll_signature = signature
	_restore_reanchor_pending = false
	_time_mapping_conflict_latched = false
	_last_control_revision = int(world_snapshot.get("authority_control_revision", 0))
	last_rollover_reason = reason
	last_rollover_utc = _timestamp_iso(now)
	recovery_status = "timeline_rolled_over"
	rollover_status = "active"
	_rollover_retry_after_utc = 0.0
	_publish_current_sample(world_snapshot, true)
	_mark_persistence_dirty()
	_emit_status()
	return {"ok": true, "timeline_version": str(_timeline.get("timeline_version", "")), "reason": reason}


func _stitch_timeline_from_state(candidate: Dictionary, previous_state: Dictionary, boundary_offset: float, reason: String) -> Dictionary:
	var output := candidate.duplicate(true)
	var boundary := previous_state.duplicate(true)
	for field in ["sampled_cycle_offset", "elapsed_since_authority_cycles", "calendar_day_label", "timeline_version", "simulation_seed", "region_id", "real_forecast_day_index", "game_day_cycle_index", "day_cycle_progress", "weather_process_time_seconds"]:
		boundary.erase(field)
	boundary["cycle_offset"] = boundary_offset
	boundary["valid_time_utc"] = _timestamp_iso(_utc_now())
	if str(boundary.get("data_quality", "unavailable")) == "unavailable":
		boundary["data_quality"] = forecast_data_quality if forecast_data_quality != "unavailable" else "partial"
	var frames: Array[Dictionary] = []
	var inserted := false
	var transition_cycles := maxf(forecast_update_blend_cycles, 0.05)
	for value in output.get("keyframes", []):
		var frame: Dictionary = value.duplicate(true)
		var offset := float(frame.get("cycle_offset", 0.0))
		if not inserted and offset >= boundary_offset - 0.000001:
			if absf(offset - boundary_offset) <= 0.000001:
				frames.append(boundary.duplicate(true))
				inserted = true
				continue
			frames.append(boundary.duplicate(true))
			inserted = true
		if inserted and offset > boundary_offset + 0.000001 and offset < boundary_offset + transition_cycles:
			var weight := _smoothstep01((offset - boundary_offset) / transition_cycles)
			frame = _blend_runtime_frame(boundary, frame, weight)
		frames.append(frame)
	if not inserted:
		frames.append(boundary.duplicate(true))
	frames.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("cycle_offset", 0.0)) < float(b.get("cycle_offset", 0.0)))
	output["keyframes"] = frames
	output["active_from_cycle_offset"] = boundary_offset
	output["continuity_transition"] = {"reason": reason, "cycle_offset": boundary_offset, "blend_cycles": transition_cycles}
	return output


func _blend_runtime_frame(from_state: Dictionary, to_state: Dictionary, weight: float) -> Dictionary:
	var result := to_state.duplicate(true)
	for field in ["air_temperature_c", "relative_humidity_percent", "air_pressure_hpa", "mean_wind_speed_mps", "cloud_fraction", "gust_forecast_mps"]:
		if from_state.has(field) and to_state.has(field):
			result[field] = lerpf(float(from_state[field]), float(to_state[field]), weight)
	if from_state.has("wind_from_direction_deg") and to_state.has("wind_from_direction_deg"):
		var a := deg_to_rad(float(from_state["wind_from_direction_deg"]))
		var b := deg_to_rad(float(to_state["wind_from_direction_deg"]))
		result["wind_from_direction_deg"] = fposmod(rad_to_deg(lerp_angle(a, b, weight)), 360.0)
	if from_state.get("gust_target", {}) is Dictionary and to_state.get("gust_target", {}) is Dictionary:
		var gust: Dictionary = (to_state["gust_target"] as Dictionary).duplicate(true)
		gust["gust_strength_mps"] = lerpf(float((from_state["gust_target"] as Dictionary).get("gust_strength_mps", 0.0)), float(gust.get("gust_strength_mps", 0.0)), weight)
		result["gust_target"] = gust
	return result


func _archive_timeline_through_cursor(timeline: Dictionary, snapshot: Dictionary, last_state: Dictionary, reason: String) -> void:
	if timeline.is_empty():
		return
	var offset := _timeline_cycle_offset_at_for(timeline, snapshot)
	if offset < 0.0:
		return
	var segment := timeline.duplicate(true)
	var retained_frames: Array[Dictionary] = []
	var active_from := float(timeline.get("active_from_cycle_offset", 0.0))
	for value in timeline.get("keyframes", []):
		var frame: Dictionary = value
		var frame_offset := float(frame.get("cycle_offset", 0.0))
		if frame_offset >= active_from - 0.000001 and frame_offset <= offset + 0.000001:
			retained_frames.append(frame.duplicate(true))
	if not last_state.is_empty():
		var end_frame := last_state.duplicate(true)
		for field in ["sampled_cycle_offset", "elapsed_since_authority_cycles", "calendar_day_label", "timeline_version", "simulation_seed", "region_id", "real_forecast_day_index", "game_day_cycle_index", "day_cycle_progress", "weather_process_time_seconds"]:
			end_frame.erase(field)
		end_frame["cycle_offset"] = offset
		end_frame["valid_time_utc"] = _timestamp_iso(_utc_now())
		if retained_frames.is_empty() or absf(float(retained_frames.back().get("cycle_offset", -1.0)) - offset) > 0.000001:
			retained_frames.append(end_frame)
	segment["keyframes"] = retained_frames
	segment["archive_reason"] = reason
	segment["archived_from_cycle_offset"] = active_from
	segment["archived_through_cycle_offset"] = offset
	segment["archived_through_utc"] = _timestamp_iso(_utc_now())
	historical_segments.append(segment)
	_prune_history_segments()


func _prune_history_segments() -> void:
	var cutoff := _utc_now() - float(history_retention_calendar_days) * 86400.0
	var kept: Array[Dictionary] = []
	for segment in historical_segments:
		var end_utc := str(segment.get("archived_through_utc", ""))
		var end_unix := Codec.parse_utc_timestamp_to_unix(end_utc) if Codec.is_valid_utc_timestamp(end_utc) else 0
		if end_unix >= cutoff:
			kept.append(segment)
	historical_segments = kept


func _hold_last_known(reason: String) -> void:
	var held: Dictionary = _last_valid_sample if not _last_valid_sample.is_empty() else current_sample
	if held.is_empty():
		if _timeline.is_empty():
			mapping_status = "waiting_for_usable_forecast"
		return
	current_sample = held.duplicate(true)
	current_sample["data_quality"] = "held_last_known"
	current_sample["held_reason"] = reason
	forecast_data_quality = "held_last_known"
	mapping_status = "held_last_known"
	rollover_status = reason


func _restore_persisted_state(world_snapshot: Dictionary) -> bool:
	if not persistence_enabled or _persistence == null:
		recovery_status = "persistence_disabled"
		return false
	var loaded: Dictionary = _persistence.load_state(region_id)
	if not bool(loaded.get("ok", false)):
		recovery_status = "no_saved_state" if str(loaded.get("status", "")) == "missing" else "saved_state_%s" % str(loaded.get("status", "invalid"))
		return false
	var saved: Dictionary = loaded.get("data", {})
	var saved_timeline: Dictionary = saved.get("active_timeline", {})
	var saved_cursor: Dictionary = saved.get("saved_cursor", {})
	simulation_seed = int(saved.get("simulation_seed", simulation_seed))
	_forecast_document = saved.get("forecast_document", {}).duplicate(true)
	_forecast_fingerprint = str(saved.get("forecast_fingerprint", ""))
	_source_snapshot = saved.get("source_snapshot_metadata", {}).duplicate(true)
	current_sample = saved.get("current_sample", {}).duplicate(true)
	_last_valid_sample = saved.get("last_valid_sample", current_sample).duplicate(true)
	data_source_status = "restored_state" if not current_sample.is_empty() else "unavailable"
	forecast_data_quality = "stale" if not current_sample.is_empty() else "unavailable"
	last_refresh_status = str(saved.get("last_refresh_status", "not_requested"))
	last_refresh_attempt_utc = str(saved.get("last_refresh_attempt_utc", ""))
	historical_segments.clear()
	for segment_value in saved.get("history_segments", []):
		if segment_value is Dictionary:
			historical_segments.append(segment_value.duplicate(true))
	last_rollover_reason = str(saved.get("last_rollover_reason", ""))
	last_rollover_utc = str(saved.get("last_rollover_utc", ""))
	_last_roll_signature = str(saved.get("last_roll_signature", ""))
	var saved_timeline_cycles := int(saved_timeline.get("cycles_per_real_day", 0)) if not saved_timeline.is_empty() else cycles_per_real_day
	var cycle_mapping_compatible := saved_timeline.is_empty() or saved_timeline_cycles == cycles_per_real_day
	if not saved_timeline.is_empty() and cycle_mapping_compatible:
		_timeline = saved_timeline.duplicate(true)
		_timeline_anchor_snapshot = saved.get("timeline_anchor_snapshot", {}).duplicate(true)
	elif not cycle_mapping_compatible:
		_restore_reanchor_pending = true
		recovery_status = "cycle_mapping_mismatch_reanchor_pending"
	var saved_position := float(saved_cursor.get("day_cycle_index", 0)) + float(saved_cursor.get("cycle_seconds", 0.0)) / 86400.0
	var current_position := float(world_snapshot.get("day_cycle_index", 0)) + float(world_snapshot.get("cycle_seconds", 0.0)) / 86400.0
	var cursor_difference_seconds := absf(saved_position - current_position) * 86400.0
	var saved_scale := float(saved_cursor.get("time_scale", 0.0))
	var current_scale := float(world_snapshot.get("time_scale", 0.0))
	var cursor_compatible := cursor_difference_seconds <= persistence_cursor_tolerance_game_seconds and is_equal_approx(saved_scale, current_scale) and is_equal_approx(current_scale, cycles_per_real_day)
	if not saved_timeline.is_empty() and not cursor_compatible:
		_restore_reanchor_pending = true
		recovery_status = "persistence_cursor_mismatch_reanchor_pending"
		mapping_status = "persistence_cursor_mismatch_reanchor_pending"
	elif not saved_timeline.is_empty() and cycle_mapping_compatible:
		var saved_valid_time := str(current_sample.get("valid_time_utc", ""))
		var saved_date := str(current_sample.get("calendar_day_label", ""))
		if Codec.is_valid_utc_timestamp(saved_valid_time):
			saved_date = _date_key(WorldTimeManagerScript.stockholm_date_from_utc(float(Codec.parse_utc_timestamp_to_unix(saved_valid_time))))
		if not saved_date.is_empty() and saved_date != _current_stockholm_date_key():
			_restore_reanchor_pending = true
			recovery_status = "offline_date_replan_pending"
			mapping_status = "offline_date_replan_pending"
		elif Codec.is_valid_utc_timestamp(saved_valid_time) and _utc_now() - float(Codec.parse_utc_timestamp_to_unix(saved_valid_time)) > wall_clock_replan_tolerance_seconds:
			_restore_reanchor_pending = true
			recovery_status = "offline_clock_gap_replan_pending"
			mapping_status = "offline_clock_gap_replan_pending"
		else:
			recovery_status = "restored"
			mapping_status = str(saved.get("mapping_status", "matched"))
	var controller := _get_weather_state_controller()
	if controller != null:
		var mode := str(saved.get("operating_mode", "AUTO"))
		if mode == "MANUAL":
			var preset := StringName(str(saved.get("manual_weather_preset", "Clear")))
			controller.call("set_weather_by_name", preset)
			controller.call("set_manual_mode")
		else:
			controller.call("set_auto_mode")
	if not current_sample.is_empty() and not _restore_reanchor_pending:
		_publish_current_sample(world_snapshot, true)
	elif not current_sample.is_empty():
		_hold_last_known("offline_date_replan_pending")
	return true


func _save_runtime_state() -> void:
	if not persistence_enabled or _persistence == null or _world_time_manager == null:
		return
	var cursor: Dictionary = _world_time_manager.call("get_authoritative_state") as Dictionary
	var controller := _get_weather_state_controller()
	var mode := "AUTO"
	var manual_preset := "Clear"
	var formal_state: Dictionary = {}
	if controller != null:
		mode = str(controller.call("get_operating_mode_name"))
		manual_preset = str(controller.get("target_weather_id"))
		formal_state = controller.call("get_wind_state") as Dictionary
	var payload := {
		"schema_version": WeatherRuntimePersistence.SCHEMA_VERSION,
		"save_format": "weather_runtime_state",
		"region_id": region_id,
		"operating_mode": mode,
		"manual_weather_preset": manual_preset,
		"simulation_seed": simulation_seed,
		"timeline_version": str(_timeline.get("timeline_version", "")),
		"active_timeline": _timeline.duplicate(true),
		"timeline_anchor_snapshot": _timeline_anchor_snapshot.duplicate(true),
		"simulation_anchor": (_timeline.get("simulation_anchor", {}) as Dictionary).duplicate(true),
		"current_authoritative_cursor": _cursor_for_save(cursor),
		"saved_cursor": _cursor_for_save(cursor),
		"real_day_boundaries_utc": (_timeline.get("real_day_boundaries_utc", []) as Array).duplicate(true),
		"calendar_day_labels": (_timeline.get("calendar_day_labels", []) as Array).duplicate(true),
		"forecast_document": _forecast_document.duplicate(true),
		"forecast_fingerprint": _forecast_fingerprint,
		"forecast_metadata": _safe_forecast_metadata(),
		"source_snapshot_metadata": _safe_source_snapshot_metadata(),
		"data_source_status": data_source_status,
		"forecast_data_quality": forecast_data_quality,
		"mapping_status": mapping_status,
		"recovery_status": recovery_status,
		"rollover_status": rollover_status,
		"current_sample": current_sample.duplicate(true),
		"last_valid_sample": _last_valid_sample.duplicate(true),
		"last_applied_formal_weather_state": formal_state,
		"history_segments": historical_segments.duplicate(true),
		"last_refresh_status": last_refresh_status,
		"last_refresh_attempt_utc": last_refresh_attempt_utc,
		"last_rollover_reason": last_rollover_reason,
		"last_rollover_utc": last_rollover_utc,
		"last_roll_signature": _last_roll_signature,
		"save_timestamp_utc": _timestamp_iso(_utc_now()),
		"pending_reanchor": _restore_reanchor_pending,
	}
	var result: Dictionary = _persistence.save_state(payload)
	if bool(result.get("ok", false)):
		_persistence_dirty = false
		_emit_status()
	else:
		push_warning("Weather runtime save failed: %s" % str(result.get("error", "unknown")))


func _cursor_for_save(snapshot: Dictionary) -> Dictionary:
	return {
		"day_cycle_index": int(snapshot.get("day_cycle_index", 0)),
		"cycle_seconds": float(snapshot.get("cycle_seconds", 0.0)),
		"time_scale": float(snapshot.get("time_scale", 0.0)),
		"paused": bool(snapshot.get("paused", false)),
		"authoritative_timestamp_utc": float(snapshot.get("authoritative_timestamp_utc", _utc_now())),
	}


func _safe_source_snapshot_metadata() -> Dictionary:
	return {
		"status": provider_status,
		"cache_source": str(_source_snapshot.get("cache_source", "")),
		"stale": bool(_source_snapshot.get("stale", false)),
		"stale_acceptable": bool(_source_snapshot.get("stale_acceptable", false)),
		"refresh_due": bool(_source_snapshot.get("refresh_due", false)),
		"stale_age_seconds": float(_source_snapshot.get("stale_age_seconds", -1.0)),
	}


func _mark_persistence_dirty() -> void:
	_persistence_dirty = true
	if persistence_enabled and is_inside_tree():
		_persistence_elapsed = maxf(_persistence_elapsed, persistence_autosave_interval_seconds)
		call_deferred("_save_runtime_state")


func _on_weather_state_changed(_weather_id: StringName, _wind_state: Dictionary) -> void:
	if _get_weather_state_controller() != null and str(_get_weather_state_controller().call("get_operating_mode_name")) == "MANUAL":
		_mark_persistence_dirty()


## Dependency injection is used by fully offline runtime integration tests and
## by a future server host. Call before adding this node to the SceneTree.
func configure_dependencies(
	provider: Object,
	world_time_manager: Node,
	godot_adapter: Node,
	region: WeatherRegion,
	configured_cycles_per_real_day: int = 24,
	seed: int = 74291
) -> void:
	_provider = provider
	_world_time_manager = world_time_manager
	_godot_adapter = godot_adapter
	weather_region = region
	region_id = region.region_id if region != null else "oresund"
	cycles_per_real_day = configured_cycles_per_real_day
	simulation_seed = seed


func set_provider_for_testing(provider: Object) -> void:
	_provider = provider


## Inject an offline clock and persistence backend before adding the authority to
## the tree. Production continues to use WorldTimeManager's UTC source.
func configure_persistence_for_testing(persistence: WeatherRuntimePersistence, utc_source: Callable = Callable()) -> void:
	_persistence = persistence
	persistence_enabled = persistence != null
	_utc_time_source = utc_source


func reanchor_authoritative_timeline(configured_cycles_per_real_day: int = -1) -> Dictionary:
	if _forecast_document.is_empty() or _world_time_manager == null:
		return {"ok": false, "error": "forecast_unavailable"}
	var requested_cycles := cycles_per_real_day
	if configured_cycles_per_real_day != -1:
		if not configured_cycles_per_real_day in [12, 24]:
			return {"ok": false, "error": "cycles_per_real_day_unsupported"}
	var world_snapshot := _world_time_manager.call("get_authoritative_state") as Dictionary
	if configured_cycles_per_real_day != -1:
		requested_cycles = configured_cycles_per_real_day
	if not is_equal_approx(float(world_snapshot.get("time_scale", 0.0)), float(requested_cycles)):
		mapping_status = "time_scale_mismatch"
		_emit_status()
		return {"ok": false, "error": "world_time_scale_mismatch"}
	var prior_cycles := cycles_per_real_day
	cycles_per_real_day = requested_cycles
	var prior_timeline := _timeline.duplicate(true)
	var prior_sample := current_sample.duplicate(true)
	if prior_sample.is_empty() and not prior_timeline.is_empty():
		var prior_sample_result := Core.sample_weather(prior_timeline, world_snapshot)
		if bool(prior_sample_result.get("ok", false)):
			prior_sample = (prior_sample_result.get("state", {}) as Dictionary).duplicate(true)
	var generated := _generate_timeline(_forecast_document, _source_snapshot, world_snapshot)
	if not bool(generated.get("ok", false)):
		cycles_per_real_day = prior_cycles
		mapping_status = str(generated.get("error", "timeline_generation_failed"))
		_emit_status()
		return generated
	var candidate: Dictionary = generated["timeline"]
	var candidate_offset := float(candidate.get("simulation_anchor_timeline_cycle_offset", 0.0))
	if not prior_sample.is_empty():
		candidate = _stitch_timeline_from_state(candidate, prior_sample, candidate_offset, "explicit_reanchor")
	candidate["active_from_cycle_offset"] = candidate_offset
	if not prior_timeline.is_empty():
		_archive_timeline_through_cursor(prior_timeline, world_snapshot, prior_sample, "explicit_reanchor")
	_timeline = candidate
	_timeline_anchor_snapshot = world_snapshot.duplicate(true)
	_time_mapping_conflict_latched = false
	_restore_reanchor_pending = false
	_last_control_revision = int(world_snapshot.get("authority_control_revision", 0))
	last_rollover_reason = "explicit_reanchor"
	last_rollover_utc = _timestamp_iso(_utc_now())
	recovery_status = "reanchored"
	mapping_status = "matched"
	_publish_current_sample(world_snapshot, true)
	_mark_persistence_dirty()
	_emit_status()
	return {"ok": true, "timeline_version": str(_timeline.get("timeline_version", "")), "previous_cycles_per_real_day": prior_cycles, "cycles_per_real_day": cycles_per_real_day}


func get_timeline_metadata() -> Dictionary:
	if _timeline.is_empty():
		return {"available": false, "mapping_status": mapping_status}
	return {
		"available": true,
		"schema_version": int(_timeline.get("schema_version", 0)),
		"region_id": str(_timeline.get("region_id", "")),
		"timeline_version": str(_timeline.get("timeline_version", "")),
		"simulation_seed": int(_timeline.get("simulation_seed", 0)),
		"cycles_per_real_day": int(_timeline.get("cycles_per_real_day", 0)),
		"real_day_boundaries_utc": (_timeline.get("real_day_boundaries_utc", []) as Array).duplicate(true),
		"calendar_day_labels": (_timeline.get("calendar_day_labels", []) as Array).duplicate(true),
		"calendar_boundary_basis": str(_timeline.get("calendar_boundary_basis", "")),
		"simulation_anchor": (_timeline.get("simulation_anchor", {}) as Dictionary).duplicate(true),
		"source_data_quality": str(_timeline.get("source_data_quality", "unavailable")),
		"forecast_issued_at_utc": str(_timeline.get("forecast_issued_at_utc", "")),
		"forecast_retrieved_at_utc": str(_timeline.get("forecast_retrieved_at_utc", "")),
		"active_from_cycle_offset": float(_timeline.get("active_from_cycle_offset", 0.0)),
		"remaining_coverage_cycles": _remaining_timeline_cycles(),
	}


## Read-only projection for the developer preview panel. This method neither
## applies weather nor refreshes the provider.
func get_preview_weather_at_cycle_offset(cycle_offset: float) -> Dictionary:
	if _timeline.is_empty() or not is_finite(cycle_offset):
		return {"ok": false, "error": "timeline_unavailable"}
	var first_allowed := float(_timeline.get("active_from_cycle_offset", 0.0))
	var end_offset := _timeline_end_cycle_offset(_timeline)
	if cycle_offset < first_allowed - 0.000001 or cycle_offset > end_offset + 0.000001:
		return {"ok": false, "error": "preview_outside_active_timeline", "minimum_cycle_offset": first_allowed, "maximum_cycle_offset": end_offset}
	var sampled := Core.sample_weather(_timeline, {"elapsed_cycles": cycle_offset - float(_timeline.get("simulation_anchor_timeline_cycle_offset", 0.0))})
	if not bool(sampled.get("ok", false)):
		return sampled
	return {"ok": true, "state": sampled["state"].duplicate(true), "data_source_status": data_source_status, "forecast_data_quality": forecast_data_quality, "mapping_status": mapping_status}


func get_current_timeline_cycle_offset() -> float:
	if _timeline.is_empty() or _world_time_manager == null:
		return -1.0
	return _timeline_cycle_offset_at(_world_time_manager.call("get_authoritative_state") as Dictionary)


func get_timeline_range() -> Dictionary:
	if _timeline.is_empty():
		return {"available": false}
	return {"available": true, "start_cycle_offset": float(_timeline.get("active_from_cycle_offset", 0.0)), "end_cycle_offset": _timeline_end_cycle_offset(_timeline), "cycles_per_real_day": cycles_per_real_day}


func sample_authoritative_weather() -> Dictionary:
	if _timeline.is_empty() or _world_time_manager == null:
		return {"ok": false, "error": "timeline_unavailable"}
	if _time_mapping_conflict_latched:
		return {"ok": false, "error": "time_mapping_reanchor_required"}
	var snapshot := _world_time_manager.call("get_authoritative_state") as Dictionary
	if not _world_scale_matches(snapshot):
		return {"ok": false, "error": "time_scale_mismatch"}
	return Core.sample_weather(_timeline, snapshot)


func get_authoritative_weather_snapshot() -> Dictionary:
	var cursor: Dictionary = _world_time_manager.call("get_authoritative_state") if _world_time_manager != null else {}
	return {
		"schema_version": 1,
		"authority_kind": "local_weather_runtime_authority",
		"region_id": region_id,
		"timeline_version": str(_timeline.get("timeline_version", "")),
		"simulation_seed": int(_timeline.get("simulation_seed", simulation_seed)),
		"forecast_metadata": _safe_forecast_metadata(),
		"authoritative_time_anchor": (_timeline.get("simulation_anchor", {}) as Dictionary).duplicate(true),
		"authoritative_cursor": {
			"authoritative_timestamp_utc": _timestamp_iso(float(cursor.get("authoritative_timestamp_utc", 0.0))),
			"day_cycle_index": int(cursor.get("day_cycle_index", 0)),
			"cycle_seconds": float(cursor.get("cycle_seconds", 0.0)),
			"time_scale": float(cursor.get("time_scale", 0.0)),
			"paused": bool(cursor.get("paused", false)),
		},
		"current_weather_state": current_sample.duplicate(true),
		"data_source_status": data_source_status,
		"provider_status": provider_status,
		"forecast_data_quality": forecast_data_quality,
		"time_mapping_status": mapping_status,
		"recovery_status": recovery_status,
		"rollover_status": rollover_status,
		"last_rollover_reason": last_rollover_reason,
		"last_rollover_utc": last_rollover_utc,
		"next_refresh_status": next_refresh_status,
		"remaining_coverage_cycles": _remaining_timeline_cycles(),
		"timeline": _timeline.duplicate(true),
	}


func serialize_authoritative_snapshot() -> String:
	return JSON.stringify(get_authoritative_weather_snapshot(), "", true, true)


func reload_provider_contact_configuration() -> void:
	if _provider == null:
		return
	var contact := UserAgentSettings.load_contact()
	_provider.call("set_user_agent_contact", contact)
	_configuration_blocked = false
	_check_provider_cache(true)


func _configure_default_provider() -> void:
	if weather_region == null:
		_set_runtime_error("provider_unavailable", "weather_region_resource_missing")
		return
	var http := HttpAdapterScript.new() as Node
	http.name = "WeatherHttpAdapter"
	add_child(http)
	_provider_http_node = http
	_provider = ProviderScript.new()
	var cache_store := CacheStoreScript.new()
	var clock_adapter := ClockAdapterScript.new()
	var retry_scheduler := RetrySchedulerScript.new(self)
	_provider.call("configure", [weather_region], http, cache_store, clock_adapter, retry_scheduler, UserAgentSettings.load_contact())


func _bootstrap_from_provider() -> void:
	var cached: Dictionary = _provider.call("read_forecast", region_id)
	_accept_provider_snapshot(cached, false)
	if bool(cached.get("refresh_due", true)):
		_check_provider_cache(true)


func _check_provider_cache(force_refresh: bool = false) -> void:
	if _configuration_blocked or _provider == null:
		return
	var cached: Dictionary = _provider.call("read_forecast", region_id)
	_accept_provider_snapshot(cached, false)
	if not force_refresh and not bool(cached.get("refresh_due", true)):
		next_refresh_status = "cache_valid"
		return
	last_refresh_attempt_utc = _timestamp_iso(_utc_now())
	last_refresh_status = "requesting"
	next_refresh_status = "provider_request_in_flight"
	var result: Dictionary = _provider.call("refresh_region", region_id, Callable(self, "_on_provider_refresh_completed"))
	if str(result.get("status", "")) == "request_started":
		last_refresh_status = "requesting"
		_emit_status()
	elif not bool(result.get("has_data", false)) and str(result.get("status", "")) == "configuration_required":
		_configuration_blocked = true
		last_refresh_status = "configuration_required"
		next_refresh_status = "configuration_required"
		provider_status = "configuration_required"
		provider_error = "MET Norway User-Agent contact is missing; configure it before online refresh."
		_emit_status()


func _on_provider_refresh_completed(result: Dictionary) -> void:
	last_refresh_status = "failed: %s" % str(result.get("error", result.get("status", "unknown"))) if str(result.get("refresh_status", "")) == "failed" else str(result.get("status", "unavailable"))
	next_refresh_status = "provider_managed"
	_accept_provider_snapshot(result, true)
	if _restore_reanchor_pending:
		_update_runtime_from_authority(_world_time_manager.call("get_authoritative_state") as Dictionary, false)
	if str(result.get("status", "")) == "configuration_required":
		_configuration_blocked = true
		provider_status = "configuration_required"
		provider_error = "MET Norway User-Agent contact is not configured."
	_emit_status()


func _accept_provider_snapshot(result: Dictionary, from_refresh: bool) -> void:
	provider_status = str(result.get("status", "unavailable"))
	provider_error = str(result.get("error", ""))
	var has_data := bool(result.get("has_data", false)) and result.get("data", {}) is Dictionary
	var acceptable := bool(result.get("stale_acceptable", false)) or not bool(result.get("stale", false))
	if not has_data or not acceptable:
		data_source_status = "unavailable"
		if not _timeline.is_empty():
			forecast_data_quality = "stale"
			_source_snapshot["stale"] = true
			_source_snapshot["stale_acceptable"] = true
		else:
			forecast_data_quality = "unavailable"
		if _timeline.is_empty():
			mapping_status = "waiting_for_usable_forecast"
		_emit_status()
		return
	var document: Dictionary = result["data"]
	var validation := Codec.validate_standardized_document(document)
	if not bool(validation.get("ok", false)):
		provider_error = "standardized_forecast_invalid:%s" % str(validation.get("error", "unknown"))
		data_source_status = "unavailable"
		forecast_data_quality = "unavailable"
		_emit_status()
		return
	_source_snapshot = result.duplicate(true)
	data_source_status = _data_source_label(result)
	var fingerprint := "%s|%s|%s" % [
		str(document.get("forecast_issued_at_utc", "")),
		str(document.get("retrieved_at_utc", "")),
		str(document.get("valid_until_utc", "")),
	]
	if fingerprint != _forecast_fingerprint:
		_forecast_document = document.duplicate(true)
		_forecast_fingerprint = fingerprint
		if _timeline.is_empty():
			var snapshot := _world_time_manager.call("get_authoritative_state") as Dictionary
			_timeline_anchor_snapshot = snapshot.duplicate(true)
			_try_create_initial_timeline(snapshot)
		elif from_refresh:
			_update_existing_timeline(document, result)
		elif not _restore_reanchor_pending:
			_update_existing_timeline(document, result)
	else:
		if not _timeline.is_empty():
			forecast_data_quality = "stale" if bool(result.get("stale", false)) else str(_timeline.get("source_data_quality", "unavailable"))
	_mark_persistence_dirty()
	_emit_status()


func _try_create_initial_timeline(snapshot: Dictionary) -> void:
	if not _world_scale_matches(snapshot):
		mapping_status = "time_scale_mismatch"
		return
	if not _forecast_covers_utc(_forecast_document, _utc_now()):
		mapping_status = "forecast_coverage_expired"
		_hold_last_known("held_last_known")
		return
	var generated := _generate_timeline(_forecast_document, _source_snapshot, snapshot)
	if not bool(generated.get("ok", false)):
		mapping_status = str(generated.get("error", "timeline_generation_failed"))
		return
	_timeline = generated["timeline"]
	_timeline["active_from_cycle_offset"] = float(_timeline.get("simulation_anchor_timeline_cycle_offset", 0.0))
	mapping_status = "matched"
	forecast_data_quality = str(_timeline.get("source_data_quality", "unavailable"))
	rollover_status = "active"
	recovery_status = "timeline_created"
	_publish_current_sample(snapshot, true)
	_mark_persistence_dirty()


func _update_existing_timeline(document: Dictionary, result: Dictionary) -> void:
	if _time_mapping_conflict_latched:
		mapping_status = "time_mapping_reanchor_required"
		return
	var world_snapshot := _world_time_manager.call("get_authoritative_state") as Dictionary
	if not _world_scale_matches(world_snapshot):
		mapping_status = "time_scale_mismatch"
		return
	var preserve_offset := _timeline_cycle_offset_at(world_snapshot)
	var maximum_offset := _timeline_end_cycle_offset(_timeline)
	if preserve_offset < 0.0 or preserve_offset >= maximum_offset:
		_roll_timeline_from_current(world_snapshot, "forecast_update_after_coverage")
		return
	var request := _make_timeline_request(document, result, _timeline_anchor_snapshot, _timeline)
	var updated := Core.update_forecast(_timeline, request, preserve_offset, maxf(forecast_update_blend_cycles, 0.05))
	if not bool(updated.get("ok", false)):
		mapping_status = "forecast_update_rejected:%s" % str(updated.get("error", "unknown"))
		return
	var updated_timeline: Dictionary = updated["timeline"]
	updated_timeline["active_from_cycle_offset"] = float(_timeline.get("active_from_cycle_offset", 0.0))
	_timeline = updated_timeline
	forecast_data_quality = str(_timeline.get("source_data_quality", "unavailable"))
	mapping_status = "matched"
	_publish_current_sample(world_snapshot, true)
	_mark_persistence_dirty()


func _generate_timeline(document: Dictionary, result: Dictionary, anchor_snapshot: Dictionary) -> Dictionary:
	var boundaries: Dictionary = CalendarAdapter.build_day_boundaries(
		float(anchor_snapshot.get("authoritative_timestamp_utc", 0.0)), timeline_calendar_days
	)
	if not bool(boundaries.get("ok", false)):
		return boundaries
	var request := _make_timeline_request(document, result, anchor_snapshot, boundaries)
	var generated := Core.generate_timeline(request)
	if not bool(generated.get("ok", false)):
		return generated
	return generated


func _make_timeline_request(document: Dictionary, result: Dictionary, anchor_snapshot: Dictionary, calendar: Dictionary) -> Dictionary:
	var boundary_values: Array = calendar.get("real_day_boundaries_utc", [])
	var anchor := Core.make_simulation_anchor_from_world_time_snapshot(anchor_snapshot)
	var issued := str(document.get("forecast_issued_at_utc", ""))
	var retrieved := str(document.get("retrieved_at_utc", ""))
	var anchor_part := "%d-%d-%s" % [int(anchor.get("day_cycle_index", 0)), int(round(float(anchor.get("cycle_seconds", 0.0)))), str(anchor.get("authoritative_timestamp_utc", ""))]
	var request_id := "%s:%s:%s:%s:%d:%d" % [region_id, str(boundary_values[0]), issued, retrieved, cycles_per_real_day, simulation_seed]
	if not _timeline.is_empty():
		request_id += ":update"
	else:
		request_id += ":%s" % anchor_part
	return {
		"schema_version": 1,
		"request_id": request_id,
		"region_id": region_id,
		"forecast_document": document.duplicate(true),
		"forecast_quality": "stale" if bool(result.get("stale", false)) else "fresh",
		"requested_start_utc": str(boundary_values[0]),
		"requested_end_utc": str(boundary_values.back()),
		"real_day_boundaries_utc": boundary_values.duplicate(true),
		"calendar_day_labels": (calendar.get("calendar_day_labels", []) as Array).duplicate(true),
		"calendar_boundary_basis": str(calendar.get("calendar_boundary_basis", "Europe/Stockholm")),
		"generated_at_utc": _timestamp_iso(float(anchor_snapshot.get("authoritative_timestamp_utc", 0.0))),
		"simulation_seed": simulation_seed,
		"cycles_per_real_day": cycles_per_real_day,
		"simulation_anchor": anchor,
	}


func _publish_current_sample(world_snapshot: Dictionary, force: bool = false) -> void:
	if _timeline.is_empty() or _time_mapping_conflict_latched:
		return
	if not _world_scale_matches(world_snapshot):
		mapping_status = "time_scale_mismatch"
		return
	var sampled := Core.sample_weather(_timeline, world_snapshot)
	if not bool(sampled.get("ok", false)):
		if str(sampled.get("error", "")) == "simulation_time_outside_timeline":
			_hold_last_known("held_last_known")
			rollover_status = "coverage_ended"
		else:
			mapping_status = "timeline_sample_unavailable:%s" % str(sampled.get("error", "unknown"))
		return
	var state: Dictionary = sampled["state"]
	if str(state.get("data_quality", "unavailable")) == "unavailable" or str(state.get("visual_weather_id", "Unknown")) == "Unknown":
		_hold_last_known("held_last_known")
		return
	var published_state := state.duplicate(true)
	if data_source_status in ["unavailable", "restored_state", "stale_cache"]:
		published_state["data_quality"] = "stale"
	current_sample = published_state
	_last_valid_sample = current_sample.duplicate(true)
	forecast_data_quality = "stale" if data_source_status in ["unavailable", "restored_state", "stale_cache"] else str(_timeline.get("source_data_quality", state.get("data_quality", "unavailable")))
	mapping_status = "matched"
	rollover_status = "active"
	recovery_status = "active"
	var controller := _get_weather_state_controller()
	if controller == null or str(controller.call("get_operating_mode_name")) != "AUTO":
		return
	var adapter_result: Dictionary = _godot_adapter.call("apply_sample", published_state, region_id)
	if not bool(adapter_result.get("ok", false)):
		mapping_status = str(adapter_result.get("error", "adapter_apply_failed"))
	if force:
		_emit_status()


func _check_time_mapping(snapshot: Dictionary) -> void:
	var revision := int(snapshot.get("authority_control_revision", 0))
	if _last_control_revision >= 0 and revision != _last_control_revision and not _timeline.is_empty():
		if str(snapshot.get("revision_reason", "")) == "time_scale_set":
			_time_mapping_conflict_latched = true
			mapping_status = "time_mapping_reanchor_required"
	_last_control_revision = revision
	if not _timeline.is_empty() and not _world_scale_matches(snapshot):
		_time_mapping_conflict_latched = true
		mapping_status = "time_scale_mismatch_reanchor_required"
	elif _timeline.is_empty() and not _restore_reanchor_pending and not _forecast_document.is_empty() and _world_scale_matches(snapshot):
		_timeline_anchor_snapshot = snapshot.duplicate(true)
		_try_create_initial_timeline(snapshot)


func _world_scale_matches(snapshot: Dictionary) -> bool:
	return is_equal_approx(float(snapshot.get("time_scale", 0.0)), float(cycles_per_real_day))


func _timeline_cycle_offset_at(snapshot: Dictionary) -> float:
	return _timeline_cycle_offset_at_for(_timeline, snapshot)


func _timeline_cycle_offset_at_for(timeline: Dictionary, snapshot: Dictionary) -> float:
	if timeline.is_empty():
		return -1.0
	var elapsed_position := float(snapshot.get("day_cycle_index", 0)) + float(snapshot.get("cycle_seconds", 0.0)) / 86400.0
	var anchor_position := float(timeline.get("simulation_anchor_cycle_position", 0.0))
	return float(timeline.get("simulation_anchor_timeline_cycle_offset", 0.0)) + elapsed_position - anchor_position


func _timeline_end_cycle_offset(timeline: Dictionary = {}) -> float:
	var source := timeline if not timeline.is_empty() else _timeline
	var frames: Array = source.get("keyframes", [])
	return float(frames.back().get("cycle_offset", 0.0)) if not frames.is_empty() else 0.0


func _remaining_timeline_cycles(snapshot: Dictionary = {}) -> float:
	if _timeline.is_empty():
		return 0.0
	var cursor := snapshot
	if cursor.is_empty() and _world_time_manager != null:
		cursor = _world_time_manager.call("get_authoritative_state") as Dictionary
	return maxf(0.0, _timeline_end_cycle_offset() - _timeline_cycle_offset_at(cursor))


func _current_stockholm_date_key() -> String:
	return _date_key(WorldTimeManagerScript.stockholm_date_from_utc(_utc_now()))


func _date_key(date: Dictionary) -> String:
	if date.is_empty():
		return ""
	return "%04d-%02d-%02d" % [int(date.get("year", 0)), int(date.get("month", 0)), int(date.get("day", 0))]


func _utc_now() -> float:
	if _utc_time_source.is_valid():
		return float(_utc_time_source.call())
	if _world_time_manager != null and _world_time_manager.has_method("get_real_utc_timestamp"):
		return float(_world_time_manager.call("get_real_utc_timestamp"))
	return Time.get_unix_time_from_system()


func _forecast_covers_utc(document: Dictionary, utc_timestamp: float) -> bool:
	var valid_from := str(document.get("valid_from_utc", ""))
	var valid_until := str(document.get("valid_until_utc", ""))
	if not Codec.is_valid_utc_timestamp(valid_from) or not Codec.is_valid_utc_timestamp(valid_until):
		return false
	return utc_timestamp >= float(Codec.parse_utc_timestamp_to_unix(valid_from)) and utc_timestamp < float(Codec.parse_utc_timestamp_to_unix(valid_until))


func _smoothstep01(value: float) -> float:
	var weight := clampf(value, 0.0, 1.0)
	return weight * weight * (3.0 - 2.0 * weight)


func _get_weather_state_controller() -> Node:
	return get_node_or_null("../WeatherStateController")


func _on_operating_mode_changed(mode_name: StringName) -> void:
	if mode_name == &"AUTO":
		_sample_elapsed = sample_interval_real_seconds
		var world_snapshot := _world_time_manager.call("get_authoritative_state") as Dictionary
		_publish_current_sample(world_snapshot, true)
	_mark_persistence_dirty()


func _data_source_label(result: Dictionary) -> String:
	var cache_source := str(result.get("cache_source", ""))
	var stale := bool(result.get("stale", false))
	if stale:
		return "stale_cache"
	if cache_source in ["memory", "disk", "http_304"]:
		return "fresh_cache"
	if cache_source == "network":
		return "live_network_response"
	return "unavailable"


func _safe_forecast_metadata() -> Dictionary:
	if _forecast_document.is_empty():
		return {"provider_id": "", "forecast_issued_at_utc": "", "retrieved_at_utc": "", "valid_from_utc": "", "valid_until_utc": ""}
	return {
		"provider_id": str(_forecast_document.get("provider_id", "")),
		"forecast_issued_at_utc": str(_forecast_document.get("forecast_issued_at_utc", "")),
		"retrieved_at_utc": str(_forecast_document.get("retrieved_at_utc", "")),
		"valid_from_utc": str(_forecast_document.get("valid_from_utc", "")),
		"valid_until_utc": str(_forecast_document.get("valid_until_utc", "")),
		"data_source_status": data_source_status,
		"forecast_data_quality": forecast_data_quality,
	}


func _timestamp_iso(unix_time: float) -> String:
	return Codec._utc_iso_from_unix(int(floor(unix_time))) if unix_time > 0.0 else ""


func _set_runtime_error(status: String, error: String) -> void:
	provider_status = status
	provider_error = error
	mapping_status = status
	_emit_status()


func _emit_status() -> void:
	runtime_status_changed.emit(get_authoritative_weather_snapshot())
