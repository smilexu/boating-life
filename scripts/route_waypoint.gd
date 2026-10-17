class_name RouteWaypoint
extends Resource

## Stable geographic waypoint data independent of scene nodes and vessel control.

@export var waypoint_id: StringName = &""
@export_range(-90.0, 90.0, 0.000001) var latitude_deg := 0.0
@export_range(-180.0, 180.0, 0.000001) var longitude_deg := 0.0
@export_range(1.0, 5000.0, 1.0) var arrival_radius_m := 150.0
@export_range(-1.0, 30.0, 0.1) var optional_speed_limit_mps := -1.0
@export_multiline var navigation_notes := ""
