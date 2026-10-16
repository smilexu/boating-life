extends SceneTree

const TEST_SCENE := preload("res://scenes/ShallowWaterTest.tscn")
const OUTPUT_DIRECTORY := "res://docs/shallow_water_validation"


func _initialize() -> void:
	call_deferred("_run_captures")


func _run_captures() -> void:
	var directory_path := ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	DirAccess.make_dir_recursive_absolute(directory_path)
	var test_root := TEST_SCENE.instantiate()
	root.add_child(test_root)
	current_scene = test_root
	await process_frame
	await process_frame
	var controller: Node = test_root.get_node("ShallowWaterTestController")
	await _capture_state(controller, 2, false, 0, false, false, "01_oblique_opaque_baseline")
	await _capture_state(controller, 2, true, 0, false, false, "02_oblique_shallow_always")
	await _capture_state(controller, 1, true, 0, false, false, "03_top_down_shallow_always")
	await _capture_state(controller, 1, true, 0, true, false, "04_top_down_transmission_mask")
	await _capture_state(controller, 2, true, 1, false, false, "05_oblique_shallow_prepass_alpha")
	await _capture_state(controller, 2, true, 2, false, false, "06_oblique_shallow_depth_never")
	await _capture_state(controller, 2, true, 0, false, true, "07_night_shallow_always")
	test_root.queue_free()
	await process_frame
	quit()


func _capture_state(
	controller: Node,
	camera_preset: int,
	transparency_enabled: bool,
	depth_mode: int,
	mask_enabled: bool,
	night: bool,
	file_stem: String
) -> void:
	controller.call("select_camera_preset", camera_preset)
	controller.call("set_test_transparency", transparency_enabled)
	controller.call("set_test_depth_draw_mode", depth_mode)
	controller.call("set_test_mask_visible", mask_enabled)
	controller.call("set_test_time_of_day", night)
	await process_frame
	await process_frame
	await create_timer(1.0).timeout
	var image := root.get_texture().get_image()
	var output_path := ProjectSettings.globalize_path(OUTPUT_DIRECTORY.path_join(file_stem + ".png"))
	var result := image.save_png(output_path)
	if result != OK:
		push_error("Could not save shallow-water capture %s (error %d)." % [output_path, result])
	else:
		print("Saved shallow-water capture: %s (%dx%d)" % [output_path, image.get_width(), image.get_height()])
