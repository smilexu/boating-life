class_name BoatFishingRigProfile
extends Resource

## Small data contract for P6 boat-fishing tackle. It does not own catch logic.

enum RigType { SINGLE_JIG, SABIKI }

@export var rig_id: StringName = &"single_jig"
@export var display_name_key: StringName = &"hud.boat_fishing.rig.single_jig"
@export var rig_type: RigType = RigType.SINGLE_JIG
@export_range(1, 5, 1) var hook_count := 1
@export_range(1, 5, 1) var maximum_catch_count := 1
@export_range(0.0, 1.0, 0.05) var hook_spacing_m := 0.0
@export_range(0.3, 2.5, 0.05) var sink_speed_mps := 1.25
@export_range(0.05, 0.3, 0.01) var top_leader_length_m := 0.12
@export_range(0.05, 0.3, 0.01) var bottom_leader_length_m := 0.14
@export_range(0.08, 0.18, 0.01) var branch_length_m := 0.10
@export var compatible_species_ids := PackedStringArray()
## Tags used by the shared fish-species profiles. Boat fishing compatibility is
## data driven and does not maintain a second species list in the controller.
@export var compatible_lure_tags := PackedStringArray()


func get_effective_height_m() -> float:
	return maxf(0.0, float(hook_count - 1) * hook_spacing_m)


func get_line_attachment_height_m() -> float:
	return top_leader_length_m + get_effective_height_m() + bottom_leader_length_m
