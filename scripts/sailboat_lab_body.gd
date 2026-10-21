extends RigidBody3D
## Standalone four-point sailboat buoyancy prototype. Not used by the powered boat.

const BUOYANCY_MATH := preload("res://scripts/sailboat_buoyancy_math.gd")
const FLOAT_POINT_COUNT := 4
const PERF_WINDOW_SIZE := 600

@export var profile: Resource
@export_node_path("Node") var wave_sampler_path: NodePath = ^"../WaveSampler"
@export var dynamic_waves_enabled := true
@export_range(-5.0, 5.0, 0.01, "or_greater", "or_less") var water_height_m := 0.0
@export_range(0.0, 2.0, 0.01) var runtime_buoyancy_strength := 1.0
@export_range(0.0, 2.0, 0.01) var runtime_damping_ratio := 0.55

var _float_offsets := PackedVector3Array()
var _wave_sampler: WaveSampler
var _gravity_mps2 := 9.8
var _last_total_buoyancy_n := 0.0
var _last_calculation_usec := 0
var _last_physics_delta := 0.0
var _last_roll_rad := 0.0
var _last_pitch_rad := 0.0
var _last_submerged_count := 0
var _pending_test_transform := Transform3D.IDENTITY
var _test_transform_pending := false
var _last_test_action := "尚无姿态测试"
var _last_wave_time_seconds := 0.0
var _last_wave_query_count := 0
var _last_wave_sample_usec := 0
var _point_water_heights_m := PackedFloat32Array()
var _point_submergences_m := PackedFloat32Array()
var _point_shallow_scales := PackedFloat32Array()
var _point_effective_depths_m := PackedFloat32Array()
var _point_sample_times_seconds := PackedFloat32Array()
var _wave_sample_usec_history := PackedInt64Array()
var _physics_calculation_usec_history := PackedInt64Array()
var _perf_history_count := 0
var _perf_history_cursor := 0


func _ready() -> void:
	if profile == null:
		push_error("SailboatLabBody requires a SailboatLabProfile resource.")
		set_physics_process(false)
		return

	mass = float(profile.get("mass_kg"))
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	var center_offset: Vector3 = profile.get("center_of_mass_m")
	center_of_mass = center_offset
	linear_damp = float(profile.get("linear_damping"))
	angular_damp = float(profile.get("angular_damping"))
	gravity_scale = 1.0
	can_sleep = false
	lock_rotation = false
	_float_offsets = profile.get("float_point_offsets_m")
	if _float_offsets.size() != FLOAT_POINT_COUNT:
		push_error("SailboatLabProfile must contain exactly four float-point offsets.")
		set_physics_process(false)
		return
	_wave_sampler = get_node_or_null(wave_sampler_path) as WaveSampler
	if _wave_sampler == null:
		dynamic_waves_enabled = false
		push_warning("SailboatLabBody: WaveSampler not found; using the S1-B1 still-water mode.")
	_point_water_heights_m.resize(FLOAT_POINT_COUNT)
	_point_submergences_m.resize(FLOAT_POINT_COUNT)
	_point_shallow_scales.resize(FLOAT_POINT_COUNT)
	_point_effective_depths_m.resize(FLOAT_POINT_COUNT)
	_point_sample_times_seconds.resize(FLOAT_POINT_COUNT)
	_wave_sample_usec_history.resize(PERF_WINDOW_SIZE)
	_physics_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_gravity_mps2 = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	reset_to_neutral()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if profile == null or _float_offsets.size() != FLOAT_POINT_COUNT:
		return
	_apply_pending_test_transform(state)

	var start_usec := Time.get_ticks_usec()
	var sample_usec := 0
	var query_count := 0
	var sample_wave_time := 0.0
	if _wave_sampler != null:
		# One shared phase snapshot for this physics tick; the UI can still report
		# the actual visual clock while physical sampling is in static mode.
		sample_wave_time = _wave_sampler.get_effective_wave_time_seconds()
	var use_dynamic_waves := dynamic_waves_enabled and _wave_sampler != null
	var stiffness := BUOYANCY_MATH.equilibrium_spring_stiffness_n_per_m(
		mass,
		_gravity_mps2,
		float(profile.get("rest_submergence_m")),
		FLOAT_POINT_COUNT,
		runtime_buoyancy_strength
	)
	var damping := BUOYANCY_MATH.critical_point_damping_n_s_per_m(
		stiffness,
		mass,
		FLOAT_POINT_COUNT,
		runtime_damping_ratio
	)
	var max_force := BUOYANCY_MATH.max_point_force_n(
		mass,
		_gravity_mps2,
		FLOAT_POINT_COUNT,
		float(profile.get("maximum_point_force_ratio"))
	)
	var total_buoyancy := 0.0
	var submerged_count := 0
	var body_origin := state.transform.origin
	var body_basis := state.transform.basis
	var center_of_mass_world := body_origin + body_basis * center_of_mass
	var angular_velocity := state.angular_velocity
	var linear_velocity := state.linear_velocity
	for index in range(FLOAT_POINT_COUNT):
		var world_offset: Vector3 = body_basis * _float_offsets[index]
		var point_world := body_origin + world_offset
		var surface_height := water_height_m
		var surface_vertical_velocity := 0.0
		var shallow_state: Dictionary = {}
		var point_sample_time := 0.0
		if use_dynamic_waves:
			var sample_start_usec := Time.get_ticks_usec()
			var wave_sample: Dictionary = _wave_sampler.sample_physics_surface(point_world, sample_wave_time)
			sample_usec += Time.get_ticks_usec() - sample_start_usec
			query_count += 1
			surface_height = float(wave_sample.get("height", water_height_m))
			surface_vertical_velocity = float(wave_sample.get("vertical_velocity_mps", 0.0))
			shallow_state = wave_sample.get("shallow_wave_state", {})
			point_sample_time = float(wave_sample.get("sample_time_seconds", sample_wave_time))
		_point_water_heights_m[index] = surface_height
		_point_shallow_scales[index] = float(shallow_state.get("amplitude_scale", 1.0))
		_point_effective_depths_m[index] = float(shallow_state.get("effective_depth_m", 0.0))
		_point_sample_times_seconds[index] = point_sample_time
		var submergence := surface_height - point_world.y
		_point_submergences_m[index] = submergence
		if submergence <= 0.0:
			continue
		submerged_count += 1
		var point_velocity := linear_velocity + angular_velocity.cross(point_world - center_of_mass_world)
		# Damping acts on the hull's vertical velocity relative to the moving
		# water surface. The sampler's value is the fixed-source phase derivative.
		var relative_vertical_velocity := point_velocity.y - surface_vertical_velocity
		var force_y := BUOYANCY_MATH.point_buoyancy_force_n(
			submergence,
			relative_vertical_velocity,
			stiffness,
			damping,
			max_force
		)
		if force_y <= 0.0:
			continue
		# PhysicsDirectBodyState3D.apply_force expects the world-space offset from
		# the rigid body's origin, not the absolute point_world coordinate.
		state.apply_force(Vector3.UP * force_y, world_offset)
		total_buoyancy += force_y

	_apply_axis_damping(state, body_basis)
	_last_total_buoyancy_n = total_buoyancy
	_last_submerged_count = submerged_count
	_last_physics_delta = state.step
	_last_wave_time_seconds = sample_wave_time
	_last_wave_query_count = query_count
	_last_wave_sample_usec = sample_usec
	var local_rotation := body_basis.get_euler()
	_last_pitch_rad = local_rotation.x
	_last_roll_rad = local_rotation.z
	_last_calculation_usec = Time.get_ticks_usec() - start_usec
	_record_performance(sample_usec, _last_calculation_usec)


