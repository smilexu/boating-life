extends Resource
class_name PolarTestProfile
## Reusable, lab-only configuration for physical sailing Polar measurements.

@export var boat_scene_paths: PackedStringArray = PackedStringArray([
	"res://scenes/boats/SailingBoat8m.tscn",
])
@export var target_tws_knots := PackedFloat32Array([4.0, 8.0, 12.0, 16.0, 20.0])
@export_range(0.0, 180.0, 1.0) var twa_start_degrees := 0.0
@export_range(0.0, 180.0, 1.0) var twa_end_degrees := 180.0
@export_range(1.0, 45.0, 1.0) var twa_step_degrees := 10.0
@export var include_port_tack := true
@export var include_starboard_tack := true
@export_range(0.0, 600.0, 1.0) var minimum_warmup_seconds := 60.0
@export_range(5.0, 120.0, 1.0) var stability_window_seconds := 30.0
@export_range(5.0, 120.0, 1.0) var sample_window_seconds := 30.0
@export_range(30.0, 1800.0, 1.0) var case_timeout_seconds := 300.0
@export_range(1.0, 20.0, 0.5) var maximum_mean_twa_error_degrees := 5.0
@export_range(1.0, 20.0, 0.5) var maximum_heading_error_degrees := 5.0
@export_range(0.01, 1.0, 0.01) var maximum_speed_standard_deviation_mps := 0.20
@export_range(0.01, 1.0, 0.01) var maximum_speed_half_window_delta_mps := 0.12
@export_range(0.0, 0.75, 0.01) var maximum_rudder_saturation_fraction := 0.20
@export_range(0.1, 15.0, 0.1) var no_forward_progress_threshold_mps := 0.10
@export_range(0.5, 20.0, 0.5) var rudder_p_gain := 5.0
@export_range(0.0, 10.0, 0.5) var rudder_d_gain := 3.0
@export_range(1.0, 35.0, 1.0) var rudder_limit_degrees := 35.0
@export var fixed_wind_from_degrees := 180.0
@export var fixed_wind_seed := 481516
@export var fixed_physics_step_seconds := 1.0 / 60.0
@export var zero_wave_sampler_strength := true
