extends SceneTree
## Offline S1-C5a experiment driver. It instantiates the actual SailboatLab
## RigidBody3D and reuses its production force calculations. All pressure-center
## changes are confined to this temporary test instance.

const LAB_SCENE := preload("res://scenes/SailboatLab.tscn")
const PROFILE := preload("res://resources/sailing/sailboat_lab_profile.tres")
const AERO := preload("res://scripts/sailboat_aero_math.gd")
const KNOTS_PER_MPS := 1.9438444924406
const TEST_SEED := 481516
const CHECKPOINTS := [5, 10, 20, 30, 60, 90, 120]
const SAIL_HEAD := Vector3(0.0, 4.45, 0.04)
const SAIL_TACK := Vector3(0.0, 0.08, 0.0)
const SAIL_CLEW := Vector3(0.0, 0.08, 4.65)
const PRESSURE_OFFSETS_M := [-1.0, -0.75, -0.5, -0.25, 0.0, 0.25, 0.5, 0.75, 1.0]
const INITIAL_SPEEDS_KNOTS := [0.0, 0.5, 1.0, 2.0, 3.0]
const TRIM_ANGLES_DEG := [10.0, 20.0, 30.0, 40.0, 50.0, 60.0]
const RUDDER_HELM_DEG := [0.0, -5.0, -10.0, 5.0, 10.0, 15.0]
const AERO_WIND_FROM_DEG := [-180.0, -150.0, -120.0, -90.0, -60.0, -45.0, 45.0, 60.0, 90.0, 120.0, 150.0, 180.0]
const AERO_TRIMS_DEG := [-80.0, -70.0, -60.0, -50.0, -40.0, -30.0, -20.0, -10.0, 0.0, 10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0]
const DURATION_SECONDS := 120

var _lab: Node3D
var _boat: RigidBody3D
var _wind: Node
var _step_seconds := 1.0 / 60.0
var _failures: Array[String] = []
var _pressure_rows: Array[String] = []
var _speed_rows: Array[String] = []
var _trim_rows: Array[String] = []
var _rudder_rows: Array[String] = []
var _aero_rows: Array[String] = []
var _pressure_summaries: Array[Dictionary] = []
var _selected_offsets: Array[float] = []
var _profile_pc_before := Vector3.ZERO
var _dynamic_cases_completed := 0
var _static_only := false
var _smoke_only := false
var _run_started_usec := 0
var _offset_axis := "boat_longitudinal"
var _output_prefix := "s1_c5a"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_run_started_usec = Time.get_ticks_usec()
	_step_seconds = 1.0 / float(Engine.physics_ticks_per_second)
	if Engine.physics_ticks_per_second != 60:
		_failures.append("Expected the project fixed physics rate to be 60 Hz; got %d Hz." % Engine.physics_ticks_per_second)
	var world_time := root.get_node_or_null("WorldTimeManager")
	if world_time != null:
		# The diagnostics use fixed local physics, not the player's persisted world clock.
		world_time.set("autosave_enabled", false)
	_profile_pc_before = PROFILE.get("main_sail_pressure_center_from_pivot_m")
	print("[S1-C5a] fixed_dt=%.8fs seed=%d duration=%ds; no production resource overrides" % [_step_seconds, TEST_SEED, DURATION_SECONDS])
	for argument in OS.get_cmdline_user_args():
		if argument == "--static-only":
			_static_only = true
		elif argument == "--smoke-only":
			_smoke_only = true
		elif argument == "--chordwise-only":
			_offset_axis = "sail_chord"
			_output_prefix = "s1_c5a_chordwise"
	if _static_only:
		_run_aero_matrix()
		_finish()
		return
	if _smoke_only:
		var first := await _run_case("pressure", 0.0, 30.0, 270.0, 0.0, 0.0)
		var second := await _run_case("pressure", 0.0, 30.0, 270.0, 0.0, 0.0, 2)
		if not _same_checkpoint_signature(first, second, [5, 30, 120], 0.002):
			_failures.append("Fresh-scene baseline repeat differed beyond 0.002 units at checkpoints 5/30/120.")
		_finish()
		return
	if _offset_axis == "sail_chord":
		_run_aero_matrix()
		await _run_pressure_center_scan(_offset_axis)
		_selected_offsets = _select_offsets_for_followup(_offset_axis, 1)
		print("[S1-C5a] geometry-valid chordwise candidate for follow-up: %s" % str(_selected_offsets))
		await _run_initial_speed_scan()
		await _run_trim_scan()
		await _run_rudder_scan()
		var chord_pc_after: Vector3 = PROFILE.get("main_sail_pressure_center_from_pivot_m")
		if not chord_pc_after.is_equal_approx(_profile_pc_before):
			_failures.append("The shared test Resource changed during the chordwise scan.")
		_write_outputs()
		if _lab != null and is_instance_valid(_lab):
			_lab.queue_free()
			await process_frame
		_finish()
		return

	_run_aero_matrix()
	await _run_pressure_center_scan(_offset_axis)
	_selected_offsets = _select_offsets_for_followup(_offset_axis)
	print("[S1-C5a] selected representative offsets for follow-up: %s" % str(_selected_offsets))
	await _run_initial_speed_scan()
	await _run_trim_scan()
	await _run_rudder_scan()

	var profile_pc_after: Vector3 = PROFILE.get("main_sail_pressure_center_from_pivot_m")
	if not profile_pc_after.is_equal_approx(_profile_pc_before):
		_failures.append("The shared test Resource changed during the scan.")
	_write_outputs()
	_lab.queue_free()
	await process_frame
	_finish()


