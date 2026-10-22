extends Resource
## Prototype/tuning values for the independent 8 m SailboatLab test hull.
## These values do not claim to describe a measured real vessel.

@export var vessel_name := "8 m 单桅测试帆船（原型调参）"
@export_range(4.0, 12.0, 0.1) var vessel_length_m := 8.0
@export_range(1.5, 4.0, 0.1) var vessel_beam_m := 2.6
@export_range(0.3, 1.8, 0.05) var draft_m := 0.9
@export_range(500.0, 10000.0, 25.0) var mass_kg := 3200.0
@export var center_of_mass_m := Vector3(0.0, -0.65, 0.0)
@export_range(0.05, 0.7, 0.01) var rest_submergence_m := 0.45
@export var float_point_offsets_m := PackedVector3Array([
	Vector3(-0.65, -0.50, -2.4),
	Vector3(0.65, -0.50, -2.4),
	Vector3(-0.65, -0.50, 2.4),
	Vector3(0.65, -0.50, 2.4),
])
@export_range(0.0, 2.0, 0.05) var buoyancy_damping_ratio := 0.55
@export_range(1.0, 3.0, 0.05) var maximum_point_force_ratio := 1.8
## Vessel-local rigid-body damping policy. SailboatLab relies on explicit hull
## and foil resistance for horizontal drag, so its profile uses REPLACE + 0.
@export_enum("Combine:0", "Replace:1") var linear_damp_mode := 1
@export_range(0.0, 2.0, 0.05) var linear_damping := 0.0
@export_range(0.0, 2.0, 0.05) var angular_damping := 0.08
@export_range(0.0, 50000.0, 100.0) var roll_damping_n_m_s_per_rad := 600.0
@export_range(0.0, 100000.0, 100.0) var pitch_damping_n_m_s_per_rad := 2000.0
@export_range(0.0, 10000.0, 100.0) var yaw_damping_n_m_s_per_rad := 1600.0

## Main-sail values below are prototype/tuning data, not a measured vessel fit.
@export_range(5.0, 60.0, 0.01) var main_sail_area_m2 := 10.16025
@export var main_sail_pivot_local_m := Vector3(0.0, 0.65, -0.75)
## The force centre is defined in the sail-pivot frame and rotates with the
## actual boom/sail angle. Z=0.80 m is inside the current triangular planform.
@export var main_sail_pressure_center_from_pivot_m := Vector3(0.0, 2.4, 0.8)
@export_range(-1.396, 0.0, 0.01745, "radians_as_degrees") var min_sail_angle_rad := -1.396
@export_range(0.0, 1.396, 0.01745, "radians_as_degrees") var max_sail_angle_rad := 1.396
@export_range(0.05, 1.0, 0.01, "radians_as_degrees") var sail_rotation_speed_rad_s := 0.35
## C7b-calibrated AUTO curve: x is absolute apparent-wind angle in degrees,
## y is sheet magnitude in degrees. Sign is selected from wind side by AutoSailTrim.
@export var auto_main_trim_curve_points_degrees := PackedVector2Array([
	Vector2(0.0, 10.0), Vector2(30.0, 10.0), Vector2(45.0, 20.0),
	Vector2(60.0, 30.0), Vector2(80.2, 60.0), Vector2(108.1, 79.9),
	Vector2(143.1, 79.9), Vector2(180.0, 79.9),
])
@export var auto_headsail_trim_curve_points_degrees := PackedVector2Array([
	Vector2(0.0, 10.0), Vector2(30.0, 10.0), Vector2(45.0, 15.0),
	Vector2(60.0, 25.0), Vector2(80.2, 55.0), Vector2(108.1, 70.0),
	Vector2(143.1, 70.0), Vector2(180.0, 70.0),
])
@export_range(0.5, 2.0, 0.01) var air_density_kg_m3 := 1.225
@export_range(0.1, 2.5, 0.05) var sail_max_lift_coefficient := 1.25
@export_range(5.0, 45.0, 1.0, "radians_as_degrees") var sail_stall_angle_rad := 0.384
@export_range(15.0, 60.0, 1.0, "radians_as_degrees") var no_sail_wind_from_angle_rad := 0.611
@export_range(25.0, 75.0, 1.0, "radians_as_degrees") var full_lift_wind_from_angle_rad := 0.873
@export_range(0.0, 0.5, 0.01) var sail_base_drag_coefficient := 0.08
@export_range(0.0, 1.5, 0.01) var sail_induced_drag_factor := 0.55
@export_range(0.0, 2.0, 0.01) var sail_flat_plate_drag_factor := 0.90
## Lift retention when the boom is geometrically on the windward/backed side.
## Drag remains active; this is a bounded game-level backing model.
@export_range(0.0, 1.0, 0.01) var sail_wrong_side_lift_retention := 0.20

