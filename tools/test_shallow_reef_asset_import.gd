extends SceneTree

## Checks the eight configured reef GLBs, geometry bounds, triangle counts, LOD
## data, and imported PBR texture references without building the main scene.

const LIBRARY_PATH := "res://resources/shallow_reef_assets.tres"

var _loaded_count := 0
var _failure_count := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var library := load(LIBRARY_PATH) as ShallowReefAssetLibrary
	if library == null:
		push_error("Could not load the ShallowReefAssetLibrary resource.")
		quit(1)
		return
	for definition in library.definitions:
		if definition == null or not definition.enabled:
			continue
		if not ResourceLoader.exists(definition.glb_path):
			push_error("Missing reef GLB: %s" % definition.glb_path)
			_failure_count += 1
			continue
		var packed := load(definition.glb_path) as PackedScene
		if packed == null:
			push_error("GLB did not import as PackedScene: %s" % definition.glb_path)
			_failure_count += 1
			continue
		var root_node := packed.instantiate()
		var stats := {"meshes": 0, "triangles": 0, "lod_surfaces": 0, "albedo": 0, "normal": 0, "bounds_valid": false, "bounds": AABB()}
		_inspect_node(root_node, Transform3D.IDENTITY, stats)
		root_node.free()
		if int(stats["meshes"]) == 0 or not bool(stats["bounds_valid"]):
			push_error("GLB contains no usable mesh: %s" % definition.asset_id)
			_failure_count += 1
			continue
		if int(stats["albedo"]) == 0 or int(stats["normal"]) == 0:
			push_warning("GLB %s imported without both albedo and normal maps." % definition.asset_id)
		else:
			_loaded_count += 1
		print("[ReefAssetCheck] %s · bounds %s m · %d mesh parts · %d source tris · %d surfaces with LOD · PBR albedo/normal %d/%d" % [
			definition.asset_id,
			str((stats["bounds"] as AABB).size),
			int(stats["meshes"]),
			int(stats["triangles"]),
			int(stats["lod_surfaces"]),
			int(stats["albedo"]),
			int(stats["normal"]),
		])
	if _loaded_count != 8 or _failure_count > 0:
		push_error("Reef asset import check failed: loaded=%d failures=%d" % [_loaded_count, _failure_count])
		quit(1)
		return
	print("[ReefAssetCheck] all %d configured GLBs and PBR maps loaded." % _loaded_count)
	quit(0)


func _inspect_node(node: Node, inherited: Transform3D, stats: Dictionary) -> void:
	var relative := inherited
	if node is Node3D:
		relative = inherited * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		var mesh := mesh_instance.mesh
		if mesh != null:
			stats["meshes"] = int(stats["meshes"]) + 1
			var bounds := ShallowReefGenerator._transformed_aabb(mesh.get_aabb(), relative)
			if not bool(stats["bounds_valid"]):
				stats["bounds"] = bounds
				stats["bounds_valid"] = true
			else:
				stats["bounds"] = (stats["bounds"] as AABB).merge(bounds)
			for surface in range(mesh.get_surface_count()):
				if mesh.has_method("surface_get_lods"):
					var lod_map: Dictionary = mesh.call("surface_get_lods", surface)
					if not lod_map.is_empty():
						stats["lod_surfaces"] = int(stats["lod_surfaces"]) + 1
				var index_length: int = mesh.surface_get_array_index_len(surface)
				var array_length: int = mesh.surface_get_array_len(surface)
				stats["triangles"] = int(stats["triangles"]) + int((index_length if index_length > 0 else array_length) / 3)
				var material := mesh_instance.get_surface_override_material(surface)
				if material == null:
					material = mesh_instance.material_override
				if material == null:
					material = mesh.surface_get_material(surface)
				if material is StandardMaterial3D:
					var standard := material as StandardMaterial3D
					if standard.albedo_texture != null:
						stats["albedo"] = int(stats["albedo"]) + 1
					if standard.normal_texture != null and standard.normal_enabled:
						stats["normal"] = int(stats["normal"]) + 1
	for child in node.get_children():
		_inspect_node(child, relative, stats)
