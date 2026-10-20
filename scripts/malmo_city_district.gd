extends Node3D

## Static, low-poly waterfront district assembled from the available Malmö GLBs
## and a small set of shared greybox materials.

const TURNING_TORSO_SCENE: PackedScene = preload("res://assets/cities/malmo/turning_torso.glb")
const BLUE_BUILDING_SCENE: PackedScene = preload("res://assets/cities/common/blue_building.glb")
const BROWN_BUILDING_SCENE: PackedScene = preload("res://assets/cities/common/brown_building.glb")
const WHITE_BUILDING_SCENE: PackedScene = preload("res://assets/cities/common/white_building.glb")
const TREE_SCENE: PackedScene = preload("res://assets/cities/common/tree.glb")

const DISTRICT_EAST_SHIFT_M := 20.0
const GROUND_TOP_Y_M := 0.82
const BASE_BOTTOM_Y_M := -2.0

var _materials: Dictionary = {}
var _building_footprints_en: Array[Rect2] = []


func _ready() -> void:
	_build_materials()
	_build_district_ground()
	_build_buildings()
	_build_trees()


func _build_materials() -> void:
	_materials["base"] = _make_material(Color("777c78"))
	_materials["ground"] = _make_material(Color("697569"))
	_materials["road"] = _make_material(Color("343a3d"))
	_materials["paving"] = _make_material(Color("a3a39c"))
	_materials["sidewalk"] = _make_material(Color("858783"))
	_materials["grass"] = _make_material(Color("465b3d"))
	_materials["curb"] = _make_material(Color("b2b0a8"))
	_materials["grey_building"] = _make_material(Color("8b8e8a"))
	_materials["grey_building_alt"] = _make_material(Color("777d80"))
	_materials["roof"] = _make_material(Color("454c50"))
	_materials["window"] = _make_material(Color("263840"))


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.88
	material.metallic = 0.0
	return material


func _build_district_ground() -> void:
	# The west/north edge follows the sampled Malmö shoreline instead of using a
	# rectangular diorama base that would visibly overhang the water.
	var land_outline := PackedVector2Array([
		Vector2(-100.0, -115.0),
		Vector2(120.0, -115.0),
		Vector2(120.0, 115.0),
		Vector2(30.0, 115.0),
		Vector2(30.0, 95.0),
		Vector2(-100.0, 85.0),
	])
	land_outline = _ensure_counter_clockwise(land_outline)
	_add_polygon_mesh("DistrictGround", land_outline, GROUND_TOP_Y_M, _materials["ground"])
	_add_extruded_polygon("DistrictBase", land_outline, GROUND_TOP_Y_M, BASE_BOTTOM_Y_M, _materials["base"])

	# A simple street ring keeps the cluster readable from the sea without
	# replacing the surrounding terrain or creating collisions.
	_add_patch("NorthWaterfrontRoad", Vector2(75.0, 104.0), 90.0, 9.0, _materials["road"])
	_add_patch("SouthAccessRoad", Vector2(10.0, -104.0), 220.0, 9.0, _materials["road"])
	_add_patch("WestAccessRoad", Vector2(-95.0, 0.0), 9.0, 160.0, _materials["road"])
	_add_patch("EastAccessRoad", Vector2(115.0, 0.0), 9.0, 194.0, _materials["road"])

	# Central plaza and its four short approach streets.
	_add_patch("TurningTorsoPlaza", Vector2.ZERO, 76.0, 76.0, _materials["paving"])
	_add_patch("NorthPlazaStreet", Vector2(0.0, 48.0), 112.0, 7.0, _materials["road"])
	_add_patch("SouthPlazaStreet", Vector2(0.0, -48.0), 112.0, 7.0, _materials["road"])
	_add_patch("WestPlazaStreet", Vector2(-51.0, 0.0), 7.0, 104.0, _materials["road"])
	_add_patch("EastPlazaStreet", Vector2(51.0, 0.0), 7.0, 104.0, _materials["road"])

	var block_centres := [
		Vector2(-78.0, 70.0), Vector2(-78.0, -70.0),
		Vector2(88.0, 70.0), Vector2(88.0, -70.0),
	]
	for index in range(block_centres.size()):
		_add_patch("BuildingForecourt_%02d" % index, block_centres[index], 38.0, 36.0, _materials["sidewalk"])
		var garden_east_offset := 22.0
		if index == 0:
			garden_east_offset = -14.0
		elif index == 2:
			garden_east_offset = -22.0
		var garden_offset := Vector2(garden_east_offset, 0.0)
		_add_patch("Garden_%02d" % index, block_centres[index] + garden_offset, 13.0, 20.0, _materials["grass"])

	# Two small greybox blocks fill the gaps visible in the reference layout.
	_add_greybox_block("NorthMidrise", Vector2(50.0, 83.0), Vector3(36.0, 17.0, 25.0), _materials["grey_building"])
	_add_greybox_block("SouthMidrise", Vector2(0.0, -83.0), Vector3(38.0, 14.0, 25.0), _materials["grey_building_alt"])

	# Light concrete edging helps the urban block read as one composed district.
	_add_patch("NorthKerb", Vector2(75.0, 111.0), 90.0, 1.2, _materials["curb"])
	_add_patch("SouthKerb", Vector2(10.0, -111.0), 220.0, 1.2, _materials["curb"])
	_add_patch("WestKerb", Vector2(-99.4, 0.0), 1.2, 160.0, _materials["curb"])
	_add_patch("EastKerb", Vector2(119.4, 0.0), 1.2, 220.0, _materials["curb"])


