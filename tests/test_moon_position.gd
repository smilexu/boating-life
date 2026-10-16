extends SceneTree

const MoonPositionScript := preload("res://scripts/moon_position.gd")

var _failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var date := {"year": 2026, "month": 7, "day": 15}
	var midnight: Dictionary = MoonPositionScript.calculate(date, 0.0, 55.7, 12.75)
	var morning: Dictionary = MoonPositionScript.calculate(date, 6.0 * 3600.0, 55.7, 12.75)
	var same_phase_at_night: Dictionary = MoonPositionScript.calculate(date, 22.0 * 3600.0, 55.7, 12.75)
	_check(not midnight.is_empty(), "valid date returns a lunar state")
	_check(float(midnight.get("elevation_degrees", -100.0)) >= -90.0 and float(midnight.get("elevation_degrees", 100.0)) <= 90.0, "lunar elevation remains bounded")
	_check(absf(Vector3(midnight.get("direction", Vector3.ZERO)).length() - 1.0) < 0.0001, "lunar direction is normalized in the Godot ENU frame")
	_check(float(midnight.get("illumination_fraction", -1.0)) >= 0.0 and float(midnight.get("illumination_fraction", 2.0)) <= 1.0, "illumination fraction remains in [0,1]")
	_check(is_equal_approx(float(midnight.get("illumination_fraction", -1.0)), float(same_phase_at_night.get("illumination_fraction", -2.0))), "lunar phase is stable across accelerated cycles on the same calendar date")
	_check(str(midnight.get("phase_name", "")).length() > 0, "phase label is present")
	_check(Vector3(midnight.get("direction", Vector3.ZERO)).angle_to(Vector3(morning.get("direction", Vector3.ZERO))) > deg_to_rad(60.0), "moon position moves continuously with the day-cycle hour angle")
	var before_wrap: Dictionary = MoonPositionScript.calculate(date, 86340.0, 55.7, 12.75)
	var after_wrap: Dictionary = MoonPositionScript.calculate(date, 60.0, 55.7, 12.75)
	_check(Vector3(before_wrap.get("direction", Vector3.ZERO)).angle_to(Vector3(after_wrap.get("direction", Vector3.ZERO))) < deg_to_rad(2.0), "moon direction remains continuous across the day-cycle midnight wrap")
	var next_date := {"year": 2026, "month": 7, "day": 16}
	var next_phase: Dictionary = MoonPositionScript.calculate(next_date, 12.0 * 3600.0, 55.7, 12.75)
	_check(absf(float(midnight.get("illumination_fraction", 0.0)) - float(next_phase.get("illumination_fraction", 0.0))) > 0.0001, "phase progresses with the world-calendar date")
	_check(MoonPositionScript.calculate({"year": 2026, "month": 2, "day": 30}, 0.0, 55.7, 12.75).is_empty(), "invalid Gregorian date is rejected")
	var saw_full_moon := false
	var saw_new_moon := false
	for day_offset in range(36):
		var sample_date := _shift_date(date, day_offset)
		var phase: Dictionary = MoonPositionScript.calculate(sample_date, 12.0 * 3600.0, 55.7, 12.75)
		if float(phase.get("illumination_fraction", 0.0)) > 0.96:
			saw_full_moon = saw_full_moon or str(phase.get("phase_name", "")) == "Full Moon"
		if float(phase.get("illumination_fraction", 1.0)) < 0.025:
			saw_new_moon = saw_new_moon or str(phase.get("phase_name", "")) == "New Moon"
	_check(saw_full_moon, "ephemeris reaches a bright full-moon phase over one synodic-month search window")
	_check(saw_new_moon, "ephemeris reaches a new-moon phase over one synodic-month search window")
	print("Moon-position tests: %d checks passed; %d failed." % [12 - _failures, _failures])
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		_failures += 1
		push_error("FAIL: %s" % description)


func _shift_date(source: Dictionary, offset: int) -> Dictionary:
	var result := source.duplicate(true)
	for _day in range(offset):
		result["day"] = int(result["day"]) + 1
		var year := int(result["year"])
		var month := int(result["month"])
		var month_days := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
		if month == 2 and (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)):
			month_days[1] = 29
		if int(result["day"]) > int(month_days[month - 1]):
			result["day"] = 1
			result["month"] = month + 1
			if int(result["month"]) > 12:
				result["month"] = 1
				result["year"] = year + 1
	return result
