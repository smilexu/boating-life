extends RefCounted
## Lightweight AWA-based trim controller for the standalone SailboatLab.
## It only selects target sheet angles; the vessel remains responsible for
## mechanical limits, trim rates and all aerodynamic forces.

const MIN_EFFECTIVE_AWS_MPS := 0.5
const HEAD_TO_WIND_HOLD_DEGREES := 12.0
const DOWNWIND_HOLD_DEGREES := 150.0
const NO_GO_ENTER_DEGREES := 30.0
const NO_GO_EXIT_DEGREES := 35.0

## These class-level points retain the C7a baseline as a safe fallback. The
## SailboatLab body configures the vessel's current calibration from its profile.
var _main_trim_curve_points_degrees := PackedVector2Array([
	Vector2(0.0, 10.0), Vector2(30.0, 10.0), Vector2(45.0, 20.0),
	Vector2(60.0, 30.0), Vector2(90.0, 50.0), Vector2(120.0, 60.0),
	Vector2(150.0, 70.0), Vector2(180.0, 75.0),
])
var _headsail_trim_curve_points_degrees := PackedVector2Array([
	Vector2(0.0, 10.0), Vector2(30.0, 10.0), Vector2(45.0, 15.0),
	Vector2(60.0, 25.0), Vector2(90.0, 40.0), Vector2(120.0, 50.0),
	Vector2(150.0, 60.0), Vector2(180.0, 65.0),
])
var _trim_sign := 0.0 # +1 moves the sails to starboard, -1 to port.
var _main_target_rad := 0.0
var _headsail_target_rad := 0.0
var _no_go_active := false
var _has_valid_wind := false
var _status := "等待有效视风"


func configure_curves(main_points: PackedVector2Array, headsail_points: PackedVector2Array) -> bool:
	if not _is_valid_curve(main_points) or not _is_valid_curve(headsail_points):
		return false
	_main_trim_curve_points_degrees = main_points.duplicate()
	_headsail_trim_curve_points_degrees = headsail_points.duplicate()
	return true


func reset(main_target_rad: float = 0.0, headsail_target_rad: float = 0.0) -> void:
	_trim_sign = 0.0
	_main_target_rad = main_target_rad if is_finite(main_target_rad) else 0.0
	_headsail_target_rad = headsail_target_rad if is_finite(headsail_target_rad) else 0.0
	_no_go_active = false
	_has_valid_wind = false
	_status = "等待有效视风"


func update_from_snapshot(snapshot: Dictionary) -> Dictionary:
	var awa := float(snapshot.get("apparent_wind_from_relative_degrees", 0.0))
	var aws := float(snapshot.get("apparent_wind_speed_mps", 0.0))
	var twa := float(snapshot.get("true_wind_from_relative_degrees", 0.0))
	var tws := float(snapshot.get("true_wind_speed_mps", 0.0))
	var sog := float(snapshot.get("sog_mps", snapshot.get("longitudinal_velocity_mps", 0.0)))
	if not is_finite(awa) or not is_finite(aws) or not is_finite(twa) or not is_finite(tws):
		_status = "风数据无效 · 保持目标角"
		return _make_result(awa, aws, sog, false)

	if aws < MIN_EFFECTIVE_AWS_MPS:
		if tws < MIN_EFFECTIVE_AWS_MPS:
			_no_go_active = false
			_status = "无有效风 · 保持目标角"
		else:
			_status = "视风过低 · 保持目标角"
		return _make_result(awa, aws, sog, false)

	_update_trim_side(awa, twa, snapshot)
	var absolute_awa := clampf(absf(awa), 0.0, 180.0)
	var main_magnitude := _main_trim_magnitude_degrees(absolute_awa)
	var headsail_magnitude := _headsail_trim_magnitude_degrees(absolute_awa)
	var main_target := deg_to_rad(main_magnitude * _trim_sign)
	var headsail_target := deg_to_rad(headsail_magnitude * _trim_sign)
	_main_target_rad = clampf(
		main_target,
		float(snapshot.get("min_sail_angle_rad", -PI)),
		float(snapshot.get("max_sail_angle_rad", PI))
	)
	if bool(snapshot.get("headsail_enabled", true)):
		_headsail_target_rad = clampf(
			headsail_target,
			float(snapshot.get("min_headsail_angle_rad", -PI)),
			float(snapshot.get("max_headsail_angle_rad", PI))
		)
	else:
		_headsail_target_rad = float(snapshot.get("target_headsail_angle_rad", _headsail_target_rad))

	if _no_go_active:
		_no_go_active = absolute_awa < NO_GO_EXIT_DEGREES
	else:
		_no_go_active = absolute_awa <= NO_GO_ENTER_DEGREES
	_has_valid_wind = true
	_status = "NO-GO · 帆无有效迎风推进" if _no_go_active else "自动修帆"
	return _make_result(awa, aws, sog, true)


