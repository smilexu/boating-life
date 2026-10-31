extends SceneTree

const BOAT_HUD_SCRIPT := preload("res://scripts/boat_hud.gd")
const SEA_TROUT_FIGHT := preload("res://resources/fishing/fight_profiles/sea_trout.tres")
const SEA_TROUT_SPECIES := preload("res://resources/fish_species/sea_trout.tres")
const NEEDLEFISH_FIGHT := preload("res://resources/fishing/fight_profiles/needlefish.tres")
const NEEDLEFISH_SPECIES := preload("res://resources/fish_species/needlefish.tres")
const ROD_MOUNT := preload("res://resources/fishing/rod_mounts/starter_cargo_boat.tres")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var system := FishingRodSystem.new()
	root.add_child(system)
	system._fight_profile = SEA_TROUT_FIGHT
	system._presentation_seed = 17
	_check(system._fight_profile.hanging_struggle_duration_seconds >= 4.0, "hanging body struggle lasts through the early catch display")
	_check(system._fight_profile.hanging_curl_total_angle_degrees >= 90.0 and system._fight_profile.hanging_curl_total_angle_degrees <= 130.0, "sea trout uses a strong 90-130 degree cumulative C bend")
	_check(absf(SEA_TROUT_FIGHT.hanging_tail_whip_angle_degrees / 38.0 - 1.3) < 0.03 and absf(NEEDLEFISH_FIGHT.hanging_tail_whip_angle_degrees / 42.0 - 1.3) < 0.03, "both species increase the tail-only angle contribution by 30 percent")
	_check(is_equal_approx(SEA_TROUT_FIGHT.hanging_burst_speed_multiplier, 1.5) and is_equal_approx(NEEDLEFISH_FIGHT.hanging_burst_speed_multiplier, 1.5), "event-driven burst speed is increased by 50 percent")
	_check(system._fight_profile.hanging_tail_wriggle_frequency_hz >= 5.0 and system._fight_profile.hanging_tail_wriggle_frequency_hz <= 7.0, "tail uses the intended fast whip frequency")
	_check(is_equal_approx(SEA_TROUT_FIGHT.hanging_tail_wriggle_frequency_hz, 6.2) and is_equal_approx(NEEDLEFISH_FIGHT.hanging_tail_wriggle_frequency_hz, 6.8), "continuous tail frequency remains unchanged")
	_check(system.hanging_struggle_intensity == 3.0, "debug struggle intensity defaults to 3x")
	var early_wriggle := system._get_hanging_body_wriggle_state(0.05)
	var repeated_early_wriggle := system._get_hanging_body_wriggle_state(0.05)
	var mid_wriggle := system._get_hanging_body_wriggle_state(2.7)
	var late_wriggle := system._get_hanging_body_wriggle_state(9.0)
	var peak_c_bend := system._get_hanging_body_wriggle_state(0.0)
	var accelerated_burst_peak := system._get_hanging_body_wriggle_state(0.002)
	var accelerated_burst_decay := system._get_hanging_body_wriggle_state(0.09)
	_check(early_wriggle.intensity > mid_wriggle.intensity and mid_wriggle.intensity > late_wriggle.intensity, "deterministic struggle bursts fade from violent to intermittent late twitches")
	_check(early_wriggle.intensity >= 0.75 and is_equal_approx(early_wriggle.tail_phase, repeated_early_wriggle.tail_phase) and early_wriggle.curl_sign == repeated_early_wriggle.curl_sign, "first hanging burst and tail phase are deterministic for a fixed seed")
	_check(peak_c_bend.curl_sign > 0.0 and peak_c_bend.intensity >= 0.8, "initial burst starts with a strong single-direction curl")
	_check(accelerated_burst_peak.intensity > accelerated_burst_decay.intensity + 0.3, "1.5x burst timing sharpens the curl and release without extending the pulse")
	var slow_sway_velocity := FishingRodSystem._hanging_burst_sway_response(0.001, 1.25, 1.0) / 0.001
	var fast_sway_velocity := FishingRodSystem._hanging_burst_sway_response(0.001, 1.25, 1.5) / 0.001
	_check(absf(fast_sway_velocity / slow_sway_velocity - 1.5) < 0.001, "burst-driven lateral angular velocity increases by 50 percent while damping is retained")
	var early_burst_count := 0
	for pulse in SEA_TROUT_FIGHT.hanging_curl_pulses:
		if pulse.x <= 4.0 and pulse.y >= 0.8:
			early_burst_count += 1
	_check(early_burst_count >= 4 and early_burst_count <= 6, "four to six strong struggle bursts occur during the first four seconds")
	_check(system._get_hanging_body_wriggle_state(10.8).intensity < late_wriggle.intensity, "hanging deformation settles near display end without changing the 56-second timeline")
	var early_swing := absf(system._get_hanging_lateral_swing_degrees(0.05))
	var reverse_swing := system._get_hanging_lateral_swing_degrees(0.72)
	var peak_swing := 0.0
	for sample_index in range(0, 240):
		peak_swing = maxf(peak_swing, absf(system._get_hanging_lateral_swing_degrees(float(sample_index) * 0.05)))
	_check(early_swing >= 10.0 and early_swing <= 20.0, "first C burst drives a clear 10-20 degree lateral swing")
	_check(reverse_swing < -6.0, "reverse C burst carries the hanging fish in the opposite direction")
	_check(peak_swing <= 20.0, "impulse-linked whole-fish swing stays within the 20 degree cap")
	_check(absf(system._get_hanging_lateral_swing_degrees(11.0)) <= 4.0, "late hanging swing settles to a small residual range")

	var front_angle := FishingRodRig.hanging_spine_angle(0.25, 125.0, 49.5, PI * 0.5, 1.0, 1.0)
	var middle_angle := FishingRodRig.hanging_spine_angle(0.62, 125.0, 49.5, PI * 0.5, 1.0, 1.0)
	var rear_angle := FishingRodRig.hanging_spine_angle(0.9, 125.0, 49.5, PI * 0.5, 1.0, 1.0)
	var reverse_middle_angle := FishingRodRig.hanging_spine_angle(0.62, 125.0, 49.5, PI * 0.5, -1.0, 1.0)
	var tail_angle := FishingRodRig.hanging_spine_angle(1.0, 125.0, 49.5, PI * 0.5, 1.0, 1.0)
	var center_front := FishingRodRig.hanging_spine_centerline(0.25, 125.0, 49.5, PI * 0.5, 1.0, 1.0)
	var center_tail := FishingRodRig.hanging_spine_centerline(1.0, 125.0, 49.5, PI * 0.5, 1.0, 1.0)
	var tail_reverse_phase_angle := FishingRodRig.hanging_spine_angle(1.0, 125.0, 49.5, PI * 1.5, 1.0, 1.0)
	var trout_old_tail_contribution := minf(150.0, 125.0 + 38.0) - 125.0
	var trout_new_tail_contribution := tail_angle - 125.0
	var needle_old_tail_contribution := minf(150.0, 100.0 + 42.0) - 100.0
	var needle_new_tail_contribution := minf(158.0, 100.0 + NEEDLEFISH_FIGHT.hanging_tail_whip_angle_degrees) - 100.0
	_check(absf(FishingRodRig.hanging_spine_angle(0.0, 125.0, 49.5, PI * 0.5, 1.0, 1.0)) < 0.001, "spine tangent starts straight at the mouth hook")
	_check(front_angle >= 0.0 and front_angle < middle_angle and middle_angle < rear_angle, "spine accumulates smooth same-sign curvature toward the rear")
	_check(reverse_middle_angle < 0.0 and tail_angle <= 158.0 and tail_reverse_phase_angle > 0.0 and tail_reverse_phase_angle < tail_angle, "body reverses as a whole while the tail adds a fast, bounded whip")
	_check(absf(trout_new_tail_contribution / trout_old_tail_contribution - 1.3) < 0.03 and absf(needle_new_tail_contribution / needle_old_tail_contribution - 1.3) < 0.03, "effective maximum terminal tail turn increases by approximately 30 percent for both species")
	_check(absf(center_front.y) < absf(center_tail.y) * 0.12 and center_tail.y > 0.32, "integrated spine produces a strong continuous C arc with a stable head")
	var hanging_rotation := system._get_hanging_rotation(0.05, Vector3.ZERO)
	var hanging_base := (Basis(Vector3.UP, 0.0) * Basis(Vector3.RIGHT, PI * 0.5)).get_rotation_quaternion()
	var tail_direction_in_base := hanging_base.inverse() * hanging_rotation * Vector3.BACK
	_check(absf(tail_direction_in_base.x) > 0.15 and absf(tail_direction_in_base.y) < 0.03, "burst response swings the fish sideways around the mouth rather than tilting it fore and aft")

	var rig := FishingRodRig.new()
	root.add_child(rig)
	rig.configure(ROD_MOUNT)
	_check(rig.set_catch_visual(SEA_TROUT_SPECIES, 0.65), "temporary sea trout mesh loads for vertex-shader deformation")
	var trout_tail_strength := 0.0
	if rig.has_catch_visual() and not rig._catch_deformation_surfaces.is_empty():
		var source_mesh: ArrayMesh = rig._catch_deformation_surfaces[0]["mesh"]
		var deformation_material: ShaderMaterial = rig._catch_deformation_surfaces[0]["material"]
		_check((source_mesh.surface_get_format(0) & Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE) == 0, "catch retains imported mesh without CPU dynamic-vertex uploads")
		_check(deformation_material.shader.code.contains("spine_centerline") and deformation_material.shader.code.contains("section_axis") and deformation_material.shader.code.contains("NORMAL"), "shader integrates a continuous spine and rotates cross-sections and normals")
		_check(deformation_material.get_shader_parameter("has_albedo_texture"), "custom material preserves source albedo texture")
		_check(deformation_material.get_shader_parameter("has_normal_texture"), "custom material preserves sea trout normal map")
		var vertices: PackedVector3Array = source_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var x_bands: Dictionary = {}
		for vertex in vertices:
			x_bands[snappedf(vertex.x, 0.001)] = true
		_check(x_bands.size() >= 18, "sea trout mesh has enough longitudinal slices for a smooth body curve")

		rig.set_catch_spine_curl(125.0, SEA_TROUT_FIGHT.hanging_tail_whip_angle_degrees, PI * 0.5, 1.0, SEA_TROUT_FIGHT.hanging_curl_bend_power)
		var positive_offsets: Dictionary = rig.get_catch_body_wriggle_probe_offsets()
		var front_offset: Vector3 = positive_offsets["front"]
		var main_bend_offset: Vector3 = positive_offsets["main_bend"]
		var tail_offset: Vector3 = positive_offsets["tail"]
		trout_tail_strength = tail_offset.length()
		_check(front_offset.length() < main_bend_offset.length() and main_bend_offset.length() > 0.035, "Sea Trout's front remains stable while the middle and rear follow the curved spine")
		_check(tail_offset.length() >= 0.18, "integrated C spine displaces the tail visibly at natural length")
		_check(is_equal_approx(float(deformation_material.get_shader_parameter("spine_bend_angle")), deg_to_rad(125.0)) and is_equal_approx(float(deformation_material.get_shader_parameter("tail_whip_angle")), deg_to_rad(49.5)), "cumulative body and tail turn angles reach the shader in radians")
		_check(rig.set_catch_visual(SEA_TROUT_SPECIES, 1.0), "larger sea trout test size loads")
		deformation_material = rig._catch_deformation_surfaces[0]["material"]
		rig.set_catch_spine_curl(125.0, SEA_TROUT_FIGHT.hanging_tail_whip_angle_degrees, PI * 0.5, 1.0, SEA_TROUT_FIGHT.hanging_curl_bend_power)
		var large_offsets: Dictionary = rig.get_catch_body_wriggle_probe_offsets()
		_check(is_equal_approx((large_offsets["tail"] as Vector3).length() / trout_tail_strength, 1.0 / 0.65), "body deformation scales with natural fish length")

		var mouth_target := Vector3(1.0, 2.0, 3.0)
		rig.set_catch_hanging_pose_world(mouth_target, Quaternion.IDENTITY)
		_check(rig.get_catch_hook_point_world().distance_to(mouth_target) < 0.001, "mouth hook point remains fixed while the shader deforms body vertices")
		rig.set_hanging_line_world(mouth_target)
		_check(rig._line_end_world.distance_to(rig.get_catch_hook_point_world()) < 0.001, "line endpoint remains on the pinned mouth during deformation")
		rig.set_catch_spine_curl(0.0, 0.0, 4.2, -1.0, SEA_TROUT_FIGHT.hanging_curl_bend_power)
		_check(is_equal_approx(float(deformation_material.get_shader_parameter("tail_wave_phase")), 4.2) and is_equal_approx(float(deformation_material.get_shader_parameter("spine_bend_angle")), 0.0) and is_equal_approx(float(deformation_material.get_shader_parameter("tail_whip_angle")), 0.0), "seek and calm states update deterministic spine uniforms without rebuilding mesh")
	rig.queue_free()

	var needlefish_rig := FishingRodRig.new()
	root.add_child(needlefish_rig)
	_check(needlefish_rig.set_catch_visual(NEEDLEFISH_SPECIES, 0.60), "temporary needlefish mesh loads for vertex-shader deformation")
	if needlefish_rig.has_catch_visual() and not needlefish_rig._catch_deformation_surfaces.is_empty():
		var needle_mesh: ArrayMesh = needlefish_rig._catch_deformation_surfaces[0]["mesh"]
		var needle_material: ShaderMaterial = needlefish_rig._catch_deformation_surfaces[0]["material"]
		_check((needle_mesh.surface_get_format(0) & Mesh.ARRAY_FLAG_USE_DYNAMIC_UPDATE) == 0, "needlefish retains imported mesh without CPU vertex uploads")
		var needle_vertices: PackedVector3Array = needle_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var needle_x_bands: Dictionary = {}
		for vertex in needle_vertices:
			needle_x_bands[snappedf(vertex.x, 0.001)] = true
		_check(needle_x_bands.size() >= 18, "needlefish mesh has enough longitudinal slices for a smooth fast tail wave")
		_check(needle_material.get_shader_parameter("has_albedo_texture"), "custom material preserves needlefish albedo texture")
		needlefish_rig.set_catch_spine_curl(100.0, NEEDLEFISH_FIGHT.hanging_tail_whip_angle_degrees, PI * 0.5, 1.0, NEEDLEFISH_FIGHT.hanging_curl_bend_power)
		var needlefish_offsets: Dictionary = needlefish_rig.get_catch_body_wriggle_probe_offsets()
		_check(needlefish_offsets["front"].length() < (needlefish_offsets["main_bend"] as Vector3).length() * 0.25, "needlefish head remains steadier than its thin posterior body")
		_check(needlefish_offsets["tail"].length() < trout_tail_strength, "needlefish uses a smaller proportional bend than sea trout")
		_check(NEEDLEFISH_FIGHT.hanging_curl_total_angle_degrees < SEA_TROUT_FIGHT.hanging_curl_total_angle_degrees, "needlefish has a smaller whole-body turn than the sea trout")
		_check(NEEDLEFISH_FIGHT.hanging_tail_wriggle_frequency_hz > SEA_TROUT_FIGHT.hanging_tail_wriggle_frequency_hz, "needlefish tail whip is faster than sea trout")
	needlefish_rig.queue_free()
	system._fight_profile = null
	var hud = BOAT_HUD_SCRIPT.new()
	hud._fishing_rod_system = system
	hud._build_catch_result_panel()
	_check(hud is CanvasLayer, "catch result UI is owned by a camera-independent CanvasLayer")
	_check(hud._catch_result_panel.get_parent() == hud, "result card is screen HUD content rather than a world-space fish label")
	_check(not hud._catch_result_panel.visible, "result card starts hidden")

	var panel := FishingPlayerPanel.new()
	root.add_child(panel)
	await process_frame
	panel.configure(null, system)
	var last_catch := panel.find_child("LastCatchSummary", true, false) as Label
	_check(last_catch != null and not last_catch.visible, "last-catch summary stays hidden until an authoritative catch succeeds")

	system.presentation_source = FishingRodSystem.PresentationSource.DEBUG_SIMULATION
	system.presentation_phase = FishingRodSystem.PresentationPhase.CATCH_PRESENTATION
	system._presentation_species_id = "sea_trout"
	system._presentation_length_m = 0.65
	system._presentation_weight_kg = 2.6
	system._presentation_seed = 17
	system._emit_catch_display_snapshot()
	_check(hud._catch_result_panel.visible, "debug presentation raises the screen result card")
	_check(hud._catch_result_title.text == tr("fishing.ui.simulation_preview"), "debug presentation is clearly labelled as a preview")
	_check(hud._catch_result_length.text.contains("65"), "preview card uses the requested simulated body length")
	_check(last_catch != null and not last_catch.visible, "simulation preview does not update recent real catch")
	_check(system._catch_result == null, "simulation display creates no real CatchResult")
	system.catch_display_updated.emit({"visible": false})
	_check(hud._catch_result_panel.visible, "simulation preview card remains after its animation ends")
	hud._advance_catch_result_card(12.5)
	_check(not hud._catch_result_panel.visible, "simulation preview card hides after the result hold")

	var result := FishingCatchResult.new()
	result.catch_id = "test-catch-1"
	result.species_id = "sea_trout"
	result.length_m = 0.65
	result.estimated_weight_kg = 2.6
	system.presentation_source = FishingRodSystem.PresentationSource.REAL_CATCH
	system._catch_result = result
	system._presentation_length_m = 0.65
	system._presentation_weight_kg = 2.6
	system._presentation_elapsed = 0.5
	system._emit_catch_display_snapshot()
	_check(hud._catch_result_title.text == tr("fishing.ui.catch_confirmed"), "authoritative settlement uses the catch-confirmed card title")
	_check(hud._catch_result_length.text.contains("65") and hud._catch_result_weight.text.contains("2.60"), "real card reads length and weight from CatchResult")
	_check(hud._catch_result_panel.visible and hud._catch_result_panel.modulate.a > 0.99, "real settlement card is fully readable after its short fade-in")
	_check(last_catch != null and not last_catch.visible, "screen card alone does not write recent-catch state")

	panel._on_catch_succeeded(result)
	_check(last_catch != null and last_catch.visible and last_catch.text.contains("65"), "real success updates the session-only last-catch summary")
	system.catch_display_updated.emit({"visible": false})
	_check(hud._catch_result_panel.visible, "real settlement card remains after the fish animation is cleaned up")
	hud._advance_catch_result_card(11.6)
	_check(hud._catch_result_panel.visible and hud._catch_result_panel.modulate.a < 1.0, "real result card fades only near the end of its hold")
	hud._advance_catch_result_card(0.5)
	_check(not hud._catch_result_panel.visible, "real result card hides after its extended hold")

	panel.queue_free()
	hud.free()
	system.queue_free()
	await process_frame
	print("[FISHING_P3_3C_1] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[FISHING_P3_3C_1][PASS] %s" % message)
	else:
		_failures += 1
		push_error("[FISHING_P3_3C_1][FAIL] %s" % message)
