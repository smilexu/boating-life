extends SceneTree

const TEST_SAVE_RES_PATH := "res://.godot/phase_4b2_two_port_test.json"


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
	var malmo := main.get_node_or_null("MalmoHarbor") as Node
	var copenhagen := main.get_node_or_null("CopenhagenHarbor") as Node
	var routes := main.get_node_or_null("PortRouteManager") as PortRouteManager
	var economy := main.get_node_or_null("CargoEconomyManager") as CargoEconomyManager
	var boat := main.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	var provider := main.get_node_or_null("NavigationDepthProvider") as NavigationDepthProvider
	var bathymetry := main.get_node_or_null("BathymetryManager") as BathymetryManager
	var geo := load("res://resources/oresund_georeference.tres") as GeoReference
	if not _expect(malmo != null and copenhagen != null and routes != null and economy != null and boat != null and provider != null and bathymetry != null and geo != null, "both port scenes and shared systems are present"):
		return
	var malmo_config: PortServiceConfig = malmo.call("get_service_config")
	var cph_config: PortServiceConfig = copenhagen.call("get_service_config")
	if not _expect(str(malmo.get("port_id")) == "malmo_greybox_v1" and str(copenhagen.get("port_id")) == "kobenhavn_test", "stable legacy port IDs are retained"):
		return
	if not _expect(malmo_config != null and cph_config != null and malmo_config.port_id != cph_config.port_id and cph_config.display_name == "København", "port services are unique and CPH cargo exchange is configured"):
		return
	if not _expect(routes.get_registered_port_ids().size() == 2, "shared port registry contains both ports once"):
		return
	var cph_config_position: Dictionary = copenhagen.call("get_port_configuration")
	var cph_geo_position: Vector2 = cph_config_position["geo_position"]
	var cph_world: Vector3 = cph_config_position["port_position"]
	var round_trip := geo.world_to_geodetic(geo.geodetic_to_world(cph_geo_position.x, cph_geo_position.y))
	if not _expect(absf(round_trip.x - cph_geo_position.x) < 0.00001 and absf(round_trip.y - cph_geo_position.y) < 0.00001, "København WGS84 and ENU coordinates round trip"):
		return
	if not _expect(not bathymetry.is_land_at_east_north(cph_world.x, -cph_world.z), "København test anchor is outside the local land mask"):
		return
	var cph_depth: Dictionary = copenhagen.call("get_berth_depth_status")
	if not _expect(bool(cph_depth.get("depth_ok", false)) and cph_depth.get("samples", []).size() == 5, "København berth has five passing gameplay-depth samples"):
		return
	var cph_berth: Vector3 = cph_config_position["berth_position"]
	var cph_sample := provider.query_world_position(cph_berth)
	if not _expect(str(cph_sample.get("override_id", "")) == "copenhagen_berth_v1" and str(cph_sample.get("source", "")).contains("unverified"), "København berth override is explicitly game-only"):
		return
	var malmo_config_position: Dictionary = malmo.call("get_port_configuration")
	var malmo_sample := provider.query_world_position(malmo_config_position["berth_position"])
	if not _expect(str(malmo_sample.get("override_id", "")) == "malmo_berth_v1", "København override does not replace Malmö berth depth"):
		return
	var outside_cph := provider.query_world_position(cph_world + Vector3(500.0, 0.0, 0.0))
	if not _expect(str(outside_cph.get("override_id", "")) != "copenhagen_basin_v1" and str(outside_cph.get("override_id", "")) != "copenhagen_berth_v1", "CPH gameplay depth polygons remain local to the greybox port"):
		return
	var unknown := provider.query_world_position(Vector3(1000000.0, 0.0, 1000000.0))
	if not _expect(not bool(unknown.get("valid", false)), "depth outside the chart coverage remains unknown"):
		return

	var malmo_to_cph := routes.get_route_between("malmo_greybox_v1", "kobenhavn_test")
	var cph_to_malmo := routes.get_route_between("kobenhavn_test", "malmo_greybox_v1")
	if not _expect(malmo_to_cph != null and cph_to_malmo != null and malmo_to_cph.route_id != cph_to_malmo.route_id, "both route directions have independent definitions"):
		return
	var out_points := malmo_to_cph.get_world_points(geo)
	var return_points := cph_to_malmo.get_world_points(geo)
	if not _expect(out_points.size() == 3 and return_points.size() == 3 and malmo_to_cph.waypoints[0].waypoint_id != cph_to_malmo.waypoints[0].waypoint_id, "ordered route points have stable, direction-specific waypoint IDs"):
		return
	if not _expect(out_points[0].distance_to(malmo_config_position["departure_position"]) < 2.0 and out_points[-1].distance_to(cph_config_position["approach_position"]) < 2.0, "outbound route starts at Malmö departure and ends at the CPH offshore approach"):
		return
	var route_distance := malmo_to_cph.get_total_distance_m(geo)
	var route_time := malmo_to_cph.get_estimated_travel_time_seconds(boat.draft_profile.cruise_speed_mps, geo)
	if not _expect(route_distance > 21000.0 and route_distance < 23000.0 and is_equal_approx(route_time, route_distance / 7.0), "route distance and cruise-time estimate are calculated from GeoReference and vessel profile"):
		return
	print("Route estimate: Malmö → København %.3f km · %.1f minutes at %.1f m/s; return %.3f km" % [route_distance / 1000.0, route_time / 60.0, boat.draft_profile.cruise_speed_mps, cph_to_malmo.get_total_distance_m(geo) / 1000.0])
	if not _expect(absf(malmo_to_cph.get_remaining_distance_m(out_points[0], geo) - route_distance) < 0.5 and malmo_to_cph.get_remaining_distance_m(out_points[-1], geo) < 0.5, "remaining route distance reaches zero at arrival and equals total at departure"):
		return
	if not _expect(malmo_to_cph.validation_status == "unverified_gameplay_route" and cph_to_malmo.validation_status == "unverified_gameplay_route", "both routes remain explicitly unverified"):
		return
	var reverse_midpoint := cph_to_malmo.waypoints[0]
	if not _expect(not is_equal_approx(reverse_midpoint.latitude_deg, malmo_to_cph.waypoints[0].latitude_deg) or not is_equal_approx(reverse_midpoint.longitude_deg, malmo_to_cph.waypoints[0].longitude_deg), "southbound route is independently represented"):
		return

	if not _run_formal_delivery(malmo, copenhagen, economy, boat):
		return
	main.queue_free()
	await process_frame
	print("Two-port route and formal delivery checks passed.")
	quit(0)


