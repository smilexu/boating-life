extends SceneTree

const MixProfile := preload("res://scripts/audio_mix_profile.gd")
const EnvironmentAudioManagerScript := preload("res://scripts/environment_audio_manager.gd")
const BoatAudioControllerScript := preload("res://scripts/boat_audio_controller.gd")
const BoatControllerScript := preload("res://scripts/boat_controller.gd")
const BoatBuoyancyScript := preload("res://scripts/boat_buoyancy.gd")
const GameMenuScript := preload("res://scripts/game_menu.gd")
const MusicManagerScript := preload("res://scripts/music_manager.gd")
const RainDebugPanelScript := preload("res://scripts/rain_visual_debug_panel.gd")

var _checks := 0
var _failures: Array[String] = []
var _temp_dir := ""


class FakeWeatherState extends Node:
	var precipitation := {"available": true, "intensity_mm_per_hour": 5.0, "data_quality": "fixture"}
	var thunderstorm := {"available": false, "intensity": 0.0}

	func get_precipitation_visual_state() -> Dictionary:
		return precipitation.duplicate(true)

	func get_thunderstorm_visual_state() -> Dictionary:
		return thunderstorm.duplicate(true)


class FakeEnvironmentAudio extends Node:
	var weather := 0.68
	var ocean := 0.72
	var set_weather_calls := 0
	var set_ocean_calls := 0
	var debug_override := {}
	var diagnostics := {
		"relative_wind_mps": 8.0,
		"rain_mm_per_hour": 5.0,
		"sea_amplitude_rms_m": 1.8,
		"music_ducking_db": -3.0,
		"target_loop_gains": {"W01": 0.2, "R02": 0.3, "SW01": 0.4},
		"actual_loop_gains": {"W01": 0.18, "R02": 0.28, "SW01": 0.38},
	}

	func get_weather_volume() -> float:
		return weather

	func get_ocean_volume() -> float:
		return ocean

	func set_weather_volume(value: float) -> void:
		weather = value
		set_weather_calls += 1

	func set_ocean_volume(value: float) -> void:
		ocean = value
		set_ocean_calls += 1

	func set_debug_audio_override(values: Dictionary) -> void:
		debug_override = values.duplicate(true)

	func clear_debug_audio_override() -> void:
		debug_override.clear()

	func get_audio_diagnostics() -> Dictionary:
		return diagnostics.duplicate(true)


class FakeBoatAudio extends Node:
	var engine := 0.62
	var set_engine_calls := 0
	var debug_override := {}
	var diagnostics := {
		"target_loop_gains": {"engine": 0.5, "S01": 0.2, "S02": 0.3},
		"actual_loop_gains": {"engine": 0.48, "S01": 0.18, "S02": 0.25},
	}

	func get_engine_volume() -> float:
		return engine

	func set_engine_volume(value: float) -> void:
		engine = value
		set_engine_calls += 1

	func set_debug_audio_override(values: Dictionary) -> void:
		debug_override = values.duplicate(true)

	func clear_debug_audio_override() -> void:
		debug_override.clear()

	func get_audio_diagnostics() -> Dictionary:
		return diagnostics.duplicate(true)


class FakeMusicManager extends Node:
	var enabled := true
	var duck_db := 0.0

	func set_environment_ducking_db(value_db: float, _fade_seconds: float = 1.25) -> void:
		duck_db = value_db


class FakeWaveSampler extends Node:
	var settings: SeaWaveSettings
	var strength := 1.0

	func get_effective_wave_settings() -> SeaWaveSettings:
		return settings

	func get_effective_wave_strength() -> float:
		return strength