func _build_buildings() -> void:
	# The GLB assets are authored close to unit size. Uniform scene scaling keeps
	# their original proportions while bringing them to city scale.
	_add_model("TurningTorso", TURNING_TORSO_SCENE, Vector2(0.0, 0.0), 162.0)
	_add_model("BlueGlassApartment", BLUE_BUILDING_SCENE, Vector2(-78.0, 70.0), 32.0)
	_add_model("WhiteApartmentWest", WHITE_BUILDING_SCENE, Vector2(-78.0, -70.0), 29.0)
	_add_model("WhiteApartmentEast", WHITE_BUILDING_SCENE, Vector2(88.0, 70.0), 34.0)
	_add_model("BrickApartment", BROWN_BUILDING_SCENE, Vector2(88.0, -70.0), 30.0)


func _build_trees() -> void:
	var tree_positions := [
		Vector2(-39.0, 54.0), Vector2(39.0, 54.0),
		Vector2(-39.0, -54.0), Vector2(39.0, -54.0),
		Vector2(-66.0, 0.0), Vector2(66.0, 0.0),
		Vector2(-95.0, 37.0), Vector2(-95.0, -37.0),
		Vector2(105.0, 37.0), Vector2(105.0, -37.0),
		Vector2(60.0, 94.0), Vector2(95.0, 94.0),
		Vector2(-25.0, -94.0), Vector2(25.0, -94.0),
	]
	for index in range(tree_positions.size()):
		var tree := TREE_SCENE.instantiate() as Node3D
		tree.name = "StreetTree_%02d" % index
		tree.position = _position_en(tree_positions[index], GROUND_TOP_Y_M)
		var size := 7.0 + float(index % 4) * 0.55
		tree.scale = Vector3.ONE * size
		tree.rotation.y = deg_to_rad(float((index * 47) % 360))
		add_child(tree)


func _add_model(node_name: String, packed_scene: PackedScene, centre_en: Vector2, scale_factor: float) -> void:
	var model := packed_scene.instantiate() as Node3D
	model.name = node_name
	model.position = _position_en(centre_en, GROUND_TOP_Y_M)
	model.scale = Vector3.ONE * scale_factor
	add_child(model)
	_register_model_footprint(model)


func _add_greybox_block(node_name: String, centre_en: Vector2, size: Vector3, material: Material) -> void:
	_register_building_footprint(centre_en, Vector2(size.x, size.z))
	_add_box(node_name, centre_en, size, GROUND_TOP_Y_M + size.y * 0.5, material, true)
	_add_box(
		node_name + "RoofPlant",
		centre_en + Vector2(5.0, -2.0),
		Vector3(size.x * 0.32, 1.6, size.z * 0.38),
		GROUND_TOP_Y_M + size.y + 0.8,
		_materials["roof"],
		true
	)
	_add_box(
		node_name + "WindowBand",
		centre_en + Vector2(0.0, 0.0),
		Vector3(size.x + 0.04, maxf(1.2, size.y * 0.12), size.z + 0.04),
		GROUND_TOP_Y_M + size.y * 0.57,
		_materials["window"],
		false
	)


func _add_patch(node_name: String, centre_en: Vector2, width_m: float, depth_m: float, material: Material) -> void:
	_add_box(node_name, centre_en, Vector3(width_m, 0.06, depth_m), GROUND_TOP_Y_M, material, false)


func _add_box(node_name: String, centre_en: Vector2, size: Vector3, centre_y: float, material: Material, casts_shadow: bool) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = _position_en(centre_en, centre_y)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


func _add_polygon_mesh(node_name: String, outline_en: PackedVector2Array, height: float, material: Material) -> void:
	var indices := Geometry2D.triangulate_polygon(outline_en)
	if indices.is_empty():
		push_warning("Malmö district polygon could not be triangulated: %s" % node_name)
		return
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for index in range(0, indices.size(), 3):
		var a: Vector2 = outline_en[indices[index]]
		var b: Vector2 = outline_en[indices[index + 1]]
		var c: Vector2 = outline_en[indices[index + 2]]
		if (b - a).cross(c - a) < 0.0:
			var swap := b
			b = c
			c = swap
		surface.set_normal(Vector3.UP)
		surface.add_vertex(_position_en(a, height))
		surface.set_normal(Vector3.UP)
		surface.add_vertex(_position_en(b, height))
		surface.set_normal(Vector3.UP)
		surface.add_vertex(_position_en(c, height))
	var mesh := surface.commit()
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


