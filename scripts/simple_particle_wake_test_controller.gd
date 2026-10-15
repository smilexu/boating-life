extends Node3D

## Test-only comparison harness. It reuses the production boat, water, sky,
## WaveSampler and camera without changing the production Main scene.

enum WakeMode { OFF, GPU_PARTICLES }

const SPEED_PRESETS := {"STOP": 0.0, "LOW": 2.0, "CRUISE": 7.0, "FAST": 12.0}
const MODE_NAMES := ["OFF", "GPU PARTICLES"]
const BENCHMARK_WARMUP_SECONDS := 3.0
const BENCHMARK_SAMPLE_SECONDS := 5.0
const BENCHMARK_QUALITY_NAMES := ["画质优先", "平衡", "性能优先"]
const BENCHMARK_CLOUD_STATES := [true, false]
const BENCHMARK_WAKE_STATES := [false, true]
const STATE_CHECKS := [
	{"name": "STOP", "duration": 5.0},
	{"name": "LOW", "duration": 4.0},
	{"name": "CRUISE", "duration": 4.0},
	{"name": "FAST", "duration": 4.0},
	{"name": "S_TURN", "duration": 8.0},
	{"name": "STOP_FADE", "duration": 5.0},
]

@export_node_path("Node3D") var boat_controller_path := NodePath("Main/PlayerBoat/MotionRoot")
@export_node_path("Node3D") var boat_camera_path := NodePath("Main/PlayerBoat/FollowCameraRig/Camera3D")
@export_node_path("Node") var particle_wake_manager_path := NodePath("ParticleWakeManager")

var _boat: BoatController
var _boat_camera: Camera3D
var _particle_wake: Node
var _quality_manager: Node
var _overhead_camera: Camera3D
var _panel_label: Label
var _selected_state := "CRUISE"
var _wake_mode := WakeMode.GPU_PARTICLES
var _s_turn_enabled := false
var _s_turn_time := 0.0
var _s_turn_base_yaw := 0.0
var _overhead_view_enabled := false
var _ui_elapsed := 0.0
var _measured_speed_mps := 0.0
var _last_boat_position := Vector3.ZERO
var _benchmark_active := false
var _benchmark_case_index := -1
var _benchmark_cases: Array[Dictionary] = []
var _benchmark_original_quality := 0
var _benchmark_original_clouds_enabled := true
var _benchmark_warmup_elapsed := 0.0
var _benchmark_sample_elapsed := 0.0
var _benchmark_frames := 0
var _benchmark_delta_sum := 0.0
var _benchmark_draw_calls_sum := 0.0
var _benchmark_min_frame_ms := INF
var _benchmark_max_frame_ms := 0.0
var _benchmark_started_at_msec := 0
var _state_check_active := false
var _state_check_index := -1
var _state_check_elapsed := 0.0
var _start_position := Vector3.ZERO
var _start_rotation := Vector3.ZERO


func _ready() -> void:
	process_priority = 100
	_boat = get_node_or_null(boat_controller_path) as BoatController
	_boat_camera = get_node_or_null(boat_camera_path) as Camera3D
	_particle_wake = get_node_or_null(particle_wake_manager_path)
	_quality_manager = get_node_or_null("Main/QualityManager")
	if _boat == null or _boat_camera == null or _particle_wake == null or _quality_manager == null:
		push_error("SimpleParticleWake is missing a boat, camera, quality manager, or particle wake reference.")
		return
	_start_position = _boat.global_position
	_start_rotation = _boat.global_rotation
	_last_boat_position = _boat.global_position
	_create_overhead_camera()
	_create_panel()
	select_speed_state("CRUISE")
	var user_arguments := OS.get_cmdline_user_args()
	if user_arguments.has("--display-probe"):
		print("DISPLAY_PROBE %s" % str(_quality_manager.call("get_render_metrics")))
		get_tree().quit()
		return
	if user_arguments.has("--display-benchmark"):
		_start_automated_benchmark()
	elif user_arguments.has("--wake-state-check"):
		_set_wake_mode(WakeMode.GPU_PARTICLES)
		_start_state_check()
	else:
		_set_wake_mode(WakeMode.GPU_PARTICLES)
	_update_panel()


