class_name FishingRodSystem
extends Node

## Visual presentation bridge between the authoritative P2 encounter and the
## hull-mounted P3 rod. It never applies forces to either vessel.

signal visual_state_changed(state_name: String)
signal catch_display_updated(snapshot: Dictionary)

enum VisualState { IDLE, CASTING, TROLLING, HOOKED, REELING, PRESENTATION, SIMULATING }
enum PresentationPhase { NONE, HOOK_STRIKE, FISH_STRUGGLE, PROGRESSIVE_RETRIEVAL, SURFACE_LANDING, CATCH_PRESENTATION }
enum PresentationSource { NONE, REAL_CATCH, DEBUG_SIMULATION }

const VISUAL_STATE_NAMES := ["IDLE", "CASTING", "TROLLING", "HOOKED", "REELING", "PRESENTATION", "SIMULATING"]
const PHASE_NAMES := ["NONE", "HOOK_STRIKE", "FISH_STRUGGLE", "PROGRESSIVE_RETRIEVAL", "SURFACE_LANDING", "CATCH_PRESENTATION"]
const PRESENTATION_SOURCE_NAMES := ["NONE", "REAL_CATCH", "DEBUG_SIMULATION"]
const DEBUG_SIMULATION_PHASES := [PresentationPhase.HOOK_STRIKE, PresentationPhase.FISH_STRUGGLE, PresentationPhase.PROGRESSIVE_RETRIEVAL, PresentationPhase.SURFACE_LANDING, PresentationPhase.CATCH_PRESENTATION]
const HANGING_CURL_PULSE_DURATION_SECONDS := 0.48
const HANGING_SWAY_DAMPING := 2.8
const TROLLING_AUDIO_PATHS := {
	"line_out": "res://assets/sfx/fishing_line_out.wav",
	"drag": "res://assets/sfx/fishing_drag.wav",
	"reel_in": "res://assets/sfx/fishing_reel_in.wav",
	"splash": "res://assets/sfx/fishing_splash.wav",
	"boat_splash": "res://assets/sfx/fishing_fish_flex.wav",
	"catch_success": "res://assets/sfx/fishing_catch_success.wav",
}
const TROLLING_LOOP_VOLUME_DB := {"line_out": -12.0, "drag": 4.0, "reel_in": 4.0}
const TROLLING_ONE_SHOT_VOLUME_DB := {"splash": -6.0, "boat_splash": -6.0, "catch_success": -2.0}
const BOAT_FISH_FLEX_SOUND := "res://assets/sfx/fishing_fish_flex.wav"
const TROLLING_AUDIO_FADE_SECONDS := 0.1
const TROLLING_AMBIENCE_DUCK_DB := {"Ocean": 8.0, "Engine": 8.0, "Weather": 5.0}
const TROLLING_AMBIENCE_DUCK_FADE_SECONDS := 0.14
const REEL_AUDIO_DIRECTION_EPSILON := 0.05
const DEFAULT_HANGING_CURL_PULSES := [
	Vector3(-0.2, 1.0, 1.0),
	Vector3(0.62, 0.98, -1.0),
	Vector3(1.36, 1.0, 1.0),
	Vector3(2.12, 0.95, -1.0),
	Vector3(2.93, 0.84, 1.0),
	Vector3(3.78, 0.68, -1.0),
	Vector3(4.9, 0.48, 1.0),
	Vector3(6.25, 0.32, -1.0),
	Vector3(7.7, 0.2, 1.0),
	Vector3(9.0, 0.12, -1.0),
	Vector3(10.0, 0.08, 1.0),
]

@export_node_path("Node") var boat_controller_path := NodePath("../MotionRoot")
@export_node_path("Node") var fish_manager_path := NodePath("../../FishResourceManager")
@export_node_path("Node") var wave_sampler_path := NodePath("../../WaveSampler")
@export_node_path("Node3D") var powerboat_visual_root_path := NodePath("../MotionRoot/VisualRoot")
@export_node_path("Node3D") var sailboat_visual_root_path := NodePath("../SailingBoat8m/VisualRoot")
@export_node_path("Node3D") var camera_rig_path := NodePath("../FollowCameraRig")

@export_category("Hull mounts")
@export var powerboat_mount_profile: FishingRodMountProfile
@export var sailboat_mount_profile: FishingRodMountProfile

@export_category("Presentation")
@export var visuals_enabled := true
@export_range(0.01, 2.0, 0.01) var cast_duration_seconds := 1.0
@export_range(0.1, 10.0, 0.1) var hook_strike_seconds := 3.0
@export_range(0.1, 30.0, 0.1) var fish_struggle_seconds := 15.0
@export_range(0.1, 40.0, 0.1) var progressive_retrieval_seconds := 22.0
@export_range(0.1, 20.0, 0.1) var surface_landing_seconds := 8.0
@export_range(0.1, 20.0, 0.1) var catch_presentation_seconds := 8.0
@export var auto_switch_to_fight_camera := true
## Presentation-only multiplier. F3 can adjust this live; it is not persisted.
@export_range(0.5, 4.0, 0.1) var hanging_struggle_intensity := 3.0
@export var fight_profiles: Array[FishingFightProfile] = []

var visual_state: VisualState = VisualState.IDLE
var presentation_phase: PresentationPhase = PresentationPhase.NONE
var presentation_source: PresentationSource = PresentationSource.NONE

var _controller: Node
var _manager: FishResourceManager
var _encounter: FishingEncounterSystem
var _wave_sampler: WaveSampler
var _camera_rig: BoatFollowCamera
var _active_visual_root: Node3D
var _active_profile: FishingRodMountProfile
var _mount: FishingRodMount
var _rig: FishingRodRig
var _trolling_activity_visible := false
var _fight_profile: FishingFightProfile
var _pending: FishingPendingCatch
var _catch_result: FishingCatchResult
var _presentation_species_id := ""
var _presentation_method := "trolling"
var _presentation_length_m := 0.0
var _presentation_weight_kg := 0.0
var _presentation_seed := 0
var _last_simulation_species_id := ""
var _last_simulation_length_m := 0.0
var _last_simulation_seed := 0
var _simulation_time_scale := 1.0
var _simulation_paused := false
var _simulation_resume_trolling := false
var _queued_real_pending: FishingPendingCatch
var _fight_elapsed := 0.0
var _presentation_elapsed := 0.0
var _cast_elapsed := 0.0
var _line_distance_m := 0.0
var _reel_spin_speed_for_audio := 0.0
var _struggle_pulse_triggered: Dictionary = {}
var _splash_pulse_triggered: Dictionary = {}
var _settlement_requested := false
var _retrieval_started_catch_id := ""
var _last_line_state := "OUT"
var _last_fish_stage := "HIDDEN"
var _connected_encounter: FishingEncounterSystem
var _active_sailboat := false
var _trolling_audio_players: Dictionary = {}
var _trolling_audio_loop_active: Dictionary = {}
var _trolling_audio_loop_gain: Dictionary = {}
var _trolling_audio_loop_target: Dictionary = {}
var _external_fishing_audio_loops: Dictionary = {}
var _external_fishing_audio_intensities: Dictionary = {}
var _external_loop_volume_scale: Dictionary = {}
var _shared_fishing_audio_event_counts: Dictionary = {}
var _boat_fish_flex_players: Array[AudioStreamPlayer] = []
var _boat_fish_flex_last_play_usec := 0
var _trolling_ambience_bus_states: Dictionary = {}
var _last_splash_audio_catch_id := ""
var _success_audio_played_for_presentation := false


func _ready() -> void:
	_controller = get_node_or_null(boat_controller_path)
	_manager = get_node_or_null(fish_manager_path) as FishResourceManager
	_wave_sampler = get_node_or_null(wave_sampler_path) as WaveSampler
	_camera_rig = get_node_or_null(camera_rig_path) as BoatFollowCamera
	if _controller != null and _controller.has_signal("vessel_mode_changed"):
		_controller.vessel_mode_changed.connect(_on_vessel_mode_changed)
	_active_sailboat = bool(_controller.call("is_sailing_active")) if _controller != null and _controller.has_method("is_sailing_active") else false
	_resolve_encounter()
	_bind_active_hull()
	_create_trolling_audio_players()
	set_process(true)


func _process(delta: float) -> void:
	_resolve_encounter()
	if visual_state == VisualState.CASTING:
		_cast_elapsed += delta
		_update_visual_line(0.0, 0.0)
		if _cast_elapsed >= cast_duration_seconds:
			_set_visual_state(VisualState.TROLLING)
	elif visual_state == VisualState.TROLLING:
		# No fish is pulling line while the rig is simply trolling. Clear any
		# spin left by a completed/cancelled fight so the shared spool and crank
		# remain still during normal trolling.
		_set_reel_spin(0.0)
		_update_visual_line(0.0, 0.0)
	elif visual_state in [VisualState.HOOKED, VisualState.REELING]:
		_advance_fight_presentation(delta)
	elif visual_state == VisualState.PRESENTATION:
		_presentation_elapsed += delta
		_update_catch_presentation_pose()
		_emit_catch_display_snapshot()
		if _presentation_elapsed >= catch_presentation_seconds:
			_finish_presentation()
	elif visual_state == VisualState.SIMULATING:
		if _simulation_paused:
			_sync_trolling_loop_audio(delta, true)
			return
		var simulation_delta := delta * _simulation_time_scale
		if presentation_phase == PresentationPhase.CATCH_PRESENTATION:
			_presentation_elapsed += simulation_delta
			_update_catch_presentation_pose()
			_emit_catch_display_snapshot()
			if _presentation_elapsed >= catch_presentation_seconds:
				_finish_simulation()
		else:
			_advance_fight_presentation(simulation_delta)
	_sync_trolling_loop_audio(delta)


func _exit_tree() -> void:
	_stop_all_trolling_audio()
	if presentation_source == PresentationSource.DEBUG_SIMULATION and _encounter != null:
		_encounter.set_debug_presentation_paused(false)
	_release_camera()
	_clear_visuals()


## Public audio seam for other fishing activities. It shares this system's
## players, loop streams, fades, SFX bus and ambience ducking without sharing
## or changing their gameplay states.
func set_external_fishing_audio_loop(owner_id: StringName, key: String, active: bool, intensity: float = 1.0) -> void:
	if not TROLLING_LOOP_VOLUME_DB.has(key) or owner_id == &"":
		return
	var requests: Dictionary = _external_fishing_audio_loops.get(owner_id, {})
	requests[key] = active
	_external_fishing_audio_loops[owner_id] = requests
	var intensities: Dictionary = _external_fishing_audio_intensities.get(owner_id, {})
	intensities[key] = clampf(intensity, 0.0, 1.0) if active and is_finite(intensity) else 0.0
	_external_fishing_audio_intensities[owner_id] = intensities
	_sync_trolling_loop_audio(0.0)


func clear_external_fishing_audio_loops(owner_id: StringName) -> void:
	if owner_id == &"":
		return
	_external_fishing_audio_loops.erase(owner_id)
	_external_fishing_audio_intensities.erase(owner_id)
	_sync_trolling_loop_audio(0.0)


func play_shared_fishing_one_shot(key: String) -> bool:
	if not TROLLING_ONE_SHOT_VOLUME_DB.has(key):
		return false
	_shared_fishing_audio_event_counts[key] = int(_shared_fishing_audio_event_counts.get(key, 0)) + 1
	_play_trolling_one_shot(key)
	return true


