extends SceneTree

const RuntimeScript := preload("res://scripts/weather_runtime/weather_runtime_authority.gd")
const AdapterScript := preload("res://scripts/weather_runtime/weather_runtime_godot_adapter.gd")
const StateScript := preload("res://scripts/weather_state_controller.gd")
const WindFieldScript := preload("res://scripts/wind_field.gd")
const ProfileScript := preload("res://resources/weather_wind_profile.gd")
const RegionScript := preload("res://resources/weather_region.gd")
const PersistenceScript := preload("res://scripts/weather_runtime/weather_runtime_persistence.gd")
const PreviewScript := preload("res://scripts/weather_runtime/weather_runtime_preview_panel.gd")
const WorldTimeManagerScript := preload("res://scripts/world_time_manager.gd")
const Codec := preload("res://scripts/weather_data/weather_forecast_codec.gd")
const Core := preload("res://scripts/weather_data/weather_simulation_core.gd")
const FixturePath := "res://tests/fixtures/weather_simulation_two_day_fixture.json"
const TestDirectory := "user://weather_runtime_persistence_rollover_tests"

var _checks := 0
var _failures: Array[String] = []
var _fixture: Dictionary
var _long_run_elapsed_ms := 0.0


class VirtualClock extends Node:
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
			"authority_session_id": "virtual-weather-test",
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

	func get_real_utc_timestamp() -> float:
		return utc_unix

	func get_utc_for_test() -> float:
		return utc_unix

	func advance_virtual_real_seconds(seconds: float) -> void:
		utc_unix += seconds
		if paused:
			return
		var position := float(day_cycle_index) + cycle_seconds / 86400.0 + seconds * time_scale / 86400.0
		day_cycle_index = floori(position)
		cycle_seconds = fposmod(position, 1.0) * 86400.0


class VirtualProvider extends RefCounted:
	var read_result: Dictionary
	var refresh_result: Dictionary
	var refresh_calls := 0

	func read_forecast(_region_id: String) -> Dictionary:
		return read_result.duplicate(true)

	func refresh_region(_region_id: String, callback: Callable = Callable()) -> Dictionary:
		refresh_calls += 1
		var result := refresh_result if not refresh_result.is_empty() else read_result
		if callback.is_valid():
			callback.call(result.duplicate(true))
		return result.duplicate(true)

	func set_user_agent_contact(_value: String) -> void:
		pass


