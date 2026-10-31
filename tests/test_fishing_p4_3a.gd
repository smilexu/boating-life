extends SceneTree

const DISPLAY_SCRIPT := preload("res://scripts/fish_finder_display.gd")

class GainRangeTestManager extends Node:
	var finder: FishFinderSensor

	func get_fish_finder_sensor() -> FishFinderSensor:
		return finder


var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 1
	root.add_child(canvas)
	var manager := GainRangeTestManager.new()
	canvas.add_child(manager)
	var sensor := FishFinderSensor.new()
	sensor.automatic_scanning_enabled = false
	sensor.minimum_history_seconds = 0.0
	sensor.history_capacity = 12
	manager.finder = sensor
	canvas.add_child(sensor)
	var real_sample := {
		"scan_id": 12,
		"scan_runtime_seconds": float(Time.get_ticks_usec()) / 1000000.0,
		"bottom_valid": true,
		"bottom_depth_below_transducer_m": 17.0,
		"echoes": [{"school_id": "real_p4_3a_school", "target_depth_below_transducer_m": 2.0, "echo_strength": 0.08, "echo_width_m": 1.0}],
	}
	sensor._history.append(real_sample)
	var display := DISPLAY_SCRIPT.new() as Control
	display.name = "P4_3aFishFinderDisplay"
	display.call("configure", manager, null)
	canvas.add_child(display)
	await process_frame

	var settings: Dictionary = display.call("get_display_settings")
	_check(str(settings.get("gain_mode", "")) == "auto" and float(settings.get("manual_gain_percent", -1.0)) == 50.0, "new display session defaults to Auto Gain with 50% manual value")
	_check(str(settings.get("range_mode", "")) == "auto" and float(settings.get("display_range_m", -1.0)) == 20.0, "new display session defaults to Auto Range and keeps the current auto range")
	_check(is_equal_approx(float(settings.get("display_range_m", -1.0)), 20.0), "17 m bottom selects the existing 20 m automatic range preset")

	var gain_zero := DISPLAY_SCRIPT.map_echo_strength(0.08, 0.0)
	var gain_mid := DISPLAY_SCRIPT.map_echo_strength(0.08, 50.0)
	var gain_full := DISPLAY_SCRIPT.map_echo_strength(0.08, 100.0)
	_check(DISPLAY_SCRIPT.map_echo_strength(0.0, 100.0) == 0.0, "zero raw strength never becomes a visible echo at any gain")
	_check(gain_zero < gain_mid and gain_mid < gain_full, "Manual Gain 0/50/100 maps the same echo monotonically")
	_check(DISPLAY_SCRIPT.map_echo_strength(0.08, 62.0) >= 0.20, "Auto Gain default keeps a 0.08 weak return visibly distinguishable")
	_check(DISPLAY_SCRIPT.map_echo_strength(0.05, 0.0) < DISPLAY_SCRIPT.map_echo_strength(0.05, 100.0), "low gain visibly suppresses weak returns without a linear black-screen multiplier")

	var empty_auto_history: Array[Dictionary] = []
	_check(DISPLAY_SCRIPT.estimate_auto_gain_percent(empty_auto_history, 62.0) == 62.0, "empty scans preserve the previous Auto Gain value")
	var weak_history: Array[Dictionary] = [{"scan_runtime_seconds": 100.0, "echoes": [{"echo_strength": 0.08}]}]
	var strong_history: Array[Dictionary] = [{"scan_runtime_seconds": 100.0, "echoes": [{"echo_strength": 0.60}]}]
	var weak_target := DISPLAY_SCRIPT.estimate_auto_gain_percent(weak_history)
	var strong_target := DISPLAY_SCRIPT.estimate_auto_gain_percent(strong_history)
	_check(weak_target > strong_target and weak_target < 75.0, "Auto Gain follows recent strength distribution with a cap, not single-echo full normalization")
	var update_time := float(Time.get_ticks_usec()) / 1000000.0 + 0.25
	display.call("_advance_auto_gain", weak_history, update_time)
	var smoothed_gain := float(display.call("get_display_settings").get("auto_gain_percent", 0.0))
	_check(smoothed_gain > 62.0 and smoothed_gain < weak_target, "Auto Gain moves smoothly using scan-time delta rather than UI frame rate")

	var plot: Control = display.get("_plot")
	var original_history: Array[Dictionary] = sensor.get_scan_history()
	display.call("set_gain_mode", "manual")
	display.call("set_manual_gain_percent", 0.0)
	var mapped_low: float = DISPLAY_SCRIPT.map_echo_strength(0.08, 0.0)
	display.call("set_manual_gain_percent", 100.0)
	var mapped_high: float = DISPLAY_SCRIPT.map_echo_strength(0.08, 100.0)
	_check(mapped_high > mapped_low and sensor.get_scan_history() == original_history, "Gain changes only display mapping and leaves raw sensor history unchanged")
	_check(is_equal_approx(float(plot.get("samples").back().get("echoes", [])[0].get("echo_strength", -1.0)), 0.08), "plot history retains the original raw echo strength")

	display.call("set_range_mode", "manual")
	var manual_settings: Dictionary = display.call("get_display_settings")
	_check(float(manual_settings.get("manual_range_m", -1.0)) == 20.0 and float(manual_settings.get("display_range_m", -1.0)) == 20.0, "Auto-to-Manual Range starts at the currently displayed range")
	display.call("set_manual_range_m", 5.0)
	_check(float(display.call("get_display_settings").get("display_range_m", -1.0)) == 5.0, "manual range switches immediately to the selected 5 m preset")
	for depth_range in [5.0, 10.0, 20.0, 30.0, 50.0]:
		display.call("set_manual_range_m", depth_range)
		_check(float(display.call("get_display_settings").get("display_range_m", -1.0)) == depth_range, "manual range preset %.0f m is selectable" % depth_range)
	display.call("set_manual_range_m", 5.0)
	_check(not DISPLAY_SCRIPT.is_depth_visible(12.0, 5.0) and DISPLAY_SCRIPT.is_depth_visible(5.0, 5.0), "manual range clips over-range echoes while keeping the boundary visible")
	_check(plot.get("samples") == original_history, "manual range changes do not clear or rewrite scan history")
	display.call("_update_auto_range", {"bottom_valid": true, "bottom_depth_below_transducer_m": 40.0, "scan_runtime_seconds": 101.0})
	display.call("_apply_current_history")
	_check(float(display.call("get_display_settings").get("display_range_m", -1.0)) == 5.0, "manual display range stays fixed while automatic range state follows deeper water")
	display.call("set_range_mode", "auto")
	_check(float(display.call("get_display_settings").get("display_range_m", -1.0)) == 50.0, "Manual-to-Auto restores the existing automatic range state")

	display.call("set_gain_mode", "manual")
	display.call("set_manual_gain_percent", 73.0)
	display.call("set_range_mode", "manual")
	display.call("set_manual_range_m", 10.0)
	display.call("set_expanded", true)
	var gain_mode_option := display.find_child("GainModeOption", true, false) as OptionButton
	var gain_slider := display.find_child("ManualGainSlider", true, false) as HSlider
	var range_mode_option := display.find_child("RangeModeOption", true, false) as OptionButton
	var manual_range_option := display.find_child("ManualRangeOption", true, false) as OptionButton
	_check(bool(display.get("_settings_container").visible) and gain_mode_option != null and gain_slider != null and range_mode_option != null and manual_range_option != null, "expanded display exposes the Gain and Range controls")
	_check(gain_slider.editable and not manual_range_option.disabled, "manual mode enables its slider and range selector")
	gain_mode_option.select(0)
	gain_mode_option.emit_signal("item_selected", 0)
	_check(str(display.call("get_display_settings").get("gain_mode", "")) == "auto" and not gain_slider.editable, "Auto Gain dropdown disables the manual slider")
	gain_mode_option.select(1)
	gain_mode_option.emit_signal("item_selected", 1)
	gain_slider.emit_signal("value_changed", 41.0)
	_check(str(display.call("get_display_settings").get("gain_mode", "")) == "manual" and float(display.call("get_display_settings").get("manual_gain_percent", -1.0)) == 41.0, "Manual Gain dropdown and slider update the live display preference")
	range_mode_option.select(0)
	range_mode_option.emit_signal("item_selected", 0)
	_check(manual_range_option.disabled, "Auto Range dropdown disables the manual range selector")
	range_mode_option.select(1)
	range_mode_option.emit_signal("item_selected", 1)
	manual_range_option.select(3)
	manual_range_option.emit_signal("item_selected", 3)
	_check(str(display.call("get_display_settings").get("range_mode", "")) == "manual" and float(display.call("get_display_settings").get("manual_range_m", -1.0)) == 30.0, "Manual Range dropdown selects a fixed 30 m display range")
	display.call("set_gain_mode", "auto")
	display.call("set_range_mode", "auto")
	_check(not gain_slider.editable and manual_range_option.disabled, "Auto modes disable their corresponding manual controls")
	display.call("set_expanded", false)
	_check(not bool(display.get("_settings_container").visible), "mini mode keeps advanced Gain and Range controls out of the compact panel")
	display.call("set_gain_mode", "manual")
	display.call("set_manual_gain_percent", 73.0)
	display.call("set_range_mode", "manual")
	display.call("set_manual_range_m", 10.0)
	display.call("close_display")
	display.call("open_display")
	_check(float(display.call("get_display_settings").get("manual_gain_percent", -1.0)) == 73.0 and float(display.call("get_display_settings").get("manual_range_m", -1.0)) == 10.0, "hide/reopen retains the current-session Gain and Range preferences")
	var settings_before_preview: Dictionary = display.call("get_display_settings")
	display.call("start_debug_preview", 12.0, 0.8, "medium")
	var settings_during_preview: Dictionary = display.call("get_display_settings")
	_check(settings_during_preview.get("gain_mode") == settings_before_preview.get("gain_mode") and settings_during_preview.get("range_mode") == settings_before_preview.get("range_mode") and settings_during_preview.get("display_range_m") == settings_before_preview.get("display_range_m"), "debug preview preserves display modes and manual range")
	display.call("stop_debug_preview")
	_check(sensor.get_scan_history() == original_history and display.call("get_display_settings").get("manual_gain_percent") == 73.0, "preview stop restores real history and retains display preferences")

	var original_locale := TranslationServer.get_locale()
	TranslationServer.set_locale("en")
	_check(tr("fish.finder.gain") == "GAIN" and tr("fish.finder.mode.auto") == "Auto" and tr("fish.finder.mode.manual") == "Manual", "Gain and Range controls resolve in English")
	TranslationServer.set_locale("zh_CN")
	_check(tr("fish.finder.gain") == "增益" and tr("fish.finder.mode.auto") == "自动" and tr("fish.finder.mode.manual") == "手动", "Gain and Range controls resolve in Simplified Chinese")
	TranslationServer.set_locale(original_locale)

	print("[FISHING_P4_3A] failures=%d" % _failures)
	canvas.queue_free()
	await process_frame
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[FISHING_P4_3A][PASS] %s" % message)
	else:
		_failures += 1
		push_error("[FISHING_P4_3A][FAIL] %s" % message)
