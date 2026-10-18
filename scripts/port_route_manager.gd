class_name PortRouteManager
extends Node3D

signal routes_changed

const DRAFT_SCHEMA_VERSION := 1
const ROUTE_DRAFT_DIRECTORY := "user://route_drafts"
const ROUTE_EXPORT_DIRECTORY := "res://resources/routes/edited"

@export var georeference: GeoReference
@export_node_path("Node") var bathymetry_path := NodePath("../BathymetryManager")
@export_node_path("Node") var depth_provider_path := NodePath("../NavigationDepthProvider")
@export var port_definitions: Array[PortDefinition] = []
@export var route_definitions: Array[RouteDefinition] = []
@export var debug_enabled := false

var _ports: Dictionary = {}
var _routes: Dictionary = {}
var _debug_root: Node3D
var bathymetry: BathymetryManager
var depth_provider: NavigationDepthProvider


func _ready() -> void:
	bathymetry = get_node_or_null(bathymetry_path) as BathymetryManager
	depth_provider = get_node_or_null(depth_provider_path) as NavigationDepthProvider
	for port in port_definitions:
		if port == null or port.port_id.is_empty():
			continue
		if _ports.has(str(port.port_id)):
			push_error("PortRouteManager: duplicate port ID %s" % port.port_id)
			continue
		_ports[str(port.port_id)] = port
	for route in route_definitions:
		if route == null or route.route_id.is_empty():
			continue
		if _routes.has(str(route.route_id)):
			push_error("PortRouteManager: duplicate route ID %s" % route.route_id)
			continue
		if not _ports.has(str(route.origin_port_id)) or not _ports.has(str(route.destination_port_id)):
			push_error("PortRouteManager: route %s references an unregistered port" % route.route_id)
			continue
		_routes[str(route.route_id)] = route
	_load_saved_route_drafts()
	_build_debug_visuals()
	set_debug_visible(debug_enabled)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event.is_action_pressed("route_debug_toggle") or event.is_echo():
		return
	toggle_debug()
	get_viewport().set_input_as_handled()


func get_port(port_id: String) -> PortDefinition:
	return _ports.get(port_id) as PortDefinition


func get_registered_port_ids() -> PackedStringArray:
	var result := PackedStringArray()
	for key in _ports:
		result.append(str(key))
	result.sort()
	return result


func get_registered_ports() -> Array[PortDefinition]:
	var result: Array[PortDefinition] = []
	for port_id in get_registered_port_ids():
		result.append(_ports[port_id] as PortDefinition)
	return result


func get_route(route_id: String) -> RouteDefinition:
	return _routes.get(route_id) as RouteDefinition


func get_routes() -> Array[RouteDefinition]:
	var result: Array[RouteDefinition] = []
	for key in _routes:
		result.append(_routes[key] as RouteDefinition)
	result.sort_custom(func(a: RouteDefinition, b: RouteDefinition) -> bool: return str(a.route_id) < str(b.route_id))
	return result


func get_route_between(origin_port_id: String, destination_port_id: String) -> RouteDefinition:
	for candidate in get_routes():
		if str(candidate.origin_port_id) == origin_port_id and str(candidate.destination_port_id) == destination_port_id:
			return candidate
	return null


func is_route_cruise_eligible(route: RouteDefinition) -> bool:
	return route != null and route.cruise_allowed and route.validation_status == RouteDefinition.STATUS_VALIDATED


func get_nearest_route_candidates(world_position: Vector3, maximum_distance_m: float, cruise_eligible_only: bool = true) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	if georeference == null:
		return candidates
	for route in get_routes():
		if cruise_eligible_only and not is_route_cruise_eligible(route):
			continue
		var projection := route.find_nearest_projection(world_position, georeference)
		if projection.is_empty():
			continue
		var distance := float(projection.get("distance_m", INF))
		if distance > maximum_distance_m:
			continue
		var segment_index := int(projection.get("segment_index", 0))
		var internal_ambiguity := _has_nearby_non_adjacent_segment(route, world_position, segment_index, distance, maximum_distance_m)
		candidates.append({
			"route": route,
			"route_id": str(route.route_id),
			"distance_m": distance,
			"route_progress_m": float(projection.get("route_progress_m", 0.0)),
			"segment_index": segment_index,
			"segment_t": float(projection.get("segment_t", 0.0)),
			"projection": projection.get("position", Vector3.ZERO),
			"tangent": projection.get("tangent", Vector2.ZERO),
			"internal_ambiguity": internal_ambiguity,
		})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("distance_m", INF)) < float(b.get("distance_m", INF))
	)
	return candidates


