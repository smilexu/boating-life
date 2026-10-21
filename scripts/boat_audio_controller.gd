extends Node
class_name BoatAudioController

## Local audio presentation for the currently selected powered vessel.
## Engine demand and buoyancy motion are consumed through read-only adapters.

const MixProfile := preload("res://scripts/audio_mix_profile.gd")
const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "audio"
const ENGINE_BUS := "Engine"
const EngineAudioProfileScript = preload("res://scripts/engine_audio_profile.gd")
const POWERBOAT_FALLBACK_PROFILE: EngineAudioProfileScript = preload("res://resources/audio/powerboat_default_engine.tres")
const HULL_DEFINITIONS := {
	"S01": "S01.mp3",
	"S02": "S02.mp3",
}
const HULL_PLAYBACK_TRIMS_DB := {"S01": 5.0, "S02": 1.0}
const RESPONSE_SECONDS := 1.0
@export_node_path("Node3D") var boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node") var buoyancy_path := NodePath("../PlayerBoat/MotionRoot/VisualRoot")
@export var settings_file_path := SETTINGS_PATH
@export_range(0.0, 1.0, 0.01) var default_engine_volume := 0.62
@export var audio_output_enabled := true

var engine_volume := 0.62

var _boat: Node3D
var _buoyancy: Node
var _engine_player: AudioStreamPlayer3D
var _hull_players: Dictionary = {}
var _target_gains: Dictionary = {"engine": 0.0, "S01": 0.0, "S02": 0.0}
var _actual_gains: Dictionary = {"engine": 0.0, "S01": 0.0, "S02": 0.0}
var _engine_pitch := 1.0
var _active_engine_profile: EngineAudioProfileScript
var _pending_engine_profile: EngineAudioProfileScript
var _engine_profile_switch_pending := false
var _audio_initialized := false
var _debug_audio_override: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_boat = get_node_or_null(boat_path) as Node3D
	_buoyancy = get_node_or_null(buoyancy_path)
	engine_volume = _read_engine_volume()
	if not audio_output_enabled or not MixProfile.runtime_audio_allowed(
		OS.has_feature("dedicated_server"), DisplayServer.get_name().to_lower() == "headless"
	):
		set_process(false)
		return
	_ensure_engine_bus()
	_apply_engine_bus_volume()
	_create_audio_players()
	_audio_initialized = true


func _process(delta: float) -> void:
	if not _audio_initialized:
		return
	_update_targets(delta)
	_update_envelopes(delta)
	if not is_instance_valid(_boat):
		return
	for player: AudioStreamPlayer3D in [_engine_player, _hull_players.get("S01"), _hull_players.get("S02")]:
		if player != null:
			player.global_position = _boat.global_position


func get_engine_volume() -> float:
	return engine_volume


func set_engine_volume(value: float) -> void:
	engine_volume = clampf(value, 0.0, 1.0) if is_finite(value) else default_engine_volume
	_apply_engine_bus_volume()
	_save_engine_volume()


## Call this after changing the active vessel. Engine profiles switch only after
## the previous loop has faded out, so a new boat never inherits the old sound.
func bind_vessel(boat: Node3D, buoyancy: Node = null) -> void:
	var next_profile := _resolve_engine_profile(boat)
	if next_profile == _active_engine_profile and not _engine_profile_switch_pending:
		_boat = boat
		_buoyancy = buoyancy if buoyancy != null else _find_buoyancy_node(boat)
		return
	_boat = boat
	_buoyancy = buoyancy if buoyancy != null else _find_buoyancy_node(boat)
	_pending_engine_profile = next_profile
	_engine_profile_switch_pending = true
	_target_gains["engine"] = 0.0
	if _audio_initialized and _engine_player == null:
		_finish_engine_profile_switch()


## Local testing values are consumed only by this presentation component.
func set_debug_audio_override(values: Dictionary) -> void:
	_debug_audio_override = values.duplicate(true)


func clear_debug_audio_override() -> void:
	_debug_audio_override.clear()


func get_audio_diagnostics() -> Dictionary:
	var engine_state := _read_engine_state()
	var motion_state := _read_hull_motion_state()
	return {
		"audio_initialized": _audio_initialized,
		"engine_running": bool(engine_state.get("running", false)),
		"engine_power_proxy": float(engine_state.get("power", 0.0)),
		"engine_rpm_proxy": _engine_pitch,
		"engine_profile_id": str(_active_engine_profile.profile_id) if _active_engine_profile != null else "none",
		"engine_profile_stream": _active_engine_profile.engine_stream.resource_path if _active_engine_profile != null and _active_engine_profile.engine_stream != null else "",
		"engine_profile_is_powerboat_fallback": _active_engine_profile == POWERBOAT_FALLBACK_PROFILE,
		"engine_playback_trim_db": _active_engine_profile.playback_trim_db if _active_engine_profile != null else 0.0,
		"hull_playback_trims_db": HULL_PLAYBACK_TRIMS_DB.duplicate(true),
		"hull_motion": motion_state,
		"target_loop_gains": _target_gains.duplicate(true),
		"actual_loop_gains": _actual_gains.duplicate(true),
		"audio_test_override_active": not _debug_audio_override.is_empty(),
	}


