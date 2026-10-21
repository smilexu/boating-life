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
@export_range(0.0, 2.0, 0.05) var linear_damping := 0.12
@export_range(0.0, 2.0, 0.05) var angular_damping := 0.08
@export_range(0.0, 50000.0, 100.0) var roll_damping_n_m_s_per_rad := 600.0
@export_range(0.0, 100000.0, 100.0) var pitch_damping_n_m_s_per_rad := 2000.0
@export_range(0.0, 10000.0, 100.0) var yaw_damping_n_m_s_per_rad := 1600.0

## Reserved for a future, measured nonlinear GZ/righting-arm curve. The B1
## prototype intentionally relies on distributed buoyancy and a low CG only.
@export var righting_arm_curve: Curve
