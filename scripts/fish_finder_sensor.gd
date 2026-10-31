class_name FishFinderSensor
extends Node

## Samples immutable, bounded sonar columns from the shared fish authority.
## The sensor is read-only and never creates, moves, or consumes fish.

signal scan_completed(result: Dictionary)

@export_category("Sonar")
@export_range(10.0, 1000.0, 5.0) var max_slant_range_m := 220.0
@export_range(1.0, 45.0, 0.5) var beam_half_cone_angle_deg := 10.0
@export_range(1.0, 100.0, 1.0) var maximum_water_depth_m := 45.0
@export_range(0.1, 20.0, 0.1) var scan_frequency_hz := 3.0
@export_range(1, 1800, 1) var history_capacity := 180
@export_range(0.0, 600.0, 5.0) var minimum_history_seconds := 60.0
@export var automatic_scanning_enabled := true
@export var transducer_offset_local_m := Vector3(0.0, -0.55, 0.0)
@export_range(-500.0, 500.0, 0.1) var chart_datum_world_y_m := 0.0
@export_range(0.0, 5.0, 0.1) var seabed_clearance_m := 0.6
@export_range(0.05, 2.0, 0.05) var school_echo_width_per_sqrt_fish_m := 0.22
@export_range(0.2, 5.0, 0.1) var maximum_visual_echo_width_m := 2.5
@export_range(1.0, 1.5, 0.01) var school_distribution_radius_margin := 1.1
@export_range(1.0, 16.0, 0.5) var maximum_school_distribution_radius_m := 8.0
@export_range(0.1, 2.0, 0.05) var minimum_school_vertical_half_thickness_m := 0.4
@export_range(0.5, 3.0, 0.05) var maximum_school_vertical_half_thickness_m := 1.5

const MAX_DIAGNOSTIC_SCHOOLS := 16
const VOLUME_SAMPLE_FRACTIONS := [-1.0, -0.5, 0.0, 0.5, 1.0]
const VOLUME_SAMPLE_WEIGHTS := [1.0, 4.0, 2.0, 4.0, 1.0]
const MIN_OVERLAP_FOR_ECHO := 0.0001

var _manager: Node
var _boat: Node3D
var _bathymetry: Node
var _wave_sampler: Node
var _history: Array[Dictionary] = []
var _last_scan_runtime_seconds := -INF
var _next_auto_scan_runtime_seconds := -INF
var _scan_sequence := 0


func _ready() -> void:
	set_process(true)


func configure(manager: Node, boat: Node3D, bathymetry: Node, wave_sampler: Node) -> void:
	_manager = manager
	_boat = boat
	_bathymetry = bathymetry
	_wave_sampler = wave_sampler


func _process(_delta: float) -> void:
	if not automatic_scanning_enabled:
		return
	var now := _runtime_seconds()
	if now < _next_auto_scan_runtime_seconds:
		return
	var interval := 1.0 / maxf(scan_frequency_hz, 0.1)
	_next_auto_scan_runtime_seconds = now + interval
	_perform_scan(now)


func scan(force: bool = false) -> Dictionary:
	var now := _runtime_seconds()
	var interval := 1.0 / maxf(scan_frequency_hz, 0.1)
	if not force and now - _last_scan_runtime_seconds < interval:
		return {"accepted": false, "reason": "scan_interval", "last_scan": get_last_scan()}
	_next_auto_scan_runtime_seconds = now + interval
	return _perform_scan(now)


