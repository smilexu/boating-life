class_name AutopilotController
extends Node

signal status_changed
signal message_changed(message: String)

const STATE_IDLE := "IDLE"
const STATE_ACQUIRING := "ACQUIRING"
const STATE_CRUISING := "CRUISING"
const STATE_APPROACHING := "APPROACHING"
const STATE_COMPLETED := "COMPLETED"
const STATE_DISENGAGED := "DISENGAGED"
const STATE_SAFETY_HOLD := "SAFETY_HOLD"

@export_node_path("Node3D") var boat_path := NodePath("../PlayerBoat/MotionRoot")
@export_node_path("Node") var route_manager_path := NodePath("../PortRouteManager")
@export_node_path("Node") var depth_provider_path := NodePath("../NavigationDepthProvider")
@export_node_path("Node") var map_path := NodePath("../FishResourceMap")
@export_range(10.0, 500.0, 1.0) var route_access_distance_m := 50.0
@export_range(1.0, 100.0, 1.0) var route_ambiguity_distance_m := 15.0
@export_range(0.1, 1.0, 0.05) var control_update_interval_seconds := 0.1
@export_range(20.0, 180.0, 1.0) var maximum_start_heading_error_degrees := 70.0
@export_range(50.0, 1000.0, 10.0) var maximum_cross_track_distance_m := 180.0
@export_range(5.0, 100.0, 1.0) var route_lookahead_minimum_m := 30.0
@export_range(20.0, 250.0, 1.0) var route_lookahead_maximum_m := 110.0
@export_range(10.0, 100.0, 1.0) var safety_sample_distance_m := 35.0
@export_range(10.0, 200.0, 1.0) var arrival_slowdown_distance_m := 750.0
@export_category("Developer speed override")
@export_range(0.1, 5.0, 0.1) var debug_cruise_speed_step_mps := 0.5
@export_range(12.0, 60.0, 1.0) var debug_max_cruise_speed_mps := 30.0

var state := STATE_IDLE
var route: RouteDefinition
var current_segment_index := 0
var route_progress_m := 0.0
var cross_track_distance_m := 0.0
var target_speed_mps := 0.0
var last_message := ""
var _boat: BoatController
var _route_manager: PortRouteManager
var _depth_provider: NavigationDepthProvider
var _map: FishResourceMap
var _control_elapsed := 0.0
var _depth_elapsed := 0.0
var _last_status_message_time := -100.0
var _message_sequence := 0
var _safety_hold_reason := ""
var _depth_speed_limit_mps := -1.0
var _route_depth_notice := ""
var _completion_time := -1.0
var _active_route_version := -1
var _route_world_points: Array[Vector3] = []
var _route_cumulative_distances := PackedFloat32Array()
var _route_total_distance_m := 0.0
var _temporary_cruise_speed_mps := -1.0


