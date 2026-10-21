extends RefCounted
class_name WeatherRuntimePersistence

## Versioned, atomic persistence for the local weather authority. The same
## dictionary contract can be hosted by a server-side storage adapter later.

const Core := preload("res://scripts/weather_data/weather_simulation_core.gd")
const Codec := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const SCHEMA_VERSION := 1

var file_path := "user://weather_data/weather_runtime_state.json"


func load_state(expected_region_id: String = "") -> Dictionary:
	if not FileAccess.file_exists(file_path):
		return {"ok": false, "status": "missing"}
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return {"ok": false, "status": "unreadable", "error_code": FileAccess.get_open_error()}
	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	file.close()
	if parse_error != OK or not parser.data is Dictionary:
		return {"ok": false, "status": "corrupt", "reason": "json_parse_error" if parse_error != OK else "root_not_object"}
	var payload: Dictionary = parser.data
	var validation := validate_payload(payload, expected_region_id)
	if not bool(validation.get("ok", false)):
		return {"ok": false, "status": "invalid", "reason": str(validation.get("error", "invalid_payload"))}
	return {"ok": true, "status": "loaded", "data": payload}


func save_state(payload: Dictionary) -> Dictionary:
	var validation := validate_payload(payload, str(payload.get("region_id", "")))
	if not bool(validation.get("ok", false)):
		return {"ok": false, "error": str(validation.get("error", "invalid_payload"))}
	var absolute_path := ProjectSettings.globalize_path(file_path)
	var directory := absolute_path.get_base_dir()
	var directory_error := DirAccess.make_dir_recursive_absolute(directory)
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return {"ok": false, "error": "create_directory_failed", "error_code": directory_error}
	var temporary := "%s.tmp-%d" % [absolute_path, OS.get_process_id()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "open_temp_failed", "error_code": FileAccess.get_open_error()}
	file.store_string(JSON.stringify(payload, "\t", true))
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(temporary)
		return {"ok": false, "error": "write_temp_failed", "error_code": write_error}
	var rename_error := DirAccess.rename_absolute(temporary, absolute_path)
	if rename_error != OK:
		# Preserve the last complete save while replacing it on platforms where
		# rename does not replace an existing file atomically.
		var backup := "%s.old-%d" % [absolute_path, OS.get_process_id()]
		var moved_old := false
		if FileAccess.file_exists(absolute_path):
			moved_old = DirAccess.rename_absolute(absolute_path, backup) == OK
			if not moved_old:
				DirAccess.remove_absolute(temporary)
				return {"ok": false, "error": "preserve_previous_save_failed", "error_code": rename_error}
		rename_error = DirAccess.rename_absolute(temporary, absolute_path)
		if rename_error != OK:
			if moved_old:
				DirAccess.rename_absolute(backup, absolute_path)
			DirAccess.remove_absolute(temporary)
			return {"ok": false, "error": "atomic_replace_failed", "error_code": rename_error}
		if moved_old:
			DirAccess.remove_absolute(backup)
	return {"ok": true, "path": file_path}