func _ensure_engine_bus() -> void:
	var index := AudioServer.get_bus_index(ENGINE_BUS)
	if index < 0:
		AudioServer.add_bus()
		index = AudioServer.get_bus_count() - 1
		AudioServer.set_bus_name(index, ENGINE_BUS)
	AudioServer.set_bus_send(index, "Master")


func _create_audio_players() -> void:
	_active_engine_profile = _resolve_engine_profile(_boat)
	if _active_engine_profile != null:
		if _active_engine_profile.engine_stream != null:
			_engine_player = _make_loop_player("EngineLoop", ENGINE_BUS, _active_engine_profile.engine_stream)
			if _engine_player == null:
				_active_engine_profile = null
		else:
			push_warning("BoatAudioController engine profile '%s' has no audio stream; engine audio is disabled." % _active_engine_profile.profile_id)
			_active_engine_profile = null
	for stem in HULL_DEFINITIONS.keys():
		var stream := _load_audio_stream(stem, str(HULL_DEFINITIONS[stem]), true)
		if stream == null:
			push_warning("BoatAudioController could not load %s; that hull layer is disabled. Check that Godot has finished importing the asset." % stem)
			continue
		_hull_players[stem] = _make_loop_player(stem + "HullLoop", "Ocean", stream)


func _make_loop_player(node_name: String, bus_name: String, source: AudioStream) -> AudioStreamPlayer3D:
	var loop_stream := _make_loop_stream(source)
	if loop_stream == null:
		return null
	var player := AudioStreamPlayer3D.new()
	player.name = node_name
	player.bus = bus_name
	player.stream = loop_stream
	player.max_distance = 150.0
	player.unit_size = 8.0
	player.volume_db = MixProfile.SILENT_DB
	add_child(player)
	player.play()
	return player


func _make_loop_stream(source: AudioStream) -> AudioStream:
	if source == null:
		return null
	var loop_stream := source.duplicate(true) as AudioStream
	if loop_stream is AudioStreamOggVorbis:
		(loop_stream as AudioStreamOggVorbis).loop = true
	elif loop_stream is AudioStreamMP3:
		(loop_stream as AudioStreamMP3).loop = true
	else:
		push_warning("BoatAudioController cannot loop unsupported engine stream type: %s" % source.get_class())
		return null
	return loop_stream


func _update_targets(delta: float) -> void:
	var engine := _read_engine_state()
	var running := bool(engine.get("running", false))
	var power := clampf(float(engine.get("power", 0.0)), 0.0, 1.0)
	if _engine_profile_switch_pending or _active_engine_profile == null or _active_engine_profile.engine_stream == null:
		_target_gains["engine"] = 0.0
		_engine_pitch = 1.0
	else:
		_target_gains["engine"] = _active_engine_profile.gain_for_power(power) if running else 0.0
		_engine_pitch = _active_engine_profile.pitch_for_power(power) if running else _active_engine_profile.minimum_pitch_scale
	if _engine_player != null:
		var pitch_weight := 1.0 - exp(-maxf(delta, 0.0) / 0.6)
		_engine_player.pitch_scale = lerpf(_engine_player.pitch_scale, _engine_pitch, pitch_weight)

	var motion := _read_hull_motion_state()
	var hull := MixProfile.hull_layer_gains(
		float(motion.get("heave_speed_mps", 0.0)),
		maxf(float(motion.get("pitch_rate_rad_s", 0.0)), float(motion.get("roll_rate_rad_s", 0.0)))
	)
	var active := not bool(engine.get("docked", false))
	_target_gains["S01"] = float(hull["light"]) if active else 0.0
	_target_gains["S02"] = float(hull["heavy"]) if active else 0.0


func _read_engine_state() -> Dictionary:
	var state := {"running": false, "power": 0.0, "docked": false}
	if is_instance_valid(_boat) and _boat.has_method("get_engine_audio_state"):
		state = _boat.call("get_engine_audio_state")
	if _debug_audio_override.has("engine_running"):
		state["running"] = bool(_debug_audio_override["engine_running"])
	if _debug_audio_override.has("engine_power"):
		state["power"] = clampf(float(_debug_audio_override["engine_power"]), 0.0, 1.0)
	return state


