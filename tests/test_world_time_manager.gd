extends SceneTree

const MANAGER_SCRIPT = preload("res://scripts/world_time_manager.gd")
const TEST_SAVE_PATH := "user://world_time_manager_test.json"

var _fake_monotonic_usec: int = 0
var _fake_utc: float = 0.0
var _failures: Array[String] = []
var _check_count: int = 0


func _initialize() -> void:
	_run_all()
	if _failures.is_empty():
		print("WorldTimeManager tests: all 12 requested categories passed (%d checks)." % _check_count)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _run_all() -> void:
	_test_default_and_elapsed_rates()
	_test_pause_and_time_scales()
	_test_natural_boundary_and_manual_jump()
	_test_calendar_midnight_month_and_year()
	_test_stockholm_dst_boundaries()
	_test_save_restore_and_snapshot_roundtrip()
	_test_offline_restore_and_real_weather_clock()
	_test_legacy_save_migration()
	_test_physics_delta_is_unscaled()


func _test_default_and_elapsed_rates() -> void:
	var manager := _new_manager(_utc(2026, 7, 8, 12, 0, 0))
	_expect(is_equal_approx(manager.state.time_scale, 24.0), "default time scale is 24x")
	_advance(150.0, manager)
	_expect(is_equal_approx(manager.state.cycle_seconds, 3600.0), "150 real seconds advance one game hour at 24x")
	_expect(manager.state.day_cycle_index == 0, "one game hour does not complete a cycle")
	manager.free()

	manager = _new_manager(_utc(2026, 7, 8, 12, 0, 0))
	_advance(3600.0, manager)
	_expect(is_equal_approx(manager.state.cycle_seconds, 0.0), "3600 real seconds complete one full day-cycle at 24x")
	_expect(manager.state.day_cycle_index == 1, "natural full cycle increments the global cycle index")
	_expect(manager.state.local_day_cycle_ordinal == 2, "today ordinal counts the initial cycle and natural boundary")
	manager.free()


func _test_pause_and_time_scales() -> void:
	var manager := _new_manager(_utc(2026, 7, 8, 12, 0, 0))
	manager.set_cycle_seconds(1234.0)
	manager.pause_time()
	_advance(120.0, manager)
	_expect(is_equal_approx(manager.state.cycle_seconds, 1234.0), "paused cycle does not advance")
	_expect(is_equal_approx(manager.get_last_real_delta_seconds(), 120.0), "pause still measures real elapsed time")
	manager.resume_time()
	_advance(1.0, manager)
	_expect(is_equal_approx(manager.state.cycle_seconds, 1258.0), "resume continues at the configured scale")
	for scale in [1.0, 12.0, 24.0, 60.0]:
		manager.set_cycle_seconds(0.0)
		manager.set_time_scale(scale)
		_advance(2.0, manager)
		_expect(is_equal_approx(manager.state.cycle_seconds, 2.0 * scale), "%.0fx scale advances by real seconds × scale" % scale)
	manager.free()


func _test_natural_boundary_and_manual_jump() -> void:
	var manager := _new_manager(_utc(2026, 7, 8, 12, 0, 0))
	manager.set_cycle_seconds(86399.0)
	var cycle_index_before_jump: int = manager.state.day_cycle_index
	manager.set_cycle_time(0, 0, 10.0)
	_expect(manager.state.day_cycle_index == cycle_index_before_jump, "manual jump across midnight does not increment cycle index")
	_advance(3599.0, manager)
	_expect(manager.state.day_cycle_index == cycle_index_before_jump, "cycle index stays unchanged before the natural boundary")
	_advance(1.0, manager)
	_expect(manager.state.day_cycle_index == cycle_index_before_jump + 1, "natural 24:00 crossing increments cycle index once")
	_expect(is_equal_approx(manager.state.cycle_seconds, 10.0), "cycle phase is continuous across its natural boundary")
	manager.free()


func _test_calendar_midnight_month_and_year() -> void:
	var manager := _new_manager(_utc(2026, 1, 31, 22, 59, 59))
	_expect(manager.state.real_calendar_date == {"year": 2026, "month": 1, "day": 31}, "Stockholm winter date uses UTC+1")
	_advance(1.0, manager)
	_expect(manager.state.real_calendar_date == {"year": 2026, "month": 2, "day": 1}, "Stockholm local midnight crosses month correctly")
	_fake_utc = _utc(2026, 12, 31, 22, 59, 59)
	manager.update_time()
	_expect(manager.state.real_calendar_date == {"year": 2026, "month": 12, "day": 31}, "year-end date before local midnight")
	_fake_utc += 1.0
	manager.update_time()
	_expect(manager.state.real_calendar_date == {"year": 2027, "month": 1, "day": 1}, "Stockholm local midnight crosses year correctly")
	_expect(manager.state.cycle_seconds > 0.0, "calendar date changes do not reset the daily cycle phase")
	manager.free()