static func validate_payload(payload: Variant, expected_region_id: String = "") -> Dictionary:
	if not payload is Dictionary:
		return {"ok": false, "error": "root_not_object"}
	if int(payload.get("schema_version", -1)) != SCHEMA_VERSION:
		return {"ok": false, "error": "unsupported_schema"}
	if str(payload.get("save_format", "")) != "weather_runtime_state":
		return {"ok": false, "error": "save_format_mismatch"}
	var region_id := str(payload.get("region_id", ""))
	if region_id.is_empty() or (not expected_region_id.is_empty() and region_id != expected_region_id):
		return {"ok": false, "error": "region_mismatch" if not region_id.is_empty() else "region_missing"}
	if not str(payload.get("operating_mode", "")) in ["AUTO", "MANUAL"]:
		return {"ok": false, "error": "operating_mode_invalid"}
	if payload.get("current_sample", {}) is not Dictionary or payload.get("forecast_document", {}) is not Dictionary:
		return {"ok": false, "error": "weather_payload_invalid"}
	var forecast_document: Dictionary = payload.get("forecast_document", {})
	if not forecast_document.is_empty():
		if str(forecast_document.get("region_id", "")) != region_id:
			return {"ok": false, "error": "forecast_region_mismatch"}
		var forecast_validation := Codec.validate_standardized_document(forecast_document)
		if not bool(forecast_validation.get("ok", false)):
			return {"ok": false, "error": "forecast_document_invalid:%s" % str(forecast_validation.get("error", "unknown"))}
	var timeline: Variant = payload.get("active_timeline", {})
	if timeline is Dictionary and not timeline.is_empty():
		var timeline_result := Core.deserialize_timeline(JSON.stringify(timeline))
		if not bool(timeline_result.get("ok", false)):
			return {"ok": false, "error": "timeline_invalid:%s" % str(timeline_result.get("error", "unknown"))}
		if str(timeline.get("region_id", "")) != region_id:
			return {"ok": false, "error": "timeline_region_mismatch"}
		if str(payload.get("timeline_version", "")) != str(timeline.get("timeline_version", "")):
			return {"ok": false, "error": "timeline_version_mismatch"}
		if int(payload.get("simulation_seed", -1)) != int(timeline.get("simulation_seed", -2)):
			return {"ok": false, "error": "timeline_seed_mismatch"}
		if not payload.get("real_day_boundaries_utc", []) is Array or not payload.get("calendar_day_labels", []) is Array:
			return {"ok": false, "error": "calendar_mapping_invalid"}
		if JSON.stringify(payload.get("real_day_boundaries_utc", [])) != JSON.stringify(timeline.get("real_day_boundaries_utc", [])):
			return {"ok": false, "error": "calendar_boundaries_mismatch"}
		if JSON.stringify(payload.get("calendar_day_labels", [])) != JSON.stringify(timeline.get("calendar_day_labels", [])):
			return {"ok": false, "error": "calendar_labels_mismatch"}
	elif not timeline is Dictionary:
		return {"ok": false, "error": "timeline_not_object"}
	var cursor: Variant = payload.get("saved_cursor", {})
	if not cursor is Dictionary:
		return {"ok": false, "error": "saved_cursor_invalid"}
	for field in ["day_cycle_index", "cycle_seconds", "time_scale", "paused", "authoritative_timestamp_utc"]:
		if not cursor.has(field):
			return {"ok": false, "error": "saved_cursor_field_missing:%s" % field}
	if int(cursor["day_cycle_index"]) < 0 or not is_finite(float(cursor["cycle_seconds"])) or float(cursor["cycle_seconds"]) < 0.0 or float(cursor["cycle_seconds"]) >= 86400.0:
		return {"ok": false, "error": "saved_cursor_position_invalid"}
	if not is_finite(float(cursor["time_scale"])) or float(cursor["time_scale"]) <= 0.0 or not is_finite(float(cursor["authoritative_timestamp_utc"])):
		return {"ok": false, "error": "saved_cursor_clock_invalid"}
	var history: Variant = payload.get("history_segments", [])
	if not history is Array:
		return {"ok": false, "error": "history_segments_invalid"}
	for segment_value in history:
		if not segment_value is Dictionary or str(segment_value.get("region_id", "")) != region_id:
			return {"ok": false, "error": "history_segment_invalid"}
		var frames: Variant = segment_value.get("keyframes", null)
		if not frames is Array or frames.is_empty():
			return {"ok": false, "error": "history_segment_keyframes_invalid"}
		var archived_from := float(segment_value.get("archived_from_cycle_offset", NAN))
		var archived_through := float(segment_value.get("archived_through_cycle_offset", NAN))
		if not is_finite(archived_from) or not is_finite(archived_through) or archived_from > archived_through:
			return {"ok": false, "error": "history_segment_range_invalid"}
		var previous_offset := -INF
		for frame_value in frames:
			if not frame_value is Dictionary or not frame_value.has("cycle_offset"):
				return {"ok": false, "error": "history_segment_frame_invalid"}
			var frame_offset := float(frame_value["cycle_offset"])
			if not is_finite(frame_offset) or frame_offset < previous_offset or frame_offset < archived_from - 0.000001 or frame_offset > archived_through + 0.000001:
				return {"ok": false, "error": "history_segment_frame_range_invalid"}
			previous_offset = frame_offset
	return {"ok": true}


func remove_for_testing() -> bool:
	if not FileAccess.file_exists(file_path):
		return true
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(file_path)) == OK
