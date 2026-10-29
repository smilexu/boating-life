extends SceneTree
## Runtime smoke for the Main Nordic 28 Polar button, panel, dataset, and reef note.

const MAIN_SCENE := preload("res://scenes/main.tscn")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main := MAIN_SCENE.instantiate() as Node3D
	root.add_child(main)
	await process_frame
	await process_frame
	var boat := main.get_node_or_null("PlayerBoat")
	var controller := boat.get_node_or_null("MotionRoot") if boat != null else null
	var hud := boat.get_node_or_null("BoatHUD") if boat != null else null
	if controller == null or hud == null:
		_fail("Main scene did not create PlayerBoat controller and HUD")
		return
	if not bool(controller.call("set_sailing_enabled", true)):
		_fail("Main could not activate Nordic 28 for the UI smoke")
		return
	await process_frame
	await process_frame
	var open_button := hud.find_child("OpenNordic28Polar", true, false) as Button
	var polar_panel := hud.get_node_or_null("Nordic28PolarPanel") as Control
	var chart := hud.get_node_or_null("Nordic28PolarPanel/PolarPanelContent/Nordic28PolarChart") as Control
	var detail := hud.get_node_or_null("Nordic28PolarPanel/PolarPanelContent/Nordic28PolarCurrentState") as Label
	if open_button == null or polar_panel == null or chart == null or detail == null:
		_fail("Polar button, panel, chart, or state label is missing")
		return
	var dataset_validation: Dictionary = chart.call("get_dataset_validation")
	if not bool(dataset_validation.get("valid", false)) or int(dataset_validation.get("measurement_count", 0)) != 95:
		_fail("Polar JSON did not validate as the complete 95-point dataset: %s" % JSON.stringify(dataset_validation))
		return
	open_button.emit_signal("pressed")
	await process_frame
	if not polar_panel.visible:
		_fail("Polar button did not open the panel while Nordic 28 was active")
		return
	chart.call("set_current_state", {
		"true_wind_valid": true,
		"true_wind_speed_mps": 5.0,
		"true_wind_from_relative_degrees": -70.0,
		"sog_knots": 2.4,
		"sail_deployment": {"main_current_deployment": 0.8, "jib_current_deployment": 0.5},
	})
	var displayed_detail: String = str(chart.call("get_current_detail_text"))
	if not displayed_detail.contains("当前已缩帆") or not displayed_detail.contains("主帆 80% / 前帆 50%"):
		_fail("Reef/full-sail reference note or live deployment details are missing: %s" % displayed_detail)
		return
	await process_frame
	var close_button := hud.find_child("CloseNordic28Polar", true, false) as Button
	if close_button == null:
		_fail("Polar close button is missing")
		return
	close_button.emit_signal("pressed")
	await process_frame
	if polar_panel.visible:
		_fail("Polar close button did not dismiss the panel")
		return
	print("Nordic 28 Polar Main UI smoke passed · %s" % JSON.stringify(dataset_validation))
	main.queue_free()
	await process_frame
	quit(0)


func _fail(message: String) -> void:
	push_error("Nordic 28 Polar UI smoke failed: " + message)
	quit(1)