func get_route_summary(route: RouteDefinition, cruise_speed_mps: float) -> Dictionary:
	if route == null or georeference == null:
		return {}
	var distance := route.get_total_distance_m(georeference)
	var time_seconds := route.get_estimated_travel_time_seconds(cruise_speed_mps, georeference)
	return {
		"route_id": str(route.route_id),
		"display_name": route.display_name,
		"origin_port_id": str(route.origin_port_id),
		"destination_port_id": str(route.destination_port_id),
		"distance_m": distance,
		"estimated_seconds": time_seconds,
		"validation_status": route.validation_status,
		"cruise_allowed": route.cruise_allowed,
		"waypoint_count": route.waypoints.size(),
		"updated_version": route.updated_version,
	}


func update_route_ports(route_id: String, origin_port_id: String, destination_port_id: String) -> Dictionary:
	if not _is_development_build():
		return {"accepted": false, "reason": "仅开发者可以修改航线起终点港"}
	var route := get_route(route_id)
	var origin := get_port(origin_port_id)
	var destination := get_port(destination_port_id)
	if route == null or origin == null or destination == null or georeference == null:
		return {"accepted": false, "reason": "航线或港口配置无效"}
	if origin_port_id == destination_port_id:
		return {"accepted": false, "reason": "起点港和终点港必须不同"}
	route.origin_port_id = StringName(origin_port_id)
	route.destination_port_id = StringName(destination_port_id)
	var departure_geo := georeference.world_to_geodetic(_port_wait_point_world(origin, origin.departure_offset_east_north_m))
	var arrival_geo := georeference.world_to_geodetic(_port_wait_point_world(destination, destination.approach_offset_east_north_m))
	route.departure_point_id = StringName("%s_departure" % route_id)
	route.departure_display_name = "%s 出港等待点" % origin.display_name
	route.departure_latitude_deg = departure_geo.x
	route.departure_longitude_deg = departure_geo.y
	route.arrival_point_id = StringName("%s_arrival" % route_id)
	route.arrival_display_name = "%s 进港等待点" % destination.display_name
	route.arrival_latitude_deg = arrival_geo.x
	route.arrival_longitude_deg = arrival_geo.y
	route.invalidate_for_edit()
	routes_changed.emit()
	return {"accepted": true, "route": route}