class VirtualVisual extends Node:
	var selected_index := 0
	var transition_count := 0

	func set_weather_by_index(index: int, _immediate: bool = false) -> void:
		selected_index = index
		transition_count += 1


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_cleanup_test_directory()
	_fixture = JSON.parse_string(FileAccess.get_file_as_string(FixturePath))
	_expect(_fixture is Dictionary, "offline weather fixture loads")
	await _test_first_run_persistence_modes_and_corrupt_storage()
	await _test_preview_is_read_only_and_no_network()
	await _test_paused_overnight_does_not_advance_weather()
	await _test_offline_calendar_gap_replans_without_cycle_catchup()
	await _test_virtual_ten_day_rollover_network_save_restore()
	_cleanup_test_directory()
	_expect(not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(TestDirectory)), "temporary weather runtime test data is removed")
	_expect(_failures.is_empty(), "all persistence and virtual-time assertions pass")
	if _failures.is_empty():
		print("Weather runtime persistence/rollover tests: %d checks passed; 10 virtual Stockholm date boundaries in %.2f ms." % [_checks, _long_run_elapsed_ms])
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_first_run_persistence_modes_and_corrupt_storage() -> void:
	var path := "%s/mode/state.json" % TestDirectory
	var persistence: WeatherRuntimePersistence = _new_persistence(path)
	var provider := VirtualProvider.new()
	provider.read_result = _fresh_result(_fixture)
	var setup := await _make_runtime(provider, persistence, _fixture, 24, 12, _utc("2026-10-20T10:00:00Z"), 0.0, false, 2)
	var authority: WeatherRuntimeAuthority = setup["authority"]
	var state: WeatherStateController = setup["state"]
	_expect(authority.mapping_status == "matched", "missing weather save starts a new authority without blocking startup")
	_expect(str(state.get_operating_mode_name()) == "AUTO", "new authority defaults to AUTO")
	_expect(FileAccess.file_exists(path), "initial authoritative timeline is saved as a critical state change")
	state.set_weather_by_name(&"Overcast")
	authority._save_runtime_state()
	var saved := persistence.load_state("oresund")
	_expect(bool(saved.get("ok", false)), "versioned weather state saves and validates")
	var saved_payload: Dictionary = saved.get("data", {})
	_expect(str(saved_payload.get("operating_mode", "")) == "MANUAL" and str(saved_payload.get("manual_weather_preset", "")) == "Overcast", "manual mode and selected preset are persisted")
	var saved_text := FileAccess.get_file_as_string(path)
	_expect(not saved_text.contains("F12") and not saved_text.contains("debug_wind_override") and not saved_text.contains("smilingkystudio@gmail.com") and not saved_text.contains("MET_NORWAY_CONTACT"), "save excludes temporary F12 settings, contact, and private config")
	var new_setup := await _make_runtime(provider, persistence, _fixture, 24, 12, setup["clock"].utc_unix, 0.0, false, 2)
	var restored_state: WeatherStateController = new_setup["state"]
	var restored_authority: WeatherRuntimeAuthority = new_setup["authority"]
	_expect(restored_authority.recovery_status in ["restored", "active"], "saved timeline restores after WorldTimeManager cursor is available")
	_expect(str(restored_state.get_operating_mode_name()) == "MANUAL", "MANUAL mode restores without automatic overwrite")
	_expect(str(restored_state.target_weather_id) == "Overcast", "manual weather preset restores")
	_expect(int(restored_authority._timeline.get("simulation_seed", -1)) == int(authority._timeline.get("simulation_seed", -2)), "simulation seed and full active timeline restore")
	await _dispose_setup(new_setup)
	await _dispose_setup(setup)

	var valid_text := FileAccess.get_file_as_string(path)
	var parsed: Dictionary = JSON.parse_string(valid_text)
	parsed["schema_version"] = 999
	_write_text(path, JSON.stringify(parsed))
	_expect(str(persistence.load_state("oresund").get("reason", "")) == "unsupported_schema", "unsupported weather save schema is rejected explicitly")
	_write_text(path, "{broken json")
	_expect(str(persistence.load_state("oresund").get("status", "")) == "corrupt", "corrupt JSON is detected without crashing")
	_write_text(path, valid_text)
	var blocked_path := "%s/replace_failure/state.json" % TestDirectory
	var blocked_persistence: WeatherRuntimePersistence = _new_persistence(blocked_path)
	_expect(bool(blocked_persistence.save_state(saved_payload).get("ok", false)), "atomic replacement test starts with a valid save at the target path")
	var blocked_temp_path := ProjectSettings.globalize_path(blocked_path) + ".tmp-%d" % OS.get_process_id()
	DirAccess.make_dir_recursive_absolute(blocked_temp_path)
	var blocked_save: Dictionary = blocked_persistence.save_state(saved_payload)
	_expect(not bool(blocked_save.get("ok", false)), "a staging write failure is surfaced rather than reported as success")
	_expect(bool(blocked_persistence.load_state("oresund").get("ok", false)), "a failed atomic save leaves the prior valid save readable at the same path")


