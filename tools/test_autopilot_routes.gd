extends SceneTree

const DRAFT_TEST_ID := "phase4b3_route_roundtrip_test"
const DRAFT_TEST_PATH := "user://route_drafts/%s.json" % DRAFT_TEST_ID


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	if not _expect(packed != null, "main scene resource loads"):
		return
	var main := packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var boat := main.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	var routes := main.get_node_or_null("PortRouteManager") as PortRouteManager
	var autopilot := main.get_node_or_null("AutopilotController") as AutopilotController
	var map := main.get_node_or_null("FishResourceMap") as FishResourceMap
	var geo := load("res://resources/oresund_georeference.tres") as GeoReference
	if not _expect(boat != null and routes != null and autopilot != null and map != null and geo != null, "boat, route manager, autopilot, F4 map and GeoReference are present"):
		return

	var outbound := routes.get_route("malmo_to_copenhagen_v1")
	var returning := routes.get_route("copenhagen_to_malmo_v1")
	if not _expect(outbound != null and returning != null, "the two legacy cross-strait definitions remain registered"):
		return
	if not _expect(routes.is_route_cruise_eligible(outbound), "accepted Malmö-to-København route is eligible"):
		return
	if not _expect(not routes.is_route_cruise_eligible(returning), "reverse route cannot cruise before independent gameplay validation"):
		return

	var points := outbound.get_world_points(geo)
	var sample_point: Vector3 = points[0].lerp(points[1], 0.38)
	var side := Vector2(-(points[1].z - points[0].z), points[1].x - points[0].x).normalized()
	var offset_position := sample_point + Vector3(side.x * 18.0, 0.0, side.y * 18.0)
	var projection := outbound.find_nearest_projection(offset_position, geo)
	if not _expect(not projection.is_empty() and absf(float(projection.get("distance_m", 0.0)) - 18.0) < 0.5, "route access uses nearest polyline-segment distance, not waypoint distance"):
		return
	var expected_progress := outbound.get_total_distance_m(geo) * 0.0 + float(projection.get("route_progress_m", 0.0))
	var point_at_progress := outbound.get_point_at_distance(expected_progress, geo)
	if not _expect(point_at_progress.has("position") and point_at_progress.has("tangent"), "route provides a stable distance-based lookahead point"):
		return
	autopilot.route = outbound
	autopilot.call("_cache_route_geometry", outbound)
	autopilot.current_segment_index = 0
	var first_leg := Vector2(points[1].x - points[0].x, points[1].z - points[0].z).normalized()
	var next_leg := Vector2(points[2].x - points[1].x, points[2].z - points[1].z).normalized()
	boat.global_position = points[1] - Vector3(first_leg.x * 100.0, 0.0, first_leg.y * 100.0)
	if not _expect(bool(autopilot.call("_can_advance_past_current_waypoint")), "configured waypoint arrival radius allows a smooth segment transition"):
		return
	var before_corner := -(first_leg + next_leg).normalized()
	boat.global_position = points[1] + Vector3(before_corner.x * 500.0, 0.0, before_corner.y * 500.0)
	if not _expect(not bool(autopilot.call("_can_advance_past_current_waypoint")), "route progress does not skip a waypoint before arrival"):
		return
	autopilot.route = null
	autopilot.call("_clear_route_geometry")

	map.set_map_open(true)
	await process_frame
	await process_frame
	var canvas := map.find_child("ResourceDistributionMap", true, false) as FishResourceMapCanvas
	if not _expect(canvas != null and canvas.size.x > 100.0 and canvas.size.y > 100.0, "existing F4 map canvas is available for route editing"):
		return
	var map_coordinate: Vector2 = canvas.call("_world_to_map", Vector2(sample_point.x, -sample_point.z))
	var round_trip := canvas.map_local_position_to_world(map_coordinate)
	var round_trip_world: Vector3 = round_trip.get("world_position", Vector3.ZERO)
	if not _expect(bool(round_trip.get("valid", false)) and Vector2(round_trip_world.x - sample_point.x, round_trip_world.z - sample_point.z).length() < 0.1, "F4 map click coordinates round-trip through GeoReference without pixel drift"):
		return

	var editor := map.find_child("RouteEditorPanel", true, false) as RouteEditorPanel
	if OS.has_feature("editor") or OS.has_feature("debug"):
		if not _expect(editor != null, "developer route editor is integrated into the F4 map"):
			return
		editor.set_editor_open(true)
		if not _expect(bool(canvas.get("_route_edit_enabled")), "developer editor enables map waypoint editing only while open"):
			return
		editor.set_editor_open(false)

	var test_file_path := ProjectSettings.globalize_path(DRAFT_TEST_PATH)
	DirAccess.remove_absolute(test_file_path)
	var draft := routes.create_route_draft("malmo_greybox_v1", "kobenhavn_test", DRAFT_TEST_ID, "Temporary route serialization test")
	if not _expect(draft != null and draft.validation_status == RouteDefinition.STATUS_DRAFT and not draft.cruise_allowed, "new routes start as non-cruisable drafts"):
		return
	var initial_departure := draft.departure_latitude_deg
	var changed_ports := routes.update_route_ports(DRAFT_TEST_ID, "kobenhavn_test", "malmo_greybox_v1")
	if not _expect(bool(changed_ports.get("accepted", false)) and str(draft.origin_port_id) == "kobenhavn_test" and str(draft.destination_port_id) == "malmo_greybox_v1" and not is_equal_approx(draft.departure_latitude_deg, initial_departure) and draft.validation_status == RouteDefinition.STATUS_NEEDS_REVIEW, "changing endpoints resets wait points and invalidates cruise approval"):
		return
	var saved := routes.save_route_draft(DRAFT_TEST_ID)
	if not _expect(bool(saved.get("accepted", false)), "developer route draft saves to user:// JSON"):
		return
	draft.display_name = "Changed after save"
	var loaded := routes.load_route_draft(DRAFT_TEST_ID)
	var restored := loaded.get("route") as RouteDefinition
	if not _expect(bool(loaded.get("accepted", false)) and restored != null and restored.display_name == "Temporary route serialization test" and restored.validation_status == RouteDefinition.STATUS_NEEDS_REVIEW and not restored.cruise_allowed, "saved route fields reload while local drafts lose prior cruise approval"):
		return
	DirAccess.remove_absolute(test_file_path)

	var tangent: Vector2 = projection.get("tangent", Vector2.ZERO)
	boat.is_port_docked = false
	boat.is_motion_paused = false
	boat.speed_mps = 0.0
	boat.global_position = offset_position
	boat.rotation.y = atan2(-tangent.x, -tangent.y)
	var original_heading := boat.rotation.y
	boat.global_position = sample_point + Vector3(side.x * 60.0, 0.0, side.y * 60.0)
	if not _expect(not bool(autopilot.try_engage_nearest_route().get("accepted", true)), "route more than 50 m away is rejected"):
		return
	boat.global_position = offset_position
	boat.rotation.y = wrapf(original_heading + PI, -PI, PI)
	if not _expect(not bool(autopilot.try_engage_nearest_route().get("accepted", true)), "route access does not force a near-180-degree reversal"):
		return
	boat.rotation.y = original_heading

	var parallel_route := outbound.duplicate(true) as RouteDefinition
	parallel_route.route_id = &"temporary_parallel_access_test"
	parallel_route.display_name = "Temporary parallel access test"
	_shift_route_laterally(parallel_route, geo, side, 6.0)
	if not _expect(routes.register_route(parallel_route), "temporary route can be registered for ambiguity test"):
		return
	var ambiguous_result := autopilot.try_engage_nearest_route()
	if not _expect(not bool(ambiguous_result.get("accepted", true)) and str(ambiguous_result.get("reason", "")).contains("多条航线"), "equidistant nearby routes are refused instead of chosen randomly"):
		return
	_shift_route_laterally(parallel_route, geo, side, -26.0)
	var nearest_result := autopilot.try_engage_nearest_route()
	if not _expect(bool(nearest_result.get("accepted", false)) and autopilot.route == outbound, "a clearly nearer route is chosen while keeping its defined direction"):
		return
	autopilot.request_manual_takeover()
	parallel_route.cruise_allowed = false

	var position_before_start := boat.global_position
	var engage_result := autopilot.try_engage_nearest_route()
	if not _expect(bool(engage_result.get("accepted", false)), "autopilot starts only after access, direction and depth checks pass: %s" % str(engage_result.get("reason", ""))):
		return
	if not _expect(boat.is_autopilot and autopilot.route == outbound, "autopilot commands the existing BoatController without replacing world motion"):
		return
	if not _expect(boat.global_position == position_before_start, "joining a route never teleports the boat"):
		return
	var snapshot := autopilot.get_status_snapshot()
	if not _expect(float(snapshot.get("remaining_m", 0.0)) > 0.0 and float(snapshot.get("eta_seconds", -1.0)) > 0.0, "autopilot exposes distance-based progress and ETA"):
		return
	autopilot.request_manual_takeover()
	if not _expect(not boat.is_autopilot and autopilot.route == null, "manual takeover returns steering and throttle authority"):
		return
	boat.is_port_docked = true
	if not _expect(not bool(autopilot.try_engage_nearest_route().get("accepted", true)), "docked boat cannot engage a route"):
		return
	boat.is_port_docked = false

	main.queue_free()
	await process_frame
	print("Autopilot and route-editor focused checks passed.")
	quit(0)


