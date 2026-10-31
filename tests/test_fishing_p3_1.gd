extends SceneTree

const POWERBOAT_MOUNT := preload("res://resources/fishing/rod_mounts/starter_cargo_boat.tres")
const SAILBOAT_MOUNT := preload("res://resources/fishing/rod_mounts/nordic28.tres")
const SEA_TROUT_FIGHT := preload("res://resources/fishing/fight_profiles/sea_trout.tres")
const SEA_TROUT_SPECIES := preload("res://resources/fish_species/sea_trout.tres")
const NEEDLEFISH_FIGHT := preload("res://resources/fishing/fight_profiles/needlefish.tres")
const NEEDLEFISH_SPECIES := preload("res://resources/fish_species/needlefish.tres")
const WAVE_SETTINGS := preload("res://resources/sea_waves.tres")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var system := FishingRodSystem.new()
	_check(is_equal_approx(system.hook_strike_seconds, 3.0), "hook strike defaults to 3 seconds")
	_check(is_equal_approx(system.fish_struggle_seconds, 15.0), "fish struggle defaults to 15 seconds")
	_check(is_equal_approx(system.progressive_retrieval_seconds, 22.0), "progressive retrieval defaults to 22 seconds")
	_check(is_equal_approx(system.surface_landing_seconds, 8.0), "surface and landing defaults to 8 seconds")
	_check(is_equal_approx(system.catch_presentation_seconds, 8.0), "catch presentation defaults to 8 seconds")
	_check(is_equal_approx(system.hook_strike_seconds + system.fish_struggle_seconds + system.progressive_retrieval_seconds + system.surface_landing_seconds + system.catch_presentation_seconds, 56.0), "default presentation is 56 seconds")
	_check(system.auto_switch_to_fight_camera, "Fight Camera automatically switches on a hook by default")
	_check(is_equal_approx(POWERBOAT_MOUNT.maximum_hook_bend_m, 0.96) and is_equal_approx(SAILBOAT_MOUNT.maximum_hook_bend_m, 0.96), "both hulls configure 0.96 m maximum tip displacement")
	_check(is_equal_approx(POWERBOAT_MOUNT.line_out_length_m, 9.0) and is_equal_approx(SAILBOAT_MOUNT.line_out_length_m, 9.0), "both hulls configure 9 m visual line-out")
	_check(is_equal_approx(POWERBOAT_MOUNT.landing_min_line_length_m, 0.45) and is_equal_approx(SAILBOAT_MOUNT.landing_min_line_length_m, 0.45), "both hulls use the configured 0.45 m final hanging line")
	_check(is_equal_approx(POWERBOAT_MOUNT.catch_approach_start_distance_m, 5.8) and is_equal_approx(SAILBOAT_MOUNT.catch_surface_distance_m, 2.7), "near-boat path distances are configured per hull")
	_check(SEA_TROUT_FIGHT.approach_start_depth_below_surface_m > SEA_TROUT_FIGHT.approach_end_depth_below_surface_m, "sea trout approaches the boat while remaining below the sampled surface")
	_check(SEA_TROUT_FIGHT.surface_lateral_amplitude_multiplier > 1.0 and NEEDLEFISH_FIGHT.surface_lateral_amplitude_multiplier < SEA_TROUT_FIGHT.surface_lateral_amplitude_multiplier, "species profiles distinguish near-surface struggle amplitudes")
	_check(is_equal_approx(POWERBOAT_MOUNT.mount_position_m.y, 0.92) and is_equal_approx(SAILBOAT_MOUNT.mount_position_m.y, 0.54), "both rod mounts are raised 0.20 m to clear stern rails")
	_check(POWERBOAT_MOUNT.fight_camera_impulse_strength_m > 0.0 and SAILBOAT_MOUNT.fight_camera_impulse_strength_m > 0.0, "fight camera impact has a small per-hull adjustable default")
	_check(SEA_TROUT_FIGHT.species_id == "sea_trout" and NEEDLEFISH_FIGHT.species_id == "needlefish", "species-specific presentation profiles load")
	_check(SEA_TROUT_FIGHT.struggle_pulses_seconds_strength.size() >= 8 and NEEDLEFISH_FIGHT.struggle_pulses_seconds_strength.size() >= 8, "fight profiles contain multiple deterministic struggle events")
	_check(SEA_TROUT_FIGHT.base_rod_load_ratio > NEEDLEFISH_FIGHT.base_rod_load_ratio, "sea trout has a stronger base presentation load")
	_check(NEEDLEFISH_FIGHT.lateral_struggle_amplitude_m > SEA_TROUT_FIGHT.lateral_struggle_amplitude_m, "needlefish has stronger lateral movement")
	_check(TranslationServer.translate("camera.mode.fight_camera") != "camera.mode.fight_camera", "Fight Camera localization key resolves")
	_check(TranslationServer.translate("fishing.debug.phase.surface_landing") != "fishing.debug.phase.surface_landing", "Fight phase localization key resolves")
	_check(TranslationServer.translate("fishing.debug.fish_stage.breach") != "fishing.debug.fish_stage.breach", "sea trout breach debug label resolves")
	_check(TranslationServer.translate("fishing.debug.fish_stage.washing_gills") != "fishing.debug.fish_stage.washing_gills", "sea trout gill-wash debug label resolves")
	_check(SEA_TROUT_FIGHT.surface_breach_enabled and SEA_TROUT_FIGHT.surface_wash_gills_enabled, "sea trout has explicit breach and gill-wash action configuration")
	_check(not NEEDLEFISH_FIGHT.surface_breach_enabled and not NEEDLEFISH_FIGHT.surface_wash_gills_enabled, "surface breach and gill-wash remain sea-trout presentation only")
	var presentation := FishingRodSystem.new()
	_check(presentation.get_surface_fish_stage(SEA_TROUT_FIGHT, 1.675) == "BREACH", "sea trout reaches its visible breach phase")
	_check(presentation._get_surface_breach_height_offset(SEA_TROUT_FIGHT, 1.675) >= 1.19, "breach arc raises the fish clearly above the sampled surface")
	_check(presentation._get_surface_breach_height_offset(SEA_TROUT_FIGHT, 1.15) < -0.3, "sea trout begins its leap below the surface")
	_check(presentation._get_surface_breach_height_offset(SEA_TROUT_FIGHT, 2.19) < -0.3, "sea trout returns through the surface after the breach arc")
	_check(presentation.get_surface_fish_stage(SEA_TROUT_FIGHT, 3.2) == "WASHING_GILLS", "sea trout has a distinct side-on gill-wash phase")
	_check(presentation.get_surface_fish_stage(SEA_TROUT_FIGHT, 5.5) == "LIFTING", "hook lift follows the surface action")
	presentation.free()
	await _test_rod_rig()
	await _test_fight_camera()
	system.free()
	print("[FISHING_P3_1] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _test_rod_rig() -> void:
	var hull := Node3D.new()
	hull.name = "FishingRodHullFixture"
	root.add_child(hull)
	var rig := FishingRodRig.new()
	hull.add_child(rig)
	rig.configure(POWERBOAT_MOUNT)
	var rod := rig.find_child("RodSegments", true, false) as MultiMeshInstance3D
	var guides := rig.find_child("LineGuides", true, false) as MultiMeshInstance3D
	var line := rig.find_child("TrollingLine", true, false) as MultiMeshInstance3D
	var splash := rig.find_child("CatchSplashDroplets", true, false) as MultiMeshInstance3D
	var reel := rig.find_child("ReelSpinningAssembly", true, false) as Node3D
	_check(rod != null and rod.multimesh.instance_count == 12, "rod keeps fixed 12-segment MultiMesh topology")
	_check(guides != null and guides.multimesh.instance_count == 7, "guides keep fixed 7-instance topology")
	_check(line != null and line.multimesh.instance_count == POWERBOAT_MOUNT.guide_count + 6, "fine line keeps a fixed curved MultiMesh topology")
	_check(FishingRodRig.LINE_RADIUS_M < POWERBOAT_MOUNT.rod_tip_diameter_m * 0.5, "fishing line radius is thinner than the rod tip radius")
	var line_material := line.material_override as StandardMaterial3D if line != null else null
	_check(line_material != null and line_material.albedo_color.r > line_material.albedo_color.b, "warm line material contrasts with graphite rod and blue water")
	_check(splash != null and splash.multimesh.instance_count == 8, "splash uses a fixed low-cost droplet mesh")
	_check(reel != null and rig.get_reel_spin_axis_rig_local().dot(Vector3.LEFT) > 0.99, "reel rotation axis follows its horizontal axle so the reel face spins vertically")
	_check(rig.find_children("ReelSpoke*", "MeshInstance3D", true, false).size() >= 6, "reel wheel has visible spokes so axial rotation can be read in motion")
	var reel_axis := rig.get_reel_spin_axis_rig_local().normalized()
	var spoke_radial_before := reel.transform.basis * Vector3.RIGHT
	rig.set_reel_spin(1.0)
	rig._process(0.1)
	var spoke_radial_after := reel.transform.basis * Vector3.RIGHT
	_check(reel_axis.dot(spoke_radial_before.cross(spoke_radial_after)) < -0.001, "positive reel-in input turns the spool in the corrected winding direction")
	rig.reset_presentation_animation()
	var straight_tip := rig.get_rod_tip_local()
	rig.trigger_hook_strike()
	await create_timer(0.28).timeout
	var loaded_tip := rig.get_rod_tip_local()
	_check(straight_tip.y - loaded_tip.y >= 0.55, "hook strike creates a clearly increased nonlinear rod-tip bend")
	_check(straight_tip.y - loaded_tip.y <= POWERBOAT_MOUNT.maximum_hook_bend_m + 0.02, "recoil remains inside the configured maximum bend envelope")
	_check(rig.get_current_rod_load_ratio() > 0.8, "rod load ramps to a strong hooked response")
	_check(rig.get_rod_tip_local().is_finite(), "loaded rod tip remains finite and does not fold")
	var fish_loaded := rig.set_catch_visual(SEA_TROUT_SPECIES, 0.55)
	_check(fish_loaded, "sea trout presentation model loads for the surface action pose")
	if fish_loaded:
		var presentation := FishingRodSystem.new()
		presentation._rig = rig
		presentation._active_visual_root = hull
		presentation._active_profile = POWERBOAT_MOUNT
		presentation._fight_profile = SEA_TROUT_FIGHT
		var water_sampler := WaveSampler.new()
		water_sampler.name = "CatchPresentationWaveSampler"
		water_sampler.wave_settings = WAVE_SETTINGS
		root.add_child(water_sampler)
		await process_frame
		presentation._wave_sampler = water_sampler
		presentation.presentation_source = FishingRodSystem.PresentationSource.DEBUG_SIMULATION
		presentation.presentation_phase = FishingRodSystem.PresentationPhase.PROGRESSIVE_RETRIEVAL
		presentation._presentation_species_id = "sea_trout"
		presentation._presentation_length_m = 0.55
		presentation._fight_elapsed = 29.0
		presentation._line_distance_m = 5.9
		presentation._update_fight_visuals()
		var trolling_line := rig.find_child("TrollingLine", true, false) as MultiMeshInstance3D
		var fish_from_hull := hull.to_local(rig.get_catch_position_world())
		var rod_tip_from_hull := hull.to_local(rig.to_global(rig.get_rod_tip_local()))
		var line_entry_from_hull := hull.to_local(rig._line_water_entry_world)
		var approach_surface_position := Vector3(fish_from_hull.x, 0.0, fish_from_hull.z)
		var approach_surface_y := presentation._sample_water_height(approach_surface_position)
		_check(trolling_line != null and trolling_line.visible, "active catch exposes the visible fishing line")
		_check(fish_from_hull.z > POWERBOAT_MOUNT.mount_position_m.z + 5.0, "retrieval fish appears aft of the stern mount")
		var lateral_min := fish_from_hull.x
		var lateral_max := fish_from_hull.x
		for sample_time in [29.35, 29.7, 30.05, 30.4]:
			presentation._fight_elapsed = sample_time
			presentation._update_fight_visuals()
			var sample_x := hull.to_local(rig.get_catch_position_world()).x
			lateral_min = minf(lateral_min, sample_x)
			lateral_max = maxf(lateral_max, sample_x)
		_check(lateral_max - lateral_min > 0.15, "near-boat fish has readable seeded side-to-side movement")
		presentation._fight_elapsed = 29.0
		presentation._update_fight_visuals()
		fish_from_hull = hull.to_local(rig.get_catch_position_world())
		line_entry_from_hull = hull.to_local(rig._line_water_entry_world)
		_check(rig.get_catch_position_world().y < approach_surface_y - 0.3, "visible approach fish remains clearly below the sampled surface")
		_check(rig._line_end_world.distance_to(rig.get_catch_hook_point_world()) < 0.001, "fishing line endpoint follows the catch fish near its head")
		_check(line_entry_from_hull.z > rod_tip_from_hull.z, "line enters the water aft of the rod tip instead of crossing back over the deck")
		_check(line_entry_from_hull.z < hull.to_local(rig.get_catch_hook_point_world()).z, "water entry lies between the rod tip and fish instead of doubling back")
		var first_approach_z := fish_from_hull.z
		presentation._fight_elapsed = 37.0
		presentation._update_fight_visuals()
		var later_approach_z := hull.to_local(rig.get_catch_position_world()).z
		_check(later_approach_z < first_approach_z and later_approach_z > POWERBOAT_MOUNT.mount_position_m.z + POWERBOAT_MOUNT.catch_surface_distance_m - 0.1, "fish advances progressively toward the stern without teleporting onto the hull")
		presentation.presentation_phase = FishingRodSystem.PresentationPhase.SURFACE_LANDING
		presentation._fight_elapsed = presentation.hook_strike_seconds + presentation.fish_struggle_seconds + presentation.progressive_retrieval_seconds + 0.5
		presentation._update_surface_fish_pose(SEA_TROUT_FIGHT)
		var splash_position := rig.to_global(rig._splash_origin_local)
		var surface_fish_position := rig.get_catch_position_world()
		_check(rig._splash_ring.visible and absf(splash_position.x - surface_fish_position.x) < 0.001 and absf(splash_position.z - surface_fish_position.z) < 0.001, "surface splash follows the fish's current water position")
		presentation._fight_elapsed = presentation.hook_strike_seconds + presentation.fish_struggle_seconds + presentation.progressive_retrieval_seconds + 1.675
		presentation._update_surface_fish_pose(SEA_TROUT_FIGHT)
		_check(rig.get_catch_position_world().y >= 1.19, "surface pose places the actual fish model above the sampled waterline during its leap")
		presentation._fight_elapsed = presentation.hook_strike_seconds + presentation.fish_struggle_seconds + presentation.progressive_retrieval_seconds + 3.575
		presentation._update_surface_fish_pose(SEA_TROUT_FIGHT)
		_check(absf(rig._catch_container.rotation.z) >= deg_to_rad(70.0), "surface pose visibly rolls the actual sea trout onto its side for gill washing")
		presentation._fight_elapsed = presentation.hook_strike_seconds + presentation.fish_struggle_seconds + presentation.progressive_retrieval_seconds + 5.0
		presentation._update_surface_fish_pose(SEA_TROUT_FIGHT)
		var pre_lift_position := rig.get_catch_position_world()
		presentation._fight_elapsed = presentation.hook_strike_seconds + presentation.fish_struggle_seconds + presentation.progressive_retrieval_seconds + 5.5
		presentation._update_surface_fish_pose(SEA_TROUT_FIGHT)
		_check(rig.get_catch_position_world().distance_to(pre_lift_position) < 1.5, "water-to-hanging transition uses the same fish instance without a large position pop")
		rig.set_rod_load(0.0)
		rig.snap_rod_load_to_target()
		presentation._fight_elapsed = presentation.hook_strike_seconds + presentation.fish_struggle_seconds + presentation.progressive_retrieval_seconds + SEA_TROUT_FIGHT.surface_lift_start_seconds + SEA_TROUT_FIGHT.surface_lift_duration_seconds
		presentation._update_surface_fish_pose(SEA_TROUT_FIGHT)
		presentation._update_visual_line(1.0, 0.0)
		var hanging_mouth := rig.get_catch_hook_point_world()
		_check(rig._catch_container.visible, "fish remains visible after the lift reaches its hanging pose")
		_check(rig._line_end_world.distance_to(hanging_mouth) < 0.001, "hanging fishing line terminates at the fish mouth/head hook point")
		_check(absf(rig.get_rod_tip_world().distance_to(hanging_mouth) - POWERBOAT_MOUNT.landing_min_line_length_m) < 0.001, "hanging line length is measured from the current rod tip")
		var hanging_rotation := rig.get_catch_world_rotation()
		_check((hanging_rotation * Vector3(0.0, 0.0, -1.0)).dot(Vector3.UP) > 0.9, "hanging fish nose points upward")
		_check((hanging_rotation * Vector3(0.0, 0.0, 1.0)).dot(Vector3.DOWN) > 0.9, "hanging fish tail points downward")
		var tail_point := rig.get_catch_tail_point_world()
		_check(tail_point.y - presentation._sample_water_height(tail_point) >= POWERBOAT_MOUNT.hanging_clearance_margin_m - 0.02, "hanging fish tail clears the sampled local wave surface")
		presentation.presentation_phase = FishingRodSystem.PresentationPhase.CATCH_PRESENTATION
		presentation._presentation_elapsed = 0.0
		presentation._update_catch_presentation_pose()
		_check(rig.get_catch_hook_point_world().distance_to(hanging_mouth) < 0.001, "landing-to-presentation boundary keeps the mouth and line attached without a jump")
		var needlefish_loaded := rig.set_catch_visual(NEEDLEFISH_SPECIES, 0.60)
		_check(needlefish_loaded and is_equal_approx(rig._catch_body_length_m, 0.60), "needlefish uses its selected natural display length")
		if needlefish_loaded:
			presentation._fight_profile = NEEDLEFISH_FIGHT
			presentation._presentation_species_id = "needlefish"
			presentation._presentation_length_m = 0.60
			presentation.presentation_phase = FishingRodSystem.PresentationPhase.SURFACE_LANDING
			presentation._fight_elapsed = presentation.hook_strike_seconds + presentation.fish_struggle_seconds + presentation.progressive_retrieval_seconds + 0.65
			presentation._update_surface_fish_pose(NEEDLEFISH_FIGHT)
			var needlefish_position := rig.get_catch_position_world()
			var needlefish_surface := presentation._sample_water_height(Vector3(needlefish_position.x, 0.0, needlefish_position.z))
			_check(needlefish_position.is_finite() and needlefish_position.y < needlefish_surface, "needlefish remains in the near-surface water path before its lift")
			presentation._fight_elapsed = presentation.hook_strike_seconds + presentation.fish_struggle_seconds + presentation.progressive_retrieval_seconds + NEEDLEFISH_FIGHT.surface_lift_start_seconds + NEEDLEFISH_FIGHT.surface_lift_duration_seconds
			presentation._update_surface_fish_pose(NEEDLEFISH_FIGHT)
			presentation._update_visual_line(1.0, 0.0)
			_check(rig._line_end_world.distance_to(rig.get_catch_hook_point_world()) < 0.001, "needlefish uses the same continuous hanging line endpoint")
			_check((rig.get_catch_world_rotation() * Vector3(0.0, 0.0, -1.0)).dot(Vector3.UP) > 0.85, "needlefish also transitions to a head-up display pose")
		presentation.free()
		water_sampler.queue_free()
	rig.queue_free()
	hull.queue_free()
	await process_frame


func _test_fight_camera() -> void:
	var harness := Node3D.new()
	harness.name = "FightCameraHarness"
	root.add_child(harness)
	var motion := Node3D.new()
	motion.name = "MotionRoot"
	harness.add_child(motion)
	var rig := BoatFollowCamera.new()
	rig.name = "FollowCameraRig"
	var camera := Camera3D.new()
	camera.name = "Camera3D"
	rig.add_child(camera)
	harness.add_child(rig)
	var mount_a := Node3D.new()
	mount_a.position = Vector3(0, 1, 2)
	harness.add_child(mount_a)
	var mount_b := Node3D.new()
	mount_b.position = Vector3(2, 1, 3)
	harness.add_child(mount_b)
	await process_frame
	_check(rig.get_available_camera_modes().size() == 2, "normal O cycle remains Follow and God before a catch")
	rig.set_fight_camera_target(mount_a, POWERBOAT_MOUNT)
	rig.set_fight_camera_focus_progress(1.0)
	_check(is_equal_approx(rig._fight_camera_focus_progress, 1.0), "Fight Camera shifts its aim gradually by retrieval progress instead of tracking fish every frame")
	rig.set_fight_camera_focus_progress(0.0)
	_check(rig.begin_fight_camera(true), "hook enables the temporary Fight Camera mode")
	_check(rig.get_available_camera_modes().size() == 3 and rig.get_camera_mode_name() == "fight_camera", "Fight Camera joins the active O cycle and switches in")
	rig.trigger_fight_camera_impulse(0.75)
	_check(rig._fight_camera_impulse_velocity.length() > 0.0, "hook/struggle camera pulse adds a bounded damped impulse only in Fight Camera")
	rig.cycle_camera_view()
	_check(rig.get_camera_mode_name() == "follow", "manual O cycling can leave Fight Camera during the catch")
	_check(rig._fight_camera_impulse_velocity == Vector2.ZERO, "leaving Fight Camera clears its transient impulse")
	rig.end_fight_camera()
	_check(rig.get_camera_mode_name() == "follow", "ending catch preserves the player's manually selected ordinary view")
	rig.cycle_camera_view()
	_check(rig.get_camera_mode_name() == "god", "the ordinary O cycle still reaches God view")
	rig.set_fight_camera_target(mount_a, POWERBOAT_MOUNT)
	rig.begin_fight_camera(true)
	rig.end_fight_camera()
	_check(rig.get_camera_mode_name() == "god", "automatic Fight Camera restores the prior ordinary view if still active")
	rig.begin_fight_camera(false)
	_check(rig.get_camera_mode_name() == "god", "automatic camera switch can be disabled without disabling the catch")
	_check(rig.get_available_camera_modes().has("fight_camera"), "disabled auto-switch still exposes Fight Camera to O cycling")
	rig.set_fight_camera_target(mount_b, SAILBOAT_MOUNT)
	_check(rig.get_fight_camera_anchor() == mount_b, "active vessel changes update the current Fight Camera anchor")
	rig.end_fight_camera()
	rig.set_fight_camera_target(null, null)
	_check(not rig.get_available_camera_modes().has("fight_camera"), "unsupported vessel removes Fight Camera from the cycle")
	harness.queue_free()
	await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[FISHING_P3_1][PASS] %s" % message)
	else:
		_failures += 1
		push_error("[FISHING_P3_1][FAIL] %s" % message)