func _test_preview_is_read_only_and_no_network() -> void:
	var provider := VirtualProvider.new()
	provider.read_result = _fresh_result(_fixture)
	var setup := await _make_runtime(provider, null, _fixture, 24, 12, _utc("2026-10-20T10:00:00Z"), 0.0, false, 2)
	var authority: WeatherRuntimeAuthority = setup["authority"]
	var clock: VirtualClock = setup["clock"]
	var field: WindField = setup["field"]
	var before_cursor := clock.get_authoritative_state()
	var before_sample := authority.current_sample.duplicate(true)
	var before_wind: Dictionary = field.get_formal_wind_settings()
	var before_refresh_calls := provider.refresh_calls
	var panel: WeatherRuntimePreviewPanel = setup["preview"]
	_expect(not panel.is_panel_open(), "weather preview panel starts closed")
	var toggle_event := InputEventKey.new()
	toggle_event.pressed = true
	toggle_event.physical_keycode = KEY_F12
	toggle_event.ctrl_pressed = true
	toggle_event.shift_pressed = true
	panel._unhandled_key_input(toggle_event)
	_expect(panel.is_panel_open(), "Ctrl+Shift+F12 opens the isolated weather preview")
	var offset := authority.get_current_timeline_cycle_offset() + 0.25
	var preview: Dictionary = authority.call("get_preview_weather_at_cycle_offset", offset)
	_expect(bool(preview.get("ok", false)), "read-only preview samples a future point in the active timeline")
	_expect(JSON.stringify(authority.current_sample) == JSON.stringify(before_sample), "preview does not replace current formal weather")
	_expect(JSON.stringify(clock.get_authoritative_state()) == JSON.stringify(before_cursor), "preview does not change WorldTimeManager cursor")
	_expect(JSON.stringify(field.get_formal_wind_settings()) == JSON.stringify(before_wind), "preview does not modify WindField")
	_expect(provider.refresh_calls == before_refresh_calls, "preview does not request or refresh weather data")
	_expect(not FileAccess.file_exists("%s/preview/state.json" % TestDirectory), "read-only preview does not create a save")
	panel._unhandled_key_input(toggle_event)
	_expect(not panel.is_panel_open(), "closing the preview leaves runtime behavior unchanged")
	await _dispose_setup(setup)


func _test_paused_overnight_does_not_advance_weather() -> void:
	var provider := VirtualProvider.new()
	provider.read_result = _fresh_result(_long_forecast(_fixture, 12, "2026-10-20T08:00:00Z", "2026-10-20T08:05:00Z", 0.0))
	var setup := await _make_runtime(provider, null, provider.read_result["data"], 24, 12, _utc("2026-10-20T22:30:00Z"), 0.0, false, 7)
	var authority: WeatherRuntimeAuthority = setup["authority"]
	var clock: VirtualClock = setup["clock"]
	var before_timeline := str(authority.get_timeline_metadata().get("timeline_version", ""))
	var before_sample := authority.current_sample.duplicate(true)
	clock.paused = true
	clock.advance_virtual_real_seconds(2.0 * 3600.0)
	authority.update_runtime_now(true)
	_expect(str(authority.get_timeline_metadata().get("timeline_version", "")) == before_timeline, "local midnight during paused game does not rebase or advance the timeline")
	_expect(int(clock.day_cycle_index) == 12 and is_equal_approx(clock.cycle_seconds, 0.0), "virtual WorldTimeManager cursor remains frozen while paused")
	clock.paused = false
	clock.revision_reason = "resumed"
	clock.control_revision += 1
	clock.advance_virtual_real_seconds(1.0)
	authority.update_runtime_now(true)
	_expect(str(authority.get_timeline_metadata().get("timeline_version", "")) != before_timeline, "after resume the authority replans against the current Stockholm date")
	_expect(absf(float(authority.current_sample.get("mean_wind_speed_mps", -1.0)) - float(before_sample.get("mean_wind_speed_mps", -2.0))) < 0.0001, "date replan starts from the held formal sample without a wind jump")
	await _dispose_setup(setup)


