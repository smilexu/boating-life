extends RefCounted
## Small, pure format helpers for the player-facing navigation HUD.

const NAVIGATION_MATH := preload("res://scripts/sailboat_navigation_math.gd")

const CARDINAL_KEYS := ["hud.direction.north", "hud.direction.east", "hud.direction.south", "hud.direction.west"]
const INTERCARDINAL_KEYS := ["hud.direction.northeast", "hud.direction.southeast", "hud.direction.southwest", "hud.direction.northwest"]


static func compass_direction_phrase(bearing_degrees: float) -> String:
	var bearing := fposmod(bearing_degrees, 360.0)
	var nearest_cardinal_index := int(roundi(bearing / 90.0)) % 4
	var nearest_cardinal_bearing := float(nearest_cardinal_index) * 90.0
	var offset := wrapf(bearing - nearest_cardinal_bearing, -180.0, 180.0)
	var cardinal := TranslationServer.translate(CARDINAL_KEYS[nearest_cardinal_index])
	if absf(offset) <= 22.5:
		if absf(offset) < 2.5:
			return cardinal
		var neighbor_index := posmod(nearest_cardinal_index + (1 if offset > 0.0 else -1), 4)
		return TranslationServer.translate("hud.direction.between_format") % [cardinal, TranslationServer.translate(CARDINAL_KEYS[neighbor_index])]
	var diagonal_index := int(roundi((bearing - 45.0) / 90.0)) % 4
	return TranslationServer.translate(INTERCARDINAL_KEYS[diagonal_index])


static func relative_wind_location_phrase(relative_from_degrees: float) -> String:
	var angle := wrapf(relative_from_degrees, -180.0, 180.0)
	var magnitude := absf(angle)
	if magnitude < 18.0:
		return TranslationServer.translate("hud.wind_relative.bow")
	if magnitude < 68.0:
		return TranslationServer.translate("hud.wind_relative.port_forward" if angle < 0.0 else "hud.wind_relative.starboard_forward")
	if magnitude < 112.0:
		return TranslationServer.translate("hud.wind_relative.port_beam" if angle < 0.0 else "hud.wind_relative.starboard_beam")
	if magnitude < 162.0:
		return TranslationServer.translate("hud.wind_relative.port_aft" if angle < 0.0 else "hud.wind_relative.starboard_aft")
	return TranslationServer.translate("hud.wind_relative.stern")


static func action_key_hint(action_name: String) -> String:
	if not InputMap.has_action(action_name):
		return TranslationServer.translate("hud.input.unbound")
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
	return " / ".join(keys) if not keys.is_empty() else TranslationServer.translate("hud.input.unbound")