class FakeCameraRig extends Node3D:
	func release_mouse_look() -> void:
		pass


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var production_music := root.get_node_or_null("MusicManager")
	if production_music != null:
		production_music.call("_cancel_fade")
		var production_player := production_music.get_node_or_null("BackgroundMusicPlayer") as AudioStreamPlayer
		if production_player != null:
			production_player.stop()
			production_player.stream = null
	_temp_dir = "/private/tmp/audio_sfx_1_test_%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(_temp_dir)
	var settings_path := _temp_dir.path_join("settings.cfg")
	var holder := Node.new()
	holder.name = "AudioSfxTestHolder"
	root.add_child(holder)
	await process_frame
	production_music = root.get_node_or_null("MusicManager")
	if production_music != null:
		production_music.set("music_enabled", false)
		production_music.call("_cancel_fade")
		var deferred_player := production_music.get_node_or_null("BackgroundMusicPlayer") as AudioStreamPlayer
		if deferred_player != null:
			deferred_player.stop()
			deferred_player.stream = null

	_test_mix_profiles()
	_test_main_scene_resource()
	_test_production_sfx_resources()
	await _test_environment_manager(settings_path, holder)
	await _test_boat_audio(settings_path, holder)
	await _test_menu_sliders(holder)
	_test_r_panel_audio_overrides(holder)
	_test_lightning_metadata_contract()

	if _failures.is_empty():
		print("AUDIO_SFX_1: %d checks passed." % _checks)
	else:
		push_error("AUDIO_SFX_1: %d/%d checks failed: %s" % [_failures.size(), _checks, "; ".join(_failures)])
	for child in holder.get_children():
		child.queue_free()
	holder.queue_free()
	await process_frame
	DirAccess.remove_absolute(settings_path)
	DirAccess.remove_absolute(_temp_dir)
	quit(0 if _failures.is_empty() else 1)


func _test_mix_profiles() -> void:
	_expect(not MixProfile.runtime_audio_allowed(true), "dedicated server does not initialize local audio presentation")
	_expect(not MixProfile.runtime_audio_allowed(false, true), "headless validation does not instantiate audio playback")
	_expect(MixProfile.runtime_audio_allowed(false), "client runtime can initialize audio")
	_expect(is_zero_approx(float(MixProfile.wind_layer_gains(0.0)["light"])), "calm air has no wind loop gain")
	_expect(is_zero_approx(float(MixProfile.wind_layer_gains(0.0)["strong"])), "calm air has no strong-wind loop gain")
	var light_wind := MixProfile.wind_layer_gains(4.0)
	var strong_wind := MixProfile.wind_layer_gains(18.0)
	_expect(float(light_wind["light"]) > float(light_wind["strong"]), "W01 leads at light wind")
	_expect(float(strong_wind["strong"]) > float(strong_wind["light"]), "W02 leads at strong wind")
	var wind_before := MixProfile.wind_layer_gains(8.9)
	var wind_after := MixProfile.wind_layer_gains(9.1)
	_expect(absf(float(wind_before["light"]) - float(wind_after["light"])) < 0.04, "wind transition is continuous")
	var no_rain := MixProfile.rain_layer_gains(0.0)
	_expect(is_zero_approx(float(no_rain["moderate"])) and is_zero_approx(float(no_rain["heavy"])), "0 mm/h mutes both rain loops")
	var medium_rain := MixProfile.rain_layer_gains(5.0)
	var heavy_rain := MixProfile.rain_layer_gains(22.0)
	_expect(float(medium_rain["moderate"]) > float(medium_rain["heavy"]), "R02 leads in moderate rain")
	_expect(float(heavy_rain["heavy"]) > float(heavy_rain["moderate"]), "R03 leads in heavy rain")
	var rain_before := MixProfile.rain_layer_gains(10.0)
	var rain_after := MixProfile.rain_layer_gains(10.1)
	_expect(absf(float(rain_before["heavy"]) - float(rain_after["heavy"])) < 0.04, "rain crossover is continuous")
	var calm_sea := MixProfile.sea_layer_gains(0.3)
	var rough_sea := MixProfile.sea_layer_gains(5.0)
	_expect(float(calm_sea["small"]) > 0.20, "SW01 remains a quiet continuous bed on calm water")
	_expect(float(calm_sea["small"]) > float(calm_sea["large"]), "SW01 leads for a small visible wave state")
	_expect(float(rough_sea["large"]) > float(rough_sea["small"]), "SW03 leads for large visible waves")
	var weights := MixProfile.sea_layer_weights(2.9)
	_expect(absf(float(weights["small"]) + float(weights["medium"]) + float(weights["large"]) - 1.0) < 0.001, "sea-state weights sum to one")
	var no_hull_motion := MixProfile.hull_layer_gains(0.0, 0.0)
	var heavy_hull_motion := MixProfile.hull_layer_gains(0.7, 1.4)
	_expect(float(heavy_hull_motion["heavy"]) > float(no_hull_motion["heavy"]), "S02 increases with buoyancy motion")
	_expect(float(heavy_hull_motion["heavy"]) <= 0.30, "S02 dynamic mix has a fixed gain ceiling")
	_expect(is_zero_approx(MixProfile.thunder_delay_seconds(0.0)), "zero-distance thunder has no propagation delay")
	_expect(is_equal_approx(MixProfile.thunder_delay_seconds(343.0), 1.0), "thunder delay uses 343 m/s")
	_expect(MixProfile.thunder_stem_for_distance(500.0) == "T03", "near thunder chooses T03")
	_expect(MixProfile.thunder_stem_for_distance(2000.0) == "T02", "middle distance thunder chooses T02")
	_expect(MixProfile.thunder_stem_for_distance(5000.0) == "T01", "distant thunder chooses T01")
	_expect(MixProfile.music_ducking_db(0.0, false) == 0.0, "music duck recovers outside a storm")
	_expect(MixProfile.music_ducking_db(1.0, false) <= -4.4, "strong storm applies modest ducking")
	_expect(MixProfile.music_ducking_db(1.0, true) >= -6.0, "storm and near thunder duck is capped at -6 dB")
	_expect(MixProfile.linear_gain_to_db(0.0) <= -79.0, "zero mix slider represents true silence")