func play_boat_fish_flex(intensity: float) -> void:
	var now := Time.get_ticks_usec()
	if now - _boat_fish_flex_last_play_usec < 90000:
		return
	for player in _boat_fish_flex_players:
		if not player.playing:
			player.volume_db = -12.0 + linear_to_db(clampf(intensity, 0.12, 1.0))
			player.play()
			_boat_fish_flex_last_play_usec = now
			return


func get_shared_fishing_audio_event_count(key: String) -> int:
	return int(_shared_fishing_audio_event_counts.get(key, 0))


func get_encounter_system() -> FishingEncounterSystem:
	_resolve_encounter()
	return _encounter


func get_visual_state_name() -> String:
	return VISUAL_STATE_NAMES[clampi(int(visual_state), 0, VISUAL_STATE_NAMES.size() - 1)]


func get_presentation_phase_name() -> String:
	return PHASE_NAMES[clampi(int(presentation_phase), 0, PHASE_NAMES.size() - 1)]


func get_presentation_source_name() -> String:
	return PRESENTATION_SOURCE_NAMES[clampi(int(presentation_source), 0, PRESENTATION_SOURCE_NAMES.size() - 1)]


func get_presentation_method() -> String:
	return _presentation_method


func start_trolling() -> bool:
	_resolve_encounter()
	if _encounter == null or visual_state != VisualState.IDLE:
		return false
	if not _encounter.start_trolling():
		return false
	_set_reel_spin(0.0)
	_cast_elapsed = 0.0
	_set_visual_state(VisualState.CASTING)
	_update_rod_load(0.0)
	if _rig != null:
		_rig.set_line_active(true)
	return true


func stop_trolling() -> void:
	_stop_all_trolling_audio()
	_resolve_encounter()
	if _encounter != null:
		_encounter.stop_trolling()
	_simulation_resume_trolling = false
	_clear_presentation()
	_set_visual_state(VisualState.IDLE)
	if _rig != null:
		_rig.set_line_active(false)
		_rig.set_rod_load(0.0)
	_update_mount_visibility()


## Shows the mounted trolling rod while the Trolling activity/setup is open.
## This is presentation only: it does not deploy line or start the encounter.
func set_trolling_activity_visible(visible: bool) -> void:
	_trolling_activity_visible = visible
	_update_mount_visibility()


func debug_reset_visual() -> void:
	if presentation_source == PresentationSource.DEBUG_SIMULATION:
		debug_stop_simulated_catch()
		return
	if _encounter != null and _encounter.pending_catch != null:
		_encounter.cancel_pending_catch()
	_clear_presentation()
	_set_visual_state(VisualState.IDLE if _encounter == null or _encounter.state == FishingEncounterSystem.State.IDLE else VisualState.TROLLING)
	if _rig != null:
		_rig.set_rod_load(0.0)
		_set_reel_spin(0.0)
		_rig.set_line_active(visual_state != VisualState.IDLE)


func can_start_debug_simulation() -> bool:
	if _manager == null or presentation_source != PresentationSource.NONE:
		return false
	if _queued_real_pending != null:
		return false
	if visual_state not in [VisualState.IDLE, VisualState.TROLLING]:
		return false
	if _encounter == null:
		return false
	if _encounter.pending_catch != null or _encounter.state in [FishingEncounterSystem.State.HOOKED, FishingEncounterSystem.State.RETRIEVING]:
		return false
	return _encounter.state in [FishingEncounterSystem.State.IDLE, FishingEncounterSystem.State.TROLLING]


func start_debug_simulated_catch(species_id: String, length_cm: float, animation_seed: int = 20261030) -> Dictionary:
	_resolve_encounter()
	if not can_start_debug_simulation():
		return {"accepted": false, "reason": "real_presentation_active"}
	var profile := _manager.get_species_profile(species_id) if _manager != null else null
	if profile == null or species_id not in ["sea_trout", "needlefish"]:
		return {"accepted": false, "reason": "unknown_species"}
	var requested_length_m := length_cm / 100.0
	var natural_length_m := clampf(requested_length_m, profile.body_length_range_m.x, profile.body_length_range_m.y)
	_simulation_resume_trolling = _encounter.state == FishingEncounterSystem.State.TROLLING
	_last_simulation_species_id = species_id
	_last_simulation_length_m = natural_length_m
	_last_simulation_seed = animation_seed
	_begin_debug_simulation(species_id, natural_length_m, animation_seed, _simulation_resume_trolling)
	return {"accepted": true, "species_id": species_id, "length_m": natural_length_m, "estimated_weight_kg": _presentation_weight_kg, "seed": animation_seed}


func debug_stop_simulated_catch() -> bool:
	if presentation_source != PresentationSource.DEBUG_SIMULATION:
		return false
	_finish_simulation()
	return true


func debug_replay_simulated_catch() -> bool:
	if _queued_real_pending != null or (_encounter != null and _encounter.pending_catch != null):
		return false
	var species_id := _presentation_species_id if presentation_source == PresentationSource.DEBUG_SIMULATION else _last_simulation_species_id
	var length_m := _presentation_length_m if presentation_source == PresentationSource.DEBUG_SIMULATION else _last_simulation_length_m
	var seed := _presentation_seed if presentation_source == PresentationSource.DEBUG_SIMULATION else _last_simulation_seed
	if species_id.is_empty() or length_m <= 0.0:
		return false
	var resume_trolling := _simulation_resume_trolling if presentation_source == PresentationSource.DEBUG_SIMULATION else (_encounter != null and _encounter.state == FishingEncounterSystem.State.TROLLING)
	if presentation_source != PresentationSource.DEBUG_SIMULATION and not can_start_debug_simulation():
		return false
	_begin_debug_simulation(species_id, length_m, seed, resume_trolling)
	return true


func has_debug_simulation_replay() -> bool:
	return not _last_simulation_species_id.is_empty() and _last_simulation_length_m > 0.0


func debug_set_simulation_paused(paused: bool) -> bool:
	if presentation_source != PresentationSource.DEBUG_SIMULATION:
		return false
	_simulation_paused = paused
	if _rig != null:
		_rig.set_presentation_clock(_simulation_time_scale, _simulation_paused)
	return true


func debug_set_simulation_speed(time_scale: float) -> bool:
	if presentation_source != PresentationSource.DEBUG_SIMULATION:
		return false
	_simulation_time_scale = clampf(time_scale, 0.5, 2.0)
	if _rig != null:
		_rig.set_presentation_clock(_simulation_time_scale, _simulation_paused)
	return true


func debug_set_hanging_struggle_intensity(intensity: float) -> bool:
	if presentation_source != PresentationSource.DEBUG_SIMULATION:
		return false
	hanging_struggle_intensity = clampf(intensity, 0.5, 4.0)
	if presentation_phase == PresentationPhase.SURFACE_LANDING:
		_update_surface_fish_pose(_fight_profile)
	elif presentation_phase == PresentationPhase.CATCH_PRESENTATION:
		_update_catch_presentation_pose()
	return true


func get_hanging_struggle_intensity() -> float:
	return hanging_struggle_intensity


func debug_seek_simulation_phase(phase_index: int) -> bool:
	if presentation_source != PresentationSource.DEBUG_SIMULATION or phase_index < 0 or phase_index >= DEBUG_SIMULATION_PHASES.size():
		return false
	if _rig != null:
		_rig.reset_presentation_animation()
	_struggle_pulse_triggered.clear()
	_splash_pulse_triggered.clear()
	_fight_elapsed = get_debug_simulation_phase_start_seconds(phase_index)
	_presentation_elapsed = 0.0
	if phase_index == 4:
		_set_presentation_phase(PresentationPhase.CATCH_PRESENTATION)
		_line_distance_m = 0.0
		_last_line_state = "LANDED"
		_last_fish_stage = "LANDED"
		if _camera_rig != null:
			_camera_rig.set_fight_camera_focus_progress(1.0)
		if _rig != null:
			_rig.set_line_active(true)
			_set_reel_spin(0.0)
			_rig.set_catch_visual_visible(true)
			_update_catch_presentation_pose()
		_emit_catch_display_snapshot()
	else:
		_set_presentation_phase(DEBUG_SIMULATION_PHASES[phase_index])
		if _rig != null:
			_rig.set_line_active(true)
			_rig.set_catch_visual_visible(false)
		if phase_index == 0 and _rig != null:
			_rig.trigger_hook_strike()
		_update_fight_visuals()
		if _rig != null:
			_rig.snap_rod_load_to_target()
	return true


func get_debug_simulation_phase_start_seconds(phase_index: int) -> float:
	if phase_index < 0 or phase_index >= DEBUG_SIMULATION_PHASES.size():
		return -1.0
	var starts := [
		0.0,
		hook_strike_seconds,
		hook_strike_seconds + fish_struggle_seconds,
		hook_strike_seconds + fish_struggle_seconds + progressive_retrieval_seconds,
		hook_strike_seconds + fish_struggle_seconds + progressive_retrieval_seconds + surface_landing_seconds,
	]
	return float(starts[phase_index])


func _begin_debug_simulation(species_id: String, natural_length_m: float, animation_seed: int, resume_trolling: bool) -> void:
	_clear_presentation()
	_simulation_resume_trolling = resume_trolling
	presentation_source = PresentationSource.DEBUG_SIMULATION
	_presentation_species_id = species_id
	_presentation_length_m = natural_length_m
	_presentation_seed = animation_seed
	_simulation_time_scale = 1.0
	_simulation_paused = false
	var species := _manager.get_species_profile(species_id) if _manager != null else null
	_presentation_weight_kg = species.estimated_weight_coefficient_kg_per_m3 * pow(natural_length_m, 3.0) if species != null else 0.0
	_fight_profile = _find_fight_profile(species_id)
	_fight_elapsed = 0.0
	_presentation_elapsed = 0.0
	_line_distance_m = _active_profile.line_out_length_m if _active_profile != null else 9.0
	_struggle_pulse_triggered.clear()
	_splash_pulse_triggered.clear()
	_last_line_state = "HOLD"
	_last_fish_stage = "FAR"
	_last_splash_audio_catch_id = ""
	_set_presentation_phase(PresentationPhase.HOOK_STRIKE)
	_set_visual_state(VisualState.SIMULATING)
	if _encounter != null:
		_encounter.set_debug_presentation_paused(true)
	if _rig != null:
		_rig.reset_presentation_animation()
		_rig.set_presentation_clock(_simulation_time_scale, false)
		if species != null:
			_rig.set_catch_visual(species, natural_length_m)
		_rig.set_catch_visual_visible(false)
		_rig.set_line_active(true)
		_rig.trigger_hook_strike()
		_rig.set_rod_load(0.95)
		_update_visual_line(0.0, 0.0)
	if _camera_rig != null and _mount != null:
		_camera_rig.set_fight_camera_target(_mount, _active_profile)
		_camera_rig.set_fight_camera_focus_progress(0.0)
		_camera_rig.begin_fight_camera(auto_switch_to_fight_camera)
		_camera_rig.trigger_fight_camera_impulse(1.0)


func get_debug_species_profile(species_id: String) -> FishSpeciesProfile:
	return _manager.get_species_profile(species_id) if _manager != null else null


