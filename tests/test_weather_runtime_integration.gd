extends SceneTree

const RuntimeScript := preload("res://scripts/weather_runtime/weather_runtime_authority.gd")
const AdapterScript := preload("res://scripts/weather_runtime/weather_runtime_godot_adapter.gd")
const StateScript := preload("res://scripts/weather_state_controller.gd")
const WindFieldScript := preload("res://scripts/wind_field.gd")
const ProfileScript := preload("res://resources/weather_wind_profile.gd")
const RegionScript := preload("res://resources/weather_region.gd")
const WorldTimeManagerScript := preload("res://scripts/world_time_manager.gd")
const FixturePath := "res://tests/fixtures/weather_simulation_two_day_fixture.json"
const Codec := preload("res://scripts/weather_data/weather_forecast_codec.gd")

var _checks := 0
var _failures: Array[String] = []
var _fixture: Dictionary


class FakeClock extends Node:
	signal state_changed(snapshot: Dictionary)

	var utc_unix := 0.0
	var day_cycle_index := 12
	var cycle_seconds := 0.0
	var time_scale := 24.0
	var paused := false
	var control_revision := 0
	var revision_reason := "runtime_start"

	func get_authoritative_state() -> Dictionary:
		return {
			"day_cycle_index": day_cycle_index,
			"cycle_seconds": cycle_seconds,
			"time_scale": time_scale,
			"paused": paused,
			"authority_control_revision": control_revision,
			"revision_reason": revision_reason,
			"authoritative_timestamp_utc": utc_unix,
			"authority_session_id": "offline-test-session",
			"authority_snapshot_sequence": control_revision + 1,
			"authority_sync_anchor": {
				"day_cycle_index": day_cycle_index,
				"cycle_seconds": cycle_seconds,
				"time_scale": time_scale,
				"paused": paused,
				"authoritative_timestamp_utc": utc_unix,
				"authority_control_revision": control_revision,
				"authority_snapshot_sequence": control_revision + 1,
			},
		}

	func get_real_calendar_date() -> Dictionary:
		return WorldTimeManagerScript.stockholm_date_from_utc(utc_unix)

	func get_real_utc_timestamp() -> float:
		return utc_unix

	func advance_real_seconds(seconds: float) -> void:
		utc_unix += seconds
		if paused:
			return
		var cycle_position := float(day_cycle_index) + cycle_seconds / 86400.0 + seconds * time_scale / 86400.0
		day_cycle_index = floori(cycle_position)
		cycle_seconds = fposmod(cycle_position, 1.0) * 86400.0


class FakeVisual extends Node:
	var selected_index := -1
	var transition_count := 0

	func set_weather_by_index(index: int, _immediate: bool = false) -> void:
		selected_index = index
		transition_count += 1


