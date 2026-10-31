extends SceneTree

const DISPLAY_SCRIPT := preload("res://scripts/fish_finder_display.gd")

class PreviewTestManager extends Node:
	var finder: FishFinderSensor

	func get_fish_finder_sensor() -> FishFinderSensor:
		return finder

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(is_equal_approx(FishFinderDisplay.depth_to_y(0.0, 20.0, 10.0, 100.0), 10.0), "zero depth maps to the sonar plot top")
	_check(is_equal_approx(FishFinderDisplay.depth_to_y(10.0, 20.0, 10.0, 100.0), 60.0), "half range maps to the same vertical midpoint for seabed and echoes")
	_check(is_equal_approx(FishFinderDisplay.depth_to_y(20.0, 20.0, 10.0, 100.0), 110.0), "display range bottom maps to the sonar plot bottom")
	_check(is_equal_approx(FishFinderDisplay.scan_time_to_x(100.0, 100.0, 60.0, 20.0, 500.0), 520.0), "latest scan maps to the right edge")
	_check(is_equal_approx(FishFinderDisplay.scan_time_to_x(40.0, 100.0, 60.0, 20.0, 500.0), 20.0), "sixty-second-old scan maps to the left edge")
	_check(is_equal_approx(FishFinderDisplay.range_for_bottom_depth(3.0), 5.0), "auto range includes a small seabed safety margin")
	_check(is_equal_approx(FishFinderDisplay.range_for_bottom_depth(12.0), 20.0), "auto range selects a preset that contains the bottom")
	_check(is_equal_approx(FishFinderDisplay.range_for_bottom_depth(44.0), 50.0), "50 m is a display range preset above the sensor depth limit")
	_check(is_equal_approx(FishFinderDisplay.range_for_bottom_depth(-1.0), -1.0), "invalid bottom depth does not select or imply a range")

	var fixture := CanvasLayer.new()
	fixture.layer = 1
	fixture.name = "FishFinderP4_2TestFixture"
	root.add_child(fixture)
	var display := DISPLAY_SCRIPT.new() as Control
	display.name = "TestFishFinderDisplay"
	display.call("configure", null, null)
	fixture.add_child(display)
	await process_frame
	_check(str(display.call("get_display_mode")) == "mini", "display starts in mini mode")
	display.call("set_expanded", true)
	_check(str(display.call("get_display_mode")) == "expanded" and fixture.layer == 1, "expand changes view without raising the containing HUD canvas layer")
	display.call("set_expanded", false)
	_check(str(display.call("get_display_mode")) == "mini" and fixture.layer == 1, "collapse returns to mini mode without changing canvas-layer priority")
	display.call("set_expanded", true)
	display.call("close_display")
	_check(str(display.call("get_display_mode")) == "hidden" and fixture.layer == 1, "close hides the display without changing canvas-layer priority")
	display.call("open_display")
	_check(str(display.call("get_display_mode")) == "expanded" and fixture.layer == 1, "display can reopen at its prior mode without altering other HUD layers")
	var diagnostic: Dictionary = display.call("get_diagnostic_snapshot")
	_check(str(diagnostic.get("mode", "")) == "expanded" and float(diagnostic.get("display_range_m", 0.0)) > 0.0, "F3 diagnostic reports the active display mode and current range")

	var preview_manager := PreviewTestManager.new()
	fixture.add_child(preview_manager)
	var preview_sensor := FishFinderSensor.new()
	preview_sensor.automatic_scanning_enabled = false
	preview_manager.finder = preview_sensor
	fixture.add_child(preview_sensor)
	var real_sample := {
		"scan_id": 77,
		"scan_runtime_seconds": float(Time.get_ticks_usec()) / 1000000.0,
		"bottom_valid": true,
		"bottom_depth_below_transducer_m": 17.0,
		"echoes": [{"school_id": "real_school", "target_depth_below_transducer_m": 3.0, "echo_strength": 0.6, "echo_width_m": 1.0}],
		"reason": "ok",
	}
	preview_sensor._history.append(real_sample)
	display.call("configure", preview_manager, null)
	var saved_real_history: Array[Dictionary] = preview_sensor.get_scan_history()
	_check(bool(display.call("start_debug_preview", 5.0, 0.8, "medium")), "debug sonar preview starts without requiring Authority schools")
	var preview_snapshot: Dictionary = display.call("get_diagnostic_snapshot")
	var plot: Control = display.get("_plot")
	var preview_samples: Array = plot.get("samples") if plot != null else []
	var preview_latest: Dictionary = preview_samples.back() if not preview_samples.is_empty() else {}
	var preview_echoes: Array = preview_latest.get("echoes", [])
	var preview_echo: Dictionary = preview_echoes[0] if not preview_echoes.is_empty() else {}
	_check(bool(preview_snapshot.get("preview_active", false)) and str(preview_snapshot.get("source", "")) == "debug_preview" and int(preview_snapshot.get("preview_history_count", 0)) >= 180, "preview uses a bounded independent 60-second scan history")
	_check(preview_echoes.size() == 1 and bool(preview_latest.get("debug_preview", false)) and str(preview_echo.get("school_id", "")) == "debug_preview_school" and is_equal_approx(float(preview_echo.get("target_depth_below_transducer_m", -1.0)), 5.0), "preview history contains one clearly tagged aggregate debug return at its selected depth")
	_check(not bool(preview_latest.get("bottom_valid", true)) and preview_snapshot.get("real_echo_count", -1) == 1 and preview_sensor.get_scan_history() == saved_real_history, "preview fabricates neither seabed nor real scan records and leaves sensor history unchanged")
	display.call("set_debug_preview_parameters", 12.0, 0.4, "large")
	var updated_preview: Dictionary = display.call("_make_debug_preview_column", float(Time.get_ticks_usec()) / 1000000.0, 5.0)
	var updated_echo: Dictionary = updated_preview.get("echoes", [])[0]
	var updated_plot_samples: Array = plot.get("samples")
	var updated_plot_echo: Dictionary = updated_plot_samples.back().get("echoes", [])[0] if not updated_plot_samples.is_empty() else {}
	_check(float(updated_echo.get("target_depth_below_transducer_m", -1.0)) == 12.0 and int(updated_echo.get("group_population", 0)) == 64 and float(updated_echo.get("echo_strength", 0.0)) <= 0.4 and float(updated_plot_echo.get("target_depth_below_transducer_m", -1.0)) == 12.0, "preview depth, intensity and size band immediately rebuild the visible independent history")
	display.call("set_expanded", false)
	_check(str(display.call("get_display_mode")) == "mini" and bool(display.call("is_debug_preview_active")), "mini and expanded modes share the same debug preview")
	_check(bool(display.call("stop_debug_preview")) and not bool(display.call("is_debug_preview_active")), "stopping preview restores the real history source")
	_check(preview_sensor.get_scan_history() == saved_real_history and plot.get("samples") == saved_real_history, "stop restores the original real scan history unchanged")
	display.call("start_debug_preview", 5.0, 0.8, "medium")
	_check(bool(display.call("stop_debug_preview")) and preview_sensor.get_scan_history() == saved_real_history, "repeated preview start/stop does not accumulate sensor history")

	var original_locale := TranslationServer.get_locale()
	TranslationServer.set_locale("en")
	_check(tr("fish.finder.title") == "Fish Finder" and tr("fish.finder.status.no_bottom") == "Bottom data unavailable" and tr("fish.finder.debug_preview") == "SONAR PREVIEW", "Fish Finder UI and preview marker resolve in English")
	TranslationServer.set_locale("zh_CN")
	_check(tr("fish.finder.title") == "鱼探仪" and tr("fish.finder.status.no_bottom") == "海底数据不可用" and tr("fish.finder.debug_preview") == "声呐预览", "Fish Finder UI and preview marker resolve in Simplified Chinese")
	TranslationServer.set_locale(original_locale)

	print("[FISHING_P4_2] failures=%d" % _failures)
	fixture.queue_free()
	await process_frame
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[FISHING_P4_2][PASS] %s" % message)
	else:
		_failures += 1
		push_error("[FISHING_P4_2][FAIL] %s" % message)