func _run_pressure_center_scan(offset_axis: String) -> void:
	for offset_m in PRESSURE_OFFSETS_M:
		var summary := await _run_case("pressure", offset_m, 30.0, 270.0, 0.0, 0.0, 1, offset_axis)
		_pressure_summaries.append(summary)
		_write_outputs()
		var final: Dictionary = summary["checkpoints"][120]
		print("[S1-C5a] PC %+.2fm · HDG120 %.1f° · fwd120 %+.3fm/s · SOG120 %.3fkn · max yaw %.2f°/s" % [
			offset_m, float(final["heading"]), float(final["forward_speed"]), float(final["sog_knots"]), float(summary["max_yaw_deg_s"])
		])
	# Re-run the unchanged baseline to detect state leakage or nondeterminism.
	var repeat := await _run_case("pressure", 0.0, 30.0, 270.0, 0.0, 0.0, 2, offset_axis)
	var baseline: Dictionary = _pressure_summaries[4]
	if not _same_checkpoint_signature(baseline, repeat, [5, 30, 120], 0.002):
		_failures.append("The repeated baseline differed beyond 0.002 units at checkpoints 5/30/120.")
	_pressure_summaries.append(repeat)
	_write_outputs()
	print("[S1-C5a] %s pressure-center scan complete: %d offsets plus deterministic repeat" % [offset_axis, PRESSURE_OFFSETS_M.size()])


func _run_initial_speed_scan() -> void:
	for offset_m in _selected_offsets:
		for initial_knots in INITIAL_SPEEDS_KNOTS:
			var summary := await _run_case("speed", offset_m, 30.0, 270.0, initial_knots, 0.0, 1, _offset_axis)
			_write_summary_checkpoints(_speed_rows, offset_m, initial_knots, summary)
		_write_outputs()
	print("[S1-C5a] initial-speed scan complete: %d cases" % (_selected_offsets.size() * INITIAL_SPEEDS_KNOTS.size()))


func _run_trim_scan() -> void:
	var trim_offsets := _selected_offsets.slice(0, mini(2, _selected_offsets.size()))
	for offset_m in trim_offsets:
		for sail_magnitude in TRIM_ANGLES_DEG:
			for tack in ["port_wind", "starboard_wind"]:
				var wind_from := 270.0 if tack == "port_wind" else 90.0
				var sail_angle: float = sail_magnitude if tack == "port_wind" else -sail_magnitude
				var summary := await _run_case("trim", offset_m, sail_angle, wind_from, 0.0, 0.0, 1, _offset_axis)
				_write_trim_checkpoints(offset_m, tack, wind_from, sail_angle, summary)
		_write_outputs()
	print("[S1-C5a] mirrored trim scan complete: %d cases" % (trim_offsets.size() * TRIM_ANGLES_DEG.size() * 2))