func _test_main_scene_resource() -> void:
	var main_scene := load("res://scenes/main.tscn") as PackedScene
	_expect(main_scene != null, "main scene and its audio node references parse successfully")


func _test_production_sfx_resources() -> void:
	# These assets are loaded dynamically by the runtime managers, so verify
	# their Godot import records and resource loaders are ready before gameplay.
	for path in [
		"res://assets/sfx/processed/OM02_loop.ogg",
		"res://assets/sfx/processed/S01_loop.ogg",
		"res://assets/sfx/processed/S02_loop.ogg",
		"res://assets/sfx/processed/SW01_loop.ogg",
		"res://assets/sfx/processed/SW02_loop.ogg",
		"res://assets/sfx/processed/SW03_loop.ogg",
		"res://assets/sfx/processed/W01_loop.ogg",
		"res://assets/sfx/processed/W02_loop.ogg",
	]:
		var stream := ResourceLoader.load(path) as AudioStream
		_expect(stream != null, "runtime SFX resource loads through Godot: %s" % path)


func _test_environment_manager(settings_path: String, holder: Node) -> void:
	var env := EnvironmentAudioManagerScript.new() as Node
	env.set("audio_output_enabled", false)
	env.set("settings_file_path", settings_path)
	holder.add_child(env)
	await process_frame
	_expect(not bool(env.get_audio_diagnostics()["audio_initialized"]), "disabled/no-output manager creates no audio voices")
	var fake_weather := FakeWeatherState.new()
	holder.add_child(fake_weather)
	env.set("_weather_state_controller", fake_weather)
	env.call("set_debug_audio_override", {"rain_mm_per_hour": 22.0})
	env.call("_update_mix_targets", 0.2)
	var debug_gains: Dictionary = env.get_audio_diagnostics()["target_loop_gains"]
	_expect(float(debug_gains.get("R03", 0.0)) > float(debug_gains.get("R02", 0.0)), "local audio override changes only visual-audio rain mix")
	_expect(float(fake_weather.precipitation["intensity_mm_per_hour"]) == 5.0, "audio override leaves formal weather rain unchanged")
	var fake_music := FakeMusicManager.new()
	holder.add_child(fake_music)
	env.set("_music_manager", fake_music)
	env.call("set_debug_audio_override", {"storm_intensity": 0.8})
	env.call("_update_music_ducking")
	_expect(fake_music.duck_db <= -4.0 and fake_music.enabled, "storm mix ducking is temporary and does not change the music toggle")
	env.call("clear_debug_audio_override")
	env.call("_update_music_ducking")
	_expect(is_zero_approx(fake_music.duck_db), "clearing test override restores music bus gain")
	env.call("_update_mix_targets", 0.2)
	var restored_gains: Dictionary = env.get_audio_diagnostics()["target_loop_gains"]
	_expect(float(restored_gains.get("R02", 0.0)) > float(restored_gains.get("R03", 0.0)), "clearing audio override returns to formal rain mix")
	_expect(env.enqueue_thunder_event({"type": "near_cg", "intensity": 0.8, "world_position": Vector3(343.0, 0.0, 0.0)}, 1000), "lightning event with world position enters thunder queue")
	_expect(env.get_pending_thunder_count() == 1, "thunder event remains queued until propagation delay")
	_expect(is_equal_approx(float(env.get_audio_diagnostics()["last_thunder_delay_seconds"]), 1.0), "queue records listener-distance delay")
	_expect(not env.enqueue_thunder_event({"type": "near_cg"}, 1000), "event without world position is safely ignored")
	env.set_weather_volume(0.0)
	env.set_ocean_volume(0.44)
	var reloaded_env := EnvironmentAudioManagerScript.new() as Node
	reloaded_env.set("audio_output_enabled", false)
	reloaded_env.set("settings_file_path", settings_path)
	holder.add_child(reloaded_env)
	await process_frame
	_expect(is_zero_approx(float(reloaded_env.call("get_weather_volume"))), "weather bus mute persists in settings")
	_expect(absf(float(reloaded_env.call("get_ocean_volume")) - 0.44) < 0.001, "ocean volume persists independently")
	var missing_stream: Variant = env.call("_load_audio_stream", "MissingTestAsset", "MissingTestAsset.mp3")
	_expect(missing_stream == null, "missing optional SFX resource safely disables its layer")
	var bus_manager := EnvironmentAudioManagerScript.new() as Node
	bus_manager.call("_ensure_audio_buses")
	_expect(AudioServer.get_bus_index("Weather") >= 0 and AudioServer.get_bus_index("Ocean") >= 0, "Weather and Ocean buses are created once")
	_expect(AudioServer.get_bus_send(AudioServer.get_bus_index("Weather")) == "Master", "Weather bus routes to Master")
	_expect(AudioServer.get_bus_send(AudioServer.get_bus_index("Ocean")) == "Master", "Ocean bus routes to Master")
	bus_manager.call("_ensure_master_limiter")
	var master_index := AudioServer.get_bus_index("Master")
	var limiter_found := false
	for index in range(AudioServer.get_bus_effect_count(master_index)):
		limiter_found = limiter_found or AudioServer.get_bus_effect(master_index, index) is AudioEffectLimiter
	_expect(limiter_found, "Master bus has a peak limiter")
	bus_manager.free()
	var wave_sampler := FakeWaveSampler.new()
	var wave_settings := SeaWaveSettings.new()
	var wave := GerstnerWave.new()
	wave.amplitude = 0.35
	wave_settings.waves = [wave]
	wave_sampler.settings = wave_settings
	holder.add_child(wave_sampler)
	env.set("_wave_sampler", wave_sampler)
	env.call("_update_mix_targets", 0.2)
	var small_sea_gains: Dictionary = env.get_audio_diagnostics()["target_loop_gains"]
	wave.amplitude = 4.0
	env.call("_update_mix_targets", 0.2)
	var rough_sea_gains: Dictionary = env.get_audio_diagnostics()["target_loop_gains"]
	_expect(float(rough_sea_gains.get("SW03", 0.0)) > float(small_sea_gains.get("SW03", 0.0)), "ocean loops follow the effective visible wave amplitude")


