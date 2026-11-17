extends SceneTree

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var reel_material := StandardMaterial3D.new()
	var reel_parts := FishingRodRig.create_reel_assembly(reel_material, reel_material)
	var reel_root := reel_parts["root"] as Node3D
	var rotor := reel_parts["rotating_assembly"] as Node3D
	var spool := reel_parts["spool"] as MeshInstance3D
	var winding := reel_parts["winding_visual"] as MultiMeshInstance3D
	var side_plate := reel_root.get_node_or_null("ReelFrame/ReelSidePlateLeft") as MeshInstance3D
	root.add_child(reel_root)
	_check(reel_root.get_node_or_null("ReelSeat") != null, "Shared reel assembly contains a rod seat")
	_check(side_plate != null and side_plate.mesh is CylinderMesh and is_equal_approx((side_plate.mesh as CylinderMesh).height, 0.006), "Fixed drum side covers are thin discs on the reel frame")
	_check(spool != null and spool.get_parent() == rotor, "Shared trolling and handheld drum reels rotate the spool with the winding assembly")
	_check(winding != null and winding.multimesh != null and winding.multimesh.instance_count == FishingRodRig.REEL_WINDING_RING_COUNT and winding.visible, "Shared drum reel keeps a fixed, always-visible winding representation")
	_check(is_equal_approx(FishingRodRig.get_reel_winding_thickness_m(0.0), FishingRodRig.REEL_LINE_LAYER_MAX_THICKNESS_M), "Empty spool has the visible maximum winding layer")
	_check(is_equal_approx(FishingRodRig.get_reel_winding_thickness_m(50.0), FishingRodRig.REEL_LINE_LAYER_MIN_THICKNESS_M), "Visual payout range reaches its minimum winding thickness at 50 m")
	_check(is_equal_approx(FishingRodRig.get_reel_winding_thickness_m(100.0), FishingRodRig.REEL_LINE_LAYER_MIN_THICKNESS_M), "Winding remains visible at its minimum after the visual range")
	var reel_line_exit := FishingRodRig.get_reel_line_exit_local(0.0)
	_check(
		reel_line_exit.distance_to(FishingRodRig.REEL_SPOOL_CENTER_LOCAL) > FishingRodRig.REEL_SPOOL_CORE_RADIUS_M
		and reel_line_exit.y < FishingRodRig.REEL_SPOOL_CENTER_LOCAL.y,
		"External line exits from the lower outer winding tangent, not the spool axle"
	)
	var thin_winding_radius := FishingRodRig.get_reel_spool_outer_radius_m(50.0)
	_check(thin_winding_radius < FishingRodRig.get_reel_spool_outer_radius_m(0.0), "External line tangent follows the changing winding thickness")
	var line_guide := reel_parts["line_guide"] as MeshInstance3D
	_check(
		line_guide != null
		and line_guide.position.is_equal_approx(FishingRodRig.get_reel_line_guide_local())
		and line_guide.position.y < spool.position.y
		and line_guide.position.z > spool.position.z,
		"Shared line route places its fixed fairlead below and forward of the drum"
	)
	FishingRodRig.set_reel_winding_line_length_on_visual(winding, 0.0)
	var full_ring_transform := winding.multimesh.get_instance_transform(0)
	FishingRodRig.set_reel_winding_line_length_on_visual(winding, 50.0)
	var thin_ring_transform := winding.multimesh.get_instance_transform(0)
	if RenderingServer.get_rendering_device() != null:
		var spool_axis := rotor.transform.basis * Vector3.UP
		var winding_axis := rotor.transform.basis * thin_ring_transform.basis.y.normalized()
		var first_ring := winding.multimesh.get_instance_transform(0)
		var second_ring := winding.multimesh.get_instance_transform(1)
		var ring_spacing := second_ring.origin - first_ring.origin
		_check(
			is_equal_approx(thin_ring_transform.basis.y.length(), full_ring_transform.basis.y.length())
			and is_equal_approx(thin_ring_transform.origin.y, full_ring_transform.origin.y)
			and thin_ring_transform.basis.x.length() < full_ring_transform.basis.x.length()
			and is_equal_approx(thin_ring_transform.basis.x.length(), thin_ring_transform.basis.z.length())
			and absf(spool_axis.normalized().dot(winding_axis.normalized())) > 0.99
			and absf(ring_spacing.normalized().dot(Vector3.UP)) > 0.99,
			"Winding coils wrap the spool axle while radial thickness changes and axial spacing remains fixed"
		)
	else:
		print("SKIP: Headless dummy renderer does not expose MultiMesh instance transforms; Forward+ verification covers radial winding updates")
	FishingRodRig.set_reel_winding_line_length_on_visual(winding, 100.0)
	_check(winding.visible, "Payout beyond the visual range keeps winding visible at minimum thickness")
	FishingRodRig.set_reel_winding_line_length_on_visual(winding, 0.0)
	_check(rotor != null and rotor.find_child("ReelHandleArm", true, false) is MeshInstance3D and rotor.find_child("ReelHandleKnob", true, false) is MeshInstance3D, "Shared rotor contains visible crank and handle parts")
	var handheld_parts := FishingRodRig.create_reel_assembly(reel_material, reel_material, -1.0, true, false)
	var handheld_root := handheld_parts["root"] as Node3D
	root.add_child(handheld_root)
	var handheld_rotor := handheld_parts["rotating_assembly"] as Node3D
	var handheld_winding := handheld_parts["winding_visual"] as MultiMeshInstance3D
	_check(
		handheld_winding != null
		and handheld_winding.multimesh != null
		and handheld_winding.multimesh.instance_count == 1
		and handheld_winding.multimesh.mesh is CylinderMesh
		and handheld_winding.get_parent() == handheld_rotor,
		"Handheld line uses one rotating, low-frequency winding shell instead of sub-pixel ring instances"
	)
	var full_shell_thickness := FishingRodRig.set_reel_winding_line_length_on_visual(handheld_winding, 0.0)
	var full_shell_transform := handheld_winding.multimesh.get_instance_transform(0)
	var thin_shell_thickness := FishingRodRig.set_reel_winding_line_length_on_visual(handheld_winding, 50.0)
	var thin_shell_transform := handheld_winding.multimesh.get_instance_transform(0)
	_check(
		is_equal_approx(full_shell_thickness, FishingRodRig.REEL_LINE_LAYER_MAX_THICKNESS_M)
		and is_equal_approx(thin_shell_thickness, FishingRodRig.REEL_LINE_LAYER_MIN_THICKNESS_M),
		"Handheld winding shell keeps the existing line-length-to-layer-thickness range"
	)
	if RenderingServer.get_rendering_device() != null:
		_check(
			thin_shell_transform.basis.x.length() < full_shell_transform.basis.x.length()
			and is_equal_approx(thin_shell_transform.basis.y.length(), full_shell_transform.basis.y.length())
			and is_equal_approx(thin_shell_transform.basis.z.length(), thin_shell_transform.basis.x.length()),
			"Handheld winding shell changes only radial thickness as paid-out length changes"
		)
	var handheld_handle := handheld_rotor.find_child("ReelHandleArm", true, false) as MeshInstance3D
	var trolling_handle := rotor.find_child("ReelHandleArm", true, false) as MeshInstance3D
	var handheld_knob := handheld_rotor.find_child("ReelHandleKnob", true, false) as MeshInstance3D
	var trolling_spoke := rotor.get_node_or_null("ReelSpokeL0") as MeshInstance3D
	var handheld_handle_root_position := handheld_root.to_local(handheld_handle.global_position) if handheld_handle != null else Vector3.ZERO
	var trolling_handle_root_position := reel_root.to_local(trolling_handle.global_position) if trolling_handle != null else Vector3.ZERO
	var handheld_knob_root_position := handheld_root.to_local(handheld_knob.global_position) if handheld_knob != null else Vector3.ZERO
	var handheld_has_star_spokes := false
	for child in handheld_rotor.get_children():
		if String(child.name).begins_with("ReelSpoke"):
			handheld_has_star_spokes = true
	_check(not handheld_has_star_spokes, "Handheld boat-fishing reel omits the alias-prone star spokes")
	_check(trolling_spoke != null, "Trolling reel retains its star spokes")
	if trolling_handle != null and trolling_spoke != null:
		var rotor_base_basis := rotor.transform.basis
		BoatFishingCastingSystem.set_reel_rotating_assembly_phase(rotor, rotor_base_basis, 0.0)
		rotor.force_update_transform()
		trolling_handle.force_update_transform()
		trolling_spoke.force_update_transform()
		var initial_axis := (rotor.global_basis * Vector3.UP).normalized()
		var initial_handle_axis := trolling_handle.global_basis.x.normalized()
		var initial_spoke_axis := trolling_spoke.global_basis.x.normalized()
		var fixed_phase_offset := _signed_angle_around_axis(initial_spoke_axis, initial_handle_axis, initial_axis)
		for phase_variant in [0.0, 0.25, 0.9, 0.3, 0.3]:
			var phase := float(phase_variant)
			BoatFishingCastingSystem.set_reel_rotating_assembly_phase(rotor, rotor_base_basis, phase)
			rotor.force_update_transform()
			trolling_handle.force_update_transform()
			trolling_spoke.force_update_transform()
			var current_axis := (rotor.global_basis * Vector3.UP).normalized()
			var handle_phase := _signed_angle_around_axis(initial_handle_axis, trolling_handle.global_basis.x, current_axis)
			var spoke_phase := _signed_angle_around_axis(initial_spoke_axis, trolling_spoke.global_basis.x, current_axis)
			var current_offset := _signed_angle_around_axis(trolling_spoke.global_basis.x, trolling_handle.global_basis.x, current_axis)
			_check(
				absf(wrapf(handle_phase - phase, -PI, PI)) < 0.001
				and absf(wrapf(spoke_phase - phase, -PI, PI)) < 0.001
				and absf(wrapf(current_offset - fixed_phase_offset, -PI, PI)) < 0.001,
				"Trolling crank and star spokes follow one rotor phase through speed changes, reversal, and stop"
			)
	_check(handheld_handle != null and handheld_handle_root_position.x > 0.0, "Handheld crank is mounted on the player's screen-left side of the spool")
	_check(handheld_knob != null and handheld_knob_root_position.x > 0.0, "Handheld crank knob sits on the same screen-left side as its arm")
	_check(trolling_handle != null and absf(trolling_handle_root_position.x - handheld_handle_root_position.x) > 0.05, "Trolling reel keeps its original crank placement while the handheld reel is mirrored")
	if rotor != null:
		var rotor_before := rotor.rotation
		var reel_in_speed := BoatFishingCastingSystem.get_reel_visual_speed_rad_s(-1.0, 0.0)
		rotor.rotate_object_local(Vector3.UP, FishingRodRig.REEL_ROTATION_SIGN * reel_in_speed * 0.1)
		_check(reel_in_speed > 0.0 and not rotor.rotation.is_equal_approx(rotor_before), "Line retrieval maps to the existing positive reel-in animation direction")
		var rotor_after_retrieve := rotor.rotation
		var payout_speed := BoatFishingCastingSystem.get_reel_visual_speed_rad_s(1.0, 0.0)
		rotor.rotate_object_local(Vector3.UP, FishingRodRig.REEL_ROTATION_SIGN * payout_speed * 0.1)
		_check(reel_in_speed > 0.0 and payout_speed < 0.0 and not rotor.rotation.is_equal_approx(rotor_after_retrieve), "Payout reverses the same drum rotor using the shared trolling axis and sign")

	var cast_targets := BoatFishingCastingSystem.get_boat_fishing_audio_targets(BoatFishingCastingSystem.CastState.CASTING, 0.4, false, false, false, true, false)
	_check(bool(cast_targets["line_out"]) and not bool(cast_targets["reel_in"]), "Bait flight requests line-out audio only")
	var landed_targets := BoatFishingCastingSystem.get_boat_fishing_audio_targets(BoatFishingCastingSystem.CastState.CASTING, 0.0, false, false, false, true, true)
	_check(not bool(landed_targets["line_out"]), "Landed bait no longer requests the cast line-out loop")
	var stationary_cast_targets := BoatFishingCastingSystem.get_boat_fishing_audio_targets(BoatFishingCastingSystem.CastState.CASTING, 0.0, false, false, false, true, false)
	_check(not bool(stationary_cast_targets["line_out"]), "Cast state without measured line extension remains silent")
	var manual_reel_targets := BoatFishingCastingSystem.get_boat_fishing_audio_targets(BoatFishingCastingSystem.CastState.WAITING, -0.05, true, false, false, false, true)
	_check(bool(manual_reel_targets["reel_in"]) and not bool(manual_reel_targets["drag"]), "Manual shortening requests reel-in but not drag audio")
	var manual_payout_targets := BoatFishingCastingSystem.get_boat_fishing_audio_targets(BoatFishingCastingSystem.CastState.WAITING, 0.05, false, true, false, false, true)
	_check(bool(manual_payout_targets["line_out"]) and not bool(manual_payout_targets["drag"]), "Manual payout requests line-out without a fish-pull drag sound")
	var auto_reel_targets := BoatFishingCastingSystem.get_boat_fishing_audio_targets(BoatFishingCastingSystem.CastState.WAITING, -0.05, false, false, true, false, true)
	_check(bool(auto_reel_targets["reel_in"]) and not bool(auto_reel_targets["drag"]), "Automatic shortening requests reel-in from authoritative line movement")
	var auto_drag_targets := BoatFishingCastingSystem.get_boat_fishing_audio_targets(BoatFishingCastingSystem.CastState.WAITING, 0.05, false, false, true, false, true)
	_check(bool(auto_drag_targets["drag"]) and not bool(auto_drag_targets["reel_in"]), "Automatic line payout requests drag audio")
	var no_motion_targets := BoatFishingCastingSystem.get_boat_fishing_audio_targets(BoatFishingCastingSystem.CastState.WAITING, 0.0, true, false, false, false, true)
	_check(not bool(no_motion_targets["reel_in"]) and not bool(no_motion_targets["drag"]), "No line-length change keeps mechanical loops silent")
	_check(BoatFishingCastingSystem.get_reel_visual_speed_rad_s(-1.0, 0.0) > 0.0, "Measured retrieval produces positive reel-in speed before the shared rotation sign")
	_check(BoatFishingCastingSystem.get_reel_visual_speed_rad_s(1.0, 0.0) < 0.0, "Measured payout produces the opposite drum speed")
	_check(is_equal_approx(absf(BoatFishingCastingSystem.get_reel_visual_speed_rad_s(-1.0, 0.0)), 1.0 / FishingRodRig.get_reel_spool_outer_radius_m(0.0)), "Drum angular speed follows measured line speed and effective spool radius")

	var audio_system := FishingRodSystem.new()
	audio_system.set_external_fishing_audio_loop(&"boat_fishing_test", "reel_in", true)
	var audio_diagnostics: Dictionary = audio_system.get_trolling_audio_diagnostics()
	var external_requests: Dictionary = audio_diagnostics["external_loop_requests"]
	var owner_requests: Dictionary = external_requests.get(&"boat_fishing_test", {})
	_check(bool(owner_requests.get("reel_in", false)), "Boat Fishing can request the shared reel loop through FishingRodSystem")
	audio_system.clear_external_fishing_audio_loops(&"boat_fishing_test")
	var cleared_audio_diagnostics: Dictionary = audio_system.get_trolling_audio_diagnostics()
	var cleared_external_requests: Dictionary = cleared_audio_diagnostics["external_loop_requests"]
	_check(not cleared_external_requests.has(&"boat_fishing_test"), "Clearing Boat Fishing removes its shared loop ownership")
	audio_system.free()

	var casting := BoatFishingCastingSystem.new()
	casting.set("_activity_active", true)
	_check(casting.report_catch_succeeded("test-catch-batch"), "A confirmed catch batch accepts its one-shot success cue")
	_check(not casting.report_catch_succeeded("test-catch-batch"), "The same catch batch cannot replay its success cue")
	_check(int(casting.get_debug_snapshot()["fishing_audio_event_counts"]["catch_success"]) == 1, "Catch success cue is counted exactly once per batch")
	casting.set("_activity_active", false)
	_check(not casting.report_catch_succeeded("inactive-catch-batch"), "An inactive Boat Fishing activity cannot report a success cue")
	casting.free()
	handheld_root.free()
	reel_root.free()
	print("[P6_2_5_REEL_AUDIO] failures=%d" % _failures)
	quit(0 if _failures == 0 else 1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		_failures += 1
		push_error("FAIL: %s" % message)


func _signed_angle_around_axis(from: Vector3, to: Vector3, axis: Vector3) -> float:
	var first := (from - axis * from.dot(axis)).normalized()
	var second := (to - axis * to.dot(axis)).normalized()
	return atan2(axis.dot(first.cross(second)), clampf(first.dot(second), -1.0, 1.0))