func validate_route(route_id: String) -> Dictionary:
	var route := get_route(route_id)
	var errors := PackedStringArray()
	var warnings := PackedStringArray()
	if route == null:
		return {"valid": false, "errors": PackedStringArray(["找不到航线"]), "warnings": warnings}
	if georeference == null:
		errors.append("GeoReference 未配置")
		return {"valid": false, "errors": errors, "warnings": warnings}
	if route.route_id.is_empty() or route.display_name.strip_edges().is_empty():
		errors.append("航线 ID 或名称为空")
	if not _ports.has(str(route.origin_port_id)) or not _ports.has(str(route.destination_port_id)):
		errors.append("起点或终点港口未注册")
	if route.origin_port_id == route.destination_port_id:
		errors.append("起点和终点不能是同一港口")
	if route.waypoints.is_empty() or route.waypoints.size() > 64:
		errors.append("航路点数量必须为 1–64")
	var ids := {}
	for waypoint in route.waypoints:
		if waypoint == null or waypoint.waypoint_id.is_empty() or waypoint.display_name.strip_edges().is_empty():
			errors.append("存在缺少稳定 ID 或名称的航路点")
			continue
		if ids.has(str(waypoint.waypoint_id)):
			errors.append("航路点 ID 重复：%s" % waypoint.waypoint_id)
		ids[str(waypoint.waypoint_id)] = true
		if not is_finite(waypoint.latitude_deg) or not is_finite(waypoint.longitude_deg) or absf(waypoint.latitude_deg) > 90.0 or absf(waypoint.longitude_deg) > 180.0:
			errors.append("航路点坐标无效：%s" % waypoint.waypoint_id)
	for endpoint in [Vector2(route.departure_latitude_deg, route.departure_longitude_deg), Vector2(route.arrival_latitude_deg, route.arrival_longitude_deg)]:
		if not is_finite(endpoint.x) or not is_finite(endpoint.y) or absf(endpoint.x) > 90.0 or absf(endpoint.y) > 180.0:
			errors.append("路线端点坐标无效")
	if not errors.is_empty():
		return _validation_result(route, errors, warnings)
	var points := route.get_world_points(georeference)
	var validation_diagnostics := {}
	if points.size() < 3:
		errors.append("路线至少需要一个中间航路点")
		return _validation_result(route, errors, warnings)
	if not points.is_empty():
		var departure_port := _ports.get(str(route.origin_port_id)) as PortDefinition
		var arrival_port := _ports.get(str(route.destination_port_id)) as PortDefinition
		if departure_port != null and _horizontal_distance(points[0], _port_wait_point_world(departure_port, departure_port.departure_offset_east_north_m)) > 250.0:
			errors.append("出发点与港口配置的出港等待点相距超过 250 m")
		if arrival_port != null and _horizontal_distance(points[-1], _port_wait_point_world(arrival_port, arrival_port.approach_offset_east_north_m)) > 250.0:
			errors.append("到达点与港口配置的进港等待点相距超过 250 m")
		for index in range(points.size()):
			var point := points[index]
			var geo := georeference.world_to_geodetic(point)
			if geo.x < georeference.south_latitude_deg or geo.x > georeference.north_latitude_deg or geo.y < georeference.west_longitude_deg or geo.y > georeference.east_longitude_deg:
				errors.append("航线点超出当前游戏地图范围")
				break
			if index > 0 and _horizontal_distance(points[index - 1], point) < 5.0:
				errors.append("路线存在重复点或短于 5 m 的零长度航段")
			if index > 0 and index < points.size() - 1:
				var incoming := Vector2(point.x - points[index - 1].x, point.z - points[index - 1].z).normalized()
				var outgoing := Vector2(points[index + 1].x - point.x, points[index + 1].z - point.z).normalized()
				var turn_degrees := rad_to_deg(acos(clampf(incoming.dot(outgoing), -1.0, 1.0)))
				if turn_degrees > 120.0:
					errors.append("航点 %d 处转向超过 120°" % index)
				elif turn_degrees > 75.0:
					warnings.append("航点 %d 处急弯，巡航时会减速" % index)
		var hard_land := false
		var land_hit_world_position := Vector3.ZERO
		var land_hit_segment_index := -1
		var unknown_depth := false
		var unsafe_depth := false
		var unsafe_depth_world_position := Vector3.ZERO
		var unsafe_depth_segment_index := -1
		var unsafe_depth_value_m := 0.0
		var unsafe_draft_m := 0.8
		var boat := get_node_or_null("../PlayerBoat/MotionRoot") as BoatController
		if boat != null and boat.get_current_draft_m() >= 0.0:
			unsafe_draft_m = boat.get_current_draft_m()
		for segment_index in range(points.size() - 1):
			var start := points[segment_index]
			var finish := points[segment_index + 1]
			var distance := _horizontal_distance(start, finish)
			var samples := maxi(1, ceili(distance / 120.0))
			for sample_index in range(samples + 1):
				var sample_position := start.lerp(finish, float(sample_index) / float(samples))
				var east := sample_position.x
				var north := -sample_position.z
				if bathymetry != null and bathymetry.is_land_at_east_north(east, north):
					hard_land = true
					land_hit_world_position = sample_position
					land_hit_segment_index = segment_index
					break
				if depth_provider != null:
					var sample := depth_provider.query_world_position(sample_position)
					if not bool(sample.get("valid", false)) or bool(sample.get("estimated", false)):
						unknown_depth = true
					if bool(sample.get("valid", false)):
						var sample_depth_m := float(sample.get("depth_m", 0.0))
						if sample_depth_m < unsafe_draft_m:
							unsafe_depth = true
							unsafe_depth_world_position = sample_position
							unsafe_depth_segment_index = segment_index
							unsafe_depth_value_m = sample_depth_m
							break
			if hard_land or unsafe_depth:
				break
		if hard_land:
			var land_hit_geo := georeference.world_to_geodetic(land_hit_world_position)
			errors.append("第 %d 航段触及 30 m OSM 陆地掩膜（%.6f°N, %.6f°E）" % [land_hit_segment_index + 1, land_hit_geo.x, land_hit_geo.y])
			validation_diagnostics["validation_hit_world_position"] = land_hit_world_position
			validation_diagnostics["validation_hit_kind"] = "land"
		if unsafe_depth:
			var unsafe_depth_geo := georeference.world_to_geodetic(unsafe_depth_world_position)
			errors.append("第 %d 航段水深 %.2f m 低于船舶吃水 %.2f m（%.6f°N, %.6f°E）" % [unsafe_depth_segment_index + 1, unsafe_depth_value_m, unsafe_draft_m, unsafe_depth_geo.x, unsafe_depth_geo.y])
			if not hard_land:
				validation_diagnostics["validation_hit_world_position"] = unsafe_depth_world_position
				validation_diagnostics["validation_hit_kind"] = "shallow"
		if unknown_depth:
			warnings.append("部分水深未知；需要管理员进行完整游戏内航行验证")
	if warnings.is_empty():
		warnings.append("自动检查不代表海事安全；仍需人工完整航行测试")
	return _validation_result(route, errors, warnings, validation_diagnostics)