func debug_complete_retrieval_now() -> Dictionary:
	_resolve_encounter()
	if _encounter == null or _encounter.pending_catch == null:
		return {"accepted": false, "reason": "no_retrieval_pending"}
	_pending = _encounter.pending_catch
	if _encounter.state == FishingEncounterSystem.State.HOOKED:
		if not _encounter.begin_retrieval():
			return {"accepted": false, "reason": "no_retrieval_pending"}
	_settlement_requested = true
	_fight_elapsed = _normal_fight_duration()
	var result := _encounter.complete_retrieval(_pending.catch_id)
	if not bool(result.get("accepted", false)):
		_settlement_requested = false
		if _encounter.pending_catch != null and _encounter.pending_catch.catch_id == _pending.catch_id:
			_encounter.cancel_pending_catch()
		else:
			_clear_presentation()
	return result


func get_presentation_snapshot() -> Dictionary:
	var phase_duration := _phase_duration(presentation_phase)
	var phase_remaining := maxf(0.0, phase_duration - _phase_elapsed()) if presentation_phase != PresentationPhase.NONE else 0.0
	var total_duration := hook_strike_seconds + fish_struggle_seconds + progressive_retrieval_seconds + surface_landing_seconds + catch_presentation_seconds
	var elapsed := _fight_elapsed if presentation_phase != PresentationPhase.CATCH_PRESENTATION else _normal_fight_duration() + _presentation_elapsed
	var load_ratio := _rig.get_current_rod_load_ratio() if _rig != null else 0.0
	var has_fish_visual := _rig != null and _rig.has_catch_visual()
	var hook_world := _rig.get_catch_hook_point_world() if has_fish_visual else Vector3.ZERO
	var tip_world := _rig.get_rod_tip_world() if _rig != null else Vector3.ZERO
	var tail_world := _rig.get_catch_tail_point_world() if has_fish_visual else Vector3.ZERO
	var water_height := _sample_water_height(tail_world) if has_fish_visual else tail_world.y
	return {
		"phase": get_presentation_phase_name(),
		"phase_remaining_seconds": phase_remaining,
		"phase_elapsed_seconds": _phase_elapsed() if presentation_phase != PresentationPhase.NONE else 0.0,
		"total_progress": clampf(elapsed / maxf(total_duration, 0.001), 0.0, 1.0),
		"rod_load_ratio": load_ratio,
		"line_state": _last_line_state,
		"line_distance_m": _line_distance_m,
		"line_out_reference_m": _active_profile.line_out_length_m if _active_profile != null else 9.0,
		"near_boat_line_reference_m": _active_profile.catch_surface_distance_m if _active_profile != null else 2.7,
		"hanging_line_length_m": tip_world.distance_to(hook_world) if has_fish_visual else 0.0,
		"hanging_tail_clearance_m": tail_world.y - water_height if has_fish_visual else 0.0,
		"fish_stage": _last_fish_stage,
		"source": get_presentation_source_name(),
		"species_id": _presentation_species_id,
		"body_length_cm": _presentation_length_m * 100.0,
		"estimated_weight_kg": _presentation_weight_kg,
		"simulation_seed": _presentation_seed,
		"simulation_speed": _simulation_time_scale,
		"simulation_paused": _simulation_paused,
		"hanging_struggle_intensity": hanging_struggle_intensity,
		"camera_mode": _camera_rig.get_camera_mode_name() if _camera_rig != null else "unavailable",
		"auto_fight_camera": auto_switch_to_fight_camera,
		"catch_id": _pending.catch_id if _pending != null else (_catch_result.catch_id if _catch_result != null else ("DEBUG PREVIEW" if presentation_source == PresentationSource.DEBUG_SIMULATION else "")),
	}


func _resolve_encounter() -> void:
	if _manager == null or not is_instance_valid(_manager):
		return
	var resolved := _manager.get_fishing_encounter_system()
	if resolved == _connected_encounter:
		_encounter = resolved
		return
	if _connected_encounter != null and is_instance_valid(_connected_encounter):
		_disconnect_encounter(_connected_encounter)
	_connected_encounter = resolved
	_encounter = resolved
	if _encounter == null:
		return
	_encounter.fish_hooked.connect(_on_fish_hooked)
	_encounter.retrieval_started.connect(_on_retrieval_started)
	_encounter.catch_succeeded.connect(_on_catch_succeeded)
	_encounter.catch_cancelled.connect(_on_catch_cancelled)
	_encounter.trolling_stopped.connect(_on_trolling_stopped)


func _disconnect_encounter(encounter: FishingEncounterSystem) -> void:
	if encounter.fish_hooked.is_connected(_on_fish_hooked): encounter.fish_hooked.disconnect(_on_fish_hooked)
	if encounter.retrieval_started.is_connected(_on_retrieval_started): encounter.retrieval_started.disconnect(_on_retrieval_started)
	if encounter.catch_succeeded.is_connected(_on_catch_succeeded): encounter.catch_succeeded.disconnect(_on_catch_succeeded)
	if encounter.catch_cancelled.is_connected(_on_catch_cancelled): encounter.catch_cancelled.disconnect(_on_catch_cancelled)
	if encounter.trolling_stopped.is_connected(_on_trolling_stopped): encounter.trolling_stopped.disconnect(_on_trolling_stopped)


func _on_vessel_mode_changed(sailboat_active: bool) -> void:
	_active_sailboat = sailboat_active
	_bind_active_hull()


func _bind_active_hull() -> void:
	var visual_path := sailboat_visual_root_path if _active_sailboat else powerboat_visual_root_path
	var profile := sailboat_mount_profile if _active_sailboat else powerboat_mount_profile
	var visual_root := get_node_or_null(visual_path) as Node3D
	if visual_root == _active_visual_root and profile == _active_profile:
		return
	if presentation_source == PresentationSource.DEBUG_SIMULATION:
		_finish_simulation()
	if _mount != null and is_instance_valid(_mount):
		_mount.queue_free()
	_mount = null
	_rig = null
	_active_visual_root = visual_root
	_active_profile = profile
	if visual_root == null or profile == null:
		if _camera_rig != null:
			_camera_rig.set_fight_camera_target(null, null)
		return
	_mount = FishingRodMount.new()
	_mount.name = "FishingRodMountP3"
	_mount.mount_profile = profile
	_active_visual_root.add_child(_mount)
	_mount.visible = _trolling_activity_visible or visual_state != VisualState.IDLE
	if visuals_enabled:
		_rig = FishingRodRig.new()
		_rig.name = "FishingRodRig"
		_mount.add_child(_rig)
		_rig.configure(profile)
	if _has_active_presentation() and _rig != null:
		var species := _manager.get_species_profile(_presentation_species_id) if _manager != null else null
		if species != null:
			_rig.set_catch_visual(species, _presentation_length_m)
		_rig.set_line_active(true)
		_update_fight_visuals()
	if _camera_rig != null:
		_camera_rig.set_fight_camera_target(_mount, profile)
	if visual_state in [VisualState.TROLLING, VisualState.CASTING, VisualState.HOOKED, VisualState.REELING, VisualState.PRESENTATION] and _rig != null:
		_rig.set_line_active(true)
	if _pending != null and _camera_rig != null and _mount != null:
		_camera_rig.set_fight_camera_target(_mount, _active_profile)


func _on_fish_hooked(pending: FishingPendingCatch) -> void:
	if pending == null:
		return
	# Boat fishing owns its hand-held fight/landing presentation. The encounter
	# signal is shared, but this trolling rod must never start its timeline for it.
	if pending.fishing_method == "boat_fishing":
		return
	if presentation_source == PresentationSource.DEBUG_SIMULATION:
		_queued_real_pending = pending
		return
	if _pending != null and _pending.catch_id == pending.catch_id:
		return
	_last_splash_audio_catch_id = ""
	_begin_real_presentation(pending)


func _begin_real_presentation(pending: FishingPendingCatch) -> void:
	if pending == null:
		return
	_queued_real_pending = null
	_clear_presentation()
	_pending = pending
	_presentation_method = pending.fishing_method
	presentation_source = PresentationSource.REAL_CATCH
	_simulation_resume_trolling = false
	_presentation_species_id = pending.species_id
	_presentation_length_m = pending.body_length_m
	_presentation_seed = 0
	var species := _manager.get_species_profile(pending.species_id) if _manager != null else null
	_presentation_weight_kg = species.estimated_weight_coefficient_kg_per_m3 * pow(pending.body_length_m, 3.0) if species != null else 0.0
	_catch_result = null
	_fight_profile = _find_fight_profile(pending.species_id)
	_fight_elapsed = 0.0
	_line_distance_m = _active_profile.line_out_length_m if _active_profile != null else 9.0
	_last_line_state = "HOLD"
	_last_fish_stage = "FAR"
	_last_splash_audio_catch_id = ""
	_set_presentation_phase(PresentationPhase.HOOK_STRIKE)
	_set_visual_state(VisualState.HOOKED)
	if _rig != null:
		if species != null:
			_rig.set_catch_visual(species, pending.body_length_m)
		_rig.set_catch_visual_visible(false)
		_rig.set_line_active(true)
		_rig.trigger_hook_strike()
		_set_reel_spin(0.0)
		_update_visual_line(0.0, 0.0)
	if _presentation_method != "boat_fishing" and _camera_rig != null and _mount != null:
		_camera_rig.set_fight_camera_target(_mount, _active_profile)
		_camera_rig.set_fight_camera_focus_progress(0.0)
		_camera_rig.begin_fight_camera(auto_switch_to_fight_camera)
		_camera_rig.trigger_fight_camera_impulse(1.0)


func _on_retrieval_started(catch_id: String) -> void:
	if presentation_source != PresentationSource.REAL_CATCH or _pending == null or catch_id != _pending.catch_id or _retrieval_started_catch_id == catch_id:
		return
	if _pending.fishing_method == "boat_fishing":
		return
	_retrieval_started_catch_id = catch_id
	if _fight_elapsed < _hook_and_struggle_duration():
		# Developer-triggered retrieval may intentionally skip the hook/struggle
		# portion; the normal path starts here after the full 18 seconds.
		_fight_elapsed = _hook_and_struggle_duration()
	_set_presentation_phase(PresentationPhase.PROGRESSIVE_RETRIEVAL)
	_set_visual_state(VisualState.REELING)


func _on_catch_succeeded(result: FishingCatchResult) -> void:
	if result == null or result.fishing_method == "boat_fishing" or presentation_source != PresentationSource.REAL_CATCH or _pending == null or result.catch_id != _pending.catch_id:
		return
	_catch_result = result
	_settlement_requested = true
	_set_visual_state(VisualState.PRESENTATION)
	_set_presentation_phase(PresentationPhase.CATCH_PRESENTATION)
	_presentation_elapsed = 0.0
	_last_line_state = "LANDED"
	_last_fish_stage = "LANDED"
	if _rig != null:
		_rig.set_line_active(true)
		_set_reel_spin(0.0)
		_rig.set_catch_visual_visible(true)
		_update_catch_presentation_pose()
	_emit_catch_display_snapshot()


