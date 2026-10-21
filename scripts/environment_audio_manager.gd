extends Node
class_name EnvironmentAudioManager

## Client-side loops for weather/ocean ambience and a bounded thunder voice pool.
## All driving values are read-only samples from the existing game systems.

const MixProfile := preload("res://scripts/audio_mix_profile.gd")
const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "audio"
const LOOP_DEFINITIONS := {
	"W01": {"bus": "Weather", "fallback": "W01.mp3"},
	"W02": {"bus": "Weather", "fallback": "W02.mp3"},
	"R02": {"bus": "Weather", "fallback": "R02.mp3"},
	"R03": {"bus": "Weather", "fallback": "R03.mp3"},
	"SW01": {"bus": "Ocean", "fallback": "SW01.mp3"},
	"SW02": {"bus": "Ocean", "fallback": "SW02.mp3"},
	"SW03": {"bus": "Ocean", "fallback": "SW03.mp3"},
}
const THUNDER_STEMS := ["T01", "T02", "T03"]
const LOOP_RESPONSE_SECONDS := 1.4
const UPDATE_INTERVAL_SECONDS := 0.20
const THUNDER_VOICE_COUNT := 6
const THUNDER_MAX_DISTANCE_M := 20000.0
const RAIN_PLAYBACK_TRIM_DB := 2.0
const THUNDER_PLAYBACK_TRIM_DB := 1.5

@export_node_path("Node3D") var boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node3D") var listener_path := NodePath("../PlayerBoat/FollowCameraRig/Camera3D")
@export_node_path("Node") var wind_field_path := NodePath("../WindField")
@export_node_path("Node") var weather_state_controller_path := NodePath("../WeatherStateController")
@export_node_path("Node") var wave_sampler_path := NodePath("../WaveSampler")
@export_node_path("Node") var lightning_event_controller_path := NodePath("../LightningEventController")
@export_node_path("Node") var music_manager_path := NodePath("../../MusicManager")
@export var settings_file_path := SETTINGS_PATH
@export_range(0.0, 1.0, 0.01) var default_weather_volume := 0.68
@export_range(0.0, 1.0, 0.01) var default_ocean_volume := 0.72
@export var audio_output_enabled := true

var weather_volume := 0.68
var ocean_volume := 0.72

var _boat: Node3D
var _listener: Node3D
var _wind_field: Node
var _weather_state_controller: Node
var _wave_sampler: Node
var _lightning_controller: Node
var _music_manager: Node
var _loop_players: Dictionary = {}
var _loop_gains: Dictionary = {}
var _target_gains: Dictionary = {}
var _thunder_voices: Array[AudioStreamPlayer3D] = []
var _thunder_queue: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
var _update_elapsed := 0.0
var _near_thunder_duck_until_msec := 0
var _last_thunder_delay_seconds := -1.0
var _last_rain_mm_per_hour := 0.0
var _last_relative_wind_mps := 0.0
var _last_sea_amplitude_rms_m := 0.0
var _last_formal_storm_intensity := 0.0
var _thunder_dropped_count := 0
var _audio_initialized := false
var _debug_audio_override: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_boat = get_node_or_null(boat_path) as Node3D
	_listener = get_node_or_null(listener_path) as Node3D
	_wind_field = get_node_or_null(wind_field_path)
	_weather_state_controller = get_node_or_null(weather_state_controller_path)
	_wave_sampler = get_node_or_null(wave_sampler_path)
	_lightning_controller = get_node_or_null(lightning_event_controller_path)
	_music_manager = get_node_or_null(music_manager_path)
	_load_mix_settings()
	_rng.randomize()
	if not audio_output_enabled or not MixProfile.runtime_audio_allowed(
		OS.has_feature("dedicated_server"), DisplayServer.get_name().to_lower() == "headless"
	):
		set_process(false)
		return
	_ensure_audio_buses()
	_ensure_master_limiter()
	_apply_bus_volume("Weather", weather_volume)
	_apply_bus_volume("Ocean", ocean_volume)
	_create_loop_players()
	_create_thunder_pool()
	_connect_lightning_events()
	_read_formal_weather_state()
	_audio_initialized = true


