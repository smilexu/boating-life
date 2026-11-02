extends SceneTree

const FishingRodSystemScript := preload("res://scripts/fishing_rod_system.gd")
const SOUND_FILES := {
	"fishing_catch_success": 4.0,
	"fishing_drag": 6.037208,
	"fishing_line_out": 6.037208,
	"fishing_reel_in": 5.0,
	"fishing_splash": 6.037208,
}

# PCM source encoding is verified with ffprobe; Godot's WAV importer may store
# the runtime AudioStreamWAV sample in the project's configured compressed form.

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for stem in SOUND_FILES:
		var stream := load("res://assets/sfx/%s.wav" % stem) as AudioStreamWAV
		_check(stream != null, "%s imports as WAV" % stem)
		if stream == null:
			continue
		_check(stream.mix_rate == 48000, "%s uses 48 kHz" % stem)
		_check(stream.stereo, "%s preserves stereo channels" % stem)
		_check(absf(stream.get_length() - float(SOUND_FILES[stem])) < 0.002, "%s has the requested decoded duration" % stem)

	var audio_logic := FishingRodSystemScript.new() as FishingRodSystem
	var line_out := FishingRodSystem.get_trolling_audio_loop_targets(FishingRodSystem.VisualState.CASTING, 0.0)
	_check(bool(line_out["line_out"]) and not bool(line_out["drag"]) and not bool(line_out["reel_in"]), "deployment plays only line-out loop")
	var normal_trolling := FishingRodSystem.get_trolling_audio_loop_targets(FishingRodSystem.VisualState.TROLLING, 0.0)
	_check(not bool(normal_trolling["line_out"]) and not bool(normal_trolling["drag"]) and not bool(normal_trolling["reel_in"]), "normal trolling wait is silent")
	var debug_bite_no_spool_motion := FishingRodSystem.get_trolling_audio_loop_targets(FishingRodSystem.VisualState.SIMULATING, 0.0)
	_check(not bool(debug_bite_no_spool_motion["drag"]) and not bool(debug_bite_no_spool_motion["reel_in"]), "simulated bite remains silent until the spool actually turns")
	var fish_pulling := FishingRodSystem.get_trolling_audio_loop_targets(FishingRodSystem.VisualState.HOOKED, -5.0)
	_check(bool(fish_pulling["drag"]) and not bool(fish_pulling["reel_in"]), "reverse reel rotation selects the drag loop")
	var debug_fish_pulling := FishingRodSystem.get_trolling_audio_loop_targets(FishingRodSystem.VisualState.SIMULATING, -5.0)
	_check(bool(debug_fish_pulling["drag"]), "simulated reverse reel rotation plays the same drag loop")
	var auto_reeling := FishingRodSystem.get_trolling_audio_loop_targets(FishingRodSystem.VisualState.REELING, 5.5)
	_check(bool(auto_reeling["reel_in"]) and not bool(auto_reeling["drag"]), "automatic retrieval plays only reel-in loop")
	var alternating_pull := FishingRodSystem.get_trolling_audio_loop_targets(FishingRodSystem.VisualState.REELING, -5.0)
	_check(bool(alternating_pull["drag"]) and not bool(alternating_pull["reel_in"]), "line-pull burst stops reel-in loop and selects ratchet")
	var stopped_spool := FishingRodSystem.get_trolling_audio_loop_targets(FishingRodSystem.VisualState.REELING, 0.0)
	_check(not bool(stopped_spool["drag"]) and not bool(stopped_spool["reel_in"]), "neither mechanical loop plays while the spool is stopped")
	var ended := FishingRodSystem.get_trolling_audio_loop_targets(FishingRodSystem.VisualState.PRESENTATION, 0.0)
	_check(not bool(ended["line_out"]) and not bool(ended["drag"]) and not bool(ended["reel_in"]), "catch presentation stops all mechanical loops")
	_check(float(FishingRodSystem.TROLLING_AMBIENCE_DUCK_DB["Ocean"]) >= 6.0 and float(FishingRodSystem.TROLLING_AMBIENCE_DUCK_DB["Engine"]) >= 6.0, "active fishing sounds duck ocean and engine ambience")

	_check(FishingRodSystem.should_play_trolling_splash(FishingRodSystem.PresentationSource.REAL_CATCH, FishingRodSystem.PresentationPhase.SURFACE_LANDING, "LIFTING", "SURFACE", false), "splash triggers on the real fish leaving the surface")
	_check(FishingRodSystem.should_play_trolling_splash(FishingRodSystem.PresentationSource.DEBUG_SIMULATION, FishingRodSystem.PresentationPhase.SURFACE_LANDING, "LIFTING", "SURFACE", false), "debug preview plays the visual surface splash once")
	_check(not FishingRodSystem.should_play_trolling_splash(FishingRodSystem.PresentationSource.REAL_CATCH, FishingRodSystem.PresentationPhase.SURFACE_LANDING, "LIFTING", "LIFTING", false), "splash does not repeat during the lifting stage")
	_check(not FishingRodSystem.should_play_trolling_splash(FishingRodSystem.PresentationSource.REAL_CATCH, FishingRodSystem.PresentationPhase.SURFACE_LANDING, "LIFTING", "SURFACE", true), "splash plays at most once per catch")
	_check(FishingRodSystem.should_play_trolling_catch_presentation_audio(FishingRodSystem.PresentationSource.REAL_CATCH, false), "real catch plays its cue when catch presentation begins")
	_check(FishingRodSystem.should_play_trolling_catch_presentation_audio(FishingRodSystem.PresentationSource.DEBUG_SIMULATION, false), "debug simulation also plays the catch presentation cue")
	_check(not FishingRodSystem.should_play_trolling_catch_presentation_audio(FishingRodSystem.PresentationSource.NONE, false), "inactive presentation does not play a catch cue")
	_check(not FishingRodSystem.should_play_trolling_catch_presentation_audio(FishingRodSystem.PresentationSource.DEBUG_SIMULATION, true), "catch presentation cue plays only once per presentation")

	for stem in ["fishing_line_out", "fishing_drag", "fishing_reel_in"]:
		var source := load("res://assets/sfx/%s.wav" % stem) as AudioStreamWAV
		if source == null:
			continue
		var looped := audio_logic._make_trolling_loop_stream(source) as AudioStreamWAV
		var expected_sample_count := roundi(source.get_length() * float(source.mix_rate))
		_check(looped != null and looped.loop_mode == AudioStreamWAV.LOOP_FORWARD and looped.loop_begin == 0 and looped.loop_end == expected_sample_count, "%s loops across its complete sample range" % stem)
	audio_logic._ensure_fishing_sfx_bus()
	_check(AudioServer.get_bus_index("SFX") >= 0, "fishing effects have a dedicated SFX bus")
	var original_bus_mix := {}
	for bus_name in ["Ocean", "Engine", "Weather"]:
		var bus_index := _ensure_test_bus(str(bus_name))
		original_bus_mix[str(bus_name)] = {"volume_db": AudioServer.get_bus_volume_db(bus_index), "muted": AudioServer.is_bus_mute(bus_index)}
		AudioServer.set_bus_mute(bus_index, false)
		AudioServer.set_bus_volume_db(bus_index, -3.0)
	audio_logic._update_trolling_ambience_ducking(true, 1.0)
	var ambience_lowered := true
	for bus_name in original_bus_mix.keys():
		var bus_index := AudioServer.get_bus_index(str(bus_name))
		ambience_lowered = ambience_lowered and AudioServer.get_bus_volume_db(bus_index) <= -3.0 - float(FishingRodSystem.TROLLING_AMBIENCE_DUCK_DB[bus_name]) + 0.1
	_check(ambience_lowered, "active fishing effects attenuate wave, engine, and weather buses")
	audio_logic._update_trolling_ambience_ducking(false, 1.0)
	var ambience_restored := true
	for bus_name in original_bus_mix.keys():
		var bus_index := AudioServer.get_bus_index(str(bus_name))
		ambience_restored = ambience_restored and is_equal_approx(AudioServer.get_bus_volume_db(bus_index), -3.0)
		var saved: Dictionary = original_bus_mix[bus_name]
		AudioServer.set_bus_volume_db(bus_index, float(saved["volume_db"]))
		AudioServer.set_bus_mute(bus_index, bool(saved["muted"]))
	_check(ambience_restored, "ambience mix returns to its previous level after fishing effects stop")
	audio_logic.free()
	print("[TROLLING_AUDIO] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _check(condition: bool, label: String) -> void:
	if condition:
		print("[TROLLING_AUDIO][PASS] %s" % label)
	else:
		_failures += 1
		push_error("[TROLLING_AUDIO][FAIL] %s" % label)


func _ensure_test_bus(bus_name: String) -> int:
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		AudioServer.add_bus()
		bus_index = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(bus_index, bus_name)
		AudioServer.set_bus_send(bus_index, "Master")
	return bus_index
