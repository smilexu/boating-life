extends RefCounted
## Small, pure format helpers for the player-facing navigation HUD.

const NAVIGATION_MATH := preload("res://scripts/sailboat_navigation_math.gd")

const CARDINALS := ["北", "东", "南", "西"]
const INTERCARDINALS := ["东北", "东南", "西南", "西北"]


static func compass_direction_phrase(bearing_degrees: float) -> String:
	var bearing := fposmod(bearing_degrees, 360.0)
	var nearest_cardinal_index := int(roundi(bearing / 90.0)) % 4
	var nearest_cardinal_bearing := float(nearest_cardinal_index) * 90.0
	var offset := wrapf(bearing - nearest_cardinal_bearing, -180.0, 180.0)
	if absf(offset) <= 22.5:
		if absf(offset) < 2.5:
			return CARDINALS[nearest_cardinal_index]
		var neighbor_index := posmod(nearest_cardinal_index + (1 if offset > 0.0 else -1), 4)
		return "%s偏%s" % [CARDINALS[nearest_cardinal_index], CARDINALS[neighbor_index]]
	var diagonal_index := int(roundi((bearing - 45.0) / 90.0)) % 4
	return INTERCARDINALS[diagonal_index]


static func relative_wind_location_phrase(relative_from_degrees: float) -> String:
	var angle := wrapf(relative_from_degrees, -180.0, 180.0)
	var magnitude := absf(angle)
	if magnitude < 18.0:
		return "正前方"
	if magnitude < 68.0:
		return "左前方" if angle < 0.0 else "右前方"
	if magnitude < 112.0:
		return "左舷侧" if angle < 0.0 else "右舷侧"
	if magnitude < 162.0:
		return "左后方" if angle < 0.0 else "右后方"
	return "正后方"


static func action_key_hint(action_name: String) -> String:
	if not InputMap.has_action(action_name):
		return "未绑定"
	var keys := PackedStringArray()
	for event in InputMap.action_get_events(action_name):
		if event is InputEventKey:
			var key_event := event as InputEventKey
			var keycode := key_event.physical_keycode if key_event.physical_keycode != KEY_NONE else key_event.keycode
			if keycode == KEY_NONE:
				continue
			var label := OS.get_keycode_string(keycode)
			if key_event.ctrl_pressed:
				label = "Ctrl+" + label
			if key_event.alt_pressed:
				label = "Alt+" + label
			if key_event.shift_pressed:
				label = "Shift+" + label
			keys.append(label)
	return " / ".join(keys) if not keys.is_empty() else "未绑定"
