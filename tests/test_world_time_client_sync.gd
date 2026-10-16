extends SceneTree

const MANAGER_SCRIPT := preload("res://scripts/world_time_manager.gd")
const CLIENT_VIEW_SCRIPT := preload("res://scripts/world_time_client_view.gd")
const SOLAR_SCRIPT := preload("res://scripts/solar_position.gd")

var _fake_monotonic_usec := 1000000
var _fake_utc := 0.0
var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	_run_all()
	if _failures.is_empty():
		print("World time client sync: %d checks passed with two isolated client views." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _run_all() -> void:
	_fake_utc = _utc(2026, 7, 15, 9, 0, 0)
	var manager: Node = _new_manager()
	manager.set_cycle_time(12, 0, 0.0)
	var snapshot_0: Dictionary = manager.create_snapshot()
	var client_a: RefCounted = CLIENT_VIEW_SCRIPT.new()
	var client_b: RefCounted = CLIENT_VIEW_SCRIPT.new()
	_expect(client_a.apply_authority_snapshot(snapshot_0, 0.2), "client A accepts initial authority snapshot")
	client_a.advance(0.6)
	_expect(client_b.apply_authority_snapshot(snapshot_0, 0.8), "client B accepts the same snapshot after a different delay")
	_expect(_views_match(client_a, client_b), "different packet delivery delays converge to the same cycle phase")
	_expect(int(client_a.get_snapshot().day_cycle_index) == 0, "initial global cycle index is shared")
	var sun_a: Dictionary = client_a.get_solar_state(55.6049, 12.9944)
	var sun_b: Dictionary = client_b.get_solar_state(55.6049, 12.9944)
	_expect((Vector3(sun_a.direction) - Vector3(sun_b.direction)).length() < 0.000001, "both client views produce the same solar direction")
	var external_copy: Dictionary = client_a.get_snapshot()
	(external_copy["calendar_date"] as Dictionary)["year"] = 1999
	_expect(int(client_b.get_snapshot().calendar_date.year) == 2026, "client snapshots do not share mutable date dictionaries")

	# Small drift is eased; it does not become a visible clock jump.
	_advance_authority(1.0, manager)
	var snapshot_1: Dictionary = manager.create_snapshot()
	client_a.advance(0.2)
	client_b.advance(0.2)
	client_a.advance(0.05) # Simulated local clock/prediction drift.
	_expect(client_a.apply_authority_snapshot(snapshot_1), "client accepts a newer same-revision synchronization sample")
	_expect(client_b.apply_authority_snapshot(snapshot_1), "second client accepts the same synchronization sample")
	_expect(not client_a.apply_authority_snapshot(snapshot_0), "same-revision packet with an older sequence is rejected")
	var diagnostics: Dictionary = client_a.get_sync_diagnostics()
	_expect(absf(float(diagnostics.phase_correction_remaining_seconds)) > 0.001 and absf(float(diagnostics.phase_correction_remaining_seconds)) < 2.0, "small synchronization error is scheduled for a smooth correction")
	for _step in range(3):
		client_a.advance(0.25)
		client_b.advance(0.25)
		_advance_authority(0.25, manager)
	_expect(absf(float(client_a.get_sync_diagnostics().phase_correction_remaining_seconds)) < 0.001, "small synchronization correction completes over its short blend")
	_expect(_views_match(client_a, client_b), "clients remain aligned after drift correction")

	# Pause is a newer authority revision and reaches both clients as an immediate state change.
	manager.pause_time()
	var pause_snapshot: Dictionary = manager.create_snapshot()
	client_a.advance(0.1)
	client_b.advance(0.7)
	_expect(client_a.apply_authority_snapshot(pause_snapshot, 0.1), "client A applies authority pause")
	client_a.advance(0.6)
	_advance_authority(0.7, manager)
	_expect(client_b.apply_authority_snapshot(pause_snapshot, 0.7), "client B applies authority pause at a later delivery time")
	_expect(bool(client_a.get_snapshot().paused) and bool(client_b.get_snapshot().paused), "pause state is identical on both clients")
	_expect(_views_match(client_a, client_b), "paused clients account for different delivery delays")
	client_a.advance(5.0)
	client_b.advance(5.0)
	_expect(is_equal_approx(float(client_a.get_snapshot().cycle_seconds), float(client_b.get_snapshot().cycle_seconds)), "paused clients do not advance the day-cycle")
	_expect(is_equal_approx(float(client_a.get_snapshot().estimated_utc_timestamp), float(client_b.get_snapshot().estimated_utc_timestamp)), "real calendar estimate still advances during a day-cycle pause")

	_advance_authority(5.0, manager)
	client_a.advance(5.0)
	client_b.advance(5.0)
	manager.resume_time()
	var resume_snapshot: Dictionary = manager.create_snapshot()
	_expect(client_a.apply_authority_snapshot(resume_snapshot, 0.15), "client A applies authority resume")
	client_a.advance(0.75)
	_advance_authority(0.9, manager)
	_expect(client_b.apply_authority_snapshot(resume_snapshot, 0.9), "client B applies authority resume after a longer delay")
	_expect(not bool(client_a.get_snapshot().paused) and not bool(client_b.get_snapshot().paused), "resume state is identical on both clients")
	_expect(_views_match(client_a, client_b), "resumed clients predict the same accelerated cycle")

	# Advance to 12x and then manually jump. The jump must snap immediately.
	manager.set_time_scale(12.0)
	var scale_snapshot: Dictionary = manager.create_snapshot()
	client_a.advance(0.1)
	client_a.apply_authority_snapshot(scale_snapshot, 0.1)
	client_a.advance(0.55)
	_advance_authority(0.65, manager)
	client_b.apply_authority_snapshot(scale_snapshot, 0.65)
	_expect(is_equal_approx(float(client_a.get_snapshot().time_scale), 12.0) and is_equal_approx(float(client_b.get_snapshot().time_scale), 12.0), "authority multiplier change is applied to both clients")
	var old_snapshot := scale_snapshot.duplicate(true)
	manager.set_day_cycle_time(17, 40, 0.0)
	var jump_snapshot: Dictionary = manager.create_snapshot()
	_expect(client_a.apply_authority_snapshot(jump_snapshot), "client A accepts administrator time jump")
	_expect(client_b.apply_authority_snapshot(jump_snapshot), "client B accepts administrator time jump")
	_expect(_views_match(client_a, client_b), "administrator jump immediately aligns both cycle phases")
	_expect(absf(float(client_a.get_sync_diagnostics().phase_correction_remaining_seconds)) < 0.001, "administrator jump is not slowly interpolated")
	var before_stale: Dictionary = client_a.get_snapshot()
	_expect(not client_a.apply_authority_snapshot(old_snapshot), "older revision arriving late is rejected")
	_expect(float(client_a.get_snapshot().cycle_seconds) == float(before_stale.cycle_seconds), "rejected old revision cannot roll back the displayed time")
	_expect(str(client_a.get_sync_diagnostics().last_snapshot_rejection) == "older_revision", "stale rejection reports its reason")

	# A missed admin jump followed by a natural wrap must still snap: the latest
	# revision reason alone is natural_cycle, but control_revision records the edit.
	manager.set_day_cycle_time(23, 59, 0.0)
	_advance_authority(10.0, manager)
	client_a.advance(10.0)
	client_b.advance(10.0)
	var post_jump_wrap: Dictionary = manager.create_snapshot()
	_expect(str(post_jump_wrap.revision_reason) == "natural_cycle", "test snapshot's newest revision is a natural wrap")
	_expect(client_a.apply_authority_snapshot(post_jump_wrap), "client A applies the missed jump despite a later natural wrap")
	_expect(client_b.apply_authority_snapshot(post_jump_wrap), "client B applies the missed jump despite a later natural wrap")
	_expect(absf(float(client_a.get_sync_diagnostics().phase_correction_remaining_seconds)) < 0.001, "control revision forces an immediate phase correction after the wrap")
	_expect(_views_match(client_a, client_b), "global cycle wrap after an unseen admin jump converges")

	manager.set_calendar_date(2031, 11, 6)
	var override_snapshot: Dictionary = manager.create_snapshot()
	client_a.apply_authority_snapshot(override_snapshot, 0.1)
	client_a.advance(0.5)
	_advance_authority(0.6, manager)
	client_b.apply_authority_snapshot(override_snapshot, 0.6)
	_expect(client_a.get_snapshot().calendar_date == {"year": 2031, "month": 11, "day": 6}, "administrator calendar override is applied immediately")
	_expect(client_a.get_snapshot().real_calendar_date == client_b.get_snapshot().real_calendar_date, "debug world date remains separate from real weather date")
	var overridden_sun_a: Dictionary = client_a.get_solar_state(55.6049, 12.9944)
	var overridden_sun_b: Dictionary = client_b.get_solar_state(55.6049, 12.9944)
	_expect((Vector3(overridden_sun_a.direction) - Vector3(overridden_sun_b.direction)).length() < 0.000001, "both clients calculate the same sun after a date override")
	_expect(not client_a.has_method("set_time_scale") and not client_a.has_method("pause_time"), "client view exposes no authority mutation methods")

	# Simulate extended play with different update cadences, then resynchronize.
	_advance_authority(300.0, manager)
	for _step in range(120):
		client_a.advance(2.5)
	for _step in range(600):
		client_b.advance(0.5)
	var long_run_snapshot: Dictionary = manager.create_snapshot()
	_expect(client_a.apply_authority_snapshot(long_run_snapshot), "client A accepts a long-run synchronization sample")
	_expect(client_b.apply_authority_snapshot(long_run_snapshot), "client B accepts a long-run synchronization sample")
	for _step in range(3):
		client_a.advance(0.25)
		client_b.advance(0.25)
		_advance_authority(0.25, manager)
	_expect(_views_match(client_a, client_b), "different client update cadences converge after five minutes of simulated transport time")

	# A newer sample sequence survives a backwards wall-clock adjustment while
	# the monotonic day-cycle continues forward.
	_fake_monotonic_usec += 1000000
	_fake_utc -= 3.0
	manager.update_time()
	client_a.advance(1.0)
	client_b.advance(1.0)
	var clock_adjusted_snapshot: Dictionary = manager.create_snapshot(false)
	_expect(client_a.apply_authority_snapshot(clock_adjusted_snapshot), "new sample sequence is accepted after server UTC is corrected backwards")
	_expect(client_b.apply_authority_snapshot(clock_adjusted_snapshot), "second client accepts the same post-correction sample")
	_expect(_views_match(client_a, client_b), "monotonic day-cycle remains aligned after a wall-clock correction")

	manager.free()


func _new_manager() -> Node:
	var manager: Node = MANAGER_SCRIPT.new()
	manager.autosave_enabled = false
	manager.set_clock_sources(Callable(self, "_get_fake_monotonic_usec"), Callable(self, "_get_fake_utc"))
	manager.initialize_runtime(false)
	return manager


func _advance_authority(seconds: float, manager: Node) -> void:
	_fake_monotonic_usec += int(round(seconds * 1000000.0))
	_fake_utc += seconds
	manager.update_time()


func _get_fake_monotonic_usec() -> int:
	return _fake_monotonic_usec


func _get_fake_utc() -> float:
	return _fake_utc


func _views_match(first: RefCounted, second: RefCounted) -> bool:
	var a: Dictionary = first.get_snapshot()
	var b: Dictionary = second.get_snapshot()
	return (
		int(a.day_cycle_index) == int(b.day_cycle_index)
		and absf(float(a.cycle_seconds) - float(b.cycle_seconds)) < 0.001
		and a.calendar_date == b.calendar_date
		and a.real_calendar_date == b.real_calendar_date
		and bool(a.paused) == bool(b.paused)
		and is_equal_approx(float(a.time_scale), float(b.time_scale))
	)


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
	_checks += 1
	if not condition:
		_failures.append("FAILED: " + description)