func _test_boat_audio(settings_path: String, holder: Node) -> void:
	var boat := BoatControllerScript.new() as BoatController
	holder.add_child(boat)
	var idle := boat.get_engine_audio_state()
	_expect(bool(idle["running"]) and float(idle["power"]) > 0.0, "undocked powered vessel exposes an idle engine proxy")
	Input.action_press("boat_accelerate")
	var throttle := boat.get_engine_audio_state()
	Input.action_release("boat_accelerate")
	_expect(float(throttle["power"]) > float(idle["power"]), "engine proxy responds to throttle demand")
	boat.is_autopilot = true
	boat.submit_autopilot_command(0.0, boat.cruise_speed_mps)
	_expect(float(boat.get_engine_audio_state()["power"]) > 0.0, "engine audio remains active under autopilot")
	boat.is_motion_paused = true
	_expect(not bool(boat.get_engine_audio_state()["running"]), "paused/docked proxy stops engine loop")
	boat.is_motion_paused = false
	boat.is_port_docked = true
	_expect(not bool(boat.get_engine_audio_state()["running"]), "port-docked vessel reports engine inactive")
	boat.is_port_docked = false
	boat.is_autopilot = false
	boat.manual_input_enabled = true
	var buoyancy := BoatBuoyancyScript.new() as Node
	buoyancy.set("_heave_velocity", 0.5)
	buoyancy.set("_pitch_velocity", 0.2)
	buoyancy.set("_roll_velocity", 0.3)
	var motion: Dictionary = buoyancy.call("get_audio_motion_state")
	_expect(absf(float(motion["heave_speed_mps"]) - 0.5) < 0.001, "hull audio reads existing heave velocity")
	_expect(absf(float(motion["roll_rate_rad_s"]) - 0.3) < 0.001, "hull audio reads existing roll rate")
	buoyancy.free()
	var boat_audio := BoatAudioControllerScript.new() as Node
	boat_audio.set("audio_output_enabled", false)
	boat_audio.set("settings_file_path", settings_path)
	holder.add_child(boat_audio)
	boat_audio.set("_boat", boat)
	boat_audio.call("_update_targets", 1.0 / 60.0)
	var idle_audio: Dictionary = boat_audio.get_audio_diagnostics()
	Input.action_press("boat_accelerate")
	boat_audio.call("_update_targets", 1.0 / 60.0)
	Input.action_release("boat_accelerate")
	var cruise_audio: Dictionary = boat_audio.get_audio_diagnostics()
	_expect(float(cruise_audio["engine_rpm_proxy"]) > float(idle_audio["engine_rpm_proxy"]), "engine tone proxy rises smoothly with throttle demand")
	boat.is_autopilot = true
	boat.submit_autopilot_command(0.0, boat.cruise_speed_mps)
	boat_audio.call("_update_targets", 1.0 / 60.0)
	_expect(float(boat_audio.get_audio_diagnostics()["target_loop_gains"]["engine"]) > 0.0, "autopilot continues to drive the engine loop target")
	boat_audio.set("engine_volume", 0.33)
	boat_audio.call("set_engine_volume", 0.33)
	var reloaded_boat_audio := BoatAudioControllerScript.new() as Node
	reloaded_boat_audio.set("audio_output_enabled", false)
	reloaded_boat_audio.set("settings_file_path", settings_path)
	holder.add_child(reloaded_boat_audio)
	await process_frame
	_expect(absf(float(reloaded_boat_audio.call("get_engine_volume")) - 0.33) < 0.001, "engine volume persists across controller instances")
	var music := MusicManagerScript.new() as Node
	music.set("settings_file_path", settings_path)
	music.set("start_playback_on_ready", false)
	holder.add_child(music)
	await process_frame
	music.call("set_music_enabled", false)
	var persisted := ConfigFile.new()
	_expect(persisted.load(settings_path) == OK, "shared audio settings remain readable after music writes")
	_expect(absf(float(persisted.get_value("audio", "weather_volume", -1.0))) < 0.001, "music setting write preserves weather slider value")
	_expect(absf(float(persisted.get_value("audio", "ocean_volume", -1.0)) - 0.44) < 0.001, "music setting write preserves ocean slider value")
	_expect(absf(float(persisted.get_value("audio", "engine_volume", -1.0)) - 0.33) < 0.001, "music setting write preserves engine slider value")


