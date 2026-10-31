extends SceneTree

const DISPLAY_SCRIPT := preload("res://scripts/fish_finder_display.gd")

class SonarTestManager extends Node:
	var finder: FishFinderSensor

	func get_fish_finder_sensor() -> FishFinderSensor:
		return finder


var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var weak_echo := {"echo_id": "scan_1_school_a", "school_id": "school_a", "echo_strength": 0.08, "echo_width_m": 0.5}
	var medium_echo := {"echo_id": "scan_2_school_a", "school_id": "school_a", "echo_strength": 0.4, "echo_width_m": 1.0}
	var strong_echo := {"echo_id": "scan_3_school_a", "school_id": "school_a", "echo_strength": 0.8, "echo_width_m": 2.2}
	var weak_display := DISPLAY_SCRIPT.map_echo_strength(float(weak_echo["echo_strength"]), 62.0)
	var medium_display := DISPLAY_SCRIPT.map_echo_strength(float(medium_echo["echo_strength"]), 62.0)
	var strong_display := DISPLAY_SCRIPT.map_echo_strength(float(strong_echo["echo_strength"]), 62.0)
	var weak_visual: Dictionary = DISPLAY_SCRIPT.echo_visual_parameters(weak_echo, 1.0, weak_display, Vector2(300.0, 110.0), 20.0)
	var repeated_weak_visual: Dictionary = DISPLAY_SCRIPT.echo_visual_parameters(weak_echo, 1.0, weak_display, Vector2(300.0, 110.0), 20.0)
	var medium_visual: Dictionary = DISPLAY_SCRIPT.echo_visual_parameters(medium_echo, 1.3, medium_display, Vector2(300.0, 110.0), 20.0)
	var strong_visual: Dictionary = DISPLAY_SCRIPT.echo_visual_parameters(strong_echo, 1.6, strong_display, Vector2(300.0, 110.0), 20.0)
	var weak_signal_color: Color = weak_visual["signal_color"]
	var strong_signal_color: Color = strong_visual["signal_color"]
	_check(float(weak_visual["display_strength"]) > 0.0 and float(weak_visual["outer_alpha"]) > 0.0, "the real 0.08 weak return remains visible through the P4.3a gain mapping")
	_check(DISPLAY_SCRIPT.echo_blob_polygon(Vector2(30.0, 40.0), 5.0, 3.0, float(weak_visual["phase"]), 0.1) == DISPLAY_SCRIPT.echo_blob_polygon(Vector2(30.0, 40.0), 5.0, 3.0, float(repeated_weak_visual["phase"]), 0.1), "recorded echo blob irregularity is deterministic for identical history")
	_check(float(strong_visual["radius_x"]) >= float(weak_visual["radius_x"]) and strong_signal_color.get_luminance() > weak_signal_color.get_luminance(), "strong echoes use a broader and brighter warm-color tier than weak echoes")
	var broad_echo := {"echo_id": "wide", "school_id": "wide_school", "echo_strength": 0.4, "echo_width_m": 2.5}
	var narrow_visual: Dictionary = DISPLAY_SCRIPT.echo_visual_parameters({"echo_id": "narrow", "school_id": "wide_school", "echo_strength": 0.4, "echo_width_m": 0.25}, 2.0, medium_display, Vector2(300.0, 110.0), 20.0)
	var broad_visual: Dictionary = DISPLAY_SCRIPT.echo_visual_parameters(broad_echo, 2.0, medium_display, Vector2(300.0, 110.0), 20.0)
	_check(float(broad_visual["radius_y"]) > float(narrow_visual["radius_y"]), "school echo width changes the aggregate blob size without creating extra targets")

	var scans: Array[Dictionary] = [
		{"scan_runtime_seconds": 1.0, "echoes": [{"echo_id": "a1", "school_id": "school_a", "target_depth_below_transducer_m": 3.0, "echo_strength": 0.08}]},
		{"scan_runtime_seconds": 1.333, "echoes": [{"echo_id": "a2", "school_id": "school_a", "target_depth_below_transducer_m": 3.2, "echo_strength": 0.4}]},
		{"scan_runtime_seconds": 1.666, "echoes": [{"echo_id": "a3", "school_id": "school_a", "target_depth_below_transducer_m": 3.4, "echo_strength": 0.08}]},
		{"scan_runtime_seconds": 2.0, "echoes": []},
		{"scan_runtime_seconds": 2.333, "echoes": [{"echo_id": "a4", "school_id": "school_a", "target_depth_below_transducer_m": 4.0, "echo_strength": 0.8}]},
		{"scan_runtime_seconds": 2.666, "echoes": [{"echo_id": "b1", "school_id": "school_b", "target_depth_below_transducer_m": 6.0, "echo_strength": 0.4}]},
		{"scan_runtime_seconds": 3.0, "echoes": [{"echo_id": "b2", "school_id": "school_b", "target_depth_below_transducer_m": 6.2, "echo_strength": 0.4}]},
	]
	var anchors := DISPLAY_SCRIPT.collect_fish_symbol_anchors(scans, 3.0, 60.0, 20.0, 62.0)
	_check(anchors.size() == 3, "fish symbols collapse continuous scans into one marker per school segment and split at real echo gaps")
	_check(str(anchors[0]["school_id"]) == "school_a" and is_equal_approx(float(anchors[0]["scan_runtime_seconds"]), 1.333) and is_equal_approx(float(anchors[0]["target_depth_below_transducer_m"]), 3.2), "a segment marker uses the strongest real sample's timestamp and depth")
	_check(str(anchors[1]["school_id"]) == "school_a" and str(anchors[2]["school_id"]) == "school_b", "markers remain associated with their original school and never merge different targets")
	var clipped_anchors := DISPLAY_SCRIPT.collect_fish_symbol_anchors(scans, 3.0, 60.0, 5.0, 62.0)
	_check(clipped_anchors.size() == 2, "manual display range excludes only over-range symbol anchors")

	var canvas := CanvasLayer.new()
	canvas.layer = 1
	root.add_child(canvas)
	var manager := SonarTestManager.new()
	canvas.add_child(manager)
	var sensor := FishFinderSensor.new()
	sensor.automatic_scanning_enabled = false
	var real_sample := {"scan_id": 91, "scan_runtime_seconds": float(Time.get_ticks_usec()) / 1000000.0, "bottom_valid": true, "bottom_depth_below_transducer_m": 8.0, "echoes": [weak_echo]}
	sensor._history.append(real_sample)
	manager.finder = sensor
	canvas.add_child(sensor)
	var display := DISPLAY_SCRIPT.new() as Control
	display.call("configure", manager, null)
	canvas.add_child(display)
	await process_frame
	var plot: Control = display.get("_plot")
	_check(not bool(display.call("get_display_settings").get("fish_symbols_enabled", true)) and not bool(plot.get("fish_symbols_enabled")), "Fish Symbols defaults off and the plot uses the default state")
	display.call("set_expanded", true)
	var symbol_toggle := display.find_child("FishSymbolsToggle", true, false) as CheckBox
	_check(symbol_toggle != null and not symbol_toggle.button_pressed, "expanded settings expose an unchecked Fish Symbols toggle")
	if symbol_toggle != null:
		symbol_toggle.set_pressed(true)
	_check(bool(display.call("get_display_settings").get("fish_symbols_enabled", false)) and bool(plot.get("fish_symbols_enabled")), "enabling the option changes only the shared display renderer")
	_check(bool(display.call("get_diagnostic_snapshot").get("fish_symbols_enabled", false)), "F3 display diagnostics expose the current Fish Symbols state")
	var saved_history: Array[Dictionary] = sensor.get_scan_history()
	display.call("start_debug_preview", 5.0, 0.8, "medium")
	_check(bool(plot.get("fish_symbols_enabled")) and bool(display.call("get_display_settings").get("fish_symbols_enabled", false)), "symbols and Gain remain available in isolated sonar preview mode")
	display.call("stop_debug_preview")
	_check(sensor.get_scan_history() == saved_history and bool(display.call("get_display_settings").get("fish_symbols_enabled", false)), "preview stop restores unchanged real history and retains the symbol preference")
	display.call("set_expanded", false)
	display.call("close_display")
	display.call("open_display")
	_check(bool(display.call("get_display_settings").get("fish_symbols_enabled", false)) and bool(plot.get("fish_symbols_enabled")), "mini mode and hide/reopen preserve the current-session symbol setting")

	var original_locale := TranslationServer.get_locale()
	TranslationServer.set_locale("en")
	_check(tr("fish.finder.fish_symbols") == "Fish Symbols", "Fish Symbols setting resolves in English")
	_check(tr("fishing.debug.finder_symbols") == "%s fish symbols", "F3 Fish Symbols status resolves in English")
	TranslationServer.set_locale("zh_CN")
	_check(tr("fish.finder.fish_symbols") == "鱼形标记", "Fish Symbols setting resolves in Simplified Chinese")
	_check(tr("fishing.debug.finder_symbols") == "%s 鱼形标记", "F3 Fish Symbols status resolves in Simplified Chinese")
	TranslationServer.set_locale(original_locale)

	print("[FISHING_P4_3B] failures=%d" % _failures)
	canvas.queue_free()
	await process_frame
	quit(1 if _failures > 0 else 0)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[FISHING_P4_3B][PASS] %s" % message)
	else:
		_failures += 1
		push_error("[FISHING_P4_3B][FAIL] %s" % message)