func _perform_scan(scan_runtime_seconds: float) -> Dictionary:
	_last_scan_runtime_seconds = scan_runtime_seconds
	_scan_sequence += 1
	var active_vessel := _resolve_active_vessel()
	var result := {
		"accepted": false,
		"valid": false,
		"scan_id": _scan_sequence,
		"scan_runtime_seconds": scan_runtime_seconds,
		"scan_game_time_seconds": _game_time_seconds(),
		"scan_unix_time_seconds": Time.get_unix_time_from_system(),
		"active_vessel_id": _active_vessel_id(active_vessel),
		"boat_speed_mps": _active_vessel_speed_mps(active_vessel),
		"scan_origin_world_position": Vector3.ZERO,
		"probe_world_position": Vector3.ZERO,
		"bathymetry_valid": false,
		"surface_valid": false,
		"bottom_valid": false,
		"chart_depth_lat_m": -1.0,
		"seabed_world_y_m": 0.0,
		"surface_height_world_y_m": 0.0,
		"water_column_below_surface_m": -1.0,
		"bottom_depth_below_transducer_m": -1.0,
		"effective_detection_depth_range_below_transducer_m": Vector2.ZERO,
		"query_radius_m": max_slant_range_m,
		"beam_half_cone_angle_deg": beam_half_cone_angle_deg,
		"max_slant_range_m": max_slant_range_m,
		"scan_frequency_hz": scan_frequency_hz,
		"schools_considered_count": 0,
		"schools_detected_count": 0,
		"school_diagnostics": [],
		"echoes": [],
		"reason": "dependencies_unavailable",
	}
	if _manager == null or active_vessel == null or _bathymetry == null or _wave_sampler == null:
		return _finish_scan(result)

	var probe_world_position: Vector3 = active_vessel.global_transform * transducer_offset_local_m
	var probe_xz := Vector3(probe_world_position.x, 0.0, probe_world_position.z)
	result["scan_origin_world_position"] = probe_world_position
	result["probe_world_position"] = probe_world_position
	var bathymetry: Dictionary = _bathymetry.call("get_depth_at_world_position", probe_xz)
	if not bool(bathymetry.get("valid", false)):
		result["reason"] = str(bathymetry.get("reason", "bathymetry_unavailable"))
		return _finish_scan(result)
	var chart_depth := float(bathymetry.get("depth_m", -1.0))
	if not is_finite(chart_depth) or chart_depth <= 0.0:
		result["reason"] = "invalid_chart_depth"
		return _finish_scan(result)
	result["bathymetry_valid"] = true
	result["chart_depth_lat_m"] = chart_depth
	result["seabed_world_y_m"] = chart_datum_world_y_m - chart_depth
	result["bathymetry_source"] = str(bathymetry.get("source", ""))
	result["bathymetry_vertical_datum"] = str(bathymetry.get("vertical_datum", ""))
	result["bathymetry_quality"] = float(bathymetry.get("quality", -1.0))
	result["bathymetry_estimated"] = bool(bathymetry.get("estimated", false))
	result["bathymetry_interpolated"] = bool(bathymetry.get("interpolated", false))
	result["bathymetry_value_count"] = int(bathymetry.get("value_count", -1))
	result["bathymetry_estimate_confidence"] = str(bathymetry.get("estimate_confidence", ""))

	var wave_time := float(_wave_sampler.get("wave_time_seconds"))
	var surface_sample: Dictionary = _wave_sampler.call("sample_physics_surface", probe_xz, wave_time)
	var surface_y := float(surface_sample.get("height", NAN))
	if not is_finite(surface_y):
		result["reason"] = "surface_sample_unavailable"
		return _finish_scan(result)
	result["surface_valid"] = true
	result["surface_height_world_y_m"] = surface_y
	var seabed_y := chart_datum_world_y_m - chart_depth
	var water_column := surface_y - seabed_y
	var bottom_depth_below_transducer := probe_world_position.y - seabed_y
	result["water_column_below_surface_m"] = maxf(water_column, 0.0)
	result["bottom_depth_below_transducer_m"] = bottom_depth_below_transducer
	if water_column <= 0.0 or bottom_depth_below_transducer <= 0.0:
		result["reason"] = "transducer_below_seabed_or_no_water"
		return _finish_scan(result)
	result["bottom_valid"] = true
	var detection_depth_max := minf(
		max_slant_range_m,
		minf(bottom_depth_below_transducer, maximum_water_depth_m + maxf(surface_y - probe_world_position.y, 0.0))
	)
	result["effective_detection_depth_range_below_transducer_m"] = Vector2(0.0, detection_depth_max)

	if not _manager.has_method("get_schools_near"):
		result["reason"] = "authority_query_unavailable"
		return _finish_scan(result)
	var query_radius := max_slant_range_m + maximum_school_distribution_radius_m
	result["query_radius_m"] = query_radius
	var schools: Array[Dictionary] = _manager.call("get_schools_near", probe_world_position, query_radius)
	var echoes: Array[Dictionary] = []
	var school_diagnostics: Array[Dictionary] = []
	for school in schools:
		var school_id := str(school.get("school_id", ""))
		var species_id := str(school.get("species_id", ""))
		var anchor := _school_position(school)
		var diagnostic := {
			"school_id": school_id,
			"species_id": species_id,
			"population": maxi(0, int(school.get("population", 0))),
			"authority_anchor_world_position": anchor,
			"activity_depth_m": float(school.get("activity_depth_m", -1.0)),
			"anchor_horizontal_distance_m": -1.0,
			"target_world_position": Vector3(NAN, NAN, NAN),
			"target_depth_below_transducer_m": -1.0,
			"vertical_distance_m": -1.0,
			"beam_radius_m": -1.0,
			"slant_range_m": -1.0,
			"anchor_geometry_reason": "invalid_geometry",
			"effective_school_radius_m": -1.0,
			"vertical_half_thickness_m": -1.0,
			"effective_vertical_thickness_m": 0.0,
			"coverage_factor": 0.0,
			"overlap_factor": 0.0,
			"final_echo_strength": 0.0,
			"aggregation_method": "ellipsoid_beam_overlap_v1",
			"detection_depth_limit_m": detection_depth_max,
			"hit": false,
			"rejection_reason": "",
		}
		var population := maxi(0, int(school.get("population", 0)))
		if population <= 0:
			diagnostic["rejection_reason"] = "empty_population"
			_remember_school_diagnostic(school_diagnostics, diagnostic)
			continue
		if not _is_finite_vector3(anchor):
			diagnostic["rejection_reason"] = "invalid_school_position"
			_remember_school_diagnostic(school_diagnostics, diagnostic)
			continue
		var anchor_horizontal_distance := Vector2(anchor.x - probe_world_position.x, anchor.z - probe_world_position.z).length()
		diagnostic["anchor_horizontal_distance_m"] = anchor_horizontal_distance
		var school_xz := Vector3(anchor.x, 0.0, anchor.z)
		var school_bathymetry: Dictionary = _bathymetry.call("get_depth_at_world_position", school_xz)
		if not bool(school_bathymetry.get("valid", false)):
			diagnostic["rejection_reason"] = "school_bathymetry_invalid"
			_remember_school_diagnostic(school_diagnostics, diagnostic)
			continue
		var school_chart_depth := float(school_bathymetry.get("depth_m", -1.0))
		if not is_finite(school_chart_depth) or school_chart_depth <= 0.0:
			diagnostic["rejection_reason"] = "school_bathymetry_invalid"
			_remember_school_diagnostic(school_diagnostics, diagnostic)
			continue
		var activity_depth := float(school.get("activity_depth_m", 0.0))
		diagnostic["activity_depth_m"] = activity_depth
		if not is_finite(activity_depth) or activity_depth < 0.0:
			diagnostic["rejection_reason"] = "activity_depth_invalid"
			_remember_school_diagnostic(school_diagnostics, diagnostic)
			continue
		var school_surface := _sample_surface_y(school_xz, wave_time)
		if not is_finite(school_surface):
			diagnostic["rejection_reason"] = "surface_sample_invalid"
			_remember_school_diagnostic(school_diagnostics, diagnostic)
			continue
		var fish_world_position := Vector3(anchor.x, school_surface - activity_depth, anchor.z)
		diagnostic["target_world_position"] = fish_world_position
		var school_seabed_y := chart_datum_world_y_m - school_chart_depth
		var relative := fish_world_position - probe_world_position
		var anchor_geometry := diagnose_target_geometry(relative, beam_half_cone_angle_deg, detection_depth_max, max_slant_range_m)
		var vertical_half_thickness := _school_vertical_half_thickness_m(species_id, activity_depth)
		var school_radius := _school_horizontal_radius_m(species_id)
		var surface_depth_below_probe := probe_world_position.y - school_surface
		var seabed_depth_below_probe := probe_world_position.y - school_seabed_y - seabed_clearance_m
		var volume := evaluate_school_volume_overlap(
			relative,
			school_radius,
			vertical_half_thickness,
			maxf(0.001, surface_depth_below_probe),
			minf(detection_depth_max, seabed_depth_below_probe),
			beam_half_cone_angle_deg,
			max_slant_range_m
		)
		var vertical_depth := float(volume.get("target_depth_below_transducer_m", -1.0))
		if vertical_depth <= 0.0:
			vertical_depth = float(anchor_geometry.get("vertical_depth_m", -1.0))
		var beam_radius := scan_radius_for_depth(vertical_depth, beam_half_cone_angle_deg)
		var slant_range := sqrt(anchor_geometry.get("horizontal_distance_m", 0.0) * anchor_geometry.get("horizontal_distance_m", 0.0) + vertical_depth * vertical_depth)
		var overlap_factor := clampf(float(volume.get("overlap_factor", 0.0)), 0.0, 1.0)
		var coverage_factor := clampf(float(volume.get("coverage_factor", 0.0)), 0.0, 1.0)
		diagnostic["target_depth_below_transducer_m"] = vertical_depth
		diagnostic["vertical_distance_m"] = vertical_depth
		diagnostic["beam_radius_m"] = beam_radius
		diagnostic["slant_range_m"] = slant_range
		diagnostic["anchor_geometry_reason"] = str(anchor_geometry.get("reason", "invalid_geometry"))
		diagnostic["effective_school_radius_m"] = school_radius
		diagnostic["vertical_half_thickness_m"] = vertical_half_thickness
		diagnostic["effective_vertical_thickness_m"] = float(volume.get("effective_vertical_thickness_m", 0.0))
		diagnostic["coverage_factor"] = coverage_factor
		diagnostic["overlap_factor"] = overlap_factor
		if str(volume.get("reason", "outside_school_volume")) != "school_volume_overlap" or overlap_factor <= 0.0:
			diagnostic["rejection_reason"] = str(volume.get("reason", "outside_school_volume"))
			_remember_school_diagnostic(school_diagnostics, diagnostic)
			continue
		var horizontal_distance := float(anchor_geometry.get("horizontal_distance_m", -1.0))
		var representative_relative := Vector3(relative.x, -vertical_depth, relative.z)
		var representative_slant_range := representative_relative.length()
		var range_score := 1.0 - clampf(slant_range / max_slant_range_m, 0.0, 1.0)
		var group_strength := 1.0 - exp(-float(population) / 8.0)
		var echo_strength := clampf(group_strength * overlap_factor * lerpf(0.2, 1.0, range_score), 0.0, 1.0)
		var echo_width := clampf(sqrt(float(population)) * school_echo_width_per_sqrt_fish_m, 0.25, maximum_visual_echo_width_m)
		diagnostic["hit"] = true
		diagnostic["final_echo_strength"] = echo_strength
		diagnostic["rejection_reason"] = "school_volume_detected" if overlap_factor >= 0.65 and coverage_factor >= 0.65 else "partial_overlap"
		_remember_school_diagnostic(school_diagnostics, diagnostic)
		echoes.append({
			"echo_id": "scan_%d_%s" % [_scan_sequence, school_id],
			"school_id": school_id,
			"species_id": species_id,
			"target_world_position": Vector3(fish_world_position.x, probe_world_position.y - vertical_depth, fish_world_position.z),
			"relative_position_m": representative_relative,
			"target_depth_below_transducer_m": vertical_depth,
			"depth_below_surface_m": activity_depth,
			"slant_range_m": representative_slant_range,
			"horizontal_offset_m": horizontal_distance,
			"beam_radius_m": beam_radius,
			"beam_center_fraction": clampf(horizontal_distance / maxf(beam_radius + school_radius, 0.001), 0.0, 1.0),
			"group_population": population,
			"group_intensity": group_strength,
			"echo_strength": echo_strength,
			"echo_width_m": echo_width,
			"echo_width_is_visual_proxy": true,
			"effective_school_radius_m": school_radius,
			"vertical_half_thickness_m": vertical_half_thickness,
			"coverage_factor": coverage_factor,
			"overlap_factor": overlap_factor,
			"aggregation_method": "ellipsoid_beam_overlap_v1",
			"estimated_group_size_band": _population_band(population),
			"activity_state": str(school.get("surface_activity_state", "unknown")),
		})
	echoes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var a_range := float(a.get("slant_range_m", INF))
		var b_range := float(b.get("slant_range_m", INF))
		if is_equal_approx(a_range, b_range):
			return str(a.get("school_id", "")) < str(b.get("school_id", ""))
		return a_range < b_range
	)
	result["accepted"] = true
	result["valid"] = true
	result["reason"] = "ok"
	result["schools_considered_count"] = schools.size()
	result["schools_detected_count"] = echoes.size()
	result["school_diagnostics"] = school_diagnostics
	result["echoes"] = echoes
	return _finish_scan(result)


