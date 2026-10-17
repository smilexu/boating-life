class_name PortServiceConfig
extends Resource

## Data-only port service definition. Port-specific labels and availability live
## in resources so the service UI can be reused by later harbours.

@export var port_id: StringName = &""
@export var display_name := "港口"
@export var available_services: PackedStringArray = PackedStringArray()
@export var service_display_names: Dictionary = {}
@export var service_availability: Dictionary = {}
@export var cargo_contract_definitions: Array[CargoContractDefinition] = []


func get_service_display_name(service_id: String) -> String:
	return str(service_display_names.get(service_id, service_id))


func is_service_available(service_id: String) -> bool:
	return service_id in available_services and bool(service_availability.get(service_id, false))
