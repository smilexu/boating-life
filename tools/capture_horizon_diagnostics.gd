extends SceneTree
## Captures fixed-view isolation checks for the ocean/sky/terrain horizon seam.
## Run with Godot's normal renderer: godot --path . --script res://tools/capture_horizon_diagnostics.gd

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_ROOT := "res://docs/horizon_seam/diagnostics"

var _camera_transform := Transform3D.IDENTITY
var _rows: Array[Dictionary] = []


func _initialize() -> void:
	_capture.call_deferred()


func _capture() -> void:
	var manager := root.get_node_or_null("WorldTimeManager")
	if manager == null:
		push_error("WorldTimeManager autoload is unavailable.")
		quit(1)
		return
	var original_snapshot: Dictionary = manager.call("create_snapshot")
	var original_autosave := bool(manager.get("autosave_enabled"))
	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	await _wait_frames(45)
	manager.set("autosave_enabled", false)
	manager.call("pause_time")
	manager.call("set_calendar_date", 2026, 7, 15)
	manager.call("set_day_cycle_time", 12, 0)
	var quality := main.get_node("QualityManager") as QualityManager
	var boat := main.get_node("PlayerBoat") as Node3D
	var motion_root := boat.get_node("MotionRoot") as Node3D
	var visual_root := boat.get_node("MotionRoot/VisualRoot") as Node3D
	var camera_rig := boat.get_node("FollowCameraRig") as Node3D
	var camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	var ocean := main.get_node("Ocean") as Ocean
	var material := main.get_node("BathymetryManager").get("water_material") as ShaderMaterial
	var region := main.get_node("OresundRegion") as Node3D
	var terrain := region.get_node("TerrainChunks") as Node3D
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	var weather := main.get_node("WeatherController") as WeatherController
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	motion_root.set_process(false)
	motion_root.set_physics_process(false)
	visual_root.set_process(false)
	visual_root.set_physics_process(false)
	camera_rig.set_process(false)
	camera_rig.set_physics_process(false)
	var wake := boat.get_node_or_null("MotionRoot/VisualRoot/WakeSystem")
	if wake != null:
		_disable_particles(wake)
	material.set_shader_parameter("freeze_time", true)
	weather.transition_seconds = 0.0
	weather.set_weather_by_name("Clear")
	await _wait_frames(30)
	_camera_transform = camera.global_transform
	camera.make_current()
	var output_path := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output_path)

	# A0: unchanged authored scene at a fixed third-person camera and noon.
	await _save("01_clear_third_person_before", camera, material, terrain, environment, "third_person")

	# A1: diagnostic-only visibility switch. If the seam remains, land is not required.
	terrain.visible = false
	await _save("02_clear_third_person_terrain_hidden", camera, material, terrain, environment, "third_person")
	terrain.visible = true

	# A2: constant opaque output. Gerstner geometry remains enabled, shading/fades are bypassed.
	material.set_shader_parameter("water_diagnostic_mode", 1)
	await _save("03_clear_third_person_flat_water", camera, material, terrain, environment, "third_person")
	material.set_shader_parameter("water_diagnostic_mode", 0)

	# A3: temporarily move the alpha fade to the outer ocean edge.
	material.set_shader_parameter("distance_fade_min", 52000.0)
	material.set_shader_parameter("distance_fade_max", 56000.0)
	await _save("04_clear_third_person_extended_fade", camera, material, terrain, environment, "third_person")
	material.set_shader_parameter("distance_fade_min", 3600.0)
	material.set_shader_parameter("distance_fade_max", 4000.0)

	# A4: fog isolation (diagnostic only).
	var fog_was_enabled := environment.fog_enabled
	environment.fog_enabled = false
	await _save("05_clear_third_person_fog_off", camera, material, terrain, environment, "third_person")
	environment.fog_enabled = fog_was_enabled

	# A5: full water normal visualization shows whether an LOD ring produces a sharp normal discontinuity.
	material.set_shader_parameter("water_diagnostic_mode", 4)
	await _save("06_clear_third_person_normal_debug", camera, material, terrain, environment, "third_person")
	material.set_shader_parameter("water_diagnostic_mode", 0)

	# Wide fixed camera points across open water to the west of Malmö.
	var wide_camera := Camera3D.new()
	wide_camera.name = "TemporaryHorizonDiagnosticCamera"
	wide_camera.fov = 70.0
	wide_camera.far = 80000.0
	main.add_child(wide_camera)
	var wide_origin := boat.global_position + Vector3.UP * 300.0
	wide_camera.global_position = wide_origin
	wide_camera.look_at(wide_origin + Vector3(-15000.0, -270.0, 0.0), Vector3.UP)
	wide_camera.make_current()
	await _save("07_clear_wide_before", wide_camera, material, terrain, environment, "wide_open_water")
	material.set_shader_parameter("distance_fade_min", 52000.0)
	material.set_shader_parameter("distance_fade_max", 56000.0)
	await _save("08_clear_wide_extended_fade", wide_camera, material, terrain, environment, "wide_open_water")
	material.set_shader_parameter("distance_fade_min", 3600.0)
	material.set_shader_parameter("distance_fade_max", 4000.0)
	terrain.visible = false
	await _save("09_clear_wide_terrain_hidden", wide_camera, material, terrain, environment, "wide_open_water")
	terrain.visible = true
	material.set_shader_parameter("water_diagnostic_mode", 4)
	await _save("10_clear_wide_normal_debug", wide_camera, material, terrain, environment, "wide_open_water")
	material.set_shader_parameter("water_diagnostic_mode", 0)
	main.remove_child(wide_camera)
	wide_camera.queue_free()

	# Final-state views at sunset and a clear moonlit night.
	camera.make_current()
	camera.global_transform = _camera_transform
	manager.call("set_day_cycle_time", 22, 0)
	await _wait_frames(20)
	await _save("11_sunset_after", camera, material, terrain, environment, "third_person")
	manager.call("set_calendar_date", 2026, 10, 26)
	manager.call("set_day_cycle_time", 19, 30)
	await _wait_frames(20)
	await _save("12_moon_night_after", camera, material, terrain, environment, "third_person")

	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(),
		"viewport_px": [root.get_viewport().size.x, root.get_viewport().size.y],
		"quality": "High",
		"weather_for_isolation": "Clear",
		"wave_phase": "frozen",
		"baseline_distance_fade_m": [3600.0, 4000.0],
		"diagnostic_distance_fade_m": [52000.0, 56000.0],
		"ocean_far_edge_m": ocean.far_edge,
		"camera_far_m": camera.far,
		"fog_depth_range_m": [environment.fog_depth_begin, environment.fog_depth_end],
		"captures": _rows,
	}
	var report_file := FileAccess.open(output_path.path_join("capture_report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "\t") + "\n")
		report_file.close()
	print(JSON.stringify(report, "\t"))
	manager.call("restore_snapshot", original_snapshot)
	manager.set("autosave_enabled", original_autosave)
	root.remove_child(main)
	main.queue_free()
	await process_frame
	quit()


func _save(name: String, camera: Camera3D, material: ShaderMaterial, terrain: Node3D, environment: Environment, camera_mode: String) -> void:
	camera.make_current()
	await _wait_frames(6)
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(OUTPUT_ROOT).path_join(name + ".png")
	var error := image.save_png(path)
	_rows.append({
		"name": name,
		"camera_mode": camera_mode,
		"water_diagnostic_mode": material.get_shader_parameter("water_diagnostic_mode"),
		"distance_fade": [material.get_shader_parameter("distance_fade_min"), material.get_shader_parameter("distance_fade_max")],
		"terrain_visible": terrain.visible,
		"fog_enabled": environment.fog_enabled,
		"save_error": error,
		"path": path,
	})
	print("Captured %s (%dx%d, error=%d)" % [name, image.get_width(), image.get_height(), error])


func _disable_particles(node: Node) -> void:
	if node is GPUParticles3D:
		(node as GPUParticles3D).emitting = false
	for child in node.get_children():
		_disable_particles(child)


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame
