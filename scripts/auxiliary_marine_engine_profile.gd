class_name AuxiliaryMarineEngineProfile
extends Resource

## Game-level tuning for a compact inboard diesel. Rated power is shaft power;
## thrust is derived using the configured propulsive efficiency and boat speed.

@export var engine_display_name := "15 hp 辅助柴油机"
@export_range(1.0, 2000.0, 0.5) var rated_power_hp := 15.0
@export_range(0.05, 0.75, 0.01) var propulsive_efficiency := 0.30
@export_range(100.0, 10000.0, 25.0) var maximum_bollard_thrust_n := 2100.0
@export_range(0.1, 2.0, 0.05) var minimum_power_speed_mps := 0.7
@export_range(0.25, 3.0, 0.05) var throttle_power_exponent := 1.2
@export_range(0.1, 1.0, 0.05) var reverse_thrust_ratio := 0.68
@export_range(0.05, 1.5, 0.05) var throttle_response_per_second := 0.65
@export_range(0.1, 10.0, 0.1) var startup_duration_s := 1.5
@export_range(0.1, 5.0, 0.1) var shutdown_duration_s := 0.6
@export_range(0.0, 0.5, 0.01) var maximum_shift_throttle := 0.10
@export_range(0.0, 10.0, 0.1) var idle_consumption_lph := 0.3
@export_range(0.0, 10.0, 0.1) var low_throttle_consumption_lph := 0.6
@export_range(0.0, 10.0, 0.1) var medium_throttle_consumption_lph := 1.1
@export_range(0.0, 10.0, 0.1) var high_throttle_consumption_lph := 2.0
@export_range(0.1, 1.0, 0.01) var neutral_throttle_load_scale := 0.75
@export_range(0.1, 1.5, 0.01) var reverse_consumption_scale := 0.9
@export_range(1.0, 10.0, 0.1) var reference_cruise_speed_knots := 5.0
@export var thrust_application_point_local_m := Vector3(0.0, -0.65, 2.65)


func rated_power_w() -> float:
	return maxf(rated_power_hp, 0.0) * 745.699872


func consumption_for_throttle_lph(throttle: float) -> float:
	var value := clampf(throttle, 0.0, 1.0)
	if value <= 0.25:
		return lerpf(idle_consumption_lph, low_throttle_consumption_lph, value / 0.25)
	if value <= 0.5:
		return lerpf(low_throttle_consumption_lph, medium_throttle_consumption_lph, (value - 0.25) / 0.25)
	return lerpf(medium_throttle_consumption_lph, high_throttle_consumption_lph, (value - 0.5) / 0.5)