func _process(delta: float) -> void:
	if _boat == null:
		return
	_boat.is_autopilot = false
	_boat.is_motion_paused = false
	_boat.speed_mps = float(SPEED_PRESETS[_selected_state])
	if _s_turn_enabled:
		_s_turn_time += delta
		var phase := TAU * _s_turn_time / 16.0
		_boat.rotation.y = _s_turn_base_yaw + deg_to_rad(32.0) * sin(phase)

	var movement := _boat.global_position - _last_boat_position
	_last_boat_position = _boat.global_position
	movement.y = 0.0
	_measured_speed_mps = movement.length() / maxf(delta, 0.0001)
	if _overhead_view_enabled:
		_update_overhead_camera()
	if _benchmark_active:
		_update_benchmark(delta)
	if _state_check_active:
		_update_state_check(delta)

	_ui_elapsed += delta
	if _ui_elapsed >= 0.5:
		_ui_elapsed = fposmod(_ui_elapsed, 0.5)
		_update_panel()


func _unhandled_key_input(event: InputEvent) -> void:
	if _benchmark_active or not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_F6:
			_s_turn_enabled = false
			select_speed_state("STOP")
		KEY_F7:
			_s_turn_enabled = false
			select_speed_state("LOW")
		KEY_F8:
			_s_turn_enabled = false
			select_speed_state("CRUISE")
		KEY_F9:
			_s_turn_enabled = false
			select_speed_state("FAST")
		KEY_F10, KEY_V:
			_toggle_s_turn()
		KEY_F11, KEY_K:
			_set_wake_mode((_wake_mode + 1) % MODE_NAMES.size())
		KEY_F12, KEY_O:
			_toggle_camera_view()
		_:
			return
	get_viewport().set_input_as_handled()
	_update_panel()


func select_speed_state(state_name: String) -> void:
	var normalized := state_name.to_upper()
	if not SPEED_PRESETS.has(normalized):
		push_warning("Unknown simple particle wake state: %s" % state_name)
		return
	_selected_state = normalized
	if _boat != null:
		_boat.speed_mps = float(SPEED_PRESETS[normalized])
	_update_panel()


func _set_wake_mode(mode: int) -> void:
	_wake_mode = clampi(mode, WakeMode.OFF, WakeMode.GPU_PARTICLES)
	_particle_wake.call("set_wake_active", _wake_mode == WakeMode.GPU_PARTICLES)
	_update_panel()


func _toggle_s_turn() -> void:
	_s_turn_enabled = not _s_turn_enabled
	if _s_turn_enabled:
		_selected_state = "CRUISE"
		_s_turn_time = 0.0
		_s_turn_base_yaw = _boat.rotation.y
		_boat.is_autopilot = false
		_boat.is_motion_paused = false
		_boat.speed_mps = float(SPEED_PRESETS[_selected_state])
	_update_panel()


func _toggle_camera_view() -> void:
	_overhead_view_enabled = not _overhead_view_enabled
	if _overhead_view_enabled:
		_update_overhead_camera()
		_overhead_camera.make_current()
	else:
		_boat_camera.make_current()
	_update_panel()


func _create_overhead_camera() -> void:
	_overhead_camera = Camera3D.new()
	_overhead_camera.name = "SimpleWakeOverheadCamera"
	_overhead_camera.fov = 58.0
	_overhead_camera.near = 0.1
	_overhead_camera.far = 2000.0
	_overhead_camera.current = false
	add_child(_overhead_camera)


