class_name BoatFishingFightProfile
extends Resource

## Force and struggle tuning for one boat-fishing species.
## These are game-balance values in newtons, not measured biological data.

@export_group("Identity")
@export var species_id := ""

@export_group("Force")
## Reference-size steady pull, in newtons.
@export_range(0.0, 1000.0, 0.1, "or_greater") var base_pull_n := 4.0
@export_range(1.0, 8.0, 0.05) var burst_multiplier := 2.5
@export_range(1.0, 4.0, 0.05) var minimum_burst_multiplier := 1.15
@export_range(0.0, 1.0, 0.01) var minimum_burst_stamina_ratio := 0.08
## Remaining stamina scales steady and burst force down to this fraction.
@export_range(0.0, 1.0, 0.01) var low_stamina_pull_multiplier := 0.45
@export_range(0.0, 1.0, 0.01) var recovery_pull_multiplier := 0.4
## Bounds this species' model output; these are not a line-break rating.
@export_range(0.0, 1000.0, 0.1, "or_greater") var minimum_pull_n := 0.0
@export_range(0.1, 5000.0, 0.1, "or_greater") var maximum_pull_n := 100.0
@export_range(0.01, 5.0, 0.01) var force_rise_time_s := 0.18
@export_range(0.01, 5.0, 0.01) var force_fall_time_s := 0.3

@export_group("Struggle timing")
@export_range(0.01, 10.0, 0.01) var burst_duration_min_s := 0.5
@export_range(0.01, 20.0, 0.01) var burst_duration_max_s := 1.0
## Time from the start of one burst to the start of the next, including burst time.
@export_range(0.1, 60.0, 0.1) var burst_interval_min_s := 3.0
@export_range(0.1, 120.0, 0.1) var burst_interval_max_s := 5.0
## Stamina ratio consumed per real second while bursting.
@export_range(0.0, 5.0, 0.01) var stamina_drain_rate := 0.2
## Stamina ratio recovered per real second while recovering.
@export_range(0.0, 5.0, 0.01) var stamina_recovery_rate := 0.1

@export_group("Body size")
## Reference length is based on the species' configured natural body-length range.
@export_range(0.01, 5.0, 0.01) var size_reference_length_m := 0.5
@export_range(0.0, 4.0, 0.05) var size_force_exponent := 2.0
@export_range(0.05, 5.0, 0.05) var minimum_size_factor := 0.5
@export_range(0.05, 10.0, 0.05) var maximum_size_factor := 2.0

@export_group("Active swim intent")
## Output only: this model does not move a fish or apply this speed to a scene node.
@export_range(0.0, 5.0, 0.05) var steady_swim_speed_mps := 0.15
@export_range(0.0, 10.0, 0.05) var burst_swim_speed_mps := 1.0
@export_range(0.0, 5.0, 0.05) var recovery_swim_speed_mps := 0.08


func get_size_factor(body_length_m: float) -> float:
	var reference_length := size_reference_length_m if _is_finite_positive(size_reference_length_m) else 0.5
	var safe_length := body_length_m if _is_finite_positive(body_length_m) else reference_length
	var exponent := clampf(size_force_exponent, 0.0, 4.0)
	var min_factor := maxf(0.05, minf(minimum_size_factor, maximum_size_factor))
	var max_factor := maxf(min_factor, maxf(minimum_size_factor, maximum_size_factor))
	var ratio := clampf(safe_length / reference_length, 0.05, 20.0)
	var factor := pow(ratio, exponent)
	if not is_finite(factor):
		return 1.0
	return clampf(factor, min_factor, max_factor)


func get_bounded_pull_n(value: float) -> float:
	var lower := minimum_pull_n if is_finite(minimum_pull_n) else 0.0
	var upper := maximum_pull_n if is_finite(maximum_pull_n) else 100.0
	upper = maxf(0.0, upper)
	lower = clampf(lower, 0.0, upper)
	if not is_finite(value):
		return lower
	return clampf(value, lower, upper)


func get_safe_burst_duration_range() -> Vector2:
	var low := _positive_or(burst_duration_min_s, 0.1)
	var high := _positive_or(burst_duration_max_s, low)
	return Vector2(minf(low, high), maxf(low, high))


func get_safe_burst_interval_range() -> Vector2:
	var low := _positive_or(burst_interval_min_s, 0.5)
	var high := _positive_or(burst_interval_max_s, low)
	return Vector2(maxf(0.1, minf(low, high)), maxf(0.1, maxf(low, high)))


func is_valid_for_species(expected_species_id: String = "") -> bool:
	if species_id.is_empty() or (not expected_species_id.is_empty() and species_id != expected_species_id):
		return false
	return is_finite(base_pull_n) and base_pull_n >= 0.0 and is_finite(maximum_pull_n) and maximum_pull_n > 0.0


static func _is_finite_positive(value: float) -> bool:
	return is_finite(value) and value > 0.0


static func _positive_or(value: float, fallback: float) -> float:
	return value if _is_finite_positive(value) else fallback
