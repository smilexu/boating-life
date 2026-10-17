extends SceneTree

var _failures := 0
const TEST_SAVE_PATH := "user://phase4b1_freight_test.json"
const CONTRACT_A := "malmo_copenhagen_spare_parts_a"
const CONTRACT_B := "malmo_copenhagen_provisions_b"
const CONTRACT_C := "malmo_copenhagen_building_materials_c"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		_fail("main scene failed to load")
		return
	var main := packed.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var manager := main.get_node_or_null("CargoEconomyManager") as CargoEconomyManager
	var harbor := main.get_node_or_null("MalmoHarbor") as Node
	var boat := main.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	var loadout := main.get_node_or_null("PlayerBoat/MotionRoot/CargoLoadout") as CargoLoadoutController
	var service := main.get_node_or_null("MalmoHarbor/PortServiceController") as PortServiceController
	var boat_hud := main.get_node_or_null("PlayerBoat/BoatHUD") as CanvasLayer
	if manager == null or harbor == null or boat == null or loadout == null or service == null:
		_fail("main scene is missing freight economy, harbour, boat, loadout or service UI")
		return
	# The project may have a real developer save from prior manual testing. Switch
	# to this test's isolated save and reset only the in-memory test world before
	# asserting a fresh wallet; never treat the developer save as an empty fixture.
	_expect(manager.set_save_path_override_for_testing(TEST_SAVE_PATH), "tests can isolate their save file")
	_expect(manager.reset_runtime_state_for_testing(), "developer test state resets cleanly")
	_expect(manager.get_balance_cents() == 50000, "new local wallet starts at exactly €500.00")
	_expect(manager.get_available_contracts("malmo_greybox_v1").size() == 3, "Malmö cargo exchange reads the three configured fixed offers")
	_expect(manager.get_available_contracts("somewhere_else").is_empty(), "offers are only available at their configured origin")
	var definition_a := manager.get_contract_definition(CONTRACT_A)
	var definition_b := manager.get_contract_definition(CONTRACT_B)
	var definition_c := manager.get_contract_definition(CONTRACT_C)
	_expect(definition_a.total_weight_kg == 180.0 and definition_a.required_space == 1 and definition_a.reward_cents == 22000, "contract A config matches the agreed 180 kg / 1 space / €220 values")
	_expect(definition_b.total_weight_kg == 120.0 and definition_b.required_space == 1 and definition_b.reward_cents == 18000, "contract B config matches the agreed 120 kg / 1 space / €180 values")
	_expect(definition_c.total_weight_kg == 450.0 and definition_c.required_space == 2 and definition_c.reward_cents == 42000, "contract C config matches the agreed 450 kg / 2 spaces / €420 values")
	_expect(manager.get_port_display_name("kobenhavn_test") == "København", "port display names come from configured port/contract data")
	var result := manager.accept_contract(CONTRACT_A, harbor)
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "wrong_origin", "acceptance is rejected unless the player is docked at the origin")
	var port_configuration: Dictionary = harbor.call("get_port_configuration")
	boat.global_position = port_configuration["berth_position"]
	boat.global_rotation.y = deg_to_rad(float(port_configuration["berth_heading_degrees"]))
	boat.speed_mps = 0.0
	boat.is_motion_paused = false
	_expect(bool(harbor.call("request_dock")), "test player docks at configured Malmö berth")
	_expect(service.open_service("cargo_exchange"), "cargo service page opens from the docked port menu")
	_expect(_count_buttons_with_text(service, "接受并装货") == 3, "exchange UI renders all three available offers with accept actions")
	var original_port_id := str(harbor.get("port_id"))
	var original_port_id_variant: Variant = harbor.get("port_id")
	harbor.set("port_id", "unrelated_test_port")
	result = manager.accept_contract(CONTRACT_A, harbor)
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "wrong_origin", "a different docked port cannot accept Malmö-origin freight")
	harbor.set("port_id", original_port_id_variant)
	_expect(str(harbor.get("port_id")) == original_port_id, "test restores the harbour's configured port ID")
	_expect(manager.set_save_path_override_for_testing("user://freight_missing_test_directory/state.json"), "test can force a storage error without touching project files")
	result = manager.accept_contract(CONTRACT_A, harbor)
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "save_failed", "failed persistence rolls the acceptance transaction back")
	_expect(loadout.get_cargo_instances_snapshot().is_empty() and str(manager.get_contract_state(CONTRACT_A).get("status", "")) == "AVAILABLE", "save failure leaves neither contract nor cargo half-committed")
	manager.set_save_path_override_for_testing(TEST_SAVE_PATH)

	var empty_draft := boat.get_current_draft_m()
	result = manager.accept_contract(CONTRACT_A, harbor)
	_expect(bool(result.get("accepted", false)), "Malmö accepts contract A and loads it atomically")
	_expect(str(manager.get_contract_state(CONTRACT_A).get("status", "")) == "IN_TRANSIT", "accepted and loaded contract enters IN_TRANSIT")
	_expect(loadout.get_used_space_units() == 1 and is_equal_approx(loadout.get_total_weight_kg(), 180.0), "contract A records one space and 180 kg")
	if boat_hud != null:
		boat_hud.call("_update_status")
	var task_hud := boat_hud.find_child("CargoTaskStatus", true, false) as Label if boat_hud != null else null
	_expect(task_hud != null and task_hud.text.contains("København"), "normal sailing HUD shows active task destination and cargo space")
	_expect(int(loadout.get_debug_snapshot().get("visible_container_count", 0)) == 1, "contract A mounts its standard cargo visual")
	result = loadout.try_unload_last_cargo()
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "contract_cargo_requires_delivery", "contract cargo cannot be manually detached from its task association")
	_expect(boat.get_current_draft_m() > empty_draft, "contract cargo updates the shared vessel draft profile")
	result = manager.accept_contract(CONTRACT_A, harbor)
	_expect(not bool(result.get("accepted", true)), "a contract cannot be accepted twice")
	result = manager.accept_contract(CONTRACT_B, harbor)
	_expect(bool(result.get("accepted", false)), "contract B can be accepted alongside A")
	_expect(loadout.get_used_space_units() == 2 and is_equal_approx(loadout.get_total_weight_kg(), 300.0), "A and B share the two slots and total 300 kg")
	result = manager.accept_contract(CONTRACT_C, harbor)
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "contract_limit", "a third simultaneous contract is rejected by the limit")
	result = manager.accept_contract(CONTRACT_A, harbor)
	_expect(not bool(result.get("accepted", true)), "duplicate acceptance remains rejected after other contracts are active")
	result = manager.deliver_contract(CONTRACT_A, harbor)
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "wrong_destination", "Malmö cannot deliver a contract addressed to Copenhagen")
	var original_capacity := boat.draft_profile.cargo_capacity_space_units
	boat.draft_profile.cargo_capacity_space_units = 1
	result = manager.accept_contract(CONTRACT_C, harbor)
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "contract_limit", "the active-contract limit is checked before any cargo mutation")
	boat.draft_profile.cargo_capacity_space_units = original_capacity

	_expect(manager.reset_runtime_state_for_testing(), "test state resets to exercise two-slot job C")
	boat.draft_profile.cargo_capacity_space_units = 1
	result = manager.accept_contract(CONTRACT_C, harbor)
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "space_limit", "contract C is rejected when only one cargo space is available")
	boat.draft_profile.cargo_capacity_space_units = original_capacity
	var original_weight_capacity := boat.draft_profile.max_cargo_weight_kg
	boat.draft_profile.max_cargo_weight_kg = 400.0
	result = manager.accept_contract(CONTRACT_C, harbor)
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "weight_limit", "contract C is rejected when remaining payload is below 450 kg")
	boat.draft_profile.max_cargo_weight_kg = original_weight_capacity
	result = manager.accept_contract(CONTRACT_C, harbor)
	_expect(bool(result.get("accepted", false)), "contract C fits as a two-space 450 kg shipment")
	_expect(loadout.get_used_space_units() == 2 and is_equal_approx(loadout.get_total_weight_kg(), 450.0), "contract C fills both slots using two unique cargo instances")
	_expect(int(loadout.get_debug_snapshot().get("visible_container_count", 0)) == 2, "contract C shows two standard containers")
	_expect(loadout.get_contract_cargo_instances(CONTRACT_C)[0].get("cargo_item_id", "") != loadout.get_contract_cargo_instances(CONTRACT_C)[1].get("cargo_item_id", ""), "contract C uses distinct cargo item IDs for its two containers")
	_expect(loadout.get_cargo_instances_snapshot()[0].get("assigned_slot_id", "") != loadout.get_cargo_instances_snapshot()[1].get("assigned_slot_id", ""), "each cargo instance persists its own distinct slot ID")
	var current_draft := boat.get_current_draft_m()
	_expect(current_draft > empty_draft, "450 kg load changes the current computed draft")
	var c_slot_ids: Array[String] = []
	for cargo_entry in loadout.get_contract_cargo_instances(CONTRACT_C):
		c_slot_ids.append(str(cargo_entry.get("assigned_slot_id", "")))
	_expect(manager.save_state(TEST_SAVE_PATH), "two-space contract C saves both cargo instances")
	_expect(manager.reset_runtime_state_for_testing() and manager.load_state(TEST_SAVE_PATH), "two-space manifest reloads from a clean boat")
	var restored_cargo := loadout.get_contract_cargo_instances(CONTRACT_C)
	_expect(restored_cargo.size() == 2 and restored_cargo[0].get("assigned_slot_id", "") != restored_cargo[1].get("assigned_slot_id", ""), "restored cargo retains the two distinct Cargo Slot assignments")
	_expect(c_slot_ids.size() == 2 and restored_cargo[0].get("assigned_slot_id", "") == c_slot_ids[0] and restored_cargo[1].get("assigned_slot_id", "") == c_slot_ids[1], "restore preserves the exact saved cargo-to-slot mapping")
	_expect(loadout.get_used_space_units() == 2 and is_equal_approx(loadout.get_total_weight_kg(), 450.0), "restored manifest recomputes space and weight without duplicating cargo")

	_expect(manager.reset_runtime_state_for_testing(), "state resets before delivery checks")
	result = manager.accept_contract(CONTRACT_A, harbor)
	_expect(bool(result.get("accepted", false)), "test shipment A is loaded")
	result = loadout.remove_contract_cargo(CONTRACT_A)
	_expect(bool(result.get("accepted", false)), "test can remove the associated contract cargo")
	result = manager.simulate_delivery_for_development(CONTRACT_A)
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "cargo_missing_or_mismatched", "delivery rejects missing contract cargo")
	_expect(manager.reset_runtime_state_for_testing(), "state resets before save and successful settlement checks")
	result = manager.accept_contract(CONTRACT_A, harbor)
	_expect(bool(result.get("accepted", false)), "test shipment A loads for save restoration")
	_expect(manager.save_state(TEST_SAVE_PATH), "versioned freight snapshot writes to the isolated test save")
	_expect(manager.reset_runtime_state_for_testing(), "runtime state can be cleared before reload")
	_expect(manager.load_state(TEST_SAVE_PATH), "versioned save reloads after restart-style reset")
	_expect(str(manager.get_contract_state(CONTRACT_A).get("status", "")) == "IN_TRANSIT", "reloaded contract status is preserved")
	_expect(loadout.get_cargo_instances_snapshot().size() == 1 and int(loadout.get_debug_snapshot().get("visible_container_count", 0)) == 1, "reload restores the cargo ID, slot assignment and visible container")
	_expect(is_equal_approx(boat.current_cargo_weight_kg, 180.0), "reload recomputes boat weight and draft from cargo instances")
	var actual_docked_before_simulation := bool(harbor.call("is_docked"))
	var actual_port_before_simulation := str(harbor.get("port_id"))
	harbor.set("_debug_enabled", true)
	harbor.call("_update_debug_label", harbor.call("get_docking_diagnostics"))
	var dev_delivery_button := harbor.find_child("SimulateDeliveryButton", true, false) as Button
	_expect(dev_delivery_button != null and dev_delivery_button.visible, "O diagnostic panel exposes the developer delivery simulation for an active task")
	if dev_delivery_button != null:
		dev_delivery_button.pressed.emit()
	_expect(manager.get_balance_cents() == 72000 and str(manager.get_contract_state(CONTRACT_A).get("status", "")) == "COMPLETED", "diagnostic action reuses the official delivery and settlement path")
	_expect(str(harbor.get("port_id")) == actual_port_before_simulation and bool(harbor.call("is_docked")) == actual_docked_before_simulation, "synthetic delivery leaves the real harbour location and docking state untouched")
	_expect(manager.get_balance_cents() == 72000 and manager.get_balance_text() == "€720.00", "contract A credits exactly €220.00 in integer cents")
	_expect(loadout.get_cargo_instances_snapshot().is_empty() and is_zero_approx(boat.current_cargo_weight_kg), "delivery unloads only associated contract cargo and updates draft")
	result = manager.simulate_delivery_for_development(CONTRACT_A)
	_expect(not bool(result.get("accepted", true)) and manager.get_balance_cents() == 72000, "settled contract cannot pay a duplicate reward")
	_expect(manager.reset_runtime_state_for_testing(), "state resets before completed-save restore test")
	_expect(manager.load_state(TEST_SAVE_PATH), "completed settlement reloads from the versioned snapshot")
	_expect(manager.get_balance_cents() == 72000 and str(manager.get_contract_state(CONTRACT_A).get("status", "")) == "COMPLETED", "completed state and wallet balance survive reload")
	result = manager.simulate_delivery_for_development(CONTRACT_A)
	_expect(not bool(result.get("accepted", true)) and manager.get_balance_cents() == 72000, "reloaded completed contracts remain idempotent")

	var corrupt_file := FileAccess.open(TEST_SAVE_PATH, FileAccess.WRITE)
	corrupt_file.store_string("{")
	corrupt_file.close()
	var balance_before_bad_load := manager.get_balance_cents()
	_expect(not manager.load_state(TEST_SAVE_PATH), "malformed JSON save is rejected without crashing")
	_expect(manager.get_balance_cents() == balance_before_bad_load, "invalid save does not partially overwrite the live wallet")
	corrupt_file = FileAccess.open(TEST_SAVE_PATH, FileAccess.WRITE)
	corrupt_file.store_string("{\"save_format\":\"cargo_economy_state\",\"schema_version\":1,\"currency\":\"EUR\",\"wallet_balance_cents\":300000}")
	corrupt_file.close()
	_expect(not manager.load_state(TEST_SAVE_PATH), "incomplete but parseable save is rejected")
	_expect(manager.get_balance_cents() == balance_before_bad_load, "incomplete save cannot partially overwrite the wallet")

	_expect(manager.reset_runtime_state_for_testing(), "runtime returns to a clean state after malformed-save check")
	_expect(bool(harbor.call("request_undock")), "harbour undocking still works after economy transactions")
	main.queue_free()
	await process_frame
	_remove_test_save_files()
	if _failures == 0:
		print("Freight economy checks passed.")
		quit(0)
	else:
		push_error("Freight economy checks failed: %d" % _failures)
		quit(1)


func _count_buttons_with_text(node: Node, button_text: String) -> int:
	var count := 0
	if node is Button and (node as Button).text == button_text:
		count += 1
	for child in node.get_children():
		count += _count_buttons_with_text(child, button_text)
	return count


func _remove_test_save_files() -> void:
	for suffix in ["", ".tmp", ".bak"]:
		var path := ProjectSettings.globalize_path(TEST_SAVE_PATH + suffix)
		if FileAccess.file_exists(TEST_SAVE_PATH + suffix):
			DirAccess.remove_absolute(path)


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
