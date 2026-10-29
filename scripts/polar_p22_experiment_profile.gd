extends Resource
class_name PolarP22ExperimentProfile
## Isolated P2.2 experiment inputs. This resource is not used by the game.

@export var boat_scene_path := "res://scenes/boats/SailingBoat8m.tscn"
@export var base_main_sail_area_m2 := 10.16025
@export var base_headsail_area_m2 := 5.16
@export var total_sail_area_candidates_m2 := PackedFloat32Array([15.32025, 28.0, 30.0, 32.0])
@export var area_test_wind_speeds_kn := PackedFloat32Array([8.0, 12.0])
@export var area_test_twa_degrees := PackedFloat32Array([50.0, 70.0, 90.0, 120.0])
@export var trim_test_wind_speed_kn := 12.0
@export var trim_test_twa_degrees := PackedFloat32Array([70.0, 90.0, 120.0])
@export var trim_offsets_degrees := PackedFloat32Array([-10.0, -5.0, 5.0, 10.0])
@export var fixed_wind_seed := 481516
@export var fixed_wind_from_degrees := 180.0
@export var physics_step_seconds := 1.0 / 60.0
@export var physics_warmup_seconds := 60.0
@export var stability_window_seconds := 30.0
@export var stable_sample_seconds := 30.0
@export var case_timeout_seconds := 300.0


func proportional_area_split(total_area_m2: float) -> Dictionary:
	var base_total := base_main_sail_area_m2 + base_headsail_area_m2
	var scale := total_area_m2 / base_total
	return {
		"main_sail_area_m2": base_main_sail_area_m2 * scale,
		"headsail_area_m2": base_headsail_area_m2 * scale,
		"total_sail_area_m2": total_area_m2,
		"area_scale": scale,
	}
