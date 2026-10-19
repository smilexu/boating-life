extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")
var _failed := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var world := MAIN_SCENE.instantiate()
	root.add_child(world)
	await process_frame
	await process_frame
	var farms := world.get_node_or_null("OresundWindFarms") as OresundWindFarms
	_check(farms != null, "wind farm scene is integrated in main.tscn")
	if farms == null:
		quit(1)
		return
	var snapshot: Dictionary = farms.get_debug_snapshot()
	_check(int(snapshot.get("lillgrund_turbines", 0)) == 48, "Lillgrund contains exactly 48 turbines")
	_check(int(snapshot.get("middelgrunden_turbines", 0)) == 20, "Middelgrunden contains exactly 20 turbines")
	_check(int(snapshot.get("total_turbines", 0)) == 68, "the two farms contain 68 turbines total")
	var layout_file := FileAccess.open("res://resources/oresund_wind_farms.json", FileAccess.READ)
	var layout_data: Dictionary = JSON.parse_string(layout_file.get_as_text()) if layout_file != null else {}
	var farm_data: Array = layout_data.get("farms", [])
	var lillgrund_points: Array = farm_data[0].get("turbine_positions_wgs84", []) if farm_data.size() > 0 else []
	var middelgrunden_points: Array = farm_data[1].get("turbine_positions_wgs84", []) if farm_data.size() > 1 else []
	var middelgrunden_max_longitude := -INF
	for point in middelgrunden_points:
		middelgrunden_max_longitude = maxf(middelgrunden_max_longitude, float(point.get("longitude_deg", -INF)))
	var middelgrunden_end_mean := 0.0
	if middelgrunden_points.size() == 20:
		middelgrunden_end_mean = (
			float(middelgrunden_points[0].get("longitude_deg", 0.0))
			+ float(middelgrunden_points.back().get("longitude_deg", 0.0))
		) * 0.5
	_check(lillgrund_points.size() == 48 and str(farm_data[0].get("layout_type", "")).contains("array"), "Lillgrund source layout is a 48-point staggered array")
	_check(middelgrunden_points.size() == 20 and middelgrunden_max_longitude - middelgrunden_end_mean > 0.001, "Middelgrunden mapped points retain a measurable curved arc")
	var renderers := [
		farms.get_node_or_null("TurbinesNearBase"),
		farms.get_node_or_null("TurbinesNearRotors"),
		farms.get_node_or_null("TurbinesFarBase"),
		farms.get_node_or_null("TurbinesFarRotors"),
		farms.get_node_or_null("TurbineNightBeacons"),
		farms.get_node_or_null("TurbinePlatformLights"),
	]
	var all_batches_valid := true
	for renderer in renderers:
		all_batches_valid = all_batches_valid and renderer is MultiMeshInstance3D
		if renderer is MultiMeshInstance3D:
			var expected_instances := 136 if renderer.name == "TurbinePlatformLights" else 68
			all_batches_valid = all_batches_valid and (renderer as MultiMeshInstance3D).multimesh.instance_count == expected_instances
	_check(all_batches_valid, "six shared MultiMesh batches allocate turbine and platform-light instances")
	_check(int(snapshot.get("render_batches", 0)) == 6, "the scene keeps the farms to six shared render batches")
	_check(int(snapshot.get("dynamic_lighted_turbine_limit", 0)) == 4 and int(snapshot.get("dynamic_lighted_turbine_count", 0)) == 4, "dynamic fill lights are pooled for only the four nearest near-LOD turbines")
	_check(int(snapshot.get("dynamic_light_node_count", 0)) == 12, "each pooled turbine has one beacon and two platform fill lights")
	_check(is_equal_approx(float(snapshot.get("beacon_emission_energy", 0.0)), 1.1), "red beacon emissive strength is doubled")
	_check(is_equal_approx(float(snapshot.get("platform_light_emission_energy", 0.0)), 0.6), "amber platform emissive strength is doubled")
	_check(is_equal_approx(float(snapshot.get("beacon_fill_light_range_m", 0.0)), 80.0), "red beacon fill light has an 80 m range")
	_check(is_equal_approx(float(snapshot.get("platform_fill_light_range_m", 0.0)), 45.0), "amber platform fill lights have a 45 m range")
	var beacon_mesh_renderer := farms.get_node_or_null("TurbineNightBeacons") as MultiMeshInstance3D
	var platform_mesh_renderer := farms.get_node_or_null("TurbinePlatformLights") as MultiMeshInstance3D
	var beacon_sphere := beacon_mesh_renderer.multimesh.mesh as SphereMesh if beacon_mesh_renderer != null else null
	var platform_sphere := platform_mesh_renderer.multimesh.mesh as SphereMesh if platform_mesh_renderer != null else null
	_check(beacon_sphere != null and is_equal_approx(beacon_sphere.radius, 1.1), "red obstacle-beacon geometry radius is doubled")
	_check(platform_sphere != null and is_equal_approx(platform_sphere.radius, 0.4), "amber platform-light geometry radius is doubled")
	var dynamic_light_nodes := 0
	var all_dynamic_lights_are_shadowless := true
	for child in farms.get_children():
		if child is OmniLight3D:
			dynamic_light_nodes += 1
			all_dynamic_lights_are_shadowless = all_dynamic_lights_are_shadowless and not (child as OmniLight3D).shadow_enabled
	_check(dynamic_light_nodes == 12 and all_dynamic_lights_are_shadowless, "12 pooled real lights add local illumination without shadow maps")
	_check(int(snapshot.get("visible_turbines", 0)) == 68, "default Malmö-side scene position keeps both farms in far view range")
	var records: Array = farms.get("_records")
	_check(records.size() == 68, "all fixed GPS records were converted into runtime positions")
	if records.size() == 68:
		var boat := world.get_node("PlayerBoat/MotionRoot") as Node3D
		boat.global_position = records[0]["position"]
		farms.call("_update_lod")
		snapshot = farms.get_debug_snapshot()
		_check(int(snapshot.get("near_lod_turbines", 0)) > 0, "near LOD activates when the player reaches a turbine")
		var initial_angle := float(farms.get("_rotor_angle"))
		await create_timer(0.2).timeout
		_check(float(farms.get("_rotor_angle")) != initial_angle, "shared rotor animation advances")
		farms.debug_teleport_to_next_farm()
		var lillgrund_center := _farm_center_world(farms, "lillgrund")
		var first_forward := -boat.global_transform.basis.z
		_check(str(farms.get_debug_snapshot().get("last_debug_teleport_farm", "")) == "lillgrund", "first debug teleport targets Lillgrund")
		_check(absf(Vector2(boat.global_position.x - lillgrund_center.x, boat.global_position.z - lillgrund_center.z).length() - farms.debug_observation_offset_m) < 1.0, "Lillgrund teleport lands at the configured offshore offset")
		_check(first_forward.dot((lillgrund_center - boat.global_position).normalized()) > 0.99, "the boat faces Lillgrund after teleport")
		_check(is_equal_approx(float(boat.get("speed_mps")), 0.0), "debug teleport stops the boat")
		farms.debug_teleport_to_next_farm()
		var middelgrunden_center := _farm_center_world(farms, "middelgrunden")
		_check(str(farms.get_debug_snapshot().get("last_debug_teleport_farm", "")) == "middelgrunden", "second debug teleport targets Middelgrunden")
		_check(absf(Vector2(boat.global_position.x - middelgrunden_center.x, boat.global_position.z - middelgrunden_center.z).length() - farms.debug_observation_offset_m) < 1.0, "Middelgrunden teleport lands at the configured offshore offset")
	print("ORESUND_WIND_FARMS_RUNTIME_TEST: %s · total %d · Lillgrund %d · Middelgrunden %d" % [
		"PASS" if not _failed else "FAIL",
		int(snapshot.get("total_turbines", 0)),
		int(snapshot.get("lillgrund_turbines", 0)),
		int(snapshot.get("middelgrunden_turbines", 0)),
	])
	quit(1 if _failed else 0)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: ", message)
	else:
		_failed = true
		push_error("FAIL: " + message)


func _farm_center_world(farms: OresundWindFarms, farm_id: String) -> Vector3:
	var total := Vector3.ZERO
	var count := 0
	var records: Array = farms.get("_records")
	for record in records:
		if str(record.get("farm_id", "")) != farm_id:
			continue
		var position: Vector3 = record["position"]
		total += position
		count += 1
	return farms.to_global(total / float(maxi(count, 1)))
