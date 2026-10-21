extends RigidBody3D
## Standalone four-point sailboat buoyancy prototype. Not used by the powered boat.

const BUOYANCY_MATH := preload("res://scripts/sailboat_buoyancy_math.gd")
const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const HYDRO_MATH := preload("res://scripts/sailboat_hydrodynamics.gd")
const NAVIGATION_MATH := preload("res://scripts/sailboat_navigation_math.gd")
const FLOAT_POINT_COUNT := 4
const PERF_WINDOW_SIZE := 600

@export var profile: Resource
@export_node_path("Node") var wave_sampler_path: NodePath = ^"../WaveSampler"
@export_node_path("Node") var wind_field_path: NodePath = ^"../WindField"
@export_node_path("Node3D") var sail_visual_pivot_path: NodePath = ^"VisualRoot/SailPivot"
@export_node_path("Node3D") var rudder_visual_pivot_path: NodePath = ^"VisualRoot/RudderPivot"
@export_node_path("Node3D") var rudder_angle_marker_path: NodePath = ^"VisualRoot/RudderAngleMarker"
@export var dynamic_waves_enabled := true
@export_range(-5.0, 5.0, 0.01, "or_greater", "or_less") var water_height_m := 0.0
@export_range(0.0, 2.0, 0.01) var runtime_buoyancy_strength := 1.0
@export_range(0.0, 2.0, 0.01) var runtime_damping_ratio := 0.55