func _process(delta: float) -> void:
	if not _audio_initialized:
		return
	_update_elapsed += delta
	if _update_elapsed >= UPDATE_INTERVAL_SECONDS:
		var sample_delta := minf(_update_elapsed, 1.0)
		_update_elapsed = 0.0
		_update_mix_targets(sample_delta)
		_update_music_ducking()
	_update_loop_envelopes(delta)
	_play_due_thunder()


func get_weather_volume() -> float:
	return weather_volume


func get_ocean_volume() -> float:
	return ocean_volume


func set_weather_volume(value: float) -> void:
	weather_volume = clampf(value, 0.0, 1.0) if is_finite(value) else default_weather_volume
	_apply_bus_volume("Weather", weather_volume)
	_save_mix_setting("weather_volume", weather_volume)


func set_ocean_volume(value: float) -> void:
	ocean_volume = clampf(value, 0.0, 1.0) if is_finite(value) else default_ocean_volume
	_apply_bus_volume("Ocean", ocean_volume)
	_save_mix_setting("ocean_volume", ocean_volume)


## Temporary local mix test values only. These values never write to weather,
## wind, wave, or persistence systems.
func set_debug_audio_override(values: Dictionary) -> void:
	_debug_audio_override = values.duplicate(true)


func clear_debug_audio_override() -> void:
	_debug_audio_override.clear()


func get_audio_diagnostics() -> Dictionary:
	return {
		"audio_initialized": _audio_initialized,
		"current_wind_mps": float(_wind_field.get_wind_at(_boat.global_position).length()) if is_instance_valid(_wind_field) and is_instance_valid(_boat) and _wind_field.has_method("get_wind_at") else 0.0,
		"relative_wind_mps": _last_relative_wind_mps,
		"rain_mm_per_hour": _last_rain_mm_per_hour,
		"sea_amplitude_rms_m": _last_sea_amplitude_rms_m,
		"target_loop_gains": _target_gains.duplicate(true),
		"actual_loop_gains": _loop_gains.duplicate(true),
		"rain_playback_trim_db": RAIN_PLAYBACK_TRIM_DB,
		"thunder_playback_trim_db": THUNDER_PLAYBACK_TRIM_DB,
		"thunder_queue_length": _thunder_queue.size(),
		"last_thunder_delay_seconds": _last_thunder_delay_seconds,
		"music_ducking_db": MixProfile.music_ducking_db(_last_formal_storm_intensity, Time.get_ticks_msec() < _near_thunder_duck_until_msec),
		"dropped_thunder_events": _thunder_dropped_count,
		"audio_test_override_active": not _debug_audio_override.is_empty(),
	}


func get_pending_thunder_count() -> int:
	return _thunder_queue.size()


func enqueue_thunder_event(event: Dictionary, now_msec: int = -1) -> bool:
	var event_position: Variant = event.get("sound_source_position", event.get("world_position"))
	if not event_position is Vector3:
		return false
	var source_position: Vector3 = event_position
	var listener_position := _get_listener_position()
	var distance := listener_position.distance_to(source_position)
	var delay := MixProfile.thunder_delay_seconds(distance)
	var clock_msec := Time.get_ticks_msec() if now_msec < 0 else now_msec
	_thunder_queue.append({
		"event_id": int(event.get("event_id", -1)),
		"type": str(event.get("type", "distant_cg")),
		"source": str(event.get("source", "formal")),
		"intensity": clampf(float(event.get("intensity", 0.32)), 0.0, 1.0),
		"world_position": source_position,
		"distance_m": distance,
		"delay_seconds": delay,
		"arrival_msec": clock_msec + int(round(delay * 1000.0)),
	})
	_last_thunder_delay_seconds = delay
	return true


func _ensure_audio_buses() -> void:
	for bus_name in ["Weather", "Ocean"]:
		_ensure_bus(bus_name)


func _ensure_bus(bus_name: String) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		AudioServer.add_bus()
		index = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(index, bus_name)
	AudioServer.set_bus_send(index, "Master")


