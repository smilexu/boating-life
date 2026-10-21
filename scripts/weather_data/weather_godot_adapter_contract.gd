extends RefCounted
class_name WeatherGodotAdapterContract

## Validates a serialized simulation state before a future adapter submits it
## to WeatherStateController. No controller or game scene is accessed here.

const SIMULATION_CONTRACT := preload("res://scripts/weather_data/weather_simulation_core_contract.gd")


static func prepare_weather_target(simulation_output: Dictionary, state_index: int = 0) -> Dictionary:
	var validation := SIMULATION_CONTRACT.validate_simulation_output(simulation_output)
	if not bool(validation.get("ok", false)):
		return validation
	var states: Array = simulation_output["weather_states"]
	if state_index < 0 or state_index >= states.size():
		return {"ok": false, "error": "weather_state_index_out_of_range"}
	var selected: Dictionary = states[state_index]
	return {
		"ok": true,
		"payload": {
			"region_id": str(simulation_output["region_id"]),
			"request_id": str(simulation_output["request_id"]),
			"target_weather_id": str(selected["visual_weather_id"]),
			"valid_from_utc": str(selected["valid_from_utc"]),
			"valid_until_utc": str(selected["valid_until_utc"]),
			"wind_profile": selected["wind"].duplicate(true),
			"source_climate": str(simulation_output.get("source_climate", "")),
			"seed": int(simulation_output.get("simulation_seed", 0)),
		},
	}