## Read-only geometric breakdown shared by Authority-anchor and visual-instance
## diagnostics. `relative_target` is target position minus transducer position.
static func diagnose_target_geometry(relative_target: Vector3, half_cone_angle_deg: float, max_depth_m: float, max_slant_range_m: float) -> Dictionary:
	var horizontal_distance := Vector2(relative_target.x, relative_target.z).length()
	var vertical_depth := -relative_target.y
	var slant_range := relative_target.length()
	var beam_radius := scan_radius_for_depth(vertical_depth, half_cone_angle_deg)
	var reason := "inside_beam"
	if not _is_finite_vector3(relative_target):
		reason = "invalid_geometry"
	elif vertical_depth <= 0.0:
		reason = "not_below_probe"
	elif vertical_depth > max_depth_m:
		reason = "depth_limit_exceeded"
	elif slant_range > max_slant_range_m:
		reason = "slant_range_exceeded"
	elif horizontal_distance > beam_radius:
		reason = "outside_beam"
	return {
		"horizontal_distance_m": horizontal_distance,
		"vertical_depth_m": vertical_depth,
		"beam_radius_m": beam_radius,
		"slant_range_m": slant_range,
		"hit": reason == "inside_beam",
		"reason": reason,
	}


func _remember_school_diagnostic(target: Array[Dictionary], diagnostic: Dictionary) -> void:
	target.append(diagnostic.duplicate(true))
	target.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("anchor_horizontal_distance_m", INF)) < float(b.get("anchor_horizontal_distance_m", INF))
	)
	while target.size() > MAX_DIAGNOSTIC_SCHOOLS:
		target.pop_back()