func _on_catch_cancelled(catch_id: String, _reason: String) -> void:
	var owns_trolling_catch := (_pending != null and catch_id == _pending.catch_id and _pending.fishing_method != "boat_fishing") \
		or (_queued_real_pending != null and catch_id == _queued_real_pending.catch_id and _queued_real_pending.fishing_method != "boat_fishing")
	if not owns_trolling_catch:
		return
	_request_all_trolling_loops_stop()
	if _queued_real_pending != null and catch_id == _queued_real_pending.catch_id:
		_queued_real_pending = null
		_simulation_resume_trolling = _encounter != null and _encounter.state == FishingEncounterSystem.State.TROLLING
		if presentation_source == PresentationSource.DEBUG_SIMULATION:
			return
	if _pending == null or catch_id != _pending.catch_id:
		return
	_clear_presentation()
	call_deferred("_sync_after_catch_cancelled", catch_id)


func _on_trolling_stopped() -> void:
	_simulation_resume_trolling = false
	_request_all_trolling_loops_stop()


func _sync_after_catch_cancelled(catch_id: String) -> void:
	if _pending != null and _pending.catch_id != catch_id:
		return
	_set_visual_state(VisualState.TROLLING if _encounter != null and _encounter.state == FishingEncounterSystem.State.TROLLING else VisualState.IDLE)


func _advance_fight_presentation(delta: float) -> void:
	if not _has_active_presentation():
		_clear_presentation()
		_set_visual_state(VisualState.TROLLING if _encounter != null and _encounter.state == FishingEncounterSystem.State.TROLLING else VisualState.IDLE)
		return
	_fight_elapsed += delta
	var hook_end := hook_strike_seconds
	var struggle_end := _hook_and_struggle_duration()
	var retrieval_end := struggle_end + progressive_retrieval_seconds
	var total_end := retrieval_end + surface_landing_seconds
	if _fight_elapsed < hook_end:
		_set_presentation_phase(PresentationPhase.HOOK_STRIKE)
	elif _fight_elapsed < struggle_end:
		_set_presentation_phase(PresentationPhase.FISH_STRUGGLE)
	elif _fight_elapsed < retrieval_end:
		if presentation_source == PresentationSource.REAL_CATCH and _encounter != null and _encounter.state == FishingEncounterSystem.State.HOOKED:
			if not _encounter.begin_retrieval():
				return
		_set_presentation_phase(PresentationPhase.PROGRESSIVE_RETRIEVAL)
	else:
		_set_presentation_phase(PresentationPhase.SURFACE_LANDING)
		if presentation_source == PresentationSource.DEBUG_SIMULATION and _fight_elapsed >= total_end:
			_update_fight_visuals()
			_begin_simulated_catch_presentation()
			return
		if presentation_source == PresentationSource.REAL_CATCH and not _settlement_requested and _fight_elapsed >= total_end:
			_update_fight_visuals()
			_settlement_requested = true
			var settled := _encounter.complete_retrieval(_pending.catch_id) if _encounter != null and _pending != null and _retrieval_started_catch_id == _pending.catch_id else {"accepted": false, "reason": "retrieval_not_started"}
			if not bool(settled.get("accepted", false)) and _pending != null:
				if _encounter != null and _encounter.pending_catch != null and _encounter.pending_catch.catch_id == _pending.catch_id:
					_encounter.cancel_pending_catch()
				else:
					_clear_presentation()
					_set_visual_state(VisualState.IDLE)
			return
	_update_fight_visuals()


func _begin_simulated_catch_presentation() -> void:
	_presentation_elapsed = 0.0
	_set_presentation_phase(PresentationPhase.CATCH_PRESENTATION)
	_last_line_state = "LANDED"
	_last_fish_stage = "LANDED"
	if _rig != null:
		_rig.set_line_active(true)
		_set_reel_spin(0.0)
		_rig.set_catch_visual_visible(true)
		_update_catch_presentation_pose()
	_emit_catch_display_snapshot()


func _update_fight_visuals() -> void:
	if _rig == null or not _has_active_presentation():
		return
	var phase := presentation_phase
	var profile := _fight_profile
	var base_load := profile.base_rod_load_ratio if profile != null else 0.76
	var pulse_strength := _pulse_envelope(profile.struggle_pulses_seconds_strength if profile != null else PackedVector2Array(), _fight_elapsed, profile.struggle_pulse_duration_seconds if profile != null else 1.1)
	var burst_strength := _pulse_envelope(profile.line_burst_pulses_seconds_strength if profile != null else PackedVector2Array(), _fight_elapsed, profile.line_burst_duration_seconds if profile != null else 0.8)
	var burst_distance := (profile.line_burst_distance_m if profile != null else 1.4) * burst_strength
	var retrieval_progress := 0.0
	if phase == PresentationPhase.PROGRESSIVE_RETRIEVAL:
		var retrieval_start := _hook_and_struggle_duration()
		retrieval_progress = clampf((_fight_elapsed - retrieval_start) / maxf(progressive_retrieval_seconds, 0.001), 0.0, 1.0)
	elif phase == PresentationPhase.SURFACE_LANDING:
		retrieval_progress = 1.0
	if _presentation_method != "boat_fishing" and _camera_rig != null:
		_camera_rig.set_fight_camera_focus_progress(retrieval_progress)
	var load_ratio := base_load + pulse_strength * (profile.struggle_load_peak if profile != null else 0.24)
	if phase == PresentationPhase.HOOK_STRIKE:
		load_ratio = maxf(load_ratio, 0.95 * (1.0 - clampf(_fight_elapsed / maxf(hook_strike_seconds, 0.01), 0.0, 1.0) * 0.16))
	elif phase == PresentationPhase.CATCH_PRESENTATION:
		load_ratio *= 0.12
	if phase == PresentationPhase.SURFACE_LANDING:
		var surface_elapsed := _fight_elapsed - hook_strike_seconds - fish_struggle_seconds - progressive_retrieval_seconds
		load_ratio *= 1.0 - 0.70 * clampf(surface_elapsed / maxf(surface_landing_seconds, 0.01), 0.0, 1.0)
	_rig.set_rod_load(clampf(load_ratio, 0.0, 1.0))
	if _fight_elapsed > 0.1:
		var pulse_index := _active_pulse_index(profile.struggle_pulses_seconds_strength if profile != null else PackedVector2Array(), _fight_elapsed)
		if pulse_index >= 0 and not _struggle_pulse_triggered.has(pulse_index):
			_struggle_pulse_triggered[pulse_index] = true
			_rig.trigger_struggle_impulse(pulse_strength)
			if _presentation_method != "boat_fishing" and _camera_rig != null:
				_camera_rig.trigger_fight_camera_impulse(pulse_strength)
	var start_distance := _active_profile.line_out_length_m if _active_profile != null else 9.0
	var near_boat_distance := _active_profile.catch_surface_distance_m if _active_profile != null else 2.7
	var distance := lerpf(start_distance, near_boat_distance, retrieval_progress) + burst_distance
	_line_distance_m = maxf(1.6, distance)
	if burst_strength > 0.15:
		_last_line_state = "BACKING_OUT"
		_set_reel_spin(-(profile.reverse_line_speed_radians_per_second if profile != null else 5.0) * burst_strength)
	else:
		_last_line_state = "REELING" if phase in [PresentationPhase.PROGRESSIVE_RETRIEVAL, PresentationPhase.SURFACE_LANDING] else "HOLD"
		_set_reel_spin(5.5 if phase == PresentationPhase.PROGRESSIVE_RETRIEVAL else (2.2 if phase == PresentationPhase.SURFACE_LANDING else 0.0))
	var fish_stage := "FAR"
	var fish_visible := false
	var visible_start := profile.near_boat_visible_start_progress if profile != null else 0.36
	if retrieval_progress >= visible_start and phase == PresentationPhase.PROGRESSIVE_RETRIEVAL:
		fish_stage = "APPROACHING"
		fish_visible = true
	if phase == PresentationPhase.SURFACE_LANDING:
		var surface_elapsed := _phase_elapsed()
		fish_stage = get_surface_fish_stage(profile, surface_elapsed)
		fish_visible = true
	var presentation_audio_key := _get_presentation_audio_key()
	var splash_already_played := presentation_audio_key.is_empty() or _last_splash_audio_catch_id == presentation_audio_key
	if should_play_trolling_splash(presentation_source, phase, fish_stage, _last_fish_stage, splash_already_played):
		_last_splash_audio_catch_id = presentation_audio_key
		_play_trolling_one_shot("splash")
	_last_fish_stage = fish_stage
	_rig.set_catch_visual_visible(fish_visible)
	if phase == PresentationPhase.SURFACE_LANDING:
		_update_surface_fish_pose(profile)
	else:
		_update_approach_fish_pose(profile, retrieval_progress)
	_update_visual_line(retrieval_progress, burst_strength)


func _update_approach_fish_pose(profile: FishingFightProfile, retrieval_progress: float) -> void:
	if _rig == null or _active_visual_root == null:
		return
	var time := _fight_elapsed
	var phase_offset := _animation_phase_offset()
	var lateral_amp := profile.lateral_struggle_amplitude_m if profile != null else 0.55
	var wag := profile.body_wag_frequency_hz if profile != null else 1.65
	var reveal_start := profile.near_boat_visible_start_progress if profile != null else 0.36
	var approach_progress := clampf((retrieval_progress - reveal_start) / maxf(1.0 - reveal_start, 0.001), 0.0, 1.0)
	var approach_eased := _smoothstep01(approach_progress)
	var approach_start_distance := _active_profile.catch_approach_start_distance_m if _active_profile != null else 5.8
	var surface_distance := _active_profile.catch_surface_distance_m if _active_profile != null else 2.7
	var approach_distance := lerpf(approach_start_distance, surface_distance, approach_eased)
	var burst_duration := profile.line_burst_duration_seconds if profile != null else 0.8
	var burst_distance := profile.line_burst_distance_m if profile != null else 1.2
	var burst := _pulse_envelope(profile.line_burst_pulses_seconds_strength if profile != null else PackedVector2Array(), time, burst_duration)
	approach_distance += burst_distance * burst
	var lateral_scale := lerpf(0.70, 1.15, approach_eased)
	var lateral_wave := lateral_amp * lateral_scale * (
		0.60 * sin(TAU * wag * 0.43 * time + phase_offset)
		+ 0.22 * sin(TAU * wag * 0.91 * time + phase_offset * 1.71)
	)
	var burst_index := _active_pulse_index(profile.line_burst_pulses_seconds_strength if profile != null else PackedVector2Array(), time)
	var burst_side := 1.0 if burst_index < 0 or burst_index % 2 == 0 else -1.0
	var lateral := lateral_wave + burst_side * lateral_amp * burst * 0.78
	var water_sample_position := _position_aft_of_boat(approach_distance, 0.0, lateral)
	var surface_y := _sample_water_height(water_sample_position)
	var start_depth := profile.approach_start_depth_below_surface_m if profile != null else 0.55
	var end_depth := profile.approach_end_depth_below_surface_m if profile != null else 0.14
	var depth := lerpf(start_depth, end_depth, approach_eased)
	var pos := _position_aft_at_world_height(approach_distance, surface_y - depth + sin(time * 2.1 + phase_offset) * 0.025, lateral)
	var yaw := deg_to_rad(profile.body_yaw_amplitude_degrees if profile != null else 24.0) * sin(time * TAU * wag * 0.34 + phase_offset)
	var roll := deg_to_rad(profile.body_roll_amplitude_degrees if profile != null else 18.0) * sin(time * TAU * wag + phase_offset)
	var pitch := deg_to_rad(profile.body_pitch_amplitude_degrees if profile != null else 8.0) * sin(time * TAU * wag * 0.78 + phase_offset)
	_rig.set_catch_position_world(pos, roll, yaw, pitch)