func _test_stockholm_dst_boundaries() -> void:
	var spring_before := _utc(2026, 3, 29, 0, 59, 59)
	var spring_after := spring_before + 1.0
	_expect(MANAGER_SCRIPT.stockholm_date_from_utc(spring_before) == {"year": 2026, "month": 3, "day": 29}, "spring DST date before transition")
	_expect(MANAGER_SCRIPT.stockholm_offset_seconds_at_utc(spring_before) == 3600, "spring DST uses CET before 01:00 UTC")
	_expect(MANAGER_SCRIPT.stockholm_offset_seconds_at_utc(spring_after) == 7200, "spring DST uses CEST from 01:00 UTC")
	var fall_before := _utc(2026, 10, 25, 0, 59, 59)
	var fall_after := fall_before + 1.0
	_expect(MANAGER_SCRIPT.stockholm_offset_seconds_at_utc(fall_before) == 7200, "fall DST uses CEST before 01:00 UTC")
	_expect(MANAGER_SCRIPT.stockholm_offset_seconds_at_utc(fall_after) == 3600, "fall DST returns to CET from 01:00 UTC")
	var manager := _new_manager(spring_before)
	_advance(1.0, manager)
	_expect(manager.state.cycle_seconds == 24.0, "DST transition never changes monotonic cycle progression")
	manager.free()


func _test_save_restore_and_snapshot_roundtrip() -> void:
	var manager := _new_manager(_utc(2026, 7, 8, 12, 0, 0))
	manager.set_cycle_time(15, 40, 12.5)
	manager.set_time_scale(12.0)
	manager.set_calendar_date(2030, 2, 28)
	manager.pause_time()
	_expect(manager.get_real_calendar_date() == {"year": 2026, "month": 7, "day": 8}, "admin calendar override does not alter the real weather date")
	_expect(is_equal_approx(manager.get_real_utc_timestamp(), _fake_utc), "admin calendar override does not alter real UTC time")
	_expect(manager.save_state(TEST_SAVE_PATH), "state saves to JSON")
	var loaded_manager := _new_manager(_fake_utc)
	_expect(loaded_manager.load_state(TEST_SAVE_PATH), "saved JSON state loads")
	_expect(loaded_manager.state.day_cycle_index == manager.state.day_cycle_index, "persistence restores global cycle index")
	_expect(is_equal_approx(loaded_manager.state.cycle_seconds, manager.state.cycle_seconds), "persistence restores cycle phase")
	_expect(is_equal_approx(loaded_manager.state.time_scale, 12.0), "persistence restores multiplier")
	_expect(loaded_manager.state.paused, "persistence restores paused state")
	_expect(loaded_manager.state.calendar_override_enabled, "persistence restores explicit calendar override flag")
	_expect(loaded_manager.state.calendar_date == {"year": 2030, "month": 2, "day": 28}, "persistence restores override date")

	var snapshot: Dictionary = manager.create_snapshot()
	_expect(str(snapshot.get("snapshot_kind", "")) == "world_time_authority", "authority snapshot is explicitly typed")
	_expect(snapshot.has("authority_session_id") and snapshot.has("authority_snapshot_sequence"), "authority snapshot carries an epoch and ordered sample number")
	_expect(snapshot.has("authority_sync_anchor") and not snapshot.has("monotonic_anchor_usec"), "transferable UTC sync anchor is present without process-local monotonic time")
	_expect(str(snapshot.authority_sync_anchor.clock) == "utc_unix_seconds", "sync anchor declares its time coordinate")
	var replica := _new_manager(_fake_utc)
	_expect(replica.restore_snapshot(snapshot), "authoritative snapshot restores")
	var restored_snapshot: Dictionary = replica.create_snapshot()
	for key in ["calendar_date", "real_calendar_date", "day_cycle_index", "cycle_seconds", "time_scale", "paused", "state_revision", "authority_control_revision", "revision_reason", "calendar_override_enabled", "calendar_override_date", "local_day_cycle_ordinal", "cycle_starts_by_local_date"]:
		_expect(restored_snapshot.get(key) == snapshot.get(key), "snapshot roundtrip preserves %s" % key)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH))
	manager.free()
	loaded_manager.free()
	replica.free()


