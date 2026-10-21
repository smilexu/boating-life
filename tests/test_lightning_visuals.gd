extends SceneTree

const LightningControllerScript := preload("res://scripts/lightning_event_controller.gd")
const BoltGeometryScript := preload("res://scripts/lightning_bolt_geometry.gd")

class FakeDayNightVisualController:
	extends Node
	var cloud_flash := 0.0
	var environment_flash := 0.0

	func set_lightning_flash_contributions(cloud_value: float, environment_value: float) -> void:
		cloud_flash = cloud_value
		environment_flash = environment_value

	func set_lightning_flash_strength(value: float) -> void:
		cloud_flash = value
		environment_flash = value

var _checks := 0
var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_authoritative_gate_and_local_override()
	_test_deterministic_event_schedule()
	_test_quality_profiles_and_event_lifecycle()
	_test_tree_geometry_and_distance_profiles()
	_test_frozen_preview_lifecycle()
	_test_branch_pulse_decay()
	_test_light_contribution_cleanup()
	if _failures.is_empty():
		print("Lightning visual tests: %d checks passed (headless scheduling and isolation)." % _checks)
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)


func _test_authoritative_gate_and_local_override() -> void:
	var controller := LightningControllerScript.new() as LightningEventController
	controller.set_random_seed(45012)
	_expect(is_empty(controller.advance_schedule(200.0)), "no formal signal and no local override produce no events")
	controller._on_formal_thunderstorm_changed({"available": false, "data_quality": "fresh"})
	_expect(is_empty(controller.advance_schedule(200.0)), "ordinary weather remains lightning-free")
	controller._on_formal_thunderstorm_changed({"available": true, "intensity": 0.32, "data_quality": "stale", "weather_symbol": "lightrainandthunder_day"})
	_expect(is_equal_approx(float(controller.get_diagnostic_state()["effective_intensity"]), 0.32), "formal symbol activates only its conservative forecast intensity")
	var formal_before := float(controller.get_diagnostic_state()["formal_intensity"])
	controller.set_debug_override(true, 0.8)
	_expect(is_equal_approx(float(controller.get_diagnostic_state()["formal_intensity"]), formal_before), "local debug override does not mutate formal storm signal")
	_expect(is_equal_approx(float(controller.get_diagnostic_state()["effective_intensity"]), 0.8), "local override affects presentation input only")
	controller.clear_debug_override()
	_expect(is_equal_approx(float(controller.get_diagnostic_state()["effective_intensity"]), formal_before), "clearing local override resumes the latest formal signal")
	controller._on_formal_thunderstorm_changed({"available": false, "data_quality": "fresh"})
	_expect(is_empty(controller.advance_schedule(300.0)), "cleared formal thunder signal stops future scheduled events")
	controller.free()


func _test_deterministic_event_schedule() -> void:
	var first := _collect_events(982341, 0.55, 900.0)
	var second := _collect_events(982341, 0.55, 900.0)
	var other_seed := _collect_events(982342, 0.55, 900.0)
	_expect(first.size() >= 3, "active storm schedules intermittent events over the simulated interval")
	_expect(first == second, "same seed and virtual time produce the same event timeline")
	_expect(first != other_seed, "independent lightning seed changes only the visual event sequence")
	var has_cloud := false
	var has_bolt := false
	var previous_interval := -1.0
	var interval_varies := false
	for event in first:
		var kind := str(event.get("type", ""))
		has_cloud = has_cloud or kind in ["in_cloud", "cloud_to_cloud"]
		has_bolt = has_bolt or kind in ["distant_cg", "near_cg"]
		var pulses: Array = event.get("pulses", [])
		_expect(pulses.size() >= 2 and pulses.size() <= 4, "each lightning event is limited to two to four short pulses")
		_expect(float(event.get("duration", 10.0)) < 1.0, "multiple discharge pulses remain under one second")
	_expect(has_cloud, "cloud lightning is represented in the scheduled event mix")
	_expect(has_bolt, "the scheduled event mix can include cloud-to-ground bolts")
	for index in range(1, first.size()):
		var interval := float(first[index].get("at", 0.0)) - float(first[index - 1].get("at", 0.0))
		if previous_interval >= 0.0 and absf(interval - previous_interval) > 0.1:
			interval_varies = true
		previous_interval = interval
	_expect(interval_varies, "event intervals vary instead of using a fixed flash timer")