func mark_route_validated_for_gameplay(route_id: String) -> Dictionary:
	if not _is_development_build():
		return {"accepted": false, "reason": "仅开发者可以批准游戏内航线"}
	var result := validate_route(route_id)
	if not bool(result.get("valid", false)):
		return {"accepted": false, "reason": "自动校验发现错误", "validation": result}
	var route := get_route(route_id)
	route.validation_status = RouteDefinition.STATUS_VALIDATED
	route.cruise_allowed = true
	route.updated_version += 1
	var saved := save_route_draft(route_id)
	if not bool(saved.get("accepted", false)):
		route.validation_status = RouteDefinition.STATUS_NEEDS_REVIEW
		route.cruise_allowed = false
		route.updated_version = maxi(route.updated_version - 1, 1)
		routes_changed.emit()
		return {"accepted": false, "reason": "路线通过校验，但批准状态无法保存：%s" % saved.get("reason", "写入失败"), "validation": result}
	routes_changed.emit()
	return {"accepted": true, "validation": result, "saved_path": saved.get("path", "")}


func mark_route_needs_review(route_id: String) -> bool:
	var route := get_route(route_id)
	if route == null:
		return false
	route.invalidate_for_edit()
	routes_changed.emit()
	return true


func register_route(route: RouteDefinition) -> bool:
	if route == null or route.route_id.is_empty():
		return false
	if not _ports.has(str(route.origin_port_id)) or not _ports.has(str(route.destination_port_id)):
		return false
	_routes[str(route.route_id)] = route
	routes_changed.emit()
	return true


