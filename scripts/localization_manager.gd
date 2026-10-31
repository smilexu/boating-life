extends Node

## Owns the player's language choice and applies it before the main scene builds UI.

signal locale_changed(locale_id: String)

const SETTINGS_PATH := "user://localization_settings.cfg"
const SETTINGS_SECTION := "localization"
const LOCALE_KEY := "locale"
const DEFAULT_LOCALE := "zh_CN"
const LOCALE_IDS := ["zh_CN", "en"]
const LOCALE_LABELS := ["简体中文", "English"]

var current_locale_id := DEFAULT_LOCALE


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_saved_locale()
	TranslationServer.set_locale(current_locale_id)


func get_locale_index() -> int:
	return LOCALE_IDS.find(current_locale_id)


func get_locale_labels() -> PackedStringArray:
	return PackedStringArray(LOCALE_LABELS)


func set_locale_index(index: int) -> void:
	if index < 0 or index >= LOCALE_IDS.size():
		return
	set_locale_id(LOCALE_IDS[index])


func set_locale_id(locale_id: String) -> void:
	if not LOCALE_IDS.has(locale_id):
		return
	var changed := current_locale_id != locale_id
	current_locale_id = locale_id
	TranslationServer.set_locale(current_locale_id)
	_save_locale()
	if changed:
		locale_changed.emit(current_locale_id)


func _load_saved_locale() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	var saved_locale := str(config.get_value(SETTINGS_SECTION, LOCALE_KEY, DEFAULT_LOCALE))
	if LOCALE_IDS.has(saved_locale):
		current_locale_id = saved_locale


func _save_locale() -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value(SETTINGS_SECTION, LOCALE_KEY, current_locale_id)
	config.save(SETTINGS_PATH)
