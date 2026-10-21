extends Resource
class_name WeatherWindProfile

## Temporary integration-test wind values. These are not Nordic climate data.

enum SeedStrategy {
	KEEP_WINDFIELD_SEED,
	APPLY_PROFILE_SEED_ON_STARTUP,
}

@export_range(0.0, 30.0, 0.1) var mean_wind_speed_mps := 6.0
@export_range(0.0, 360.0, 0.1) var mean_wind_from_degrees := 240.0
@export_range(0.0, 15.0, 0.1) var gust_strength_mps := 2.0
@export_range(1.0, 180.0, 0.5) var gust_time_scale_seconds := 24.0
@export_range(50.0, 10000.0, 10.0) var gust_space_scale_meters := 450.0
@export_range(0.0, 30.0, 0.1) var gust_direction_variation_degrees := 8.0
@export_enum("Keep WindField seed", "Apply profile seed at startup") var seed_strategy: int = SeedStrategy.KEEP_WINDFIELD_SEED
@export var random_seed := 74291
@export var source_note := "Temporary gameplay tuning for W2.1 integration tests; not climate data."


func to_wind_state() -> Dictionary:
	return {
		"mean_wind_speed_mps": mean_wind_speed_mps,
		"mean_wind_from_degrees": fposmod(mean_wind_from_degrees, 360.0),
		"gust_strength_mps": gust_strength_mps,
		"gust_time_scale_seconds": gust_time_scale_seconds,
		"gust_space_scale_meters": gust_space_scale_meters,
		"gust_direction_variation_degrees": gust_direction_variation_degrees,
	}
