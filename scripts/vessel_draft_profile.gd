class_name VesselDraftProfile
extends Resource

## One cargo/draft profile shared by navigation checks and the visual load response.
## The visual model's empty waterline offset is calibrated independently per vessel.

@export var vessel_display_name := "测试船"
@export var vessel_id: StringName = &"unknown_vessel"
@export_category("Gameplay cargo capacity")
@export_range(0, 64, 1) var cargo_capacity_space_units := 0
@export_range(0.0, 20.0, 0.01, "or_greater") var empty_draft_m := 0.65
@export_range(0.0, 20.0, 0.01, "or_greater") var full_load_draft_m := 1.15
@export_range(0.0, 1000000.0, 1.0, "or_greater") var max_cargo_weight_kg := 1200.0
@export_category("Route planning · gameplay estimate")
@export_range(0.5, 20.0, 0.1) var cruise_speed_mps := 7.0
@export_category("Visual vessel dimensions · metres")
@export_range(0.0, 100.0, 0.01, "or_greater") var vessel_length_m := 0.0
@export_range(0.0, 100.0, 0.01, "or_greater") var vessel_beam_m := 0.0
@export_range(0.0, 100.0, 0.01, "or_greater") var vessel_height_m := 0.0


func draft_for_cargo_weight(cargo_weight_kg: float) -> float:
	var empty_draft := maxf(empty_draft_m, 0.0)
	var loaded_draft := maxf(full_load_draft_m, empty_draft)
	var cargo_weight := maxf(cargo_weight_kg, 0.0)
	var maximum_cargo := maxf(max_cargo_weight_kg, 0.0)
	var load_ratio := 0.0
	if cargo_weight > 0.0:
		load_ratio = 1.0 if maximum_cargo <= 0.0 else clampf(cargo_weight / maximum_cargo, 0.0, 1.0)
	return lerpf(empty_draft, loaded_draft, load_ratio)
