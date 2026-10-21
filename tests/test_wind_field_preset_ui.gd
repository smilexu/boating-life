extends SceneTree

const WIND_FIELD_SCRIPT := preload("res://scripts/wind_field.gd")
const WIND_PANEL_SCRIPT := preload("res://scripts/wind_field_debug_panel.gd")

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node.new()
	host.name = "WindFieldPresetTestHost"
	root.add_child(host)
	var field: WindField = WIND_FIELD_SCRIPT.new() as WindField
	field.name = "WindField"
	field.set_test_simulation_time(0.0)
	host.add_child(field)
	var panel = WIND_PANEL_SCRIPT.new()
	panel.name = "WindFieldDebugPanel"
	panel.set("wind_field_path", NodePath("../WindField"))
	panel.set("sample_source_path", NodePath(""))
	panel.set("start_visible", false)
	host.add_child(panel)
	await process_frame
	for preset_case in [
		{"id": "north", "expected": Vector3(0.0, 0.0, 8.0)},
		{"id": "west", "expected": Vector3(8.0, 0.0, 0.0)},
		{"id": "calm", "expected": Vector3.ZERO},
	]:
		panel.apply_test_preset(str(preset_case["id"]))
		var expected: Vector3 = preset_case["expected"]
		_expect(field.get_wind_at(Vector3.ZERO).distance_to(expected) <= 0.05, "%s button configures its deterministic wind" % preset_case["id"])
		var validation := panel.find_child("PresetValidationResult", true, false) as Label
		_expect(validation != null and validation.text.contains("PASS"), "%s preset shows PASS with vector error" % preset_case["id"])
	panel.apply_test_preset("gust")
	_expect(is_equal_approx(field.mean_wind_speed_mps, 8.0) and is_equal_approx(field.gust_strength_mps, 3.0), "gust button configures 8 m/s mean and 3 m/s gust")
	var result_label := panel.find_child("PresetValidationResult", true, false) as Label
	_expect(result_label != null and result_label.text.contains("阵风预设"), "gust preset replaces the prior direction validation display")
	host.queue_free()
	if _failures.is_empty():
		print("WindField preset UI tests: all checks passed (%d checks)." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("WindField preset UI test failed: %s" % description)
