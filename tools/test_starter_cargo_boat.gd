extends SceneTree

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var original_bytes := FileAccess.get_file_as_bytes("res://assets/boats/first_boat.glb").size()
	var optimized_bytes := FileAccess.get_file_as_bytes("res://assets/boats/first_boat_optimized.glb").size()
	_expect(original_bytes > optimized_bytes, "optimized GLB is smaller than the untouched source asset")
	var boat_model_scene := load("res://assets/boats/first_boat_optimized.glb") as PackedScene
	_expect(boat_model_scene != null, "optimized first_boat GLB imports as a PackedScene")
	if boat_model_scene != null:
		var model := boat_model_scene.instantiate()
		root.add_child(model)
		_expect(_count_triangles(model) == 50000, "optimized model preserves the source 50,000 triangles")
		model.queue_free()

	var main_scene := load("res://scenes/main.tscn") as PackedScene
	if main_scene == null:
		_fail("main.tscn failed to load")
		return
	var main := main_scene.instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	var boat := main.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	var loadout := main.get_node_or_null("PlayerBoat/MotionRoot/CargoLoadout") as CargoLoadoutController
	var harbor := main.get_node_or_null("MalmoHarbor")
	var monitor := main.get_node_or_null("NavigationDepthMonitor") as NavigationDepthMonitor
	if boat == null or loadout == null or harbor == null or monitor == null:
		_fail("main scene is missing the boat, cargo loadout, harbor, or depth monitor")
		return

	var profile := boat.draft_profile
	_expect(profile != null and profile.vessel_display_name == "StarterCargoBoat · 初始货运船", "formal StarterCargoBoat profile is assigned")
	_expect(profile.cargo_capacity_space_units == 2 and is_equal_approx(profile.max_cargo_weight_kg, 500.0), "vessel uses two cargo spaces and a distinct 500 kg maximum")
	_expect(is_equal_approx(boat.get_vessel_length_m(), 7.2) and is_equal_approx(boat.get_vessel_beam_m(), 2.555), "docking footprint reads the configured starter vessel dimensions")

	var visual_frame := main.get_node("PlayerBoat/MotionRoot/VisualRoot/BoatModelFrame") as Node3D
	_expect(visual_frame.transform.basis.x.normalized().dot(Vector3.FORWARD) > 0.999, "model bow axis is corrected to the vessel's -Z forward direction")
	var snapshot := loadout.get_debug_snapshot()
	var actual_dimensions: Vector3 = snapshot.get("model_dimensions_m", Vector3.ZERO)
	print("StarterCargoBoat measured imported bounds L×B×H = %.3f × %.3f × %.3f m" % [actual_dimensions.x, actual_dimensions.y, actual_dimensions.z])
	_expect(absf(actual_dimensions.x - 7.2) < 0.02, "model length is calibrated to approximately 7.2 m")
	_expect(absf(actual_dimensions.y - 2.55) < 0.02, "model beam follows uniform GLB scaling")
	_expect(absf(actual_dimensions.z - 3.83) < 0.03, "model height is measured from imported mesh bounds")
	_expect(int(snapshot.get("slot_count", 0)) == 2, "exactly two configured cargo slots are loaded")
	_expect(int(snapshot.get("visible_container_count", 0)) == 0, "empty vessel starts with no visible container")
	var slots := [
		main.get_node("PlayerBoat/MotionRoot/VisualRoot/CargoSlots/CargoSlot_01") as Marker3D,
		main.get_node("PlayerBoat/MotionRoot/VisualRoot/CargoSlots/CargoSlot_02") as Marker3D,
	]
	var visual_buoyancy := main.get_node("PlayerBoat/MotionRoot/VisualRoot")
	var model_frame := main.get_node("PlayerBoat/MotionRoot/VisualRoot/BoatModelFrame") as Node3D
	var cargo_slots_root := main.get_node("PlayerBoat/MotionRoot/VisualRoot/CargoSlots") as Node3D
	_expect(is_equal_approx(model_frame.position.y, -0.32), "empty visual hull is raised 0.40 m to reveal the side fenders")
	_expect(is_equal_approx(cargo_slots_root.position.y, 0.4), "cargo slots follow the raised hull baseline")
	_expect(is_zero_approx(float(visual_buoyancy.call("get_visual_cargo_sink_m"))), "empty boat has no cargo-induced visual sink")
	_expect(slots[1].position.z - slots[0].position.z > 1.0, "container slots have a positive deck gap")
	_expect(slots[0].position.y > 0.0 and slots[1].position.y > 0.0, "container slot bases sit above the motion waterline")

	var empty_draft := boat.get_current_draft_m()
	var result := loadout.set_debug_test_loadout(1)
	_expect(bool(result.get("accepted", false)), "one 200 kg test container loads")
	snapshot = loadout.get_debug_snapshot()
	_expect(int(snapshot.get("container_count", 0)) == 1 and int(snapshot.get("visible_container_count", 0)) == 1, "one loaded item displays exactly one container visual")
	_expect(int(snapshot.get("used_space_units", 0)) == 1 and is_equal_approx(boat.current_cargo_weight_kg, 200.0), "one container consumes one space and updates the authoritative boat load")
	var one_draft := boat.get_current_draft_m()
	_expect(one_draft > empty_draft, "one-container draft is greater than empty draft")
	_expect(is_equal_approx(float(visual_buoyancy.call("get_visual_cargo_sink_m")), one_draft - empty_draft), "one-container visual sink uses the same draft delta as navigation")

	result = loadout.set_debug_test_loadout(2)
	_expect(bool(result.get("accepted", false)), "two test containers fit the vessel")
	snapshot = loadout.get_debug_snapshot()
	_expect(int(snapshot.get("container_count", 0)) == 2 and int(snapshot.get("visible_container_count", 0)) == 2, "two loaded items display exactly two container visuals")
	_expect(int(snapshot.get("used_space_units", 0)) == 2 and is_equal_approx(boat.current_cargo_weight_kg, 400.0), "two containers use both cargo spaces and total 400 kg")
	var two_draft := boat.get_current_draft_m()
	_expect(two_draft > one_draft, "two-container draft is greater than one-container draft")
	_expect(is_equal_approx(float(visual_buoyancy.call("get_visual_cargo_sink_m")), two_draft - empty_draft), "two-container visual sink follows the authoritative loaded draft")
	monitor.refresh_now()
	_expect(is_equal_approx(float(monitor.get_snapshot().get("draft_m", -1.0)), two_draft), "navigation depth monitor uses the updated loaded draft")

	var oversized_item := CargoItemDefinition.new()
	oversized_item.cargo_id = &"test_too_large"
	oversized_item.display_name = "超空间货物"
	oversized_item.weight_kg = 50.0
	oversized_item.space_units = 1
	oversized_item.visual_asset_id = &"none"
	result = loadout.try_load_cargo(oversized_item)
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "space_limit", "space over-capacity item is rejected")
	var overweight_item := CargoItemDefinition.new()
	overweight_item.cargo_id = &"test_overweight"
	overweight_item.display_name = "超重货物"
	overweight_item.weight_kg = 600.0
	overweight_item.space_units = 1
	overweight_item.visual_asset_id = &"none"
	loadout.set_debug_test_loadout(0)
	result = loadout.try_load_cargo(overweight_item)
	_expect(not bool(result.get("accepted", true)) and str(result.get("code", "")) == "weight_limit", "cargo exceeding maximum weight is rejected")
	_expect(is_zero_approx(boat.current_cargo_weight_kg), "rejected cargo does not alter vessel cargo weight")

	loadout.set_debug_test_loadout(0)
	var harbor_config: Dictionary = harbor.call("get_port_configuration")
	boat.global_position = harbor_config["berth_position"]
	boat.global_rotation.y = deg_to_rad(float(harbor_config["berth_heading_degrees"]))
	boat.speed_mps = 0.0
	boat.is_motion_paused = false
	_expect(bool(harbor.call("request_dock")), "starter cargo boat retains Malmö docking")
	_expect(bool(harbor.call("request_undock")), "starter cargo boat retains Malmö undocking")

	# Exercise the same F12 action that the developer key uses in the running scene.
	var f12 := InputEventKey.new()
	f12.keycode = KEY_F12
	f12.physical_keycode = KEY_F12
	f12.pressed = true
	loadout._unhandled_key_input(f12)
	_expect(is_equal_approx(boat.current_cargo_weight_kg, 200.0), "F12 test action advances empty vessel to one container")
	loadout._unhandled_key_input(f12)
	_expect(is_equal_approx(boat.current_cargo_weight_kg, 400.0), "F12 test action advances to two containers")
	loadout._unhandled_key_input(f12)
	_expect(is_zero_approx(boat.current_cargo_weight_kg) and int(loadout.get_debug_snapshot().get("visible_container_count", 0)) == 0, "F12 wraps back to empty without residual visuals")

	main.queue_free()
	await process_frame
	if _failures == 0:
		print("Starter cargo boat checks passed.")
		quit(0)
	else:
		push_error("Starter cargo boat checks failed: %d" % _failures)
		quit(1)


func _count_triangles(node: Node) -> int:
	var total := 0
	if node is MeshInstance3D:
		var mesh := (node as MeshInstance3D).mesh
		if mesh != null:
			for surface_index in range(mesh.get_surface_count()):
				var arrays := mesh.surface_get_arrays(surface_index)
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				total += (indices.size() if not indices.is_empty() else vertices.size()) / 3
	for child in node.get_children():
		total += _count_triangles(child)
	return total


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
