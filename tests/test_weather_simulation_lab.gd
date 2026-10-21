extends SceneTree

const LAB_SCENE := preload("res://scenes/WeatherSimulationLab.tscn")

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for dimensions in [Vector2i(1280, 720), Vector2i(1632, 957), Vector2i(1920, 1080)]:
		await _test_resolution(dimensions)
	if _failures.is_empty():
		print("WeatherSimulationLab layout tests: %d checks passed at 1280x720, 1632x957 and 1920x1080." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_resolution(dimensions: Vector2i) -> void:
	root.size = dimensions
	var lab: Control = LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	await process_frame
	var page: ScrollContainer = lab.get_node("PageScroll")
	_expect(page.size.x >= float(dimensions.x) - 2.0, "%s: page scroll fills window width" % str(dimensions))
	_expect(page.size.y >= float(dimensions.y) - 2.0, "%s: page scroll fills window height" % str(dimensions))
	var source_status := lab.find_child("SourceStatus", true, false) as Label
	_expect(source_status != null, "%s: source-status control exists" % str(dimensions))
	if source_status == null:
		lab.queue_free()
		await process_frame
		return
	_expect(source_status.text.contains("TEST FIXTURE") and source_status.text.contains("N/A"), "%s: bundled synthetic data is never labelled fresh/live" % str(dimensions))
	_expect(str(lab.call("_format_stat_value", "mean_wind_speed_mps", 3.5)) == "3.50 m/s", "%s: wind summary values show the m/s unit" % str(dimensions))
	_expect(str(lab.call("_format_stat_value", "temperature_min_c", 8.0)) == "8.00°C", "%s: temperature summary values show the Celsius unit" % str(dimensions))
	var report: Dictionary = lab.get("_quality_report")
	_expect(report.get("data_source_classification", {}).get("source_kind") == "TEST FIXTURE", "%s: exported report preserves the source kind" % str(dimensions))
	_expect(report.get("data_source_classification", {}).get("cache_freshness") == "N/A · 合成数据", "%s: fixture freshness is N/A in report metadata" % str(dimensions))
	_expect(report.get("comparison", {}).has("explicit_precipitation_day_fraction") and report.get("comparison", {}).has("possible_precipitation_day_fraction"), "%s: exported quality report compares full-day evidenced precipitation shares" % str(dimensions))
	var comparison_grid := lab.find_child("ComparisonGrid", true, false) as GridContainer
	var has_full_day_precipitation_label := false
	if comparison_grid != null:
		for child in comparison_grid.get_children():
			if child is Label and str(child.text).contains("明确降水占全天"):
				has_full_day_precipitation_label = true
				break
	_expect(has_full_day_precipitation_label, "%s: UI distinguishes evidenced full-day precipitation share" % str(dimensions))
	var chart_names := ["Chart_wind", "Chart_cloud_precip", "Chart_direction"]
	for chart_name in chart_names:
		var chart := lab.find_child(chart_name, true, false) as Control
		_expect(chart != null, "%s: %s is present" % [str(dimensions), chart_name])
		if chart == null:
			continue
		_expect(chart.size.x >= float(dimensions.x) - 96.0, "%s: %s expands with the window instead of remaining a narrow panel" % [str(dimensions), chart_name])
		_expect(chart.size.y >= 250.0, "%s: %s keeps a legible plot height" % [str(dimensions), chart_name])
	var cycles := lab.find_child("TimelineCycles", true, false) as HBoxContainer
	_expect(cycles != null, "%s: selectable timeline container exists" % str(dimensions))
	if cycles == null:
		lab.queue_free()
		await process_frame
		return
	_expect(cycles.get_child_count() == 24, "%s: 24 game cycles render as individual selectable timeline items" % str(dimensions))
	lab.call("_select_cycle", 5)
	_expect(is_equal_approx(float(lab.get("_chart_range_start")), 5.0) and is_equal_approx(float(lab.get("_chart_range_end")), 6.0), "%s: selecting a timeline cycle zooms chart range" % str(dimensions))
	var detail := lab.find_child("SampleDetail", true, false) as Label
	_expect(detail.text.contains("日轮 6 / 24") and detail.text.contains("原始预报") and detail.text.contains("生成天气"), "%s: timeline selection updates shared source/generated detail" % str(dimensions))
	lab.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("[Lab #%d] %s" % [_checks, message])