func _ensure_master_limiter() -> void:
	var master_index := AudioServer.get_bus_index("Master")
	if master_index < 0:
		return
	for effect_index in range(AudioServer.get_bus_effect_count(master_index)):
		if AudioServer.get_bus_effect(master_index, effect_index) is AudioEffectLimiter:
			return
	var limiter := AudioEffectLimiter.new()
	limiter.threshold_db = -2.0
	limiter.ceiling_db = -0.5
	AudioServer.add_bus_effect(master_index, limiter)


func _create_loop_players() -> void:
	for stem in LOOP_DEFINITIONS.keys():
		var definition: Dictionary = LOOP_DEFINITIONS[stem]
		var source := _load_audio_stream(stem, str(definition["fallback"]), true)
		if source == null:
			push_warning(
				"EnvironmentAudioManager could not load %s; its loop is disabled. " % stem
				+ "Check that the asset exists and Godot has finished importing it."
			)
			continue
		var loop_stream := source.duplicate(true) as AudioStream
		if loop_stream is AudioStreamOggVorbis:
			(loop_stream as AudioStreamOggVorbis).loop = true
		elif loop_stream is AudioStreamMP3:
			(loop_stream as AudioStreamMP3).loop = true
		else:
			push_warning("EnvironmentAudioManager cannot loop unsupported stream %s." % stem)
			continue
		var player := AudioStreamPlayer.new()
		player.name = stem + "Loop"
		player.stream = loop_stream
		player.bus = str(definition["bus"])
		player.volume_db = MixProfile.SILENT_DB
		add_child(player)
		_loop_players[stem] = player
		_loop_gains[stem] = 0.0
		_target_gains[stem] = 0.0
		player.play()


func _create_thunder_pool() -> void:
	for index in range(THUNDER_VOICE_COUNT):
		var voice := AudioStreamPlayer3D.new()
		voice.name = "ThunderVoice%d" % index
		voice.bus = "Weather"
		voice.max_distance = THUNDER_MAX_DISTANCE_M
		voice.unit_size = 1.0
		voice.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		voice.panning_strength = 1.0
		voice.volume_db = MixProfile.SILENT_DB
		add_child(voice)
		_thunder_voices.append(voice)


func _connect_lightning_events() -> void:
	if _lightning_controller == null or not _lightning_controller.has_signal("lightning_event_started"):
		return
	var callback := Callable(self, "_on_lightning_event_started")
	if not _lightning_controller.is_connected("lightning_event_started", callback):
		_lightning_controller.connect("lightning_event_started", callback)


func _on_lightning_event_started(event: Dictionary) -> void:
	if str(event.get("source", "formal")) not in ["formal", "debug"]:
		return
	enqueue_thunder_event(event)


func _update_mix_targets(_delta: float) -> void:
	if is_instance_valid(_boat) and is_instance_valid(_wind_field) and _wind_field.has_method("get_wind_at"):
		var air_velocity: Vector3 = _wind_field.call("get_wind_at", _boat.global_position)
		var boat_speed := float(_boat.get("speed_mps"))
		var boat_velocity := -_boat.global_basis.z * boat_speed
		_last_relative_wind_mps = (air_velocity - boat_velocity).length()
		if _debug_audio_override.has("relative_wind_mps"):
			_last_relative_wind_mps = maxf(float(_debug_audio_override["relative_wind_mps"]), 0.0)
		var wind_gains := MixProfile.wind_layer_gains(_last_relative_wind_mps)
		_target_gains["W01"] = float(wind_gains["light"])
		_target_gains["W02"] = float(wind_gains["strong"])
	else:
		_target_gains["W01"] = 0.0
		_target_gains["W02"] = 0.0

	var precipitation := _read_formal_precipitation()
	_last_rain_mm_per_hour = float(precipitation.get("intensity_mm_per_hour", 0.0)) if bool(precipitation.get("available", false)) else 0.0
	if _debug_audio_override.has("rain_mm_per_hour"):
		_last_rain_mm_per_hour = maxf(float(_debug_audio_override["rain_mm_per_hour"]), 0.0)
	var rain_gains := MixProfile.rain_layer_gains(_last_rain_mm_per_hour)
	_target_gains["R02"] = float(rain_gains["moderate"])
	_target_gains["R03"] = float(rain_gains["heavy"])

	_last_sea_amplitude_rms_m = _read_wave_amplitude_rms()
	if _debug_audio_override.has("sea_amplitude_rms_m"):
		_last_sea_amplitude_rms_m = maxf(float(_debug_audio_override["sea_amplitude_rms_m"]), 0.0)
	var sea_gains := MixProfile.sea_layer_gains(_last_sea_amplitude_rms_m)
	_target_gains["SW01"] = float(sea_gains["small"])
	_target_gains["SW02"] = float(sea_gains["medium"])
	_target_gains["SW03"] = float(sea_gains["large"])