func _update_overhead_camera() -> void:
	if _overhead_camera == null or _boat == null:
		return
	var aft_direction := _boat.global_transform.basis.z.normalized()
	var focus := _boat.global_position + Vector3.UP * 0.8
	_overhead_camera.global_position = focus + Vector3.UP * 32.0 + aft_direction * 26.0
	_overhead_camera.look_at(focus, Vector3.UP)


func _create_panel() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "SimpleParticleWakeOverlay"
	canvas.layer = 15
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.offset_left = -510.0
	panel.offset_top = 24.0
	panel.offset_right = -24.0
	panel.offset_bottom = 274.0
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.09, 0.13, 0.91)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", style)
	canvas.add_child(panel)
	_panel_label = Label.new()
	_panel_label.add_theme_color_override("font_color", Color(0.91, 0.96, 0.94, 1.0))
	_panel_label.add_theme_font_size_override("font_size", 14)
	_panel_label.add_theme_constant_override("line_spacing", 2)
	_panel_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(_panel_label)


func _update_panel() -> void:
	if _panel_label == null:
		return
	var target_speed := float(SPEED_PRESETS[_selected_state])
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / float(fps) if fps > 0 else 0.0
	var particles := int(_particle_wake.call("get_estimated_steady_state_particle_count"))
	var particle_capacity := int(_particle_wake.call("get_particle_capacity"))
	var emission_ratio := float(_particle_wake.call("get_emission_ratio"))
	var lifetime_range: Vector2 = _particle_wake.call("get_lifetime_range_seconds")
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var view_text := "tilted top-down" if _overhead_view_enabled else "stern follow"
	var mode_text: String = str(MODE_NAMES[_wake_mode])
	var fps_text := "--" if fps <= 0 else str(fps)
	var particle_text := "steady est. %d / %d cap (%.2f ratio)" % [particles, particle_capacity, emission_ratio]
	if _wake_mode != WakeMode.GPU_PARTICLES:
		particle_text = "0 rendered / %d cap" % particle_capacity
	_panel_label.text = (
		"GPU PARTICLE WAKE / DISPLAY TEST\n"
		+ "F6 Stop · F7 Low 2 · F8 Cruise 7 · F9 Fast 12 m/s\n"
		+ "F10/V S-turn · F11/K OFF / GPU particles\n"
		+ "F12/O camera: stern / tilted top-down\n"
		+ "Mode: %s · Speed target %.1f / measured %.2f m/s · View: %s\n"
		+ "Particles: %s · persistence %.1f s\n"
		+ "FPS: %s · frame interval %.2f ms · Draw Calls %d"
	) % [mode_text, target_speed, _measured_speed_mps, view_text, particle_text, lifetime_range.x, fps_text, frame_ms, draw_calls]


func _start_automated_benchmark() -> void:
	_benchmark_active = true
	var user_arguments := OS.get_cmdline_user_args()
	if user_arguments.has("--display-benchmark-windowed"):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(1920, 1080))
		await get_tree().process_frame
	elif user_arguments.has("--display-benchmark-3440-windowed"):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		if DisplayServer.get_screen_count() > 1:
			DisplayServer.window_set_current_screen(1)
		DisplayServer.window_set_size(Vector2i(3440, 1440))
		await get_tree().process_frame
	else:
		var requested_screen := -1
		for argument in user_arguments:
			if str(argument).begins_with("--display-benchmark-screen="):
				requested_screen = int(str(argument).get_slice("=", 1))
		if requested_screen >= 0 and requested_screen < DisplayServer.get_screen_count():
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_current_screen(requested_screen)
			await get_tree().process_frame
			if user_arguments.has("--display-benchmark-fullscreen"):
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
				await get_tree().process_frame
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_benchmark_original_quality = int(_quality_manager.call("get_quality_index"))
	_benchmark_original_clouds_enabled = bool(_quality_manager.call("get_clouds_enabled"))
	_benchmark_started_at_msec = Time.get_ticks_msec()
	_benchmark_cases.clear()
	for quality_index in range(BENCHMARK_QUALITY_NAMES.size()):
		for clouds_enabled in BENCHMARK_CLOUD_STATES:
			for wake_enabled in BENCHMARK_WAKE_STATES:
				_benchmark_cases.append({
					"quality": quality_index,
					"clouds": clouds_enabled,
					"wake": wake_enabled,
				})
	var metrics: Dictionary = _quality_manager.call("get_render_metrics")
	print(
		"DISPLAY_BENCH_SETUP window_px=%s viewport_px=%s screen_px=%s screens=%s refresh_hz=%.1f screen_scale=%.2f hidpi=%s internal_3d_estimate=%s adapter=%s processor=%s fullscreen=%s vsync=%d max_fps=%d cases=%d"
		% [str(metrics["window_px"]), str(metrics["viewport_px"]), str(metrics["screen_px"]), str(metrics["screens"]), float(metrics["refresh_hz"]), float(metrics["screen_scale"]), str(metrics["hidpi_enabled"]), str(metrics["internal_3d_px_estimate"]), str(metrics["adapter"]), str(metrics["processor"]), str(metrics["fullscreen"]), int(metrics["vsync"]), Engine.max_fps, _benchmark_cases.size()]
	)
	_benchmark_case_index = 0
	_start_benchmark_case()