func _run_rudder_scan() -> void:
	var rudder_offsets := _selected_offsets.slice(0, mini(2, _selected_offsets.size()))
	for offset_m in rudder_offsets:
		for initial_knots in [0.0, 1.0, 2.0]:
			for helm_deg in RUDDER_HELM_DEG:
				var summary := await _run_case("rudder", offset_m, 30.0, 270.0, initial_knots, helm_deg, 1, _offset_axis)
				_write_rudder_checkpoints(offset_m, initial_knots, helm_deg, summary)
		_write_outputs()
	print("[S1-C5a] sustained-helm scan complete: %d cases" % (rudder_offsets.size() * 3 * RUDDER_HELM_DEG.size()))


func _run_case(
	group: String,
	offset_m: float,
	sail_deg: float,
	wind_from_deg: float,
	initial_speed_knots: float,
	helm_deg: float,
	repeat_index: int = 1,
	offset_axis: String = "boat_longitudinal"
) -> Dictionary:
	await _spawn_fresh_lab()
	await _prepare_case(offset_m, sail_deg, wind_from_deg, initial_speed_knots, helm_deg, offset_axis)
	var initial_position: Vector3 = _boat.global_position
	var initial_basis: Basis = _boat.global_basis
	var initial_forward := (initial_basis * Vector3(0.0, 0.0, -1.0)).normalized()
	var initial_right := (initial_basis * Vector3.RIGHT).normalized()
	var initial_heading := _heading_degrees()
	var unwrapped_heading := initial_heading
	var previous_heading := initial_heading
	var maximum_yaw_deg_s := 0.0
	var rudder_yaw_last30_sum := 0.0
	var rudder_yaw_last30_count := 0
	var checkpoints: Dictionary = {}
	var total_steps := DURATION_SECONDS * Engine.physics_ticks_per_second
	for step_index in range(1, total_steps + 1):
		await physics_frame
		var sample: Dictionary = _boat.call("get_s1_c4_diagnostic_snapshot")
		var sim_time := float(step_index) * _step_seconds
		var heading := float(sample["heading_degrees"])
		unwrapped_heading += wrapf(heading - previous_heading, -180.0, 180.0)
		previous_heading = heading
		var yaw_deg_s := rad_to_deg(float(sample["yaw_rate_rad_s"]))
		maximum_yaw_deg_s = maxf(maximum_yaw_deg_s, absf(yaw_deg_s))
		if sim_time > 90.0:
			rudder_yaw_last30_sum += float(sample["rudder_yaw_torque_local_nm"])
			rudder_yaw_last30_count += 1
		if step_index % Engine.physics_ticks_per_second == 0:
			var second := int(round(sim_time))
			if CHECKPOINTS.has(second):
				var displacement: Vector3 = sample["position_world_m"] - initial_position
				var record := {
					"sim_time": second,
					"heading": heading,
					"heading_unwrapped": unwrapped_heading,
					"sog_knots": float(sample["sog_mps"]) * KNOTS_PER_MPS,
					"forward_speed": float(sample["longitudinal_velocity_mps"]),
					"lateral_speed": float(sample["lateral_velocity_mps"]),
					"forward_displacement": displacement.dot(initial_forward),
					"cross_displacement": displacement.dot(initial_right),
					"yaw_rate_deg_s": yaw_deg_s,
					"max_yaw_deg_s": maximum_yaw_deg_s,
					"sail_forward_n": -Vector3(sample["sail_force_local_n"]).z,
					"sail_lateral_n": Vector3(sample["sail_force_local_n"]).x,
					"sail_yaw_nm": float(sample["sail_yaw_torque_local_nm"]),
					"keel_yaw_nm": float(sample["keel_yaw_torque_local_nm"]),
					"rudder_yaw_nm": float(sample["rudder_yaw_torque_local_nm"]),
					"hull_drag_forward_n": -Vector3(sample["hull_drag_force_local_n"]).z,
					"total_yaw_nm": float(sample["summed_measured_yaw_torque_local_nm"]),
					"luffing": float(sample["sail_luffing_scale"]),
					"apparent_from_deg": float(sample["apparent_wind_from_angle_degrees"]),
					"heel_deg": float(sample["roll_degrees"]),
					"actual_rudder_deg": rad_to_deg(float(sample["actual_rudder_angle_rad"])),
				}
				checkpoints[second] = record
				if group == "pressure":
					_write_pressure_checkpoint(offset_m, repeat_index, record, sail_deg, offset_axis)
				if second % 30 == 0:
					print("[S1-C5a] %s PC%+.2f sail%+.0f helm%+.0f v0%.1f · %ds HDG %.1f° SOG %.2fkn" % [
						group, offset_m, sail_deg, helm_deg, initial_speed_knots, second, heading, float(sample["sog_mps"]) * KNOTS_PER_MPS
					])
	_dynamic_cases_completed += 1
	return {
		"group": group,
		"offset_m": offset_m,
		"sail_deg": sail_deg,
		"wind_from_deg": wind_from_deg,
		"initial_speed_knots": initial_speed_knots,
		"helm_deg": helm_deg,
		"max_yaw_deg_s": maximum_yaw_deg_s,
		"mean_rudder_yaw_last30_nm": rudder_yaw_last30_sum / maxf(float(rudder_yaw_last30_count), 1.0),
		"checkpoints": checkpoints,
	}


