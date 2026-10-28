class_name AuxiliaryMarineEngine
extends Node

enum State { OFF, STARTING, RUNNING, STOPPING }
enum Gear { REVERSE = -1, NEUTRAL = 0, FORWARD = 1 }

@export var profile: AuxiliaryMarineEngineProfile
@export_node_path("Node") var fuel_tank_path: NodePath = ^"../FuelTank"

var state := State.OFF
var gear := Gear.NEUTRAL
var target_throttle := 0.0
var actual_throttle := 0.0

var _fuel_tank: FuelTankComponent
var _transition_elapsed_s := 0.0
var _last_thrust_forward_axis_n := 0.0
var _last_consumption_lph := 0.0
var _last_consumed_l := 0.0


func _ready() -> void:
	_fuel_tank = get_node_or_null(fuel_tank_path) as FuelTankComponent
	if profile == null:
		push_error("AuxiliaryMarineEngine requires an AuxiliaryMarineEngineProfile.")


func start_engine() -> bool:
	if profile == null or _fuel_tank == null or _fuel_tank.fuel_remaining_l <= 0.0:
		return false
	if state == State.RUNNING or state == State.STARTING:
		return true
	state = State.STARTING
	_transition_elapsed_s = 0.0
	return true


func stop_engine() -> void:
	if state == State.OFF:
		actual_throttle = 0.0
		return
	if state == State.STOPPING:
		return
	target_throttle = 0.0
	state = State.STOPPING
	_transition_elapsed_s = 0.0


## Called when the vessel is switched away. The motor stops without advancing
## the hidden vessel or consuming fuel, while the tank amount is preserved.
func stop_for_vessel_switch() -> void:
	state = State.OFF
	_transition_elapsed_s = 0.0
	target_throttle = 0.0
	actual_throttle = 0.0
	gear = Gear.NEUTRAL
	_last_thrust_forward_axis_n = 0.0
	_last_consumption_lph = 0.0
	_last_consumed_l = 0.0


func reset_for_lab_test(fuel_l: float = -1.0) -> void:
	stop_for_vessel_switch()
	if fuel_l >= 0.0 and _fuel_tank != null:
		_fuel_tank.set_fuel_remaining_l(fuel_l)
		_fuel_tank.total_fuel_consumed_l = 0.0


func set_fuel_for_lab_test(fuel_l: float) -> void:
	if _fuel_tank != null:
		_fuel_tank.set_fuel_remaining_l(fuel_l)


func toggle_engine() -> bool:
	if state == State.OFF or state == State.STOPPING:
		return start_engine()
	stop_engine()
	return true


func set_gear(value: int) -> bool:
	if value not in [Gear.REVERSE, Gear.NEUTRAL, Gear.FORWARD]:
		return false
	if profile != null and maxf(target_throttle, actual_throttle) > profile.maximum_shift_throttle:
		return false
	gear = value
	return true


func cycle_gear() -> bool:
	var next_gear := Gear.FORWARD
	match gear:
		Gear.FORWARD:
			next_gear = Gear.NEUTRAL
		Gear.NEUTRAL:
			next_gear = Gear.REVERSE
		Gear.REVERSE:
			next_gear = Gear.FORWARD
	return set_gear(next_gear)


func set_target_throttle(value: float) -> void:
	if is_finite(value):
		target_throttle = clampf(value, 0.0, 1.0)


func adjust_target_throttle(delta: float) -> void:
	set_target_throttle(target_throttle + delta)