func _test_offline_restore_and_real_weather_clock() -> void:
	var manager := _new_manager(_utc(2026, 1, 1, 12, 0, 0))
	manager.set_cycle_time(9, 30, 0.0)
	manager.set_time_scale(12.0)
	var saved_cycle_seconds: float = manager.state.cycle_seconds
	_expect(manager.save_state(TEST_SAVE_PATH), "normal calendar state saves")
	_fake_utc = _utc(2026, 1, 3, 12, 0, 0)
	var restarted := _new_manager(_fake_utc)
	_expect(restarted.load_state(TEST_SAVE_PATH), "state reloads after simulated server downtime")
	_expect(is_equal_approx(restarted.state.cycle_seconds, saved_cycle_seconds), "day-cycle is frozen during server downtime")
	_expect(restarted.state.real_calendar_date == {"year": 2026, "month": 1, "day": 3}, "normal calendar follows current Stockholm date after restart")
	_expect(restarted.state.calendar_date == restarted.state.real_calendar_date, "normal calendar is refreshed unless an admin override is active")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH))
	manager.free()
	restarted.free()


func _test_physics_delta_is_unscaled() -> void:
	var manager := _new_manager(_utc(2026, 7, 8, 12, 0, 0))
	manager.set_time_scale(1.0)
	_advance(2.0, manager)
	var real_delta_at_1x: float = manager.get_last_real_delta_seconds()
	manager.set_time_scale(60.0)
	_advance(2.0, manager)
	var real_delta_at_60x: float = manager.get_last_real_delta_seconds()
	_expect(is_equal_approx(real_delta_at_1x, 2.0), "1x update reports the true two-second delta")
	_expect(is_equal_approx(real_delta_at_60x, 2.0), "60x update reports the same true physics delta")
	_expect(is_equal_approx(real_delta_at_1x, real_delta_at_60x), "physics delta does not scale with the day-cycle")
	manager.free()


func _test_legacy_save_migration() -> void:
	var legacy_payload := {
		"schema_version": 1,
		"calendar_date": {"year": 2026, "month": 7, "day": 8},
		"day_cycle_index": 7,
		"cycle_seconds": 45296.0,
		"time_scale": 12.0,
		"paused": true,
		"authoritative_timestamp_utc": _utc(2026, 7, 8, 12, 0, 0),
		# v1 did not define revision_reason or require the recent per-date history.
	}
	var file := FileAccess.open(TEST_SAVE_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(legacy_payload))
	file.close()
	var manager := _new_manager(_utc(2026, 7, 10, 12, 0, 0))
	_expect(manager.load_state(TEST_SAVE_PATH), "v1 save with newer fields absent migrates")
	_expect(manager.state.day_cycle_index == 7 and is_equal_approx(manager.state.cycle_seconds, 45296.0), "legacy save preserves global cycle and phase")
	_expect(is_equal_approx(manager.state.time_scale, 12.0) and manager.state.paused, "legacy save preserves scale and pause")
	_expect(manager.state.revision_reason == "legacy_restore", "legacy save receives an explicit migrated revision reason")
	_expect(manager.state.real_calendar_date == {"year": 2026, "month": 7, "day": 10}, "legacy normal calendar refreshes from current real Stockholm date")
	_expect(manager.state.cycle_starts_by_local_date is Dictionary, "missing cycle history safely migrates to an empty history")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SAVE_PATH))
	manager.free()


func _new_manager(initial_utc: float) -> Node:
	_fake_monotonic_usec = 1000000
	_fake_utc = initial_utc
	var manager: Node = MANAGER_SCRIPT.new()
	manager.autosave_enabled = false
	manager.set_clock_sources(Callable(self, "_get_fake_monotonic_usec"), Callable(self, "_get_fake_utc"))
	manager.initialize_runtime(false)
	return manager


func _advance(real_seconds: float, manager: Node) -> void:
	_fake_monotonic_usec += int(round(real_seconds * 1000000.0))
	_fake_utc += real_seconds
	manager.update_time()


func _get_fake_monotonic_usec() -> int:
	return _fake_monotonic_usec


func _get_fake_utc() -> float:
	return _fake_utc


func _utc(year: int, month: int, day: int, hour: int, minute: int, second: int) -> float:
	return Time.get_unix_time_from_datetime_dict({
		"year": year,
		"month": month,
		"day": day,
		"hour": hour,
		"minute": minute,
		"second": second,
	})


func _expect(condition: bool, description: String) -> void:
	_check_count += 1
	if not condition:
		_failures.append("FAILED: " + description)

