extends SceneTree
## Captures controlled ocean-seam diagnostics from the production Main scene.
## Run: godot --path . --script res://tools/capture_ocean_seam_diagnostics.gd

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_DIR := "res://docs/ocean_seam"
const WIDE_CAMERA_OFFSET := Vector3(72.0, 32.0, -136.0)
const WIDE_CAMERA_TARGET_OFFSET := Vector3(0.0, 2.0, 0.0)

var captures: Array[Dictionary] = []
var geometry_report: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		push_error("Could not load %s" % MAIN_SCENE)
		quit(1)
		return
	var main := packed.instantiate()
	root.add_child(main)
	await _wait_frames(24)

	var ocean := main.get_node("Ocean") as Node3D
	var environment := (main.get_node("WorldEnvironment") as WorldEnvironment).environment
	var quality := main.get_node("QualityManager") as QualityManager
	var water := (main.get_node("BathymetryManager") as BathymetryManager).water_material
	var motion_root := main.get_node("PlayerBoat/MotionRoot") as Node3D
	var camera_rig := main.get_node("PlayerBoat/FollowCameraRig") as Node3D
	var camera := main.get_node("PlayerBoat/FollowCameraRig/Camera3D") as Camera3D
	if ocean == null or environment == null or quality == null or water == null or camera == null:
		push_error("Main scene is missing ocean-seam diagnostic dependencies.")
		quit(1)
		return

	quality.set_quality_for_benchmark(QualityManager.Quality.HIGH)
	motion_root.set_process(false)
	camera_rig.set_process(false)
	water.set_shader_parameter("freeze_time", true)
	var boat_position := motion_root.global_position
	camera.global_position = boat_position + WIDE_CAMERA_OFFSET
	camera.look_at(boat_position + WIDE_CAMERA_TARGET_OFFSET, Vector3.UP)
	camera.fov = 68.0
	camera.make_current()
	await _wait_frames(36)

	var output_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)
	var default_fog := environment.fog_enabled
	var default_diagnostic_mode := int(water.get_shader_parameter("water_diagnostic_mode"))
	var default_fade_min := float(water.get_shader_parameter("distance_fade_min"))
	var default_fade_max := float(water.get_shader_parameter("distance_fade_max"))

	# A: actual pre-fix material and fog at the problematic wide camera.
	environment.fog_enabled = true
	water.set_shader_parameter("water_diagnostic_mode", 0)
	await _capture_frame("A_before_wide_normal_fog_on", output_path)

	# B: fixed base color with fog disabled; all other shader features are removed.
	environment.fog_enabled = false
	water.set_shader_parameter("water_diagnostic_mode", 1)
	await _capture_frame("diagnostic_flat_base_fog_off_default_fade", output_path)

	# C: same base-color diagnostic, but keep the distant water opaque.
	# This is a diagnostic override only, not a candidate final setting.
	water.set_shader_parameter("distance_fade_min", 25000.0)
	water.set_shader_parameter("distance_fade_max", 30000.0)
	await _capture_frame("diagnostic_flat_base_fog_off_long_fade", output_path)

	# D: normal material, no environment fog, original distance fade restored.
	water.set_shader_parameter("distance_fade_min", default_fade_min)
	water.set_shader_parameter("distance_fade_max", default_fade_max)
	water.set_shader_parameter("water_diagnostic_mode", 0)
	await _capture_frame("diagnostic_normal_fog_off_default_fade", output_path)

	# E: normal material and original fade with environment fog restored.
	environment.fog_enabled = default_fog
	await _capture_frame("diagnostic_normal_fog_on_default_fade", output_path)

	# F: visualize bathymetry validity/depth to see whether the edge follows its bounds.
	environment.fog_enabled = false
	water.set_shader_parameter("water_diagnostic_mode", 6)
	await _capture_frame("diagnostic_bathymetry_validity", output_path)

	# G/H: test whether the apparent wedge belongs to the shoreline mesh or the
	# water alpha cutoff. Keep the same camera transform and render resolution.
	water.set_shader_parameter("water_diagnostic_mode", 0)
	environment.fog_enabled = default_fog
	var region := main.get_node("OresundRegion") as Node3D
	var region_was_visible := region.visible
	region.visible = false
	await _capture_frame("diagnostic_terrain_hidden", output_path)
	region.visible = region_was_visible
	var terrain_chunks := region.get_node_or_null("TerrainChunks") as Node3D
	var terrain_shadow_states: Array[bool] = []
	var terrain_materials: Array[Material] = []
	if terrain_chunks != null:
		for chunk in terrain_chunks.get_children():
			if chunk is MeshInstance3D:
				var terrain_chunk := chunk as MeshInstance3D
				terrain_shadow_states.append(terrain_chunk.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
				terrain_materials.append(terrain_chunk.material_override)
				terrain_chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	await _capture_frame("diagnostic_terrain_shadows_off", output_path)
	if terrain_chunks != null:
		var terrain_index := 0
		for chunk in terrain_chunks.get_children():
			if chunk is MeshInstance3D:
				var terrain_chunk := chunk as MeshInstance3D
				terrain_chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if terrain_shadow_states[terrain_index] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				var terrain_debug := StandardMaterial3D.new()
				terrain_debug.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				terrain_debug.cull_mode = BaseMaterial3D.CULL_DISABLED
				terrain_debug.albedo_color = Color(1.0, 0.02, 0.45, 1.0)
				terrain_chunk.material_override = terrain_debug
				terrain_index += 1
	await _capture_frame("diagnostic_terrain_geometry_magenta", output_path)
	if terrain_chunks != null:
		var restore_index := 0
		for chunk in terrain_chunks.get_children():
			if chunk is MeshInstance3D:
				(chunk as MeshInstance3D).material_override = terrain_materials[restore_index]
				restore_index += 1
	water.set_shader_parameter("distance_fade_min", 60000.0)
	water.set_shader_parameter("distance_fade_max", 60001.0)
	await _capture_frame("diagnostic_water_alpha_fade_removed", output_path)
	water.set_shader_parameter("distance_fade_min", default_fade_min)
	water.set_shader_parameter("distance_fade_max", default_fade_max)

	# I: replace only the generated mesh materials to show each LOD shell/plane.
	water.set_shader_parameter("water_diagnostic_mode", default_diagnostic_mode)
	var ocean_children := ocean.get_children()
	for child in ocean_children:
		if child is not MeshInstance3D:
			continue
		var mesh_instance := child as MeshInstance3D
		var debug_material := StandardMaterial3D.new()
		debug_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		debug_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		debug_material.albedo_color = _lod_color(mesh_instance.name)
		mesh_instance.material_override = debug_material
		var vertices := 0
		var triangles := 0
		if mesh_instance.mesh is ArrayMesh:
			var array_mesh := mesh_instance.mesh as ArrayMesh
			for surface_index in range(array_mesh.get_surface_count()):
				var surface_vertices := array_mesh.surface_get_array_len(surface_index)
				vertices += surface_vertices
				triangles += surface_vertices / 3
		geometry_report.append({
			"node": mesh_instance.name,
			"position": [mesh_instance.position.x, mesh_instance.position.y, mesh_instance.position.z],
			"vertices": vertices,
			"triangles": triangles,
		})
	await _capture_frame("diagnostic_lod_shells", output_path)

	var report := {
		"renderer": RenderingServer.get_video_adapter_name(),
		"engine": Engine.get_version_info(),
		"viewport_px": [root.size.x, root.size.y],
		"quality": "High",
		"camera_offset": [WIDE_CAMERA_OFFSET.x, WIDE_CAMERA_OFFSET.y, WIDE_CAMERA_OFFSET.z],
		"camera_fov": camera.fov,
		"water_fade_before": [default_fade_min, default_fade_max],
		"water_far_edge": ocean.get("far_edge"),
		"water_lod_levels": ocean.get("levels_of_detail"),
		"water_outermost_resolution": ocean.get("outermost_resolution"),
		"water_region_width": ocean.get("region_width"),
		"water_total_width": ocean.get("total_width"),
		"generated_meshes": geometry_report,
		"captures": captures,
	}
	var report_file := FileAccess.open(output_path.path_join("diagnostics_report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "  ") + "\n")
	print(JSON.stringify(report, "  "))

	water.set_shader_parameter("distance_fade_min", default_fade_min)
	water.set_shader_parameter("distance_fade_max", default_fade_max)
	water.set_shader_parameter("water_diagnostic_mode", default_diagnostic_mode)
	water.set_shader_parameter("freeze_time", false)
	environment.fog_enabled = default_fog
	main.queue_free()
	await process_frame
	quit()


func _lod_color(node_name: String) -> Color:
	if node_name.ends_with("_far"):
		return Color(1.0, 0.12, 0.10)
	if node_name.ends_with("_mid"):
		return Color(1.0, 0.68, 0.08)
	var parts := node_name.split("_")
	if parts.size() >= 5:
		var shell := maxi(abs(int(parts[3])), abs(int(parts[4])))
		match shell:
			0:
				return Color(0.10, 0.86, 0.24)
			1:
				return Color(0.12, 0.55, 0.95)
			2:
				return Color(0.65, 0.20, 0.95)
			_:
				return Color(0.96, 0.22, 0.55)
	return Color.WHITE


func _capture_frame(capture_name: String, output_path: String) -> void:
	await _wait_frames(12)
	var image := root.get_texture().get_image()
	var file_path := output_path.path_join(capture_name + ".png")
	var error := image.save_png(file_path)
	captures.append({
		"name": capture_name,
		"path": file_path,
		"width": image.get_width(),
		"height": image.get_height(),
		"save_error": error,
	})


func _wait_frames(count: int) -> void:
	for _index in range(count):
		await process_frame
