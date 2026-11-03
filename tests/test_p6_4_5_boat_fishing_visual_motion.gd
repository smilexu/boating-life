extends SceneTree

const CASTING_SCRIPT := preload("res://scripts/boat_fishing_casting_system.gd")
const PARTICIPANT_CATALOG := preload("res://scripts/boat_fishing_fight_profile_catalog.gd")
const SOLVER_SCRIPT := preload("res://scripts/boat_fishing_fight_solver.gd")
const PARTICIPANT_SCRIPT := preload("res://scripts/boat_fishing_fight_participant.gd")
const PENDING_CATCH_SCRIPT := preload("res://scripts/fishing_pending_catch.gd")
const RENDERER_SCRIPT := preload("res://scripts/fish_school_renderer.gd")
const LINE_PROFILE: BoatFishingLineProfile = preload("res://resources/boat_fishing/line_profiles/standard_boat_fishing_line.tres")

var _failures := 0
var _maximum_mouth_error_m := 0.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_mouth_anchor_transform_for_boat_species()
	_test_single_jig_motion_does_not_require_line_payout()
	_test_motion_is_update_rate_stable()
	_test_sabiki_branches_move_independently_within_limits()
	_test_active_swim_direction_and_smooth_turns()
	print("[P6.4.5] max_mouth_hook_error=%.8fm failures=%d" % [_maximum_mouth_error_m, _failures])
	quit(1 if _failures > 0 else 0)


func _test_mouth_anchor_transform_for_boat_species() -> void:
	for species_id in ["herring", "sea_trout", "needlefish"]:
		var profile := load("res://resources/fish_species/%s.tres" % species_id) as FishSpeciesProfile
		_check(profile != null, "%s profile loads" % species_id)
		if profile == null:
			continue
		var heading := Vector3(0.31, 0.0, 0.95).normalized()
		var model_basis := RENDERER_SCRIPT.basis_for_model_heading(heading, profile.model_forward_axis)
		var scale_factor := maxf(0.05, profile.body_length_range_m.y / 1.2)
		var scaled_basis := model_basis.scaled(Vector3.ONE * scale_factor)
		var hook_world := Vector3(12.4, -2.3, 7.8)
		var fish_origin: Vector3 = CASTING_SCRIPT.mouth_anchored_fish_origin(hook_world, scaled_basis, profile.boat_fishing_mouth_anchor_local)
		var fish_transform := Transform3D(scaled_basis, fish_origin)
		var calculated_mouth: Vector3 = fish_transform * profile.boat_fishing_mouth_anchor_local
		var error_m := calculated_mouth.distance_to(hook_world)
		_maximum_mouth_error_m = maxf(_maximum_mouth_error_m, error_m)
		_check(error_m < 0.000001, "%s scaled/rotated mouth anchor stays at hook tip" % species_id)
		_check(profile.boat_fishing_mouth_anchor_local.length_squared() > 0.01, "%s uses a species-local mouth anchor" % species_id)


func _test_single_jig_motion_does_not_require_line_payout() -> void:
	var herring_profile := PARTICIPANT_CATALOG.load_profile("herring") as BoatFishingFightProfile
	var below_drag_solver := SOLVER_SCRIPT.new(LINE_PROFILE) as BoatFishingFightSolver
	var line_length_m := 10.0
	var hook_position := Vector3(line_length_m, 0.0, 0.0)
	var rod_tip := Vector3.ZERO
	var fixed_line := line_length_m
	for _frame in range(90):
		var solved: Dictionary = below_drag_solver.solve_step(
			1.0 / 30.0,
			line_length_m,
			0.55,
			100.0,
			false,
			LINE_PROFILE.default_drag_setting,
			[{"catch_id": "herring-motion", "current_pull_n": herring_profile.base_pull_n, "swim_direction": Vector3(0.0, 0.0, 1.0)}],
			Vector3.RIGHT
		)
		line_length_m += float(solved.get("line_delta_m", 0.0))
		hook_position = CASTING_SCRIPT.advance_tethered_hook_world(
			rod_tip,
			hook_position,
			Vector3(0.0, 0.0, 1.0),
			0.72,
			1.0 / 30.0,
			fixed_line
		)
	_check(is_equal_approx(line_length_m, fixed_line), "below-drag fish does not change paid-out line length")
	_check(hook_position.distance_to(rod_tip) <= fixed_line + 0.00001 and hook_position.distance_to(rod_tip) >= fixed_line - 0.00001, "single-jig hook remains on its authoritative line-length sphere")
	_check(hook_position.z > 1.6, "herring burst can move the hook laterally even when it cannot pay out line")
	print("[P6.4.5][MOTION] below-drag fixed-line side displacement=%.4fm" % hook_position.z)


func _test_motion_is_update_rate_stable() -> void:
	var simulation_30 := _simulate_participant_tether_motion(1.0 / 30.0)
	var simulation_60 := _simulate_participant_tether_motion(1.0 / 60.0)
	var position_30: Vector3 = simulation_30.get("position", Vector3.ZERO)
	var position_60: Vector3 = simulation_60.get("position", Vector3.ZERO)
	_check(absf(position_30.z - position_60.z) < 0.06, "30 and 60 FPS produce similar profile-driven fixed-line lateral movement")
	_check(absf(position_30.length() - 10.0) < 0.00001 and absf(position_60.length() - 10.0) < 0.00001, "lateral motion never changes tether radius")
	_check(float(simulation_30.get("max_side_m", 0.0)) > 0.15, "profile-driven herring fight produces measurable side movement below drag")
	_check(is_equal_approx(float(simulation_30.get("line_length_m", -1.0)), 10.0), "profile-driven below-drag struggle leaves authoritative paid-out line unchanged")
	print("[P6.4.5][MOTION] profile herring max side=%.4fm at fixed 10.0m line; 30fps endpoint delta=%.4fm" % [float(simulation_30.get("max_side_m", 0.0)), absf(position_30.z - position_60.z)])