## Independent prototype jib. Geometry and force data are both hull-local and
## remain separate from the visual GLB/mesh and from the mainsail.
@export var headsail_enabled := true
@export_range(1.0, 16.0, 0.01) var headsail_area_m2 := 5.16
@export var headsail_head_local_m := Vector3(0.0, 4.95, -0.75)
@export var headsail_tack_local_m := Vector3(0.0, 0.65, -3.55)
@export var headsail_clew_neutral_local_m := Vector3(0.0, 0.65, -1.15)
## The pressure centre starts at the triangle centroid and follows one third
## of the Clew displacement. This is a tunable prototype distribution, not
## measured sail data.
@export var headsail_pressure_center_offset_from_centroid_m := Vector3.ZERO
@export_range(0.0, 1.0, 0.01) var headsail_pressure_center_clew_follow := 0.333333
@export_range(-1.396, 0.0, 0.01745, "radians_as_degrees") var min_headsail_angle_rad := -1.222
@export_range(0.0, 1.396, 0.01745, "radians_as_degrees") var max_headsail_angle_rad := 1.222
@export_range(0.05, 1.0, 0.01, "radians_as_degrees") var headsail_rotation_speed_rad_s := 0.52
@export_range(0.1, 2.5, 0.05) var headsail_max_lift_coefficient := 1.25
@export_range(5.0, 45.0, 1.0, "radians_as_degrees") var headsail_stall_angle_rad := 0.384
@export_range(15.0, 60.0, 1.0, "radians_as_degrees") var headsail_no_sail_wind_from_angle_rad := 0.611
@export_range(25.0, 75.0, 1.0, "radians_as_degrees") var headsail_full_lift_wind_from_angle_rad := 0.873
@export_range(0.0, 0.5, 0.01) var headsail_base_drag_coefficient := 0.08
@export_range(0.0, 1.5, 0.01) var headsail_induced_drag_factor := 0.55
@export_range(0.0, 2.0, 0.01) var headsail_flat_plate_drag_factor := 0.90
@export_range(0.0, 1.0, 0.01) var headsail_wrong_side_lift_retention := 0.20

## Prototype/tuning hydrodynamics. No measured hull data is implied.
@export_range(500.0, 1200.0, 5.0) var water_density_kg_m3 := 1025.0
@export var keel_center_local_m := Vector3(0.0, -1.05, 0.15)
@export_range(0.2, 4.0, 0.05) var keel_area_m2 := 2.2
@export_range(0.0, 8.0, 0.1) var keel_lift_slope_per_rad := 4.0
@export_range(0.1, 1.8, 0.05) var keel_max_lift_coefficient := 1.15
@export_range(5.0, 60.0, 1.0, "radians_as_degrees") var keel_stall_angle_rad := 0.42
@export_range(0.0, 0.5, 0.005) var keel_base_drag_coefficient := 0.025
@export_range(0.0, 1.0, 0.01) var keel_induced_drag_factor := 0.12
@export_range(0.0, 2.0, 0.01) var keel_flat_plate_drag_factor := 0.85
@export_range(0.1, 4.0, 0.05) var keel_max_force_weight_ratio := 2.5

@export var rudder_center_local_m := Vector3(0.0, -0.88, 3.18)
@export_range(0.1, 1.5, 0.025) var rudder_area_m2 := 0.5
@export_range(5.0, 50.0, 1.0, "radians_as_degrees") var max_rudder_angle_rad := 0.611
@export_range(5.0, 120.0, 1.0, "radians_as_degrees") var rudder_rotation_speed_rad_s := 1.047
@export_range(0.0, 8.0, 0.1) var rudder_lift_slope_per_rad := 3.2
@export_range(0.1, 1.8, 0.05) var rudder_max_lift_coefficient := 1.2
@export_range(5.0, 60.0, 1.0, "radians_as_degrees") var rudder_stall_angle_rad := 0.42
@export_range(0.0, 0.5, 0.005) var rudder_base_drag_coefficient := 0.03
@export_range(0.0, 1.0, 0.01) var rudder_induced_drag_factor := 0.15
@export_range(0.0, 2.0, 0.01) var rudder_flat_plate_drag_factor := 0.9
@export_range(0.1, 3.0, 0.05) var rudder_max_force_weight_ratio := 1.0

@export_range(0.0, 3000.0, 10.0) var hull_longitudinal_drag_linear_n_s_m := 220.0
@export_range(0.0, 1000.0, 5.0) var hull_longitudinal_drag_quadratic_n_s2_m2 := 85.0
@export_range(0.0, 3000.0, 10.0) var hull_lateral_drag_linear_n_s_m := 500.0
@export_range(0.0, 1000.0, 5.0) var hull_lateral_drag_quadratic_n_s2_m2 := 250.0
@export_range(0.1, 5.0, 0.1) var hull_drag_max_force_weight_ratio := 2.0

## Reserved for a future, measured nonlinear GZ/righting-arm curve. The B1
## prototype intentionally relies on distributed buoyancy and a low CG only.
@export var righting_arm_curve: Curve