func _finish_scan(result: Dictionary) -> Dictionary:
	_record_scan(result)
	scan_completed.emit(result.duplicate(true))
	return result


func get_scan_history() -> Array[Dictionary]:
	return _history.duplicate(true)


func get_last_scan() -> Dictionary:
	return _history.back().duplicate(true) if not _history.is_empty() else {}


func get_history_coverage_seconds() -> float:
	if _history.size() < 2:
		return 0.0
	return maxf(0.0, float(_history.back().get("scan_runtime_seconds", 0.0)) - float(_history.front().get("scan_runtime_seconds", 0.0)))


func get_effective_history_capacity() -> int:
	var capacity_for_duration := ceili(maxf(scan_frequency_hz, 0.1) * maxf(minimum_history_seconds, 0.0))
	return clampi(maxi(history_capacity, capacity_for_duration), 1, 12000)


static func scan_radius_for_depth(vertical_depth_m: float, half_cone_angle_deg: float) -> float:
	if vertical_depth_m <= 0.0:
		return 0.0
	return vertical_depth_m * tan(deg_to_rad(clampf(half_cone_angle_deg, 0.1, 89.0)))


## Deterministic low-cost overlap estimate for an ellipsoidal school proxy and the
## existing downward cone. `relative_anchor` is school center minus transducer.
## The vertical interval is already clipped to valid water and seabed clearance.
static func evaluate_school_volume_overlap(relative_anchor: Vector3, horizontal_radius_m: float, vertical_half_thickness_m: float, minimum_valid_depth_m: float, maximum_valid_depth_m: float, half_cone_angle_deg: float, max_slant_range_m: float) -> Dictionary:
	var result := {
		"reason": "outside_school_volume",
		"overlap_factor": 0.0,
		"coverage_factor": 0.0,
		"target_depth_below_transducer_m": -1.0,
		"effective_vertical_thickness_m": 0.0,
		"sample_depth_min_m": -1.0,
		"sample_depth_max_m": -1.0,
	}
	if not _is_finite_vector3(relative_anchor) or horizontal_radius_m <= 0.0 or vertical_half_thickness_m <= 0.0:
		result["reason"] = "invalid_geometry"
		return result
	var center_depth := -relative_anchor.y
	var volume_low := maxf(center_depth - vertical_half_thickness_m, minimum_valid_depth_m)
	var volume_high := minf(center_depth + vertical_half_thickness_m, maximum_valid_depth_m)
	if volume_high < volume_low:
		if center_depth - vertical_half_thickness_m > maximum_valid_depth_m:
			result["reason"] = "depth_limit_exceeded"
		elif center_depth + vertical_half_thickness_m < minimum_valid_depth_m:
			result["reason"] = "school_volume_outside_water"
		else:
			result["reason"] = "insufficient_seabed_clearance"
		return result
	result["effective_vertical_thickness_m"] = maxf(0.0, volume_high - volume_low)
	result["sample_depth_min_m"] = volume_low
	result["sample_depth_max_m"] = volume_high
	var horizontal_distance := Vector2(relative_anchor.x, relative_anchor.z).length()
	var weighted_beam_volume := 0.0
	var weighted_overlap := 0.0
	var weighted_coverage := 0.0
	var weighted_depth := 0.0
	var any_intersection := false
	var any_valid_sonar_volume := false
	for index in range(VOLUME_SAMPLE_FRACTIONS.size()):
		var fraction := float(VOLUME_SAMPLE_FRACTIONS[index])
		var vertical_weight := float(VOLUME_SAMPLE_WEIGHTS[index])
		var depth := lerpf(volume_low, volume_high, (fraction + 1.0) * 0.5)
		if depth <= 0.0 or depth > max_slant_range_m:
			continue
		var cone_radius := scan_radius_for_depth(depth, half_cone_angle_deg)
		var slant_radius := sqrt(maxf(max_slant_range_m * max_slant_range_m - depth * depth, 0.0))
		var beam_radius := minf(cone_radius, slant_radius)
		if beam_radius <= 0.00001:
			continue
		var vertical_normalized := clampf((depth - center_depth) / vertical_half_thickness_m, -1.0, 1.0)
		var school_slice_radius := horizontal_radius_m * sqrt(maxf(0.0, 1.0 - vertical_normalized * vertical_normalized))
		if school_slice_radius <= 0.00001:
			continue
		any_valid_sonar_volume = true
		var beam_area := PI * beam_radius * beam_radius
		var overlap_area := _circle_overlap_area(horizontal_distance, school_slice_radius, beam_radius)
		var coverage := clampf(overlap_area / maxf(beam_area, 0.0000001), 0.0, 1.0)
		var overlap_density := 0.0
		if overlap_area > 0.0:
			any_intersection = true
			# The nearest part of the cone footprint gives a stable local-density
			# proxy. Area coverage separately weakens narrow edge contacts.
			var nearest_radial_distance := maxf(horizontal_distance - beam_radius, 0.0)
			var radial_q := pow(nearest_radial_distance / school_slice_radius, 2.0)
			var volume_q := radial_q + vertical_normalized * vertical_normalized
			overlap_density = pow(maxf(1.0 - volume_q, 0.0), 0.6)
		var slice_overlap := coverage * overlap_density
		var sample_weight := vertical_weight * beam_area
		weighted_beam_volume += sample_weight
		weighted_coverage += coverage * sample_weight
		weighted_overlap += slice_overlap * sample_weight
		weighted_depth += depth * slice_overlap * sample_weight
	if not any_valid_sonar_volume:
		result["reason"] = "slant_range_exceeded" if volume_low > max_slant_range_m else "depth_limit_exceeded"
		return result
	if not any_intersection or weighted_beam_volume <= 0.0:
		result["reason"] = "outside_school_volume"
		return result
	var overlap_factor := clampf(weighted_overlap / weighted_beam_volume, 0.0, 1.0)
	var coverage_factor := clampf(weighted_coverage / weighted_beam_volume, 0.0, 1.0)
	if overlap_factor <= MIN_OVERLAP_FOR_ECHO:
		result["reason"] = "overlap_below_threshold"
		result["overlap_factor"] = overlap_factor
		result["coverage_factor"] = coverage_factor
		return result
	result["reason"] = "school_volume_overlap"
	result["overlap_factor"] = overlap_factor
	result["coverage_factor"] = coverage_factor
	result["target_depth_below_transducer_m"] = weighted_depth / weighted_overlap
	return result


