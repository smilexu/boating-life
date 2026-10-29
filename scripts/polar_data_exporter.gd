extends RefCounted
## Writes raw Polar test artifacts under user://polar_tests without touching project data.

const ROOT_DIR := "user://polar_tests"
const CSV_FIELDS := [
	"case_id", "boat_id", "boat_scene_path", "boat_config_hash", "physics_version", "test_run_id", "timestamp",
	"engine_state", "auto_trim_state", "target_tws_kn", "target_twa_deg", "tack", "wind_from_deg",
	"wave_mode", "physics_ticks_per_second", "physics_time_scale", "effective_simulated_ticks_per_second",
	"observed_physics_step_seconds", "maximum_physics_step_error_seconds", "mean_tws_kn", "measured_twa_deg", "mean_aws_kn", "mean_awa_deg",
	"mean_velocity_world_x_mps", "mean_velocity_world_z_mps", "mean_heading_deg", "mean_cog_deg",
	"mean_sog_kn", "mean_stw_kn", "mean_vmg_kn",
	"mean_heel_deg", "mean_leeway_deg", "speed_stddev_mps", "heading_error_deg", "mean_rudder_deg",
	"rudder_saturation_fraction", "main_sail_deg", "headsail_deg", "mean_main_forward_force_n",
	"mean_headsail_forward_force_n", "mean_hull_resistance_forward_n", "mean_keel_force_forward_n",
	"mean_rudder_force_forward_n", "mean_total_water_force_forward_n", "mean_longitudinal_velocity_mps",
	"mean_body_calculation_usec", "p95_body_calculation_usec", "elapsed_simulation_seconds", "wall_clock_elapsed_seconds",
	"stability_first_qualified_simulation_seconds", "sample_count", "status", "failure_reason"
]


static func create_run_directory(run_id: String) -> String:
	var path := "%s/%s" % [ROOT_DIR, run_id]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))
	return path


static func save_bundle(run_directory: String, run_metadata: Dictionary, cases: Array[Dictionary], results: Array[Dictionary], checkpoint: Dictionary) -> bool:
	var csv_lines := PackedStringArray([",".join(PackedStringArray(CSV_FIELDS))])
	for result in results:
		var values := PackedStringArray()
		for field in CSV_FIELDS:
			values.append(_csv_value(result.get(field, "")))
		csv_lines.append(",".join(values))
	if not _write_text(run_directory.path_join("polar_results.csv"), "\n".join(csv_lines) + "\n"):
		return false
	if not _write_json(run_directory.path_join("polar_results.json"), {"metadata": run_metadata, "cases": cases, "results": results}):
		return false
	if not _write_json(run_directory.path_join("polar_summary.json"), _make_summary(run_metadata, results)):
		return false
	return _write_json(run_directory.path_join("polar_checkpoint.json"), checkpoint)


static func load_latest_checkpoint() -> Dictionary:
	var root := DirAccess.open(ROOT_DIR)
	if root == null:
		return {"ok": false, "reason": "no polar_tests directory"}
	var directories := PackedStringArray()
	root.list_dir_begin()
	var item := root.get_next()
	while not item.is_empty():
		if root.current_is_dir() and not item.begins_with("."):
			directories.append(item)
		item = root.get_next()
	root.list_dir_end()
	directories.sort()
	directories.reverse()
	for directory in directories:
		var path := "%s/%s/polar_checkpoint.json" % [ROOT_DIR, directory]
		if not FileAccess.file_exists(path):
			continue
		var parsed := _read_json(path)
		if bool(parsed.get("ok", false)):
			parsed["checkpoint_path"] = path
			return parsed
	return {"ok": false, "reason": "no valid checkpoint found"}


static func _make_summary(metadata: Dictionary, results: Array[Dictionary]) -> Dictionary:
	var counts := {}
	var stable_count := 0
	var stable_sog_total := 0.0
	for result in results:
		var status := str(result.get("status", "INVALID"))
		counts[status] = int(counts.get(status, 0)) + 1
		if status == "STABLE":
			stable_count += 1
			stable_sog_total += float(result.get("mean_sog_kn", 0.0))
	return {
		"test_run_id": metadata.get("test_run_id", ""),
		"boat_id": metadata.get("boat_id", ""),
		"boat_config_hash": metadata.get("boat_config_hash", ""),
		"created_at": metadata.get("created_at", ""),
		"result_count": results.size(),
		"status_counts": counts,
		"stable_mean_sog_kn": stable_sog_total / float(stable_count) if stable_count > 0 else null,
		"results_file": "polar_results.csv",
	}


static func _write_json(path: String, value: Variant) -> bool:
	return _write_text(path, JSON.stringify(value, "\t") + "\n")


static func _write_text(path: String, contents: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Polar exporter could not write %s: %s" % [path, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(contents)
	return true


static func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "reason": "cannot open %s" % path}
	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	if error != OK or not json.data is Dictionary:
		return {"ok": false, "reason": "invalid JSON in %s" % path}
	return {"ok": true, "data": json.data}


static func _csv_value(value: Variant) -> String:
	if value == null:
		return ""
	var text := str(value)
	if value is float:
		if not is_finite(value):
			text = ""
		else:
			text = "%.6f" % value
	if text.contains(",") or text.contains("\"") or text.contains("\n"):
		text = "\"" + text.replace("\"", "\"\"") + "\""
	return text