func _prepare_case(offset_m: float, sail_deg: float, wind_from_deg: float, initial_speed_knots: float, helm_deg: float, offset_axis: String) -> void:
	_boat.call("set_dynamic_waves_enabled", false)
	_boat.call("set_water_current_world_velocity", Vector3.ZERO)
	_wind.call("set_random_seed", TEST_SEED)
	_wind.set("gust_direction_variation_degrees", 0.0)
	_wind.call("set_test_simulation_time", 0.0)
	if not bool(_boat.call("set_lab_test_wind", 8.0, wind_from_deg)):
		_failures.append("Could not apply isolated test wind %.1f°." % wind_from_deg)
	_boat.call("reset_to_neutral", 0.0)
	_boat.call("set_target_sail_angle", deg_to_rad(sail_deg))
	_boat.call("set_target_rudder_angle", deg_to_rad(helm_deg))
	_boat.set("actual_sail_angle_rad", deg_to_rad(sail_deg))
	_boat.set("actual_rudder_angle_rad", 0.0)
	await physics_frame
	await physics_frame
	var base_pc: Vector3 = PROFILE.get("main_sail_pressure_center_from_pivot_m")
	# The requested scan axis is boat-local +Z/-Z. Convert that hull-frame
	# displacement back into the sail pivot frame before the production body
	# rotates the force-center vector with the boom angle.
	var sail_local_delta := Vector3(0.0, 0.0, offset_m)
	if offset_axis == "boat_longitudinal":
		var hull_longitudinal_delta := Vector3(0.0, 0.0, offset_m)
		sail_local_delta = Basis(Vector3.UP, -deg_to_rad(sail_deg)) * hull_longitudinal_delta
	_boat.set("_sail_pressure_center_from_pivot_m", base_pc + sail_local_delta)
	var float_offsets: PackedVector3Array = PROFILE.get("float_point_offsets_m")
	var mean_float_y := 0.0
	for point in float_offsets:
		mean_float_y += point.y
	mean_float_y /= maxf(float(float_offsets.size()), 1.0)
	var initial_y := -float(PROFILE.get("rest_submergence_m")) - mean_float_y
	_boat.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, initial_y, 0.0))
	_boat.linear_velocity = Vector3(0.0, 0.0, -initial_speed_knots / KNOTS_PER_MPS)
	_boat.angular_velocity = Vector3.ZERO
	_boat.set("actual_sail_angle_rad", deg_to_rad(sail_deg))
	_boat.set("actual_rudder_angle_rad", 0.0)
	_boat.call("set_target_sail_angle", deg_to_rad(sail_deg))
	_boat.call("set_target_rudder_angle", deg_to_rad(helm_deg))


func _spawn_fresh_lab() -> void:
	if _lab != null and is_instance_valid(_lab):
		_lab.queue_free()
		await process_frame
	_lab = LAB_SCENE.instantiate() as Node3D
	root.add_child(_lab)
	await process_frame
	_boat = _lab.get_node_or_null("SailboatBody") as RigidBody3D
	_wind = _lab.get_node_or_null("WindField")
	if _boat == null or _wind == null:
		_failures.append("SailboatLab did not provide SailboatBody and WindField.")
		return
	_lab.call("set_dynamic_waves_enabled", false)
	var wave_sampler := _lab.get_node_or_null("WaveSampler")
	if wave_sampler != null:
		wave_sampler.set_process(false)
		wave_sampler.set_physics_process(false)
	if not bool(_boat.call("can_set_lab_test_wind")):
		_failures.append("The lab WindField is not available for isolated test control.")