func _update_loop_envelopes(delta: float) -> void:
	var weight := 1.0 - exp(-maxf(delta, 0.0) / LOOP_RESPONSE_SECONDS)
	for stem in _loop_players.keys():
		var target := clampf(float(_target_gains.get(stem, 0.0)), 0.0, 1.0)
		var actual := lerpf(float(_loop_gains.get(stem, 0.0)), target, weight)
		_loop_gains[stem] = actual
		var player := _loop_players[stem] as AudioStreamPlayer
		if player == null:
			continue
		var playback_gain_db := MixProfile.linear_gain_to_db(actual)
		if stem in ["R02", "R03"] and actual > 0.001:
			playback_gain_db += RAIN_PLAYBACK_TRIM_DB
		player.volume_db = playback_gain_db
		if target <= 0.0005 and actual <= 0.001 and player.playing:
			player.stop()
		elif target > 0.0005 and not player.playing:
			player.play()


func _read_formal_precipitation() -> Dictionary:
	if _weather_state_controller != null and _weather_state_controller.has_method("get_precipitation_visual_state"):
		return _weather_state_controller.call("get_precipitation_visual_state")
	return {"available": false, "intensity_mm_per_hour": 0.0, "data_quality": "unavailable"}


func _read_formal_weather_state() -> void:
	var precipitation := _read_formal_precipitation()
	_last_rain_mm_per_hour = float(precipitation.get("intensity_mm_per_hour", 0.0)) if bool(precipitation.get("available", false)) else 0.0
	if _weather_state_controller != null and _weather_state_controller.has_method("get_thunderstorm_visual_state"):
		var storm: Dictionary = _weather_state_controller.call("get_thunderstorm_visual_state")
		_last_formal_storm_intensity = float(storm.get("intensity", 0.0)) if bool(storm.get("available", false)) else 0.0
	if _debug_audio_override.has("storm_intensity"):
		_last_formal_storm_intensity = clampf(float(_debug_audio_override["storm_intensity"]), 0.0, 1.0)


func _read_wave_amplitude_rms() -> float:
	if _wave_sampler == null or not _wave_sampler.has_method("get_effective_wave_settings") or not _wave_sampler.has_method("get_effective_wave_strength"):
		return 0.0
	var settings := _wave_sampler.call("get_effective_wave_settings") as SeaWaveSettings
	if settings == null or settings.waves.is_empty():
		return 0.0
	var strength := absf(float(_wave_sampler.call("get_effective_wave_strength")))
	var squared_amplitude := 0.0
	for wave: GerstnerWave in settings.waves:
		squared_amplitude += pow(absf(wave.amplitude) * strength, 2.0)
	return sqrt(squared_amplitude * 0.5)


func _update_music_ducking() -> void:
	if _weather_state_controller != null and _weather_state_controller.has_method("get_thunderstorm_visual_state"):
		var storm: Dictionary = _weather_state_controller.call("get_thunderstorm_visual_state")
		_last_formal_storm_intensity = float(storm.get("intensity", 0.0)) if bool(storm.get("available", false)) else 0.0
	if _debug_audio_override.has("storm_intensity"):
		_last_formal_storm_intensity = clampf(float(_debug_audio_override["storm_intensity"]), 0.0, 1.0)
	var near_active := Time.get_ticks_msec() < _near_thunder_duck_until_msec
	var duck_db := MixProfile.music_ducking_db(_last_formal_storm_intensity, near_active)
	if _music_manager != null and _music_manager.has_method("set_environment_ducking_db"):
		_music_manager.call("set_environment_ducking_db", duck_db)