func _apply_axis_damping(state: PhysicsDirectBodyState3D, body_basis: Basis) -> void:
	var local_angular_velocity := body_basis.inverse() * state.angular_velocity
	var local_damping_torque := Vector3(
		-local_angular_velocity.x * float(profile.get("pitch_damping_n_m_s_per_rad")),
		-local_angular_velocity.y * float(profile.get("yaw_damping_n_m_s_per_rad")),
		-local_angular_velocity.z * float(profile.get("roll_damping_n_m_s_per_rad"))
	)
	if local_damping_torque.length_squared() <= 0.0:
		return
	state.apply_torque(body_basis * local_damping_torque)


func get_debug_snapshot() -> Dictionary:
	var wave_timing := _summarize_history(_wave_sample_usec_history)
	var total_timing := _summarize_history(_physics_calculation_usec_history)
	return {
		"mass_kg": mass,
		"linear_velocity_mps": linear_velocity,
		"linear_speed_mps": linear_velocity.length(),
		"angular_velocity_rad_s": angular_velocity,
		"roll_degrees": rad_to_deg(_last_roll_rad),
		"pitch_degrees": rad_to_deg(_last_pitch_rad),
		"water_height_m": water_height_m,
		"buoyancy_total_n": _last_total_buoyancy_n,
		"float_point_count": _float_offsets.size(),
		"submerged_point_count": _last_submerged_count,
		"force_calculation_usec": _last_calculation_usec,
		"physics_delta_s": _last_physics_delta,
		"buoyancy_strength": runtime_buoyancy_strength,
		"damping_ratio": runtime_damping_ratio,
		"dynamic_waves_enabled": dynamic_waves_enabled and _wave_sampler != null,
		"wave_sampler_available": _wave_sampler != null,
		"wave_time_seconds": _last_wave_time_seconds,
		"wave_query_count_per_tick": _last_wave_query_count,
		"wave_sample_usec": _last_wave_sample_usec,
		"wave_sample_average_usec": int(wave_timing.get("average_usec", 0)),
		"wave_sample_p95_usec": int(wave_timing.get("p95_usec", 0)),
		"total_physics_calculation_average_usec": int(total_timing.get("average_usec", 0)),
		"total_physics_calculation_p95_usec": int(total_timing.get("p95_usec", 0)),
		"point_water_heights_m": _point_water_heights_m.duplicate(),
		"point_submergences_m": _point_submergences_m.duplicate(),
		"point_shallow_scales": _point_shallow_scales.duplicate(),
		"point_effective_depths_m": _point_effective_depths_m.duplicate(),
		"point_sample_times_seconds": _point_sample_times_seconds.duplicate(),
		"performance_sample_count": _perf_history_count,
		"extreme_wave_target_height_m": _wave_sampler.get_extreme_sea_test_target_height() if _wave_sampler != null else 0.0,
		"extreme_wave_transitioning": _wave_sampler.is_extreme_sea_test_transitioning() if _wave_sampler != null else false,
		"pose_command_pending": _test_transform_pending,
		"last_test_action": _last_test_action,
	}