func _collect_events(seed: int, intensity: float, seconds: float) -> Array[Dictionary]:
	var controller := LightningControllerScript.new() as LightningEventController
	controller.set_random_seed(seed)
	controller._on_formal_thunderstorm_changed({"available": true, "intensity": intensity, "data_quality": "fixture", "weather_symbol": "thunderstorm_fixture"})
	var events: Array[Dictionary] = []
	var elapsed := 0.0
	while elapsed < seconds:
		for event in controller.advance_schedule(1.0):
			var copy := event.duplicate(true)
			copy["at"] = elapsed + 1.0
			events.append(copy)
		elapsed += 1.0
	controller.free()
	return events


func _test_quality_profiles_and_event_lifecycle() -> void:
	var controller := LightningControllerScript.new() as LightningEventController
	for level in range(3):
		controller.set_quality_level(level)
		_expect(str(controller.get_diagnostic_state()["quality"]) in ["Low", "Medium", "High"], "quality level %d has a named profile" % level)
	controller.set_quality_level(LightningControllerScript.Quality.LOW)
	controller.set_random_seed(12)
	var low_has_near := false
	for index in range(200):
		var event := controller._make_scheduled_event(1.0)
		low_has_near = low_has_near or str(event.get("type", "")) == "near_cg"
	_expect(not low_has_near, "Low profile does not schedule nearby cloud-to-ground bolts")
	for event_type in ["in_cloud", "cloud_to_cloud", "distant_cg", "medium_cg", "near_cg"]:
		_expect(controller.trigger_debug_event(event_type), "R-panel test trigger accepts %s" % event_type)
		_expect(str(controller.get_diagnostic_state()["active_event_type"]) == event_type, "%s trigger selects its requested local visual" % event_type)
	var event: Dictionary = controller._active_event.duplicate(true)
	controller._update_active_event(float(event.get("duration", 0.0)) + 0.05)
	_expect(controller._active_event.is_empty(), "flash contribution clears after the event ends")
	_expect(float(controller.get_diagnostic_state()["flash_level"]) == 0.0, "lightning has no residual ambient contribution after the flash")
	controller.clear_debug_override()
	_expect(not bool(controller.get_diagnostic_state()["debug_override_active"]), "local storm override can be cleared independently")
	controller.free()


