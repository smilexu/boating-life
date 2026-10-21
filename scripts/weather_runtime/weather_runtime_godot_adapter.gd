extends Node
class_name WeatherRuntimeGodotAdapter

## Thin boundary from serialized WeatherSimulationCore samples to the existing
## Godot WeatherStateController. It does not own time, network, or generation.

@export_node_path("Node") var weather_state_controller_path := NodePath("../WeatherStateController")

var _weather_state_controller: Node


func _ready() -> void:
	_weather_state_controller = get_node_or_null(weather_state_controller_path)


func apply_sample(sample: Dictionary, region_id: String) -> Dictionary:
	if _weather_state_controller == null:
		return {"ok": false, "error": "weather_state_controller_missing"}
	var visual_name := str(sample.get("visual_weather_id", "Unknown"))
	var visual_index := _visual_index(visual_name)
	if visual_index < 0:
		return {"ok": false, "error": "visual_weather_unavailable", "visual_weather_id": visual_name}
	var wind_state := _wind_state_from_sample(sample)
	var date := _date_from_sample(sample)
	# WeatherSimulationCore derives this only from a retained forecast symbol
	# window. Rain rate and wind are deliberately not used as proxies for thunder.
	var thunderstorm_forecast := bool(sample.get("thunderstorm_forecast", false))
	var thunderstorm_symbol := str(sample.get("weather_symbol", "")) if thunderstorm_forecast else ""
	var precipitation_available := sample.has("precipitation_intensity_mm_per_hour")
	var precipitation_rate := 0.0
	if precipitation_available:
		var raw_rate: Variant = sample.get("precipitation_intensity_mm_per_hour")
		if raw_rate is int or raw_rate is float:
			var parsed_rate := float(raw_rate)
			if is_finite(parsed_rate):
				precipitation_rate = maxf(parsed_rate, 0.0)
			else:
				precipitation_available = false
		else:
			precipitation_available = false
	var applied := bool(_weather_state_controller.call(
		"apply_runtime_climate_sample",
		str(sample.get("weather_type", visual_name)),
		visual_index,
		wind_state,
		region_id,
		date,
		sample.get("data_quality", "unavailable"),
		precipitation_rate,
		precipitation_available,
		thunderstorm_forecast,
		thunderstorm_symbol
	))
	return {
		"ok": applied,
		"visual_weather_id": visual_name,
		"wind_available": not wind_state.is_empty(),
		"precipitation_available": precipitation_available,
		"precipitation_intensity_mm_per_hour": precipitation_rate,
		"thunderstorm_forecast": thunderstorm_forecast,
	}


func _visual_index(visual_name: String) -> int:
	match visual_name:
		"Clear": return WeatherStateController.WeatherId.CLEAR
		"PartlyCloudy": return WeatherStateController.WeatherId.PARTLY_CLOUDY
		"Overcast": return WeatherStateController.WeatherId.OVERCAST
	return -1


func _wind_state_from_sample(sample: Dictionary) -> Dictionary:
	if not sample.has("mean_wind_speed_mps") or not sample.has("wind_from_direction_deg"):
		return {}
	var wind := {
		"mean_wind_speed_mps": maxf(float(sample["mean_wind_speed_mps"]), 0.0),
		# MET and the simulation core use meteorological FROM direction, clockwise
		# from true north. WindField expects the same convention.
		"mean_wind_from_degrees": fposmod(float(sample["wind_from_direction_deg"]), 360.0),
		"gust_strength_mps": 0.0,
		"gust_time_scale_seconds": 18.0,
		"gust_space_scale_meters": 250.0,
		"gust_direction_variation_degrees": 3.0,
	}
	var gust_target: Variant = sample.get("gust_target", {})
	if gust_target is Dictionary:
		wind["gust_strength_mps"] = maxf(float(gust_target.get("gust_strength_mps", 0.0)), 0.0)
		wind["gust_time_scale_seconds"] = maxf(float(gust_target.get("time_scale_seconds", 18.0)), 1.0)
		wind["gust_space_scale_meters"] = maxf(float(gust_target.get("space_scale_meters", 250.0)), 1.0)
	return wind


func _date_from_sample(sample: Dictionary) -> Dictionary:
	var label := str(sample.get("calendar_day_label", ""))
	var fields := label.split("-", false)
	if fields.size() != 3 or not fields[0].is_valid_int() or not fields[1].is_valid_int() or not fields[2].is_valid_int():
		return {}
	return {"year": int(fields[0]), "month": int(fields[1]), "day": int(fields[2])}