var _float_offsets := PackedVector3Array()
var _wave_sampler: WaveSampler
var _wind_field: WindField
var _sail_visual_pivot: Node3D
var _rudder_visual_pivot: Node3D
var _rudder_angle_marker: Node3D
var _gravity_mps2 := 9.8
var target_sail_angle_rad := 0.0
var actual_sail_angle_rad := 0.0
var target_rudder_angle_rad := 0.0
var actual_rudder_angle_rad := 0.0
var _rudder_key_a_pressed := false
var _rudder_key_d_pressed := false
var _rudder_keyboard_active := false
var _water_current_world_mps := Vector3.ZERO
var _sail_area_m2 := 26.0
var _sail_pivot_local_m := Vector3.ZERO
var _sail_pressure_center_from_pivot_m := Vector3(0.0, 2.4, 1.55)
var _minimum_sail_angle_rad := -1.396
var _maximum_sail_angle_rad := 1.396
var _sail_rotation_speed_rad_s := 0.35
var _air_density_kg_m3 := 1.225
var _sail_maximum_lift_coefficient := 1.25
var _sail_stall_angle_rad := 0.384
var _no_sail_wind_from_angle_rad := 0.611
var _full_lift_wind_from_angle_rad := 0.873
var _sail_base_drag_coefficient := 0.08
var _sail_induced_drag_factor := 0.55
var _sail_flat_plate_drag_factor := 0.90
var _sail_wrong_side_lift_retention := 0.20
var _water_density_kg_m3 := 1025.0
var _keel_center_local_m := Vector3(0.0, -1.05, 0.15)
var _keel_area_m2 := 2.2
var _keel_lift_slope_per_rad := 3.2
var _keel_max_lift_coefficient := 1.15
var _keel_stall_angle_rad := 0.42
var _keel_base_drag_coefficient := 0.025
var _keel_induced_drag_factor := 0.12
var _keel_flat_plate_drag_factor := 0.85
var _keel_max_force_weight_ratio := 2.5
var _rudder_center_local_m := Vector3(0.0, -0.88, 3.18)
var _rudder_area_m2 := 0.5
var _maximum_rudder_angle_rad := 0.611
var _rudder_rotation_speed_rad_s := 1.047
var _rudder_lift_slope_per_rad := 3.2
var _rudder_max_lift_coefficient := 1.2
var _rudder_stall_angle_rad := 0.42
var _rudder_base_drag_coefficient := 0.03
var _rudder_induced_drag_factor := 0.15
var _rudder_flat_plate_drag_factor := 0.9
var _rudder_max_force_weight_ratio := 1.0
var _hull_longitudinal_drag_linear := 220.0
var _hull_longitudinal_drag_quadratic := 85.0
var _hull_lateral_drag_linear := 500.0
var _hull_lateral_drag_quadratic := 250.0
var _hull_drag_max_force_weight_ratio := 2.0
var _last_total_buoyancy_n := 0.0
var _last_calculation_usec := 0
var _last_physics_delta := 0.0
var _last_roll_rad := 0.0
var _last_pitch_rad := 0.0
var _last_submerged_count := 0
var _pending_test_transform := Transform3D.IDENTITY
var _test_transform_pending := false
var _test_initial_linear_velocity_local_mps := Vector3.ZERO
var _test_initial_velocity_pending := false
var _last_test_initial_linear_velocity_local_mps := Vector3.ZERO
var _last_test_action := "尚无姿态测试"
var _last_wave_time_seconds := 0.0
var _last_wave_query_count := 0
var _last_wave_sample_usec := 0
var _last_wind_query_count := 0
var _last_wind_sample_usec := 0
var _last_aero_calculation_usec := 0
var _last_true_wind_world_mps := Vector3.ZERO
var _last_true_wind_from_degrees := 0.0
var _last_apparent_wind_world_mps := Vector3.ZERO
var _last_apparent_wind_local_mps := Vector3.ZERO
var _last_apparent_wind_speed_mps := 0.0
var _last_apparent_wind_from_angle_degrees := 0.0
var _last_windward_side := "无有效视风"
var _last_sail_angle_of_attack_rad := 0.0
var _last_sail_luffing_scale := 0.0
var _last_sail_cl := 0.0
var _last_sail_cd := 0.0
var _last_sail_dynamic_pressure_pa := 0.0
var _last_sail_pressure_center_local_m := Vector3.ZERO
var _last_sail_wrong_side_lift_scale := 1.0
var _last_sail_sheet_efficiency_scale := 1.0
var _last_windward_sheet_alignment := 0.0
var _last_sail_lift_force_local_n := Vector3.ZERO
var _last_sail_drag_force_local_n := Vector3.ZERO
var _last_sail_net_force_local_n := Vector3.ZERO
var _last_sail_net_force_world_n := Vector3.ZERO
var _last_hull_drag_force_local_n := Vector3.ZERO
var _last_keel_relative_water_velocity_local_mps := Vector3.ZERO
var _last_keel_result: Dictionary = {}
var _last_rudder_relative_water_velocity_local_mps := Vector3.ZERO
var _last_rudder_result: Dictionary = {}
var _last_sail_yaw_torque_nm := 0.0
var _last_keel_yaw_torque_nm := 0.0
var _last_rudder_yaw_torque_nm := 0.0
var _last_total_horizontal_force_local_n := Vector3.ZERO
var _last_total_external_yaw_torque_nm := 0.0
var _last_keel_calculation_usec := 0
var _last_rudder_calculation_usec := 0
var _last_hull_drag_calculation_usec := 0
var _last_longitudinal_velocity_mps := 0.0
var _last_lateral_velocity_mps := 0.0
var _last_yaw_rate_rad_s := 0.0
var _point_water_heights_m := PackedFloat32Array()
var _point_submergences_m := PackedFloat32Array()
var _point_shallow_scales := PackedFloat32Array()
var _point_effective_depths_m := PackedFloat32Array()
var _point_sample_times_seconds := PackedFloat32Array()
var _wave_sample_usec_history := PackedInt64Array()
var _wind_sample_usec_history := PackedInt64Array()
var _aero_calculation_usec_history := PackedInt64Array()
var _keel_calculation_usec_history := PackedInt64Array()
var _rudder_calculation_usec_history := PackedInt64Array()
var _hull_drag_calculation_usec_history := PackedInt64Array()
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
	linear_damp_mode = int(profile.get("linear_damp_mode"))
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
	_wind_field = get_node_or_null(wind_field_path) as WindField
	if _wind_field == null:
		push_warning("SailboatLabBody: WindField not found; sail forces remain zero until one is connected.")
	_sail_visual_pivot = get_node_or_null(sail_visual_pivot_path) as Node3D
	_rudder_visual_pivot = get_node_or_null(rudder_visual_pivot_path) as Node3D
	_rudder_angle_marker = get_node_or_null(rudder_angle_marker_path) as Node3D
	_sail_area_m2 = float(profile.get("main_sail_area_m2"))
	_sail_pivot_local_m = profile.get("main_sail_pivot_local_m")
	_sail_pressure_center_from_pivot_m = profile.get("main_sail_pressure_center_from_pivot_m")
	_minimum_sail_angle_rad = float(profile.get("min_sail_angle_rad"))
	_maximum_sail_angle_rad = float(profile.get("max_sail_angle_rad"))
	_sail_rotation_speed_rad_s = float(profile.get("sail_rotation_speed_rad_s"))
	_air_density_kg_m3 = float(profile.get("air_density_kg_m3"))
	_sail_maximum_lift_coefficient = float(profile.get("sail_max_lift_coefficient"))
	_sail_stall_angle_rad = float(profile.get("sail_stall_angle_rad"))
	_no_sail_wind_from_angle_rad = float(profile.get("no_sail_wind_from_angle_rad"))
	_full_lift_wind_from_angle_rad = float(profile.get("full_lift_wind_from_angle_rad"))
	_sail_base_drag_coefficient = float(profile.get("sail_base_drag_coefficient"))
	_sail_induced_drag_factor = float(profile.get("sail_induced_drag_factor"))
	_sail_flat_plate_drag_factor = float(profile.get("sail_flat_plate_drag_factor"))
	_sail_wrong_side_lift_retention = float(profile.get("sail_wrong_side_lift_retention"))
	_water_density_kg_m3 = float(profile.get("water_density_kg_m3"))
	_keel_center_local_m = profile.get("keel_center_local_m")
	_keel_area_m2 = float(profile.get("keel_area_m2"))
	_keel_lift_slope_per_rad = float(profile.get("keel_lift_slope_per_rad"))
	_keel_max_lift_coefficient = float(profile.get("keel_max_lift_coefficient"))
	_keel_stall_angle_rad = float(profile.get("keel_stall_angle_rad"))
	_keel_base_drag_coefficient = float(profile.get("keel_base_drag_coefficient"))
	_keel_induced_drag_factor = float(profile.get("keel_induced_drag_factor"))
	_keel_flat_plate_drag_factor = float(profile.get("keel_flat_plate_drag_factor"))
	_keel_max_force_weight_ratio = float(profile.get("keel_max_force_weight_ratio"))
	_rudder_center_local_m = profile.get("rudder_center_local_m")
	_rudder_area_m2 = float(profile.get("rudder_area_m2"))
	_maximum_rudder_angle_rad = float(profile.get("max_rudder_angle_rad"))
	_rudder_rotation_speed_rad_s = float(profile.get("rudder_rotation_speed_rad_s"))
	_rudder_lift_slope_per_rad = float(profile.get("rudder_lift_slope_per_rad"))
	_rudder_max_lift_coefficient = float(profile.get("rudder_max_lift_coefficient"))
	_rudder_stall_angle_rad = float(profile.get("rudder_stall_angle_rad"))
	_rudder_base_drag_coefficient = float(profile.get("rudder_base_drag_coefficient"))
	_rudder_induced_drag_factor = float(profile.get("rudder_induced_drag_factor"))
	_rudder_flat_plate_drag_factor = float(profile.get("rudder_flat_plate_drag_factor"))
	_rudder_max_force_weight_ratio = float(profile.get("rudder_max_force_weight_ratio"))
	_hull_longitudinal_drag_linear = float(profile.get("hull_longitudinal_drag_linear_n_s_m"))
	_hull_longitudinal_drag_quadratic = float(profile.get("hull_longitudinal_drag_quadratic_n_s2_m2"))
	_hull_lateral_drag_linear = float(profile.get("hull_lateral_drag_linear_n_s_m"))
	_hull_lateral_drag_quadratic = float(profile.get("hull_lateral_drag_quadratic_n_s2_m2"))
	_hull_drag_max_force_weight_ratio = float(profile.get("hull_drag_max_force_weight_ratio"))
	_point_water_heights_m.resize(FLOAT_POINT_COUNT)
	_point_submergences_m.resize(FLOAT_POINT_COUNT)
	_point_shallow_scales.resize(FLOAT_POINT_COUNT)
	_point_effective_depths_m.resize(FLOAT_POINT_COUNT)
	_point_sample_times_seconds.resize(FLOAT_POINT_COUNT)
	_wave_sample_usec_history.resize(PERF_WINDOW_SIZE)
	_wind_sample_usec_history.resize(PERF_WINDOW_SIZE)
	_aero_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_keel_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_rudder_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_hull_drag_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_physics_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_gravity_mps2 = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	reset_to_neutral()