func get_status() -> String:
	return _status


func get_trim_sign() -> float:
	return _trim_sign


func has_valid_wind() -> bool:
	return _has_valid_wind


func _update_trim_side(awa: float, twa: float, snapshot: Dictionary) -> void:
	var absolute_awa := absf(awa)
	var side_can_change := absolute_awa > HEAD_TO_WIND_HOLD_DEGREES and absolute_awa < DOWNWIND_HOLD_DEGREES
	if side_can_change:
		# Signed wind-from angles are negative for port wind and positive for
		# starboard wind. Leeward trim is therefore the opposite signed angle.
		_trim_sign = -signf(awa)
	if is_zero_approx(_trim_sign):
		if absf(twa) > HEAD_TO_WIND_HOLD_DEGREES and absf(twa) < DOWNWIND_HOLD_DEGREES:
			_trim_sign = -signf(twa)
		elif absf(awa) > HEAD_TO_WIND_HOLD_DEGREES:
			_trim_sign = -signf(awa)
		else:
			var previous_target := float(snapshot.get("target_sail_angle_rad", _main_target_rad))
			_trim_sign = signf(previous_target)
			if is_zero_approx(_trim_sign):
				_trim_sign = 1.0


func _main_trim_magnitude_degrees(absolute_awa: float) -> float:
	return _evaluate_curve(_main_trim_curve_points_degrees, absolute_awa)


func _headsail_trim_magnitude_degrees(absolute_awa: float) -> float:
	return _evaluate_curve(_headsail_trim_curve_points_degrees, absolute_awa)


func _evaluate_curve(points: PackedVector2Array, absolute_awa: float) -> float:
	var angle := clampf(absolute_awa, 0.0, 180.0)
	if angle <= points[0].x:
		return points[0].y
	for index in range(1, points.size()):
		var previous := points[index - 1]
		var current := points[index]
		if angle <= current.x:
			var t := (angle - previous.x) / (current.x - previous.x)
			return lerpf(previous.y, current.y, t)
	return points[points.size() - 1].y


func _is_valid_curve(points: PackedVector2Array) -> bool:
	if points.size() < 2 or not is_zero_approx(points[0].x) or not is_equal_approx(points[points.size() - 1].x, 180.0):
		return false
	var previous_x := -1.0
	for point in points:
		if not is_finite(point.x) or not is_finite(point.y) or point.x <= previous_x or point.x < 0.0 or point.x > 180.0 or point.y < 0.0:
			return false
		previous_x = point.x
	return true


func _make_result(awa: float, aws: float, sog: float, updated: bool) -> Dictionary:
	var side := "右舷展开" if _trim_sign > 0.0 else "左舷展开" if _trim_sign < 0.0 else "未选舷侧"
	return {
		"main_target_angle_rad": _main_target_rad,
		"headsail_target_angle_rad": _headsail_target_rad,
		"trim_sign": _trim_sign,
		"selected_side": side,
		"no_go": _no_go_active,
		"apparent_wind_angle_degrees": awa,
		"apparent_wind_speed_mps": aws,
		"sog_mps": sog,
		"status": _status,
		"updated": updated,
	}