func _run_formal_delivery(malmo: Node, copenhagen: Node, economy: CargoEconomyManager, boat: BoatController) -> bool:
	var absolute_test_path := ProjectSettings.globalize_path(TEST_SAVE_RES_PATH)
	DirAccess.remove_absolute(absolute_test_path)
	DirAccess.remove_absolute(absolute_test_path + ".bak")
	if not _expect(economy.reset_runtime_state_for_testing(), "isolated economy state resets for two-port delivery test"):
		return false
	if not _expect(economy.set_save_path_override_for_testing(absolute_test_path), "delivery test uses its own save file"):
		return false
	var malmo_config: Dictionary = malmo.call("get_port_configuration")
	boat.is_port_docked = false
	boat.is_motion_paused = false
	boat.speed_mps = 0.0
	boat.global_position = malmo_config["berth_position"]
	boat.global_rotation.y = deg_to_rad(float(malmo_config["berth_heading_degrees"]))
	if not _expect(bool(malmo.call("request_dock")), "Malmö test berth accepts a valid stationary vessel"):
		return false
	var contract_id := "malmo_copenhagen_spare_parts_a"
	var accepted: Dictionary = economy.accept_contract(contract_id, malmo)
	if not bool(accepted.get("accepted", false)):
		print("Delivery test accept result: %s" % JSON.stringify(accepted))
		print("Delivery test save error: %s" % str(economy.get_debug_snapshot().get("last_error", "")))
	if not _expect(bool(accepted.get("accepted", false)), "Malmö accepts and loads the Copenhagen cargo contract"):
		return false
	var loaded_draft := boat.get_current_draft_m()
	if not _expect(boat.current_cargo_weight_kg == 180.0 and loaded_draft > boat.draft_profile.empty_draft_m, "cargo load changes mass and calculated draft through the shared loadout"):
		return false
	if not _expect(not bool(economy.can_deliver_contract(contract_id, malmo).get("can_deliver", false)), "contract cannot be delivered at its origin port"):
		return false
	malmo.call("request_undock")
	var cph_config: Dictionary = copenhagen.call("get_port_configuration")
	boat.is_port_docked = false
	boat.is_motion_paused = false
	boat.speed_mps = 0.0
	boat.global_position = cph_config["berth_position"]
	boat.global_rotation.y = deg_to_rad(float(cph_config["berth_heading_degrees"]))
	if not _expect(bool(copenhagen.call("request_dock")), "København test berth accepts the loaded vessel"):
		return false
	if not _expect(bool(economy.can_deliver_contract(contract_id, copenhagen).get("can_deliver", false)), "formal destination validator accepts delivery at docked København"):
		return false
	var before_balance := economy.get_balance_cents()
	var delivered: Dictionary = economy.deliver_contract(contract_id, copenhagen)
	if not _expect(bool(delivered.get("accepted", false)) and economy.get_balance_cents() == before_balance + 22000, "formal delivery unloads cargo and credits the configured reward once"):
		return false
	if not _expect(is_zero_approx(boat.current_cargo_weight_kg) and is_equal_approx(boat.get_current_draft_m(), boat.draft_profile.empty_draft_m), "delivery updates cargo weight and calculated draft"):
		return false
	var duplicate: Dictionary = economy.deliver_contract(contract_id, copenhagen)
	if not _expect(not bool(duplicate.get("accepted", false)) and economy.get_balance_cents() == before_balance + 22000, "repeated delivery cannot credit a duplicate reward"):
		return false
	if not _expect(economy.load_state(absolute_test_path) and economy.get_balance_cents() == before_balance + 22000, "København completion and wallet restore from the test save"):
		return false
	DirAccess.remove_absolute(absolute_test_path)
	DirAccess.remove_absolute(absolute_test_path + ".bak")
	return true


func _expect(condition: bool, description: String) -> bool:
	if not condition:
		push_error("FAIL: %s" % description)
		quit(1)
		return false
	print("PASS: %s" % description)
	return true
