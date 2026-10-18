extends SceneTree
var main: Node3D
var camera: Camera3D
var region: Node3D
var output := ProjectSettings.globalize_path("res://.godot/peberholm_shore_check")
func _initialize(): call_deferred("run")
func snap(name: String):
	for i in range(14): await process_frame
	await RenderingServer.frame_post_draw
	var error = root.get_texture().get_image().save_png(output.path_join(name + ".png"))
	assert(error == OK)
	print("CAPTURE ", name, " camera=", camera.global_position)
func faces(mesh: ArrayMesh) -> Dictionary:
	var result := {}
	for surface in range(mesh.get_surface_count()):
		var a = mesh.surface_get_arrays(surface)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count = v.size() if indices.is_empty() else indices.size()
		for i in range(0, count, 3):
			var triangle := PackedVector3Array()
			for j in range(3): triangle.append(v[i+j] if indices.is_empty() else v[indices[i+j]])
			var key = triangle.to_byte_array().hex_encode()
			result[key] = result.get(key, 0) + 1
	return result
func validate_partition(source: MeshInstance3D, rest: MeshInstance3D, focus: MeshInstance3D, check_cull := true):
	var combined = faces(rest.mesh)
	var selected = faces(focus.mesh)
	for key in selected: combined[key] = combined.get(key, 0) + selected[key]
	assert(combined == faces(source.mesh), "Partition changed or lost source triangle coordinates")
	assert(not source.visible and rest.visible and focus.visible)
	if check_cull:
		assert(focus.material_override is ShaderMaterial, "Peberholm top should use its opaque local ground shader")
func run():
	if DisplayServer.get_name() == "headless":
		push_error("Run without --headless: this check requires actual Forward+ captures.")
		quit(2)
		return
	create_timer(45.0).timeout.connect(func():
		push_error("Peberholm Forward+ check timed out")
		quit(1)
	)
	DirAccess.make_dir_recursive_absolute(output)
	main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	region = main.get_node("OresundRegion")
	var coast = region.get_node("CoastTransitions")
	for split in region.get("_peberholm_terrain_splits"):
		validate_partition(split.source, split.remainder, split.focus)
	region.call("_set_peberholm_render_debug", true)
	var coast_partition: Dictionary = coast.get_peberholm_debug_diagnostics()
	assert(bool(coast_partition.get("partition_preserved", false)), "Coast art split did not preserve the source triangle count")
	assert(coast.get("_mesh_instance").visible and coast.get("_peberholm_debug_instance").visible)
	region.call("_set_peberholm_render_debug", false)
	assert(coast.get("_mesh_instance").visible and coast.get("_peberholm_debug_instance").visible)
	assert(coast.get("_peberholm_debug_instance").material_override is ShaderMaterial)
	assert(region.get("_peberholm_flora").visible)
	var body: MeshInstance3D = coast.get("_peberholm_body_instance")
	var body_mesh_id = body.mesh.get_instance_id()
	region.call("_set_peberholm_render_debug", true)
	region.call("_set_peberholm_render_debug", false)
	assert(body.mesh.get_instance_id() == body_mesh_id)
	print("INVARIANTS exact source-face partitions preserved; source heights/normals/data untouched; F3 restored local material; closed body unchanged")
	print("TOP ", region.get_peberholm_render_debug_diagnostics().top)
	var coast_mesh: ArrayMesh = coast.get("_peberholm_debug_instance").mesh
	var coast_vertices: PackedVector3Array = coast_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var boat: Vector3 = region.georeference.geodetic_to_world(55.58997, 12.77726, 0.0)
	var motion := main.get_node("PlayerBoat/MotionRoot") as Node3D
	motion.global_position = Vector3(boat.x, 0.0, boat.z)
	motion.set("speed_mps", 0.0)
	motion.set("is_motion_paused", true)
	var boat_xz := Vector2(boat.x, boat.z)
	var closest := Vector2.ZERO
	var nearest := INF
	var max_osm_gap := 0.0
	var min_osm_gap := INF
	var crossings := 0
	var outside_osm := 0
	for i in range(0, coast_vertices.size(), 3):
		var intersections := PackedVector2Array()
		for j in range(3):
			var a = coast_vertices[i+j]
			var b = coast_vertices[i+(j+1)%3]
			if (a.y <= 0.0 and b.y > 0.0) or (b.y <= 0.0 and a.y > 0.0):
				var p: Vector3 = a.lerp(b, -a.y/(b.y-a.y))
				var xz := Vector2(p.x, p.z)
				intersections.append(xz)
				var d: float = region.call("_distance_to_outline", xz)
				max_osm_gap = maxf(max_osm_gap, d)
				min_osm_gap = minf(min_osm_gap, d)
				crossings += 1
				if not Geometry2D.is_point_in_polygon(xz, region.get("_peberholm_outline")): outside_osm += 1
		if intersections.size() == 2:
			var p := Geometry2D.get_closest_point_to_segment(boat_xz, intersections[0], intersections[1])
			if p.distance_to(boat_xz) < nearest:
				closest = p
				nearest = p.distance_to(boat_xz)
	print("SHORE waterline uses actual triangle-plane intersections Y=0; OSM mismatch=", min_osm_gap, "..", max_osm_gap, "m; outside OSM=", outside_osm, "/", crossings, " nearest=", closest, " boat distance=", nearest)
	for n in main.find_children("*", "CanvasLayer", true, false): n.visible = false
	main.get_node("PlayerBoat/MotionRoot").set("is_motion_paused", true)
	main.get_node("PlayerBoat/FollowCameraRig").process_mode = Node.PROCESS_MODE_DISABLED
	main.get_node("PlayerBoat/MotionRoot/VisualRoot").visible = false
	camera = Camera3D.new()
	main.add_child(camera)
	camera.far = 30000
	camera.fov = 65
	camera.make_current()
	camera.position = Vector3(boat.x + 30, 9, boat.z - 30)
	camera.look_at(Vector3(120, 1.8, 11188), Vector3.UP)
	await snap("boat_normal")
	var direction := (closest - Vector2(120, 11188)).normalized()
	camera.position = Vector3(closest.x + direction.x * 35, 6, closest.y + direction.y * 35)
	camera.look_at(Vector3(closest.x - direction.x * 35, 1.0, closest.y - direction.y * 35), Vector3.UP)
	await snap("near_shore")
	var water: ShaderMaterial = main.get_node("Ocean").material
	main.get_node("WaveSampler").set_process(false)
	water.set_shader_parameter("freeze_time", false)
	var normal_strength: float = main.get_node("WaveSampler").wave_strength
	main.get_node("WeatherController").set_wave_strength(1.5)
	water.set_shader_parameter("WaveTime", 5.0)
	await snap("waves_5s")
	water.set_shader_parameter("WaveTime", 12.0)
	await snap("waves_12s")
	main.get_node("WeatherController").set_wave_strength(normal_strength)
	# Keep the actual lighting/sky, disable fog only for the complete-island diagnostic.
	var env: Environment = load("res://resources/sea_environment.tres").duplicate(true)
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	camera.environment = env
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 4700
	camera.position = Vector3(120, 3500, 11188)
	camera.look_at(Vector3(120, 0, 11188), Vector3.FORWARD)
	await snap("aerial_no_fog")
	print("PASS Forward+ production materials; near-shore waves strength=1.5 at t=5/12s; captures=", output)
	main.queue_free()
	await process_frame
	quit()