func _test_offline_calendar_gap_replans_without_cycle_catchup() -> void:
	var path := "%s/offline_gap/state.json" % TestDirectory
	var persistence: WeatherRuntimePersistence = _new_persistence(path)
	var document := _long_forecast(_fixture, 12, "2026-10-20T08:00:00Z", "2026-10-20T08:05:00Z", 0.0)
	var provider := VirtualProvider.new()
	provider.read_result = _fresh_result(document)
	var setup := await _make_runtime(provider, persistence, document, 24, 12, _utc("2026-10-20T10:00:00Z"), 0.0, false, 7)
	var authority: WeatherRuntimeAuthority = setup["authority"]
	var clock: VirtualClock = setup["clock"]
	var saved_cursor := clock.get_authoritative_state()
	var saved_utc := clock.utc_unix
	var saved_sample: Dictionary = authority.current_sample.duplicate(true)
	var saved_history: Array = authority.historical_segments.duplicate(true)
	var saved_version := str(authority._timeline.get("timeline_version", ""))
	authority._save_runtime_state()
	await _dispose_setup(setup)
	# The process is offline for two Stockholm dates, but WorldTimeManager has
	# intentionally not advanced its game-day cursor during shutdown.
	var offline_resume_utc := saved_utc + 2.0 * 86400.0
	setup = await _make_runtime(provider, persistence, document, 24, int(saved_cursor["day_cycle_index"]), offline_resume_utc, float(saved_cursor["cycle_seconds"]), false, 7)
	authority = setup["authority"]
	clock = setup["clock"]
	_expect(clock.day_cycle_index == int(saved_cursor["day_cycle_index"]) and is_equal_approx(clock.cycle_seconds, float(saved_cursor["cycle_seconds"])), "offline restart does not catch up frozen game-day cycles")
	_expect(authority.mapping_status == "matched" and not authority._restore_reanchor_pending, "offline calendar mismatch is explicitly replanned before AUTO resumes")
	_expect(str(authority.last_rollover_reason) == "restore_reanchor" and str(authority._timeline.get("timeline_version", "")) != saved_version, "offline replan records a new timeline version and recovery reason")
	_expect(absf(float(authority.current_sample.get("mean_wind_speed_mps", -1.0)) - float(saved_sample.get("mean_wind_speed_mps", -2.0))) < 0.0001, "offline replan preserves the last formal wind state at its new anchor")
	var resumed_utc := Codec.parse_utc_timestamp_to_unix(str(authority.current_sample.get("valid_time_utc", "")))
	_expect(absf(float(resumed_utc) - offline_resume_utc) < 1.0, "new active timeline uses current UTC while retaining the frozen game cursor")
	_expect(authority.historical_segments.size() >= saved_history.size(), "offline replan retains previously confirmed history")
	for index in range(saved_history.size()):
		_expect(JSON.stringify(authority.historical_segments[index]) == JSON.stringify(saved_history[index]), "offline replan does not rewrite an archived history segment")
	await _dispose_setup(setup)