func _ready() -> void:
	process_priority = -10
	_boat = get_node_or_null(boat_path) as BoatController
	_route_manager = get_node_or_null(route_manager_path) as PortRouteManager
	_depth_provider = get_node_or_null(depth_provider_path) as NavigationDepthProvider
	_map = get_node_or_null(map_path) as FishResourceMap
	if _boat == null or _route_manager == null or _depth_provider == null:
		push_error("AutopilotController requires a boat, PortRouteManager and NavigationDepthProvider.")
		return
	_boat.manual_takeover_requested.connect(_on_manual_takeover_requested)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if _boat != null and _boat.is_autopilot and _is_debug_build() and not (_map != null and _map.is_map_open()):
			var adjustment := _cruise_adjustment_for_key(event as InputEventKey)
			if adjustment != 0:
				adjust_temporary_cruise_speed(adjustment)
				get_viewport().set_input_as_handled()
				return
	if not event.is_action_pressed("boat_toggle_autopilot") or event.is_echo():
		return
	if _map != null and _map.is_map_open():
		return
	if _boat != null and _boat.is_autopilot:
		cancel_autopilot("已切回手动驾驶")
	else:
		try_engage_nearest_route()
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _boat == null or _route_manager == null:
		return
	if _boat.is_port_docked:
		if route != null or _boat.is_autopilot:
			cancel_autopilot("船舶已停泊，自动巡航退出")
		return
	if route != null and not _boat.is_autopilot and state not in [STATE_COMPLETED, STATE_DISENGAGED, STATE_IDLE]:
		cancel_autopilot("自动巡航已退出，临时速度已恢复")
		return
	if not _is_engaged():
		if state == STATE_COMPLETED and _completion_time >= 0.0 and Time.get_ticks_msec() / 1000.0 - _completion_time > 8.0:
			state = STATE_DISENGAGED
			route = null
			_clear_route_geometry()
			status_changed.emit()
		return
	if _route_manager.get_route(str(route.route_id)) != route or not _route_manager.is_route_cruise_eligible(route) or route.updated_version != _active_route_version:
		cancel_autopilot("活动航线已被禁用或修改，已安全交还手动控制")
		return
	if _boat.is_motion_paused:
		return
	_control_elapsed += delta
	_depth_elapsed += delta
	if _control_elapsed < control_update_interval_seconds:
		return
	var step := minf(_control_elapsed, 0.3)
	_control_elapsed = fmod(_control_elapsed, control_update_interval_seconds)
	_update_route_progress()
	if not _is_engaged():
		return
	if state == STATE_SAFETY_HOLD and not _safety_hold_reason.is_empty():
		if _safety_hold_reason.begins_with("偏离航线"):
			_publish_motion_command(0.0, 0.0)
			return
	if _depth_elapsed >= 0.5:
		_depth_elapsed = fmod(_depth_elapsed, 0.5)
		_check_water_ahead()
	if not _safety_hold_reason.is_empty():
		_publish_motion_command(_steering_for_current_heading(), 0.0)
		return
	_update_path_following(step)


func try_engage_nearest_route() -> Dictionary:
	if _boat == null or _route_manager == null:
		return _reject("自动巡航系统尚未就绪")
	if _boat.is_port_docked:
		return _reject("停泊期间不能启动自动巡航，请先离港")
	if _boat.is_motion_paused:
		return _reject("船舶已暂停，恢复航行后再启动自动巡航")
	if _boat.speed_mps < 0.0 or not is_finite(_boat.speed_mps):
		return _reject("当前船速状态无效，不能接入航线")
	var cruise_speed := _get_cruise_speed()
	if not is_finite(cruise_speed) or cruise_speed <= 0.0 or cruise_speed > _boat.max_speed_mps:
		return _reject("当前船型没有有效的巡航速度配置")
	var candidates: Array[Dictionary] = _route_manager.get_nearest_route_candidates(_boat.global_position, route_access_distance_m, true)
	if candidates.is_empty():
		var all_candidates: Array[Dictionary] = _route_manager.get_nearest_route_candidates(_boat.global_position, route_access_distance_m, false)
		if not all_candidates.is_empty():
			return _reject("附近航线尚未完成游戏内验证，不能自动巡航")
		return _reject("50 米接入范围内没有可用航线，请驶近预设路线")
	var first: Dictionary = candidates[0]
	if float(first.get("distance_m", INF)) > route_access_distance_m:
		return _reject("距离最近航线 %.0f m，超过接入范围 %.0f m" % [float(first.get("distance_m", INF)), route_access_distance_m])
	if candidates.size() > 1 and float(candidates[1].get("distance_m", INF)) - float(first.get("distance_m", INF)) < route_ambiguity_distance_m:
		return _reject("附近有多条航线，请驶近希望使用的航线后重试")
	if bool(first.get("internal_ambiguity", false)):
		return _reject("此处路线自身有交叉或折返，请驶近唯一航段后重试")
	var chosen_route := first.get("route") as RouteDefinition
	if chosen_route == null or not _route_manager.is_route_cruise_eligible(chosen_route):
		return _reject("航线未启用或未完成游戏内验证")
	var projection: Vector3 = first.get("projection", Vector3.ZERO)
	var projection_depth := _depth_provider.evaluate_world_position(projection, _boat.get_current_draft_m())
	if not _is_start_water_allowed(projection_depth):
		return _reject("接入点水深状态为 %s，自动巡航要求有效的 Safe/Caution 游戏参考数据" % str(projection_depth.get("status", NavigationDepthProvider.STATUS_UNKNOWN)))
	var projection_progress := float(first.get("route_progress_m", 0.0))
	var lookahead := clampf(_boat.speed_mps * 3.5, route_lookahead_minimum_m, route_lookahead_maximum_m)
	var join_target := chosen_route.get_point_at_distance(minf(projection_progress + lookahead, chosen_route.get_total_distance_m(_route_manager.georeference)), _route_manager.georeference)
	var target_position: Vector3 = join_target.get("position", projection)
	var desired_heading := _heading_to(Vector2(target_position.x - _boat.global_position.x, target_position.z - _boat.global_position.z))
	var heading_error := absf(wrapf(desired_heading - _current_world_heading(), -PI, PI))
	if heading_error > deg_to_rad(maximum_start_heading_error_degrees):
		return _reject("接入需要转向 %.0f°，请先调整船头方向后重试" % rad_to_deg(heading_error))
	var current_depth := _depth_provider.evaluate_world_position(_boat.global_position, _boat.get_current_draft_m())
	if not _is_start_water_allowed(current_depth):
		return _reject("当前位置水深为 %s，不能从未知或不安全水域启动自动巡航" % str(current_depth.get("status", NavigationDepthProvider.STATUS_UNKNOWN)))
	route = chosen_route
	_cache_route_geometry(chosen_route)
	route_progress_m = projection_progress
	current_segment_index = int(first.get("segment_index", 0))
	cross_track_distance_m = float(first.get("distance_m", 0.0))
	_safety_hold_reason = ""
	_depth_speed_limit_mps = -1.0
	_route_depth_notice = ""
	_completion_time = -1.0
	_active_route_version = chosen_route.updated_version
	state = STATE_ACQUIRING
	_control_elapsed = 0.0
	_depth_elapsed = 0.5
	_temporary_cruise_speed_mps = -1.0
	_boat.set_autopilot_speed_cap_mps(0.0)
	_boat.submit_autopilot_command(0.0, _boat.speed_mps)
	_set_message("自动巡航接入 %s；不会自动靠泊" % route.display_name)
	status_changed.emit()
	return {"accepted": true, "route_id": str(route.route_id), "distance_m": cross_track_distance_m, "segment_index": current_segment_index}