func _process(_delta: float) -> void:
	if _sail_visual_pivot != null:
		# The pivot only mirrors the physics-controlled angle; it does not drive it.
		_sail_visual_pivot.rotation.y = actual_sail_angle_rad
	if _rudder_visual_pivot != null:
		_rudder_visual_pivot.rotation.y = actual_rudder_angle_rad
	if _rudder_angle_marker != null:
		_rudder_angle_marker.rotation.y = actual_rudder_angle_rad


func _input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if key_event.echo:
		return
	if key_event.keycode == KEY_A:
		_rudder_key_a_pressed = key_event.pressed
		_update_keyboard_rudder_target()
	elif key_event.keycode == KEY_D:
		_rudder_key_d_pressed = key_event.pressed
		_update_keyboard_rudder_target()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if profile == null or _float_offsets.size() != FLOAT_POINT_COUNT:
		return
	_apply_pending_test_transform(state)
	if _test_initial_velocity_pending:
		# Explicit test-runner initialization only. Normal gameplay never queues
		# an initial velocity and remains entirely solver-driven.
		state.linear_velocity = state.transform.basis * _test_initial_linear_velocity_local_mps
		_last_test_initial_linear_velocity_local_mps = _test_initial_linear_velocity_local_mps
		_test_initial_velocity_pending = false

	var start_usec := Time.get_ticks_usec()
	var sample_usec := 0
	var query_count := 0
	var wind_query_count := 0
	var wind_sample_usec := 0
	var aero_calculation_usec := 0
	var keel_calculation_usec := 0
	var rudder_calculation_usec := 0
	var hull_drag_calculation_usec := 0
	var sample_wave_time := 0.0
	actual_sail_angle_rad = AERO_MATH.move_sail_angle_toward(
		actual_sail_angle_rad,
		target_sail_angle_rad,
		state.step,
		_sail_rotation_speed_rad_s,
		_minimum_sail_angle_rad,
		_maximum_sail_angle_rad
	)
	actual_rudder_angle_rad = HYDRO_MATH.move_rudder_angle_toward(
		actual_rudder_angle_rad,
		target_rudder_angle_rad,
		state.step,
		_rudder_rotation_speed_rad_s,
		_maximum_rudder_angle_rad
	)
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
	var local_velocity := body_basis.inverse() * linear_velocity
	_last_longitudinal_velocity_mps = -local_velocity.z
	_last_lateral_velocity_mps = local_velocity.x
	_last_yaw_rate_rad_s = (body_basis.inverse() * angular_velocity).y
	var sail_pivot_rotation := Basis(Vector3.UP, actual_sail_angle_rad)
	var sail_pressure_center_local := (
		_sail_pivot_local_m
		+ sail_pivot_rotation * _sail_pressure_center_from_pivot_m
	)
	var sail_center_offset_world := body_basis * sail_pressure_center_local
	var sail_center_world := body_origin + sail_center_offset_world
	var true_wind_world := Vector3.ZERO
	var true_wind_from_degrees := 0.0
	if _wind_field != null:
		var wind_start_usec := Time.get_ticks_usec()
		var wind_details: Dictionary = _wind_field.get_wind_details_at(sail_center_world)
		wind_sample_usec = Time.get_ticks_usec() - wind_start_usec
		wind_query_count = 1
		true_wind_world = wind_details.get("wind_vector", Vector3.ZERO)
		true_wind_from_degrees = float(wind_details.get("instant_wind_from_degrees", 0.0))
	var apparent := AERO_MATH.calculate_apparent_wind(
		true_wind_world,
		linear_velocity,
		angular_velocity,
		sail_center_world - center_of_mass_world,
		body_basis
	)
	var aero_start_usec := Time.get_ticks_usec()
	var sail_result: Dictionary = AERO_MATH.calculate_sail_forces(
		apparent.get("apparent_velocity_local_mps", Vector3.ZERO),
		actual_sail_angle_rad,
		_sail_area_m2,
		_air_density_kg_m3,
		_sail_maximum_lift_coefficient,
		_sail_stall_angle_rad,
		_sail_base_drag_coefficient,
		_sail_induced_drag_factor,
		_sail_flat_plate_drag_factor,
		_no_sail_wind_from_angle_rad,
		_full_lift_wind_from_angle_rad,
		_sail_wrong_side_lift_retention
	)
	aero_calculation_usec = Time.get_ticks_usec() - aero_start_usec
	var sail_lift_local: Vector3 = sail_result.get("lift_force_local_n", Vector3.ZERO)
	var sail_drag_local: Vector3 = sail_result.get("drag_force_local_n", Vector3.ZERO)
	var sail_net_local: Vector3 = sail_result.get("net_force_local_n", Vector3.ZERO)
	var sail_net_world := body_basis * sail_net_local
	var sail_yaw_torque := (sail_pressure_center_local - center_of_mass).cross(sail_net_local).y
	if sail_net_world.length_squared() > 0.0:
		# Offset is relative to the rigid-body origin; the engine solves torque
		# about the actual centre of mass, including the profile's COM offset.
		state.apply_force(sail_net_world, sail_center_offset_world)
	var local_velocity_through_water := body_basis.inverse() * (linear_velocity - _water_current_world_mps)
	var hull_drag_start_usec := Time.get_ticks_usec()
	var hull_drag_local := HYDRO_MATH.calculate_hull_resistance(
		local_velocity_through_water,
		_hull_longitudinal_drag_linear,
		_hull_longitudinal_drag_quadratic,
		_hull_lateral_drag_linear,
		_hull_lateral_drag_quadratic,
		mass * _gravity_mps2 * _hull_drag_max_force_weight_ratio
	)
	hull_drag_calculation_usec = Time.get_ticks_usec() - hull_drag_start_usec
	if hull_drag_local.length_squared() > 0.0:
		state.apply_central_force(body_basis * hull_drag_local)

	var keel_offset_world := body_basis * _keel_center_local_m
	var keel_position_world := body_origin + keel_offset_world
	var keel_point_velocity_world := linear_velocity + angular_velocity.cross(keel_position_world - center_of_mass_world)
	var keel_velocity_local := body_basis.inverse() * (keel_point_velocity_world - _water_current_world_mps)
	var keel_start_usec := Time.get_ticks_usec()
	var keel_result := HYDRO_MATH.calculate_foil_forces(
		keel_velocity_local,
		0.0,
		_keel_area_m2,
		_water_density_kg_m3,
		_keel_lift_slope_per_rad,
		_keel_max_lift_coefficient,
		_keel_stall_angle_rad,
		_keel_base_drag_coefficient,
		_keel_induced_drag_factor,
		_keel_flat_plate_drag_factor,
		mass * _gravity_mps2 * _keel_max_force_weight_ratio
	)
	keel_calculation_usec = Time.get_ticks_usec() - keel_start_usec
	var keel_force_local: Vector3 = keel_result.get("net_force_local_n", Vector3.ZERO)
	var keel_yaw_torque := (_keel_center_local_m - center_of_mass).cross(keel_force_local).y
	if keel_force_local.length_squared() > 0.0:
		state.apply_force(body_basis * keel_force_local, keel_offset_world)

	var rudder_offset_world := body_basis * _rudder_center_local_m
	var rudder_position_world := body_origin + rudder_offset_world
	var rudder_point_velocity_world := linear_velocity + angular_velocity.cross(rudder_position_world - center_of_mass_world)
	var rudder_velocity_local := body_basis.inverse() * (rudder_point_velocity_world - _water_current_world_mps)
	var rudder_start_usec := Time.get_ticks_usec()
	var rudder_result := HYDRO_MATH.calculate_foil_forces(
		rudder_velocity_local,
		actual_rudder_angle_rad,
		_rudder_area_m2,
		_water_density_kg_m3,
		_rudder_lift_slope_per_rad,
		_rudder_max_lift_coefficient,
		_rudder_stall_angle_rad,
		_rudder_base_drag_coefficient,
		_rudder_induced_drag_factor,
		_rudder_flat_plate_drag_factor,
		mass * _gravity_mps2 * _rudder_max_force_weight_ratio
	)
	rudder_calculation_usec = Time.get_ticks_usec() - rudder_start_usec
	var rudder_force_local: Vector3 = rudder_result.get("net_force_local_n", Vector3.ZERO)
	var rudder_yaw_torque := (_rudder_center_local_m - center_of_mass).cross(rudder_force_local).y
	if rudder_force_local.length_squared() > 0.0:
		state.apply_force(body_basis * rudder_force_local, rudder_offset_world)

	_last_hull_drag_force_local_n = hull_drag_local
	_last_keel_relative_water_velocity_local_mps = keel_velocity_local
	_last_keel_result = keel_result
	_last_rudder_relative_water_velocity_local_mps = rudder_velocity_local
	_last_rudder_result = rudder_result
	_last_sail_yaw_torque_nm = sail_yaw_torque
	_last_keel_yaw_torque_nm = keel_yaw_torque
	_last_rudder_yaw_torque_nm = rudder_yaw_torque
	_last_total_horizontal_force_local_n = sail_net_local + hull_drag_local + keel_force_local + rudder_force_local
	_last_total_external_yaw_torque_nm = sail_yaw_torque + keel_yaw_torque + rudder_yaw_torque
	_last_true_wind_world_mps = true_wind_world
	_last_true_wind_from_degrees = true_wind_from_degrees
	_last_apparent_wind_world_mps = apparent.get("apparent_velocity_world_mps", Vector3.ZERO)
	_last_apparent_wind_local_mps = apparent.get("apparent_velocity_local_mps", Vector3.ZERO)
	_last_apparent_wind_speed_mps = float(apparent.get("apparent_speed_mps", 0.0))
	_last_apparent_wind_from_angle_degrees = float(apparent.get("apparent_from_angle_degrees", 0.0))
	_last_windward_side = str(apparent.get("windward_side", "无有效视风"))
	_last_sail_angle_of_attack_rad = float(sail_result.get("angle_of_attack_rad", 0.0))
	_last_sail_luffing_scale = float(sail_result.get("luffing_scale", 0.0))
	_last_sail_cl = float(sail_result.get("cl", 0.0))
	_last_sail_cd = float(sail_result.get("cd", 0.0))
	_last_sail_dynamic_pressure_pa = float(sail_result.get("dynamic_pressure_pa", 0.0))
	_last_sail_pressure_center_local_m = sail_pressure_center_local
	_last_sail_wrong_side_lift_scale = float(sail_result.get("wrong_side_lift_scale", 1.0))
	_last_sail_sheet_efficiency_scale = float(sail_result.get("sheet_efficiency_scale", 1.0))
	_last_windward_sheet_alignment = float(sail_result.get("windward_sheet_alignment", 0.0))
	_last_sail_lift_force_local_n = sail_lift_local
	_last_sail_drag_force_local_n = sail_drag_local
	_last_sail_net_force_local_n = sail_net_local
	_last_sail_net_force_world_n = sail_net_world
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
	_last_wind_query_count = wind_query_count
	_last_wind_sample_usec = wind_sample_usec
	_last_aero_calculation_usec = aero_calculation_usec
	var local_rotation := body_basis.get_euler()
	_last_pitch_rad = local_rotation.x
	_last_roll_rad = local_rotation.z
	_last_calculation_usec = Time.get_ticks_usec() - start_usec
	_record_performance(
		sample_usec,
		wind_sample_usec,
		aero_calculation_usec,
		keel_calculation_usec,
		rudder_calculation_usec,
		hull_drag_calculation_usec,
		_last_calculation_usec
	)


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
	var wind_timing := _summarize_history(_wind_sample_usec_history)
	var aero_timing := _summarize_history(_aero_calculation_usec_history)
	var keel_timing := _summarize_history(_keel_calculation_usec_history)
	var rudder_timing := _summarize_history(_rudder_calculation_usec_history)
	var hull_drag_timing := _summarize_history(_hull_drag_calculation_usec_history)
	var total_timing := _summarize_history(_physics_calculation_usec_history)
	var local_velocity := global_basis.inverse() * linear_velocity
	var wind_override_state := "无风场"
	if _wind_field != null:
		wind_override_state = str(_wind_field.get_debug_override_state())
	return {
		"mass_kg": mass,
		"linear_velocity_mps": linear_velocity,
		"linear_speed_mps": linear_velocity.length(),
		"angular_velocity_rad_s": angular_velocity,
		"roll_degrees": rad_to_deg(_last_roll_rad),
		"pitch_degrees": rad_to_deg(_last_pitch_rad),
		"heading_degrees": fposmod(rad_to_deg(atan2(-global_basis.z.x, global_basis.z.z)), 360.0),
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
		"wind_query_count_per_tick": _last_wind_query_count,
		"wind_sample_usec": _last_wind_sample_usec,
		"wind_sample_average_usec": int(wind_timing.get("average_usec", 0)),
		"wind_sample_p95_usec": int(wind_timing.get("p95_usec", 0)),
		"aero_calculation_usec": _last_aero_calculation_usec,
		"aero_calculation_average_usec": int(aero_timing.get("average_usec", 0)),
		"aero_calculation_p95_usec": int(aero_timing.get("p95_usec", 0)),
		"keel_calculation_usec": _last_keel_calculation_usec,
		"keel_calculation_average_usec": int(keel_timing.get("average_usec", 0)),
		"keel_calculation_p95_usec": int(keel_timing.get("p95_usec", 0)),
		"rudder_calculation_usec": _last_rudder_calculation_usec,
		"rudder_calculation_average_usec": int(rudder_timing.get("average_usec", 0)),
		"rudder_calculation_p95_usec": int(rudder_timing.get("p95_usec", 0)),
		"hull_drag_calculation_usec": _last_hull_drag_calculation_usec,
		"hull_drag_calculation_average_usec": int(hull_drag_timing.get("average_usec", 0)),
		"hull_drag_calculation_p95_usec": int(hull_drag_timing.get("p95_usec", 0)),
		"total_physics_calculation_average_usec": int(total_timing.get("average_usec", 0)),
		"total_physics_calculation_p95_usec": int(total_timing.get("p95_usec", 0)),
		"true_wind_world_mps": _last_true_wind_world_mps,
		"true_wind_speed_mps": _last_true_wind_world_mps.length(),
		"true_wind_from_degrees": _last_true_wind_from_degrees,
		"apparent_wind_world_mps": _last_apparent_wind_world_mps,
		"apparent_wind_local_mps": _last_apparent_wind_local_mps,
		"apparent_wind_speed_mps": _last_apparent_wind_speed_mps,
		"apparent_wind_from_angle_degrees": _last_apparent_wind_from_angle_degrees,
		"windward_side": _last_windward_side,
		"target_sail_angle_rad": target_sail_angle_rad,
		"actual_sail_angle_rad": actual_sail_angle_rad,
		"min_sail_angle_rad": _minimum_sail_angle_rad,
		"max_sail_angle_rad": _maximum_sail_angle_rad,
		"sail_rotation_speed_rad_s": _sail_rotation_speed_rad_s,
		"sail_area_m2": _sail_area_m2,
		"sail_pressure_center_local_m": _last_sail_pressure_center_local_m,
		"sail_wrong_side_lift_retention": _sail_wrong_side_lift_retention,
		"sail_wrong_side_lift_scale": _last_sail_wrong_side_lift_scale,
		"sail_sheet_efficiency_scale": _last_sail_sheet_efficiency_scale,
		"sail_windward_sheet_alignment": _last_windward_sheet_alignment,
		"sail_angle_of_attack_rad": _last_sail_angle_of_attack_rad,
		"sail_luffing_scale": _last_sail_luffing_scale,
		"sail_cl": _last_sail_cl,
		"sail_cd": _last_sail_cd,
		"sail_dynamic_pressure_pa": _last_sail_dynamic_pressure_pa,
		"sail_lift_force_local_n": _last_sail_lift_force_local_n,
		"sail_drag_force_local_n": _last_sail_drag_force_local_n,
		"sail_net_force_local_n": _last_sail_net_force_local_n,
		"sail_net_force_world_n": _last_sail_net_force_world_n,
		"sail_yaw_torque_nm": _last_sail_yaw_torque_nm,
		"hull_drag_force_local_n": _last_hull_drag_force_local_n,
		"keel_center_local_m": _keel_center_local_m,
		"keel_relative_water_velocity_local_mps": _last_keel_relative_water_velocity_local_mps,
		"keel_water_speed_mps": float(_last_keel_result.get("water_speed_mps", 0.0)),
		"keel_side_slip_angle_rad": float(_last_keel_result.get("side_slip_angle_rad", 0.0)),
		"keel_angle_of_attack_rad": float(_last_keel_result.get("angle_of_attack_rad", 0.0)),
		"keel_force_local_n": _last_keel_result.get("net_force_local_n", Vector3.ZERO),
		"keel_yaw_torque_nm": _last_keel_yaw_torque_nm,
		"rudder_center_local_m": _rudder_center_local_m,
		"target_rudder_angle_rad": target_rudder_angle_rad,
		"actual_rudder_angle_rad": actual_rudder_angle_rad,
		"max_rudder_angle_rad": _maximum_rudder_angle_rad,
		"rudder_rotation_speed_rad_s": _rudder_rotation_speed_rad_s,
		"rudder_relative_water_velocity_local_mps": _last_rudder_relative_water_velocity_local_mps,
		"rudder_water_speed_mps": float(_last_rudder_result.get("water_speed_mps", 0.0)),
		"rudder_side_slip_angle_rad": float(_last_rudder_result.get("side_slip_angle_rad", 0.0)),
		"rudder_angle_of_attack_rad": float(_last_rudder_result.get("angle_of_attack_rad", 0.0)),
		"rudder_force_local_n": _last_rudder_result.get("net_force_local_n", Vector3.ZERO),
		"rudder_yaw_torque_nm": _last_rudder_yaw_torque_nm,
		"total_horizontal_force_local_n": _last_total_horizontal_force_local_n,
		"total_external_yaw_torque_nm": _last_total_external_yaw_torque_nm,
		"water_current_world_mps": _water_current_world_mps,
		"longitudinal_velocity_mps": _last_longitudinal_velocity_mps,
		"lateral_velocity_mps": _last_lateral_velocity_mps,
		"yaw_rate_rad_s": _last_yaw_rate_rad_s,
		"wind_field_available": _wind_field != null,
		"wind_field_weather_controlled": _wind_field.is_weather_controlled() if _wind_field != null else false,
		"wind_debug_override_state": wind_override_state,
		"local_velocity_mps": local_velocity,
		"point_water_heights_m": _point_water_heights_m.duplicate(),
		"point_submergences_m": _point_submergences_m.duplicate(),
		"point_shallow_scales": _point_shallow_scales.duplicate(),
		"point_effective_depths_m": _point_effective_depths_m.duplicate(),
		"point_sample_times_seconds": _point_sample_times_seconds.duplicate(),
		"performance_sample_count": _perf_history_count,
		"extreme_wave_target_height_m": _wave_sampler.get_extreme_sea_test_target_height() if _wave_sampler != null else 0.0,
		"extreme_wave_transitioning": _wave_sampler.is_extreme_sea_test_transitioning() if _wave_sampler != null else false,
		"pose_command_pending": _test_transform_pending,
		"test_initial_velocity_pending": _test_initial_velocity_pending,
		"test_initial_velocity_applied_local_mps": _last_test_initial_linear_velocity_local_mps,
		"last_test_action": _last_test_action,
	}


