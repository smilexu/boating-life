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
		_expect(int(lab.call("get_camera_mode")) == 2, "second C selects underwater inspection mode")
		lab.call("_input", event)
		_expect(bool(lab.call("is_camera_follow_enabled")), "third C returns to smooth follow mode")
		var follow_start_x := camera.global_position.x
		boat.global_position += Vector3(5.0, 0.0, 0.0)
		await process_frame
		lab.call("_process", 0.5)
		_expect(camera.global_position.x > follow_start_x + 3.5, "follow mode smoothly relocates the camera with the boat")
		var camera_transform_before_drag := camera.global_transform
		var boat_transform_before_drag := boat.global_transform
		var boat_velocity_before_drag := boat.linear_velocity
		var follow_yaw_before_drag := float(lab.get("_follow_orbit_yaw_rad"))
		var viewport_size := lab.get_viewport().get_visible_rect().size
		var right_press := InputEventMouseButton.new()
		right_press.button_index = MOUSE_BUTTON_RIGHT
		right_press.pressed = true
		right_press.position = viewport_size * Vector2(0.55, 0.68)
		lab.call("_input", right_press)
		var follow_motion := InputEventMouseMotion.new()
		follow_motion.position = right_press.position + Vector2(80.0, -25.0)
		follow_motion.relative = Vector2(80.0, -25.0)
		lab.call("_input", follow_motion)
		lab.call("_process", 1.0)
		_expect(not is_equal_approx(float(lab.get("_follow_orbit_yaw_rad")), follow_yaw_before_drag), "holding right mouse and dragging rotates the follow-camera orbit")
		_expect(not camera.global_transform.is_equal_approx(camera_transform_before_drag), "follow camera updates its observation angle after right-drag")
		_expect(boat.global_transform.is_equal_approx(boat_transform_before_drag) and boat.linear_velocity.is_equal_approx(boat_velocity_before_drag), "right-drag camera orbit leaves boat transform and velocity unchanged")
		var right_release := InputEventMouseButton.new()
		right_release.button_index = MOUSE_BUTTON_RIGHT
		right_release.pressed = false
		right_release.position = follow_motion.position
		lab.call("_input", right_release)
		var debug_content := lab.get_node("DebugPanel").find_child("SailboatLabDebugPanelContent", true, false) as Control
		if debug_content != null:
			var panel_yaw_before_drag := float(lab.get("_follow_orbit_yaw_rad"))
			var panel_press := InputEventMouseButton.new()
			panel_press.button_index = MOUSE_BUTTON_RIGHT
			panel_press.pressed = true
			panel_press.position = debug_content.get_global_rect().get_center()
			lab.call("_input", panel_press)
			var panel_motion := InputEventMouseMotion.new()
			panel_motion.position = panel_press.position + Vector2(60.0, 20.0)
			panel_motion.relative = Vector2(60.0, 20.0)
			lab.call("_input", panel_motion)
			_expect(is_equal_approx(float(lab.get("_follow_orbit_yaw_rad")), panel_yaw_before_drag), "right-drag starting over the debug panel does not rotate the camera")
			var panel_release := InputEventMouseButton.new()
			panel_release.button_index = MOUSE_BUTTON_RIGHT
			panel_release.pressed = false
			panel_release.position = panel_motion.position
			lab.call("_input", panel_release)
		var direction_controls := debug_content.find_child("WindDirectionControls", true, false) as VBoxContainer if debug_content != null else null
		var strength_controls := debug_content.find_child("WindStrengthControls", true, false) as VBoxContainer if debug_content != null else null
		var wind_speed := debug_content.find_child("LabWindSpeed", true, false) as HSlider if debug_content != null else null
		var wind_field := lab.get_node("WindField") as WindField
		_expect(direction_controls != null and strength_controls != null and direction_controls.get_parent() == strength_controls.get_parent() and direction_controls.get_parent() is HBoxContainer, "wind direction presets and wind strength are separate adjacent controls")
		_expect(wind_speed != null, "SailboatLab exposes an independent wind-strength slider")
		if wind_speed != null:
			wind_speed.value = 8.0
			_expect(is_equal_approx(wind_field.mean_wind_speed_mps, 8.0), "wind-strength slider sets speed without changing the selected direction")
		var port_wind_button := debug_content.find_child("WindFrom270", true, false) as Button if debug_content != null else null
		if port_wind_button != null:
			port_wind_button.emit_signal("pressed")
			_expect(is_equal_approx(wind_field.mean_wind_speed_mps, 8.0) and is_equal_approx(wind_field.mean_wind_from_degrees, 270.0), "direction preset changes direction while preserving selected wind strength")
		if wind_speed != null:
			wind_speed.value = 12.0
			_expect(is_equal_approx(wind_field.mean_wind_speed_mps, 12.0) and is_equal_approx(wind_field.mean_wind_from_degrees, 270.0), "changing wind strength preserves the selected direction")

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
