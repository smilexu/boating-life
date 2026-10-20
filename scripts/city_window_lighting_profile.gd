extends Resource
class_name CityWindowLightingProfile

enum BuildingKind {
	LANDMARK,
	RESIDENTIAL,
	OFFICE,
	BRICK_RESIDENTIAL,
}

@export var building_node_name := ""
@export var kind: BuildingKind = BuildingKind.RESIDENTIAL
@export var window_rank_mask: Texture2D
@export var far_proxy_mask: Texture2D
@export_range(0.0, 0.8, 0.01) var evening_lit_ratio := 0.3
@export_range(0.0, 0.8, 0.01) var late_night_lit_ratio := 0.15
@export var warm_window_color := Color("f2bd83")
@export var secondary_window_color := Color("e4e9e8")
@export_range(0.0, 1.0, 0.01) var secondary_color_ratio := 0.12
@export_range(0.0, 4.0, 0.05) var emission_strength := 1.25
@export_range(0.0, 1.0, 0.001) var pattern_offset := 0.0
@export_range(0.0, 8.0, 0.1) var far_proxy_emission_strength := 3.8
