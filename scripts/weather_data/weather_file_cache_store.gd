extends RefCounted
class_name WeatherFileCacheStore

## Atomic, region-keyed disk persistence. The root path is injectable so tests
## can use a dedicated user:// directory.

const CACHE_SCHEMA_VERSION := 1

var base_directory := "user://weather_data/met_norway_locationforecast"


func load_envelope(region_id: String) -> Dictionary:
	var path := _cache_path(region_id)
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"ok": false, "status": "miss"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "status": "unreadable", "error_code": FileAccess.get_open_error()}
	var text := file.get_as_text()
	file.close()
	var parser := JSON.new()
	var parse_error := parser.parse(text)
	if parse_error != OK:
		return {"ok": false, "status": "corrupt", "reason": "json_parse_error", "error_line": parser.get_error_line()}
	var parsed: Variant = parser.data
	if not parsed is Dictionary:
		return {"ok": false, "status": "corrupt", "reason": "root_not_object"}
	if int(parsed.get("cache_schema_version", -1)) != CACHE_SCHEMA_VERSION:
		return {"ok": false, "status": "unsupported_schema", "reason": "unsupported_cache_schema"}
	if str(parsed.get("region_id", "")) != region_id:
		return {"ok": false, "status": "corrupt", "reason": "region_mismatch"}
	return {"ok": true, "status": "hit", "envelope": parsed}


func save_envelope(region_id: String, envelope: Dictionary) -> Dictionary:
	if _cache_path(region_id).is_empty() or str(envelope.get("region_id", "")) != region_id:
		return {"ok": false, "error": "invalid_region_or_envelope"}
	var value := envelope.duplicate(true)
	value["cache_schema_version"] = CACHE_SCHEMA_VERSION
	var target := ProjectSettings.globalize_path(_cache_path(region_id))
	var directory := target.get_base_dir()
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error != OK and error != ERR_ALREADY_EXISTS:
		return {"ok": false, "error": "create_directory_failed", "error_code": error}
	var temporary := "%s.tmp-%d" % [target, OS.get_process_id()]
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "open_temp_failed", "error_code": FileAccess.get_open_error()}
	file.store_string(JSON.stringify(value, "", true, true))
	file.flush()
	file.close()
	var rename_error := DirAccess.rename_absolute(temporary, target)
	if rename_error != OK:
		# Some platforms do not replace an existing destination during rename.
		# Keep the old file intact until the new temporary file is fully written.
		var backup := "%s.old-%d" % [target, OS.get_process_id()]
		var moved_old := false
		if FileAccess.file_exists(target):
			moved_old = DirAccess.rename_absolute(target, backup) == OK
			if not moved_old:
				DirAccess.remove_absolute(temporary)
				return {"ok": false, "error": "preserve_old_cache_failed", "error_code": rename_error}
		rename_error = DirAccess.rename_absolute(temporary, target)
		if rename_error != OK:
			if moved_old:
				DirAccess.rename_absolute(backup, target)
			DirAccess.remove_absolute(temporary)
			return {"ok": false, "error": "atomic_replace_failed", "error_code": rename_error}
		if moved_old:
			DirAccess.remove_absolute(backup)
	return {"ok": true, "path": _cache_path(region_id)}


func remove_region(region_id: String) -> bool:
	var path := _cache_path(region_id)
	if path.is_empty() or not FileAccess.file_exists(path):
		return true
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK


func write_corrupt_for_test(region_id: String) -> bool:
	var path := _cache_path(region_id)
	if path.is_empty():
		return false
	var absolute_path := ProjectSettings.globalize_path(path)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_path.get_base_dir())
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return false
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string("{ deliberately broken")
	file.close()
	return true


func clear_directory() -> void:
	var absolute := ProjectSettings.globalize_path(base_directory)
	if not DirAccess.dir_exists_absolute(absolute):
		return
	var directory := DirAccess.open(base_directory)
	if directory == null:
		return
	directory.list_dir_begin()
	var filename := directory.get_next()
	while not filename.is_empty():
		if not directory.current_is_dir():
			directory.remove(filename)
		filename = directory.get_next()
	directory.list_dir_end()


func _cache_path(region_id: String) -> String:
	if not _is_safe_region_id(region_id):
		return ""
	return "%s/%s.json" % [base_directory.trim_suffix("/"), region_id]


func _is_safe_region_id(region_id: String) -> bool:
	if region_id.is_empty():
		return false
	for character in region_id:
		if not (character.is_valid_identifier() or character == "-"):
			return false
	return true