func _start_benchmark_case() -> void:
	if _benchmark_case_index >= _benchmark_cases.size():
		_quality_manager.call("set_clouds_enabled", _benchmark_original_clouds_enabled)
		_quality_manager.call("set_quality_for_benchmark", _benchmark_original_quality)
		print("DISPLAY_BENCH_COMPLETE cases=%d total_seconds=%.2f" % [_benchmark_cases.size(), float(Time.get_ticks_msec() - _benchmark_started_at_msec) / 1000.0])
		get_tree().quit()
		return
	var current_case: Dictionary = _benchmark_cases[_benchmark_case_index]
	var quality_index := int(current_case["quality"])
	var clouds_enabled := bool(current_case["clouds"])
	var wake_enabled := bool(current_case["wake"])
	_quality_manager.call("set_quality_for_benchmark", quality_index)
	_quality_manager.call("set_clouds_enabled", clouds_enabled)
	_set_wake_mode(WakeMode.GPU_PARTICLES if wake_enabled else WakeMode.OFF)
	_boat.global_position = _start_position
	_boat.global_rotation = _start_rotation
	_boat.speed_mps = float(SPEED_PRESETS["CRUISE"])
	_selected_state = "CRUISE"
	_s_turn_enabled = false
	_last_boat_position = _boat.global_position
	_benchmark_warmup_elapsed = 0.0
	_benchmark_sample_elapsed = 0.0
	_benchmark_frames = 0
	_benchmark_delta_sum = 0.0
	_benchmark_draw_calls_sum = 0.0
	_benchmark_min_frame_ms = INF
	_benchmark_max_frame_ms = 0.0
	print("DISPLAY_BENCH_BEGIN quality=%s scale=%.2f clouds=%s wake=%s speed_mps=7.0 warmup_s=%.1f sample_s=%.1f" % [BENCHMARK_QUALITY_NAMES[quality_index], float(_quality_manager.call("get_resolution_scale")), "on" if clouds_enabled else "off", "gpu" if wake_enabled else "off", BENCHMARK_WARMUP_SECONDS, BENCHMARK_SAMPLE_SECONDS])


func _update_benchmark(delta: float) -> void:
	if _benchmark_sample_elapsed <= 0.0:
		_benchmark_warmup_elapsed += delta
		if _benchmark_warmup_elapsed >= BENCHMARK_WARMUP_SECONDS:
			_benchmark_sample_elapsed = 0.000001
		return
	_benchmark_sample_elapsed += delta
	_benchmark_delta_sum += delta
	_benchmark_frames += 1
	var frame_ms := delta * 1000.0
	_benchmark_min_frame_ms = minf(_benchmark_min_frame_ms, frame_ms)
	_benchmark_max_frame_ms = maxf(_benchmark_max_frame_ms, frame_ms)
	_benchmark_draw_calls_sum += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	if _benchmark_sample_elapsed >= BENCHMARK_SAMPLE_SECONDS:
		_finish_benchmark_case()


