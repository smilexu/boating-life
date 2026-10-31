extends SceneTree

const DISPLAY_SCRIPT := preload("res://scripts/fish_finder_display.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_bottom_sample_continuity()
	_test_layouts()
	await _test_display_lifecycle()
	_test_new_localization()
	print("[FISHING_P4_3C] failures=%d" % _failures)
	quit(1 if _failures > 0 else 0)


func _test_bottom_sample_continuity() -> void:
	var first := _scan(10, 10.0, 1.4, Vector3(100.0, 0.0, 200.0), "starter_cargo_boat", "EMODnet DTM 2024 · LAT")
	var steep_but_continuous := _scan(11, 10.34, 8.7, Vector3(101.0, 0.0, 200.0), "starter_cargo_boat", "EMODnet DTM 2024 · LAT")
	var continuous := DISPLAY_SCRIPT.evaluate_bottom_sample_connection(first, steep_but_continuous)
	_check(bool(continuous.get("connect", false)), "a real depth change at continuous same-vessel samples is preserved, not smoothed or dropped")
	_check(is_equal_approx(float(continuous.get("delta_depth_m", 0.0)), 7.3), "bottom diagnostic reports the raw adjacent depth delta")

	var invalid := steep_but_continuous.duplicate(true)
	invalid["bottom_valid"] = false
	_check(str(DISPLAY_SCRIPT.evaluate_bottom_sample_connection(first, invalid).get("reason", "")) == "invalid_bottom", "invalid bottom samples never connect")
	var gap := steep_but_continuous.duplicate(true)
	gap["scan_runtime_seconds"] = 11.0
	_check(str(DISPLAY_SCRIPT.evaluate_bottom_sample_connection(first, gap).get("reason", "")) == "scan_gap", "long scan intervals leave a visible break")
	var switched_vessel := steep_but_continuous.duplicate(true)
	switched_vessel["active_vessel_id"] = "nordic_28"
	_check(str(DISPLAY_SCRIPT.evaluate_bottom_sample_connection(first, switched_vessel).get("reason", "")) == "vessel_changed", "a vessel switch cannot connect two bathymetry samples")
	var switched_source := steep_but_continuous.duplicate(true)
	switched_source["bathymetry_source"] = "other source"
	_check(str(DISPLAY_SCRIPT.evaluate_bottom_sample_connection(first, switched_source).get("reason", "")) == "bathymetry_source_changed", "a bathymetry source change cannot connect two samples")
	var teleported := steep_but_continuous.duplicate(true)
	teleported["probe_world_position"] = Vector3(150.0, 0.0, 200.0)
	_check(str(DISPLAY_SCRIPT.evaluate_bottom_sample_connection(first, teleported).get("reason", "")) == "probe_discontinuity", "probe teleport leaves a display gap")

	var jump_history: Array[Dictionary] = [first, steep_but_continuous]
	var jump := DISPLAY_SCRIPT.analyze_bottom_history(jump_history)
	_check(bool(jump.get("available", false)) and is_equal_approx(float(jump.get("max_delta_depth_m", 0.0)), 7.3), "history diagnostic finds the largest raw adjacent valid depth change")
	_check(bool(jump.get("connected_for_display", false)) and is_equal_approx(float(jump.get("horizontal_displacement_m", 0.0)), 1.0), "history diagnostic reports time continuity, horizontal movement, and display connectivity")


func _test_layouts() -> void:
	var viewport_sizes: Array[Vector2] = [Vector2(1280.0, 720.0), Vector2(1600.0, 900.0), Vector2(1920.0, 1080.0), Vector2(1024.0, 768.0)]
	for viewport_size in viewport_sizes:
		var right_panel := Rect2(Vector2(viewport_size.x - 414.0, viewport_size.y * 0.2), Vector2(390.0, viewport_size.y * 0.8 - 16.0))
		for mode in ["mini", "expanded"]:
			var layout := DISPLAY_SCRIPT.compute_layout_rect(viewport_size, mode, right_panel)
			_check(layout.position.x >= 16.0 and layout.position.y >= 16.0, "%s layout at %s stays inside the safe viewport" % [mode, viewport_size])
			_check(layout.end.x <= viewport_size.x - 16.0 and layout.end.y <= viewport_size.y - 16.0, "%s layout at %s does not cross the viewport edge" % [mode, viewport_size])
			_check(not layout.intersects(right_panel), "%s layout at %s avoids the right-side F3 panel" % [mode, viewport_size])
		var normal_layout := DISPLAY_SCRIPT.compute_layout_rect(viewport_size, "mini")
		_check(normal_layout.end.x <= viewport_size.x - 16.0 and normal_layout.end.y <= viewport_size.y - 16.0, "normal mini layout at %s remains within viewport bounds" % viewport_size)


func _test_display_lifecycle() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 1
	root.add_child(canvas)
	var display := DISPLAY_SCRIPT.new() as Control
	display.name = "FishFinderP4_3cLifecycleTest"
	display.call("configure", null, null)
	canvas.add_child(display)
	await process_frame
	display.call("set_gain_mode", "manual")
	display.call("set_manual_gain_percent", 73.0)
	display.call("set_range_mode", "manual")
	display.call("set_manual_range_m", 30.0)
	display.call("set_fish_symbols_enabled", true)
	_check(bool(display.call("start_debug_preview", 5.0, 0.8, "medium")), "sonar preview can start independently from authority fish")
	display.call("set_expanded", true)
	var expanded_rect := Rect2(Vector2(610.0, 140.0), Vector2(390.0, 600.0))
	display.call("set_overlay_obstruction_rect", expanded_rect)
	_check(canvas.layer == 1, "expanded fish finder keeps the containing HUD canvas layer unchanged")
	var settings: Dictionary = display.call("get_display_settings")
	_check(settings.get("gain_mode", "") == "manual" and is_equal_approx(float(settings.get("manual_gain_percent", -1.0)), 73.0), "manual gain survives expansion and preview")
	_check(settings.get("range_mode", "") == "manual" and is_equal_approx(float(settings.get("display_range_m", -1.0)), 30.0), "manual range survives expansion and preview")
	_check(bool(settings.get("fish_symbols_enabled", false)), "fish symbol preference survives expansion and preview")
	display.call("close_display")
	display.call("open_display")
	display.call("set_expanded", false)
	settings = display.call("get_display_settings")
	_check(settings.get("gain_mode", "") == "manual" and settings.get("range_mode", "") == "manual" and bool(settings.get("fish_symbols_enabled", false)), "settings persist across hide, reopen, and mini/expanded changes")
	_check(canvas.layer == 1, "hide and reopen do not change other HUD canvas layers")
	_check(bool(display.call("is_debug_preview_active")), "preview remains isolated and active across display visibility changes")
	canvas.queue_free()
	await process_frame


func _test_new_localization() -> void:
	var original_locale := TranslationServer.get_locale()
	TranslationServer.set_locale("en")
	var english_template := tr("fishing.debug.finder_bottom_jump")
	var english := english_template % [7.3, 1.4, 8.7, 7.3, 0.0, 0.34, 1.0, 10, 11, tr("fish.finder.debug.connected"), tr("fishing.debug.bottom_link.continuous")]
	_check(english.begins_with("Bottom history max step:") and not english.contains("%."), "bottom-jump diagnostic has a usable English formatted message")
	TranslationServer.set_locale("zh_CN")
	var chinese := tr("fishing.debug.finder_bottom_source")
	_check(chinese.begins_with("海底来源"), "bottom provenance diagnostic resolves in Simplified Chinese")
	TranslationServer.set_locale(original_locale)


func _scan(scan_id: int, runtime: float, depth_m: float, probe: Vector3, vessel_id: String, source: String) -> Dictionary:
	return {
		"scan_id": scan_id,
		"scan_runtime_seconds": runtime,
		"bottom_valid": true,
		"bottom_depth_below_transducer_m": depth_m,
		"probe_world_position": probe,
		"active_vessel_id": vessel_id,
		"boat_speed_mps": 2.0,
		"bathymetry_source": source,
		"chart_depth_lat_m": depth_m + 1.0,
	}


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error("[FISHING_P4_3C] %s" % message)