func create_route_draft(origin_port_id: String, destination_port_id: String, route_id: String, display_name: String) -> RouteDefinition:
	if not _is_development_build() or route_id.is_empty() or _safe_route_file_name(route_id) != route_id or get_route(route_id) != null:
		return null
	var origin := get_port(origin_port_id)
	var destination := get_port(destination_port_id)
	if origin == null or destination == null or origin_port_id == destination_port_id or georeference == null:
		return null
	var departure_world := _port_wait_point_world(origin, origin.departure_offset_east_north_m)
	var arrival_world := _port_wait_point_world(destination, destination.approach_offset_east_north_m)
	var departure_geo := georeference.world_to_geodetic(departure_world)
	var arrival_geo := georeference.world_to_geodetic(arrival_world)
	var route := RouteDefinition.new()
	route.route_id = StringName(route_id)
	route.display_name = display_name if not display_name.strip_edges().is_empty() else "%s → %s" % [origin.display_name, destination.display_name]
	route.origin_port_id = StringName(origin_port_id)
	route.destination_port_id = StringName(destination_port_id)
	route.departure_point_id = StringName("%s_departure" % route_id)
	route.departure_display_name = "%s 出港等待点" % origin.display_name
	route.departure_latitude_deg = departure_geo.x
	route.departure_longitude_deg = departure_geo.y
	route.arrival_point_id = StringName("%s_arrival" % route_id)
	route.arrival_display_name = "%s 进港等待点" % destination.display_name
	route.arrival_latitude_deg = arrival_geo.x
	route.arrival_longitude_deg = arrival_geo.y
	route.cruise_allowed = false
	route.validation_status = RouteDefinition.STATUS_DRAFT
	route.updated_version = 1
	route.data_source = "Developer-created route draft; automatic navigation and DTM validation are not safety certification."
	return route if register_route(route) else null


func save_route_draft(route_id: String) -> Dictionary:
	if not _is_development_build():
		return {"accepted": false, "reason": "航线草稿写入仅限开发版本"}
	var route := get_route(route_id)
	if route == null:
		return {"accepted": false, "reason": "找不到要保存的航线"}
	var directory := ProjectSettings.globalize_path(ROUTE_DRAFT_DIRECTORY)
	var make_error := DirAccess.make_dir_recursive_absolute(directory)
	if make_error != OK and make_error != ERR_ALREADY_EXISTS:
		return {"accepted": false, "reason": "无法创建 user://route_drafts 目录"}
	var path := _draft_path(route_id)
	if path.is_empty():
		return {"accepted": false, "reason": "航线 ID 含有不支持的字符"}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"accepted": false, "reason": "无法写入开发者航线草稿"}
	file.store_string(JSON.stringify(_route_to_dictionary(route), "\t"))
	file.close()
	return {"accepted": true, "path": path}


func load_route_draft(route_id: String) -> Dictionary:
	if not _is_development_build():
		return {"accepted": false, "reason": "航线草稿加载仅限开发版本"}
	var path := _draft_path(route_id)
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"accepted": false, "reason": "未找到该航线的本地草稿"}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"accepted": false, "reason": "无法读取航线草稿"}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != DRAFT_SCHEMA_VERSION:
		return {"accepted": false, "reason": "航线草稿格式或版本无效"}
	var route := _route_from_dictionary(parsed.get("route", {}))
	if route == null or str(route.route_id) != route_id or not _ports.has(str(route.origin_port_id)) or not _ports.has(str(route.destination_port_id)):
		return {"accepted": false, "reason": "航线草稿的 ID 或港口配置无效"}
	# Persisted local approval belongs to this exact saved route draft. Any
	# subsequent editor change invalidates it before that changed route is saved.
	_routes[route_id] = route
	routes_changed.emit()
	return {"accepted": true, "route": route}


func export_route_draft(route_id: String) -> Dictionary:
	if not OS.has_feature("editor"):
		return {"accepted": false, "reason": "打包运行版本不能写入 res://；草稿已保存在 user://route_drafts"}
	var route := get_route(route_id)
	if route == null:
		return {"accepted": false, "reason": "找不到要导出的航线"}
	var directory := ProjectSettings.globalize_path(ROUTE_EXPORT_DIRECTORY)
	var make_error := DirAccess.make_dir_recursive_absolute(directory)
	if make_error != OK and make_error != ERR_ALREADY_EXISTS:
		return {"accepted": false, "reason": "无法创建项目航线导出目录"}
	var path := "%s/%s.json" % [ROUTE_EXPORT_DIRECTORY.trim_suffix("/"), _safe_route_file_name(route_id)]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"accepted": false, "reason": "Godot 编辑器无法写入 res://；请从开发草稿导出"}
	file.store_string(JSON.stringify(_route_to_dictionary(route), "\t"))
	file.close()
	return {"accepted": true, "path": path}


func set_debug_visible(visible: bool) -> void:
	debug_enabled = visible
	if _debug_root != null:
		_debug_root.visible = visible


func toggle_debug() -> void:
	set_debug_visible(not debug_enabled)


func get_debug_summary(cruise_speed_mps: float) -> String:
	var lines := PackedStringArray()
	for route in get_routes():
		var summary := get_route_summary(route, cruise_speed_mps)
		var travel_seconds := float(summary.get("estimated_seconds", -1.0))
		var travel_minutes := int(round(travel_seconds / 60.0)) if travel_seconds >= 0.0 else -1
		var travel_text := "%d:%02d h" % [int(travel_minutes / 60), travel_minutes % 60] if travel_minutes >= 60 else "%d min" % travel_minutes
		lines.append("%s · %d WP · %.2f km · ETA %s @ %.1f m/s · %s%s" % [
			str(summary.get("route_id", "")),
			int(summary.get("waypoint_count", 0)),
			float(summary.get("distance_m", 0.0)) / 1000.0,
			travel_text,
			cruise_speed_mps,
			str(summary.get("validation_status", "Unknown")),
			" · 可自动巡航" if bool(summary.get("cruise_allowed", false)) else " · 禁止巡航",
		])
	return "\n".join(lines)


func _load_saved_route_drafts() -> void:
	_load_exported_route_definitions()
	if not _is_development_build():
		return
	var directory := DirAccess.open(ROUTE_DRAFT_DIRECTORY)
	if directory == null:
		return
	directory.list_dir_begin()
	var file_name := directory.get_next()
	while not file_name.is_empty():
		if not directory.current_is_dir() and file_name.ends_with(".json"):
			var route_id := file_name.trim_suffix(".json")
			var loaded := load_route_draft(route_id)
			if not bool(loaded.get("accepted", false)):
				push_warning("PortRouteManager ignored route draft %s: %s" % [file_name, loaded.get("reason", "invalid")])
		file_name = directory.get_next()
	directory.list_dir_end()


func _load_exported_route_definitions() -> void:
	var directory := DirAccess.open(ROUTE_EXPORT_DIRECTORY)
	if directory == null:
		return
	directory.list_dir_begin()
	var file_name := directory.get_next()
	while not file_name.is_empty():
		if not directory.current_is_dir() and file_name.ends_with(".json"):
			var path := "%s/%s" % [ROUTE_EXPORT_DIRECTORY.trim_suffix("/"), file_name]
			var file := FileAccess.open(path, FileAccess.READ)
			if file != null:
				var parsed: Variant = JSON.parse_string(file.get_as_text())
				file.close()
				if parsed is Dictionary and int(parsed.get("schema_version", 0)) == DRAFT_SCHEMA_VERSION:
					var route := _route_from_dictionary(parsed.get("route", {}))
					if route != null and _ports.has(str(route.origin_port_id)) and _ports.has(str(route.destination_port_id)):
						_routes[str(route.route_id)] = route
					else:
						push_warning("PortRouteManager ignored exported route %s: invalid route or port ID" % file_name)
				else:
					push_warning("PortRouteManager ignored exported route %s: invalid JSON or schema" % file_name)
		file_name = directory.get_next()
	directory.list_dir_end()


func _route_to_dictionary(route: RouteDefinition) -> Dictionary:
	var waypoint_values: Array[Dictionary] = []
	for waypoint in route.waypoints:
		if waypoint == null:
			continue
		waypoint_values.append({
			"waypoint_id": str(waypoint.waypoint_id),
			"display_name": waypoint.display_name,
			"latitude_deg": waypoint.latitude_deg,
			"longitude_deg": waypoint.longitude_deg,
			"arrival_radius_m": waypoint.arrival_radius_m,
			"optional_speed_limit_mps": waypoint.optional_speed_limit_mps,
			"navigation_notes": waypoint.navigation_notes,
		})
	return {
		"schema_version": DRAFT_SCHEMA_VERSION,
		"route": {
			"route_id": str(route.route_id), "display_name": route.display_name,
			"origin_port_id": str(route.origin_port_id), "destination_port_id": str(route.destination_port_id),
			"departure_point_id": str(route.departure_point_id), "departure_display_name": route.departure_display_name,
			"departure_latitude_deg": route.departure_latitude_deg, "departure_longitude_deg": route.departure_longitude_deg,
			"arrival_point_id": str(route.arrival_point_id), "arrival_display_name": route.arrival_display_name,
			"arrival_latitude_deg": route.arrival_latitude_deg, "arrival_longitude_deg": route.arrival_longitude_deg,
			"arrival_radius_m": route.arrival_radius_m, "waypoints": waypoint_values,
			"cruise_allowed": route.cruise_allowed, "validation_status": route.validation_status,
			"updated_version": route.updated_version, "data_source": route.data_source,
		},
	}


func _route_from_dictionary(data: Variant) -> RouteDefinition:
	if not data is Dictionary:
		return null
	var route := RouteDefinition.new()
	route.route_id = StringName(str(data.get("route_id", "")))
	route.display_name = str(data.get("display_name", ""))
	route.origin_port_id = StringName(str(data.get("origin_port_id", "")))
	route.destination_port_id = StringName(str(data.get("destination_port_id", "")))
	route.departure_point_id = StringName(str(data.get("departure_point_id", "")))
	route.departure_display_name = str(data.get("departure_display_name", "出港等待点"))
	route.departure_latitude_deg = float(data.get("departure_latitude_deg", NAN))
	route.departure_longitude_deg = float(data.get("departure_longitude_deg", NAN))
	route.arrival_point_id = StringName(str(data.get("arrival_point_id", "")))
	route.arrival_display_name = str(data.get("arrival_display_name", "进港等待点"))
	route.arrival_latitude_deg = float(data.get("arrival_latitude_deg", NAN))
	route.arrival_longitude_deg = float(data.get("arrival_longitude_deg", NAN))
	route.arrival_radius_m = float(data.get("arrival_radius_m", 180.0))
	route.cruise_allowed = bool(data.get("cruise_allowed", false))
	route.validation_status = str(data.get("validation_status", RouteDefinition.STATUS_DRAFT))
	var known_statuses := [RouteDefinition.STATUS_DRAFT, RouteDefinition.STATUS_NEEDS_REVIEW, RouteDefinition.STATUS_VALIDATED, RouteDefinition.STATUS_DISABLED]
	if not known_statuses.has(route.validation_status):
		route.validation_status = RouteDefinition.STATUS_DRAFT
		route.cruise_allowed = false
	elif route.validation_status != RouteDefinition.STATUS_VALIDATED:
		route.cruise_allowed = false
	elif not route.cruise_allowed:
		route.validation_status = RouteDefinition.STATUS_NEEDS_REVIEW
	route.updated_version = maxi(int(data.get("updated_version", 1)), 1)
	route.data_source = str(data.get("data_source", "Developer edited route"))
	var waypoint_data: Variant = data.get("waypoints", [])
	if not waypoint_data is Array:
		return null
	for waypoint_value in waypoint_data:
		if not waypoint_value is Dictionary:
			return null
		var waypoint := RouteWaypoint.new()
		waypoint.waypoint_id = StringName(str(waypoint_value.get("waypoint_id", "")))
		waypoint.display_name = str(waypoint_value.get("display_name", ""))
		waypoint.latitude_deg = float(waypoint_value.get("latitude_deg", NAN))
		waypoint.longitude_deg = float(waypoint_value.get("longitude_deg", NAN))
		waypoint.arrival_radius_m = float(waypoint_value.get("arrival_radius_m", 150.0))
		waypoint.optional_speed_limit_mps = float(waypoint_value.get("optional_speed_limit_mps", -1.0))
		waypoint.navigation_notes = str(waypoint_value.get("navigation_notes", ""))
		route.waypoints.append(waypoint)
	return route


func _validation_result(route: RouteDefinition, errors: PackedStringArray, warnings: PackedStringArray, diagnostics: Dictionary = {}) -> Dictionary:
	var valid := errors.is_empty()
	if route != null:
		route.validation_status = RouteDefinition.STATUS_NEEDS_REVIEW if valid else RouteDefinition.STATUS_DRAFT
		route.cruise_allowed = false
	var result := {"valid": valid, "errors": errors, "warnings": warnings, "route_id": str(route.route_id) if route != null else ""}
	result.merge(diagnostics, true)
	return result