func _finish_benchmark_case() -> void:
	var average_fps := float(_benchmark_frames) / maxf(_benchmark_delta_sum, 0.0001)
	var average_frame_ms := _benchmark_delta_sum * 1000.0 / maxf(float(_benchmark_frames), 1.0)
	var average_draw_calls := _benchmark_draw_calls_sum / maxf(float(_benchmark_frames), 1.0)
	var estimated_particles := int(_particle_wake.call("get_estimated_steady_state_particle_count")) if bool(_benchmark_cases[_benchmark_case_index]["wake"]) else 0
	var metrics: Dictionary = _quality_manager.call("get_render_metrics")
	print(
		"DISPLAY_BENCH_RESULT quality=%s scale=%.2f clouds=%s wake=%s output_px=%s viewport_px=%s internal_3d_estimate=%s upscaler=%s vsync=%d max_fps=%d samples=%d avg_fps=%.2f avg_frame_ms=%.3f min_frame_ms=%.3f max_frame_ms=%.3f avg_draw_calls=%.1f estimated_particles=%d particle_capacity=%d gpu_ms=unavailable"
		% [BENCHMARK_QUALITY_NAMES[int(_benchmark_cases[_benchmark_case_index]["quality"])], float(metrics["resolution_scale"]), "on" if bool(_benchmark_cases[_benchmark_case_index]["clouds"]) else "off", "gpu" if bool(_benchmark_cases[_benchmark_case_index]["wake"]) else "off", str(metrics["window_px"]), str(metrics["viewport_px"]), str(metrics["internal_3d_px_estimate"]), str(metrics["upscaler"]), int(metrics["vsync"]), Engine.max_fps, _benchmark_frames, average_fps, average_frame_ms, _benchmark_min_frame_ms, _benchmark_max_frame_ms, average_draw_calls, estimated_particles, int(_particle_wake.call("get_particle_capacity"))]
	)
	_benchmark_case_index += 1
	_start_benchmark_case()


func _start_state_check() -> void:
	_state_check_active = true
	_state_check_index = 0
	_begin_state_check_stage()


func _begin_state_check_stage() -> void:
	if _state_check_index >= STATE_CHECKS.size():
		print("WAKE_STATE_CHECK_COMPLETE stages=%d" % STATE_CHECKS.size())
		get_tree().quit()
		return
	var stage: Dictionary = STATE_CHECKS[_state_check_index]
	var stage_name := str(stage["name"])
	_s_turn_enabled = stage_name == "S_TURN"
	if stage_name == "S_TURN":
		_selected_state = "CRUISE"
		_s_turn_time = 0.0
		_s_turn_base_yaw = _boat.rotation.y
	else:
		select_speed_state("STOP" if stage_name == "STOP_FADE" else stage_name)
	_state_check_elapsed = 0.0
	print("WAKE_STATE_BEGIN name=%s duration_s=%.1f" % [stage_name, float(stage["duration"])])


func _update_state_check(delta: float) -> void:
	_state_check_elapsed += delta
	var stage: Dictionary = STATE_CHECKS[_state_check_index]
	if _state_check_elapsed >= float(stage["duration"]):
		print(
			"WAKE_STATE_RESULT name=%s actual_speed_mps=%.2f emission_ratio=%.3f estimated_steady_particles=%d capacity=%d"
			% [str(stage["name"]), float(_particle_wake.call("get_measured_speed_mps")), float(_particle_wake.call("get_emission_ratio")), int(_particle_wake.call("get_estimated_steady_state_particle_count")), int(_particle_wake.call("get_particle_capacity"))]
		)
		_state_check_index += 1
		_begin_state_check_stage()