## Physics-only update. Returns a local force vector and consumes fuel using
## the same fixed simulation step as the RigidBody3D solver.
func simulate_physics_step(delta_s: float, longitudinal_speed_mps: float) -> Dictionary:
	var dt := maxf(delta_s, 0.0) if is_finite(delta_s) else 0.0
	if profile == null or _fuel_tank == null:
		return _empty_output()
	var stop_force_scale := 1.0
	match state:
		State.STARTING:
			_transition_elapsed_s += dt
			if _transition_elapsed_s >= maxf(profile.startup_duration_s, 0.01):
				state = State.RUNNING
				_transition_elapsed_s = 0.0
		State.RUNNING:
			actual_throttle = move_toward(actual_throttle, target_throttle, profile.throttle_response_per_second * dt)
		State.STOPPING:
			actual_throttle = move_toward(actual_throttle, 0.0, profile.throttle_response_per_second * dt)
			_transition_elapsed_s += dt
			stop_force_scale = clampf(1.0 - _transition_elapsed_s / maxf(profile.shutdown_duration_s, 0.01), 0.0, 1.0)
			if _transition_elapsed_s >= profile.shutdown_duration_s:
				state = State.OFF
				actual_throttle = 0.0
				stop_force_scale = 0.0

	var engine_consuming := state == State.RUNNING or state == State.STOPPING
	var consumption_lph := profile.consumption_for_throttle_lph(actual_throttle) if engine_consuming else 0.0
	if consumption_lph > profile.idle_consumption_lph and gear == Gear.NEUTRAL:
		consumption_lph = lerpf(profile.idle_consumption_lph, consumption_lph, profile.neutral_throttle_load_scale)
	elif consumption_lph > profile.idle_consumption_lph and gear == Gear.REVERSE:
		consumption_lph *= profile.reverse_consumption_scale
	var required_fuel_l := consumption_lph * dt / 3600.0
	var fuel_fraction := 1.0
	if required_fuel_l > 0.0:
		fuel_fraction = clampf(_fuel_tank.fuel_remaining_l / required_fuel_l, 0.0, 1.0)
		_last_consumed_l = _fuel_tank.consume_fuel(required_fuel_l)
	else:
		_last_consumed_l = 0.0
	if engine_consuming and _fuel_tank.fuel_remaining_l <= 0.0:
		state = State.OFF
		actual_throttle = 0.0
		target_throttle = 0.0
		stop_force_scale = 0.0

	var thrust_forward_axis_n := 0.0
	if (state == State.RUNNING or state == State.STOPPING) and gear != Gear.NEUTRAL and actual_throttle > 0.0:
		var speed := absf(longitudinal_speed_mps) if is_finite(longitudinal_speed_mps) else 0.0
		var throttle_power := pow(actual_throttle, profile.throttle_power_exponent)
		var propulsive_power_w := profile.rated_power_w() * profile.propulsive_efficiency * throttle_power
		var power_thrust_n := propulsive_power_w / maxf(speed, profile.minimum_power_speed_mps)
		var magnitude := minf(power_thrust_n, profile.maximum_bollard_thrust_n)
		var gear_scale := 1.0 if gear == Gear.FORWARD else -profile.reverse_thrust_ratio
		thrust_forward_axis_n = magnitude * gear_scale * stop_force_scale * fuel_fraction

	_last_thrust_forward_axis_n = thrust_forward_axis_n
	_last_consumption_lph = consumption_lph if _fuel_tank.fuel_remaining_l > 0.0 else 0.0
	var local_force := Vector3(0.0, 0.0, -thrust_forward_axis_n)
	return {
		"force_local_n": local_force,
		"thrust_forward_axis_n": thrust_forward_axis_n,
		"consumption_lph": _last_consumption_lph,
		"fuel_used_l": _last_consumed_l,
		"state": state,
		"gear": gear,
		"actual_throttle": actual_throttle,
		"target_throttle": target_throttle,
	}


func get_state_name() -> String:
	match state:
		State.STARTING:
			return "启动中"
		State.RUNNING:
			return "运行"
		State.STOPPING:
			return "关闭中"
		_:
			return "关闭"


func get_gear_name() -> String:
	match gear:
		Gear.FORWARD:
			return "前进"
		Gear.REVERSE:
			return "倒车"
		_:
			return "空挡"


func get_snapshot(longitudinal_speed_mps: float = 0.0) -> Dictionary:
	var tank := _fuel_tank.get_snapshot() if _fuel_tank != null else {}
	var consumption := _last_consumption_lph
	var remaining := float(tank.get("remaining_l", 0.0))
	var runtime_h := remaining / consumption if consumption > 0.0001 else 0.0
	return {
		"available": profile != null and _fuel_tank != null,
		"engine_name": profile.engine_display_name if profile != null else "未配置",
		"state": state,
		"state_name": get_state_name(),
		"running": state == State.RUNNING or state == State.STOPPING,
		"gear": gear,
		"gear_name": get_gear_name(),
		"target_throttle": target_throttle,
		"actual_throttle": actual_throttle,
		"rated_power_hp": profile.rated_power_hp if profile != null else 0.0,
		"rated_power_w": profile.rated_power_w() if profile != null else 0.0,
		"thrust_forward_axis_n": _last_thrust_forward_axis_n,
		"consumption_lph": consumption,
		"fuel_used_l": _last_consumed_l,
		"remaining_runtime_h": runtime_h,
		"runtime_estimate_valid": consumption > 0.0001 and remaining > 0.0,
		"longitudinal_speed_mps": longitudinal_speed_mps,
		"tank": tank,
		"application_point_local_m": profile.thrust_application_point_local_m if profile != null else Vector3.ZERO,
	}


func _empty_output() -> Dictionary:
	return {"force_local_n": Vector3.ZERO, "thrust_forward_axis_n": 0.0, "consumption_lph": 0.0, "fuel_used_l": 0.0}