static func _circle_overlap_area(center_distance_m: float, first_radius_m: float, second_radius_m: float) -> float:
	if center_distance_m >= first_radius_m + second_radius_m:
		return 0.0
	var smaller_radius := minf(first_radius_m, second_radius_m)
	if center_distance_m <= absf(first_radius_m - second_radius_m):
		return PI * smaller_radius * smaller_radius
	var distance_squared := center_distance_m * center_distance_m
	var first_squared := first_radius_m * first_radius_m
	var second_squared := second_radius_m * second_radius_m
	var first_angle := acos(clampf((distance_squared + first_squared - second_squared) / (2.0 * center_distance_m * first_radius_m), -1.0, 1.0))
	var second_angle := acos(clampf((distance_squared + second_squared - first_squared) / (2.0 * center_distance_m * second_radius_m), -1.0, 1.0))
	var triangle_term := maxf(0.0, (-center_distance_m + first_radius_m + second_radius_m) * (center_distance_m + first_radius_m - second_radius_m) * (center_distance_m - first_radius_m + second_radius_m) * (center_distance_m + first_radius_m + second_radius_m))
	return maxf(0.0, first_squared * first_angle + second_squared * second_angle - 0.5 * sqrt(triangle_term))


func _school_horizontal_radius_m(species_id: String) -> float:
	var base_radius := 2.4
	if _manager != null and _manager.has_method("get_species_profile"):
		var profile := _manager.call("get_species_profile", species_id) as FishSpeciesProfile
		if profile != null:
			base_radius = profile.school_wander_radius_m
			if profile.behavior_type == "coastal_benthic":
				base_radius = maxf(base_radius, profile.school_activity_radius_m)
	return clampf(base_radius * school_distribution_radius_margin, 0.5, maximum_school_distribution_radius_m)