func _test_virtual_ten_day_rollover_network_save_restore() -> void:
	var started_usec := Time.get_ticks_usec()
	var path := "%s/ten_day/state.json" % TestDirectory
	var persistence: WeatherRuntimePersistence = _new_persistence(path)
	var initial_forecast := _long_forecast(_fixture, 16, "2026-10-20T08:00:00Z", "2026-10-20T08:05:00Z", 0.0)
	var provider := VirtualProvider.new()
	provider.read_result = _fresh_result(initial_forecast)
	provider.refresh_result = provider.read_result.duplicate(true)
	var setup := await _make_runtime(provider, persistence, initial_forecast, 24, 12, _utc("2026-10-20T10:00:00Z"), 0.0, false, 7)
	var authority: WeatherRuntimeAuthority = setup["authority"]
	var clock: VirtualClock = setup["clock"]
	_expect(not authority._timeline.is_empty(), "seven-day runtime timeline starts from offline fixture")
	var boundaries: Array = authority._timeline.get("real_day_boundaries_utc", [])
	var found_25_hour_day := false
	for index in range(boundaries.size() - 1):
		var duration := Codec.parse_utc_timestamp_to_unix(str(boundaries[index + 1])) - Codec.parse_utc_timestamp_to_unix(str(boundaries[index]))
		if duration == 25 * 3600:
			found_25_hour_day = true
	_expect(found_25_hour_day, "active timeline explicitly includes Stockholm's 25-hour autumn DST date")
	var start_date := _date_key(WorldTimeManagerScript.stockholm_date_from_utc(clock.utc_unix))
	var start_version := str(authority._timeline.get("timeline_version", ""))
	var update_doc := _long_forecast(_fixture, 16, "2026-10-22T08:00:00Z", "2026-10-22T08:05:00Z", 1.2)
	var old_timeline: Dictionary = authority._timeline.duplicate(true)
	for day in range(1, 11):
		var version_before_boundary := str(authority._timeline.get("timeline_version", ""))
		clock.advance_virtual_real_seconds(86400.0)
		# Apply the new authoritative cursor first, so network comparisons share
		# one virtual instant rather than yesterday's cached display sample.
		var boundary_result := authority.update_runtime_now(false)
		_expect(bool(boundary_result.get("ok", false)), "virtual date boundary samples without waiting or frame stepping")
		if day == 3:
			var old_offset := authority._timeline_cycle_offset_at(clock.get_authoritative_state())
			var update_result := _fresh_result(update_doc)
			update_result["cache_source"] = "network"
			update_result["refresh_status"] = "success"
			provider.read_result = update_result.duplicate(true)
			provider.refresh_result = update_result.duplicate(true)
			authority._on_provider_refresh_completed(update_result)
			var updated_frames: Array = authority._timeline.get("keyframes", [])
			var preserved := true
			for old_frame in old_timeline.get("keyframes", []):
				if float(old_frame.get("cycle_offset", 0.0)) >= old_offset - 0.000001:
					continue
				var found := false
				for new_frame in updated_frames:
					if is_equal_approx(float(new_frame.get("cycle_offset", -999.0)), float(old_frame.get("cycle_offset", -998.0))):
						found = JSON.stringify(new_frame) == JSON.stringify(old_frame)
						break
				if not found:
					preserved = false
			_expect(preserved, "forecast refresh preserves experienced timeline frames exactly")
			if not preserved:
				print("[weather-history] preserve_offset=%.6f old_frames=%d new_frames=%d version=%s" % [old_offset, (old_timeline.get("keyframes", []) as Array).size(), updated_frames.size(), str(authority.mapping_status)])
		elif day == 4:
			provider.read_result = {"status": "unavailable", "region_id": "oresund", "has_data": false, "refresh_due": true, "data": {}}
			provider.refresh_result = provider.read_result.duplicate(true)
			var before_outage_wind := float(authority.current_sample.get("mean_wind_speed_mps", -1.0))
			authority.update_runtime_now(true)
			_expect(authority.data_source_status == "unavailable" and authority.forecast_data_quality == "stale", "outage uses the still-valid prior forecast but labels it stale")
			_expect(absf(float(authority.current_sample.get("mean_wind_speed_mps", -2.0)) - before_outage_wind) < 1.0, "offline update retains a plausible current sample")
		elif day == 5:
			var recovery_doc := _long_forecast(_fixture, 16, "2026-10-24T08:00:00Z", "2026-10-24T08:05:00Z", 0.8)
			var recovery_result := _fresh_result(recovery_doc)
			recovery_result["cache_source"] = "network"
			recovery_result["refresh_status"] = "success"
			provider.read_result = recovery_result.duplicate(true)
			provider.refresh_result = recovery_result.duplicate(true)
			var before_recovery := float(authority.current_sample.get("mean_wind_speed_mps", -1.0))
			authority._on_provider_refresh_completed(recovery_result)
			_expect(authority.data_source_status == "live_network_response", "provider restoration installs the newer forecast")
			_expect(absf(float(authority.current_sample.get("mean_wind_speed_mps", -2.0)) - before_recovery) < 0.1, "new forecast update keeps current weather continuous at the same authoritative cursor")
			authority._save_runtime_state()
			var previous_version := str(authority._timeline.get("timeline_version", ""))
			var previous_seed := int(authority._timeline.get("simulation_seed", -1))
			var saved_cycle_index := clock.day_cycle_index
			var saved_cycle_seconds := clock.cycle_seconds
			var saved_utc := clock.utc_unix
			await _dispose_setup(setup)
			setup = await _make_runtime(provider, persistence, recovery_doc, 24, saved_cycle_index, saved_utc, saved_cycle_seconds, false, 7)
			authority = setup["authority"]
			clock = setup["clock"]
			_expect(not authority._restore_reanchor_pending and authority.mapping_status == "matched", "saved active timeline restores using the already-restored virtual WorldTimeManager cursor")
			_expect(str(authority._timeline.get("timeline_version", "")) == previous_version, "save/load preserves current timeline version and does not catch up offline cycles")
			_expect(int(authority._timeline.get("simulation_seed", -2)) == previous_seed, "save/load preserves deterministic seed")
			_expect(str((setup["state"] as WeatherStateController).get_operating_mode_name()) == "AUTO", "AUTO mode restores after the virtual restart")
		var step_result := authority.update_runtime_now(true)
		_expect(bool(step_result.get("ok", false)), "one explicit scheduler update processes the virtual date boundary")
		var current_state: Dictionary = authority.current_sample
		var valid_until := Codec.parse_utc_timestamp_to_unix(str(authority._forecast_document.get("valid_until_utc", "")))
		var sampled_unix := Codec.parse_utc_timestamp_to_unix(str(current_state.get("valid_time_utc", "")))
		_expect(not current_state.is_empty() and sampled_unix < valid_until, "generated current sample remains within actual fixture forecast coverage")
		if day == 3:
			var version_after_update := str(authority._timeline.get("timeline_version", ""))
			authority._on_provider_refresh_completed(provider.refresh_result)
			_expect(str(authority._timeline.get("timeline_version", "")) == version_after_update, "re-reading the same forecast fingerprint does not regenerate the timeline")
		if day == 7:
			_expect(str(authority._timeline.get("timeline_version", "")) != version_before_boundary, "seven-day timeline automatically rolls before its coverage expires")
			_expect(authority.historical_segments.size() >= 1, "automatic rollover archives the confirmed weather segment")
	_expect(int(clock.day_cycle_index) == 12 + 24 * 10, "10 virtual real-day boundaries advance the unpaused world cursor by ten configured cycles")
	_expect(_date_key(WorldTimeManagerScript.stockholm_date_from_utc(clock.utc_unix)) != start_date, "virtual clock spans ten Stockholm calendar date boundaries")
	_expect(not str(authority._timeline.get("timeline_version", "")).is_empty() and str(authority._timeline.get("timeline_version", "")) != start_version, "timeline rolls before its seven-day coverage expires")
	_expect(authority.historical_segments.size() >= 1, "timeline rollover archives the already-experienced segment")
	_expect(authority.mapping_status == "matched" and authority.rollover_status == "active", "long run ends with a matched active timeline")
	var final_roll_count := authority.historical_segments.size()
	var final_roll_reason := authority.last_rollover_reason
	var final_cycle_index := clock.day_cycle_index
	var final_mapping_status := authority.mapping_status
	await _dispose_setup(setup)
	_long_run_elapsed_ms = float(Time.get_ticks_usec() - started_usec) / 1000.0
	print("[virtual-ten-day] elapsed_ms=%.2f archived_segments=%d last_roll_reason=%s cycle=%d status=%s" % [_long_run_elapsed_ms, final_roll_count, final_roll_reason, final_cycle_index, final_mapping_status])
	_expect(_long_run_elapsed_ms < 10000.0, "10-day virtual test completes within the 10-second target")
	_expect(not FileAccess.file_exists("%s/player_save.json" % TestDirectory), "test uses and cleans an isolated temporary save namespace")