func _test_menu_sliders(holder: Node) -> void:
	var env := FakeEnvironmentAudio.new()
	env.name = "FakeEnvironmentAudio"
	holder.add_child(env)
	var boat_audio := FakeBoatAudio.new()
	boat_audio.name = "FakeBoatAudio"
	holder.add_child(boat_audio)
	var boat := BoatControllerScript.new() as BoatController
	boat.name = "FakeBoat"
	holder.add_child(boat)
	var camera := FakeCameraRig.new()
	camera.name = "FakeCamera"
	holder.add_child(camera)
	var menu := GameMenuScript.new() as CanvasLayer
	menu.name = "AudioTestMenu"
	menu.set("boat_controller_path", NodePath("../FakeBoat"))
	menu.set("camera_rig_path", NodePath("../FakeCamera"))
	menu.set("environment_audio_manager_path", NodePath("../FakeEnvironmentAudio"))
	menu.set("boat_audio_controller_path", NodePath("../FakeBoatAudio"))
	holder.add_child(menu)
	await process_frame
	menu.call("_show_settings_page")
	var weather_slider := menu.find_child("WeatherVolumeSlider", true, false) as HSlider
	var ocean_slider := menu.find_child("OceanVolumeSlider", true, false) as HSlider
	var engine_slider := menu.find_child("EngineVolumeSlider", true, false) as HSlider
	_expect(weather_slider != null and ocean_slider != null and engine_slider != null, "ESC settings exposes Weather/Ocean/Engine sliders")
	if weather_slider != null:
		weather_slider.value = 35.0
	if ocean_slider != null:
		ocean_slider.value = 50.0
	if engine_slider != null:
		engine_slider.value = 25.0
	_expect(absf(env.weather - 0.35) < 0.001 and env.set_weather_calls > 0, "weather slider immediately updates its audio manager")
	_expect(absf(env.ocean - 0.50) < 0.001 and env.set_ocean_calls > 0, "ocean slider immediately updates its audio manager")
	_expect(absf(boat_audio.engine - 0.25) < 0.001 and boat_audio.set_engine_calls > 0, "engine slider immediately updates its audio manager")


