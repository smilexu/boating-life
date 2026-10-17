class_name PortDefinition
extends Resource

## Stable, data-only identity and placement for a port. Local layout offsets are
## east/north metres in the greybox's unrotated frame; the harbor applies yaw.

@export var port_id: StringName = &""
@export var display_name := "Port"
@export_range(-90.0, 90.0, 0.000001) var latitude_deg := 0.0
@export_range(-180.0, 180.0, 0.000001) var longitude_deg := 0.0
@export_range(-180.0, 180.0, 1.0) var layout_rotation_degrees := 0.0
@export var entrance_offset_east_north_m := Vector2.ZERO
@export var approach_offset_east_north_m := Vector2.ZERO
@export var departure_offset_east_north_m := Vector2.ZERO
@export var service_offset_east_north_m := Vector2.ZERO
@export var berth_definitions: Array[Dictionary] = []
## Game-only override metadata. Polygon footprints are generated from the
## shared greybox layout and are clipped to the port's small test water area.
@export var navigation_depth_overrides: Dictionary = {}
@export var depth_override_id_prefix := "port"
@export var environment_configuration: Dictionary = {}
@export var service_config: PortServiceConfig


func get_primary_berth() -> Dictionary:
	return berth_definitions[0].duplicate(true) if not berth_definitions.is_empty() else {}


func get_depth_override(area_id: String) -> Dictionary:
	var value: Variant = navigation_depth_overrides.get(area_id, {})
	return value.duplicate(true) if value is Dictionary else {}