func _run_aero_matrix() -> void:
	var base_pc: Vector3 = PROFILE.get("main_sail_pressure_center_from_pivot_m")
	var pivot: Vector3 = PROFILE.get("main_sail_pivot_local_m")
	var center_of_mass: Vector3 = PROFILE.get("center_of_mass_m")
	var area := float(PROFILE.get("main_sail_area_m2"))
	var air_density := float(PROFILE.get("air_density_kg_m3"))
	var max_cl := float(PROFILE.get("sail_max_lift_coefficient"))
	var stall_angle := float(PROFILE.get("sail_stall_angle_rad"))
	var base_cd := float(PROFILE.get("sail_base_drag_coefficient"))
	var induced_drag := float(PROFILE.get("sail_induced_drag_factor"))
	var flat_drag := float(PROFILE.get("sail_flat_plate_drag_factor"))
	var no_sail := float(PROFILE.get("no_sail_wind_from_angle_rad"))
	var full_lift := float(PROFILE.get("full_lift_wind_from_angle_rad"))
	for wind_from_deg in AERO_WIND_FROM_DEG:
		for sail_deg in AERO_TRIMS_DEG:
			var angle_rad := deg_to_rad(wind_from_deg)
			var flow_local := Vector3(-sin(angle_rad), 0.0, cos(angle_rad)) * 8.0
			var result: Dictionary = AERO.calculate_sail_forces(
				flow_local, deg_to_rad(sail_deg), area, air_density, max_cl, stall_angle,
				base_cd, induced_drag, flat_drag, no_sail, full_lift
			)
			var lift: Vector3 = result["lift_force_local_n"]
			var drag: Vector3 = result["drag_force_local_n"]
			var force: Vector3 = result["net_force_local_n"]
			var pc := pivot + Basis(Vector3.UP, deg_to_rad(sail_deg)) * (base_pc + Vector3(0.0, 0.0, 0.0))
			var moment := (pc - center_of_mass).cross(force)
			var side := _trim_side_label(wind_from_deg, sail_deg)
			_aero_rows.append(_csv([
				_num(wind_from_deg), _wind_side_label(wind_from_deg), _num(sail_deg), side, _num(float(result["apparent_speed_mps"])),
				_num(rad_to_deg(float(result["angle_of_attack_rad"]))), _num(float(result["luffing_scale"])), _num(float(result["cl"])), _num(float(result["cd"])),
				_num(float(result["dynamic_pressure_pa"])), _num(-lift.z), _num(lift.x), _num(-drag.z), _num(drag.x), _num(-force.z), _num(force.x),
				_num(pc.x), _num(pc.y), _num(pc.z), _num(moment.y), _num(moment.z),
			]))
	_write_outputs()
	print("[S1-C5a] fixed-heading sail-force consistency matrix: %d cases" % (AERO_WIND_FROM_DEG.size() * AERO_TRIMS_DEG.size()))


