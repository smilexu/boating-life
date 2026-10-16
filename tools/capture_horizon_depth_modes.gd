extends SceneTree
## Isolates water depth-write mode and each generated ocean mesh layer.
## Run with: godot --path . --script res://tools/capture_horizon_depth_modes.gd

const MAIN_SCENE := preload("res://scenes/main.tscn")
const OUTPUT_ROOT := "res://docs/horizon_seam/diagnostics/depth_modes"
const DEPTH_MODES := ["depth_draw_always", "depth_draw_never", "depth_prepass_alpha"]
const MESH_GROUPS := ["near", "transition", "mid", "far", "all"]

var _rows: Array[Dictionary] = []


func _initialize() -> void:
	_capture.call_deferred()


func _capture() -> void:
	var manager := root.get_node_or_null("WorldTimeManager")
	if manager == null:
		push_error("WorldTimeManager autoload is unavailable.")
		quit(1)
		return
	var snapshot: Dictionary = manager.call("create_snapshot")
	var old_autosave := bool(manager.get("autosave_enabled"))
	var main := MAIN_SCENE.instantiate()
	root.add_child(main)
	await _wait_frames(45)
	manager.set("autosave_enabled", false)
	manager.call("pause_time")
	manager.call("set_calendar_date", 2026, 7, 15)
	manager.call("set_day_cycle_time", 12, 0)
	var quality := main.get_node("QualityManager") as QualityManager
	var boat := main.get_node("PlayerBoat") as Node3D
	var ocean := main.get_node("Ocean") as Ocean
	var water := main.get_node("BathymetryManager").get("water_material") as ShaderMaterial
	var terrain := main.get_node("OresundRegion/TerrainChunks") as Node3D
	var weather := main.get_node("WeatherController") as WeatherController
	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	weather.transition_seconds = 0.0
	weather.set_weather_by_name("Clear")
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		(canvas as CanvasLayer).visible = false
	for path in ["MotionRoot", "MotionRoot/VisualRoot", "FollowCameraRig"]:
		var node := boat.get_node(path)
		node.set_process(false)
		node.set_physics_process(false)
	var wake := boat.get_node_or_null("MotionRoot/VisualRoot/WakeSystem")
	if wake != null:
		_disable_particles(wake)
	water.set_shader_parameter("freeze_time", true)
	water.set_shader_parameter("water_diagnostic_mode", 1)
	var camera := boat.get_node("FollowCameraRig/Camera3D") as Camera3D
	camera.make_current()
	await _wait_frames(20)
	var meshes := _get_ocean_meshes(ocean)
	var original_shader := water.shader
	for depth_mode in DEPTH_MODES:
		var shader_variant := (original_shader.duplicate() as Shader)
		shader_variant.code = original_shader.code.replace("depth_draw_always", depth_mode)
		water.shader = shader_variant
		await _wait_frames(12)
		for group_name in MESH_GROUPS:
			_set_group_visible(meshes, group_name)
			await _capture_one("%s_%s" % [depth_mode, group_name], camera, meshes)
	water.shader = original_shader
	for mesh in meshes:
		mesh.visible = true
	var output := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output)
	var report := {"renderer": RenderingServer.get_video_adapter_name(),
		"processor": OS.get_processor_name(), "viewport_px": [root.get_viewport().size.x, root.get_viewport().size.y],
		"water_diagnostic_mode": 1, "depth_mode_variants": DEPTH_MODES,
		"mesh_groups": MESH_GROUPS, "mesh_nodes": meshes.map(func(mesh): return mesh.name), "captures": _rows}
	var file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t") + "\n")
		file.close()
	print(JSON.stringify(report, "\t"))
	manager.call("restore_snapshot", snapshot)
	manager.set("autosave_enabled", old_autosave)
	root.remove_child(main)
	main.queue_free()
	await process_frame
	quit()


func _set_group_visible(meshes: Array[MeshInstance3D], group_name: String) -> void:
	for mesh in meshes:
		var match_group := group_name == "all"
		if group_name == "near":
			match_group = mesh.name.begins_with("_gen_nearplane")
		elif group_name == "transition":
			match_group = mesh.name == "_gen_farplane_transition"
		elif group_name == "mid":
			match_group = mesh.name == "_gen_farplane_mid"
		elif group_name == "far":
			match_group = mesh.name == "_gen_farplane_far"
		mesh.visible = match_group


func _get_ocean_meshes(ocean: Ocean) -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	for child in ocean.get_children():
		if child is MeshInstance3D and child.name.begins_with("_gen_"):
			meshes.append(child as MeshInstance3D)
	return meshes


func _capture_one(name: String, camera: Camera3D, meshes: Array[MeshInstance3D]) -> void:
	camera.make_current()
	await _wait_frames(5)
	await RenderingServer.frame_post_draw
	var image := root.get_viewport().get_texture().get_image()
	var output := ProjectSettings.globalize_path(OUTPUT_ROOT)
	DirAccess.make_dir_recursive_absolute(output)
	var path := output.path_join(name + ".png")
	var error := image.save_png(path)
	_rows.append({"name": name, "path": path, "visible_meshes": meshes.filter(func(mesh): return mesh.visible).map(func(mesh): return mesh.name), "save_error": error})
	print("Captured %s (%dx%d, error=%d)" % [name, image.get_width(), image.get_height(), error])


func _disable_particles(node: Node) -> void:
	if node is GPUParticles3D:
		(node as GPUParticles3D).emitting = false
	for child in node.get_children():
		_disable_particles(child)


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame
