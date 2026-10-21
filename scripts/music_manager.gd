extends Node

## Persistent background music playback. The Music bus is created at runtime so
## this feature does not alter the project's existing SFX or Master settings.

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "audio"
const MUSIC_ENABLED_KEY := "music_enabled"
const MUSIC_BUS_NAME := "Music"
const MUSIC_VOLUME_DB := 0.0
const SILENT_VOLUME_DB := -80.0
const USER_FADE_SECONDS := 1.25
const TRACK_CHANGE_FADE_SECONDS := 0.45

@export var settings_file_path := SETTINGS_PATH
@export var start_playback_on_ready := true
@export var track_definitions: Array[Dictionary] = [
	{
		"id": "bgm1",
		"ogg_path": "res://assets/music/processed/bgm1.ogg",
		"mp3_fallback_path": "res://assets/music/bgm1.mp3",
	},
	{
		"id": "bgm2",
		"ogg_path": "res://assets/music/processed/bgm2.ogg",
		"mp3_fallback_path": "res://assets/music/bgm2.mp3",
	},
]

var music_enabled := true
var current_track_index := 0

var _player: AudioStreamPlayer
var _fade_tween: Tween
var _saved_position_seconds := 0.0
var _settings := ConfigFile.new()
var _settings_loaded := false
var _music_bus_index := -1
var _environment_ducking_db := 0.0
var _duck_tween: Tween


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_settings()
	if OS.has_feature("dedicated_server"):
		return
	_ensure_music_bus()
	_create_player()
	if start_playback_on_ready and music_enabled:
		call_deferred("_start_track", current_track_index, 0.0, USER_FADE_SECONDS)


func is_music_enabled() -> bool:
	return music_enabled


func get_current_track_name() -> String:
	if track_definitions.is_empty() or current_track_index < 0 or current_track_index >= track_definitions.size():
		return ""
	return str(track_definitions[current_track_index].get("id", ""))


func get_current_track_index() -> int:
	return current_track_index


## Applies a temporary mix-bus contribution. It does not change the player's
## saved enabled state or any user preference.
func set_environment_ducking_db(value_db: float, fade_seconds: float = 1.25) -> void:
	var target := clampf(value_db, -6.0, 0.0) if is_finite(value_db) else 0.0
	if absf(target - _environment_ducking_db) < 0.12:
		return
	_environment_ducking_db = target
	if _music_bus_index < 0:
		return
	if _duck_tween != null and _duck_tween.is_running():
		_duck_tween.kill()
	var current := AudioServer.get_bus_volume_db(_music_bus_index)
	_duck_tween = create_tween()
	_duck_tween.set_trans(Tween.TRANS_SINE)
	_duck_tween.set_ease(Tween.EASE_IN_OUT)
	_duck_tween.tween_method(_set_music_bus_volume_db, current, target, maxf(fade_seconds, 0.0))


func get_environment_ducking_db() -> float:
	return _environment_ducking_db


func set_music_enabled(enabled: bool) -> void:
	var changed := music_enabled != enabled
	music_enabled = enabled
	if changed:
		_save_settings()

	if _player == null:
		return
	_cancel_fade()
	if enabled:
		if _player.playing:
			_fade_player_to(MUSIC_VOLUME_DB, USER_FADE_SECONDS)
		else:
			_start_track(current_track_index, _saved_position_seconds, USER_FADE_SECONDS)
	else:
		if _player.playing:
			_saved_position_seconds = _player.get_playback_position()
			_fade_player_to(SILENT_VOLUME_DB, USER_FADE_SECONDS, true)


func _ensure_music_bus() -> void:
	_music_bus_index = AudioServer.get_bus_index(MUSIC_BUS_NAME)
	if _music_bus_index < 0:
		AudioServer.add_bus()
		_music_bus_index = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(_music_bus_index, MUSIC_BUS_NAME)
	AudioServer.set_bus_send(_music_bus_index, "Master")
	AudioServer.set_bus_volume_db(_music_bus_index, _environment_ducking_db)


func _create_player() -> void:
	_player = AudioStreamPlayer.new()
	_player.name = "BackgroundMusicPlayer"
	_player.bus = MUSIC_BUS_NAME
	_player.volume_db = SILENT_VOLUME_DB
	_player.finished.connect(_on_track_finished)
	add_child(_player)


func _load_settings() -> void:
	_settings_loaded = false
	music_enabled = true
	if not FileAccess.file_exists(settings_file_path):
		return
	var error := _settings.load(settings_file_path)
	if error != OK:
		push_warning("MusicManager could not read %s; using music enabled by default." % settings_file_path)
		_settings = ConfigFile.new()
		return
	_settings_loaded = true
	var saved_value: Variant = _settings.get_value(SETTINGS_SECTION, MUSIC_ENABLED_KEY, true)
	if typeof(saved_value) == TYPE_BOOL:
		music_enabled = saved_value
	else:
		push_warning("Music setting in %s is invalid; using music enabled by default." % settings_file_path)
		music_enabled = true


func _save_settings() -> void:
	# Reload on every write so Weather/Ocean/Engine settings written by the
	# sibling audio controllers are not overwritten by this manager's cache.
	_settings = ConfigFile.new()
	if FileAccess.file_exists(settings_file_path):
		var load_error := _settings.load(settings_file_path)
		if load_error != OK:
			push_warning("MusicManager could not preserve other settings in %s; starting a fresh config." % settings_file_path)
			_settings = ConfigFile.new()
	_settings.set_value(SETTINGS_SECTION, MUSIC_ENABLED_KEY, music_enabled)
	var error := _settings.save(settings_file_path)
	if error != OK:
		push_warning("MusicManager could not save music preference to %s (error %d)." % [settings_file_path, error])
	else:
		_settings_loaded = true


func _set_music_bus_volume_db(value_db: float) -> void:
	if _music_bus_index >= 0:
		AudioServer.set_bus_volume_db(_music_bus_index, clampf(value_db, -6.0, 0.0))


func _start_track(start_index: int, playback_position: float, fade_seconds: float) -> bool:
	if not music_enabled or _player == null or track_definitions.is_empty():
		return false
	_cancel_fade()
	_player.stop()
	var candidate_index := posmod(start_index, track_definitions.size())
	for _attempt in range(track_definitions.size()):
		var definition := track_definitions[candidate_index]
		var loaded := _load_track(definition)
		var stream := loaded.get("stream") as AudioStream
		if stream != null:
			current_track_index = candidate_index
			_player.stream = stream
			_player.volume_db = SILENT_VOLUME_DB if fade_seconds > 0.0 else MUSIC_VOLUME_DB
			var safe_position := maxf(0.0, playback_position)
			if stream.get_length() > 0.0 and safe_position >= stream.get_length() - 0.05:
				safe_position = 0.0
			_saved_position_seconds = safe_position
			_player.play(safe_position)
			if fade_seconds > 0.0:
				_fade_player_to(MUSIC_VOLUME_DB, fade_seconds)
			return true
		candidate_index = (candidate_index + 1) % track_definitions.size()
	push_error("MusicManager could not load any background music track; playback remains stopped.")
	return false


func _load_track(definition: Dictionary) -> Dictionary:
	var preferred_path := str(definition.get("ogg_path", ""))
	var fallback_path := str(definition.get("mp3_fallback_path", ""))
	for path in [preferred_path, fallback_path]:
		if path.is_empty() or not ResourceLoader.exists(path):
			continue
		var stream := ResourceLoader.load(path) as AudioStream
		if stream != null:
			return {"stream": stream, "path": path}
	push_warning(
		"MusicManager cannot load '%s' (tried %s and %s)." % [
			str(definition.get("id", "unnamed")), preferred_path, fallback_path,
		]
	)
	return {}


func _fade_player_to(target_volume_db: float, duration: float, stop_when_done: bool = false) -> void:
	_cancel_fade()
	if duration <= 0.0:
		_player.volume_db = target_volume_db
		if stop_when_done:
			_finish_fade_out()
		return
	_fade_tween = create_tween()
	_fade_tween.set_trans(Tween.TRANS_SINE)
	_fade_tween.set_ease(Tween.EASE_IN_OUT)
	_fade_tween.tween_property(_player, "volume_db", target_volume_db, duration)
	if stop_when_done:
		_fade_tween.tween_callback(_finish_fade_out)


func _finish_fade_out() -> void:
	if music_enabled or _player == null or not _player.playing:
		return
	_saved_position_seconds = _player.get_playback_position()
	_player.stop()
	_player.volume_db = SILENT_VOLUME_DB
	_fade_tween = null


func _cancel_fade() -> void:
	if _fade_tween != null and _fade_tween.is_running():
		_fade_tween.kill()
	_fade_tween = null


func _on_track_finished() -> void:
	_cancel_fade()
	_saved_position_seconds = 0.0
	if track_definitions.is_empty():
		return
	current_track_index = (current_track_index + 1) % track_definitions.size()
	if music_enabled:
		_start_track(current_track_index, 0.0, TRACK_CHANGE_FADE_SECONDS)