func _school_vertical_half_thickness_m(species_id: String, activity_depth_m: float) -> float:
	var profile := _manager.call("get_species_profile", species_id) as FishSpeciesProfile if _manager != null and _manager.has_method("get_species_profile") else null
	if profile == null:
		return clampf(0.9, minimum_school_vertical_half_thickness_m, maximum_school_vertical_half_thickness_m)
	var configured_range := profile.preferred_swim_depth_m
	if profile.surface_activity_cycle_enabled:
		var surface_range: Vector2 = profile.surface_activity_depth_m
		var deep_range: Vector2 = profile.deep_activity_depth_m
		var surface_distance := _distance_to_range(activity_depth_m, surface_range)
		var deep_distance := _distance_to_range(activity_depth_m, deep_range)
		configured_range = surface_range if surface_distance <= deep_distance else deep_range
	elif profile.behavior_type == "coastal_benthic":
		configured_range = profile.near_surface_depth_m if _distance_to_range(activity_depth_m, profile.near_surface_depth_m) < _distance_to_range(activity_depth_m, profile.preferred_swim_depth_m) else profile.preferred_swim_depth_m
	var half_thickness := maxf(0.0, configured_range.y - configured_range.x) * 0.5
	return clampf(half_thickness, minimum_school_vertical_half_thickness_m, maximum_school_vertical_half_thickness_m)