func _add_extruded_polygon(node_name: String, outline_en: PackedVector2Array, top_y: float, bottom_y: float, material: Material) -> void:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var indices := Geometry2D.triangulate_polygon(outline_en)
	if indices.is_empty():
		push_warning("Malmö district shell could not be triangulated: %s" % node_name)
		return
	for index in range(0, indices.size(), 3):
		var a: Vector2 = outline_en[indices[index]]
		var b: Vector2 = outline_en[indices[index + 1]]
		var c: Vector2 = outline_en[indices[index + 2]]
		if (b - a).cross(c - a) < 0.0:
			var swap := b
			b = c
			c = swap
		_add_triangle_with_normal(surface, _position_en(a, bottom_y), _position_en(c, bottom_y), _position_en(b, bottom_y), Vector3.DOWN)
	for index in range(outline_en.size()):
		var a_en := outline_en[index]
		var b_en := outline_en[(index + 1) % outline_en.size()]
		var outward := Vector3(b_en.y - a_en.y, 0.0, b_en.x - a_en.x).normalized()
		var a_top := _position_en(a_en, top_y)
		var b_top := _position_en(b_en, top_y)
		var a_bottom := _position_en(a_en, bottom_y)
		var b_bottom := _position_en(b_en, bottom_y)
		_add_triangle_with_normal(surface, a_top, a_bottom, b_bottom, outward)
		_add_triangle_with_normal(surface, a_top, b_bottom, b_top, outward)
	var mesh := surface.commit()
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


func _add_triangle_with_normal(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	surface.set_normal(normal)
	surface.add_vertex(a)
	surface.set_normal(normal)
	surface.add_vertex(b)
	surface.set_normal(normal)
	surface.add_vertex(c)


func _ensure_counter_clockwise(outline: PackedVector2Array) -> PackedVector2Array:
	var signed_area := 0.0
	for index in range(outline.size()):
		var current := outline[index]
		var next := outline[(index + 1) % outline.size()]
		signed_area += current.x * next.y - next.x * current.y
	if signed_area >= 0.0:
		return outline
	var reversed := PackedVector2Array()
	for index in range(outline.size() - 1, -1, -1):
		reversed.append(outline[index])
	return reversed


func _position_en(position_east_north: Vector2, height: float) -> Vector3:
	return Vector3(position_east_north.x + DISTRICT_EAST_SHIFT_M, height, -position_east_north.y)


func get_distance_to_city_cluster(world_position: Vector3) -> float:
	if _building_footprints_en.is_empty():
		return INF
	var city_local := to_local(world_position)
	var boat_en := Vector2(city_local.x, -city_local.z)
	var nearest_distance := INF
	for footprint in _building_footprints_en:
		var closest_point := Vector2(
			clampf(boat_en.x, footprint.position.x, footprint.end.x),
			clampf(boat_en.y, footprint.position.y, footprint.end.y)
		)
		nearest_distance = minf(nearest_distance, boat_en.distance_to(closest_point))
	return nearest_distance


func get_distance_to_building_cluster(world_position: Vector3) -> float:
	# Compatibility alias for callers using the earlier city-specific API.
	return get_distance_to_city_cluster(world_position)


func _register_model_footprint(model_root: Node3D) -> void:
	var bounds := _collect_model_bounds(model_root)
	if bool(bounds.get("found", false)):
		var min_en: Vector2 = bounds["min_en"]
		var max_en: Vector2 = bounds["max_en"]
		_building_footprints_en.append(Rect2(min_en, max_en - min_en))


func _collect_model_bounds(node: Node) -> Dictionary:
	var min_en := Vector2(INF, INF)
	var max_en := Vector2(-INF, -INF)
	var found_visual := false
	if node is VisualInstance3D:
		var visual := node as VisualInstance3D
		var local_bounds := visual.get_aabb()
		for x_index in range(2):
			for y_index in range(2):
				for z_index in range(2):
					var local_point := Vector3(
						local_bounds.position.x if x_index == 0 else local_bounds.end.x,
						local_bounds.position.y if y_index == 0 else local_bounds.end.y,
						local_bounds.position.z if z_index == 0 else local_bounds.end.z
					)
					var city_point := to_local(visual.global_transform * local_point)
					var point_en := Vector2(city_point.x, -city_point.z)
					if not found_visual:
						min_en = point_en
						max_en = point_en
						found_visual = true
					else:
						min_en = min_en.min(point_en)
						max_en = max_en.max(point_en)
	for child in node.get_children():
		var child_bounds := _collect_model_bounds(child)
		if not bool(child_bounds.get("found", false)):
			continue
		var child_min: Vector2 = child_bounds["min_en"]
		var child_max: Vector2 = child_bounds["max_en"]
		if not found_visual:
			min_en = child_min
			max_en = child_max
			found_visual = true
		else:
			min_en = min_en.min(child_min)
			max_en = max_en.max(child_max)
	return {"found": found_visual, "min_en": min_en, "max_en": max_en}


func _register_building_footprint(centre_en: Vector2, size_en: Vector2) -> void:
	var shifted_centre := centre_en + Vector2(DISTRICT_EAST_SHIFT_M, 0.0)
	_building_footprints_en.append(Rect2(shifted_centre - size_en * 0.5, size_en))
