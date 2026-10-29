extends RefCounted
## Tilt-only staged sail reefing controller. It consumes the vessel's actual
## signed heel and simulation delta; wind data is intentionally not an input.

const FILTER_SECONDS_DEFAULT := 3.0
const REEF_THRESHOLD_DEFAULT_DEG := 25.0
const AGGRESSIVE_THRESHOLD_DEFAULT_DEG := 30.0
const EMERGENCY_THRESHOLD_DEFAULT_DEG := 35.0
const RECOVERY_THRESHOLD_DEFAULT_DEG := 18.0
const REEF_CONFIRM_SECONDS_DEFAULT := 3.0
const RECOVERY_CONFIRM_SECONDS_DEFAULT := 20.0
const ACTION_INTERVAL_SECONDS_DEFAULT := 3.0

var filter_seconds := FILTER_SECONDS_DEFAULT
var reef_threshold_deg := REEF_THRESHOLD_DEFAULT_DEG
var aggressive_threshold_deg := AGGRESSIVE_THRESHOLD_DEFAULT_DEG
var emergency_threshold_deg := EMERGENCY_THRESHOLD_DEFAULT_DEG
var recovery_threshold_deg := RECOVERY_THRESHOLD_DEFAULT_DEG
var reef_confirm_seconds := REEF_CONFIRM_SECONDS_DEFAULT
var recovery_confirm_seconds := RECOVERY_CONFIRM_SECONDS_DEFAULT
var action_interval_seconds := ACTION_INTERVAL_SECONDS_DEFAULT

var enabled := false
var filtered_heel_deg := 0.0
var _high_heel_seconds := 0.0
var _recovery_seconds := 0.0
var _action_seconds := 0.0
var _emergency_latched := false
var _status := "手动控制"


func configure(profile: Resource) -> void:
	if profile == null:
		return
	filter_seconds = maxf(float(profile.get("auto_reef_filter_seconds")), 0.1)
	reef_threshold_deg = float(profile.get("auto_reef_reef_threshold_deg"))
	aggressive_threshold_deg = float(profile.get("auto_reef_aggressive_threshold_deg"))
	emergency_threshold_deg = float(profile.get("auto_reef_emergency_threshold_deg"))
	recovery_threshold_deg = float(profile.get("auto_reef_recovery_threshold_deg"))
	reef_confirm_seconds = maxf(float(profile.get("auto_reef_reef_confirm_seconds")), 0.0)
	recovery_confirm_seconds = maxf(float(profile.get("auto_reef_recovery_confirm_seconds")), 0.0)
	action_interval_seconds = maxf(float(profile.get("auto_reef_action_interval_seconds")), 0.1)


func set_enabled(value: bool, heel_rad: float, main_current: float, jib_current: float) -> void:
	enabled = value
	filtered_heel_deg = absf(rad_to_deg(heel_rad)) if is_finite(heel_rad) else 0.0
	_high_heel_seconds = 0.0
	_recovery_seconds = 0.0
	_action_seconds = 0.0
	_emergency_latched = false
	_status = "AUTO Reef 已开启 · 监测横倾" if enabled else "手动控制"