func _write_pressure_checkpoint(offset_m: float, repeat_index: int, r: Dictionary, sail_deg: float, offset_axis: String) -> void:
	var base_pc: Vector3 = PROFILE.get("main_sail_pressure_center_from_pivot_m")
	var pivot: Vector3 = PROFILE.get("main_sail_pivot_local_m")
	var sail_rotation := Basis(Vector3.UP, deg_to_rad(sail_deg))
	var pc_relative_boat := sail_rotation * base_pc + Vector3(0.0, 0.0, offset_m)
	if offset_axis == "sail_chord":
		pc_relative_boat = sail_rotation * (base_pc + Vector3(0.0, 0.0, offset_m))
	var pc_relative_sail := sail_rotation.inverse() * pc_relative_boat
	var actual_pc := pivot + pc_relative_boat
	var inside_sail_projection := _point_is_inside_sail_triangle(pc_relative_sail)
	_pressure_rows.append(_csv([
		_num(offset_m), str(repeat_index), str(r["sim_time"]), _num(actual_pc.x), _num(actual_pc.y), _num(actual_pc.z),
		_num(absf(pc_relative_sail.x)), _num(pc_relative_sail.z), str(inside_sail_projection).to_lower(),
		_num(float(r["heading"])), _num(float(r["heading_unwrapped"])), _num(float(r["sog_knots"])), _num(float(r["forward_speed"])), _num(float(r["lateral_speed"])),
		_num(float(r["forward_displacement"])), _num(float(r["cross_displacement"])), _num(float(r["yaw_rate_deg_s"])), _num(float(r["max_yaw_deg_s"])),
		_num(float(r["sail_yaw_nm"])), _num(float(r["keel_yaw_nm"])), _num(float(r["rudder_yaw_nm"])), _num(float(r["hull_drag_forward_n"])), _num(float(r["total_yaw_nm"])),
		_num(float(r["luffing"])), _num(float(r["apparent_from_deg"])), _num(float(r["heel_deg"])),
	]))


func _write_summary_checkpoints(rows: Array[String], offset_m: float, initial_knots: float, summary: Dictionary) -> void:
	for second in [30, 120]:
		var r: Dictionary = summary["checkpoints"][second]
		rows.append(_csv([
			_num(offset_m), _num(initial_knots), str(second), _num(float(r["heading"])), _num(float(r["heading_unwrapped"])), _num(float(r["sog_knots"])),
			_num(float(r["forward_speed"])), _num(float(r["lateral_speed"])), _num(float(r["forward_displacement"])), _num(float(r["cross_displacement"])),
			_num(float(r["yaw_rate_deg_s"])), _num(float(r["max_yaw_deg_s"])), _num(float(r["sail_forward_n"])), _num(float(r["sail_yaw_nm"])),
			_num(float(r["keel_yaw_nm"])), _num(float(r["rudder_yaw_nm"])), _num(float(r["luffing"])), _num(float(r["apparent_from_deg"])), _num(float(r["heel_deg"])),
		]))


func _write_trim_checkpoints(offset_m: float, tack: String, wind_from_deg: float, sail_deg: float, summary: Dictionary) -> void:
	for second in [30, 120]:
		var r: Dictionary = summary["checkpoints"][second]
		_trim_rows.append(_csv([
			_num(offset_m), tack, _num(wind_from_deg), _num(sail_deg), str(second), _num(float(r["heading"])), _num(float(r["heading_unwrapped"])), _num(float(r["sog_knots"])),
			_num(float(r["forward_speed"])), _num(float(r["lateral_speed"])), _num(float(r["forward_displacement"])), _num(float(r["cross_displacement"])),
			_num(float(r["yaw_rate_deg_s"])), _num(float(r["max_yaw_deg_s"])), _num(float(r["sail_forward_n"])), _num(float(r["sail_lateral_n"])),
			_num(float(r["sail_yaw_nm"])), _num(float(r["keel_yaw_nm"])), _num(float(r["rudder_yaw_nm"])), _num(float(r["luffing"])), _num(float(r["apparent_from_deg"])), _num(float(r["heel_deg"])),
		]))


func _write_rudder_checkpoints(offset_m: float, initial_knots: float, helm_deg: float, summary: Dictionary) -> void:
	var side := "starboard" if helm_deg > 0.0 else "port" if helm_deg < 0.0 else "centered"
	for second in [30, 120]:
		var r: Dictionary = summary["checkpoints"][second]
		_rudder_rows.append(_csv([
			_num(offset_m), _num(initial_knots), side, _num(helm_deg), _num(float(r["actual_rudder_deg"])), str(second), _num(float(r["heading"])), _num(float(r["heading_unwrapped"])),
			_num(float(r["sog_knots"])), _num(float(r["forward_speed"])), _num(float(r["lateral_speed"])), _num(float(r["forward_displacement"])), _num(float(r["cross_displacement"])),
			_num(float(r["yaw_rate_deg_s"])), _num(float(r["max_yaw_deg_s"])), _num(float(summary["mean_rudder_yaw_last30_nm"])), _num(float(r["rudder_yaw_nm"])),
			_num(float(r["sail_yaw_nm"])), _num(float(r["keel_yaw_nm"])), _num(float(r["luffing"])), _num(float(r["apparent_from_deg"])), _num(float(r["heel_deg"])),
		]))


