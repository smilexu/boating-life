extends SceneTree

const LAB_PATH := "res://scenes/SailboatLab.tscn"
const EPSILON := 0.001

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene_error := change_scene_to_file(LAB_PATH)
	_expect(scene_error == OK, "test loads SailboatLab as the active scene")
	for _frame in range(10):
		if current_scene != null:
			break
		await process_frame
	var lab := current_scene as Node3D
	_expect(lab != null, "SailboatLab is active before testing its scene shortcuts")
	if lab != null:
		var boat := lab.get_node("SailboatBody") as RigidBody3D
		_expect(bool(lab.call("is_camera_follow_enabled")), "smooth follow is the scene-start camera mode")
		var event := InputEventKey.new()
		event.physical_keycode = KEY_C
		event.pressed = true
		lab.call("_input", event)
		_expect(not bool(lab.call("is_camera_follow_enabled")), "C switches to fixed observation mode")
		var camera := lab.get_node("Camera3D") as Camera3D
		var fixed_camera_position := camera.global_position
		boat.global_position += Vector3(5.0, 0.0, 0.0)
		await process_frame
		_expect(camera.global_position.is_equal_approx(fixed_camera_position), "fixed observation mode keeps the original camera position")
		lab.call("_input", event)
		_expect(bool(lab.call("is_camera_follow_enabled")), "C switches back to follow mode")
		var follow_start_x := camera.global_position.x
		boat.global_position += Vector3(5.0, 0.0, 0.0)
		await process_frame
		lab.call("_process", 0.5)
		_expect(camera.global_position.x > follow_start_x + 3.5, "follow mode smoothly relocates the camera with the boat")

		# Dirty several independent test controls, then use the actual Delete/Backspace input
		# path to confirm it reloads the whole scene instead of only the boat.
		boat.set("actual_sail_angle_rad", deg_to_rad(25.0))
		boat.set("actual_headsail_angle_rad", deg_to_rad(-20.0))
		boat.set("actual_rudder_angle_rad", deg_to_rad(15.0))
		boat.call("set_dynamic_waves_enabled", false)
		boat.call("set_lab_test_wind", 8.0, 270.0)
		lab.call("set_camera_follow_enabled", false)
		var old_id := lab.get_instance_id()
		var reset_event := InputEventKey.new()
		reset_event.physical_keycode = KEY_BACKSPACE
		reset_event.pressed = true
		lab.call("_input", reset_event)
		for _frame in range(10):
			await process_frame
			if current_scene != null and current_scene.get_instance_id() != old_id:
				break
		var reset_lab := current_scene as Node3D
		_expect(reset_lab != null and reset_lab.get_instance_id() != old_id, "Delete/Backspace reloads a new complete SailboatLab scene instance")
		if reset_lab != null and reset_lab.get_instance_id() != old_id:
			var reset_boat := reset_lab.get_node("SailboatBody") as RigidBody3D
			var reset_wind := reset_lab.get_node("WindField")
			_expect(bool(reset_lab.call("is_camera_follow_enabled")), "scene reload restores follow camera mode")
			_expect(bool(reset_boat.get("dynamic_waves_enabled")), "scene reload restores the original dynamic-wave toggle")
			_expect(absf(float(reset_wind.get("mean_wind_speed_mps"))) < EPSILON, "scene reload clears the local test-wind override")
			_expect(absf(float(reset_boat.get("actual_sail_angle_rad"))) < EPSILON, "scene reload restores mainsail trim")
			_expect(absf(float(reset_boat.get("actual_headsail_angle_rad"))) < EPSILON, "scene reload restores jib trim")
			_expect(absf(float(reset_boat.get("actual_rudder_angle_rad"))) < EPSILON, "scene reload restores neutral rudder")
	if _failures.is_empty():
		print("SailboatLab shortcut tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("FAIL: " + description)
		push_error("FAIL: " + description)
