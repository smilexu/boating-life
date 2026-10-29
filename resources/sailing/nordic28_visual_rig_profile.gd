extends Resource
## Visual-only mounting clearances for the Nordic 28 imported hull.
## These values never feed the sail, foil, buoyancy, or rigid-body calculations.

## Approved Nordic 28 V2 visual-only rig anchors. The physics profile is not
## read or modified by this resource.
@export var mast_base_local_m := Vector3(0.0, 1.3184, -1.0)
@export_range(5.0, 10.5, 0.05) var mast_length_m := 6.50
@export var visual_assembly_offset_local_m := Vector3(0.0, -0.30, 0.0)
@export var boom_pivot_local_m := Vector3(0.0, 1.9111, -1.0)
@export_range(2.5, 4.5, 0.05) var boom_length_m := 3.30
@export var main_head_local_m := Vector3(0.0, 7.6384, -1.0)
@export var jib_head_local_m := Vector3(0.0, 5.9500, -1.0)
@export var jib_tack_local_m := Vector3(0.0, 1.9614, -3.5498)
@export var jib_clew_local_m := Vector3(0.0, 1.6686, -1.1498)

@export_range(0.0, 0.15, 0.005) var mast_step_embed_m := 0.03
@export_range(0.20, 1.20, 0.01) var boom_clearance_over_roof_m := 0.40
@export_range(0.15, 0.35, 0.01) var minimum_boom_lower_edge_clearance_m := 0.20
@export_range(0.15, 0.60, 0.01) var roof_sample_half_width_m := 0.35
@export_range(0.10, 0.40, 0.01) var roof_sample_half_length_m := 0.22

## Visual-only Nordic 28 spade rudder mounting dimensions. The pivot's vertical
## position is still derived from the imported stern underside at runtime.
@export_range(0.0, 0.05, 0.005) var rudder_axis_hull_embed_m := 0.01
@export_range(0.90, 1.50, 0.01) var rudder_visual_span_m := 1.25
@export_range(0.30, 0.70, 0.01) var rudder_visual_max_chord_m := 0.48
@export_range(0.015, 0.06, 0.001) var rudder_stock_radius_m := 0.032
@export_range(0.02, 0.20, 0.005) var rudder_foil_top_clearance_m := 0.08

## Cockpit helm appearance only. The station is seated against the sampled GLB
## cockpit floor; the wheel animation reads the body's actual rudder angle.
@export var helm_station_local_m := Vector3(0.0, 0.0, 2.72)
@export_range(0.60, 0.90, 0.01) var helm_pedestal_height_m := 0.72
@export var helm_pedestal_base_size_m := Vector2(0.48, 0.38)
@export var helm_pedestal_top_size_m := Vector2(0.32, 0.26)
@export_range(0.30, 0.40, 0.005) var helm_wheel_outer_radius_m := 0.353
@export_range(4.0, 8.0, 0.1) var helm_wheel_degrees_per_rudder_degree := 180.0 / 35.0
@export_range(-1.0, 1.0, 2.0) var helm_wheel_rotation_sign := -1.0
