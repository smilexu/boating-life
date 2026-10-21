extends RefCounted
class_name WeatherUserAgentSettings

## Resolves the MET Norway contact identifier without embedding private details
## in source. Environment variables take precedence over local, ignored config.

const DEFAULT_LOCAL_CONFIG_PATH := "res://config/weather_provider.local.json"
const DEFAULT_USER_CONFIG_PATH := "user://weather_data/provider_settings.json"
const CONTACT_ENVIRONMENT_VARIABLE := "MET_NORWAY_CONTACT"


static func load_contact(config_path: String = "", environment_override: String = "") -> String:
	var environment_contact := environment_override.strip_edges()
	if environment_contact.is_empty():
		environment_contact = OS.get_environment(CONTACT_ENVIRONMENT_VARIABLE).strip_edges()
	if not environment_contact.is_empty():
		return environment_contact
	var paths: Array[String] = []
	if not config_path.is_empty():
		paths.append(config_path)
	else:
		paths.append(DEFAULT_USER_CONFIG_PATH)
		paths.append(DEFAULT_LOCAL_CONFIG_PATH)
	for path in paths:
		var contact := _read_contact_file(path)
		if not contact.is_empty():
			return contact
	return ""


static func save_contact(contact: String, path: String = DEFAULT_USER_CONFIG_PATH) -> Dictionary:
	var trimmed := contact.strip_edges()
	if trimmed.is_empty() or trimmed.contains("\n") or trimmed.contains("\r"):
		return {"ok": false, "error": "contact_invalid"}
	var absolute_path := ProjectSettings.globalize_path(path)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_path.get_base_dir())
	if directory_error != OK and directory_error != ERR_ALREADY_EXISTS:
		return {"ok": false, "error": "create_directory_failed", "error_code": directory_error}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "open_config_failed", "error_code": FileAccess.get_open_error()}
	file.store_string(JSON.stringify({"user_agent_contact": trimmed}, "\t", true))
	file.close()
	return {"ok": true, "path": path}


static func _read_contact_file(path: String) -> String:
	if path.is_empty() or not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	file.close()
	if parse_error != OK or not parser.data is Dictionary:
		return ""
	return str(parser.data.get("user_agent_contact", "")).strip_edges()