func _select_offsets_for_followup(offset_axis: String, nonzero_limit: int = 2) -> Array[float]:
	var candidates: Array[Dictionary] = []
	for summary in _pressure_summaries:
		var offset_m := float(summary["offset_m"])
		if is_zero_approx(offset_m):
			continue
		if offset_axis == "sail_chord" and not _chordwise_pc_inside_sail(offset_m):
			continue
		var cp: Dictionary = summary["checkpoints"]
		var fwd30 := float(cp[30]["forward_speed"])
		var fwd60 := float(cp[60]["forward_speed"])
		var fwd120 := float(cp[120]["forward_speed"])
		var heading5 := absf(float(cp[5]["heading_unwrapped"]))
		var max_yaw := float(summary["max_yaw_deg_s"])
		var score := (fwd30 + fwd60 + fwd120) / 3.0 - max_yaw * 0.015 - heading5 * 0.001
		candidates.append({"offset_m": offset_m, "score": score, "max_yaw": max_yaw, "fwd120": fwd120})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
	var selected: Array[float] = [0.0]
	for candidate in candidates:
		if selected.size() >= nonzero_limit + 1:
			break
		selected.append(float(candidate["offset_m"]))
	return selected


func _chordwise_pc_inside_sail(offset_m: float) -> bool:
	var pc: Vector3 = PROFILE.get("main_sail_pressure_center_from_pivot_m")
	return _point_is_inside_sail_triangle(pc + Vector3(0.0, 0.0, offset_m))


func _point_is_inside_sail_triangle(point: Vector3) -> bool:
	if absf(point.x) > 0.01 or point.y < SAIL_TACK.y or point.y > SAIL_HEAD.y:
		return false
	var height_fraction := inverse_lerp(SAIL_HEAD.y, SAIL_TACK.y, point.y)
	var luff_z := lerpf(SAIL_HEAD.z, SAIL_TACK.z, height_fraction)
	var leech_z := lerpf(SAIL_HEAD.z, SAIL_CLEW.z, height_fraction)
	return point.z >= minf(luff_z, leech_z) - 0.0001 and point.z <= maxf(luff_z, leech_z) + 0.0001


func _same_checkpoint_signature(a: Dictionary, b: Dictionary, seconds: Array, tolerance: float) -> bool:
	for second in seconds:
		var ar: Dictionary = a["checkpoints"][second]
		var br: Dictionary = b["checkpoints"][second]
		for key in ["heading_unwrapped", "sog_knots", "forward_speed", "lateral_speed", "forward_displacement", "sail_yaw_nm", "luffing"]:
			if absf(float(ar[key]) - float(br[key])) > tolerance:
				return false
	return true


func _trim_side_label(wind_from_deg: float, sail_deg: float) -> String:
	if absf(absf(wind_from_deg) - 180.0) < 0.001:
		return "astern_side_ambiguous"
	if is_zero_approx(sail_deg):
		return "centerline_trim"
	return "same_sign_as_wind_from" if signf(sail_deg) == signf(wind_from_deg) else "opposite_sign_to_wind_from"


func _wind_side_label(wind_from_deg: float) -> String:
	if absf(absf(wind_from_deg) - 180.0) < 0.001:
		return "astern"
	return "starboard" if wind_from_deg > 0.0 else "port"


func _heading_degrees() -> float:
	return float(_boat.call("get_s1_c4_diagnostic_snapshot")["heading_degrees"])