func update(
	heel_rad: float,
	delta_seconds: float,
	main_target: float,
	jib_target: float,
	main_current: float,
	jib_current: float
) -> Dictionary:
	var result := {
		"main_target": clampf(main_target, 0.0, 1.0),
		"jib_target": clampf(jib_target, 0.0, 1.0),
		"filtered_heel_deg": filtered_heel_deg,
		"status": _status,
		"enabled": enabled,
		"action": "none",
	}
	if not enabled:
		return result
	var step := maxf(delta_seconds, 0.0) if is_finite(delta_seconds) else 0.0
	var measured_heel_deg := absf(rad_to_deg(heel_rad)) if is_finite(heel_rad) else 0.0
	# Treat the configured value as the approximate 95% settling time rather than
	# a 3 s first-order time constant, so emergency tilt reacts within a few seconds.
	var alpha := 1.0 - exp(-3.0 * step / filter_seconds) if step > 0.0 else 0.0
	filtered_heel_deg = lerpf(filtered_heel_deg, measured_heel_deg, alpha)
	_action_seconds += step

	var next_main := float(result["main_target"])
	var next_jib := float(result["jib_target"])
	var action := "none"
	if filtered_heel_deg > emergency_threshold_deg:
		_high_heel_seconds = maxf(_high_heel_seconds, reef_confirm_seconds)
		_recovery_seconds = 0.0
		if not _emergency_latched:
			next_main = maxf(0.0, next_main - 0.25)
			next_jib = maxf(0.0, next_jib - 0.12)
			_emergency_latched = true
			_action_seconds = 0.0
			action = "紧急缩帆"
		elif _action_seconds >= minf(action_interval_seconds * 0.5, 1.5):
			next_main = maxf(0.0, next_main - 0.15)
			if next_main <= 0.5:
				next_jib = maxf(0.0, next_jib - 0.10)
			_action_seconds = 0.0
			action = "继续强力缩帆"
		_status = "强横倾 %.1f° · %s" % [filtered_heel_deg, action if action != "none" else "等待下一步缩帆"]
	elif filtered_heel_deg > aggressive_threshold_deg:
		_high_heel_seconds += step
		_recovery_seconds = 0.0
		if _high_heel_seconds >= reef_confirm_seconds and _action_seconds >= minf(action_interval_seconds * 0.5, 1.5):
			next_main = maxf(0.0, next_main - 0.15)
			if next_main <= 0.5:
				next_jib = maxf(0.0, next_jib - 0.10)
			_action_seconds = 0.0
			action = "积极缩帆"
		_status = "横倾 %.1f° · %s" % [filtered_heel_deg, action if action != "none" else "等待调整间隔"]
	elif filtered_heel_deg > reef_threshold_deg:
		_emergency_latched = false
		_high_heel_seconds += step
		_recovery_seconds = 0.0
		if _high_heel_seconds >= reef_confirm_seconds and _action_seconds >= action_interval_seconds:
			next_main = maxf(0.0, next_main - 0.10)
			if next_main <= 0.5:
				next_jib = maxf(0.0, next_jib - 0.08)
			_action_seconds = 0.0
			action = "逐步缩帆"
		_status = "持续横倾 %.1f° · %s" % [filtered_heel_deg, action if action != "none" else "等待确认"]
	else:
		_high_heel_seconds = 0.0
		_emergency_latched = false
		if filtered_heel_deg < recovery_threshold_deg:
			_recovery_seconds += step
			if _recovery_seconds >= recovery_confirm_seconds and _action_seconds >= action_interval_seconds:
				if next_main < 0.999:
					next_main = minf(1.0, next_main + 0.05)
					action = "缓慢展开主帆"
				elif next_jib < 0.999:
					next_jib = minf(1.0, next_jib + 0.05)
					action = "缓慢展开前帆"
				_action_seconds = 0.0
			_status = "横倾 %.1f° · %s" % [filtered_heel_deg, action if action != "none" else "恢复观察"]
		else:
			_recovery_seconds = 0.0
			_status = "横倾 %.1f° · 保持当前展开量" % filtered_heel_deg

	if is_equal_approx(next_main, main_current) and is_equal_approx(next_jib, jib_current) and action == "none" and main_current <= 0.001 and jib_current <= 0.001 and filtered_heel_deg > reef_threshold_deg:
		_status = "横倾仍高 · 两片帆已完全收起"
	result["main_target"] = clampf(next_main, 0.0, 1.0)
	result["jib_target"] = clampf(next_jib, 0.0, 1.0)
	result["filtered_heel_deg"] = filtered_heel_deg
	result["status"] = _status
	result["action"] = action
	return result


func get_snapshot() -> Dictionary:
	return {
		"enabled": enabled,
		"filtered_heel_deg": filtered_heel_deg,
		"status": _status,
		"high_heel_seconds": _high_heel_seconds,
		"recovery_seconds": _recovery_seconds,
	}
