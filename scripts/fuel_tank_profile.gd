class_name FuelTankProfile
extends Resource

## Static vessel-specific tank configuration. Remaining fuel lives on the
## FuelTankComponent instance, so switching vessels cannot share this state.

enum FuelType { DIESEL, GASOLINE }

@export var fuel_type: FuelType = FuelType.DIESEL
@export_range(1.0, 10000.0, 1.0) var capacity_l := 40.0
@export_range(0.0, 10000.0, 0.1) var initial_fuel_l := 40.0
@export_range(0.05, 0.5, 0.01) var low_fuel_warning_fraction := 0.2


func fuel_type_name() -> String:
	return "柴油" if fuel_type == FuelType.DIESEL else "汽油"