func _make_runtime(
	provider: VirtualProvider,
	persistence: WeatherRuntimePersistence,
	document: Dictionary,
	cycles: int,
	cycle_index: int,
	start_utc: float,
	cycle_seconds: float,
	paused: bool,
	timeline_days: int
) -> Dictionary:
	var host := Node.new()
	host.name = "WeatherRuntimeVirtualTestHost"
	root.add_child(host)
	var clock := VirtualClock.new()
	clock.name = "Clock"
	clock.utc_unix = start_utc
	clock.day_cycle_index = cycle_index
	clock.cycle_seconds = cycle_seconds
	clock.time_scale = float(cycles)
	clock.paused = paused
	host.add_child(clock)
	var visual := VirtualVisual.new()
	visual.name = "WeatherController"
	host.add_child(visual)
	var field: WindField = WindFieldScript.new() as WindField
	field.name = "WindField"
	field.random_seed = 62917
	field.set_physics_process(false)
	host.add_child(field)
	var state: WeatherStateController = StateScript.new() as WeatherStateController
	state.name = "WeatherStateController"
	state.weather_controller_path = NodePath("../WeatherController")
	state.wind_field_path = NodePath("../WindField")
	state.world_time_manager_path = NodePath("../Clock")
	state.clear_wind_profile = _profile(5.0, 240.0)
	state.partly_cloudy_wind_profile = _profile(6.0, 220.0)
	state.overcast_wind_profile = _profile(8.0, 200.0)
	state.use_short_real_time_transition_for_testing = true
	host.add_child(state)
	var adapter: WeatherRuntimeGodotAdapter = AdapterScript.new() as WeatherRuntimeGodotAdapter
	adapter.name = "WeatherRuntimeGodotAdapter"
	adapter.weather_state_controller_path = NodePath("../WeatherStateController")
	host.add_child(adapter)
	provider.read_result = _fresh_result(document)
	var region: WeatherRegion = RegionScript.new() as WeatherRegion
	region.region_id = "oresund"
	region.display_name = "Øresund"
	region.latitude = 55.64
	region.longitude = 12.78
	var authority: WeatherRuntimeAuthority = RuntimeScript.new() as WeatherRuntimeAuthority
	authority.name = "WeatherRuntimeAuthority"
	authority.timeline_calendar_days = timeline_days
	authority.configure_dependencies(provider, clock, adapter, region, cycles, 7451)
	if persistence != null:
		authority.configure_persistence_for_testing(persistence, Callable(clock, "get_utc_for_test"))
	else:
		authority.persistence_enabled = false
	host.add_child(authority)
	await process_frame
	state.set_process(false)
	field.set_physics_process(false)
	var preview: WeatherRuntimePreviewPanel = PreviewScript.new() as WeatherRuntimePreviewPanel
	preview.authority_path = NodePath("../WeatherRuntimeAuthority")
	preview.state_controller_path = NodePath("../WeatherStateController")
	preview.show_in_debug_builds = true
	host.add_child(preview)
	await process_frame
	return {"host": host, "clock": clock, "visual": visual, "field": field, "state": state, "adapter": adapter, "provider": provider, "authority": authority, "preview": preview}


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