func cancel_autopilot(message: String = "自动巡航已取消") -> void:
	if _boat != null:
		_boat.disengage_autopilot()
	_temporary_cruise_speed_mps = -1.0
	route = null
	_clear_route_geometry()
	current_segment_index = 0
	route_progress_m = 0.0
	cross_track_distance_m = 0.0
	target_speed_mps = 0.0
	_safety_hold_reason = ""
	_route_depth_notice = ""
	state = STATE_DISENGAGED
	_set_message(message)
	status_changed.emit()


func request_manual_takeover() -> void:
	if _is_engaged():
		cancel_autopilot("已切回手动驾驶")


func get_status_snapshot() -> Dictionary:
	var total_distance := _route_total_distance_m if route != null else 0.0
	var remaining := maxf(total_distance - route_progress_m, 0.0)
	var segment_count := _route_world_points.size() - 1 if route != null else 0
	var target_name := ""
	if route != null:
		if current_segment_index < route.waypoints.size():
			var waypoint := route.waypoints[current_segment_index]
			target_name = waypoint.display_name if waypoint != null and not waypoint.display_name.is_empty() else str(waypoint.waypoint_id) if waypoint != null else "航路点"
		else:
			target_name = route.arrival_display_name
	var cruise_speed := _get_cruise_speed()
	var eta_seconds := remaining / maxf(cruise_speed, 0.1) * 1.1 if cruise_speed > 0.0 else -1.0
	return {
		"state": state,
		"route_id": str(route.route_id) if route != null else "",
		"route_name": route.display_name if route != null else "",
		"validation_status": route.validation_status if route != null else "",
		"origin_port_id": str(route.origin_port_id) if route != null else "",
		"destination_port_id": str(route.destination_port_id) if route != null else "",
		"target_waypoint": target_name,
		"segment_index": current_segment_index + 1,
		"segment_count": segment_count,
		"progress_fraction": clampf(route_progress_m / total_distance, 0.0, 1.0) if total_distance > 0.0 else 0.0,
		"progress_m": route_progress_m,
		"remaining_m": remaining,
		"eta_seconds": eta_seconds,
		"actual_speed_mps": _boat.speed_mps if _boat != null else 0.0,
		"target_speed_mps": target_speed_mps,
		"cruise_speed_mps": cruise_speed,
		"temporary_cruise_speed_mps": _temporary_cruise_speed_mps,
		"cross_track_distance_m": cross_track_distance_m,
		"message": last_message,
		"message_age_seconds": Time.get_ticks_msec() / 1000.0 - _last_status_message_time,
		"safety_hold_reason": _safety_hold_reason,
		"depth_notice": _route_depth_notice,
	}


