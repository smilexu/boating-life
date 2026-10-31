class_name FishingFightProfile
extends Resource

## Deterministic, presentation-only response parameters for one caught species.

@export var species_id := ""

@export_group("Rod load")
@export_range(0.2, 1.0, 0.01) var base_rod_load_ratio := 0.72
@export_range(0.0, 0.5, 0.01) var struggle_load_peak := 0.24
@export_range(0.2, 2.5, 0.05) var struggle_pulse_duration_seconds := 1.15
## Each Vector2 stores (seconds since hook, normalized impulse strength).
@export var struggle_pulses_seconds_strength := PackedVector2Array()

@export_group("Line resistance")
@export_range(0.0, 3.0, 0.05) var line_burst_distance_m := 1.4
@export_range(0.1, 2.0, 0.05) var line_burst_duration_seconds := 0.8
@export_range(0.1, 12.0, 0.1) var reverse_line_speed_radians_per_second := 5.0
@export var line_burst_pulses_seconds_strength := PackedVector2Array()

@export_group("Fish pose")
@export_range(0.0, 1.5, 0.05) var lateral_struggle_amplitude_m := 0.55
@export_range(0.0, 45.0, 1.0) var body_yaw_amplitude_degrees := 24.0
@export_range(0.0, 35.0, 1.0) var body_roll_amplitude_degrees := 18.0
@export_range(0.0, 25.0, 1.0) var body_pitch_amplitude_degrees := 8.0
@export_range(0.2, 5.0, 0.1) var body_wag_frequency_hz := 1.65

@export_group("Near boat approach")
@export_range(0.1, 0.8, 0.01) var near_boat_visible_start_progress := 0.36
@export_range(0.1, 1.5, 0.05) var approach_start_depth_below_surface_m := 0.55
@export_range(0.0, 0.8, 0.05) var approach_end_depth_below_surface_m := 0.14
@export_range(0.5, 1.5, 0.05) var surface_lateral_amplitude_multiplier := 1.0
@export_range(0.0, 0.2, 0.01) var surface_bob_amplitude_m := 0.06

@export_group("Surface splashes")
@export_range(0.5, 3.0, 0.05) var splash_strength_multiplier := 2.0
@export_range(0.5, 3.0, 0.05) var breach_splash_strength_multiplier := 2.8
## Times are relative to the start of Surface & Landing.
@export var surface_splash_times_seconds := PackedFloat32Array()

@export_group("Surface action")
@export var surface_breach_enabled := false
@export_range(0.0, 5.0, 0.05) var surface_breach_start_seconds := 1.15
@export_range(0.3, 2.0, 0.05) var surface_breach_duration_seconds := 1.0
@export_range(0.2, 2.0, 0.05) var surface_breach_peak_height_m := 1.05
@export_range(0.0, 0.8, 0.05) var surface_breach_submerge_depth_m := 0.30
@export_range(0.0, 80.0, 1.0) var surface_breach_pitch_degrees := 56.0
@export var surface_wash_gills_enabled := false
@export_range(0.0, 7.0, 0.05) var surface_wash_gills_start_seconds := 2.25
@export_range(0.3, 5.0, 0.05) var surface_wash_gills_duration_seconds := 2.6
@export_range(20.0, 100.0, 1.0) var surface_wash_gills_roll_degrees := 82.0
@export_range(0.0, 7.0, 0.05) var surface_lift_start_seconds := 5.15
@export_range(0.3, 2.0, 0.05) var surface_lift_duration_seconds := 0.75

@export_group("Airborne struggle")
@export_range(0.0, 1.0, 0.05) var airborne_wriggle_strength := 0.7
@export_range(0.0, 45.0, 1.0) var airborne_wriggle_yaw_degrees := 24.0
@export_range(0.0, 45.0, 1.0) var airborne_wriggle_roll_degrees := 20.0
@export_range(0.5, 6.0, 0.1) var airborne_wriggle_frequency_hz := 2.8

@export_group("Hanging catch display")
@export_range(0.5, 4.0, 0.1) var hanging_struggle_duration_seconds := 2.0
@export_range(0.0, 20.0, 1.0) var hanging_sway_max_degrees := 20.0
@export_range(0.0, 45.0, 0.5) var hanging_burst_sway_impulse_degrees := 36.0
@export_range(0.5, 3.0, 0.05) var hanging_sway_response_frequency_hz := 1.25
## Speeds only event-driven curl and sway responses; it does not change their amplitude or the continuous tail frequency.
@export_range(1.0, 2.0, 0.05) var hanging_burst_speed_multiplier := 1.5
@export_range(0.0, 12.0, 0.5) var hanging_twist_max_degrees := 6.0
@export_range(0.0, 6.0, 0.5) var hanging_residual_sway_degrees := 2.5
@export_range(0.0, 150.0, 1.0) var hanging_curl_total_angle_degrees := 120.0
@export_range(0.6, 2.5, 0.05) var hanging_curl_bend_power := 1.0
@export_range(0.0, 65.0, 0.5) var hanging_tail_whip_angle_degrees := 35.0
@export_range(1.0, 10.0, 0.1) var hanging_tail_wriggle_frequency_hz := 6.2
## Each Vector3 is (seconds after lift, strength, bend direction).
@export var hanging_curl_pulses := PackedVector3Array()
