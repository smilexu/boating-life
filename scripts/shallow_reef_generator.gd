class_name ShallowReefGenerator
extends RefCounted

## Loads configured GLBs once, validates their bounds/material parts, and batches
## deterministic placement transforms by reusable mesh. Missing assets are skipped.


static func load_asset_cache(library: ShallowReefAssetLibrary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if library == null:
		return result
	for definition in library.definitions:
		var entry := {
			"definition": definition,
			"loaded": false,
			"parts": [],
			"bounds": AABB(),
			"total_triangles": 0,
		}
		result.append(entry)
		if definition == null or not definition.enabled or definition.glb_path.is_empty():
			continue
		if not ResourceLoader.exists(definition.glb_path):
			push_warning("Reef asset '%s' is missing at %s; this asset will be skipped." % [definition.asset_id, definition.glb_path])
			continue
		var packed := ResourceLoader.load(definition.glb_path) as PackedScene
		if packed == null:
			push_warning("Reef asset '%s' could not be loaded as a PackedScene; this asset will be skipped." % definition.asset_id)
			continue
		var root := packed.instantiate()
		if root == null:
			push_warning("Reef asset '%s' failed to instantiate; this asset will be skipped." % definition.asset_id)
			continue
		var cache := {"parts": [], "bounds": AABB(), "bounds_valid": false, "triangles": 0}
		_collect_mesh_parts(root, Transform3D.IDENTITY, cache)
		root.free()
		if cache["parts"].is_empty() or not bool(cache["bounds_valid"]):
			push_warning("Reef asset '%s' contains no reusable MeshInstance3D; this asset will be skipped." % definition.asset_id)
			continue
		entry["loaded"] = true
		entry["parts"] = cache["parts"]
		entry["bounds"] = cache["bounds"]
		entry["total_triangles"] = int(cache["triangles"])
		print("[ShallowReef] asset %s: %s · bounds %s · %d triangles" % [definition.asset_id, definition.glb_path.get_file(), str(cache["bounds"].size), int(cache["triangles"])])
	return result


static func _collect_mesh_parts(node: Node, inherited_transform: Transform3D, cache: Dictionary) -> void:
	var relative_transform := inherited_transform
	if node is Node3D:
		relative_transform = inherited_transform * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		if mesh_instance.mesh != null:
			var mesh: Mesh = mesh_instance.mesh
			var override_material: Material = mesh_instance.material_override
			if mesh is ArrayMesh:
				# Keep imported PBR textures and material values, while allowing a
				# restrained MultiMesh instance-color variation on the albedo.
				mesh = mesh.duplicate() as Mesh
				for surface in range(mesh.get_surface_count()):
					var surface_material := mesh_instance.get_surface_override_material(surface)
					if surface_material == null:
						surface_material = mesh.surface_get_material(surface)
					if surface_material is BaseMaterial3D:
						var material_copy := (surface_material as BaseMaterial3D).duplicate() as BaseMaterial3D
						material_copy.vertex_color_use_as_albedo = true
						(mesh as ArrayMesh).surface_set_material(surface, material_copy)
				if override_material is BaseMaterial3D:
					var override_copy := (override_material as BaseMaterial3D).duplicate() as BaseMaterial3D
					override_copy.vertex_color_use_as_albedo = true
					override_material = override_copy
			var transformed_bounds := _transformed_aabb(mesh.get_aabb(), relative_transform)
			if not bool(cache["bounds_valid"]):
				cache["bounds"] = transformed_bounds
				cache["bounds_valid"] = true
			else:
				var existing_bounds: AABB = cache["bounds"]
				cache["bounds"] = existing_bounds.merge(transformed_bounds)
			var part_triangles := 0
			for surface in range(mesh.get_surface_count()):
				var index_count: int = mesh.surface_get_array_index_len(surface)
				var vertex_count: int = mesh.surface_get_array_len(surface)
				part_triangles += int((index_count if index_count > 0 else vertex_count) / 3)
			cache["triangles"] = int(cache["triangles"]) + part_triangles
			cache["parts"].append({
				"mesh": mesh,
				"transform": relative_transform,
				"material_override": override_material,
				"triangles": part_triangles,
			})
	for child in node.get_children():
		_collect_mesh_parts(child, relative_transform, cache)


static func _transformed_aabb(bounds: AABB, transform: Transform3D) -> AABB:
	var first := transform * Vector3(bounds.position.x, bounds.position.y, bounds.position.z)
	var result := AABB(first, Vector3.ZERO)
	for x in [bounds.position.x, bounds.end.x]:
		for y in [bounds.position.y, bounds.end.y]:
			for z in [bounds.position.z, bounds.end.z]:
				result = result.expand(transform * Vector3(x, y, z))
	return result


static func add_glb_chunk_multimeshes(
	parent: Node3D,
	asset_cache: Array[Dictionary],
	instances_by_asset: Array,
	visible: bool,
	tile_size_m: float
) -> Dictionary:
	var result := {"instances": 0, "triangles": 0, "batches": 0, "instances_by_asset": {}}
	for asset_index in range(mini(asset_cache.size(), instances_by_asset.size())):
		var entry: Dictionary = asset_cache[asset_index]
		if not bool(entry.get("loaded", false)):
			continue
		var records: Array = instances_by_asset[asset_index]
		if records.is_empty():
			continue
		var definition: ShallowReefAssetDefinition = entry["definition"]
		var asset_id := String(definition.asset_id)
		result["instances_by_asset"][asset_id] = records.size()
		result["instances"] = int(result["instances"]) + records.size()
		result["triangles"] = int(result["triangles"]) + records.size() * int(entry["total_triangles"])
		for part_index in range(entry["parts"].size()):
			var part: Dictionary = entry["parts"][part_index]
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.use_colors = true
			multimesh.mesh = part["mesh"]
			multimesh.instance_count = records.size()
			for index in range(records.size()):
				var record: Dictionary = records[index]
				var centered_part: Transform3D = record["center_offset"] * part["transform"]
				multimesh.set_instance_transform(index, record["transform"] * centered_part)
				multimesh.set_instance_color(index, record["color"])
			var instance := MultiMeshInstance3D.new()
			instance.name = "Reef_%s_Part%d" % [asset_id, part_index]
			instance.multimesh = multimesh
			instance.material_override = part.get("material_override") as Material
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			instance.custom_aabb = AABB(Vector3(-8.0, -14.0, -8.0), Vector3(tile_size_m + 16.0, 22.0, tile_size_m + 16.0))
			instance.visible = visible
			parent.add_child(instance)
			result["batches"] = int(result["batches"]) + 1
	return result


static func add_cluster_debug_mesh(
	parent: Node3D,
	clusters: Array,
	east_min: float,
	north_max: float,
	tile_size_m: float
) -> void:
	if clusters.is_empty():
		return
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.95, 0.42, 0.16, 0.95)
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.no_depth_test = true
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	for cluster in clusters:
		var center := Vector3(float(cluster["east"]) - east_min, float(cluster.get("ground_y", 0.0)) + 0.10, north_max - float(cluster["north"]))
		var radius := float(cluster["radius"])
		const SEGMENTS := 24
		for segment in range(SEGMENTS):
			var angle_a := TAU * float(segment) / float(SEGMENTS)
			var angle_b := TAU * float(segment + 1) / float(SEGMENTS)
			mesh.surface_add_vertex(center + Vector3(cos(angle_a) * radius, 0.0, sin(angle_a) * radius))
			mesh.surface_add_vertex(center + Vector3(cos(angle_b) * radius, 0.0, sin(angle_b) * radius))
			if segment % 6 == 0:
				mesh.surface_add_vertex(center - Vector3(cos(angle_a) * 0.30, 0.0, sin(angle_a) * 0.30))
				mesh.surface_add_vertex(center + Vector3(cos(angle_a) * 0.30, 0.0, sin(angle_a) * 0.30))
	mesh.surface_end()
	var instance := MeshInstance3D.new()
	instance.name = "ReefClusterDebug"
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	instance.custom_aabb = AABB(Vector3(-8.0, -14.0, -8.0), Vector3(tile_size_m + 16.0, 22.0, tile_size_m + 16.0))
	parent.add_child(instance)