func get_current_state() -> String:
	return state


func _update_route_progress() -> void:
	if route == null or _route_manager == null or _route_manager.georeference == null or _boat == null:
		return
	var last_segment := mini(current_segment_index + 2, _route_world_points.size() - 2)
	var projection := _find_cached_projection(_boat.global_position, current_segment_index, last_segment)
	if projection.is_empty():
		return
	while int(projection.get("segment_index", current_segment_index)) > current_segment_index:
		if not _can_advance_past_current_waypoint():
			projection = _find_cached_projection(_boat.global_position, current_segment_index, current_segment_index)
			break
		current_segment_index += 1
		last_segment = mini(current_segment_index + 2, _route_world_points.size() - 2)
		projection = _find_cached_projection(_boat.global_position, current_segment_index, last_segment)
		if projection.is_empty():
			return
	cross_track_distance_m = float(projection.get("distance_m", INF))
	if cross_track_distance_m > maximum_cross_track_distance_m:
		_safety_hold_reason = "偏离航线 %.0f m，自动巡航减速停车，请手动接管" % cross_track_distance_m
		state = STATE_SAFETY_HOLD
		_set_message(_safety_hold_reason)
		target_speed_mps = 0.0
		return
	var projected_progress := float(projection.get("route_progress_m", route_progress_m))
	if projected_progress >= route_progress_m - 8.0:
		route_progress_m = maxf(route_progress_m, projected_progress)
		current_segment_index = maxi(current_segment_index, int(projection.get("segment_index", current_segment_index)))
	var end_distance := maxf(_route_total_distance_m - route_progress_m, 0.0)
	if end_distance <= route.arrival_radius_m and _boat.speed_mps <= 1.5:
		_finish_route()


func _can_advance_past_current_waypoint() -> bool:
	if route == null or _boat == null or current_segment_index >= route.waypoints.size():
		return false
	var waypoint := route.waypoints[current_segment_index]
	var corner := _route_world_points[current_segment_index + 1]
	var distance_to_waypoint := Vector2(_boat.global_position.x - corner.x, _boat.global_position.z - corner.z).length()
	var radius := waypoint.arrival_radius_m if waypoint != null else 1.0
	if distance_to_waypoint <= radius:
		return true
	var outgoing_end := _route_world_points[current_segment_index + 2]
	var outgoing := Vector2(outgoing_end.x - corner.x, outgoing_end.z - corner.z).normalized()
	var offset := Vector2(_boat.global_position.x - corner.x, _boat.global_position.z - corner.z)
	return offset.dot(outgoing) > 0.0


func _update_path_following(_delta: float) -> void:
	if route == null or _route_manager == null or _route_manager.georeference == null:
		cancel_autopilot("航线数据失效，已恢复手动驾驶")
		return
	var total := _route_total_distance_m
	if total <= 1.0:
		cancel_autopilot("路线长度无效，已恢复手动驾驶")
		return
	var remaining := maxf(total - route_progress_m, 0.0)
	var lookahead := clampf(maxf(_boat.speed_mps, 1.0) * 4.0, route_lookahead_minimum_m, route_lookahead_maximum_m)
	var follow_point := _get_cached_point_at_distance(minf(route_progress_m + lookahead, total))
	var target_position: Vector3 = follow_point.get("position", _boat.global_position)
	var direction := Vector2(target_position.x - _boat.global_position.x, target_position.z - _boat.global_position.z)
	if direction.length_squared() < 1.0:
		var tangent: Vector2 = follow_point.get("tangent", Vector2.ZERO)
		direction = tangent if tangent.length_squared() > 0.1 else Vector2(-_boat.global_transform.basis.z.x, -_boat.global_transform.basis.z.z)
	var desired_heading := _heading_to(direction)
	var heading_error := wrapf(desired_heading - _current_world_heading(), -PI, PI)
	var turn_rate := deg_to_rad(maxf(_boat.turn_rate_degrees_per_second, 1.0))
	var steering := clampf(heading_error / maxf(turn_rate * 1.7, 0.05), -1.0, 1.0)
	target_speed_mps = _get_cruise_speed()
	if current_segment_index < route.waypoints.size():
		var next_waypoint := route.waypoints[current_segment_index]
		if next_waypoint != null and next_waypoint.optional_speed_limit_mps > 0.0:
			target_speed_mps = minf(target_speed_mps, next_waypoint.optional_speed_limit_mps)
	if _depth_speed_limit_mps > 0.0:
		target_speed_mps = minf(target_speed_mps, _depth_speed_limit_mps)
	target_speed_mps = minf(target_speed_mps, _speed_for_upcoming_turn())
	if remaining <= arrival_slowdown_distance_m:
		state = STATE_APPROACHING
		var stop_distance := maxf(remaining - route.arrival_radius_m, 0.0)
		var braking_target := sqrt(maxf(2.0 * _boat.braking_mps2 * stop_distance, 0.0))
		target_speed_mps = minf(target_speed_mps, braking_target)
	else:
		state = STATE_ACQUIRING if cross_track_distance_m > 8.0 else STATE_CRUISING
	_publish_motion_command(steering, target_speed_mps)
	status_changed.emit()