func _test_tree_geometry_and_distance_profiles() -> void:
	var near := BoltGeometryScript.build("near_cg", 713901, LightningControllerScript.Quality.MEDIUM, 0.85, 1.65, 1.35, 1.0, 1.0)
	var same_seed := BoltGeometryScript.build("near_cg", 713901, LightningControllerScript.Quality.MEDIUM, 0.85, 1.65, 1.35, 1.0, 1.0)
	var other_seed := BoltGeometryScript.build("near_cg", 713902, LightningControllerScript.Quality.MEDIUM, 0.85, 1.65, 1.35, 1.0, 1.0)
	_expect(near["vertices"] == same_seed["vertices"] and near["indices"] == same_seed["indices"], "fixed seed reproduces identical lightning geometry")
	_expect(near["vertices"] != other_seed["vertices"], "different visual seed produces a different bolt shape")
	_expect(int(near["primary_branch_count"]) >= 6 and int(near["primary_branch_count"]) <= 10, "Medium near bolt has the target range of pronounced primary branches")
	_expect(int(near["secondary_branch_count"]) >= 18 and int(near["secondary_branch_count"]) <= 30, "Medium near bolt has a dense secondary branch layer")
	_expect(int(near["path_count"]) == 1 + int(near["primary_branch_count"]) + int(near["secondary_branch_count"]), "tree geometry contains one trunk and attached branch paths")
	var main_path: Array = near["paths"][0]["points"]
	var maximum_lateral_offset := 0.0
	for point_value in main_path:
		var point: Vector3 = point_value
		maximum_lateral_offset = maxf(maximum_lateral_offset, Vector2(point.x, point.z).length())
	_expect(main_path.size() >= 25 and maximum_lateral_offset > 120.0, "main trunk has visible multi-scale curvature instead of a small jitter")
	var primary_paths: Array[Array] = []
	for path_data_value in near["paths"]:
		var path_data: Dictionary = path_data_value
		if str(path_data["kind"]) == "primary":
			primary_paths.append(path_data["points"])
	var primary_attachments_valid := true
	for primary_path in primary_paths:
		var attached_to_trunk := false
		for point_value in main_path:
			if (primary_path[0] as Vector3).distance_to(point_value) < 0.001:
				attached_to_trunk = true
		primary_attachments_valid = primary_attachments_valid and attached_to_trunk
	var secondary_attachments_valid := true
	var secondary_count := 0
	for path_data_value in near["paths"]:
		var path_data: Dictionary = path_data_value
		if str(path_data["kind"]) != "secondary":
			continue
		secondary_count += 1
		var attached_to_primary := false
		for parent_path in primary_paths:
			for point_value in parent_path:
				if (path_data["points"][0] as Vector3).distance_to(point_value) < 0.001:
					attached_to_primary = true
		secondary_attachments_valid = secondary_attachments_valid and attached_to_primary
	_expect(primary_attachments_valid and primary_paths.size() == int(near["primary_branch_count"]), "primary branches start on separate points of the main trunk")
	_expect(secondary_attachments_valid and secondary_count == int(near["secondary_branch_count"]), "secondary branches attach to an interior point of a primary branch")
	_expect(float(near["main_core_radius"]) > 2.0 and float(near["main_halo_radius"]) > float(near["main_aura_radius"]), "near bolt has thick core, wider aura, and wider soft halo")
	_expect(float(near["max_segment_length"]) < 500.0, "fractal path subdivision prevents excessively long straight segments")
	var vertices: PackedVector3Array = near["vertices"]
	var indices: PackedInt32Array = near["indices"]
	var colors: PackedColorArray = near["colors"]
	var finite_vertices := true
	for vertex in vertices:
		finite_vertices = finite_vertices and is_finite(vertex.x) and is_finite(vertex.y) and is_finite(vertex.z)
	_expect(finite_vertices and vertices.size() == colors.size(), "batched mesh has finite vertices with matching color data")
	var has_secondary_dimmed_alpha := false
	var has_full_main_core_alpha := false
	for color in colors:
		has_secondary_dimmed_alpha = has_secondary_dimmed_alpha or is_equal_approx(color.a, 0.98 * 0.52)
		has_full_main_core_alpha = has_full_main_core_alpha or is_equal_approx(color.a, 0.98)
	_expect(has_secondary_dimmed_alpha and has_full_main_core_alpha, "main core remains brightest while secondary branch cores are dimmer")
	var valid_indices := true
	for index_value in indices:
		valid_indices = valid_indices and index_value >= 0 and index_value < vertices.size()
	_expect(valid_indices and indices.size() % 3 == 0, "batched mesh indices are valid triangles")
	var medium := BoltGeometryScript.build("medium_cg", 713901, LightningControllerScript.Quality.MEDIUM, 0.85)
	var distant := BoltGeometryScript.build("distant_cg", 713901, LightningControllerScript.Quality.MEDIUM, 0.85)
	_expect(float(medium["main_core_radius"]) < float(near["main_core_radius"]), "medium bolt is narrower than near bolt")
	_expect(float(distant["main_core_radius"]) < float(medium["main_core_radius"]), "distant bolt is narrower than medium bolt")
	var low := BoltGeometryScript.build("near_cg", 44, LightningControllerScript.Quality.LOW, 0.85)
	var high := BoltGeometryScript.build("near_cg", 44, LightningControllerScript.Quality.HIGH, 0.85)
	_expect(int(low["vertex_count"]) < int(near["vertex_count"]) and int(near["vertex_count"]) < int(high["vertex_count"]), "Low, Medium, High profiles scale mesh complexity in order")
	var no_bolt := BoltGeometryScript.build("in_cloud", 12, LightningControllerScript.Quality.MEDIUM, 0.7)
	_expect(int(no_bolt["vertex_count"]) == 0, "in-cloud-only flash does not produce a ground-bolt mesh")
	var scheduler := LightningControllerScript.new() as LightningEventController
	scheduler.set_random_seed(9001)
	var scheduler_state_before := int(scheduler._schedule_rng.state)
	scheduler.set_debug_visual_seed(112233)
	scheduler.trigger_debug_event("near_cg")
	_expect(int(scheduler._schedule_rng.state) == scheduler_state_before, "manual visual triggers use a seed stream separate from formal event scheduling")
	_expect(int(scheduler._active_event["seed"]) == 112233, "manual test bolt receives the configured reproducible visual seed")
	scheduler.free()


