class_name CargoItemDefinition
extends Resource

## Lightweight manifest entry. Gameplay weight/space is independent of its visual.

@export var cargo_id: StringName = &""
@export var display_name := "货物"
@export_range(0.0, 1000000.0, 1.0, "or_greater") var weight_kg := 0.0
@export_range(0, 64, 1) var space_units := 1
@export var visual_asset_id: StringName = &""