func _distance_to_port_anchor(point: Vector3, port: PortDefinition) -> float:
	if port == null or georeference == null:
		return INF
	var anchor := georeference.geodetic_to_world(port.latitude_deg, port.longitude_deg)
	return _horizontal_distance(point, anchor)


func _port_wait_point_world(port: PortDefinition, offset: Vector2) -> Vector3:
	var anchor := georeference.geodetic_to_world(port.latitude_deg, port.longitude_deg)
	var local_offset := Vector3(offset.x, 0.0, -offset.y)
	return anchor + Basis(Vector3.UP, deg_to_rad(port.layout_rotation_degrees)) * local_offset


func _has_nearby_non_adjacent_segment(route: RouteDefinition, position: Vector3, chosen_segment: int, chosen_distance: float, maximum_distance: float) -> bool:
	var points := route.get_world_points(georeference)
	for segment_index in range(points.size() - 1):
		if absi(segment_index - chosen_segment) <= 1:
			continue
		var projection := route.find_nearest_projection(position, georeference, segment_index, segment_index)
		if not projection.is_empty() and float(projection.get("distance_m", INF)) <= minf(maximum_distance, chosen_distance + 15.0):
			return true
	return false


func _draft_path(route_id: String) -> String:
	var safe_id := _safe_route_file_name(route_id)
	return "" if safe_id.is_empty() else "%s/%s.json" % [ROUTE_DRAFT_DIRECTORY, safe_id]


func _safe_route_file_name(route_id: String) -> String:
	if route_id.is_empty():
		return ""
	for character in route_id:
		var code := character.unicode_at(0)
		var is_ascii_letter := (code >= 65 and code <= 90) or (code >= 97 and code <= 122)
		var is_ascii_digit := code >= 48 and code <= 57
		if not (is_ascii_letter or is_ascii_digit or code == 95 or code == 45 or code == 46):
			return ""
	if route_id.contains("..") or route_id.begins_with("."):
		return ""
	return route_id


func _is_development_build() -> bool:
	return OS.has_feature("editor") or OS.has_feature("debug")


func _horizontal_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(b.x - a.x, b.z - a.z).length()


func _build_debug_visuals() -> void:
	_debug_root = Node3D.new()
	_debug_root.name = "RouteDebugVisuals"
	add_child(_debug_root)
	for route in get_routes():
		var points := route.get_world_points(georeference)
		if points.size() < 2:
			continue
		var line_mesh := ImmediateMesh.new()
		line_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for point in points:
			line_mesh.surface_add_vertex(point + Vector3(0.0, 2.0, 0.0))
		line_mesh.surface_end()
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color("#f0b75a") if str(route.origin_port_id) == "kobenhavn_test" else Color("#46e5de")
		line_mesh.surface_set_material(0, material)
		var line := MeshInstance3D.new()
		line.name = "Route_%s" % route.route_id
		line.mesh = line_mesh
		_debug_root.add_child(line)
		for index in range(points.size()):
			var marker := MeshInstance3D.new()
			marker.name = "RoutePoint_%s_%02d" % [route.route_id, index]
			var sphere := SphereMesh.new()
			sphere.radius = 3.2 if index == 0 or index == points.size() - 1 else 2.0
			sphere.height = sphere.radius * 2.0
			sphere.material = material
			marker.mesh = sphere
			marker.position = points[index] + Vector3(0.0, 2.5, 0.0)
			_debug_root.add_child(marker)
			var label := Label3D.new()
			label.name = "RouteLabel_%s_%02d" % [route.route_id, index]
			label.text = route.departure_display_name if index == 0 else route.arrival_display_name if index == points.size() - 1 else route.waypoints[index - 1].display_name
			label.position = points[index] + Vector3(0.0, 7.0, 0.0)
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.font_size = 36
			label.modulate = material.albedo_color
			_debug_root.add_child(label)