func _test_frozen_preview_lifecycle() -> void:
	var controller := LightningControllerScript.new() as LightningEventController
	controller.set_random_seed(80211)
	controller.set_quality_level(LightningControllerScript.Quality.MEDIUM)
	controller.set_preview_frozen(true)
	var frozen_before: Dictionary = controller.get_diagnostic_state()
	controller._update_active_event(20.0)
	var frozen_after: Dictionary = controller.get_diagnostic_state()
	_expect(bool(frozen_before["preview_frozen"]) and bool(frozen_after["preview_frozen"]), "geometry freeze preview holds the event across arbitrary elapsed time")
	_expect(str(frozen_after["active_event_type"]) == "near_cg" and float(frozen_after["flash_level"]) > 0.0, "freeze preview creates a visible near bolt for camera inspection")
	controller.set_preview_frozen(false)
	controller._update_active_event(2.0)
	_expect(not bool(controller.get_diagnostic_state()["preview_frozen"]), "unfreezing resumes the ordinary flash lifecycle")
	controller.clear_debug_override()
	_expect(controller.get_diagnostic_state()["active_event_type"] == "none", "closing the local override clears a frozen developer event")
	controller.free()


func _test_branch_pulse_decay() -> void:
	var controller := LightningControllerScript.new() as LightningEventController
	var pulses: Array = [{"start": 0.0, "duration": 0.1, "amplitude": 1.0}]
	var levels: Dictionary = controller.get_branch_pulse_levels(0.035, pulses)
	_expect(float(levels["secondary"]) < float(levels["primary"]) and float(levels["primary"]) < 1.0, "fine branches fade before primary branches during a discharge pulse")
	var later_levels: Dictionary = controller.get_branch_pulse_levels(0.075, pulses)
	_expect(float(later_levels["secondary"]) < 0.04 and float(later_levels["primary"]) < float(levels["primary"]), "secondary branches disappear quickly while the trunk and main branches decay more slowly")
	controller.free()


func _test_light_contribution_cleanup() -> void:
	var controller := LightningControllerScript.new() as LightningEventController
	var visual := FakeDayNightVisualController.new()
	controller._day_night_visual_controller = visual
	controller.set_cloud_flash_multiplier(0.7)
	controller.set_environment_flash_multiplier(0.45)
	controller.set_preview_frozen(true)
	_expect(visual.cloud_flash > 0.0 and visual.environment_flash > 0.0, "frozen near flash reaches the cloud and environment composition inputs")
	_expect(is_equal_approx(visual.cloud_flash, 0.86 * 0.7) and is_equal_approx(visual.environment_flash, 0.86 * 0.45), "cloud and environment flash contributions use their independent debug multipliers")
	controller.clear_debug_override()
	_expect(is_zero_approx(visual.cloud_flash) and is_zero_approx(visual.environment_flash), "ending the event clears transient lighting without accumulation")
	visual.free()
	controller.free()


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append("%s" % description)


func is_empty(value: Variant) -> bool:
	return value is Array and value.is_empty()