func _simulate_participant_tether_motion(step: float) -> Dictionary:
	var pending := PENDING_CATCH_SCRIPT.new() as FishingPendingCatch
	pending.catch_id = "visual-motion-herring-fixed-seed"
	pending.species_id = "herring"
	pending.fishing_method = "boat_fishing"
	pending.hook_confirmed = true
	pending.body_length_m = 0.3
	var profile := PARTICIPANT_CATALOG.load_profile("herring") as BoatFishingFightProfile
	var participant := PARTICIPANT_SCRIPT.new() as BoatFishingFightParticipant
	if profile == null or not participant.initialize_from_pending_catch(pending, profile, 187, Vector3.RIGHT):
		return {"position": Vector3.ZERO, "max_side_m": 0.0, "line_length_m": -1.0}
	var position := Vector3(10.0, 0.0, 0.0)
	var max_side_m := 0.0
	var line_length_m := 10.0
	var solver := SOLVER_SCRIPT.new(LINE_PROFILE) as BoatFishingFightSolver
	var count := roundi(18.0 / step)
	for _frame in range(count):
		var snapshot := participant.advance(step, Vector3.RIGHT)
		var swim_direction: Vector3 = snapshot.get("swim_direction", Vector3.ZERO)
		var horizontal_outward := Vector3(swim_direction.x, 0.0, swim_direction.z).dot(Vector3.RIGHT)
		_check(horizontal_outward >= -0.0001, "participant never outputs active swimming toward the current hull") if _frame % maxi(1, count / 12) == 0 else null
		var solve_result := solver.solve_step(step, line_length_m, 0.55, 100.0, false, LINE_PROFILE.default_drag_setting, [snapshot], position.normalized())
		line_length_m = clampf(line_length_m + float(solve_result.get("line_delta_m", 0.0)), 0.55, 100.0)
		position = CASTING_SCRIPT.advance_tethered_hook_world(
			Vector3.ZERO,
			position,
			swim_direction,
			float(snapshot.get("swim_speed_mps", 0.0)),
			step,
			10.0
		)
		max_side_m = maxf(max_side_m, absf(position.z))
	return {"position": position, "max_side_m": max_side_m, "line_length_m": line_length_m}


func _test_sabiki_branches_move_independently_within_limits() -> void:
	var directions := [Vector3.RIGHT, Vector3.UP, Vector3.FORWARD, Vector3(1.0, 0.2, 1.0).normalized(), Vector3(-1.0, 0.4, 0.2).normalized()]
	var results: Array[Vector3] = []
	for direction in directions:
		var current := Vector3.LEFT
		for _frame in range(12):
			current = CASTING_SCRIPT.advance_bounded_branch_direction_world(current, direction, 1.3, 1.0 / 30.0, 0.18, Vector3.LEFT, deg_to_rad(52.0))
		results.append(current)
	var unique_directions := {}
	for index in range(results.size()):
		var rest := Vector3.LEFT
		var angle := acos(clampf(rest.dot(results[index]), -1.0, 1.0))
		var tip_displacement := (results[index] - rest).length() * 0.18
		_check(angle <= deg_to_rad(52.0) + 0.0001, "Sabiki branch remains within swing cone")
		_check(tip_displacement <= 0.18 * 2.0 * sin(deg_to_rad(26.0)) + 0.0001, "Sabiki hook stays within branch length")
		unique_directions[Vector3(snappedf(results[index].x, 0.01), snappedf(results[index].y, 0.01), snappedf(results[index].z, 0.01))] = true
	_check(unique_directions.size() >= 3, "five Sabiki hook branch motions are not synchronized")


func _test_active_swim_direction_and_smooth_turns() -> void:
	var inward := CASTING_SCRIPT.remove_inward_swim_direction(Vector3(-1.0, 0.25, 0.7), Vector3.RIGHT)
	_check(Vector3(inward.x, 0.0, inward.z).dot(Vector3.RIGHT) >= -0.000001, "inward swimming is removed while lateral and vertical motion remain")
	_check(absf(inward.z) > 0.1 and absf(inward.y) > 0.1, "hull constraint preserves lateral and depth movement")
	var heading := CASTING_SCRIPT.advance_heading_toward(Vector3.RIGHT, Vector3.LEFT, deg_to_rad(45.0))
	_check(rad_to_deg(Vector3.RIGHT.angle_to(heading)) <= 45.001, "fish facing turns toward an opposite target without a one-frame 180-degree flip")
	_check(heading.is_finite() and absf(heading.length() - 1.0) < 0.00001, "smoothed fish-facing direction stays normalized and finite")


func _check(condition: bool, message: String) -> void:
	if condition:
		print("[P6.4.5][PASS] %s" % message)
	else:
		_failures += 1
		push_error("[P6.4.5][FAIL] %s" % message)