func _read_hull_motion_state() -> Dictionary:
	if not _debug_audio_override.is_empty():
		return {
			"heave_speed_mps": maxf(float(_debug_audio_override.get("heave_speed_mps", 0.0)), 0.0),
			"pitch_rate_rad_s": maxf(float(_debug_audio_override.get("pitch_rate_rad_s", 0.0)), 0.0),
			"roll_rate_rad_s": maxf(float(_debug_audio_override.get("roll_rate_rad_s", 0.0)), 0.0),
			"available": true,
		}
	if _buoyancy != null and _buoyancy.has_method("get_audio_motion_state"):
		return _buoyancy.call("get_audio_motion_state")
	return {"heave_speed_mps": 0.0, "pitch_rate_rad_s": 0.0, "roll_rate_rad_s": 0.0}


func _update_envelopes(delta: float) -> void:
	var weight := 1.0 - exp(-maxf(delta, 0.0) / RESPONSE_SECONDS)
	for key in _actual_gains.keys():
		var target := clampf(float(_target_gains.get(key, 0.0)), 0.0, 1.0)
		var actual := lerpf(float(_actual_gains[key]), target, weight)
		_actual_gains[key] = actual
		var player: AudioStreamPlayer3D = _engine_player if key == "engine" else _hull_players.get(key)
		if player == null:
			continue
		var playback_gain_db := MixProfile.linear_gain_to_db(actual)
		if key == "engine" and actual > 0.001 and _active_engine_profile != null:
			playback_gain_db += _active_engine_profile.playback_trim_db
		elif key in HULL_PLAYBACK_TRIMS_DB and actual > 0.001:
			playback_gain_db += float(HULL_PLAYBACK_TRIMS_DB[key])
		player.volume_db = playback_gain_db
		if target <= 0.0005 and actual <= 0.001 and player.playing:
			player.stop()
		elif target > 0.0005 and not player.playing:
			player.play()
	_finish_engine_profile_switch()


func _resolve_engine_profile(boat: Node3D) -> EngineAudioProfileScript:
	if not is_instance_valid(boat) or not boat.has_method("has_engine") or not bool(boat.call("has_engine")):
		return null
	if boat.has_method("get_engine_audio_profile"):
		var configured_profile: Variant = boat.call("get_engine_audio_profile")
		if configured_profile is EngineAudioProfileScript:
			return configured_profile as EngineAudioProfileScript
	return POWERBOAT_FALLBACK_PROFILE


func _finish_engine_profile_switch() -> void:
	if not _engine_profile_switch_pending or float(_actual_gains.get("engine", 0.0)) > 0.001:
		return
	if _engine_player != null and _engine_player.playing:
		_engine_player.stop()
	_active_engine_profile = _pending_engine_profile
	_pending_engine_profile = null
	_engine_profile_switch_pending = false
	_target_gains["engine"] = 0.0
	_actual_gains["engine"] = 0.0
	if _active_engine_profile == null:
		if _engine_player != null:
			_engine_player.stream = null
		return
	if _active_engine_profile.engine_stream == null:
		push_warning("BoatAudioController engine profile '%s' has no audio stream; engine audio is disabled." % _active_engine_profile.profile_id)
		_active_engine_profile = null
		if _engine_player != null:
			_engine_player.stream = null
		return
	var next_stream := _make_loop_stream(_active_engine_profile.engine_stream)
	if next_stream == null:
		_active_engine_profile = null
		if _engine_player != null:
			_engine_player.stream = null
		return
	if _engine_player == null:
		_engine_player = _make_loop_player("EngineLoop", ENGINE_BUS, _active_engine_profile.engine_stream)
		if _engine_player == null:
			_active_engine_profile = null
	else:
		_engine_player.stream = next_stream
		_engine_player.pitch_scale = _active_engine_profile.minimum_pitch_scale


func _find_buoyancy_node(boat: Node3D) -> Node:
	if not is_instance_valid(boat):
		return null
	return boat.get_node_or_null("VisualRoot")


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


func _read_engine_volume() -> float:
	if not FileAccess.file_exists(settings_file_path):
		return default_engine_volume
	var config := ConfigFile.new()
	if config.load(settings_file_path) != OK:
		return default_engine_volume
	var value: Variant = config.get_value(SETTINGS_SECTION, "engine_volume", default_engine_volume)
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(value)):
		return default_engine_volume
	return clampf(float(value), 0.0, 1.0)


func _save_engine_volume() -> void:
	var config := ConfigFile.new()
	if FileAccess.file_exists(settings_file_path) and config.load(settings_file_path) != OK:
		push_warning("BoatAudioController could not read %s; preserving defaults before saving." % settings_file_path)
		config = ConfigFile.new()
	config.set_value(SETTINGS_SECTION, "engine_volume", engine_volume)
	var error := config.save(settings_file_path)
	if error != OK:
		push_warning("BoatAudioController could not save engine volume (error %d)." % error)


func _apply_engine_bus_volume() -> void:
	var index := AudioServer.get_bus_index(ENGINE_BUS)
	if index < 0:
		return
	AudioServer.set_bus_mute(index, engine_volume <= 0.0001)
	if engine_volume > 0.0001:
		AudioServer.set_bus_volume_db(index, MixProfile.linear_gain_to_db(engine_volume))