func get_s1_c4_diagnostic_snapshot() -> Dictionary:
	## Compact read-only diagnostics for the offline S1-C4 experiment runner.
	## Reads cached force results and current rigid-body state only; it never
	## performs additional WindField or WaveSampler queries.
	var local_velocity := global_basis.inverse() * linear_velocity
	var local_angular_velocity := global_basis.inverse() * angular_velocity
	var sog_vector := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var apparent := Vector2(_last_apparent_wind_local_mps.x, _last_apparent_wind_local_mps.z)
	var sail_force := _last_sail_net_force_local_n
	var keel_force: Vector3 = _last_keel_result.get("net_force_local_n", Vector3.ZERO)
	var rudder_force: Vector3 = _last_rudder_result.get("net_force_local_n", Vector3.ZERO)
	var explicit_yaw_damping := -local_angular_velocity.y * float(profile.get("yaw_damping_n_m_s_per_rad"))
	var local_total_yaw := (
		_last_sail_yaw_torque_nm
		+ _last_keel_yaw_torque_nm
		+ _last_rudder_yaw_torque_nm
		+ explicit_yaw_damping
	)
	var world_total_yaw_vector := global_basis * Vector3(0.0, local_total_yaw, 0.0)
	return {
		"position_world_m": global_position,
		"heading_degrees": NAVIGATION_MATH.heading_degrees_from_forward(-global_basis.z),
		"sog_mps": sog_vector.length(),
		"cog_degrees": NAVIGATION_MATH.bearing_degrees_from_vector(sog_vector) if sog_vector.length() >= 0.1 else -1.0,
		"longitudinal_velocity_mps": -local_velocity.z,
		"lateral_velocity_mps": local_velocity.x,
		"yaw_rate_rad_s": local_angular_velocity.y,
		"roll_degrees": rad_to_deg(_last_roll_rad),
		"apparent_wind_speed_mps": apparent.length(),
		"apparent_wind_from_angle_degrees": _last_apparent_wind_from_angle_degrees,
		"keel_water_speed_mps": float(_last_keel_result.get("water_speed_mps", 0.0)),
		"sail_attack_angle_degrees": rad_to_deg(_last_sail_angle_of_attack_rad),
		"sail_luffing_scale": _last_sail_luffing_scale,
		"sail_cl": _last_sail_cl,
		"sail_cd": _last_sail_cd,
		"sail_force_local_n": sail_force,
		"sail_yaw_torque_local_nm": _last_sail_yaw_torque_nm,
		"sail_yaw_torque_world_vertical_nm": (global_basis * Vector3(0.0, _last_sail_yaw_torque_nm, 0.0)).y,
		"keel_force_local_n": keel_force,
		"keel_yaw_torque_local_nm": _last_keel_yaw_torque_nm,
		"keel_yaw_torque_world_vertical_nm": (global_basis * Vector3(0.0, _last_keel_yaw_torque_nm, 0.0)).y,
		"rudder_force_local_n": rudder_force,
		"rudder_water_speed_mps": float(_last_rudder_result.get("water_speed_mps", 0.0)),
		"rudder_yaw_torque_local_nm": _last_rudder_yaw_torque_nm,
		"rudder_yaw_torque_world_vertical_nm": (global_basis * Vector3(0.0, _last_rudder_yaw_torque_nm, 0.0)).y,
		"hull_drag_force_local_n": _last_hull_drag_force_local_n,
		"total_force_local_n": _last_total_horizontal_force_local_n,
		"explicit_yaw_damping_torque_local_nm": explicit_yaw_damping,
		"summed_measured_yaw_torque_local_nm": local_total_yaw,
		"summed_measured_yaw_torque_world_vertical_nm": world_total_yaw_vector.y,
		"actual_sail_angle_rad": actual_sail_angle_rad,
		"target_sail_angle_rad": target_sail_angle_rad,
		"actual_rudder_angle_rad": actual_rudder_angle_rad,
		"target_rudder_angle_rad": target_rudder_angle_rad,
		"pose_command_pending": _test_transform_pending,
		"test_initial_velocity_pending": _test_initial_velocity_pending,
		"test_initial_velocity_applied_local_mps": _last_test_initial_linear_velocity_local_mps,
		"physics_delta_s": _last_physics_delta,
	}


