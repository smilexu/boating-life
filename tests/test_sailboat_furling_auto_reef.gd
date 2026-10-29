extends SceneTree

const AUTO_REEF := preload("res://scripts/sailboat_auto_reef.gd")
const AERO := preload("res://scripts/sailboat_aero_math.gd")
const MAIN_SAIL_SCRIPT := preload("res://scripts/sail_triangle_visual.gd")
const JIB_SAIL_SCRIPT := preload("res://scripts/headsail_triangle_visual.gd")
const PROFILE := preload("res://resources/sailing/sailboat_lab_profile.tres")
const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_visual_geometry()
	_test_auto_reef_timing_and_staging()
	await _test_body_and_control_integration()
	if _failures.is_empty():
		print("Sailboat furling/AUTO Reef tests: %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_visual_geometry() -> void:
	var main_sail := MAIN_SAIL_SCRIPT.new() as MeshInstance3D
	root.add_child(main_sail)
	var main_head := Vector3(0.0, 8.0273, 0.0)
	var main_tack := Vector3.ZERO
	var main_clew := Vector3(0.0, 0.0, 4.4)
	main_sail.call("configure", main_head, main_tack, main_clew)
	await process_frame
	var main_full_area := AERO.triangular_sail_area_m2(main_head, main_tack, main_clew)
	for deployment in [0.0, 0.25, 0.5, 0.75, 1.0]:
		main_sail.call("set_deployment", deployment)
		var main_snapshot: Dictionary = main_sail.call("get_visual_snapshot")
		_expect(absf(float(main_snapshot.get("geometric_area_m2", -1.0)) - main_full_area * deployment) < 0.002, "main cloth geometry area matches its %.0f%% deployment" % (deployment * 100.0))
		if deployment == 0.0:
			_expect(bool(main_snapshot.get("furled_fabric_visible", false)), "main boom retains the rolled-cloth visual when the sail is fully furled")
	main_sail.queue_free()

	var jib_sail := JIB_SAIL_SCRIPT.new() as MeshInstance3D
	root.add_child(jib_sail)
	var jib_head := Vector3(0.0, 10.03, -1.0)
	var jib_tack := Vector3(0.0, 1.6614, -3.5498)
	var jib_clew := Vector3(0.0, 1.7686, -1.05)
	jib_sail.call("configure", jib_head, jib_tack, jib_clew)
	await process_frame
	var jib_full_area := AERO.triangular_sail_area_m2(jib_head, jib_tack, jib_clew)
	for deployment in [0.0, 0.25, 0.5, 0.75, 1.0]:
		jib_sail.call("set_deployment", deployment, 0.0)
		var jib_snapshot: Dictionary = jib_sail.call("get_visual_snapshot")
		_expect(absf(float(jib_snapshot.get("geometric_area_m2", -1.0)) - jib_full_area * deployment) < 0.002, "Jib cloth geometry area matches its %.0f%% deployment" % (deployment * 100.0))
		if deployment == 0.0:
			_expect(bool(jib_snapshot.get("furled_fabric_visible", false)), "Jib retains its furled-cloth visual at 0% deployment")
		if deployment > 0.0:
			var deployed_clew: Vector3 = jib_snapshot.get("last_clew_local_m", Vector3.ZERO)
			_expect(AERO.triangular_sail_area_m2(jib_head, jib_tack, deployed_clew) > 0.0, "partially deployed Jib remains a valid sail triangle")
	jib_sail.queue_free()


func _test_auto_reef_timing_and_staging() -> void:
	var controller = AUTO_REEF.new()
	controller.configure(PROFILE)
	controller.set_enabled(true, 0.0, 1.0, 1.0)
	var main_target := 1.0
	var jib_target := 1.0
	for _index in range(60 * 15):
		var result: Dictionary = controller.update(deg_to_rad(26.0), 1.0 / 60.0, main_target, jib_target, main_target, jib_target)
		main_target = float(result["main_target"])
		jib_target = float(result["jib_target"])
	_expect(main_target < 1.0 and is_equal_approx(jib_target, 1.0), "sustained 25–30° heel stages the first reef on the main sail")
	_expect(float(controller.get_snapshot().get("filtered_heel_deg", 0.0)) > 25.0, "AUTO Reef uses filtered actual heel rather than an instantaneous reading")

	controller.set_enabled(true, 0.0, 1.0, 1.0)
	main_target = 1.0
	jib_target = 1.0
	for _index in range(60 * 13):
		var result: Dictionary = controller.update(deg_to_rad(36.0), 1.0 / 60.0, main_target, jib_target, main_target, jib_target)
		main_target = float(result["main_target"])
		jib_target = float(result["jib_target"])
	_expect(main_target < 1.0 and jib_target < 1.0, "filtered heel above 35° immediately requests a strong two-sail reef")

	controller.set_enabled(true, 0.0, 0.5, 0.5)
	main_target = 0.5
	jib_target = 0.5
	for _index in range(60 * 24):
		var result: Dictionary = controller.update(0.0, 1.0 / 60.0, main_target, jib_target, main_target, jib_target)
		main_target = float(result["main_target"])
		jib_target = float(result["jib_target"])
	_expect(main_target > 0.5, "AUTO Reef only starts gradual re-expansion after the low-heel recovery delay")


func _test_body_and_control_integration() -> void:
	var lab := LAB_SCENE.instantiate()
	root.add_child(lab)
	await process_frame
	var boat := lab.get_node("SailboatBody") as RigidBody3D
	_expect(boat != null, "SailboatLab loads the shared production RigidBody")
	if boat == null:
		lab.queue_free()
		return
	boat.call("set_dynamic_waves_enabled", false)
	await physics_frame
	await physics_frame
	var navigation: Dictionary = boat.call("get_navigation_snapshot")
	var deployment: Dictionary = navigation.get("sail_deployment", {})
	_expect(is_equal_approx(float(deployment.get("main_current_deployment", 0.0)), 1.0), "new vessel starts with the main sail fully deployed")
	_expect(is_equal_approx(float(deployment.get("jib_current_deployment", 0.0)), 1.0), "new vessel starts with the Jib fully deployed")
	_expect(absf(float(deployment.get("main_effective_area_m2", 0.0)) - 17.66006) < 0.001, "100% main deployment preserves the P2.16 full-sail area")
	_expect(absf(float(deployment.get("jib_effective_area_m2", 0.0)) - 10.323244) < 0.001, "100% Jib deployment preserves the P2.16 full-sail area")
	_expect(int(boat.call("get_debug_snapshot").get("wind_query_count_per_tick", -1)) == 1, "furling adds no WindField queries")
	_expect(int(boat.call("get_debug_snapshot").get("wave_query_count_per_tick", -1)) == 0, "static-wave test mode keeps WaveSampler queries disabled")

	boat.call("set_main_sail_deployment_target", 0.5)
	boat.call("set_jib_deployment_target", 0.5)
	var old_main: float = boat.get("current_main_sail_deployment")
	var old_jib: float = boat.get("current_jib_deployment")
	await physics_frame
	var debug: Dictionary = boat.call("get_debug_snapshot")
	var step_seconds := float(debug.get("physics_delta_s", 1.0 / 60.0))
	var expected_delta := step_seconds / 15.0
	_expect(absf(float(boat.get("current_main_sail_deployment")) - (old_main - expected_delta)) < 0.0001, "main furling advances at the configured 15-second full-range rate")
	_expect(absf(float(boat.get("current_jib_deployment")) - (old_jib - expected_delta)) < 0.0001, "Jib furling advances at the same 15-second full-range rate")
	deployment = boat.call("get_sail_deployment_snapshot")
	_expect(absf(float(deployment.get("main_effective_area_m2", 0.0)) - 17.66006 * float(deployment.get("main_current_deployment", 0.0))) < 0.0001, "main physical area reads the same current deployment value")
	_expect(absf(float(deployment.get("jib_effective_area_m2", 0.0)) - 10.323244 * float(deployment.get("jib_current_deployment", 0.0))) < 0.0001, "Jib physical area reads the same current deployment value")
	var profile: Resource = boat.get("profile")
	var main_pc: Vector3 = deployment.get("main_pressure_center_local_m", Vector3.ZERO)
	var main_pc_from_pivot: Vector3 = profile.get("main_sail_pressure_center_from_pivot_m")
	var main_pivot: Vector3 = profile.get("main_sail_pivot_local_m")
	_expect(absf(main_pc.y - (main_pivot.y + main_pc_from_pivot.y * float(deployment.get("main_current_deployment", 0.0)))) < 0.0001, "reefed main pressure center descends with its visible head")
	_expect(absf(main_pc.z - (main_pivot.z + main_pc_from_pivot.z)) < 0.0001, "main pressure center remains above the fixed boom foot position")

	boat.call("set_auto_sail_trim_enabled", true)
	boat.call("set_auto_reef_enabled", true)
	_expect(bool(boat.get("auto_sail_trim_enabled")) and bool(boat.get("auto_reef_enabled")), "AUTO Trim and AUTO Reef can run independently")
	boat.call("set_target_rudder_angle", deg_to_rad(8.0))
	_expect(bool(boat.get("auto_reef_enabled")), "manual rudder/autopilot control does not disable AUTO Reef")
	var debug_panel := lab.get_node_or_null("DebugPanel")
	var main_slider := debug_panel.find_child("MainSailDeployment", true, false) as HSlider if debug_panel != null else null
	var jib_slider := debug_panel.find_child("JibDeployment", true, false) as HSlider if debug_panel != null else null
	var auto_reef_toggle := debug_panel.find_child("AutoReefToggle", true, false) as CheckButton if debug_panel != null else null
	_expect(main_slider != null and jib_slider != null and auto_reef_toggle != null, "SailboatLab F3 sail page exposes main, Jib and AUTO Reef controls")
	if main_slider != null and jib_slider != null and auto_reef_toggle != null:
		main_slider.value = 40.0
		_expect(not bool(boat.get("auto_reef_enabled")) and absf(float(boat.get("target_main_sail_deployment")) - 0.4) < 0.001, "moving the F3 main-sail slider sets its target and returns AUTO Reef to manual")
		jib_slider.value = 60.0
		_expect(absf(float(boat.get("target_jib_deployment")) - 0.6) < 0.001, "moving the F3 Jib slider sets an independent deployment target")
		auto_reef_toggle.button_pressed = true
		_expect(bool(boat.get("auto_reef_enabled")), "F3 AUTO Reef toggle enables heel-based automatic reefing")
	_expect(bool(boat.get("auto_sail_trim_enabled")), "manual furling does not switch AUTO Trim off")
	boat.call("set_dynamic_waves_enabled", true)
	lab.queue_free()
	await process_frame


func _expect(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
