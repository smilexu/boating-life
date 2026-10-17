class_name CargoContractDefinition
extends Resource

## Immutable contract offer. Runtime status and cargo instance IDs live in the
## CargoEconomyManager save, never in this shared Resource.

@export var contract_id: StringName = &""
@export var origin_port_id: StringName = &""
@export var origin_port_display_name := ""
@export var destination_port_id: StringName = &""
@export var destination_port_display_name := ""
@export var display_name := "货运合同"
@export var cargo_type := "货物"
@export var cargo_items: Array[CargoItemDefinition] = []
@export_range(0, 64, 1) var required_space := 0
@export_range(0.0, 1000000.0, 1.0, "or_greater") var total_weight_kg := 0.0
@export_range(0, 100000000, 1, "or_greater") var reward_cents := 0


func get_reward_eur_text() -> String:
	return "€%d.%02d" % [int(reward_cents / 100), reward_cents % 100]