func _expect(condition: bool, description: String) -> bool:
	if not condition:
		push_error("FAIL: %s" % description)
		quit(1)
		return false
	print("PASS: %s" % description)
	return true


func _shift_route_laterally(route: RouteDefinition, georeference: GeoReference, side: Vector2, offset_m: float) -> void:
	var departure := georeference.geodetic_to_world(route.departure_latitude_deg, route.departure_longitude_deg)
	var shifted_departure := georeference.world_to_geodetic(departure + Vector3(side.x * offset_m, 0.0, side.y * offset_m))
	route.departure_latitude_deg = shifted_departure.x
	route.departure_longitude_deg = shifted_departure.y
	for waypoint in route.waypoints:
		var world_position := georeference.geodetic_to_world(waypoint.latitude_deg, waypoint.longitude_deg)
		var shifted := georeference.world_to_geodetic(world_position + Vector3(side.x * offset_m, 0.0, side.y * offset_m))
		waypoint.latitude_deg = shifted.x
		waypoint.longitude_deg = shifted.y
	var arrival := georeference.geodetic_to_world(route.arrival_latitude_deg, route.arrival_longitude_deg)
	var shifted_arrival := georeference.world_to_geodetic(arrival + Vector3(side.x * offset_m, 0.0, side.y * offset_m))
	route.arrival_latitude_deg = shifted_arrival.x
	route.arrival_longitude_deg = shifted_arrival.y