func _speed_for_upcoming_turn() -> float:
	if route == null or _route_manager == null or _route_manager.georeference == null:
		return _get_cruise_speed()
	var points := _route_world_points
	if current_segment_index + 2 >= points.size():
		return _get_cruise_speed()
	var start := points[current_segment_index]
	var corner := points[current_segment_index + 1]
	var after_corner := points[current_segment_index + 2]
	var incoming := Vector2(corner.x - start.x, corner.z - start.z).normalized()
	var outgoing := Vector2(after_corner.x - corner.x, after_corner.z - corner.z).normalized()
	var turn_degrees := rad_to_deg(acos(clampf(incoming.dot(outgoing), -1.0, 1.0)))
	if turn_degrees < 30.0:
		return _get_cruise_speed()
	var corner_distance := _distance_to_segment_end(_boat.global_position, start, corner)
	var slowdown_distance := clampf(_boat.speed_mps * _boat.speed_mps / maxf(2.0 * _boat.braking_mps2, 0.1) + 90.0, 120.0, 350.0)
	var blend := 1.0 - clampf(corner_distance / slowdown_distance, 0.0, 1.0)
	var speed_floor := _get_cruise_speed() * (0.55 if turn_degrees < 75.0 else 0.35)
	return lerpf(_get_cruise_speed(), maxf(speed_floor, minf(1.8, _get_cruise_speed())), blend)


func _check_water_ahead() -> void:
	if _depth_provider == null or _boat == null:
		_safety_hold_reason = "水深提供器不可用，自动巡航保守停车"
		state = STATE_SAFETY_HOLD
		_set_message(_safety_hold_reason)
		return
	var draft := _boat.get_current_draft_m()
	if draft < 0.0:
		_safety_hold_reason = "船舶吃水数据未知，自动巡航保守停车"
		state = STATE_SAFETY_HOLD
		_set_message(_safety_hold_reason)
		return
	var forward := -_boat.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.001:
		return
	forward = forward.normalized()
	var ahead_distance := clampf(maxf(_boat.speed_mps, 1.5) * 4.0, 20.0, safety_sample_distance_m)
	var current := _depth_provider.evaluate_world_position(_boat.global_position, draft)
	var ahead := _depth_provider.evaluate_world_position(_boat.global_position + forward * ahead_distance, draft)
	var current_status := str(current.get("status", NavigationDepthProvider.STATUS_UNKNOWN))
	var ahead_status := str(ahead.get("status", NavigationDepthProvider.STATUS_UNKNOWN))
	if current_status == NavigationDepthProvider.STATUS_UNSAFE or ahead_status == NavigationDepthProvider.STATUS_UNSAFE:
		_safety_hold_reason = "前方参考水深低于吃水，自动巡航正在减速停车"
		_route_depth_notice = _safety_hold_reason
		state = STATE_SAFETY_HOLD
		_set_message(_safety_hold_reason)
	elif current_status == NavigationDepthProvider.STATUS_UNKNOWN or ahead_status == NavigationDepthProvider.STATUS_UNKNOWN:
		# A gameplay-validated route may still cross gaps in the low-resolution
		# DTM. Keep it usable at a conservative speed; measured unsafe depth above
		# remains a full stop.
		_safety_hold_reason = ""
		_depth_speed_limit_mps = 2.0
		_route_depth_notice = "前方参考水深未知，自动巡航保守限速至 2 m/s；这不是海事安全导航"
		_set_message(_route_depth_notice)
	elif current_status == NavigationDepthProvider.STATUS_CAUTION or ahead_status == NavigationDepthProvider.STATUS_CAUTION:
		_safety_hold_reason = ""
		_depth_speed_limit_mps = 2.0
		_route_depth_notice = "水深未满足配置安全余量，自动巡航限速至 2 m/s"
		_set_message(_route_depth_notice)
	else:
		_safety_hold_reason = ""
		_depth_speed_limit_mps = -1.0
		_route_depth_notice = ""


