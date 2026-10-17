extends SceneTree

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed_scene := load("res://scenes/main.tscn") as PackedScene
	if packed_scene == null:
		_fail("Could not load scenes/main.tscn")
		return
	var main_scene := packed_scene.instantiate()
	root.add_child(main_scene)
	await process_frame
	await process_frame

	var harbour := main_scene.get_node_or_null("MalmoHarbor") as Node
	var boat := main_scene.get_node_or_null("PlayerBoat/MotionRoot") as BoatController
	if harbour == null or boat == null:
		_fail("Main scene is missing MalmoHarbor or PlayerBoat/MotionRoot")
		return
	if not _expect(harbour.get_child_count() >= 25, "greybox structures were generated"):
		return

	var locations: Dictionary = harbour.call("get_port_configuration")
	var berth_position: Vector3 = locations["berth_position"]
	var approach_position: Vector3 = locations["approach_position"]
	var berth_heading := deg_to_rad(float(locations["berth_heading_degrees"]))
	boat.global_position = berth_position
	boat.global_rotation.y = berth_heading
	boat.speed_mps = 0.0
	boat.is_motion_paused = false
	var status: Dictionary = harbour.call("get_docking_diagnostics")
	if not _expect(bool(status.get("can_dock", false)), "aligned, stationary boat can dock"):
		return

	boat.speed_mps = 2.0
	status = harbour.call("get_docking_diagnostics")
	if not _expect(not bool(status.get("can_dock", false)) and not bool(status.get("speed_ok", true)), "high-speed boat is rejected"):
		return

	boat.speed_mps = 0.0
	boat.global_rotation.y = berth_heading + PI * 0.5
	status = harbour.call("get_docking_diagnostics")
	if not _expect(not bool(status.get("can_dock", false)) and not bool(status.get("heading_ok", true)), "misaligned boat is rejected"):
		return

	boat.global_rotation.y = berth_heading
	boat.global_position = berth_position + Vector3(18.0, 0.0, 0.0)
	status = harbour.call("get_docking_diagnostics")
	if not _expect(not bool(status.get("can_dock", false)) and not bool(status.get("position_ok", true)), "boat outside berth is rejected"):
		return

	boat.global_position = berth_position
	if not _expect(bool(harbour.call("request_dock")), "E-equivalent docking request succeeds"):
		return
	if not _expect(boat.is_motion_paused and is_zero_approx(boat.speed_mps), "docking stops the boat using existing pause state"):
		return
	if not _expect(bool(harbour.call("request_undock")) and not boat.is_motion_paused, "undocking restores motion"):
		return

	harbour.call("teleport_to_approach")
	if not _expect(boat.global_position.distance_to(approach_position) < 0.01, "P-equivalent debug relocation reaches approach point"):
		return
	main_scene.queue_free()
	await process_frame
	print("Malmo harbour greybox checks passed.")
	quit(0)


func _expect(condition: bool, description: String) -> bool:
	if not condition:
		push_error("FAIL: %s" % description)
		quit(1)
		return false
	print("PASS: %s" % description)
	return true


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
