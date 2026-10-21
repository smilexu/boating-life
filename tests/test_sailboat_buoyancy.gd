extends SceneTree

const BUOYANCY_MATH := preload("res://scripts/sailboat_buoyancy_math.gd")
const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const LAB_PROFILE := preload("res://resources/sailing/sailboat_lab_profile.tres")
const EXTREME_PRESETS := preload("res://scripts/extreme_sea_state_presets.gd")
const TEST_MASS_KG := 3200.0
const GRAVITY_MPS2 := 9.8
const FLOAT_POINT_COUNT := 4

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_point_force_rules()
	_test_static_equilibrium()
	_test_symmetric_restoring_torque()
	_test_profile_float_point_symmetry()
	_test_invalid_values()
	await _test_rigidbody_float_and_recovery()
	await _test_wave_sampling_and_dynamic_coupling()
	if _failures.is_empty():
		print("Sailboat buoyancy tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_point_force_rules() -> void:
	var stiffness := BUOYANCY_MATH.equilibrium_spring_stiffness_n_per_m(
		TEST_MASS_KG, GRAVITY_MPS2, 0.20, FLOAT_POINT_COUNT
	)
	var cap := BUOYANCY_MATH.max_point_force_n(TEST_MASS_KG, GRAVITY_MPS2, FLOAT_POINT_COUNT, 1.8)
	_expect(is_zero_approx(BUOYANCY_MATH.point_buoyancy_force_n(0.0, -1.0, stiffness, 1000.0, cap)), "dry float point has zero force, even while moving downward")
	var shallow_force := BUOYANCY_MATH.point_buoyancy_force_n(0.05, 0.0, stiffness, 0.0, cap)
	var deeper_force := BUOYANCY_MATH.point_buoyancy_force_n(0.10, 0.0, stiffness, 0.0, cap)
	_expect(deeper_force > shallow_force, "spring force rises continuously with submergence")
	_expect(absf(deeper_force - shallow_force - stiffness * 0.05) < 0.001, "spring response has no hidden force step below its cap")
	var capped_force := BUOYANCY_MATH.point_buoyancy_force_n(100.0, -10.0, stiffness, 1000.0, cap)
	_expect(capped_force <= cap and is_equal_approx(capped_force, cap), "point force has a finite safety cap")
	var falling_force := BUOYANCY_MATH.point_buoyancy_force_n(0.2, -0.2, stiffness, 1000.0, cap)
	var rising_force := BUOYANCY_MATH.point_buoyancy_force_n(0.2, 0.2, stiffness, 1000.0, cap)
	_expect(falling_force > rising_force, "vertical damping opposes point velocity")
	_expect(is_finite(falling_force) and is_finite(rising_force), "damping force remains finite")
	_expect(
		is_equal_approx(
			BUOYANCY_MATH.critical_point_damping_n_s_per_m(stiffness, TEST_MASS_KG, FLOAT_POINT_COUNT, 0.55),
			2.0 * 0.55 * sqrt(stiffness * TEST_MASS_KG / FLOAT_POINT_COUNT)
		),
		"point damping coefficient follows the configured damping ratio"
	)


func _test_static_equilibrium() -> void:
	var stiffness := BUOYANCY_MATH.equilibrium_spring_stiffness_n_per_m(
		TEST_MASS_KG, GRAVITY_MPS2, 0.20, FLOAT_POINT_COUNT
	)
	var total := 0.0
	for _point in range(FLOAT_POINT_COUNT):
		total += BUOYANCY_MATH.point_buoyancy_force_n(0.20, 0.0, stiffness, 0.0, TEST_MASS_KG * GRAVITY_MPS2)
	_expect(absf(total - TEST_MASS_KG * GRAVITY_MPS2) < 0.01, "four equal float points balance m*g at the configured rest depth")
	_expect(
		BUOYANCY_MATH.equilibrium_spring_stiffness_n_per_m(TEST_MASS_KG, GRAVITY_MPS2, 0.0, 4) == 0.0,
		"invalid zero rest depth produces a safe zero stiffness"
	)


func _test_symmetric_restoring_torque() -> void:
	var offsets := PackedVector3Array([
		Vector3(-0.65, -0.50, -2.4), Vector3(0.65, -0.50, -2.4),
		Vector3(-0.65, -0.50, 2.4), Vector3(0.65, -0.50, 2.4),
	])
	var stiffness := BUOYANCY_MATH.equilibrium_spring_stiffness_n_per_m(TEST_MASS_KG, GRAVITY_MPS2, 0.45, 4)
	var basis := Basis.from_euler(Vector3(0.0, 0.0, deg_to_rad(25.0)))
	var body_origin := Vector3(0.0, 0.05, 0.0)
	var center_of_mass := Vector3(0.0, -0.65, 0.0)
	var torque := Vector3.ZERO
	var left_force := 0.0
	var right_force := 0.0
	for offset in offsets:
		var world_offset: Vector3 = BUOYANCY_MATH.point_offset_world(basis, offset)
		var submergence := maxf(-(body_origin.y + world_offset.y), 0.0)
		var force_y := BUOYANCY_MATH.point_buoyancy_force_n(
			submergence, 0.0, stiffness, 0.0, TEST_MASS_KG * GRAVITY_MPS2
		)
		var center_offset_world: Vector3 = body_origin + basis * center_of_mass
		var point_world := body_origin + world_offset
		var lever_from_com := point_world - center_offset_world
		torque += lever_from_com.cross(Vector3.UP * force_y)
		if offset.x < 0.0:
			left_force += force_y
		else:
			right_force += force_y
	_expect(left_force > right_force, "positive heel submerges the port-side float points more")
	_expect(torque.z < 0.0, "port-starboard buoyancy difference produces a restoring roll moment")
	var mirrored_basis := Basis.from_euler(Vector3(0.0, 0.0, deg_to_rad(-25.0)))
	var mirrored_torque_z := _roll_torque_z(offsets, mirrored_basis, center_of_mass, stiffness)
	_expect(mirrored_torque_z > 0.0, "opposite heel receives the opposite restoring torque")
	_expect(absf(torque.z + mirrored_torque_z) < absf(torque.z) * 0.05, "symmetric float layout produces approximately mirrored restoring moments")


func _roll_torque_z(offsets: PackedVector3Array, basis: Basis, com: Vector3, stiffness: float) -> float:
	var result := 0.0
	var body_origin := Vector3(0.0, 0.05, 0.0)
	var center_offset_world: Vector3 = body_origin + basis * com
	for offset in offsets:
		var world_offset: Vector3 = basis * offset
		var immersion := maxf(-(body_origin.y + world_offset.y), 0.0)
		var force_y := BUOYANCY_MATH.point_buoyancy_force_n(
			immersion, 0.0, stiffness, 0.0, TEST_MASS_KG * GRAVITY_MPS2
		)
		result += (body_origin + world_offset - center_offset_world).cross(Vector3.UP * force_y).z
	return result


func _test_invalid_values() -> void:
	_expect(_buoyancy_zero_for_invalid(), "non-finite input cannot produce a NaN force")
	_expect(BUOYANCY_MATH.max_point_force_n(-1.0, GRAVITY_MPS2, 4, 1.8) == 0.0, "invalid mass safely disables buoyancy cap")
	_expect(BUOYANCY_MATH.equilibrium_spring_stiffness_n_per_m(1.0, 9.8, 0.2, 0, 1.0) == 0.0, "zero float-point count cannot divide by zero")
	var repeat_a := BUOYANCY_MATH.point_buoyancy_force_n(0.14, -0.3, 18000.0, 12000.0, 20000.0)
	var repeat_b := BUOYANCY_MATH.point_buoyancy_force_n(0.14, -0.3, 18000.0, 12000.0, 20000.0)
	_expect(is_equal_approx(repeat_a, repeat_b), "buoyancy result depends only on current physics state, not render FPS")
	_expect(repeat_a == BUOYANCY_MATH.point_buoyancy_force_n(0.14, -0.3, 18000.0, 12000.0, 20000.0), "same fixed-step input produces an identical force independent of frame schedule")


func _test_profile_float_point_symmetry() -> void:
	var offsets: PackedVector3Array = LAB_PROFILE.get("float_point_offsets_m")
	_expect(offsets.size() == FLOAT_POINT_COUNT, "test vessel resource defines exactly four buoyancy points")
	_expect(offsets[0].x == -offsets[1].x and offsets[0].z == offsets[1].z, "forward port and starboard float points are mirrored")
	_expect(offsets[2].x == -offsets[3].x and offsets[2].z == offsets[3].z, "aft port and starboard float points are mirrored")
	_expect(offsets[0].x == offsets[2].x and offsets[1].x == offsets[3].x, "fore and aft stations use matching beam offsets")


func _buoyancy_zero_for_invalid() -> bool:
	return is_zero_approx(BUOYANCY_MATH.point_buoyancy_force_n(INF, 0.0, 100.0, 10.0, 1000.0))


func _test_rigidbody_float_and_recovery() -> void:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	var boat: RigidBody3D = lab.get_node("SailboatBody")
	lab.call("set_dynamic_waves_enabled", false)
	var debug_panel: CanvasLayer = lab.get_node("DebugPanel")
	var tabs := debug_panel.find_child("SailboatDebugTabs", true, false) as TabContainer
	_expect(tabs != null, "new sailboat debug controls are collected in one tab container")
	if tabs != null:
		_expect(tabs.get_tab_count() == 5, "tab container exposes status, attitude, impulse, buoyancy, and wave-coupling pages")
	for _step in range(600):
		await physics_frame
	var neutral_y: float = boat.global_position.y
	var neutral_speed: float = boat.linear_velocity.length()
	var neutral_buoyancy: float = boat.get_debug_snapshot()["buoyancy_total_n"]
	print("[SAILBOAT_LAB] settle y=%.3f m, speed=%.4f m/s, buoyancy=%.1f N, roll=%.2f deg, pitch=%.2f deg" % [
		neutral_y,
		neutral_speed,
		neutral_buoyancy,
		float(boat.get_debug_snapshot()["roll_degrees"]),
		float(boat.get_debug_snapshot()["pitch_degrees"]),
	])
	print("[SAILBOAT_LAB] buoyancy force loop=%d μs per %.4f s fixed physics step" % [
		int(boat.get_debug_snapshot()["force_calculation_usec"]),
		float(boat.get_debug_snapshot()["physics_delta_s"]),
	])
	_expect(absf(neutral_y - 0.05) < 0.08, "body settles close to its calculated calm-water waterline")
	_expect(neutral_speed < 0.08, "unforced test hull settles without self-propelled drift")
	_expect(absf(neutral_buoyancy - TEST_MASS_KG * GRAVITY_MPS2) < TEST_MASS_KG * GRAVITY_MPS2 * 0.08, "runtime buoyancy settles close to its weight")

	var heel_button := _find_button_with_text(lab, "左倾 25° 后释放")
	_expect(heel_button != null, "heel release control exists in the attitude tab")
	if heel_button != null:
		tabs.current_tab = 1
		await process_frame
		_expect(heel_button.is_visible_in_tree(), "heel release control is visible when its tab is selected")
		_expect(heel_button.size.x > 0.0 and heel_button.size.y > 0.0, "heel release control has a clickable layout rect")
		heel_button.pressed.emit()
	await physics_frame
	var initial_heel := absf(float(boat.get_debug_snapshot()["roll_degrees"]))
	_expect(absf(initial_heel - 25.0) < 1.0, "attitude tab button applies the requested 25 degree heel on a physics step")
	_expect(str(boat.get_debug_snapshot()["last_test_action"]).contains("已应用姿态"), "attitude button updates its applied-action feedback")
	for _step in range(14):
		await physics_frame
	var attitude_feedback := lab.find_child("AttitudeFeedback", true, false) as Label
	_expect(
		attitude_feedback != null and attitude_feedback.text.contains("已应用姿态") and attitude_feedback.text.contains("当前：横倾"),
		"attitude panel reports the applied command and live measured angle"
	)
	var heel_after_quarter_second := absf(float(boat.get_debug_snapshot()["roll_degrees"]))
	for _step in range(15):
		await physics_frame
	var heel_after_half_second := absf(float(boat.get_debug_snapshot()["roll_degrees"]))
	for _step in range(30):
		await physics_frame
	var heel_after_one_second := absf(float(boat.get_debug_snapshot()["roll_degrees"]))
	for _step in range(300):
		await physics_frame
	var heel_after_release := absf(float(boat.get_debug_snapshot()["roll_degrees"]))
	print("[SAILBOAT_LAB] heel 25° → %.2f° at 0.25 s → %.2f° at 0.5 s → %.2f° at 1 s → %.2f° at 6 s" % [
		heel_after_quarter_second, heel_after_half_second, heel_after_one_second, heel_after_release,
	])
	_expect(heel_after_release < initial_heel * 0.5, "25 degree heel release moves naturally toward upright")

	boat.call("reset_to_neutral")
	for _step in range(120):
		await physics_frame
	var pitch_button := _find_button_with_text(lab, "船首下俯 18° 后释放")
	_expect(pitch_button != null, "pitch release control exists in the attitude tab")
	if pitch_button != null:
		tabs.current_tab = 1
		await process_frame
		pitch_button.pressed.emit()
	await physics_frame
	var initial_pitch := absf(float(boat.get_debug_snapshot()["pitch_degrees"]))
	_expect(absf(initial_pitch - 18.0) < 1.0, "attitude tab button applies the requested 18 degree pitch on a physics step")
	for _step in range(59):
		await physics_frame
	var pitch_after_one_second := absf(float(boat.get_debug_snapshot()["pitch_degrees"]))
	for _step in range(300):
		await physics_frame
	var pitch_after_release := absf(float(boat.get_debug_snapshot()["pitch_degrees"]))
	print("[SAILBOAT_LAB] pitch 18° → %.2f° at 1 s → %.2f° at 6 s" % [pitch_after_one_second, pitch_after_release])
	_expect(pitch_after_release < 10.0, "18 degree pitch release moves naturally toward level")
	lab.queue_free()
	await process_frame


func _test_wave_sampling_and_dynamic_coupling() -> void:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	var boat: RigidBody3D = lab.get_node("SailboatBody")
	var sampler := lab.get_node("WaveSampler") as WaveSampler
	var camera := lab.get_node("Camera3D") as Camera3D
	lab.call("set_dynamic_waves_enabled", false)
	_expect(
		not (lab.get_node("WaterSurface") as MeshInstance3D).visible
			and (lab.get_node("WaterSurfaceStatic") as MeshInstance3D).visible,
		"still-water mode also displays a flat water plane instead of dynamic waves"
	)
	_expect(sampler != null and sampler.water_material != null, "SailboatLab uses the existing shared water shader and WaveSampler")
	_expect(boat != null and sampler != null, "dynamic-wave lab resolves its rigid body and sampler")
	if boat == null or sampler == null:
		lab.queue_free()
		await process_frame
		return
	boat.call("reset_performance_history")
	for _step in range(240):
		await physics_frame
	var still_metrics: Dictionary = boat.call("get_debug_snapshot")
	print("[SAILBOAT_B2_PERF] still-water 240 steps: total avg/P95=%d/%d μs, wave queries=%d" % [
		int(still_metrics.get("total_physics_calculation_average_usec", 0)),
		int(still_metrics.get("total_physics_calculation_p95_usec", 0)),
		int(still_metrics.get("wave_query_count_per_tick", -1)),
	])
	_expect(int(still_metrics.get("wave_query_count_per_tick", -1)) == 0, "still-water mode performs zero wave queries")

	lab.call("set_dynamic_waves_enabled", true)
	_expect(
		(lab.get_node("WaterSurface") as MeshInstance3D).visible
			and not (lab.get_node("WaterSurfaceStatic") as MeshInstance3D).visible,
		"dynamic-wave mode restores the shared shader-driven water plane"
	)
	var test_position := Vector3(24.0, 0.0, -18.0)
	var sample_time := sampler.get_effective_wave_time_seconds()
	var material := sampler.water_material
	var original_freeze := bool(material.get_shader_parameter("freeze_time"))
	var original_fade_min := float(material.get_shader_parameter("vertex_wave_fade_min"))
	var original_fade_max := float(material.get_shader_parameter("vertex_wave_fade_max"))
	var near_physics: Dictionary = sampler.sample_physics_surface(test_position, sample_time)
	var near_visual: Dictionary = sampler.sample_surface(test_position, sample_time)
	_expect(
		absf(float(near_physics.get("height", 0.0)) - float(near_visual.get("height", 0.0))) < 0.001,
		"near-boat physical and visual samples agree before camera distance fading"
	)
	if camera != null:
		var original_camera_position := camera.global_position
		camera.global_position = Vector3(0.0, 2300.0, 0.0)
		var far_physics: Dictionary = sampler.sample_physics_surface(test_position, sample_time)
		var far_visual: Dictionary = sampler.sample_surface(test_position, sample_time)
		_expect(
			absf(float(far_physics.get("height", 0.0)) - float(near_physics.get("height", 0.0))) < 0.00001,
			"physical wave height is independent of camera position"
		)
		_expect(
			absf(float(far_visual.get("height", 0.0))) < 0.00001,
			"legacy visual sample still applies its far-camera vertex fade"
		)
		camera.global_position = original_camera_position
	else:
		_expect(false, "lab exposes a camera for camera-independence validation")
	material.set_shader_parameter("freeze_time", true)
	var frozen_a: Dictionary = sampler.sample_physics_surface(test_position, 17.0)
	var frozen_b: Dictionary = sampler.sample_physics_surface(test_position, 987.0)
	_expect(
		absf(float(frozen_a.get("height", 0.0)) - float(frozen_b.get("height", 0.0))) < 0.00001
			and is_zero_approx(float(frozen_a.get("vertical_velocity_mps", 1.0))),
		"frozen shader time yields a stable physical sample and zero water phase velocity"
	)
	material.set_shader_parameter("freeze_time", original_freeze)
	material.set_shader_parameter("vertex_wave_fade_min", original_fade_min)
	material.set_shader_parameter("vertex_wave_fade_max", original_fade_max)
	var phase_before_tree_pause := sampler.wave_time_seconds
	paused = true
	for _frame in range(5):
		await process_frame
	var phase_during_tree_pause := sampler.wave_time_seconds
	paused = false
	await process_frame
	_expect(
		is_equal_approx(phase_before_tree_pause, phase_during_tree_pause)
			and sampler.wave_time_seconds > phase_during_tree_pause,
		"global SceneTree pause stops the shared wave clock and resume continues it"
	)

	boat.call("reset_to_neutral")
	lab.call("set_dynamic_waves_enabled", true)
	boat.call("reset_performance_history")
	var min_body_y := INF
	var max_body_y := -INF
	var minimum_sample_range := INF
	for step_index in range(600):
		await physics_frame
		min_body_y = minf(min_body_y, boat.global_position.y)
		max_body_y = maxf(max_body_y, boat.global_position.y)
		if step_index == 599:
			var metrics: Dictionary = boat.call("get_debug_snapshot")
			var heights: PackedFloat32Array = metrics.get("point_water_heights_m", PackedFloat32Array())
			var sample_times: PackedFloat32Array = metrics.get("point_sample_times_seconds", PackedFloat32Array())
			var height_min := INF
			var height_max := -INF
			for height in heights:
				height_min = minf(height_min, height)
				height_max = maxf(height_max, height)
			for point_time in sample_times:
				_expect(is_equal_approx(point_time, float(metrics.get("wave_time_seconds", -1.0))), "four float points use one phase snapshot in the physics tick")
			minimum_sample_range = height_max - height_min
			print("[SAILBOAT_B2_PERF] dynamic normal sea: samples=%d, wave avg/P95=%d/%d μs, total avg/P95=%d/%d μs, queries=%d, boat Y range=%.3f m" % [
				int(metrics.get("performance_sample_count", 0)),
				int(metrics.get("wave_sample_average_usec", 0)),
				int(metrics.get("wave_sample_p95_usec", 0)),
				int(metrics.get("total_physics_calculation_average_usec", 0)),
				int(metrics.get("total_physics_calculation_p95_usec", 0)),
				int(metrics.get("wave_query_count_per_tick", -1)),
				max_body_y - min_body_y,
			])
			_expect(int(metrics.get("wave_query_count_per_tick", -1)) == 4, "dynamic mode issues exactly four full wave queries per physics tick")
			_expect(int(metrics.get("performance_sample_count", 0)) >= 590, "performance metrics use at least 590 stable physics-step samples")
	_expect(max_body_y - min_body_y > 0.04, "rigid body heave responds to the sampled dynamic wave surface")
	_expect(minimum_sample_range > 0.0001, "four separated hull points sample different wave heights")
	_expect(_boat_state_is_finite(boat), "normal dynamic sea keeps rigid body velocities finite")

	for target_height in [5.0, 10.0, 20.0, 30.0]:
		var extreme_settings: SeaWaveSettings = EXTREME_PRESETS.build_settings(sampler.wave_settings, target_height)
		_expect(extreme_settings != null, "existing F3 preset builder supports %.0f m" % target_height)
		if extreme_settings == null:
			continue
		sampler.set_extreme_sea_test(extreme_settings, target_height)
		sampler.set_shallow_wave_constraint_options(true, 30.0, 0.40, 0.20)
		if sampler.is_extreme_sea_test_transitioning():
			sampler.call("_advance_extreme_transition", 2.5)
		boat.call("reset_to_neutral")
		boat.call("reset_performance_history")
		for _step in range(120):
			await physics_frame
		var metrics: Dictionary = boat.call("get_debug_snapshot")
		var point_position: Vector3 = boat.global_transform * LAB_PROFILE.get("float_point_offsets_m")[0]
		var wave_sample: Dictionary = sampler.sample_physics_surface(
			point_position,
			sampler.get_effective_wave_time_seconds()
		)
		var shallow: Dictionary = wave_sample.get("shallow_wave_state", {})
		var amplitude_scale := float(shallow.get("amplitude_scale", -1.0))
		var constrained_scale := float(shallow.get("constrained_amplitude_scale", -1.0))
		_expect(bool(shallow.get("enabled", false)), "%.0f m test activates the existing shallow-wave constraint" % target_height)
		_expect(amplitude_scale >= 0.0 and amplitude_scale <= constrained_scale + 0.00001, "%.0f m test respects the local shallow-water amplitude cap" % target_height)
		_expect(_boat_state_is_finite(boat), "%.0f m test produces no non-finite rigid-body state" % target_height)
		print("[SAILBOAT_B2_PERF] %.0f m test 120 steps: wave avg/P95=%d/%d μs, total avg/P95=%d/%d μs, sample=%d/%d per tick, shallow scale=%.3f, body speed=%.3f m/s" % [
			target_height,
			int(metrics.get("wave_sample_average_usec", 0)),
			int(metrics.get("wave_sample_p95_usec", 0)),
			int(metrics.get("total_physics_calculation_average_usec", 0)),
			int(metrics.get("total_physics_calculation_p95_usec", 0)),
			int(metrics.get("wave_query_count_per_tick", -1)),
			int(metrics.get("float_point_count", 0)),
			amplitude_scale,
			float(metrics.get("linear_speed_mps", INF)),
		])
		_expect(int(metrics.get("wave_query_count_per_tick", -1)) == 4, "%.0f m preset keeps the four-query physics budget" % target_height)

	var beam_button := _find_button_with_text(lab, "10 m 横浪 · 快速观察")
	_expect(beam_button != null, "wave tab exposes a one-click 10 m beam-sea observation setup")
	var original_main_direction := sampler.wave_settings.waves[0].direction_degrees
	if beam_button != null:
		beam_button.pressed.emit()
		var compactness_slider := lab.find_child("WaveCompactness", true, false) as HSlider
		var sharpness_slider := lab.find_child("WaveSharpness", true, false) as HSlider
		var direction_slider := lab.find_child("WaveDirectionOffset", true, false) as HSlider
		_expect(compactness_slider != null and is_equal_approx(compactness_slider.value, 2.5), "beam-sea preset selects the tightest lab wavelength for visible cross-hull sampling")
		_expect(sharpness_slider != null and is_equal_approx(sharpness_slider.value, 0.25), "beam-sea preset applies its modest lab-only horizontal crest shape")
		if sampler.is_extreme_sea_test_transitioning():
			sampler.call("_advance_extreme_transition", 2.5)
		var applied_settings: SeaWaveSettings = sampler.get_effective_wave_settings()
		_expect(applied_settings != null and is_equal_approx(applied_settings.waves[0].frequency, 1.0 / 48.0), "10 m compactness setting changes the primary wavelength/frequency to 48 m")
		_expect(applied_settings != null and is_equal_approx(applied_settings.waves[0].direction_degrees, 90.0), "beam-sea preset points the primary wave phase across the hull")
		_expect(is_equal_approx(sampler.wave_settings.waves[0].direction_degrees, original_main_direction), "lab wave tuning leaves the shared formal wave resource unchanged")
		var profile_label := lab.find_child("WaveProfileDiagnostics", true, false) as Label
		_expect(
			profile_label != null and profile_label.text.contains("传播方位 270°") and profile_label.text.contains("空间频率 0.0208 m⁻¹"),
			"wave diagnostics report actual propagation azimuth and spatial frequency with correct units"
		)
		if direction_slider != null:
			_expect(is_equal_approx(direction_slider.value, 70.0), "beam-sea preset rotates the current 20 degree base profile by 70 degrees")
		boat.call("reset_to_neutral")
		var maximum_side_to_side_height_delta := 0.0
		var maximum_roll_degrees := 0.0
		for _step in range(180):
			await physics_frame
			var beam_metrics: Dictionary = boat.call("get_debug_snapshot")
			maximum_roll_degrees = maxf(maximum_roll_degrees, absf(float(beam_metrics.get("roll_degrees", 0.0))))
			var beam_heights: PackedFloat32Array = beam_metrics.get("point_water_heights_m", PackedFloat32Array())
			if beam_heights.size() >= 4:
				var port_height := (beam_heights[0] + beam_heights[2]) * 0.5
				var starboard_height := (beam_heights[1] + beam_heights[3]) * 0.5
				maximum_side_to_side_height_delta = maxf(
					maximum_side_to_side_height_delta,
					absf(port_height - starboard_height)
				)
		print(
			"[SAILBOAT_B2_TUNING] 10 m beam preset over 180 steps: "
			+ "max port/starboard water-height delta=%.3f m, max hull roll=%.2f°"
			% [maximum_side_to_side_height_delta, maximum_roll_degrees]
		)
		_expect(maximum_side_to_side_height_delta > 0.05, "10 m beam preset creates a measurable port/starboard surface-height difference")
		_expect(maximum_roll_degrees > 1.0, "10 m beam preset produces a measurable hull roll response")
	var wave_points_label := lab.find_child("WavePointDiagnostics", true, false) as Label
	_expect(
		wave_points_label != null and wave_points_label.text.contains("左右水面高差") and wave_points_label.text.contains("前后水面高差"),
		"wave diagnostics show cross-hull and fore-aft sampled height differences"
	)
	sampler.clear_extreme_sea_test()
	lab.queue_free()
	await process_frame


func _boat_state_is_finite(boat: RigidBody3D) -> bool:
	return (
		is_finite(boat.global_position.x)
		and is_finite(boat.global_position.y)
		and is_finite(boat.global_position.z)
		and is_finite(boat.linear_velocity.x)
		and is_finite(boat.linear_velocity.y)
		and is_finite(boat.linear_velocity.z)
		and is_finite(boat.angular_velocity.x)
		and is_finite(boat.angular_velocity.y)
		and is_finite(boat.angular_velocity.z)
	)


func _find_button_with_text(search_root: Node, button_text: String) -> Button:
	for node in search_root.find_children("*", "Button", true, false):
		var button := node as Button
		if button.text == button_text:
			return button
	return null


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("Sailboat buoyancy test failed: %s" % description)