func _is_start_water_allowed(sample: Dictionary) -> bool:
	var status := str(sample.get("status", NavigationDepthProvider.STATUS_UNKNOWN))
	return bool(sample.get("valid", false)) and status in [NavigationDepthProvider.STATUS_SAFE, NavigationDepthProvider.STATUS_CAUTION]


func _publish_motion_command(steering: float, speed: float) -> void:
	if _boat == null:
		return
	target_speed_mps = clampf(speed, 0.0, minf(_boat.get_autopilot_speed_cap_mps(), _get_cruise_speed()))
	_boat.submit_autopilot_command(steering, target_speed_mps)


func _finish_route() -> void:
	if _boat != null:
		_boat.disengage_autopilot()
	_temporary_cruise_speed_mps = -1.0
	route_progress_m = _route_total_distance_m
	target_speed_mps = 0.0
	state = STATE_COMPLETED
	_completion_time = Time.get_ticks_msec() / 1000.0
	_safety_hold_reason = ""
	_route_depth_notice = ""
	_set_message("已到达港外等待点；自动巡航已结束，请手动进港")
	status_changed.emit()


func _cache_route_geometry(route_definition: RouteDefinition) -> void:
	_route_world_points = route_definition.get_world_points(_route_manager.georeference)
	_route_cumulative_distances.clear()
	_route_cumulative_distances.append(0.0)
	_route_total_distance_m = 0.0
	for index in range(_route_world_points.size() - 1):
		var start := _route_world_points[index]
		var finish := _route_world_points[index + 1]
		_route_total_distance_m += Vector2(finish.x - start.x, finish.z - start.z).length()
		_route_cumulative_distances.append(_route_total_distance_m)


func _clear_route_geometry() -> void:
	_route_world_points.clear()
	_route_cumulative_distances.clear()
	_route_total_distance_m = 0.0


func _find_cached_projection(world_position: Vector3, first_segment: int, last_segment: int) -> Dictionary:
	if _route_world_points.size() < 2:
		return {}
	var first := clampi(first_segment, 0, _route_world_points.size() - 2)
	var last := clampi(last_segment, first, _route_world_points.size() - 2)
	var best_distance := INF
	var best_progress := 0.0
	var best_segment := first
	var best_t := 0.0
	var best_position := _route_world_points[first]
	var best_tangent := Vector2.ZERO
	for index in range(first, last + 1):
		var start := _route_world_points[index]
		var finish := _route_world_points[index + 1]
		var segment := Vector2(finish.x - start.x, finish.z - start.z)
		var length_squared := segment.length_squared()
		if length_squared <= 0.0001:
			continue
		var length := sqrt(length_squared)
		var offset := Vector2(world_position.x - start.x, world_position.z - start.z)
		var t := clampf(offset.dot(segment) / length_squared, 0.0, 1.0)
		var projected := start.lerp(finish, t)
		var distance := Vector2(world_position.x - projected.x, world_position.z - projected.z).length()
		if distance < best_distance:
			best_distance = distance
			best_progress = _route_cumulative_distances[index] + length * t
			best_segment = index
			best_t = t
			best_position = projected
			best_tangent = segment / length
	return {
		"distance_m": best_distance,
		"route_progress_m": best_progress,
		"segment_index": best_segment,
		"segment_t": best_t,
		"position": best_position,
		"tangent": best_tangent,
	}


