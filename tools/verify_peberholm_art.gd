extends SceneTree

var main: Node3D
var camera: Camera3D
var output_directory := ""
var art_enabled := true
var shoreline := Vector2(1704.068, 12264.46)
var offshore := Vector2.ZERO


func _initialize() -> void:
	call_deferred("run")


func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This check requires the actual Forward+ renderer; do not run it headless.")
		quit(2)
		return
	art_enabled = not OS.get_cmdline_user_args().has("--baseline")
	var mode := "art" if art_enabled else "baseline"
	output_directory = ProjectSettings.globalize_path("res://.godot/peberholm_art_preview/%s" % mode)
	DirAccess.make_dir_recursive_absolute(output_directory)
	create_timer(60.0).timeout.connect(func():
		push_error("Peberholm art preview timed out")
		quit(1)
	)
	main = load("res://scenes/main.tscn").instantiate()
	var region := main.get_node("OresundRegion") as Node
	region.set("peberholm_art_enabled", art_enabled)
	root.add_child(main)
	await process_frame
	await process_frame
	var diagnostics: Dictionary = region.call("get_peberholm_render_debug_diagnostics")
	assert(not art_enabled or int(diagnostics.get("flora", {}).get("grass", 0)) == 12000)
	for canvas in main.find_children("*", "CanvasLayer", true, false):
		canvas.visible = false
	var motion := main.get_node("PlayerBoat/MotionRoot") as Node3D
	motion.set("is_motion_paused", true)
	main.get_node("PlayerBoat/FollowCameraRig").process_mode = Node.PROCESS_MODE_DISABLED
	var island_center := Vector2(120.0, 11188.0)
	offshore = (shoreline - island_center).normalized()
	camera = Camera3D.new()
	camera.name = "PeberholmArtValidationCamera"
	camera.far = 30000.0
	camera.fov = 65.0
	main.add_child(camera)
	camera.make_current()

	# A low waterline view, an oblique shoreline close-up and a compact overhead
	# view exercise the shipped distance culling and the real static meshes.
	camera.position = Vector3(shoreline.x + offshore.x * 110.0, 9.0, shoreline.y + offshore.y * 110.0)
	camera.look_at(Vector3(shoreline.x - offshore.x * 185.0, 1.8, shoreline.y - offshore.y * 185.0), Vector3.UP)
	await capture("boat_approach")

	camera.position = Vector3(shoreline.x + offshore.x * 28.0, 38.0, shoreline.y + offshore.y * 28.0)
	camera.look_at(Vector3(shoreline.x - offshore.x * 48.0, 1.8, shoreline.y - offshore.y * 48.0), Vector3.UP)
	await capture("coast_oblique")

	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 300.0
	camera.position = Vector3(island_center.x + 65.0, 150.0, island_center.y + 45.0)
	camera.look_at(Vector3(island_center.x, 1.8, island_center.y), Vector3.FORWARD)
	var environment := load("res://resources/sea_environment.tres").duplicate(true) as Environment
	environment.fog_enabled = false
	environment.volumetric_fog_enabled = false
	camera.environment = environment
	await capture("overhead")

	camera.size = 4700.0
	camera.position = Vector3(island_center.x, 3500.0, island_center.y)
	camera.look_at(Vector3(island_center.x, 0.0, island_center.y), Vector3.FORWARD)
	await capture("whole_island")

	await measure_performance(mode)
	print("PEBERHOLM_ART_PREVIEW mode=%s output=%s" % [mode, output_directory])
	main.queue_free()
	await process_frame
	quit()


func capture(name: String) -> void:
	for _frame in range(16):
		await process_frame
	await RenderingServer.frame_post_draw
	var path := output_directory.path_join(name + ".png")
	var error := root.get_texture().get_image().save_png(path)
	assert(error == OK, "Could not save %s" % path)
	print("CAPTURE %s camera=%s" % [name, camera.global_position])


func measure_performance(mode: String) -> void:
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.position = Vector3(shoreline.x + offshore.x * 110.0, 9.0, shoreline.y + offshore.y * 110.0)
	camera.look_at(Vector3(shoreline.x - offshore.x * 185.0, 1.8, shoreline.y - offshore.y * 185.0), Vector3.UP)
	for _frame in range(90):
		await process_frame
	var frame_milliseconds: Array[float] = []
	var draw_calls_total := 0.0
	var primitives_total := 0.0
	var objects_total := 0.0
	var last_tick := Time.get_ticks_usec()
	for _frame in range(240):
		await process_frame
		var current_tick := Time.get_ticks_usec()
		frame_milliseconds.append(float(current_tick - last_tick) / 1000.0)
		last_tick = current_tick
		draw_calls_total += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		primitives_total += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		objects_total += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	frame_milliseconds.sort()
	var average_ms := 0.0
	for frame_ms in frame_milliseconds:
		average_ms += frame_ms
	average_ms /= maxf(float(frame_milliseconds.size()), 1.0)
	var p95_ms := frame_milliseconds[mini(frame_milliseconds.size() - 1, floori(float(frame_milliseconds.size()) * 0.95))]
	print("PERF mode=%s fps=%.2f avg_frame_ms=%.3f p95_ms=%.3f draw_calls=%.1f primitives=%.0f objects=%.1f samples=%d" % [
		mode,
		1000.0 / maxf(average_ms, 0.001),
		average_ms,
		p95_ms,
		draw_calls_total / frame_milliseconds.size(),
		primitives_total / frame_milliseconds.size(),
		objects_total / frame_milliseconds.size(),
		frame_milliseconds.size(),
	])