func _play_due_thunder() -> void:
	if _thunder_queue.is_empty():
		return
	var now := Time.get_ticks_msec()
	var next_index := -1
	var next_arrival := 0x7fffffff
	for index in range(_thunder_queue.size()):
		var arrival := int(_thunder_queue[index]["arrival_msec"])
		if arrival <= now and arrival < next_arrival:
			next_index = index
			next_arrival = arrival
	if next_index < 0:
		return
	var event: Dictionary = _thunder_queue.pop_at(next_index)
	_play_thunder_event(event)


func _play_thunder_event(event: Dictionary) -> void:
	var voice := _acquire_thunder_voice()
	if voice == null:
		_thunder_dropped_count += 1
		return
	var distance := float(event.get("distance_m", 0.0))
	if distance <= 1200.0:
		_near_thunder_duck_until_msec = Time.get_ticks_msec() + 1800
	var stem := MixProfile.thunder_stem_for_distance(distance)
	var fallback := stem + ".mp3"
	var stream := _load_audio_stream(stem, fallback)
	if stream == null:
		push_warning("EnvironmentAudioManager could not load thunder asset %s." % stem)
		return
	voice.stop()
	voice.stream = stream.duplicate(true) as AudioStream
	voice.global_position = event["world_position"]
	var intensity := float(event.get("intensity", 0.32))
	var distance_gain := exp(-distance / 10500.0)
	var intensity_gain := lerpf(0.55, 1.0, clampf(intensity, 0.0, 1.0))
	voice.volume_db = MixProfile.linear_gain_to_db(distance_gain * intensity_gain) + THUNDER_PLAYBACK_TRIM_DB
	voice.pitch_scale = _rng.randf_range(0.97, 1.03)
	voice.attenuation_filter_cutoff_hz = clampf(10000.0 - distance * 0.55, 1400.0, 10000.0)
	voice.play()


func _acquire_thunder_voice() -> AudioStreamPlayer3D:
	for voice in _thunder_voices:
		if not voice.playing:
			return voice
	return null


func _get_listener_position() -> Vector3:
	if is_instance_valid(_listener):
		return _listener.global_position
	if is_instance_valid(_boat):
		return _boat.global_position
	return Vector3.ZERO


func _load_audio_stream(stem: String, fallback_filename: String, prefer_loop_variant: bool = false) -> AudioStream:
	var paths: Array[String] = []
	if prefer_loop_variant:
		paths.append("res://assets/sfx/processed/%s_loop.ogg" % stem)
	paths.append("res://assets/sfx/processed/%s.ogg" % stem)
	paths.append("res://assets/sfx/%s" % fallback_filename)
	for path in paths:
		if not ResourceLoader.exists(path):
			continue
		var stream := ResourceLoader.load(path) as AudioStream
		if stream != null:
			return stream
	return null


func _load_mix_settings() -> void:
	weather_volume = _read_mix_setting("weather_volume", default_weather_volume)
	ocean_volume = _read_mix_setting("ocean_volume", default_ocean_volume)


func _read_mix_setting(key: String, fallback: float) -> float:
	if not FileAccess.file_exists(settings_file_path):
		return fallback
	var config := ConfigFile.new()
	if config.load(settings_file_path) != OK:
		return fallback
	var value: Variant = config.get_value(SETTINGS_SECTION, key, fallback)
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)):
		return fallback
	return clampf(float(value), 0.0, 1.0)


func _save_mix_setting(key: String, value: float) -> void:
	var config := ConfigFile.new()
	if FileAccess.file_exists(settings_file_path) and config.load(settings_file_path) != OK:
		push_warning("EnvironmentAudioManager could not read %s; preserving defaults before saving." % settings_file_path)
		config = ConfigFile.new()
	config.set_value(SETTINGS_SECTION, key, value)
	var error := config.save(settings_file_path)
	if error != OK:
		push_warning("EnvironmentAudioManager could not save %s (error %d)." % [settings_file_path, error])


func _apply_bus_volume(bus_name: String, volume: float) -> void:
	var index := AudioServer.get_bus_index(bus_name)
	if index < 0:
		return
	var safe_volume := clampf(volume, 0.0, 1.0)
	AudioServer.set_bus_mute(index, safe_volume <= 0.0001)
	if safe_volume > 0.0001:
		AudioServer.set_bus_volume_db(index, MixProfile.linear_gain_to_db(safe_volume))