static func _distance_to_range(value: float, depth_range: Vector2) -> float:
	if value < depth_range.x:
		return depth_range.x - value
	if value > depth_range.y:
		return value - depth_range.y
	return 0.0


static func is_within_beam(horizontal_distance_m: float, vertical_depth_m: float, full_beam_angle_deg: float, max_range_m: float) -> bool:
	if horizontal_distance_m < 0.0 or vertical_depth_m <= 0.0 or max_range_m <= 0.0:
		return false
	var radius := scan_radius_for_depth(vertical_depth_m, clampf(full_beam_angle_deg, 1.0, 179.0) * 0.5)
	var slant_range := sqrt(horizontal_distance_m * horizontal_distance_m + vertical_depth_m * vertical_depth_m)
	return horizontal_distance_m <= radius and slant_range <= max_range_m


func _resolve_active_vessel() -> Node3D:
	if _manager != null and _manager.has_method("get_boat"):
		_boat = _manager.call("get_boat") as Node3D
	if _boat == null or not is_instance_valid(_boat):
		return null
	if _boat.has_method("is_sailing_active") and bool(_boat.call("is_sailing_active")) and _boat.has_method("get_sailing_body"):
		var active_sailing_body := _boat.call("get_sailing_body") as Node3D
		if active_sailing_body != null and is_instance_valid(active_sailing_body):
			return active_sailing_body
	return _boat