class FakeProvider extends RefCounted:
	var read_result: Dictionary
	var refresh_result: Dictionary
	var refresh_calls := 0
	var pending_callback: Callable
	var defer_refresh := false
	var contact := ""

	func read_forecast(_region: String) -> Dictionary:
		return read_result.duplicate(true)

	func refresh_region(_region: String, callback: Callable = Callable()) -> Dictionary:
		refresh_calls += 1
		if defer_refresh:
			pending_callback = callback
			return {"status": "request_started", "has_data": bool(read_result.get("has_data", false)), "refresh_due": true}
		if callback.is_valid():
			callback.call(refresh_result.duplicate(true) if not refresh_result.is_empty() else read_result.duplicate(true))
		return refresh_result.duplicate(true) if not refresh_result.is_empty() else read_result.duplicate(true)

	func set_user_agent_contact(value: String) -> void:
		contact = value

	func complete_refresh(result: Dictionary) -> void:
		read_result = result.duplicate(true)
		if pending_callback.is_valid():
			pending_callback.call(result.duplicate(true))
		pending_callback = Callable()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_fixture = JSON.parse_string(FileAccess.get_file_as_string(FixturePath))
	_expect(_fixture is Dictionary, "offline forecast fixture loads")
	if not _fixture is Dictionary:
		quit(1)
		return
	await _test_fresh_cache_auto_manual_and_f12()
	await _test_stale_cache_and_async_forecast_update()
	await _test_unavailable_and_contact_missing()
	await _test_twelve_cycle_mode_and_mapping_conflict()
	await _test_snapshot_serialization_and_no_private_config()
	_expect(_failures.is_empty(), "all runtime integration assertions pass")
	if _failures.is_empty():
		print("WeatherRuntimeAuthority integration tests: %d checks passed (offline provider)." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_fresh_cache_auto_manual_and_f12() -> void:
	var setup := await _make_runtime(_fresh_result(_fixture), 24, 12, false)
	var authority: WeatherRuntimeAuthority = setup["authority"]
	var state: WeatherStateController = setup["state"]
	var field: WindField = setup["field"]
	var provider: FakeProvider = setup["provider"]
	var visual: FakeVisual = setup["visual"]
	var clock: FakeClock = setup["clock"]
	_expect(str(authority.get_timeline_metadata().get("region_id", "")) == "oresund", "fresh cached Øresund forecast produces an authoritative timeline")
	_expect(authority.data_source_status == "fresh_cache", "fresh cache state is distinct from forecast quality")
	_expect(authority.mapping_status == "matched" and authority.current_sample.has("mean_wind_speed_mps"), "AUTO applies current simulation sample")
	_expect(provider.refresh_calls == 0, "valid fresh cache does not trigger a redundant network refresh")
	_expect(str(state.get_operating_mode_name()) == "AUTO", "runtime authority owns AUTO mode after startup")
	_expect(visual.selected_index >= 0, "weather visual preset is routed through adapter and state controller")
	_expect(not state.is_transitioning(), "AUTO samples do not restart the long simulation-time wind transition")
	var stable_transition_count := visual.transition_count
	for _sample_index in range(4):
		authority._publish_current_sample(clock.get_authoritative_state())
	_expect(visual.transition_count == stable_transition_count, "unchanged visual weather does not restart the five-second sky transition")
	state._process(10.0)
	_expect(_wind_distance(state.get_wind_state(), authority.current_sample) < 0.05, "runtime wind tracker converges without chasing a restarted transition")
	var before_pause := authority.sample_authoritative_weather()
	clock.paused = true
	clock.control_revision += 1
	clock.revision_reason = "paused"
	clock.advance_real_seconds(30.0)
	authority._process(2.0)
	var while_paused := authority.sample_authoritative_weather()
	_expect(float(while_paused.get("state", {}).get("sampled_cycle_offset", -1.0)) == float(before_pause.get("state", {}).get("sampled_cycle_offset", -2.0)), "WorldTimeManager pause freezes the authoritative weather cursor")
	clock.paused = false
	clock.control_revision += 1
	clock.revision_reason = "resumed"
	clock.advance_real_seconds(1.0)
	var after_resume := authority.sample_authoritative_weather()
	_expect(float(after_resume.get("state", {}).get("sampled_cycle_offset", -1.0)) > float(while_paused.get("state", {}).get("sampled_cycle_offset", -2.0)), "weather cursor resumes from its paused position")

	var before_manual := visual.transition_count
	_expect(state.set_weather_by_index(WeatherStateController.WeatherId.PARTLY_CLOUDY), "manual shortcut API accepts a weather preset")
	_expect(str(state.get_operating_mode_name()) == "MANUAL", "manual weather selection suspends AUTO application")
	var sample_before := state.climate_weather_type
	var world: FakeClock = setup["clock"]
	world.cycle_seconds = 1800.0
	authority._publish_current_sample(world.get_authoritative_state())
	_expect(visual.transition_count == before_manual + 1, "manual preset causes one visual transition and AUTO sampling does not override it")
	_expect(state.climate_weather_type == sample_before, "MANUAL does not consume new runtime weather targets")
	var auto_key := InputEventKey.new()
	auto_key.pressed = true
	auto_key.physical_keycode = KEY_0
	state._unhandled_key_input(auto_key)
	_expect(str(state.get_operating_mode_name()) == "AUTO", "0 key returns from MANUAL to authoritative AUTO weather")
	state.set_manual_mode()

	field.set_debug_wind_override({
		"mean_wind_speed_mps": 21.0, "mean_wind_from_degrees": 120.0,
		"gust_strength_mps": 8.0, "gust_time_scale_seconds": 10.0,
		"gust_space_scale_meters": 100.0, "gust_direction_variation_degrees": 5.0,
	})
	state.set_auto_mode()
	state._process(8.0)
	_expect(str(state.get_operating_mode_name()) == "AUTO", "returning to AUTO resumes the current authoritative cursor")
	_expect(field.is_debug_wind_override_enabled(), "F12 debug override remains active and isolated during AUTO weather updates")
	_expect(float(field.get_formal_wind_settings().get("mean_wind_speed_mps", 0.0)) != 21.0, "formal climate target remains separate from F12 overlay")
	_expect(float(field.get_effective_wind_settings().get("mean_wind_speed_mps", 0.0)) == 21.0, "F12 continues to control only effective temporary wind")
	field.clear_debug_wind_override(0.0)
	field._physics_process(0.01)
	_expect(not field.is_debug_wind_override_enabled(), "F12 can clear independently without changing AUTO ownership")
	await _dispose_setup(setup)


func _test_stale_cache_and_async_forecast_update() -> void:
	var stale := _fresh_result(_fixture)
	stale["status"] = "stale_cache"
	stale["stale"] = true
	stale["stale_acceptable"] = true
	stale["refresh_due"] = true
	var provider := FakeProvider.new()
	provider.read_result = stale
	provider.defer_refresh = true
	var setup := await _make_runtime(stale, 24, 12, false, provider)
	var authority: WeatherRuntimeAuthority = setup["authority"]
	_expect(authority.data_source_status == "stale_cache", "acceptable stale cache is labeled stale, not fresh")
	_expect(not authority.current_sample.is_empty(), "acceptable stale forecast remains available as explicit fallback")
	_expect(provider.refresh_calls == 1 and provider.pending_callback.is_valid(), "stale forecast starts one asynchronous update")
	var before: Dictionary = authority.get_authoritative_weather_snapshot()["timeline"]
	var updated_document: Dictionary = _fixture.duplicate(true)
	updated_document["forecast_issued_at_utc"] = "2026-10-20T09:55:00Z"
	updated_document["retrieved_at_utc"] = "2026-10-20T10:05:00Z"
	for sample in updated_document["timeseries"]:
		if sample.has("wind_speed_mps"):
			sample["wind_speed_mps"] = float(sample["wind_speed_mps"]) + 1.0
	var fresh := _fresh_result(updated_document)
	fresh["cache_source"] = "network"
	provider.complete_refresh(fresh)
	var after: Dictionary = authority.get_authoritative_weather_snapshot()["timeline"]
	_expect(str(after.get("timeline_version", "")) != str(before.get("timeline_version", "")), "new forecast creates an updated timeline version")
	_expect(float(after.get("forecast_update", {}).get("preserved_through_cycle_offset", -1.0)) >= 12.0, "forecast update records the elapsed history preservation boundary")
	_expect(str(authority.data_source_status) == "live_network_response", "new provider response is distinguished from a disk-cache hit")
	await _dispose_setup(setup)


func _test_unavailable_and_contact_missing() -> void:
	var unavailable := {"status": "unavailable", "region_id": "oresund", "has_data": false, "refresh_due": true, "data": {}}
	var provider := FakeProvider.new()
	provider.read_result = unavailable
	provider.refresh_result = {"status": "configuration_required", "region_id": "oresund", "has_data": false, "refresh_due": true, "error": "user_agent_contact_required", "data": {}}
	var setup := await _make_runtime(unavailable, 24, 12, false, provider)
	var authority: WeatherRuntimeAuthority = setup["authority"]
	_expect(provider.refresh_calls == 1, "missing-cache startup performs at most one configured refresh attempt")
	_expect(authority.provider_status == "configuration_required", "missing User-Agent contact is reported as configuration required")
	_expect(authority.current_sample.is_empty(), "unavailable forecast does not synthesize an AUTO weather state")
	_expect(authority.mapping_status == "waiting_for_usable_forecast", "game remains available while weather forecast is unavailable")
	await _dispose_setup(setup)


func _test_twelve_cycle_mode_and_mapping_conflict() -> void:
	var setup := await _make_runtime(_fresh_result(_fixture), 12, 6, false)
	var authority: WeatherRuntimeAuthority = setup["authority"]
	var clock: FakeClock = setup["clock"]
	_expect(int(authority.get_timeline_metadata().get("cycles_per_real_day", 0)) == 12, "12-cycle configuration is encoded in timeline independently of clock scale")
	clock.time_scale = 10.0
	clock.control_revision += 1
	clock.revision_reason = "time_scale_set"
	clock.state_changed.emit(clock.get_authoritative_state())
	_expect(authority.mapping_status == "time_scale_mismatch_reanchor_required", "runtime multiplier mismatch latches a safe mapping conflict")
	_expect(str(authority.sample_authoritative_weather().get("error", "")) == "time_mapping_reanchor_required", "sampling stops rather than silently remapping a timeline")
	clock.time_scale = 12.0
	clock.control_revision += 1
	clock.revision_reason = "time_scale_set"
	clock.state_changed.emit(clock.get_authoritative_state())
	_expect(authority.mapping_status == "time_mapping_reanchor_required", "restoring the old multiplier does not silently clear the conflict")
	var reanchored := authority.reanchor_authoritative_timeline()
	_expect(bool(reanchored.get("ok", false)) and authority.mapping_status == "matched", "explicit reanchor safely restores weather timeline sampling")
	clock.time_scale = 24.0
	clock.control_revision += 1
	clock.revision_reason = "time_scale_set"
	clock.state_changed.emit(clock.get_authoritative_state())
	var mode_24_reanchor := authority.reanchor_authoritative_timeline(24)
	_expect(bool(mode_24_reanchor.get("ok", false)) and int(authority.get_timeline_metadata().get("cycles_per_real_day", 0)) == 24, "explicit reanchor can intentionally switch from 12 to 24 cycles when the WorldTimeManager scale matches")
	await _dispose_setup(setup)


func _test_snapshot_serialization_and_no_private_config() -> void:
	var setup := await _make_runtime(_fresh_result(_fixture), 24, 12, false)
	var authority: WeatherRuntimeAuthority = setup["authority"]
	var json := authority.serialize_authoritative_snapshot()
	var parsed: Variant = JSON.parse_string(json)
	_expect(parsed is Dictionary and int(parsed.get("schema_version", 0)) == 1, "authoritative weather snapshot JSON round-trips")
	_expect(not json.contains("user://weather_data") and not json.contains("@") and not json.contains("MET_NORWAY_CONTACT"), "snapshot excludes contact details and local cache paths")
	_expect(parsed is Dictionary and parsed.get("timeline", {}) is Dictionary, "snapshot includes serialized timeline for future client presentation")
	await _dispose_setup(setup)


func _make_runtime(
	provider_snapshot: Dictionary,
	cycles: int,
	cycle_index: int,
	manual: bool,
	injected_provider: FakeProvider = null
) -> Dictionary:
	var host := Node.new()
	host.name = "WeatherRuntimeOfflineTestHost"
	root.add_child(host)
	var clock := FakeClock.new()
	clock.name = "Clock"
	clock.utc_unix = Codec.parse_utc_timestamp_to_unix("2026-10-20T10:00:00Z")
	clock.day_cycle_index = cycle_index
	clock.time_scale = float(cycles)
	host.add_child(clock)
	var visual := FakeVisual.new()
	visual.name = "WeatherController"
	host.add_child(visual)
	var field: WindField = WindFieldScript.new() as WindField
	field.name = "WindField"
	field.random_seed = 9123
	field.set_physics_process(false)
	host.add_child(field)
	var profile_clear: WeatherWindProfile = _profile(5.0, 240.0)
	var profile_partly: WeatherWindProfile = _profile(6.0, 220.0)
	var profile_overcast: WeatherWindProfile = _profile(8.0, 200.0)
	var state: WeatherStateController = StateScript.new() as WeatherStateController
	state.name = "WeatherStateController"
	state.weather_controller_path = NodePath("../WeatherController")
	state.wind_field_path = NodePath("../WindField")
	state.world_time_manager_path = NodePath("../Clock")
	state.clear_wind_profile = profile_clear
	state.partly_cloudy_wind_profile = profile_partly
	state.overcast_wind_profile = profile_overcast
	state.use_short_real_time_transition_for_testing = true
	host.add_child(state)
	var adapter: WeatherRuntimeGodotAdapter = AdapterScript.new() as WeatherRuntimeGodotAdapter
	adapter.name = "WeatherRuntimeGodotAdapter"
	adapter.weather_state_controller_path = NodePath("../WeatherStateController")
	host.add_child(adapter)
	var provider := injected_provider if injected_provider != null else FakeProvider.new()
	provider.read_result = provider_snapshot.duplicate(true)
	var region: WeatherRegion = RegionScript.new() as WeatherRegion
	region.region_id = "oresund"
	region.display_name = "Øresund"
	region.latitude = 55.64
	region.longitude = 12.78
	var authority: WeatherRuntimeAuthority = RuntimeScript.new() as WeatherRuntimeAuthority
	authority.name = "WeatherRuntimeAuthority"
	authority.timeline_calendar_days = 2
	authority.persistence_enabled = false
	authority.configure_dependencies(provider, clock, adapter, region, cycles, 7451)
	host.add_child(authority)
	await process_frame
	state.set_process(false)
	field.set_physics_process(false)
	return {"host": host, "clock": clock, "visual": visual, "field": field, "state": state, "adapter": adapter, "provider": provider, "authority": authority}


func _dispose_setup(setup: Dictionary) -> void:
	var host: Node = setup.get("host")
	if is_instance_valid(host):
		host.queue_free()
	await process_frame


func _profile(speed: float, direction: float) -> WeatherWindProfile:
	var profile: WeatherWindProfile = ProfileScript.new() as WeatherWindProfile
	profile.mean_wind_speed_mps = speed
	profile.mean_wind_from_degrees = direction
	profile.gust_strength_mps = 1.0
	profile.gust_time_scale_seconds = 18.0
	profile.gust_space_scale_meters = 250.0
	profile.gust_direction_variation_degrees = 3.0
	return profile


func _fresh_result(document: Dictionary) -> Dictionary:
	return {
		"status": "fresh_cache",
		"region_id": "oresund",
		"has_data": true,
		"cache_hit": true,
		"cache_source": "disk",
		"refresh_due": false,
		"stale_acceptable": true,
		"stale_age_seconds": 0.0,
		"stale": false,
		"data": document.duplicate(true),
	}


func _wind_distance(wind_state: Dictionary, sample: Dictionary) -> float:
	if wind_state.is_empty() or not sample.has("mean_wind_speed_mps") or not sample.has("wind_from_direction_deg"):
		return INF
	var speed_error := absf(float(wind_state.get("mean_wind_speed_mps", 0.0)) - float(sample["mean_wind_speed_mps"]))
	var target_angle := deg_to_rad(float(sample["wind_from_direction_deg"]))
	var current_angle := deg_to_rad(float(wind_state.get("mean_wind_from_degrees", 0.0)))
	var angle_error := absf(rad_to_deg(atan2(sin(target_angle - current_angle), cos(target_angle - current_angle)))) / 360.0
	return speed_error + angle_error


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL: " + message)