func _update_surface_fish_pose(profile: FishingFightProfile) -> void:
	if _rig == null:
		return
	var surface_elapsed := _phase_elapsed()
	var lateral_amp := profile.lateral_struggle_amplitude_m if profile != null else 0.55
	var wag := profile.body_wag_frequency_hz if profile != null else 1.65
	var phase_offset := _animation_phase_offset()
	var surface_distance := _active_profile.catch_surface_distance_m if _active_profile != null else 2.7
	var lateral_scale := profile.surface_lateral_amplitude_multiplier if profile != null else 1.0
	var lateral_pattern := 0.54 * sin(surface_elapsed * TAU * wag * 0.47 + phase_offset)
	lateral_pattern += 0.23 * sin(surface_elapsed * TAU * wag * 0.91 + phase_offset * 1.71)
	var burst_duration := profile.line_burst_duration_seconds if profile != null else 0.8
	var burst_events := profile.line_burst_pulses_seconds_strength if profile != null else PackedVector2Array()
	var burst := _pulse_envelope(burst_events, _fight_elapsed, burst_duration)
	var burst_index := _active_pulse_index(burst_events, _fight_elapsed)
	var burst_side := 1.0 if burst_index < 0 or burst_index % 2 == 0 else -1.0
	var lateral := lateral_amp * lateral_scale * (lateral_pattern + burst_side * burst * 0.82)
	lateral = clampf(lateral, -0.95, 0.95)
	var water_sample_position := _position_aft_of_boat(surface_distance, 0.0, lateral)
	var surface_y := _sample_water_height(water_sample_position)
	var surface_bob := profile.surface_bob_amplitude_m if profile != null else 0.06
	var target_y := surface_y - 0.12 + sin(surface_elapsed * 7.0 + phase_offset) * surface_bob
	var yaw_amp := profile.body_yaw_amplitude_degrees if profile != null else 24.0
	var roll_amp := profile.body_roll_amplitude_degrees if profile != null else 18.0
	var pitch_amp := profile.body_pitch_amplitude_degrees if profile != null else 8.0
	var yaw := deg_to_rad(yaw_amp) * sin(surface_elapsed * TAU * wag * 0.43 + phase_offset)
	yaw += deg_to_rad(yaw_amp * 0.16) * burst_side * burst
	var roll := deg_to_rad(roll_amp) * sin(surface_elapsed * TAU * wag + phase_offset)
	var pitch := deg_to_rad(pitch_amp) * sin(surface_elapsed * TAU * wag * 0.73 + phase_offset)
	var breach_t := _get_surface_breach_progress(profile, surface_elapsed)
	if breach_t >= 0.0:
		var breach_arc := sin(PI * breach_t)
		target_y = surface_y + _get_surface_breach_height_offset(profile, surface_elapsed)
		pitch = deg_to_rad(profile.surface_breach_pitch_degrees * breach_arc)
		roll += deg_to_rad(24.0 * sin(breach_t * TAU))
		lateral += sin(PI * breach_t) * lateral_amp * 0.38
	else:
		var wash_t := _get_surface_wash_gills_progress(profile, surface_elapsed)
		if wash_t >= 0.0:
			var wash_envelope := _smoothstep01(minf(wash_t / 0.16, 1.0)) * (1.0 - _smoothstep01(maxf((wash_t - 0.82) / 0.18, 0.0)))
			var wash_cycle := sin(surface_elapsed * TAU * 1.8 + phase_offset)
			target_y = surface_y - 0.04 + absf(wash_cycle) * (surface_bob + 0.04)
			roll = deg_to_rad(profile.surface_wash_gills_roll_degrees + 10.0 * wash_cycle) * wash_envelope
			pitch = deg_to_rad(22.0 + 12.0 * sin(surface_elapsed * TAU * 1.25)) * wash_envelope
			yaw += deg_to_rad(20.0 * sin(surface_elapsed * TAU * 0.9)) * wash_envelope
			lateral += sin(surface_elapsed * TAU * 2.0 + phase_offset) * lateral_amp * 0.48 * wash_envelope
		var lift_progress := _get_surface_lift_progress(profile, surface_elapsed)
		if lift_progress > 0.0:
			var lift_t := lift_progress
			var water_start := _position_aft_at_world_height(surface_distance, _sample_water_height(water_sample_position) + 0.025, lateral)
			var lift_start := profile.surface_lift_start_seconds if profile != null else surface_landing_seconds * 0.57
			var hanging_elapsed := maxf(0.0, surface_elapsed - lift_start)
			var wriggle_state := _get_hanging_body_wriggle_state(hanging_elapsed)
			var curl_angles := _get_effective_hanging_curl_angles(wriggle_state.intensity)
			_rig.set_catch_spine_curl(float(curl_angles.body), float(curl_angles.tail), wriggle_state.tail_phase, wriggle_state.curl_sign, profile.hanging_curl_bend_power if profile != null else 1.0)
			var swim_roll := lerpf(roll, 0.0, lift_t)
			var air_envelope := sin(PI * lift_t) * (profile.airborne_wriggle_strength if profile != null else 0.7)
			var air_frequency := profile.airborne_wriggle_frequency_hz if profile != null else 2.8
			var air_cycle := sin(TAU * air_frequency * surface_elapsed + phase_offset)
			air_cycle = clampf(air_cycle + 0.24 * sin(TAU * air_frequency * 1.63 * surface_elapsed + phase_offset * 0.67), -1.0, 1.0)
			var swim_yaw := lerpf(yaw, 0.0, lift_t) + deg_to_rad(profile.airborne_wriggle_yaw_degrees if profile != null else 24.0) * air_envelope * sin(TAU * air_frequency * surface_elapsed * 0.73 + phase_offset)
			var swim_pitch := lerpf(pitch, 0.0, lift_t) + deg_to_rad(14.0) * air_envelope * cos(TAU * air_frequency * surface_elapsed * 0.82 + phase_offset)
			_rig.set_catch_position_world(water_start, swim_roll + deg_to_rad(profile.airborne_wriggle_roll_degrees if profile != null else 20.0) * air_envelope * air_cycle, swim_yaw, swim_pitch)
			var current_mouth := _rig.get_catch_hook_point_world()
			var hanging_mouth := _get_hanging_mouth_point_world()
			var mouth := current_mouth.lerp(hanging_mouth, lift_t)
			var swim_rotation := _rig.get_catch_world_rotation()
			var hanging_rotation := _get_hanging_rotation(hanging_elapsed, hanging_mouth)
			_rig.set_catch_hanging_pose_world(mouth, swim_rotation.slerp(hanging_rotation, lift_t))
			_rig.set_rod_load(lerpf(profile.base_rod_load_ratio if profile != null else 0.76, 0.08, lift_t))
			_fire_surface_splashes(profile, surface_elapsed, water_start)
			return
		var idle_wriggle_state := _get_hanging_body_wriggle_state(maxf(0.0, surface_elapsed - (profile.surface_lift_start_seconds if profile != null else surface_landing_seconds * 0.57)))
		_rig.set_catch_spine_curl(0.0, 0.0, idle_wriggle_state.tail_phase, idle_wriggle_state.curl_sign, profile.hanging_curl_bend_power if profile != null else 1.0)
	lateral = clampf(lateral, -1.1, 1.1)
	var pos := _position_aft_at_world_height(surface_distance, target_y, lateral)
	_rig.set_catch_position_world(pos, roll, yaw, pitch)
	_fire_surface_splashes(profile, surface_elapsed, pos)


func get_surface_fish_stage(profile: FishingFightProfile, surface_elapsed: float) -> String:
	if _get_surface_breach_progress(profile, surface_elapsed) >= 0.0:
		return "BREACH"
	if _get_surface_wash_gills_progress(profile, surface_elapsed) >= 0.0:
		return "WASHING_GILLS"
	var lift_start := profile.surface_lift_start_seconds if profile != null else surface_landing_seconds * 0.57
	var lift_duration := profile.surface_lift_duration_seconds if profile != null else surface_landing_seconds * 0.22
	if surface_elapsed < lift_start:
		return "SURFACE"
	if surface_elapsed < lift_start + lift_duration:
		return "LIFTING"
	return "LANDED"


func _get_surface_breach_progress(profile: FishingFightProfile, surface_elapsed: float) -> float:
	if profile == null or not profile.surface_breach_enabled:
		return -1.0
	var progress := (surface_elapsed - profile.surface_breach_start_seconds) / maxf(profile.surface_breach_duration_seconds, 0.001)
	return progress if progress >= 0.0 and progress <= 1.0 else -1.0


func _get_surface_breach_height_offset(profile: FishingFightProfile, surface_elapsed: float) -> float:
	var progress := _get_surface_breach_progress(profile, surface_elapsed)
	if progress < 0.0:
		return 0.0
	var arc := sin(PI * progress)
	return -profile.surface_breach_submerge_depth_m + (profile.surface_breach_peak_height_m + profile.surface_breach_submerge_depth_m) * arc


func _get_surface_wash_gills_progress(profile: FishingFightProfile, surface_elapsed: float) -> float:
	if profile == null or not profile.surface_wash_gills_enabled:
		return -1.0
	var progress := (surface_elapsed - profile.surface_wash_gills_start_seconds) / maxf(profile.surface_wash_gills_duration_seconds, 0.001)
	return progress if progress >= 0.0 and progress <= 1.0 else -1.0


func _get_surface_lift_progress(profile: FishingFightProfile, surface_elapsed: float) -> float:
	var lift_start := profile.surface_lift_start_seconds if profile != null else surface_landing_seconds * 0.57
	var lift_duration := profile.surface_lift_duration_seconds if profile != null else surface_landing_seconds * 0.22
	var t := clampf((surface_elapsed - lift_start) / maxf(lift_duration, 0.001), 0.0, 1.0)
	return _smoothstep01(t)