func _active_vessel_id(active_vessel: Node3D) -> String:
	if active_vessel == null:
		return "unavailable"
	var profile: Resource
	if active_vessel == _boat:
		profile = _boat.get("draft_profile") as Resource
	else:
		profile = active_vessel.get("profile") as Resource
	if profile != null:
		var configured_id: Variant = profile.get("vessel_id")
		if configured_id != null and not str(configured_id).is_empty() and str(configured_id) != "unknown_vessel":
			return str(configured_id)
	var scene_path := active_vessel.scene_file_path
	if not scene_path.is_empty():
		return scene_path.get_file().get_basename().to_snake_case()
	return active_vessel.name.to_snake_case()


func _active_vessel_speed_mps(active_vessel: Node3D) -> float:
	if active_vessel == null:
		return 0.0
	if active_vessel is RigidBody3D:
		return (active_vessel as RigidBody3D).linear_velocity.length()
	var speed_value: Variant = active_vessel.get("speed_mps")
	return absf(float(speed_value)) if speed_value != null else 0.0


func _sample_surface_y(position: Vector3, sample_time_seconds: float) -> float:
	var query := Vector3(position.x, 0.0, position.z)
	var sample: Dictionary = _wave_sampler.call("sample_physics_surface", query, sample_time_seconds)
	return float(sample.get("height", NAN))


func _game_time_seconds() -> float:
	if _manager == null or not _manager.has_method("get_world_game_time_seconds"):
		return 0.0
	var game_time := float(_manager.call("get_world_game_time_seconds"))
	return maxf(0.0, game_time) if is_finite(game_time) else 0.0


func _school_position(school: Dictionary) -> Vector3:
	var value: Variant = school.get("world_position", [])
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3(NAN, NAN, NAN)


static func _is_finite_vector3(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


func _population_band(population: int) -> String:
	if population <= 3:
		return "small"
	if population <= 10:
		return "medium"
	return "large"


func _record_scan(result: Dictionary) -> void:
	_history.append(result.duplicate(true))
	while _history.size() > get_effective_history_capacity():
		_history.pop_front()


static func _runtime_seconds() -> float:
	return float(Time.get_ticks_usec()) / 1000000.0
