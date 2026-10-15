extends SceneTree
## Captures controlled water diagnostics from the real main scene.
## Run: godot --path . --script res://tools/capture_water_color_comparison.gd

const MAIN_SCENE := "res://scenes/main.tscn"
const OUTPUT_DIR := "res://docs/water_color_comparison"
const WARMUP_FRAMES := 30
const MEASURE_FRAMES := 120

const ORIGINAL_PARAMETERS := {
	"wave_normal_strength": 1.0,
	"detail_normal_strength_near": 2.5,
	"depth_color_strength": 0.8,
}
const CLEAN_PARAMETERS := {
	"wave_normal_strength": 0.45,
	"detail_normal_strength_near": 0.8,
	"depth_color_strength": 0.6,
}
const SOFT_PARAMETERS := {
	"wave_normal_strength": 0.25,
	"detail_normal_strength_near": 0.4,
	"depth_color_strength": 0.6,
}
const DEPTH_SOFT_PARAMETERS := {
	"wave_normal_strength": 1.0,
	"detail_normal_strength_near": 2.5,
	"depth_color_strength": 0.6,
}
const VISUAL_STATES := [
	{"name": "A_flat_base", "mode": 1, "parameters": "original"},
	{"name": "B_waves_no_color_texture_or_depth", "mode": 2, "parameters": "original"},
	{"name": "C_waves_plus_bathymetry", "mode": 3, "parameters": "original"},
	{"name": "D_full_shader", "mode": 0, "parameters": "original"},
	{"name": "P_full_flat_wave_normal", "mode": 11, "parameters": "original"},
	{"name": "G_depth_strength_060_only", "mode": 0, "parameters": "depth_soft"},
	{"name": "E_final_reduced_normal_contrast", "mode": 0, "parameters": "clean"},
	{"name": "F_soft_normal_candidate", "mode": 0, "parameters": "soft"},
]
const FPS_STATES := [
	{"name": "B_waves_no_color_texture_or_depth", "mode": 2, "parameters": "original"},
	{"name": "C_waves_plus_bathymetry", "mode": 3, "parameters": "original"},
	{"name": "D_full_shader", "mode": 0, "parameters": "original"},
	{"name": "G_depth_strength_060_only", "mode": 0, "parameters": "depth_soft"},
	{"name": "E_final_reduced_normal_contrast", "mode": 0, "parameters": "clean"},
	{"name": "F_soft_normal_candidate", "mode": 0, "parameters": "soft"},
]


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var packed_scene := load(MAIN_SCENE) as PackedScene
	if packed_scene == null:
		push_error("Could not load %s" % MAIN_SCENE)
		quit(1)
		return
	var main := packed_scene.instantiate()
	root.add_child(main)
	for _frame in range(8):
		await process_frame

	var manager := main.get_node_or_null("BathymetryManager")
	var material := manager.get("water_material") as ShaderMaterial if manager != null else null
	if material == null:
		push_error("Main scene has no BathymetryManager ShaderMaterial")
		main.queue_free()
		await process_frame
		quit(1)
		return

	var saved_parameters: Dictionary = {}
	for parameter_name in ORIGINAL_PARAMETERS:
		saved_parameters[parameter_name] = material.get_shader_parameter(parameter_name)
	var saved_freeze := bool(material.get_shader_parameter("freeze_time"))
	var output_path := ProjectSettings.globalize_path(OUTPUT_DIR)
	DirAccess.make_dir_recursive_absolute(output_path)
	material.set_shader_parameter("freeze_time", true)
	material.set_shader_parameter("water_diagnostic_mode", 0)

	var captures: Array[Dictionary] = []
	for state in VISUAL_STATES:
		_apply_parameters(material, str(state["parameters"]))
		material.set_shader_parameter("water_diagnostic_mode", int(state["mode"]))
		for _settle in range(5):
			await process_frame
		var frame := root.get_texture().get_image()
		var path := output_path.path_join(str(state["name"]) + ".png")
		captures.append({
			"name": state["name"],
			"mode": state["mode"],
			"parameters": state["parameters"],
			"width": frame.get_width(),
			"height": frame.get_height(),
			"path": path,
			"save_error": frame.save_png(path),
		})

	var fps_results: Array[Dictionary] = []
	for state in FPS_STATES:
		_apply_parameters(material, str(state["parameters"]))
		material.set_shader_parameter("water_diagnostic_mode", int(state["mode"]))
		for _warmup in range(WARMUP_FRAMES):
			await process_frame
		var start_us := Time.get_ticks_usec()
		for _sample in range(MEASURE_FRAMES):
			await process_frame
		var elapsed_seconds := float(Time.get_ticks_usec() - start_us) / 1000000.0
		fps_results.append({
			"name": state["name"],
			"frames": MEASURE_FRAMES,
			"elapsed_seconds": elapsed_seconds,
			"average_fps": float(MEASURE_FRAMES) / maxf(elapsed_seconds, 0.000001),
			"frame_time_ms": elapsed_seconds * 1000.0 / float(MEASURE_FRAMES),
		})

	material.set_shader_parameter("water_diagnostic_mode", 0)
	material.set_shader_parameter("freeze_time", saved_freeze)
	for parameter_name in saved_parameters:
		material.set_shader_parameter(parameter_name, saved_parameters[parameter_name])
	var report := {
		"engine": Engine.get_version_info(),
		"renderer": RenderingServer.get_video_adapter_name(),
		"resolution": [root.size.x, root.size.y],
		"vsync_mode": DisplayServer.window_get_vsync_mode(),
		"max_fps": Engine.max_fps,
		"waves_frozen_for_visual_comparison": true,
		"wave_count": int(material.get_shader_parameter("WaveCount")),
		"captures": captures,
		"fps": fps_results,
	}
	print(JSON.stringify(report, "  "))
	var report_file := FileAccess.open(output_path.path_join("report.json"), FileAccess.WRITE)
	if report_file != null:
		report_file.store_string(JSON.stringify(report, "  ") + "\n")
	main.queue_free()
	await process_frame
	quit()


func _apply_parameters(material: ShaderMaterial, parameter_set: String) -> void:
	var parameters: Dictionary = ORIGINAL_PARAMETERS
	if parameter_set == "clean":
		parameters = CLEAN_PARAMETERS
	elif parameter_set == "soft":
		parameters = SOFT_PARAMETERS
	elif parameter_set == "depth_soft":
		parameters = DEPTH_SOFT_PARAMETERS
	for parameter_name in parameters:
		material.set_shader_parameter(parameter_name, parameters[parameter_name])
