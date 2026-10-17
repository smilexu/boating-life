class_name ShallowReefAssetDefinition
extends Resource

enum Role { SINGLE_STONE, REEF_MODULE }

@export var asset_id: StringName = &""
@export_file("*.glb") var glb_path := ""
@export var enabled := true
@export var role: Role = Role.SINGLE_STONE
@export_range(0.0, 20.0, 0.05) var selection_weight := 1.0
@export_range(0.1, 3.0, 0.05) var target_height_min_m := 0.35
@export_range(0.1, 4.0, 0.05) var target_height_max_m := 0.8
@export_range(0.0, 0.55, 0.01) var burial_fraction := 0.24
@export_range(0.0, 0.3, 0.005) var maximum_placement_slope := 0.09
@export var allow_far_lod := false