func get_navigation_snapshot() -> Dictionary:
	## Compact read-only snapshot for the SailboatLab instrument. It only reads
	## cached physics outputs and current rigid-body state; it does not sample
	## WindField or WaveSampler.
	var forward_world := -global_basis.z
	var heading_degrees := NAVIGATION_MATH.heading_degrees_from_forward(forward_world)
	var horizontal_velocity := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var sog_mps := horizontal_velocity.length()
	var cog_valid := NAVIGATION_MATH.cog_is_reliable(sog_mps)
	var cog_degrees := NAVIGATION_MATH.bearing_degrees_from_vector(horizontal_velocity) if cog_valid else 0.0
	var cog_minus_heading := NAVIGATION_MATH.signed_relative_bearing_degrees(cog_degrees, heading_degrees) if cog_valid else 0.0
	var true_wind_horizontal := Vector3(_last_true_wind_world_mps.x, 0.0, _last_true_wind_world_mps.z)
	var apparent_wind_horizontal := Vector3(_last_apparent_wind_world_mps.x, 0.0, _last_apparent_wind_world_mps.z)
	var true_wind_speed := true_wind_horizontal.length()
	var apparent_wind_speed := apparent_wind_horizontal.length()
	var true_wind_valid := true_wind_speed > 0.05
	var apparent_wind_valid := apparent_wind_speed > 0.05
	var true_wind_from := NAVIGATION_MATH.wind_from_bearing_from_wind_to(true_wind_horizontal) if true_wind_valid else 0.0
	var apparent_wind_from := NAVIGATION_MATH.wind_from_bearing_from_wind_to(apparent_wind_horizontal) if apparent_wind_valid else 0.0
	return {
		"heading_degrees": heading_degrees,
		"cog_valid": cog_valid,
		"cog_degrees": cog_degrees,
		"cog_minus_heading_degrees": cog_minus_heading,
		"sog_mps": sog_mps,
		"sog_knots": NAVIGATION_MATH.sog_knots(sog_mps),
		"heel_degrees": rad_to_deg(_last_roll_rad),
		"true_wind_valid": true_wind_valid,
		"true_wind_speed_mps": true_wind_speed,
		"true_wind_from_degrees": true_wind_from,
		"true_wind_from_relative_degrees": NAVIGATION_MATH.signed_relative_bearing_degrees(true_wind_from, heading_degrees) if true_wind_valid else 0.0,
		"apparent_wind_valid": apparent_wind_valid,
		"apparent_wind_speed_mps": apparent_wind_speed,
		"apparent_wind_from_degrees": apparent_wind_from,
		"apparent_wind_from_relative_degrees": NAVIGATION_MATH.signed_relative_bearing_degrees(apparent_wind_from, heading_degrees) if apparent_wind_valid else 0.0,
		"actual_sail_angle_rad": actual_sail_angle_rad,
		"target_sail_angle_rad": target_sail_angle_rad,
		"actual_rudder_angle_rad": actual_rudder_angle_rad,
		"target_rudder_angle_rad": target_rudder_angle_rad,
		"max_rudder_angle_rad": _maximum_rudder_angle_rad,
		"keel_side_slip_angle_rad": float(_last_keel_result.get("side_slip_angle_rad", 0.0)),
		"wind_query_count_per_tick": _last_wind_query_count,
		"wave_query_count_per_tick": _last_wave_query_count,
	}


