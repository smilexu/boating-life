class_name FuelTankComponent
extends Node

signal fuel_changed(remaining_l: float, capacity_l: float)

@export var profile: FuelTankProfile

var fuel_remaining_l := -1.0
var total_fuel_consumed_l := 0.0


func _ready() -> void:
	if fuel_remaining_l < 0.0:
		fuel_remaining_l = profile.initial_fuel_l if profile != null else 0.0
	fuel_remaining_l = clampf(fuel_remaining_l, 0.0, get_capacity_l())


func get_capacity_l() -> float:
	return maxf(profile.capacity_l, 0.0) if profile != null else 0.0


func get_fuel_type_name() -> String:
	return profile.fuel_type_name() if profile != null else "未配置"


func get_remaining_capacity_l() -> float:
	return maxf(get_capacity_l() - maxf(fuel_remaining_l, 0.0), 0.0)


func consume_fuel(liters: float) -> float:
	if not is_finite(liters) or liters <= 0.0:
		return 0.0
	var consumed := minf(liters, maxf(fuel_remaining_l, 0.0))
	fuel_remaining_l = maxf(fuel_remaining_l - consumed, 0.0)
	if consumed > 0.0:
		total_fuel_consumed_l += consumed
		fuel_changed.emit(fuel_remaining_l, get_capacity_l())
	return consumed


## Returns the actual amount accepted; price and payment belong to a future
## port transaction, not to the tank.
func refuel(liters: float) -> float:
	if not is_finite(liters) or liters <= 0.0:
		return 0.0
	var accepted := minf(liters, get_remaining_capacity_l())
	fuel_remaining_l = clampf(fuel_remaining_l + accepted, 0.0, get_capacity_l())
	if accepted > 0.0:
		fuel_changed.emit(fuel_remaining_l, get_capacity_l())
	return accepted


func set_fuel_remaining_l(liters: float) -> void:
	if not is_finite(liters):
		return
	fuel_remaining_l = clampf(liters, 0.0, get_capacity_l())
	fuel_changed.emit(fuel_remaining_l, get_capacity_l())


func get_snapshot() -> Dictionary:
	var capacity := get_capacity_l()
	var remaining := clampf(fuel_remaining_l, 0.0, capacity)
	var fraction := clampf(remaining / capacity, 0.0, 1.0) if capacity > 0.0 else 0.0
	var warning_fraction := profile.low_fuel_warning_fraction if profile != null else 0.2
	return {
		"fuel_type": get_fuel_type_name(),
		"capacity_l": capacity,
		"remaining_l": remaining,
		"remaining_capacity_l": get_remaining_capacity_l(),
		"total_fuel_consumed_l": maxf(total_fuel_consumed_l, 0.0),
		"fraction": fraction,
		"low_fuel_warning_fraction": warning_fraction,
		"low_fuel_warning": remaining > 0.0 and fraction <= warning_fraction,
		"fuel_depleted": remaining <= 0.0,
	}
