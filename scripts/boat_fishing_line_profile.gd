class_name BoatFishingLineProfile
extends Resource

## Boat-fishing reel, main-line and deterministic break tuning.
## Force values are game calibration values in newtons, not real tackle ratings.

@export_group("Line strength and drag")
@export_range(1.0, 5000.0, 0.5, "or_greater") var line_break_force_n := 68.0
@export_range(0.0, 2000.0, 0.5, "or_greater") var drag_min_force_n := 4.0
@export_range(0.0, 2000.0, 0.5, "or_greater") var drag_max_force_n := 52.0
@export_range(0.0, 1.0, 0.01) var default_drag_setting := 0.3
@export_range(0.0, 20.0, 0.1) var drag_hysteresis_n := 1.0

@export_group("Line speeds")
@export_range(0.01, 5.0, 0.01) var reel_in_speed_mps := 0.65
@export_range(0.01, 15.0, 0.01) var max_line_out_speed_mps := 2.4
## Effective load beyond the drag threshold needed to reach maximum payout speed.
@export_range(0.1, 1000.0, 0.1) var payout_full_speed_force_delta_n := 30.0
@export_range(0.1, 4.0, 0.05) var reel_load_slowdown_exponent := 1.3

@export_group("Main line load")
## Scalar branch loads combine as an L^p norm. Values above 1 prevent a linear sum.
@export_range(1.0, 3.0, 0.05) var multi_fish_load_exponent := 1.5
## Direction projection keeps some branch load even when a fish swims cross-line.
@export_range(0.0, 1.0, 0.01) var minimum_directional_load_fraction := 0.25
@export_range(0.1, 2000.0, 0.1) var maximum_single_fish_load_n := 500.0
@export_range(1.0, 5000.0, 1.0) var maximum_effective_fish_load_n := 1000.0

@export_group("Transient tension")
## Gain on the positive rate of change of effective fish load.
@export_range(0.0, 3.0, 0.01) var transient_peak_gain := 0.75
@export_range(0.01, 5.0, 0.01) var transient_peak_decay_s := 0.55
@export_range(0.0, 1000.0, 0.5, "or_greater") var transient_peak_cap_n := 32.0
@export_range(1.0, 10000.0, 1.0) var maximum_instantaneous_tension_n := 300.0

@export_group("Break danger ratios")
@export_range(0.0, 1.0, 0.01) var danger_safe_ratio := 0.70
@export_range(0.0, 1.0, 0.01) var danger_onset_ratio := 0.85
@export_range(0.1, 2.0, 0.01) var danger_limit_ratio := 1.0
@export_range(0.2, 4.0, 0.01) var danger_severe_ratio := 1.2
@export_range(0.1, 60.0, 0.1) var break_danger_seconds_to_snap := 2.2
@export_range(0.0, 10.0, 0.01) var danger_rate_at_onset := 0.2
@export_range(0.0, 20.0, 0.01) var danger_rate_at_limit := 1.5
@export_range(0.0, 50.0, 0.01) var danger_rate_at_severe := 16.0
@export_range(0.0, 200.0, 0.1) var danger_severe_rate_per_ratio := 80.0
@export_range(0.0, 20.0, 0.01) var danger_recovery_rate := 1.8


func get_drag_threshold_n(drag_setting: float) -> float:
	var low := _finite_nonnegative(drag_min_force_n, 0.0)
	var high := _finite_nonnegative(drag_max_force_n, low)
	var minimum := minf(low, high)
	var maximum := maxf(low, high)
	var setting := clampf(drag_setting, 0.0, 1.0) if is_finite(drag_setting) else clampf(default_drag_setting, 0.0, 1.0)
	return lerpf(minimum, maximum, setting)


func is_valid() -> bool:
	var numeric_values: Array[float] = [
		line_break_force_n, drag_min_force_n, drag_max_force_n, default_drag_setting,
		drag_hysteresis_n, reel_in_speed_mps, max_line_out_speed_mps,
		payout_full_speed_force_delta_n, reel_load_slowdown_exponent,
		multi_fish_load_exponent, minimum_directional_load_fraction,
		maximum_single_fish_load_n, maximum_effective_fish_load_n,
		transient_peak_gain, transient_peak_decay_s, transient_peak_cap_n,
		maximum_instantaneous_tension_n, danger_safe_ratio, danger_onset_ratio,
		danger_limit_ratio, danger_severe_ratio, break_danger_seconds_to_snap,
		danger_rate_at_onset, danger_rate_at_limit, danger_rate_at_severe,
		danger_severe_rate_per_ratio, danger_recovery_rate,
	]
	for value in numeric_values:
		if not is_finite(value):
			return false
	return line_break_force_n > 0.0 \
		and drag_min_force_n >= 0.0 and drag_max_force_n >= 0.0 \
		and default_drag_setting >= 0.0 and default_drag_setting <= 1.0 \
		and drag_hysteresis_n >= 0.0 \
		and reel_in_speed_mps >= 0.0 and max_line_out_speed_mps >= 0.0 \
		and payout_full_speed_force_delta_n > 0.0 \
		and reel_load_slowdown_exponent > 0.0 \
		and multi_fish_load_exponent >= 1.0 \
		and minimum_directional_load_fraction >= 0.0 and minimum_directional_load_fraction <= 1.0 \
		and maximum_single_fish_load_n > 0.0 and maximum_effective_fish_load_n > 0.0 \
		and transient_peak_gain >= 0.0 and transient_peak_decay_s > 0.0 \
		and transient_peak_cap_n >= 0.0 and maximum_instantaneous_tension_n > 0.0 \
		and danger_safe_ratio >= 0.0 and danger_safe_ratio <= 1.0 \
		and danger_onset_ratio >= danger_safe_ratio and danger_onset_ratio <= 1.0 \
		and danger_onset_ratio < danger_limit_ratio and danger_limit_ratio < danger_severe_ratio \
		and danger_limit_ratio <= 2.0 and danger_severe_ratio <= 4.0 \
		and break_danger_seconds_to_snap > 0.0 \
		and danger_rate_at_onset >= 0.0 and danger_rate_at_limit >= 0.0 \
		and danger_rate_at_severe >= 0.0 and danger_severe_rate_per_ratio >= 0.0 \
		and danger_recovery_rate >= 0.0


static func _finite_nonnegative(value: float, fallback: float) -> float:
	return maxf(0.0, value) if is_finite(value) else fallback