func set_dynamic_waves_enabled(enabled: bool) -> void:
	dynamic_waves_enabled = enabled and _wave_sampler != null
	if not dynamic_waves_enabled:
		_last_wave_query_count = 0
		_last_wave_sample_usec = 0


func _record_performance(
	wave_usec: int,
	wind_usec: int,
	aero_usec: int,
	keel_usec: int,
	rudder_usec: int,
	hull_drag_usec: int,
	total_usec: int
) -> void:
	_wave_sample_usec_history[_perf_history_cursor] = wave_usec
	_wind_sample_usec_history[_perf_history_cursor] = wind_usec
	_aero_calculation_usec_history[_perf_history_cursor] = aero_usec
	_keel_calculation_usec_history[_perf_history_cursor] = keel_usec
	_rudder_calculation_usec_history[_perf_history_cursor] = rudder_usec
	_hull_drag_calculation_usec_history[_perf_history_cursor] = hull_drag_usec
	_physics_calculation_usec_history[_perf_history_cursor] = total_usec
	_last_keel_calculation_usec = keel_usec
	_last_rudder_calculation_usec = rudder_usec
	_last_hull_drag_calculation_usec = hull_drag_usec
	_perf_history_cursor = (_perf_history_cursor + 1) % PERF_WINDOW_SIZE
	_perf_history_count = mini(_perf_history_count + 1, PERF_WINDOW_SIZE)


