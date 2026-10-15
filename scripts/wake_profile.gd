class_name WakeProfile
extends Resource

## Visual tuning for one hull. Speeds and dimensions are in m/s and meters.

@export_category("Identity")
@export var profile_name := "Sailboat"
@export_range(80, 300, 10) var max_particle_budget := 240

@export_category("Speed response")
@export_range(0.0, 4.0, 0.05) var minimum_visible_speed_mps := 0.45
@export_range(1.0, 30.0, 0.5) var full_effect_speed_mps := 12.0
@export_range(0.0, 1.0, 0.01) var emission_strength_min := 0.08
@export_range(0.0, 1.0, 0.01) var emission_strength_max := 0.82
@export_range(0.2, 2.0, 0.05) var speed_influence := 1.0
@export_range(0.2, 6.0, 0.1) var response_speed := 1.8

@export_category("Spawn and shape")
@export_range(0.1, 1.5, 0.05) var spawn_half_width_min_m := 0.28
@export_range(0.1, 2.0, 0.05) var spawn_half_width_max_m := 0.78
@export_range(0.05, 0.6, 0.01) var spawn_length_half_extent_m := 0.2
@export_range(0.0, 40.0, 1.0) var lateral_spread_min_degrees := 5.0
@export_range(0.0, 40.0, 1.0) var lateral_spread_max_degrees := 14.0
@export_range(0.0, 2.0, 0.05) var initial_velocity_min_mps := 0.05
@export_range(0.0, 3.0, 0.05) var initial_velocity_max_mps := 0.75
@export_range(0.1, 1.5, 0.05) var particle_size_min_m := 0.42
@export_range(0.1, 2.0, 0.05) var particle_size_max_m := 1.05

@export_category("Lifetime and color")
@export_range(0.5, 8.0, 0.1) var particle_lifetime_min_seconds := 2.8
@export_range(0.5, 8.0, 0.1) var particle_lifetime_max_seconds := 4.0
@export_range(0.0, 1.0, 0.01) var wake_opacity_min := 0.13
@export_range(0.0, 1.0, 0.01) var wake_opacity_max := 0.26
@export_range(0.0, 1.0, 0.01) var foam_opacity_min := 0.48
@export_range(0.0, 1.0, 0.01) var foam_opacity_max := 0.76
@export var wake_tint := Color(0.28, 0.62, 0.64, 1.0)
@export var foam_tint := Color(0.83, 0.92, 0.89, 1.0)
@export_range(0.0, 0.2, 0.005) var color_hue_variation := 0.035

## Reserved for a future separate V-shaped effect. WakeSystem does not render it.
@export_range(0.0, 1.0, 0.01) var future_v_wave_strength := 0.0
