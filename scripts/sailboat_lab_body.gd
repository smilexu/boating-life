extends RigidBody3D
## Standalone four-point sailboat buoyancy prototype. Not used by the powered boat.

const BUOYANCY_MATH := preload("res://scripts/sailboat_buoyancy_math.gd")
const AERO_MATH := preload("res://scripts/sailboat_aero_math.gd")
const HYDRO_MATH := preload("res://scripts/sailboat_hydrodynamics.gd")
const NAVIGATION_MATH := preload("res://scripts/sailboat_navigation_math.gd")
const AUTO_SAIL_TRIM_SCRIPT := preload("res://scripts/sailboat_auto_sail_trim.gd")
const FLOAT_POINT_COUNT := 4
const PERF_WINDOW_SIZE := 600
const ANOMALY_SAMPLE_CAPACITY := 600
const ANOMALY_FLOAT_WATER_FIELDS := ["float_1_water_height_m", "float_2_water_height_m", "float_3_water_height_m", "float_4_water_height_m"]
const ANOMALY_FLOAT_SUBMERGENCE_FIELDS := ["float_1_submergence_m", "float_2_submergence_m", "float_3_submergence_m", "float_4_submergence_m"]
const ANOMALY_FIELDS := [
	"physics_frame", "sim_time_s", "step_s",
	"position_x_m", "position_y_m", "position_z_m",
	"basis_x_x", "basis_x_y", "basis_x_z",
	"basis_y_x", "basis_y_y", "basis_y_z",
	"basis_z_x", "basis_z_y", "basis_z_z",
	"linear_velocity_x_mps", "linear_velocity_y_mps", "linear_velocity_z_mps",
	"angular_velocity_x_rad_s", "angular_velocity_y_rad_s", "angular_velocity_z_rad_s",
	"linear_acceleration_x_mps2", "linear_acceleration_y_mps2", "linear_acceleration_z_mps2",
	"angular_acceleration_x_rad_s2", "angular_acceleration_y_rad_s2", "angular_acceleration_z_rad_s2",
	"speed_mps", "angular_speed_rad_s", "tilt_from_world_up_deg",
	"local_longitudinal_speed_mps", "local_lateral_speed_mps", "local_yaw_rate_rad_s",
	"true_wind_x_mps", "true_wind_y_mps", "true_wind_z_mps", "true_wind_from_deg",
	"apparent_wind_local_x_mps", "apparent_wind_local_y_mps", "apparent_wind_local_z_mps",
	"apparent_wind_speed_mps", "apparent_wind_from_angle_deg",
	"main_sail_actual_rad", "main_sail_target_rad", "main_sail_aoa_rad", "main_sail_dynamic_pressure_pa",
	"headsail_enabled", "headsail_actual_rad", "headsail_target_rad", "headsail_aoa_rad", "headsail_dynamic_pressure_pa",
	"rudder_actual_rad", "rudder_target_rad",
	"main_force_local_x_n", "main_force_local_y_n", "main_force_local_z_n",
	"headsail_force_local_x_n", "headsail_force_local_y_n", "headsail_force_local_z_n",
	"hull_drag_local_x_n", "hull_drag_local_y_n", "hull_drag_local_z_n",
	"keel_force_local_x_n", "keel_force_local_y_n", "keel_force_local_z_n",
	"rudder_force_local_x_n", "rudder_force_local_y_n", "rudder_force_local_z_n",
	"main_yaw_torque_nm", "headsail_yaw_torque_nm", "keel_yaw_torque_nm", "rudder_yaw_torque_nm",
	"total_explicit_yaw_torque_nm", "total_horizontal_force_local_x_n", "total_horizontal_force_local_y_n", "total_horizontal_force_local_z_n",
	"total_buoyancy_n", "wave_time_s", "wave_query_count", "wind_query_count",
	"float_1_water_height_m", "float_2_water_height_m", "float_3_water_height_m", "float_4_water_height_m",
	"float_1_submergence_m", "float_2_submergence_m", "float_3_submergence_m", "float_4_submergence_m"
]


static func world_arm_from_local_point(point_local: Vector3, center_of_mass_local: Vector3, body_basis: Basis) -> Vector3:
	## Converts a rigid-body local point to a world-space arm measured from its
	## effective local centre of mass. This is for angular point velocity only;
	## apply_force() positions remain body-origin offsets.
	return body_basis * (point_local - center_of_mass_local)

@export var profile: Resource
@export_node_path("Node") var wave_sampler_path: NodePath = ^"../WaveSampler"
@export_node_path("Node") var wind_field_path: NodePath = ^"../WindField"
@export_node_path("Node3D") var sail_visual_pivot_path: NodePath = ^"VisualRoot/VisualBoomPivot"
@export_node_path("Node3D") var rudder_visual_pivot_path: NodePath = ^"VisualRoot/RudderPivot"
@export_node_path("Node3D") var rudder_angle_marker_path: NodePath = ^"VisualRoot/RudderAngleMarker"
@export_node_path("MeshInstance3D") var headsail_visual_path: NodePath = ^"VisualRoot/HeadsailVisual"
@export_node_path("Node") var auxiliary_engine_path: NodePath = ^"AuxiliaryMarineEngine"
@export var dynamic_waves_enabled := true
@export var auto_reset_on_ready := true
@export var keyboard_controls_enabled := true
@export_range(-5.0, 5.0, 0.01, "or_greater", "or_less") var water_height_m := 0.0
@export_range(0.0, 2.0, 0.01) var runtime_buoyancy_strength := 1.0
@export_range(0.0, 2.0, 0.01) var runtime_damping_ratio := 0.55
@export var enable_debug_anomaly_capture := true
## P2.2-only readout. When enabled this only accumulates cached force moments;
## it does not alter any force, sampling or classification path.
@export var p22_extended_telemetry_enabled := false

var _float_offsets := PackedVector3Array()
var _wave_sampler: WaveSampler
var _wind_field: WindField
var _sail_visual_pivot: Node3D
var _rudder_visual_pivot: Node3D
var _rudder_angle_marker: Node3D
var _headsail_visual: MeshInstance3D
var _auxiliary_engine: AuxiliaryMarineEngine
var _gravity_mps2 := 9.8
var target_sail_angle_rad := 0.0
var actual_sail_angle_rad := 0.0
var target_headsail_angle_rad := 0.0
var actual_headsail_angle_rad := 0.0
var auto_sail_trim_enabled := false
var _auto_sail_trim = AUTO_SAIL_TRIM_SCRIPT.new()
var _auto_trim_applying_targets := false
var _last_auto_trim_result: Dictionary = {}
var _last_auto_trim_calculation_usec := 0
var _headsail_enabled := true
var _lab_sail_forces_enabled := true
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
var _headsail_area_m2 := 5.16
var _headsail_head_local_m := Vector3(0.0, 4.95, -0.75)
var _headsail_tack_local_m := Vector3(0.0, 0.65, -3.55)
var _headsail_clew_neutral_local_m := Vector3(0.0, 0.65, -1.15)
var _headsail_pressure_center_offset_from_centroid_m := Vector3.ZERO
var _headsail_pressure_center_clew_follow := 0.333333
var _minimum_headsail_angle_rad := -1.222
var _maximum_headsail_angle_rad := 1.222
var _headsail_rotation_speed_rad_s := 0.52
var _headsail_maximum_lift_coefficient := 1.25
var _headsail_stall_angle_rad := 0.384
var _headsail_no_sail_wind_from_angle_rad := 0.611
var _headsail_full_lift_wind_from_angle_rad := 0.873
var _headsail_base_drag_coefficient := 0.08
var _headsail_induced_drag_factor := 0.55
var _headsail_flat_plate_drag_factor := 0.90
var _headsail_wrong_side_lift_retention := 0.20
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
var _hull_lateral_center_from_com_local_m := Vector3.ZERO
## P2.12-only diagnostic lever arm, measured from the effective COM along local Z.
## Zero preserves the production central-force path exactly.
var _test_hull_lateral_application_offset_z_m := 0.0
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
var _last_headsail_aero_calculation_usec := 0
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
var _last_headsail_apparent_wind_local_mps := Vector3.ZERO
var _last_headsail_apparent_wind_speed_mps := 0.0
var _last_headsail_arm_from_com_world_m := Vector3.ZERO
var _last_headsail_angle_of_attack_rad := 0.0
var _last_headsail_luffing_scale := 0.0
var _last_headsail_wrong_side_lift_scale := 1.0
var _last_headsail_cl := 0.0
var _last_headsail_cd := 0.0
var _last_headsail_effective_area_m2 := 0.0
var _last_headsail_pressure_center_local_m := Vector3.ZERO
var _last_headsail_lift_force_local_n := Vector3.ZERO
var _last_headsail_drag_force_local_n := Vector3.ZERO
var _last_headsail_net_force_local_n := Vector3.ZERO
var _last_headsail_net_force_world_n := Vector3.ZERO
var _last_headsail_torque_local_nm := Vector3.ZERO
var _last_hull_drag_force_local_n := Vector3.ZERO
var _last_hull_drag_applied_force_local_n := Vector3.ZERO
var _last_hull_lateral_velocity_local_mps := Vector3.ZERO
var _last_hull_lateral_center_from_com_local_m := Vector3.ZERO
var _last_hull_lateral_application_point_local_m := Vector3.ZERO
var _last_hull_lateral_torque_local_nm := Vector3.ZERO
var _last_hull_lateral_yaw_torque_nm := 0.0
var _last_keel_relative_water_velocity_local_mps := Vector3.ZERO
var _last_keel_result: Dictionary = {}
var _last_rudder_relative_water_velocity_local_mps := Vector3.ZERO
var _last_rudder_result: Dictionary = {}
var _last_sail_yaw_torque_nm := 0.0
var _last_headsail_yaw_torque_nm := 0.0
var _last_keel_yaw_torque_nm := 0.0
var _last_rudder_yaw_torque_nm := 0.0
var _last_total_horizontal_force_local_n := Vector3.ZERO
var _last_total_external_yaw_torque_nm := 0.0
var _last_axis_damping_torque_local_nm := Vector3.ZERO
var _last_buoyancy_torque_local_nm := Vector3.ZERO
var _last_engine_force_local_n := Vector3.ZERO
var _last_engine_thrust_forward_axis_n := 0.0
var _last_engine_yaw_torque_nm := 0.0
var _last_engine_calculation_usec := 0
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
var _headsail_aero_calculation_usec_history := PackedInt64Array()
var _keel_calculation_usec_history := PackedInt64Array()
var _rudder_calculation_usec_history := PackedInt64Array()
var _hull_drag_calculation_usec_history := PackedInt64Array()
var _physics_calculation_usec_history := PackedInt64Array()
var _perf_history_count := 0
var _perf_history_cursor := 0
var _anomaly_samples := PackedFloat64Array()
var _anomaly_field_indices: Dictionary = {}
var _anomaly_sample_count := 0
var _anomaly_write_cursor := 0
var _anomaly_elapsed_seconds := 0.0
var _anomaly_frame_count := 0
var _anomaly_capture_armed := false