func _smoothstep01(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _update_catch_presentation_pose() -> void:
	if _rig == null or _active_visual_root == null:
		return
	var fade := exp(-_presentation_elapsed * 0.65)
	var lift_start := _fight_profile.surface_lift_start_seconds if _fight_profile != null else surface_landing_seconds * 0.57
	var hanging_elapsed := maxf(0.0, surface_landing_seconds - lift_start) + _presentation_elapsed
	var hanging_mouth := _get_hanging_mouth_point_world()
	var wriggle_state := _get_hanging_body_wriggle_state(hanging_elapsed)
	var curl_angles := _get_effective_hanging_curl_angles(wriggle_state.intensity)
	_rig.set_catch_spine_curl(float(curl_angles.body), float(curl_angles.tail), wriggle_state.tail_phase, wriggle_state.curl_sign, _fight_profile.hanging_curl_bend_power if _fight_profile != null else 1.0)
	_rig.set_catch_hanging_pose_world(hanging_mouth, _get_hanging_rotation(hanging_elapsed, hanging_mouth))
	_rig.set_rod_load(0.08 * fade)
	_rig.set_line_active(true)
	_rig.set_hanging_line_world(_rig.get_catch_hook_point_world())
	_last_line_state = "HANGING"
	_last_fish_stage = "LANDED"
	if _camera_rig != null:
		_camera_rig.set_fight_camera_focus_progress(1.0)


func _emit_catch_display_snapshot() -> void:
	if presentation_phase != PresentationPhase.CATCH_PRESENTATION or not _has_active_presentation():
		catch_display_updated.emit({"visible": false})
		return
	var real_result := presentation_source == PresentationSource.REAL_CATCH and _catch_result != null
	if presentation_source == PresentationSource.REAL_CATCH and not real_result:
		catch_display_updated.emit({"visible": false})
		return
	var species := _manager.get_species_profile(_presentation_species_id) if _manager != null else null
	var fade_in := _smoothstep01(_presentation_elapsed / 0.4)
	var fade_out := _smoothstep01((catch_presentation_seconds - _presentation_elapsed) / 0.4)
	catch_display_updated.emit({
		"visible": true,
		"alpha": minf(fade_in, fade_out),
		"source": get_presentation_source_name(),
		"species_id": _presentation_species_id,
		"species_name_key": species.name_key if species != null else "fishing.ui.unknown_fish",
		"length_cm": _catch_result.length_m * 100.0 if real_result else _presentation_length_m * 100.0,
		"weight_kg": _catch_result.estimated_weight_kg if real_result else _presentation_weight_kg,
		"catch_id": _catch_result.catch_id if real_result else "",
		"debug_spawned": real_result and _catch_result.debug_spawned,
		"presentation_elapsed": _presentation_elapsed,
	})


func _surface_lift_end_seconds() -> float:
	var lift_start := _fight_profile.surface_lift_start_seconds if _fight_profile != null else surface_landing_seconds * 0.57
	var lift_duration := _fight_profile.surface_lift_duration_seconds if _fight_profile != null else surface_landing_seconds * 0.22
	return lift_start + lift_duration


func _get_hanging_mouth_point_world() -> Vector3:
	if _rig == null:
		return Vector3.ZERO
	var line_length := _active_profile.landing_min_line_length_m if _active_profile != null else 0.45
	return _rig.get_rod_tip_world() + Vector3.DOWN * line_length


func _get_hanging_rotation(hanging_elapsed: float, mouth_world: Vector3) -> Quaternion:
	var heading := _active_visual_root.global_rotation.y if _active_visual_root != null else 0.0
	var base := (Basis(Vector3.UP, heading) * Basis(Vector3.RIGHT, PI * 0.5)).get_rotation_quaternion()
	var profile_sway := _fight_profile.hanging_sway_max_degrees if _fight_profile != null else 12.0
	var mount_sway := _active_profile.hanging_sway_max_degrees if _active_profile != null else 12.0
	# The whole-fish swing is subordinate to the local body bend and limited by
	# both the species profile and this boat's safe display envelope.
	var configured_sway := minf(minf(profile_sway, mount_sway), 20.0)
	var sway_limit := deg_to_rad(configured_sway)
	var body_length := _rig.get_catch_body_length_m() if _rig != null else 0.0
	if body_length > 0.0 and _wave_sampler != null:
		var margin := _active_profile.hanging_clearance_margin_m if _active_profile != null else 0.10
		var sway_clearance_allowance := body_length * (1.0 - cos(sway_limit))
		var predicted_tail := mouth_world + base * Vector3(0.0, 0.0, body_length)
		var water_height := _sample_water_height(predicted_tail)
		var available_drop := mouth_world.y - water_height - margin - sway_clearance_allowance
		if available_drop < body_length and available_drop > 0.0:
			var safe_tilt := acos(clampf(available_drop / body_length, 0.0, 1.0))
			base = base * Quaternion(Vector3.RIGHT, safe_tilt + sway_limit)
	var body_wriggle := _get_hanging_body_wriggle(hanging_elapsed)
	var duration := _fight_profile.hanging_struggle_duration_seconds if _fight_profile != null else 2.0
	var residual_rise := _smoothstep01(hanging_elapsed / maxf(duration, 0.001))
	var residual_fade := 1.0 - 0.45 * _smoothstep01((hanging_elapsed - duration) / 2.0)
	var residual_envelope := residual_rise * residual_fade
	var seeded_phase := _animation_phase_offset()
	var residual_phase := hanging_elapsed * TAU * 0.62 + seeded_phase
	var root_sway := deg_to_rad(_get_hanging_lateral_swing_degrees(hanging_elapsed))
	var twist_limit := deg_to_rad(minf(_fight_profile.hanging_twist_max_degrees if _fight_profile != null else 5.0, 7.0))
	var axial_twist := twist_limit * (0.34 * body_wriggle + 0.16 * residual_envelope * sin(residual_phase * 1.37 + 0.6))
	# Fish local UP becomes a horizontal cross-body axis in the hanging basis.
	# Rotating around it moves the tail sideways while keeping the mouth fixed.
	return base * Quaternion(Vector3.UP, root_sway) * Quaternion(Vector3.BACK, axial_twist)


func _get_hanging_body_wriggle(hanging_elapsed: float) -> float:
	var state := _get_hanging_body_wriggle_state(hanging_elapsed)
	return state.curl_sign * state.intensity


func _get_hanging_body_wriggle_state(hanging_elapsed: float) -> Dictionary:
	var tail_frequency := _fight_profile.hanging_tail_wriggle_frequency_hz if _fight_profile != null else 6.2
	var elapsed := maxf(hanging_elapsed, 0.0)
	var tail_phase := elapsed * TAU * tail_frequency + _animation_phase_offset() * 0.73
	var burst_speed := _fight_profile.hanging_burst_speed_multiplier if _fight_profile != null else 1.5
	var pulse_strength := 0.0
	var curl_sign := 1.0
	for pulse_index in range(_hanging_curl_pulse_count()):
		var event := _hanging_curl_pulse(pulse_index)
		if hanging_elapsed >= event.x:
			curl_sign = -1.0 if event.z < 0.0 else 1.0
		var progress: float = (hanging_elapsed - event.x) / HANGING_CURL_PULSE_DURATION_SECONDS
		if progress < 0.0 or progress > 1.0:
			continue
		var pulse := _hanging_burst_envelope(progress * burst_speed)
		var candidate_strength: float = pulse * float(event.y)
		if candidate_strength > pulse_strength:
			pulse_strength = candidate_strength
			curl_sign = -1.0 if event.z < 0.0 else 1.0
	var late_fade := 1.0 - _smoothstep01((hanging_elapsed - 8.7) / 2.0)
	var background := lerpf(0.12, 0.025, _smoothstep01(hanging_elapsed / 5.2)) * maxf(late_fade, 0.0)
	var intensity := clampf(maxf(pulse_strength, background), 0.0, 1.0)
	return {
		"intensity": intensity,
		"tail_phase": tail_phase,
		"curl_sign": curl_sign,
	}


func _get_hanging_lateral_swing_degrees(hanging_elapsed: float) -> float:
	var frequency := _fight_profile.hanging_sway_response_frequency_hz if _fight_profile != null else 1.25
	var burst_speed := _fight_profile.hanging_burst_speed_multiplier if _fight_profile != null else 1.5
	var impulse_degrees := _fight_profile.hanging_burst_sway_impulse_degrees if _fight_profile != null else 18.0
	var swing := 0.0
	for pulse_index in range(_hanging_curl_pulse_count()):
		var event := _hanging_curl_pulse(pulse_index)
		var age: float = hanging_elapsed - event.x
		if age < 0.0 or age > 2.4:
			continue
		# Each C-bend kicks a damped lateral response. It continues after the
		# body pulse ends, so the fish swings from inertia instead of following a
		# separate clock-like sine loop.
		var inertia := _hanging_burst_sway_response(age, frequency, burst_speed)
		swing += event.y * (1.0 if event.z >= 0.0 else -1.0) * inertia * impulse_degrees
	var residual_degrees := _fight_profile.hanging_residual_sway_degrees if _fight_profile != null else 2.5
	var residual_envelope := _smoothstep01(maxf(hanging_elapsed, 0.0) / 0.4)
	var residual_phase := hanging_elapsed * TAU * 0.62 + _animation_phase_offset()
	swing += residual_degrees * residual_envelope * (0.72 * sin(residual_phase) + 0.28 * sin(residual_phase * 0.57 + 1.1))
	var profile_limit := _fight_profile.hanging_sway_max_degrees if _fight_profile != null else 20.0
	var mount_limit := _active_profile.hanging_sway_max_degrees if _active_profile != null else 20.0
	var limit := minf(minf(profile_limit, mount_limit), 20.0)
	return clampf(swing, -limit, limit)


func _hanging_burst_envelope(progress: float) -> float:
	var t := clampf(progress, 0.0, 1.0)
	if t < 0.32:
		return _smoothstep01(t / 0.32)
	return 1.0 - _smoothstep01((t - 0.32) / 0.68)


static func _hanging_burst_sway_response(age: float, frequency_hz: float, speed_multiplier: float) -> float:
	var elapsed := maxf(age, 0.0)
	return sin(TAU * frequency_hz * maxf(speed_multiplier, 1.0) * elapsed) * exp(-HANGING_SWAY_DAMPING * elapsed)


func _get_effective_hanging_curl_angles(pulse_intensity: float) -> Dictionary:
	var profile_body_angle := _fight_profile.hanging_curl_total_angle_degrees if _fight_profile != null else 125.0
	var profile_tail_angle := _fight_profile.hanging_tail_whip_angle_degrees if _fight_profile != null else 38.0
	var struggle_scale := clampf(hanging_struggle_intensity / 3.0, 0.0, 4.0 / 3.0)
	var amplitude_scale := clampf(pulse_intensity, 0.0, 1.0) * struggle_scale
	return {
		"body": profile_body_angle * amplitude_scale,
		"tail": profile_tail_angle * amplitude_scale,
	}


func _hanging_curl_pulse_count() -> int:
	if _fight_profile != null and not _fight_profile.hanging_curl_pulses.is_empty():
		return _fight_profile.hanging_curl_pulses.size()
	return DEFAULT_HANGING_CURL_PULSES.size()


func _hanging_curl_pulse(index: int) -> Vector3:
	if _fight_profile != null and not _fight_profile.hanging_curl_pulses.is_empty():
		return _fight_profile.hanging_curl_pulses[index]
	return DEFAULT_HANGING_CURL_PULSES[index]


func _animation_phase_offset() -> float:
	return fmod(absf(float(_presentation_seed)) * 0.61803398875, TAU)


func _update_visual_line(retrieval_progress: float, burst_strength: float) -> void:
	if _rig == null or _active_visual_root == null:
		return
	var trailing := _line_distance_m if _has_active_presentation() else (_active_profile.line_out_length_m if _active_profile != null else 9.0)
	if visual_state in [VisualState.CASTING, VisualState.TROLLING]:
		var eased_cast := clampf(_cast_elapsed / maxf(cast_duration_seconds, 0.001), 0.0, 1.0) if visual_state == VisualState.CASTING else 1.0
		trailing *= eased_cast
	_rig.set_reel_line_length(trailing)
	var lift_started := presentation_phase == PresentationPhase.SURFACE_LANDING and _get_surface_lift_progress(_fight_profile, _phase_elapsed()) > 0.0
	if presentation_phase == PresentationPhase.CATCH_PRESENTATION or lift_started or (presentation_phase == PresentationPhase.SURFACE_LANDING and _last_fish_stage == "LANDED"):
		_rig.set_hanging_line_world(_rig.get_catch_hook_point_world())
		_last_line_state = "HANGING"
		return
	var tip_world := _rig.to_global(_rig.get_rod_tip_local())
	var tip_root_local := _active_visual_root.to_local(tip_world)
	var water_entry_root_local := Vector3(tip_root_local.x, -0.18, tip_root_local.z + minf(trailing * 0.22, 2.1))
	var water_entry := _active_visual_root.to_global(water_entry_root_local)
	var line_end := _active_visual_root.to_global(Vector3(tip_root_local.x, -0.24, tip_root_local.z + trailing))
	if _has_active_presentation() and _rig.has_catch_visual():
		line_end = _rig.get_catch_hook_point_world()
		water_entry = tip_world.lerp(line_end, 0.72)
		water_entry.y = _sample_water_height(water_entry) + 0.015
	_rig.set_line_points_world(water_entry, line_end)
	var tension := 0.38
	if _has_active_presentation():
		tension = 0.82
		if presentation_phase == PresentationPhase.SURFACE_LANDING:
			tension = 0.9
		elif presentation_phase == PresentationPhase.CATCH_PRESENTATION:
			tension = 0.05
	if burst_strength > 0.15:
		tension = maxf(tension, 0.94)
	_rig.set_line_tension(tension)
	if not _rig.is_line_active():
		_rig.set_line_active(true)
	_last_line_state = "BACKING_OUT" if burst_strength > 0.15 else ("REELING" if retrieval_progress > 0.0 else "OUT")


func _fire_surface_splashes(profile: FishingFightProfile, surface_elapsed: float, fish_surface_position: Vector3) -> void:
	if _rig == null or presentation_phase != PresentationPhase.SURFACE_LANDING:
		return
	if profile == null:
		return
	for index in range(profile.surface_splash_times_seconds.size()):
		var event_time := profile.surface_splash_times_seconds[index]
		if surface_elapsed >= event_time and not _splash_pulse_triggered.has(index):
			_splash_pulse_triggered[index] = true
			var source := Vector3(fish_surface_position.x, _sample_water_height(fish_surface_position) + 0.02, fish_surface_position.z)
			var intensity := profile.splash_strength_multiplier
			if profile.surface_breach_enabled and absf(event_time - profile.surface_breach_start_seconds) <= 0.06:
				intensity = profile.breach_splash_strength_multiplier
			_rig.trigger_splash(source, intensity)


func _position_aft_of_boat(aft_distance: float, height_from_root: float, lateral_offset: float) -> Vector3:
	if _active_visual_root == null:
		return Vector3.ZERO
	var mount_position := _active_profile.mount_position_m if _active_profile != null else Vector3.ZERO
	return _active_visual_root.to_global(Vector3(mount_position.x + lateral_offset, height_from_root, mount_position.z + aft_distance))


func _position_aft_at_world_height(aft_distance: float, world_y: float, lateral_offset: float) -> Vector3:
	var position := _position_aft_of_boat(aft_distance, 0.0, lateral_offset)
	position.y = world_y
	return position


func _sample_water_height(world_position: Vector3) -> float:
	if _wave_sampler == null:
		return world_position.y
	var time_seconds := _wave_sampler.get_effective_wave_time_seconds()
	var sample: Dictionary = _wave_sampler.sample_surface(world_position, time_seconds)
	return float(sample.get("height", world_position.y))


func _pulse_envelope(events: PackedVector2Array, time_seconds: float, duration: float) -> float:
	var strongest := 0.0
	for event in events:
		var t := (time_seconds - event.x) / maxf(duration, 0.001)
		if t < 0.0 or t > 1.0:
			continue
		var envelope := sin(t * PI)
		strongest = maxf(strongest, envelope * envelope * event.y)
	return clampf(strongest, 0.0, 1.0)


func _active_pulse_index(events: PackedVector2Array, time_seconds: float) -> int:
	for index in range(events.size()):
		if time_seconds >= events[index].x and time_seconds < events[index].x + 0.22:
			return index
	return -1


func _phase_duration(phase: PresentationPhase) -> float:
	match phase:
		PresentationPhase.HOOK_STRIKE: return hook_strike_seconds
		PresentationPhase.FISH_STRUGGLE: return fish_struggle_seconds
		PresentationPhase.PROGRESSIVE_RETRIEVAL: return progressive_retrieval_seconds
		PresentationPhase.SURFACE_LANDING: return surface_landing_seconds
		PresentationPhase.CATCH_PRESENTATION: return catch_presentation_seconds
		_: return 0.0


func _phase_elapsed() -> float:
	match presentation_phase:
		PresentationPhase.HOOK_STRIKE: return _fight_elapsed
		PresentationPhase.FISH_STRUGGLE: return _fight_elapsed - hook_strike_seconds
		PresentationPhase.PROGRESSIVE_RETRIEVAL: return _fight_elapsed - _hook_and_struggle_duration()
		PresentationPhase.SURFACE_LANDING: return _fight_elapsed - _hook_and_struggle_duration() - progressive_retrieval_seconds
		PresentationPhase.CATCH_PRESENTATION: return _presentation_elapsed
		_: return 0.0


func _set_presentation_phase(next_phase: PresentationPhase) -> void:
	var entering_catch_presentation := next_phase == PresentationPhase.CATCH_PRESENTATION and presentation_phase != PresentationPhase.CATCH_PRESENTATION
	presentation_phase = next_phase
	if entering_catch_presentation and _presentation_method != "boat_fishing" and should_play_trolling_catch_presentation_audio(presentation_source, _success_audio_played_for_presentation):
		_success_audio_played_for_presentation = true
		_play_trolling_one_shot("catch_success")


func _set_visual_state(next_state: VisualState) -> void:
	if visual_state == next_state:
		return
	visual_state = next_state
	if next_state in [VisualState.IDLE, VisualState.TROLLING]:
		_set_reel_spin(0.0)
	_update_mount_visibility()
	visual_state_changed.emit(get_visual_state_name())


func _update_mount_visibility() -> void:
	if _mount != null and is_instance_valid(_mount):
		_mount.visible = _trolling_activity_visible or (visual_state != VisualState.IDLE and _presentation_method != "boat_fishing")


static func get_trolling_audio_loop_targets(state: int, reel_spin_speed_radians_per_second: float) -> Dictionary:
	var casting := state == VisualState.CASTING
	var active_fight := state in [VisualState.HOOKED, VisualState.REELING, VisualState.SIMULATING]
	return {
		"line_out": casting,
		"drag": active_fight and reel_spin_speed_radians_per_second < -REEL_AUDIO_DIRECTION_EPSILON,
		"reel_in": active_fight and reel_spin_speed_radians_per_second > REEL_AUDIO_DIRECTION_EPSILON,
	}


static func should_play_trolling_splash(source: int, phase: int, current_stage: String, previous_stage: String, already_played: bool) -> bool:
	return (
		source in [PresentationSource.REAL_CATCH, PresentationSource.DEBUG_SIMULATION]
		and phase == PresentationPhase.SURFACE_LANDING
		and current_stage == "LIFTING"
		and previous_stage != "LIFTING"
		and not already_played
	)


static func should_play_trolling_catch_presentation_audio(source: int, already_played: bool) -> bool:
	return source in [PresentationSource.REAL_CATCH, PresentationSource.DEBUG_SIMULATION] and not already_played


func _get_presentation_audio_key() -> String:
	if _pending != null:
		return _pending.catch_id
	if presentation_source == PresentationSource.DEBUG_SIMULATION:
		return "debug:%s:%d" % [_presentation_species_id, _presentation_seed]
	return ""


func get_trolling_audio_diagnostics() -> Dictionary:
	var loops := {}
	for key in TROLLING_LOOP_VOLUME_DB.keys():
		var player := _trolling_audio_players.get(key) as AudioStreamPlayer
		var stream := player.stream as AudioStreamWAV if player != null else null
		loops[key] = {
			"playing": player.playing if player != null else false,
			"requested": bool(_trolling_audio_loop_active.get(key, false)),
			"target": float(_trolling_audio_loop_target.get(key, 0.0)) > 0.5,
			"gain": float(_trolling_audio_loop_gain.get(key, 0.0)),
			"loop_end_samples": stream.loop_end if stream != null else -1,
			"sample_count": roundi(stream.get_length() * float(stream.mix_rate)) if stream != null else 0,
		}
	var one_shots := {}
	for key in TROLLING_ONE_SHOT_VOLUME_DB.keys():
		var player := _trolling_audio_players.get(key) as AudioStreamPlayer
		one_shots[key] = player.playing if player != null else false
	return {
		"available": not _trolling_audio_players.is_empty(),
		"loops": loops,
		"one_shots": one_shots,
		"external_loop_requests": _external_fishing_audio_loops.duplicate(true),
		"shared_event_counts": _shared_fishing_audio_event_counts.duplicate(true),
		"reel_spin_speed_rad_s": _reel_spin_speed_for_audio,
		"line_length_m": _line_distance_m,
		"line_state": _last_line_state,
		"ambience_duck_active": not _trolling_ambience_bus_states.is_empty(),
	}


func _create_trolling_audio_players() -> void:
	if OS.has_feature("dedicated_server") or DisplayServer.get_name().to_lower() == "headless":
		return
	_ensure_fishing_sfx_bus()
	for key in TROLLING_AUDIO_PATHS.keys():
		var source := load(str(TROLLING_AUDIO_PATHS[key])) as AudioStream
		if source == null:
			push_warning("FishingRodSystem could not load trolling sound '%s'." % str(TROLLING_AUDIO_PATHS[key]))
			continue
		var player := AudioStreamPlayer.new()
		player.name = "TrollingSfx_%s" % key
		player.bus = "SFX"
		if TROLLING_LOOP_VOLUME_DB.has(key):
			var loop_stream := _make_trolling_loop_stream(source)
			if loop_stream == null:
				player.queue_free()
				continue
			player.stream = loop_stream
			player.volume_db = -80.0
			_trolling_audio_loop_active[key] = false
			_trolling_audio_loop_gain[key] = 0.0
			_trolling_audio_loop_target[key] = 0.0
		else:
			player.stream = source
			player.volume_db = float(TROLLING_ONE_SHOT_VOLUME_DB.get(key, 0.0))
		add_child(player)
		_trolling_audio_players[key] = player
	var flex_sound := load(BOAT_FISH_FLEX_SOUND) as AudioStream
	if flex_sound != null:
		for index in range(3):
			var player := AudioStreamPlayer.new()
			player.name = "BoatFishFlex%d" % index
			player.bus = "SFX"
			player.stream = flex_sound
			add_child(player)
			_boat_fish_flex_players.append(player)


func _ensure_fishing_sfx_bus() -> void:
	var bus_index := AudioServer.get_bus_index("SFX")
	if bus_index >= 0:
		return
	AudioServer.add_bus()
	bus_index = AudioServer.get_bus_count() - 1
	AudioServer.set_bus_name(bus_index, "SFX")
	AudioServer.set_bus_send(bus_index, "Master")


func _make_trolling_loop_stream(source: AudioStream) -> AudioStream:
	var stream := source.duplicate(true) as AudioStream
	if stream is AudioStreamWAV:
		var wav_stream := stream as AudioStreamWAV
		var sample_count := roundi(wav_stream.get_length() * float(wav_stream.mix_rate))
		if sample_count <= 1:
			push_warning("FishingRodSystem cannot loop an empty trolling sound '%s'." % source.resource_path)
			return null
		wav_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav_stream.loop_begin = 0
		# AudioStreamWAV loop_end is a sample-frame index. Zero produces an
		# empty loop region, which left looped reel sounds inaudible while the
		# same source worked as a one-shot.
		wav_stream.loop_end = sample_count
		return stream
	push_warning("FishingRodSystem cannot loop unsupported trolling sound type '%s'." % source.get_class())
	return null


func _sync_trolling_loop_audio(delta: float, force_silent: bool = false) -> void:
	var targets := {} if force_silent else get_trolling_audio_loop_targets(int(visual_state), _reel_spin_speed_for_audio)
	var external_intensities := {}
	if not force_silent:
		for owner_id_variant in _external_fishing_audio_loops.keys():
			var owner_requests_variant = _external_fishing_audio_loops[owner_id_variant]
			var owner_requests: Dictionary = owner_requests_variant
			var owner_intensities: Dictionary = _external_fishing_audio_intensities.get(owner_id_variant, {})
			for key_variant in owner_requests.keys():
				var key := str(key_variant)
				if bool(owner_requests[key]) and targets.has(key):
					targets[key] = true
					external_intensities[key] = maxf(float(external_intensities.get(key, 0.0)), float(owner_intensities.get(key, 1.0)))
	var trolling_targets := get_trolling_audio_loop_targets(int(visual_state), _reel_spin_speed_for_audio)
	for key in TROLLING_LOOP_VOLUME_DB.keys():
		var key_string := str(key)
		# Apply speed-sensitive volume only when this loop is requested by an
		# external activity and trolling itself is not driving the same loop.
		var external_only: bool = external_intensities.has(key_string) and not bool(trolling_targets.get(key_string, false))
		_external_loop_volume_scale[key_string] = lerpf(0.72, 1.15, float(external_intensities.get(key_string, 0.0))) if external_only else 1.0
		_set_trolling_loop_target(key_string, bool(targets.get(key, false)))
		_advance_trolling_loop_fade(key_string, delta)
	_update_trolling_ambience_ducking(_has_trolling_audio_playback(), delta)


func _has_trolling_audio_playback() -> bool:
	for player_variant in _trolling_audio_players.values():
		var player := player_variant as AudioStreamPlayer
		if player != null and player.playing:
			return true
	return false


func _update_trolling_ambience_ducking(duck_active: bool, delta: float) -> void:
	if not duck_active and _trolling_ambience_bus_states.is_empty():
		return
	var fade_weight := 1.0 - exp(-maxf(delta, 0.0) / TROLLING_AMBIENCE_DUCK_FADE_SECONDS)
	for bus_name_variant in TROLLING_AMBIENCE_DUCK_DB.keys():
		var bus_name := str(bus_name_variant)
		var bus_index := AudioServer.get_bus_index(bus_name)
		if bus_index < 0:
			continue
		if duck_active and not _trolling_ambience_bus_states.has(bus_name):
			var initial_db := AudioServer.get_bus_volume_db(bus_index)
			_trolling_ambience_bus_states[bus_name] = {
				"base_db": initial_db,
				"last_applied_db": initial_db,
			}
		if not _trolling_ambience_bus_states.has(bus_name):
			continue
		var state: Dictionary = _trolling_ambience_bus_states[bus_name]
		var current_db := AudioServer.get_bus_volume_db(bus_index)
		if absf(current_db - float(state.get("last_applied_db", current_db))) > 0.25:
			state["base_db"] = current_db
		var base_db := float(state.get("base_db", current_db))
		var target_db := base_db - float(TROLLING_AMBIENCE_DUCK_DB[bus_name]) if duck_active else base_db
		var applied_db := lerpf(current_db, target_db, fade_weight)
		if not duck_active and absf(applied_db - target_db) < 0.1:
			applied_db = target_db
		AudioServer.set_bus_volume_db(bus_index, applied_db)
		state["last_applied_db"] = applied_db
		if not duck_active and is_equal_approx(applied_db, base_db):
			_trolling_ambience_bus_states.erase(bus_name)
		else:
			_trolling_ambience_bus_states[bus_name] = state


func _set_reel_spin(speed_radians_per_second: float) -> void:
	_reel_spin_speed_for_audio = speed_radians_per_second if is_finite(speed_radians_per_second) else 0.0
	if _rig != null and is_instance_valid(_rig):
		_rig.set_reel_spin(_reel_spin_speed_for_audio)


func _set_trolling_loop_target(key: String, active: bool) -> void:
	if not _trolling_audio_players.has(key):
		return
	var player := _trolling_audio_players[key] as AudioStreamPlayer
	if player == null:
		return
	if active and not bool(_trolling_audio_loop_active.get(key, false)):
		_trolling_audio_loop_active[key] = true
		if not player.playing:
			player.volume_db = -80.0
			player.play()
	_trolling_audio_loop_target[key] = 1.0 if active else 0.0


func _advance_trolling_loop_fade(key: String, delta: float) -> void:
	if not _trolling_audio_players.has(key):
		return
	var player := _trolling_audio_players[key] as AudioStreamPlayer
	if player == null:
		return
	var current := float(_trolling_audio_loop_gain.get(key, 0.0))
	var target := float(_trolling_audio_loop_target.get(key, 0.0))
	var step := maxf(delta, 0.0) / TROLLING_AUDIO_FADE_SECONDS
	current = move_toward(current, target, step)
	_trolling_audio_loop_gain[key] = current
	var target_db := float(TROLLING_LOOP_VOLUME_DB.get(key, 0.0))
	var volume_scale := maxf(0.01, float(_external_loop_volume_scale.get(key, 1.0)))
	player.volume_db = linear_to_db(current * volume_scale) + target_db if current > 0.0001 else -80.0
	if target <= 0.0 and current <= 0.0001:
		player.stop()
		_trolling_audio_loop_active[key] = false


func _play_trolling_one_shot(key: String) -> void:
	var player := _trolling_audio_players.get(key) as AudioStreamPlayer
	if player == null:
		return
	player.stop()
	player.volume_db = float(TROLLING_ONE_SHOT_VOLUME_DB.get(key, 0.0))
	player.play()


func _request_all_trolling_loops_stop() -> void:
	for key in TROLLING_LOOP_VOLUME_DB.keys():
		_trolling_audio_loop_target[str(key)] = 0.0


func _stop_all_trolling_audio() -> void:
	_external_fishing_audio_loops.clear()
	_external_fishing_audio_intensities.clear()
	_external_loop_volume_scale.clear()
	for player_variant in _trolling_audio_players.values():
		var player := player_variant as AudioStreamPlayer
		if player != null:
			player.stop()
	for key in TROLLING_LOOP_VOLUME_DB.keys():
		_trolling_audio_loop_active[str(key)] = false
		_trolling_audio_loop_gain[str(key)] = 0.0
		_trolling_audio_loop_target[str(key)] = 0.0
	_update_trolling_ambience_ducking(false, 1.0)


func _find_fight_profile(species_id: String) -> FishingFightProfile:
	for profile in fight_profiles:
		if profile != null and profile.species_id == species_id:
			return profile
	return null


func _normal_fight_duration() -> float:
	return _hook_and_struggle_duration() + progressive_retrieval_seconds + surface_landing_seconds


func _hook_and_struggle_duration() -> float:
	return hook_strike_seconds + fish_struggle_seconds


func _clear_presentation() -> void:
	catch_display_updated.emit({"visible": false})
	var was_debug_simulation := presentation_source == PresentationSource.DEBUG_SIMULATION
	_pending = null
	_catch_result = null
	presentation_source = PresentationSource.NONE
	if was_debug_simulation and _encounter != null:
		_encounter.set_debug_presentation_paused(false)
	_presentation_species_id = ""
	_presentation_method = "trolling"
	_success_audio_played_for_presentation = false
	_presentation_length_m = 0.0
	_presentation_weight_kg = 0.0
	_presentation_seed = 0
	_simulation_time_scale = 1.0
	_simulation_paused = false
	_simulation_resume_trolling = false
	_fight_profile = null
	_fight_elapsed = 0.0
	_presentation_elapsed = 0.0
	_line_distance_m = 0.0
	_set_reel_spin(0.0)
	_retrieval_started_catch_id = ""
	_struggle_pulse_triggered.clear()
	_splash_pulse_triggered.clear()
	_settlement_requested = false
	_set_presentation_phase(PresentationPhase.NONE)
	if _camera_rig != null:
		_camera_rig.set_fight_camera_focus_progress(0.0)
	_last_line_state = "OUT"
	_last_fish_stage = "HIDDEN"
	if _rig != null:
		_rig.reset_presentation_animation()
		_rig.clear_catch_visual()
		_rig.set_presentation_clock(1.0, false)
		_rig.set_line_active(false)
	_release_camera()


func _update_rod_load(load_ratio: float) -> void:
	if _rig != null:
		_rig.set_rod_load(load_ratio)


func _clear_visuals() -> void:
	if _rig != null and is_instance_valid(_rig):
		_rig.clear_catch_visual()
	if _mount != null and is_instance_valid(_mount):
		_mount.queue_free()
	_rig = null
	_mount = null
	_active_visual_root = null


func _finish_presentation() -> void:
	var settled_trolling_catch := _pending != null and _pending.fishing_method == "trolling"
	_clear_presentation()
	if settled_trolling_catch and _encounter != null and _encounter.state == FishingEncounterSystem.State.SETTLED:
		_encounter.start_trolling()
	_set_visual_state(VisualState.TROLLING if _encounter != null and _encounter.state == FishingEncounterSystem.State.TROLLING else VisualState.IDLE)
	if _rig != null:
		_rig.set_line_active(visual_state == VisualState.TROLLING)
		_rig.set_rod_load(0.12 if visual_state == VisualState.TROLLING else 0.0)


func _finish_simulation() -> void:
	if presentation_source != PresentationSource.DEBUG_SIMULATION:
		return
	var pending_to_resume := _queued_real_pending
	if pending_to_resume == null and _encounter != null:
		pending_to_resume = _encounter.pending_catch
	_queued_real_pending = null
	_clear_presentation()
	if pending_to_resume != null and _encounter != null and _encounter.pending_catch != null and _encounter.pending_catch.catch_id == pending_to_resume.catch_id:
		_begin_real_presentation(pending_to_resume)
		return
	var encounter_trolling := _encounter != null and _encounter.state == FishingEncounterSystem.State.TROLLING
	_set_visual_state(VisualState.TROLLING if encounter_trolling else VisualState.IDLE)
	if _rig != null:
		_rig.set_line_active(encounter_trolling)
		_rig.set_rod_load(0.12 if encounter_trolling else 0.0)


func _has_active_presentation() -> bool:
	return presentation_source != PresentationSource.NONE and not _presentation_species_id.is_empty() and _presentation_length_m > 0.0


func _release_camera() -> void:
	if _camera_rig != null:
		_camera_rig.end_fight_camera()
