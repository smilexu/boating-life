extends SceneTree

const FORMAT := preload("res://scripts/navigation_hud_format.gd")
const HUD_LAYOUT := preload("res://scripts/boat_hud.gd")
const COMPASS_LAYOUT := preload("res://scripts/compass_hud.gd")
const QUALITY_MANAGER := preload("res://scripts/quality_manager.gd")

var _checks := 0
var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect(FORMAT.compass_direction_phrase(0.0) == "北", "north bearing has a clear Chinese direction label")
	_expect(FORMAT.compass_direction_phrase(90.0) == "东", "east bearing has a clear Chinese direction label")
	_expect(FORMAT.compass_direction_phrase(280.0) == "西偏北", "280° is described as wind from west leaning north")
	_expect(FORMAT.compass_direction_phrase(45.0) == "东北", "intercardinal bearings are described directly")
	_expect(FORMAT.compass_direction_phrase(359.0) == "北", "direction text wraps cleanly around 000°: %s" % FORMAT.compass_direction_phrase(359.0))
	_expect(FORMAT.relative_wind_location_phrase(-45.0) == "左前方", "negative relative angle maps to port-front per project truth table")
	_expect(FORMAT.relative_wind_location_phrase(45.0) == "右前方", "positive relative angle maps to starboard-front per project truth table")
	_expect(FORMAT.relative_wind_location_phrase(-90.0) == "左舷侧", "left beam wind is named without confusing side and bearing")
	_expect(FORMAT.relative_wind_location_phrase(180.0) == "正后方", "astern relative wind is handled")
	_expect(FORMAT.action_key_hint("boat_turn_left") == "A", "rudder hint reads the active InputMap binding")
	_expect(FORMAT.action_key_hint("boat_turn_right") == "D", "right-rudder hint reads the active InputMap binding")
	_expect(FORMAT.action_key_hint("sailboat_main_trim_ease") == "Z", "mainsail hint reads the active InputMap binding")
	_expect(FORMAT.action_key_hint("sailboat_main_trim_out") == "X", "mainsail hint reads the active InputMap binding")
	_expect(FORMAT.action_key_hint("sailboat_headsail_trim_ease") == "J", "headsail hint reads the active InputMap binding")
	_expect(FORMAT.action_key_hint("sailboat_headsail_trim_out") == "L", "headsail hint reads the active InputMap binding")
	_expect(FORMAT.action_key_hint("sailboat_toggle_auto_trim") == "T", "automatic-trim hint reads the active InputMap binding")
	_expect(QUALITY_MANAGER.UI_SCALE_FACTORS.size() == 5, "five UI scale levels are available")
	_expect(QUALITY_MANAGER.UI_SCALE_FACTORS[2] == 1.25, "the default large UI scale is 125 percent")

	for resolution in [Vector2(1280.0, 720.0), Vector2(1600.0, 900.0), Vector2(1920.0, 1080.0), Vector2(2560.0, 1440.0)]:
		for scale_value in QUALITY_MANAGER.UI_SCALE_FACTORS:
			var layout: Dictionary = HUD_LAYOUT.sailing_panel_layout_metrics(resolution, float(scale_value), true)
			var panel_left := float(layout["screen_left"])
			var panel_top := float(layout["screen_top"])
			var panel_right := panel_left + float(layout["screen_width"])
			var panel_bottom := panel_top + float(layout["screen_height"])
			var map_right := 380.0 * float(scale_value)
			_expect(panel_left >= map_right - 0.1, "%dx%d at UI %.0f%% keeps the lower-right panel clear of the left chart" % [int(resolution.x), int(resolution.y), float(scale_value) * 100.0])
			_expect(panel_top >= 0.0 and panel_bottom <= resolution.y + 0.1, "%dx%d at UI %.0f%% keeps the panel vertically on-screen" % [int(resolution.x), int(resolution.y), float(scale_value) * 100.0])
			_expect(panel_left >= 0.0 and panel_right <= resolution.x + 0.1, "%dx%d at UI %.0f%% keeps the panel horizontally on-screen" % [int(resolution.x), int(resolution.y), float(scale_value) * 100.0])
			var compass: Rect2 = COMPASS_LAYOUT.compute_layout_rect(resolution, float(scale_value))
			var top_left_end: float = 18.0 * float(scale_value) + minf(300.0 * float(scale_value), resolution.x * 0.30)
			var top_right_start: float = resolution.x - 18.0 * float(scale_value) - minf(220.0 * float(scale_value), resolution.x * 0.24)
			_expect(compass.position.x >= top_left_end - 0.1 and compass.end.x <= top_right_start + 0.1, "%dx%d at UI %.0f%% keeps the compass clear of both top-corner panels" % [int(resolution.x), int(resolution.y), float(scale_value) * 100.0])
			_expect(compass.position.y >= 0.0 and compass.end.x <= resolution.x + 0.1 and compass.end.y <= resolution.y + 0.1, "%dx%d at UI %.0f%% keeps the compass within the viewport" % [int(resolution.x), int(resolution.y), float(scale_value) * 100.0])

	if _failures.is_empty():
		print("Navigation HUD formatting/layout tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL: " + description)