func _new_persistence(path: String) -> WeatherRuntimePersistence:
	var persistence: WeatherRuntimePersistence = PersistenceScript.new() as WeatherRuntimePersistence
	persistence.file_path = path
	return persistence


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


func _long_forecast(base: Dictionary, day_count: int, issued_at: String, retrieved_at: String, speed_delta: float) -> Dictionary:
	var document := base.duplicate(true)
	var first_sample: Dictionary = (base.get("timeseries", []) as Array)[0].duplicate(true)
	var start_unix := _utc("2026-10-20T00:00:00Z")
	var series: Array[Dictionary] = []
	for index in range(day_count * 4 + 1):
		var valid_unix := start_unix + index * 6 * 3600
		var valid_iso := Codec._utc_iso_from_unix(valid_unix)
		var sample := first_sample.duplicate(true)
		sample["valid_time_utc"] = valid_iso
		sample["air_temperature_c"] = 8.0 + float(index % 9) * 0.7
		sample["relative_humidity_percent"] = 78.0 + float(index % 5) * 2.0
		sample["air_pressure_hpa"] = 1009.0 + float(index % 7) * 0.3
		sample["wind_speed_mps"] = maxf(0.0, 5.0 + speed_delta + sin(float(index) * 0.27) * 0.6)
		sample["wind_gust_mps"] = float(sample["wind_speed_mps"]) + 2.0
		sample["wind_from_direction_deg"] = fposmod(350.0 + float(index % 20) * 2.0, 360.0)
		sample["cloud_fraction"] = 0.70 + float(index % 4) * 0.04
		for period_value in sample.get("precipitation_periods", []):
			var period: Dictionary = period_value
			period["period_start_utc"] = valid_iso
			period["period_end_utc"] = Codec._utc_iso_from_unix(valid_unix + int(period["duration_hours"]) * 3600)
		for symbol_value in sample.get("weather_symbol_periods", []):
			var symbol: Dictionary = symbol_value
			symbol["period_start_utc"] = valid_iso
			symbol["period_end_utc"] = Codec._utc_iso_from_unix(valid_unix + int(symbol["duration_hours"]) * 3600)
		series.append(sample)
	document["schema_version"] = 2
	document["provider_id"] = "offline_virtual_forecast"
	document["region_id"] = "oresund"
	document["forecast_issued_at_utc"] = issued_at
	document["retrieved_at_utc"] = retrieved_at
	document["valid_from_utc"] = str(series[0]["valid_time_utc"])
	document["valid_until_utc"] = Codec._utc_iso_from_unix(start_unix + day_count * 86400)
	document["timeseries"] = series
	var validation := Codec.validate_standardized_document(document)
	_expect(bool(validation.get("ok", false)), "long deterministic fixture validates: %s" % str(validation.get("error", "")))
	return document


