extends SceneTree

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		_fail("main.tscn failed to load")
		return
	var main := packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	var harbor := main.get_node_or_null("MalmoHarbor") as Node
	var service_ui := main.get_node_or_null("MalmoHarbor/PortServiceController") as PortServiceController
	var boat := main.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	if harbor == null or service_ui == null or boat == null:
		_fail("Phase 3 harbour, service controller, or boat is missing")
		return

	var config := harbor.call("get_service_config") as PortServiceConfig
	_expect(config != null and config.port_id == &"malmo_greybox_v1", "Malmö service definition is provided as port data")
	_expect(config.display_name == "Malmö", "service menu uses the configured port display name")
	_expect(config.available_services.size() == 4, "all four configured service entry points are present")
	_expect(service_ui.get_state_name() == "SAILING" and not service_ui.get_menu_visible(), "service UI begins hidden in sailing state")

	var config_b := PortServiceConfig.new()
	config_b.port_id = &"test_port"
	config_b.display_name = "Test Port"
	config_b.available_services = PackedStringArray(["fuel"])
	config_b.service_display_names = {"fuel": "Fuel Stop"}
	config_b.service_availability = {"fuel": true}
	_expect(config_b.get_service_display_name("fuel") == "Fuel Stop" and config_b.is_service_available("fuel"), "a different port can provide its own names and availability")

	var location: Dictionary = harbor.call("get_port_configuration")
	boat.global_position = location["berth_position"]
	boat.global_rotation.y = deg_to_rad(float(location["berth_heading_degrees"]))
	boat.speed_mps = 0.0
	boat.is_motion_paused = false
	_expect(bool(harbor.call("request_dock")), "valid berth conditions allow docking")
	_expect(bool(harbor.call("is_docked")) and boat.is_port_docked, "docking enters DOCKED and locks vessel controls")
	_expect(service_ui.get_state_name() == "PORT_MENU" and service_ui.get_menu_visible(), "successful docking opens the port menu")
	_expect(boat.is_motion_paused and is_zero_approx(boat.speed_mps), "docked vessel remains stationary")
	var docked_position := boat.global_position
	boat.speed_mps = 7.0
	boat.is_motion_paused = false
	boat._process(1.0)
	_expect(is_zero_approx(boat.speed_mps) and boat.is_motion_paused and boat.global_position.is_equal_approx(docked_position), "docked controls cannot restart propulsion or move the boat")

	var interact := InputEventAction.new()
	interact.action = "port_interact"
	interact.pressed = true
	harbor.call("_unhandled_input", interact)
	_expect(bool(harbor.call("is_docked")) and service_ui.is_menu_open(), "E interaction while menu is open cannot undock")

	_expect(service_ui.open_service("cargo_exchange"), "cargo exchange page opens")
	_expect(service_ui.get_current_service_id() == "cargo_exchange", "selected service page is tracked")
	for service_id in ["fuel", "shipyard", "ship_market"]:
		_expect(service_ui.open_service(service_id), "%s page opens" % service_id)
		service_ui.return_to_main_menu()
	service_ui.open_service("cargo_exchange")
	service_ui._unhandled_key_input(_key_event(KEY_ESCAPE))
	_expect(service_ui.get_state_name() == "PORT_MENU" and service_ui.get_current_service_id().is_empty(), "Escape from a service page returns to the main menu")
	service_ui._unhandled_key_input(_key_event(KEY_ESCAPE))
	_expect(service_ui.get_state_name() == "DOCKED" and bool(harbor.call("is_docked")), "Escape from the main menu closes UI but keeps the vessel docked")
	_expect(not service_ui.get_menu_visible() and boat.is_port_docked, "closed menu keeps port UI hidden and controls locked")

	var open_services := InputEventAction.new()
	open_services.action = "port_open_services"
	open_services.pressed = true
	harbor.call("_unhandled_input", open_services)
	_expect(service_ui.get_state_name() == "PORT_MENU", "F interaction reopens services while docked")
	service_ui.close_menu()
	_expect(service_ui.get_state_name() == "DOCKED", "close button returns to docked state")

	# The E compatibility path still undocks once the menu has been closed.
	harbor.call("_unhandled_input", interact)
	_expect(not bool(harbor.call("is_docked")) and not boat.is_port_docked, "E undocks after the menu is closed")
	_expect(service_ui.get_state_name() == "SAILING" and not service_ui.get_menu_visible(), "undocking hides the menu and restores sailing state")

	# Repeated cycles reuse the one scene controller and do not duplicate overlays.
	for _cycle in range(3):
		boat.global_position = location["berth_position"]
		boat.global_rotation.y = deg_to_rad(float(location["berth_heading_degrees"]))
		boat.speed_mps = 0.0
		boat.is_motion_paused = false
		_expect(bool(harbor.call("request_dock")), "repeat docking succeeds")
		_expect(bool(harbor.call("request_undock")), "repeat undocking succeeds")
	var service_controller_count := 0
	for child in harbor.get_children():
		if child is PortServiceController:
			service_controller_count += 1
	_expect(service_controller_count == 1 and harbor.get_node_or_null("PortServiceController") == service_ui, "repeated docking reuses a single service controller instance")
	_expect(not service_ui.is_docked(), "port services cannot be used after leaving")

	main.queue_free()
	await process_frame
	if _failures == 0:
		print("Port service checks passed.")
		quit(0)
	else:
		push_error("Port service checks failed: %d" % _failures)
		quit(1)


func _key_event(key: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = key
	event.physical_keycode = key
	event.pressed = true
	return event


func _expect(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		_failures += 1
		push_error("FAIL: %s" % description)


func _fail(message: String) -> void:
	_failures += 1
	push_error(message)
	quit(1)