func _write_outputs() -> void:
	var base_path := ProjectSettings.globalize_path("res://docs/sailing/c5a_data")
	DirAccess.make_dir_recursive_absolute(base_path)
	if not _static_only:
		_write_text(base_path.path_join("%s_pressure_center_scan.csv" % _output_prefix), "offset_from_current_pc_m,repeat_index,sim_time_s,pc_local_x_m,pc_local_y_m,pc_local_z_m,pc_distance_from_sail_plane_m,pc_chord_projection_m,pc_inside_visual_triangle,heading_deg,heading_unwrapped_deg,sog_knots,longitudinal_velocity_mps,lateral_velocity_mps,forward_displacement_initial_axis_m,cross_displacement_initial_axis_m,yaw_rate_deg_s,max_abs_yaw_rate_deg_s,sail_yaw_torque_local_nm,keel_yaw_torque_local_nm,rudder_yaw_torque_local_nm,hull_drag_force_forward_n,total_measured_yaw_torque_local_nm,luffing_scale,apparent_wind_from_relative_deg,heel_deg\n" + "\n".join(_pressure_rows) + "\n")
		_write_text(base_path.path_join("%s_initial_speed_scan.csv" % _output_prefix), "offset_from_current_pc_m,initial_speed_knots,sim_time_s,heading_deg,heading_unwrapped_deg,sog_knots,longitudinal_velocity_mps,lateral_velocity_mps,forward_displacement_initial_axis_m,cross_displacement_initial_axis_m,yaw_rate_deg_s,max_abs_yaw_rate_deg_s,sail_forward_force_n,sail_yaw_torque_local_nm,keel_yaw_torque_local_nm,rudder_yaw_torque_local_nm,luffing_scale,apparent_wind_from_relative_deg,heel_deg\n" + "\n".join(_speed_rows) + "\n")
		_write_text(base_path.path_join("%s_sail_trim_scan.csv" % _output_prefix), "offset_from_current_pc_m,tack,wind_from_deg,sail_angle_deg,sim_time_s,heading_deg,heading_unwrapped_deg,sog_knots,longitudinal_velocity_mps,lateral_velocity_mps,forward_displacement_initial_axis_m,cross_displacement_initial_axis_m,yaw_rate_deg_s,max_abs_yaw_rate_deg_s,sail_forward_force_n,sail_lateral_force_n,sail_yaw_torque_local_nm,keel_yaw_torque_local_nm,rudder_yaw_torque_local_nm,luffing_scale,apparent_wind_from_relative_deg,heel_deg\n" + "\n".join(_trim_rows) + "\n")
		_write_text(base_path.path_join("%s_rudder_scan.csv" % _output_prefix), "offset_from_current_pc_m,initial_speed_knots,helm_side,helm_target_deg,actual_rudder_deg,sim_time_s,heading_deg,heading_unwrapped_deg,sog_knots,longitudinal_velocity_mps,lateral_velocity_mps,forward_displacement_initial_axis_m,cross_displacement_initial_axis_m,yaw_rate_deg_s,max_abs_yaw_rate_deg_s,mean_rudder_yaw_torque_last30_nm,rudder_yaw_torque_local_nm,sail_yaw_torque_local_nm,keel_yaw_torque_local_nm,luffing_scale,apparent_wind_from_relative_deg,heel_deg\n" + "\n".join(_rudder_rows) + "\n")
	_write_text(base_path.path_join("%s_aero_consistency.csv" % _output_prefix), "wind_from_relative_deg,wind_from_side,sail_angle_deg,trim_sign_vs_wind_from,apparent_speed_mps,angle_of_attack_deg,luffing_scale,cl,cd,dynamic_pressure_pa,lift_forward_n,lift_lateral_n,drag_forward_n,drag_lateral_n,total_forward_force_n,total_lateral_force_n,pressure_center_local_x_m,pressure_center_local_y_m,pressure_center_local_z_m,yaw_moment_local_nm,roll_moment_local_nm\n" + "\n".join(_aero_rows) + "\n")


func _write_text(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_failures.append("Could not write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return
	file.store_string(content)
	file.close()


func _csv(values: Array) -> String:
	var text_values: Array[String] = []
	for value in values:
		text_values.append(str(value))
	return ",".join(text_values)


func _num(value: float) -> String:
	return "%.6f" % value


func _finish() -> void:
	if not _failures.is_empty():
		for failure in _failures:
			push_error("[S1-C5a] " + failure)
		quit(1)
		return
	var elapsed_seconds := float(Time.get_ticks_usec() - _run_started_usec) / 1000000.0
	print("[S1-C5a] completed %d physical cases, %d aerodynamic cases in %.2fs. CSV output: docs/sailing/c5a_data/" % [_dynamic_cases_completed, _aero_rows.size(), elapsed_seconds])
	quit(0)