func reset_performance_history() -> void:
	_wave_sample_usec_history.fill(0)
	_wind_sample_usec_history.fill(0)
	_aero_calculation_usec_history.fill(0)
	_keel_calculation_usec_history.fill(0)
	_rudder_calculation_usec_history.fill(0)
	_hull_drag_calculation_usec_history.fill(0)
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


func reset_to_neutral(heading_degrees: float = 0.0) -> void:
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
		Basis(Vector3.UP, deg_to_rad(heading_degrees)),
		Vector3(0.0, water_height_m - rest_submergence - mean_float_y, 0.0)
	)
	_queue_test_transform(neutral_transform, "已请求重置到静水漂浮 · 航向 %.0f°" % fposmod(heading_degrees, 360.0))
	target_sail_angle_rad = 0.0
	actual_sail_angle_rad = 0.0
	target_rudder_angle_rad = 0.0
	actual_rudder_angle_rad = 0.0
	_rudder_key_a_pressed = false
	_rudder_key_d_pressed = false
	_rudder_keyboard_active = false
	runtime_buoyancy_strength = 1.0
	runtime_damping_ratio = float(profile.get("buoyancy_damping_ratio"))


func set_test_initial_linear_velocity_local(velocity_mps: Vector3) -> void:
	## Queues a deterministic initial speed for offline physical experiments.
	## It is inert in normal sailing unless an explicit test invokes it.
	_test_initial_linear_velocity_local_mps = velocity_mps
	_test_initial_velocity_pending = true
	sleeping = false


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