func _utc(timestamp: String) -> float:
	return float(Codec.parse_utc_timestamp_to_unix(timestamp))


func _date_key(date: Dictionary) -> String:
	return "%04d-%02d-%02d" % [int(date.get("year", 0)), int(date.get("month", 0)), int(date.get("day", 0))]


func _write_text(path: String, value: String) -> void:
	var directory := ProjectSettings.globalize_path(path).get_base_dir()
	DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(value)
		file.flush()
		file.close()


func _cleanup_test_directory() -> void:
	var absolute := ProjectSettings.globalize_path(TestDirectory)
	if DirAccess.dir_exists_absolute(absolute):
		var root_dir := DirAccess.open(TestDirectory)
		if root_dir != null:
			_remove_directory_contents(root_dir, absolute)


func _remove_directory_contents(directory: DirAccess, absolute_path: String) -> void:
	directory.list_dir_begin()
	var entry := directory.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			var child_path := absolute_path.path_join(entry)
			if directory.current_is_dir():
				var child := DirAccess.open(child_path)
				if child != null:
					_remove_directory_contents(child, child_path)
				DirAccess.remove_absolute(child_path)
			else:
				DirAccess.remove_absolute(child_path)
		entry = directory.get_next()
	directory.list_dir_end()
	DirAccess.remove_absolute(absolute_path)


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL: " + message)