func set_dynamic_waves_enabled(enabled: bool) -> void:
	dynamic_waves_enabled = enabled and _wave_sampler != null
	if not dynamic_waves_enabled:
		_last_wave_query_count = 0
		_last_wave_sample_usec = 0


func _record_performance(wave_usec: int, total_usec: int) -> void:
	_wave_sample_usec_history[_perf_history_cursor] = wave_usec
	_physics_calculation_usec_history[_perf_history_cursor] = total_usec
	_perf_history_cursor = (_perf_history_cursor + 1) % PERF_WINDOW_SIZE
	_perf_history_count = mini(_perf_history_count + 1, PERF_WINDOW_SIZE)


func reset_performance_history() -> void:
	_wave_sample_usec_history.fill(0)
	_physics_calculation_usec_history.fill(0)
	_perf_history_count = 0
	_perf_history_cursor = 0


func _summarize_history(history: PackedInt64Array) -> Dictionary:
	if _perf_history_count == 0:
		return {"average_usec": 0, "p95_usec": 0}
	var sorted_values := PackedInt64Array()
	sorted_values.resize(_perf_history_count)
	var total := 0
	for index in range(_perf_history_count):
		var value := history[index]
		sorted_values[index] = value
		total += value
	sorted_values.sort()
	var p95_index := clampi(int(ceil(float(_perf_history_count - 1) * 0.95)), 0, _perf_history_count - 1)
	return {
		"average_usec": int(round(float(total) / float(_perf_history_count))),
		"p95_usec": sorted_values[p95_index],
	}


func reset_to_neutral() -> void:
	if profile == null:
		return
	var offsets: PackedVector3Array = profile.get("float_point_offsets_m")
	if offsets.size() != FLOAT_POINT_COUNT:
		return
	var mean_float_y := 0.0
	for offset in offsets:
		mean_float_y += offset.y
	mean_float_y /= float(FLOAT_POINT_COUNT)
	var rest_submergence := float(profile.get("rest_submergence_m"))
	# This explicit test reset is the only normal UI path that teleports the body
	# or clears velocity; the simulation itself is always solver-driven.
	var neutral_transform := Transform3D(
		Basis.IDENTITY,
		Vector3(0.0, water_height_m - rest_submergence - mean_float_y, 0.0)
	)
	_queue_test_transform(neutral_transform, "已请求重置到水平静水漂浮")
	runtime_buoyancy_strength = 1.0
	runtime_damping_ratio = float(profile.get("buoyancy_damping_ratio"))


func set_test_attitude(roll_degrees: float, pitch_degrees: float) -> void:
	if profile == null:
		return
	var current_transform := _pending_test_transform if _test_transform_pending else global_transform
	var test_basis := Basis.from_euler(Vector3(deg_to_rad(pitch_degrees), 0.0, deg_to_rad(roll_degrees)))
	# Apply the explicit release-test pose through the physics state on the next
	# fixed step. This avoids writing a RigidBody3D transform from a GUI callback.
	var action := "已请求姿态：横倾 %+.0f° · 纵摇 %+.0f°" % [roll_degrees, pitch_degrees]
	_queue_test_transform(Transform3D(test_basis, current_transform.origin), action)


func _queue_test_transform(target: Transform3D, action: String) -> void:
	_pending_test_transform = target
	_test_transform_pending = true
	_last_test_action = action
	sleeping = false


func _apply_pending_test_transform(state: PhysicsDirectBodyState3D) -> void:
	if not _test_transform_pending:
		return
	state.transform = _pending_test_transform
	state.linear_velocity = Vector3.ZERO
	state.angular_velocity = Vector3.ZERO
	state.sleeping = false
	_test_transform_pending = false
	_last_test_action = _last_test_action.replace("已请求", "已应用")


func apply_horizontal_test_impulse() -> void:
	apply_central_impulse(global_basis * Vector3(420.0, 0.0, 0.0))


func apply_roll_test_impulse() -> void:
	apply_torque_impulse(global_basis.z * 1800.0)


func apply_pitch_test_impulse() -> void:
	apply_torque_impulse(global_basis.x * 2600.0)


func set_runtime_buoyancy_strength(value: float) -> void:
	runtime_buoyancy_strength = clampf(value, 0.25, 1.75)


func set_runtime_damping_ratio(value: float) -> void:
	runtime_damping_ratio = clampf(value, 0.1, 1.5)