func set_target_sail_angle(angle_rad: float) -> void:
	if not is_finite(angle_rad):
		return
	target_sail_angle_rad = clampf(angle_rad, _minimum_sail_angle_rad, _maximum_sail_angle_rad)


func set_target_rudder_angle(angle_rad: float) -> void:
	if not is_finite(angle_rad):
		return
	_rudder_keyboard_active = false
	target_rudder_angle_rad = clampf(angle_rad, -_maximum_rudder_angle_rad, _maximum_rudder_angle_rad)


func set_rudder_input(axis: float) -> void:
	if not is_finite(axis):
		return
	var safe_axis := clampf(axis, -1.0, 1.0)
	target_rudder_angle_rad = safe_axis * _maximum_rudder_angle_rad
	_rudder_keyboard_active = not is_zero_approx(safe_axis)


func clear_rudder_input() -> void:
	_rudder_keyboard_active = false
	target_rudder_angle_rad = 0.0


func set_water_current_world_velocity(velocity_world_mps: Vector3) -> void:
	if is_finite(velocity_world_mps.x) and is_finite(velocity_world_mps.y) and is_finite(velocity_world_mps.z):
		_water_current_world_mps = velocity_world_mps


func _update_keyboard_rudder_target() -> void:
	if _rudder_key_a_pressed or _rudder_key_d_pressed:
		_rudder_keyboard_active = true
		var axis := (1.0 if _rudder_key_d_pressed else 0.0) - (1.0 if _rudder_key_a_pressed else 0.0)
		target_rudder_angle_rad = axis * _maximum_rudder_angle_rad
	elif _rudder_keyboard_active:
		_rudder_keyboard_active = false
		target_rudder_angle_rad = 0.0


func can_set_lab_test_wind() -> bool:
	return _wind_field != null and not _wind_field.is_weather_controlled()


## Local SailboatLab fixture control. It refuses to write to a field owned by
## WeatherStateController, so this cannot replace formal weather targets.
func set_lab_test_wind(speed_mps: float, wind_from_degrees: float) -> bool:
	if not can_set_lab_test_wind() or not is_finite(speed_mps) or not is_finite(wind_from_degrees):
		return false
	_wind_field.set_gust_parameters(0.0, 24.0, 450.0)
	_wind_field.set_mean_wind(clampf(speed_mps, 0.0, 30.0), fposmod(wind_from_degrees, 360.0))
	return true