func _get_cached_point_at_distance(distance_m: float) -> Dictionary:
	if _route_world_points.size() < 2:
		return {}
	var remaining := clampf(distance_m, 0.0, _route_total_distance_m)
	for index in range(_route_world_points.size() - 1):
		var start := _route_world_points[index]
		var finish := _route_world_points[index + 1]
		var segment := Vector2(finish.x - start.x, finish.z - start.z)
		var length := segment.length()
		if length <= 0.0001:
			continue
		if remaining <= length or index == _route_world_points.size() - 2:
			var t := clampf(remaining / length, 0.0, 1.0)
			return {"position": start.lerp(finish, t), "tangent": segment / length, "segment_index": index}
		remaining -= length
	return {"position": _route_world_points[-1], "tangent": Vector2.ZERO, "segment_index": _route_world_points.size() - 2}


func _on_manual_takeover_requested() -> void:
	if _is_engaged():
		cancel_autopilot("检测到 W/A/S/D 驾驶输入，已交还手动控制")


func _is_engaged() -> bool:
	return _boat != null and _boat.is_autopilot and route != null and state not in [STATE_COMPLETED, STATE_DISENGAGED, STATE_IDLE]


func _get_cruise_speed() -> float:
	if _boat == null:
		return 0.0
	if _temporary_cruise_speed_mps > 0.0:
		return _temporary_cruise_speed_mps
	return _get_configured_cruise_speed()


func _get_configured_cruise_speed() -> float:
	if _boat == null:
		return 0.0
	if _boat.draft_profile != null and _boat.draft_profile.cruise_speed_mps > 0.0:
		return _boat.draft_profile.cruise_speed_mps
	return _boat.cruise_speed_mps


func adjust_temporary_cruise_speed(direction: int) -> Dictionary:
	if not _is_debug_build():
		return {"accepted": false, "reason": "临时巡航调速仅在开发构建可用"}
	if _boat == null or not _boat.is_autopilot or not _is_engaged():
		return {"accepted": false, "reason": "请先启动自动巡航"}
	if direction == 0:
		return {"accepted": false, "reason": "调速方向无效"}
	var current_speed := _get_cruise_speed()
	var next_speed := clampf(current_speed + signf(float(direction)) * debug_cruise_speed_step_mps, 0.5, debug_max_cruise_speed_mps)
	if is_equal_approx(next_speed, current_speed):
		_set_message("临时巡航速度已到 %.1f m/s 边界" % next_speed)
		return {"accepted": false, "speed_mps": next_speed, "reason": last_message}
	_temporary_cruise_speed_mps = next_speed
	_boat.set_autopilot_speed_cap_mps(maxf(_boat.max_speed_mps, next_speed))
	_set_message("本次临时巡航速度：%.1f m/s（退出巡航后恢复船型默认值）" % next_speed)
	status_changed.emit()
	return {"accepted": true, "speed_mps": next_speed}


func _cruise_adjustment_for_key(event: InputEventKey) -> int:
	if event.keycode in [KEY_PLUS, KEY_KP_ADD] or (event.keycode == KEY_EQUAL and event.shift_pressed):
		return 1
	if event.keycode in [KEY_MINUS, KEY_KP_SUBTRACT]:
		return -1
	return 0


func _is_debug_build() -> bool:
	return OS.has_feature("editor") or OS.has_feature("debug")


func _steering_for_current_heading() -> float:
	return 0.0


func _heading_to(direction: Vector2) -> float:
	if direction.length_squared() < 0.0001:
		return _current_world_heading()
	return atan2(-direction.x, -direction.y)


func _current_world_heading() -> float:
	if _boat == null:
		return 0.0
	var forward := -_boat.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return 0.0
	forward = forward.normalized()
	return atan2(-forward.x, -forward.z)


func _distance_to_segment_end(position: Vector3, start: Vector3, end: Vector3) -> float:
	var segment := Vector2(end.x - start.x, end.z - start.z)
	var length_squared := segment.length_squared()
	if length_squared < 0.0001:
		return 0.0
	var offset := Vector2(position.x - start.x, position.z - start.z)
	var t := clampf(offset.dot(segment) / length_squared, 0.0, 1.0)
	return (1.0 - t) * sqrt(length_squared)


func _reject(message: String) -> Dictionary:
	_set_message(message)
	return {"accepted": false, "reason": message}


func _set_message(message: String) -> void:
	last_message = message
	_last_status_message_time = Time.get_ticks_msec() / 1000.0
	_message_sequence += 1
	message_changed.emit(message)