func _ready() -> void:
	if profile == null:
		push_error("SailboatLabBody requires a SailboatLabProfile resource.")
		set_physics_process(false)
		return
	var main_trim_curve: PackedVector2Array = profile.get("auto_main_trim_curve_points_degrees")
	var headsail_trim_curve: PackedVector2Array = profile.get("auto_headsail_trim_curve_points_degrees")
	if not _auto_sail_trim.configure_curves(main_trim_curve, headsail_trim_curve):
		push_warning("SailboatLabProfile has invalid AUTO sail-trim curve points; using the controller defaults.")

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
	_headsail_visual = get_node_or_null(headsail_visual_path) as MeshInstance3D
	_auxiliary_engine = get_node_or_null(auxiliary_engine_path) as AuxiliaryMarineEngine
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
	_headsail_enabled = bool(profile.get("headsail_enabled"))
	_headsail_area_m2 = float(profile.get("headsail_area_m2"))
	_headsail_head_local_m = profile.get("headsail_head_local_m")
	_headsail_tack_local_m = profile.get("headsail_tack_local_m")
	_headsail_clew_neutral_local_m = profile.get("headsail_clew_neutral_local_m")
	_headsail_pressure_center_offset_from_centroid_m = profile.get("headsail_pressure_center_offset_from_centroid_m")
	_headsail_pressure_center_clew_follow = float(profile.get("headsail_pressure_center_clew_follow"))
	_minimum_headsail_angle_rad = float(profile.get("min_headsail_angle_rad"))
	_maximum_headsail_angle_rad = float(profile.get("max_headsail_angle_rad"))
	_headsail_rotation_speed_rad_s = float(profile.get("headsail_rotation_speed_rad_s"))
	_headsail_maximum_lift_coefficient = float(profile.get("headsail_max_lift_coefficient"))
	_headsail_stall_angle_rad = float(profile.get("headsail_stall_angle_rad"))
	_headsail_no_sail_wind_from_angle_rad = float(profile.get("headsail_no_sail_wind_from_angle_rad"))
	_headsail_full_lift_wind_from_angle_rad = float(profile.get("headsail_full_lift_wind_from_angle_rad"))
	_headsail_base_drag_coefficient = float(profile.get("headsail_base_drag_coefficient"))
	_headsail_induced_drag_factor = float(profile.get("headsail_induced_drag_factor"))
	_headsail_flat_plate_drag_factor = float(profile.get("headsail_flat_plate_drag_factor"))
	_headsail_wrong_side_lift_retention = float(profile.get("headsail_wrong_side_lift_retention"))
	if _headsail_visual != null:
		_headsail_visual.visible = _headsail_enabled
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
	var hull_lateral_center_value: Variant = profile.get("hull_lateral_center_from_com_local_m")
	_hull_lateral_center_from_com_local_m = hull_lateral_center_value if hull_lateral_center_value is Vector3 else Vector3.ZERO
	_point_water_heights_m.resize(FLOAT_POINT_COUNT)
	_point_submergences_m.resize(FLOAT_POINT_COUNT)
	_point_shallow_scales.resize(FLOAT_POINT_COUNT)
	_point_effective_depths_m.resize(FLOAT_POINT_COUNT)
	_point_sample_times_seconds.resize(FLOAT_POINT_COUNT)
	_wave_sample_usec_history.resize(PERF_WINDOW_SIZE)
	_wind_sample_usec_history.resize(PERF_WINDOW_SIZE)
	_aero_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_headsail_aero_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_keel_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_rudder_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_hull_drag_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_physics_calculation_usec_history.resize(PERF_WINDOW_SIZE)
	_anomaly_samples.resize(ANOMALY_SAMPLE_CAPACITY * ANOMALY_FIELDS.size())
	for field_index in range(ANOMALY_FIELDS.size()):
		_anomaly_field_indices[ANOMALY_FIELDS[field_index]] = field_index
	_arm_anomaly_capture()
	_gravity_mps2 = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	if auto_reset_on_ready:
		reset_to_neutral()


func _process(_delta: float) -> void:
	_update_auxiliary_engine_keyboard_input(_delta)
	if _sail_visual_pivot != null:
		# The pivot only mirrors the physics-controlled angle; it does not drive it.
		_sail_visual_pivot.rotation.y = actual_sail_angle_rad
	if _rudder_visual_pivot != null:
		_rudder_visual_pivot.rotation.y = actual_rudder_angle_rad
	if _rudder_angle_marker != null:
		_rudder_angle_marker.rotation.y = actual_rudder_angle_rad
	if _headsail_visual != null:
		_headsail_visual.visible = _headsail_enabled
		if _headsail_visual.has_method("set_sheet_angle"):
			_headsail_visual.call("set_sheet_angle", actual_headsail_angle_rad)


func _input(event: InputEvent) -> void:
	if not keyboard_controls_enabled or not event is InputEventKey:
		return
	var key_event := event as InputEventKey
	if key_event.echo:
		return
	var turn_left := _event_matches_action(key_event, "boat_turn_left")
	var turn_right := _event_matches_action(key_event, "boat_turn_right")
	var trim_main_in := _event_matches_action(key_event, "sailboat_main_trim_ease")
	var trim_main_out := _event_matches_action(key_event, "sailboat_main_trim_out")
	var trim_headsail_in := _event_matches_action(key_event, "sailboat_headsail_trim_ease")
	var trim_headsail_out := _event_matches_action(key_event, "sailboat_headsail_trim_out")
	var toggle_auto := _event_matches_action(key_event, "sailboat_toggle_auto_trim")
	var toggle_engine := _event_matches_action(key_event, "sailboat_engine_toggle")
	var cycle_engine_gear := _event_matches_action(key_event, "sailboat_engine_gear_cycle")
	if turn_left:
		_rudder_key_a_pressed = key_event.pressed
		_update_keyboard_rudder_target()
	elif turn_right:
		_rudder_key_d_pressed = key_event.pressed
		_update_keyboard_rudder_target()
	elif key_event.pressed and trim_headsail_in:
		set_target_headsail_angle(target_headsail_angle_rad - deg_to_rad(10.0))
	elif key_event.pressed and trim_headsail_out:
		set_target_headsail_angle(target_headsail_angle_rad + deg_to_rad(10.0))
	elif key_event.pressed and trim_main_in:
		set_target_sail_angle(target_sail_angle_rad - deg_to_rad(10.0))
	elif key_event.pressed and trim_main_out:
		set_target_sail_angle(target_sail_angle_rad + deg_to_rad(10.0))
	elif key_event.pressed and toggle_auto:
		set_auto_sail_trim_enabled(not auto_sail_trim_enabled)
	elif key_event.pressed and toggle_engine and _auxiliary_engine != null:
		_auxiliary_engine.call("toggle_engine")
	elif key_event.pressed and cycle_engine_gear and _auxiliary_engine != null:
		_auxiliary_engine.call("cycle_gear")
	if key_event.pressed and (turn_left or turn_right or trim_headsail_in or trim_headsail_out or trim_main_in or trim_main_out or toggle_auto or toggle_engine or cycle_engine_gear):
		get_viewport().set_input_as_handled()


func _event_matches_action(event: InputEvent, action_name: StringName) -> bool:
	return InputMap.has_action(action_name) and InputMap.event_is_action(event, action_name)


