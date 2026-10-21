extends SceneTree

const GEOREFERENCE := preload("res://resources/oresund_georeference.tres")
const BASE_WAVES := preload("res://resources/sea_waves.tres")
const WATER_MATERIAL := preload("res://materials/sea_water_material.tres")
const MAIN_SCENE := preload("res://scenes/main.tscn")

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_depth_scale_curve()
	await _test_shared_bathymetry_sample()
	await _test_f3_controls()
	if _failures.is_empty():
		print("ShallowWaveConstraint tests: all %d checks passed." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_depth_scale_curve() -> void:
	var expected_depths := [0.0, 3.0, 5.0, 10.0, 15.0, 20.0, 30.0]
	var expected_scales := [0.0, 0.40, 0.60, 0.80, 0.90, 0.95, 1.0]
	for index in range(expected_depths.size()):
		var components := WaveSampler.calculate_shallow_wave_scale_components(
			float(expected_depths[index]), 5.0, 0.20, 30.0, 0.40
		)
		_expect(
			absf(float(components["visual_zone_scale"]) - float(expected_scales[index])) < 0.00001,
			"visual amplitude control point %.1f m matches %.2f" % [expected_depths[index], expected_scales[index]]
		)
		_expect(
			absf(float(components["amplitude_scale"]) - float(expected_scales[index])) < 0.00001,
			"safety cap does not alter the visual scale at %.1f m when its budget is sufficient" % expected_depths[index]
		)

	for knot in [3.0, 5.0, 10.0, 15.0, 20.0, 30.0]:
		var before := WaveSampler.calculate_shallow_wave_scale_components(knot - 0.01, 5.0, 0.20, 30.0, 0.40)
		var after := WaveSampler.calculate_shallow_wave_scale_components(knot + 0.01, 5.0, 0.20, 30.0, 0.40)
		_expect(
			absf(float(before["visual_zone_scale"]) - float(after["visual_zone_scale"])) < 0.001,
			"the visual curve has no amplitude step around %.1f m" % knot
		)

	var target := WaveSampler.calculate_shallow_wave_scale_components(5.52, 5.0, 0.20, 30.0, 0.40)
	_expect(is_equal_approx(float(target["allowed_trough_m"]), 4.416), "5.52 m depth reserves 20 percent and allows a 4.416 m trough")
	_expect(absf(float(target["safety_scale"]) - 0.8832) < 0.0001, "5.52 m safety scale is 0.8832 for the 5 m trough envelope")
	_expect(float(target["visual_zone_scale"]) >= 0.60 and float(target["visual_zone_scale"]) <= 0.63, "5.52 m smoothstep visual scale is in the expected 0.60-0.63 range")
	_expect(absf(float(target["amplitude_scale"]) - float(target["visual_zone_scale"])) < 0.00001, "the 5.52 m final scale is set by the visual curve, not the safety cap")
	_expect(absf(float(target["amplitude_scale"]) * 5.0 - 3.0) < 0.15, "the 5.52 m theoretical trough remains about 3.0-3.15 m")
	print("[SHALLOW_WAVE_TEST] 5.52 m, trough=5.00 m, allowed=%.3f m, visual=%.3f, safety=%.3f, final=%.3f, constrained=%.3f m" % [
		float(target["allowed_trough_m"]),
		float(target["visual_zone_scale"]),
		float(target["safety_scale"]),
		float(target["amplitude_scale"]),
		float(target["amplitude_scale"]) * 5.0,
	])

	for test_depth in [5.0, 3.0, 2.0, 1.0, 0.5]:
		var test_depth_value := float(test_depth)
		var shallow := WaveSampler.calculate_shallow_wave_scale_components(test_depth_value, 5.0, 0.20, 30.0, 0.40)
		var expected_allowed := test_depth_value * 0.80
		_expect(
			absf(float(shallow["allowed_trough_m"]) - expected_allowed) < 0.00001,
			"%.1f m depth allows %.1f m trough with 20 percent margin" % [test_depth_value, expected_allowed]
		)
		_expect(float(shallow["amplitude_scale"]) * 5.0 <= expected_allowed + 0.00001, "%.1f m theoretical trough stays within its percentage budget" % test_depth_value)

	var small_wave := WaveSampler.calculate_shallow_wave_scale_components(1.0, 0.30, 0.20, 30.0, 0.40)
	_expect(is_equal_approx(float(small_wave["amplitude_scale"]), 1.0), "normal small waves retain their amplitude at 1 m depth")
	var near_zero := WaveSampler.calculate_shallow_wave_scale_components(0.001, 5.0, 0.20, 30.0, 0.40)
	var dry := WaveSampler.calculate_shallow_wave_scale_components(0.0, 5.0, 0.20, 30.0, 0.40)
	_expect(float(near_zero["amplitude_scale"]) < 0.001, "storm waves taper continuously toward zero as effective depth approaches zero")
	_expect(is_zero_approx(float(dry["amplitude_scale"])), "zero or invalid effective depth cannot receive wave amplitude")
	var no_wave := WaveSampler.calculate_shallow_wave_scale_components(0.0, 0.0, 0.20, 30.0, 0.40)
	_expect(is_equal_approx(float(no_wave["amplitude_scale"]), 1.0), "an empty wave envelope avoids division by zero")

	var expected_safety := [0.9936, 0.8832, 0.7728, 0.552]
	var ratios := [0.10, 0.20, 0.30, 0.50]
	for index in range(ratios.size()):
		var ratio_value := float(ratios[index])
		var adjusted := WaveSampler.calculate_shallow_wave_scale_components(5.52, 5.0, ratio_value, 30.0, 0.40)
		_expect(
			absf(float(adjusted["safety_scale"]) - float(expected_safety[index])) < 0.0001,
			"%.0f percent safety margin produces the expected safety scale" % (ratio_value * 100.0)
		)
		_expect(
			absf(float(adjusted["amplitude_scale"]) - minf(float(adjusted["visual_zone_scale"]), float(adjusted["safety_scale"]))) < 0.00001,
			"%.0f percent margin combines through min(visual,safety)" % (ratio_value * 100.0)
		)
	_expect(
		is_equal_approx(float(WaveSampler.calculate_shallow_wave_scale_components(35.0, 5.0, 0.20, 30.0, 0.40)["amplitude_scale"]), 1.0),
		"water deeper than 30 m keeps the original full deep-water amplitude"
	)
	_expect(
		is_equal_approx(float(WaveSampler.calculate_shallow_wave_scale_components(35.0, 5.0, 0.50, 30.0, 0.40)["amplitude_scale"]), 1.0),
		"the percentage safety margin cannot amplify deep-water waves"
	)


func _test_shared_bathymetry_sample() -> void:
	var bathymetry := BathymetryManager.new()
	bathymetry.georeference = GEOREFERENCE
	root.add_child(bathymetry)
	await process_frame
	_expect(bathymetry.data_available, "the offline EMODnet grid loads for CPU sampling")
	var world_position: Vector3 = GEOREFERENCE.geodetic_to_world(55.7, 12.75)
	var texture_sample: Dictionary = bathymetry.sample_shader_depth_at_world_position(world_position)
	_expect(bool(texture_sample.get("valid", false)), "the shared RG8 texture sample reports valid water in the Oresund test area")
	_expect(float(texture_sample.get("depth_m", 0.0)) > 0.0, "the GPU-equivalent depth decoder returns positive LAT depth")
	var texture_bounds: Vector4 = bathymetry.get("_depth_texture_bounds")
	var boundary_north := (texture_bounds.y + texture_bounds.w) * 0.5
	var boundary_sample: Dictionary = bathymetry.sample_shader_depth_at_world_position(Vector3(texture_bounds.x, 0.0, -boundary_north))
	var outside_sample: Dictionary = bathymetry.sample_shader_depth_at_world_position(Vector3(texture_bounds.x - 1.0, 0.0, -boundary_north))
	_expect(float(boundary_sample.get("edge_coverage", 1.0)) == 0.0, "the texture edge fades to conservative zero coverage")
	_expect(is_zero_approx(float(outside_sample.get("effective_depth_m", -1.0))), "out-of-bounds texture samples remain conservative shallow fallback")
	var source_sample: Dictionary = bathymetry.get_depth_at_geodetic(55.7, 12.75, false)
	_expect(bool(source_sample.get("valid", false)), "the corresponding source DTM query is valid")
	_expect(
		absf(float(source_sample.get("depth_m", 0.0)) - float(texture_sample.get("depth_m", 0.0))) < 3.0,
		"the 30 m shader texture stays close to the source DTM sample"
	)

	var extreme_settings: SeaWaveSettings = ExtremeSeaStatePresets.build_settings(BASE_WAVES, 10.0, 2.35, 0.76)
	var sampler := WaveSampler.new()
	sampler.wave_settings = BASE_WAVES
	var test_material := WATER_MATERIAL.duplicate(true) as ShaderMaterial
	sampler.water_material = test_material
	root.add_child(sampler)
	_expect(not bool(test_material.get_shader_parameter("shallow_wave_constraint_enabled")), "the water material leaves the test-only constraint disabled by default")
	sampler.set("_bathymetry_manager", bathymetry)
	sampler.set("_extreme_test_settings", extreme_settings)
	sampler.set("_extreme_test_strength", 1.0)
	sampler.set("_extreme_test_active", true)
	sampler.call("_apply_wave_parameters")
	sampler.set_shallow_wave_constraint_options(true, 30.0, 0.40, 0.20)
	_expect(bool(test_material.get_shader_parameter("shallow_wave_constraint_enabled")), "the F3-facing option synchronizes its enabled state to the shader")
	_expect(
		is_equal_approx(float(test_material.get_shader_parameter("shallow_wave_safe_depth_ratio")), sampler.shallow_wave_safe_depth_ratio),
		"the CPU safety ratio is sent to the shader without a separate parameter source"
	)
	_expect(
		is_equal_approx(
			float(test_material.get_shader_parameter("shallow_wave_max_trough_excursion_m")),
			sampler.get_theoretical_max_trough_excursion()
		),
		"CPU theoretical trough envelope is sent to the shader"
	)
	var diagnostics: Dictionary = sampler.get_shallow_wave_diagnostics(world_position)
	var effective_depth := float(diagnostics.get("effective_depth_m", 0.0))
	var expected_components := WaveSampler.calculate_shallow_wave_scale_components(
		effective_depth,
		float(diagnostics.get("theoretical_max_trough_excursion_m", 0.0)),
		0.20,
		30.0,
		0.40
	)
	_expect(float(diagnostics.get("depth_m", 0.0)) > 5.0 and float(diagnostics.get("depth_m", 0.0)) < 6.0, "the Oresund fixture is the requested approximately 5.52 m test location")
	_expect(
		absf(float(diagnostics.get("amplitude_scale", -1.0)) - float(expected_components["amplitude_scale"])) < 0.00001,
		"CPU height sampling uses the same visual and safety components as its diagnostics"
	)
	_expect(
		absf(float(diagnostics.get("visual_zone_scale", -1.0)) - float(expected_components["visual_zone_scale"])) < 0.00001,
		"CPU reports its actual visual-zone component"
	)
	print("[SHALLOW_WAVE_TEST] Oresund LAT depth=%.2f m, valid=%s, raw trough=%.2f m, allowed=%.3f m, visual=%.3f, safety=%.3f, final=%.3f, constrained=%.2f m" % [
		float(diagnostics.get("depth_m", 0.0)),
		str(bool(diagnostics.get("valid", false))),
		float(diagnostics.get("theoretical_max_trough_excursion_m", 0.0)),
		float(diagnostics.get("allowed_trough_m", 0.0)),
		float(diagnostics.get("visual_zone_scale", 1.0)),
		float(diagnostics.get("safety_scale", 1.0)),
		float(diagnostics.get("amplitude_scale", 1.0)),
		float(diagnostics.get("constrained_max_trough_excursion_m", 0.0)),
	])

	var allowed_trough := effective_depth * 0.80
	var stays_clear := true
	for time_value in range(0, 16):
		var surface: Dictionary = sampler.sample_surface(world_position, float(time_value))
		var downward_excursion := maxf(-float(surface.get("displacement", Vector3.ZERO).y), 0.0)
		var local_state: Dictionary = surface.get("shallow_wave_state", {})
		var local_allowed := float(local_state.get("effective_depth_m", 0.0)) * 0.80
		if downward_excursion > local_allowed + 0.02:
			stays_clear = false
			break
	_expect(stays_clear, "CPU wave samples stay within the local 20 percent depth budget across sampled phases")
	_expect(allowed_trough >= 0.0, "the reported percentage safety budget is nonnegative")
	sampler.free()
	bathymetry.free()


func _test_f3_controls() -> void:
	var scene := MAIN_SCENE.instantiate()
	root.add_child(scene)
	await process_frame
	var hud := scene.get_node("PlayerBoat/BoatHUD")
	var selector := hud.get("_extreme_sea_option") as OptionButton
	var constraint_toggle := hud.get("_shallow_wave_constraint_toggle") as CheckButton
	var ratio_slider := hud.get("_shallow_wave_safe_ratio_slider") as HSlider
	var defaults_button := hud.get("_shallow_wave_defaults_button") as Button
	var status := hud.get("_shallow_wave_status") as Label
	var sampler := scene.get_node("WaveSampler") as WaveSampler
	var controller := hud.get("_controller") as Node3D
	_expect(selector != null and constraint_toggle != null and ratio_slider != null and status != null, "F3 builds the percentage slider and shallow-wave status display")
	if selector == null or constraint_toggle == null or ratio_slider == null or status == null:
		scene.queue_free()
		await process_frame
		return
	sampler.set_process(false)
	_expect(is_equal_approx(ratio_slider.min_value, 0.10) and is_equal_approx(ratio_slider.max_value, 0.50), "F3 constrains the safety-margin slider to 10-50 percent")
	selector.select(2)
	hud.call("_on_extreme_sea_selected", 2)
	_expect(sampler.is_extreme_sea_test_active(), "F3 can select the 10 m test preset")
	_expect(constraint_toggle.button_pressed and sampler.shallow_wave_constraint_enabled, "the 10 m test enables shallow-wave control by default")
	_expect(bool(sampler.water_material.get_shader_parameter("shallow_wave_constraint_enabled")), "F3 enable state reaches the shared water material")
	var position := controller.global_position if controller != null else Vector3.ZERO
	var normal_to_10_peak_step := _advance_wave_transition(sampler, position)
	_expect(not sampler.is_extreme_sea_test_transitioning(), "normal-to-10 m transition reaches its endpoint")
	ratio_slider.value = 0.50
	hud.call("_on_shallow_wave_options_changed", 0.50)
	_expect(is_equal_approx(sampler.shallow_wave_safe_depth_ratio, 0.50), "F3 ratio changes update the CPU immediately")
	_expect(is_equal_approx(float(sampler.water_material.get_shader_parameter("shallow_wave_safe_depth_ratio")), 0.50), "F3 ratio changes update the shader immediately")
	hud.call("_update_shallow_wave_status")
	_expect(status.text.contains("50%") and status.text.contains("视觉分区倍率") and status.text.contains("波谷安全倍率"), "F3 displays the safety ratio and both amplitude constraints")
	if defaults_button != null:
		defaults_button.pressed.emit()
		_expect(is_equal_approx(sampler.shallow_wave_safe_depth_ratio, 0.20), "restore-defaults returns the safety margin to 20 percent")
	selector.select(3)
	hud.call("_on_extreme_sea_selected", 3)
	var ten_to_twenty_peak_step := _advance_wave_transition(sampler, position)
	_expect(sampler.is_extreme_sea_test_active() and not sampler.is_extreme_sea_test_transitioning(), "10-to-20 m transition reaches the selected test preset")
	constraint_toggle.set_pressed_no_signal(false)
	hud.call("_on_shallow_wave_constraint_toggled", false)
	_expect(not sampler.shallow_wave_constraint_enabled, "the F3 toggle can disable the constraint immediately")
	selector.select(0)
	hud.call("_on_extreme_sea_selected", 0)
	var twenty_to_weather_peak_step := _advance_wave_transition(sampler, position)
	_expect(not sampler.shallow_wave_constraint_enabled, "returning to weather control leaves the test constraint disabled")
	_expect(not sampler.is_extreme_sea_test_active(), "20-to-weather transition restores weather ownership")
	print("[SHALLOW_WAVE_TRANSITION_TEST] max single-frame sampled height step: normal->10m=%.3f m, 10m->20m=%.3f m, 20m->weather=%.3f m" % [
		normal_to_10_peak_step,
		ten_to_twenty_peak_step,
		twenty_to_weather_peak_step,
	])
	_expect(
		maxf(normal_to_10_peak_step, maxf(ten_to_twenty_peak_step, twenty_to_weather_peak_step)) < 1.0,
		"stepped weather transitions contain no single-frame metre-scale height jump in CPU sampling"
	)
	scene.queue_free()
	await process_frame


func _advance_wave_transition(sampler: WaveSampler, position: Vector3) -> float:
	var previous_height := float(sampler.sample_surface(position, sampler.wave_time_seconds).get("height", 0.0))
	var peak_height_step := 0.0
	for _frame in range(160):
		sampler.call("_process", 1.0 / 60.0)
		var current_height := float(sampler.sample_surface(position, sampler.wave_time_seconds).get("height", 0.0))
		peak_height_step = maxf(peak_height_step, absf(current_height - previous_height))
		previous_height = current_height
	return peak_height_step


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(description)