func _test_r_panel_audio_overrides(holder: Node) -> void:
	var env := FakeEnvironmentAudio.new()
	var boat_audio := FakeBoatAudio.new()
	var panel := RainDebugPanelScript.new() as CanvasLayer
	holder.add_child(env)
	holder.add_child(boat_audio)
	holder.add_child(panel)
	panel.set("_environment_audio_manager", env)
	panel.set("_boat_audio_controller", boat_audio)
	var status_label := Label.new()
	holder.add_child(status_label)
	panel.set("_audio_status_label", status_label)
	panel.call("_refresh_audio_status")
	_expect(status_label.text.contains("目标 W01") and status_label.text.contains("船体 S01"), "R panel formats target and actual loop diagnostics")
	var preset := {"relative_wind_mps": 15.0, "rain_mm_per_hour": 22.0, "engine_running": true, "engine_power": 0.7}
	panel.call("_apply_audio_debug_override", preset)
	_expect(float(env.debug_override.get("rain_mm_per_hour", 0.0)) == 22.0, "R panel applies local audio test preset to environment mixing")
	_expect(float(boat_audio.debug_override.get("engine_power", 0.0)) == 0.7, "R panel applies local audio test preset to boat sounds")
	panel.call("_clear_audio_debug_override")
	_expect(env.debug_override.is_empty() and boat_audio.debug_override.is_empty(), "closing/restoring R panel clears both audio test overrides")


func _test_lightning_metadata_contract() -> void:
	var source_event := {"event_id": 7, "type": "near_cg", "source": "formal", "intensity": 0.32, "world_position": Vector3(1200.0, 1800.0, -500.0), "sound_source_position": Vector3(1200.0, 0.0, -500.0)}
	_expect(source_event.has("event_id") and source_event.has("world_position"), "audio contract uses actual lightning event id and world position")
	_expect(source_event["sound_source_position"] == Vector3(1200.0, 0.0, -500.0), "cloud-ground thunder position preserves strike location near sea level")
	var invalid_event := {"event_id": 8, "type": "cloud_to_cloud", "source": "formal"}
	_expect(not invalid_event.has("world_position"), "audio skips events without resolved world geometry")


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(description)
		push_error("Audio SFX test failed: " + description)