func _update_auxiliary_engine_keyboard_input(delta: float) -> void:
	if not keyboard_controls_enabled or _auxiliary_engine == null:
		return
	var focused_control := get_viewport().gui_get_focus_owner()
	if is_instance_valid(focused_control):
		return
	var throttle_axis := Input.get_axis("boat_brake", "boat_accelerate")
	if absf(throttle_axis) > 0.001:
		_auxiliary_engine.adjust_target_throttle(throttle_axis * maxf(delta, 0.0) * 0.35)


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
	# Sample the solver state before calculating this tick's forces. If the last
	# solver step produced runaway motion, capture it before resistance/aero math
	# can emit secondary normalization errors.
	_record_anomaly_sample(state)

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
	actual_headsail_angle_rad = AERO_MATH.move_sail_angle_toward(
		actual_headsail_angle_rad,
		target_headsail_angle_rad,
		state.step,
		_headsail_rotation_speed_rad_s,
		_minimum_headsail_angle_rad,
		_maximum_headsail_angle_rad
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
	var total_buoyancy_torque_local := Vector3.ZERO
	var submerged_count := 0
	var body_origin := state.transform.origin
	var body_basis := state.transform.basis
	var angular_velocity := state.angular_velocity
	var linear_velocity := state.linear_velocity
	var local_velocity := body_basis.inverse() * linear_velocity
	_last_longitudinal_velocity_mps = -local_velocity.z
	_last_lateral_velocity_mps = local_velocity.x
	_last_yaw_rate_rad_s = (body_basis.inverse() * angular_velocity).y
	var engine_step_start_usec := Time.get_ticks_usec()
	var engine_result: Dictionary = {}
	var engine_force_local := Vector3.ZERO
	var engine_thrust_forward_axis_n := 0.0
	var engine_yaw_torque_nm := 0.0
	if _auxiliary_engine != null:
		engine_result = _auxiliary_engine.simulate_physics_step(state.step, _last_longitudinal_velocity_mps)
		engine_force_local = engine_result.get("force_local_n", Vector3.ZERO)
		engine_thrust_forward_axis_n = float(engine_result.get("thrust_forward_axis_n", 0.0))
		var engine_point_local: Vector3 = engine_result.get("application_point_local_m", Vector3(0.0, center_of_mass.y, 2.65))
		# Keep the propeller thrust line level with the body's effective COM to
		# avoid adding an artificial pitch torque. The aft Z offset remains real.
		engine_point_local.y = center_of_mass.y
		engine_yaw_torque_nm = (engine_point_local - center_of_mass).cross(engine_force_local).y
		if engine_force_local.length_squared() > 0.0:
			state.apply_force(body_basis * engine_force_local, body_basis * engine_point_local)
	_last_engine_calculation_usec = Time.get_ticks_usec() - engine_step_start_usec
	_last_engine_force_local_n = engine_force_local
	_last_engine_thrust_forward_axis_n = engine_thrust_forward_axis_n
	_last_engine_yaw_torque_nm = engine_yaw_torque_nm
	var sail_pivot_rotation := Basis(Vector3.UP, actual_sail_angle_rad)
	var sail_pressure_center_local := (
		_sail_pivot_local_m
		+ sail_pivot_rotation * _sail_pressure_center_from_pivot_m
	)
	var sail_center_offset_world := body_basis * sail_pressure_center_local
	var sail_center_world := body_origin + sail_center_offset_world
	var sail_arm_from_com_world := world_arm_from_local_point(sail_pressure_center_local, center_of_mass, body_basis)
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
		sail_arm_from_com_world,
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
	var headsail_clew_local := AERO_MATH.headsail_clew_from_sheet(
		_headsail_tack_local_m,
		_headsail_clew_neutral_local_m,
		actual_headsail_angle_rad
	)
	# Sheeting changes orientation, not the amount of sail cloth.
	var headsail_effective_area := _headsail_area_m2
	var headsail_pressure_center_local := AERO_MATH.triangular_sail_centroid(
		_headsail_head_local_m,
		_headsail_tack_local_m,
		_headsail_clew_neutral_local_m
	) + _headsail_pressure_center_offset_from_centroid_m
	headsail_pressure_center_local += (headsail_clew_local - _headsail_clew_neutral_local_m) * _headsail_pressure_center_clew_follow
	var headsail_chord := headsail_clew_local - _headsail_tack_local_m
	var headsail_chord_xz := Vector2(headsail_chord.x, headsail_chord.z)
	var headsail_arm_from_com_world := world_arm_from_local_point(headsail_pressure_center_local, center_of_mass, body_basis)
	var headsail_apparent := AERO_MATH.calculate_apparent_wind(
		true_wind_world,
		linear_velocity,
		angular_velocity,
		headsail_arm_from_com_world,
		body_basis
	)
	var headsail_aero_start_usec := Time.get_ticks_usec()
	var headsail_result: Dictionary = _empty_sail_result()
	if _headsail_enabled:
		headsail_result = AERO_MATH.calculate_sail_forces_for_chord(
			headsail_apparent.get("apparent_velocity_local_mps", Vector3.ZERO),
			headsail_chord_xz,
			headsail_effective_area,
			_air_density_kg_m3,
			_headsail_maximum_lift_coefficient,
			_headsail_stall_angle_rad,
			_headsail_base_drag_coefficient,
			_headsail_induced_drag_factor,
			_headsail_flat_plate_drag_factor,
			_headsail_no_sail_wind_from_angle_rad,
			_headsail_full_lift_wind_from_angle_rad,
			_headsail_wrong_side_lift_retention
		)
	var headsail_aero_calculation_usec := Time.get_ticks_usec() - headsail_aero_start_usec
	aero_calculation_usec = Time.get_ticks_usec() - aero_start_usec
	var sail_lift_local: Vector3 = sail_result.get("lift_force_local_n", Vector3.ZERO)
	var sail_drag_local: Vector3 = sail_result.get("drag_force_local_n", Vector3.ZERO)
	var sail_net_local: Vector3 = sail_result.get("net_force_local_n", Vector3.ZERO)
	var sail_net_world := body_basis * sail_net_local
	var sail_yaw_torque := (sail_pressure_center_local - center_of_mass).cross(sail_net_local).y
	if _lab_sail_forces_enabled and sail_net_world.length_squared() > 0.0:
		# Offset is relative to the rigid-body origin; the engine solves torque
		# about the actual centre of mass, including the profile's COM offset.
		state.apply_force(sail_net_world, sail_center_offset_world)
	var headsail_lift_local: Vector3 = headsail_result.get("lift_force_local_n", Vector3.ZERO)
	var headsail_drag_local: Vector3 = headsail_result.get("drag_force_local_n", Vector3.ZERO)
	var headsail_net_local: Vector3 = headsail_result.get("net_force_local_n", Vector3.ZERO)
	var headsail_net_world := body_basis * headsail_net_local
	var headsail_force_offset_world := body_basis * headsail_pressure_center_local
	var headsail_torque_local := (headsail_pressure_center_local - center_of_mass).cross(headsail_net_local)
	var headsail_yaw_torque := headsail_torque_local.y
	if _lab_sail_forces_enabled and _headsail_enabled and headsail_net_world.length_squared() > 0.0:
		state.apply_force(headsail_net_world, headsail_force_offset_world)
	var local_velocity_through_water := body_basis.inverse() * (linear_velocity - _water_current_world_mps)
	var hull_lateral_center_from_com_local_m := _hull_lateral_center_from_com_local_m + Vector3(0.0, 0.0, _test_hull_lateral_application_offset_z_m)
	var hull_lateral_velocity_local_mps := local_velocity_through_water
	if not hull_lateral_center_from_com_local_m.is_zero_approx():
		var hull_lateral_arm_from_com_world_m := body_basis * hull_lateral_center_from_com_local_m
		var hull_lateral_point_velocity_world_mps := linear_velocity + angular_velocity.cross(hull_lateral_arm_from_com_world_m)
		hull_lateral_velocity_local_mps = body_basis.inverse() * (hull_lateral_point_velocity_world_mps - _water_current_world_mps)
	var hull_drag_velocity_local_mps := Vector3(
		hull_lateral_velocity_local_mps.x,
		local_velocity_through_water.y,
		local_velocity_through_water.z
	)
	var hull_drag_start_usec := Time.get_ticks_usec()
	var hull_drag_local := HYDRO_MATH.calculate_hull_resistance(
		hull_drag_velocity_local_mps,
		_hull_longitudinal_drag_linear,
		_hull_longitudinal_drag_quadratic,
		_hull_lateral_drag_linear,
		_hull_lateral_drag_quadratic,
		mass * _gravity_mps2 * _hull_drag_max_force_weight_ratio
	)
	hull_drag_calculation_usec = Time.get_ticks_usec() - hull_drag_start_usec
	var hull_lateral_yaw_torque_nm := 0.0
	var hull_lateral_application_point_local_m := center_of_mass + hull_lateral_center_from_com_local_m
	var hull_applied_force_local := hull_drag_local
	var hull_lateral_torque_local_nm := Vector3.ZERO
	if not hull_lateral_center_from_com_local_m.is_zero_approx():
		# Apply the one computed lateral resultant at its COM-relative point.
		# Longitudinal resistance remains based on COM flow and applied centrally.
		# apply_force's position is a body-origin offset, so convert the complete
		# COM-local point through the rigid body's basis.
		var hull_central_force_local := Vector3(0.0, hull_drag_local.y, hull_drag_local.z)
		var hull_lateral_force_local := Vector3(hull_drag_local.x, 0.0, 0.0)
		hull_applied_force_local = hull_central_force_local + hull_lateral_force_local
		if hull_central_force_local.length_squared() > 0.0:
			state.apply_central_force(body_basis * hull_central_force_local)
		if hull_lateral_force_local.length_squared() > 0.0:
			state.apply_force(body_basis * hull_lateral_force_local, body_basis * hull_lateral_application_point_local_m)
		hull_lateral_torque_local_nm = hull_lateral_center_from_com_local_m.cross(hull_lateral_force_local)
		hull_lateral_yaw_torque_nm = hull_lateral_torque_local_nm.y
	else:
		# Keep the default path byte-for-byte equivalent in its force application.
		if hull_drag_local.length_squared() > 0.0:
			state.apply_central_force(body_basis * hull_drag_local)
			hull_applied_force_local = hull_drag_local

	var keel_offset_world := body_basis * _keel_center_local_m
	var keel_arm_from_com_world := world_arm_from_local_point(_keel_center_local_m, center_of_mass, body_basis)
	var keel_point_velocity_world := linear_velocity + angular_velocity.cross(keel_arm_from_com_world)
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
	var rudder_arm_from_com_world := world_arm_from_local_point(_rudder_center_local_m, center_of_mass, body_basis)
	var rudder_point_velocity_world := linear_velocity + angular_velocity.cross(rudder_arm_from_com_world)
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
	_last_hull_drag_applied_force_local_n = hull_applied_force_local
	_last_hull_lateral_velocity_local_mps = hull_lateral_velocity_local_mps
	_last_hull_lateral_center_from_com_local_m = hull_lateral_center_from_com_local_m
	_last_hull_lateral_application_point_local_m = hull_lateral_application_point_local_m
	_last_hull_lateral_torque_local_nm = hull_lateral_torque_local_nm
	_last_hull_lateral_yaw_torque_nm = hull_lateral_yaw_torque_nm
	_last_keel_relative_water_velocity_local_mps = keel_velocity_local
	_last_keel_result = keel_result
	_last_rudder_relative_water_velocity_local_mps = rudder_velocity_local
	_last_rudder_result = rudder_result
	_last_sail_yaw_torque_nm = sail_yaw_torque
	_last_headsail_yaw_torque_nm = headsail_yaw_torque
	_last_keel_yaw_torque_nm = keel_yaw_torque
	_last_rudder_yaw_torque_nm = rudder_yaw_torque
	var applied_sail_force_local := sail_net_local if _lab_sail_forces_enabled else Vector3.ZERO
	var applied_headsail_force_local := headsail_net_local if _lab_sail_forces_enabled and _headsail_enabled else Vector3.ZERO
	var applied_sail_yaw_torque := sail_yaw_torque if _lab_sail_forces_enabled else 0.0
	var applied_headsail_yaw_torque := headsail_yaw_torque if _lab_sail_forces_enabled and _headsail_enabled else 0.0
	_last_total_horizontal_force_local_n = applied_sail_force_local + applied_headsail_force_local + hull_drag_local + keel_force_local + rudder_force_local + engine_force_local
	_last_total_external_yaw_torque_nm = applied_sail_yaw_torque + applied_headsail_yaw_torque + hull_lateral_yaw_torque_nm + keel_yaw_torque + rudder_yaw_torque + engine_yaw_torque_nm
	_last_true_wind_world_mps = true_wind_world
	_last_true_wind_from_degrees = true_wind_from_degrees
	_last_apparent_wind_world_mps = apparent.get("apparent_velocity_world_mps", Vector3.ZERO)
	_last_apparent_wind_local_mps = apparent.get("apparent_velocity_local_mps", Vector3.ZERO)
	_last_apparent_wind_speed_mps = float(apparent.get("apparent_speed_mps", 0.0))
	_last_apparent_wind_from_angle_degrees = float(apparent.get("apparent_from_angle_degrees", 0.0))
	_last_windward_side = str(apparent.get("windward_side", "无有效视风"))
	_update_auto_sail_trim_from_cached_wind(body_basis)
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
	_last_headsail_apparent_wind_local_mps = headsail_apparent.get("apparent_velocity_local_mps", Vector3.ZERO)
	_last_headsail_apparent_wind_speed_mps = float(headsail_apparent.get("apparent_speed_mps", 0.0))
	_last_headsail_arm_from_com_world_m = headsail_arm_from_com_world
	_last_headsail_angle_of_attack_rad = float(headsail_result.get("angle_of_attack_rad", 0.0))
	_last_headsail_luffing_scale = float(headsail_result.get("luffing_scale", 0.0))
	_last_headsail_wrong_side_lift_scale = float(headsail_result.get("wrong_side_lift_scale", 1.0))
	_last_headsail_cl = float(headsail_result.get("cl", 0.0))
	_last_headsail_cd = float(headsail_result.get("cd", 0.0))
	_last_headsail_effective_area_m2 = headsail_effective_area if _headsail_enabled else 0.0
	_last_headsail_pressure_center_local_m = headsail_pressure_center_local
	_last_headsail_lift_force_local_n = headsail_lift_local
	_last_headsail_drag_force_local_n = headsail_drag_local
	_last_headsail_net_force_local_n = headsail_net_local
	_last_headsail_net_force_world_n = headsail_net_world
	_last_headsail_torque_local_nm = headsail_torque_local
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
		var float_arm_from_com_world := world_arm_from_local_point(_float_offsets[index], center_of_mass, body_basis)
		var point_velocity := linear_velocity + angular_velocity.cross(float_arm_from_com_world)
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
		if p22_extended_telemetry_enabled:
			# The applied force is world-up, while the reported arm is body-local.
			# Rotate the force into the same local frame before calculating the
			# read-only telemetry moment. This does not change the force applied above.
			var buoyancy_force_local := body_basis.inverse() * (Vector3.UP * force_y)
			total_buoyancy_torque_local += (_float_offsets[index] - center_of_mass).cross(buoyancy_force_local)

	_apply_axis_damping(state, body_basis)
	_last_total_buoyancy_n = total_buoyancy
	_last_buoyancy_torque_local_nm = total_buoyancy_torque_local if p22_extended_telemetry_enabled else Vector3.ZERO
	_last_submerged_count = submerged_count
	_last_physics_delta = state.step
	_last_wave_time_seconds = sample_wave_time
	_last_wave_query_count = query_count
	_last_wave_sample_usec = sample_usec
	_last_wind_query_count = wind_query_count
	_last_wind_sample_usec = wind_sample_usec
	_last_aero_calculation_usec = aero_calculation_usec
	_last_headsail_aero_calculation_usec = headsail_aero_calculation_usec
	var local_rotation := body_basis.get_euler()
	_last_pitch_rad = local_rotation.x
	_last_roll_rad = local_rotation.z
	_last_calculation_usec = Time.get_ticks_usec() - start_usec
	_record_performance(
		sample_usec,
		wind_sample_usec,
		aero_calculation_usec,
		headsail_aero_calculation_usec,
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
	_last_axis_damping_torque_local_nm = local_damping_torque
	if local_damping_torque.length_squared() <= 0.0:
		return
	state.apply_torque(body_basis * local_damping_torque)


func get_debug_snapshot() -> Dictionary:
	var wave_timing := _summarize_history(_wave_sample_usec_history)
	var wind_timing := _summarize_history(_wind_sample_usec_history)
	var aero_timing := _summarize_history(_aero_calculation_usec_history)
	var headsail_aero_timing := _summarize_history(_headsail_aero_calculation_usec_history)
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
		"center_of_mass_local_m": center_of_mass,
		"p22_extended_telemetry_enabled": p22_extended_telemetry_enabled,
		"p22_buoyancy_torque_local_nm": _last_buoyancy_torque_local_nm,
		"p22_axis_damping_torque_local_nm": _last_axis_damping_torque_local_nm,
		"auxiliary_engine": get_auxiliary_engine_snapshot(),
		"engine_force_local_n": _last_engine_force_local_n,
		"engine_thrust_forward_axis_n": _last_engine_thrust_forward_axis_n,
		"engine_yaw_torque_nm": _last_engine_yaw_torque_nm,
		"engine_calculation_usec": _last_engine_calculation_usec,
		"effective_sail_forces_enabled": _lab_sail_forces_enabled,
		"linear_velocity_mps": linear_velocity,
		"linear_speed_mps": linear_velocity.length(),
		"angular_velocity_rad_s": angular_velocity,
		"roll_degrees": rad_to_deg(_last_roll_rad),
		"pitch_degrees": rad_to_deg(_last_pitch_rad),
		"heading_degrees": fposmod(rad_to_deg(atan2(-global_basis.z.x, global_basis.z.z)), 360.0),
		"water_height_m": water_height_m,
		"buoyancy_total_n": _last_total_buoyancy_n,
		"float_point_count": _float_offsets.size(),
		"float_point_offsets_local_m": _float_offsets,
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
		"headsail_aero_calculation_usec": _last_headsail_aero_calculation_usec,
		"headsail_aero_calculation_average_usec": int(headsail_aero_timing.get("average_usec", 0)),
		"headsail_aero_calculation_p95_usec": int(headsail_aero_timing.get("p95_usec", 0)),
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
		"sail_apparent_wind_speed_mps": _last_apparent_wind_speed_mps,
		"sail_apparent_wind_from_angle_degrees": _last_apparent_wind_from_angle_degrees,
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
		"headsail_enabled": _headsail_enabled,
		"auto_sail_trim_enabled": auto_sail_trim_enabled,
		"auto_sail_trim": get_auto_sail_trim_snapshot(),
		"auto_trim_calculation_usec": _last_auto_trim_calculation_usec,
		"headsail_area_m2": _headsail_area_m2,
		"headsail_effective_area_m2": _last_headsail_effective_area_m2,
		"target_headsail_angle_rad": target_headsail_angle_rad,
		"actual_headsail_angle_rad": actual_headsail_angle_rad,
		"min_headsail_angle_rad": _minimum_headsail_angle_rad,
		"max_headsail_angle_rad": _maximum_headsail_angle_rad,
		"headsail_rotation_speed_rad_s": _headsail_rotation_speed_rad_s,
		"headsail_head_local_m": _headsail_head_local_m,
		"headsail_tack_local_m": _headsail_tack_local_m,
		"headsail_clew_local_m": AERO_MATH.headsail_clew_from_sheet(_headsail_tack_local_m, _headsail_clew_neutral_local_m, actual_headsail_angle_rad),
		"headsail_pressure_center_local_m": _last_headsail_pressure_center_local_m,
		"headsail_apparent_wind_local_mps": _last_headsail_apparent_wind_local_mps,
		"headsail_apparent_wind_speed_mps": _last_headsail_apparent_wind_speed_mps,
		"headsail_arm_from_com_world_m": _last_headsail_arm_from_com_world_m,
		"headsail_angle_of_attack_rad": _last_headsail_angle_of_attack_rad,
		"headsail_luffing_scale": _last_headsail_luffing_scale,
		"headsail_wrong_side_lift_scale": _last_headsail_wrong_side_lift_scale,
		"headsail_cl": _last_headsail_cl,
		"headsail_cd": _last_headsail_cd,
		"headsail_lift_force_local_n": _last_headsail_lift_force_local_n,
		"headsail_drag_force_local_n": _last_headsail_drag_force_local_n,
		"headsail_net_force_local_n": _last_headsail_net_force_local_n,
		"headsail_net_force_world_n": _last_headsail_net_force_world_n,
		"headsail_torque_local_nm": _last_headsail_torque_local_nm,
		"headsail_roll_torque_local_nm": _last_headsail_torque_local_nm.z,
		"headsail_yaw_torque_nm": _last_headsail_yaw_torque_nm,
		"hull_drag_force_local_n": _last_hull_drag_force_local_n,
		"hull_drag_applied_force_local_n": _last_hull_drag_applied_force_local_n,
		"hull_lateral_force_local_n": Vector3(_last_hull_drag_force_local_n.x, 0.0, 0.0),
		"hull_lateral_velocity_local_mps": _last_hull_lateral_velocity_local_mps,
		"hull_lateral_center_from_com_local_m": _last_hull_lateral_center_from_com_local_m,
		"hull_lateral_application_point_local_m": _last_hull_lateral_application_point_local_m,
		"hull_lateral_application_offset_z_m": _last_hull_lateral_center_from_com_local_m.z,
		"hull_lateral_torque_local_nm": _last_hull_lateral_torque_local_nm,
		"hull_lateral_yaw_torque_nm": _last_hull_lateral_yaw_torque_nm,
		"keel_center_local_m": _keel_center_local_m,
		"keel_area_m2": _keel_area_m2,
		"keel_result": _last_keel_result.duplicate(true),
		"keel_relative_water_velocity_local_mps": _last_keel_relative_water_velocity_local_mps,
		"keel_water_speed_mps": float(_last_keel_result.get("water_speed_mps", 0.0)),
		"keel_side_slip_angle_rad": float(_last_keel_result.get("side_slip_angle_rad", 0.0)),
		"keel_angle_of_attack_rad": float(_last_keel_result.get("angle_of_attack_rad", 0.0)),
		"keel_force_local_n": _last_keel_result.get("net_force_local_n", Vector3.ZERO),
		"keel_yaw_torque_nm": _last_keel_yaw_torque_nm,
		"rudder_center_local_m": _rudder_center_local_m,
		"rudder_area_m2": _rudder_area_m2,
		"rudder_result": _last_rudder_result.duplicate(true),
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
		+ _last_headsail_yaw_torque_nm
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
		"headsail_force_local_n": _last_headsail_net_force_local_n,
		"headsail_torque_local_nm": _last_headsail_torque_local_nm,
		"headsail_roll_torque_local_nm": _last_headsail_torque_local_nm.z,
		"headsail_yaw_torque_local_nm": _last_headsail_yaw_torque_nm,
		"headsail_yaw_torque_world_vertical_nm": (global_basis * Vector3(0.0, _last_headsail_yaw_torque_nm, 0.0)).y,
		"keel_force_local_n": keel_force,
		"keel_yaw_torque_local_nm": _last_keel_yaw_torque_nm,
		"keel_yaw_torque_world_vertical_nm": (global_basis * Vector3(0.0, _last_keel_yaw_torque_nm, 0.0)).y,
		"rudder_force_local_n": rudder_force,
		"rudder_water_speed_mps": float(_last_rudder_result.get("water_speed_mps", 0.0)),
		"rudder_yaw_torque_local_nm": _last_rudder_yaw_torque_nm,
		"rudder_yaw_torque_world_vertical_nm": (global_basis * Vector3(0.0, _last_rudder_yaw_torque_nm, 0.0)).y,
		"hull_drag_force_local_n": _last_hull_drag_force_local_n,
		"hull_drag_applied_force_local_n": _last_hull_drag_applied_force_local_n,
		"hull_lateral_force_local_n": Vector3(_last_hull_drag_force_local_n.x, 0.0, 0.0),
		"hull_lateral_velocity_local_mps": _last_hull_lateral_velocity_local_mps,
		"hull_lateral_center_from_com_local_m": _last_hull_lateral_center_from_com_local_m,
		"hull_lateral_application_point_local_m": _last_hull_lateral_application_point_local_m,
		"hull_lateral_application_offset_z_m": _last_hull_lateral_center_from_com_local_m.z,
		"hull_lateral_torque_local_nm": _last_hull_lateral_torque_local_nm,
		"hull_lateral_yaw_torque_local_nm": _last_hull_lateral_yaw_torque_nm,
		"total_force_local_n": _last_total_horizontal_force_local_n,
		"explicit_yaw_damping_torque_local_nm": explicit_yaw_damping,
		"summed_measured_yaw_torque_local_nm": local_total_yaw,
		"summed_measured_yaw_torque_world_vertical_nm": world_total_yaw_vector.y,
		"actual_sail_angle_rad": actual_sail_angle_rad,
		"target_sail_angle_rad": target_sail_angle_rad,
		"actual_headsail_angle_rad": actual_headsail_angle_rad,
		"target_headsail_angle_rad": target_headsail_angle_rad,
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
		"headsail_enabled": _headsail_enabled,
		"auto_sail_trim_enabled": auto_sail_trim_enabled,
		"auto_sail_trim": get_auto_sail_trim_snapshot(),
		"actual_headsail_angle_rad": actual_headsail_angle_rad,
		"target_headsail_angle_rad": target_headsail_angle_rad,
		"headsail_apparent_wind_speed_mps": _last_headsail_apparent_wind_speed_mps,
		"headsail_arm_from_com_world_m": _last_headsail_arm_from_com_world_m,
		"headsail_angle_of_attack_rad": _last_headsail_angle_of_attack_rad,
		"headsail_luffing_scale": _last_headsail_luffing_scale,
		"headsail_net_force_local_n": _last_headsail_net_force_local_n,
		"headsail_yaw_torque_nm": _last_headsail_yaw_torque_nm,
		"actual_rudder_angle_rad": actual_rudder_angle_rad,
		"target_rudder_angle_rad": target_rudder_angle_rad,
		"max_rudder_angle_rad": _maximum_rudder_angle_rad,
		"keel_side_slip_angle_rad": float(_last_keel_result.get("side_slip_angle_rad", 0.0)),
		"wind_query_count_per_tick": _last_wind_query_count,
		"wave_query_count_per_tick": _last_wave_query_count,
		"auxiliary_engine": get_auxiliary_engine_snapshot(),
	}


func prepare_for_main_spawn(reference_transform: Transform3D) -> void:
	## One-time vessel-selection placement. Normal sailing remains solver-driven.
	if profile == null:
		return
	var forward := -reference_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		forward = Vector3.FORWARD
	else:
		forward = forward.normalized()
	var yaw := atan2(-forward.x, -forward.z)
	var mean_float_y := 0.0
	for offset in _float_offsets:
		mean_float_y += offset.y
	mean_float_y /= float(maxi(_float_offsets.size(), 1))
	var water_height := water_height_m
	if _wave_sampler != null:
		var sample := _wave_sampler.sample_physics_surface(
			Vector3(reference_transform.origin.x, water_height_m, reference_transform.origin.z),
			_wave_sampler.get_effective_wave_time_seconds()
		)
		water_height = float(sample.get("height", water_height_m))
	var spawn_origin := Vector3(
		reference_transform.origin.x,
		water_height - float(profile.get("rest_submergence_m")) - mean_float_y,
		reference_transform.origin.z
	)
	global_transform = Transform3D(Basis(Vector3.UP, yaw), spawn_origin)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	sleeping = false
	_reset_controls_for_main_spawn()
	_arm_anomaly_capture()


func set_vessel_active(active: bool) -> void:
	visible = active
	freeze = not active
	var collision_shape := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if collision_shape != null:
		collision_shape.disabled = not active
	if active:
		sleeping = false
		_arm_anomaly_capture()
	else:
		keyboard_controls_enabled = false
		clear_rudder_input()
		if _auxiliary_engine != null:
			_auxiliary_engine.stop_for_vessel_switch()


func set_keyboard_controls_enabled(enabled: bool) -> void:
	keyboard_controls_enabled = enabled
	if not enabled:
		_rudder_key_a_pressed = false
		_rudder_key_d_pressed = false
		clear_rudder_input()


func has_auxiliary_engine() -> bool:
	return _auxiliary_engine != null and _auxiliary_engine.profile != null


func get_auxiliary_engine_snapshot() -> Dictionary:
	if _auxiliary_engine == null:
		return {"available": false}
	return _auxiliary_engine.get_snapshot(_last_longitudinal_velocity_mps)


func toggle_auxiliary_engine() -> bool:
	return bool(_auxiliary_engine.call("toggle_engine")) if _auxiliary_engine != null else false


func start_auxiliary_engine() -> bool:
	return bool(_auxiliary_engine.call("start_engine")) if _auxiliary_engine != null else false


func stop_auxiliary_engine() -> void:
	if _auxiliary_engine != null:
		_auxiliary_engine.call("stop_engine")


func set_auxiliary_engine_gear(gear_value: int) -> bool:
	return bool(_auxiliary_engine.call("set_gear", gear_value)) if _auxiliary_engine != null else false


func set_auxiliary_engine_target_throttle(throttle: float) -> void:
	if _auxiliary_engine != null:
		_auxiliary_engine.call("set_target_throttle", throttle)


func set_sail_forces_enabled_for_lab_test(enabled: bool) -> void:
	## Test-panel override only; normal Main instances keep this enabled.
	_lab_sail_forces_enabled = enabled


func reset_auxiliary_engine_for_lab_test(fuel_remaining_l: float = -1.0) -> void:
	if _auxiliary_engine != null:
		_auxiliary_engine.reset_for_lab_test(fuel_remaining_l)


func set_auxiliary_fuel_for_lab_test(fuel_remaining_l: float) -> void:
	if _auxiliary_engine != null:
		_auxiliary_engine.set_fuel_for_lab_test(fuel_remaining_l)


func get_audio_motion_state() -> Dictionary:
	var local_angular_velocity := global_basis.inverse() * angular_velocity
	return {
		"heave_speed_mps": absf(linear_velocity.y),
		"pitch_rate_rad_s": absf(local_angular_velocity.x),
		"roll_rate_rad_s": absf(local_angular_velocity.z),
		"available": true,
	}


func _reset_controls_for_main_spawn() -> void:
	target_sail_angle_rad = 0.0
	actual_sail_angle_rad = 0.0
	target_headsail_angle_rad = 0.0
	actual_headsail_angle_rad = 0.0
	_headsail_enabled = bool(profile.get("headsail_enabled"))
	set_auto_sail_trim_enabled(false)
	_auto_sail_trim.reset(0.0, 0.0)
	_last_auto_trim_result.clear()
	target_rudder_angle_rad = 0.0
	actual_rudder_angle_rad = 0.0
	_rudder_key_a_pressed = false
	_rudder_key_d_pressed = false
	_rudder_keyboard_active = false
	if _auxiliary_engine != null:
		_auxiliary_engine.stop_for_vessel_switch()
	if _headsail_visual != null:
		_headsail_visual.visible = _headsail_enabled


func set_dynamic_waves_enabled(enabled: bool) -> void:
	dynamic_waves_enabled = enabled and _wave_sampler != null
	if not dynamic_waves_enabled:
		_last_wave_query_count = 0
		_last_wave_sample_usec = 0


func _record_performance(
	wave_usec: int,
	wind_usec: int,
	aero_usec: int,
	headsail_aero_usec: int,
	keel_usec: int,
	rudder_usec: int,
	hull_drag_usec: int,
	total_usec: int
) -> void:
	_wave_sample_usec_history[_perf_history_cursor] = wave_usec
	_wind_sample_usec_history[_perf_history_cursor] = wind_usec
	_aero_calculation_usec_history[_perf_history_cursor] = aero_usec
	_headsail_aero_calculation_usec_history[_perf_history_cursor] = headsail_aero_usec
	_keel_calculation_usec_history[_perf_history_cursor] = keel_usec
	_rudder_calculation_usec_history[_perf_history_cursor] = rudder_usec
	_hull_drag_calculation_usec_history[_perf_history_cursor] = hull_drag_usec
	_physics_calculation_usec_history[_perf_history_cursor] = total_usec
	_last_keel_calculation_usec = keel_usec
	_last_rudder_calculation_usec = rudder_usec
	_last_hull_drag_calculation_usec = hull_drag_usec
	_perf_history_cursor = (_perf_history_cursor + 1) % PERF_WINDOW_SIZE
	_perf_history_count = mini(_perf_history_count + 1, PERF_WINDOW_SIZE)


func _arm_anomaly_capture() -> void:
	_anomaly_sample_count = 0
	_anomaly_write_cursor = 0
	_anomaly_elapsed_seconds = 0.0
	_anomaly_frame_count = 0
	_anomaly_capture_armed = OS.is_debug_build() and enable_debug_anomaly_capture
	if not _anomaly_samples.is_empty():
		_anomaly_samples.fill(0.0)


func _record_anomaly_sample(state: PhysicsDirectBodyState3D) -> void:
	if not _anomaly_capture_armed:
		return
	var transform_snapshot := state.transform
	var body_basis := transform_snapshot.basis
	var position := transform_snapshot.origin
	var linear := state.linear_velocity
	var angular := state.angular_velocity
	_anomaly_elapsed_seconds += state.step if is_finite(state.step) and state.step > 0.0 else 0.0
	var row_base := _anomaly_write_cursor * ANOMALY_FIELDS.size()
	var linear_speed := _safe_vector_length(linear)
	var angular_speed := _safe_vector_length(angular)
	var tilt_degrees := _tilt_from_up_degrees(body_basis.y)
	var linear_acceleration := Vector3.ZERO
	var angular_acceleration := Vector3.ZERO
	if _anomaly_sample_count > 0 and is_finite(state.step) and state.step > 0.0:
		var previous_slot := _anomaly_write_cursor - 1
		if previous_slot < 0:
			previous_slot += ANOMALY_SAMPLE_CAPACITY
		var previous_base := previous_slot * ANOMALY_FIELDS.size()
		var velocity_index := int(_anomaly_field_indices["linear_velocity_x_mps"])
		var angular_velocity_index := int(_anomaly_field_indices["angular_velocity_x_rad_s"])
		var previous_linear := Vector3(
			_anomaly_samples[previous_base + velocity_index],
			_anomaly_samples[previous_base + velocity_index + 1],
			_anomaly_samples[previous_base + velocity_index + 2]
		)
		var previous_angular := Vector3(
			_anomaly_samples[previous_base + angular_velocity_index],
			_anomaly_samples[previous_base + angular_velocity_index + 1],
			_anomaly_samples[previous_base + angular_velocity_index + 2]
		)
		linear_acceleration = (linear - previous_linear) / state.step
		angular_acceleration = (angular - previous_angular) / state.step
	var keel_force: Vector3 = _last_keel_result.get("net_force_local_n", Vector3.ZERO)
	var rudder_force: Vector3 = _last_rudder_result.get("net_force_local_n", Vector3.ZERO)
	_anomaly_frame_count += 1
	_anomaly_set(row_base, "physics_frame", float(_anomaly_frame_count))
	_anomaly_set(row_base, "sim_time_s", _anomaly_elapsed_seconds)
	_anomaly_set(row_base, "step_s", state.step)
	_anomaly_set_vector(row_base, "position_x_m", position)
	_anomaly_set_vector(row_base, "basis_x_x", body_basis.x)
	_anomaly_set_vector(row_base, "basis_y_x", body_basis.y)
	_anomaly_set_vector(row_base, "basis_z_x", body_basis.z)
	_anomaly_set_vector(row_base, "linear_velocity_x_mps", linear)
	_anomaly_set_vector(row_base, "angular_velocity_x_rad_s", angular)
	_anomaly_set_vector(row_base, "linear_acceleration_x_mps2", linear_acceleration)
	_anomaly_set_vector(row_base, "angular_acceleration_x_rad_s2", angular_acceleration)
	_anomaly_set(row_base, "speed_mps", linear_speed)
	_anomaly_set(row_base, "angular_speed_rad_s", angular_speed)
	_anomaly_set(row_base, "tilt_from_world_up_deg", tilt_degrees)
	_anomaly_set(row_base, "local_longitudinal_speed_mps", _last_longitudinal_velocity_mps)
	_anomaly_set(row_base, "local_lateral_speed_mps", _last_lateral_velocity_mps)
	_anomaly_set(row_base, "local_yaw_rate_rad_s", _last_yaw_rate_rad_s)
	_anomaly_set_vector(row_base, "true_wind_x_mps", _last_true_wind_world_mps)
	_anomaly_set(row_base, "true_wind_from_deg", _last_true_wind_from_degrees)
	_anomaly_set_vector(row_base, "apparent_wind_local_x_mps", _last_apparent_wind_local_mps)
	_anomaly_set(row_base, "apparent_wind_speed_mps", _last_apparent_wind_speed_mps)
	_anomaly_set(row_base, "apparent_wind_from_angle_deg", _last_apparent_wind_from_angle_degrees)
	_anomaly_set(row_base, "main_sail_actual_rad", actual_sail_angle_rad)
	_anomaly_set(row_base, "main_sail_target_rad", target_sail_angle_rad)
	_anomaly_set(row_base, "main_sail_aoa_rad", _last_sail_angle_of_attack_rad)
	_anomaly_set(row_base, "main_sail_dynamic_pressure_pa", _last_sail_dynamic_pressure_pa)
	_anomaly_set(row_base, "headsail_enabled", 1.0 if _headsail_enabled else 0.0)
	_anomaly_set(row_base, "headsail_actual_rad", actual_headsail_angle_rad)
	_anomaly_set(row_base, "headsail_target_rad", target_headsail_angle_rad)
	_anomaly_set(row_base, "headsail_aoa_rad", _last_headsail_angle_of_attack_rad)
	_anomaly_set(row_base, "headsail_dynamic_pressure_pa", _last_headsail_apparent_wind_speed_mps * _last_headsail_apparent_wind_speed_mps * 0.5 * _air_density_kg_m3)
	_anomaly_set(row_base, "rudder_actual_rad", actual_rudder_angle_rad)
	_anomaly_set(row_base, "rudder_target_rad", target_rudder_angle_rad)
	_anomaly_set_vector(row_base, "main_force_local_x_n", _last_sail_net_force_local_n)
	_anomaly_set_vector(row_base, "headsail_force_local_x_n", _last_headsail_net_force_local_n)
	_anomaly_set_vector(row_base, "hull_drag_local_x_n", _last_hull_drag_force_local_n)
	_anomaly_set_vector(row_base, "keel_force_local_x_n", keel_force)
	_anomaly_set_vector(row_base, "rudder_force_local_x_n", rudder_force)
	_anomaly_set(row_base, "main_yaw_torque_nm", _last_sail_yaw_torque_nm)
	_anomaly_set(row_base, "headsail_yaw_torque_nm", _last_headsail_yaw_torque_nm)
	_anomaly_set(row_base, "keel_yaw_torque_nm", _last_keel_yaw_torque_nm)
	_anomaly_set(row_base, "rudder_yaw_torque_nm", _last_rudder_yaw_torque_nm)
	_anomaly_set(row_base, "total_explicit_yaw_torque_nm", _last_total_external_yaw_torque_nm)
	_anomaly_set_vector(row_base, "total_horizontal_force_local_x_n", _last_total_horizontal_force_local_n)
	_anomaly_set(row_base, "total_buoyancy_n", _last_total_buoyancy_n)
	_anomaly_set(row_base, "wave_time_s", _last_wave_time_seconds)
	_anomaly_set(row_base, "wave_query_count", float(_last_wave_query_count))
	_anomaly_set(row_base, "wind_query_count", float(_last_wind_query_count))
	for point_index in range(FLOAT_POINT_COUNT):
		_anomaly_set(row_base, ANOMALY_FLOAT_WATER_FIELDS[point_index], _point_water_heights_m[point_index])
		_anomaly_set(row_base, ANOMALY_FLOAT_SUBMERGENCE_FIELDS[point_index], _point_submergences_m[point_index])
	_anomaly_write_cursor = (_anomaly_write_cursor + 1) % ANOMALY_SAMPLE_CAPACITY
	_anomaly_sample_count = mini(_anomaly_sample_count + 1, ANOMALY_SAMPLE_CAPACITY)
	var trigger_reason := _get_anomaly_trigger_reason(
		state, body_basis, position, linear, angular, linear_speed, angular_speed, tilt_degrees
	)
	if not trigger_reason.is_empty():
		_anomaly_capture_armed = false
		call_deferred("_write_anomaly_capture", trigger_reason)


func _anomaly_set(row_base: int, field_name: String, value: float) -> void:
	var field_index := int(_anomaly_field_indices.get(field_name, -1))
	if field_index >= 0:
		_anomaly_samples[row_base + field_index] = value


func _anomaly_set_vector(row_base: int, first_field_name: String, value: Vector3) -> void:
	var field_index := int(_anomaly_field_indices.get(first_field_name, -1))
	if field_index < 0:
		return
	_anomaly_samples[row_base + field_index] = value.x
	_anomaly_samples[row_base + field_index + 1] = value.y
	_anomaly_samples[row_base + field_index + 2] = value.z


func _get_anomaly_trigger_reason(
	state: PhysicsDirectBodyState3D,
	body_basis: Basis,
	position: Vector3,
	linear: Vector3,
	angular: Vector3,
	linear_speed: float,
	angular_speed: float,
	tilt_degrees: float
) -> String:
	if not is_finite(state.step) or state.step <= 0.0:
		return "invalid_physics_step"
	if not _vector_is_finite(position):
		return "non_finite_position"
	if not _vector_is_finite(linear):
		return "non_finite_linear_velocity"
	if not _vector_is_finite(angular):
		return "non_finite_angular_velocity"
	if not _vector_is_finite(body_basis.x) or not _vector_is_finite(body_basis.y) or not _vector_is_finite(body_basis.z):
		return "non_finite_orientation_basis"
	if not _basis_axis_lengths_valid(body_basis):
		return "degenerate_orientation_basis"
	var basis_determinant := body_basis.determinant()
	if not is_finite(basis_determinant) or absf(basis_determinant) < 0.25:
		return "singular_orientation_basis"
	if not is_finite(linear_speed) or not is_finite(angular_speed) or tilt_degrees < 0.0 or not is_finite(tilt_degrees):
		return "non_finite_derived_state"
	if not is_finite(actual_sail_angle_rad) or not is_finite(target_sail_angle_rad) or not is_finite(actual_headsail_angle_rad) or not is_finite(target_headsail_angle_rad) or not is_finite(actual_rudder_angle_rad) or not is_finite(target_rudder_angle_rad):
		return "non_finite_control_state"
	if not _vector_is_finite(_last_true_wind_world_mps) or not _vector_is_finite(_last_apparent_wind_local_mps) or not _vector_is_finite(_last_headsail_apparent_wind_local_mps):
		return "non_finite_wind_state"
	if not is_finite(_last_sail_dynamic_pressure_pa) or not is_finite(_last_apparent_wind_speed_mps) or not is_finite(_last_headsail_angle_of_attack_rad):
		return "non_finite_sail_state"
	var headsail_dynamic_pressure := 0.5 * _air_density_kg_m3 * _last_headsail_apparent_wind_speed_mps * _last_headsail_apparent_wind_speed_mps
	if not is_finite(headsail_dynamic_pressure) or not is_finite(_last_sail_angle_of_attack_rad):
		return "non_finite_sail_state"
	var keel_force: Vector3 = _last_keel_result.get("net_force_local_n", Vector3.ZERO)
	var rudder_force: Vector3 = _last_rudder_result.get("net_force_local_n", Vector3.ZERO)
	var largest_force_component := 0.0
	if not _vector_is_finite(_last_sail_net_force_local_n) or not _vector_is_finite(_last_headsail_net_force_local_n) or not _vector_is_finite(_last_hull_drag_force_local_n) or not _vector_is_finite(keel_force) or not _vector_is_finite(rudder_force) or not _vector_is_finite(_last_total_horizontal_force_local_n):
		return "non_finite_applied_force"
	largest_force_component = maxf(largest_force_component, _vector_max_abs_component(_last_sail_net_force_local_n))
	largest_force_component = maxf(largest_force_component, _vector_max_abs_component(_last_headsail_net_force_local_n))
	largest_force_component = maxf(largest_force_component, _vector_max_abs_component(_last_hull_drag_force_local_n))
	largest_force_component = maxf(largest_force_component, _vector_max_abs_component(keel_force))
	largest_force_component = maxf(largest_force_component, _vector_max_abs_component(rudder_force))
	largest_force_component = maxf(largest_force_component, _vector_max_abs_component(_last_total_horizontal_force_local_n))
	if not is_finite(_last_total_external_yaw_torque_nm):
		return "non_finite_yaw_torque"
	if not is_finite(_last_total_buoyancy_n) or not is_finite(_last_apparent_wind_speed_mps) or not is_finite(_last_headsail_apparent_wind_speed_mps):
		return "non_finite_environment_or_buoyancy_state"
	for point_index in range(FLOAT_POINT_COUNT):
		if not is_finite(_point_water_heights_m[point_index]) or not is_finite(_point_submergences_m[point_index]):
			return "non_finite_buoyancy_sample"
	if linear_speed >= 25.0:
		return "linear_speed_over_25_mps"
	if angular_speed >= 4.0:
		return "angular_speed_over_4_rad_s"
	if tilt_degrees >= 65.0:
		return "hull_tilt_over_65_deg"
	if _vector_max_abs_component(position) >= 1.0e12:
		return "position_over_1e12_m"
	if largest_force_component >= 250000.0:
		return "force_component_over_250_kn"
	if _last_apparent_wind_speed_mps >= 100.0:
		return "apparent_wind_over_100_mps"
	return ""


func _write_anomaly_capture(trigger_reason: String) -> void:
	var unix_stamp := int(Time.get_unix_time_from_system())
	var tick_stamp := Time.get_ticks_usec()
	var output_path := "user://sailboat_anomaly_%d_%d.csv" % [unix_stamp, tick_stamp]
	var file := FileAccess.open(output_path, FileAccess.WRITE)
	if file == null:
		push_error("Sailboat anomaly capture could not write CSV; FileAccess error %d." % FileAccess.get_open_error())
		return
	var scene_path := "unknown"
	if get_tree() != null and get_tree().current_scene != null:
		scene_path = get_tree().current_scene.scene_file_path
	file.store_line("# trigger_reason=%s" % trigger_reason)
	file.store_line("# scene=%s" % scene_path)
	file.store_line("# profile=%s" % (profile.resource_path if profile != null else "none"))
	file.store_line("# captured_samples=%d; ring_capacity=%d; nominal_history_seconds=%.1f" % [_anomaly_sample_count, ANOMALY_SAMPLE_CAPACITY, float(ANOMALY_SAMPLE_CAPACITY) / 60.0])
	file.store_line("# diagnostic_thresholds: tilt>=65deg, linear_speed>=25m/s, angular_speed>=4rad/s, force_component>=250000N, apparent_wind>=100m/s, position_component>=1e12m, or invalid numeric state")
	file.store_line("# physics_frame is a sample counter since the most recent reset/rearm; accelerations are finite-difference diagnostics, not solver-reported values")
	var header := PackedStringArray()
	for field_name in ANOMALY_FIELDS:
		header.append(str(field_name))
	file.store_line(",".join(header))
	var oldest_sample := _anomaly_write_cursor - _anomaly_sample_count
	if oldest_sample < 0:
		oldest_sample += ANOMALY_SAMPLE_CAPACITY
	var row_parts := PackedStringArray()
	row_parts.resize(ANOMALY_FIELDS.size())
	for sample_offset in range(_anomaly_sample_count):
		var sample_slot := (oldest_sample + sample_offset) % ANOMALY_SAMPLE_CAPACITY
		var row_base := sample_slot * ANOMALY_FIELDS.size()
		for column_index in range(ANOMALY_FIELDS.size()):
			row_parts[column_index] = str(_anomaly_samples[row_base + column_index])
		file.store_line(",".join(row_parts))
	file.close()
	var absolute_path := ProjectSettings.globalize_path(output_path)
	push_warning("Sailboat first-anomaly snapshot saved (%s): %s" % [trigger_reason, absolute_path])


func _vector_is_finite(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _vector_max_abs_component(value: Vector3) -> float:
	return maxf(absf(value.x), maxf(absf(value.y), absf(value.z)))


func _safe_vector_length(value: Vector3) -> float:
	if not _vector_is_finite(value):
		return INF
	var largest_component := _vector_max_abs_component(value)
	if largest_component <= 0.0:
		return 0.0
	return (value / largest_component).length() * largest_component


func _basis_axis_lengths_valid(body_basis: Basis) -> bool:
	return _basis_axis_length_valid(body_basis.x) and _basis_axis_length_valid(body_basis.y) and _basis_axis_length_valid(body_basis.z)


func _basis_axis_length_valid(axis: Vector3) -> bool:
	var axis_length := _safe_vector_length(axis)
	return is_finite(axis_length) and axis_length >= 0.5 and axis_length <= 1.5


func _tilt_from_up_degrees(body_up: Vector3) -> float:
	var up_length := _safe_vector_length(body_up)
	if not is_finite(up_length) or up_length < 0.5:
		return -1.0
	return rad_to_deg(acos(clampf(body_up.y / up_length, -1.0, 1.0)))


func reset_performance_history() -> void:
	_wave_sample_usec_history.fill(0)
	_wind_sample_usec_history.fill(0)
	_aero_calculation_usec_history.fill(0)
	_headsail_aero_calculation_usec_history.fill(0)
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
	set_auto_sail_trim_enabled(false)
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
	target_headsail_angle_rad = 0.0
	actual_headsail_angle_rad = 0.0
	_auto_sail_trim.reset(0.0, 0.0)
	_last_auto_trim_result = {}
	_last_auto_trim_calculation_usec = 0
	target_rudder_angle_rad = 0.0
	actual_rudder_angle_rad = 0.0
	_rudder_key_a_pressed = false
	_rudder_key_d_pressed = false
	_rudder_keyboard_active = false
	runtime_buoyancy_strength = 1.0
	runtime_damping_ratio = float(profile.get("buoyancy_damping_ratio"))


func set_test_hull_lateral_resistance_application_offset_z_m(offset_from_com_z_m: float) -> bool:
	## P2.12 test-only override. Values are a COM-relative local-Z lever arm;
	## zero is the unchanged central-resistance behavior.
	if not is_finite(offset_from_com_z_m) or absf(offset_from_com_z_m) > 0.300001:
		return false
	_test_hull_lateral_application_offset_z_m = offset_from_com_z_m
	return true


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
	_arm_anomaly_capture()


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
	if auto_sail_trim_enabled and not _auto_trim_applying_targets:
		set_auto_sail_trim_enabled(false)
	target_sail_angle_rad = clampf(angle_rad, _minimum_sail_angle_rad, _maximum_sail_angle_rad)


func set_target_headsail_angle(angle_rad: float) -> void:
	if not is_finite(angle_rad):
		return
	if auto_sail_trim_enabled and not _auto_trim_applying_targets:
		set_auto_sail_trim_enabled(false)
	target_headsail_angle_rad = clampf(angle_rad, _minimum_headsail_angle_rad, _maximum_headsail_angle_rad)


func set_auto_sail_trim_enabled(enabled: bool) -> void:
	if auto_sail_trim_enabled == enabled:
		return
	auto_sail_trim_enabled = enabled
	_auto_sail_trim.reset(target_sail_angle_rad, target_headsail_angle_rad)
	_last_auto_trim_result = _auto_sail_trim.update_from_snapshot({
		"target_sail_angle_rad": target_sail_angle_rad,
		"target_headsail_angle_rad": target_headsail_angle_rad,
		"headsail_enabled": _headsail_enabled,
	})
	_last_auto_trim_calculation_usec = 0


func get_auto_sail_trim_enabled() -> bool:
	return auto_sail_trim_enabled


func get_auto_sail_trim_snapshot() -> Dictionary:
	var result := _last_auto_trim_result.duplicate(true)
	result["enabled"] = auto_sail_trim_enabled
	result["mode"] = "AUTO" if auto_sail_trim_enabled else "MANUAL"
	result["main_target_angle_rad"] = target_sail_angle_rad
	result["headsail_target_angle_rad"] = target_headsail_angle_rad
	if not auto_sail_trim_enabled:
		var awa := _last_apparent_wind_from_angle_degrees
		var aws := _last_apparent_wind_speed_mps
		result["selected_side"] = "右舷展开" if awa < -12.0 and absf(awa) < 150.0 else "左舷展开" if awa > 12.0 and absf(awa) < 150.0 else "保持当前舷侧"
		result["no_go"] = aws >= 0.5 and absf(awa) <= AUTO_SAIL_TRIM_SCRIPT.NO_GO_ENTER_DEGREES
		result["status"] = "手动操帆"
	elif not result.has("status"):
		result["status"] = "等待有效视风"
	return result


func _update_auto_sail_trim_from_cached_wind(body_basis: Basis) -> void:
	_last_auto_trim_calculation_usec = 0
	if not auto_sail_trim_enabled:
		return
	var heading_degrees := NAVIGATION_MATH.heading_degrees_from_forward(-body_basis.z)
	var awa := _last_apparent_wind_from_angle_degrees
	var aws := _last_apparent_wind_speed_mps
	var twa := NAVIGATION_MATH.signed_relative_bearing_degrees(_last_true_wind_from_degrees, heading_degrees)
	var true_wind_horizontal := Vector3(_last_true_wind_world_mps.x, 0.0, _last_true_wind_world_mps.z)
	var local_velocity := body_basis.inverse() * linear_velocity
	var auto_snapshot := {
		"apparent_wind_from_relative_degrees": awa,
		"apparent_wind_speed_mps": aws,
		"true_wind_from_relative_degrees": twa,
		"true_wind_speed_mps": true_wind_horizontal.length(),
		"sog_mps": Vector2(linear_velocity.x, linear_velocity.z).length(),
		"longitudinal_velocity_mps": -local_velocity.z,
		"target_sail_angle_rad": target_sail_angle_rad,
		"target_headsail_angle_rad": target_headsail_angle_rad,
		"min_sail_angle_rad": _minimum_sail_angle_rad,
		"max_sail_angle_rad": _maximum_sail_angle_rad,
		"min_headsail_angle_rad": _minimum_headsail_angle_rad,
		"max_headsail_angle_rad": _maximum_headsail_angle_rad,
		"headsail_enabled": _headsail_enabled,
	}
	var start_usec := Time.get_ticks_usec()
	_last_auto_trim_result = _auto_sail_trim.update_from_snapshot(auto_snapshot)
	_last_auto_trim_calculation_usec = Time.get_ticks_usec() - start_usec
	_auto_trim_applying_targets = true
	set_target_sail_angle(float(_last_auto_trim_result.get("main_target_angle_rad", target_sail_angle_rad)))
	if _headsail_enabled:
		set_target_headsail_angle(float(_last_auto_trim_result.get("headsail_target_angle_rad", target_headsail_angle_rad)))
	_auto_trim_applying_targets = false


func get_target_headsail_angle() -> float:
	return target_headsail_angle_rad


func get_actual_headsail_angle() -> float:
	return actual_headsail_angle_rad


func set_headsail_enabled(enabled: bool) -> void:
	if _headsail_enabled == enabled:
		return
	_headsail_enabled = enabled
	if _headsail_visual != null:
		_headsail_visual.visible = enabled
	if not enabled:
		_last_total_horizontal_force_local_n -= _last_headsail_net_force_local_n
		_last_total_external_yaw_torque_nm -= _last_headsail_yaw_torque_nm
		_last_headsail_aero_calculation_usec = 0
		_last_headsail_effective_area_m2 = 0.0
		_last_headsail_apparent_wind_local_mps = Vector3.ZERO
		_last_headsail_apparent_wind_speed_mps = 0.0
		_last_headsail_arm_from_com_world_m = Vector3.ZERO
		_last_headsail_angle_of_attack_rad = 0.0
		_last_headsail_luffing_scale = 0.0
		_last_headsail_wrong_side_lift_scale = 1.0
		_last_headsail_cl = 0.0
		_last_headsail_cd = 0.0
		_last_headsail_pressure_center_local_m = Vector3.ZERO
		_last_headsail_lift_force_local_n = Vector3.ZERO
		_last_headsail_drag_force_local_n = Vector3.ZERO
		_last_headsail_net_force_local_n = Vector3.ZERO
		_last_headsail_net_force_world_n = Vector3.ZERO
		_last_headsail_torque_local_nm = Vector3.ZERO
		_last_headsail_yaw_torque_nm = 0.0


func is_headsail_enabled() -> bool:
	return _headsail_enabled


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


func _empty_sail_result() -> Dictionary:
	return {
		"valid": false,
		"apparent_speed_mps": 0.0,
		"dynamic_pressure_pa": 0.0,
		"angle_of_attack_rad": 0.0,
		"apparent_wind_from_angle_rad": 0.0,
		"luffing_scale": 0.0,
		"windward_sheet_alignment": 0.0,
		"wrong_side_lift_scale": 1.0,
		"sheet_efficiency_scale": 1.0,
		"cl": 0.0,
		"cd": 0.0,
		"lift_force_local_n": Vector3.ZERO,
		"drag_force_local_n": Vector3.ZERO,
		"net_force_local_n": Vector3.ZERO,
	}


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
